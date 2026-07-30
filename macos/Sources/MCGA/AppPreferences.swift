import AppKit
import Carbon
import ServiceManagement
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case zh
    case en

    var id: String { rawValue }
}
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct KeyboardShortcut: Equatable {
    var keyCode: Int
    var carbonModifiers: UInt32

    static let defaultHistory = KeyboardShortcut(keyCode: 9, carbonModifiers: UInt32(cmdKey | shiftKey))

    var displayText: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        text += Self.keyName(for: keyCode)
        return text
    }

    static func from(event: NSEvent) -> KeyboardShortcut? {
        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        guard !modifierOnlyKeyCodes.contains(Int(event.keyCode)) else { return nil }
        return KeyboardShortcut(keyCode: Int(event.keyCode), carbonModifiers: modifiers)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    private static let modifierOnlyKeyCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private static func keyName(for keyCode: Int) -> String {
        switch keyCode {
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 6: "Z"
        case 7: "X"
        case 8: "C"
        case 9: "V"
        case 11: "B"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        case 16: "Y"
        case 17: "T"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 22: "6"
        case 23: "5"
        case 24: "="
        case 25: "9"
        case 26: "7"
        case 27: "-"
        case 28: "8"
        case 29: "0"
        case 30: "]"
        case 31: "O"
        case 32: "U"
        case 33: "["
        case 34: "I"
        case 35: "P"
        case 36: "↩"
        case 37: "L"
        case 38: "J"
        case 39: "'"
        case 40: "K"
        case 41: ";"
        case 42: "\\"
        case 43: ","
        case 44: "/"
        case 45: "N"
        case 46: "M"
        case 47: "."
        case 48: "⇥"
        case 49: "Space"
        case 50: "`"
        case 51: "⌫"
        case 53: "⎋"
        case 65: "."
        case 67: "*"
        case 69: "+"
        case 71: "Clear"
        case 75: "/"
        case 76: "⌅"
        case 78: "-"
        case 81: "="
        case 82: "0"
        case 83: "1"
        case 84: "2"
        case 85: "3"
        case 86: "4"
        case 87: "5"
        case 88: "6"
        case 89: "7"
        case 91: "8"
        case 92: "9"
        case 96: "F5"
        case 97: "F6"
        case 98: "F7"
        case 99: "F3"
        case 100: "F8"
        case 101: "F9"
        case 103: "F11"
        case 105: "F13"
        case 107: "F14"
        case 109: "F10"
        case 111: "F12"
        case 113: "F15"
        case 114: "Help"
        case 115: "Home"
        case 116: "Page Up"
        case 117: "⌦"
        case 118: "F4"
        case 119: "End"
        case 120: "F2"
        case 121: "Page Down"
        case 122: "F1"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: "Key \(keyCode)"
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    @Published var historyShortcutEnabled: Bool {
        didSet {
            defaults.set(historyShortcutEnabled, forKey: Keys.historyShortcutEnabled)
            onHistoryShortcutChanged?(historyShortcutEnabled, historyShortcut)
        }
    }

    @Published var historyShortcut: KeyboardShortcut {
        didSet {
            defaults.set(historyShortcut.keyCode, forKey: Keys.historyShortcutKeyCode)
            defaults.set(Int(historyShortcut.carbonModifiers), forKey: Keys.historyShortcutModifiers)
            onHistoryShortcutChanged?(historyShortcutEnabled, historyShortcut)
        }
    }

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginNeedsApproval: Bool

    @Published var historyRetentionDays: Int {
        didSet {
            if historyRetentionDays < 0 {
                historyRetentionDays = 0
                return
            }
            defaults.set(historyRetentionDays, forKey: Keys.historyRetentionDays)
            onHistoryRetentionChanged?()
        }
    }

    @Published private(set) var disabledParserNames: Set<String> {
        didSet { defaults.set(Array(disabledParserNames).sorted(), forKey: Keys.disabledParsers) }
    }

    var onHistoryShortcutChanged: ((Bool, KeyboardShortcut) -> Void)?
    var onHistoryRetentionChanged: (() -> Void)?

    private let defaults = UserDefaults.standard

    init() {
        self.language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .zh
        self.theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        self.historyShortcutEnabled = defaults.bool(forKey: Keys.historyShortcutEnabled)
        let savedKeyCode = defaults.object(forKey: Keys.historyShortcutKeyCode) as? Int
        let savedModifiers = defaults.object(forKey: Keys.historyShortcutModifiers) as? Int
        self.historyShortcut = KeyboardShortcut(
            keyCode: savedKeyCode ?? KeyboardShortcut.defaultHistory.keyCode,
            carbonModifiers: UInt32(savedModifiers ?? Int(KeyboardShortcut.defaultHistory.carbonModifiers))
        )
        self.launchAtLogin = LoginItemController.isRegistered
        self.launchAtLoginNeedsApproval = LoginItemController.needsApproval
        self.historyRetentionDays = defaults.object(forKey: Keys.historyRetentionDays) as? Int ?? 0
        self.disabledParserNames = Set(defaults.stringArray(forKey: Keys.disabledParsers) ?? [])
    }

    func isParserEnabled(_ name: String) -> Bool {
        !disabledParserNames.contains(name)
    }

    func setParser(_ name: String, enabled: Bool) {
        if enabled {
            disabledParserNames.remove(name)
        } else {
            disabledParserNames.insert(name)
        }
    }

    func enabledParserNames(from allNames: [String]) -> Set<String> {
        Set(allNames.filter { isParserEnabled($0) })
    }

    func text(_ key: TextKey) -> String {
        key.value(language)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LoginItemController.setEnabled(enabled)
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = LoginItemController.isRegistered
        launchAtLoginNeedsApproval = LoginItemController.needsApproval
    }

    private enum Keys {
        static let language = "app.language"
        static let theme = "app.theme"
        static let historyShortcutEnabled = "app.historyShortcutEnabled"
        static let historyShortcutKeyCode = "app.historyShortcut.keyCode"
        static let historyShortcutModifiers = "app.historyShortcut.modifiers"
        static let historyRetentionDays = "app.historyRetentionDays"
        static let disabledParsers = "app.disabledParsers"
    }
}

enum LoginItemController {
    static var isRegistered: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if !isRegistered {
                    try SMAppService.mainApp.register()
                }
            } else if isRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Login item registration is user-facing state; keep the UI in sync after failures.
        }
    }
}

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: KeyboardShortcut
    let placeholder: String
    let recordingText: String

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onShortcut = { shortcut in
            self.shortcut = shortcut
        }
        view.placeholder = placeholder
        view.recordingText = recordingText
        view.shortcut = shortcut
        return view
    }

    func updateNSView(_ view: ShortcutRecorderNSView, context: Context) {
        view.onShortcut = { shortcut in
            self.shortcut = shortcut
        }
        view.placeholder = placeholder
        view.recordingText = recordingText
        view.shortcut = shortcut
    }
}

