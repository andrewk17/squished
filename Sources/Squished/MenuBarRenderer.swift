import AppKit
import SquishedCore

@MainActor
final class MenuBarRenderer {
    private var lastKey = ""
    private var cached: NSImage?
    func invalidate() { lastKey = "" }

    private struct DiskNumber {
        var partition: Int
        var text: String
    }

    private struct BlockLayout {
        var width: CGFloat
        var barsInset: CGFloat
        var numbersInset: CGFloat
    }

    private struct Entry {
        var label: String
        var steps: [Int] // half-point fill heights; zero means no fill
        var levels: [LoadLevel]
        var state: Int // live, stale, offline, connecting
        var freeSpace: [DiskNumber]
        var barY: CGFloat
        var barHeight: CGFloat
        var barsWidth: CGFloat { CGFloat(steps.count) * 3.5 + CGFloat(steps.count - 1) + (steps.count > 3 ? 1 : 0) }
        var numbers: String { freeSpace.map(\.text).joined(separator: " ") }
        func barOffset(_ index: Int) -> CGFloat {
            CGFloat(index) * 4.5 + (steps.count > 3 && index >= 2 ? 1 : 0)
        }
    }

    func accessibilityLabel(store: FleetStore) -> String {
        var parts = store.hosts.filter { $0.config.showInMenuBar }.map { host in
            let state: String
            switch host.state {
            case .offline: state = "offline" + (host.snapshot == nil ? "" : ", " + Self.metrics(host))
            case .connecting: state = "connecting" + (host.snapshot == nil ? "" : ", " + Self.metrics(host))
            case .stale: state = "stale, " + Self.metrics(host)
            case .live: state = Self.metrics(host)
            }
            return host.config.displayName + " " + state
        }
        if store.settings.showNetworkInMenuBar {
            let rate = store.hosts.first { $0.config.kind == .local }?.snapshot?.network
            parts.append("network up \(FleetFormat.rate(rate?.txPerSecond)), down \(FleetFormat.rate(rate?.rxPerSecond))")
        }
        parts += store.feeds.jobs.map { $0.name + " " + $0.title(at: store.now).lowercased() }
        return parts.isEmpty ? "Squished" : parts.joined(separator: "; ").replacingOccurrences(of: "%", with: " %")
    }
    private static func metrics(_ host: HostModel) -> String {
        let disks = host.snapshot?.disks.map { disk in
            let free = FleetFormat.bytes(disk.total > disk.used ? disk.total - disk.used : 0)
            return "disk \(disk.mount) \(FleetFormat.percent(disk.percent)), \(free) free"
        }.joined(separator: ", ") ?? "disk —"
        return "CPU \(FleetFormat.percent(host.snapshot?.cpu?.total)), memory \(FleetFormat.percent(host.snapshot?.memory?.percent)), \(disks)"
    }

