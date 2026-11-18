import AppKit
import IOKit
import SwiftUI
import SquishedCore

/// Read settings inside the observed SwiftUI tree, so an open popover updates live.
struct HostedPanelView: View {
    @Bindable var store: FleetStore
    let settings: () -> Void
    let maximumHeight: CGFloat

    var body: some View {
        PanelView(store: store, settings: settings, maximumHeight: maximumHeight)
            .environment(\.panelDensity, store.settings.panelLayout)
    }
}

struct PanelView: View {
    @Bindable var store: FleetStore
    let settings: () -> Void
    let maximumHeight: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.panelDensity) private var density
    @Environment(\.renderingPanel) private var rendering
    private var quietJobs: Bool {
        density == .extreme && !store.feeds.jobs.isEmpty
            && store.feeds.jobs.allSatisfy { $0.status == .ok && !$0.isOverdue(at: store.now) }
    }
    var body: some View {
        Group {
            if rendering { content.fixedSize(horizontal: false, vertical: true) }
            else { fittedContent }
        }.frame(width: 340).background {
            if !rendering { PanelSurface() }
        }
    }

    private var fittedContent: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView {
                content
            }
        }.frame(width: 340).frame(maxHeight: maximumHeight)
    }

    private var content: some View {
        VStack(spacing: 8) {
            if quietJobs {
                ForEach(store.feeds.jobs) { job in
                    CompactJobSection(job: job, now: store.now, summaryOnly: true)
                }
            }
            if density == .current { HStack {
                Text("Squished").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(store.hosts.filter { $0.state.isLive }.count) of \(store.hosts.count) online").font(
                    .system(size: 10.5)
                ).foregroundStyle(.secondary).monospacedDigit()
            } } else if store.hosts.contains(where: { !$0.state.isLive }) {
                Text("\(store.hosts.filter { !$0.state.isLive }.count) of \(store.hosts.count) offline")
                    .font(Theme.fine).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .help("\(store.hosts.filter { $0.state.isLive }.count) of \(store.hosts.count) online; other hosts may be connecting, stale or offline")
            }

            if !quietJobs {
                ForEach(store.feeds.jobs) { job in
                    if density == .current { JobSection(job: job, now: store.now) }
                    else { CompactJobSection(job: job, now: store.now) }
                }
            }
            if store.settings.showSimulators { SimulatorsSection(store: store) }
            VStack(spacing: 0) {
                ForEach(Array(store.hosts.enumerated()), id: \.element.id) { index, model in
                    if index > 0 { Theme.border(scheme, contrast: contrast).frame(height: 0.5) }
                    HostCard(model: model, now: store.now, retry: { store.retry(model.id) })
                }
            }.background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.border(scheme, contrast: contrast), lineWidth: 0.7) }

            PanelFooter(hosts: store.hosts.map(\.config), settings: settings)
        }.padding(density.panelPadding).frame(width: 340)
            .help("Squished · \(store.hosts.filter { $0.state.isLive }.count) of \(store.hosts.count) online")
    }
}

struct HostCard: View {
    @Bindable var model: HostModel
    let now: Date
    let retry: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var stale: Bool {
        if case .stale = model.state {
            return true
        }

        return false
    }

    private var local: Bool {
        model.config.kind == .local
    }

    private static let hasBattery: Bool = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else {
            return false
        }

