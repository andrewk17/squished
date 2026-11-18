import AppKit
import SwiftUI
import SquishedCore

struct CompactHostCard: View {
    @Bindable var model: HostModel
    let now: Date
    let symbol: String
    let retry: () -> Void
    @Environment(\.panelDensity) private var density
    @Environment(\.colorScheme) private var scheme
    @State private var showingUptime = false
    private var subtitle: String {
        model.info.map { "\($0.osName) · \($0.model ?? $0.kernel) · \($0.cpuCount) cores" } ?? "Connecting…"
    }
    private var stateTitle: String {
        switch model.state {
        case .live: return "Live"
        case .stale(let date): return "Stale · \(FleetFormat.ago(now.timeIntervalSince(date)))"
        case .offline: return "Offline"
        case .connecting: return "Connecting…"
        }
    }
    private var stateColor: Color {
        switch model.state {
        case .live: return Theme.ok(scheme)
        case .stale: return Theme.warn(scheme)
        default: return .secondary
        }
    }
    private var updated: String {
        model.snapshot.map { "Updated \(FleetFormat.ago(now.timeIntervalSince($0.timestamp))) ago" } ?? "Waiting for first sample"
    }
    private var uptime: String { "up \(model.snapshot?.uptime.map(FleetFormat.uptime) ?? "—")" }
    private var stale: Bool { if case .stale = model.state { true } else { false } }
    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12))
                if density == .extreme {
                    Text(model.config.displayName).font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail).help(model.config.displayName)
                } else {
                    Text(model.config.displayName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                }
                if density != .medium {
                    Circle().fill(stateColor).frame(width: 7, height: 7)
                        .help(stateTitle + "\n" + updated).accessibilityLabel(stateTitle)
                }
                if density == .medium {
                    Text(subtitle).font(Theme.fine).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if density == .medium {
                    StatePill(state: model.state, now: now).fixedSize().help(stateTitle + "\n" + updated)
                }
                if density == .extreme {
                    ExtremeHeaderNetwork(model: model).fixedSize().layoutPriority(1)
                    Button { showingUptime.toggle() } label: { Image(systemName: "clock").font(Theme.fine) }
                        .buttonStyle(.plain).modifier(HoverFill()).help(uptime).accessibilityLabel(uptime)
                        .popover(isPresented: $showingUptime) { Text(uptime).font(Theme.fine).padding(8) }
                    terminalButton
                }
            }.help(subtitle + "\n" + stateTitle + "\n" + updated)
            switch model.state {
            case .connecting:
                if density == .extreme {
                    MeterRow(model: model, available: false)
                    ExtremeResources(model: model, now: now, connecting: true)
                } else {
                    MeterSkeleton().accessibilityLabel("Waiting for first sample")
                }
            case .offline(let reason, let retryAt):
                MeterRow(model: model, available: false)
                OfflineBody(reason: reason, retryAt: retryAt, now: now, history: model.cpuHistory.values, retry: retry)
            case .live, .stale:
                metrics.opacity(stale ? 0.55 : 1)
            }
        }.padding(.horizontal, density.horizontalPadding).padding(.vertical, density.verticalPadding)
    }
    private var metrics: some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            MeterRow(model: model)
            if density == .extreme {
                ExtremeResources(model: model, now: model.snapshot?.timestamp ?? now)
            } else {
                CompactHistory(model: model, now: model.snapshot?.timestamp ?? now)
                if let disks = model.snapshot?.disks, disks.count > 1 {
                    PartitionsList(disks: disks)
                }
                CompactProcesses(model: model)
            }
            if density != .extreme {
                HStack(spacing: 4) {
                    showAll
                    Spacer(minLength: 0)
                    if density == .high { CompactResourceToggle(model: model) }
                    Text(uptime).font(Theme.fine).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                    Spacer(minLength: 0)
                    terminalButton
                }
            } else if model.showAllGroups {
                showAll
            }
        }
    }
    private var showAll: some View {
        Button(model.showAllGroups ? "Show less" : "Show all (\(model.snapshot?.groups.count ?? 0))") {
            model.showAllGroups.toggle()
        }.font(Theme.fine).modifier(PanelBorderless())
            .help("Show all process groups; \(model.snapshot?.groups.count ?? 0) total")
    }
    private var terminalButton: some View {
        Button { TerminalLauncher.open(model.config) } label: {
            Image(systemName: "terminal").font(Theme.fine)
        }.modifier(PanelBorderless()).modifier(HoverFill()).help("Open btop on \(model.config.displayName)")
            .accessibilityLabel("Open btop on \(model.config.displayName)")
    }
}

