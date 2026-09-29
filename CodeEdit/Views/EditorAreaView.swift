import SwiftUI

/// 右侧编辑区：标签页条 + 代码编辑器 / 终端（或空状态）。
struct EditorAreaView: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var servers: ServerStore
    @StateObject private var findController = FindController()
    @Environment(\.colorScheme) private var colorScheme

    /// 当前主题（字号/主题名/系统配色变化时重建，CETheme 构造只是颜色组装，开销可忽略）。
    private var theme: CETheme {
        let name = ThemeManager.effectiveDisplayName(
            followSystem: settings.followSystemTheme,
            family: settings.themeFamily,
            fallbackName: settings.themeName,
            systemDark: colorScheme == .dark
        )
        return ThemeManager.makeTheme(named: name, fontSize: settings.fontSize, monoFont: settings.monoFont)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.openDocuments.isEmpty || !workspace.openTerminals.isEmpty {
                // 顶部栏自动显隐：上滑隐藏（导航栏 + 标签条），下滑恢复
                if !workspace.isTopBarsHidden {
                    tabBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Divider()
                        .transition(.opacity)
                }
            }
            // 终端层常驻挂载（切到文件标签时只是隐藏）：保住回滚屏、不断会话；
            // 选中态经 isActive 驱动键盘聚焦/让出，非选中不参与触摸。
            ZStack {
                ForEach(workspace.openTerminals) { tab in
                    let isActive = workspace.selectedTerminal?.id == tab.id
                    TerminalView(
                        tab: tab,
                        initialPath: nil,
                        servers: servers,
                        settings: settings,
                        workspace: workspace,
                        isActive: isActive
                    )
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                }
                if workspace.selectedTerminal == nil {
                    if workspace.selectedDocument != nil {
                        ObservedDocumentView(
                            workspace: workspace,
                            settings: settings,
                            theme: theme,
                            findController: findController
                        )
                    } else {
                        WelcomeView(workspace: workspace)
                    }
                }
            }
        }
        .toolbar(workspace.isTopBarsHidden ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            EditorToolbarContent(workspace: workspace, findController: findController)
        }
        // 切标签 / 关到无标签（欢迎页无滚动视图）时恢复顶部栏，避免困在隐藏状态
        .onChange(of: workspace.selectedDocument?.id) { _, _ in
            workspace.setTopBarsHidden(false)
        }
        .onChange(of: workspace.selectedTerminal?.id) { _, _ in
            workspace.setTopBarsHidden(false)
        }
        .onChange(of: workspace.openDocuments.isEmpty && workspace.openTerminals.isEmpty) { _, isEmpty in
            if isEmpty { workspace.setTopBarsHidden(false) }
        }
    }

    // MARK: - 标签页条

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspace.openDocuments) { doc in
                        DocTab(doc: doc, workspace: workspace)
                            .id(doc.id)
                    }
                    ForEach(workspace.openTerminals) { tab in
                        TerminalTabRow(tab: tab, workspace: workspace, servers: servers)
                            .id(tab.id)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: 38)
            .background(.bar)
            .onAppear {
                scrollToSelectedSoon(proxy, animated: false)
            }
            .onChange(of: workspace.selectedDocument?.id) { _, _ in
                scrollToSelectedSoon(proxy, animated: true)
            }
            .onChange(of: workspace.selectedTerminal?.id) { _, _ in
                scrollToSelectedSoon(proxy, animated: true)
            }
        }
    }

    // MARK: - 标签页条

    /// 保证当前标签（文档或终端）始终处在可见区域（同 openCoder 的处理）。
    /// 用 Task 跳一拍：刚打开标签时新标签还没完成布局，直接 scrollTo 会滚不到。
    private func scrollToSelectedSoon(_ proxy: ScrollViewProxy, animated: Bool) {
        Task {
            let id: AnyHashable?
            if let termID = workspace.selectedTerminal?.id {
                id = AnyHashable(termID)
            } else if let docID = workspace.selectedDocument?.id {
                id = AnyHashable(docID)
            } else {
                id = nil
            }
            guard let id else { return }
            if animated {
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            } else {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

/// 观察单个文档（含 viewMode）：在源码编辑器与预览之间切换。
/// 单独成视图是因为 EditorAreaView 只观察 workspace，直接读 doc.viewMode
/// 不会触发刷新；这里用 @ObservedObject 包一层，切换分段控件时即时重绘。
/// `.id("source"/"preview")` 保证切换模式时底层 UIView 重建，不残留旧状态。
private struct ObservedDocumentView: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var settings: SettingsStore
    var theme: CETheme
    var findController: FindController

    var body: some View {
        if let doc = workspace.selectedDocument {
            ObservedDocumentInnerView(
                document: doc,
                settings: settings,
                theme: theme,
                findController: findController,
                workspace: workspace
            )
            .id(doc.url)
        }
    }
}

private struct ObservedDocumentInnerView: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var settings: SettingsStore
    var theme: CETheme
    var findController: FindController
    @ObservedObject var workspace: WorkspaceStore

    var body: some View {
        if document.isPreviewable && document.viewMode == .preview {
            PreviewContainerView(document: document, theme: theme, workspace: workspace, settings: settings)
                .id("preview")
        } else {
            CodeEditorView(
                document: document,
                settings: settings,
                theme: theme,
                findController: findController,
                workspace: workspace
            )
            .id("source")
        }
    }
}

// MARK: - 工具栏

/// 工具栏内容：预览开关与查找按钮都依赖 document.viewMode，
/// 必须由直接观察 document 的视图驱动，否则切换模式时按钮状态不更新。
private struct EditorToolbarContent: ToolbarContent {
    @ObservedObject var workspace: WorkspaceStore
    var findController: FindController

    var body: some ToolbarContent {
        if let doc = workspace.selectedDocument {
            DocumentToolbarContent(document: doc, findController: findController)
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    findController.presentFind()
                } label: {
                    Label("查找", systemImage: "magnifyingglass")
                }
                .disabled(true)
            }
        }
    }
}