        IOObjectRelease(service)
        return true
    }()
    private var symbol: String {
        local ? (Self.hasBattery ? "laptopcomputer" : "desktopcomputer") : "server.rack"
    }

    @Environment(\.panelDensity) private var density
    var body: some View {
        if density == .current { originalBody }
        else { CompactHostCard(model: model, now: now, symbol: symbol, retry: retry) }
    }

    private var originalBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: symbol).font(.system(size: 14)).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.config.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let info = model.info {
                        Text("\(info.osName) · \(info.model ?? info.kernel) · \(info.cpuCount) cores").font(
                            .system(size: 10.5)
                        ).foregroundStyle(.secondary).lineLimit(2).monospacedDigit()
                    }
                }

                Spacer(minLength: 0)
                StatePill(state: model.state, now: now).fixedSize()
            }

            switch model.state {
            case .offline(let reason, let retryAt):
                MeterRow(model: model, available: false)
                OfflineBody(reason: reason, retryAt: retryAt, now: now, history: model.cpuHistory.values, retry: retry)
            case .connecting:
                MeterSkeleton().accessibilityLabel("Waiting for first sample")
            case .live, .stale:
                metrics.opacity(stale ? 0.55 : 1)
            }
        }.padding(.horizontal, 10).padding(.vertical, 9)
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            MeterRow(model: model)
            HistoryChart(points: model.cpuHistory.values, now: model.snapshot?.timestamp ?? now, label: "CPU")
            HistoryChart(points: model.memoryHistory.values, now: model.snapshot?.timestamp ?? now, label: "MEM")
            if let disks = model.snapshot?.disks, disks.count > 1 {
                PartitionsList(disks: disks)
            }
            TopProcessesSection(model: model, local: local)
            HStack {
                Label("up \(model.snapshot?.uptime.map(FleetFormat.uptime) ?? "—")", systemImage: "clock").font(
                    Theme.fine
                ).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button {
                    TerminalLauncher.open(model.config)
                } label: {
                    Label("btop", systemImage: "terminal")
                }.font(Theme.fine).modifier(PanelBorderless()).modifier(HoverFill())
            }

            if let snapshot = model.snapshot {
                Text("updated \(FleetFormat.ago(now.timeIntervalSince(snapshot.timestamp))) ago").font(Theme.fine)
                    .foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }
}

struct MeterRow: View {
    @Bindable var model: HostModel
    var available = true
    private var snapshot: HostSnapshot? { available ? model.snapshot : nil }
    private var traffic: TrafficLedger.Bucket? { available ? model.traffic : nil }

    @Environment(\.panelDensity) private var density
    var body: some View {
        if density == .extreme {
            ExtremeMeterRow(model: model, snapshot: snapshot, cpuHelp: cpuHelp, memoryHelp: memoryHelp, diskHelp: diskHelp)
        } else { standardMeters }
    }
    private var standardMeters: some View {
        HStack(alignment: .top, spacing: 6) {
            MeterColumn(title: "CPU", value: snapshot?.cpu?.total, level: model.cpuLevel.level,
                        detail: snapshot?.load.map { "load \(FleetFormat.decimal($0.one, digits: 2))" } ?? "—",
                        usesCPUWarning: true)
                .help(cpuHelp)
            MeterColumn(title: "MEM", value: snapshot?.memory?.percent, level: model.memoryLevel,
                        detail: snapshot?.memory.map { FleetFormat.capacity(used: $0.used, total: $0.total) } ?? "—",
                        detailMinimumScale: (snapshot?.disks.count ?? 0) > 1 ? 0.7 : 1,
                        pressure: snapshot?.memory?.pressure)
                .help(memoryHelp)
            if let disks = snapshot?.disks, disks.count > 1 {
                let shown = Array(disks.prefix(3))
                PartitionMeterColumn(disks: shown, levels: shown.map { model.diskLevel(for: $0) },
                                     detail: snapshot?.disk.map { FleetFormat.capacity(used: $0.used, total: $0.total) } ?? "—")
                    .help(diskHelp)
            } else {
                MeterColumn(title: "DISK", value: snapshot?.disk?.percent, level: model.diskLevel,
                            detail: snapshot?.disk.map { FleetFormat.capacity(used: $0.used, total: $0.total) } ?? "—")
                    .help(diskHelp)
            }
            VStack(alignment: .leading, spacing: 5) {
                SectionCaption(title: "NET")
                VStack(alignment: .leading, spacing: density == .high ? 0 : 4) {
                    rate("↑", snapshot?.network?.txPerSecond)
                    rate("↓", snapshot?.network?.rxPerSecond)
                }.frame(height: density.tubeHeight, alignment: .top)
                Text(traffic.map { "today \(FleetFormat.trafficTotal($0.today))" } ?? "—")
                    .font(Theme.fine).foregroundStyle(.secondary).lineLimit(1)
            }.monospacedDigit().frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .help(networkHelp)
        }
    }

