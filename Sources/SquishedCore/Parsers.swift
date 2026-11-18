import Foundation

public enum LinuxParser {
    public static func cpu(_ text: String) -> CPUTicks? {
        guard
            let line = text.split(separator: "\n").first(where: {
                $0.split(whereSeparator: \.isWhitespace).first == "cpu"
            }
            )
        else {
            return nil
        }

        let fields = line.split(whereSeparator: \.isWhitespace).dropFirst()
        guard fields.count >= 4 else {
            return nil
        }

        // Only the first 8 columns (user … steal) count. Older kernels have 4; guest and
        // guest_nice are already inside user/nice, so adding them would count them twice.
        let values = fields.prefix(8).compactMap {
            UInt64($0)
        }

        guard values.count == min(8, fields.count) else {
            return nil
        }

        return CPUTicks(values)
    }

    public static func memory(_ text: String, psi: String? = nil) -> MemoryUsage? {
        var fields: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let p = line.split(whereSeparator: \.isWhitespace)
            if p.count >= 2, let n = UInt64(p[1]), n <= UInt64.max / 1024 {
                fields[String(p[0].dropLast())] = n * 1024
            }
        }

        guard let total = fields["MemTotal"], total > 0 else {
            return nil
        }

        let fallback =
            Double(fields["MemFree", default: 0]) + Double(fields["Buffers", default: 0])
            + Double(fields["Cached", default: 0]) + Double(fields["SReclaimable", default: 0])
            - Double(fields["Shmem", default: 0])
        let available = min(total, fields["MemAvailable"] ?? UInt64(max(0, min(Double(total), fallback))))
        let swapTotal = fields["SwapTotal", default: 0], swapFree = min(swapTotal, fields["SwapFree", default: 0])
        let pressure: MemoryPressure?
        if let avg = psi.flatMap(psiAverage) {
            pressure = avg < 10 ? .normal : avg < 30 ? .warning : .critical
        } else {
            // No PSI (older kernels, e.g. Synology 4.4): judge by what's left, not by the percent used.
            let fraction = Double(available) / Double(total)
            pressure = fraction < 0.05 ? .critical : fraction < 0.1 ? .warning : .normal
        }

        return MemoryUsage(
            used: total - available,
            total: total,
            swapUsed: swapTotal - swapFree,
            swapTotal: swapTotal,
            pressure: pressure
        )
    }

    public static func psiAverage(_ text: String) -> Double? {
        for line in text.split(separator: "\n") where line.hasPrefix("some ") {
            if let field = line.split(separator: " ").first(where: {
                $0.hasPrefix("avg10=")
            }
            ) {
                return Double(field.dropFirst(6))
            }
        }

        return nil
    }

    public static func load(_ text: String) -> LoadAverage? {
        let p = text.split(whereSeparator: \.isWhitespace).prefix(3).compactMap {
            Double($0)
        }

        guard p.count == 3,
            p.allSatisfy({
                $0.isFinite && $0 >= 0
            }
            )
        else {
            return nil
        }

        return LoadAverage(p[0], p[1], p[2])
    }

    public static func uptime(_ text: String) -> TimeInterval? {
        guard let first = text.split(whereSeparator: \.isWhitespace).first, let n = Double(first), n.isFinite, n >= 0
        else {
            return nil
        }

        return n
    }

    /// Device-backed partitions, with subvolumes and bind mounts counted once.
    public static func disks(_ text: String) -> [DiskUsage] {
        var devices: [String: DiskUsage] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            // Accept ordinary df -Pk and captured df -PkT output (with a type column).
            let offset = fields.count == 7 ? 1 : 0
            guard fields.count == 6 + offset, fields[0].hasPrefix("/dev/"),
                  !fields[0].hasPrefix("/dev/loop"),
                  let used = UInt64(fields[2 + offset]), let available = UInt64(fields[3 + offset]),
                  available <= UInt64.max / 1024, used <= UInt64.max / 1024 - available,
                  used + available > 0,
                  fields[4 + offset].hasSuffix("%"),
                  let percent = Double(fields[4 + offset].dropLast()), percent.isFinite, percent >= 0
            else { continue }
            let mount = String(fields[5 + offset])
            guard mount.hasPrefix("/"), !["/boot", "/snap", "/var/lib/docker", "/run"].contains(where: {
                mount == $0 || mount.hasPrefix($0 + "/")
            }) else { continue }
            // df rounds Capacity upward; preserve it so the display matches df.
            let usage = DiskUsage(mount: mount, used: used * 1024, total: (used + available) * 1024, percent: percent)
            let source = String(fields[0])
            if let previous = devices[source],
               previous.mount.count < mount.count || (previous.mount.count == mount.count && previous.mount <= mount) {
                continue
            }
            devices[source] = usage
        }
        let minimum: UInt64 = 4 * 1024 * 1024 * 1024
        let hasLargePartition = devices.values.contains { $0.total >= minimum }
        return Array(devices.values.filter { !hasLargePartition || $0.total >= minimum }.sorted {
            if $0.mount == "/" { return $1.mount != "/" }
            if $1.mount == "/" { return false }
            return $0.mount < $1.mount
        }.prefix(6))
    }

    public static func disk(_ text: String) -> DiskUsage? {
        disks(text).max { $0.percent < $1.percent }
    }

    public static func processes(_ text: String) -> [ProcessUsage] {
        text.split(separator: "\n").compactMap { line in

            let f = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard f.count == 4, let pid = Int32(f[0]), let permille = Double(f[1]), permille.isFinite, permille >= 0,
                let rss = UInt64(f[2]), rss <= UInt64.max / 1024
            else {
                return nil
            }

            return ProcessUsage(pid: pid, name: String(f[3]), cpuPercent: permille / 10, rssBytes: rss * 1024)
        }
    }

    public static func info(_ text: String) -> HostInfo? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)

            if f.count == 2 {
                fields[String(f[0])] = String(f[1])
            }
        }

        guard let os = fields["os"] else {
            return nil
        }

        return HostInfo(
            osName: os,
            kernel: fields["kernel", default: ""],
            model: fields["pretty"],
            cpuCount: Int(fields["cpus", default: "0"]) ?? 0
        )
    }
}

