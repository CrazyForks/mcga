import AppKit
import SwiftUI

enum AppSymbols {
    static var primary: NSImage? {
        NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "MCGA")
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "MCGA")
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "MCGA")
    }
}

struct InteractiveIconButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 26, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background(configuration: configuration))
            )
            .foregroundStyle(.primary)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }

    private func background(configuration: Configuration) -> Color {
        if configuration.isPressed {
            return Color.primary.opacity(0.14)
        }
        if isHovered {
            return Color.primary.opacity(0.07)
        }
        return Color.clear
    }
}

struct InteractiveCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
            )
    }
}

extension View {
    func interactiveCard() -> some View {
        modifier(InteractiveCardModifier())
    }
}
