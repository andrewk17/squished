import Foundation

public enum ConnectionAction: Sendable, Equatable {
    case launch, terminate, scheduleRetry(Date)
}

public enum ConnectionEvent: Sendable {
    case start, frameReceived(at: Date), processExited(status: Int32, stderrTail: String), tick, retryNow, wake
}

public struct ConnectionMachine: Sendable {
    public private(set) var state: ConnectionState = .connecting
    public private(set) var failures = 0
    private var launchedAt: Date?
    private var lastFrame: Date?
    public let interval: TimeInterval
    private let clock: @Sendable () -> Date
    private let jitter: @Sendable () -> Double
    public init(
        interval: TimeInterval,
        clock: @escaping @Sendable () -> Date = {
            Date()
        },
        jitter: @escaping @Sendable () -> Double = {
            Double.random(in: -0.1...0.1)
        }

    ) {
        self.interval = max(0.1, interval)
        self.clock = clock
        self.jitter = jitter
    }

    @discardableResult public mutating func send(_ event: ConnectionEvent) -> [ConnectionAction] {
        let now = clock()
        switch event {
        case .start: return launch(now)
        case .wake, .retryNow:
            failures = 0
            return [.terminate] + launch(now)
        case .frameReceived(let at):
            guard launchedAt != nil else {
                return []
            }

            lastFrame = at
            failures = 0
            state = .live
            return []
        case .processExited(let status, let stderr):
            guard launchedAt != nil else {
                return []
            }

            return offline(Self.reason(status: status, stderr: stderr), now: now, terminate: false)
        case .tick:
            if case .offline(_, let retryAt) = state {
                return now >= retryAt ? launch(now) : []
            }

            guard let launchedAt else {
                return []
            }

            guard let lastFrame else {
                return now.timeIntervalSince(launchedAt) >= 11 ? offline("Timed out", now: now, terminate: true) : []
            }

            let age = now.timeIntervalSince(lastFrame)
            if age >= max(10, 5 * interval) {
                return offline("No data received", now: now, terminate: true)
            }

            if age >= 3 * interval {
                state = .stale(since: lastFrame)
            }

            return []
        }
    }

    private mutating func launch(_ now: Date) -> [ConnectionAction] {
        launchedAt = now
        lastFrame = nil
        state = .connecting
        return [.launch]
    }

    private mutating func offline(_ reason: String, now: Date, terminate: Bool) -> [ConnectionAction] {
        let delay = [1.0, 2, 4, 8, 16, 30][min(failures, 5)] * (1 + max(-0.1, min(0.1, jitter())))
        failures = min(failures + 1, 6)
        launchedAt = nil
        lastFrame = nil
        let retry = now.addingTimeInterval(delay)
        state = .offline(reason: reason, retryAt: retry)
        return (terminate ? [.terminate] : []) + [.scheduleRetry(retry)]
    }

    public static func reason(status: Int32, stderr: String) -> String {
        var line =
            stderr.split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.last(
                where: {
                    !$0.isEmpty
                }
            ) ?? ""
        while line.hasPrefix("ssh: ") {
            line = String(line.dropFirst(5))
        }

        if line.localizedCaseInsensitiveContains("connection timed out") {
            return "Connection timed out"
        }

        if line.localizedCaseInsensitiveContains("permission denied") {
            return "Permission denied (publickey)"
        }

        return line.isEmpty ? "Disconnected (exit \(status))" : String(line.prefix(300))
    }
}