/// Each resource keeps its history and ranking together; the persisted picker
/// still belongs to the other densities and never controls these columns.
private struct ExtremeResources: View {
    @Bindable var model: HostModel
    let now: Date
    var connecting = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ExtremeResourceColumn(model: model, now: now, memory: false, connecting: connecting)
            ExtremeResourceColumn(model: model, now: now, memory: true, connecting: connecting)
        }.contextMenu {
            Button(model.showAllGroups ? "Show less" : "Show all (\(model.snapshot?.groups.count ?? 0))") {
                model.showAllGroups.toggle()
            }
        }
    }
}

private struct ExtremeResourceColumn: View {
    @Bindable var model: HostModel
    let now: Date
    let memory: Bool
    let connecting: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.renderingPanel) private var rendering
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var expandedGroup: String?
    private var title: String { memory ? "Memory" : "CPU" }
    private var seriesColor: Color { memory ? Theme.memory(scheme) : .accentColor }
    private var sorted: [ProcessGroup] {
        (model.snapshot?.groups ?? []).sorted {
            let a = memory ? Double($0.memoryBytes) : $0.cpuPercent
            let b = memory ? Double($1.memoryBytes) : $1.cpuPercent
            return a == b ? $0.id < $1.id : a > b
        }
    }
    // Zero-only memory data cannot identify offenders. Keep the chart and the
    // three empty rows instead of presenting a misleading ranked zero list.
    private var unavailable: Bool { sorted.isEmpty || (memory && !sorted.contains { $0.memoryBytes > 0 }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The caption sits beside the chart, never on it: a line at any level stays clear of the text.
            HStack(spacing: 4) {
                Text(memory ? "MEM" : "CPU").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(seriesColor.opacity(contrast == .increased ? 1 : 0.8))
                    .fixedSize().frame(width: 23, alignment: .leading).accessibilityHidden(true)
                if connecting {
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08)).frame(height: 16)
                        .accessibilityLabel("\(title) history waiting for first sample")
                } else {
                    Sparkline(points: memory ? model.memoryHistory.values : model.cpuHistory.values, now: now,
                              color: seriesColor, label: title,
                              height: 16, showsRules: false)
                        .help("\(title), last 5 min · 0–100%")
                }
            }
            if connecting || unavailable { placeholders }
            else if model.showAllGroups {
                if rendering {
                    // ImageRenderer cannot draw an AppKit-backed ScrollView.
                    // Render the same first viewport without changing live scrolling.
                    rows.frame(height: min(260, CGFloat(sorted.count) * 15), alignment: .top).clipped()
                } else { ScrollView { rows }.frame(maxHeight: 260) }
            }
            else { rows }
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
    private var placeholders: some View {
        VStack(spacing: 0) {
            ForEach(0..<3) { _ in
                HStack {
                    if connecting {
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08)).frame(width: 70, height: 8)
                    }
                    Spacer(minLength: 0)
                    Text("—").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                }.frame(height: 15)
            }
        }.help("\(title) process data unavailable")
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title) process data unavailable")
    }
    private var rows: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(sorted.prefix(model.showAllGroups ? sorted.count : 3))) { group in
                Button { expandedGroup = expandedGroup == group.id ? nil : group.id } label: {
                    row(group)
                }.buttonStyle(.plain)
                if expandedGroup == group.id {
                    ExpandedProcessGroup(group: group, memory: memory, remote: model.config.kind != .local)
                }
            }
        }
    }
    private func row(_ group: ProcessGroup) -> some View {
        let fullValue = memory ? FleetFormat.bytes(group.memoryBytes) : FleetFormat.percent(group.cpuPercent, digits: 1)
        // Retain the shared formatter's binary units and precision, shortening
        // only its suffix for the half-width column ("2.1 GB" -> "2.1G").
        let compactBytes = fullValue.replacingOccurrences(of: " ", with: "")
        let value = memory ? (fullValue.hasSuffix(" B") ? compactBytes : String(compactBytes.dropLast())) : fullValue
        return HStack(spacing: 4) {
            if let path = group.bundlePath {
                Image(nsImage: ProcessIconCache.shared.icon(path)).resizable().frame(width: 12, height: 12)
            } else {
                Image(systemName: group.symbol).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 12, height: 12)
            }
            Text(group.name).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value).fontWeight(.medium).monospacedDigit()
                .foregroundStyle(seriesColor.opacity(contrast == .increased ? 1 : 0.75)).fixedSize()
        }.font(.system(size: 10.5)).frame(height: 15).contentShape(Rectangle())
            .modifier(HoverFill(horizontalPadding: 0, verticalPadding: 0))
            .help("\(group.name)\n\(group.subtitle) · \(group.processCount) processes\n\(title): \(fullValue)"
                  + (memory && model.config.kind != .local ? "\nRSS: shared pages are counted once per process." : "")
                  + (memory ? "" : "\n100 % = one core · \(model.info?.cpuCount ?? 0) cores")
                  + "\nClick to expand; right-click to show all process groups.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(group.name), \(group.processCount) processes, \(title) \(fullValue)")
    }
}

