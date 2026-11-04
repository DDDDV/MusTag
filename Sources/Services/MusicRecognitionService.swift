import Foundation

enum AutomaticMatchDecision: Sendable {
    case selected(MetadataCandidate)
    case belowThreshold
    case ambiguous
    case noMatch
}

/// ShazamKit or AcoustID recognition, with separate MusicBrainz edition searches.
/// Both recognition providers receive signatures, not the original audio.
/// A recording score applies to every release edition of that recording.
actor MusicRecognitionService {
    typealias FingerprintProvider = @Sendable (URL) async throws -> (fingerprint: String, duration: Double)
    typealias ShazamProvider = @Sendable (URL) async throws -> [ShazamRecognitionResult]
    static let automaticMatchThreshold = 0.9

    private let session: URLSession
    private let fingerprintProvider: FingerprintProvider
    private let shazamProvider: ShazamProvider
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
         },
         shazamProvider: @escaping ShazamProvider = { url in
             try await ShazamRecognitionService.recognize(url: url)
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
        self.shazamProvider = shazamProvider
    }

    func identify(url: URL, apiKey: String, provider: RecognitionProvider = .acoustID) async throws -> [MetadataCandidate] {
        if provider == .shazamKit {
            try Task.checkCancellation()
            let staged = try Self.stageForReading(url)
            defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
            let matches = try await shazamProvider(staged)
            try Task.checkCancellation()
            return Self.uniqueCandidates(matches.compactMap(Self.shazamCandidate))
        }
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
            throw Self.acoustIDError(response.error)
        }
        let matches = Self.recordingMatches(from: response)
        // Preserve ties at the lookup boundary: cutting a tie can make an album
        // appear to be the only match when another equally scored edition exists.
        let minimumLookupScore = matches.prefix(5).last?.score ?? 0
        var candidates: [MetadataCandidate] = []
        for match in matches.prefix(while: { $0.score >= minimumLookupScore }) {
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
                                      "AcoustID · 暂时无法获取专辑信息，可稍后重试"),
                    hasIncompleteReleaseInfo: true, source: .acoustID))
            }
        }
        return Self.rankedCandidates(candidates)
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

    /// Look up the selected edition, and fill track/disc only if unambiguous.
    func resolve(_ candidate: MetadataCandidate) async throws -> MetadataCandidate {
        guard candidate.source != .shazamKit else { return candidate }
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

    private enum Provider {
        case musicBrainz, acoustID

        var name: String { self == .acoustID ? "AcoustID" : "MusicBrainz" }
    }

    private static func acoustIDError(_ error: AcoustIDError?, httpStatus: Int? = nil) -> MusTagError {
        // Interpret documented codes, never echo the response message: it may contain request data.
        // AcoustID code 5 is an internal error; only 4/17 identify an invalid application key.
        let message: String
        switch error?.code {
        case 4, 17:
            message = L10n.text(
                "AcoustID rejected the Application API Key. In Settings, get a key by registering an application. The personal User API Key cannot be used for recognition.",
                "AcoustID 拒绝了应用 Key。请在设置中通过“获取 AcoustID 应用 Key”注册应用，填写 Application API Key；个人页面的 User API Key 不能用于识别。")
        case 2:
            message = L10n.text("The AcoustID request is missing a required parameter.",
                                "AcoustID 请求缺少必填参数。")
        case 3:
            message = L10n.text("AcoustID rejected the audio fingerprint. Try another audio file or search by title.",
                                "AcoustID 无法接受此音频指纹，请尝试其他音频文件或按歌名搜索。")
        case 8:
            message = L10n.text("AcoustID rejected the audio duration. Check that the file plays correctly or search by title.",
                                "AcoustID 无法接受此音频时长，请检查文件能否正常播放，或按歌名搜索。")
        case 5:
            message = L10n.text("AcoustID encountered an internal server error. Try again later.",
                                "AcoustID 服务发生内部错误，请稍后重试。")
        case 13:
            message = L10n.text("AcoustID is temporarily unavailable. Try again later.",
                                "AcoustID 服务暂不可用，请稍后重试。")
        case 14:
            message = L10n.text("AcoustID received too many requests. Try again later.",
                                "AcoustID 请求过于频繁，请稍后重试。")
        default:
            message = L10n.text("AcoustID could not complete this lookup. Check the request parameters and try again.",
                                "AcoustID 无法完成查询，请检查请求参数后重试。")
        }
        let details = [httpStatus.map { "HTTP \($0)" }, error?.code.map { "AcoustID \($0)" }]
            .compactMap { $0 }.joined(separator: "; ")
        return .message(details.isEmpty ? message : "\(message) (\(details))")
    }

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
            guard data.count <= 4 * 1024 * 1024 else {
                throw MusTagError.message(L10n.text("The metadata response was too large.", "元数据响应过大。"))
            }
            guard (200..<300).contains(http.statusCode) else {
                // AcoustID sends validation failures as HTTP 400 with a structured JSON body.
                // Parse it before the generic HTTP fallback so the actionable reason survives.
                if provider == .acoustID,
                   let failure = try? JSONDecoder().decode(AcoustIDResponse.self, from: data),
                   failure.status == "error" {
                    throw Self.acoustIDError(failure.error, httpStatus: http.statusCode)
                }
                if http.statusCode == 400 {
                    throw MusTagError.message(L10n.text(
                        "\(provider.name) rejected the request (HTTP 400). Check the request parameters and try again.",
                        "\(provider.name) 拒绝了请求（HTTP 400），请检查请求参数后重试。"))
                }
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw MusTagError.message(L10n.text("\(provider.name) denied access (HTTP \(http.statusCode)). Check the API key and service permissions.",
                                                       "\(provider.name) 拒绝访问（HTTP \(http.statusCode)），请检查 API Key 和服务权限。"))
                }
                throw MusTagError.message(L10n.text("\(provider.name) is unavailable (HTTP \(http.statusCode)). Try again later.",
                                                   "\(provider.name) 服务暂不可用（HTTP \(http.statusCode)），请稍后重试。"))
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
                detail: L10n.text("MusicBrainz · recording only", "MusicBrainz · 仅录音信息"),
                source: fingerprintScore == nil ? .musicBrainz : .acoustID)]
        }
        // Every returned edition is needed to detect ties and match an existing album.
        // Editions share the recording's score; they have no independent fingerprint score.
        return releases.map { release in
            base.album = release.title
            base.albumArtist = MBArtistCredit.display(release.artistCredit)
            base.year = validYear(release.date)
            let description = [release.date, release.country, release.disambiguation, release.status]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return MetadataCandidate(id: "\(recording.id):\(release.id)", recordingID: recording.id,
                releaseID: release.id, tags: base, duration: duration, score: fingerprintScore,
                detail: description.isEmpty ? "MusicBrainz" : description,
                source: fingerprintScore == nil ? .musicBrainz : .acoustID)
        }
    }

    private static func shazamCandidate(_ match: ShazamRecognitionResult) -> MetadataCandidate? {
        let title = match.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !match.id.isEmpty else { return nil }
        // The base Shazam match does not identify a physical release, track/disc,
        // release date, or album artist. Leave those fields empty to preserve the draft.
        return MetadataCandidate(id: "shazam:\(match.id)", recordingID: nil,
            tags: AudioTags(title: title, artist: match.artist,
                            genre: match.genres.joined(separator: "; ")),
            score: nil,
            detail: L10n.text("Shazam · song match; album edition not determined",
                              "Shazam · 歌曲匹配，尚未确定专辑版本"),
            source: .shazamKit, artworkURL: match.artworkURL,
            appleMusicURL: validatedAppleMusicURL(match.appleMusicURL), isrc: match.isrc)
    }

    private static func validatedAppleMusicURL(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", url.host?.lowercased() == "music.apple.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        return url
    }

    static func resolve(_ candidate: MetadataCandidate, with release: MBRelease) -> MetadataCandidate {
        guard candidate.source != .shazamKit, candidate.recordingID != nil else { return candidate }
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

    static func rankedCandidates(_ candidates: [MetadataCandidate]) -> [MetadataCandidate] {
        var best: [String: MetadataCandidate] = [:]
        for candidate in candidates {
            if let previous = best[candidate.id],
               (validFingerprintScore(previous.score) ?? -1) >= (validFingerprintScore(candidate.score) ?? -1) {
                continue
            }
            best[candidate.id] = candidate
        }
        return best.values.sorted {
            let leftScore = validFingerprintScore($0.score) ?? -1
            let rightScore = validFingerprintScore($1.score) ?? -1
            return leftScore == rightScore ? $0.id < $1.id : leftScore > rightScore
        }
    }

    static func automaticMatch(from candidates: [MetadataCandidate], originalAlbum: String) -> AutomaticMatchDecision {
        // Shazam's recognition result is not an AcoustID similarity percentage.
        // Apply only one distinct match; multiple songs always require a choice.
        if candidates.contains(where: { $0.source == .shazamKit }) {
            let matches = uniqueCandidates(candidates)
            guard matches.count == 1, let match = matches.first, !match.tags.title.isEmpty else { return .ambiguous }
            return .selected(match)
        }
        let ranked = rankedCandidates(candidates)
        guard let first = ranked.first, let highestScore = validFingerprintScore(first.score) else {
            return .noMatch
        }
        guard highestScore >= automaticMatchThreshold else { return .belowThreshold }
        let highestMatches = ranked.prefix { validFingerprintScore($0.score) == highestScore }
        if highestMatches.count == 1 { return .selected(first) }
        // An unavailable edition list might contain the same album; partial results
        // cannot establish a unique album preference among tied recordings.
        guard !highestMatches.contains(where: \.hasIncompleteReleaseInfo) else { return .ambiguous }

        let album = normalizedAlbum(originalAlbum)
        guard !album.isEmpty else { return .ambiguous }
        let albumMatches = highestMatches.filter { normalizedAlbum($0.tags.album) == album }
        guard albumMatches.count == 1, let match = albumMatches.first else { return .ambiguous }
        return .selected(match)
    }

    private static func validFingerprintScore(_ score: Double?) -> Double? {
        guard let score, score.isFinite, (0...1).contains(score) else { return nil }
        return score
    }

    private static func normalizedAlbum(_ album: String) -> String {
        album.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
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
        return best.values.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
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
