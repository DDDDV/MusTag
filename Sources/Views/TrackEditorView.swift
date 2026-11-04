import SwiftUI

struct TrackEditorView: View {
    @EnvironmentObject private var model: AppModel
    let documentID: UUID
    @State private var showsReview = false
    @State private var showsDiscard = false

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
                        if let attribution = document.draftShazamAttribution {
                            ShazamAttributionView(attribution: attribution,
                                                  linkIdentifier: "draftAppleMusicLink")
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

                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            ArtworkPreviewButton(artwork: document.draftArtwork)
                                .accessibilityIdentifier("artworkPreviewButton")
                            if document.hasArtworkChanges {
                                Label(L10n.text("New cover · not saved", "新封面 · 尚未保存"), systemImage: "arrow.down.circle")
                                    .font(.subheadline)
                                    .foregroundStyle(.indigo)
                                Button {
                                    model.resetArtwork(for: documentID)
                                } label: {
                                    Text(document.originalArtwork == nil
                                         ? L10n.text("Discard cover change", "撤销封面修改")
                                         : L10n.text("Keep original cover", "保留原封面"))
                                }
                                .accessibilityIdentifier("resetArtworkButton")
                            } else {
                                Text(document.draftArtwork == nil
                                     ? L10n.text("No embedded cover", "文件暂无内嵌封面")
                                     : L10n.text("Current cover", "当前封面"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text(L10n.text("Cover", "封面"))
                    } footer: {
                        Text(L10n.text("Choose a matching result to download its cover. Tap the image to preview it; it is written only when you review and save.", "选择匹配结果后下载对应封面。点击图片可放大预览，确认保存后才会写入文件。"))
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
                                candidateView(candidate, document: document)
                            }
                        } header: {
                            Text(L10n.text("Matching candidates", "匹配候选"))
                        } footer: {
                            VStack(alignment: .leading, spacing: 6) {
                                if candidates.contains(where: { $0.score != nil }) {
                                    Text(L10n.text("Fingerprint matches are sorted by similarity. Tied matches or matches below 90% need manual selection. AcoustID supplies the available title and artist; other fields keep their current values.", "指纹候选按相似度从高到低排列。最高分并列或低于 90% 时需手动选择。AcoustID 提供可用的歌名和艺术家，其余字段保留现有内容。"))
                                }
                                if candidates.contains(where: { $0.source == .shazamKit }) {
                                    Text(L10n.text("Shazam and Apple Music details are combined in one result per song. If the album differs from your file, choose which album information to use within that result. If the lookup is unavailable, the Shazam details are kept. Check the edition before saving.", "同一首歌的 Shazam 识别与 Apple Music 补全合并为一个结果。专辑与文件原值不同时，在该结果中选择采用哪套专辑信息；查询不可用时保留 Shazam 信息。保存前请核对发行版本。"))
                                }
                                Text(L10n.text("Changes stay in the draft. When applying a match, missing fields keep their current values and unavailable covers keep the original cover. Review before saving.", "修改先填入草稿。采用匹配信息时，空缺字段保留现有内容，未获取到封面时保留原封面。预览确认后保存。"))
                            }
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
                            Button { model.identify([documentID], automaticallyApply: true) } label: {
                                Label(L10n.text("Auto-match", "自动匹配"), systemImage: "waveform")
                                    .frame(maxWidth: .infinity)
                            }
                            .accessibilityIdentifier("trackIdentifyButton")
                            .buttonStyle(.bordered)
                            Button { showsReview = true } label: {
                                Text(L10n.text("Review changes", "预览修改"))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!document.hasChanges)
                            .accessibilityIdentifier("trackReviewButton")
                            Text(model.recognitionHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
            } else {
                ContentUnavailableView(L10n.text("File removed", "文件已移除"), systemImage: "doc")
            }
        }
    }

    private func candidateView(_ candidate: MetadataCandidate, document: AudioDocument) -> some View {
        let isApplied = model.appliedCandidateIDs[documentID] == candidate.id
        let hasConflict = candidate.hasAlbumConflict(with: document.original.album)
        let releaseChoice = isApplied ? model.appliedReleaseChoices[documentID] : nil
        return VStack(alignment: .leading, spacing: 10) {
            if hasConflict {
                MetadataCandidateRow(candidate: candidate, isApplied: isApplied,
                                     originalAlbum: document.original.album, releaseChoice: releaseChoice)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("metadataCandidate_\(candidate.id)")
                Text(L10n.text("The albums differ. Album artist, year, track, disc and cover are handled with the album choice.",
                               "专辑与文件原值不同。专辑艺术家、年份、曲序、碟号及封面随专辑选择一起处理。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                releaseChoiceButton(candidate, choice: .keepOriginal,
                                    title: L10n.text("Keep original album information", "保留原专辑信息"),
                                    identifier: "keepOriginalAlbum_\(candidate.id)", selected: releaseChoice == .keepOriginal)
                releaseChoiceButton(candidate, choice: .appleMusic,
                                    title: L10n.text("Use Apple Music information", "采用 Apple Music 信息"),
                                    identifier: "useAppleMusicAlbum_\(candidate.id)", selected: releaseChoice == .appleMusic)
            } else {
                Button { model.useCandidate(candidate, for: documentID) } label: {
                    MetadataCandidateRow(candidate: candidate, isApplied: isApplied)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("metadataCandidate_\(candidate.id)")
                .accessibilityAddTraits(isApplied ? [.isSelected] : [])
                .disabled(model.isWorking)
            }
            if let appleMusicURL = candidate.appleMusicURL {
                Link(destination: appleMusicURL) {
                    Label(L10n.text("Listen on Apple Music", "在 Apple Music 中聆听"), systemImage: "arrow.up.right")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("appleMusicLink_\(candidate.id)")
            }
        }
    }

    private func releaseChoiceButton(_ candidate: MetadataCandidate, choice: CandidateReleaseChoice,
                                     title: String, identifier: String, selected: Bool) -> some View {
        Button { model.useCandidate(candidate, for: documentID, releaseChoice: choice) } label: {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .disabled(model.isWorking)
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

struct ShazamAttributionView: View {
    let attribution: ShazamAttribution
    @State private var showsMetadataDetails = false
    // A later manual edit or another match may preserve only some matched fields.
    // Describe the persisted match as a record, not as the source of every current tag.
    var context: String = L10n.text("Shazam recognition record", "Shazam 识别记录")
    let linkIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(context)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text([attribution.title, attribution.artist].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.subheadline)
            if let url = attribution.appleMusicURL {
                Link(destination: url) {
                    Label(L10n.text("Listen on Apple Music", "在 Apple Music 中聆听"), systemImage: "arrow.up.right")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(linkIdentifier)
            }
            if attribution.metadata != nil || attribution.appleMusicMetadata != nil {
                Button(L10n.text("Recognition details", "识别详情")) { showsMetadataDetails = true }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("shazamMetadataDetailsButton")
            }
        }
        .padding(.vertical, 3)
        .sheet(isPresented: $showsMetadataDetails) {
            RecognitionMetadataDetailsView(attribution: attribution)
        }
    }
}

private struct RecognitionMetadataDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    let attribution: ShazamAttribution

    var body: some View {
        NavigationStack {
            Form {
                if let metadata = attribution.metadata {
                    Section {
                        metadataRow("title", L10n.text("Title", "歌名"), metadata.title)
                        metadataRow("artist", L10n.text("Artist", "艺术家"), metadata.artist)
                        metadataRow("subtitle", L10n.text("Subtitle", "副标题"), metadata.subtitle)
                        metadataRow("isrc", "ISRC", metadata.isrc)
                        metadataRow("appleMusicID", L10n.text("Apple Music song ID", "Apple Music 歌曲标识"), metadata.appleMusicID)
                        metadataRow("shazamID", L10n.text("Shazam ID", "Shazam 标识"), metadata.id)
                        metadataRow("genres", L10n.text("Genres", "流派"), metadata.genres.joined(separator: " · "))
                    } header: {
                        Text("Shazam")
                    } footer: {
                        Text(L10n.text("This is the recognition record. Later edits may change the tags in your file.", "此处显示识别时的记录，后续编辑可能改变文件中的标签。"))
                    }
                }
                if let metadata = attribution.appleMusicMetadata {
                    Section {
                        metadataRow("catalogID", L10n.text("Song ID", "歌曲标识"), metadata.id)
                        metadataRow("album", L10n.text("Album", "专辑"), metadata.albumTitle)
                        metadataRow("albumArtist", L10n.text("Album artist", "专辑艺术家"), metadata.albumArtist)
                        metadataRow("releaseDate", L10n.text("Release date", "发行日期"), metadata.releaseDate.map {
                            String(ISO8601DateFormatter().string(from: $0).prefix(10))
                        })
                        metadataRow("trackNumber", L10n.text("Track", "曲序"), metadata.trackNumber.map(String.init))
                        metadataRow("discNumber", L10n.text("Disc", "碟号"), metadata.discNumber.map(String.init))
                    } header: {
                        Text("Apple Music")
                    } footer: {
                        Text(L10n.text("The date, track and disc describe this Apple Music edition. They may differ from the original release or your physical disc.", "日期、曲序及碟号属于此 Apple Music 发行版本，可能与最初发行版本或实体唱片不同。"))
                    }
                }
            }
            .navigationTitle(L10n.text("Recognition details", "识别详情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done", "完成")) { dismiss() }
                        .accessibilityIdentifier("shazamMetadataDetailsDoneButton")
                }
            }
        }
    }

    @ViewBuilder
    private func metadataRow(_ key: String, _ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label, value: value)
                .textSelection(.enabled)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(value)
                .accessibilityIdentifier("shazamMetadata_\(key)")
        }
    }
}

private struct MetadataCandidateRow: View {
    let candidate: MetadataCandidate
    let isApplied: Bool
    var originalAlbum: String? = nil
    var releaseChoice: CandidateReleaseChoice? = nil

