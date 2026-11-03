import SwiftUI

struct ReviewSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let documentIDs: [UUID]

    private var documents: [AudioDocument] {
        model.documents.filter { documentIDs.contains($0.id) && $0.hasChanges }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(L10n.text("Original files will be updated. A full backup is kept for undo.", "将更新原文件，并保留完整备份以便撤销。"), systemImage: "arrow.uturn.backward.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(documents) { document in
                    Section {
                        if document.hasArtworkChanges {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(L10n.text("Cover", "封面"))
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack(alignment: .top, spacing: 16) {
                                    VStack(spacing: 8) {
                                        ArtworkPreviewButton(artwork: document.originalArtwork, size: 112,
                                                             label: L10n.text("Preview original cover", "预览原封面"))
                                            .accessibilityIdentifier("originalArtworkPreview")
                                        Text(document.originalArtwork == nil
                                             ? L10n.text("No original cover", "原文件无封面")
                                             : L10n.text("Original", "原封面"))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    VStack(spacing: 8) {
                                        ArtworkPreviewButton(artwork: document.draftArtwork, size: 112,
                                                             label: L10n.text("Preview new cover", "预览新封面"))
                                            .accessibilityIdentifier("draftArtworkPreview")
                                        Text(L10n.text("New cover", "新封面"))
                                            .font(.caption.weight(.medium)).foregroundStyle(.indigo)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                Text(L10n.text("The new front cover will be embedded in the audio file.", "新正面封面将写入音频文件。"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        ForEach(TagField.allCases.filter { $0.value(in: document.original) != $0.value(in: document.draft) }) { field in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(field.label).font(.caption).foregroundStyle(.secondary)
                                Text(displayTag(field.value(in: document.original)))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .strikethrough()
                                    .textSelection(.enabled)
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "arrow.right").font(.caption).accessibilityHidden(true)
                                    Text(displayTag(field.value(in: document.draft)))
                                        .font(.subheadline.weight(.medium))
                                        .textSelection(.enabled)
                                }
                                .foregroundStyle(.indigo)
                            }
                            .padding(.vertical, 3)
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text(document.fileName).textCase(nil)
                    }
                }
            }
            .navigationTitle(L10n.text("Review changes", "预览修改"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Cancel", "取消")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.save(Set(documents.map(\.id)))
                    dismiss()
                } label: {
                    Text(L10n.text("Save \(documents.count) file\(documents.count == 1 ? "" : "s")", "保存 \(documents.count) 个文件"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(documents.isEmpty || model.isWorking)
                .padding()
                .background(.bar)
                .accessibilityIdentifier("confirmSaveButton")
            }
        }
    }
}
