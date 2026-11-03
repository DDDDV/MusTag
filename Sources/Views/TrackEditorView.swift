import SwiftUI

struct TrackEditorView: View {
    @EnvironmentObject private var model: AppModel
    let documentID: UUID
    @State private var showsReview = false
    @State private var showsDiscard = false
    @State private var showsSearch = false

    var body: some View {
        Group {
            if let document = model.document(documentID) {
                Form {
                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "waveform")
                                .font(.title2)
                                .foregroundStyle(.indigo)
                                .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(document.fileName).font(.subheadline.weight(.medium)).textSelection(.enabled)
                                Text(document.url.deletingLastPathComponent().lastPathComponent)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }

                    Section {
                        tagInput(.title, document: document)
                        tagInput(.artist, document: document)
                        tagInput(.album, document: document)
                        tagInput(.albumArtist, document: document)
                    }

                    Section {
                        tagInput(.year, document: document)
                        tagInput(.trackNumber, document: document)
                        tagInput(.discNumber, document: document)
                        tagInput(.genre, document: document)
                    } footer: {
                        Text(L10n.text("Changes stay in the draft until you review and save.", "修改先保存在草稿中，预览确认后才会写入文件。"))
                    }

                    if let error = document.error {
                        Section {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let candidates = model.candidates[documentID], !candidates.isEmpty {
                        Section {
                            ForEach(candidates) { candidate in
                                Button { model.useCandidate(candidate, for: documentID) } label: {
                                    MetadataCandidateRow(candidate: candidate)
                                }
                                .disabled(model.isWorking)
                            }
                        } header: {
                            Text(L10n.text("Choose a match", "选择匹配版本"))
                        } footer: {
                            Text(L10n.text("MusicBrainz · Select your release to fill the draft. Empty fields keep your existing values.", "MusicBrainz · 选择对应发行版本以填入草稿。空缺字段会保留现有内容。"))
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .disabled(model.isWorking)
                .navigationTitle(L10n.text("Edit tags", "编辑标签"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(role: .destructive) { showsDiscard = true } label: {
                                Label(L10n.text("Discard draft", "撤销草稿修改"), systemImage: "arrow.uturn.backward")
                            }
                            .disabled(!document.hasChanges || model.isWorking)
                        } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel(L10n.text("More options", "更多操作"))
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if model.isWorking { OperationFooter() }
                    else {
                        VStack(spacing: 10) {
                            HStack(spacing: 12) {
                                Button { model.identify([documentID]) } label: {
                                    Label(L10n.text("Identify", "指纹识别"), systemImage: "waveform")
                                        .frame(maxWidth: .infinity)
                                }
                                .accessibilityIdentifier("trackIdentifyButton")
                                Button { showsSearch = true } label: {
                                    Label(L10n.text("Search", "按歌名搜索"), systemImage: "magnifyingglass")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.bordered)
                            Button { showsReview = true } label: {
                                Text(L10n.text("Review changes", "预览修改"))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!document.hasChanges)
                            .accessibilityIdentifier("trackReviewButton")
                        }
                        .controlSize(.large)
                        .padding(.horizontal)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                        .background(.bar)
                    }
                }
                .confirmationDialog(L10n.text("Discard unsaved changes?", "撤销尚未写入的修改？"), isPresented: $showsDiscard, titleVisibility: .visible) {
                    Button(L10n.text("Discard changes", "撤销修改"), role: .destructive) { model.discardChanges(for: documentID) }
                }
                .sheet(isPresented: $showsReview) { ReviewSheet(documentIDs: [documentID]) }
                .sheet(isPresented: $showsSearch) {
                    MetadataSearchSheet(documentID: documentID, title: document.draft.title, artist: document.draft.artist)
                }
            } else {
                ContentUnavailableView(L10n.text("File removed", "文件已移除"), systemImage: "doc")
            }
        }
    }

    private func tagInput(_ field: TagField, document: AudioDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.label).font(.caption).foregroundStyle(.secondary)
            TextField(field.label, text: Binding(get: {
                model.document(documentID).map { field.value(in: $0.draft) } ?? ""
            }, set: { value in
                guard let current = model.document(documentID) else { return }
                var tags = current.draft
                field.set(value, in: &tags)
                model.updateDraft(tags, for: documentID)
            }), axis: .vertical)
            .lineLimit(1...3)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .accessibilityIdentifier("tag_\(field.rawValue)")
            if field.value(in: document.original) != field.value(in: document.draft) {
                Text(L10n.text("Was: ", "原值：") + displayTag(field.value(in: document.original)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct MetadataCandidateRow: View {
    let candidate: MetadataCandidate
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(candidate.tags.title).foregroundStyle(.primary).fontWeight(.medium)
                Text(candidate.tags.artist).font(.subheadline).foregroundStyle(.secondary)
                if !candidate.tags.album.isEmpty {
                    Text(candidate.tags.album).font(.subheadline).foregroundStyle(.primary)
                }
                if !candidate.detail.isEmpty {
                    Text(candidate.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.down.to.line").font(.subheadline).padding(.top, 3)
        }
        .padding(.vertical, 3)
    }
}

private struct MetadataSearchSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let documentID: UUID
    @State var title: String
    @State var artist: String

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.text("Title", "歌名"), text: $title)
                    TextField(L10n.text("Artist (optional)", "艺术家（可选）"), text: $artist)
                } footer: {
                    Text(L10n.text("Search titles and artists on MusicBrainz. No API key needed.", "将歌名和艺术家发送至 MusicBrainz 搜索，无需 API Key。"))
                }
            }
            .autocorrectionDisabled()
            .navigationTitle(L10n.text("Search metadata", "搜索元数据"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Cancel", "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Search", "搜索")) {
                        model.search(documentID, title: title, artist: artist)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

func displayTag(_ value: String) -> String {
    value.isEmpty ? L10n.text("Empty", "空") : value
}
