import Foundation

public enum HostKind: Codable, Sendable, Equatable {
    case local, ssh(String)
}

public struct HostConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: HostKind
    public var displayName: String
    public var menuBarLabel: String
    public var enabled: Bool
    public var showInMenuBar: Bool
    public var showFreeSpaceInMenuBar: Bool
    public var refreshInterval: Double?
    public init(
        id: UUID = UUID(),
        kind: HostKind,
        displayName: String,
        menuBarLabel: String,
        enabled: Bool = true,
        showInMenuBar: Bool = true,
        showFreeSpaceInMenuBar: Bool = true,
        refreshInterval: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.menuBarLabel = menuBarLabel
        self.enabled = enabled
        self.showInMenuBar = showInMenuBar
        self.showFreeSpaceInMenuBar = showFreeSpaceInMenuBar
        self.refreshInterval = refreshInterval
    }

    /// Local sampling always follows the global setting. Invalid overrides inherit it too.
    public func effectiveRefreshInterval(global: Double) -> Double {
        guard kind != .local, let interval = refreshInterval,
              interval.isFinite, interval >= 0.1, interval <= 60 else { return global }
        return interval
    }

    private enum CodingKeys: CodingKey {
        case id, kind, displayName, menuBarLabel, enabled, showInMenuBar, showFreeSpaceInMenuBar, refreshInterval
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(HostKind.self, forKey: .kind)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Host"
        menuBarLabel =
            try c.decodeIfPresent(String.self, forKey: .menuBarLabel) ?? String(displayName.uppercased().prefix(4))
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true
        showFreeSpaceInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showFreeSpaceInMenuBar) ?? true
        refreshInterval = try? c.decodeIfPresent(Double.self, forKey: .refreshInterval)
    }
}

/// Raw values retain compatibility with the original panel-density trial.
public enum PanelLayout: String, Codable, CaseIterable, Sendable {
    case extreme, high, medium, current

    public var title: String {
        switch self {
        case .extreme: "Compact"
        case .high: "Dense"
        case .medium: "Medium"
        case .current: "Roomy"
        }
    }
}

public struct FleetSettings: Codable, Sendable, Equatable {
    public var hosts: [HostConfig]
    public var refreshInterval: TimeInterval
    public var showNetworkInMenuBar: Bool
    public var showSimulators: Bool
    public var panelLayout: PanelLayout
    public init(
        hosts: [HostConfig] = [
            HostConfig(kind: .local, displayName: "Mac", menuBarLabel: "MAC")
        ], refreshInterval: TimeInterval = 2, showNetworkInMenuBar: Bool = true,
        showSimulators: Bool = true, panelLayout: PanelLayout = .extreme
    ) {
        self.hosts = hosts
        self.refreshInterval = refreshInterval
        self.showNetworkInMenuBar = showNetworkInMenuBar
        self.showSimulators = showSimulators
        self.panelLayout = panelLayout
    }

    private enum CodingKeys: CodingKey {
        case hosts, refreshInterval, showNetworkInMenuBar, showSimulators, panelLayout
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FleetSettings()
        hosts = (try? c.decode([HostConfig].self, forKey: .hosts)) ?? defaults.hosts
        let interval = (try? c.decode(Double.self, forKey: .refreshInterval)) ?? 2
        refreshInterval = [1.0, 2, 3, 5].contains(interval) ? interval : 2
        showNetworkInMenuBar = (try? c.decode(Bool.self, forKey: .showNetworkInMenuBar)) ?? true
        showSimulators = (try? c.decode(Bool.self, forKey: .showSimulators)) ?? true
        panelLayout = (try? c.decode(PanelLayout.self, forKey: .panelLayout)) ?? .extreme
    }

    public static func load(from defaults: UserDefaults = .standard) -> FleetSettings {
        let data = defaults.data(forKey: "settings")
        var settings = data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        if defaults.object(forKey: "panelDensity") != nil {
            let saved = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            // A saved layout wins, even if its value is unknown to this version.
            if saved?["panelLayout"] == nil,
               let rawValue = defaults.string(forKey: "panelDensity"),
               let layout = PanelLayout(rawValue: rawValue) {
                settings.panelLayout = layout
                // Change only this key in existing JSON: retain unrecognized settings
                // and avoid writing unrelated defaults during a one-time migration.
                let migrated: Data?
                if var saved {
                    saved["panelLayout"] = layout.rawValue
                    migrated = try? JSONSerialization.data(withJSONObject: saved)
                } else {
                    migrated = try? JSONEncoder().encode(settings)
                }
                // Persist before removing the trial key so the choice survives a restart.
                guard let migrated else { return settings }
                defaults.set(migrated, forKey: "settings")
            }
            defaults.removeObject(forKey: "panelDensity")
        }
        return settings
    }
}

public struct CPUUsage: Sendable, Equatable {
    public var total: Double
    public var user: Double
    public var system: Double
    public init(total: Double, user: Double, system: Double) {
        self.total = total
        self.user = user
        self.system = system
    }

