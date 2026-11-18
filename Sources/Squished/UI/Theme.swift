import SwiftUI
import SquishedCore

enum Theme {
    static func ok(_ s: ColorScheme) -> Color {
        s == .dark ? .green : Color(red: 0, green: 0.44, blue: 0.18)
    }

    static func warn(_ s: ColorScheme) -> Color {
        s == .dark ? .yellow : Color(red: 0.56, green: 0.36, blue: 0)
    }

    static func resourceWarning(_ s: ColorScheme) -> Color {
        s == .dark ? .orange : Color(red: 0.65, green: 0.32, blue: 0)
    }

    static func hot(_ s: ColorScheme) -> Color {
        s == .dark ? .red : Color(red: 0.68, green: 0.08, blue: 0.10)
    }

    static func memory(_ s: ColorScheme) -> Color {
        s == .dark ? .mint : Color(red: 0, green: 0.44, blue: 0.40)
    }

    static func control(_ s: ColorScheme) -> Color {
        s == .dark ? .white.opacity(0.085) : .black.opacity(0.055)
    }

    static func card(_ s: ColorScheme) -> Color {
        s == .dark ? .white.opacity(0.075) : .white.opacity(0.38)
    }

    static func border(_ s: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        s == .dark
            ? .white.opacity(contrast == .increased ? 0.28 : 0.11)
            : .black.opacity(contrast == .increased ? 0.24 : 0.09)
    }

    static func meter(_ level: LoadLevel, _ scheme: ColorScheme, usesCPUWarning: Bool = false) -> Color {
        switch level {
        case .normal: return .primary
        case .elevated: return usesCPUWarning ? warn(scheme) : resourceWarning(scheme)
        case .high: return hot(scheme)
        }
    }

    static let caption = Font.system(size: 10, weight: .semibold)
    static let fine = Font.system(size: 10)
}

struct SectionCaption: View {
    let title: String
    var body: some View {
        Text(title).font(Theme.caption).kerning(0.5).foregroundStyle(.secondary)
    }
}

struct HoverFill: ViewModifier {
    var horizontalPadding: CGFloat = 4
    var verticalPadding: CGFloat = 2
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.padding(.horizontal, horizontalPadding).padding(.vertical, verticalPadding)
            .background(hovering ? Theme.control(scheme) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .onHover {
                hovering = $0
            }
    }
}

struct ChipStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 6)
            .background(
                Theme.control(scheme).opacity(configuration.isPressed ? 1.8 : 1),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .modifier(HoverFill())
    }
}

struct PanelSurface: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var tint: Color {
        scheme == .dark ? .black.opacity(0.42) : .white.opacity(0.68)
    }

    @ViewBuilder var body: some View {
        if #available(macOS 26.0, *) {
            if reduceTransparency {
                Rectangle().fill(.regularMaterial).overlay(tint).ignoresSafeArea()
            } else {
                #if compiler(>=6.2)
                    Rectangle().fill(.clear).glassEffect(.regular, in: Rectangle()).overlay(
                        tint.opacity(scheme == .dark ? 0.45 : 0.35)
                    ).ignoresSafeArea()
                #else
                    Rectangle().fill(.regularMaterial).overlay(tint).ignoresSafeArea()
                #endif
            }
        } else {
            Color.clear
        }
    }
}

/// ImageRenderer cannot snapshot AppKit-backed borderless controls. Keep the real
/// style in the popover and draw only the SwiftUI label in offscreen fixtures.
struct PanelBorderless: ViewModifier {
    @Environment(\.renderingPanel) private var rendering
    func body(content: Content) -> some View {
        if rendering { content.buttonStyle(.plain) }
        else { content.buttonStyle(.borderless) }
    }
}

struct ProcessResourcePicker: View {
    @Binding var memory: Bool
    @Environment(\.renderingPanel) private var rendering
    var body: some View {
        if rendering {
            HStack(spacing: 0) {
                segment("CPU", selected: !memory)
                segment("Memory", selected: memory)
            }.font(.system(size: 9)).frame(width: 112, height: 14)
                .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 3))
        } else {
            Picker("Resource", selection: $memory) {
                Text("CPU").tag(false)
                Text("Memory").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 112).controlSize(.mini)
        }
    }
    private func segment(_ title: String, selected: Bool) -> some View {
        Text(title).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? Color.primary.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 3))
    }
}
