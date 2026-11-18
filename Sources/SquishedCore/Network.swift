import Foundation

public struct NetworkCounters: Codable, Sendable, Equatable {
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public init(rxBytes: UInt64 = 0, txBytes: UInt64 = 0) {
        self.rxBytes = rxBytes
        self.txBytes = txBytes
    }
    public static func delta(_ previous: Self, _ current: Self) -> Self? {
        guard current.rxBytes >= previous.rxBytes, current.txBytes >= previous.txBytes else { return nil }
        return Self(rxBytes: current.rxBytes - previous.rxBytes, txBytes: current.txBytes - previous.txBytes)
    }
    public mutating func add(_ value: Self) {
        // Saturate rather than overflow if persisted input is corrupt.
        rxBytes = rxBytes.addingReportingOverflow(value.rxBytes).overflow ? .max : rxBytes + value.rxBytes
        txBytes = txBytes.addingReportingOverflow(value.txBytes).overflow ? .max : txBytes + value.txBytes
    }
}

public struct NetworkRate: Sendable, Equatable {
    public var rxPerSecond: Double
    public var txPerSecond: Double
    public init(rxPerSecond: Double, txPerSecond: Double) {
        self.rxPerSecond = rxPerSecond
        self.txPerSecond = txPerSecond
    }
    public static func between(_ previous: NetworkCounters, _ current: NetworkCounters, seconds: Double) -> Self? {
        guard seconds.isFinite, seconds > 0, let delta = NetworkCounters.delta(previous, current) else { return nil }
        return Self(rxPerSecond: Double(delta.rxBytes) / seconds, txPerSecond: Double(delta.txBytes) / seconds)
    }
}

public enum NetworkInterface {
    public static func includes(_ name: String) -> Bool {
        !name.isEmpty && !["lo", "docker", "veth", "br-", "virbr", "vnet", "tun", "tap", "wg", "zt",
                          "utun", "awdl", "llw", "bridge", "ap", "gif", "stf", "anpi", "ipsec"].contains {
            name.hasPrefix($0)
        }
    }
}

extension LinuxParser {
    public static func networkInterfaces(_ text: String) -> [String: NetworkCounters] {
        var result: [String: NetworkCounters] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let fields = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace)
            guard NetworkInterface.includes(name), fields.count >= 16,
                  let rx = UInt64(fields[0]), let tx = UInt64(fields[8]) else { continue }
            result[name] = NetworkCounters(rxBytes: rx, txBytes: tx)
        }
        return result
    }
    public static func network(_ text: String) -> NetworkCounters? {
        let interfaces = networkInterfaces(text)
        guard !interfaces.isEmpty else { return nil }
        return interfaces.values.reduce(into: NetworkCounters()) { $0.add($1) }
    }
}

/// Only current day/month totals are persisted. Baselines deliberately are not:
/// restarting the app must never count traffic while it was not running.
public struct TrafficLedger: Codable, Sendable {
    public struct Bucket: Codable, Sendable, Equatable {
        public var day: Date
        public var month: Date
        public var today = NetworkCounters()
        public var monthly = NetworkCounters()
    }
    public private(set) var buckets: [String: Bucket] = [:]
    private var previous: [String: NetworkCounters] = [:]
    // Only the totals are saved. The last raw counters are not, so after a relaunch (or
    // resetBaseline) the first reading only sets a new baseline and adds nothing: the
    // host's counters may have reset or jumped while we weren't watching.
    private enum CodingKeys: CodingKey { case buckets }
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        buckets = try c.decode([String: Bucket].self, forKey: .buckets)
    }
    public mutating func resetBaseline(host: String) { previous[host] = nil }
    public mutating func rollOver(now: Date, calendar: Calendar = .current) {
        for host in Array(buckets.keys) { prepare(host: host, now: now, calendar: calendar) }
    }
    private mutating func prepare(host: String, now: Date, calendar: Calendar) {
        // Calendar days in the user's time zone, so a 23- or 25-hour DST day still rolls
        // over at local midnight.
        let day = calendar.startOfDay(for: now)
        let month = calendar.dateInterval(of: .month, for: now)!.start
        var bucket = buckets[host] ?? Bucket(day: day, month: month)
        if bucket.day != day { bucket.day = day; bucket.today = NetworkCounters() }
        if bucket.month != month { bucket.month = month; bucket.monthly = NetworkCounters() }
        buckets[host] = bucket
    }
    public mutating func record(host: String, counters: NetworkCounters, now: Date, calendar: Calendar = .current) {
        prepare(host: host, now: now, calendar: calendar)
        if let old = previous[host], let delta = NetworkCounters.delta(old, counters) {
            buckets[host]!.today.add(delta)
            buckets[host]!.monthly.add(delta)
        }
        previous[host] = counters
    }
}

extension FleetFormat {
    public static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return bytes(UInt64(min(value, Double(UInt64.max / 2)))) + "/s"
    }
    public static func compactRate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let units = ["B", "K", "M", "G"]
        var n = value, i = 0
        while n >= 999.5 && i < units.count - 1 { n /= 1024; i += 1 }
        return decimal(min(n, 999), digits: i > 0 && n < 9.95 ? 1 : 0) + units[i]
    }
}
