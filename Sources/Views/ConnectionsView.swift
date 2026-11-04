import SwiftUI

struct ConnectionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var picker: AudioPickerMode?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    importButton(
                        L10n.text("Files", "文件"),
                        subtitle: L10n.text("Choose one or more audio files", "选择一个或多个音频文件"),
                        systemImage: "doc.fill", color: .blue, mode: .files,
                        identifier: "connectionFilesButton")
                    importButton(
                        L10n.text("Folder", "文件夹"),
                        subtitle: L10n.text("Import music from a folder", "导入文件夹中的音乐"),
                        systemImage: "folder.fill", color: .orange, mode: .folder,
                        identifier: "connectionFolderButton")
                } header: {
                    Text(L10n.text("Local", "本地"))
                } footer: {
                    Text(L10n.text("Imported music appears on Home.", "导入的音乐会显示在首页。"))
                }

                Section(L10n.text("NAS & Servers", "NAS & 服务器")) {
                    ForEach(ConnectionService.allCases) { service in
                        NavigationLink {
                            ConnectionServiceView(service: service)
                        } label: {
                            connectionLabel(service.title, subtitle: service.summary,
                                            systemImage: service.systemImage, color: service.color)
                        }
                        .accessibilityIdentifier("connectionService_\(service.rawValue)")
                    }
                }

                Section {
                    importButton(
                        L10n.text("Browse cloud storage", "浏览网盘"),
                        subtitle: L10n.text("iCloud Drive and locations added to Files", "iCloud Drive 及已添加到“文件”的网盘"),
                        systemImage: "icloud.fill", color: .cyan, mode: .files,
                        identifier: "connectionCloudButton")
                } header: {
                    Text(L10n.text("Cloud storage", "网盘"))
                } footer: {
                    Text(L10n.text("Choose a cloud location in the Files browser to import audio.",
                                   "在系统“文件”的浏览页面中选择网盘位置，即可导入音频。"))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.text("Connections", "连接"))
            .navigationBarTitleDisplayMode(.large)
            .safeAreaInset(edge: .bottom) {
                if model.isWorking { OperationFooter() }
            }
            .sheet(item: $picker) { mode in
                AudioDocumentPicker(mode: mode, onPick: { urls in
                    model.importFiles(urls)
                    picker = nil
                }, onCancel: { picker = nil })
            }
        }
    }

    private func importButton(_ title: String, subtitle: String, systemImage: String,
                              color: Color, mode: AudioPickerMode, identifier: String) -> some View {
        Button { picker = mode } label: {
            HStack(spacing: 12) {
                connectionLabel(title, subtitle: subtitle, systemImage: systemImage, color: color)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isWorking)
        .accessibilityIdentifier(identifier)
    }

    private func connectionLabel(_ title: String, subtitle: String,
                                 systemImage: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 5)
    }
}

private enum ConnectionService: String, CaseIterable, Identifiable {
    case smb, ftp, webDAV, navidrome

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smb: "SMB"
        case .ftp: "FTP"
        case .webDAV: "WebDAV"
        case .navidrome: "Navidrome"
        }
    }

    var summary: String {
        switch self {
        case .smb: L10n.text("Shared folders on your local network", "局域网共享文件夹")
        case .ftp: L10n.text("Files on an FTP server", "FTP 服务器文件")
        case .webDAV: L10n.text("Remote folders over WebDAV", "WebDAV 远程文件夹")
        case .navidrome: L10n.text("Your personal music server", "个人音乐服务器")
        }
    }

    var systemImage: String {
        switch self {
        case .smb: "externaldrive.connected.to.line.below"
        case .ftp: "server.rack"
        case .webDAV: "network"
        case .navidrome: "music.note.house.fill"
        }
    }

    var color: Color {
        switch self {
        case .smb: .green
        case .ftp: .orange
        case .webDAV: .blue
        case .navidrome: .purple
        }
    }
}

private struct ConnectionServiceView: View {
    let service: ConnectionService

    var body: some View {
        ContentUnavailableView {
            Label(service.title, systemImage: service.systemImage)
        } description: {
            Text(service.summary)
            Text(L10n.text("Connections are not available yet.", "连接功能暂未开放。"))
        }
        .navigationTitle(service.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("connectionServiceDetail_\(service.rawValue)")
    }
}
