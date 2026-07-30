import MCGACore
import SwiftUI

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
