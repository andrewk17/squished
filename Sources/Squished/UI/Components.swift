import AppKit
import SwiftUI
import SquishedCore

struct MeterTube: View {
    let value: Double?
    let level: LoadLevel
    var usesCPUWarning = false
    var width: CGFloat = 9
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelDensity) private var density
    var body: some View {
        RoundedRectangle(cornerRadius: 2.5).fill(Color.primary.opacity(0.08))
            .overlay(alignment: .bottom) {
                if let value = value {
                    RoundedRectangle(cornerRadius: 2.5).fill(Theme.meter(level, scheme, usesCPUWarning: usesCPUWarning))
                        .frame(height: max(2, density.tubeHeight * CGFloat(max(0, min(100, value)) / 100)))
                }
            }.frame(width: width, height: density.tubeHeight)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: value)
            .accessibilityHidden(true)
    }
}

/// Horizontal counterpart of the meter tube, using the same track and load colours.
struct UsageBar: View {
    let value: Double
    let level: LoadLevel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Color.primary.opacity(0.08))
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.meter(level, scheme))
                        .frame(width: max(2, geometry.size.width * CGFloat(max(0, min(100, value)) / 100)))
                }
        }.frame(height: 4)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: value)
            .accessibilityHidden(true)
    }
}

struct MeterColumn: View {
    let title: String
    let value: Double?
    let level: LoadLevel
    let detail: String
    var detailMinimumScale: CGFloat = 1
    var pressure: MemoryPressure? = nil
    var usesCPUWarning = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.panelDensity) private var density
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                SectionCaption(title: title)
                if let pressure = pressure, pressure != .normal {
                    Circle().fill(pressure == .warning ? Theme.resourceWarning(scheme) : Theme.hot(scheme))
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Memory pressure: \(pressure.rawValue)")
                }
            }
            HStack(alignment: .top, spacing: 6) {
                MeterTube(value: value, level: level, usesCPUWarning: usesCPUWarning)
                Text(FleetFormat.percent(value))
                    .font(.system(size: density.heroSize, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }.frame(height: density.tubeHeight, alignment: .top)
            Text(detail).font(Theme.fine).foregroundStyle(.secondary).lineLimit(1)
                .minimumScaleFactor(detailMinimumScale)
        }.monospacedDigit().frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

/// Keep the disk group in its existing column, with one value row per mount.
struct PartitionMeterColumn: View {
    let disks: [DiskUsage]
    let levels: [LoadLevel]
    let detail: String
    @Environment(\.panelDensity) private var density

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionCaption(title: "DISK")
            HStack(alignment: .top, spacing: 4) {
                HStack(spacing: 1.5) {
                    ForEach(disks.indices, id: \.self) { index in
                        MeterTube(value: disks[index].percent, level: levels[index], width: disks.count > 2 ? 3.5 : 5)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(disks.indices, id: \.self) { index in
                        let disk = disks[index]
                        (Text(FleetFormat.percent(disk.percent))
                            .font(.system(size: density.heroSize, weight: .semibold, design: .rounded))
                         + Text(" " + disk.mount).font(Theme.fine).foregroundColor(.secondary))
                            .lineLimit(1).minimumScaleFactor(0.35)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }.frame(height: density.tubeHeight, alignment: .top)
            // Omit a capacity that cannot fit in full; never leave an ellipsis.
            ViewThatFits(in: .horizontal) {
                Text(detail).font(Theme.fine).foregroundStyle(.secondary).fixedSize()
                Color.clear.frame(height: 12)
            }
        }.monospacedDigit().frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(disks.map { disk in
                "Disk \(disk.mount), \(FleetFormat.percent(disk.percent)), \(FleetFormat.bytes(disk.total > disk.used ? disk.total - disk.used : 0)) free"
            }.joined(separator: "; "))
    }
}

struct MeterSkeleton: View {
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(0..<4) { index in
                VStack(alignment: .leading, spacing: 5) {
                    SectionCaption(title: ["CPU", "MEM", "DISK", "NET"][index])
                    HStack(alignment: .top, spacing: 6) {
                        if index < 3 { MeterTube(value: nil, level: .normal) }
                        RoundedRectangle(cornerRadius: 2.5).fill(Color.primary.opacity(0.08))
                            .frame(height: index < 3 ? 15 : 32)
                    }.frame(height: 44, alignment: .top)
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08)).frame(height: 10)
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }.accessibilityElement(children: .ignore)
    }
}

