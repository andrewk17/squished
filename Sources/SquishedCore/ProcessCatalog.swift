import Foundation

public enum ProcessCatalog {
    public struct Entry: Sendable { public var name, explanation: String; public var kind: ProcessGroupKind }
    private static let common: [(String, String, String)] = [("Squished", "Squished", "Resource monitor")]
    private static let mac: [(String, String, String)] = [
        ("mds mds_stores mdworker* corespotlightd", "Spotlight", "Indexing files for search"),
        ("STExtractionService ScreenTimeAgent", "Screen Time", "Reading app usage"),
        ("KaleidoscopePoster PhotosPosterProvider WallpaperAgent wallpaperd WallpaperVideoExtension", "Wallpaper & Lock Screen", "Drawing wallpaper and the Lock Screen"),
        ("diagnosticd logd ReportCrash spindump analyticsd tailspind osanalyticshelper diagnosticservicesd", "Diagnostics & logging", "Recording system diagnostics"),
        ("kernel_task", "macOS kernel (also slows the CPU when hot)", "Managing hardware and CPU temperature"),
        ("WindowServer", "Screen drawing", "Compositing windows on screen"),
        ("photoanalysisd mediaanalysisd photolibraryd PhotosCloudService", "Photos analysis", "Organizing and analyzing photos"),
        ("backupd backupd-helper", "Time Machine", "Backing up your Mac"),
        ("cloudd bird fileproviderd CloudPhotosConfiguration", "iCloud sync", "Syncing files with iCloud"),
        ("XprotectService XProtectService XProtectRemediator* syspolicyd trustd securityd", "Malware checks", "Checking software and security"),
        ("testmanagerd xctest XCTRunner", "Xcode test runner", "Running app tests"),
        ("coreaudiod audiomxd", "Audio", "Managing sound"),
        ("bluetoothd BlueTool", "Bluetooth", "Connecting Bluetooth devices"),
        ("airportd wifid configd mDNSResponder networkd nesessionmanager", "Networking", "Managing network connections"),
        ("powerd thermalmonitord", "Power & temperature", "Managing energy and cooling"),
        ("launchd runningboardd launchservicesd lsd", "App management", "Starting and managing apps"),
        ("cfprefsd distnoted notifyd", "System preferences", "Sharing settings and notifications"),
        ("softwareupdated installd storedownloadd appstoreagent", "Software updates", "Installing software and updates"),
        ("fontd fontworker", "Fonts", "Preparing fonts"),
        ("searchpartyd locationd", "Location & Find My", "Managing location services"),
        ("sharingd rapportd", "Nearby sharing", "Connecting nearby Apple devices"),
        ("tccd sandboxd", "Privacy & permissions", "Enforcing app permissions"),
    ]
    private static let linux: [(String, String, String)] = [
        ("dockerd containerd* docker-proxy runc buildkitd", "Docker", "Running containers"),
        ("kworker/* ksoftirqd/* kswapd* migration/* rcu_*", "Kernel workers", "Running Linux kernel work"),
        ("sshd ssh", "SSH", "Secure remote connections"),
        ("systemd-journald rsyslogd", "System log", "Recording system messages"),
        ("earlyoom", "Out-of-memory guard", "Protecting the machine when memory runs low"),
        ("snapd snap-confine", "Snap packages", "Managing Snap applications"),
        ("systemd systemd-udevd systemd-logind systemd-resolved systemd-networkd", "Linux system management", "Managing services and devices"),
        ("NetworkManager dhclient", "Networking", "Managing network connections"),
        ("cron crond atd", "Scheduled jobs", "Running scheduled tasks"),
        ("dbus-daemon dbus-broker", "System messaging", "Connecting system services"),
        ("udisksd", "Disks", "Managing storage devices"),
        ("polkitd", "Permissions", "Checking system permissions"),
        ("unattended-upgr apt apt-get dpkg", "Software updates", "Installing Linux packages"),
        ("btrfs-*", "Btrfs filesystem", "Maintaining filesystem data"),
    ]
    public static func lookup(_ executable: String, platform: ProcessPlatform) -> Entry? {
        for (patterns, name, explanation) in common + (platform == .macOS ? mac : linux) {
            for pattern in patterns.split(separator: " ").map(String.init) {
                if executable == pattern || (pattern.hasSuffix("*") && executable.hasPrefix(String(pattern.dropLast()))) {
                    let kind: ProcessGroupKind = name == "Docker" ? .docker : name.contains("kernel") || name == "Kernel workers" ? .kernel : .service
                    return Entry(name: name, explanation: explanation, kind: kind)
                }
            }
        }
        return nil
    }
}
