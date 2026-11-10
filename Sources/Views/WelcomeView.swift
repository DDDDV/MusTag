import SwiftUI

/// The empty library is also the first-run entry point. Importing a file or a
/// folder naturally replaces this page with the library, without a setup gate.
struct WelcomeView: View {
    let isImporting: Bool
    let onImport: (AudioPickerMode) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsFAQ = false

    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.65, green: 0.66, blue: 1)
            : Color(red: 0.32, green: 0.30, blue: 0.82)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 8)

                    WelcomeIllustration()
                        .frame(width: illustrationWidth(in: geometry),
                               height: illustrationWidth(in: geometry) * 0.84)
                        .padding(.bottom, 22)

                    VStack(spacing: 14) {
                        Text(L10n.text(
                            "Identify and complete song information with audio fingerprinting.",
                            "通过音频指纹技术识别并补全歌曲信息"))
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .tracking(-0.7)
                            .foregroundStyle(.primary)
                            .accessibilityAddTraits(.isHeader)

                        Text(L10n.text(
                            "Batch-identify MP3, FLAC and M4A files to fill in titles, artists, albums, years, genres and covers, or edit tags manually. All files are copied to this device. Review and confirm before saving to the Music folder, with a metadata backup before each save.",
                            "支持 MP3、FLAC 和 M4A，批量识别并补全歌名、艺术家、专辑、年份、流派与封面，也可手动编辑标签。所有文件先复制到本机，预览确认后保存到 Music 文件夹，保存前自动备份元数据。"))
                            .font(.subheadline)
                            .lineSpacing(5)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 30)

                    actions
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: 480)
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("welcomeScreen")
        .sheet(isPresented: $showsFAQ) { WelcomeFAQView() }
    }

    private func illustrationWidth(in geometry: GeometryProxy) -> CGFloat {
        min(max(geometry.size.width - 56, 0), min(geometry.size.height * 0.49, 400))
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Menu {
                Button { onImport(.files) } label: {
                    Label(L10n.text("Choose files", "选择文件"), systemImage: "doc")
                }
                .accessibilityIdentifier("chooseFilesButton")
                Button { onImport(.folder) } label: {
                    Label(L10n.text("Choose folder", "选择文件夹"), systemImage: "folder")
                }
                .accessibilityIdentifier("chooseFolderButton")
            } label: {
                Label(L10n.text("Import music", "导入音乐"), systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .padding(.vertical, 17)
                    .foregroundStyle(.white)
                    .background {
                        RoundedRectangle(cornerRadius: 17)
                            .fill(LinearGradient(
                                colors: [Color(red: 0.38, green: 0.36, blue: 0.94),
                                         Color(red: 0.29, green: 0.29, blue: 0.82)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 17))
            }
            .disabled(isImporting)
            .opacity(isImporting ? 0.6 : 1)
            .accessibilityIdentifier("addAudioButton")

            Button { showsFAQ = true } label: {
                Text(L10n.text("Good to know", "常见问题"))
                    .font(.headline)
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .padding(.vertical, 15)
                    .background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 17))
                    .overlay {
                        RoundedRectangle(cornerRadius: 17)
                            .strokeBorder(accent.opacity(0.26), lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 17))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("welcomeFAQButton")

            Label(L10n.text("Review first. Back up before saving.", "修改先预览，保存前自动备份"),
                  systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }
}

private struct WelcomeFAQView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.text("A little care for your collection.", "从一首歌开始，整理你的珍藏。"))
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text(L10n.text("Import → Identify → Review & save", "导入音乐 → 识别补全 → 预览保存"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)

                    answer("folder", question: L10n.text("Which files can I import?", "可以导入哪些音乐？"),
                           text: L10n.text(
                            "MusTag supports MP3, FLAC and M4A. Import files or folders, receive music over Wi-Fi, or download from WebDAV, SMB, FTP, Subsonic, Navidrome and FeiNiu Music in Connections. All files are saved locally.",
                            "支持 MP3、FLAC 和 M4A。可导入文件或文件夹、使用 WiFi 传歌，或在“连接”中从 WebDAV、SMB、FTP、Subsonic、Navidrome、飞牛音乐下载。所有文件均保存在本机。"))

                    answer("waveform", question: L10n.text("How does recognition work?", "如何识别并补全标签？"),
                           text: L10n.text(
                            "After importing, tap Auto-match for your library, a folder or selected files. ShazamKit identifies songs without an API key or microphone. Available titles, artists, covers and album details are added to drafts for you to review. You can also edit tags manually.",
                            "导入后，点击“自动匹配”，即可处理全部音乐、当前文件夹或所选文件。默认通过 ShazamKit 识别，无需填写 API Key，也不使用麦克风。可用的歌名、艺术家、封面和专辑信息会填入草稿，等待你预览确认；也可以手动编辑标签。"))

                    answer("checkmark.shield", question: L10n.text("Will my original audio change?", "会改变原来的音质吗？"),
                           text: L10n.text(
                            "Saving changes tags without re-encoding the audio. Only local copies are updated after you review and confirm; source files are never changed. Before each save, MusTag backs up the original tags and covers without storing the audio. Undo in Settings requires the audio file and the backup. Backups are kept on this device and are removed if you delete the app.",
                            "保存时只修改标签，不重新编码音频。预览并确认保存后，仅修改本机副本，来源文件不会被改动；每次保存前会备份原标签和封面，不保存音频内容。在设置中撤销修改时，需要保留音频文件和备份。备份保存在本机，卸载 App 时会一并删除。"))

                    answer("square.and.pencil", question: L10n.text("What if a song isn't recognized?", "没有匹配结果怎么办？"),
                           text: L10n.text(
                            "Your existing tags are kept. Open a track to edit its details manually. Matches depend on the recognition service's catalog; covers and album details may not be available for every song. Lyrics are not currently supported.",
                            "原有标签会保留，可以点开歌曲手动编辑。匹配结果取决于识别服务的曲库，部分歌曲可能缺少封面或专辑信息。目前暂不支持歌词。"))
                }
                .padding(24)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("welcomeFAQContent")
            .navigationTitle(L10n.text("Good to know", "常见问题"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done", "完成")) { dismiss() }
                        .accessibilityIdentifier("welcomeFAQDoneButton")
                }
            }
        }
    }

    private func answer(_ symbol: String, question: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(question, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
