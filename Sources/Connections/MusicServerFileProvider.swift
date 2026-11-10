import CryptoKit
import Foundation

/// Read-only adapters. All editing happens after the caller imports a local copy.
actor MusicServerFileProvider: RemoteFileProvider {
    private let connection: RemoteConnection
    private let password: String
    private let baseURL: URL
    private let http: MusicServerHTTP
    private var feiniuToken: String?
    private var feiniuAlbums: [RemoteFile]?
    private var feiniuAlbumFiles: [String: [RemoteFile]] = [:]
    private var disconnected = false

    init(connection: RemoteConnection, password: String,
         configuration: URLSessionConfiguration = .ephemeral) throws {
        guard connection.kind.isMusicServer else { throw MusicServerFailure.invalidAddress }
        self.connection = connection
        self.password = password
        baseURL = try Self.normalizedURL(connection)
        http = MusicServerHTTP(configuration: configuration)
    }

    func disconnect() async {
        disconnected = true
        feiniuToken = nil
        feiniuAlbums = nil
        feiniuAlbumFiles = [:]
        http.disconnect()
    }

    func listDirectory(path: String) async throws -> [RemoteFile] {
        try checkActive()
        if connection.kind == .feiniu {
            if path == "/" || path.isEmpty {
                try await loadFeiniuAlbums()
                return feiniuAlbums ?? []
            }
            if feiniuAlbums == nil { try await loadFeiniuAlbums() }
            guard let files = feiniuAlbumFiles[path] else { throw MusicServerFailure.invalidPath }
            return files
        }
        if path == "/" || path.isEmpty { return try await subsonicAlbums() }
        let id = try Self.identifier(from: path, prefix: "/subsonic/album/")
        let envelope = try await subsonicRequest("getAlbum.view", parameters: ["id": id])
        guard let album = envelope["album"] as? [String: Any] else { throw MusicServerFailure.invalidResponse }
        let songs = try Self.objects(album["song"])
        var result: [RemoteFile] = []
        for (index, song) in songs.enumerated() {
            try checkActive()
            result.append(try await subsonicFile(song, fallbackID: "\(path)/unavailable-\(index)"))
        }
        return result
    }

    func download(_ file: RemoteFile, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        try checkActive()
        guard file.isSupportedAudio else {
            throw MusTagError.message(file.unavailableReason ?? L10n.text("This file cannot be imported.", "无法导入此文件。"))
        }
        if connection.kind == .feiniu {
            let guid = try Self.identifier(from: file.id, prefix: "/feiniu/song/")
            let metadata = try await feiniuRequest("track/metadata", parameters: ["guid": guid])
            let track = metadata["track"] as? [String: Any] ?? metadata
            let current = Self.feiniuFile(track, guid: guid)
            try Self.validateCurrent(current, comparedTo: file)
            let token = try await authenticateFeiniu()
            var request = try feiniuURLRequest("track/stream", parameters: ["guid": guid], token: token)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            try await http.download(request, to: destination, expectedSize: current.size ?? file.size, progress: progress)
        } else {
            let id = try Self.identifier(from: file.id, prefix: "/subsonic/song/")
            let envelope = try await subsonicRequest("getSong.view", parameters: ["id": id])
            guard let song = envelope["song"] as? [String: Any] else { throw MusicServerFailure.invalidResponse }
            let current = Self.subsonicFileValue(song, id: id)
            try Self.validateCurrent(current, comparedTo: file)
            // download.view returns the original bytes; stream.view may transcode.
            var request = try subsonicURLRequest("download.view", parameters: ["id": id])
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            try await http.download(request, to: destination, expectedSize: current.size ?? file.size, progress: progress)
        }
    }

    private func subsonicAlbums() async throws -> [RemoteFile] {
        var offset = 0
        var seen = Set<String>()
        var seenPages = Set<Data>()
        var result: [RemoteFile] = []
        while true {
            try checkActive()
            let envelope = try await subsonicRequest("getAlbumList2.view", parameters: [
                "type": "alphabeticalByName", "size": "500", "offset": String(offset)
            ])
            guard let container = envelope["albumList2"] as? [String: Any] else { throw MusicServerFailure.invalidResponse }
            let page = try Self.objects(container["album"])
            if page.isEmpty { break }
            let pageData = try JSONSerialization.data(withJSONObject: page, options: .sortedKeys)
            guard seenPages.insert(Data(SHA256.hash(data: pageData))).inserted else { throw MusicServerFailure.repeatedPage }
            for (index, album) in page.enumerated() {
                let name = Self.text(album["name"]) ?? Self.text(album["title"]) ?? L10n.text("Untitled album", "未命名专辑")
                guard let id = Self.text(album["id"]) else {
                    result.append(RemoteFile(id: "/subsonic/unavailable-\(offset + index)", name: name, isDirectory: false,
                                             unavailableReason: MusicServerFailure.invalidResponse.localizedDescription))
                    continue
                }
                guard seen.insert(id).inserted else { throw MusicServerFailure.repeatedPage }
                result.append(RemoteFile(id: Self.path("/subsonic/album/", id), name: name, isDirectory: true))
            }
            // Continue to an empty page: some servers cap the requested page size.
            offset += page.count
        }
        return result
    }

    private func subsonicFile(_ song: [String: Any], fallbackID: String) async throws -> RemoteFile {
        guard let id = Self.text(song["id"]) else {
            return RemoteFile(id: fallbackID, name: Self.text(song["title"]) ?? L10n.text("Unavailable track", "不可用歌曲"),
                              isDirectory: false, unavailableReason: MusicServerFailure.invalidResponse.localizedDescription)
        }
        let initial = Self.subsonicFileValue(song, id: id)
        guard initial.unavailableReason != nil else { return initial }
        do {
            let envelope = try await subsonicRequest("getSong.view", parameters: ["id": id])
            guard let full = envelope["song"] as? [String: Any] else { throw MusicServerFailure.invalidResponse }
            return Self.subsonicFileValue(full, id: id)
        } catch is CancellationError { throw CancellationError() }
        catch {
            var unavailable = initial
            unavailable.unavailableReason = error.localizedDescription
            return unavailable
        }
    }

    private static func subsonicFileValue(_ song: [String: Any], id: String) -> RemoteFile {
        let filename = originalFilename(song["path"] ?? song["fileName"] ?? song["filename"])
        return RemoteFile(id: path("/subsonic/song/", id),
                          name: filename ?? text(song["title"]) ?? L10n.text("Unavailable track", "不可用歌曲"),
                          isDirectory: false, size: byteCount(song["size"]),
                          unavailableReason: filename == nil ? MusicServerFailure.missingFilename.localizedDescription : nil)
    }

    private func subsonicRequest(_ endpoint: String, parameters: [String: String] = [:]) async throws -> [String: Any] {
        let data = try await http.json(subsonicURLRequest(endpoint, parameters: parameters))
        try checkActive()
        guard let envelope = data["subsonic-response"] as? [String: Any],
              let status = envelope["status"] as? String else { throw MusicServerFailure.invalidResponse }
        guard status == "ok" else {
            let code = Self.integer((envelope["error"] as? [String: Any])?["code"]) ?? 0
            if code == 40 || code == 50 { throw MusicServerFailure.authentication }
            throw MusicServerFailure.server(code)
        }
        return envelope
    }

    private func subsonicURLRequest(_ endpoint: String, parameters: [String: String]) throws -> URLRequest {
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let token = Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        var query = parameters
        query.merge(["u": connection.username, "t": token, "s": salt, "v": "1.16.1", "c": "MusTag", "f": "json"]) { _, value in value }
        return try request(path: "/rest/" + endpoint, parameters: query)
    }

    private func loadFeiniuAlbums() async throws {
        var pageNumber = 1
        var received = 0
        var expectedTotal: Int?
        var seen = Set<String>()
        var seenPages = Set<Data>()
        var albums: [RemoteFile] = []
        var groups: [String: [RemoteFile]] = [:]
        while true {
            try checkActive()
            let data = try await feiniuRequest("track/list", parameters: ["page": String(pageNumber), "size": "300"])
            guard let page = data["list"] as? [[String: Any]] else { throw MusicServerFailure.invalidResponse }
            if let total = Self.integer(data["total"]), total >= 0 {
                if let previous = expectedTotal, previous != total { throw MusicServerFailure.incompletePage }
                expectedTotal = total
            }
            if page.isEmpty {
                if let expectedTotal, received < expectedTotal { throw MusicServerFailure.incompletePage }
                break
            }
            let pageData = try JSONSerialization.data(withJSONObject: page, options: .sortedKeys)
            guard seenPages.insert(Data(SHA256.hash(data: pageData))).inserted else { throw MusicServerFailure.repeatedPage }
            for (index, item) in page.enumerated() {
                try checkActive()
                let album = item["album"] as? [String: Any] ?? [:]
                let albumName = Self.text(album["name"]) ?? L10n.text("Other tracks", "其他歌曲")
                let albumKey = Self.text(album["guid"]).map { "id:\($0)" } ?? "name:\(albumName)"
                let albumPath = Self.path("/feiniu/album/", albumKey)
                if groups[albumPath] == nil {
                    albums.append(RemoteFile(id: albumPath, name: albumName, isDirectory: true))
                    groups[albumPath] = []
                }
                guard let guid = Self.text(item["guid"]) else {
                    groups[albumPath, default: []].append(RemoteFile(id: "/feiniu/unavailable-\(received + index)",
                        name: Self.text(item["title"]) ?? L10n.text("Unavailable track", "不可用歌曲"), isDirectory: false,
                        unavailableReason: MusicServerFailure.invalidResponse.localizedDescription))
                    continue
                }
                guard seen.insert(guid).inserted else { throw MusicServerFailure.repeatedPage }
                var file = Self.feiniuFile(item, guid: guid)
                if file.unavailableReason == MusicServerFailure.missingFilename.localizedDescription {
                    do {
                        let metadata = try await feiniuRequest("track/metadata", parameters: ["guid": guid])
                        file = Self.feiniuFile(metadata["track"] as? [String: Any] ?? metadata, guid: guid)
                    } catch is CancellationError { throw CancellationError() }
                    catch { file.unavailableReason = error.localizedDescription }
                }
                groups[albumPath, default: []].append(file)
            }
            received += page.count
            if let expectedTotal {
                guard received <= expectedTotal else { throw MusicServerFailure.incompletePage }
                if received == expectedTotal { break }
            }
            pageNumber += 1
        }
        try checkActive()
        feiniuAlbumFiles = groups
        feiniuAlbums = albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func feiniuFile(_ track: [String: Any], guid: String) -> RemoteFile {
        let audio = track["audioSpec"] as? [String: Any] ?? [:]
        let filename = originalFilename(audio["path"] ?? track["path"] ?? audio["fileName"] ?? track["fileName"])
        let unavailable = ["audioFileDeleted", "isAudioFileDeleted", "audio_file_deleted"].contains { boolean(track[$0]) }
            || integer(track["accessStatus"]) == 3
        let reason: MusicServerFailure? = unavailable ? .unavailable : boolean(track["isCue"]) ? .cue : filename == nil ? .missingFilename : nil
        return RemoteFile(id: path("/feiniu/song/", guid),
                          name: filename ?? text(track["title"]) ?? L10n.text("Unavailable track", "不可用歌曲"),
                          isDirectory: false,
                          size: byteCount(audio["size"] ?? audio["fileSize"] ?? track["size"] ?? track["fileSize"]),
                          unavailableReason: reason?.localizedDescription)
    }

    private func authenticateFeiniu(force: Bool = false) async throws -> String {
        try checkActive()
        if !force, let feiniuToken { return feiniuToken }
        let hash = SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
        var request = try feiniuURLRequest("user/password-login", parameters: [:], token: nil)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": connection.username, "password": hash,
            "deviceId": connection.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        ])
        let data = try Self.feiniuEnvelope(try await http.json(request))
        try checkActive()
        guard let token = Self.text(data["userToken"]),
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !token.contains(";"), !token.contains(",") else { throw MusicServerFailure.authentication }
        feiniuToken = token
        return token
    }

    private func feiniuRequest(_ endpoint: String, parameters: [String: String]) async throws -> [String: Any] {
        let token = try await authenticateFeiniu()
        do {
            let response = try await http.json(feiniuURLRequest(endpoint, parameters: parameters, token: token))
            try checkActive()
            return try Self.feiniuEnvelope(response)
        } catch MusicServerFailure.authentication {
            let token = try await authenticateFeiniu(force: true)
            let response = try await http.json(feiniuURLRequest(endpoint, parameters: parameters, token: token))
            try checkActive()
            return try Self.feiniuEnvelope(response)
        }
    }

    private static func feiniuEnvelope(_ envelope: [String: Any]) throws -> [String: Any] {
        guard let code = integer(envelope["code"]) else { throw MusicServerFailure.invalidResponse }
        guard code == 0 else {
            let message = text(envelope["msg"]) ?? ""
            if code == 401 || code == 403 || message.localizedCaseInsensitiveContains("invalid token") {
                throw MusicServerFailure.authentication
            }
            throw MusicServerFailure.server(code)
        }
        guard let data = envelope["data"] as? [String: Any] else { throw MusicServerFailure.invalidResponse }
        return data
    }

    private func feiniuURLRequest(_ endpoint: String, parameters: [String: String], token: String?) throws -> URLRequest {
        var request = try request(path: "/music/api/v1/" + endpoint, parameters: parameters)
        if let token { request.setValue("music-token=\(token)", forHTTPHeaderField: "Cookie") }
        return request
    }

    private func request(path: String, parameters: [String: String]) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw MusicServerFailure.invalidAddress }
        components.path += path
        components.queryItems = parameters.isEmpty ? nil : parameters.keys.sorted().map { URLQueryItem(name: $0, value: parameters[$0]) }
        guard let url = components.url else { throw MusicServerFailure.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        if disconnected { throw CancellationError() }
    }

    private static func normalizedURL(_ connection: RemoteConnection) throws -> URL {
        let raw = connection.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw MusicServerFailure.invalidAddress }
        let value = raw.contains("://") ? raw : "https://" + raw
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host?.isEmpty == false, components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              components.query == nil, components.fragment == nil else { throw MusicServerFailure.invalidAddress }
        if scheme == "http", !connection.allowsInsecureConnection { throw MusicServerFailure.insecureHTTP }
        components.scheme = scheme
        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffixes = connection.kind == .feiniu ? ["music/api/v1", "music"] : ["rest"]
        for suffix in suffixes where path == suffix || path.hasSuffix("/" + suffix) {
            path = String(path.dropLast(suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            break
        }
        components.path = path.isEmpty ? "" : "/" + path
        guard let url = components.url else { throw MusicServerFailure.invalidAddress }
        return url
    }

    private static func validateCurrent(_ current: RemoteFile, comparedTo original: RemoteFile) throws {
        if let reason = current.unavailableReason { throw MusTagError.message(reason) }
        guard current.name == original.name,
              current.size == nil || original.size == nil || current.size == original.size else {
            throw MusicServerFailure.changedFile
        }
    }

    private static func originalFilename(_ value: Any?) -> String? {
        guard let path = text(value) else { return nil }
        let name = (path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !(name as NSString).pathExtension.isEmpty,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }

    private static func path(_ prefix: String, _ id: String) -> String {
        prefix + Data(id.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func identifier(from path: String, prefix: String) throws -> String {
        guard path.hasPrefix(prefix) else { throw MusicServerFailure.invalidPath }
        var encoded = String(path.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let id = String(data: data, encoding: .utf8), !id.isEmpty else {
            throw MusicServerFailure.invalidPath
        }
        return id
    }

    private static func objects(_ value: Any?) throws -> [[String: Any]] {
        guard let value, !(value is NSNull) else { return [] }
        if let array = value as? [[String: Any]] { return array }
        if let object = value as? [String: Any] { return [object] }
        throw MusicServerFailure.invalidResponse
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return Int(number.stringValue) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func byteCount(_ value: Any?) -> Int64? {
        guard let number = integer(value), number >= 0 else { return nil }
        return Int64(number)
    }

    private static func boolean(_ value: Any?) -> Bool {
        value as? Bool == true || integer(value) == 1 || (value as? String).map { ["true", "yes"].contains($0.lowercased()) } == true
    }
}