private struct DocumentToolbarContent: ToolbarContent {
    @ObservedObject var document: EditorDocument
    var findController: FindController

    var body: some ToolbarContent {
        // md/html 文件：源码 / 预览切换
        ToolbarItem(placement: .topBarTrailing) {
            if document.isPreviewable {
                Picker("视图", selection: $document.viewMode) {
                    Text("源码").tag(DocumentViewMode.source)
                    Text("预览").tag(DocumentViewMode.preview)
                }
                .pickerStyle(.segmented)
                .frame(width: 132)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                findController.presentFind()
            } label: {
                Label("查找", systemImage: "magnifyingglass")
            }
            // 预览模式下没有编辑器，查找不可用
            .disabled(document.isPreviewable && document.viewMode == .preview)
        }
    }
}

/// 单个标签页：同时观察文档（dirty 圆点）与工作区（选中高亮）。
private struct DocTab: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var workspace: WorkspaceStore

    var body: some View {
        let isSelected = workspace.selectedDocument?.id == doc.id
        HStack(spacing: 6) {
            if doc.isDirty {
                Circle()
                    .fill(.orange)
                    .frame(width: 8, height: 8)
            }
            // 预览模式中的标签页：眼睛图标提示当前是渲染预览而非源码
            if doc.isPreviewable && doc.viewMode == .preview {
                Image(systemName: "eye")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(doc.displayName)
                .font(.subheadline)
                .lineLimit(1)
            Button {
                workspace.close(doc)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { workspace.selectDocument(doc) }
    }
}

/// 终端标签页：图标 + 服务器名 + 关闭按钮。
private struct TerminalTabRow: View {
    @ObservedObject var tab: TerminalTab
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var servers: ServerStore

    var body: some View {
        let isSelected = workspace.selectedTerminal?.id == tab.id
        // 服务器改名后标签名跟着变
        let name = servers.server(id: tab.serverID)?.name ?? tab.title
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Text(name)
                .font(.subheadline)
                .lineLimit(1)
            Button {
                workspace.closeTerminal(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { workspace.selectTerminal(tab) }
    }
}

// MARK: - 空状态

private struct WelcomeView: View {
    @ObservedObject var workspace: WorkspaceStore
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("选择或新建文件开始")
                .font(.headline)
            Text(sizeClass == .compact ? "轻触左上角按钮打开文件抽屉" : "轻触左侧文件列表开始编辑")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    workspace.createFile(
                        name: NSLocalizedString("未命名.txt", comment: "Default new file name"),
                        in: workspace.rootItem
                    )
                } label: {
                    Label("新建文件", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