    private func rate(_ arrow: String, _ value: Double?) -> some View {
        (Text(arrow).foregroundColor(.secondary) + Text(" " + FleetFormat.rate(value)))
            .font(.system(size: density == .high ? 10.5 : 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
    }

    private var cpuHelp: String {
        let usage = "User \(FleetFormat.percent(snapshot?.cpu?.user)) · system \(FleetFormat.percent(snapshot?.cpu?.system))"
        guard let load = snapshot?.load else { return usage + "\nLoad averages: —" }
        return usage + "\nLoad averages (1 / 5 / 15 min): "
            + [load.one, load.five, load.fifteen].map { FleetFormat.decimal($0, digits: 2) }.joined(separator: " / ")
    }

    private var memoryHelp: String {
        guard let memory = snapshot?.memory else { return "Memory: —" }
        return "Used \(FleetFormat.bytes(memory.used)) of \(FleetFormat.bytes(memory.total))"
            + "\nSwap \(FleetFormat.bytes(memory.swapUsed)) of \(FleetFormat.bytes(memory.swapTotal))"
            + (memory.compressed.map { "\nCompressed \(FleetFormat.bytes($0))" } ?? "")
            + "\nPressure: \(memory.pressure?.rawValue.capitalized ?? "Unavailable")"
    }

    private var diskHelp: String {
        guard let disk = snapshot?.disk else { return "Disk: —" }
        let partitions = (snapshot?.disks.count ?? 0) > 1
            ? "\nPartitions:\n" + (snapshot?.disks ?? []).map {
                "\($0.mount): \(FleetFormat.capacity(used: $0.used, total: $0.total)) · \(FleetFormat.percent($0.percent)) · \(FleetFormat.bytes($0.total > $0.used ? $0.total - $0.used : 0)) free"
            }.joined(separator: "\n") : ""
        return "Mount: \(disk.mount)\nUsed \(FleetFormat.bytes(disk.used)) of \(FleetFormat.bytes(disk.total))"
            + "\nFree \(FleetFormat.bytes(disk.total > disk.used ? disk.total - disk.used : 0))" + partitions
    }

    private var networkHelp: String {
        "Today: \(FleetFormat.trafficSplit(traffic?.today))"
            + "\nThis month: \(FleetFormat.trafficSplit(traffic?.monthly))"
            + "\nCounted while Squished is running"
    }
}

struct PartitionsList: View {
    let disks: [DiskUsage]
    @State private var levels: [String: LoadLevel] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Partitions").foregroundStyle(.secondary)
            ForEach(disks, id: \.mount) { disk in
                HStack(spacing: 6) {
                    Text(disk.mount).lineLimit(1).truncationMode(.middle)
                        .frame(width: 72, alignment: .leading).help(disk.mount)
                    UsageBar(value: disk.percent, level: levels[disk.mount] ?? .disk(percent: disk.percent))
                        .frame(minWidth: 24)
                    Text(FleetFormat.capacity(used: disk.used, total: disk.total)).fixedSize()
                    Text(FleetFormat.percent(disk.percent)).frame(width: 28, alignment: .trailing)
                }.accessibilityElement(children: .combine)
            }
        }.font(Theme.fine).monospacedDigit()
            .onChange(of: disks, initial: true) { _, current in
                levels = Dictionary(uniqueKeysWithValues: current.map {
                    ($0.mount, LoadLevel.disk(percent: $0.percent, previous: levels[$0.mount] ?? .normal))
                })
            }
    }
}

/// A 5-minute sparkline with its caption. CPU uses the accent colour, memory the
/// memory tint, so the two rows can't be mistaken for each other.
private struct HistoryChart: View {
    let points: [HistoryPoint]
    let now: Date
    let label: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Sparkline(
                points: points,
                now: now,
                color: label == "MEM" ? Theme.memory(scheme) : .accentColor,
                label: label == "MEM" ? "Memory" : label
            )
            // Both captions share one width so the two charts line up.
            // Sized to the wider of the two captions, so both charts end at the same x.
            ZStack(alignment: .leading) {
                Text("CPU · 5 min").hidden()
                Text("MEM · 5 min").hidden()
                Text("\(label) · 5 min")
            }.font(Theme.fine).foregroundStyle(.secondary).fixedSize()
        }
    }
}

