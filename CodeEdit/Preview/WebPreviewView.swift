import SwiftUI
import WebKit

/// WKWebView 预览（Markdown / HTML 共用）：HTML 源字符串由调用方提供。
/// 顶部栏自动显隐：复用 TopBarScrollTracker，与编辑器行为一致。
struct WebPreviewView: UIViewRepresentable {
    @ObservedObject var document: EditorDocument
    var theme: CETheme
    var workspace: WorkspaceStore
    var settings: SettingsStore
    /// (原文, 是否深色) -> 完整 HTML。
    /// HTML 文件：原文直接套壳；Markdown：先经 markdownToHTML 转 HTML 再套壳。
    var htmlProvider: (String, Bool) -> String

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        wv.backgroundColor = theme.background
        wv.isOpaque = true
        wv.scrollView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 32, right: 0)

        let coordinator = context.coordinator
        coordinator.tracker = TopBarScrollTracker(workspace: workspace, settings: settings)
        coordinator.scrollObservation = wv.scrollView.observe(\.contentOffset, options: [.new]) { [weak coordinator] scrollView, _ in
            coordinator?.tracker?.handleScroll(scrollView)
        }
        reload(wv, coordinator: coordinator)
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.lastText != document.text || coordinator.lastDark != theme.isDark else { return }
        wv.backgroundColor = theme.background
        reload(wv, coordinator: coordinator)
    }

    private func reload(_ wv: WKWebView, coordinator: Coordinator) {
        coordinator.lastText = document.text
        coordinator.lastDark = theme.isDark
        wv.loadHTMLString(htmlProvider(document.text, theme.isDark), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var tracker: TopBarScrollTracker?
        var scrollObservation: NSKeyValueObservation?
        var lastText: String?
        var lastDark: Bool?
    }
}
