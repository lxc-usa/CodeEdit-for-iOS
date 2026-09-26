import SwiftUI

/// 主界面：
/// - iPad（regular）：NavigationSplitView，左侧文件树常驻。
/// - iPhone（compact）：编辑器为主界面，文件树做成左侧抽屉，
///   点左上角按钮滑出，打开文件后自动缩回。
struct ContentView: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var settings: SettingsStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showSettings = false
    @State private var showDrawer = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

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
            FileBrowserView(workspace: workspace)
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
    }

    // MARK: - iPhone：编辑器 + 文件抽屉

    private var compactLayout: some View {
        NavigationStack {
            EditorAreaView(workspace: workspace, settings: settings)
                .navigationTitle(workspace.selectedDocument?.displayName ?? "codeEditor")
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
                        FileBrowserView(workspace: workspace) {
                            // 打开文件后抽屉自动缩回
                            withAnimation(.easeInOut(duration: 0.25)) { showDrawer = false }
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
    }
}
