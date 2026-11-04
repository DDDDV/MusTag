import Foundation
import MusicKit

/// A snapshot of the exact Apple Music catalog item associated with a Shazam match.
/// Its release fields describe that catalog edition, not an inferred original release.
struct AppleMusicSongMetadata: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var artist: String
    var albumTitle: String? = nil
    var albumArtist: String? = nil
    var releaseDate: Date? = nil
    var trackNumber: Int? = nil
    var discNumber: Int? = nil
    var isrc: String? = nil
    var duration: TimeInterval? = nil
    var url: URL? = nil
    var artworkURL: URL? = nil
    var genres: [String] = []
}

enum AppleMusicMetadataService {
    typealias AuthorizationStatus = @Sendable () -> MusicAuthorization.Status
    typealias AuthorizationRequest = @Sendable () async -> MusicAuthorization.Status
    typealias SongLoader = @Sendable (String) async throws -> Song?
    typealias AlbumLoader = @Sendable (Song) async throws -> MusicItemCollection<Album>?

    /// Injected operations let tests cover permission, cancellation, and relationship failures offline.
    static func song(
        id: String,
        authorizationStatus: AuthorizationStatus = { MusicAuthorization.currentStatus },
        requestAuthorization: AuthorizationRequest = { await MusicAuthorization.request() },
        loadSong: SongLoader = { id in
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
            let response = try await request.response()
            return response.items.first { $0.id.rawValue == id }
        },
        loadAlbums: AlbumLoader = { song in
            if let albums = song.albums { return albums }
            return try await song.with([.albums], preferredSource: .catalog).albums
        }
    ) async throws -> AppleMusicSongMetadata? {
        try Task.checkCancellation()
        guard let id = normalizedID(id) else {
            throw MusTagError.message(L10n.text("The Apple Music song identifier is invalid.",
                                               "Apple Music 歌曲标识无效。"))
        }
        var status = authorizationStatus()
        if status == .notDetermined {
            status = await requestAuthorization()
        }
        try Task.checkCancellation()
        guard status == .authorized else {
            throw MusTagError.message(L10n.text(
                "Allow Music access in Settings to complete album, year, track and disc information. Shazam recognition remains available.",
                "请在系统设置中允许访问音乐，以补全专辑、年份、曲序和碟号。Shazam 识别仍然可用。"))
        }

        do {
            guard let song = try await loadSong(id) else {
                try Task.checkCancellation()
                return nil
            }
            try Task.checkCancellation()
            // Do not silently accept an equivalent song from another storefront or release.
            guard song.id.rawValue == id else { return nil }
            var result = metadata(from: song)
            do {
                if let albums = try await loadAlbums(song), albums.count == 1, !albums.hasNextBatch,
                   let album = albums.first {
                    result.albumArtist = nonempty(album.artistName)
                }
            } catch {
                try propagateCancellation(error)
                // Album artists are optional. A failed relationship request must keep song fields.
            }
            try Task.checkCancellation()
            return result
        } catch {
            try propagateCancellation(error)
            throw error
        }
    }

    static func normalizedID(_ text: String?) -> String? {
        guard let id = nonempty(text), id.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt64(id), number > 0 else { return nil }
        return id
    }

