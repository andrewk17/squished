import Foundation
import SquishedCore

@MainActor
final class RemoteHostSampler {
    private let model: HostModel
    private let changed: () -> Void
    private let interval: Double
    private var machine: ConnectionMachine
    private var session: SSHSession?
    private var timer: Timer?
    private var previousNetwork: NetworkCounters?
    private var previousUptime: Double?
    private var previousCPU: CPUTicks?
    private var generation = UUID()
    private var suspended = false
    init(model: HostModel, interval: Double, changed: @escaping () -> Void) {
        self.model = model
        self.interval = interval
        self.changed = changed
        machine = ConnectionMachine(interval: interval)
    }

    func start() {
        send(.start)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in

            Task { @MainActor in

                guard let self, !self.suspended else {
                    return
                }

                self.send(.tick)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        suspended = true
        disconnect()
    }

    func suspend() {
        suspended = true
        disconnect()
    }

    func wake() {
        suspended = false
        send(.wake)
    }

    func retry() {
        suspended = false
        send(.retryNow)
    }

    private func send(_ event: ConnectionEvent) {
        let actions = machine.send(event)
        if model.state != machine.state {
            model.state = machine.state
        }

        for action in actions {
            switch action {
            case .terminate: disconnect()
            case .launch: launch()
            case .scheduleRetry: break  // The main-actor tick owns the retry clock.
            }
        }

        changed()
    }

    private func disconnect() {
        generation = UUID()
        session?.terminateAndWait()
        session = nil
        previousCPU = nil
        previousNetwork = nil
        previousUptime = nil
    }

    private func launch() {
        disconnect()
        guard case .ssh(let alias) = model.config.kind else {
            return
        }

        let token = generation
        let runner = SSHSession(
            onFrame: { [weak self] frame in

                Task { @MainActor in

                    guard let self, self.generation == token, !self.suspended else {
                        return
                    }

                    if let info = frame.info {
                        if self.model.info != info {
                            self.model.info = info
                        }

                        if info.osName != "Linux" {
                            self.disconnect()

                            self.send(.processExited(status: 1, stderrTail: "Unsupported OS: \(info.osName)"))
                            return
                        }
                    }

                    let snapshot = frame.snapshot(previousCPU: self.previousCPU, previousNetwork: self.previousNetwork, previousUptime: self.previousUptime)
                    self.previousCPU = frame.sections["cpu"].flatMap(LinuxParser.cpu)
                    self.previousNetwork = snapshot.networkCounters
                    self.previousUptime = snapshot.uptime
                    self.model.receive(snapshot)
                    self.send(.frameReceived(at: snapshot.timestamp))
                }
            },
            onExit: { [weak self] status, stderr in

                Task { @MainActor in

                    guard let self, self.generation == token, !self.suspended else {
                        return
                    }

                    self.send(.processExited(status: status, stderrTail: stderr))
                }
            }

        )
        session = runner
        runner.start(alias: alias, interval: interval)
    }
}
