import SwiftUI
import WebKit

/// HTML 预览：WKWebView。
/// - HTML 片段：套一层带主题的壳（viewport + 深色/浅色 CSS）。
/// - 完整文档（含 <html>）：直接加载，只注入 viewport 和一份低优先级默认样式，
///   页面自带样式优先（作者意图不被覆盖）。
/// 顶部栏自动显隐：复用 TopBarScrollTracker，与编辑器行为一致。
struct HTMLPreviewView: UIViewRepresentable {
    @ObservedObject var document: EditorDocument
    var theme: CETheme
    var workspace: WorkspaceStore
    var settings: SettingsStore

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
        wv.loadHTMLString(wrappedHTML(document.text, isDark: theme.isDark), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var tracker: TopBarScrollTracker?
        var scrollObservation: NSKeyValueObservation?
        var lastText: String?
        var lastDark: Bool?
    }
}

/// HTML 包装：片段套壳，完整文档注入默认样式（低优先级）。
private func wrappedHTML(_ html: String, isDark: Bool) -> String {
    let bg = isDark ? "#000000" : "#ffffff"
    let fg = isDark ? "#e8e8e8" : "#1c1c1e"
    let link = isDark ? "#0a84ff" : "#0066cc"
    let codeBG = isDark ? "#2c2c2e" : "#f2f2f7"
    let border = isDark ? "#48484a" : "#d1d1d6"

    let defaultCSS = """
        body{font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:17px;line-height:1.6;color:\(fg);background:\(bg);padding:16px;margin:0;word-wrap:break-word;}
        a{color:\(link);}
        img,video{max-width:100%;height:auto;}
        pre{overflow-x:auto;background:\(codeBG);padding:12px;border-radius:8px;}
        code{font-family:ui-monospace,Menlo,monospace;font-size:.85em;}
        table{border-collapse:collapse;margin:12px 0;}
        th,td{border:1px solid \(border);padding:6px 12px;text-align:left;}
        """

    let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().contains("<html") {
        // 完整文档：只在 <head> 后注入 viewport + 默认样式（作者样式在后，优先级更高）
        var full = html
        let injection = "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>\(defaultCSS)</style>"
        if let headRange = full.range(of: "<head[^>]*>", options: .regularExpression) {
            full.insert(contentsOf: injection, at: headRange.upperBound)
        } else {
            full = injection + full
        }
        return full
    }
    return """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>\(defaultCSS)</style></head><body>\(html)</body></html>
        """
}
