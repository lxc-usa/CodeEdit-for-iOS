import SwiftUI

@main
struct CodeEditApp: App {
    @StateObject private var workspace = WorkspaceStore()
    @StateObject private var settings = SettingsStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(workspace: workspace, settings: settings)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                workspace.saveAll()
            }
        }
    }
}
