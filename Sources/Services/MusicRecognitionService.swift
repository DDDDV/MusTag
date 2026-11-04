import Foundation

enum AutomaticMatchDecision: Sendable {
    case selected(MetadataCandidate)
    case belowThreshold
    case ambiguous
    case noMatch
}

/// Audio recognition with optional, exact Apple Music catalog supplementation.
/// Neither recognition provider receives the original audio file.
actor MusicRecognitionService {
    typealias FingerprintProvider = @Sendable (URL) async throws -> (fingerprint: String, duration: Double)
    typealias ShazamProvider = @Sendable (URL) async throws -> [ShazamRecognitionResult]
    typealias AppleMusicProvider = @Sendable (String) async throws -> AppleMusicSongMetadata?
    static let automaticMatchThreshold = 0.9

    private let session: URLSession
    private let fingerprintProvider: FingerprintProvider
    private let shazamProvider: ShazamProvider
    private let appleMusicProvider: AppleMusicProvider
    private let minimumAcoustIDInterval: TimeInterval
    private var nextAcoustIDRequest = Date.distantPast

    init(session: URLSession? = nil,
         minimumAcoustIDInterval: TimeInterval = 0.35,
         fingerprintProvider: @escaping FingerprintProvider = { try await NativeAudio.fingerprint(url: $0) },
         shazamProvider: @escaping ShazamProvider = { try await ShazamRecognitionService.recognize(url: $0) },
         appleMusicProvider: @escaping AppleMusicProvider = { try await AppleMusicMetadataService.song(id: $0) }) {
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
        self.minimumAcoustIDInterval = minimumAcoustIDInterval
        self.fingerprintProvider = fingerprintProvider
        self.shazamProvider = shazamProvider
        self.appleMusicProvider = appleMusicProvider
    }

    func identify(url: URL, apiKey: String, provider: RecognitionProvider = .acoustID) async throws -> [MetadataCandidate] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .acoustID, key.isEmpty {
            throw MusTagError.message(L10n.text("Add your AcoustID application API key in Settings to identify audio.",
                                               "请先在设置中填写 AcoustID 应用 API Key，再识别音频。"))
        }
        try Task.checkCancellation()
        let staged = try Self.stageForReading(url)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        if provider == .shazamKit {
            let matches = try await shazamProvider(staged)
            try Task.checkCancellation()
            var candidates: [MetadataCandidate] = []
            for base in Self.uniqueCandidates(matches.compactMap(Self.shazamCandidate)) {
                try Task.checkCancellation()
                candidates += try await supplementShazam(base)
            }
            return candidates
        }
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
            .init(name: "client", value: key), .init(name: "format", value: "json"),
            .init(name: "duration", value: String(Int(signature.duration.rounded()))),
            .init(name: "fingerprint", value: signature.fingerprint), .init(name: "meta", value: "recordings")
        ]
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let data = try await fetch(request)
        let response: AcoustIDResponse = try decode(data)
        try Task.checkCancellation()
        guard response.status == "ok" else { throw Self.acoustIDError(response.error) }
        return Self.recordingMatches(from: response).compactMap { match in
            let title = match.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            return MetadataCandidate(id: match.id, tags: AudioTags(title: title, artist: match.artist ?? ""),
                duration: match.duration, score: match.score,
                detail: L10n.text("AcoustID · basic song information", "AcoustID · 歌曲基础信息"), source: .acoustID)
        }
    }

    /// Supplement one catalog edition only. Missing data must never trigger a title search
    /// or mix positions from another album into the matched Apple Music edition.
    private func supplementShazam(_ base: MetadataCandidate) async throws -> [MetadataCandidate] {
        var fallback = base
        guard let id = AppleMusicMetadataService.normalizedID(base.shazamMetadata?.appleMusicID ?? "") else {
            fallback.supplementationNotice = Self.supplementationUnavailable(L10n.text(
                "Shazam did not return a valid Apple Music song ID, so catalog details could not be requested.",
                "Shazam 未返回有效的 Apple Music 歌曲标识，因此未查询曲库详情。"))
            return [fallback]
        }
        do {
            guard let song = try await appleMusicProvider(id) else {
                try Task.checkCancellation()
                fallback.supplementationNotice = Self.supplementationUnavailable(L10n.text(
                    "No exact match for this song ID was found in the current Apple Music catalog.",
                    "当前 Apple Music 曲库中未找到与此歌曲标识完全一致的结果。"))
                return [fallback]
            }
            try Task.checkCancellation()
            guard song.id == id else {
                fallback.supplementationNotice = Self.supplementationUnavailable(L10n.text(
                    "Apple Music returned a different song ID. Its metadata was not applied.",
                    "Apple Music 返回的歌曲标识与请求不一致，未采用该元数据。"))
                return [fallback]
            }
            if let expected = Self.normalizedISRC(base.isrc),
               let actual = Self.normalizedISRC(song.isrc), expected != actual {
                fallback.supplementationNotice = Self.supplementationUnavailable(L10n.text(
                    "The Shazam and Apple Music recording identifiers (ISRC) conflict. Album details were not applied.",
                    "Shazam 与 Apple Music 的录音标识（ISRC）不一致，未采用该专辑详情。"))
                return [fallback]
            }
            let tags = Self.appleMusicTags(song)
            // An album title anchors the release-specific fields. Without it, the user
            // cannot review which edition the date and positions belong to.
            guard !tags.album.isEmpty else {
                fallback.supplementationNotice = Self.supplementationUnavailable(L10n.text(
                    "Apple Music returned no album name. Release details were not applied because the edition could not be identified.",
                    "Apple Music 未返回专辑名称，无法确定发行版本，因此未采用发行详情。"))
                return [fallback]
            }
            var candidate = base
            candidate.tags = Self.fillingMissing(base.tags, with: tags)
            candidate.appleMusicMetadata = song
            candidate.duration = song.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            candidate.appleMusicURL = Self.validatedAppleMusicURL(song.url) ?? base.appleMusicURL
            candidate.artworkURL = song.artworkURL.flatMap {
                CoverArtRedirectDelegate.allows($0, provider: .shazam) ? $0 : nil
            } ?? base.artworkURL
            candidate.detail = L10n.text("Shazam + Apple Music · catalog edition", "Shazam + Apple Music · 数字发行版本")
            let complete = !tags.year.isEmpty && !tags.trackNumber.isEmpty && !tags.discNumber.isEmpty
            candidate.hasIncompleteReleaseInfo = !complete
            if !complete {
                candidate.supplementationNotice = L10n.text(
                    "Some Apple Music fields are missing. Available details were added; missing fields retain their existing values.",
                    "Apple Music 部分字段缺失。已补充可用详情，缺失字段保留原值。")
            }
            return [candidate]
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            fallback.hasIncompleteReleaseInfo = true
            fallback.supplementationNotice = Self.supplementationUnavailable(
                AppleMusicMetadataService.diagnosticMessage(for: error))
            return [fallback]
        }
    }

    private static func supplementationUnavailable(_ reason: String) -> String {
        reason + "\n" + L10n.text("Shazam tags were kept; missing fields retain their existing values.",
                                  "已保留 Shazam 标签，缺失字段保留原值。")
    }

    static func appleMusicTags(_ song: AppleMusicSongMetadata) -> AudioTags {
        func clean(_ value: String?) -> String { value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func position(_ value: Int?) -> String { value.flatMap { $0 > 0 ? String($0) : nil } ?? "" }
        var year = ""
        if let date = song.releaseDate, date.timeIntervalSinceReferenceDate.isFinite {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let value = calendar.component(.year, from: date)
            if (1...9999).contains(value) { year = String(format: "%04d", value) }
        }
        return AudioTags(title: clean(song.title), artist: clean(song.artist), album: clean(song.albumTitle),
            albumArtist: clean(song.albumArtist), year: year, trackNumber: position(song.trackNumber),
            discNumber: position(song.discNumber), genre: GenreLocalization.localized(song.genres))
    }

    static func normalizedISRC(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "").uppercased()
        return normalized.range(of: "^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$", options: .regularExpression) != nil ? normalized : nil
    }

    private static func shazamCandidate(_ match: ShazamRecognitionResult) -> MetadataCandidate? {
        let title = match.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !match.id.isEmpty else { return nil }
        // A catalog song is one choice even when Shazam returns multiple identifiers
        // for it. Keep this identity unchanged if catalog supplementation is unavailable.
        let id = AppleMusicMetadataService.normalizedID(match.appleMusicID)
            .map { "shazam:appleMusic:\($0)" } ?? "shazam:\(match.id)"
        return MetadataCandidate(id: id,
            tags: AudioTags(title: title, artist: match.artist, genre: GenreLocalization.localized(match.genres)),
            detail: L10n.text("Shazam · basic song information", "Shazam · 歌曲基础信息"), source: .shazamKit,
            artworkURL: match.artworkURL, appleMusicURL: validatedAppleMusicURL(match.appleMusicURL),
            isrc: match.isrc, shazamMetadata: match)
    }

    private static func validatedAppleMusicURL(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", url.host?.lowercased() == "music.apple.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        return url
    }

    private static func fillingMissing(_ primary: AudioTags, with supplement: AudioTags) -> AudioTags {
        var result = primary
        for field in TagField.allCases where field.value(in: primary).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            field.set(field.value(in: supplement), in: &result)
        }
        return result
    }

    static func automaticMatch(from candidates: [MetadataCandidate]) -> AutomaticMatchDecision {
        let matches = uniqueCandidates(candidates)
        guard !matches.isEmpty else { return .noMatch }
        if matches.contains(where: { $0.source == .shazamKit }) {
            guard matches.allSatisfy({ $0.source == .shazamKit }) else { return .ambiguous }
            if matches.count == 1, let match = matches.first, !match.tags.title.isEmpty { return .selected(match) }
            return .ambiguous
        }
        let ranked = rankedCandidates(candidates)
        guard let first = ranked.first, let highestScore = validFingerprintScore(first.score) else { return .noMatch }
        guard highestScore >= automaticMatchThreshold else { return .belowThreshold }
        return ranked.filter { validFingerprintScore($0.score) == highestScore }.count == 1 ? .selected(first) : .ambiguous
    }

    static func rankedCandidates(_ candidates: [MetadataCandidate]) -> [MetadataCandidate] {
        var best: [String: MetadataCandidate] = [:]
        for candidate in candidates {
            if let previous = best[candidate.id],
               (validFingerprintScore(previous.score) ?? -1) >= (validFingerprintScore(candidate.score) ?? -1) { continue }
            best[candidate.id] = candidate
        }
        return best.values.sorted {
            let left = validFingerprintScore($0.score) ?? -1
            let right = validFingerprintScore($1.score) ?? -1
            return left == right ? $0.id < $1.id : left > right
        }
    }

    private static func validFingerprintScore(_ score: Double?) -> Double? {
        guard let score, score.isFinite, (0...1).contains(score) else { return nil }
        return score
    }

    private static func uniqueCandidates(_ candidates: [MetadataCandidate]) -> [MetadataCandidate] {
        var seen: Set<String> = []
        return candidates.filter { candidate in
            let id: String
            if candidate.source == .shazamKit,
               let catalogID = AppleMusicMetadataService.normalizedID(candidate.shazamMetadata?.appleMusicID) {
                id = "shazam:appleMusic:\(catalogID)"
            } else {
                id = candidate.id
            }
            return seen.insert(id).inserted
        }
    }

    private func waitForSlot() async throws {
        while true {
            try Task.checkCancellation()
            let now = Date()
            let delay = nextAcoustIDRequest.timeIntervalSince(now)
            if delay <= 0 {
                nextAcoustIDRequest = now.addingTimeInterval(minimumAcoustIDInterval)
                return
            }
            try await Task.sleep(for: .seconds(delay))
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            throw MusTagError.message(L10n.text("The metadata response could not be read. Try again later.",
                                               "无法读取元数据响应，请稍后重试。"))
        }
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
            message = L10n.text("AcoustID rejected the audio fingerprint. Try another audio file or use ShazamKit.",
                                "AcoustID 无法接受此音频指纹，请尝试其他音频文件或使用 ShazamKit。")
        case 8:
            message = L10n.text("AcoustID rejected the audio duration. Check that the file plays correctly or use ShazamKit.",
                                "AcoustID 无法接受此音频时长，请检查文件能否正常播放，或使用 ShazamKit。")
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

    private func fetch(_ baseRequest: URLRequest) async throws -> Data {
        var request = baseRequest
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MusTag/0.1.0", forHTTPHeaderField: "User-Agent")
        for attempt in 0...1 {
            try await waitForSlot()
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
                if let failure = try? JSONDecoder().decode(AcoustIDResponse.self, from: data),
                   failure.status == "error" {
                    throw Self.acoustIDError(failure.error, httpStatus: http.statusCode)
                }
                if http.statusCode == 400 {
                    throw MusTagError.message(L10n.text(
                        "AcoustID rejected the request (HTTP 400). Check the request parameters and try again.",
                        "AcoustID 拒绝了请求（HTTP 400），请检查请求参数后重试。"))
                }
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw MusTagError.message(L10n.text("AcoustID denied access (HTTP \(http.statusCode)). Check the API key and service permissions.",
                                                       "AcoustID 拒绝访问（HTTP \(http.statusCode)），请检查 API Key 和服务权限。"))
                }
                throw MusTagError.message(L10n.text("AcoustID is unavailable (HTTP \(http.statusCode)). Try again later.",
                                                   "AcoustID 服务暂不可用（HTTP \(http.statusCode)），请稍后重试。"))
            }
            return data
        }
        throw MusTagError.message(L10n.text("The service is busy. Try again later.", "服务繁忙，请稍后重试。"))
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

// AcoustID lookup response; recording IDs are opaque identities, never used for another service.
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
