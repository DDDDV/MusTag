import Foundation

/// Personal-use AcoustID + MusicBrainz integration. No audio is uploaded.
/// MusicBrainz release selection is always explicit; a recording is not an album edition.
actor MusicRecognitionService {
    typealias FingerprintProvider = @Sendable (URL) async throws -> (fingerprint: String, duration: Double)

    private let session: URLSession
    private let fingerprintProvider: FingerprintProvider
    private let minimumMusicBrainzInterval: TimeInterval
    private let minimumAcoustIDInterval: TimeInterval
    private var nextMusicBrainzRequest = Date.distantPast
    private var nextAcoustIDRequest = Date.distantPast
    private var recordingCache: [String: MBRecording] = [:]
    private var releaseCache: [String: MBRelease] = [:]
    private var searchCache: [String: [MetadataCandidate]] = [:]
    private static let maximumCacheEntries = 200

    init(session: URLSession? = nil,
         minimumMusicBrainzInterval: TimeInterval = 1.05,
         minimumAcoustIDInterval: TimeInterval = 0.35,
         fingerprintProvider: @escaping FingerprintProvider = { url in
             try await NativeAudio.fingerprint(url: url)
         }) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 45
            configuration.httpMaximumConnectionsPerHost = 2
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
        self.minimumMusicBrainzInterval = minimumMusicBrainzInterval
        self.minimumAcoustIDInterval = minimumAcoustIDInterval
        self.fingerprintProvider = fingerprintProvider
    }

    func identify(url: URL, apiKey: String) async throws -> [MetadataCandidate] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw MusTagError.message(L10n.text("Add your AcoustID application API key in Settings to identify audio.",
                                               "请先在设置中填写 AcoustID 应用 API Key，再识别音频。"))
        }
        try Task.checkCancellation()
        let staged = try Self.stageForReading(url)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        let signature = try await fingerprintProvider(staged)
        try Task.checkCancellation()
        guard signature.duration.isFinite, signature.duration > 0,
              signature.duration < Double(Int.max) - 1, !signature.fingerprint.isEmpty else {
            throw MusTagError.message(L10n.text("This file did not produce a usable audio fingerprint.", "此文件无法生成有效音频指纹。"))
        }

        var request = URLRequest(url: URL(string: "https://api.acoustid.org/v2/lookup")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            .init(name: "client", value: key),
            .init(name: "format", value: "json"),
            .init(name: "duration", value: String(Int(signature.duration.rounded()))),
            .init(name: "fingerprint", value: signature.fingerprint),
            .init(name: "meta", value: "recordings")
        ]
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let data = try await fetch(request, provider: .acoustID)
        let response: AcoustIDResponse = try decode(data)
        guard response.status == "ok" else {
            if response.error?.code == 4 || response.error?.code == 5 {
                throw MusTagError.message(L10n.text("AcoustID rejected the API key. Use an application key, not a user submission key.",
                                                   "AcoustID 拒绝了此 API Key，请使用应用 Key，而非用户提交指纹用的 Key。"))
            }
            throw MusTagError.message(L10n.text("AcoustID could not complete this lookup. Check your key and try again.",
                                               "AcoustID 无法完成查询，请检查 Key 后重试。"))
        }
        let matches = Self.recordingMatches(from: response)
        var candidates: [MetadataCandidate] = []
        for match in matches.prefix(5) {
            try Task.checkCancellation()
            do {
                let recording = try await recording(id: match.id)
                candidates += Self.candidates(from: recording, fingerprintScore: match.score)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // An AcoustID recording title/artist remains useful if MusicBrainz is temporarily down.
                guard let title = match.title, !title.isEmpty else { throw error }
                let tags = AudioTags(title: title, artist: match.artist ?? "")
                candidates.append(MetadataCandidate(id: match.id, recordingID: match.id,
                    tags: tags, duration: match.duration, score: match.score,
                    detail: L10n.text("AcoustID · album details unavailable; try again later",
                                      "AcoustID · 暂时无法获取专辑信息，可稍后重试")))
            }
        }
        return Self.uniqueCandidates(candidates)
    }

    func search(title: String, artist: String) async throws -> [MetadataCandidate] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw MusTagError.message(L10n.text("Enter a title to search MusicBrainz.", "请填写歌曲名后搜索 MusicBrainz。"))
        }
        let query = Self.searchQuery(title: title, artist: artist)
        if let cached = searchCache[query] { return cached }
        let request = try musicBrainzRequest(path: "recording", query: [
            .init(name: "query", value: query), .init(name: "limit", value: "12")
        ])
        let data = try await fetch(request, provider: .musicBrainz)
        let response: MBSearchResponse = try decode(data)
        let results = Self.uniqueCandidates(response.recordings.flatMap {
            Self.candidates(from: $0, fingerprintScore: nil)
        })
        trimCachesIfNeeded()
        searchCache[query] = results
        return results
    }

    /// Look up only the edition the person selected, and fill track/disc only if unambiguous.
    func resolve(_ candidate: MetadataCandidate) async throws -> MetadataCandidate {
        guard let releaseID = candidate.releaseID else { return candidate }
        let release: MBRelease
        if let cached = releaseCache[releaseID] {
            release = cached
        } else {
            let request = try musicBrainzRequest(path: "release/\(releaseID)", query: [
                .init(name: "inc", value: "recordings+artist-credits")
            ])
            let data = try await fetch(request, provider: .musicBrainz)
            release = try decode(data)
            trimCachesIfNeeded()
            releaseCache[releaseID] = release
        }
        return Self.resolve(candidate, with: release)
    }

    private func recording(id: String) async throws -> MBRecording {
        if let cached = recordingCache[id] { return cached }
        let request = try musicBrainzRequest(path: "recording/\(id)", query: [
            .init(name: "inc", value: "artists+releases")
        ])
        let data = try await fetch(request, provider: .musicBrainz)
        let recording: MBRecording = try decode(data)
        trimCachesIfNeeded()
        recordingCache[id] = recording
        return recording
    }

    private func musicBrainzRequest(path: String, query: [URLQueryItem]) throws -> URLRequest {
        // IDs are controlled by the remote schema, but still validate before building URL paths.
        if path.contains("/") {
            guard let id = path.split(separator: "/").last, UUID(uuidString: String(id)) != nil else {
                throw MusTagError.message(L10n.text("The metadata provider returned an invalid identifier.", "元数据服务返回了无效标识。"))
            }
        }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/\(path)")!
        components.queryItems = query + [.init(name: "fmt", value: "json")]
        return URLRequest(url: components.url!)
    }

    private enum Provider { case musicBrainz, acoustID }

    private func fetch(_ baseRequest: URLRequest, provider: Provider) async throws -> Data {
        var request = baseRequest
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let contact = (Bundle.main.object(forInfoDictionaryKey: "MusicBrainzContact") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        request.setValue("MusTag/0.1.0 (\(contact.isEmpty ? "personal development build" : contact))", forHTTPHeaderField: "User-Agent")
        for attempt in 0...1 {
            try await waitForSlot(provider)
            try Task.checkCancellation()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw MusTagError.message(L10n.text("Unable to reach the recognition service. Check your connection and retry.",
                                                   "无法连接识别服务，请检查网络后重试。"))
            }
            guard let http = response as? HTTPURLResponse else {
                throw MusTagError.message(L10n.text("The recognition service returned an invalid response.", "识别服务返回了无效响应。"))
            }
            if (http.statusCode == 429 || http.statusCode == 503), attempt == 0 {
                let retry = min(max(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2, 1), 10)
                try await Task.sleep(nanoseconds: UInt64(retry * 1_000_000_000))
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw MusTagError.message(L10n.text("The service denied access. Check the API key and service permissions.",
                                                       "服务拒绝访问，请检查 API Key 和服务权限。"))
                }
                throw MusTagError.message(L10n.text("The recognition service is unavailable (HTTP \(http.statusCode)). Try again later.",
                                                   "识别服务暂不可用（HTTP \(http.statusCode)），请稍后重试。"))
            }
            guard data.count <= 4 * 1024 * 1024 else {
                throw MusTagError.message(L10n.text("The metadata response was too large.", "元数据响应过大。"))
            }
            return data
        }
        throw MusTagError.message(L10n.text("The service is busy. Try again later.", "服务繁忙，请稍后重试。"))
    }

    private func waitForSlot(_ provider: Provider) async throws {
        while true {
            try Task.checkCancellation()
            let now = Date()
            let next = provider == .musicBrainz ? nextMusicBrainzRequest : nextAcoustIDRequest
            let delay = next.timeIntervalSince(now)
            if delay <= 0 {
                if provider == .musicBrainz {
                    nextMusicBrainzRequest = now.addingTimeInterval(minimumMusicBrainzInterval)
                } else {
                    nextAcoustIDRequest = now.addingTimeInterval(minimumAcoustIDInterval)
                }
                return
            }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            // Recheck after every suspension: queued calls must not burst when iOS resumes the app.
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            throw MusTagError.message(L10n.text("The metadata response could not be read. Try again later.",
                                               "无法读取元数据响应，请稍后重试。"))
        }
    }

    private func trimCachesIfNeeded() {
        if recordingCache.count >= Self.maximumCacheEntries { recordingCache.removeAll(keepingCapacity: true) }
        if releaseCache.count >= Self.maximumCacheEntries { releaseCache.removeAll(keepingCapacity: true) }
        if searchCache.count >= Self.maximumCacheEntries { searchCache.removeAll(keepingCapacity: true) }
    }

    private static func stageForReading(_ url: URL) throws -> URL {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MusTag-recognition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinated in
            do {
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: coordinated, to: destination)
            } catch { copyError = error }
        }
        if let error = coordinationError ?? (copyError as NSError?) {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return destination
    }

    static func searchQuery(title: String, artist: String) -> String {
        func escaped(_ text: String) -> String {
            let reserved = Set("+-!():^[]\"{}~*?|&/\\")
            return text.map { reserved.contains($0) ? "\\\($0)" : String($0) }.joined()
        }
        var query = "recording:\"\(escaped(title))\""
        if !artist.isEmpty { query += " AND artist:\"\(escaped(artist))\"" }
        return query
    }

    static func candidates(from recording: MBRecording, fingerprintScore: Double?) -> [MetadataCandidate] {
        let artist = MBArtistCredit.display(recording.artistCredit)
        var base = AudioTags(title: recording.title, artist: artist)
        let duration = recording.length.map { Double($0) / 1_000 }
        guard let releases = recording.releases, !releases.isEmpty else {
            return [MetadataCandidate(id: recording.id, recordingID: recording.id, tags: base,
                duration: duration, score: fingerprintScore,
                detail: L10n.text("MusicBrainz · recording only", "MusicBrainz · 仅录音信息"))]
        }
        // A bounded edition list makes selection usable; do not rank by an invented probability.
        return releases.prefix(12).map { release in
            base.album = release.title
            base.albumArtist = MBArtistCredit.display(release.artistCredit)
            base.year = validYear(release.date)
            let description = [release.date, release.country, release.disambiguation, release.status]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return MetadataCandidate(id: "\(recording.id):\(release.id)", recordingID: recording.id,
                releaseID: release.id, tags: base, duration: duration, score: fingerprintScore,
                detail: description.isEmpty ? "MusicBrainz" : description)
        }
    }

    static func resolve(_ candidate: MetadataCandidate, with release: MBRelease) -> MetadataCandidate {
        var result = candidate
        result.tags.album = release.title
        result.tags.albumArtist = MBArtistCredit.display(release.artistCredit)
        result.tags.year = validYear(release.date)
        var matched: [(MBMedium, MBTrack)] = []
        for medium in release.media ?? [] {
            for track in medium.tracks ?? [] where track.recording?.id == candidate.recordingID {
                matched.append((medium, track))
            }
        }
        // The same recording can appear twice in a box set; never guess its position.
        if matched.count == 1, let (medium, track) = matched.first {
            result.tags.trackNumber = track.position.map(String.init) ?? ""
            result.tags.discNumber = medium.position.map(String.init) ?? ""
            if let title = track.title, !title.isEmpty { result.tags.title = title }
            let artist = MBArtistCredit.display(track.artistCredit)
            if !artist.isEmpty { result.tags.artist = artist }
            if let length = track.length { result.duration = Double(length) / 1_000 }
        } else {
            result.tags.trackNumber = ""
            result.tags.discNumber = ""
            if matched.count > 1 {
                result.detail += L10n.text(" · multiple track positions; choose manually", " · 存在多个曲目位置，请手动确认")
            }
        }
        return result
    }

    static func validYear(_ date: String?) -> String {
        guard let date, date.count >= 4 else { return "" }
        let year = String(date.prefix(4))
        return year.allSatisfy(\.isNumber) ? year : ""
    }

    private static func uniqueCandidates(_ candidates: [MetadataCandidate]) -> [MetadataCandidate] {
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.id).inserted }
    }

    struct RecordingMatch {
        var id: String
        var score: Double
        var title: String?
        var artist: String?
        var duration: Double?
    }

    static func recordingMatches(from response: AcoustIDResponse) -> [RecordingMatch] {
        var best: [String: RecordingMatch] = [:]
        for result in response.results ?? [] {
            guard result.score.isFinite, (0...1).contains(result.score) else { continue }
            for recording in result.recordings ?? [] {
                guard UUID(uuidString: recording.id) != nil else { continue }
                if let previous = best[recording.id], previous.score >= result.score { continue }
                let artist = recording.artists?.compactMap(\.name).joined(separator: ", ")
                best[recording.id] = RecordingMatch(id: recording.id, score: result.score,
                    title: recording.title, artist: artist, duration: recording.duration)
            }
        }
        return best.values.sorted { $0.score > $1.score }
    }
}