struct CompactResourceToggle: View {
    @Bindable var model: HostModel
    @Environment(\.panelDensity) private var density
    var body: some View {
        Group {
        if density == .extreme {
            Button { model.groupMemory.toggle() } label: {
                Image(systemName: model.groupMemory ? "memorychip" : "cpu").font(Theme.fine)
            }.modifier(HoverFill()).accessibilityValue(model.groupMemory ? "Memory" : "CPU")
        } else { HStack(spacing: 3) {
            Button("CPU") { model.groupMemory = false }.foregroundStyle(model.groupMemory ? .secondary : .primary)
            Text("/").foregroundStyle(.tertiary)
            Button("MEM") { model.groupMemory = true }.foregroundStyle(model.groupMemory ? .primary : .secondary)
        } }
        }.font(.system(size: 9, weight: .medium)).buttonStyle(.plain)
            .help("Using the most: \(model.groupMemory ? "Memory" : "CPU"). Switch CPU / Memory. 100 % = one core · \(model.info?.cpuCount ?? 0) cores. Click a process to expand; right-click for all processes.")
            .accessibilityLabel("Sort processes by CPU or memory")
    }
}

private struct CompactProcesses: View {
    @Bindable var model: HostModel
    @Environment(\.panelDensity) private var density
    @Environment(\.colorScheme) private var scheme
    private var sorted: [ProcessGroup] {
        (model.snapshot?.groups ?? []).sorted {
            let a = model.groupMemory ? Double($0.memoryBytes) : $0.cpuPercent
            let b = model.groupMemory ? Double($1.memoryBytes) : $1.cpuPercent
            return a == b ? $0.id < $1.id : a > b
        }
    }
    var body: some View {
        VStack(spacing: density == .extreme ? 0 : 2) {
            if density == .medium {
                HStack(spacing: 2) {
                    Button { model.expanded.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: model.expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                            SectionCaption(title: "USING THE MOST")
                        }
                    }.buttonStyle(.plain).modifier(HoverFill())
                        .help("100 % = one core · this host has \(model.info?.cpuCount ?? 0)")
                    Spacer(minLength: 0)
                    ProcessResourcePicker(memory: $model.groupMemory)
                }
            }
            if density != .medium || model.expanded {
                if model.groupMemory, let breakdown = model.snapshot?.memoryBreakdown { MemoryBreakdownView(breakdown: breakdown) }
                if model.showAllGroups { ScrollView { rows }.frame(maxHeight: 260) }
                else { rows }
                if sorted.isEmpty { Text("Waiting for process sample").font(Theme.fine).foregroundStyle(.secondary) }
            }
        }.contextMenu {
            Button(model.showAllGroups ? "Show less" : "Show all (\(sorted.count))") { model.showAllGroups.toggle() }
        }.help("Using the most · \(sorted.count) process groups. Right-click to show all.\n" + sorted.prefix(5).map { group in
            "\(group.name): \(model.groupMemory ? FleetFormat.bytes(group.memoryBytes) : FleetFormat.percent(group.cpuPercent, digits: 1)) · \(group.subtitle)"
        }.joined(separator: "\n"))
    }
    private var rows: some View {
        VStack(spacing: density == .extreme ? 0 : 2) {
            ForEach(Array(sorted.prefix(model.showAllGroups ? 15 : density.processLimit))) { group in
                Button { model.expandedGroup = model.expandedGroup == group.id ? nil : group.id } label: {
                    row(group)
                }.buttonStyle(.plain)
                if model.expandedGroup == group.id {
                    ExpandedProcessGroup(group: group, memory: model.groupMemory, remote: model.config.kind != .local)
                }
            }
        }
    }
    private func row(_ group: ProcessGroup) -> some View {
        let size: CGFloat = density == .extreme ? 12 : 14
        let share = model.groupMemory
            ? Double(group.memoryBytes) / Double(max(1, model.snapshot?.memory?.total ?? 1))
            : group.cpuPercent / Double(max(1, model.info?.cpuCount ?? 1) * 100)
        let value = model.groupMemory ? FleetFormat.bytes(group.memoryBytes) : FleetFormat.percent(group.cpuPercent, digits: 1)
        return HStack(spacing: 4) {
            if let path = group.bundlePath {
                Image(nsImage: ProcessIconCache.shared.icon(path)).resizable().frame(width: size, height: size)
            } else { Image(systemName: group.symbol).foregroundStyle(.secondary).frame(width: size, height: size) }
            Text(group.name).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            if group.processCount > 1 {
                Text("· \(group.processCount)").foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength: 0)
            Text(value).fontWeight(.medium).monospacedDigit().fixedSize()
        }.font(.system(size: density == .extreme ? 10.5 : 11)).frame(height: 14)
            .background(alignment: .leading) {
                if density != .extreme {
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 3).fill((model.groupMemory ? Theme.memory(scheme) : .accentColor).opacity(0.1))
                            .frame(width: proxy.size.width * max(0, min(1, share)))
                    }
                }
            }.modifier(HoverFill())
            .accessibilityLabel("\(group.name), \(group.subtitle), \(value)")
            .help("\(group.name)\n\(group.subtitle) · \(group.kind.rawValue) · \(group.processCount) processes\n\(value)\n100 % = one core · \(model.info?.cpuCount ?? 0) cores")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(group.name), \(group.subtitle), \(value)")
    }
}

