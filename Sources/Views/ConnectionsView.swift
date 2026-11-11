import SwiftUI

struct ConnectionsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ConnectionStore
    @EnvironmentObject private var downloads: ConnectionDownloads
    @Environment(\.dismiss) private var dismiss
    var isImportSheet = false
    @State private var picker: AudioPickerMode?
    @State private var editing: RemoteConnection?
    @State private var removing: RemoteConnection?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    importButton(.files, title: L10n.text("Import files", "导入文件"), icon: "doc.fill")
                    importButton(.folder, title: L10n.text("Import folder", "导入文件夹"), icon: "folder.fill")
                    NavigationLink { WiFiImportView() } label: {
                        Label(L10n.text("Wi-Fi Transfer", "WiFi 传歌"), systemImage: "wifi")
                    }.accessibilityIdentifier("connectionWiFiButton")
                    NavigationLink { LocalMusicFilesView() } label: {
                        Label(L10n.text("Local music folder", "本机音乐文件夹"), systemImage: "internaldrive")
                    }.accessibilityIdentifier("connectionLocalFolderButton")
                } header: { Text(L10n.text("Local", "本地")) }
                footer: { Text(L10n.text("Files are copied to this device before editing. Find saved music in Files → On My iPhone/iPad → MusTag → Music.", "所有文件先复制到本机再编辑。保存后的音乐位于“文件”→“我的 iPhone/iPad”→ MusTag → Music。")) }
                if !store.connections.isEmpty {
                    Section(L10n.text("Saved connections", "已保存的连接")) {
                        ForEach(store.connections) { connection in
                            NavigationLink { RemoteBrowserView(connection: connection, downloads: downloads) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(connection.name)
                                    Text(connection.kind.title + " · " + connection.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .swipeActions {
                                Button(L10n.text("Remove", "移除"), role: .destructive) { removing = connection }
                                Button(L10n.text("Edit", "编辑")) { editing = connection }.tint(.blue)
                            }
                            .contextMenu {
                                Button(L10n.text("Edit connection", "编辑连接")) { editing = connection }
                                Button(L10n.text("Remove connection", "移除连接"), role: .destructive) { removing = connection }
                            }
                            .disabled(downloads.isRunning)
                        }
                    }
                }
                Section(L10n.text("Add NAS or server", "添加 NAS 或服务器")) {
                    ForEach(ConnectionKind.allCases) { kind in
                        Button { editing = RemoteConnection(kind: kind, name: kind.title, address: "", username: "") } label: {
                            Label(kind.title, systemImage: kind.isMusicServer ? "music.note.house" : "server.rack")
                        }.accessibilityIdentifier("connectionService_\(kind.rawValue)").disabled(downloads.isRunning)
                    }
                }
                if downloads.isRunning || downloads.summary != nil {
                    Section(L10n.text("Downloads", "下载")) { DownloadStatusView(downloads: downloads) }
                }
                if let error = store.error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle(isImportSheet ? L10n.text("Import music", "导入音乐") : L10n.text("Connections", "连接"))
            .toolbar {
                if isImportSheet {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.text("Done", "完成")) { dismiss() }
                            .accessibilityIdentifier("importSourcesDoneButton")
                    }
                }
            }
            .sheet(item: $picker) { mode in
                AudioDocumentPicker(mode: mode, onPick: { urls in model.importFiles(urls); picker = nil }, onCancel: { picker = nil })
            }
            .sheet(item: $editing) { ConnectionEditorView(connection: $0, store: store) }
            .confirmationDialog(L10n.text("Remove this connection?", "移除此连接？"), isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }
            ), titleVisibility: .visible, presenting: removing) { connection in
                Button(L10n.text("Remove connection", "移除连接"), role: .destructive) {
                    do { try store.remove(connection) } catch { store.error = error.localizedDescription }
                }
            } message: { _ in Text(L10n.text("Downloaded files and local edits will be kept.", "已下载的文件和本地修改会保留。")) }
        }
        .localDeletionConfirmation(isEnabled: isImportSheet)
        .alert(L10n.text("Notice", "提示"), isPresented: Binding(
            get: { isImportSheet && model.notice != nil },
            set: { if !$0 && isImportSheet { model.notice = nil } }
        )) {
            Button(L10n.text("OK", "好"), role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }

    private func importButton(_ mode: AudioPickerMode, title: String, icon: String) -> some View {
        Button { picker = mode } label: { Label(title, systemImage: icon) }
            .disabled(model.isWorking)
            .accessibilityIdentifier(mode == .files ? "connectionFilesButton" : "connectionFolderButton")
    }
}

