#if DEBUG
import AppKit
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import SquishedCore

/// No connection, timers or persisted app settings are used by this render path.
@MainActor enum PanelVariantRenderer {
    static func render(to directory: String) throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = try fixtures()
        if CommandLine.arguments.contains("--fixture-show-all") {
            for host in store.hosts { host.showAllGroups = true }
        }
        if CommandLine.arguments.contains("--fixture-no-process-memory") {
            for index in store.hosts[1].snapshot?.groups.indices ?? 0..<0 {
                store.hosts[1].snapshot?.groups[index].memoryBytes = 0
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--fixture-state"), CommandLine.arguments.indices.contains(index + 1) {
            let host = store.hosts[1]
            switch CommandLine.arguments[index + 1] {
            case "offline": host.state = .offline(reason: "Connection timed out", retryAt: store.now.addingTimeInterval(8))
            case "stale":
                host.state = .stale(since: store.now.addingTimeInterval(-16))
                host.snapshot?.timestamp = store.now.addingTimeInterval(-16)
            case "connecting": host.state = .connecting
            default: throw NSError(domain: "PanelRender", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unknown fixture state"])
            }
        }
        if CommandLine.arguments.contains("--menu-bar-glyphs") {
            try renderMenuBarGlyphs(store: store, to: url.appendingPathComponent("menubar-glyphs.png"))
            return
        }
        let variants: [(PanelDensity, ColorScheme, String)] = PanelDensity.allCases.map { ($0, .dark, $0.rawValue) }
            + [(.high, .light, "high-light"), (.extreme, .light, "extreme-light")]
        let originalDisks = store.hosts[1].snapshot?.disks
        let originalNetwork = store.hosts[1].snapshot?.network
        var sizes: [String: Double] = [:]
        for (density, scheme, name) in variants {
            store.hosts[1].snapshot?.network = originalNetwork
            if let originalDisks { store.hosts[1].snapshot?.disks = originalDisks }
            if density == .extreme {
                store.hosts[1].snapshot?.network = NetworkRate(rxPerSecond: 71 * 1024, txPerSecond: 331 * 1024)
                store.hosts[1].snapshot?.disks[0] = DiskUsage(mount: "/", used: 10 * 1_073_741_824,
                                                            total: 100 * 1_073_741_824, percent: 10)
            }
            store.settings.panelLayout = density
            let panel = HostedPanelView(store: store, settings: {}, maximumHeight: .greatestFiniteMagnitude)
                .environment(\.renderingPanel, true)
                .environment(\.colorScheme, scheme)
                // SwiftUI exposes the writable contrast hook under this name.
                .environment(\._colorSchemeContrast, CommandLine.arguments.contains("--fixture-increase-contrast") ? .increased : .standard)
                .foregroundStyle(scheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.88))
                .tint(Color(red: 0.05, green: 0.52, blue: 1))
                .background(scheme == .dark ? Color(red: 0.13, green: 0.22, blue: 0.36) : Color(red: 0.88, green: 0.92, blue: 0.96))
            let renderer = ImageRenderer(content: panel)
            renderer.proposedSize = ProposedViewSize(width: 340, height: nil)
            renderer.scale = 2
            guard let rendered = renderer.cgImage else { throw NSError(domain: "PanelRender", code: 1) }
            try writePNG(rendered, to: url.appendingPathComponent(name + ".png"))
            let height = Double(rendered.height) / 2
            sizes[name] = height
            print("\(name): 340 × \(height) pt (2×)")
        }
        try verifyLiveLayout(store: store)
        try captureSettings(store: store, to: url.appendingPathComponent("settings.png"))
        try JSONSerialization.data(withJSONObject: sizes, options: [.prettyPrinted, .sortedKeys])
            .write(to: url.appendingPathComponent("heights.json"))
    }