struct Sparkline: View {
    let points: [HistoryPoint]
    let now: Date
    var color: Color = .accentColor
    var label = "CPU"
    var height: CGFloat = 24
    var showsRules = true
    var body: some View {
        GeometryReader { geometry in

            let width = geometry.size.width, height = geometry.size.height
            let visible = points.filter { now.timeIntervalSince($0.date) <= 300 }

            let coordinates = visible.map {
                CGPoint(
                    x: width * CGFloat(max(0, min(1, 1 - now.timeIntervalSince($0.date) / 300))),
                    y: height * CGFloat(1 - max(0, min(100, $0.value)) / 100)
                )
            }

            ZStack {
                if showsRules { Group {
                Path { p in

                    p.move(to: CGPoint(x: 0, y: height))
                    p.addLine(to: CGPoint(x: width, y: height))
                }.stroke(Color.secondary.opacity(0.28), lineWidth: 1)
                Path { p in

                    p.move(to: .zero)
                    p.addLine(to: CGPoint(x: width, y: 0))
                }.stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                } }
                if let first = coordinates.first, let last = coordinates.last {
                    Path { p in

                        p.move(to: CGPoint(x: first.x, y: height))
                        p.addLines(coordinates)

                        p.addLine(to: CGPoint(x: last.x, y: height))
                        p.closeSubpath()
                    }.fill(
                        LinearGradient(
                            colors: [color.opacity(0.16), color.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    Path { p in
                        p.addLines(coordinates)
                    }.stroke(
                        color,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }.frame(height: height).accessibilityLabel("\(label) history over five minutes")
    }
}

struct DotPill: View {
    let title: String
    let color: Color
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false
    @Environment(\.panelDensity) private var density
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7).shadow(color: color.opacity(0.6), radius: 2)
                .opacity(pulsing && dim && !reduceMotion ? 0.35 : 1)
            Text(title).font(.system(size: density == .current ? 11 : 10.5, weight: .medium)).monospacedDigit()
        }.foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 3).background(
            color.opacity(0.13),
            in: Capsule()
        )
        .onAppear {
            if pulsing && !reduceMotion {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
        }
    }
}

struct StatePill: View {
    let state: ConnectionState
    let now: Date
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        switch state {
        case .live: DotPill(title: "Live", color: Theme.ok(scheme))
        case .stale(let since):
            DotPill(title: "Stale · \(FleetFormat.ago(now.timeIntervalSince(since)))", color: Theme.warn(scheme))
        case .offline: DotPill(title: "Offline", color: .secondary)
        case .connecting: DotPill(title: "Connecting…", color: .secondary, pulsing: true)
        }
    }
}

@MainActor
final class ProcessIconCache {
    static let shared = ProcessIconCache()
    private var icons: [String: NSImage] = [:]
    func icon(_ path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        if icons.count >= 128 { icons.removeAll() }
        icons[path] = icon
        return icon
    }
}

struct ProcessGroupRow: View, Equatable {
    @Environment(\.colorScheme) private var scheme
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.group == rhs.group && lhs.memory == rhs.memory && lhs.totalMemory == rhs.totalMemory
            && lhs.cores == rhs.cores && lhs.remote == rhs.remote
    }
    let group: ProcessGroup
    let memory: Bool
    let totalMemory: UInt64
    let cores: Int
    var remote = false
    private var value: String { memory ? FleetFormat.bytes(group.memoryBytes) : FleetFormat.percent(group.cpuPercent, digits: 1) }
    private var share: Double {
        min(1, max(0, memory ? Double(group.memoryBytes) / Double(max(1, totalMemory)) : group.cpuPercent / Double(max(1, cores) * 100)))
    }
    private var tooltip: String {
        let rows = group.processes.sorted { memory ? $0.memoryBytes > $1.memoryBytes : $0.cpuPercent > $1.cpuPercent }.prefix(5)
        let detail = rows.map { p in
            p.name + " · " + (memory ? FleetFormat.bytes(p.memoryBytes) : FleetFormat.percent(p.cpuPercent, digits: 1))
                + (group.kind == .service || group.kind == .kernel ? "\n" + p.executablePath : "")
        }.joined(separator: "\n")
        return (detail.isEmpty ? "\(group.processCount) processes · \(group.subtitle)" : detail)
            + (remote && memory ? "\nRSS: shared pages are counted once per process." : "")
    }
    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                if let path = group.bundlePath {
                    Image(nsImage: ProcessIconCache.shared.icon(path)).resizable().frame(width: 16, height: 16)
                } else { Image(systemName: group.symbol).frame(width: 16, height: 16).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Text(group.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 2)
                Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit().fixedSize()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(memory ? Theme.memory(scheme) : Color.accentColor).frame(width: geometry.size.width * share)
                }
            }.frame(height: 2)
        }.help(tooltip).modifier(HoverFill())
    }
}

