import AppKit
import MCGACore
import SwiftUI

struct ClipboardPopoverView: View {
    @ObservedObject var model: ClipboardModel
    @ObservedObject var preferences: AppPreferences
    let openSettings: () -> Void
    let close: () -> Void
    let paste: (ClipboardPayload) -> Void
    @State private var searchText = ""
    @State private var selectedHistoryID: UInt64?
    @State private var focusedPane: HistoryFocusPane = .original
    @State private var selectedResultIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                searchField
                historyView
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 420, minHeight: 520)
        .background(HistoryKeyboardCaptureView { handleHistoryKeyAction($0) })
        .overlay(alignment: .top) {
            if let notice = model.copyNotice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .padding(.top, 46)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.copyNotice)
        .onAppear {
            selectFirstHistoryIfNeeded()
        }
        .onChange(of: model.history) {
            reconcileHistorySelection()
        }
        .onChange(of: searchText) {
            reconcileHistorySelection()
        }
        .preferredColorScheme(preferences.theme.colorScheme)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
            Text("MCGA")
                .font(.headline)
            Spacer()
            Button {
                model.togglePaused()
            } label: {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
            }
            .help(model.isPaused ? preferences.text(.resume) : preferences.text(.pause))

            Button {
                model.refreshHistory()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(preferences.text(.refreshHistory))

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help(preferences.text(.openSettings))

            Button {
                close()
            } label: {
                Image(systemName: "xmark")
            }
            .keyboardShortcut(.escape, modifiers: [])
            .help(preferences.text(.close))
        }
        .buttonStyle(InteractiveIconButtonStyle())
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            HistorySearchField(
                text: $searchText,
                placeholder: preferences.text(.searchHistory)
            )
            .frame(height: 22)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(preferences.text(.close))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var historyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(preferences.text(.history))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    model.clearHistory()
                    selectedHistoryID = nil
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(InteractiveIconButtonStyle())
                .help(preferences.text(.clearHistory))
            }
            let entries = filteredHistory
            if model.history.isEmpty {
                ContentUnavailableView {
                    Label(preferences.text(.noHistory), systemImage: "tray")
                } description: {
                    Text(preferences.text(.emptyHint))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView {
                    Label(preferences.text(.noSearchResults), systemImage: "magnifyingglass")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(preferences.text(.historyOriginal))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(focusedPane == .original ? Color.accentColor : Color.secondary)
                            Spacer()
                        }
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(entries) { entry in
                                        historyOriginalRow(entry)
                                            .id(entry.id)
                                    }
                                }
                            }
                            .onChange(of: selectedHistoryID) {
                                if let selectedHistoryID {
                                    proxy.scrollTo(selectedHistoryID, anchor: .center)
                                }
                            }
                        }
                    }
                    .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(preferences.text(.historyParsed))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(focusedPane == .parsed ? Color.accentColor : Color.secondary)
                            Spacer()
                        }
                        if let entry = selectedHistoryEntry {
                            historyParsedPanel(entry)
                        } else {
                            Text(preferences.text(.selectHistoryEntry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 260, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func historyOriginalRow(_ entry: HistoryEntry) -> some View {
        let isSelected = selectedHistoryID == entry.id
        return Button {
            selectedHistoryID = entry.id
            focusedPane = .original
            selectedResultIndex = 0
            focusHistoryKeyboard()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(entry.originalPreview)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.summaryText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected
                            ? Color.accentColor.opacity(0.4)
                            : Color(nsColor: .separatorColor).opacity(0.7),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func historyParsedPanel(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if entry.results.isEmpty {
                attachmentPreview(entry)
            } else {
                ForEach(Array(entry.results.enumerated()), id: \.offset) { index, result in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(result.parserName)
                                .font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                            Spacer()
                            Button {
                                model.promoteHistoryEntry(id: entry.id)
                                model.copy(result.parsed)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(InteractiveIconButtonStyle())
                            .help(preferences.text(.copyResult))
                        }
                        Text(result.parsed)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let details = result.details, details != result.parsed {
                            Text(details)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(focusedPane == .parsed && selectedResultIndex == index ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor).opacity(0.7))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(focusedPane == .parsed && selectedResultIndex == index ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focusedPane = .parsed
                        selectedResultIndex = index
                        focusHistoryKeyboard()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func attachmentPreview(_ entry: HistoryEntry) -> some View {
        if let attachment = entry.attachment {
            VStack(alignment: .leading, spacing: 8) {
                attachmentMetadata(attachment)
                switch attachment.previewKind {
                case .image:
                    if let path = attachment.assetPath, let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 360)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text(preferences.text(.previewUnavailable))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .text:
                    Text(attachment.textPreview ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                case .none:
                    Text(preferences.text(.noPreviewForBinary))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .interactiveCard()
        } else {
            Text(preferences.text(.noParsedResults))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func attachmentMetadata(_ attachment: HistoryAttachment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fileName = attachment.fileName {
                Text(fileName)
                    .font(.caption.weight(.semibold))
            }
            if let filePath = attachment.filePath {
                Text(filePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(attachment.metadataText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filteredHistory: [HistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.history }
        return model.history.filter { $0.matchesHistoryQuery(query) }
    }

    private var selectedHistoryEntry: HistoryEntry? {
        guard let selectedHistoryID else { return nil }
        return filteredHistory.first { $0.id == selectedHistoryID }
    }

    private var focusedContentPayload: ClipboardPayload? {
        guard let entry = selectedHistoryEntry else { return nil }
        switch focusedPane {
        case .original:
            return originalPayload(entry)
        case .parsed:
            return parsedOrPreviewPayload(entry)
        }
    }

    private func originalPayload(_ entry: HistoryEntry) -> ClipboardPayload {
        if let original = entry.originalContent {
            return .text(original)
        }
        if let filePath = entry.attachment?.filePath {
            return .file(URL(fileURLWithPath: filePath))
        }
        if entry.contentKind == .image,
           let assetPath = entry.attachment?.assetPath {
            return .image(URL(fileURLWithPath: assetPath))
        }
        return .text(entry.originalPreview)
    }

    private func parsedOrPreviewPayload(_ entry: HistoryEntry) -> ClipboardPayload {
        if !entry.results.isEmpty {
            let index = min(max(selectedResultIndex, 0), entry.results.count - 1)
            return .text(entry.results[index].parsed)
        }
        if let textPreview = entry.attachment?.textPreview, !textPreview.isEmpty {
            return .text(textPreview)
        }
        if let filePath = entry.attachment?.filePath {
            return .file(URL(fileURLWithPath: filePath))
        }
        if entry.contentKind == .image,
           let assetPath = entry.attachment?.assetPath {
            return .image(URL(fileURLWithPath: assetPath))
        }
        return .text(entry.originalPreview)
    }

    private func selectFirstHistoryIfNeeded() {
        guard selectedHistoryID == nil else { return }
        selectedHistoryID = filteredHistory.first?.id
        focusHistoryKeyboard()
    }

    private func reconcileHistorySelection() {
        let entries = filteredHistory
        if let selectedHistoryID, entries.contains(where: { $0.id == selectedHistoryID }) {
            clampSelectedResultIndex()
            return
        }
        selectedHistoryID = entries.first?.id
        selectedResultIndex = 0
    }

    private func handleHistoryKeyAction(_ action: HistoryKeyAction) {
        switch action {
        case .moveUp:
            if focusedPane == .parsed {
                moveParsedSelection(.previous)
            } else {
                moveHistorySelection(.previous)
            }
        case .moveDown:
            if focusedPane == .parsed {
                moveParsedSelection(.next)
            } else {
                moveHistorySelection(.next)
            }
        case .focusOriginal:
            focusedPane = .original
        case .focusParsed:
            focusedPane = .parsed
            clampSelectedResultIndex()
        case .copy:
            if let entry = selectedHistoryEntry, let payload = focusedContentPayload {
                model.promoteHistoryEntry(id: entry.id)
                model.copy(payload)
            }
        case .paste:
            if let entry = selectedHistoryEntry, let payload = focusedContentPayload {
                model.promoteHistoryEntry(id: entry.id)
                paste(payload)
            }
        }
    }

    private func moveHistorySelection(_ direction: HistorySelectionDirection) {
        let entries = filteredHistory
        guard !entries.isEmpty else {
            selectedHistoryID = nil
            return
        }
        guard let selectedHistoryID,
              let currentIndex = entries.firstIndex(where: { $0.id == selectedHistoryID }) else {
            selectedHistoryID = entries.first?.id
            return
        }

        let nextIndex: Int
        switch direction {
        case .previous:
            nextIndex = max(entries.startIndex, currentIndex - 1)
        case .next:
            nextIndex = min(entries.index(before: entries.endIndex), currentIndex + 1)
        }
        self.selectedHistoryID = entries[nextIndex].id
        selectedResultIndex = 0
    }

    private func moveParsedSelection(_ direction: HistorySelectionDirection) {
        guard let entry = selectedHistoryEntry, !entry.results.isEmpty else { return }
        switch direction {
        case .previous:
            selectedResultIndex = max(0, selectedResultIndex - 1)
        case .next:
            selectedResultIndex = min(entry.results.count - 1, selectedResultIndex + 1)
        }
    }

    private func clampSelectedResultIndex() {
        guard let entry = selectedHistoryEntry, !entry.results.isEmpty else {
            selectedResultIndex = 0
            return
        }
        selectedResultIndex = min(max(selectedResultIndex, 0), entry.results.count - 1)
    }

    private func focusHistoryKeyboard() {
    }
}

struct HistorySearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.stringValue = text
        field.placeholderString = placeholder
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        focus(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        focus(field)
    }

    private func focus(_ field: NSTextField) {
        DispatchQueue.main.async {
            guard let window = field.window, window.firstResponder !== field.currentEditor() else { return }
            window.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

enum HistorySelectionDirection {
    case previous
    case next
}

enum HistoryFocusPane {
    case original
    case parsed
}

enum HistoryKeyAction {
    case moveUp
    case moveDown
    case focusOriginal
    case focusParsed
    case copy
    case paste
}

struct HistoryKeyboardCaptureView: NSViewRepresentable {
    let onAction: (HistoryKeyAction) -> Void

    func makeNSView(context: Context) -> HistoryKeyboardCaptureNSView {
        let view = HistoryKeyboardCaptureNSView()
        view.onAction = onAction
        return view
    }

    func updateNSView(_ view: HistoryKeyboardCaptureNSView, context: Context) {
        view.onAction = onAction
    }
}

final class HistoryKeyboardCaptureNSView: NSView {
    var onAction: ((HistoryKeyAction) -> Void)?
    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeEventMonitor()
        } else {
            installEventMonitor()
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if handleKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window else {
                return event
            }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    @discardableResult
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36:
            if event.modifierFlags.contains(.command) {
                onAction?(.copy)
            } else {
                onAction?(.paste)
            }
        case 123:
            onAction?(.focusOriginal)
        case 124:
            onAction?(.focusParsed)
        case 126:
            onAction?(.moveUp)
        case 125:
            onAction?(.moveDown)
        default:
            return false
        }
        return true
    }
}

private extension HistoryEntry {
    func matchesHistoryQuery(_ query: String) -> Bool {
        var fields = [originalContent ?? originalPreview, originalPreview]
        for result in results {
            fields.append(result.parserName)
            fields.append(result.parsed)
            if let details = result.details {
                fields.append(details)
            }
        }
        if let fileName = attachment?.fileName {
            fields.append(fileName)
        }
        if let filePath = attachment?.filePath {
            fields.append(filePath)
        }
        if let fileType = attachment?.fileType {
            fields.append(fileType)
        }
        if let textPreview = attachment?.textPreview {
            fields.append(textPreview)
        }
        let haystack = fields.joined(separator: "\n")
        return haystack.localizedCaseInsensitiveContains(query)
    }

    var summaryText: String {
        if !results.isEmpty {
            return results.map(\.parserName).joined(separator: ", ")
        }
        switch contentKind ?? .text {
        case .text:
            return "Text"
        case .image:
            return "Image"
        case .file:
            return attachment?.fileType ?? "File"
        }
    }
}

private extension HistoryAttachment {
    var metadataText: String {
        var parts: [String] = []
        if let fileType {
            parts.append(fileType)
        }
        if let fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
        }
        if let imageWidth, let imageHeight {
            parts.append("\(imageWidth) x \(imageHeight)")
        }
        return parts.isEmpty ? "File" : parts.joined(separator: " · ")
    }
}
