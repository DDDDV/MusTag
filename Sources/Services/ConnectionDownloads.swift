import CryptoKit
import Foundation

/// Owns downloaded files permanently. No credentials and no writable remote API enter this layer.
actor LocalDownloadRepository {
    nonisolated let libraryDirectory: URL
    private let stateURL: URL
    private var manifest: [String: String]?
    private let manager = FileManager.default

    init(libraryDirectory: URL = AudioFileStore.defaultLibraryDirectory, stateDirectory: URL? = nil) {
        self.libraryDirectory = libraryDirectory.standardizedFileURL
        let state = stateDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusTag", isDirectory: true)
        stateURL = state.appendingPathComponent("downloads.json")
    }

    func sourceDirectory(_ connection: RemoteConnection) throws -> URL {
        try directory(["Connections", ConnectionPaths.component(connection.name) + "-" + connection.id.uuidString.prefix(8)])
    }

    nonisolated func importRoots(for urls: [URL]) -> [URL] {
        let prefix = libraryDirectory.path + "/"
        return Array(Set(urls.map { url in
            guard url.path.hasPrefix(prefix) else { return url }
            let parts = url.path.dropFirst(prefix.count).split(separator: "/")
            guard parts.count > 2, parts[0] == "Connections" else { return url }
            return libraryDirectory.appendingPathComponent("Connections", isDirectory: true)
                .appendingPathComponent(String(parts[1]), isDirectory: true)
        }))
    }

    func existingFile(connection: RemoteConnection, file: RemoteFile) throws -> URL? {
        try loadManifest()
        guard let path = manifest?[key(connection, file)], let url = try? resolved(path),
              manager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw invalidPath() }
        return url
    }

    func checkSpace(for expectedSize: Int64?) throws {
        try checkBatchSpace(totalSize: max(0, expectedSize ?? 0), largestFile: max(0, expectedSize ?? 0))
    }

    func checkBatchSpace(totalSize: Int64, largestFile: Int64) throws {
        try rejectSymlink(libraryDirectory)
        try manager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        let capacity = try libraryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        let reserve: Int64 = 32 * 1_024 * 1_024
        guard let capacity else { return }
        guard largestFile <= (Int64.max - reserve) / 2,
              totalSize <= Int64.max - largestFile * 2 - reserve,
              capacity >= totalSize + largestFile * 2 + reserve else {
            throw MusTagError.message(L10n.text("Not enough space for this download and local editing.", "本机空间不足，无法下载并保留编辑所需空间。"))
        }
    }

    func accept(_ temporaryURL: URL, connection: RemoteConnection, file: RemoteFile,
                relativeComponents: [String]) throws -> URL {
        try Task.checkCancellation()
        if let existing = try existingFile(connection: connection, file: file) { return existing }
        try validateAudio(temporaryURL, expectedSize: file.size)
        let source = try sourceDirectory(connection)
        let components = relativeComponents.map(ConnectionPaths.component)
        guard let name = components.last else { throw invalidPath() }
        let parent = try directory(["Connections", source.lastPathComponent] + components.dropLast())
        let destination = try unusedURL(in: parent, name: name)
        try Task.checkCancellation()
        try manager.moveItem(at: temporaryURL, to: destination)
        let relative = String(destination.path.dropFirst(libraryDirectory.path.count + 1))
        manifest?[key(connection, file)] = relative
        // A valid local audio file remains recoverable in Files if persisting the manifest fails.
        try persistManifest()
        return destination
    }

    func acceptWiFi(_ temporaryURL: URL, relativePath: String, expectedSize: Int64) throws -> URL {
        try Task.checkCancellation()
        let components = try ConnectionPaths.validateRelativePath(relativePath)
        guard let name = components.last,
              ["mp3", "flac", "m4a"].contains((name as NSString).pathExtension.lowercased()) else {
            throw MusTagError.message(L10n.text("Choose MP3, FLAC or M4A files.", "请选择 MP3、FLAC 或 M4A 文件。"))
        }
        try validateAudio(temporaryURL, expectedSize: expectedSize)
        let parent = try directory(["WiFi"] + components.dropLast())
        let destination = try unusedURL(in: parent, name: name)
        try Task.checkCancellation()
        try manager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func validateAudio(_ url: URL, expectedSize: Int64?) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        let size = Int64(values.fileSize ?? 0)
        guard size > 0, values.isRegularFile == true, values.isSymbolicLink != true,
              expectedSize == nil || expectedSize == size else {
            throw MusTagError.message(L10n.text("The download is incomplete. Retry this file.", "文件下载不完整，请重试。"))
        }
        _ = try NativeMetadataCodec().read(from: url)
        _ = try NativeAudio.payloadHash(url: url)
    }

    private func loadManifest() throws {
        guard manifest == nil else { return }
        manifest = manager.fileExists(atPath: stateURL.path)
            ? try JSONDecoder().decode([String: String].self, from: Data(contentsOf: stateURL)) : [:]
    }

    private func persistManifest() throws {
        try manager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest ?? [:]).write(to: stateURL, options: .atomic)
    }

    private func key(_ connection: RemoteConnection, _ file: RemoteFile) -> String {
        let identity = [connection.id.uuidString, connection.kind.rawValue, connection.address,
                        connection.rootPath, connection.username, connection.domain, file.id]
        return SHA256.hash(data: Data(identity.map { "\($0.utf8.count):\($0)" }.joined().utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func directory(_ components: [String]) throws -> URL {
        try rejectSymlink(libraryDirectory)
        try manager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        try rejectSymlink(libraryDirectory)
        var current = libraryDirectory
        for component in components {
            guard component == ConnectionPaths.component(component) else { throw invalidPath() }
            current.appendPathComponent(component, isDirectory: true)
            try rejectSymlink(current)
            if let attributes = try? manager.attributesOfItem(atPath: current.path) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw invalidPath() }
            } else {
                try manager.createDirectory(at: current, withIntermediateDirectories: false)
            }
            try rejectSymlink(current)
        }
        return current
    }

    private func resolved(_ relative: String) throws -> URL {
        let components = try ConnectionPaths.validateRelativePath(relative)
        try rejectSymlink(libraryDirectory)
        var url = libraryDirectory
        for component in components {
            url.appendPathComponent(component)
            try rejectSymlink(url)
        }
        return url
    }

    private func rejectSymlink(_ url: URL) throws {
        if let attributes = try? manager.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw invalidPath() }
        let root = libraryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let systemAlias = libraryDirectory.path.hasPrefix("/var/") || libraryDirectory.path.hasPrefix("/tmp/")
        guard root == libraryDirectory.path || (systemAlias && root == "/private" + libraryDirectory.path) else {
            throw invalidPath()
        }
        let actual = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard actual == root || actual.hasPrefix(root + "/") else { throw invalidPath() }
    }

    private func unusedURL(in directory: URL, name: String) throws -> URL {
        let safeName = ConnectionPaths.component(name)
        let ext = (safeName as NSString).pathExtension
        let stem = (safeName as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(safeName)
        var suffix = 2
        while (try? manager.attributesOfItem(atPath: candidate.path)) != nil {
            candidate = directory.appendingPathComponent("\(stem) (\(suffix))").appendingPathExtension(ext)
            suffix += 1
        }
        return candidate
    }

    private func invalidPath() -> MusTagError {
        .message(L10n.text("The local destination is not a regular folder. Choose another location in Files.", "本地目标路径不是普通文件夹，请在“文件”中检查该位置。"))
    }
}

