import Foundation
import SwiftUI
#if DEBUG
import AVFoundation
#endif

@MainActor
final class AppModel: ObservableObject {
    @Published var documents: [AudioDocument] = []
    @Published var candidates: [UUID: [MetadataCandidate]] = [:]
    @Published var backupRecords: [BackupRecord] = []
    @Published var apiKey = APIKeyStore.load()
    @Published var operation: String?
    @Published var currentFile = ""
    @Published var completedCount = 0
    @Published var totalCount = 0
    @Published var notice: String?
    @Published var showsSettings = false

    private let fileStore: AudioFileStore
    private let recognition: MusicRecognitionService
    private let coverArt: CoverArtService
    private var operationTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var loaded = false
    private var canPersist = false
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
         coverArt: CoverArtService = CoverArtService()) {
        #if DEBUG
        if Self.isUITesting && ProcessInfo.processInfo.arguments.contains("--ui-testing-with-cover") {
            let session = CoverArtUITestSupport.session()
            self.recognition = MusicRecognitionService(session: session, minimumMusicBrainzInterval: 0)
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
        } else {
            self.fileStore = AudioFileStore(codec: NativeMetadataCodec())
            uiTestDirectory = nil
        }
    }

    var isWorking: Bool { operation != nil }
    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var changedDocuments: [AudioDocument] { documents.filter(\.hasChanges) }

    func load() async {
        guard !loaded else { return }
        loaded = true
        do {
            documents = try await fileStore.loadDocuments()
            backupRecords = try await fileStore.backups()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-with-audio"),
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
        } catch { notice = error.localizedDescription }
    }

    func document(_ id: UUID) -> AudioDocument? {
        documents.first { $0.id == id }
    }

    func updateDraft(_ tags: AudioTags, for id: UUID) {
        guard !isWorking, let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].draft = tags
        documents[index].error = nil
        schedulePersistence()
    }

    func useCandidate(_ candidate: MetadataCandidate, for id: UUID) {
        guard !isWorking, let document = document(id) else { return }
        begin(L10n.text("Loading release", "正在读取发行版本"), total: 1)
        operationTask = Task {
            defer { finish() }
            do {
                let resolved = try await recognition.resolve(candidate)
                var tags = document.draft
                // Empty provider fields never erase existing user metadata.
                for field in TagField.allCases {
                    let proposed = field.value(in: resolved.tags)
                    if !proposed.isEmpty { field.set(proposed, in: &tags) }
                }
                // A newly selected release must never retain another release's pending cover.
                var artwork = document.originalArtwork
                var coverNotice: String?
                if let releaseID = resolved.releaseID {
                    operation = L10n.text("Downloading cover", "正在下载封面")
                    do {
                        if let downloaded = try await coverArt.frontCover(releaseID: releaseID) {
                            artwork = downloaded
                        } else {
                            coverNotice = L10n.text(
                                "This release has no front cover. Tags were added to the draft; the original cover was kept.",
                                "此发行版本暂无正面封面。文字标签已填入草稿，原封面保持不变。")
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        coverNotice = L10n.text(
                            "Cover download failed. Tags were added to the draft; the original cover was kept. Select the release again to retry.\n",
                            "封面下载失败。文字标签已填入草稿，原封面保持不变。可再次选择此版本重试。\n") + error.localizedDescription
                    }
                } else {
                    coverNotice = L10n.text("This match has no release to look up a cover. The original cover was kept.",
                                            "此匹配没有可用于查找封面的发行版本，原封面保持不变。")
                }
                try Task.checkCancellation()
                if let index = documents.firstIndex(where: { $0.id == id }) {
                    documents[index].draft = tags
                    documents[index].draftArtwork = artwork
                    documents[index].error = nil
                }
                notice = coverNotice
                completedCount = 1
                await persistNow()
            } catch is CancellationError { }
            catch { notice = error.localizedDescription }
        }
    }

    func discardChanges(for id: UUID) {
        guard !isWorking, let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].draft = documents[index].original
        documents[index].draftArtwork = documents[index].originalArtwork
        documents[index].error = nil
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
        ids.forEach { candidates.removeValue(forKey: $0) }
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
                var refreshedDrafts = 0
                for incoming in result.documents {
                    if let index = documents.firstIndex(where: { $0.url.standardizedFileURL == incoming.url.standardizedFileURL }) {
                        let existing = documents[index]
                        var refreshed = incoming
                        refreshed.id = existing.id
                        if existing.hasChanges {
                            // Rebase only edited fields; preserve unrelated changes made by another app.
                            var draft = incoming.original
                            for field in TagField.allCases where field.value(in: existing.original) != field.value(in: existing.draft) {
                                field.set(field.value(in: existing.draft), in: &draft)
                            }
                            refreshed.draft = draft
                            if existing.hasArtworkChanges { refreshed.draftArtwork = existing.draftArtwork }
                            refreshedDrafts += 1
                        }
                        documents[index] = refreshed
                        candidates.removeValue(forKey: existing.id)
                    } else { documents.append(incoming) }
                }
                await persistNow()
                if !failures.isEmpty {
                    notice = L10n.text("Some files could not be imported:\n", "部分文件未能导入：\n") + failures.prefix(8).joined(separator: "\n")
                } else if result.documents.isEmpty {
                    notice = L10n.text("No supported audio files found. Choose MP3, FLAC or M4A files.", "没有找到支持的音频文件。请选择 MP3、FLAC 或 M4A 文件。")
                } else if refreshedDrafts > 0 {
                    notice = L10n.text("Original files refreshed. Your edited fields were kept in the draft; review them against the current file before saving.", "已重新读取原文件。你编辑过的字段仍保留在草稿中，请对照当前文件重新预览后保存。")
                }
            } catch is CancellationError {
                notice = L10n.text("Import cancelled.", "已取消导入。")
            } catch { notice = error.localizedDescription }
        }
    }

    func identify(_ ids: Set<UUID>) {
        guard !isWorking else { return }
        guard hasAPIKey else { showsSettings = true; return }
        let items = documents.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        begin(L10n.text("Identifying", "正在识别"), total: items.count)
        let key = apiKey
        operationTask = Task {
            defer { finish() }
            var failures: [String] = []
            for item in items {
                if Task.isCancelled { break }
                currentFile = item.fileName
                do {
                    let url = try accessibleURL(for: item)
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let matches = try await recognition.identify(url: url, apiKey: key)
                    candidates[item.id] = matches
                    setError(matches.isEmpty ? L10n.text("No match found. Try a title search or edit manually.", "未找到匹配，可按歌名搜索或手动编辑。") : nil, for: item.id)
                } catch is CancellationError { break }
                catch {
                    setError(error.localizedDescription, for: item.id)
                    failures.append(item.fileName + ": " + error.localizedDescription)
                }
                completedCount += 1
            }
            await persistNow()
            if !failures.isEmpty {
                notice = failures.prefix(5).joined(separator: "\n")
            }
        }
    }

    func search(_ id: UUID, title: String, artist: String) {
        guard !isWorking else { return }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice = L10n.text("Enter a title to search MusicBrainz.", "请输入歌名以搜索 MusicBrainz。")
            return
        }
        begin(L10n.text("Searching", "正在搜索"), total: 1)
        currentFile = document(id)?.fileName ?? ""
        operationTask = Task {
            defer { finish() }
            do {
                let matches = try await recognition.search(title: title, artist: artist)
                candidates[id] = matches
                setError(matches.isEmpty ? L10n.text("No results. Try another title or artist.", "没有找到结果，请调整歌名或艺术家。") : nil, for: id)
                completedCount = 1
                await persistNow()
            } catch is CancellationError { }
            catch { notice = error.localizedDescription }
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
                let restored = try await fileStore.restore(backup)
                if let index = documents.firstIndex(where: { $0.id == restored.id || $0.url == restored.url }) {
                    documents[index] = restored
                } else { documents.append(restored) }
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
        do { try await fileStore.persistDocuments(documents) }
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
