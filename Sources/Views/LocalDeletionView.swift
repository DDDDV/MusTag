import SwiftUI

extension View {
    func localDeletionConfirmation(isEnabled: Bool = true) -> some View {
        modifier(LocalDeletionConfirmationModifier(isEnabled: isEnabled))
    }
}

private struct LocalDeletionConfirmationModifier: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let isEnabled: Bool
    @State private var confirming = false

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { isEnabled && !confirming ? model.deletionPlan : nil },
                set: { if $0 == nil && isEnabled && !confirming { model.cancelDeletion() } }
            ), onDismiss: {
                // Finish dismissing before executing so a fast result can present
                // the shared notice alert without competing with this sheet.
                if confirming {
                    model.confirmDeletion()
                    confirming = false
                }
            }) { plan in
                LocalDeletionConfirmationView(plan: plan) { confirming = true }
            }
            .overlay {
                if isEnabled && model.isPreparingDeletion {
                    ProgressView(L10n.text("Checking local files…", "正在检查本地文件…"))
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("preparingDeletionProgress")
                }
            }
    }
}

private struct LocalDeletionConfirmationView: View {
    @EnvironmentObject private var model: AppModel
    let plan: LocalDeletionPlan
    let confirm: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(L10n.text("Files: \(plan.fileCount) · Folders: \(plan.folderCount)", "\(plan.fileCount) 个文件 · \(plan.folderCount) 个文件夹"), systemImage: "trash")
                        .font(.headline)
                        .accessibilityIdentifier("localDeletionSummary")
                    LabeledContent(L10n.text("File size", "文件总大小"), value: ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))
                }
                Section {
                    if plan.folderCount > 0 {
                        Text(L10n.text("Selected folders and all their subfolders and local files will be deleted, including artwork and other non-audio files.", "将删除所选文件夹及其所有子文件夹和本地文件，包括封面等非音频文件。"))
                    }
                    Text(L10n.text("Library entries and unsaved changes will also be removed. Files on your server and original import sources are unaffected.", "同时清除列表记录和未保存的修改。服务器及原导入来源的文件不受影响。"))
                    Text(L10n.text("This cannot be undone in MusTag. Download or import files again if needed. Saved backups are kept, but metadata backups cannot recover deleted audio.", "删除后无法在 MusTag 内撤销，需要重新下载或导入。已保存的备份会保留，但元数据备份无法找回已删除的音频。"))
                }
                .font(.subheadline)
                Section(L10n.text("Selected items", "所选项目")) {
                    ForEach(plan.roots, id: \.self) { url in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent)
                            Text(relativePath(url))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(L10n.text("Confirm deletion", "确认删除"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button(role: .destructive, action: confirm) {
                    Text(L10n.text("Delete local files and folders", "删除本地文件与文件夹"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .padding()
                .background(.bar)
                .accessibilityIdentifier("confirmLocalDeleteButton")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Cancel", "取消")) { model.cancelDeletion() }
                        .accessibilityIdentifier("cancelLocalDeleteButton")
                }
            }
        }
        .interactiveDismissDisabled(false)
    }

    private func relativePath(_ url: URL) -> String {
        let root = model.localLibraryDirectory.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? "Music/" + String(path.dropFirst(root.count)) : url.lastPathComponent
    }
}
