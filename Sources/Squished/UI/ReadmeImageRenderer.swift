#if DEBUG
import AppKit
import SwiftUI
import SquishedCore

extension PanelVariantRenderer {
    static func renderReadmeImages(to directory: String) throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = try ReadmeDemo.store()
        for scheme: ColorScheme in [.dark, .light] {
            let dark = scheme == .dark
            let suffix = dark ? "dark" : "light"
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let item = MenuBarRenderer().image(store: store, appearance: appearance)
            let statusItem = Image(nsImage: item).frame(width: item.size.width, height: item.size.height)
            let ink: Color = dark ? .white : .black
            let strip = menuBarStrip(dark: dark)
            let panelShape = RoundedRectangle(cornerRadius: 12)
            let panel = HostedPanelView(store: store, settings: {}, maximumHeight: .greatestFiniteMagnitude)
                .environment(\.renderingPanel, true)
                .environment(\._colorSchemeContrast, .standard)
                .foregroundStyle(ink.opacity(dark ? 0.92 : 0.88))
                .tint(Color(red: 0.05, green: 0.52, blue: 1))
                .background(dark ? color(38, 42, 49) : color(246, 246, 248))
                .clipShape(panelShape)
                .overlay { panelShape.strokeBorder(ink.opacity(0.10), lineWidth: 0.5) }
                .shadow(color: .black.opacity(dark ? 0.35 : 0.18), radius: 24, x: 0, y: 10)

            let hero = VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 14) {
                    statusItem
                    Text("Tue 9:41").font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                }
                .padding(.trailing, 16)
                .frame(width: 520, height: 24, alignment: .trailing)
                .background(strip)
                .overlay(alignment: .bottom) { ink.opacity(0.08).frame(height: 0.5) }

                panel.padding(.trailing, 20).padding(.bottom, 38)
            }
            .background(readmeBackdrop(dark: dark))
            .environment(\.colorScheme, scheme)

            let closeUp = statusItem.padding(12)
                .background(strip, in: RoundedRectangle(cornerRadius: 8))
                .environment(\.colorScheme, scheme)
            try writeReadmeImage(hero, scale: 2, to: url.appendingPathComponent("hero-\(suffix).png"))
            try writeReadmeImage(closeUp, scale: 6, to: url.appendingPathComponent("menubar-\(suffix).png"))
        }

        let localStore = FleetStore(startServices: false)
        localStore.hosts = store.hosts.filter { $0.config.kind == .local }
        localStore.settings.showNetworkInMenuBar = store.settings.showNetworkInMenuBar
        for scheme: ColorScheme in [.dark, .light] {
            let dark = scheme == .dark
            let suffix = dark ? "dark" : "light"
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let item = MenuBarRenderer().image(store: store, appearance: appearance)
            let localItem = MenuBarRenderer().image(store: localStore, appearance: appearance)
            let widths = MenuBarWidthComparison(fleetItem: item, localItem: localItem, strip: menuBarStrip(dark: dark))
                .background(readmeBackdrop(dark: dark))
                .environment(\.colorScheme, scheme)
            try writeReadmeImage(widths, scale: 2, to: url.appendingPathComponent("widths-\(suffix).png"))
        }
    }

    private static func menuBarStrip(dark: Bool) -> Color {
        (dark ? color(18, 20, 26) : color(250, 250, 250)).opacity(0.82)
    }

    private static func readmeBackdrop(dark: Bool) -> LinearGradient {
        LinearGradient(colors: dark ? [color(26, 34, 48), color(43, 58, 82)]
                                   : [color(223, 230, 239), color(245, 247, 250)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private static func color(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255)
    }

    private static func writeReadmeImage(_ view: some View, scale: CGFloat, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let rendered = renderer.cgImage else { throw NSError(domain: "PanelRender", code: 1) }
        // Drop a partly covered last row or column (a fractional point size), which shows as a dark edge.
        let width = Int((CGFloat(rendered.width) / scale).rounded(.down) * scale)
        let height = Int((CGFloat(rendered.height) / scale).rounded(.down) * scale)
        guard let image = rendered.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)) else {
            throw NSError(domain: "PanelRender", code: 1)
        }
        try writePNG(image, to: url)
        print("\(url.lastPathComponent): \(image.width) × \(image.height) px at \(Int(scale))×")
    }
}

private struct MenuBarWidthComparison: View {
    let fleetItem: NSImage
    let localItem: NSImage
    let strip: Color

    private static let widthScale: CGFloat = 1.5
    // Status item button padding measured on macOS 27.
    private static let statusItemPadding: CGFloat = 2
    private static let labelWidth: CGFloat = 140
    // A 22 pt menu bar item at the same scale, plus room for the outline.
    private static let stripHeight: CGFloat = 22 * widthScale + 4
    private static let valueWidth: CGFloat = 58
    private static let columnSpacing: CGFloat = 14

