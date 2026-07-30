import AppKit
import MCGACore
import UniformTypeIdentifiers

@MainActor
final class ClipboardModel: ObservableObject {
    @Published var isPaused = false
    @Published var currentContent = ""
    @Published var results: [ParseResult] = []
    @Published var history: [HistoryEntry] = []
    @Published var lastUpdated: Date?
    @Published var copyNotice: String?
    var onNewResults: ((String, [ParseResult]) -> Void)?

    private let engine = ParserEngine()
    private let preferences: AppPreferences
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var previousContent = ""
    private let filePreviewLimit = 256 * 1024
    private let imagePreviewMaxSide: CGFloat = 900

    var parserNames: [String] {
        engine.parserNames
    }

    var parserInfos: [ParserInfo] {
        engine.parserInfos
    }

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    func start() {
        refreshHistory()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollClipboard()
            }
        }
        timer?.tolerance = 0.1
    }

    func togglePaused() {
        isPaused.toggle()
    }

    func clearHistory() {
        Task {
            await HistoryStore.shared.clear()
            refreshHistory()
        }
    }

    func refreshHistory() {
        Task {
            let entries = await HistoryStore.shared.allRecent(retentionDays: preferences.historyRetentionDays)
            await MainActor.run {
                self.history = entries
            }
        }
    }

    func promoteHistoryEntry(id: UInt64) {
        Task {
            await HistoryStore.shared.promote(id: id, retentionDays: preferences.historyRetentionDays)
            refreshHistory()
        }
    }

    func copy(_ value: String) {
        copy(.text(value))
    }

    func copy(_ payload: ClipboardPayload) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch payload {
        case .text(let value):
            pasteboard.setString(value, forType: .string)
        case .file(let url):
            pasteboard.writeObjects([url as NSURL])
        case .image(let url):
            if let image = NSImage(contentsOf: url) {
                pasteboard.writeObjects([image])
            } else {
                pasteboard.setString(url.path, forType: .string)
            }
        }
        lastChangeCount = pasteboard.changeCount
        copyNotice = preferences.text(.copied)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            await MainActor.run {
                if self?.copyNotice == self?.preferences.text(.copied) {
                    self?.copyNotice = nil
                }
            }
        }
    }

    private func pollClipboard() {
        guard !isPaused else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        let fileURLs = pasteboardFileURLs(pasteboard)
        if !fileURLs.isEmpty {
            for fileURL in fileURLs {
                appendFileHistory(fileURL)
            }
            return
        }

        if let image = NSImage(pasteboard: pasteboard) {
            appendImageHistory(image)
            return
        }

        guard let content = pasteboard.string(forType: .string), content != currentContent else { return }

        let parsed = engine.parseAll(
            content,
            previousContent: previousContent,
            enabledParserNames: preferences.enabledParserNames(from: engine.parserNames)
        )
        previousContent = content

        currentContent = content
        results = parsed
        lastUpdated = Date()
        if !parsed.isEmpty {
            onNewResults?(content, parsed)
        }
        Task {
            await HistoryStore.shared.append(original: content, results: parsed, retentionDays: preferences.historyRetentionDays)
            refreshHistory()
        }
    }

    private func pasteboardFileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    private func appendFileHistory(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey])
        let fileSize = Int64(values?.fileSize ?? 0)
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        let typeName = type?.localizedDescription ?? type?.identifier ?? url.pathExtension
        let fileName = url.lastPathComponent
        let preview = "\(fileName)\n\(url.path)"

        if let type, type.conforms(to: .image), let image = NSImage(contentsOf: url) {
            let assetPath = saveImagePreview(image)
            let attachment = HistoryAttachment(
                previewKind: assetPath == nil ? .none : .image,
                assetPath: assetPath,
                filePath: url.path,
                fileName: fileName,
                fileType: typeName,
                fileSize: fileSize,
                imageWidth: Int(image.size.width),
                imageHeight: Int(image.size.height),
                textPreview: nil
            )
            appendAttachment(kind: .file, preview: preview, attachment: attachment)
            return
        }

        if isTextPreviewable(type: type), let textPreview = readTextPreview(url) {
            let attachment = HistoryAttachment(
                previewKind: .text,
                assetPath: nil,
                filePath: url.path,
                fileName: fileName,
                fileType: typeName,
                fileSize: fileSize,
                imageWidth: nil,
                imageHeight: nil,
                textPreview: textPreview
            )
            appendAttachment(kind: .file, preview: preview, attachment: attachment)
            return
        }

        let attachment = HistoryAttachment(
            previewKind: .none,
            assetPath: nil,
            filePath: url.path,
            fileName: fileName,
            fileType: typeName,
            fileSize: fileSize,
            imageWidth: nil,
            imageHeight: nil,
            textPreview: nil
        )
        appendAttachment(kind: .file, preview: preview, attachment: attachment)
    }

    private func appendImageHistory(_ image: NSImage) {
        let assetPath = saveImagePreview(image)
        let preview = "Image \(Int(image.size.width)) x \(Int(image.size.height))"
        let attachment = HistoryAttachment(
            previewKind: assetPath == nil ? .none : .image,
            assetPath: assetPath,
            filePath: nil,
            fileName: nil,
            fileType: "Image",
            fileSize: nil,
            imageWidth: Int(image.size.width),
            imageHeight: Int(image.size.height),
            textPreview: nil
        )
        appendAttachment(kind: .image, preview: preview, attachment: attachment)
    }

    private func appendAttachment(kind: HistoryContentKind, preview: String, attachment: HistoryAttachment) {
        currentContent = preview
        results = []
        lastUpdated = Date()
        Task {
            await HistoryStore.shared.append(
                kind: kind,
                originalPreview: preview,
                attachment: attachment,
                retentionDays: preferences.historyRetentionDays
            )
            refreshHistory()
        }
    }

    private func isTextPreviewable(type: UTType?) -> Bool {
        guard let type else { return false }
        return type.conforms(to: .text)
            || type.conforms(to: .json)
            || type.conforms(to: .xml)
            || type.identifier == "public.yaml"
            || type.identifier == "net.daringfireball.markdown"
    }

    private func readTextPreview(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: filePreviewLimit), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private func saveImagePreview(_ image: NSImage) -> String? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/mcga/history-assets")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let originalSize = image.size
        let maxDimension = max(originalSize.width, originalSize.height)
        let scale = maxDimension > imagePreviewMaxSide ? imagePreviewMaxSide / maxDimension : 1
        let targetSize = NSSize(
            width: max(1, originalSize.width * scale),
            height: max(1, originalSize.height * scale)
        )
        let thumbnail = NSImage(size: targetSize)
        thumbnail.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1)
        thumbnail.unlockFocus()

        guard let tiff = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        do {
            try png.write(to: url, options: [.atomic])
            return url.path
        } catch {
            return nil
        }
    }
}