private struct TopProcessesSection: View {
    @Bindable var model: HostModel
    let local: Bool
    private var sortedGroups: [ProcessGroup] {
        (model.snapshot?.groups ?? []).sorted {
            let a = model.groupMemory ? Double($0.memoryBytes) : $0.cpuPercent
            let b = model.groupMemory ? Double($1.memoryBytes) : $1.cpuPercent
            return a == b ? $0.id < $1.id : a > b
        }
    }
    private var groups: [ProcessGroup] { Array(sortedGroups.prefix(model.showAllGroups ? 15 : 5)) }
    private var rows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(groups) { group in
                Button { model.expandedGroup = model.expandedGroup == group.id ? nil : group.id } label: {
                    ProcessGroupRow(group: group, memory: model.groupMemory,
                                    totalMemory: model.snapshot?.memory?.total ?? 0, cores: model.info?.cpuCount ?? 1, remote: !local).equatable()
                }.buttonStyle(.plain)
                if model.expandedGroup == group.id {
                    ExpandedProcessGroup(group: group, memory: model.groupMemory, remote: !local)
                }
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button { model.expanded.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                        SectionCaption(title: "USING THE MOST")
                    }
                }.buttonStyle(.plain).modifier(HoverFill())
                    .help("100 % = one core · this \(local ? "Mac" : "host") has \(model.info?.cpuCount ?? 0)")
                Spacer(minLength: 0)
                ProcessResourcePicker(memory: $model.groupMemory)
            }
            if model.expanded {
                if model.groupMemory, let breakdown = model.snapshot?.memoryBreakdown {
                    MemoryBreakdownView(breakdown: breakdown)
                }
                if model.showAllGroups { ScrollView { rows }.frame(maxHeight: 260) }
                else { rows }
                if sortedGroups.count > 5 {
                    Button(model.showAllGroups ? "Show less" : "Show all (\(sortedGroups.count))") { model.showAllGroups.toggle() }
                        .modifier(PanelBorderless()).font(Theme.fine)
                }
                if groups.isEmpty { Text("Waiting for process sample").font(Theme.fine).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct SimulatorsSection: View {
    @Bindable var store: FleetStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    private func android(_ host: HostModel) -> [SimulatorObservation] {
        guard let snapshot = host.snapshot else { return [] }
        let observed = snapshot.simulatorDevices.filter { $0.platform == .android }
        if snapshot.hasSimulatorSample || !observed.isEmpty { return observed.sorted { $0.name < $1.name } }
        return snapshot.groups.filter { $0.id.hasPrefix("android:") }.map {
            SimulatorObservation(id: $0.id, name: String($0.id.dropFirst(8)), platform: .android, startedAt: $0.startedAt)
        }
    }
    private var hasHistory: Bool {
        store.simulatorSessions.contains { $0.start <= store.now && ($0.end ?? store.now) > store.now.addingTimeInterval(-12 * 60 * 60) }
    }
    private var hasRunningDevices: Bool {
        !store.simulators.devices.isEmpty || store.hosts.contains { !android($0).isEmpty }
    }
    private var machines: [HostModel] {
        store.hosts.filter { host in
            !android(host).isEmpty || (host.config.kind == .local
                && (!store.simulators.devices.isEmpty || !store.feeds.deviceLabels.notes.isEmpty))
        }
    }
    private func resourceText(cpu: Double?, memory: UInt64?) -> String? {
        guard let memory else { return nil }
        let cpuText = cpu.flatMap { $0 >= 25 ? FleetFormat.percent($0, digits: 0) + " · " : nil } ?? ""
        return cpuText + FleetFormat.bytes(memory)
    }
    private func holderColor(_ key: String) -> Color {
        // Swift's Hasher changes every launch; FNV-1a keeps each group's colour stable.
        let hash = key.lowercased().utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let palette: [Color] = [.purple, .indigo, .teal, .pink, .cyan, .brown]
        return palette[Int(hash % UInt64(palette.count))]
    }
    private func deviceRow(name: String, platform: SimulatorPlatform, resources: String?, startedAt: Date?,
                           label: DeviceLabels.Entry? = nil, unlabeledText: String? = nil, tooltip: String) -> some View {
        let tint: Color = platform == .ios ? .blue : .green
        return HStack(spacing: 7) {
            Image(systemName: "iphone").font(.system(size: 12)).foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let startedAt {
                        let duration = max(0, store.now.timeIntervalSince(startedAt))
                        Text(FleetFormat.duration(duration)).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(duration >= 3 * 60 * 60 ? Theme.resourceWarning(scheme) : .primary).fixedSize()
                    } else {
                        Text(resources ?? "—").font(Theme.fine).monospacedDigit().fixedSize()
                    }
                }
                HStack(spacing: 6) {
                    if let text = label?.label ?? unlabeledText {
                        let color = label?.label != nil ? holderColor(label?.colorKey ?? "") : Theme.hot(scheme)
                        Text(text.replacingOccurrences(of: ": ", with: " · "))
                            .font(.system(size: 10)).foregroundStyle(color).lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                    }
                    if startedAt != nil, let resources {
                        Text(resources).font(Theme.fine).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 14)
            }
        }.help(tooltip)
    }
    private func iosTooltip(_ device: SimulatorDevice, host: HostModel, group: ProcessGroup?, label: DeviceLabels.Entry?) -> String {
        var lines = [device.name, host.config.displayName, device.runtime]
        if let group { lines.append("\(group.processCount) processes") }
        if let label { lines.append(label.tooltip) }
        else if let text = store.feeds.deviceLabels.unlabeledText { lines.append(text) }
        return lines.joined(separator: "\n")
    }
    var body: some View {
        if hasRunningDevices {
            VStack(alignment: .leading, spacing: 0) {
                Label("Simulators", systemImage: "iphone").font(.system(size: 13, weight: .semibold))
                ForEach(machines) { host in
                    VStack(alignment: .leading, spacing: 8) {
                        SectionCaption(title: host.config.displayName.uppercased())
                            .lineLimit(1).truncationMode(.middle)
                        VStack(alignment: .leading, spacing: 10) {
                            if host.config.kind == .local {
                                ForEach(store.simulators.devices) { device in
                                    let group = host.snapshot?.groups.first { $0.deviceID?.caseInsensitiveCompare(device.id) == .orderedSame }
                                    let label = store.feeds.deviceLabels.entry(for: device.id)
                                    let start = group?.startedAt ?? store.simulatorSessions.last {
                                        $0.hostID == host.id.uuidString && $0.deviceID == "sim:" + device.id.uppercased() && $0.end == nil
                                    }?.start
                                    deviceRow(name: device.name, platform: .ios,
                                              resources: resourceText(cpu: group?.cpuPercent, memory: group?.memoryBytes), startedAt: start,
                                              label: label, unlabeledText: store.feeds.deviceLabels.unlabeledText,
                                              tooltip: iosTooltip(device, host: host, group: group, label: label))
                                }
                            }
                            ForEach(android(host)) { device in
                                let group = host.snapshot?.groups.first { $0.id == device.id }
                                let label = host.config.kind == .local ? store.feeds.deviceLabels.entry(for: device.name) : nil
                                deviceRow(name: device.name, platform: .android,
                                          resources: resourceText(cpu: device.cpuPercent ?? group?.cpuPercent, memory: device.memoryBytes ?? group?.memoryBytes),
                                          startedAt: device.startedAt ?? group?.startedAt,
                                          label: label,
                                          unlabeledText: host.config.kind == .local ? store.feeds.deviceLabels.unlabeledText : nil,
                                          tooltip: device.name + "\n" + host.config.displayName + "\nAndroid emulator"
                                            + (group.map { "\n\($0.processCount) processes" } ?? "")
                                            + (label.map { "\n" + $0.tooltip } ?? ""))
                            }
                        }
                        if host.config.kind == .local {
                            ForEach(Array(store.feeds.deviceLabels.notes.enumerated()), id: \.offset) { _, note in
                                Text(note.text).font(Theme.fine)
                                    .foregroundStyle(note.isWarning ? Theme.resourceWarning(scheme) : .secondary)
                                    .lineLimit(1).truncationMode(.middle).help(note.text)
                            }
                        }
                    }.padding(.top, 8)
                }
                SimulatorTimeline(sessions: store.simulatorSessions, hosts: store.settings.hosts, now: store.now).padding(.top, hasHistory ? 10 : 0)
            }.padding(.horizontal, 10).padding(.vertical, 9)
                .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border(scheme, contrast: contrast), lineWidth: 0.7) }
        }
    }
}

