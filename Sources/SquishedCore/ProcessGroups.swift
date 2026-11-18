import Foundation

public enum ProcessPlatform: Sendable { case macOS, linux }
public enum ProcessGroupKind: String, Sendable { case simulator, app, interpreter, service, tool, kernel, docker }
public struct ProcessInput: Sendable, Equatable {
    public var pid, ppid: Int32
    public var startTime: UInt64 // Unix microseconds; zero when unknown
    public var executablePath, name: String
    public var arguments: [String]
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var appName: String?
    public init(pid: Int32, ppid: Int32 = 0, startTime: UInt64 = 0, executablePath: String = "", name: String,
                arguments: [String] = [], cpuPercent: Double = 0, memoryBytes: UInt64 = 0, appName: String? = nil) {
        self.pid = pid; self.ppid = ppid; self.startTime = startTime; self.executablePath = executablePath
        self.name = name; self.arguments = arguments; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes; self.appName = appName
    }
}
public struct ProcessGroup: Sendable, Equatable, Identifiable {
    public var id, name, subtitle: String
    public var kind: ProcessGroupKind
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var processCount: Int
    public var processes: [ProcessInput]
    public var bundlePath: String?
    public var deviceID: String?
    public var startedAt: Date? = nil
    public var symbol: String {
        switch kind { case .simulator: return "iphone"; case .app: return "app"; case .service: return "gearshape"
        case .kernel: return "cpu"; case .docker: return "shippingbox"; default: return "terminal" }
    }
}
public enum ProcessGrouper {
    public static func outermostApp(_ path: String) -> String? {
        guard !path.hasPrefix("/System/Library/Frameworks/"), !path.hasPrefix("/System/Library/PrivateFrameworks/") else { return nil }
        let parts = path.split(separator: "/")
        guard let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + parts[...i].joined(separator: "/")
    }
    public static func isInterpreter(_ name: String) -> Bool {
        ["node", "bun", "deno", "npx", "ruby", "java", "perl", "php", "sh", "bash", "zsh"].contains(name) || name.hasPrefix("python")
    }
    public static func scriptName(_ arguments: [String]) -> String? {
        let args = Array(arguments.dropFirst())
        for (i, arg) in args.enumerated() {
            if arg == "-m", i + 1 < args.count { return args[i + 1] }
            if arg == "-c" || arg == "-e" { return nil }
            if arg.hasPrefix("-") { continue }
            let parts = arg.split(separator: "/").map(String.init)
            var base = parts.last ?? arg
            if base == "index.js" || base == "cli.js", parts.count > 1 { base = parts[parts.count - 2] }
            for suffix in [".js", ".mjs", ".cjs", ".py", ".rb", ".sh", ".jar"] where base.hasSuffix(suffix) { base = String(base.dropLast(suffix.count)) }
            if let at = base.dropFirst().firstIndex(of: "@") { base = String(base[..<at]) }
            return base.isEmpty ? nil : base
        }
        return nil
    }
    public static func group(_ inputs: [ProcessInput], platform: ProcessPlatform, devices: [SimulatorDevice] = []) -> [ProcessGroup] {
        let byPID = Dictionary(inputs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var roots: [Int32: String] = [:]
        for p in inputs where p.name == "launchd_sim" {
            let text = p.arguments.joined(separator: " ")
            if let range = text.range(of: "/CoreSimulator/Devices/") {
                roots[p.pid] = String(text[range.upperBound...].prefix(while: { $0 != "/" && !$0.isWhitespace }))
            } else { roots[p.pid] = "pid-\(p.pid)" }
        }
        var result: [String: ProcessGroup] = [:]
        for p in inputs {
            var key = "plain:\(p.name)", name = p.name, subtitle = "", kind = ProcessGroupKind.tool
            var bundle: String?, device: String?
            var ancestor = p.pid, visited = Set<Int32>()
            if platform == .macOS {
                while ancestor > 0, visited.insert(ancestor).inserted {
                    if let root = roots[ancestor] { device = root; break }
                    ancestor = byPID[ancestor]?.ppid ?? 0
                }
            }
            if let id = device {
                let d = devices.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
                key = "sim:\(id)"; name = "Simulator · \(d?.name ?? id)"; subtitle = d?.runtime ?? "iOS Simulator"; kind = .simulator
            } else if ["SimMetalHost", "CoreSimulatorService", "simdiskimaged", "SimulatorTrampoline"].contains(p.name), platform == .macOS {
                key = "sim-services"; name = "Simulator · services"; subtitle = "Simulator support services"; kind = .simulator
            } else if (p.name.hasPrefix("qemu-system-") || p.name.hasPrefix("emulator")), let i = p.arguments.firstIndex(of: "-avd"), i + 1 < p.arguments.count {
                let avd = p.arguments[i + 1]; key = "android:\(avd)"; name = "Android emulator · \(avd)"; subtitle = "Android emulator"; kind = .simulator
            } else if platform == .macOS, let app = outermostApp(p.executablePath) {
                key = "app:\(app)"; bundle = app; name = p.appName ?? URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent; subtitle = "App"; kind = .app
            } else if isInterpreter(p.name), let script = scriptName(p.arguments) {
                key = "interp:\(p.name):\(script)"; name = script; subtitle = p.name; kind = .interpreter
            } else if let entry = ProcessCatalog.lookup(p.name, platform: platform) {
                key = "catalog:\(entry.name)"; name = entry.name; subtitle = entry.explanation; kind = entry.kind
            } else if p.name == "Squished" { name = "Squished"; subtitle = "Resource monitor"
            } else if platform == .linux && (p.pid == 2 || p.ppid == 2 || p.name == "[kernel]") {
                key = "kernel"; name = "Kernel workers"; subtitle = "Linux kernel work"; kind = .kernel
            } else if ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains(where: { p.executablePath.hasPrefix($0) }) {
                subtitle = platform == .macOS ? "macOS service" : "Linux service"; kind = .service
            } else {
                subtitle = (p.executablePath as NSString).deletingLastPathComponent
                if subtitle.contains("/Cellar/") || subtitle.hasPrefix("/opt/homebrew/") { subtitle = "Homebrew" }
                if let range = subtitle.range(of: "/.local/bin") { subtitle = "~" + subtitle[range.lowerBound...] }
            }
            var g = result[key] ?? ProcessGroup(id: key, name: name, subtitle: subtitle, kind: kind, cpuPercent: 0, memoryBytes: 0, processCount: 0, processes: [], bundlePath: bundle, deviceID: device)
            g.cpuPercent += max(0, p.cpuPercent); g.memoryBytes = g.memoryBytes &+ p.memoryBytes; g.processCount += 1; g.processes.append(p)
            if p.startTime > 0 {
                let started = Date(timeIntervalSince1970: Double(p.startTime) / 1_000_000)
                g.startedAt = min(g.startedAt ?? started, started)
            }
            result[key] = g
        }
        return result.values.map { original in
            var g = original
            if [.app, .interpreter, .simulator].contains(g.kind) { g.subtitle += " · \(g.processCount) processes" }
            return g
        }.sorted { $0.cpuPercent == $1.cpuPercent ? $0.id < $1.id : $0.cpuPercent > $1.cpuPercent }
    }
}
