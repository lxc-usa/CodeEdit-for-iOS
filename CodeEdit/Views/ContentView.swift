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
    /// 非 nil 时全屏打开该服务器的远程终端。
    @State private var terminalServer: ServerConfig?

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
            FileBrowserView(workspace: workspace, servers: servers, onOpenTerminal: openTerminal)
        } detail: {
            EditorAreaView(workspace: workspace, settings: settings)
                .navigationBarTitleDisplayMode(.inline)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showSettings = true
                } label: {
                    Label("设置", systemImage: "gear")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings)
        }
        .fullScreenCover(item: $terminalServer) { server in
            terminalCover(server: server)
        }
    }

    // MARK: - iPhone：编辑器 + 文件抽屉

    private var compactLayout: some View {
        NavigationStack {
            EditorAreaView(workspace: workspace, settings: settings)
                .navigationTitle(workspace.selectedDocument?.displayName ?? "CodeEdit")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { showDrawer = true }
                        } label: {
                            Label("文件", systemImage: "sidebar.leading")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showSettings = true
                        } label: {
                            Label("设置", systemImage: "gear")
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
                        }
                    }
                    .frame(width: 300)
                    .transition(.move(edge: .leading))
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings)
        }
        .fullScreenCover(item: $terminalServer) { server in
            terminalCover(server: server)
        }
    }

    // MARK: - 远程终端

    private func openTerminal(serverID: UUID) {
        guard let server = servers.server(id: serverID) else { return }
        terminalServer = server
    }

    @ViewBuilder
    private func terminalCover(server: ServerConfig) -> some View {
        NavigationStack {
            TerminalView(serverID: server.id, initialPath: nil, servers: servers, settings: settings)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            terminalServer = nil
                        } label: {
                            Label("关闭", systemImage: "xmark")
                        }
                    }
                }
        }
    }
}
