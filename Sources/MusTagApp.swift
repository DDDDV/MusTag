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
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { Task { await model.persistNow() } }
                }
        }
    }
}