final class ShortcutRecorderNSView: NSView {
    var shortcut: KeyboardShortcut = .defaultHistory {
        didSet { updateText() }
    }
    var placeholder = "" {
        didSet { updateText() }
    }
    var recordingText = "" {
        didSet { updateText() }
    }
    var onShortcut: ((KeyboardShortcut) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var isRecording = false {
        didSet { updateText() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateText()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            isRecording = false
            return
        }
        guard let shortcut = KeyboardShortcut.from(event: event) else {
            NSSound.beep()
            return
        }
        self.shortcut = shortcut
        isRecording = false
        onShortcut?(shortcut)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    private func updateText() {
        label.stringValue = isRecording ? recordingText : (shortcut.displayText.isEmpty ? placeholder : shortcut.displayText)
        label.textColor = isRecording ? .controlAccentColor : .labelColor
        layer?.borderColor = (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }
}

final class GlobalHotKeyController: @unchecked Sendable {
    private let signature: OSType = 0x4D434741
    private let hotKeyIDValue: UInt32 = 1
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var callback: (@MainActor () -> Void)?

    init() {
        installHandler()
    }

    deinit {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    func update(shortcut: KeyboardShortcut?, callback: @escaping @MainActor () -> Void) {
        self.callback = callback
        unregister()
        guard let shortcut else { return }

        let hotKeyID = EventHotKeyID(signature: signature, id: hotKeyIDValue)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newRef
        )
        if status == noErr {
            hotKeyRef = newRef
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var newHandler: EventHandlerRef?
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == controller.signature,
                      hotKeyID.id == controller.hotKeyIDValue else {
                    return noErr
                }
                Task { @MainActor in
                    controller.callback?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &newHandler
        )
        if status == noErr {
            handlerRef = newHandler
        }
    }
}

enum TextKey {
    case history
    case copyFirstResult
    case copyResult
    case currentClipboard
    case copyOriginal
    case paused
    case waiting
    case emptyHint
    case refreshHistory
    case quit
    case clearHistory
    case noHistory
    case settings
    case language
    case chinese
    case english
    case theme
    case system
    case light
    case dark
    case general
    case shortcut
    case parsers
    case historyShortcutEnabled
    case historyShortcut
    case recordShortcut
    case recordingShortcut
    case launchAtLogin
    case launchAtLoginNeedsApproval
    case historyRetentionDays
    case historyRetentionUnlimited
    case historyRetentionDaysValue
    case searchHistory
    case historyOriginal
    case historyParsed
    case selectHistoryEntry
    case previewUnavailable
    case noPreviewForBinary
    case noParsedResults
    case noSearchResults
    case pause
    case resume
    case copied
    case openSettings
    case close
    case description
    case examples
    case clipboardContent
    case expectedOutput

    func value(_ language: AppLanguage) -> String {
        switch (language, self) {
        case (.zh, .history): "历史"
        case (.en, .history): "History"
        case (.zh, .copyFirstResult): "复制第一条结果"
        case (.en, .copyFirstResult): "Copy first result"
        case (.zh, .copyResult): "复制解析结果"
        case (.en, .copyResult): "Copy result"
        case (.zh, .currentClipboard): "当前剪切板"
        case (.en, .currentClipboard): "Current clipboard"
        case (.zh, .copyOriginal): "复制原文"
        case (.en, .copyOriginal): "Copy original"
        case (.zh, .paused): "已暂停监听"
        case (.en, .paused): "Paused"
        case (.zh, .waiting): "等待剪切板内容"
        case (.en, .waiting): "Waiting for clipboard"
        case (.zh, .emptyHint): "复制可解析内容后会在这里显示。"
        case (.en, .emptyHint): "Copy supported content to show parsed results here."
        case (.zh, .refreshHistory): "刷新历史"
        case (.en, .refreshHistory): "Refresh history"
        case (.zh, .quit): "退出"
        case (.en, .quit): "Quit"
        case (.zh, .clearHistory): "清空历史"
        case (.en, .clearHistory): "Clear history"
        case (.zh, .noHistory): "暂无历史"
        case (.en, .noHistory): "No history"
        case (.zh, .settings): "设置"
        case (.en, .settings): "Settings"
        case (.zh, .language): "语言"
        case (.en, .language): "Language"
        case (.zh, .chinese): "中文"
        case (.en, .chinese): "Chinese"
        case (.zh, .english): "英文"
        case (.en, .english): "English"
        case (.zh, .theme): "主题"
        case (.en, .theme): "Theme"
        case (.zh, .system): "跟随系统"
        case (.en, .system): "System"
        case (.zh, .light): "浅色"
        case (.en, .light): "Light"
        case (.zh, .dark): "深色"
        case (.en, .dark): "Dark"
        case (.zh, .general): "通用"
        case (.en, .general): "General"
        case (.zh, .shortcut): "快捷键"
        case (.en, .shortcut): "Shortcut"
        case (.zh, .parsers): "解析器"
        case (.en, .parsers): "Parsers"
        case (.zh, .historyShortcutEnabled): "启用历史快捷键"
        case (.en, .historyShortcutEnabled): "Enable history shortcut"
        case (.zh, .historyShortcut): "历史快捷键"
        case (.en, .historyShortcut): "History shortcut"
        case (.zh, .recordShortcut): "点击后按下快捷键"
        case (.en, .recordShortcut): "Click and press a shortcut"
        case (.zh, .recordingShortcut): "按下新的快捷键，Esc 取消"
        case (.en, .recordingShortcut): "Press a new shortcut, Esc to cancel"
        case (.zh, .launchAtLogin): "开机自启动"
        case (.en, .launchAtLogin): "Start at login"
        case (.zh, .launchAtLoginNeedsApproval): "需要在系统设置的登录项中允许 MCGA 后才会生效。"
        case (.en, .launchAtLoginNeedsApproval): "Allow MCGA in System Settings login items to finish enabling this."
        case (.zh, .historyRetentionDays): "历史保留时间"
        case (.en, .historyRetentionDays): "History retention"
        case (.zh, .historyRetentionUnlimited): "不限制时间"
        case (.en, .historyRetentionUnlimited): "Unlimited"
        case (.zh, .historyRetentionDaysValue): "保留 %d 天"
        case (.en, .historyRetentionDaysValue): "Keep for %d days"
        case (.zh, .searchHistory): "搜索原文或解析结果"
        case (.en, .searchHistory): "Search original or parsed content"
        case (.zh, .historyOriginal): "原始内容"
        case (.en, .historyOriginal): "Original"
        case (.zh, .historyParsed): "解析结果"
        case (.en, .historyParsed): "Parsed"
        case (.zh, .selectHistoryEntry): "选择左侧历史后查看解析结果。"
        case (.en, .selectHistoryEntry): "Select a history item on the left to view parsed results."
        case (.zh, .previewUnavailable): "预览不可用"
        case (.en, .previewUnavailable): "Preview unavailable"
        case (.zh, .noPreviewForBinary): "此文件类型不预览。"
        case (.en, .noPreviewForBinary): "Preview is disabled for this file type."
        case (.zh, .noParsedResults): "无解析结果"
        case (.en, .noParsedResults): "No parsed results"
        case (.zh, .noSearchResults): "没有匹配的历史"
        case (.en, .noSearchResults): "No matching history"
        case (.zh, .pause): "暂停监听"
        case (.en, .pause): "Pause"
        case (.zh, .resume): "继续监听"
        case (.en, .resume): "Resume"
        case (.zh, .copied): "已复制"
        case (.en, .copied): "Copied"
        case (.zh, .openSettings): "打开设置"
        case (.en, .openSettings): "Open settings"
        case (.zh, .close): "关闭"
        case (.en, .close): "Close"
        case (.zh, .description): "说明"
        case (.en, .description): "Description"
        case (.zh, .examples): "示例"
        case (.en, .examples): "Examples"
        case (.zh, .clipboardContent): "剪切板内容"
        case (.en, .clipboardContent): "Clipboard content"
        case (.zh, .expectedOutput): "预期输出"
        case (.en, .expectedOutput): "Expected output"
        }
    }
}
