import CryptoKit
import Foundation

/// Imports sources as permanent local copies. External source files are read only.
/// Only owned library files can be replaced, after staging and backup verification.
actor AudioFileStore {
    typealias PayloadHasher = @Sendable (URL) throws -> String
    typealias PayloadRanges = @Sendable (URL) throws -> [AudioPayloadRange]

    private let codec: any AudioMetadataCodec
    private let payloadHasher: PayloadHasher
    private let payloadRanges: PayloadRanges
    private let storageDirectory: URL
    nonisolated let libraryDirectory: URL
    nonisolated static var defaultLibraryDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
    }
    private let manager = FileManager.default
    private static let supportedExtensions: Set<String> = ["mp3", "flac", "m4a"]

    init(
        codec: any AudioMetadataCodec,
        storageDirectory: URL? = nil,
        libraryDirectory: URL? = nil,
        payloadHasher: @escaping PayloadHasher = { try NativeAudio.payloadHash(url: $0) },
        payloadRanges: @escaping PayloadRanges = { try NativeAudio.payloadRanges(url: $0) }
    ) {
        self.codec = codec
        self.payloadHasher = payloadHasher
        self.payloadRanges = payloadRanges
        self.storageDirectory = (storageDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("MusTag", isDirectory: true)).standardizedFileURL
        self.libraryDirectory = (libraryDirectory ?? storageDirectory?.appendingPathComponent("Music", isDirectory: true)
            ?? Self.defaultLibraryDirectory).standardizedFileURL
    }

    private var documentsURL: URL { storageDirectory.appendingPathComponent("documents.json") }
    private var journalURL: URL { storageDirectory.appendingPathComponent("backups.json") }
    private var backupDirectory: URL { storageDirectory.appendingPathComponent("Backups", isDirectory: true) }
    private var stagingDirectory: URL { storageDirectory.appendingPathComponent("Staging", isDirectory: true) }
    private var importsURL: URL { storageDirectory.appendingPathComponent("imports.json") }

    private struct ImportLocations: Codable {
        var files: [String: String] = [:]
        var folders: [String: String] = [:]
    }

    /// Decode the library once per batch, and normalize each persisted identity once.
    /// The lowest matching position preserves the former `first(where:)` behavior
    /// when an old library contains overlapping source and local identities.
    private struct ImportLibraryIndex {
        private enum Key: Hashable {
            case relativePath(String), localURL(URL), sourceURL(URL), legacyURL(URL)
        }

        private let library: AudioLibrary
        private var documents: [Key: Int] = [:]
        private var folders: [Key: Int] = [:]

        init(_ library: AudioLibrary) {
            self.library = library
            for (index, document) in library.documents.enumerated() {
                let url = document.url.standardizedFileURL
                var keys: [Key] = [.localURL(url)]
                if let path = document.libraryRelativePath { keys.append(.relativePath(path)) }
                else { keys.append(.legacyURL(url)) }
                if let source = document.sourceURL { keys.append(.sourceURL(source.standardizedFileURL)) }
                for key in keys where documents[key] == nil { documents[key] = index }
            }
            for (index, folder) in library.folders.enumerated() {
                var keys: [Key] = [.localURL(folder.url.standardizedFileURL)]
                if let path = folder.libraryRelativePath { keys.append(.relativePath(path)) }
                if let source = folder.sourceURL { keys.append(.sourceURL(source.standardizedFileURL)) }
                for key in keys where folders[key] == nil { folders[key] = index }
            }
        }

        func document(relativePath: String, local: URL, source: URL) -> AudioDocument? {
            let source = source.standardizedFileURL
            let keys: [Key] = [.relativePath(relativePath), .localURL(local.standardizedFileURL),
                               .sourceURL(source), .legacyURL(source)]
            guard let index = keys.compactMap({ documents[$0] }).min() else { return nil }
            return library.documents[index]
        }

        func folder(relativePath: String, local: URL, source: URL) -> AudioFolder? {
            let source = source.standardizedFileURL
            let keys: [Key] = [.relativePath(relativePath), .localURL(local.standardizedFileURL),
                               .sourceURL(source), .localURL(source)]
            guard let index = keys.compactMap({ folders[$0] }).min() else { return nil }
            return library.folders[index]
        }
    }

    func importFiles(from urls: [URL]) throws -> ImportResult {
        try prepareStorage()
        var documents: [AudioDocument] = []
        var failures: [String] = []
        var folders: [AudioFolder] = []
        var seen: [String: Int] = [:]
        let library = try readLibrary()
        let libraryIndex = ImportLibraryIndex(library)
        var locations = try readImportLocations(library: library)

        // Plan containing folders first so mixed file/folder selections keep their tree.
        let roots = urls.enumerated().map { index, url in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return (url: url, directory: directory, order: index)
        }.sorted { lhs, rhs in
            if lhs.directory != rhs.directory { return lhs.directory }
            if lhs.directory, lhs.url.pathComponents.count != rhs.url.pathComponents.count {
                return lhs.url.pathComponents.count < rhs.url.pathComponents.count
            }
            return lhs.order < rhs.order
        }.map(\.url)

        do {
            for root in roots {
                try Task.checkCancellation()
                let accessing = root.startAccessingSecurityScopedResource()
                defer { if accessing { root.stopAccessingSecurityScopedResource() } }

                do {
                    guard root.isFileURL else { throw localImportRequired() }
                    let resource = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if resource.isSymbolicLink == true {
                        throw message("Symbolic links are not imported.", "不导入符号链接。")
                    }
                    if resource.isDirectory == true {
                        guard let enumerator = manager.enumerator(
                            at: root,
                            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                            options: [.skipsHiddenFiles, .skipsPackageDescendants],
                            errorHandler: { url, error in
                                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                                return true
                            }
                        ) else {
                            throw message("This folder could not be read. Reconnect the drive and select it again.",
                                          "无法读取此文件夹。请重新连接存储位置并再次选择。")
                        }
                        let folder = try localFolder(for: root, locations: &locations, libraryIndex: libraryIndex)
                        if !folders.contains(where: { $0.id == folder.id }) { folders.append(folder) }

                        for case let file as URL in enumerator {
                            try Task.checkCancellation()
                            do {
                                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                                if values.isDirectory == true {
                                    _ = try localFolder(for: file, locations: &locations, libraryIndex: libraryIndex)
                                    continue
                                }
                                guard values.isRegularFile == true,
                                      Self.supportedExtensions.contains(file.pathExtension.lowercased()) else { continue }
                                try importOne(file, folderID: folder.id, locations: &locations, libraryIndex: libraryIndex,
                                              seen: &seen, documents: &documents)
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
                            }
                        }
                    } else {
                        guard Self.supportedExtensions.contains(root.pathExtension.lowercased()) else {
                            throw message("Choose an MP3, FLAC, or M4A audio file.", "请选择 MP3、FLAC 或 M4A 音频文件。")
                        }
                        try importOne(root, locations: &locations, libraryIndex: libraryIndex, seen: &seen, documents: &documents)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append("\(root.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch is CancellationError {
            guard !documents.isEmpty || !folders.isEmpty else { throw CancellationError() }
            failures.append(L10n.text("Import stopped. Items already imported were kept.", "导入已停止，已导入的项目已保留。"))
        }
        return ImportResult(documents: documents, failures: failures, folders: folders)
    }

    func save(_ document: AudioDocument) throws -> (AudioDocument, BackupRecord) {
        try prepareStorage()
        try Task.checkCancellation()
        guard document.hasChanges else {
            throw message("There are no changes to save.", "没有需要保存的修改。")
        }
        guard !document.sourceHash.isEmpty else {
            throw message("Select this file again before saving so its original can be verified.",
                          "请重新选择此文件，以便核对原文件后再保存。")
        }

        let source = try ownedURL(for: document.url, relativePath: document.libraryRelativePath,
                                  bookmark: document.bookmark)
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let workspace = try makeWorkspace()
        defer { try? manager.removeItem(at: workspace) }
        let staged = workspace.appendingPathComponent("edited").appendingPathExtension(source.pathExtension)
        try coordinatedCopy(from: source, to: staged)
        let originalHash = try Self.fileHash(staged)
        guard originalHash == document.sourceHash else { throw sourceChanged() }

        try ensureAvailableSpace(for: staged)
        let originalPayload = try payloadHasher(staged)
        let originalArtwork = try codec.read(from: staged).artwork
        let backupID = UUID()
        let backupURL = backupDirectory.appendingPathComponent(backupID.uuidString)
            .appendingPathExtension("mustagbackup")
        var journaled = false
        defer { if !journaled { try? manager.removeItem(at: backupURL) } }
        let metadataBackup = try AudioMetadataBackup.capture(from: staged, audioRanges: payloadRanges(staged))
        let backupData = try metadataBackup.encodedData()
        try backupData.write(to: backupURL, options: .atomic)
        try synchronizeFile(backupURL)
        let backupHash = SHA256.hash(data: backupData).map { String(format: "%02x", $0) }.joined()
        guard try Self.fileHash(backupURL) == backupHash else {
            throw message("The backup failed verification. The original was not changed.", "备份校验失败，原文件未修改。")
        }

        try Task.checkCancellation()
        if document.original != document.draft {
            try codec.write(document.draft, to: staged)
        }
        if document.hasArtworkChanges {
            guard let artwork = document.draftArtwork else {
                throw message("Choose a cover before saving.", "请先选择要保存的封面。")
            }
            try codec.writeArtwork(artwork, to: staged)
        }
        let verified = try codec.read(from: staged)
        guard tagsEquivalent(verified.tags, document.draft) else {
            throw message("This file format did not preserve the requested tags. The original was not changed.",
                          "此格式未能完整保存所需标签，原文件未修改。")
        }
        guard try payloadHasher(staged) == originalPayload else {
            throw message("Audio verification failed. The original was not changed.",
                          "音频数据校验失败，原文件未修改。")
        }
        let expectedArtwork = document.hasArtworkChanges ? document.draftArtwork : originalArtwork
        guard verified.artwork == expectedArtwork else {
            throw message("Cover art verification failed. The original was not changed.",
                          "封面校验失败，原文件未修改。")
        }
        let writtenHash = try Self.fileHash(staged)
        // Prove the persisted metadata and the edited file's audio can reproduce
        // the exact original, including fields the editor does not expose.
        // This verification copy is temporary and never enters Backups.
        let verificationCopy = workspace.appendingPathComponent("verify-original")
        do {
            defer { try? manager.removeItem(at: verificationCopy) }
            let persistedBackup = try AudioMetadataBackup(data: Data(contentsOf: backupURL))
            try persistedBackup.restore(from: staged, audioRanges: payloadRanges(staged), to: verificationCopy)
            guard try Self.fileHash(verificationCopy) == originalHash else {
                throw message("The metadata backup could not restore the original. Nothing was changed.",
                              "元数据备份无法准确恢复原文件，未修改任何文件。")
            }
        }
        var backup = BackupRecord(
            documentID: document.id,
            originalURL: source,
            bookmark: try refreshedBookmark(source, fallback: document.bookmark),
            backupURL: backupURL,
            originalHash: originalHash,
            writtenHash: writtenHash
        )
        backup.id = backupID
        backup.originalShazamAttribution = document.originalShazamAttribution
        backup.backupHash = backupHash
        backup.libraryRelativePath = try relativeLibraryPath(source)
        var journal = try readJournal()
        journal.append(backup)
        try writeJSON(journal, to: journalURL)
        journaled = true

        // Cancellation after the journal is durable but before the replace is safe.
        try Task.checkCancellation()
        try coordinatedReplace(source, with: staged, expectedHash: originalHash, resultHash: writtenHash)

        var updated = document
        updated.url = source
        updated.libraryRelativePath = backup.libraryRelativePath
        var postSaveWarning: String?
        do {
            backup.bookmark = try refreshedBookmark(source, fallback: backup.bookmark)
            if let index = journal.firstIndex(where: { $0.id == backup.id }) {
                journal[index] = backup
                try writeJSON(journal, to: journalURL)
            }
        } catch {
            postSaveWarning = L10n.text(
                "Saved with a backup, but access information could not be refreshed. Reimport this file before editing again.",
                "文件已保存并保留备份，但访问授权更新失败。再次编辑前请重新导入此文件。"
            )
        }
        updated.bookmark = backup.bookmark
        updated.original = verified.tags
        updated.draft = verified.tags
        updated.originalArtwork = verified.artwork
        updated.draftArtwork = verified.artwork
        updated.originalShazamAttribution = document.draftShazamAttribution
        updated.artworkVersion = 1
        updated.duration = verified.duration
        updated.sourceHash = writtenHash
        updated.error = postSaveWarning
        // A failed library-index write must not conceal a successful audio-file write.
        do { try updatePersistedDocument(updated) } catch {
            updated.error = L10n.text(
                "Saved with a backup, but the library list could not be updated. Reimport this file before editing again.",
                "文件已保存并保留备份，但列表状态保存失败。再次编辑前请重新导入此文件。"
            )
        }
        return (updated, backup)
    }

    func backups() throws -> [BackupRecord] {
        try prepareStorage()
        return try readJournal().sorted { $0.createdAt > $1.createdAt }
    }

    func restore(_ requestedBackup: BackupRecord) throws -> AudioDocument {
        try prepareStorage()
        try Task.checkCancellation()
        var journal = try readJournal()
        guard let index = journal.firstIndex(where: { $0.id == requestedBackup.id }) else {
            throw message("This backup could not be found.", "找不到此备份。")
        }
        var backup = journal[index]
        guard !backup.restored else {
            throw message("This backup has already been restored.", "此备份已恢复。")
        }
        guard try Self.fileHash(backup.backupURL) == (backup.backupHash ?? backup.originalHash) else {
            throw message("The backup failed verification. Nothing was changed.", "备份校验失败，未修改任何文件。")
        }
        // Legacy backups may become usable after their document has been copied
        // into the library. Never restore directly to an external source URL.
        if backup.libraryRelativePath == nil,
           let document = try readLibrary().documents.first(where: { $0.id == backup.documentID }),
           let relativePath = document.libraryRelativePath {
            backup.originalURL = try ownedURL(for: document.url, relativePath: relativePath, bookmark: document.bookmark)
            backup.libraryRelativePath = relativePath
            backup.bookmark = nil
        }
        let source = try ownedURL(for: backup.originalURL, relativePath: backup.libraryRelativePath,
                                  bookmark: backup.bookmark)
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let workspace = try makeWorkspace()
        defer { try? manager.removeItem(at: workspace) }
        let originalCopy = workspace.appendingPathComponent("restore").appendingPathExtension(source.pathExtension)
        let currentHash: String
        if backup.backupHash != nil {
            let currentCopy = workspace.appendingPathComponent("current").appendingPathExtension(source.pathExtension)
            try coordinatedCopy(from: source, to: currentCopy)
            currentHash = try Self.fileHash(currentCopy)
            guard currentHash == backup.originalHash || currentHash == backup.writtenHash else {
                throw message("This file changed after it was saved. Restore newer edits first, or reimport the file.",
                              "文件在保存后又发生了变化。请先撤销较新的修改，或重新导入文件。")
            }
            try ensureAvailableSpace(for: currentCopy)
            let archive = try AudioMetadataBackup(data: Data(contentsOf: backup.backupURL))
            try archive.restore(from: currentCopy, audioRanges: payloadRanges(currentCopy), to: originalCopy)
            guard try Self.fileHash(originalCopy) == backup.originalHash,
                  try payloadHasher(originalCopy) == payloadHasher(currentCopy) else {
                throw message("The metadata backup failed restoration verification. Nothing was changed.",
                              "元数据备份恢复校验失败，未修改任何文件。")
            }
        } else {
            // Keep existing complete-file backups usable after upgrading.
            try manager.copyItem(at: backup.backupURL, to: originalCopy)
            currentHash = try coordinatedHash(source)
        }
        let snapshot = try codec.read(from: originalCopy)
        if currentHash != backup.originalHash {
            guard currentHash == backup.writtenHash else {
                throw message("This file changed after it was saved. Restore newer edits first, or reimport the file.",
                              "文件在保存后又发生了变化。请先撤销较新的修改，或重新导入文件。")
            }
            try coordinatedReplace(source, with: originalCopy, expectedHash: backup.writtenHash, resultHash: backup.originalHash)
        }
        // Equal-to-original also covers a save cancelled before replacement, or a
        // successful restore interrupted before the journal update.
        let restoredBookmark = try refreshedBookmark(source, fallback: backup.bookmark)
        journal[index].originalURL = source
        journal[index].libraryRelativePath = try relativeLibraryPath(source)
        journal[index].bookmark = restoredBookmark
        journal[index].restored = true
        try writeJSON(journal, to: journalURL)
        var document = AudioDocument(
            id: backup.documentID, url: source,
            bookmark: restoredBookmark,
            original: snapshot.tags, draft: snapshot.tags, duration: snapshot.duration,
            error: nil, sourceHash: backup.originalHash,
            originalArtwork: snapshot.artwork, draftArtwork: snapshot.artwork
        )
        document.originalShazamAttribution = backup.originalShazamAttribution
        document.draftShazamAttribution = backup.originalShazamAttribution
        document.libraryRelativePath = try relativeLibraryPath(source)
        do {
            let existing = try readLibrary().documents.first {
                $0.id == document.id || $0.url.standardizedFileURL == document.url.standardizedFileURL
            }
            document.importFolderIDs = existing?.importFolderIDs
            document.sourceURL = existing?.sourceURL
            try updatePersistedDocument(document)
        } catch {
            document.error = L10n.text(
                "Restored, but the library list could not be updated. Reimport this file before editing again.",
                "文件已恢复，但列表状态保存失败。再次编辑前请重新导入此文件。"
            )
        }
        return document
    }

    func loadDocuments() throws -> [AudioDocument] {
        try loadLibrary().documents
    }

    func loadLibrary() throws -> AudioLibrary {
        try prepareStorage()
        var library = try readLibrary()
        let libraryIndex = ImportLibraryIndex(library)
        var locations = try readImportLocations(library: library)
        for index in library.folders.indices {
            let old = library.folders[index]
            do {
                var folder: AudioFolder
                if let relativePath = old.libraryRelativePath {
                    folder = old
                    folder.url = try libraryURL(relativePath: relativePath)
                } else {
                    folder = try localFolder(for: old.url, locations: &locations, libraryIndex: libraryIndex)
                }
                folder.persistentID = old.id
                folder.sourceURL = old.sourceURL ?? folder.sourceURL
                library.folders[index] = folder
            } catch {
                // Keep unavailable legacy group identities so a later reimport can
                // recover them. Their documents cannot be saved outside the library.
            }
        }
        var documents = library.documents
        for index in documents.indices {
            do {
                let old = documents[index]
                let url: URL
                if old.libraryRelativePath != nil || isLibraryLocation(old.url) {
                    url = try ownedURL(for: old.url, relativePath: old.libraryRelativePath, bookmark: old.bookmark)
                } else {
                    let external = try resolvedURL(for: old.url, bookmark: old.bookmark)
                    let accessing = external.startAccessingSecurityScopedResource()
                    defer { if accessing { external.stopAccessingSecurityScopedResource() } }
                    var migrated: [AudioDocument] = []
                    var seen: [String: Int] = [:]
                    try importOne(external, locations: &locations, libraryIndex: libraryIndex, seen: &seen, documents: &migrated)
                    guard var local = migrated.first else { throw localImportRequired() }
                    local.id = old.id
                    local.draft = old.draft
                    local.importFolderIDs = old.importFolderIDs
                    local.sourceURL = old.sourceURL ?? old.url
                    local.originalShazamAttribution = old.originalShazamAttribution
                    local.draftShazamAttribution = old.draftShazamAttribution
                    if old.hasArtworkChanges { local.draftArtwork = old.draftArtwork }
                    documents[index] = local
                    url = local.url
                    locations.files[old.url.standardizedFileURL.absoluteString] = local.libraryRelativePath
                    try writeJSON(locations, to: importsURL)
                }
                documents[index].url = url
                documents[index].libraryRelativePath = try relativeLibraryPath(url)
                documents[index].bookmark = try refreshedBookmark(url, fallback: nil)
                documents[index].error = nil
                if documents[index].artworkVersion == nil {
                    let workspace = try makeWorkspace()
                    defer { try? manager.removeItem(at: workspace) }
                    let staged = workspace.appendingPathComponent("artwork").appendingPathExtension(url.pathExtension)
                    try coordinatedCopy(from: url, to: staged)
                    guard try Self.fileHash(staged) == documents[index].sourceHash else { throw sourceChanged() }
                    let artwork = try codec.read(from: staged).artwork
                    let hasPendingArtwork = documents[index].hasArtworkChanges
                    documents[index].originalArtwork = artwork
                    if !hasPendingArtwork { documents[index].draftArtwork = artwork }
                    documents[index].artworkVersion = 1
                }
            } catch {
                documents[index].error = L10n.text(
                    "This file could not be copied into the local library. Select the source again to import it before editing.",
                    "无法将此文件复制到本地资料库。请重新选择来源并导入后再编辑。"
                )
            }
        }
        library.documents = documents
        try writeJSON(library, to: documentsURL)
        return library
    }

    func persistDocuments(_ documents: [AudioDocument]) throws {
        try prepareStorage()
        var library = try readLibrary()
        library.documents = documents
        try persistLibrary(library)
    }

    func persistLibrary(_ library: AudioLibrary) throws {
        try prepareStorage()
        try writeJSON(library, to: documentsURL)
    }

    private func importOne(_ source: URL, folderID: String? = nil, locations: inout ImportLocations,
                           libraryIndex: ImportLibraryIndex,
                           seen: inout [String: Int], documents: inout [AudioDocument]) throws {
        guard source.isFileURL else { throw localImportRequired() }
        let identity = source.standardizedFileURL.absoluteString
        if let index = seen[identity] {
            if let folderID {
                documents[index].importFolderIDs = (documents[index].importFolderIDs ?? []).union([folderID])
            }
            return
        }
        let local: URL
        if isLibraryLocation(source) {
            local = try validatedLibraryURL(source, requireRegularFile: true)
        } else if let path = locations.files[identity] {
            local = try libraryURL(relativePath: path)
        } else {
            let parent = source.deletingLastPathComponent()
            let localParent: URL
            if let mapped = try mappedFolder(for: parent, locations: locations) {
                localParent = mapped
            } else {
                localParent = libraryDirectory.appendingPathComponent("Imported Files", isDirectory: true)
                    .appendingPathComponent(sourceKey(parent), isDirectory: true)
            }
            local = try validatedLibraryURL(localParent.appendingPathComponent(source.lastPathComponent))
        }
        let localIdentity = local.standardizedFileURL.absoluteString
        if let index = seen[localIdentity] {
            if let folderID {
                documents[index].importFolderIDs = (documents[index].importFolderIDs ?? []).union([folderID])
            }
            seen[identity] = index
            return
        }
        let workspace = try makeWorkspace()
        defer { try? manager.removeItem(at: workspace) }
        let staged = workspace.appendingPathComponent("original").appendingPathExtension(source.pathExtension)
        let alreadyCopied = manager.fileExists(atPath: local.path)
        let input = alreadyCopied ? try validatedLibraryURL(local, requireRegularFile: true) : source
        let values = try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw localImportRequired() }
        try ensureAvailableSpace(for: input)
        try coordinatedCopy(from: input, to: staged)
        try Task.checkCancellation()
        let hash = try Self.fileHash(staged)
        let snapshot = try codec.read(from: staged)
        if !alreadyCopied {
            _ = try validatedLibraryURL(local)
            try manager.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try validatedLibraryURL(local)
            // A move to a new path fails if another import created it. It cannot
            // overwrite an edited local copy or the external source.
            try manager.moveItem(at: staged, to: local)
            try synchronizeFile(local)
        }
        let relativePath = try relativeLibraryPath(local)
        if !isLibraryLocation(source), locations.files[identity] != relativePath {
            locations.files[identity] = relativePath
            try writeJSON(locations, to: importsURL)
        }
        let previous = libraryIndex.document(relativePath: relativePath, local: local, source: source)
        documents.append(AudioDocument(
            id: previous?.id ?? UUID(),
            url: local, bookmark: try refreshedBookmark(local, fallback: nil),
            original: snapshot.tags, draft: snapshot.tags, duration: snapshot.duration,
            error: nil, sourceHash: hash,
            originalArtwork: snapshot.artwork, draftArtwork: snapshot.artwork,
            importFolderIDs: folderID.map { Set([$0]) },
            sourceURL: isLibraryLocation(source) ? previous?.sourceURL : source.standardizedFileURL,
            libraryRelativePath: relativePath
        ))
        seen[identity] = documents.count - 1
        seen[localIdentity] = documents.count - 1
    }

    private func prepareStorage() throws {
        _ = try validatedLibraryURL(libraryDirectory)
        for directory in [storageDirectory, backupDirectory, stagingDirectory] {
            _ = try validatedOwnedURL(directory, root: storageDirectory)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try validatedOwnedURL(directory, root: storageDirectory)
        }
        try manager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        _ = try validatedLibraryURL(libraryDirectory)
        var root = storageDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    private func localFolder(for source: URL, locations: inout ImportLocations,
                             libraryIndex: ImportLibraryIndex) throws -> AudioFolder {
        guard source.isFileURL else { throw localImportRequired() }
        let identity = source.standardizedFileURL.absoluteString
        let local: URL
        if isLibraryLocation(source) {
            local = try validatedLibraryURL(source)
        } else if let mapped = try mappedFolder(for: source, locations: locations) {
            local = mapped
        } else {
            local = try validatedLibraryURL(libraryDirectory.appendingPathComponent("Imports", isDirectory: true)
                .appendingPathComponent(sourceKey(source), isDirectory: true)
                .appendingPathComponent(source.lastPathComponent, isDirectory: true))
        }
        try manager.createDirectory(at: local, withIntermediateDirectories: true)
        _ = try validatedLibraryURL(local)
        let relativePath = try relativeLibraryPath(local)
        if !isLibraryLocation(source), locations.folders[identity] != relativePath {
            locations.folders[identity] = relativePath
            try writeJSON(locations, to: importsURL)
        }
        let previous = libraryIndex.folder(relativePath: relativePath, local: local, source: source)
        return AudioFolder(url: local,
                           sourceURL: isLibraryLocation(source) ? previous?.sourceURL : source.standardizedFileURL,
                           libraryRelativePath: relativePath, persistentID: previous?.id ?? identity)
    }

    private func mappedFolder(for source: URL, locations: ImportLocations) throws -> URL? {
        let sourceComponents = source.standardizedFileURL.pathComponents
        let matching = locations.folders.compactMap { key, value -> (URL, String)? in
            guard let original = URL(string: key), original.isFileURL,
                  sourceComponents.starts(with: original.standardizedFileURL.pathComponents) else { return nil }
            return (original, value)
        }.max { $0.0.pathComponents.count < $1.0.pathComponents.count }
        guard let (original, path) = matching else { return nil }
        var result = try libraryURL(relativePath: path)
        for component in sourceComponents.dropFirst(original.standardizedFileURL.pathComponents.count) {
            result.appendPathComponent(component, isDirectory: true)
        }
        return try validatedLibraryURL(result)
    }

    private func sourceKey(_ source: URL) -> String {
        SHA256.hash(data: Data(source.standardizedFileURL.absoluteString.utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func readImportLocations(library: AudioLibrary) throws -> ImportLocations {
        var locations = manager.fileExists(atPath: importsURL.path)
            ? try JSONDecoder().decode(ImportLocations.self, from: Data(contentsOf: importsURL)) : ImportLocations()
        for document in library.documents {
            if let source = document.sourceURL, source.isFileURL, let path = document.libraryRelativePath {
                locations.files[source.standardizedFileURL.absoluteString] = path
            }
        }
        for folder in library.folders {
            if let source = folder.sourceURL, source.isFileURL, let path = folder.libraryRelativePath {
                locations.folders[source.standardizedFileURL.absoluteString] = path
            }
        }
        return locations
    }

    private func isLibraryLocation(_ url: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.pathComponents.starts(with: libraryDirectory.pathComponents)
    }

    private func libraryURL(relativePath: String) throws -> URL {
        if relativePath.isEmpty { return try validatedLibraryURL(libraryDirectory) }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw localImportRequired()
        }
        var url = libraryDirectory
        for component in components { url.appendPathComponent(String(component)) }
        return try validatedLibraryURL(url)
    }

    private func relativeLibraryPath(_ url: URL) throws -> String {
        try validatedLibraryURL(url).pathComponents.dropFirst(libraryDirectory.pathComponents.count).joined(separator: "/")
    }

    private func ownedURL(for url: URL, relativePath: String?, bookmark: Data?) throws -> URL {
        let candidate = try relativePath.map { try libraryURL(relativePath: $0) }
            ?? resolvedURL(for: url, bookmark: bookmark)
        return try validatedLibraryURL(candidate, requireRegularFile: true)
    }

    /// Check both lexical containment and every component below the trusted root.
    /// A library subfolder replaced by a symlink must never redirect a save.
    private func validatedLibraryURL(_ url: URL, requireRegularFile: Bool = false) throws -> URL {
        try validatedOwnedURL(url, root: libraryDirectory, requireRegularFile: requireRegularFile)
    }

    private func validatedOwnedURL(_ url: URL, root: URL, requireRegularFile: Bool = false) throws -> URL {
        guard url.isFileURL, url.standardizedFileURL.pathComponents.starts(with: root.pathComponents) else {
            throw localImportRequired()
        }
        // iOS and macOS expose these system aliases. Other changes in the root's
        // ancestry are not trusted: a redirected parent must not redefine ownership.
        let resolvedRoot = root.resolvingSymlinksInPath()
        let systemAlias = root.path == "/var" || root.path.hasPrefix("/var/")
            || root.path == "/tmp" || root.path.hasPrefix("/tmp/")
        guard resolvedRoot.path == root.path || (systemAlias && resolvedRoot.path == "/private" + root.path) else {
            throw localImportRequired()
        }
        let normalized = url.standardizedFileURL
        var current = root
        let suffix = normalized.pathComponents.dropFirst(root.pathComponents.count)
        for component in [""] + Array(suffix) {
            if !component.isEmpty { current.appendPathComponent(component) }
            if let attributes = try? manager.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw localImportRequired()
            }
        }
        guard normalized.resolvingSymlinksInPath().pathComponents.starts(with:
                resolvedRoot.pathComponents) else { throw localImportRequired() }
        if requireRegularFile {
            let attributes = try manager.attributesOfItem(atPath: normalized.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw localImportRequired() }
        }
        return normalized
    }

    private func localImportRequired() -> MusTagError {
        message("Only files copied into the MusTag local library can be edited or restored. Import this file again; the source will not be changed.",
                "只能编辑或恢复已复制到 MusTag 本地资料库的文件。请重新导入；来源文件不会被修改。")
    }

    private func makeWorkspace() throws -> URL {
        let url = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        _ = try validatedOwnedURL(url, root: storageDirectory)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try validatedOwnedURL(url, root: storageDirectory)
        return url
    }

    private func ensureAvailableSpace(for file: URL) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let volume = try storageDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = volume.volumeAvailableCapacityForImportantUsage,
           available < Int64(size) * 2 + 8 * 1_024 * 1_024 {
            throw message("Not enough device storage to safely stage this operation.", "设备空间不足，无法安全暂存文件以完成操作。")
        }
    }

    private func resolvedURL(for original: URL, bookmark: Data?) throws -> URL {
        guard let bookmark else { return original }
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                       relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private func refreshedBookmark(_ url: URL, fallback: Data?) throws -> Data? {
        do { return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
        catch {
            if let fallback { return fallback }
            // App-owned fixtures and documents need no security-scoped grant.
            let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path + "/"
            if url.standardizedFileURL.path.hasPrefix(home) { return nil }
            throw message("Access to this file could not be saved. Select it again using Files.",
                          "无法保存此文件的访问授权，请从“文件”重新选择。")
        }
    }

    private func coordinatedCopy(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var operationError: Error?
        var accessed = false
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
            accessed = true
            do { try manager.copyItem(at: coordinated, to: destination) }
            catch { operationError = error }
        }
        if let error = coordinationError ?? operationError as NSError? { throw error }
        guard accessed else { throw message("The file provider did not return this file.", "文件提供器未返回此文件。") }
    }

    private func coordinatedHash(_ source: URL) throws -> String {
        var coordinationError: NSError?
        var result: Result<String, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
            result = Result { try Self.fileHash(coordinated) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw message("The file provider did not return this file.", "文件提供器未返回此文件。") }
        return try result.get()
    }

    private func coordinatedReplace(_ destination: URL, with staged: URL, expectedHash: String, resultHash: String) throws {
        _ = try validatedLibraryURL(destination, requireRegularFile: true)
        var coordinationError: NSError?
        var operationError: Error?
        var accessed = false
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { coordinated in
            accessed = true
            do {
                _ = try validatedLibraryURL(coordinated, requireRegularFile: true)
                try Task.checkCancellation()
                guard try Self.fileHash(coordinated) == expectedHash else { throw sourceChanged() }
                // Ask Foundation for a safe-save location on the destination's
                // volume. A grant for one document need not authorize arbitrary
                // sibling files in its parent directory (especially providers).
                let replacementDirectory = try manager.url(
                    for: .itemReplacementDirectory,
                    in: .userDomainMask,
                    appropriateFor: coordinated,
                    create: true
                )
                let replacementAccess = replacementDirectory.startAccessingSecurityScopedResource()
                defer {
                    try? manager.removeItem(at: replacementDirectory)
                    if replacementAccess { replacementDirectory.stopAccessingSecurityScopedResource() }
                }
                let replacement = replacementDirectory.appendingPathComponent(coordinated.lastPathComponent)
                try manager.copyItem(at: staged, to: replacement)
                guard try Self.fileHash(replacement) == resultHash else {
                    throw message("The temporary write failed verification. The original was not changed.",
                                  "临时写入校验失败，原文件未修改。")
                }
                try synchronizeFile(replacement)
                // Check again after copying: a network provider may take minutes.
                guard try Self.fileHash(coordinated) == expectedHash else { throw sourceChanged() }
                try Task.checkCancellation()
                _ = try validatedLibraryURL(coordinated, requireRegularFile: true)
                _ = try manager.replaceItemAt(coordinated, withItemAt: replacement, backupItemName: nil, options: [])
                // Once replacement starts, finish verification even when the user
                // cancels the surrounding batch. The next file can be cancelled.
                guard try Self.fileHash(coordinated, checkingCancellation: false) == resultHash else {
                    throw message("Write-back verification failed. The undo backup is retained in Backups.",
                                  "写回校验失败，撤销备份已保留在“备份”中。")
                }
            } catch {
                // A provider can report an error after completing the replace.
                if (try? Self.fileHash(coordinated, checkingCancellation: false)) != resultHash { operationError = error }
            }
        }
        if let error = coordinationError ?? operationError as NSError? { throw error }
        guard accessed else { throw message("The file provider did not allow this write.", "文件提供器未允许此次写入。") }
    }

    private func readJournal() throws -> [BackupRecord] {
        guard manager.fileExists(atPath: journalURL.path) else { return [] }
        let records = try JSONDecoder().decode([BackupRecord].self, from: Data(contentsOf: journalURL))
        // iOS can relocate an app's data container after updates or restores.
        // Backups belong to this store, so their location is relative to it.
        return try records.map { record in
            var record = record
            record.backupURL = backupDirectory.appendingPathComponent(record.backupURL.lastPathComponent)
            if let relativePath = record.libraryRelativePath {
                record.originalURL = try libraryURL(relativePath: relativePath)
                record.bookmark = nil
            }
            return record
        }
    }

    private func readLibrary() throws -> AudioLibrary {
        guard manager.fileExists(atPath: documentsURL.path) else {
            return AudioLibrary(documents: [], folders: [])
        }
        let data = try Data(contentsOf: documentsURL)
        let decoder = JSONDecoder()
        // Earlier versions persisted the document array directly without import origins.
        if let documents = try? decoder.decode([AudioDocument].self, from: data) {
            return AudioLibrary(documents: documents, folders: [])
        }
        return try decoder.decode(AudioLibrary.self, from: data)
    }

    private func updatePersistedDocument(_ document: AudioDocument) throws {
        var library = try readLibrary()
        if let index = library.documents.firstIndex(where: { $0.id == document.id }) {
            library.documents[index] = document
        } else {
            library.documents.append(document)
        }
        try writeJSON(library, to: documentsURL)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        _ = try validatedOwnedURL(url, root: storageDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try synchronizeFile(url)
    }

    private func synchronizeFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func sourceChanged() -> MusTagError {
        message("This file changed since it was imported. Select it again before saving.",
                "此文件在导入后发生了变化，请重新选择后再保存。")
    }

    private func message(_ english: String, _ chinese: String) -> MusTagError {
        .message(L10n.text(english, chinese))
    }

    private func tagsEquivalent(_ lhs: AudioTags, _ rhs: AudioTags) -> Bool {
        var lhs = lhs, rhs = rhs
        // Numeric MP4 atoms canonicalize leading zeros (e.g. 01/12 -> 1/12).
        for keyPath in [\AudioTags.trackNumber, \AudioTags.discNumber] {
            lhs[keyPath: keyPath] = canonicalNumber(lhs[keyPath: keyPath])
            rhs[keyPath: keyPath] = canonicalNumber(rhs[keyPath: keyPath])
        }
        return lhs == rhs
    }

    private func canonicalNumber(_ value: String) -> String {
        value.split(separator: "/", omittingEmptySubsequences: false)
            .map { Int($0).map(String.init) ?? String($0) }.joined(separator: "/")
    }

    static func fileHash(_ url: URL, checkingCancellation: Bool = true) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            if checkingCancellation { try Task.checkCancellation() }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
