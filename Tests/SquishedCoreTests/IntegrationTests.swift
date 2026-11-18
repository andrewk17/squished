import XCTest
@testable import SquishedCore

/// Quoting checked through a real /bin/sh, since the remote side runs it the same way.
final class SSHCommandTests: XCTestCase {
    func testShellQuoteRoundTrip() throws {
        let original = "a 'quote'\n$HOME `touch /tmp/squished-should-not-exist` \\ unicode é"
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")

        p.arguments = ["-c", "printf %s " + SSHCommand.quote(original)]
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), original)
        XCTAssertEqual(p.terminationStatus, 0)
    }
}

final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SamplerFrame] = []
    let ready: XCTestExpectation
    init(_ ready: XCTestExpectation) {
        self.ready = ready
    }

    func append(_ f: SamplerFrame) {
        lock.lock()
        storage.append(f)
        let n = storage.count
        lock.unlock()
        if n == 3 {
            ready.fulfill()
        }
    }

    var frames: [SamplerFrame] {
        lock.lock()
        defer {
            lock.unlock()
        }

        return storage
    }
}

final class IntegrationTests: XCTestCase {
    #if os(Linux)
    private func readCommandLine(pid: Int32) throws -> Data {
        // /proc files report size zero. Swift 6.4.2's FileManager.contents(atPath:)
        // corrupts reads beyond one page; stream until EOF instead of sizing a buffer.
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/proc/\(pid)/cmdline"))
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }
    #endif

    /// On Linux, `Process` started from a libdispatch worker passes on that thread's
    /// blocked signal mask, so a local sampler shell can't receive SIGTERM or SIGCHLD and
    /// hangs in `wait` (sshd-started remote shells are unaffected). The session's delayed
    /// SIGKILL doesn't run once the test process has exited, so kill leftovers here.
    override func tearDown() {
        #if os(Linux)
            let me = getpid()
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? [] {
                guard let pid = Int32(entry),
                      let stat = try? String(contentsOfFile: "/proc/\(entry)/stat", encoding: .utf8),
                      let close = stat.lastIndex(of: ")"),
                      Int32(stat[stat.index(close, offsetBy: 2)...].split(separator: " ")[1]) == me,
                      let cmdline = try? readCommandLine(pid: pid),
                      String(decoding: cmdline, as: UTF8.self).contains("@@FLEET")
                else { continue }
                kill(pid, SIGKILL)
            }
        #endif
        super.tearDown()
    }

