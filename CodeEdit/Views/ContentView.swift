import SwiftUI

/// 主界面：
/// - iPad（regular）：NavigationSplitView，左侧文件树常驻。
/// - iPhone（compact）：编辑器为主界面，文件树做成左侧抽屉，
///   点左上角按钮滑出，打开文件后自动缩回。
struct ContentView: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var servers: ServerStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showSettings = false
    @State private var showDrawer = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    /// 导航栏标题：当前工作区的名字；没有工作区时退回活跃文件名/终端服务器名。
    private var navigationTitle: String {
        let name = workspace.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if let term = workspace.selectedTerminal {
            return servers.server(id: term.serverID)?.name ?? term.title
        }
        return workspace.selectedDocument?.displayName ?? "CodeEdit"
    }

    var body: some View {
        if sizeClass == .compact {
            compactLayout
        } else {
            splitLayout
        }
    }

    // MARK: - iPad：左右分栏

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            FileBrowserView(
                workspace: workspace,
                servers: servers,
                onOpenTerminal: openTerminal,
                onOpenSettings: { showSettings = true }
            )
        } detail: {
            EditorAreaView(workspace: workspace, settings: settings, servers: servers)
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, workspace: workspace, servers: servers)
        }
    }

    // MARK: - iPhone：编辑器 + 文件抽屉

    private var compactLayout: some View {
        NavigationStack {
            EditorAreaView(workspace: workspace, settings: settings, servers: servers)
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { showDrawer = true }
                        } label: {
                            Label("文件", systemImage: "sidebar.leading")
                        }
                    }
                }
        }
        .overlay {
            if showDrawer {
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) { showDrawer = false }
                        }
                    NavigationStack {
                        FileBrowserView(workspace: workspace, servers: servers) {
                            // 打开文件后抽屉自动缩回
                            withAnimation(.easeInOut(duration: 0.25)) { showDrawer = false }
                        } onOpenTerminal: { serverID in
                            withAnimation(.easeInOut(duration: 0.25)) { showDrawer = false }
                            openTerminal(serverID: serverID)
                        } onOpenSettings: {
                            showSettings = true
                        }
                    }
                    .frame(width: 300)
                    .transition(.move(edge: .leading))
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, workspace: workspace, servers: servers)
        }
    }

    // MARK: - 远程终端（作为标签页在主界面打开）

    private func openTerminal(serverID: UUID) {
        workspace.openTerminal(serverID: serverID)
    }
}
