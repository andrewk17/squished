import AppKit

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: FleetStore?
    private var controller: StatusItemController?
    static func main() {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(where: { $0 == "--render-panel-variants" || $0 == "--readme-images" }) {
            let mode = CommandLine.arguments[index]
            guard CommandLine.arguments.indices.contains(index + 1) else {
                fputs("Usage: \(mode) <directory>\n", stderr)
                exit(2)
            }
            let directory = CommandLine.arguments[index + 1]
            do {
                if mode == "--readme-images" { try PanelVariantRenderer.renderReadmeImages(to: directory) }
                else { try PanelVariantRenderer.render(to: directory) }
            }
            catch { fputs("Render failed: \(error)\n", stderr); exit(1) }
            return
        }
        #endif
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        TerminalLauncher.clean()
        let store = FleetStore()
        self.store = store
        controller = StatusItemController(store: store)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
        store?.stop()
    }
}
