import SwiftUI

/// HTML 预览：WKWebView（片段套主题壳，完整文档注入低优先级默认样式）。
struct HTMLPreviewView: View {
    @ObservedObject var document: EditorDocument
    var theme: CETheme
    var workspace: WorkspaceStore
    var settings: SettingsStore

    var body: some View {
        WebPreviewView(document: document, theme: theme, workspace: workspace, settings: settings) { text, isDark in
            wrappedHTML(text, isDark: isDark)
        }
    }
}