    /// nil when any counter went backwards (the host rebooted) or no time passed: the
    /// interval has no meaningful usage, so skip it rather than show a spike or 0%.
    public static func between(_ previous: CPUTicks, _ current: CPUTicks) -> CPUUsage? {
        guard
            zip(previous.values, current.values).allSatisfy({
                $1 >= $0
            }
            )
        else {
            return nil
        }

        let d = zip(previous.values, current.values).map { Double($1 - $0) }

        let total = d.reduce(0, +)
        guard total > 0 else {
            return nil
        }

        let user = d[0] + d[1], system = d[2] + d[5] + d[6] + d[7]
        return CPUUsage(total: (user + system) / total * 100, user: user / total * 100, system: system / total * 100)
    }
}

public struct CPUTicks: Sendable, Equatable {
    public var values: [UInt64]  // user, nice, system, idle, iowait, irq, softirq, steal
    public init(_ values: [UInt64]) {
        self.values = Array((values + Array(repeating: 0, count: 8)).prefix(8))
    }
}

public enum MemoryPressure: String, Codable, Sendable {
    case normal, warning, critical
}

public struct MemoryUsage: Sendable, Equatable {
    public var used, total, swapUsed, swapTotal: UInt64
    public var compressed: UInt64?
    public var pressure: MemoryPressure?
    public var percent: Double {
        total > 0 ? Double(used) / Double(total) * 100 : 0
    }

    public init(
        used: UInt64,
        total: UInt64,
        swapUsed: UInt64 = 0,
        swapTotal: UInt64 = 0,
        compressed: UInt64? = nil,
        pressure: MemoryPressure? = nil
    ) {
        self.used = used
        self.total = total
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal

        self.compressed = compressed
        self.pressure = pressure
    }
}

public struct DiskUsage: Sendable, Equatable {
    private var reportedPercent: Double?
    public var mount: String
    public var used, total: UInt64
    public var percent: Double {
        reportedPercent ?? (total > 0 ? Double(used) / Double(total) * 100 : 0)
    }

    public init(mount: String = "/", used: UInt64, total: UInt64, percent: Double? = nil) {
        self.reportedPercent = percent
        self.mount = mount
        self.used = used
        self.total = total
    }
}

public struct LoadAverage: Sendable, Equatable {
    public var one, five, fifteen: Double
    public init(_ one: Double, _ five: Double, _ fifteen: Double) {
        self.one = one
        self.five = five
        self.fifteen = fifteen
    }
}

public struct ProcessUsage: Sendable, Equatable, Identifiable {
    public var id: Int32 {
        pid
    }

    public var pid: Int32
    public var name: String
    public var cpuPercent: Double
    public var rssBytes: UInt64
    public init(pid: Int32, name: String, cpuPercent: Double, rssBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.rssBytes = rssBytes
    }
}

public struct HostSnapshot: Sendable, Equatable {
    public var timestamp: Date
    public var cpu: CPUUsage?
    public var memory: MemoryUsage?
    public var disks: [DiskUsage]
    /// The busiest partition drives all disk meters and warnings.
    public var disk: DiskUsage? { disks.max { $0.percent < $1.percent } }
    public var network: NetworkRate?
    public var networkCounters: NetworkCounters?
    public var load: LoadAverage?
    public var uptime: TimeInterval?
    public var memoryBreakdown: MemoryBreakdown?
    public var groups: [ProcessGroup]
    public var simulatorDevices: [SimulatorObservation]
    public var hasSimulatorSample: Bool
    public var topProcesses: [ProcessUsage]
    public init(
        timestamp: Date = Date(),
        cpu: CPUUsage? = nil,
        memory: MemoryUsage? = nil,
        disk: DiskUsage? = nil,
        disks: [DiskUsage] = [],
        network: NetworkRate? = nil,
        networkCounters: NetworkCounters? = nil,
        load: LoadAverage? = nil,
        uptime: TimeInterval? = nil,
        topProcesses: [ProcessUsage] = [],
        groups: [ProcessGroup] = [],
        simulatorDevices: [SimulatorObservation] = [],
        hasSimulatorSample: Bool = false,
        memoryBreakdown: MemoryBreakdown? = nil
    ) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.memory = memory
        self.disks = disks.isEmpty ? disk.map { [$0] } ?? [] : disks
        self.network = network
        self.networkCounters = networkCounters
        self.load = load

        self.uptime = uptime
        self.topProcesses = topProcesses
        self.groups = groups
        self.simulatorDevices = simulatorDevices
        self.hasSimulatorSample = hasSimulatorSample
        self.memoryBreakdown = memoryBreakdown
    }
}

public struct HostInfo: Sendable, Equatable {
    public var osName, kernel: String
    public var model: String?
    public var cpuCount: Int
    public init(osName: String, kernel: String, model: String? = nil, cpuCount: Int) {
        self.osName = osName
        self.kernel = kernel
        self.model = model
        self.cpuCount = cpuCount
    }
}

public enum ConnectionState: Sendable, Equatable {
    case connecting, live, stale(since: Date), offline(reason: String, retryAt: Date)
    public var isLive: Bool {
        if case .live = self {
            return true
        }

        return false
    }
}