    private static func verifyLiveLayout(store: FleetStore) throws {
        store.settings.panelLayout = .extreme
        let host = NSHostingView(rootView:
            HostedPanelView(store: store, settings: {}, maximumHeight: .greatestFiniteMagnitude)
                .environment(\.renderingPanel, true))
        let compact = host.fittingSize.height
        store.settings.panelLayout = .current
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        let roomy = host.fittingSize.height
        store.settings.panelLayout = .extreme
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        guard roomy > compact, abs(host.fittingSize.height - compact) < 1 else {
            throw NSError(domain: "PanelRender", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Hosted panel did not update live with Layout"])
        }
        print("Live Layout: Compact \(compact) → Roomy \(roomy) → Compact \(host.fittingSize.height) pt")
    }

    private static func captureSettings(store: FleetStore, to url: URL) throws {
        // Form/TabView contain AppKit controls that ImageRenderer cannot draw.
        // Capture our own real fixture window, then close it before returning.
        let controller = SettingsWindowController(store: store)
        controller.show()
        guard let window = controller.window else { throw NSError(domain: "PanelRender", code: 6) }
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0 else {
            throw NSError(domain: "PanelRender", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Settings window capture failed"])
        }
        print("Settings: live fixture window captured")
    }

    private static func renderMenuBarGlyphs(store: FleetStore, to url: URL) throws {
        // One row: failed, overdue (dark menu bar), then failed, overdue (light).
        let scale: CGFloat = 6, rowHeight: CGFloat = 30, columnWidth: CGFloat = 125
        let size = NSSize(width: columnWidth * 4, height: rowHeight)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw NSError(domain: "PanelRender", code: 8)
        }
        rep.size = size // before the context exists, so drawing is in points at this scale
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { throw NSError(domain: "PanelRender", code: 8) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: columnWidth * 2, height: size.height).fill()
        NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
        NSRect(x: columnWidth * 2, y: 0, width: columnWidth * 2, height: size.height).fill()
        do {
            for column in 0..<4 {
                if column % 2 == 0 { store.feeds.jobs[0].status = .failed } else {
                    store.feeds.jobs[0].status = .ok
                    store.feeds.jobs[0].finishedAt = store.now.addingTimeInterval(-3 * 3600)
                }
                let image = MenuBarRenderer().image(store: store, appearance: NSAppearance(named: column < 2 ? .darkAqua : .aqua))
                image.draw(in: NSRect(x: CGFloat(column) * columnWidth + 10, y: 4,
                                      width: image.size.width, height: image.size.height))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "PanelRender", code: 9) }
        try data.write(to: url)
        print("menubar-glyphs.png: failed, overdue (dark), failed, overdue (light)")
    }

    static func writePNG(_ rendered: CGImage, to url: URL) throws {
        guard let context = CGContext(data: nil, width: rendered.width, height: rendered.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "PanelRender", code: 1)
        }
        // Encode 8-bit sRGB: extended-linear 16-bit PNGs display grey in some image viewers.
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
        guard let cgImage = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "PanelRender", code: 2)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "PanelRender", code: 3) }
    }

    private static func fixtures() throws -> FleetStore {
        let store = FleetStore(startServices: false)
        let now = Date(timeIntervalSince1970: 1_794_830_400)
        store.now = now
        store.settings.showSimulators = false
        let gb = 1_073_741_824.0
        func bytes(_ value: Double) -> UInt64 { UInt64(value * gb) }
        let stress = CommandLine.arguments.contains("--fixture-process-stress")
        let names = ["Mac", stress ? "server-with-a-very-long-hostname-production" : "server", "vps"]
        store.hosts = names.enumerated().map { index, name in
            let config = HostConfig(kind: index == 0 ? .local : .ssh(name), displayName: name, menuBarLabel: name.uppercased())
            let host = HostModel(config, interval: 2, persistPreferences: false)
            host.expanded = true
            host.groupMemory = false
            host.info = index == 0 ? HostInfo(osName: "macOS", kernel: "Darwin", model: "Apple silicon", cpuCount: 8)
                : HostInfo(osName: "Linux", kernel: "x86_64", cpuCount: index == 1 ? 4 : 2)
            host.state = .live
            let cpu = [29.0, 1, 7][index], memory = [25.3, 2.8, 0.8][index], total = [32.0, 30.2, 4][index]
            let disks = index == 0 ? [DiskUsage(used: bytes(749), total: bytes(926), percent: 81)]
                : index == 1 ? [DiskUsage(mount: "/", used: bytes(9), total: bytes(100), percent: 9),
                                DiskUsage(mount: "/home", used: bytes(148), total: bytes(800), percent: 19)]
                : [DiskUsage(used: bytes(12), total: bytes(80), percent: 15)]
            for tick in 0...150 {
                let wave = sin(Double(tick) * 0.67) * (index == 0 ? 6 : 0.7) + cos(Double(tick) * 1.71) * (index == 0 ? 3 : 0.2)
                host.receive(HostSnapshot(timestamp: now.addingTimeInterval(Double(tick - 150) * 2),
                    cpu: CPUUsage(total: tick == 150 ? cpu : max(0, cpu + wave), user: cpu * 0.7, system: cpu * 0.3),
                    memory: MemoryUsage(used: bytes(memory + (tick == 150 ? 0 : sin(Double(tick) * 0.08) * 0.12)), total: bytes(total), pressure: index == 0 ? .normal : nil),
                    disks: disks, network: NetworkRate(rxPerSecond: [43 * 1024, 2 * 1024, 8 * 1024][index], txPerSecond: [33 * 1024, 2 * 1024, 3 * 1024][index]),
                    load: index == 0 ? LoadAverage(6.26, 4.19, 3.01) : LoadAverage(0.14, 0.2, 0.18),
                    uptime: index == 0 ? 12 * 86400 + 19 * 3600 : 8 * 86400 + 4 * 3600))
            }
            host.snapshot?.groups = processFixtures(mac: index == 0)
            var ledger = TrafficLedger()
            ledger.record(host: name, counters: NetworkCounters(), now: now)
            ledger.record(host: name, counters: NetworkCounters(rxBytes: index == 0 ? bytes(2) : 244 * 1_048_576,
                                                               txBytes: index == 0 ? bytes(1) : 100 * 1_048_576), now: now)
            host.traffic = ledger.buckets[name]
            return host
        }
        store.settings.hosts = store.hosts.map(\.config)
        let jobState = CommandLine.arguments.firstIndex(of: "--fixture-job").flatMap {
            CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil
        }
        store.feeds = try fixtureFeeds(job: ["name": "Weekly backup", "status": jobState == "failed" ? "failed" : "ok",
            "finishedAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(jobState == "overdue" ? -3 * 3600 : -14 * 60)),
            "durationSeconds": 48, "message": "Weekly check passed 1 d ago", "expectedEverySeconds": 3600,
            "logPath": "/tmp/backup-fixture.log"])
        return store
    }

    static func fixtureFeeds(job: [String: Any]) throws -> FileFeeds {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("squished-render-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("jobs"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: job).write(to: root.appendingPathComponent("jobs/backup.json"))
        return FileFeeds.read(root: root)
    }

    private static func processFixtures(mac: Bool) -> [ProcessGroup] {
        var inputs: [ProcessInput] = []
        let rows: [(String, Double, Int)] = mac ? [("Safari", 29.2, 51), ("Squished", 13.3, 1),
            ("spotlightknowledged.updater", 12.4, 1), ("Mail", 11.5, 1), ("Maps", 5.7, 9)]
            : [("node", 0.7, 3), ("sshd", 0.3, 1), ("systemd", 0.2, 1), ("dockerd", 0.1, 1), ("cron", 0.05, 1)]
        for (index, row) in rows.enumerated() {
            let (name, cpu, count) = row
            let memory = CommandLine.arguments.contains("--fixture-process-stress")
                ? [2_254_857_830, 671_088_640, 7_945_689_498, 157_286_400, 943_718_400][index] : 50_000_000
            for _ in 0..<count {
                let app = mac && name != "spotlightknowledged.updater"
                inputs.append(ProcessInput(pid: Int32(inputs.count + 100),
                    executablePath: app ? "/Applications/\(name).app/Contents/MacOS/\(name)" : "/usr/libexec/\(name)",
                    name: name, cpuPercent: cpu / Double(count), memoryBytes: UInt64(memory / count), appName: app ? name : nil))
            }
        }
        if mac {
            for index in 0..<450 {
                inputs.append(ProcessInput(pid: Int32(1000 + index), executablePath: "/usr/libexec/background-\(index)",
                    name: "background-\(index)", cpuPercent: 0, memoryBytes: 100_000))
            }
        }
        return ProcessGrouper.group(inputs, platform: mac ? .macOS : .linux)
    }
}
#endif
