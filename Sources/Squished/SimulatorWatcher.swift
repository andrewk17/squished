import Foundation
import Darwin
import SquishedCore

struct SimulatorState: Sendable, Equatable {
    var devices: [SimulatorDevice] = []

}

/// File reads only. Device identities are also needed by background history;
/// Device labels are supplied independently through the optional file feed.
final class SimulatorWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "me.andrewkim.squished.simulators", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let receive: @Sendable (SimulatorState) -> Void
    init(receive: @escaping @Sendable (SimulatorState) -> Void) { self.receive = receive }
    func configure(open: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: open ? 10 : 60, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.refresh(open: open) }
            self.timer = timer
            timer.resume()
        }
    }
    private func refresh(open: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let devices = urls.compactMap { url -> SimulatorDevice? in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("device.plist")) else { return nil }
            return SimulatorDevice.parse(id: url.lastPathComponent, data: data)
        }.sorted { $0.name < $1.name }
        var state = SimulatorState()
        state.devices = devices
        receive(state)
    }
    func stop() { queue.async { [weak self] in self?.timer?.cancel(); self?.timer = nil } }
    deinit { timer?.cancel() }
}