@MainActor
final class ConnectionDownloads: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isScanning = false
    @Published private(set) var currentName = ""
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var expectedBytes: Int64?
    @Published private(set) var failures: [String] = []
    @Published private(set) var summary: String?
    private var task: Task<Void, Never>?
    private let repository: LocalDownloadRepository

    init(repository: LocalDownloadRepository = LocalDownloadRepository()) { self.repository = repository }

    func cancel() { task?.cancel() }

    func start(connection: RemoteConnection, provider: any RemoteFileProvider,
               entries: [RemoteFile], parentNames: [String]) {
        guard !isRunning else { return }
        isRunning = true
        isScanning = true
        failures = []
        summary = nil
        completed = 0
        total = 0
        task = Task { [self] in
            var downloaded: [URL] = []
            defer {
                isRunning = false; isScanning = false; task = nil; currentName = ""
                if !downloaded.isEmpty {
                    NotificationCenter.default.post(name: .musTagLocalFilesAdded, object: nil,
                                                    userInfo: ["urls": repository.importRoots(for: downloaded)])
                }
            }
            do {
                var visited = Set<String>()
                var files: [(RemoteFile, [String])] = []
                try await collect(entries, names: parentNames, provider: provider, visited: &visited, files: &files)
                isScanning = false
                total = files.count
                var pendingSizes: [Int64] = []
                for (file, _) in files {
                    if try await repository.existingFile(connection: connection, file: file) == nil {
                        pendingSizes.append(max(0, file.size ?? 0))
                    }
                }
                let knownSize = pendingSizes.reduce(Int64(0)) { result, value in
                    let (sum, overflow) = result.addingReportingOverflow(max(0, value))
                    return overflow ? Int64.max : sum
                }
                try await repository.checkBatchSpace(totalSize: knownSize, largestFile: pendingSizes.max() ?? 0)
                for (file, relativePath) in files {
                    try Task.checkCancellation()
                    currentName = file.name; receivedBytes = 0; expectedBytes = file.size
                    let temporary = FileManager.default.temporaryDirectory
                        .appendingPathComponent("MusTag-download-" + UUID().uuidString)
                        .appendingPathExtension((file.name as NSString).pathExtension)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    do {
                        if let existing = try await repository.existingFile(connection: connection, file: file) {
                            downloaded.append(existing)
                        } else {
                            try await repository.checkSpace(for: file.size)
                            try await provider.download(file, to: temporary) { [weak self] bytes, expected in
                                Task { @MainActor in
                                    guard self?.isRunning == true, self?.currentName == file.name else { return }
                                    self?.receivedBytes = bytes; self?.expectedBytes = expected
                                }
                            }
                            try Task.checkCancellation()
                            let local = try await repository.accept(temporary, connection: connection, file: file,
                                                                    relativeComponents: relativePath)
                            downloaded.append(local)
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        if Task.isCancelled { throw CancellationError() }
                        failures.append(file.name + ": " + error.localizedDescription)
                    }
                    completed += 1
                }
                summary = total == 0
                    ? L10n.text("No MP3, FLAC or M4A files found.", "没有找到 MP3、FLAC 或 M4A 文件。")
                    : L10n.text("\(downloaded.count) files ready locally. \(failures.count) errors. Find the files in MusTag → Music in Files.", "\(downloaded.count) 个文件已就绪，\(failures.count) 项失败。可在“文件”App 的 MusTag → Music 中查看。")
            } catch is CancellationError {
                summary = L10n.text("Cancelled. Completed downloads were kept; select the same items to retry the rest.", "已取消。完成的文件已保留，重新选择相同项目可重试其余文件。")
            } catch {
                failures.append(error.localizedDescription)
                summary = L10n.text("Download stopped. Completed files were kept.", "下载已停止，已完成的文件已保留。")
            }
        }
    }

    private func collect(_ entries: [RemoteFile], names: [String], provider: any RemoteFileProvider,
                         visited: inout Set<String>, files: inout [(RemoteFile, [String])]) async throws {
        guard names.count < 128, visited.count < 100_000 else {
            throw MusTagError.message(L10n.text("Select a smaller folder to continue.", "目录过大或层级过深，请分批选择。"))
        }
        for entry in entries {
            try Task.checkCancellation()
            guard visited.insert(entry.id).inserted else { continue }
            if let reason = entry.unavailableReason { failures.append(entry.name + ": " + reason); continue }
            if entry.isDirectory {
                currentName = entry.name
                do {
                    let children = try await provider.listDirectory(path: entry.id)
                    try await collect(children, names: names + [entry.name], provider: provider, visited: &visited, files: &files)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if Task.isCancelled { throw CancellationError() }
                    failures.append(entry.name + ": " + error.localizedDescription)
                }
            } else if entry.isSupportedAudio { files.append((entry, names + [entry.name])) }
        }
    }
}
