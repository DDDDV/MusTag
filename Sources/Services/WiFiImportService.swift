import Darwin
import Foundation
import Network

@MainActor
final class WiFiImportService: ObservableObject {
    @Published private(set) var address: URL?
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var imported: [String] = []
    @Published var error: String?
    private var server: WiFiImportServer?
    private var generation = UUID()

    func start(port: UInt16) {
        guard server == nil else { return }
        isStarting = true; error = nil; imported = []
        let generation = UUID()
        self.generation = generation
        do {
            let server = try WiFiImportServer(port: port, repository: LocalDownloadRepository()) { [weak self] event in
                Task { @MainActor in
                    if case .imported(let url) = event {
                        if self?.generation == generation { self?.imported.append(url.lastPathComponent) }
                        NotificationCenter.default.post(name: .musTagLocalFilesAdded, object: nil,
                            userInfo: ["urls": [AudioFileStore.defaultLibraryDirectory.appendingPathComponent("WiFi", isDirectory: true)]])
                        return
                    }
                    guard let self else { return }
                    guard self.generation == generation else { return }
                    switch event {
                    case .ready(let port, let token):
                        guard self.server != nil else { return }
                        var parts = URLComponents()
                        parts.scheme = "http"; parts.host = Self.localAddress(); parts.port = Int(port)
                        parts.path = "/"; parts.queryItems = [URLQueryItem(name: "key", value: token)]
                        self.address = parts.url; self.isRunning = true; self.isStarting = false
                    case .imported: break
                    case .failed(let message): self.error = message; self.stop()
                    }
                }
            }
            self.server = server
            server.start()
        } catch { self.error = error.localizedDescription; isStarting = false }
    }

    func stop() {
        generation = UUID()
        server?.stop(); server = nil
        isRunning = false; isStarting = false; address = nil
    }

    private static func localAddress() -> String {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return "127.0.0.1" }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        var fallback = "127.0.0.1"
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name == "en0" || name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buffer)
                if name == "en0" { return ip }
                fallback = ip
            }
        }
        return fallback
    }
}

/// A small HTTP receiver, modeled on NetMusic's WiFi transfer. Files stream to disk.
final class WiFiImportServer: @unchecked Sendable {
    enum Event: Sendable {
        case ready(UInt16, String)
        case imported(URL)
        case failed(String)
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MusTag.WiFiImport")
    private let repository: LocalDownloadRepository
    private let spaceBudget: WiFiUploadSpaceBudget
    private let token = UUID().uuidString
    private let event: @Sendable (Event) -> Void
    private var clients: [UUID: WiFiUploadConnection] = [:]
    private var stopped = false

    init(port: UInt16, repository: LocalDownloadRepository, event: @escaping @Sendable (Event) -> Void) throws {
        listener = try NWListener(using: .tcp, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        self.repository = repository; self.event = event
        spaceBudget = WiFiUploadSpaceBudget(repository: repository)
        listener.service = NWListener.Service(name: "MusTag", type: "_http._tcp")
    }
    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready: if let port = self.listener.port { self.event(.ready(port.rawValue, self.token)) }
            case .failed(let error): self.event(.failed(error.localizedDescription)); self.stop()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped, self.clients.count < 8 else { connection.cancel(); return }
            let id = UUID()
            let client = WiFiUploadConnection(connection: connection, queue: self.queue, token: self.token,
                repository: self.repository, spaceBudget: self.spaceBudget,
                imported: { [event = self.event] url in event(.imported(url)) },
                finished: { [weak self] in self?.clients.removeValue(forKey: id) })
            self.clients[id] = client
            client.start()
        }
        listener.start(queue: queue)
    }
    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            listener.cancel()
            let active = Array(clients.values)
            clients.removeAll()
            active.forEach { $0.cancel() }
        }
    }
}

/// Admit uploads against all outstanding bodies, including requests still waiting
/// for their disk-space check. Reservations end after cancellation and final writes.
private actor WiFiUploadSpaceBudget {
    private let repository: LocalDownloadRepository
    private var reservations: [UUID: Int64] = [:]

    init(repository: LocalDownloadRepository) { self.repository = repository }

    func reserve(_ id: UUID, size: Int64) async throws {
        reservations[id] = size
        let total = reservations.values.reduce(Int64(0)) { result, value in
            let (sum, overflow) = result.addingReportingOverflow(value)
            return overflow ? Int64.max : sum
        }
        do {
            try await repository.checkBatchSpace(totalSize: total, largestFile: reservations.values.max() ?? 0)
            try Task.checkCancellation()
        } catch {
            reservations.removeValue(forKey: id)
            throw error
        }
    }

    func release(_ id: UUID) { reservations.removeValue(forKey: id) }
}

struct WiFiUploadRequest {
    let method: String
    let path: String
    let relativePath: String?
    let length: Int64