    func image(store: FleetStore, appearance: NSAppearance? = nil) -> NSImage {
        let visibleHosts = store.hosts.filter { $0.config.showInMenuBar }
        let stacked = visibleHosts.contains { host in
            host.config.showFreeSpaceInMenuBar
                && (host.snapshot?.disks.prefix(2).contains { host.showsFreeSpace(for: $0) } ?? false)
        }
        let entries = visibleHosts.map { host -> Entry in
            let state: Int
            switch host.state {
            case .live: state = 0
            case .stale: state = 1
            case .offline: state = 2
            case .connecting: state = 3
            }
            let disks = Array((host.snapshot?.disks ?? []).prefix(2))
            let values: [Double?] = [host.snapshot?.cpu?.total, host.snapshot?.memory?.percent]
                + (disks.isEmpty ? [nil] : disks.map { Optional($0.percent) })
            let free: [DiskNumber] = host.config.showFreeSpaceInMenuBar ? disks.enumerated().compactMap { index, disk in
                guard host.showsFreeSpace(for: disk) else { return nil }
                return DiskNumber(partition: index, text: state >= 2 ? "–"
                    : FleetFormat.compactFreeSpace(disk.total > disk.used ? disk.total - disk.used : 0))
            } : []
            // Reserve the number row for the whole host if any partition shows one.
            let barY: CGFloat = stacked && !free.isEmpty ? 7.5 : 2
            let barHeight: CGFloat = (stacked ? 15 : 13) - barY
            return Entry(label: String(host.config.menuBarLabel.uppercased().prefix(4)),
                         steps: values.map {
                             let value = max(0, min(100, $0 ?? 0))
                             return state >= 2 || value == 0 ? 0 : max(2, Int((value * Double(barHeight) * 2 / 100).rounded()))
                         },
                         levels: [host.cpuLevel.level, host.memoryLevel]
                            + (disks.isEmpty ? [.normal] : disks.map { host.diskLevel(for: $0) }), state: state,
                         freeSpace: free, barY: barY, barHeight: barHeight)
        }
        let rate = store.hosts.first { $0.config.kind == .local }?.snapshot?.network
        let network = store.settings.showNetworkInMenuBar
            ? [FleetFormat.compactRate(rate?.txPerSecond), FleetFormat.compactRate(rate?.rxPerSecond)] : []
        let idle = [rate?.txPerSecond, rate?.rxPerSecond].map { ($0 ?? 0) < 5 * 1024 }
        // Red only for a job that failed; a late one is a calmer orange.
        let glyph = store.feeds.jobs.contains { $0.status == .failed } ? "hot"
            : store.feeds.jobs.contains { $0.showsMenuBarWarning(at: store.now) } ? "warn" : ""
        let key = (appearance?.name.rawValue ?? "") + "|\(stacked)|" + entries.map {
            // Only resolved colours matter when stale/offline, not hidden load levels.
            "\($0.label)|\($0.steps)|\($0.state)|\($0.state == 0 ? $0.levels.map(\.rawValue) : [])|\($0.freeSpace.map { "\($0.partition):\($0.text)" })"
        }.joined(separator: ";") + "|\(network)|\(network.isEmpty ? [] : idle)|\(glyph)"
        if lastKey == key, let cached { return cached }

        let labelFont = NSFont.systemFont(ofSize: stacked ? 7 : 7.5, weight: .bold, width: .condensed)
        let numberFont = Self.digitFont(size: 7.2)
        let rateFont = Self.digitFont(size: 7.7)
        let layouts = entries.map { entry -> BlockLayout in
            let labelWidth = Self.measure(entry.label, labelFont, kern: 0.3)
            let numberWidth = Self.measure(entry.numbers, numberFont)
            if entry.steps.count > 3, entry.freeSpace.count == 1, let number = entry.freeSpace.first {
                // A lone number belongs to its disk bar. Reserve only its actual
                // overhang so it cannot collide with a neighbouring host.
                let center = entry.barOffset(number.partition + 2) + 1.75
                let left = min(0, center - numberWidth / 2)
                let right = max(entry.barsWidth, center + numberWidth / 2)
                let width = max(labelWidth, right - left)
                let barsInset = (width - (right - left)) / 2 - left
                return BlockLayout(width: width, barsInset: barsInset,
                                   numbersInset: barsInset + center - numberWidth / 2)
            }
            let width = max(labelWidth, entry.barsWidth, numberWidth)
            return BlockLayout(width: width, barsInset: (width - entry.barsWidth) / 2,
                               numbersInset: (width - numberWidth) / 2)
        }
        let networkWidth = 6.5 + Self.measure("999K", rateFont)
        let machineWidth = layouts.reduce(0) { $0 + $1.width } + CGFloat(max(0, entries.count - 1)) * 4
        let width = machineWidth + (network.isEmpty ? 0 : (entries.isEmpty ? 0 : 4) + networkWidth)
            + (glyph.isEmpty ? 0 : (entries.isEmpty && network.isEmpty ? 0 : 3) + 11)
        let result = NSImage(size: NSSize(width: max(1, ceil(width)), height: 22), flipped: false) { _ in
            let draw = {
                var x: CGFloat = 0
                for (index, entry) in entries.enumerated() {
                    let layout = layouts[index]
                    let width = layout.width
                    let tint: NSColor = entry.state == 2 ? .tertiaryLabelColor : entry.state == 1 ? .secondaryLabelColor : .labelColor
                    let barsWidth = entry.barsWidth
                    let barsX = Self.snap(x + layout.barsInset)
                    let labelX = x + (width - Self.measure(entry.label, labelFont, kern: 0.3)) / 2
                    Self.text(entry.label, x: labelX, baseline: stacked ? 16.5 : 15, font: labelFont, color: tint, kern: 0.3)
                    for bar in entry.steps.indices {
                        let bx = Self.snap(barsX + entry.barOffset(bar))
                        let track = NSBezierPath(roundedRect: NSRect(x: bx, y: entry.barY, width: 3.5, height: entry.barHeight), xRadius: 1, yRadius: 1)
                        NSColor.labelColor.withAlphaComponent(0.2).setFill()
                        track.fill()
                        if entry.steps[bar] > 0 {
                            NSGraphicsContext.saveGraphicsState()
                            track.addClip()
                            (entry.state == 1 ? NSColor.secondaryLabelColor : Self.color(entry.levels[bar])).setFill()
                            NSRect(x: bx, y: entry.barY, width: 3.5, height: CGFloat(entry.steps[bar]) / 2).fill()
                            NSGraphicsContext.restoreGraphicsState()
                        }
                    }
                    if entry.state == 2 {
                        NSColor.tertiaryLabelColor.setStroke()
                        let slash = NSBezierPath()
                        slash.lineWidth = 1
                        slash.move(to: NSPoint(x: barsX, y: entry.barY))
                        slash.line(to: NSPoint(x: barsX + barsWidth, y: entry.barY + entry.barHeight))
                        slash.stroke()
                    }
                    var numberX = x + layout.numbersInset
                    for number in entry.freeSpace {
                        let color: NSColor = entry.state == 2 ? .tertiaryLabelColor : entry.state == 1 ? .secondaryLabelColor : Self.color(entry.levels[number.partition + 2])
                        Self.text(number.text, x: numberX, baseline: 1, font: numberFont, color: color)
                        numberX += Self.measure(number.text + " ", numberFont)
                    }
                    x += width + (index < entries.count - 1 ? 4 : 0)
                }
                if !network.isEmpty {
                    if !entries.isEmpty { x += 4 }
                    for row in 0..<2 {
                        let baseline: CGFloat = row == 0 ? 13 : 3
                        Self.arrow(up: row == 0, x: x, y: baseline,
                                   color: NSColor.labelColor.withAlphaComponent(idle[row] ? 0.4 : 0.7))
                        Self.text(network[row], x: x + networkWidth - Self.measure(network[row], rateFont),
                                  baseline: baseline, font: rateFont,
                                  color: NSColor.labelColor.withAlphaComponent(idle[row] ? 0.55 : 1))
                    }
                    x += networkWidth
                }
                if !glyph.isEmpty {
                    if !entries.isEmpty || !network.isEmpty { x += 3 }
                    let color = glyph == "hot" ? NSColor.systemRed : NSColor.systemOrange
                    // A plain warning triangle: the earlier clock-arrow symbol read as Time Machine.
                    if let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 9.5, weight: .semibold)) {
                        let size = symbol.size
                        let rect = NSRect(x: x + (11 - size.width) / 2, y: 11 - size.height / 2, width: size.width, height: size.height)
                        symbol.draw(in: rect)
                        color.setFill()
                        rect.fill(using: .sourceAtop)
                    }
                }
            }
            if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
            return true
        }
        result.isTemplate = false
        lastKey = key
        cached = result
        return result
    }
    private nonisolated static func snap(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
    private nonisolated static func digitFont(size: CGFloat) -> NSFont {
        let condensed = NSFont.systemFont(ofSize: size, weight: .semibold, width: .condensed)
        return NSFont(descriptor: condensed.fontDescriptor.addingAttributes([
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]
        ]), size: size) ?? condensed
    }
    private nonisolated static func measure(_ text: String, _ font: NSFont, kern: CGFloat = 0) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font, .kern: kern]).width - (text.isEmpty ? 0 : kern)
    }
    private nonisolated static func text(_ text: String, x: CGFloat, baseline: CGFloat, font: NSFont, color: NSColor, kern: CGFloat = 0) {
        (text as NSString).draw(at: NSPoint(x: x, y: baseline + font.descender),
                               withAttributes: [.font: font, .foregroundColor: color, .kern: kern])
    }
    private nonisolated static func arrow(up: Bool, x: CGFloat, y: CGFloat, color: NSColor) {
        let tip = up ? y + 5 : y, tail = up ? y : y + 5, head = up ? y + 2.6 : y + 2.4
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x + 2, y: tail))
        path.line(to: NSPoint(x: x + 2, y: tip))
        path.move(to: NSPoint(x: x + 0.2, y: head))
        path.line(to: NSPoint(x: x + 2, y: tip))
        path.line(to: NSPoint(x: x + 3.8, y: head))
        path.lineWidth = 0.9
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
    private nonisolated static func color(_ level: LoadLevel) -> NSColor {
        level == .high ? .systemRed : level == .elevated ? .systemOrange : .labelColor
    }
}
