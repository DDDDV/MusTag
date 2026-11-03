import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var keyError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(L10n.text("Application API key", "Application API Key"), text: $key)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("apiKeyField")
                    if key != model.apiKey {
                        Button(L10n.text("Save key", "保存 Key")) {
                            do { try model.saveAPIKey(key); keyError = nil }
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
                    Text(L10n.text("Use an application key, not a user key. Recognition sends only the audio fingerprint and duration. Your key is stored securely on this device. Manual editing and title search work without a key.", "请填写应用 Key，而非用户 Key。识别仅发送音频指纹和时长；Key 安全保存在此设备。未配置时仍可手动编辑和按歌名搜索。"))
                }

                Section {
                    NavigationLink {
                        BackupHistoryView()
                    } label: {
                        Label(L10n.text("Undo saved changes", "撤销已保存的修改"), systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("backupHistoryButton")
                } footer: {
                    Text(L10n.text("Backups are stored on this device and use storage. Keep the app installed until you no longer need them.", "备份保存在此设备，会占用存储空间。需要恢复时，请保留此 App 及其数据。"))
                }

                Section {
                    LabeledContent(L10n.text("Version", "版本"), value: "0.1.0")
                    NavigationLink(L10n.text("Open-source licenses", "开源许可")) { LicenseView() }
                        .accessibilityIdentifier("licensesButton")
                } footer: {
                    Text(L10n.text("Personal preview · MP3, FLAC and M4A", "个人预览版 · MP3、FLAC 和 M4A"))
                }
            }
            .navigationTitle(L10n.text("Settings", "设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done", "完成")) {
                        if key != model.apiKey {
                            do { try model.saveAPIKey(key) }
                            catch { keyError = error.localizedDescription; return }
                        }
                        dismiss()
                    }
                    .accessibilityIdentifier("settingsDoneButton")
                }
            }
            .onAppear { key = model.apiKey }
            .task { await model.refreshBackups() }
            .alert(L10n.text("Notice", "提示"), isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                Button(L10n.text("OK", "好"), role: .cancel) { model.notice = nil }
            } message: { Text(model.notice ?? "") }
        }
    }
}

private struct BackupHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var restoring: BackupRecord?

    var body: some View {
        Group {
            if model.backupRecords.isEmpty {
                ContentUnavailableView(L10n.text("No saved changes yet", "尚无已保存的修改"), systemImage: "clock.arrow.circlepath", description: Text(L10n.text("A backup is created before each file is changed.", "每次修改文件前会自动创建备份。")))
            } else {
                List(model.backupRecords.sorted { $0.createdAt > $1.createdAt }) { backup in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(backup.originalURL.lastPathComponent).font(.body.weight(.medium))
                        Text(backup.createdAt, format: .dateTime.year().month().day().hour().minute())
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
                NavigationLink("TagLib · MPL 1.1") { LicenseTextView(name: "TagLib-MPL-1.1") }
                    .accessibilityIdentifier("taglibLicenseButton")
                NavigationLink("TagLib · LGPL") { LicenseTextView(name: "TagLib-LGPL") }
                NavigationLink("Chromaprint · LGPL 2.1") { LicenseTextView(name: "Chromaprint") }
                NavigationLink("utf8cpp · Boost Software License") { LicenseTextView(name: "utf8cpp") }
            }
            Section {
                Link("AcoustID", destination: URL(string: "https://acoustid.org/")!)
                Link("MusicBrainz", destination: URL(string: "https://musicbrainz.org/")!)
                Link("Cover Art Archive", destination: URL(string: "https://coverartarchive.org/")!)
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
