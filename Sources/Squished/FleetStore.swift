import AppKit
import Observation
import OSLog
import SquishedCore

@Observable @MainActor
final class HostModel: Identifiable {
    var config: HostConfig
    var info: HostInfo?
    var state: ConnectionState = .connecting
    var snapshot: HostSnapshot?
    var cpuHistory: HistoryBuffer<HistoryPoint>
    var memoryHistory: HistoryBuffer<HistoryPoint>
    var cpuLevel = LoadTracker()
    private var memoryLoad = LoadTracker()
    var memoryLevel: LoadLevel {
        switch snapshot?.memory?.pressure {
        case .normal?: return .normal
        case .warning?: return .elevated
        case .critical?: return .high
        case nil: return memoryLoad.level
        }
    }
    var diskLevel: LoadLevel = .normal
    private var partitionLevels: [String: LoadLevel] = [:]
    private var partitionFreeSpaceVisible: [String: Bool] = [:]

    func showsFreeSpace(for disk: DiskUsage) -> Bool {
        partitionFreeSpaceVisible[disk.mount] ?? (disk.percent >= 70)
    }

    func diskLevel(for disk: DiskUsage) -> LoadLevel {
        partitionLevels[disk.mount] ?? .disk(percent: disk.percent)
    }
    var traffic: TrafficLedger.Bucket?
    @ObservationIgnored var onSnapshot: ((HostSnapshot) -> Void)?
    nonisolated let id: UUID

    var expandedGroup: String?
    var showAllGroups = false
    private let persistPreferences: Bool
    var groupMemory: Bool {
        didSet { if persistPreferences { UserDefaults.standard.set(groupMemory, forKey: "groupMemory.\(id)") } }
    }
    var expanded: Bool {
        didSet {
            if persistPreferences { UserDefaults.standard.set(expanded, forKey: "expanded.\(id)") }
        }
    }

    init(_ config: HostConfig, interval: Double, persistPreferences: Bool = true) {
        self.persistPreferences = persistPreferences
        self.config = config
        id = config.id
        cpuHistory = HistoryBuffer(interval: interval)
        memoryHistory = HistoryBuffer(interval: interval)
        groupMemory = persistPreferences && UserDefaults.standard.bool(forKey: "groupMemory.\(config.id)")
        expanded = persistPreferences && UserDefaults.standard.bool(forKey: "expanded.\(config.id)")
    }

    func receive(_ snapshot: HostSnapshot) {
        self.snapshot = snapshot
        // Track each mount independently so changing the fullest disk cannot
        // carry one partition's warning colour over to another.
        var currentLevels: [String: LoadLevel] = [:]
        var currentVisibility: [String: Bool] = [:]
        for disk in snapshot.disks {
            currentLevels[disk.mount] = .disk(percent: disk.percent, previous: partitionLevels[disk.mount] ?? .normal)
            // Reveal at 30% free; keep showing until free space recovers above 33%.
            currentVisibility[disk.mount] = showsFreeSpace(for: disk) ? disk.percent >= 67 : disk.percent >= 70
        }
        partitionLevels = currentLevels
        partitionFreeSpaceVisible = currentVisibility
        diskLevel = snapshot.disk.map { diskLevel(for: $0) } ?? .normal
        onSnapshot?(snapshot)
        if let value = snapshot.cpu?.total {
            cpuHistory.append(HistoryPoint(date: snapshot.timestamp, value: value))
            cpuLevel.append(value)
        }

        if let value = snapshot.memory?.percent {
            memoryHistory.append(HistoryPoint(date: snapshot.timestamp, value: value))
            memoryLoad.append(value)
        }
    }

    func resizeHistory(interval: Double) {
        let cpu = cpuHistory.values, mem = memoryHistory.values
        cpuHistory = HistoryBuffer(interval: interval)
        memoryHistory = HistoryBuffer(interval: interval)
        for value in cpu.suffix(cpuHistory.capacity) {
            cpuHistory.append(value)
        }

        for value in mem.suffix(memoryHistory.capacity) {
            memoryHistory.append(value)
        }
    }
}