private struct CompactHistory: View {
    let model: HostModel
    let now: Date
    @Environment(\.panelDensity) private var density
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if density == .medium {
            VStack(spacing: 3) {
                historyLine(model.cpuHistory.values, label: "CPU", color: .accentColor)
                historyLine(model.memoryHistory.values, label: "MEM", color: Theme.memory(scheme))
            }
        } else {
            HStack(spacing: 5) {
                ZStack {
                    Sparkline(points: model.cpuHistory.values, now: now, height: density == .extreme ? 14 : 20)
                    Sparkline(points: model.memoryHistory.values, now: now, color: Theme.memory(scheme), label: "Memory",
                              height: density == .extreme ? 14 : 20, showsRules: false)
                }
                if density != .extreme {
                    HStack(spacing: 3) {
                        Circle().fill(Color.accentColor).frame(width: 3, height: 3)
                        Text("CPU ·")
                        Circle().fill(Theme.memory(scheme)).frame(width: 3, height: 3)
                        Text("MEM · 5 min")
                    }.font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
                }
            }.help("CPU and memory, last 5 min").accessibilityLabel("CPU and memory, last 5 min")
        }
    }
    private func historyLine(_ points: [HistoryPoint], label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Sparkline(points: points, now: now, color: color, label: label, height: 18)
            Text("\(label) · 5 min").font(Theme.fine).foregroundStyle(.secondary).fixedSize()
        }
    }
}

