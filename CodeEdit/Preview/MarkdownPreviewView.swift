import SwiftUI
import UIKit

/// Markdown 预览：系统 `AttributedString(markdown:)` 渲染 + 自研 GFM 表格支持。
///
/// 注意：用 TextKit 1 的 UITextView（显式搭 NSTextStorage/NSLayoutManager/NSTextContainer），
/// NSTextTable 是 TextKit 1 的 API，在 TextKit 2 下行为不明，1 代最稳。
/// 顶部栏自动显隐：复用 TopBarScrollTracker，与编辑器行为一致。
struct MarkdownPreviewView: UIViewRepresentable {
    @ObservedObject var document: EditorDocument
    var theme: CETheme
    var workspace: WorkspaceStore
    var settings: SettingsStore

    func makeUIView(context: Context) -> UITextView {
        // TextKit 1 栈：NSTextTable 必需
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: .zero)
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let tv = UITextView(frame: .zero, textContainer: textContainer)
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = theme.background
        tv.textColor = .label
        tv.font = .systemFont(ofSize: 17)
        // 按 App 主题（而非系统外观）解析动态颜色：用户可能手动指定了深色主题
        tv.overrideUserInterfaceStyle = theme.isDark ? .dark : .light
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 40, right: 16)
        tv.textContainer.lineFragmentPadding = 0

        let coordinator = context.coordinator
        coordinator.tracker = TopBarScrollTracker(workspace: workspace, settings: settings)
        coordinator.scrollObservation = tv.observe(\.contentOffset, options: [.new]) { [weak coordinator] scrollView, _ in
            coordinator?.tracker?.handleScroll(scrollView)
        }
        reload(tv, coordinator: coordinator)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let coordinator = context.coordinator
        let themeChanged = coordinator.lastDark != theme.isDark
        guard coordinator.lastText != document.text || themeChanged else { return }
        if themeChanged {
            tv.backgroundColor = theme.background
            tv.overrideUserInterfaceStyle = theme.isDark ? .dark : .light
        }
        reload(tv, coordinator: coordinator)
    }

    /// 重建渲染内容；尽量保持滚动位置（切回来不跳到顶）。
    private func reload(_ tv: UITextView, coordinator: Coordinator) {
        coordinator.lastText = document.text
        coordinator.lastDark = theme.isDark
        let offset = tv.contentOffset
        tv.attributedText = renderMarkdown(document.text, theme: theme)
        // 内容变矮时钳制，避免偏移量越界
        let maxY = max(0, tv.contentSize.height - tv.bounds.height + tv.contentInset.bottom)
        tv.contentOffset = CGPoint(x: offset.x, y: min(offset.y, maxY))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var tracker: TopBarScrollTracker?
        var scrollObservation: NSKeyValueObservation?
        var lastText: String?
        var lastDark: Bool?
    }
}