    static func metadata(from song: Song) -> AppleMusicSongMetadata {
        AppleMusicSongMetadata(
            id: song.id.rawValue,
            title: nonempty(song.title) ?? "",
            artist: nonempty(song.artistName) ?? "",
            albumTitle: nonempty(song.albumTitle),
            releaseDate: song.releaseDate.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil },
            trackNumber: song.trackNumber.flatMap { $0 > 0 ? $0 : nil },
            discNumber: song.discNumber.flatMap { $0 > 0 ? $0 : nil },
            isrc: nonempty(song.isrc),
            duration: song.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            url: secureURL(song.url),
            artworkURL: secureURL(song.artwork?.url(width: 1_200, height: 1_200)),
            genres: song.genreNames.compactMap(nonempty)
        )
    }

    /// Only fixed explanations and numeric codes leave the service boundary. Provider
    /// descriptions, response bodies, URLs, and error domains can contain private details.
    static func diagnosticMessage(for error: Error) -> String {
        if let error = error as? MusTagError { return error.localizedDescription }
        if let error = error as? MusicTokenRequestError {
            switch error {
            case .developerTokenRequestFailed:
                return developerAuthenticationMessage + " (MusicKit developerTokenRequestFailed)"
            case .permissionDenied, .userTokenRevoked:
                return L10n.text(
                    "Apple Music access was denied or revoked. Allow Music access for MusTag in Settings and retry.",
                    "Apple Music 访问权限被拒绝或撤销。请在系统设置中允许 MusTag 访问音乐后重试。")
            case .userNotSignedIn:
                return L10n.text("Sign in to your Apple Music account in the Music app, then retry.",
                                 "请先在“音乐”App 中登录 Apple Music 账户，再重试。")
            case .privacyAcknowledgementRequired:
                return L10n.text("Open the Music app and review its latest privacy notice, then retry.",
                                 "请打开“音乐”App 并确认最新的隐私提示，再重试。")
            case .userTokenRequestFailed:
                return L10n.text(
                    "Apple Music could not authenticate your account. Check your Music sign-in, app permission and connection, then retry.",
                    "Apple Music 无法完成账户认证。请检查“音乐”App 的登录状态、应用权限及网络后重试。")
                    + " (MusicKit userTokenRequestFailed)"
            case .unknown:
                return L10n.text("Apple Music authentication failed. Check your account and connection, then retry.",
                                 "Apple Music 认证失败。请检查账户和网络后重试。") + " (MusicKit unknown)"
            @unknown default:
                return L10n.text("Apple Music authentication failed. Please retry later.",
                                 "Apple Music 认证失败，请稍后重试。")
            }
        }
        if let error = error as? MusicDataRequest.Error {
            return diagnosticMessage(httpStatus: error.status, code: error.code)
        }
        if let error = error as? URLError {
            let message: String
            switch error.code {
            case .timedOut:
                message = L10n.text("The Apple Music lookup timed out. Check your connection and retry.",
                                    "Apple Music 查询超时。请检查网络后重试。")
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
                message = L10n.text("Apple Music cannot access the network. Check Wi-Fi and cellular access, then retry.",
                                    "Apple Music 无法使用网络。请检查 Wi-Fi 和蜂窝数据权限后重试。")
            case .cannotFindHost, .dnsLookupFailed:
                message = L10n.text("The Apple Music server address could not be resolved. Try another network.",
                                    "无法解析 Apple Music 服务器地址，请尝试其他网络。")
            case .cannotConnectToHost, .networkConnectionLost:
                message = L10n.text("The connection to Apple Music failed or was interrupted. Check your connection and retry.",
                                    "连接 Apple Music 失败或中断。请检查网络后重试。")
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired,
                 .appTransportSecurityRequiresSecureConnection:
                message = L10n.text("A secure connection to Apple Music could not be established. Check the device date and network.",
                                    "无法与 Apple Music 建立安全连接，请检查设备日期和网络。")
            default:
                message = L10n.text("The Apple Music network request failed. Check your connection and retry.",
                                    "Apple Music 网络请求失败，请检查网络后重试。")
            }
            return "\(message) (NSURLErrorDomain \(error.code.rawValue))"
        }
        return L10n.text("Apple Music lookup failed. Please retry later.", "Apple Music 查询失败，请稍后重试。")
            + " (\(L10n.text("code", "错误码")) \((error as NSError).code))"
    }

    /// Separate numeric classification keeps HTTP error handling testable without service requests.
    static func diagnosticMessage(httpStatus: Int, code: Int) -> String {
        let message: String
        switch httpStatus {
        case 401:
            message = developerAuthenticationMessage
        case 403:
            message = L10n.text(
                "Apple Music rejected the account or request authorization. Check Music sign-in and MusTag's music access, then retry.",
                "Apple Music 拒绝了账户或请求认证。请检查“音乐”App 登录状态及 MusTag 的音乐访问权限后重试。")
        case 404:
            message = L10n.text("This song was not found in the current Apple Music catalog.",
                                "当前 Apple Music 曲库中未找到这首歌曲。")
        case 429:
            message = L10n.text("Apple Music received too many requests. Wait a moment and retry.",
                                "Apple Music 请求过于频繁，请稍后重试。")
        case 500...599:
            message = L10n.text("Apple Music is temporarily unavailable. Please retry later.",
                                "Apple Music 服务暂不可用，请稍后重试。")
        default:
            message = L10n.text("Apple Music could not complete this request. Please retry later.",
                                "Apple Music 无法完成此请求，请稍后重试。")
        }
        return "\(message) (HTTP \(httpStatus); Apple Music \(code))"
    }

    private static var developerAuthenticationMessage: String {
        L10n.text(
            "Apple Music developer authentication failed. For development builds, enable MusicKit for this App ID in Apple Developer, and check the bundle identifier, signing and connection.",
            "Apple Music 开发者认证失败。开发版本请在 Apple Developer 中为此 App ID 启用 MusicKit，并检查 Bundle ID、签名及网络。")
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func secureURL(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func propagateCancellation(_ error: Error) throws {
        try Task.checkCancellation()
        if error is CancellationError { throw CancellationError() }
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            throw CancellationError()
        }
    }
}
