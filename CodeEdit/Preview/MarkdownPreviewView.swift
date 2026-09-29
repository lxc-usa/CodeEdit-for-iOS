import SwiftUI

/// Markdown 预览：零依赖转 HTML（含 GFM 表格）→ WKWebView。
struct MarkdownPreviewView: View {
    @ObservedObject var document: EditorDocument
    var theme: CETheme
    var workspace: WorkspaceStore
    var settings: SettingsStore

    var body: some View {
        WebPreviewView(document: document, theme: theme, workspace: workspace, settings: settings) { text, isDark in
            wrappedHTML(markdownToHTML(text), isDark: isDark)
        }
    }
}
