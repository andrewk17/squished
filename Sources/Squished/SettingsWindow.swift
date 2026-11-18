import AppKit
import ServiceManagement
import SwiftUI
import SquishedCore

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: FleetStore
    init(store: FleetStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Squished Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 580))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(store:)")
    }

    func show() {
        if window?.contentViewController == nil {
            window?.contentViewController = NSHostingController(rootView: SettingsView(store: store))
        }

        if window?.isVisible != true {
            window?.center()
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
    }
}

struct SettingsView: View {
    @Bindable var store: FleetStore
    var body: some View {
        TabView {
            GeneralSettings(store: store).tabItem {
                Label("General", systemImage: "gearshape")
            }

            HostsSettings(store: store).tabItem {
                Label("Hosts", systemImage: "server.rack")
            }
        }.padding(12).frame(width: 520, height: 580)
    }
}

struct GeneralSettings: View {
    @Bindable var store: FleetStore
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var previewRenderer = MenuBarRenderer()
    private func binding<T>(_ key: WritableKeyPath<FleetSettings, T>) -> Binding<T> {
        Binding(
            get: {
                store.settings[keyPath: key]
            },
            set: { value in

                var updated = store.settings
                updated[keyPath: key] = value
                store.apply(updated)
            }

        )
    }

    var body: some View {
        Form {
            Section("Sampling") {
                Picker("Refresh interval", selection: binding(\.refreshInterval)) {
                    ForEach([1.0, 2, 3, 5], id: \.self) {
                        Text("\(Int($0)) seconds").tag($0)
                    }
                }
            }

            Section("Menu bar") {
                Toggle("Show network in menu bar", isOn: binding(\.showNetworkInMenuBar))
                HStack {
                    Text("Preview")
                    Spacer()

                    Image(nsImage: previewRenderer.image(store: store, appearance: NSApp.effectiveAppearance)).padding(
                        6
                    )
                }
            }

            Section("Panel") {
                Picker("Layout", selection: binding(\.panelLayout)) {
                    ForEach(PanelLayout.allCases, id: \.self) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                Toggle("Show Simulators and emulators", isOn: binding(\.showSimulators))
            }

            Section("Startup") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: {
                            loginStatus == .enabled || loginStatus == .requiresApproval
                        },
                        set: { enabled in

                            do {
                                if enabled {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }

                                loginError = nil
                            } catch {
                                loginError = error.localizedDescription
                            }

                            loginStatus = SMAppService.mainApp.status
                        }

                    )
                ).disabled(Bundle.main.bundleIdentifier == nil)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }

                Button("Open Login Items…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        }.formStyle(.grouped).onAppear {
            loginStatus = SMAppService.mainApp.status
        }.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in

            loginStatus = SMAppService.mainApp.status
        }
    }

    private var statusText: String {
        if Bundle.main.bundleIdentifier == nil {
            return "Run the packaged Squished.app to enable launch at login."
        }

        switch loginStatus {
        case .enabled: return "Enabled"
        case .requiresApproval: return "Allow Squished in System Settings → Login Items."
        case .notFound: return "Login item not found. Open the packaged app and try again."
        case .notRegistered: return "Disabled"
        @unknown default: return "Check Login Items in System Settings."
        }
    }
}

struct HostsSettings: View {
    @Bindable var store: FleetStore
    @State private var selected: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let local = store.settings.hosts.first(where: {
                $0.kind == .local
            }
            ) {
                GroupBox("Local Mac") {
                    HostEditor(store: store, host: local).padding(6)
                }
            }

            Text("Linux hosts · drag to reorder").font(.caption).foregroundStyle(.secondary)
            List(selection: $selected) {
                ForEach(
                    store.settings.hosts.filter { $0.kind != .local }
                ) { host in

                    HostEditor(store: store, host: host).padding(.vertical, 5).tag(host.id)
                }.onMove {
                    offsets,
                    destination in
                    var updated = store.settings
                    var remotes = updated.hosts.filter { $0.kind != .local }

                    remotes.move(fromOffsets: offsets, toOffset: destination)
                    updated.hosts =
                        updated.hosts.filter { $0.kind == .local }
                        + remotes
                    store.apply(updated)
                }
            }.listStyle(.inset).frame(maxHeight: .infinity)
            HStack {
                Button {
                    var updated = store.settings

                    let host = HostConfig(
                        kind: .ssh(""),
                        displayName: "Linux host",
                        menuBarLabel: "LINX",
                        enabled: false
                    )
                    updated.hosts.append(host)
                    selected = host.id
                    store.apply(updated)
                } label: {
                    Image(systemName: "plus")
                }.help("Add Linux host")
                Button {
                    guard let selected else {
                        return
                    }

                    var updated = store.settings
                    updated.hosts.removeAll {
                        $0.id == selected && $0.kind != .local
                    }

                    self.selected = nil

                    store.apply(updated)
                } label: {
                    Image(systemName: "minus")
                }.disabled(selected == nil).help("Remove selected host")
                Spacer()
                Text("Uses your ~/.ssh/config aliases and keys.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(8)
    }
}

struct HostEditor: View {
    @Bindable var store: FleetStore
    let host: HostConfig
    private func binding<T>(_ key: WritableKeyPath<HostConfig, T>) -> Binding<T> {
        Binding(
            get: {
                (store.settings.hosts.first {
                    $0.id == host.id
                }
                    ?? host)[keyPath: key]
            },
            set: { value in

                store.editHost(host.id) {
                    $0[keyPath: key] = value
                }
            }

        )
    }