// Internal Codable models are also used by fixture-driven tests.
struct AcoustIDResponse: Decodable {
    var status: String
    var results: [AcoustIDResult]?
    var error: AcoustIDError?
}
struct AcoustIDError: Decodable { var code: Int?; var message: String? }
struct AcoustIDResult: Decodable {
    var score: Double
    var recordings: [AcoustIDRecording]?
}
struct AcoustIDRecording: Decodable {
    var id: String
    var title: String?
    var artists: [AcoustIDArtist]?
    var duration: Double?
}
struct AcoustIDArtist: Decodable { var name: String? }
struct MBSearchResponse: Decodable { var recordings: [MBRecording] }
struct MBRecording: Decodable {
    var id: String
    var title: String
    var length: Int?
    var artistCredit: [MBArtistCredit]?
    var releases: [MBRelease]?
    enum CodingKeys: String, CodingKey {
        case id, title, length, releases
        case artistCredit = "artist-credit"
    }
}
struct MBRelease: Decodable {
    var id: String
    var title: String
    var date: String?
    var country: String?
    var disambiguation: String?
    var status: String?
    var artistCredit: [MBArtistCredit]?
    var media: [MBMedium]?
    enum CodingKeys: String, CodingKey {
        case id, title, date, country, disambiguation, status, media
        case artistCredit = "artist-credit"
    }
}
struct MBArtistCredit: Decodable {
    var name: String?
    var joinphrase: String?
    var artist: MBArtist?
    static func display(_ credits: [MBArtistCredit]?) -> String {
        (credits ?? []).map { ($0.name ?? $0.artist?.name ?? "") + ($0.joinphrase ?? "") }.joined()
    }
}
struct MBArtist: Decodable { var name: String? }
struct MBMedium: Decodable { var position: Int?; var tracks: [MBTrack]? }
struct MBTrack: Decodable {
    var position: Int?
    var title: String?
    var length: Int?
    var recording: MBTrackRecording?
    var artistCredit: [MBArtistCredit]?
    enum CodingKeys: String, CodingKey {
        case position, title, length, recording
        case artistCredit = "artist-credit"
    }
}
struct MBTrackRecording: Decodable { var id: String }