public struct SamplerFrame: Sendable, Equatable {
    public var sequence: UInt64
    public var sections: [String: String]
    public var info: HostInfo? {
        sections["info"].flatMap(LinuxParser.info)
    }

    public func snapshot(previousCPU: CPUTicks?, previousNetwork: NetworkCounters? = nil, previousUptime: Double? = nil, at date: Date = Date()) -> HostSnapshot {
        let ticks = sections["cpu"].flatMap(LinuxParser.cpu)
        let counters = sections["net"].flatMap(LinuxParser.network)
        let uptime = sections["uptime"].flatMap(LinuxParser.uptime)
        let rate = previousNetwork.flatMap { old in
            counters.flatMap { current in
                previousUptime.flatMap { before in uptime.flatMap { NetworkRate.between(old, current, seconds: $0 - before) } }
            }
        }
        return HostSnapshot(
            timestamp: date,
            cpu: previousCPU.flatMap { p in

                ticks.flatMap { CPUUsage.between(p, $0) }
            },
            memory: sections["mem"].flatMap { LinuxParser.memory($0, psi: sections["psi"]) },
            disks: LinuxParser.disks(sections["df", default: ""]),
            network: rate,
            networkCounters: counters,
            load: sections["load"].flatMap(LinuxParser.load),
            uptime: sections["uptime"].flatMap(LinuxParser.uptime),
            topProcesses: LinuxParser.processes(sections["procs", default: ""]),
            groups: sections["groups"].map { LinuxParser.groups($0, members: sections["members", default: ""]) } ?? ProcessGrouper.group(LinuxParser.processes(sections["procs", default: ""]).map { ProcessInput(pid: $0.pid, name: $0.name, cpuPercent: $0.cpuPercent, memoryBytes: $0.rssBytes) }, platform: .linux),
            simulatorDevices: LinuxParser.simulatorDevices(sections["devices", default: ""]),
            hasSimulatorSample: sections["devices", default: ""].split(separator: "\n").contains("complete"),
            memoryBreakdown: sections["mem"].flatMap(MemoryBreakdown.linux)
        )
    }
}

/// Line-oriented framing keeps UTF-8 intact across arbitrary byte boundaries.
public struct FrameDecoder: Sendable {
    private var pending = Data()
    private var sequence: UInt64?
    private var sections: [String: String] = [:]
    private var section: String?
    private var frameSize = 0
    public let limit: Int
    public init(limit: Int = 256 * 1024) {
        self.limit = max(128, limit)
    }

    public mutating func append(_ data: Data) -> [SamplerFrame] {
        var result: [SamplerFrame] = []
        // Bound memory even when an attacker sends a huge chunk without a newline.
        for byte in data {
            if byte == 10 {
                let line = String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .init(charactersIn: "\r"))
                pending.removeAll(keepingCapacity: true)
                if line.hasPrefix("@@FLEET 1 "), let seq = UInt64(line.dropFirst(10)) {
                    sequence = seq
                    sections = [:]
                    section = nil
                    frameSize = 0
                } else if line.hasPrefix("@@END ") {
                    if let sequence, UInt64(line.dropFirst(6)) == sequence {
                        result.append(SamplerFrame(sequence: sequence, sections: sections))
                    }

                    reset()
                } else if sequence != nil {
                    frameSize += line.utf8.count + 1
                    if frameSize > limit {
                        reset()
                    } else if line.hasPrefix("#") {
                        section = String(line.dropFirst())
                        sections[section!] = ""
                    } else if let section {
                        sections[section, default: ""] += line + "\n"
                    }
                }
            } else {
                pending.append(byte)
                if pending.count > limit {
                    pending.removeAll(keepingCapacity: true)
                    reset()
                }
            }
        }