    func testCleanupReadsLongChildCommandLine() throws {
        #if os(Linux)
        let child = Process(), input = Pipe(), output = Pipe()
        let arguments = ["-c", "printf ready; read line", "squished-cmdline-fixture", String(repeating: "x", count: 32_000)]
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = arguments
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            child.waitUntilExit()
        }
        // Process.run() can return before Linux has installed the child's argv.
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 5), Data("ready".utf8))
        let expected = Data((["/bin/sh"] + arguments).joined(separator: "\0").utf8) + Data([0])
        let actual = try readCommandLine(pid: child.processIdentifier)
        XCTAssertEqual(actual, expected, "cleanup must read all pages of a real child's arguments")
        XCTAssertTrue(String(decoding: actual, as: UTF8.self) == String(decoding: expected, as: UTF8.self))
        #else
        throw XCTSkip("Linux /proc integration")
        #endif
    }

    /// A signal to the remote shell (sshd hangup, `pkill`) must end the session at once,
    /// not wait for stdin to close. A foreground `cat` used to defer the shell's traps.
    func testSamplerShellExitsPromptlyOnSignal() throws {
        let shell = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", RemoteSampler.script(interval: 1)]
        shell.standardInput = stdin
        shell.standardOutput = stdout
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        defer {
            try? stdin.fileHandleForWriting.close()
        }

        var received = Data()
        let firstFrameDeadline = Date().addingTimeInterval(10)
        while !String(decoding: received, as: UTF8.self).contains("@@END 1"), Date() < firstFrameDeadline {
            received.append(stdout.fileHandleForReading.availableData)
        }
        XCTAssertTrue(String(decoding: received, as: UTF8.self).contains("@@END 1"))

        kill(shell.processIdentifier, SIGTERM)
        let exitDeadline = Date().addingTimeInterval(3)
        while shell.isRunning, Date() < exitDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(shell.isRunning, "sampler shell ignored SIGTERM while stdin was still open")
        if shell.isRunning {
            shell.terminate()
        }
    }

    func testSamplerEveryInstalledAwk() throws {
        #if os(Linux)
            let node = Process()
            node.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = directory.appendingPathComponent("squished-named-worker.js")
            try "while (true) {}".write(to: fixture, atomically: true, encoding: .utf8)
            node.arguments = ["node", fixture.path]
            try node.run()
            defer { if node.isRunning { node.terminate(); node.waitUntilExit() } }
            var variants: [String] = []
            for name in ["mawk", "gawk", "busybox"] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")

                p.arguments = ["-c", "command -v " + name + " >/dev/null"]
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    variants.append(name == "busybox" ? "busybox awk" : name)
                }
            }

            if variants.isEmpty {
                variants = ["awk"]
            }

            // Keep the full-host smoke check, then isolate only PID enumeration for the
            // naming/member check. All stat/cmdline reads still use the real child.
            // A busy host can outrank that child or shorten its wire key below its name.
            for (variant, fixtureOnly) in variants.flatMap({ [($0, false), ($0, true)] }) {
                let done = expectation(description: "three frames: \(variant), fixture only: \(fixtureOnly)"), collector = FrameCollector(done)
                let session = SSHSession(
                    onFrame: {
                        collector.append($0)
                    },
                    onExit: {
                        status,
                        stderr in
                        if status != 0 {
                            print("Sampler exited: \(status): \(stderr)")
                        }
                    }

                )
                let program = fixtureOnly
                    ? RemoteSampler.program.replacingOccurrences(of: "cmd = \"ls /proc\"",
                        with: "cmd = \"echo \(node.processIdentifier)\"")
                    : RemoteSampler.program
                let script = RemoteSampler.script(interval: 1, awkCommand: variant)
                    .replacingOccurrences(of: SSHCommand.quote(RemoteSampler.program), with: SSHCommand.quote(program))
                session.launch(executable: "/bin/sh", arguments: ["-c", script])
                wait(for: [done], timeout: 12)
                session.terminateAndWait()
                let frames = collector.frames
                XCTAssertGreaterThanOrEqual(frames.count, 3, variant)
                guard frames.count >= 3 else {
                    continue
                }

                for frame in frames {
                    let bytes = "@@FLEET 1 \(frame.sequence)\n@@END \(frame.sequence)\n".utf8.count
                        + frame.sections.reduce(0) { $0 + $1.key.utf8.count + 2 + $1.value.utf8.count }
                    XCTAssertLessThan(bytes, 2048, "Full wire frame exceeds budget: \(variant)")
                    print("Sampler wire frame (\(variant), fixture only \(fixtureOnly), seq \(frame.sequence)): \(bytes) bytes")
                }
                XCTAssertEqual(frames[0].info?.osName, "Linux")
                XCTAssertGreaterThan(frames[0].info?.cpuCount ?? 0, 0)
                XCTAssertTrue(frames[0].snapshot(previousCPU: nil).topProcesses.isEmpty)
                for i in 1...2 {
                    let snapshot = frames[i].snapshot(
                        previousCPU: frames[i - 1].sections["cpu"].flatMap(LinuxParser.cpu),
                        previousNetwork: frames[i - 1].sections["net"].flatMap(LinuxParser.network),
                        previousUptime: frames[i - 1].sections["uptime"].flatMap(LinuxParser.uptime)
                    )
                    XCTAssertNotNil(snapshot.cpu, variant)
                    XCTAssertNotNil(snapshot.memory, variant)

                    XCTAssertNotNil(frames[i].sections["net"], variant)
                    XCTAssertNotNil(snapshot.networkCounters, variant)
                    XCTAssertNotNil(snapshot.network, variant)
                    XCTAssertNotNil(snapshot.disk, variant)
                    XCTAssertTrue(snapshot.disks.contains { $0.mount == "/" }, variant)
                    let mounts = (try? String(contentsOfFile: "/proc/mounts", encoding: .utf8)) ?? ""
                    if mounts.split(separator: "\n").contains(where: { $0.hasPrefix("/dev/") && $0.split(separator: " ").dropFirst().first == "/home" }) {
                        XCTAssertTrue(snapshot.disks.contains { $0.mount == "/home" }, variant)
                    }
                    XCTAssertNotNil(snapshot.load, variant)

                    XCTAssertNotNil(snapshot.uptime, variant)
                    XCTAssertFalse(snapshot.groups.isEmpty, variant)
                    XCTAssertNotNil(snapshot.memoryBreakdown, variant)
                    XCTAssertNotNil(frames[i].sections["members"], variant)
                    if fixtureOnly {
                        XCTAssertEqual(snapshot.groups.count, 1, variant)
                        let named = try XCTUnwrap(snapshot.groups.first, variant)
                        XCTAssertEqual(named.name, "squished-named-worker", variant)
                        XCTAssertGreaterThan(named.cpuPercent, 0, variant)
                        XCTAssertGreaterThan(named.memoryBytes, 0, variant)
                        XCTAssertTrue(named.processes.contains { $0.pid == node.processIdentifier }, variant)
                    }
                    let processLines = (frames[i].sections["groups"] ?? "").split(
                        separator: "\n",
                        omittingEmptySubsequences: false
                    ).dropLast()
                    XCTAssertFalse(
                        processLines.contains {
                            $0.trimmingCharacters(in: .whitespaces).isEmpty
                        },
                        variant
                    )
                    if i == 2 {
                        XCTAssertLessThanOrEqual(snapshot.groups.count, 16, variant)

                        XCTAssertLessThanOrEqual(processLines.count, 16, variant)
                    }

                    XCTAssertLessThan(
                        frames[i].sections.values.reduce(0) {
                            $0 + $1.utf8.count
                        },
                        2048
                    )
                }
            }

        #else
            throw XCTSkip("Linux /proc integration")
        #endif
    }

    func testSamplerParenthesesInRealProcessName() throws {
        #if os(Linux)
            // /proc/self/comm is writable: Linux comm allows spaces and closing parentheses.
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = ["-c", "printf 'busy ) worker' > /proc/self/comm; while :; do :; done"]
            try child.run()
            defer {
                if child.isRunning {
                    child.terminate()
                }
            }

            let done = expectation(description: "named process frames"), collector = FrameCollector(done)
            let session = SSHSession(
                onFrame: {
                    collector.append($0)
                },
                onExit: {
                    _,
                    _ in
                }
            )
            session.launch(executable: "/bin/sh", arguments: ["-c", RemoteSampler.script(interval: 1)])
            wait(for: [done], timeout: 10)
            session.terminateAndWait()
            XCTAssertTrue(
                collector.frames.dropFirst().contains {
                    $0.snapshot(previousCPU: nil).groups.contains {
                        $0.name == "busy ) worker" && $0.cpuPercent > 0
                    }
                }

            )
        #else
            throw XCTSkip("Linux process naming")
        #endif
    }

    func testSSHOptIn() throws {
        guard let host = ProcessInfo.processInfo.environment["SQUISHED_SSH_TEST_HOST"], !host.isEmpty else {
            throw XCTSkip("Set SQUISHED_SSH_TEST_HOST to exercise real SSH")
        }

        let done = expectation(description: "SSH three frames"), collector = FrameCollector(done)
        let session = SSHSession(
            onFrame: {
                collector.append($0)
            },
            onExit: {
                status,
                stderr in print("SSH exit \(status): \(stderr)")
            }

        )
        session.start(alias: host, interval: 1)
        wait(for: [done], timeout: 20)
        session.terminateAndWait()
        XCTAssertGreaterThanOrEqual(collector.frames.count, 3)
    }

    func testFrameArrivesBeforeStreamCloses() {
        let done = expectation(description: "frame delivered while child is still running")
        done.expectedFulfillmentCount = 2
        let session = SSHSession(onFrame: { frame in
            let snapshot = frame.snapshot(previousCPU: nil)
            XCTAssertEqual(snapshot.memory?.percent, 90)
            // High usage is not pressure: frame 1 has a normal PSI reading, frame 2 has
            // no PSI and falls back to the available fraction (10% left is still normal).
            XCTAssertEqual(snapshot.memory?.pressure, .normal)
            XCTAssertEqual(snapshot.disk?.mount, "/data")
            if let root = snapshot.disks.first(where: { $0.mount == "/" }) {
                XCTAssertEqual(FleetFormat.compactFreeSpace(root.total - root.used), "9")
            } else {
                XCTFail("root partition missing from streamed frame")
            }
            if let disk = snapshot.disk {
                XCTAssertEqual(FleetFormat.compactFreeSpace(disk.total - disk.used), "512M")
                XCTAssertEqual(LoadLevel.disk(percent: disk.percent), .elevated)
            } else {
                XCTFail("headline disk missing from streamed frame")
            }
            done.fulfill()
        }, onExit: { _, _ in })
        session.launch(executable: "/bin/sh", arguments: [
            "-c", """
            for seq in 1 2; do
                printf '@@FLEET 1 %s\n#cpu\ncpu 1 0 1 1\n#mem\nMemTotal: 1000 kB\nMemAvailable: 100 kB\n' "$seq"
                if [ "$seq" = 1 ]; then printf '#psi\nsome avg10=0.00 avg60=0.00 avg300=0.00 total=0\n'; fi
                printf '#df\n/dev/root 10485760 1048576 9437184 10%% /\n/dev/data 5242880 4718592 524288 90%% /data\n@@END %s\n' "$seq"
            done
            exec sleep 5
            """,
        ])
        defer { session.terminateAndWait() }
        wait(for: [done], timeout: 2)
    }

    func testRestartWhilePipesAreReadable() {
        let done = expectation(description: "final session exits after repeated pipe teardown")
        let session = SSHSession(
            onFrame: { _ in

            },
            onExit: {
                status,
                stderr in
                if status == 42 {
                    XCTAssertTrue(stderr.contains("final session"))
                    done.fulfill()
                }
            }

        )
        for _ in 0..<20 {
            session.launch(
                executable: "/bin/sh",
                arguments: [
                    "-c", "while :; do printf 'stdout data\n'; printf 'stderr data\n' >&2; done",
                ]
            )
            // Give readability callbacks work while the serial session queue closes stdin.
            Thread.sleep(forTimeInterval: 0.01)
            session.terminateAndWait()
        }

        session.launch(executable: "/bin/sh", arguments: ["-c", "echo 'final session' >&2; exit 42"])
        wait(for: [done], timeout: 5)
        session.terminateAndWait()
    }

    func testImmediateExitStderr() throws {
        let done = expectation(description: "stderr delivered")
        let session = SSHSession(
            onFrame: { _ in
                XCTFail("unexpected frame")
            },
            onExit: {
                status,
                stderr in
                XCTAssertEqual(status, 42)
                XCTAssertTrue(stderr.contains("Could not resolve hostname mni"))

                done.fulfill()
            }

        )
        session.launch(
            executable: "/bin/sh",
            arguments: ["-c", "echo 'ssh: Could not resolve hostname mni' >&2; exit 42"]
        )
        wait(for: [done], timeout: 5)
        session.terminateAndWait()
    }
}

