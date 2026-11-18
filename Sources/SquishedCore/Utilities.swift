import Foundation

public struct HistoryBuffer<T: Sendable>: Sendable {
    private var storage: [T?]
    private var next = 0
    public private(set) var count = 0
    public var capacity: Int {
        storage.count
    }

    public init(capacity: Int) {
        storage = Array(repeating: nil, count: max(1, capacity))
    }

    public init(interval: TimeInterval) {
        self.init(capacity: Int(ceil(300 / max(0.1, interval))))
    }

    public mutating func append(_ value: T) {
        storage[next] = value
        next = (next + 1) % capacity
        count = min(count + 1, capacity)
    }

    public var values: [T] {
        (0..<count).compactMap {
            storage[(next - count + $0 + capacity) % capacity]
        }
    }
}

public struct HistoryPoint: Sendable {
    public var date: Date
    public var value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public enum LoadLevel: Int, Sendable {
    case normal, elevated, high
    public init(percent: Double) {
        self = percent >= 90 ? .high : percent >= 70 ? .elevated : .normal
    }
}

public extension LoadLevel {
    /// Disk warnings enter at 90/95 and recover below 86/92 to avoid flicker.
    static func disk(percent: Double, previous: LoadLevel = .normal) -> LoadLevel {
        switch previous {
        case .normal: return percent >= 95 ? .high : percent >= 90 ? .elevated : .normal
        case .elevated: return percent >= 95 ? .high : percent < 86 ? .normal : .elevated
        case .high: return percent < 86 ? .normal : percent < 92 ? .elevated : .high
        }
    }
}

public struct LoadTracker: Sendable {
    public private(set) var level: LoadLevel = .normal
    private var samples = HistoryBuffer<Double>(capacity: 3)
    public init() {
    }

    @discardableResult public mutating func append(_ percent: Double) -> LoadLevel {
        samples.append(percent)
        let mean = samples.values.reduce(0, +) / Double(samples.count)
        switch level {
        case .normal: level = mean >= 90 ? .high : mean >= 70 ? .elevated : .normal
        case .elevated: level = mean >= 90 ? .high : mean < 62 ? .normal : .elevated
        case .high: level = mean < 62 ? .normal : mean < 84 ? .elevated : .high
        }

        return level
    }
}

public enum FleetFormat {
    /// Menu bar only: bare numbers mean GiB; retain M/T so other units stay clear.
    public static func compactFreeSpace(_ bytes: UInt64) -> String {
        let gibibyte = 1024.0 * 1024 * 1024
        let gibibytes = Double(bytes) / gibibyte
        if gibibytes < 1 { return decimal(Double(bytes) / (1024 * 1024), digits: 0) + "M" }
        if gibibytes < 1024 { return decimal(gibibytes, digits: 0) }
        let tebibytes = gibibytes / 1024
        return decimal(tebibytes, digits: tebibytes < 10 ? 1 : 0) + "T"
    }

    public static func decimal(_ value: Double, digits: Int = 1) -> String {
        guard value.isFinite else {
            return "—"
        }

        return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
    }

    public static func bytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var value = Double(bytes), i = 0
        while value >= 1024 && i < units.count - 1 {
            value /= 1024
            i += 1
        }

        return decimal(value, digits: i >= 3 && value < 100 ? 1 : 0) + " " + units[i]
    }

    /// Use the total's unit for both values so a narrow meter needs only one unit label.
    public static func capacity(used: UInt64, total: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var divisor = 1.0, unit = 0
        while Double(total) / divisor >= 1024 && unit < units.count - 1 {
            divisor *= 1024
            unit += 1
        }
        func number(_ bytes: UInt64) -> String {
            let value = Double(bytes) / divisor
            let result = decimal(value, digits: unit >= 3 && value < 100 ? 1 : 0)
            return result.hasSuffix(".0") ? String(result.dropLast(2)) : result
        }
        return "\(number(used)) / \(number(total)) \(units[unit])"
    }

    public static func trafficTotal(_ counters: NetworkCounters) -> String {
        let sum = counters.rxBytes.addingReportingOverflow(counters.txBytes)
        return bytes(sum.overflow ? .max : sum.partialValue)
    }

    public static func trafficSplit(_ counters: NetworkCounters?) -> String {
        counters.map { "↓ \(bytes($0.rxBytes)) ↑ \(bytes($0.txBytes))" } ?? "—"
    }

    public static func percent(_ value: Double?, digits: Int = 0) -> String {
        value.map { decimal($0, digits: digits) + "%" }
            ?? "—"
    }

    public static func uptime(_ seconds: TimeInterval) -> String {
        let m = Int(max(0, min(seconds.isFinite ? seconds : 0, Double(Int.max / 2))) / 60)
        if m >= 1440 {
            return "\(m / 1440) d \((m % 1440) / 60) h"
        }

        if m >= 60 {
            return "\(m / 60) h \(m % 60) m"
        }

        return "\(m) m"
    }

    public static func ago(_ seconds: TimeInterval) -> String {
        "\(Int(max(0, min(seconds.isFinite ? seconds : 0, 1e9)))) s"
    }

    /// Coarse, human "how long ago": `just now`, `14 min ago`, `2 h 5 min ago`, `3 days ago`.
    public static func relative(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, min(seconds.isFinite ? seconds : 0, 1e9)))
        if s < 60 { return "just now" }
        return duration(Double(s), roundedTo: .minutes) + " ago"
    }

    /// A length of time for people: `40 s`, `16 min`, `1 h 5 min`, `13 h`, `1 day`, `3 days`.
    public static func duration(_ seconds: TimeInterval) -> String {
        duration(seconds, roundedTo: .seconds)
    }

    private enum Precision { case seconds, minutes }

    private static func duration(_ seconds: TimeInterval, roundedTo precision: Precision) -> String {
        let s = Int(max(0, min(seconds.isFinite ? seconds : 0, 1e9)))
        if s < 60 { return precision == .seconds ? "\(s) s" : "1 min" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60
        if h < 24 { return h < 10 && m % 60 > 0 ? "\(h) h \(m % 60) min" : "\(h) h" }
        let d = h / 24
        return d == 1 ? "1 day" : "\(d) days"
    }
}