private struct ExtremeHeaderNetwork: View {
    let model: HostModel
    private var available: Bool {
        switch model.state { case .live, .stale: true; default: false }
    }
    private var network: NetworkRate? { available ? model.snapshot?.network : nil }
    private var traffic: TrafficLedger.Bucket? { available ? model.traffic : nil }
    private var stale: Bool { if case .stale = model.state { true } else { false } }
    var body: some View {
        HStack(spacing: 5) {
            rate("↑", network?.txPerSecond)
            rate("↓", network?.rxPerSecond)
        }.font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            .opacity(stale ? 0.55 : 1)
            .help("Today: \(FleetFormat.trafficSplit(traffic?.today))"
                  + "\nThis month: \(FleetFormat.trafficSplit(traffic?.monthly))"
                  + "\nCounted while Squished is running"
                  + "\n↑ \(FleetFormat.rate(network?.txPerSecond)) · ↓ \(FleetFormat.rate(network?.rxPerSecond))")
    }
    private func rate(_ arrow: String, _ value: Double?) -> some View {
        Text(arrow + shortRate(value)).opacity((value ?? 0) < 5 * 1024 ? 0.55 : 1)
    }
    private func shortRate(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 1_048_576 { return String(format: "%.1fM", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.0fK", value / 1024) }
        return String(format: "%.0f", value)
    }
}

struct ExtremeMeterRow: View {
    let model: HostModel
    let snapshot: HostSnapshot?
    let cpuHelp, memoryHelp, diskHelp: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { proxy in
            // Four equal slots; a single disk also occupies the intervening gutter.
            let slotWidth = max(0, (proxy.size.width - 18) / 4)
            HStack(alignment: .top, spacing: 6) {
                column("CPU", value: FleetFormat.percent(snapshot?.cpu?.total), percent: snapshot?.cpu?.total ?? 0,
                       level: model.cpuLevel.level, cpu: true, captionTint: .accentColor)
                    .frame(width: slotWidth)
                    .help(cpuHelp + "\n" + (snapshot?.load.map { "load \(FleetFormat.decimal($0.one, digits: 2))" } ?? "—"))
                column("MEM", value: FleetFormat.percent(snapshot?.memory?.percent), percent: snapshot?.memory?.percent ?? 0,
                       level: model.memoryLevel, captionTint: Theme.memory(scheme))
                    .frame(width: slotWidth).help(memoryHelp)
                let disks = snapshot?.disks ?? []
                if disks.count > 1 {
                    ForEach(0..<2) { index in
                        let disk = disks[index]
                        // Same footprint as a single disk: one DISK caption, bars filling both slots.
                        column(index == 0 ? "DISK" : nil, value: FleetFormat.percent(disk.percent), percent: disk.percent,
                               level: model.diskLevel(for: disk), note: disk.mount, fullWidthBar: true)
                            .frame(width: slotWidth)
                            .help(index == 1 && disks.count > 2
                                  ? disks.map(partitionHelp).joined(separator: "\n") : partitionHelp(disk))
                    }
                } else {
                    let disk = disks.first
                    column("DISK", value: FleetFormat.percent(disk?.percent), percent: disk?.percent ?? 0,
                           level: disk.map { model.diskLevel(for: $0) } ?? model.diskLevel,
                           note: disk.map { "· \(compactFreeSpace($0)) free" }, fullWidthBar: true)
                        .frame(width: slotWidth * 2 + 6).help(diskHelp)
                }
            }
        }.frame(height: 18).monospacedDigit()
    }
    private func compactFreeSpace(_ disk: DiskUsage) -> String {
        let free = disk.total > disk.used ? disk.total - disk.used : 0
        let compact = FleetFormat.compactFreeSpace(free)
        // The menu bar omits G; the panel needs an explicit unit beside "free".
        return compact + (free >= 1_073_741_824 && free < 1_099_511_627_776 ? "G" : "")
    }
    private func partitionHelp(_ disk: DiskUsage) -> String {
        "\(disk.mount): \(FleetFormat.capacity(used: disk.used, total: disk.total)) used · \(FleetFormat.percent(disk.percent))"
            + " · \(FleetFormat.bytes(disk.total > disk.used ? disk.total - disk.used : 0)) free"
    }
    private func column(_ title: String?, value: String, percent: Double, level: LoadLevel,
                        cpu: Bool = false, captionTint: Color? = nil, note: String? = nil,
                        fullWidthBar: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                if let title {
                    Text(title).font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary).foregroundStyle(captionTint ?? .primary)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
                // Same size as every other value; the note (free space or mount) gives way first.
                Text(value).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false).layoutPriority(1)
                if let note {
                    Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            GeometryReader { proxy in
                Capsule().fill(Color.primary.opacity(0.08)).overlay(alignment: .leading) {
                    Capsule().fill(Theme.meter(level, scheme, usesCPUWarning: cpu))
                        .frame(width: max(1, proxy.size.width * max(0, min(100, percent)) / 100))
                }
            }.frame(width: fullWidthBar ? nil : 36, height: 3).accessibilityHidden(true)
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

struct CompactJobSection: View {
    let job: Job
    let now: Date
    var summaryOnly = false
    @Environment(\.panelDensity) private var density
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var tint: Color {
        job.status == .failed ? Theme.hot(scheme) : job.isOverdue(at: now) || job.status == .warning ? Theme.warn(scheme) : job.status == .ok ? Theme.ok(scheme) : .secondary
    }
    private var age: String { job.finishedAt.map { FleetFormat.relative(now.timeIntervalSince($0)) } ?? "never" }
    private var detail: String {
        "Last run \(age)" + (job.durationSeconds.map { " · took \(FleetFormat.duration($0))" } ?? "")
            + (job.message.map { " · \($0)" } ?? "")
    }
    private func openLog() {
        if let path = job.logPath, !path.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
    }
    var body: some View {
        if summaryOnly {
            Group {
                if let path = job.logPath, !path.isEmpty {
                    Button(action: openLog) { summary }.buttonStyle(.plain).modifier(HoverFill())
                } else { summary }
            }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading).help(tooltip)
        } else { card }
    }
    private var summary: some View {
        Text("✓ \(job.name) \(age)").lineLimit(1).truncationMode(.middle)
    }
    private var tooltip: String {
        job.name + "\n" + detail + "\n" + job.title(at: now) + (job.logPath.map { "\nOpen log: \($0)" } ?? "")
    }
    private var card: some View {
        Group {
            if density == .medium { contents }
            else { Button(action: openLog) { contents }.buttonStyle(.plain).modifier(HoverFill()) }
        }.monospacedDigit().padding(.horizontal, density.horizontalPadding).padding(.vertical, density.verticalPadding)
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border(scheme, contrast: contrast), lineWidth: 0.7) }
            .help(detail + "\n" + job.title(at: now) + (job.logPath.map { "\nOpen log: \($0)" } ?? ""))
    }
    private var contents: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "archivebox").font(.system(size: 12))
                Text(job.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if density != .medium { Text(age).font(Theme.fine).foregroundStyle(.secondary).lineLimit(1).fixedSize() }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    Text(job.title(at: now)).font(.system(size: 10.5, weight: .medium))
                }.foregroundStyle(tint)
                    .padding(.horizontal, density == .medium ? 6 : 0).padding(.vertical, density == .medium ? 3 : 0)
                    .background(density == .medium ? tint.opacity(0.13) : .clear, in: Capsule()).fixedSize()
            }
            if density == .medium {
                HStack(spacing: 4) {
                    Text(detail).font(Theme.fine).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if job.logPath != nil {
                        Button(action: openLog) { Image(systemName: "doc") }.modifier(PanelBorderless())
                            .help("Open log").accessibilityLabel("Open log")
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