private struct ConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var connection: RemoteConnection
    @ObservedObject var store: ConnectionStore
    @State private var password = ""
    @State private var error: String?
    @State private var checking = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.text("Name", "名称"), text: $connection.name)
                    TextField(addressHint, text: $connection.address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("connectionAddressField")
                    TextField(L10n.text("Username", "用户名"), text: $connection.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(L10n.text("Password", "密码"), text: $password)
                    if !connection.kind.isMusicServer {
                        TextField(L10n.text("Starting folder (optional)", "起始文件夹（可选）"), text: $connection.rootPath)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if connection.kind == .smb {
                        TextField(L10n.text("Domain (optional)", "域（可选）"), text: $connection.domain)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } footer: { Text(L10n.text("Only browsing and downloading are supported. Server files remain unchanged.", "连接仅用于浏览和下载，服务器文件不会被修改。")) }
                if connection.kind != .smb {
                    Section {
                        Toggle(L10n.text("Allow unencrypted connection", "允许未加密连接"), isOn: $connection.allowsInsecureConnection)
                    } footer: {
                        Text(connection.kind == .ftp
                             ? L10n.text("Supports ftp:// only. Account and file transfers are unencrypted. Enable only on a trusted network.", "支持 ftp://，账号与文件传输不加密。请仅在信任的网络中启用。")
                             : L10n.text("HTTPS is recommended. Enable only if your trusted server uses http://.", "建议使用 HTTPS。仅当信任的服务器使用 http:// 时启用。"))
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                if checking { ProgressView(L10n.text("Checking connection…", "正在检查连接…")) }
            }
            .disabled(checking)
            .navigationTitle(connection.kind.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Cancel", "取消")) { task?.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Connect", "连接")) { connect() }
                        .disabled(checking || connection.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("saveConnectionButton")
                }
            }
            .onAppear {
                if store.connections.contains(where: { $0.id == connection.id }) {
                    do { password = try ConnectionPasswordStore.password(for: connection.id) }
                    catch { self.error = error.localizedDescription }
                }
            }
            .onDisappear { task?.cancel() }
        }
    }

    private var addressHint: String {
        switch connection.kind {
        case .smb: "smb://192.168.1.10/Music"
        case .ftp: "ftp://192.168.1.10:21"
        case .feiniu: "http://192.168.1.10:5666"
        default: "https://music.example.com"
        }
    }

    private func connect() {
        checking = true; error = nil
        connection.address = connection.address.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if connection.name.isEmpty { connection.name = connection.kind.title }
        task = Task {
            defer { checking = false }
            do {
                let provider = try ConnectionProviderFactory.make(connection, password: password)
                do { _ = try await provider.listDirectory(path: "/") }
                catch { await provider.disconnect(); throw error }
                await provider.disconnect()
                try Task.checkCancellation()
                try store.save(connection, password: password)
                dismiss()
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private struct RemoteBrowserView: View {
    @EnvironmentObject private var model: AppModel
    let connection: RemoteConnection
    @ObservedObject var downloads: ConnectionDownloads
    var path = "/"
    var parentNames: [String] = []
    @State var provider: (any RemoteFileProvider)?
    @State private var entries: [RemoteFile] = []
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text(L10n.text("Select files or folders to download. Only local copies will be edited.", "选择文件或文件夹下载，之后仅编辑本机副本。"))
                    .font(.footnote).foregroundStyle(.secondary)
                if loading { ProgressView(L10n.text("Loading…", "正在读取…")) }
                if let error {
                    Text(error).foregroundStyle(.red)
                    Button(L10n.text("Retry", "重试")) { Task { await load() } }
                }
                if !loading && error == nil && entries.isEmpty { Text(L10n.text("This folder is empty.", "此文件夹为空。")) }
            }
            Section {
                ForEach(entries) { file in
                    HStack(spacing: 12) {
                        Button { toggle(file) } label: {
                            Image(systemName: selected.contains(file.id) ? "checkmark.circle.fill" : "circle").font(.title3).frame(width: 28, height: 32)
                        }.buttonStyle(.plain)
                            .accessibilityLabel(L10n.text("Select ", "选择 ") + file.name)
                            .disabled(!selectable(file) || downloads.isRunning)
                        if file.isDirectory, let provider, file.unavailableReason == nil {
                            NavigationLink {
                                RemoteBrowserView(connection: connection, downloads: downloads, path: file.id,
                                                  parentNames: parentNames + [file.name], provider: provider)
                            } label: { entryLabel(file) }
                        } else { entryLabel(file).onTapGesture { if !downloads.isRunning { toggle(file) } } }
                    }
                }
            }
            if downloads.isRunning || downloads.summary != nil { Section { DownloadStatusView(downloads: downloads) } }
        }
        .navigationTitle(parentNames.last ?? connection.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("Select all", "全选")) { selected = Set(entries.filter(selectable).map(\.id)) }
                    .disabled(loading || downloads.isRunning)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                guard let provider else { return }
                downloads.start(connection: connection, provider: provider,
                                entries: entries.filter { selected.contains($0.id) }, parentNames: parentNames)
            } label: {
                Label(L10n.text("Download selected (\(selected.count))", "下载所选（\(selected.count)）"), systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
            }.buttonStyle(.borderedProminent).padding().background(.bar)
                .disabled(selected.isEmpty || loading || downloads.isRunning || model.isWorking)
                .accessibilityIdentifier("downloadSelectedButton")
        }
        .task { await load() }
        .refreshable { if !downloads.isRunning { await load() } }
    }

    private func selectable(_ file: RemoteFile) -> Bool { file.unavailableReason == nil && (file.isDirectory || file.isSupportedAudio) }
    private func toggle(_ file: RemoteFile) {
        guard selectable(file) else { return }
        if selected.contains(file.id) { selected.remove(file.id) } else { selected.insert(file.id) }
    }
    private func entryLabel(_ file: RemoteFile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: file.isDirectory ? "folder.fill" : "music.note").foregroundStyle(file.isDirectory ? Color.orange : Color.indigo)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).foregroundStyle(.primary).lineLimit(2)
                if let reason = file.unavailableReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                else if !file.isDirectory && !file.isSupportedAudio {
                    Text(L10n.text("Supports MP3, FLAC and M4A", "支持 MP3、FLAC、M4A")).font(.caption).foregroundStyle(.secondary)
                } else if let size = file.size {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            if provider == nil { provider = try ConnectionProviderFactory.make(connection, password: ConnectionPasswordStore.password(for: connection.id)) }
            guard let provider else { return }
            let result = try await provider.listDirectory(path: path)
            try Task.checkCancellation()
            entries = result.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            selected.formIntersection(Set(entries.filter(selectable).map(\.id)))
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

private struct DownloadStatusView: View {
    @ObservedObject var downloads: ConnectionDownloads
    var body: some View {
        if downloads.isRunning {
            Text(downloads.isScanning ? L10n.text("Scanning folders…", "正在扫描文件夹…") : "\(downloads.completed) / \(downloads.total)")
            if !downloads.isScanning, downloads.activeCount > 0 {
                Text(L10n.text("Downloading \(downloads.activeCount) files", "正在下载 \(downloads.activeCount) 个文件"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(downloads.currentName).font(.caption).lineLimit(3)
            if let expected = downloads.expectedBytes, expected > 0, !downloads.isScanning {
                ProgressView(value: min(Double(downloads.receivedBytes), Double(expected)), total: Double(expected))
            } else { ProgressView() }
            if !downloads.isScanning, downloads.receivedBytes > 0 {
                Text(ByteCountFormatter.string(fromByteCount: downloads.receivedBytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(L10n.text("Cancel download", "取消下载"), role: .cancel) { downloads.cancel() }
        }
        if let summary = downloads.summary { Text(summary).font(.footnote).foregroundStyle(.secondary) }
        ForEach(Array(downloads.failures.prefix(20).enumerated()), id: \.offset) { _, failure in
            Text(failure).font(.caption).foregroundStyle(.red)
        }
    }
}

struct LocalMusicFilesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    var directory: URL? = nil
    @State private var entries: [LocalFileEntry] = []
    @State private var selected: Set<String> = []
    @State private var selecting = false
    @State private var loading = true
    @State private var loadError: String?
    private var currentDirectory: URL { directory ?? model.localLibraryDirectory }
    private var allIDs: Set<String> { Set(entries.map(\.id)) }

    var body: some View {
        List {
            if directory == nil {
                Section {
                    Text(L10n.text("Browse all local files, including items removed from the library list. Select files or folders to delete them from this device.", "这里显示全部本地文件，包括已从资料库列表移除的项目。可选择文件或文件夹，从本机删除。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button(L10n.text("Refresh local files", "刷新本地文件")) {
                        model.enqueueLocalImports([model.localLibraryDirectory])
                        Task { await reload() }
                    }
                    .disabled(model.isWorking || model.isPreparingDeletion)
                    .accessibilityIdentifier("refreshLocalFilesButton")
                }
            }
            if loading {
                ProgressView(L10n.text("Loading files…", "正在读取文件…"))
            } else if let loadError {
                Text(loadError).foregroundStyle(.secondary)
            } else if entries.isEmpty {
                ContentUnavailableView(L10n.text("No local files", "暂无本地文件"), systemImage: "folder")
                    .accessibilityIdentifier("localFilesEmptyState")
            } else {
                if selecting {
                    Section {
                        HStack {
                            Text(L10n.text("\(selected.count) selected", "已选 \(selected.count) 项"))
                                .accessibilityIdentifier("localFilesSelectedCount")
                            Spacer()
                            Button(selected == allIDs ? L10n.text("Deselect all", "取消全选") : L10n.text("Select all", "全选")) {
                                selected = selected == allIDs ? [] : allIDs
                            }
                            .disabled(model.isWorking || model.isPreparingDeletion)
                            .accessibilityIdentifier("localFilesSelectAllButton")
                        }
                    }
                }
                Section {
                    ForEach(entries) { entry in localRow(entry) }
                } footer: {
                    Text(L10n.text("Deleting a folder also deletes all its subfolders and local contents. Server files are unaffected.", "删除文件夹会同时删除其中的全部子文件夹和本地内容，不影响服务器上的文件。"))
                }
            }
        }
        .navigationTitle(directory?.lastPathComponent ?? L10n.text("Local files", "本地文件"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selecting ? L10n.text("Done", "完成") : L10n.text("Select", "选择")) {
                    selecting.toggle()
                    selected = []
                }
                .disabled(entries.isEmpty || model.isWorking || model.isPreparingDeletion)
                .accessibilityIdentifier("localFilesSelectButton")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isWorking { OperationFooter() }
            else if selecting {
                Button(role: .destructive) {
                    model.prepareDeletion(urls: entries.filter { selected.contains($0.id) }.map(\.url))
                } label: {
                    Label(L10n.text("Delete selected items", "删除所选文件与文件夹"), systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
                .disabled(selected.isEmpty || !model.canDeleteLocalFiles)
                .padding().background(.bar)
                .accessibilityIdentifier("localFilesBatchDeleteButton")
            }
        }
        .task(id: "\(model.localFilesRevision)-\(model.isWorking)") {
            if !model.isWorking { await reload() }
        }
        .refreshable { await reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
    }

    @ViewBuilder
    private func localRow(_ entry: LocalFileEntry) -> some View {
        Group {
            if selecting {
                Button {
                    if selected.contains(entry.id) { selected.remove(entry.id) }
                    else { selected.insert(entry.id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(entry.id) ? Color.accentColor : .secondary)
                        entryLabel(entry)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isWorking || model.isPreparingDeletion)
                .accessibilityAddTraits(selected.contains(entry.id) ? [.isSelected] : [])
                .accessibilityIdentifier("localFileSelection_\(entry.name)")
            } else if entry.isDirectory {
                NavigationLink { LocalMusicFilesView(directory: entry.url) } label: { entryLabel(entry) }
                    .accessibilityIdentifier("localFileRow_\(entry.name)")
            } else {
                entryLabel(entry)
                    .accessibilityIdentifier("localFileRow_\(entry.name)")
            }
        }
        .swipeActions(allowsFullSwipe: false) {
            if !selecting {
                Button(role: .destructive) { model.prepareDeletion(urls: [entry.url]) } label: {
                    Label(L10n.text("Delete", "删除"), systemImage: "trash")
                }
                .disabled(!model.canDeleteLocalFiles)
                .accessibilityIdentifier("localFileDelete_\(entry.name)")
            }
        }
        .contextMenu {
            if !selecting {
                Button(role: .destructive) { model.prepareDeletion(urls: [entry.url]) } label: {
                    Label(L10n.text("Delete from this device", "从本机删除"), systemImage: "trash")
                }
                .disabled(!model.canDeleteLocalFiles)
                if !entry.isDirectory {
                    ShareLink(item: entry.url) { Label(L10n.text("Share", "分享"), systemImage: "square.and.arrow.up") }
                }
            }
        }
    }

    private func entryLabel(_ entry: LocalFileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(.indigo)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).foregroundStyle(.primary)
                if !entry.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: entry.fileSize, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    @MainActor
    private func reload() async {
        do {
            entries = try await model.localFiles(in: currentDirectory)
            selected.formIntersection(allIDs)
            if entries.isEmpty { selecting = false }
            loadError = nil
        } catch { loadError = error.localizedDescription }
        loading = false
    }
}