    static func parse(_ data: Data, token: String) throws -> WiFiUploadRequest {
        guard data.count <= 32 * 1024, let text = String(data: data, encoding: .utf8) else { throw invalid() }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0",
              first[1].hasPrefix("/"), !first[1].hasPrefix("//"),
              let parts = URLComponents(string: String(first[1])) else { throw invalid() }
        let keys = (parts.queryItems ?? []).filter { $0.name == "key" }
        guard keys.count == 1, keys[0].value == token else {
            throw MusTagError.message(L10n.text("Open the full address displayed in MusTag.", "请打开 MusTag 显示的完整地址。"))
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let index = line.firstIndex(of: ":") else { throw invalid() }
            let key = line[..<index].lowercased()
            guard headers[key] == nil else { throw invalid() }
            headers[key] = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let length = Int64(headers["content-length"] ?? "0"), length >= 0 else { throw invalid() }
        let paths = (parts.queryItems ?? []).filter { $0.name == "path" }
        guard paths.count <= 1 else { throw invalid() }
        let method = String(first[0])
        if method == "POST", parts.path == "/upload" {
            guard length > 0, let path = paths.first?.value,
                  let name = try ConnectionPaths.validateRelativePath(path).last,
                  ["mp3", "flac", "m4a"].contains((name as NSString).pathExtension.lowercased()) else { throw invalid() }
        } else if !(method == "GET" && parts.path == "/" && length == 0) { throw invalid() }
        return WiFiUploadRequest(method: method, path: parts.path, relativePath: paths.first?.value, length: length)
    }

    private static func invalid() -> MusTagError {
        .message(L10n.text("Invalid upload. Choose MP3, FLAC or M4A files.", "上传请求无效，请选择 MP3、FLAC 或 M4A 文件。"))
    }
}

private final class WiFiUploadConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let token: String
    private let repository: LocalDownloadRepository
    private let spaceBudget: WiFiUploadSpaceBudget
    private let reservationID = UUID()
    private let imported: @Sendable (URL) -> Void
    private let finished: () -> Void
    private var buffer = Data()
    private var request: WiFiUploadRequest?
    private var handle: FileHandle?
    private var temporary: URL?
    private var count: Int64 = 0
    private var done = false
    private var processing = false
    private var work: Task<Void, Never>?
    private var activityLease: LocalLibraryAccess.Lease?
    private var timeout: DispatchWorkItem?

