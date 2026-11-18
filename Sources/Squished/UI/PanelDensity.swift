import SwiftUI
import SquishedCore

// Keep the geometry's existing density names while settings own the persisted choice.
typealias PanelDensity = PanelLayout
extension PanelLayout {
    var panelPadding: CGFloat { switch self { case .current: 12; case .medium: 10; case .high: 10; case .extreme: 6 } }
    var horizontalPadding: CGFloat { switch self { case .current: 10; case .medium: 9; case .high: 9; case .extreme: 7 } }
    var verticalPadding: CGFloat { switch self { case .current: 9; case .medium: 7; case .high: 7; case .extreme: 5 } }
    var spacing: CGFloat { switch self { case .current: 8; case .medium: 6; case .high: 6; case .extreme: 4 } }
    var tubeHeight: CGFloat { switch self { case .current: 44; case .medium: 32; case .high: 24; case .extreme: 3 } }
    var heroSize: CGFloat { switch self { case .current: 15; case .medium: 14; case .high: 12.5; case .extreme: 10.5 } }
    var processLimit: Int { self == .medium || self == .current ? 5 : 3 }
}
private struct PanelDensityKey: EnvironmentKey { static let defaultValue = PanelDensity.extreme }
private struct PanelRenderKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var panelDensity: PanelDensity {
        get { self[PanelDensityKey.self] }
        set { self[PanelDensityKey.self] = newValue }
    }
    var renderingPanel: Bool {
        get { self[PanelRenderKey.self] }
        set { self[PanelRenderKey.self] = newValue }
    }
}