@Observable @MainActor
final class FleetStore {
    @ObservationIgnored private let logger = Logger(subsystem: "me.andrewkim.squished", category: "storage")
    var settings: FleetSettings
    var hosts: [HostModel] = []
    var now = Date()
    var simulators = SimulatorState()
    var simulatorSessions: [SimulatorSession] = []
    @ObservationIgnored private var sessionStore: SimulatorSessionStore?
    @ObservationIgnored private var nextSessionPrune = Date().addingTimeInterval(24 * 60 * 60)
    @ObservationIgnored private var simulatorWatcher: SimulatorWatcher?
    var feeds = FileFeeds()
    @ObservationIgnored private var feedWatcher: FileFeedWatcher?
    @ObservationIgnored private var ledger = TrafficLedger()
    var testResults: [UUID: String] = [:]
    @ObservationIgnored var onMenuChange: (() -> Void)?
    @ObservationIgnored private var panelIsVisible = false
    @ObservationIgnored private var local: LocalMacSampler?
    @ObservationIgnored private var remotes: [UUID: RemoteHostSampler] = [:]
    @ObservationIgnored private var tests: [UUID: SSHSession] = [:]
    @ObservationIgnored private var testTokens: [UUID: UUID] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var clock: Timer?
    init(startServices: Bool = true) {
        // Offscreen fixture rendering must not sample hosts, read feeds or touch saved settings.
        if !startServices {
            settings = FleetSettings()
            return
        }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "trafficLedger"),
           let saved = try? JSONDecoder().decode(TrafficLedger.self, from: data) { ledger = saved }
        settings = FleetSettings.load(from: defaults)

        // Always retain exactly one local host, first, even if a saved file was edited manually.
        let localHost =
            settings.hosts.first(where: {
                $0.kind == .local
            }
            )
            ?? HostConfig(kind: .local, displayName: "Mac", menuBarLabel: "MAC")
        settings.hosts =
            [localHost]
            + settings.hosts.filter { $0.kind != .local }

