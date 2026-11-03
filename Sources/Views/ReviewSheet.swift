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
