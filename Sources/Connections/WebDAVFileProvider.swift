import Foundation

final class WebDAVFileProvider: RemoteFileProvider, @unchecked Sendable {
    private let root: URL
    private let session: URLSession
    private let delegate: WebDAVSessionDelegate
    private let transfers = RemoteCancellationRegistry()

    init(connection: RemoteConnection, password: String) throws {
        let address = try RemoteFilePaths.endpoint(connection.address, defaultScheme: "https", schemes: ["http", "https"])
        guard address.scheme?.lowercased() != "http" || connection.allowsInsecureConnection else {
            throw RemoteTransportError.insecureConnection
        }
        root = try Self.rootURL(address: address, rootPath: connection.rootPath)
        delegate = WebDAVSessionDelegate(origin: address, username: connection.username, password: password)
        session = URLSession(configuration: Self.configuration(), delegate: delegate, delegateQueue: nil)
    }

    fileprivate static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        return config
    }

    deinit { session.invalidateAndCancel(); transfers.cancelAll() }
    func disconnect() async { session.invalidateAndCancel(); transfers.cancelAll() }

    static func rootURL(address: URL, rootPath: String) throws -> URL {
        try requestURL(root: address, path: rootPath, directory: true)
    }

    private func url(for logicalPath: String, directory: Bool = false) throws -> URL {
        try Self.requestURL(root: root, path: logicalPath, directory: directory)
    }

    static func requestURL(root: URL, path: String, directory: Bool) throws -> URL {
        guard var url = URLComponents(url: root, resolvingAgainstBaseURL: true) else {
            throw RemoteTransportError.invalidAddress
        }
        let parts = try decodedComponents(root) + RemoteFilePaths.components(path)
        // Construct one path: appending an empty directory component can preserve a
        // second slash on iOS even though macOS Foundation normalizes the same call.
        url.path = "/" + parts.joined(separator: "/") + (directory && !parts.isEmpty ? "/" : "")
        guard let result = url.url else { throw RemoteTransportError.invalidPath }
        return result
    }

    func listDirectory(path: String) async throws -> [RemoteFile] {
        let target = try url(for: path, directory: true)
        var request = URLRequest(url: target)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>".utf8)
        let (temporary, response) = try await session.download(for: request, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.validate(response)
        let length = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard length <= 8 * 1024 * 1024 else { throw RemoteTransportError.invalidResponse }
        try Task.checkCancellation()
        return try Self.parseListing(Data(contentsOf: temporary), requestURL: target, rootURL: root)
    }

    func download(_ file: RemoteFile, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        guard !file.isDirectory else { throw RemoteTransportError.invalidPath }
        let stage = try RemoteDownloadStage(destination: destination)
        var request = URLRequest(url: try url(for: file.id))
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        progress(0, file.size)
        let transfer = WebDAVDownloadOperation(origin: delegate.origin, username: delegate.username,
                                               password: delegate.password, progress: progress, expectedSize: file.size)
        let token = transfers.add { transfer.cancel() }
        defer { transfers.remove(token); transfer.cancel() }
        let (temporary, response) = try await transfer.run(request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.validate(response)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RemoteTransportError.invalidResponse }
        let input = try FileHandle(forReadingFrom: temporary)
        defer { try? input.close() }
        var received: Int64 = 0
        while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            try stage.handle.write(contentsOf: data)
            received += Int64(data.count)
        }
        let total = response.expectedContentLength >= 0 ? response.expectedContentLength : file.size
        if let total, received != total { throw RemoteTransportError.invalidResponse }
        try stage.finish()
        progress(received, total)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw RemoteTransportError.invalidResponse }
        switch http.statusCode {
        case 200...299: return
        case 401, 403: throw RemoteTransportError.authentication
        case 404: throw RemoteTransportError.notFound
        default: throw RemoteTransportError.server(http.statusCode)
        }
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }

    static func decodedComponents(_ url: URL) throws -> [String] {
        guard let encoded = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath else {
            throw RemoteTransportError.invalidPath
        }
        return try encoded.split(separator: "/").map { component in
            guard let value = String(component).removingPercentEncoding,
                  try RemoteFilePaths.components(value) == [value] else { throw RemoteTransportError.invalidPath }
            return value
        }
    }

    static func parseListing(_ data: Data, requestURL: URL, rootURL: URL) throws -> [RemoteFile] {
        guard !String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("<!DOCTYPE") else {
            throw RemoteTransportError.invalidResponse
        }
        let delegate = WebDAVListingParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.sawMultistatus else { throw RemoteTransportError.invalidResponse }
        let rootParts = try decodedComponents(rootURL)
        let parentParts = try decodedComponents(requestURL)
        var found: [String: RemoteFile] = [:]
        for item in delegate.entries {
            guard let url = URL(string: item.href, relativeTo: requestURL)?.absoluteURL,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  sameOrigin(url, rootURL), let parts = try? decodedComponents(url),
                  parts.count == parentParts.count + 1, Array(parts.dropLast()) == parentParts,
                  Array(parts.prefix(rootParts.count)) == rootParts, let name = parts.last else { continue }
            let id = "/" + parts.dropFirst(rootParts.count).joined(separator: "/")
            found[id] = RemoteFile(id: id, name: name, isDirectory: item.isDirectory, size: item.size, modifiedAt: item.modifiedAt)
        }
        return RemoteFilePaths.sorted(Array(found.values))
    }
}

