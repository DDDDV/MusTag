import Foundation

/// Every music-server request stays at its configured origin. In particular, neither
/// Subsonic URL tokens nor FN Music login bodies/cookies are replayed to redirects.
final class MusicServerRedirectDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64, Int64?) -> Void

    init(progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite >= 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) { }
}

enum MusicServerFailure: LocalizedError {
    case invalidAddress, insecureHTTP, invalidResponse, incompletePage, repeatedPage
    case authentication, server(Int), network(Int), redirected, missingFilename
    case unavailable, cue, changedFile, invalidAudio, invalidPath

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return L10n.text("Enter a valid music server address without embedded credentials.", "请输入不含账号密码的有效音乐服务器地址。")
        case .insecureHTTP:
            return L10n.text("Enable the insecure HTTP option for this connection, or use HTTPS.", "请为此连接明确开启不安全 HTTP 选项，或使用 HTTPS。")
        case .invalidResponse:
            return L10n.text("The music server returned an invalid response.", "音乐服务器返回了无效响应。")
        case .incompletePage:
            return L10n.text("The music server returned an incomplete list. Refresh and try again.", "音乐服务器返回的列表不完整，请刷新后重试。")
        case .repeatedPage:
            return L10n.text("The music server repeated a page. Refresh and try again.", "音乐服务器重复返回了同一页，请刷新后重试。")
        case .authentication:
            return L10n.text("Sign-in failed or the account cannot download original files.", "登录失败，或此账号无权下载原始文件。")
        case .server(let code):
            return L10n.text("Music server error (\(code)).", "音乐服务器错误（\(code)）。")
        case .network(let code):
            return L10n.text("Could not reach the music server (\(code)).", "无法访问音乐服务器（\(code)）。")
        case .redirected:
            return L10n.text("The server redirected this request. Use its final server address to protect your credentials.", "服务器重定向了请求。请填写最终服务器地址以保护凭证。")
        case .missingFilename:
            return L10n.text("The server did not provide the original filename and extension.", "服务器未提供原始文件名和扩展名。")
        case .unavailable:
            return L10n.text("The original audio file is unavailable on the server.", "服务器上的原始音频文件不可用。")
        case .cue:
            return L10n.text("CUE segments cannot be downloaded as individual original files.", "CUE 分轨无法作为独立的原始文件下载。")
        case .changedFile:
            return L10n.text("The server file changed. Refresh this folder before downloading.", "服务器文件已变化，请刷新此目录后再下载。")
        case .invalidAudio:
            return L10n.text("The server did not return a complete original audio file.", "服务器没有返回完整的原始音频文件。")
        case .invalidPath:
            return L10n.text("This music server folder or file is no longer available. Refresh the connection.", "此音乐服务器目录或文件已不可用，请刷新连接。")
        }
    }
}

final class MusicServerHTTP: @unchecked Sendable {
    private let session: URLSession
    private let redirectDelegate = MusicServerRedirectDelegate()

    init(configuration: URLSessionConfiguration) {
        let isolated = configuration.copy() as! URLSessionConfiguration
        isolated.httpCookieStorage = nil
        isolated.httpShouldSetCookies = false
        isolated.urlCredentialStorage = nil
        isolated.urlCache = nil
        isolated.requestCachePolicy = .reloadIgnoringLocalCacheData
        isolated.timeoutIntervalForRequest = 60
        isolated.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: isolated, delegate: redirectDelegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func disconnect() { session.invalidateAndCancel() }

    func json(_ request: URLRequest) async throws -> [String: Any] {
        try Task.checkCancellation()
        do {
            let (data, response) = try await session.data(for: request, delegate: redirectDelegate)
            try Task.checkCancellation()
            try Self.validate(response)
            guard let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MusicServerFailure.invalidResponse
            }
            return dictionary
        } catch { throw Self.sanitized(error) }
    }

    func download(_ request: URLRequest, to destination: URL, expectedSize: Int64?,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        try Task.checkCancellation()
        let delegate = MusicServerRedirectDelegate(progress: progress)
        do {
            progress(0, expectedSize)
            let (temporary, response) = try await session.download(for: request, delegate: delegate)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            try Self.validate(response)
            let count = (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize.map(Int64.init) ?? 0
            guard count > 0, expectedSize.map({ $0 == count }) ?? true,
                  response.expectedContentLength < 0 || response.expectedContentLength == count else {
                throw MusicServerFailure.invalidAudio
            }
            let type = response.mimeType?.lowercased() ?? ""
            guard !["text/", "application/json", "application/xml", "application/xhtml"].contains(where: type.hasPrefix) else {
                throw MusicServerFailure.invalidAudio
            }
            let handle = try FileHandle(forReadingFrom: temporary)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 512) ?? Data()
            let text = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !text.hasPrefix("<"), !text.hasPrefix("{"), !text.hasPrefix("[") else {
                throw MusicServerFailure.invalidAudio
            }
            try Task.checkCancellation()
            // The caller owns this local destination. copyItem refuses to overwrite it.
            try FileManager.default.copyItem(at: temporary, to: destination)
            progress(count, expectedSize ?? count)
        } catch { throw Self.sanitized(error) }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw MusicServerFailure.invalidResponse }
        if (300..<400).contains(http.statusCode) { throw MusicServerFailure.redirected }
        if http.statusCode == 401 || http.statusCode == 403 { throw MusicServerFailure.authentication }
        guard http.statusCode == 200 else { throw MusicServerFailure.server(http.statusCode) }
    }

    private static func sanitized(_ error: Error) -> Error {
        if error is CancellationError || (error as NSError).code == NSURLErrorCancelled { return CancellationError() }
        if let failure = error as? MusicServerFailure { return failure }
        if let urlError = error as? URLError { return MusicServerFailure.network(urlError.errorCode) }
        // Foundation errors can contain authenticated URLs in their descriptions.
        return MusTagError.message(L10n.text("The music server operation failed. Check the connection and local storage.",
                                            "音乐服务器操作失败，请检查连接和本地存储空间。"))
    }
}
