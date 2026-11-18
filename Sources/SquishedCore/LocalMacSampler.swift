#if os(macOS)
import Foundation
import Darwin

/// All sample state lives on the utility queue; delivery returns immutable values.
public final class LocalMacSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "me.andrewkim.squished.local", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let interval: Double
    private let receive: @Sendable (HostInfo, HostSnapshot) -> Void
    private var previousNetwork: NetworkCounters?
    private var networkTime: Double?
    private var previousCPU: CPUTicks?
    private var lastGroups: [ProcessGroup] = []
    private var processTicks: [Int32: (ticks: UInt64, start: UInt64)] = [:]
    private struct Metadata { var start: UInt64; var path, name: String; var arguments: [String]; var appName: String? }
    private var metadata: [Int32: Metadata] = [:]
    private var previousTime: TimeInterval?
    private var includesProcesses = false
    private var devices: [SimulatorDevice] = []
    private var deviceSampleTime: TimeInterval = -.infinity
    public func setDevices(_ devices: [SimulatorDevice]) {
        queue.async { [weak self] in
            guard let self, self.devices != devices else { return }
            self.devices = devices
            self.deviceSampleTime = -.infinity
        }
    }
    private var cachedDisk: DiskUsage?
    private var diskSampleTime: TimeInterval = -.infinity
    private var timebase = mach_timebase_info_data_t()
    public init(interval: Double, receive: @escaping @Sendable (HostInfo, HostSnapshot) -> Void) {
        self.interval = interval
        self.receive = receive
        mach_timebase_info(&timebase)
    }

    public func start() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        source.setEventHandler { [weak self] in
            self?.sample()
        }

        timer = source
        source.resume()
    }

    public func setIncludesProcesses(_ enabled: Bool) {
        queue.async { [weak self] in
            self?.includesProcesses = enabled
            if !enabled {
                self?.processTicks.removeAll()
                self?.previousTime = nil
            }
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func integer(_ key: String) -> UInt64 {
        var result: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(key, &result, &size, nil, 0) == 0 else {
            return 0
        }

        return result
    }

    private func string(_ key: String) -> String {
        var size = 0
        sysctlbyname(key, nil, &size, nil, 0)
        guard size > 0 else {
            return ""
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else {
            return ""
        }

        return String(cString: buffer)
    }

    private func sample() {
        let date = Date()
        var cpuInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &cpuInfo) { ptr in

            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        var cpu: CPUUsage?
        if cpuResult == KERN_SUCCESS {
            let t = cpuInfo.cpu_ticks
            let ticks = CPUTicks([UInt64(t.0), UInt64(t.3), UInt64(t.1), UInt64(t.2)])
            cpu = previousCPU.flatMap { CPUUsage.between($0, ticks) }

            previousCPU = ticks
        }

        var vm = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { ptr in

            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }

        var breakdown: MemoryBreakdown?
        var memory: MemoryUsage?
        if vmResult == KERN_SUCCESS {
            let pageSize = UInt64(getpagesize())
            let internalPages = UInt64(vm.internal_page_count), purgeable = UInt64(vm.purgeable_count)
            let usedPages =
                (internalPages > purgeable ? internalPages - purgeable : 0) + UInt64(vm.wire_count)
                + UInt64(vm.compressor_page_count)
            var swap = xsw_usage()
            var size = MemoryLayout<xsw_usage>.size
            sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
            breakdown = MemoryBreakdown.mac(total: integer("hw.memsize"), internalBytes: internalPages * pageSize,
                                            purgeable: purgeable * pageSize, wired: UInt64(vm.wire_count) * pageSize,
                                            compressed: UInt64(vm.compressor_page_count) * pageSize,
                                            external: UInt64(vm.external_page_count) * pageSize,
                                            free: UInt64(vm.free_count) * pageSize, swapUsed: swap.xsu_used)
            let pressure = integer("kern.memorystatus_vm_pressure_level")
            memory = MemoryUsage(
                used: usedPages * pageSize,
                total: integer("hw.memsize"),
                swapUsed: swap.xsu_used,
                swapTotal: swap.xsu_total,
                compressed: UInt64(vm.compressor_page_count) * pageSize,
                pressure: pressure == 0 ? nil : pressure >= 4 ? .critical : pressure >= 2 ? .warning : .normal
            )
        }

        // Finder's purgeable-capacity query invokes CacheDelete services. Disk
        // capacity changes slowly; avoid doing that work every two seconds.
        let monotonicTime = ProcessInfo.processInfo.systemUptime
        if monotonicTime - diskSampleTime >= 30 {
            diskSampleTime = monotonicTime
            if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ]), let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacityForImportantUsage,
                total > 0
            {
                cachedDisk = DiskUsage(used: UInt64(max(0, Int64(total) - available)), total: UInt64(total))
            }
        }

        var averages = [Double](repeating: 0, count: 3)
        let load = getloadavg(&averages, 3) == 3 ? LoadAverage(averages[0], averages[1], averages[2]) : nil
        var boot = timeval()
        var bootSize = MemoryLayout<timeval>.size
        let hasBoot = sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0) == 0
        let uptime = hasBoot ? date.timeIntervalSince1970 - Double(boot.tv_sec) : ProcessInfo.processInfo.systemUptime
        let chip = string("machdep.cpu.brand_string")
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let info = HostInfo(
            osName:
                "macOS \(version.majorVersion).\(version.minorVersion)",
            kernel: string("kern.osrelease"),
            model: chip.isEmpty ? string("hw.model") : chip,
            cpuCount: ProcessInfo.processInfo.processorCount
        )
        let counters = networkCounters()
        let network = previousNetwork.flatMap { old in
            counters.flatMap { current in networkTime.flatMap { NetworkRate.between(old, current, seconds: monotonicTime - $0) } }
        }
        previousNetwork = counters
        networkTime = monotonicTime
        // History still observes devices with the panel closed, without paying
        // for a full process scan on every background resource sample.
        let scanDue = includesProcesses || monotonicTime - deviceSampleTime >= 60
        let processes = scanDue ? scanProcesses(at: monotonicTime) : nil
        if processes != nil { deviceSampleTime = monotonicTime }
        // Light resource samples are not an empty process census. Retain the
        // last known groups so opening the panel does not lose device memory
        // until its first full scan arrives. Freshness still gates history.
        if let processes { lastGroups = ProcessGrouper.group(processes, platform: .macOS, devices: devices) }
        let groups = lastGroups
        var observed = devices.map { device in
            let group = groups.first { $0.deviceID?.caseInsensitiveCompare(device.id) == .orderedSame }
            return SimulatorObservation(id: "sim:" + device.id.uppercased(), name: device.name,
                                        platform: .ios, startedAt: group?.startedAt)
        }
        for group in groups {
            if group.id.hasPrefix("android:") {
                observed.append(SimulatorObservation(id: group.id, name: String(group.id.dropFirst(8)),
                                                     platform: .android, startedAt: group.startedAt,
                                                     cpuPercent: group.cpuPercent, memoryBytes: group.memoryBytes))
            } else if let id = group.deviceID, UUID(uuidString: id) != nil,
                      !observed.contains(where: { $0.id == "sim:" + id.uppercased() }) {
                // A newly booted device can precede its plist refresh. Preserve
                // its presence, then start history once its name is available.
                observed.append(SimulatorObservation(id: "sim:" + id.uppercased(), name: id,
                                                     platform: .ios, startedAt: nil))
            }
        }
        receive(
            info,
            HostSnapshot(
                timestamp: date,
                cpu: cpu,
                memory: memory,
                disks: cachedDisk.map { [$0] } ?? [],
                network: network,
                networkCounters: counters,
                load: load,
                uptime: uptime,
                groups: groups,
                simulatorDevices: observed,
                hasSimulatorSample: processes != nil,
                memoryBreakdown: breakdown
            )
        )
    }

    /// NET_RT_IFLIST2 supplies if_data64, avoiding getifaddrs' 32-bit counters.
    private func networkCounters() -> NetworkCounters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        return withUnsafeTemporaryAllocation(byteCount: size, alignment: MemoryLayout<if_msghdr2>.alignment) { buffer in
            guard sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0) == 0 else { return nil }
            var offset = 0
            var total = NetworkCounters()
            var found = false
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let pointer = buffer.baseAddress!.advanced(by: offset)
                let header = pointer.loadUnaligned(as: if_msghdr.self)
                let length = Int(header.ifm_msglen)
                guard length > 0, offset + length <= size else { break }
                if header.ifm_type == UInt8(RTM_IFINFO2), length >= MemoryLayout<if_msghdr2>.size {
                    let info = pointer.loadUnaligned(as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if info.ifm_flags & IFF_UP != 0, if_indextoname(UInt32(info.ifm_index), &name) != nil,
                       NetworkInterface.includes(String(cString: name)) {
                        total.add(NetworkCounters(rxBytes: info.ifm_data.ifi_ibytes, txBytes: info.ifm_data.ifi_obytes))
                        found = true
                    }
                }
                offset += length
            }
            return found ? total : nil
        }
    }

    private func scanProcesses(at time: TimeInterval) -> [ProcessInput]? {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else {
            return nil
        }

        var pids = [Int32](repeating: 0, count: Int(needed) + 128)
        let bytes = Int32(pids.count * MemoryLayout<Int32>.size)
        let n = proc_listallpids(&pids, bytes)
        guard n > 0, n < pids.count else {
            return nil
        }

        var next: [Int32: (ticks: UInt64, start: UInt64)] = [:], rows: [ProcessInput] = []
        let elapsed =
            previousTime.map { time - $0 }
            ?? 0
        for pid in pids.prefix(min(Int(n), pids.count)) where pid > 0 {
            var task = proc_taskinfo()
            guard
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
                    == Int32(MemoryLayout<proc_taskinfo>.size)
            else {
                continue
            }

            // Start time prevents attributing a recycled PID's CPU ticks to its predecessor.
            var bsd = proc_bsdinfo()
            guard
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
                    == Int32(MemoryLayout<proc_bsdinfo>.size)
            else {
                continue
            }

            let start = bsd.pbi_start_tvsec &* 1_000_000 &+ bsd.pbi_start_tvusec
            let ticks = task.pti_total_user &+ task.pti_total_system
            next[pid] = (ticks, start)
            if metadata[pid]?.start != start {
                var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                let path = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 ? String(cString: pathBuffer) : ""
                var nameBuffer = [CChar](repeating: 0, count: 1024)
                _ = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
                let app = ProcessGrouper.outermostApp(path).flatMap { Bundle(path: $0) }
                let appName = app?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? app?.object(forInfoDictionaryKey: "CFBundleName") as? String
                metadata[pid] = Metadata(start: start, path: path, name: String(cString: nameBuffer), arguments: arguments(pid), appName: appName)
            }
            guard let meta = metadata[pid] else { continue }
            var percent = 0.0
            if elapsed > 0, let old = processTicks[pid], old.start == start, ticks >= old.ticks {
                // pti_total_user/system are Mach absolute time units, not nanoseconds: on
                // Apple Silicon (timebase 125/3) skipping this reads 41x too low. Measured
                // against `ps -o time` on the M1 Pro, 2026-11-07.
                let nanoseconds = Double(ticks - old.ticks) * Double(timebase.numer) / Double(max(1, timebase.denom))
                percent = nanoseconds / 1_000_000_000 / elapsed * 100
            }
            var usage = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &usage) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            rows.append(ProcessInput(pid: pid, ppid: Int32(bsd.pbi_ppid), startTime: start,
                                     executablePath: meta.path, name: meta.name, arguments: meta.arguments,
                                     cpuPercent: percent, memoryBytes: result == 0 ? usage.ri_phys_footprint : 0, appName: meta.appName))
        }

        processTicks = next
        previousTime = time
        metadata = metadata.filter { next[$0.key]?.start == $0.value.start }
        return rows
    }

    private func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return [] }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return [] }
        var offset = MemoryLayout<Int32>.size
        while offset < size && bytes[offset] != 0 { offset += 1 } // executable path
        while offset < size && bytes[offset] == 0 { offset += 1 } // padding
        var result: [String] = []
        for _ in 0..<argc {
            guard offset < size else { break }
            let start = offset
            while offset < size && bytes[offset] != 0 { offset += 1 }
            result.append(String(decoding: bytes[start..<offset], as: UTF8.self))
            offset += 1
        }
        return result
    }

    deinit {
        timer?.cancel()
    }
}

#endif