    init(connection: NWConnection, queue: DispatchQueue, token: String, repository: LocalDownloadRepository,
         spaceBudget: WiFiUploadSpaceBudget,
         imported: @escaping @Sendable (URL) -> Void, finished: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.token = token; self.repository = repository
        self.spaceBudget = spaceBudget
        self.imported = imported; self.finished = finished
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cancel() }
            if case .cancelled = state { self?.cancel() }
        }
        connection.start(queue: queue)
        receive()
    }
    func cancel() {
        guard !done else { return }
        done = true; timeout?.cancel()
        let pending = work
        pending?.cancel()
        activityLease = nil
        try? handle?.close(); handle = nil
        let staging = temporary
        temporary = nil
        connection.cancel(); finished()
        Task { [spaceBudget, reservationID] in
            // The repository may still be validating this file. Its task retains
            // the library lease until the final write has stopped.
            await pending?.value
            if let staging { try? FileManager.default.removeItem(at: staging) }
            await spaceBudget.release(reservationID)
        }
    }
    private func receive() {
        guard !done, !processing else { return }
        timeout?.cancel()
        let expiry = DispatchWorkItem { [weak self] in self?.cancel() }
        timeout = expiry
        queue.asyncAfter(deadline: .now() + 60, execute: expiry)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, ended, error in
            guard let self, !self.done else { return }
            if error != nil { self.cancel(); return }
            do {
                if let data { try self.consume(data) }
                if ended && !self.processing { self.cancel() }
                else { self.receive() }
            } catch { self.respond(status: 400, text: error.localizedDescription) }
        }
    }
    private func consume(_ data: Data) throws {
        if request == nil {
            buffer.append(data)
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 32 * 1024 { throw MusTagError.message("Request headers too large") }
                return
            }
            let request = try WiFiUploadRequest.parse(Data(buffer[..<range.lowerBound]), token: token)
            self.request = request
            let body = Data(buffer[range.upperBound...]); buffer = Data()
            if request.method == "GET" { respond(status: 200, text: Self.page, html: true); return }
            guard let relative = request.relativePath else { throw MusTagError.message("Missing file path") }
            activityLease = try LocalLibraryAccess.shared.acquire(repository.libraryDirectory)
            processing = true
            work = Task { [weak self] in
                guard let self else { return }
                do {
                    try await spaceBudget.reserve(reservationID, size: request.length)
                    try Task.checkCancellation()
                    queue.async { [weak self] in
                        guard let self, !self.done else { return }
                        do {
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MusTag-wifi-" + UUID().uuidString)
                                .appendingPathExtension((relative as NSString).pathExtension)
                            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                            self.temporary = url; self.handle = try FileHandle(forWritingTo: url)
                            self.processing = false
                            try self.write(body)
                            self.receive()
                        } catch { self.respond(status: 400, text: error.localizedDescription) }
                    }
                } catch { queue.async { [weak self] in self?.respond(status: 400, text: error.localizedDescription) } }
            }
        } else { try write(data) }
    }
    private func write(_ data: Data) throws {
        guard let request, !processing else { return }
        let accepted = min(Int64(data.count), request.length - count)
        try handle?.write(contentsOf: data.prefix(Int(accepted)))
        count += accepted
        guard count == request.length, let temporary, let path = request.relativePath else { return }
        try handle?.synchronize(); try handle?.close(); handle = nil
        processing = true; timeout?.cancel()
        let lease = activityLease
        work = Task { [weak self, lease] in
            defer { withExtendedLifetime(lease) {} }
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let local = try await repository.acceptWiFi(temporary, relativePath: path, expectedSize: request.length)
                imported(local)
                queue.async { [weak self] in self?.respond(status: 200, text: local.lastPathComponent) }
            } catch { queue.async { [weak self] in self?.respond(status: 400, text: error.localizedDescription) } }
        }
    }
    private func respond(status: Int, text: String, html: Bool = false) {
        guard !done else { return }
        processing = true; timeout?.cancel()
        let body = Data(text.utf8)
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Bad Request")\r\nContent-Type: \(html ? "text/html" : "text/plain"); charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in self?.cancel() })
    }

    private static let page = """
    <!doctype html><html lang="zh"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>MusTag · WiFi</title><style>body{font:17px system-ui;max-width:640px;margin:60px auto;padding:24px;background:#f5f5fa;color:#202030}main{background:white;border-radius:22px;padding:28px}h1{color:#5147ba}label{display:block;margin:24px 0}input{display:block;margin-top:10px;max-width:100%}progress{width:100%}pre{white-space:pre-wrap;font:14px system-ui}small{color:#64647a}</style>
    <main><h1>MusTag</h1><p>WiFi 传歌 / Transfer music</p><small>MP3 · FLAC · M4A<br>文件将保存在本机 MusTag/Music，可通过“文件”App 查看。<br>Files are saved locally. Existing files are kept.</small>
    <label>选择文件 / Choose files<input id="files" type="file" multiple accept=".mp3,.flac,.m4a"></label>
    <label>选择文件夹 / Choose folder<input id="folder" type="file" webkitdirectory multiple></label>
    <progress id="progress" value="0" max="1"></progress><p id="summary" aria-live="polite"></p><pre id="status"></pre></main>
    <script>
    const key=new URLSearchParams(location.search).get('key');
    const status=document.getElementById('status');
    const progress=document.getElementById('progress');
    const summary=document.getElementById('summary');
    const inputs=Array.from(document.querySelectorAll('input'));
    let uploading=false;
    async function upload(list){
      if(uploading)return;
      const files=list.filter(file=>/\\.(mp3|flac|m4a)$/i.test(file.name));
      if(!files.length){status.textContent='请选择 MP3、FLAC 或 M4A 文件。 / Choose MP3, FLAC or M4A files.';return}
      uploading=true;
      inputs.forEach(input=>input.disabled=true);
      status.textContent='';
      const loaded=files.map(()=>0);
      const totalBytes=files.reduce((sum,file)=>sum+file.size,0);
      let next=0,completed=0,succeeded=0,failed=0;
      function render(){
        const transferred=loaded.reduce((sum,bytes)=>sum+bytes,0);
        progress.max=Math.max(1,totalBytes);progress.value=transferred;
        summary.textContent='已完成 / Completed '+completed+'/'+files.length+' · 成功 / Saved '+succeeded+' · 失败 / Failed '+failed+'\\n'
          +(transferred/1048576).toFixed(1)+' / '+(totalBytes/1048576).toFixed(1)+' MiB';
      }
      async function worker(){
        while(next<files.length){
          const index=next++,file=files[index],path=file.webkitRelativePath||file.name;
          status.textContent+='↑ '+path+'\\n';
          try{
            await new Promise((resolve,reject)=>{
              const request=new XMLHttpRequest();let settled=false;
              function finish(error){if(settled)return;settled=true;error?reject(error):resolve()}
              request.open('POST','/upload?key='+encodeURIComponent(key)+'&path='+encodeURIComponent(path));
              request.setRequestHeader('Content-Type','application/octet-stream');
              request.upload.onprogress=event=>{
                if(settled)return;
                loaded[index]=Math.max(loaded[index],Math.min(file.size,event.loaded));render();
              };
              request.onload=()=>finish(request.status===200?null:new Error(request.responseText||'上传失败 / Upload failed'));
              request.onerror=request.onabort=request.ontimeout=()=>finish(new Error('连接中断 / Connection interrupted'));
              request.send(file);
            });
            loaded[index]=file.size;succeeded++;status.textContent+='✓ '+path+'\\n';
          }catch(error){failed++;status.textContent+='✕ '+path+': '+error.message+'\\n'}
          finally{completed++;render()}
        }
      }
      render();
      try{await Promise.all(Array.from({length:Math.min(3,files.length)},()=>worker()))}
      finally{uploading=false;inputs.forEach(input=>{input.disabled=false;input.value=''})}
    }
    inputs.forEach(input=>input.onchange=()=>upload(Array.from(input.files)));
    </script></html>
    """
}
