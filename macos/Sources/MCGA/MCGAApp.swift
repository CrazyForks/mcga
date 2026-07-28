import AppKit
import Carbon
import MCGACore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@main
struct MCGAApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: ClipboardModel
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section(preferences.text(.general)) {
                Picker(preferences.text(.language), selection: $preferences.language) {
                    Text(preferences.text(.chinese)).tag(AppLanguage.zh)
                    Text(preferences.text(.english)).tag(AppLanguage.en)
                }

                Picker(preferences.text(.theme), selection: $preferences.theme) {
                    Text(preferences.text(.system)).tag(AppTheme.system)
                    Text(preferences.text(.light)).tag(AppTheme.light)
                    Text(preferences.text(.dark)).tag(AppTheme.dark)
                }

                Toggle(isOn: Binding(
                    get: { preferences.launchAtLogin },
                    set: { preferences.setLaunchAtLogin($0) }
                )) {
                    Text(preferences.text(.launchAtLogin))
                }

                if preferences.launchAtLoginNeedsApproval {
                    Text(preferences.text(.launchAtLoginNeedsApproval))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Stepper(value: $preferences.historyRetentionDays, in: 0...3650) {
                    HStack {
                        Text(preferences.text(.historyRetentionDays))
                        Spacer()
                        Text(preferences.historyRetentionDays == 0
                            ? preferences.text(.historyRetentionUnlimited)
                            : String(format: preferences.text(.historyRetentionDaysValue), preferences.historyRetentionDays)
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Section(preferences.text(.shortcut)) {
                Toggle(preferences.text(.historyShortcutEnabled), isOn: $preferences.historyShortcutEnabled)

                if preferences.historyShortcutEnabled {
                    LabeledContent(preferences.text(.historyShortcut)) {
                        ShortcutRecorderView(
                            shortcut: $preferences.historyShortcut,
                            placeholder: preferences.text(.recordShortcut),
                            recordingText: preferences.text(.recordingShortcut)
                        )
                        .frame(width: 180, height: 24)
                    }
                }
            }

            Section(preferences.text(.parsers)) {
                ForEach(model.parserInfos) { info in
                    parserRow(info)
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(width: 560, height: 620)
        .preferredColorScheme(preferences.theme.colorScheme)
    }

    private func parserRow(_ info: ParserInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { preferences.isParserEnabled(info.name) },
                set: { preferences.setParser(info.name, enabled: $0) }
            )) {
                Text(info.name)
            }

            Text(description(for: info))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !info.examples.isEmpty {
                DisclosureGroup(preferences.text(.examples)) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(info.examples) { example in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(example.input)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Label(expected(for: example), systemImage: "arrow.turn.down.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func description(for info: ParserInfo) -> String {
        preferences.language == .zh ? info.zhDescription : info.enDescription
    }

    private func expected(for example: ParserExample) -> String {
        preferences.language == .zh ? example.zhExpected : example.enExpected
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = AppPreferences()
    private lazy var model = ClipboardModel(preferences: preferences)
    private let overlayPresenter = FloatingOverlayPresenter()
    private let historyHotKey = GlobalHotKeyController()
    private var statusItem: NSStatusItem?
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var appBeforeHistoryBundleIdentifier: String?
    private var appBeforeHistoryProcessIdentifier: pid_t?
    private var lastExternalAppBundleIdentifier: String?
    private var lastExternalAppProcessIdentifier: pid_t?
    private var didRequestAccessibilityPermission = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        preferences.onHistoryShortcutChanged = { [weak self] enabled, shortcut in
            self?.configureHistoryShortcut(enabled: enabled, shortcut: shortcut)
        }
        preferences.onHistoryRetentionChanged = { [weak self] in
            self?.model.refreshHistory()
        }
        configureHistoryShortcut(enabled: preferences.historyShortcutEnabled, shortcut: preferences.historyShortcut)
        setupWorkspaceActivationTracking()
        model.onNewResults = { [weak self] content, results in
            guard let self else { return }
            self.overlayPresenter.show(
                content: content,
                results: results,
                preferences: self.preferences,
                copy: { [weak self] value in self?.model.copy(value) },
                showHistory: { [weak self] in self?.openHistoryWindow() }
            )
        }
        model.start()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = AppSymbols.primary
        image?.isTemplate = true
        item.button?.image = image
        item.button?.imagePosition = .imageOnly
        item.button?.action = #selector(statusItemActivated)
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemActivated() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusItemMenu()
        } else {
            togglePopover()
        }
    }

    private func showStatusItemMenu() {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "\(preferences.text(.settings))…",
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: preferences.text(.quit),
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openSettingsFromMenu() {
        openSettingsWindow()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc private func togglePopover() {
        if let historyWindow, historyWindow.isVisible {
            historyWindow.close()
        } else {
            openHistoryWindow()
        }
    }

    private func configureHistoryShortcut(enabled: Bool, shortcut: KeyboardShortcut) {
        historyHotKey.update(shortcut: enabled ? shortcut : nil) { [weak self] in
            self?.openHistoryWindow()
        }
    }

    private func openHistoryWindow() {
        rememberFrontmostAppBeforeHistory()
        if let historyWindow {
            historyWindow.center()
            showNonActivatingHistoryWindow(historyWindow)
            return
        }

        model.refreshHistory()
        let window = makeHistoryPanel(
            title: preferences.text(.history),
            size: NSSize(width: 720, height: 680)
        )
        window.contentView = NSHostingView(rootView: ClipboardPopoverView(
            model: model,
            preferences: preferences,
            openSettings: { [weak self] in self?.openSettingsWindow() },
            close: { [weak self] in self?.historyWindow?.close() },
            paste: { [weak self] payload in self?.pasteToPreviousApp(payload) }
        ))
        historyWindow = window
        showNonActivatingHistoryWindow(window)
    }

    private func pasteToPreviousApp(_ payload: ClipboardPayload) {
        model.copy(payload)
        let targetApp = appBeforeHistoryTarget()
        historyWindow?.orderOut(nil)
        historyWindow?.close()
        Task { @MainActor in
            if let targetApp {
                targetApp.unhide()
                targetApp.activate()
                await waitUntilFrontmost(targetApp)
            }
            try? await Task.sleep(for: .milliseconds(180))
            sendPasteKeystroke()
        }
    }

    private func setupWorkspaceActivationTracking() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let bundleIdentifier = app.bundleIdentifier
            let processIdentifier = app.processIdentifier
            let isTerminated = app.isTerminated
            Task { @MainActor in
                self?.rememberExternalApp(
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: processIdentifier,
                    isTerminated: isTerminated
                )
            }
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            rememberExternalApp(app)
        }
    }

    private func rememberFrontmostAppBeforeHistory() {
        if let app = NSWorkspace.shared.frontmostApplication,
           rememberExternalApp(app) {
            appBeforeHistoryBundleIdentifier = app.bundleIdentifier
            appBeforeHistoryProcessIdentifier = app.processIdentifier
            return
        }
        appBeforeHistoryBundleIdentifier = lastExternalAppBundleIdentifier
        appBeforeHistoryProcessIdentifier = lastExternalAppProcessIdentifier
    }

    @discardableResult
    private func rememberExternalApp(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return false
        }
        lastExternalAppBundleIdentifier = app.bundleIdentifier
        lastExternalAppProcessIdentifier = app.processIdentifier
        return true
    }

    @discardableResult
    private func rememberExternalApp(bundleIdentifier: String?, processIdentifier: pid_t, isTerminated: Bool) -> Bool {
        guard !isTerminated,
              bundleIdentifier != Bundle.main.bundleIdentifier else {
            return false
        }
        lastExternalAppBundleIdentifier = bundleIdentifier
        lastExternalAppProcessIdentifier = processIdentifier
        return true
    }

    private func appBeforeHistoryTarget() -> NSRunningApplication? {
        if let pid = appBeforeHistoryProcessIdentifier,
           let app = NSRunningApplication(processIdentifier: pid),
           !app.isTerminated {
            return app
        }
        if let bundleID = appBeforeHistoryBundleIdentifier {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first { !$0.isTerminated }
        }
        return nil
    }

    private func waitUntilFrontmost(_ app: NSRunningApplication) async {
        for _ in 0..<12 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                return
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private func sendPasteKeystroke() {
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermissionOnce()
            return
        }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false) else {
            return
        }
        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        commandUp.flags = .maskCommand

        commandDown.post(tap: .cgAnnotatedSessionEventTap)
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        commandUp.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func requestAccessibilityPermissionOnce() {
        guard !didRequestAccessibilityPermission else { return }
        didRequestAccessibilityPermission = true
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private func openSettingsWindow() {
        if let settingsWindow {
            preferences.refreshLaunchAtLogin()
            settingsWindow.center()
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        preferences.refreshLaunchAtLogin()
        let window = makeSettingsPanel(
            title: preferences.text(.settings),
            size: NSSize(width: 560, height: 620)
        )
        window.contentView = NSHostingView(rootView: SettingsView(
            model: model,
            preferences: preferences
        ))
        settingsWindow = window
        showCentered(window)
    }

    private func makeHistoryPanel(title: String, size: NSSize) -> NSPanel {
        let window = NonActivatingHistoryPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureCenteredPanel(window, title: title)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return window
    }

    private func makeSettingsPanel(title: String, size: NSSize) -> NSPanel {
        let window = CenteredPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.level = .floating
        window.delegate = self
        return window
    }

    private func configureCenteredPanel(_ window: NSPanel, title: String) {
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.level = .floating
        window.delegate = self
    }

    private func showCentered(_ window: NSWindow) {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showNonActivatingHistoryWindow(_ window: NSWindow) {
        window.center()
        window.orderFrontRegardless()
        window.makeKey()
    }
}

enum ClipboardPayload {
    case text(String)
    case file(URL)
    case image(URL)
}

final class CenteredPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class NonActivatingHistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension AppDelegate: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === historyWindow || window === settingsWindow {
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === historyWindow {
            historyWindow = nil
        }
        if window === settingsWindow {
            settingsWindow = nil
        }
    }
}

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

private struct InteractiveCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
            )
    }
}

private extension View {
    func interactiveCard() -> some View {
        modifier(InteractiveCardModifier())
    }
}

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
