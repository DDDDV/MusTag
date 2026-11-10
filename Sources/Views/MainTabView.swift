import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            switch model.libraryLoadState {
            case .loading:
                ProgressView(L10n.text("Loading library…", "正在读取资料库…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
                    .accessibilityIdentifier("libraryLoadingState")
            case .failed(let message):
                ContentUnavailableView {
                    Label(L10n.text("Couldn’t load library", "无法读取资料库"), systemImage: "exclamationmark.folder")
                } description: {
                    Text(message)
                } actions: {
                    Button(L10n.text("Try again", "重试")) {
                        Task { await model.load() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("libraryRetryButton")
                }
                .accessibilityIdentifier("libraryLoadErrorState")
            case .ready:
                tabs
            }
        }
        .alert(L10n.text("Notice", "提示"), isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        )) {
            Button(L10n.text("OK", "好"), role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }

    private var tabs: some View {
        TabView(selection: $model.selectedTab) {
            LibraryView()
                .environment(\.horizontalSizeClass, horizontalSizeClass)
                .tabItem {
                    Label(L10n.text("Home", "首页"), systemImage: "house")
                }
                .tag(AppTab.home)

            ConnectionsView()
                .environment(\.horizontalSizeClass, horizontalSizeClass)
                .tabItem {
                    Label(L10n.text("Connections", "连接"), systemImage: "link")
                }
                .tag(AppTab.connections)

            SettingsView()
                .environment(\.horizontalSizeClass, horizontalSizeClass)
                .tabItem {
                    Label(L10n.text("Settings", "设置"), systemImage: "gearshape")
                }
                .tag(AppTab.settings)
        }
        // Keep navigation at the bottom on iPad, while preserving each page's layout traits.
        .environment(\.horizontalSizeClass, .compact)
    }
}
