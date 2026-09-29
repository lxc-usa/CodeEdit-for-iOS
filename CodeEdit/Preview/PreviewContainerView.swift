import SwiftUI

/// 预览容器：按扩展名分发到 Markdown / HTML 预览。
struct PreviewContainerView: View {
    @ObservedObject var document: EditorDocument
    var theme: CETheme
    var workspace: WorkspaceStore
    var settings: SettingsStore

    var body: some View {
        let ext = document.url.pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
            HTMLPreviewView(document: document, theme: theme, workspace: workspace, settings: settings)
        } else {
            MarkdownPreviewView(document: document, theme: theme, workspace: workspace, settings: settings)
        }
    }
}