    private struct MeasuredApp {
        let name: String
        var note: String?
        let span: CGFloat
        let items: [(offset: CGFloat, width: CGFloat)]
    }

    // Each app showing one Mac. Accessibility frames can overlap; offsets are
    // relative to the leftmost frame.
    private static let measuredApps: [MeasuredApp] = [
        .init(name: "MenuMeters", note: "No disk level", span: 41, items: [(0, 19), (17, 13), (28, 13)]),
        .init(name: "Stats", span: 65, items: [(0, 12.5), (11, 12.5), (22, 12.5), (33, 32)]),
        .init(name: "Vorssaint", span: 146, items: [(0, 146)])
    ]

    var body: some View {
        VStack(spacing: 0) {
            section("ONE MAC")
            squishedRow(item: localItem)
            ForEach(Self.measuredApps.sorted { $0.span < $1.span }, id: \.name) { app in
                row(app.name, note: app.note, span: app.span, valueColor: .primary) {
                    ZStack(alignment: .leading) {
                        ForEach(app.items.indices, id: \.self) { index in
                            let item = app.items[index]
                            // Inset each item slightly so neighbours read as separate items
                            // even where their measured frames overlap.
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.tertiary)
                                .frame(width: item.width * Self.widthScale - 2, height: Self.stripHeight)
                                .offset(x: item.offset * Self.widthScale + 1)
                        }
                    }
                    .frame(width: app.span * Self.widthScale, alignment: .leading)
                }
                .overlay(alignment: .top) { separator }
            }

            section("THREE MACHINES", note: "The other apps show one Mac only").padding(.top, 8)
            squishedRow(item: fleetItem)
        }
        .overlay {
            Canvas { context, size in
                let rightEdge = size.width - Self.valueWidth - Self.columnSpacing
                let guide = Path { path in
                    path.move(to: CGPoint(x: rightEdge, y: 0))
                    path.addLine(to: CGPoint(x: rightEdge, y: size.height))
                }
                context.stroke(guide, with: .color(.primary.opacity(0.18)),
                               style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(width: 560)
    }

    private var separator: some View {
        Rectangle().fill(.primary.opacity(0.10)).frame(height: 0.5)
    }

    private func section(_ title: String, note: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
            if let note {
                Text(note).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 26)
        .overlay(alignment: .bottom) { separator }
    }

    private func squishedRow(item: NSImage) -> some View {
        let span = item.size.width + Self.statusItemPadding
        let shape = RoundedRectangle(cornerRadius: 4)
        return row("Squished", note: nil, span: span, valueColor: .blue) {
            Image(nsImage: item)
                .resizable()
                .frame(width: item.size.width * Self.widthScale, height: item.size.height * Self.widthScale)
                .frame(width: span * Self.widthScale, height: Self.stripHeight)
                .background(strip, in: shape)
                .overlay { shape.strokeBorder(.blue, lineWidth: 1) }
        }
    }

    private func row(_ name: String, note: String?, span: CGFloat, valueColor: Color,
                     @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: Self.columnSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.labelWidth, alignment: .leading)

            content().frame(maxWidth: .infinity, alignment: .trailing)

            Text("\(FleetFormat.decimal(Double(span), digits: span.rounded() == span ? 0 : 1)) pt")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(valueColor)
                .frame(width: Self.valueWidth, alignment: .trailing)
        }
        .frame(height: 44)
    }
}

@MainActor private enum ReadmeDemo {
    private struct Machine {
        let name: String
        let label: String
        let info: HostInfo
        let cpu: Double
        let memory: Double
        let memoryGiB: Double
        let disks: [DiskUsage]
        let network: NetworkRate
        let load: LoadAverage
        let uptime: TimeInterval
        let processes: [(name: String, cpu: Double, memoryMiB: Double)]
    }