    private var needsAlbumChoice: Bool { isApplied && originalAlbum != nil && releaseChoice == nil }

    private var appliedText: String {
        guard originalAlbum != nil else { return L10n.text("Applied to draft", "已填入草稿") }
        switch releaseChoice {
        case .keepOriginal:
            return L10n.text("Original album information kept · applied to draft", "保留原专辑信息 · 已填入草稿")
        case .appleMusic:
            return L10n.text("Apple Music information applied to draft", "已采用 Apple Music 信息")
        case nil:
            return L10n.text("Song details added · choose album information", "歌曲信息已填入 · 请选择专辑信息")
        }
    }

    private var similarity: String? {
        guard let score = candidate.score, score.isFinite, (0...1).contains(score) else { return nil }
        // Truncate instead of rounding a sub-threshold score up to 90%.
        return String(format: "%.2f%%", (score * 10_000).rounded(.down) / 100)
    }

    private var editionDetails: String {
        var parts: [String] = []
        if !candidate.tags.year.isEmpty {
            parts.append(L10n.text("Year \(candidate.tags.year)", "年份 \(candidate.tags.year)"))
        }
        if !candidate.tags.discNumber.isEmpty {
            parts.append(L10n.text("Disc \(candidate.tags.discNumber)", "碟号 \(candidate.tags.discNumber)"))
        }
        if !candidate.tags.trackNumber.isEmpty {
            parts.append(L10n.text("Track \(candidate.tags.trackNumber)", "曲序 \(candidate.tags.trackNumber)"))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(candidate.tags.title).foregroundStyle(.primary).fontWeight(.medium)
                Text(candidate.tags.artist).font(.subheadline).foregroundStyle(.secondary)
                if candidate.source == .shazamKit {
                    Text(L10n.text("Recognized with Shazam", "由 Shazam 识别"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.indigo)
                }
                if let originalAlbum {
                    Text(L10n.text("Original album: ", "文件原专辑：") + originalAlbum)
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(L10n.text("Apple Music album: ", "Apple Music 专辑：") + candidate.tags.album)
                        .font(.subheadline).foregroundStyle(.primary)
                } else if !candidate.tags.album.isEmpty {
                    Text(candidate.tags.album).font(.subheadline).foregroundStyle(.primary)
                }
                if !editionDetails.isEmpty {
                    Text(editionDetails).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !candidate.detail.isEmpty {
                    Text(candidate.detail).font(.caption).foregroundStyle(.secondary)
                }
                if let notice = candidate.supplementationNotice, !notice.isEmpty {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("metadataSupplementationNotice_\(candidate.id)")
                }
                if let similarity {
                    Text(L10n.text("Fingerprint similarity \(similarity)", "指纹相似度 \(similarity)"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if isApplied {
                    Text(appliedText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.indigo)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: needsAlbumChoice ? "exclamationmark.circle" : (isApplied ? "checkmark.circle.fill" : "arrow.down.to.line"))
                .font(.subheadline)
                .foregroundStyle(isApplied ? Color.indigo : Color.secondary)
                .padding(.top, 3)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
    }
}

func displayTag(_ value: String) -> String {
    value.isEmpty ? L10n.text("Empty", "空") : value
}
