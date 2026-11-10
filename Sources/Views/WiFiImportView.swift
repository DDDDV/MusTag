import SwiftUI

struct WiFiImportView: View {
    @StateObject private var service = WiFiImportService()
    @State private var port = "8080"
    @Environment(\.scenePhase) private var phase

    var body: some View {
        List {
            Section {
                Text(L10n.text("Connect the computer and this device to the same Wi-Fi network. Keep this page open, then open the address below in the computer's browser.", "让电脑与本机连接同一 WiFi。保持此页面打开，在电脑浏览器中访问下方地址即可传歌。"))
                TextField(L10n.text("Port", "端口"), text: $port).keyboardType(.numberPad)
                    .disabled(service.isRunning || service.isStarting)
                if service.isStarting { ProgressView() }
                if service.isRunning || service.isStarting {
                    Button(L10n.text("Stop transfer service", "停止传输服务"), role: .destructive) { service.stop() }
                } else {
                    Button(L10n.text("Start Wi-Fi transfer", "开启 WiFi 传歌")) {
                        guard let value = UInt16(port), value > 0 else {
                            service.error = L10n.text("Enter a port from 1 to 65535.", "请输入 1–65535 之间的端口。"); return
                        }
                        service.start(port: value)
                    }.accessibilityIdentifier("startWiFiTransferButton")
                }
                if let address = service.address {
                    Text(address.absoluteString).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    ShareLink(item: address) { Label(L10n.text("Share address", "分享地址"), systemImage: "square.and.arrow.up") }
                }
                if let error = service.error { Text(error).foregroundStyle(.red) }
            } footer: {
                Text(L10n.text("Uploads use HTTP on your local network. Stopping or leaving this page closes the service. Files already received stay in Files → MusTag → Music → WiFi.", "上传通过本地网络 HTTP 进行。停止服务或离开页面会关闭连接，已接收的文件保留在“文件”→ MusTag → Music → WiFi。"))
            }
            if !service.imported.isEmpty {
                Section(L10n.text("Received", "已接收")) {
                    ForEach(Array(service.imported.enumerated()), id: \.offset) { _, name in Label(name, systemImage: "checkmark.circle") }
                }
            }
        }
        .navigationTitle(L10n.text("Wi-Fi Transfer", "WiFi 传歌")).navigationBarTitleDisplayMode(.inline)
        .onDisappear { service.stop() }
        .onChange(of: phase) { _, phase in if phase == .background { service.stop() } }
    }
}