struct OfflineBody: View {
    let reason: String
    let retryAt: Date
    let now: Date
    let history: [HistoryPoint]
    let retry: () -> Void
    var body: some View {
        Group {
            Text(reason).font(Theme.fine).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Text("Retrying in \(FleetFormat.ago(max(0, ceil(retryAt.timeIntervalSince(now)))))").font(
                    Theme.fine
                ).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Retry now", action: retry).font(Theme.fine).modifier(PanelBorderless())
            }

            if !history.isEmpty {
                HistoryChart(points: history, now: history.last?.date ?? now, label: "CPU").opacity(0.3)
            }
        }
    }
}

struct PanelFooter: View {
    @Environment(\.renderingPanel) private var rendering
    @Environment(\.colorScheme) private var scheme
    let hosts: [HostConfig]
    let settings: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            if rendering {
                HStack(spacing: 4) {
                    Label("Open btop", systemImage: "terminal")
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }.font(.system(size: 11)).padding(5).background(Theme.control(scheme), in: RoundedRectangle(cornerRadius: 7)).modifier(HoverFill())
            } else { Menu {
                ForEach(hosts) { host in

                    Button(host.displayName) {
                        TerminalLauncher.open(host)
                    }
                }
            } label: {
                Label("Open btop", systemImage: "terminal").font(.system(size: 11))
            }.menuStyle(.borderlessButton).fixedSize().padding(5).background(
                Theme.control(scheme),
                in: RoundedRectangle(cornerRadius: 7)
            ).modifier(HoverFill()) }
            Spacer(minLength: 0)
            Button(action: settings) {
                Label("Settings", systemImage: "gearshape")
            }.buttonStyle(ChipStyle())
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }.buttonStyle(ChipStyle())
        }
    }
}

