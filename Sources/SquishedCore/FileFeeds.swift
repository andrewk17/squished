import Foundation

/// Optional fields are independent: a bad timestamp must not hide a valid job.
private func feedDate(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter.date(from: text)
}

public struct Job: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable { case ok, warning, failed, running }
    public var id, name: String
    public var status: Status
    public var finishedAt: Date?
    public var durationSeconds: Double?
    public var message: String?
    public var expectedEverySeconds: Double?
    public var logPath: String?
    /// When the producer last wrote the job: the `updatedAt` field, else the file's modification time.
    public var updatedAt: Date?

    public func isOverdue(at now: Date) -> Bool {
        guard let expectedEverySeconds else { return false }
        if status == .running, let updatedAt {
            // A run in progress is not late just because the previous one ended long ago.
            // It is late once nothing has been heard for twice the interval, or twice the
            // last run's length when runs take longer than the interval.
            return now.timeIntervalSince(updatedAt) > 2 * max(expectedEverySeconds, durationSeconds ?? 0)
        }
        guard let finishedAt else { return false }
        return now.timeIntervalSince(finishedAt) > 2 * expectedEverySeconds
    }
    public func title(at now: Date) -> String {
        if status == .failed { return "Failed" }
        if isOverdue(at: now) { return "Overdue" }
        switch status {
        case .ok: return "Healthy"
        case .warning: return "Warning"
        case .failed: return "Failed"
        case .running: return "Running"
        }
    }
    public func showsMenuBarWarning(at now: Date) -> Bool { status == .failed || isOverdue(at: now) }

    fileprivate static func read(url: URL) -> Job? {
        guard let object = FeedFile.object(url), let name = object["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rawStatus = object["status"] as? String, let status = Status(rawValue: rawStatus) else { return nil }
        func seconds(_ key: String, positive: Bool = false) -> Double? {
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let number = value.doubleValue
            return number.isFinite && (positive ? number > 0 : number >= 0) ? number : nil
        }
        return Job(id: url.lastPathComponent, name: name, status: status, finishedAt: feedDate(object["finishedAt"]),
                   durationSeconds: seconds("durationSeconds"), message: object["message"] as? String,
                   expectedEverySeconds: seconds("expectedEverySeconds", positive: true), logPath: object["logPath"] as? String,
                   updatedAt: feedDate(object["updatedAt"])
                       ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
    }
}

public struct DeviceLabels: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var id: String?
        public var label: String?
        public var group: String?
        public var since: Date?
        public var detail: String?
        public var colorKey: String { group ?? label?.components(separatedBy: ":").first ?? "" }
        public var tooltip: String {
            [label, detail, since.map { "Since " + $0.formatted(date: .abbreviated, time: .shortened) }]
                .compactMap { $0 }.joined(separator: "\n")
        }
    }
    public struct Note: Sendable, Equatable {
        public var text: String
        public var isWarning: Bool
    }
    public var updatedAt: Date?
    public var unlabeledText: String?
    public var devices: [Entry] = []
    public var notes: [Note] = []
    public init() {}
    public func entry(for id: String) -> Entry? {
        devices.first { entry in
            guard let candidate = entry.id else { return false }
            // UUIDs are case-insensitive; virtual-device names are not.
            return UUID(uuidString: id) != nil ? candidate.caseInsensitiveCompare(id) == .orderedSame : candidate == id
        }
    }
    fileprivate static func read(url: URL) -> DeviceLabels {
        guard let object = FeedFile.object(url) else { return DeviceLabels() }
        var labels = DeviceLabels()
        labels.updatedAt = feedDate(object["updatedAt"])
        labels.unlabeledText = object["unlabeledText"] as? String
        labels.devices = (object["devices"] as? [[String: Any]] ?? []).map {
            Entry(id: $0["id"] as? String, label: $0["label"] as? String, group: $0["group"] as? String,
                  since: feedDate($0["since"]), detail: $0["detail"] as? String)
        }
        labels.notes = (object["notes"] as? [[String: Any]] ?? []).compactMap {
            guard let text = $0["text"] as? String else { return nil }
            return Note(text: text, isWarning: $0["level"] as? String == "warning")
        }
        return labels
    }
}

import CoreFoundation

private enum FeedFile {
    static func object(_ url: URL) -> [String: Any]? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

public struct FileFeeds: Sendable, Equatable {
    public var jobs: [Job] = []
    public var deviceLabels = DeviceLabels()
    public init() {}
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Squished")
    }
    public static func read(root: URL) -> FileFeeds {
        var feeds = FileFeeds()
        let folder = root.appendingPathComponent("jobs")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        feeds.jobs = files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { Job.read(url: $0) }
        feeds.deviceLabels = DeviceLabels.read(url: root.appendingPathComponent("devices.json"))
        return feeds
    }
}
