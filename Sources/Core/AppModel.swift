import Foundation
import SwiftUI
#if DEBUG
import AVFoundation
#endif

enum AppTab: Hashable {
    case home, connections, settings
}

@MainActor
final class AppModel: ObservableObject {
    @Published var documents: [AudioDocument] = []
    @Published var folders: [AudioFolder] = []
    @Published var candidates: [UUID: [MetadataCandidate]] = [:]
    @Published var appliedCandidateIDs: [UUID: String] = [:]
    @Published var appliedReleaseChoices: [UUID: CandidateReleaseChoice] = [:]
    @Published var backupRecords: [BackupRecord] = []
    @Published var apiKey = APIKeyStore.load()
    @Published var recognitionProvider: RecognitionProvider {
        didSet {
            if !Self.isUITesting {
                preferences.set(recognitionProvider.rawValue, forKey: "recognitionProvider")
            }
        }
    }
    @Published var operation: String?
    @Published var currentFile = ""
    @Published var completedCount = 0
    @Published var totalCount = 0
    @Published var notice: String?
    @Published var selectedTab: AppTab = .home
    @Published var settingsNavigationPath = NavigationPath()

    private let fileStore: AudioFileStore
    private let recognition: MusicRecognitionService
    private let coverArt: CoverArtService
    private let preferences: UserDefaults
    private var operationTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var loaded = false
    private var canPersist = false
    private var pendingLocalImports: [URL] = []
    private let uiTestDirectory: URL?

