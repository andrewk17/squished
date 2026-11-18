import Foundation
#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

/// All mutable state is confined to `queue`. Callbacks are serialized on that queue.
public final class SSHSession: @unchecked Sendable {
    public typealias FrameHandler = @Sendable (SamplerFrame) -> Void
    public typealias ExitHandler = @Sendable (Int32, String) -> Void
    private let queue = DispatchQueue(label: "me.andrewkim.squished.ssh", qos: .utility)
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    #if os(macOS)
        private var outputReader: DispatchSourceRead?
        private var errorReader: DispatchSourceRead?
    #endif
    private var decoder = FrameDecoder()
    private var stderrTail = Data()
    private var generation: UInt64 = 0
    private let onFrame: FrameHandler
    private let onExit: ExitHandler
    public init(onFrame: @escaping FrameHandler, onExit: @escaping ExitHandler) {
        self.onFrame = onFrame
        self.onExit = onExit
    }

    public func start(alias: String, interval: TimeInterval) {
        do {
            let argv = try SSHCommand.arguments(alias: alias, interval: interval)

            launch(executable: "/usr/bin/ssh", arguments: argv)
        } catch {
            queue.async {
                self.onExit(-1, error.localizedDescription)
            }
        }
    }

    /// Also used to exercise the actual pipe lifecycle with a local shell in tests.
    public func launch(executable: String, arguments: [String]) {
        queue.async {
            self.startProcess(executable: executable, arguments: arguments)
        }
    }

    private func startProcess(executable: String, arguments: [String]) {
        stopProcess()
        generation &+= 1
        let token = generation
        decoder = FrameDecoder()
        stderrTail = Data()
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        process = child
        input = stdin
        output = stdout
        errors = stderr
        #if !os(macOS)
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in

                let data = (try? Self.readAvailable(handle)) ?? Data()
                self?.queue.async { [weak self] in

                    guard let self, self.generation == token else {
                        return
                    }

                    if data.isEmpty {
                        handle.readabilityHandler = nil
                    }

                    for frame in self.decoder.append(data) {
                        self.onFrame(frame)
                    }
                }
            }

            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in

                let data = (try? Self.readAvailable(handle)) ?? Data()
                self?.queue.async { [weak self] in

                    guard let self, self.generation == token else {
                        return
                    }

                    if data.isEmpty {
                        handle.readabilityHandler = nil
                    }

                    self.stderrTail.append(data)
                    self.stderrTail = Data(self.stderrTail.suffix(4096))
                }
            }

        #endif

        child.terminationHandler = { [weak self] child in

            self?.queue.async { [weak self] in

                guard let self, self.generation == token else {
                    return
                }

                // Drain stderr after exit so a short-lived DNS/authentication error isn't lost.
                stderr.fileHandleForReading.readabilityHandler = nil
                self.stderrTail.append(((try? stderr.fileHandleForReading.readToEnd()) ?? Data()))
                self.stderrTail = Data(self.stderrTail.suffix(4096))
                stdout.fileHandleForReading.readabilityHandler = nil
                for frame in self.decoder.append(((try? stdout.fileHandleForReading.readToEnd()) ?? Data())) {
                    self.onFrame(frame)
                }

                self.onExit(child.terminationStatus, String(decoding: self.stderrTail, as: UTF8.self))
                self.closePipes()
                self.process = nil
            }
        }

        #if os(macOS)
            // Deliver readiness directly on the session queue. FileHandle's
            // monitoring queue can enqueue thousands of callbacks before a read.
            outputReader = makeReader(stdout.fileHandleForReading, token: token) { [weak self] data in
                guard let self else { return }
                for frame in self.decoder.append(data) { self.onFrame(frame) }
            }
            errorReader = makeReader(stderr.fileHandleForReading, token: token) { [weak self] data in
                guard let self else { return }
                self.stderrTail.append(data)
                self.stderrTail = Data(self.stderrTail.suffix(4096))
            }
        #endif
        do {
            try child.run()
        } catch {
            closePipes()
            process = nil
            onExit(-1, error.localizedDescription)
        }
    }

    public func terminate() {
        queue.async {
            self.stopProcess()
        }
    }

    /// Wait until termination has been requested and the stdin writer is closed (app shutdown).
    public func terminateAndWait() {
        queue.sync {
            stopProcess()
        }
    }

    private func stopProcess() {
        generation &+= 1
        guard let child = process else {
            closePipes()
            return
        }

        child.terminationHandler = nil
        try? input?.fileHandleForWriting.close()
        if child.isRunning {
            child.terminate()
            queue.asyncAfter(deadline: .now() + 2) {
                if child.isRunning {
                    _ = kill(child.processIdentifier, SIGKILL)
                }
            }
        }

        closePipes()
        process = nil
    }

    #if os(macOS)
        private func makeReader(_ handle: FileHandle, token: UInt64,
                                consume: @escaping @Sendable (Data) -> Void) -> DispatchSourceRead {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self, self.generation == token else { return }
                guard let data = try? Self.readAvailable(handle) else { return }
                if data.isEmpty {
                    // Process termination cancels sources; suspend EOF readiness meanwhile.
                    if handle === self.output?.fileHandleForReading { self.outputReader?.cancel() }
                    else { self.errorReader?.cancel() }
                } else { consume(data) }
            }
            source.resume()
            return source
        }
    #endif

    private static func readAvailable(_ handle: FileHandle) throws -> Data? {
        #if os(Linux)
            var available: Int32 = 0
            guard ioctl(handle.fileDescriptor, UInt(FIONREAD), &available) == 0 else {
                throw POSIXError(.EIO)
            }
            return try handle.read(upToCount: max(1, min(65536, Int(available))))
        #else
            // Foundation's read(upToCount:) waits to fill a pipe read on macOS.
            // POSIX read returns the available bytes immediately after readability.
            var data = Data(count: 65536)
            let count = data.withUnsafeMutableBytes { bytes in
                Darwin.read(handle.fileDescriptor, bytes.baseAddress!, bytes.count)
            }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { return nil }
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            data.count = count
            return data
        #endif
    }

    private func closePipes() {
        #if os(macOS)
            outputReader?.cancel()
            errorReader?.cancel()
            outputReader = nil
            errorReader = nil
        #endif
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        // A running readability callback retains its handle. Let it finish before deallocation.
        try? input?.fileHandleForWriting.close()
        input = nil
        output = nil
        errors = nil
    }

    deinit {
        if let child = process, child.isRunning {
            child.terminate()
        }

        try? input?.fileHandleForWriting.close()
    }
}
