import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            LibraryContentsView()
                .navigationDestination(for: UUID.self) { id in
                    TrackEditorView(documentID: id)
                }
                .navigationDestination(for: AudioFolder.self) { folder in
                    LibraryContentsView(folder: folder)
                }
        }
        .sheet(isPresented: $model.showsSettings) { SettingsView() }
        .alert(L10n.text("Notice", "提示"), isPresented: Binding(get: { model.notice != nil && !model.showsSettings }, set: { if !$0 { model.notice = nil } })) {
            Button(L10n.text("OK", "好"), role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }
}

private struct LibraryContentsView: View {
    @EnvironmentObject private var model: AppModel
    var folder: AudioFolder? = nil
    @State private var picker: AudioPickerMode?
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var review: ReviewRequest?
    @State private var removalIDs: Set<UUID>?

    // The home page acts on the whole library; a folder acts only on its own files.
    private var scopeDocuments: [AudioDocument] {
        if let folder { return model.documents(in: folder) }
        return model.documents
    }
    private var visibleDocuments: [AudioDocument] {
        folder == nil ? model.standaloneDocuments : scopeDocuments
    }
    private var scopeIDs: Set<UUID> { Set(scopeDocuments.map(\.id)) }
    private var targetIDs: Set<UUID> { selecting ? selected.intersection(scopeIDs) : scopeIDs }
    private var changedTargetIDs: [UUID] {
        scopeDocuments.filter { targetIDs.contains($0.id) && $0.hasChanges }.map(\.id)
    }
    private var isEmpty: Bool {
        folder == nil ? model.documents.isEmpty && model.folders.isEmpty : scopeDocuments.isEmpty
    }