extension IntegrationTests {
    /// Exercise df's BusyBox fallback, wire filtering and decoding together in real shells.
    func testPartitionSamplerFallbackAcrossAwks() throws {
        #if os(Linux)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let df = directory.appendingPathComponent("df")
        try """
        #!/bin/sh
        [ "$1" = '-Pkl' ] && exit 1
        [ "$1" = '-Pk' ] || exit 2
        cat <<'DF'
        Filesystem 1024-blocks Used Available Capacity Mounted on
        /dev/sda1 153707984 31276892 114550388 22% /
        /dev/sda2 841867264 87364920 751675896 11% /srv/subvolume
        /dev/sda2 841867264 87364920 751675896 11% /srv
        /dev/sda3 10000000 9000000 1000000 90% /data
        /dev/sda4 10000000 5000000 5000000 50% /volume1
        /dev/sda5 10000000 4000000 6000000 40% /volumeUSB1/usbshare
        /dev/sda6 10000000 3000000 7000000 30% /work
        /dev/sda7 10000000 2000000 8000000 20% /z-last
        /dev/md0 2400000 2200000 200000 92% /dsm
        /dev/loop0 10000000 10000000 0 100% /snap/core/1
        /dev/loop1 10000000 10000000 0 100% /elsewhere
        /dev/sda8 10000000 9000000 1000000 90% /boot/efi
        /dev/sda9 10000000 9000000 1000000 90% /var/lib/docker/data
        /dev/sda10 10000000 9000000 1000000 90% /run/media
        overlay 10000000 9900000 100000 99% /var/lib/docker/overlay2/merged
        tmpfs 10000000 9900000 100000 99% /tmp
        DF
        """.write(to: df, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: df.path)
        for variant in ["mawk", "gawk", "busybox"]
        where FileManager.default.isExecutableFile(atPath: "/usr/bin/" + variant) {
            let done = expectation(description: "partition frames: \(variant)"), collector = FrameCollector(done)
            let session = SSHSession(onFrame: { collector.append($0) }, onExit: { _, _ in })
            let path = directory.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            session.launch(executable: "/bin/sh", arguments: ["-c",
                "PATH=" + SSHCommand.quote(path) + "; export PATH\n"
                + RemoteSampler.script(interval: 0.1, awkCommand: variant == "busybox" ? "busybox awk" : variant)
            ])
            wait(for: [done], timeout: 10)
            session.terminateAndWait()
            XCTAssertGreaterThanOrEqual(collector.frames.count, 3, variant)
            for frame in collector.frames {
                let host = frame.snapshot(previousCPU: nil)
                XCTAssertEqual(host.disks.map(\.mount), ["/", "/data", "/srv", "/volume1", "/volumeUSB1/usbshare", "/work"], variant)
                XCTAssertEqual(host.disk?.mount, "/data", variant)
                XCTAssertEqual((frame.sections["df"] ?? "").split(separator: "\n").count, 6, variant)
                let bytes = "@@FLEET 1 \(frame.sequence)\n@@END \(frame.sequence)\n".utf8.count
                    + frame.sections.reduce(0) { $0 + $1.key.utf8.count + 2 + $1.value.utf8.count }
                XCTAssertLessThan(bytes, 2048, "six-partition wire frame exceeds budget: \(variant)")
            }
        }
        #else
        throw XCTSkip("Linux /proc integration")
        #endif
    }
}