private struct JobSection: View {
    let job: Job
    let now: Date
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    private var tint: Color {
        if job.status == .failed { return Theme.hot(scheme) }
        if job.isOverdue(at: now) || job.status == .warning { return Theme.warn(scheme) }
        return job.status == .ok ? Theme.ok(scheme) : .secondary
    }
    private var detail: String {
        "Last run \(job.finishedAt.map { FleetFormat.relative(now.timeIntervalSince($0)) } ?? "never")"
            + (job.durationSeconds.map { " · took \(FleetFormat.duration($0))" } ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "archivebox").font(.system(size: 14))
                Text(job.name).lineLimit(1).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                        .opacity(job.status == .running && pulse && !reduceMotion ? 0.4 : 1)
                    Text(job.title(at: now))
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(tint.opacity(0.13), in: Capsule())
            }
            Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(detail)
            if job.message != nil || job.logPath != nil {
                HStack(spacing: 4) {
                    if let message = job.message { Text(message).lineLimit(1).truncationMode(.middle).help(message) }
                    Spacer(minLength: 0)
                    if let path = job.logPath, !path.isEmpty {
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                        } label: { Label("Open log", systemImage: "doc") }.modifier(PanelBorderless()).fixedSize()
                    }
                }.font(Theme.fine).foregroundStyle(.secondary)
            }
        }.monospacedDigit().padding(.horizontal, 10).padding(.vertical, 9)
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border(scheme, contrast: contrast), lineWidth: 0.7) }
            .onAppear {
                if job.status == .running && !reduceMotion {
                    withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulse = true }
                }
            }.onChange(of: job.status) { _, kind in
                pulse = false
                if kind == .running && !reduceMotion {
                    withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulse = true }
                }
            }
    }
}