    private enum Field: Hashable {
        case name, alias, label
    }

    @State private var draftName: String
    @State private var draftAlias: String
    @State private var draftLabel: String
    @FocusState private var focusedField: Field?

    init(store: FleetStore, host: HostConfig) {
        self.store = store
        self.host = host
        _draftName = State(initialValue: host.displayName)
        _draftLabel = State(initialValue: host.menuBarLabel)
        if case .ssh(let alias) = host.kind {
            _draftAlias = State(initialValue: alias)
        } else {
            _draftAlias = State(initialValue: "")
        }
    }

    private func commit(_ field: Field) {
        guard
            let current = store.settings.hosts.first(where: {
                $0.id == host.id
            }
            )
        else {
            return
        }

        switch field {
        case .name:
            if current.displayName != draftName {
                store.editHost(host.id) {
                    $0.displayName = draftName
                }
            }

        case .label:
            let label = String(draftLabel.prefix(4))
            if current.menuBarLabel != label {
                store.editHost(host.id) {
                    $0.menuBarLabel = label
                }
            }

        case .alias:
            if SSHCommand.validAlias(draftAlias), current.kind != .ssh(draftAlias) {
                store.editHost(host.id) {
                    $0.kind = .ssh(draftAlias)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if host.kind != .local {
                Toggle("Enabled", isOn: binding(\.enabled))
            }

            HStack {
                Text("Name").frame(width: 65, alignment: .leading)

                TextField("Display name", text: $draftName).focused($focusedField, equals: .name).onSubmit {
                    commit(.name)
                }
            }

            if host.kind != .local {
                HStack {
                    Text("SSH alias").frame(width: 65, alignment: .leading)

                    TextField("server", text: $draftAlias).focused($focusedField, equals: .alias).onSubmit {
                        commit(.alias)
                    }

                    Button("Test") {
                        commit(.alias)
                        var candidate = host
                        candidate.kind = .ssh(draftAlias)
                        store.test(candidate)
                    }.disabled(!SSHCommand.validAlias(draftAlias))
                }

                Picker("Refresh", selection: binding(\.refreshInterval)) {
                    Text("Default (\(Int(store.settings.refreshInterval)) s)").tag(nil as Double?)
                    ForEach([5.0, 10, 30], id: \.self) { interval in
                        Text("\(Int(interval)) s").tag(Optional(interval))
                    }
                }

                if !draftAlias.isEmpty && !SSHCommand.validAlias(draftAlias) {
                    Text("Use an SSH alias without spaces or shell characters.").font(.caption).foregroundStyle(.red)
                }

                if let result = store.testResults[host.id] {
                    Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            HStack {
                Text("Menu label").frame(width: 65, alignment: .leading)
                TextField("Up to 4 letters", text: $draftLabel).focused($focusedField, equals: .label).onSubmit {
                    commit(.label)
                }.frame(width: 85)
                Spacer()
                Toggle("Show in menu bar", isOn: binding(\.showInMenuBar))
            }
            Toggle("Free space in menu bar", isOn: binding(\.showFreeSpaceInMenuBar))
                .disabled(!host.showInMenuBar)
        }.font(.system(size: 11)).textFieldStyle(.roundedBorder)
            .onChange(of: focusedField) {
                previous,
                _ in
                if let previous {
                    commit(previous)
                }
            }.onChange(of: host) {
                _,
                updated in
                if focusedField != .name {
                    draftName = updated.displayName
                }

                if focusedField != .label {
                    draftLabel = updated.menuBarLabel
                }

                if focusedField != .alias, case .ssh(let alias) = updated.kind {
                    draftAlias = alias
                }
            }
    }
}