struct MemoryBreakdownView: View {
    let breakdown: MemoryBreakdown
    private let colors: [Color] = [.accentColor, .orange, .purple, .mint, .gray]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                let denominator = max(Double(breakdown.total), breakdown.segments.reduce(0) { $0 + Double($1.bytes) })
                HStack(spacing: 0) {
                    ForEach(Array(breakdown.segments.enumerated()), id: \.element.id) { index, segment in
                        colors[index % colors.count]
                            .frame(width: geometry.size.width * Double(segment.bytes) / max(1, denominator))
                            .help("\(segment.name): \(FleetFormat.bytes(segment.bytes)) · \(FleetFormat.percent(Double(segment.bytes) / Double(max(1, breakdown.total)) * 100, digits: 1)) of RAM")
                    }
                }.clipShape(Capsule())
            }.frame(height: 8)
            HStack(spacing: 4) {
                ForEach(Array(breakdown.segments.enumerated()), id: \.element.id) { index, segment in
                    HStack(spacing: 2) {
                        Circle().fill(colors[index % colors.count]).frame(width: 4, height: 4)
                        Text(segment.name)
                    }.help("\(segment.name): \(FleetFormat.bytes(segment.bytes))")
                }
                Text("Swap \(FleetFormat.bytes(breakdown.swapUsed))").monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.65)
        }
    }
}

struct ExpandedProcessGroup: View {
    let group: ProcessGroup
    let memory: Bool
    let remote: Bool
    private var processes: [ProcessInput] {
        Array(group.processes.sorted {
            let a = memory ? Double($0.memoryBytes) : $0.cpuPercent
            let b = memory ? Double($1.memoryBytes) : $1.cpuPercent
            return a == b ? $0.pid < $1.pid : a > b
        }.prefix(10))
    }
    private var remainingValue: String {
        if memory {
            let shown = processes.reduce(UInt64(0)) { $0 &+ $1.memoryBytes }
            return FleetFormat.bytes(group.memoryBytes > shown ? group.memoryBytes - shown : 0)
        }
        return FleetFormat.percent(max(0, group.cpuPercent - processes.reduce(0) { $0 + $1.cpuPercent }), digits: 1)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(processes, id: \.pid) { process in
                HStack(spacing: 5) {
                    Text(process.name + (ProcessGrouper.scriptName(process.arguments).map { " · " + $0 } ?? ""))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(memory ? FleetFormat.bytes(process.memoryBytes) : FleetFormat.percent(process.cpuPercent, digits: 1))
                        .monospacedDigit().fixedSize()
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(process.executablePath + (remote && memory ? "\nRSS: shared pages are counted once per process." : ""))
            }
            if group.processCount > processes.count {
                Text("+ \(group.processCount - processes.count) more · \(remainingValue)").font(Theme.fine).foregroundStyle(.secondary)
            }
            if remote { Text("top processes only").font(Theme.fine).foregroundStyle(.secondary) }
        }.padding(.leading, 22).padding(.bottom, 3)
    }
}
