import AppKit
import SquishedCore

@MainActor
enum TerminalLauncher {
    private static let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "Squished-commands",
        isDirectory: true
    )
    static func clean() {
        // Only remove this app's generated commands, never the surrounding temp directory.
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "command" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func open(_ host: HostConfig) {
        do {
            let command: String
            switch host.kind {
            case .local:
                command =
                    "if [ -x /opt/homebrew/bin/btop ]; then exec /opt/homebrew/bin/btop; "
                    + "elif [ -x /usr/local/bin/btop ]; then exec /usr/local/bin/btop; "
                    + "else exec /usr/bin/top -o cpu; fi"
            case .ssh(let alias):
                guard SSHCommand.validAlias(alias) else {
                    throw SSHCommand.ValidationError.invalidAlias
                }

                command =
                    "exec /usr/bin/ssh -t -- " + SSHCommand.quote(alias) + " "
                    + SSHCommand.quote("command -v btop >/dev/null && exec btop || exec top")
            }

            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let file = directory.appendingPathComponent(UUID().uuidString + ".command")
            try ("#!/bin/sh\n" + command + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw CocoaError(.fileNoSuchFile)
            }

            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            {
                _,
                error in
                if let error {
                    Task { @MainActor in
                        NSAlert(error: error).runModal()
                    }
                }
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
