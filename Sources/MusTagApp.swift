import SwiftUI

@main
struct MusTagApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(model)
                .tint(.indigo)
                .task { await model.load() }
                .onReceive(NotificationCenter.default.publisher(for: .musTagLocalFilesAdded)) { notification in
                    if let urls = notification.userInfo?["urls"] as? [URL] { model.enqueueLocalImports(urls) }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { Task { await model.persistNow() } }
                }
        }
    }
}