    var body: some View {
        Group {
            if isEmpty {
                emptyState
            } else {
                List {
                    if selecting {
                        Section {
                            HStack {
                                Text(L10n.text("\(scopeDocuments.count) files", "\(scopeDocuments.count) 个文件"))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(selected == scopeIDs ? L10n.text("Deselect all", "取消全选") : L10n.text("Select all", "全选")) {
                                    selected = selected == scopeIDs ? [] : scopeIDs
                                }
                                .accessibilityIdentifier("selectAllButton")
                            }
                            .font(.subheadline)
                        }
                    }
                    if folder == nil, !model.folders.isEmpty {
                        Section(L10n.text("Folders", "文件夹")) {
                            ForEach(model.folders) { folder in
                                folderRow(folder)
                            }
                        }
                    }
                    if !visibleDocuments.isEmpty {
                        Section {
                            ForEach(visibleDocuments) { document in
                                audioRow(document)
                            }
                        } header: {
                            Text(folder == nil
                                 ? L10n.text("Files · \(visibleDocuments.count)", "文件 · \(visibleDocuments.count)")
                                 : L10n.text("\(visibleDocuments.count) files", "\(visibleDocuments.count) 个文件"))
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(folder?.name ?? "MusTag")
        .toolbar {
            ToolbarItem(placement: folder == nil ? .topBarLeading : .topBarTrailing) {
                if !scopeDocuments.isEmpty {
                    Button(selecting ? L10n.text("Done", "完成") : L10n.text("Select", "选择")) {
                        selecting.toggle()
                        selected = []
                    }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("librarySelectButton")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if folder == nil {
                    if !isEmpty { addMenu.disabled(model.isWorking) }
                    Button { model.showsSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(L10n.text("Settings", "设置"))
                    .accessibilityIdentifier("settingsButton")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isWorking {
                OperationFooter()
            } else if !scopeDocuments.isEmpty {
                batchActions
            }
        }
        .onChange(of: scopeIDs) { _, ids in
            selected.formIntersection(ids)
            if ids.isEmpty { selecting = false }
        }
        .sheet(item: $picker) { mode in
            AudioDocumentPicker(mode: mode, onPick: { urls in
                model.importFiles(urls)
                picker = nil
            }, onCancel: { picker = nil })
        }
        .sheet(item: $review) { request in ReviewSheet(documentIDs: request.ids) }
        .confirmationDialog(
            L10n.text("Remove \(removalIDs?.count ?? 0) selected files?", "移除选中的 \(removalIDs?.count ?? 0) 个文件？"),
            isPresented: Binding(get: { removalIDs != nil }, set: { if !$0 { removalIDs = nil } }),
            titleVisibility: .visible,
            presenting: removalIDs
        ) { ids in
            Button(L10n.text("Remove from list", "从列表移除"), role: .destructive) {
                guard !model.isWorking else { return }
                model.remove(ids.intersection(scopeIDs))
                selected = []
                selecting = false
            }
            .disabled(model.isWorking)
            .accessibilityIdentifier("confirmRemoveButton")
            Button(L10n.text("Cancel", "取消"), role: .cancel) { }
        } message: { _ in
            Text(L10n.text(
                "These files will be removed from the MusTag list and their unsaved changes discarded. Original audio files and saved backups will be kept.",
                "这些文件将从 MusTag 列表移除，尚未保存的修改将丢弃。原始音频文件和已保存的备份会保留。"
            ))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if folder != nil {
            ContentUnavailableView {
                Label(L10n.text("No audio files", "暂无音频文件"), systemImage: "folder")
            } description: {
                Text(L10n.text("This folder has no imported MP3, FLAC or M4A files. Choose it again from the home page to refresh its contents.", "此文件夹中暂无已导入的 MP3、FLAC 或 M4A 文件。可在首页重新选择此文件夹以刷新内容。"))
            }
            .accessibilityIdentifier("folderEmptyState")
        } else {
            ContentUnavailableView {
                Label(L10n.text("Your music, organized", "整理你的音乐"), systemImage: "music.note.list")
            } description: {
                Text(L10n.text("Edit MP3, FLAC and M4A files from Files, iCloud Drive or your NAS.", "编辑来自“文件”、iCloud Drive 或 NAS 的 MP3、FLAC 和 M4A 文件。"))
            } actions: {
                addMenu
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
            }
        }
    }

    private func folderRow(_ folder: AudioFolder) -> some View {
        let documents = model.documents(in: folder)
        let ids = Set(documents.map(\.id))
        let selectedCount = selected.intersection(ids).count
        return HStack(spacing: 12) {
            if selecting {
                Button {
                    if ids.isSubset(of: selected) { selected.subtract(ids) }
                    else { selected.formUnion(ids) }
                } label: {
                    Image(systemName: selectedCount == 0 ? "circle" : selectedCount == ids.count ? "checkmark.circle.fill" : "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(selectedCount > 0 ? Color.accentColor : .secondary)
                        .frame(minWidth: 32, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .disabled(ids.isEmpty || model.isWorking)
                .accessibilityLabel(L10n.text("Select files in \(folder.name)", "选择“\(folder.name)”中的文件"))
                .accessibilityValue(L10n.text("\(selectedCount) of \(ids.count) selected", "已选 \(selectedCount) 个，共 \(ids.count) 个"))
            }
            NavigationLink(value: folder) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.title2)
                        .foregroundStyle(.indigo)
                        .frame(width: 44, height: 44)
                        .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(folder.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(L10n.text("\(documents.count) audio files", "\(documents.count) 个音频文件"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if model.folders.filter({ $0.name == folder.name }).count > 1 {
                            Text(folder.url.deletingLastPathComponent().path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        let changedCount = documents.filter(\.hasChanges).count
                        if changedCount > 0 {
                            Text(L10n.text("\(changedCount) changes to review", "\(changedCount) 个文件有待确认的修改"))
                                .font(.caption)
                                .foregroundStyle(.indigo)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            .accessibilityIdentifier("folderRow_\(folder.name)")
        }
        .swipeActions {
            if !selecting {
                Button(role: .destructive) { model.removeFolder(folder) } label: {
                    Label(L10n.text("Remove from list", "从列表移除"), systemImage: "minus.circle")
                }
                .disabled(model.isWorking)
            }
        }
    }

    @ViewBuilder
    private func audioRow(_ document: AudioDocument) -> some View {
        if selecting {
            Button {
                if selected.contains(document.id) { selected.remove(document.id) }
                else { selected.insert(document.id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selected.contains(document.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected.contains(document.id) ? Color.accentColor : .secondary)
                    AudioRow(document: document, candidateCount: model.candidates[document.id]?.count ?? 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isWorking)
            .accessibilityAddTraits(selected.contains(document.id) ? [.isSelected] : [])
            .accessibilityIdentifier("audioRow_\(document.fileName)")
        } else {
            NavigationLink(value: document.id) {
                AudioRow(document: document, candidateCount: model.candidates[document.id]?.count ?? 0)
            }
            .accessibilityIdentifier("audioRow_\(document.fileName)")
            .swipeActions {
                Button(role: .destructive) { model.remove([document.id]) } label: {
                    Label(L10n.text("Remove from list", "从列表移除"), systemImage: "minus.circle")
                }
                .disabled(model.isWorking)
            }
        }
    }

    private var batchActions: some View {
        VStack(spacing: 8) {
            if selecting {
                HStack {
                    Text(L10n.text("\(targetIDs.count) selected", "已选 \(targetIDs.count) 个"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("selectedCountLabel")
                    Spacer()
                    Button(role: .destructive) { removalIDs = targetIDs } label: {
                        Label(L10n.text("Remove from list", "从列表移除"), systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(targetIDs.isEmpty)
                    .accessibilityIdentifier("batchRemoveButton")
                }
            }
            if !selecting {
                Text(folder == nil
                     ? L10n.text("Entire library · \(targetIDs.count) files", "全部资料库 · \(targetIDs.count) 个文件")
                     : L10n.text("Current folder · \(targetIDs.count) files", "当前文件夹 · \(targetIDs.count) 个文件"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Button { model.identify(targetIDs, automaticallyApply: true) } label: {
                    Label(L10n.text("Auto-match", "自动匹配"), systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(targetIDs.isEmpty)
                .accessibilityIdentifier("identifyButton")
                Button { review = ReviewRequest(ids: changedTargetIDs) } label: {
                    Text(L10n.text("Review \(changedTargetIDs.count)", "预览修改 \(changedTargetIDs.count)"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(changedTargetIDs.isEmpty)
                .accessibilityIdentifier("reviewButton")
            }
            .controlSize(.large)
            Text(L10n.text("Fixed 90% threshold · review drafts before saving", "固定 90% 门槛 · 草稿预览后保存"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var addMenu: some View {
        Menu {
            Button { picker = .files } label: {
                Label(L10n.text("Choose files", "选择文件"), systemImage: "doc")
            }
            .accessibilityIdentifier("chooseFilesButton")
            Button { picker = .folder } label: {
                Label(L10n.text("Choose folder", "选择文件夹"), systemImage: "folder")
            }
            .accessibilityIdentifier("chooseFolderButton")
        } label: {
            Label(L10n.text("Add audio", "添加音频"), systemImage: "plus")
        }
        .accessibilityIdentifier("addAudioButton")
    }
}

private struct AudioRow: View {
    let document: AudioDocument
    let candidateCount: Int

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(artwork: document.draftArtwork, maximumPixelSize: 144)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(document.draft.title.isEmpty ? document.fileName : document.draft.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let error = document.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if document.hasChanges {
                    Text(L10n.text("Changes to review", "有待确认的修改"))
                        .font(.caption)
                        .foregroundStyle(.indigo)
                } else if candidateCount > 0 {
                    Text(L10n.text("\(candidateCount) matches · choose a release", "\(candidateCount) 个匹配 · 请选择版本"))
                        .font(.caption)
                        .foregroundStyle(.indigo)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        let values = [document.draft.artist, document.draft.album].filter { !$0.isEmpty }
        if !values.isEmpty { return values.joined(separator: " · ") }
        let minutes = Int(document.duration) / 60
        let seconds = Int(document.duration) % 60
        return document.url.pathExtension.uppercased() + (document.duration > 0 ? String(format: " · %d:%02d", minutes, seconds) : "")
    }
}

struct OperationFooter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.operation ?? "").font(.subheadline.weight(.semibold))
                    if !model.currentFile.isEmpty {
                        Text(model.currentFile).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if model.totalCount > 0 {
                    Text("\(model.completedCount)/\(model.totalCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button(L10n.text("Stop", "停止")) { model.cancelOperation() }
                    .font(.subheadline)
            }
            if model.totalCount > 0 {
                ProgressView(value: Double(model.completedCount), total: Double(model.totalCount))
            } else { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding()
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}

struct ReviewRequest: Identifiable {
    let id = UUID()
    let ids: [UUID]
}
