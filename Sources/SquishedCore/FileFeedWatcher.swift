#if os(macOS)
import Foundation
import Darwin

/// Directory events catch atomic replacements; per-file events also catch in-place
/// writes. Watching the nearest existing parent handles missing/recreated folders.
public final class FileFeedWatcher: @unchecked Sendable {
    private let root: URL
    private let receive: @Sendable (FileFeeds) -> Void
    private let queue = DispatchQueue(label: "me.andrewkim.squished.feeds", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var stopped = true
    public init(root: URL, receive: @escaping @Sendable (FileFeeds) -> Void) {
        self.root = root; self.receive = receive
    }
    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            self.reload()
        }
    }
    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.pending?.cancel()
            self.sources.forEach { $0.cancel() }
            self.sources.removeAll()
        }
    }
    private func scheduleReload() {
        guard !stopped else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
    private func reload() {
        guard !stopped else { return }
        sources.forEach { $0.cancel() }
        sources.removeAll()
        let manager = FileManager.default
        var parent = root.deletingLastPathComponent()
        while !manager.fileExists(atPath: parent.path), parent.path != "/" { parent.deleteLastPathComponent() }
        let jobs = root.appendingPathComponent("jobs")
        var urls = [parent, root, jobs, root.appendingPathComponent("devices.json")]
        urls += (try? manager.contentsOfDirectory(at: jobs, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []
        for url in Set(urls) {
            let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: queue)
            source.setEventHandler { [weak self] in self?.scheduleReload() }
            source.setCancelHandler { close(descriptor) }
            sources.append(source)
            source.resume()
        }
        receive(FileFeeds.read(root: root))
    }
    deinit { pending?.cancel(); sources.forEach { $0.cancel() } }
}
#endif