    static func store() throws -> FleetStore {
        let store = FleetStore(startServices: false)
        let now = Date(timeIntervalSince1970: 1_699_954_860)
        store.now = now
        store.settings.panelLayout = .extreme
        store.settings.showSimulators = false
        let machines = [
            Machine(name: "Mac", label: "MAC",
                    info: HostInfo(osName: "macOS", kernel: "Darwin", model: "Apple silicon", cpuCount: 8),
                    cpu: 23, memory: 64, memoryGiB: 32, disks: [disk("/", used: 749, total: 926)],
                    network: NetworkRate(rxPerSecond: 1.2 * 1_048_576, txPerSecond: 42 * 1024),
                    load: LoadAverage(2.14, 1.92, 1.64), uptime: 3 * 86400 + 4 * 3600,
                    processes: [("Xcode", 18.2, 3.1 * 1024), ("Safari", 6.4, 1.6 * 1024),
                                ("WindowServer", 4.1, 312), ("Mail", 1.9, 920)]),
            Machine(name: "homelab", label: "LAB",
                    info: HostInfo(osName: "Linux", kernel: "x86_64", cpuCount: 4),
                    cpu: 12, memory: 41, memoryGiB: 8,
                    disks: [disk("/", used: 31, total: 100), disk("/data", used: 640, total: 1000)],
                    network: NetworkRate(rxPerSecond: 18 * 1024, txPerSecond: 85 * 1024),
                    load: LoadAverage(0.51, 0.42, 0.38), uptime: 12 * 86400 + 7 * 3600,
                    processes: [("jellyfin", 7.9, 1.2 * 1024), ("postgres", 2.1, 640), ("node", 1.4, 410)]),
            Machine(name: "vps", label: "VPS",
                    info: HostInfo(osName: "Linux", kernel: "x86_64", cpuCount: 2),
                    cpu: 4, memory: 37, memoryGiB: 2, disks: [disk("/", used: 21, total: 50)],
                    network: NetworkRate(rxPerSecond: 6 * 1024, txPerSecond: 11 * 1024),
                    load: LoadAverage(0.09, 0.13, 0.16), uptime: 8 * 86400 + 2 * 3600,
                    processes: [("nginx", 1.8, 48), ("node", 1.1, 380), ("sshd", 0.2, 14), ("postgres", 0.08, 290)])
        ]
        store.hosts = machines.enumerated().map { index, machine in
            let local = index == 0
            let config = HostConfig(kind: local ? .local : .ssh(machine.name), displayName: machine.name, menuBarLabel: machine.label)
            let host = HostModel(config, interval: 2, persistPreferences: false)
            host.state = .live
            host.info = machine.info
            host.expanded = true
            let totalMemory = UInt64(machine.memoryGiB * 1_073_741_824)
            for tick in 0...150 {
                let time = Double(tick - 150) * 2
                let phase = Double(tick + index * 23)
                let taper = min(1, Double(150 - tick) / 12)
                let pulse = (1 + sin(phase / Double(12 + index * 2))) / 2
                let cpuWave = [21.0, 19, 16][index] * pulse - [10.0, 7, 2][index]
                    + 1.8 * cos(phase / 4.1) + 1.5 * sin(phase / 26)
                let memoryWave = 5.4 * sin(phase / Double(18 - index * 2))
                    + 2.3 * cos(phase / 9) + 1.6 * sin(phase / 31)
                let cpu = machine.cpu + taper * cpuWave
                let memory = machine.memory + taper * memoryWave
                host.receive(HostSnapshot(timestamp: now.addingTimeInterval(time),
                    cpu: CPUUsage(total: cpu, user: cpu * 0.75, system: cpu * 0.25),
                    memory: MemoryUsage(used: UInt64(Double(totalMemory) * memory / 100), total: totalMemory,
                                        pressure: local ? .normal : nil),
                    disks: machine.disks, network: machine.network, load: machine.load, uptime: machine.uptime))
            }
            let processes = machine.processes.enumerated().map { offset, row in
                let app = local && row.name != "WindowServer"
                return ProcessInput(pid: Int32(100 + offset),
                    executablePath: app ? "/Applications/\(row.name).app/Contents/MacOS/\(row.name)" : "/usr/bin/\(row.name)",
                    name: row.name, cpuPercent: row.cpu, memoryBytes: UInt64(row.memoryMiB * 1_048_576),
                    appName: app ? row.name : nil)
            }
            host.snapshot?.groups = ProcessGrouper.group(processes, platform: local ? .macOS : .linux).map { group in
                var demoGroup = group
                demoGroup.name = group.processes.first?.name ?? group.name
                // Real app icons where this Mac has the app; otherwise the generic symbol.
                let bundleIDs = ["Xcode": "com.apple.dt.Xcode", "Safari": "com.apple.Safari", "Mail": "com.apple.mail"]
                demoGroup.bundlePath = local ? bundleIDs[demoGroup.name]
                    .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path } : nil
                return demoGroup
            }
            return host
        }
        store.settings.hosts = store.hosts.map(\.config)
        store.feeds = try PanelVariantRenderer.fixtureFeeds(job: ["name": "Nightly backup", "status": "ok",
            "finishedAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(-6 * 3600)),
            "expectedEverySeconds": 86400])
        return store
    }

    private static func disk(_ mount: String, used: UInt64, total: UInt64) -> DiskUsage {
        DiskUsage(mount: mount, used: used * 1_073_741_824, total: total * 1_073_741_824)
    }
}
#endif