        settings.hosts[0].enabled = true
        let sessionsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Squished/simulator-sessions.json")
        do {
            let history = try SimulatorSessionStore(url: sessionsURL)
            sessionStore = history
            simulatorSessions = history.sessions
        } catch { logger.error("Could not load simulator history: \(error.localizedDescription, privacy: .public)") }
        feedWatcher = FileFeedWatcher(root: FileFeeds.defaultRoot) { [weak self] feeds in
            Task { @MainActor in
                self?.feeds = feeds
                self?.onMenuChange?()
            }
        }
        feedWatcher?.start()
        simulatorWatcher = SimulatorWatcher { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if self.simulators != state { self.simulators = state }
                self.local?.setDevices(state.devices)
            }
        }
        simulatorWatcher?.configure(open: false)
        apply(settings, persist: false)
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in

                Task { @MainActor in

                    self?.remotes.values.forEach { $0.suspend() }
                }
            }

        )
        observers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in

                Task { @MainActor in

                    self?.remotes.values.forEach { $0.wake() }
                }
            }

        )
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in

            Task { @MainActor in
                self?.ledger.rollOver(now: Date())
                self?.refreshTraffic()
                self?.persistLedger()
                self?.pruneSimulatorSessions()
            }
        }
    }

    func apply(_ newSettings: FleetSettings, persist: Bool = true) {
        let oldInterval = settings.refreshInterval
        settings = newSettings
        // Loading settings must not rewrite them just to materialize new defaults.
        if persist, let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "settings")
        }

        let enabled = settings.hosts.filter { $0.enabled || $0.kind == .local }

        for id in Array(remotes.keys)
        where !enabled.contains(where: {
            $0.id == id
        }
        ) {
            remotes.removeValue(forKey: id)?.stop()
        }

        let previous = hosts
        hosts = enabled.map { config in

            let interval = config.effectiveRefreshInterval(global: settings.refreshInterval)
            let model =
                previous.first(where: {
                    $0.id == config.id
                }
                ) ?? HostModel(config, interval: interval)
            let intervalChanged = model.config.effectiveRefreshInterval(global: oldInterval) != interval
            let changed = model.config.kind != config.kind
            model.config = config
            if changed || intervalChanged { ledger.resetBaseline(host: model.id.uuidString) }
            model.onSnapshot = { [weak self, weak model] snapshot in
                guard let self, let model else { return }
                self.now = snapshot.timestamp
                if let history = self.sessionStore {
                    do {
                        if try history.reconcile(hostID: model.id.uuidString, devices: snapshot.simulatorDevices,
                                                 at: snapshot.timestamp, fresh: snapshot.hasSimulatorSample) {
                            self.simulatorSessions = history.sessions
                        }
                    } catch { self.logger.error("Could not save simulator history: \(error.localizedDescription, privacy: .public)") }
                }
                if let counters = snapshot.networkCounters {
                    if snapshot.network == nil { self.ledger.resetBaseline(host: model.id.uuidString) }
                    self.ledger.record(host: model.id.uuidString, counters: counters, now: snapshot.timestamp)
                    model.traffic = self.ledger.buckets[model.id.uuidString]
                }
            }
            if intervalChanged {
                model.resizeHistory(interval: interval)
            }

            if case .local = config.kind {
                if model.state != .live {
                    model.state = .live
                }

                if local == nil || oldInterval != settings.refreshInterval {
                    local?.stop()
                    let sampler = LocalMacSampler(interval: settings.refreshInterval) {
                        [weak self, weak model] info, snapshot in

                        Task { @MainActor in

                            guard let self, let model else {
                                return
                            }

                            if model.info != info {
                                model.info = info
                            }

                            model.receive(snapshot)
                            self.onMenuChange?()
                        }
                    }

                    sampler.setDevices(simulators.devices)
                    sampler.setIncludesProcesses(panelIsVisible)
                    local = sampler
                    sampler.start()
                }
            } else if remotes[config.id] == nil || changed || intervalChanged {
                remotes.removeValue(forKey: config.id)?.stop()
                let sampler = RemoteHostSampler(model: model, interval: interval) { [weak self] in

                    self?.onMenuChange?()
                }

                remotes[config.id] = sampler
                sampler.start()
            }

            return model
        }

        onMenuChange?()
    }

    private func refreshTraffic() {
        for host in hosts { host.traffic = ledger.buckets[host.id.uuidString] }
    }
    private func pruneSimulatorSessions() {
        let date = Date()
        guard date >= nextSessionPrune, let history = sessionStore else { return }
        do {
            if try history.prune(at: date) { simulatorSessions = history.sessions }
            nextSessionPrune = date.addingTimeInterval(24 * 60 * 60)
        } catch { logger.error("Could not prune simulator history: \(error.localizedDescription, privacy: .public)") }
    }
    private func persistLedger() {
        if let data = try? JSONEncoder().encode(ledger) { UserDefaults.standard.set(data, forKey: "trafficLedger") }
    }

    func setPanelVisible(_ visible: Bool) {
        guard panelIsVisible != visible else { return }
        panelIsVisible = visible
        simulatorWatcher?.configure(open: visible)
        if visible { now = Date() }
        local?.setIncludesProcesses(visible)
    }

    func editHost(_ id: UUID, _ edit: (inout HostConfig) -> Void) {
        var updated = settings
        guard
            let index = updated.hosts.firstIndex(where: {
                $0.id == id
            }
            )
        else {
            return
        }

        edit(&updated.hosts[index])
        apply(updated)
    }

    func retry(_ id: UUID) {
        remotes[id]?.retry()
    }

    func test(_ host: HostConfig) {
        guard case .ssh(let alias) = host.kind else {
            return
        }

        tests.removeValue(forKey: host.id)?.terminate()
        testResults[host.id] = "Testing…"
        let token = UUID()
        testTokens[host.id] = token
        let session = SSHSession(
            onFrame: { [weak self] frame in

                guard let info = frame.info else {
                    return
                }

                Task { @MainActor in

                    guard let self, self.testTokens[host.id] == token else {
                        return
                    }

                    self.testResults[host.id] =
                        info.osName == "Linux"
                        ? "OK · Linux \(info.kernel) · \(info.cpuCount) cores" : "Unsupported OS: \(info.osName)"
                    self.testTokens[host.id] = nil
                    self.tests.removeValue(forKey: host.id)?.terminate()
                }
            },
            onExit: { [weak self] status, stderr in

                Task { @MainActor in

                    guard let self, self.testTokens[host.id] == token else {
                        return
                    }

                    self.testResults[host.id] = ConnectionMachine.reason(status: status, stderr: stderr)
                    self.testTokens[host.id] = nil
                    self.tests.removeValue(forKey: host.id)?.terminate()
                }
            }

        )
        tests[host.id] = session
        session.start(alias: alias, interval: 1)
        Task { @MainActor [weak self] in

            try? await Task.sleep(for: .seconds(11))
            guard let self, self.testTokens[host.id] == token else {
                return
            }

            self.testResults[host.id] = "Timed out"
            self.testTokens[host.id] = nil
            self.tests.removeValue(forKey: host.id)?.terminate()
        }
    }

    func stop() {
        ledger.rollOver(now: Date())
        persistLedger()
        feedWatcher?.stop()
        simulatorWatcher?.stop()
        clock?.invalidate()
        local?.stop()
        remotes.values.forEach { $0.stop() }

        tests.values.forEach { $0.terminateAndWait() }

        remotes.removeAll()
        tests.removeAll()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }

        observers.removeAll()
    }
}