private class WebDAVSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let origin: URL
    let username: String
    let password: String
    private let progress: (@Sendable (Int64, Int64?) -> Void)?
    private let expectedSize: Int64?
    init(origin: URL, username: String, password: String,
         progress: (@Sendable (Int64, Int64?) -> Void)? = nil, expectedSize: Int64? = nil) {
        self.origin = origin; self.username = username; self.password = password
        self.progress = progress; self.expectedSize = expectedSize
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?(totalBytesWritten, totalBytesExpectedToWrite >= 0 ? totalBytesExpectedToWrite : expectedSize)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let passwordMethods = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault]
        guard passwordMethods.contains(space.authenticationMethod) else {
            completionHandler(.performDefaultHandling, nil); return
        }
        guard challenge.previousFailureCount == 0, space.host.lowercased() == origin.host?.lowercased(),
              space.port == (origin.port ?? (origin.scheme?.lowercased() == "https" ? 443 : 80)),
              space.protocol?.lowercased() == origin.scheme?.lowercased() else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .none))
    }
}

/// The async download convenience method suppresses download progress callbacks.
/// A delegate-driven task provides byte progress and owns its temporary file until delivery.
private final class WebDAVDownloadOperation: WebDAVSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var activeSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadedURL: URL?
    private var fileError: Error?
    private var cancelled = false

    func run(_ request: URLRequest) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                begin(request, continuation: continuation)
            }
        } onCancel: { self.cancel() }
    }

    private func begin(_ request: URLRequest, continuation: CheckedContinuation<(URL, URLResponse), Error>) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let session = URLSession(configuration: WebDAVFileProvider.configuration(), delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: request)
        activeSession = session; downloadTask = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock(); cancelled = true
        let task = downloadTask; let session = activeSession
        lock.unlock()
        task?.cancel(); session?.invalidateAndCancel()
    }

    override func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }
        let retained = FileManager.default.temporaryDirectory.appendingPathComponent("MusTag-WebDAV-\(UUID().uuidString)")
        do {
            // URLSession removes its download when this delegate method returns.
            try FileManager.default.moveItem(at: location, to: retained)
            downloadedURL = retained
        } catch { fileError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let waiting = continuation; continuation = nil
        let local = downloadedURL; downloadedURL = nil
        let failure = cancelled ? CancellationError() : (error ?? fileError)
        downloadTask = nil; activeSession = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        guard let waiting else {
            if let local { try? FileManager.default.removeItem(at: local) }
            return
        }
        if let failure {
            if let local { try? FileManager.default.removeItem(at: local) }
            waiting.resume(throwing: failure)
        } else if let local, let response = task.response {
            waiting.resume(returning: (local, response))
        } else {
            if let local { try? FileManager.default.removeItem(at: local) }
            waiting.resume(throwing: RemoteTransportError.invalidResponse)
        }
    }
}

private final class WebDAVListingParser: NSObject, XMLParserDelegate {
    struct Entry { var href = ""; var isDirectory = false; var size: Int64?; var modifiedAt: Date? }
    var entries: [Entry] = []
    var sawMultistatus = false
    private var current = Entry()
    private var prop = Entry()
    private var status = ""
    private var inPropstat = false
    private var accepted = false
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        guard namespaceURI == "DAV:" || namespaceURI == nil else { return }
        switch elementName {
        case "multistatus": sawMultistatus = true
        case "response": current = Entry(); accepted = false
        case "propstat": prop = Entry(); status = ""; inPropstat = true
        case "collection": if inPropstat { prop.isDirectory = true }
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard namespaceURI == "DAV:" || namespaceURI == nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href": if !inPropstat { current.href = value }
        case "getcontentlength": if inPropstat { prop.size = Int64(value).flatMap { $0 >= 0 ? $0 : nil } }
        case "getlastmodified":
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if inPropstat { prop.modifiedAt = formatter.date(from: value) }
        case "status": if inPropstat { status = value }
        case "propstat":
            if let code = status.split(separator: " ").dropFirst().first.flatMap({ Int($0) }), (200..<300).contains(code) {
                accepted = true; current.isDirectory = current.isDirectory || prop.isDirectory
                current.size = prop.size ?? current.size; current.modifiedAt = prop.modifiedAt ?? current.modifiedAt
            }
            inPropstat = false
        case "response": if accepted, !current.href.isEmpty { entries.append(current) }
        default: break
        }
        text = ""
    }
}