extension IntegrationTests {
    /// Run the complete awk sampler and frame decoder against a proc-filesystem
    /// boundary fixture, including on macOS where /proc itself is unavailable.
    func testEmulatorStartTimesAcrossAwks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("uptime", "1000.00 1000.00\n")
        try write("meminfo", "MemTotal: 10000 kB\nMemAvailable: 5000 kB\n")
        try write("loadavg", "0.00 0.00 0.00 1/3 103\n")
        try write("net/dev", "")
        for (pid, ticks, name) in [(101, 500, "emulator"), (102, 900, "emulator"), (103, 100, "ordinary")] {
            var fields = Array(repeating: "0", count: 22)
            fields[0] = "S"; fields[1] = "1"; fields[19] = String(ticks); fields[21] = "256"
            try write("\(pid)/stat", "\(pid) (\(name)) " + fields.joined(separator: " ") + "\n")
        }
        for pid in [101, 102] { try write("\(pid)/cmdline", "emulator\0-avd\0Squished_Uptime_Fixture\0") }
        let clock = Process(), output = Pipe()
        clock.executableURL = URL(fileURLWithPath: "/usr/bin/getconf")
        clock.arguments = ["CLK_TCK"]; clock.standardOutput = output
        try clock.run()
        let hzText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        clock.waitUntilExit()
        let hz = try XCTUnwrap(Double(hzText.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertGreaterThan(hz, 0)
        let program = RemoteSampler.program.replacingOccurrences(of: "/proc", with: root.path)
            .replacingOccurrences(of: "os = command(\"uname -s\")", with: "os = \"Linux\"")
        for variant in ["awk", "mawk", "gawk", "busybox awk"] {
            let lookup = Process()
            lookup.executableURL = URL(fileURLWithPath: "/bin/sh")
            lookup.arguments = ["-c", "command -v " + String(variant.split(separator: " ")[0]) + " >/dev/null"]
            try lookup.run(); lookup.waitUntilExit()
            guard lookup.terminationStatus == 0 else { continue }
            for (knownStart, crowded) in [(true, false), (false, false), (true, true)] {
                if crowded {
                    for pid in 200..<220 {
                        var fields = Array(repeating: "0", count: 22)
                        fields[0] = "S"; fields[1] = "1"; fields[19] = "500"
                        try write("\(pid)/stat", "\(pid) (emulator) " + fields.joined(separator: " ") + "\n")
                        try write("\(pid)/cmdline", "emulator\0-avd\0Crowded_\(pid)_" + String(repeating: "x", count: 32) + "\0")
                    }
                }
                try write("stat", "cpu 1 0 1 100\ncpu0 1 0 1 100\n" + (knownStart ? "btime 1700000000\n" : ""))
                let done = expectation(description: "emulator start frames: \(variant), known \(knownStart)")
                let collector = FrameCollector(done)
                let session = SSHSession(onFrame: { collector.append($0) }, onExit: { _, _ in })
                let script = RemoteSampler.script(interval: 0.1, awkCommand: variant)
                    .replacingOccurrences(of: SSHCommand.quote(RemoteSampler.program), with: SSHCommand.quote(program))
                session.launch(executable: "/bin/sh", arguments: ["-c", script])
                wait(for: [done], timeout: 10)
                session.terminateAndWait()
                XCTAssertGreaterThanOrEqual(collector.frames.count, 3, variant)
                for frame in collector.frames {
                    let bytes = "@@FLEET 1 \(frame.sequence)\n@@END \(frame.sequence)\n".utf8.count
                        + frame.sections.reduce(0) { $0 + $1.key.utf8.count + 2 + $1.value.utf8.count }
                    XCTAssertLessThan(bytes, 2048, variant)
                    if crowded {
                        let sample = frame.snapshot(previousCPU: nil)
                        XCTAssertFalse(sample.hasSimulatorSample, "overflow must not look like fresh disappearance")
                        XCTAssertFalse(sample.simulatorDevices.isEmpty)
                        XCTAssertLessThan(sample.simulatorDevices.count, 21)
                        continue
                    }
                    let groups = frame.snapshot(previousCPU: nil).groups
                    let emulator = try XCTUnwrap(groups.first { $0.id == "android:Squished_Uptime_Fixture" })
                    XCTAssertEqual(emulator.processCount, 2)
                    let sample = frame.snapshot(previousCPU: nil)
                    XCTAssertTrue(sample.hasSimulatorSample)
                    let device = try XCTUnwrap(sample.simulatorDevices.first { $0.id == emulator.id })
                    XCTAssertEqual(device.startedAt, emulator.startedAt)
                    XCTAssertEqual(device.cpuPercent, emulator.cpuPercent)
                    XCTAssertEqual(device.memoryBytes, emulator.memoryBytes)
                    if knownStart {
                        let started = try XCTUnwrap(emulator.startedAt)
                        XCTAssertEqual(started.timeIntervalSince1970, floor(1_700_000_000 + 500 / hz))
                    } else { XCTAssertNil(emulator.startedAt) }
                    XCTAssertNil(groups.first { $0.name == "ordinary" }?.startedAt)
                }
                if crowded {
                    for pid in 200..<220 { try FileManager.default.removeItem(at: root.appendingPathComponent(String(pid))) }
                }
            }
        }
    }
}

extension IntegrationTests {
    /// Stream real child-process frames through the decoder, reconcile them into
    /// an atomic JSON file, then reopen it as a new app launch would.
    func testSimulatorSessionPersistenceFromStreamedFrames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("simulator-sessions.json")
        let base: TimeInterval = 1_700_000_000
        func capture(_ bodies: [String]) throws -> [SamplerFrame] {
            let wire = bodies.enumerated().map { index, body in
                "@@FLEET 1 \(index + 1)\n#devices\n\(body)@@END \(index + 1)\n"
            }.joined()
            let done = expectation(description: "three session frames"), collector = FrameCollector(done)
            let session = SSHSession(onFrame: { collector.append($0) }, onExit: { _, _ in })
            session.launch(executable: "/bin/sh", arguments: ["-c", "printf %s " + SSHCommand.quote(wire) + "; exec sleep 5"])
            wait(for: [done], timeout: 5)
            session.terminateAndWait()
            XCTAssertEqual(collector.frames.count, 3)
            return collector.frames
        }
        func inode() throws -> NSNumber {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)
        }
        let history = try SimulatorSessionStore(url: url, now: Date(timeIntervalSince1970: base))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let first = try capture(["1700000000 0 0 Fixture\ncomplete\n", "", "0 0 0 Fixture\ncomplete\n"])
        let initial = first[0].snapshot(previousCPU: nil, at: Date(timeIntervalSince1970: base + 10))
        XCTAssertTrue(try history.reconcile(hostID: "remote-host", devices: initial.simulatorDevices,
                                            at: initial.timestamp, fresh: initial.hasSimulatorSample))
        XCTAssertEqual(history.sessions.first?.start, Date(timeIntervalSince1970: base))
        let unchangedFile = try inode()
        for (offset, frame) in first.dropFirst().enumerated() {
            let snapshot = frame.snapshot(previousCPU: nil, at: Date(timeIntervalSince1970: base + 20 + Double(offset)))
            XCTAssertFalse(try history.reconcile(hostID: "remote-host", devices: snapshot.simulatorDevices,
                                                 at: snapshot.timestamp, fresh: snapshot.hasSimulatorSample))
            XCTAssertNil(history.sessions.first?.end)
            XCTAssertEqual(try inode(), unchangedFile, "missing telemetry or an unknown start must not rewrite history")
        }
        let reopened = try SimulatorSessionStore(url: url, now: Date(timeIntervalSince1970: base + 30))
        XCTAssertFalse(try reopened.reconcile(hostID: "remote-host", devices: initial.simulatorDevices,
                                              at: Date(timeIntervalSince1970: base + 30), fresh: true))
        XCTAssertEqual(try inode(), unchangedFile, "the same session after relaunch must not duplicate or rewrite")
        let events = try capture(["1700000040 0 0 Fixture\ncomplete\n", "complete\n", "1700000050 0 0 AnotherDevice\ncomplete\n"])
        for (offset, frame) in events.enumerated() {
            let date = Date(timeIntervalSince1970: base + 50 + Double(offset) * 10)
            let snapshot = frame.snapshot(previousCPU: nil, at: date)
            XCTAssertTrue(try reopened.reconcile(hostID: "remote-host", devices: snapshot.simulatorDevices,
                                                 at: date, fresh: snapshot.hasSimulatorSample))
        }
        XCTAssertEqual(reopened.sessions.count, 3)
        XCTAssertEqual(reopened.sessions[0].end, Date(timeIntervalSince1970: base + 40), "a restart between polls ends the old session")
        XCTAssertEqual(reopened.sessions[1].end, Date(timeIntervalSince1970: base + 60), "fresh disappearance ends the session")
        XCTAssertNil(reopened.sessions[2].end)
        let pruned = try SimulatorSessionStore(url: url, now: Date(timeIntervalSince1970: base + 8 * 86400))
        XCTAssertEqual(pruned.sessions.count, 1, "launch pruning drops old completed sessions")
        XCTAssertEqual(pruned.sessions.first?.name, "AnotherDevice", "long-running open sessions survive retention pruning")
        let prunedFile = try inode()
        XCTAssertFalse(try pruned.prune(at: Date(timeIntervalSince1970: base + 8 * 86400)))
        XCTAssertEqual(try inode(), prunedFile)
        let final = try SimulatorSessionStore(url: url, now: Date(timeIntervalSince1970: base + 8 * 86400))
        XCTAssertEqual(final.sessions, pruned.sessions)
    }
}