    private static var isUITesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
        false
        #endif
    }

    init(fileStore: AudioFileStore? = nil,
         recognition: MusicRecognitionService = MusicRecognitionService(),
         coverArt: CoverArtService = CoverArtService(),
         recognitionProvider: RecognitionProvider? = nil,
         preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.recognitionProvider = recognitionProvider
            ?? (Self.isUITesting ? nil : preferences.string(forKey: "recognitionProvider").flatMap(RecognitionProvider.init(rawValue:)))
            ?? .shazamKit
        #if DEBUG
        if Self.isUITesting && ProcessInfo.processInfo.arguments.contains("--ui-testing-shazam") {
            let session = CoverArtUITestSupport.session()
            let hasAlbumConflict = ProcessInfo.processInfo.arguments.contains("--ui-testing-shazam-album-conflict")
            self.recognition = MusicRecognitionService(session: session,
                shazamProvider: { _ in [CoverArtUITestSupport.shazamResult()] },
                appleMusicProvider: { _ in
                    var song = CoverArtUITestSupport.appleMusicSong()
                    if hasAlbumConflict { song.albumTitle = "Different catalog album" }
                    return song
                })
            self.coverArt = CoverArtService(session: session)
            self.recognitionProvider = .shazamKit
        } else if Self.isUITesting && ProcessInfo.processInfo.arguments.contains("--ui-testing-auto-match") {
            let session = CoverArtUITestSupport.session()
            self.recognition = MusicRecognitionService(session: session, minimumAcoustIDInterval: 0, fingerprintProvider: { _ in ("ui-test-fingerprint", 120) })
            self.coverArt = CoverArtService(session: session)
            self.recognitionProvider = .acoustID
        } else if Self.isUITesting && ProcessInfo.processInfo.arguments.contains("--ui-testing-with-cover") {
            let session = CoverArtUITestSupport.session()
            self.recognition = MusicRecognitionService(session: session)
            self.coverArt = CoverArtService(session: session)
        } else {
            self.recognition = recognition
            self.coverArt = coverArt
        }
        #else
        self.recognition = recognition
        self.coverArt = coverArt
        #endif
        if let fileStore {
            self.fileStore = fileStore
            uiTestDirectory = nil
        } else if Self.isUITesting {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MusTagUITests-\(UUID().uuidString)", isDirectory: true)
            self.fileStore = AudioFileStore(codec: NativeMetadataCodec(), storageDirectory: directory)
            uiTestDirectory = directory
            apiKey = ""
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-auto-match") { apiKey = "ui-test-key" }
            #endif
        } else {
            self.fileStore = AudioFileStore(codec: NativeMetadataCodec())
            uiTestDirectory = nil
        }
    }

    var isWorking: Bool { operation != nil }
    var localLibraryDirectory: URL { fileStore.libraryDirectory }

    func enqueueLocalImports(_ urls: [URL]) {
        pendingLocalImports.append(contentsOf: urls)
        drainLocalImports()
    }

    private func drainLocalImports() {
        guard canPersist, !isWorking, !pendingLocalImports.isEmpty else { return }
        let urls = Array(Set(pendingLocalImports))
        pendingLocalImports.removeAll()
        importFiles(urls)
    }
    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var recognitionHint: String {
        recognitionProvider == .shazamKit
            ? L10n.text("ShazamKit · a unique match fills the draft; review before saving",
                        "ShazamKit · 唯一匹配填入草稿，预览后保存")
            : L10n.text("AcoustID · fixed 90% threshold; review drafts before saving",
                        "AcoustID · 固定 90% 门槛，草稿预览后保存")
    }
    var changedDocuments: [AudioDocument] { documents.filter(\.hasChanges) }
    var standaloneDocuments: [AudioDocument] {
        documents.filter { ($0.importFolderIDs ?? []).isEmpty }
    }

    func documents(in folder: AudioFolder) -> [AudioDocument] {
        documents.filter { $0.importFolderIDs?.contains(folder.id) == true }
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        do {
            let library = try await fileStore.loadLibrary()
            documents = library.documents
            folders = library.folders
            backupRecords = try await fileStore.backups()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-with-folders"),
               let directory = uiTestDirectory {
                let fixture = try Self.makeUITestAudio(in: directory)
                let music = directory.appendingPathComponent("Music Folder", isDirectory: true)
                let nested = music.appendingPathComponent("Disc 2", isDirectory: true)
                let other = directory.appendingPathComponent("Other Folder", isDirectory: true)
                let empty = directory.appendingPathComponent("Empty Folder", isDirectory: true)
                for folder in [nested, other, empty] {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                for (folder, name) in [(music, "Folder Track"), (nested, "Nested Track"), (other, "Other Track")] {
                    let url = folder.appendingPathComponent(name).appendingPathExtension("m4a")
                    try FileManager.default.copyItem(at: fixture, to: url)
                    try NativeMetadataCodec().write(AudioTags(title: name, artist: "Test artist"), to: url)
                }
                let result = try await fileStore.importFiles(from: [fixture, music, other, empty])
                documents = result.documents
                folders = result.folders
                if !result.failures.isEmpty { throw MusTagError.message(result.failures.joined(separator: "\n")) }
            } else if ProcessInfo.processInfo.arguments.contains("--ui-testing-with-audio"),
               let directory = uiTestDirectory {
                let fixture = try Self.makeUITestAudio(in: directory)
                let result = try await fileStore.importFiles(from: [fixture])
                documents = result.documents
                if !result.failures.isEmpty { throw MusTagError.message(result.failures.joined(separator: "\n")) }
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-with-cover"), let document = documents.first {
                    candidates[document.id] = [CoverArtUITestSupport.candidate(tags: document.original)]
                }
            }
            #endif
            canPersist = true
            if uiTestDirectory != nil { await persistNow() }
            drainLocalImports()
        } catch { notice = error.localizedDescription }
    }

    func document(_ id: UUID) -> AudioDocument? {
        documents.first { $0.id == id }
    }

    func updateDraft(_ tags: AudioTags, for id: UUID) {
        guard !isWorking, let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].draft = tags
        documents[index].error = nil
        appliedCandidateIDs.removeValue(forKey: id)
        appliedReleaseChoices.removeValue(forKey: id)
        schedulePersistence()
    }

    func useCandidate(_ candidate: MetadataCandidate, for id: UUID,
                      releaseChoice: CandidateReleaseChoice? = nil) {
        guard !isWorking, let document = document(id) else { return }
        begin(L10n.text("Loading match", "正在读取匹配结果"), total: 1)
        currentFile = document.fileName
        operationTask = Task {
            defer { finish() }
            do {
                notice = try await applyCandidate(candidate, to: document, releaseChoice: releaseChoice)
                completedCount = 1
            } catch is CancellationError { }
            catch { notice = error.localizedDescription }
            // begin() cancels the debounce for earlier manual edits. Keep those
            // edits durable even if loading this candidate fails or is cancelled.
            await persistNow()
        }
    }

    /// Prepare the complete selection before changing the draft, so cancellation is atomic per file.
    private func applyCandidate(_ candidate: MetadataCandidate, to document: AudioDocument,
                                releaseChoice: CandidateReleaseChoice? = nil) async throws -> String? {
        operation = L10n.text("Loading match", "正在读取匹配结果")
        try Task.checkCancellation()
        let resolved = candidate
        let hasCatalog = resolved.source == .shazamKit && resolved.appleMusicMetadata != nil
        let choice: CandidateReleaseChoice? = hasCatalog
            ? (releaseChoice ?? (resolved.hasAlbumConflict(with: document.original.album) ? nil : .appleMusic))
            : nil
        let releaseFields: Set<TagField> = [.album, .albumArtist, .year, .trackNumber, .discNumber]
        var tags = document.draft
        for field in TagField.allCases {
            if hasCatalog && releaseFields.contains(field) && choice != .appleMusic {
                // An explicit choice restores even empty original fields. Pending choices
                // leave manual draft edits intact until the user decides on the album.
                if choice == .keepOriginal { field.set(field.value(in: document.original), in: &tags) }
                continue
            }
            let proposed = field.value(in: resolved.tags)
            // Empty provider fields never erase existing user metadata.
            if !proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                field.set(proposed, in: &tags)
            }
        }
        // A newly selected release must never retain another release's pending cover.
        var artwork = document.originalArtwork
        if hasCatalog && choice == nil { artwork = document.draftArtwork }
        var coverNotice: String?
        if resolved.source == .shazamKit && (!hasCatalog || choice == .appleMusic) {
            operation = L10n.text("Downloading cover", "正在下载封面")
            do {
                let downloaded: AudioArtwork?
                if let url = resolved.artworkURL {
                    downloaded = try await coverArt.shazamCover(url: url)
                } else {
                    downloaded = nil
                }
                if let downloaded {
                    artwork = downloaded
                } else {
                    coverNotice = L10n.text(
                        "This match has no cover. Tags were added to the draft; the original cover was kept.",
                        "此匹配暂无封面。文字标签已填入草稿，原封面保持不变。")
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                coverNotice = L10n.text(
                    "Cover download failed. Tags were added to the draft; the original cover was kept. Select the match again to retry.\n",
                    "封面下载失败。文字标签已填入草稿，原封面保持不变。可再次选择此匹配重试。\n") + error.localizedDescription
            }
        }
        try Task.checkCancellation()
        let supplementationNotice = hasCatalog && choice != .appleMusic ? nil : resolved.supplementationNotice
        let notices = [supplementationNotice, coverNotice].compactMap { $0 }
        let selectionNotice = notices.isEmpty ? nil : notices.joined(separator: "\n")
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            documents[index].draft = tags
            documents[index].draftArtwork = artwork
            if resolved.source == .shazamKit {
                documents[index].draftShazamAttribution = ShazamAttribution(
                    title: resolved.tags.title, artist: resolved.tags.artist, appleMusicURL: resolved.appleMusicURL,
                    metadata: resolved.shazamMetadata, appleMusicMetadata: resolved.appleMusicMetadata)
            }
            documents[index].error = selectionNotice
            appliedCandidateIDs[document.id] = candidate.id
            appliedReleaseChoices[document.id] = choice
        }
        return selectionNotice
    }

    func discardChanges(for id: UUID) {
        guard !isWorking, let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].draft = documents[index].original
        documents[index].draftArtwork = documents[index].originalArtwork
        documents[index].draftShazamAttribution = documents[index].originalShazamAttribution
        documents[index].error = nil
        appliedCandidateIDs.removeValue(forKey: id)
        appliedReleaseChoices.removeValue(forKey: id)
        schedulePersistence()
    }

    func resetArtwork(for id: UUID) {
        guard !isWorking, let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].draftArtwork = documents[index].originalArtwork
        schedulePersistence()
    }

    func remove(_ ids: Set<UUID>) {
        guard !isWorking else { return }
        documents.removeAll { ids.contains($0.id) }
        ids.forEach {
            candidates.removeValue(forKey: $0)
            appliedCandidateIDs.removeValue(forKey: $0)
            appliedReleaseChoices.removeValue(forKey: $0)
        }
        schedulePersistence()
    }

    func removeFolder(_ folder: AudioFolder) {
        guard !isWorking else { return }
        let removedIDs = Set(documents.filter { $0.importFolderIDs == [folder.id] }.map(\.id))
        documents.removeAll { removedIDs.contains($0.id) }
        for index in documents.indices {
            documents[index].importFolderIDs?.remove(folder.id)
        }
        removedIDs.forEach {
            candidates.removeValue(forKey: $0)
            appliedCandidateIDs.removeValue(forKey: $0)
            appliedReleaseChoices.removeValue(forKey: $0)
        }
        folders.removeAll { $0.id == folder.id }
        schedulePersistence()
    }

    func importFiles(_ urls: [URL]) {
        guard !isWorking else { return }
        let scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        begin(L10n.text("Importing", "正在导入"), total: 0)
        operationTask = Task {
            defer {
                scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                finish()
            }
            do {
                let result = try await fileStore.importFiles(from: urls)
                let failures = result.failures
                for folder in result.folders {
                    if let index = folders.firstIndex(where: { $0.id == folder.id }) {
                        folders[index] = folder
                    } else {
                        folders.append(folder)
                    }
                }
                var refreshedDrafts = 0
                for incoming in result.documents {
                    if let index = documents.firstIndex(where: { existing in
                        existing.id == incoming.id || existing.url.standardizedFileURL == incoming.url.standardizedFileURL ||
                        (incoming.sourceURL != nil && (existing.sourceURL ?? existing.url).standardizedFileURL == incoming.sourceURL?.standardizedFileURL)
                    }) {
                        let existing = documents[index]
                        var refreshed = incoming
                        refreshed.id = existing.id
                        // Refreshing a file directly must keep its imported folder membership.
                        refreshed.importFolderIDs = (existing.importFolderIDs ?? []).union(incoming.importFolderIDs ?? [])
                        if refreshed.sourceHash == existing.sourceHash {
                            refreshed.originalShazamAttribution = existing.originalShazamAttribution
                            refreshed.draftShazamAttribution = existing.draftShazamAttribution
                        }
                        if existing.hasChanges {
                            // Rebase only edited fields; preserve unrelated changes made by another app.
                            var draft = incoming.original
                            for field in TagField.allCases where field.value(in: existing.original) != field.value(in: existing.draft) {
                                field.set(field.value(in: existing.draft), in: &draft)
                            }
                            refreshed.draft = draft
                            if existing.hasArtworkChanges { refreshed.draftArtwork = existing.draftArtwork }
                            refreshed.draftShazamAttribution = existing.draftShazamAttribution
                            refreshedDrafts += 1
                        }
                        documents[index] = refreshed
                        candidates.removeValue(forKey: existing.id)
                        appliedCandidateIDs.removeValue(forKey: existing.id)
                        appliedReleaseChoices.removeValue(forKey: existing.id)
                    } else { documents.append(incoming) }
                }
                await persistNow()
                if !failures.isEmpty {
                    notice = L10n.text("Some files could not be imported:\n", "部分文件未能导入：\n") + failures.prefix(8).joined(separator: "\n")
                } else if result.documents.isEmpty && result.folders.isEmpty {
                    notice = L10n.text("No supported audio files found. Choose MP3, FLAC or M4A files.", "没有找到支持的音频文件。请选择 MP3、FLAC 或 M4A 文件。")
                } else if refreshedDrafts > 0 {
                    notice = L10n.text("Original files refreshed. Your edited fields were kept in the draft; review them against the current file before saving.", "已重新读取原文件。你编辑过的字段仍保留在草稿中，请对照当前文件重新预览后保存。")
                }
            } catch is CancellationError {
                notice = L10n.text("Import cancelled.", "已取消导入。")
            } catch { notice = error.localizedDescription }
        }
    }

    func identify(_ ids: Set<UUID>, automaticallyApply: Bool = false) {
        guard !isWorking else { return }
        guard recognitionProvider != .acoustID || hasAPIKey else {
            settingsNavigationPath = NavigationPath()
            selectedTab = .settings
            return
        }
        let items = documents.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        begin(L10n.text("Identifying", "正在识别"), total: items.count)
        let key = apiKey
        let provider = recognitionProvider
        operationTask = Task {
            defer { finish() }
            var failures: [String] = []
            var applied = 0
            var pending = 0
            var unmatched = 0
            var detailWarnings = 0
            for item in items {
                if Task.isCancelled { break }
                currentFile = item.fileName
                operation = L10n.text("Identifying", "正在识别")
                candidates.removeValue(forKey: item.id)
                appliedCandidateIDs.removeValue(forKey: item.id)
                appliedReleaseChoices.removeValue(forKey: item.id)
                do {
                    let url = try accessibleURL(for: item)
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let matches = try await recognition.identify(url: url, apiKey: key, provider: provider)
                    try Task.checkCancellation()
                    candidates[item.id] = matches
                    if automaticallyApply {
                        switch MusicRecognitionService.automaticMatch(from: matches) {
                        case .selected(let candidate):
                            let warning = try await applyCandidate(candidate, to: item)
                            applied += 1
                            if candidate.hasAlbumConflict(with: item.original.album) { pending += 1 }
                            if warning != nil { detailWarnings += 1 }
                        case .belowThreshold:
                            pending += 1
                            setError(L10n.text("Best similarity is below 90%. Choose a match manually; your draft was kept.",
                                               "最高相似度低于 90%，请手动选择匹配；已有草稿保持不变。"), for: item.id)
                        case .ambiguous:
                            pending += 1
                            setError(provider == .shazamKit
                                ? L10n.text("Shazam returned several matches. Choose one manually; your draft was kept.",
                                            "Shazam 返回了多个匹配，请手动选择；已有草稿保持不变。")
                                : L10n.text("Several matches share the highest similarity. Choose a song manually; your draft was kept.",
                                            "存在多个最高相似度匹配，请手动选择；已有草稿保持不变。"), for: item.id)
                        case .noMatch:
                            unmatched += 1
                            setError(L10n.text("No match found. Try another recognition provider or edit manually.",
                                               "未找到匹配，可切换识别服务或手动编辑。"), for: item.id)
                        }
                    } else {
                        setError(matches.isEmpty ? L10n.text("No match found. Try another recognition provider or edit manually.", "未找到匹配，可切换识别服务或手动编辑。") : nil, for: item.id)
                    }
                } catch is CancellationError { break }
                catch {
                    setError(error.localizedDescription, for: item.id)
                    failures.append(item.fileName + ": " + error.localizedDescription)
                }
                completedCount += 1
                await persistNow()
            }
            // begin() cancels pending debounced edits; persist even if the first file was cancelled.
            await persistNow()
            if automaticallyApply {
                var lines = [
                    L10n.text("Added to drafts: \(applied)", "已填入草稿：\(applied)"),
                    L10n.text("Needs manual selection: \(pending)", "待手动确认：\(pending)"),
                    L10n.text("No match: \(unmatched)", "未找到匹配：\(unmatched)"),
                    L10n.text("Failed: \(failures.count)", "处理失败：\(failures.count)")
                ]
                if detailWarnings > 0 {
                    lines.append(L10n.text("Metadata or cover notices: \(detailWarnings)", "补全或封面提示：\(detailWarnings)"))
                }
                if Task.isCancelled {
                    lines.append(L10n.text("Stopped. Unprocessed: \(items.count - completedCount)",
                                           "已停止，尚未处理：\(items.count - completedCount)"))
                }
                lines.append(L10n.text("Review the drafts before saving to your files.", "请预览草稿，确认后保存到文件。"))
                lines.append(contentsOf: failures.prefix(5))
                if let persistenceNotice = notice { lines.append(persistenceNotice) }
                notice = lines.joined(separator: "\n")
            } else if !failures.isEmpty {
                notice = failures.prefix(5).joined(separator: "\n")
            }
        }
    }

    /// Called only after the review sheet's explicit confirmation.
    func save(_ ids: Set<UUID>) {
        guard !isWorking else { return }
        let items = documents.filter { ids.contains($0.id) && $0.hasChanges }
        guard !items.isEmpty else { return }
        begin(L10n.text("Saving", "正在保存"), total: items.count)
        operationTask = Task {
            defer { finish() }
            var failures: [String] = []
            for item in items {
                if Task.isCancelled { break }
                currentFile = item.fileName
                do {
                    let (saved, _) = try await fileStore.save(item)
                    if let index = documents.firstIndex(where: { $0.id == item.id }) { documents[index] = saved }
                } catch is CancellationError { break }
                catch {
                    setError(error.localizedDescription, for: item.id)
                    failures.append(item.fileName + ": " + error.localizedDescription)
                }
                completedCount += 1
                await persistNow()
            }
            await refreshBackups()
            if !failures.isEmpty { notice = failures.prefix(5).joined(separator: "\n") }
        }
    }

    func restore(_ backup: BackupRecord) {
        guard !isWorking else { return }
        begin(L10n.text("Restoring", "正在恢复"), total: 1)
        currentFile = backup.originalURL.lastPathComponent
        operationTask = Task {
            defer { finish() }
            do {
                var restored = try await fileStore.restore(backup)
                if let index = documents.firstIndex(where: { $0.id == restored.id || $0.url == restored.url }) {
                    restored.importFolderIDs = documents[index].importFolderIDs
                    documents[index] = restored
                } else {
                    // A just-removed folder may still be in the debounced on-disk index.
                    restored.importFolderIDs = restored.importFolderIDs?.intersection(folders.map(\.id))
                    documents.append(restored)
                }
                appliedCandidateIDs.removeValue(forKey: restored.id)
                appliedReleaseChoices.removeValue(forKey: restored.id)
                candidates.removeValue(forKey: restored.id)
                completedCount = 1
                await persistNow()
                await refreshBackups()
            } catch { notice = error.localizedDescription }
        }
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !Self.isUITesting { try APIKeyStore.save(trimmed) }
        apiKey = trimmed
    }

    func cancelOperation() { operationTask?.cancel() }

    func refreshBackups() async {
        do { backupRecords = try await fileStore.backups() }
        catch { notice = error.localizedDescription }
    }

    private func begin(_ name: String, total: Int) {
        persistenceTask?.cancel()
        notice = nil
        operation = name
        currentFile = ""
        completedCount = 0
        totalCount = total
    }

    private func finish() {
        operation = nil
        currentFile = ""
        operationTask = nil
        drainLocalImports()
    }

    private func setError(_ message: String?, for id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].error = message
    }

    private func accessibleURL(for document: AudioDocument) throws -> URL {
        guard let bookmark = document.bookmark else { return document.url }
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private func schedulePersistence() {
        persistenceTask?.cancel()
        persistenceTask = Task {
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            await persistNow()
        }
    }

    func persistNow() async {
        // Scene transitions can arrive while the initial actor read is still pending.
        // Never replace an unread or unreadable on-disk index with an empty model.
        guard canPersist else { return }
        do { try await fileStore.persistLibrary(AudioLibrary(documents: documents, folders: folders)) }
        catch { notice = error.localizedDescription }
    }

    #if DEBUG
    /// A genuine encoded audio file, isolated from user files, for end-to-end UI tests.
    private static func makeUITestAudio(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("UI Test.m4a")
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000
        ])
        guard let format = file?.processingFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100),
              let samples = buffer.floatChannelData?[0] else {
            throw MusTagError.message("Could not create UI test audio.")
        }
        buffer.frameLength = 44_100
        for frame in 0..<44_100 {
            samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44_100) * 0.2)
        }
        try file?.write(from: buffer)
        file = nil
        try NativeMetadataCodec().write(AudioTags(title: "Original title", artist: "Test artist", album: "Test album"), to: url)
        return url
    }
    #endif
}

enum TagField: String, CaseIterable, Identifiable {
    case title, artist, album, albumArtist, year, trackNumber, discNumber, genre
    var id: String { rawValue }
    var label: String {
        switch self {
        case .title: return L10n.text("Title", "歌名")
        case .artist: return L10n.text("Artist", "艺术家")
        case .album: return L10n.text("Album", "专辑")
        case .albumArtist: return L10n.text("Album artist", "专辑艺术家")
        case .year: return L10n.text("Year", "年份")
        case .trackNumber: return L10n.text("Track", "曲序")
        case .discNumber: return L10n.text("Disc", "碟号")
        case .genre: return L10n.text("Genre", "流派")
        }
    }
    var keyPath: WritableKeyPath<AudioTags, String> {
        switch self {
        case .title: return \.title
        case .artist: return \.artist
        case .album: return \.album
        case .albumArtist: return \.albumArtist
        case .year: return \.year
        case .trackNumber: return \.trackNumber
        case .discNumber: return \.discNumber
        case .genre: return \.genre
        }
    }
    func value(in tags: AudioTags) -> String { tags[keyPath: keyPath] }
    func set(_ value: String, in tags: inout AudioTags) { tags[keyPath: keyPath] = value }
}
