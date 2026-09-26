import SwiftUI

@main
struct CodeEditApp: App {
    @StateObject private var workspace = WorkspaceStore()
    @StateObject private var settings = SettingsStore()
    @StateObject private var servers = ServerStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(workspace: workspace, settings: settings, servers: servers)
                .onAppear {
                    // 服务器列表就绪后，恢复上次的远程工作区（若有）
                    workspace.restoreRemoteWorkspaceIfNeeded(servers: servers)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                workspace.saveAll()
            }
        }
    }
}
