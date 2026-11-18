import Foundation

public enum SimulatorPlatform: String, Codable, Sendable { case ios, android }

public struct SimulatorObservation: Sendable, Equatable, Identifiable {
    public var id, name: String
    public var platform: SimulatorPlatform
    public var startedAt: Date?
    public var cpuPercent: Double?
    public var memoryBytes: UInt64?
    public init(id: String, name: String, platform: SimulatorPlatform, startedAt: Date?, cpuPercent: Double? = nil, memoryBytes: UInt64? = nil) {
        self.id = id; self.name = name; self.platform = platform; self.startedAt = startedAt
        self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
    }
}

public struct SimulatorSession: Codable, Sendable, Equatable, Identifiable {
    public var hostID, deviceID, name: String
    public var platform: SimulatorPlatform
    public var start: Date
    public var end: Date?
    public var laneID: String { hostID + "|" + deviceID }
    public var id: String { laneID + "|" + String(start.timeIntervalSince1970) }
}

/// Local event storage. Call only with a complete, fresh device sample; missing
/// telemetry (including a closed-panel light sample) must never end a session.
public final class SimulatorSessionStore {
    public private(set) var sessions: [SimulatorSession]
    private let url: URL
    private var lastSample: [String: Date] = [:]

    public init(url: URL, now: Date = Date()) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            sessions = try decoder.decode([SimulatorSession].self, from: Data(contentsOf: url))
        } else { sessions = [] }
        try prune(at: now)
    }

    @discardableResult public func reconcile(hostID: String, devices: [SimulatorObservation], at date: Date, fresh: Bool) throws -> Bool {
        guard fresh, date >= lastSample[hostID, default: .distantPast] else { return false }
        var updated = sessions
        for index in updated.indices where updated[index].hostID == hostID && updated[index].end == nil {
            guard let device = devices.first(where: { $0.id == updated[index].deviceID }) else {
                updated[index].end = max(updated[index].start, date)
                continue
            }
            if let start = device.startedAt {
                if start > updated[index].start.addingTimeInterval(0.001) {
                    // A restart between polls is still a new session.
                    updated[index].end = max(updated[index].start, min(start, date))
                } else if start < updated[index].start.addingTimeInterval(-0.001) {
                    // A later scan can discover an older member of the same device.
                    updated[index].start = start
                }
            }
        }
        for device in devices {
            guard let start = device.startedAt,
                  !updated.contains(where: { $0.hostID == hostID && $0.deviceID == device.id && $0.end == nil }) else { continue }
            updated.append(SimulatorSession(hostID: hostID, deviceID: device.id, name: device.name,
                                            platform: device.platform, start: start, end: nil))
        }
        let changed = updated != sessions
        if changed { try save(updated) }
        lastSample[hostID] = date
        return changed
    }

    @discardableResult public func prune(at date: Date) throws -> Bool {
        let cutoff = date.addingTimeInterval(-7 * 24 * 60 * 60)
        let kept = sessions.filter { $0.end == nil || $0.end! >= cutoff }
        guard kept != sessions else { return false }
        try save(kept)
        return true
    }

    private func save(_ updated: [SimulatorSession]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(updated)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        sessions = updated
    }
}