        return result
    }

    private mutating func reset() {
        sequence = nil
        sections = [:]
        section = nil
        frameSize = 0
    }
}

public extension LinuxParser {
    static func simulatorDevices(_ text: String) -> [SimulatorObservation] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard fields.count == 4, let seconds = UInt64(fields[0]),
                  let cpu = Double(fields[1]), cpu.isFinite, cpu >= 0,
                  let rss = UInt64(fields[2]), rss <= UInt64.max / 1024 else { return nil }
            let name = String(fields[3])
            return SimulatorObservation(id: "android:" + name, name: name, platform: .android,
                                        startedAt: seconds > 0 ? Date(timeIntervalSince1970: Double(seconds)) : nil,
                                        cpuPercent: cpu / 10, memoryBytes: rss * 1024)
        }
    }

    static func groups(_ text: String, members: String = "") -> [ProcessGroup] {
        let rows: [(ProcessInput, Int)] = text.split(separator: "\n").compactMap { line in
            let f = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
            guard f.count == 5, let cpu = Double(f[0]), cpu.isFinite, cpu >= 0,
                  let rss = UInt64(f[1]), rss <= UInt64.max / 1024, let count = Int(f[2]), count > 0,
                  ["p", "i", "e"].contains(f[3]) else { return nil }
            var key = String(f[4])
            var startTime: UInt64 = 0
            if f[3] == "e", let tab = key.firstIndex(of: "\t") {
                if let epoch = UInt64(key[..<tab]), epoch > 0, epoch <= UInt64.max / 1_000_000 {
                    startTime = epoch * 1_000_000
                }
                key = String(key[key.index(after: tab)...])
            }
            var p = ProcessInput(pid: 0, startTime: startTime, name: key, cpuPercent: cpu / 10, memoryBytes: rss * 1024)
            if f[3] == "i", let colon = key.firstIndex(of: ":") {
                p.name = String(key[..<colon]); p.arguments = [p.name, String(key[key.index(after: colon)...])]
            } else if f[3] == "e" { p.name = "emulator"; p.arguments = ["emulator", "-avd", key] }
            return (p, count)
        }
        var merged: [String: ProcessGroup] = [:]
        for (p, count) in rows {
            guard var g = ProcessGrouper.group([p], platform: .linux).first else { continue }
            g.processCount = count; g.processes = []
            g.subtitle = g.subtitle.replacingOccurrences(of: "1 processes", with: "\(count) processes")
            if var old = merged[g.id] { old.cpuPercent += g.cpuPercent; old.memoryBytes &+= g.memoryBytes; old.processCount += count; merged[g.id] = old }
            else { merged[g.id] = g }
        }
        for member in Self.members(members) {
            let source = member.kind + " " + member.key
            // Resolve exactly as #groups, including catalogue aliases which merge.
            let synthetic = "0 0 1 " + source
            if let id = Self.groups(synthetic).first?.id, merged[id] != nil {
                merged[id]?.processes.append(member.process)
            }
        }
        return merged.values.sorted { $0.cpuPercent == $1.cpuPercent ? $0.id < $1.id : $0.cpuPercent > $1.cpuPercent }
    }
}

public struct RemoteProcessMember: Sendable, Equatable {
    public var kind, key: String
    public var process: ProcessInput
}
public extension LinuxParser {
    /// Tab separates the composite group key from a conventional process row;
    /// names and plain group keys may contain spaces.
    static func members(_ text: String) -> [RemoteProcessMember] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { return nil }
            let group = fields[0].split(maxSplits: 1, whereSeparator: \.isWhitespace)
            let p = fields[1].split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard group.count == 2, ["p", "i", "e"].contains(group[0]), p.count == 4,
                  let pid = Int32(p[0]), pid > 0, let cpu = Double(p[1]), cpu.isFinite, cpu >= 0,
                  let rss = UInt64(p[2]), rss <= UInt64.max / 1024 else { return nil }
            let key = String(group[1]), kind = String(group[0])
            var process = ProcessInput(pid: pid, name: String(p[3]), cpuPercent: cpu / 10, memoryBytes: rss * 1024)
            if kind == "i", let colon = key.firstIndex(of: ":") {
                process.arguments = [String(key[..<colon]), String(key[key.index(after: colon)...])]
            }
            return RemoteProcessMember(kind: kind, key: key, process: process)
        }
    }
}
