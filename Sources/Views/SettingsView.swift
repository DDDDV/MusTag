import SwiftUI

private enum SettingsDestination: Hashable {
    case backups, licenses
    case license(String)
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var key = ""
    @State private var hasLoadedKey = false
    @State private var keyError: String?
    @FocusState private var keyIsFocused: Bool

    var body: some View {
        NavigationStack(path: $model.settingsNavigationPath) {
            Form {
                Section {
                    Picker(L10n.text("Recognition service", "识别服务"), selection: $model.recognitionProvider) {
                        ForEach(RecognitionProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("recognitionProviderPicker")
                    .disabled(model.isWorking)
                    if model.recognitionProvider == .shazamKit {
                        LabeledContent("ShazamKit", value: L10n.text("No API key needed", "无需 API Key"))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("ShazamKit")
                            .accessibilityValue(L10n.text("No API key needed", "无需 API Key"))
                            .accessibilityIdentifier("recognitionStatus")
                    }
                } header: {
                    Text(L10n.text("Music recognition", "歌曲识别"))
                } footer: {
                    if model.recognitionProvider == .shazamKit {
                        Text(L10n.text("ShazamKit identifies selected files without using the microphone. Audio signatures are sent to Apple; the original audio is not uploaded. Apple Music can complete album, year, track and disc details after you grant music access. Review matched tags and covers before saving.", "ShazamKit 直接识别所选文件，无需使用麦克风。音频签名会发送至 Apple，原音频不会上传。授予音乐访问权限后，可通过 Apple Music 补全专辑、年份、曲序和碟号。匹配的标签和封面需预览确认后保存。"))
                    }
                }

                if model.recognitionProvider == .acoustID {
                    Section {
                        SecureField(L10n.text("Application API key", "Application API Key"), text: $key)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($keyIsFocused)
                            .accessibilityIdentifier("apiKeyField")
                        if key != model.apiKey {
                            Button(L10n.text("Save key", "保存 Key")) {
                                do {
                                    try model.saveAPIKey(key)
                                    key = model.apiKey
                                    keyError = nil
                                    keyIsFocused = false
                                }
                                catch { keyError = error.localizedDescription }
                            }
                            .accessibilityIdentifier("saveKeyButton")
                        }
                        if let keyError {
                            Text(keyError).font(.footnote).foregroundStyle(.red)
                        }
                        LabeledContent(L10n.text("Fingerprint recognition", "指纹识别")) {
                            Text(model.hasAPIKey ? L10n.text("Configured", "已配置") : L10n.text("Key required", "需要配置 Key"))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.text("Fingerprint recognition", "指纹识别"))
                        .accessibilityValue(model.hasAPIKey ? L10n.text("Configured", "已配置") : L10n.text("Key required", "需要配置 Key"))
                        .accessibilityIdentifier("recognitionStatus")
                        Link(L10n.text("Get an AcoustID application key", "获取 AcoustID 应用 Key"), destination: URL(string: "https://acoustid.org/new-application")!)
                    } header: {
                        Text("AcoustID")
                    } footer: {
                        Text(L10n.text("Use an application key, not a user key. Recognition sends only the audio fingerprint and duration, and fills the available title and artist. Your key is stored securely on this device. ShazamKit and manual editing work without a key.", "请填写应用 Key，而非用户 Key。识别仅发送音频指纹和时长，填入可用的歌名与艺术家；Key 安全保存在此设备。未配置时仍可使用 ShazamKit 和手动编辑。"))
                    }
                }

                Section {
                    NavigationLink(value: SettingsDestination.backups) {
                        Label(L10n.text("Undo saved changes", "撤销已保存的修改"), systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("backupHistoryButton")
                } footer: {
                    Text(L10n.text("New backups store the original tags and covers without audio. To undo changes, keep the audio files and this app's data. Older full-file backups remain available.", "新备份仅保存原标签、封面等信息，不包含音频内容。撤销修改需要保留音频文件及此 App 的数据。旧版完整文件备份仍可使用。"))
                }

                Section {
                    LabeledContent(L10n.text("Version", "版本"), value: "0.1.0")
                    NavigationLink(L10n.text("Open-source licenses", "开源许可"), value: SettingsDestination.licenses)
                        .accessibilityIdentifier("licensesButton")
                } footer: {
                    Text(L10n.text("Personal preview · MP3, FLAC and M4A", "个人预览版 · MP3、FLAC 和 M4A"))
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(L10n.text("Settings", "设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if keyIsFocused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(L10n.text("Done", "完成")) { keyIsFocused = false }
                            .accessibilityIdentifier("dismissKeyboardButton")
                    }
                }
            }
            .onAppear {
                guard !hasLoadedKey else { return }
                key = model.apiKey
                hasLoadedKey = true
            }
            .task { await model.refreshBackups() }
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .backups: BackupHistoryView()
                case .licenses: LicenseView()
                case .license(let name): LicenseTextView(name: name)
                }
            }
        }
    }
}

private struct BackupHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var restoring: BackupRecord?

    var body: some View {
        Group {
            if model.backupRecords.isEmpty {
                ContentUnavailableView(L10n.text("No saved changes yet", "尚无已保存的修改"), systemImage: "clock.arrow.circlepath", description: Text(L10n.text("Original tags and covers are backed up before each save.", "每次保存前会自动备份原标签和封面。")))
            } else {
                List(model.backupRecords.sorted { $0.createdAt > $1.createdAt }) { backup in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(backup.originalURL.lastPathComponent).font(.body.weight(.medium))
                        Text(backup.createdAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                        Text(backup.backupHash == nil
                             ? L10n.text("Full-file backup · older version", "完整文件备份 · 旧版")
                             : L10n.text("Tags and covers · audio file required to restore", "标签和封面备份 · 恢复需保留音频文件"))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if backup.restored {
                                Label(L10n.text("Restored", "已恢复"), systemImage: "checkmark")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            } else {
                                Button(L10n.text("Restore original", "恢复原文件")) { restoring = backup }
                                    .disabled(model.isWorking)
                            }
                            Spacer()
                            ShareLink(item: backup.backupURL) {
                                Label(L10n.text("Export backup", "导出备份"), systemImage: "square.and.arrow.up")
                                    .font(.subheadline)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .navigationTitle(L10n.text("Undo changes", "撤销修改"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { if model.isWorking { OperationFooter() } }
        .confirmationDialog(L10n.text("Restore this backup?", "恢复这份备份？"), isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible, presenting: restoring) { backup in
            Button(L10n.text("Restore original", "恢复原文件"), role: .destructive) {
                model.restore(backup)
                restoring = nil
            }
            .accessibilityIdentifier("confirmRestoreButton")
        } message: { _ in
            Text(L10n.text("The saved changes will be undone. If another app has changed the file, restoration will stop to protect it.", "将撤销该次保存的修改。如果文件已被其他 App 更改，恢复操作会停止以保护文件。"))
        }
    }
}

private struct LicenseView: View {
    var body: some View {
        List {
            Section {
                NavigationLink("TagLib · MPL 1.1", value: SettingsDestination.license("TagLib-MPL-1.1"))
                    .accessibilityIdentifier("taglibLicenseButton")
                NavigationLink("TagLib · LGPL", value: SettingsDestination.license("TagLib-LGPL"))
                NavigationLink("Chromaprint · LGPL 2.1", value: SettingsDestination.license("Chromaprint"))
                NavigationLink("utf8cpp · Boost Software License", value: SettingsDestination.license("utf8cpp"))
                NavigationLink("SMBClient · MIT", value: SettingsDestination.license("SMBClient"))
            }
            Section {
                Link("ShazamKit", destination: URL(string: "https://developer.apple.com/shazamkit/")!)
                Link("AcoustID", destination: URL(string: "https://acoustid.org/")!)
                Link("MusicKit", destination: URL(string: "https://developer.apple.com/musickit/")!)
            } header: { Text(L10n.text("Metadata services", "元数据服务")) }
        }
        .navigationTitle(L10n.text("Acknowledgements", "致谢"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseTextView: View {
    let name: String
    private var contents: String {
        let url = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Resources/Licenses")
            ?? Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Licenses")
            ?? Bundle.main.url(forResource: name, withExtension: "txt")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return L10n.text("License file unavailable.", "未找到许可文件。")
        }
        return text
    }
    var body: some View {
        ScrollView {
            Text(contents)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
                .accessibilityIdentifier("licenseText")
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
