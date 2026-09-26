import SwiftUI

/// 右侧编辑区：标签页条 + 代码编辑器（或空状态）。
struct EditorAreaView: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var settings: SettingsStore
    @StateObject private var findController = FindController()

    /// 当前主题（字号/主题名变化时重建，CETheme 构造只是颜色组装，开销可忽略）。
    private var theme: CETheme {
        ThemeManager.makeTheme(named: settings.themeName, fontSize: settings.fontSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.openDocuments.isEmpty {
                tabBar
                Divider()
            }
            if let doc = workspace.selectedDocument {
                CodeEditorView(
                    document: doc,
                    settings: settings,
                    theme: theme,
                    findController: findController,
                    workspace: workspace
                )
                .id(doc.url)
            } else {
                WelcomeView(workspace: workspace)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    findController.presentFind()
                } label: {
                    Label("查找", systemImage: "magnifyingglass")
                }
                .disabled(workspace.selectedDocument == nil)
            }
        }
    }

    // MARK: - 标签页条

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(workspace.openDocuments) { doc in
                    DocTab(doc: doc, workspace: workspace)
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 38)
        .background(.bar)
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
        .onTapGesture { workspace.selectedDocument = doc }
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
