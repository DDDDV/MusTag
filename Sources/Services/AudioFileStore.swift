import CryptoKit
import Foundation

/// Owns all original-file mutations. Original audio is never handed to the tag writer.
/// Full backups and the undo journal are made durable before replacement begins.
actor AudioFileStore {
    typealias PayloadHasher = @Sendable (URL) throws -> String

    private let codec: any AudioMetadataCodec
    private let payloadHasher: PayloadHasher
    private let storageDirectory: URL
    private let manager = FileManager.default
    private static let supportedExtensions: Set<String> = ["mp3", "flac", "m4a"]

    init(
        codec: any AudioMetadataCodec,
        storageDirectory: URL? = nil,
        payloadHasher: @escaping PayloadHasher = { try NativeAudio.payloadHash(url: $0) }
    ) {
        self.codec = codec
        self.payloadHasher = payloadHasher
        self.storageDirectory = storageDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("MusTag", isDirectory: true)
    }

    private var documentsURL: URL { storageDirectory.appendingPathComponent("documents.json") }
    private var journalURL: URL { storageDirectory.appendingPathComponent("backups.json") }
    private var backupDirectory: URL { storageDirectory.appendingPathComponent("Backups", isDirectory: true) }
    private var stagingDirectory: URL { storageDirectory.appendingPathComponent("Staging", isDirectory: true) }

    func importFiles(from urls: [URL]) throws -> ImportResult {
        try prepareStorage()
        var documents: [AudioDocument] = []
        var failures: [String] = []
        var seen = Set<String>()

        do {
            for root in urls {
                try Task.checkCancellation()
                let accessing = root.startAccessingSecurityScopedResource()
                defer { if accessing { root.stopAccessingSecurityScopedResource() } }

                do {
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

                        for case let file as URL in enumerator {
                            try Task.checkCancellation()
                            do {
                                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                                guard values.isRegularFile == true,
                                      Self.supportedExtensions.contains(file.pathExtension.lowercased()) else { continue }
                                try importOne(file, seen: &seen, documents: &documents)
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
                        try importOne(root, seen: &seen, documents: &documents)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append("\(root.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch is CancellationError {
            guard !documents.isEmpty else { throw CancellationError() }
            failures.append(L10n.text("Import stopped. Files already imported were kept.", "导入已停止，已导入的文件已保留。"))
        }
        return ImportResult(documents: documents, failures: failures)
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

        let source = try resolvedURL(for: document.url, bookmark: document.bookmark)
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
            .appendingPathExtension(source.pathExtension)
        var journaled = false
        defer { if !journaled { try? manager.removeItem(at: backupURL) } }
        try manager.copyItem(at: staged, to: backupURL)
        try synchronizeFile(backupURL)
        guard try Self.fileHash(backupURL) == originalHash else {
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
        var backup = BackupRecord(
            documentID: document.id,
            originalURL: source,
            bookmark: try refreshedBookmark(source, fallback: document.bookmark),
            backupURL: backupURL,
            originalHash: originalHash,
            writtenHash: writtenHash
        )
        backup.id = backupID
        var journal = try readJournal()
        journal.append(backup)
        try writeJSON(journal, to: journalURL)
        journaled = true

        // Cancellation after the journal is durable but before the replace is safe.
        try Task.checkCancellation()
        try coordinatedReplace(source, with: staged, expectedHash: originalHash, resultHash: writtenHash)

        var updated = document
        updated.url = source
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
        let backup = journal[index]
        guard !backup.restored else {
            throw message("This backup has already been restored.", "此备份已恢复。")
        }
        guard try Self.fileHash(backup.backupURL) == backup.originalHash else {
            throw message("The backup failed verification. Nothing was changed.", "备份校验失败，未修改任何文件。")
        }
        let source = try resolvedURL(for: backup.originalURL, bookmark: backup.bookmark)
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let workspace = try makeWorkspace()
        defer { try? manager.removeItem(at: workspace) }
        let originalCopy = workspace.appendingPathComponent("restore").appendingPathExtension(source.pathExtension)
        try manager.copyItem(at: backup.backupURL, to: originalCopy)
        let snapshot = try codec.read(from: originalCopy)
        let currentHash = try coordinatedHash(source)
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
        do { try updatePersistedDocument(document) } catch {
            document.error = L10n.text(
                "Restored, but the library list could not be updated. Reimport this file before editing again.",
                "文件已恢复，但列表状态保存失败。再次编辑前请重新导入此文件。"
            )
        }
        return document
    }

    func loadDocuments() throws -> [AudioDocument] {
        try prepareStorage()
        guard manager.fileExists(atPath: documentsURL.path) else { return [] }
        var documents = try JSONDecoder().decode([AudioDocument].self, from: Data(contentsOf: documentsURL))
        for index in documents.indices {
            do {
                let url = try resolvedURL(for: documents[index].url, bookmark: documents[index].bookmark)
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                documents[index].url = url
                documents[index].bookmark = try refreshedBookmark(url, fallback: documents[index].bookmark)
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
                    "Reconnect the drive and select this file again.", "请重新连接存储位置并再次选择此文件。"
                )
            }
        }
        return documents
    }

    func persistDocuments(_ documents: [AudioDocument]) throws {
        try prepareStorage()
        try writeJSON(documents, to: documentsURL)
    }

    private func importOne(_ source: URL, seen: inout Set<String>, documents: inout [AudioDocument]) throws {
        let identity = source.standardizedFileURL.absoluteString
        guard seen.insert(identity).inserted else { return }
        let workspace = try makeWorkspace()
        defer { try? manager.removeItem(at: workspace) }
        let staged = workspace.appendingPathComponent("original").appendingPathExtension(source.pathExtension)
        try coordinatedCopy(from: source, to: staged)
        try Task.checkCancellation()
        let hash = try Self.fileHash(staged)
        let snapshot = try codec.read(from: staged)
        documents.append(AudioDocument(
            url: source, bookmark: try refreshedBookmark(source, fallback: nil),
            original: snapshot.tags, draft: snapshot.tags, duration: snapshot.duration,
            error: nil, sourceHash: hash,
            originalArtwork: snapshot.artwork, draftArtwork: snapshot.artwork
        ))
    }

    private func prepareStorage() throws {
        for directory in [storageDirectory, backupDirectory, stagingDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var root = storageDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    private func makeWorkspace() throws -> URL {
        let url = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func ensureAvailableSpace(for file: URL) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let volume = try storageDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = volume.volumeAvailableCapacityForImportantUsage,
           available < Int64(size) * 2 + 8 * 1_024 * 1_024 {
            throw message("Not enough device storage for a safe backup and edit.", "设备空间不足，无法安全备份和编辑。")
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
        var coordinationError: NSError?
        var operationError: Error?
        var accessed = false
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { coordinated in
            accessed = true
            do {
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
                _ = try manager.replaceItemAt(coordinated, withItemAt: replacement, backupItemName: nil, options: [])
                // Once replacement starts, finish verification even when the user
                // cancels the surrounding batch. The next file can be cancelled.
                guard try Self.fileHash(coordinated, checkingCancellation: false) == resultHash else {
                    throw message("Write-back verification failed. The original backup is retained in Backups.",
                                  "写回校验失败，原文件备份已保留在“备份”中。")
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
        return records.map { record in
            var record = record
            record.backupURL = backupDirectory.appendingPathComponent(record.backupURL.lastPathComponent)
            return record
        }
    }

    private func updatePersistedDocument(_ document: AudioDocument) throws {
        var documents: [AudioDocument] = []
        if manager.fileExists(atPath: documentsURL.path) {
            documents = try JSONDecoder().decode([AudioDocument].self, from: Data(contentsOf: documentsURL))
        }
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            documents[index] = document
        } else {
            documents.append(document)
        }
        try writeJSON(documents, to: documentsURL)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
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
