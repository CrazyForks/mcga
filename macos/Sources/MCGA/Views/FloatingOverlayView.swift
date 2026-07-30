import AppKit
import MCGACore
import SwiftUI

@MainActor
final class FloatingOverlayPresenter {
    private var panels: [NSPanel] = []

    func show(
        content: String,
        results: [ParseResult],
        preferences: AppPreferences,
        copy: @escaping (String) -> Void,
        showHistory: @escaping () -> Void
    ) {
        guard let screen = NSScreen.main else { return }
        while panels.count >= 2 {
            let oldest = panels.removeFirst()
            oldest.orderOut(nil)
        }

        let frame = screen.visibleFrame
        let width = max(380, min(frame.width * 0.28, 520))
        let height = max(280, min(frame.height * 0.38, 420))
        let marginRight = max(16, frame.width * 0.012)
        let marginBottom = max(36, frame.height * 0.07)
        let gap = max(10, frame.height * 0.012)
        let slot = panels.count
        let origin = NSPoint(
            x: frame.maxX - width - marginRight,
            y: frame.minY + marginBottom + CGFloat(slot) * (height + gap)
        )

        let panel = NonActivatingOverlayPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: FloatingOverlayView(
            content: content,
            results: results,
            preferences: preferences,
            copy: copy,
            showHistory: showHistory
        ))

        panels.append(panel)
        panel.orderFrontRegardless()

        Task { [weak self, weak panel] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, let panel else { return }
            while panel.frame.contains(NSEvent.mouseLocation) {
                try? await Task.sleep(for: .milliseconds(300))
            }
            panel.orderOut(nil)
            self.panels.removeAll { $0 === panel }
        }
    }
}

struct FloatingOverlayView: View {
    let content: String
    let results: [ParseResult]
    @ObservedObject var preferences: AppPreferences
    let copy: (String) -> Void
    let showHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(results) { result in
                        resultCard(result)
                    }
                }
                .padding(12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .preferredColorScheme(preferences.theme.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("MCGA")
                    .font(.system(size: 13, weight: .semibold))
                Text(contentPreview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button {
                showHistory()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(InteractiveIconButtonStyle())
            .help(preferences.text(.history))

            Button {
                if let first = results.first {
                    copy(first.parsed)
                }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(InteractiveIconButtonStyle())
            .help(preferences.text(.copyFirstResult))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func resultCard(_ result: ParseResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(result.parserName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Button {
                    copy(result.parsed)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(InteractiveIconButtonStyle())
                .help(preferences.text(.copyResult))
            }
            SelectableOverlayText(
                result.parsed,
                font: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
                textColor: .labelColor
            )
            if let details = result.details, details != result.parsed {
                SelectableOverlayText(
                    details,
                    font: .monospacedSystemFont(ofSize: 11.5, weight: .regular),
                    textColor: .secondaryLabelColor
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
        )
    }

    private var contentPreview: String {
        let preview = content.replacingOccurrences(of: "\n", with: " ")
        return String(preview.prefix(80))
    }
}

final class NonActivatingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct SelectableOverlayText: NSViewRepresentable {
    let text: String
    let font: NSFont
    let textColor: NSColor

    init(_ text: String, font: NSFont, textColor: NSColor) {
        self.text = text
        self.font = font
        self.textColor = textColor
    }

    func makeNSView(context: Context) -> OverlaySelectableTextField {
        let field = OverlaySelectableTextField(wrappingLabelWithString: text)
        field.isSelectable = true
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: OverlaySelectableTextField, context: Context) {
        field.stringValue = text
        field.font = font
        field.textColor = textColor
    }
}

final class OverlaySelectableTextField: NSTextField {
    override var needsPanelToBecomeKey: Bool { true }
}
