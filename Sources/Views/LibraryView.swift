import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var picker: AudioPickerMode?
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var review: ReviewRequest?

    private var targetIDs: Set<UUID> {
        selecting ? selected : Set(model.documents.map(\.id))
    }
    private var changedTargetIDs: [UUID] {
        model.documents.filter { targetIDs.contains($0.id) && $0.hasChanges }.map(\.id)
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.documents.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.text("Your music, organized", "整理你的音乐"), systemImage: "music.note.list")
                    } description: {
                        Text(L10n.text("Edit MP3, FLAC and M4A files from Files, iCloud Drive or your NAS.", "编辑来自“文件”、iCloud Drive 或 NAS 的 MP3、FLAC 和 M4A 文件。"))
                    } actions: {
                        addMenu
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isWorking)
                    }
                } else {
                    List {
                        Section {
                            ForEach(model.documents) { document in
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
                                    .accessibilityAddTraits(selected.contains(document.id) ? [.isSelected] : [])
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
                        } header: {
                            HStack {
                                Text(L10n.text("\(model.documents.count) files", "\(model.documents.count) 个文件"))
                                Spacer()
                                if selecting {
                                    Button(selected.count == model.documents.count ? L10n.text("Deselect all", "取消全选") : L10n.text("Select all", "全选")) {
                                        selected = selected.count == model.documents.count ? [] : Set(model.documents.map(\.id))
                                    }
                                    .textCase(nil)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("MusTag")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.documents.isEmpty {
                        Button(selecting ? L10n.text("Done", "完成") : L10n.text("Select", "选择")) {
                            selecting.toggle()
                            selected = []
                        }
                        .disabled(model.isWorking)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !model.documents.isEmpty { addMenu.disabled(model.isWorking) }
                    Button { model.showsSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(L10n.text("Settings", "设置"))
                    .accessibilityIdentifier("settingsButton")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.isWorking {
                    OperationFooter()
                } else if !model.documents.isEmpty {
                    VStack(spacing: 8) {
                        if selecting {
                            Text(L10n.text("\(selected.count) selected", "已选 \(selected.count) 个"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Button { model.identify(targetIDs) } label: {
                                Label(L10n.text("Identify", "识别"), systemImage: "waveform")
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
                    }
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .background(.bar)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                TrackEditorView(documentID: id)
            }
            .onChange(of: model.documents.map(\.id)) { _, ids in selected.formIntersection(ids) }
        }
        .sheet(item: $picker) { mode in
            AudioDocumentPicker(mode: mode, onPick: { urls in
                model.importFiles(urls)
                picker = nil
            }, onCancel: { picker = nil })
        }
        .sheet(isPresented: $model.showsSettings) { SettingsView() }
        .sheet(item: $review) { request in ReviewSheet(documentIDs: request.ids) }
        .alert(L10n.text("Notice", "提示"), isPresented: Binding(get: { model.notice != nil && !model.showsSettings }, set: { if !$0 { model.notice = nil } })) {
            Button(L10n.text("OK", "好"), role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
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
            Image(systemName: "music.note")
                .font(.title3)
                .foregroundStyle(.indigo)
                .frame(width: 40, height: 44)
                .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
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
