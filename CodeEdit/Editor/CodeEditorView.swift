import Runestone
import SwiftUI
import UIKit

// MARK: - 查找控制器

/// 桥接 SwiftUI 工具栏按钮与 TextView 的系统查找面板。
final class FindController: ObservableObject {
    var requestFind: (() -> Void)?
    func presentFind() { requestFind?() }
}

// MARK: - 符号对

struct BasicCharacterPair: CharacterPair {
    let leading: String
    let trailing: String
}

// MARK: - 编辑器视图

/// Runestone TextView 的 SwiftUI 封装。每个文档实例对应一个独立的 TextView，
/// 父视图用 `.id(document.url)` 保证切换标签页时重建。
struct CodeEditorView: UIViewRepresentable {
    @ObservedObject var document: EditorDocument
    @ObservedObject var settings: SettingsStore
    var theme: CETheme
    var findController: FindController
    var workspace: WorkspaceStore

    func makeUIView(context: Context) -> TextView {
        let tv = TextView()
        let coordinator = context.coordinator

        tv.showLineNumbers = settings.showLineNumbers
        tv.isLineWrappingEnabled = settings.wordWrap
        tv.lineHeightMultiplier = 1.25
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)

        // 代码编辑不需要的系统行为全部关闭
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
        tv.keyboardType = .asciiCapable
        tv.keyboardAppearance = theme.isDark ? .dark : .light

        // 系统查找/替换面板（iOS 16+）
        tv.isFindInteractionEnabled = true

        tv.characterPairs = [
            BasicCharacterPair(leading: "{", trailing: "}"),
            BasicCharacterPair(leading: "(", trailing: ")"),
            BasicCharacterPair(leading: "[", trailing: "]"),
            BasicCharacterPair(leading: "\"", trailing: "\""),
            BasicCharacterPair(leading: "'", trailing: "'"),
            BasicCharacterPair(leading: "`", trailing: "`"),
        ]

        tv.insertionPointColor = theme.caretColor
        tv.selectionHighlightColor = theme.selectionColor
        tv.backgroundColor = theme.background
        tv.theme = theme

        let invisibles = settings.showInvisibles
        tv.showSpaces = invisibles
        tv.showTabs = invisibles
        tv.showLineBreaks = invisibles

        tv.editorDelegate = coordinator
        tv.inputAccessoryView = coordinator.makeSymbolBar()

        coordinator.textView = tv
        coordinator.tabWidth = Int(settings.tabWidth)
        coordinator.themeKey = themeKey()
        coordinator.loadInitialText()

        // 顶部栏自动显隐：上滑隐藏、下滑显示（只响应用户手势）
        let topBarTracker = TopBarScrollTracker(workspace: workspace)
        coordinator.topBarTracker = topBarTracker
        coordinator.scrollObservation = tv.observe(\.contentOffset, options: [.new]) { [weak coordinator] scrollView, _ in
            coordinator?.topBarTracker?.handleScroll(scrollView)
        }

        findController.requestFind = { [weak tv] in
            tv?.findInteraction?.presentFindNavigator(showingReplace: false)
        }
        return tv
    }

    func updateUIView(_ tv: TextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.tabWidth = Int(settings.tabWidth)

        // 主题或字号变化时换主题
        let key = themeKey()
        if coordinator.themeKey != key {
            coordinator.themeKey = key
            tv.theme = theme
            tv.backgroundColor = theme.background
            tv.insertionPointColor = theme.caretColor
            tv.selectionHighlightColor = theme.selectionColor
            tv.keyboardAppearance = theme.isDark ? .dark : .light
        }

        if tv.showLineNumbers != settings.showLineNumbers {
            tv.showLineNumbers = settings.showLineNumbers
        }
        if tv.isLineWrappingEnabled != settings.wordWrap {
            tv.isLineWrappingEnabled = settings.wordWrap
        }
        let invisibles = settings.showInvisibles
        if tv.showSpaces != invisibles {
            tv.showSpaces = invisibles
            tv.showTabs = invisibles
            tv.showLineBreaks = invisibles
        }

        findController.requestFind = { [weak tv] in
            tv?.findInteraction?.presentFindNavigator(showingReplace: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func themeKey() -> String {
        "\(theme.displayName)-\(settings.fontSize)-\(settings.monoFont.rawValue)"
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, TextViewDelegate {
        var parent: CodeEditorView
        weak var textView: TextView?
        /// setState 期间为 true，防止把初始加载回写为用户编辑。
        var suppressChanges = false
        var themeKey: String?
        var tabWidth: Int = 4
        /// 顶部栏自动显隐：KVO 观察 contentOffset
        ///（Runestone 的 TextViewDelegate 没有滚动回调）。
        var scrollObservation: NSKeyValueObservation?
        /// makeUIView 里创建（Coordinator 外部需要访问，不能 private）
        var topBarTracker: TopBarScrollTracker?

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        /// 后台线程创建 TextViewState（可能很耗时），主线程 setState。
        func loadInitialText() {
            let text = parent.document.text
            let theme = parent.theme
            let language = parent.document.language
            suppressChanges = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let state: TextViewState
                if let language = language {
                    state = TextViewState(text: text, theme: theme, language: language)
                } else {
                    state = TextViewState(text: text, theme: theme)
                }
                DispatchQueue.main.async {
                    self?.textView?.setState(state)
                    self?.suppressChanges = false
                }
            }
        }

        func textViewDidChange(_ textView: TextView) {
            guard !suppressChanges else { return }
            parent.document.text = textView.text
            // UIKit 保证 delegate 回调在主线程，同步跳回 @MainActor 的 WorkspaceStore。
            MainActor.assumeIsolated {
                parent.workspace.documentDidChange(parent.document)
            }
        }

        // MARK: - 符号快捷栏

        /// 符号栏容器：键尺寸对标系统键盘（真机实测：iPhone 竖屏 36.7×44pt，
        /// 横屏约 30×28pt；iPad 沿用 44×44），不拉伸铺满。
        /// 放得下时整组键按整栏宽度居中（隐藏按钮悬浮于滚动区右上层，不占布局位，
        /// 避免整组相对屏幕中心偏左）；放不下（竖屏）时可横滑，右侧给悬浮按钮留位。
        /// 键帽样式对标系统键盘：圆角 + 细阴影。
        private final class SymbolBarView: UIView {
            var scrollView: UIScrollView?
            var symbolStack: UIStackView?
            /// 符号键的宽/高约束（随横竖屏切换更新 constant）
            var keySizeConstraints: [(w: NSLayoutConstraint, h: NSLayoutConstraint)] = []
            /// 键组与可见区边缘的最小间距
            private let minSideInset: CGFloat = 8
            /// 已应用的键尺寸标记，避免 layoutSubviews 里重复设置
            private var appliedKeySpec = ""

            /// 真实界面方向。不能拿自身的 bounds 判断：横条的宽永远大于高，
            /// v19 用 bounds.width > bounds.height 把竖屏恒判成横屏，
            /// 竖屏拿到了 30×28 的小键（真机实测）。
            private var isLandscape: Bool {
                let ref = window?.bounds ?? UIScreen.main.bounds
                return ref.width > ref.height
            }

            override func layoutSubviews() {
                // 先按当前横竖屏/机型算出目标键尺寸（super 之后读 stack.bounds 才有效，
                // 尺寸变化会触发下一次 layout，本次用旧 contentW 算 inset，下次纠正）
                let isPad = UIDevice.current.userInterfaceIdiom == .pad
                let landscape = isLandscape
                let keyW: CGFloat
                let keyH: CGFloat
                let fontSize: CGFloat
                if isPad {
                    keyW = 44; keyH = 44; fontSize = 22
                } else if landscape {
                    keyW = 30; keyH = 28; fontSize = 20
                } else {
                    // 竖屏：14 符号键 + 隐藏键共 15 个，挤一挤全部显示，不横滑
                    // （用户 2026-09-27：竖屏只差两三个键位，要求挤挤全显示）
                    keyW = max(18, (bounds.width - 16 - 14 * 6) / 15)
                    keyH = 44; fontSize = 20
                }
                let spec = "\(keyW)x\(keyH)"
                if spec != appliedKeySpec {
                    appliedKeySpec = spec
                    for (w, h) in keySizeConstraints {
                        w.constant = keyW
                        h.constant = keyH
                    }
                    if let stack = symbolStack {
                        for case let b as UIButton in stack.arrangedSubviews {
                            b.titleLabel?.font = .systemFont(ofSize: fontSize, weight: .regular)
                        }
                    }
                }

                super.layoutSubviews()
                guard let sv = scrollView, let stack = symbolStack else { return }
                let visibleW = sv.bounds.width
                let contentW = stack.bounds.width
                guard visibleW > 0, contentW > 0 else { return }
                // 15 个键在 iPhone 上永远放得下：整组居中；
                // 极窄屏幕兜底：放不下时左贴边横滑。
                let side: CGFloat
                if contentW < visibleW {
                    side = max(minSideInset, (visibleW - contentW) / 2)
                } else {
                    side = minSideInset
                }
                let inset = UIEdgeInsets(top: 0, left: side, bottom: 0, right: side)
                // 只在变化时改，避免布局循环
                if sv.contentInset != inset {
                    sv.contentInset = inset
                }
            }
        }

        /// 键帽样式对标 iOS 系统键盘：圆角 + 细阴影。
        /// 底色沿用 tertiarySystemBackground（浅色下为白、深色下为深灰，与系统键帽一致）。
        private func applyKeyCapStyle(_ button: UIButton) {
            button.backgroundColor = .tertiarySystemBackground
            button.layer.cornerRadius = 7
            button.layer.shadowColor = UIColor.black.cgColor
            button.layer.shadowOpacity = 0.25
            button.layer.shadowOffset = CGSize(width: 0, height: 1)
            button.layer.shadowRadius = 1
        }

        func makeSymbolBar() -> UIView {
            let container = SymbolBarView()
            container.backgroundColor = .secondarySystemBackground
            // inputAccessoryView 用 frame 定高 58pt，宽度由系统拉伸；
            // 高度定死后 layout 里绝不再改，否则键盘占位和实际高度打架、
            // 底部漏出白条（v19 真机实测）。
            container.frame = CGRect(x: 0, y: 0, width: 0, height: 58)
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]

            // "隐藏键盘"按钮：样式与符号键一致，尺寸跟随键尺寸，排在最后。
            let hideButton = UIButton(type: .system)
            hideButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
            hideButton.setPreferredSymbolConfiguration(
                UIImage.SymbolConfiguration(pointSize: 18, weight: .regular), forImageIn: .normal)
            hideButton.tintColor = .label
            applyKeyCapStyle(hideButton)
            hideButton.accessibilityLabel = NSLocalizedString("隐藏键盘", comment: "Hide keyboard button on the editor symbol bar")
            hideButton.addTarget(self, action: #selector(hideKeyboardTapped), for: .touchUpInside)
            hideButton.translatesAutoresizingMaskIntoConstraints = false

            let scrollView = UIScrollView()
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            // 先加滚动区
            container.addSubview(scrollView)

            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 6
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(stack)

            // 符号快捷键：只放系统英文 123 首屏没有的符号，避免重复。
            // 系统首屏已有：- / : ; ( ) $ & @ " . , ? ! ' —— 这里不再放。
            // 竖屏 15 个键挤一排全部显示（用户要求），横屏键尺寸对标系统键盘（实测 30×28）。
            let symbols = ["⇥", "{", "}", "[", "]", "=", "<", ">", "\\", "|",
                           "+", "*", "_", "#"]
            var keySizeConstraints: [(w: NSLayoutConstraint, h: NSLayoutConstraint)] = []
            for symbol in symbols {
                let button = UIButton(type: .system)
                button.setTitle(symbol, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 22, weight: .regular)
                button.setTitleColor(.label, for: .normal)
                applyKeyCapStyle(button)
                let w = button.widthAnchor.constraint(equalToConstant: 44)
                let h = button.heightAnchor.constraint(equalToConstant: 44)
                w.isActive = true
                h.isActive = true
                keySizeConstraints.append((w, h))
                button.addTarget(self, action: #selector(symbolTapped(_:)), for: .touchUpInside)
                stack.addArrangedSubview(button)
            }
            // 隐藏键作为第 15 个普通键排在最后（不再悬浮）：竖屏 15 个键挤一排全显示，
            // 横屏整组居中；从根上杜绝悬浮按钮压住符号键（v19 真机实测压住了）。
            let hideW = hideButton.widthAnchor.constraint(equalToConstant: 44)
            let hideH = hideButton.heightAnchor.constraint(equalToConstant: 44)
            hideW.isActive = true
            hideH.isActive = true
            keySizeConstraints.append((hideW, hideH))
            stack.addArrangedSubview(hideButton)

            container.scrollView = scrollView
            container.symbolStack = stack
            container.keySizeConstraints = keySizeConstraints

            NSLayoutConstraint.activate([
                // 滚动区占整栏；整组居中/横滑的水平边距由
                // SymbolBarView.layoutSubviews 经 contentInset 控制
                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: container.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

                stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                // 栈高 = 栏高，键在栈内垂直居中（stack.alignment = .center）：
                // 竖屏 44pt 键上下各 7pt，横屏 28pt 键垂直居中
                stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            ])
            // 首帧 inset 就正确，不等 layoutSubviews 纠正
            scrollView.contentInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
            return container
        }

        @objc private func symbolTapped(_ sender: UIButton) {
            guard let symbol = sender.currentTitle, let tv = textView else { return }
            if symbol == "⇥" {
                tv.insertText(String(repeating: " ", count: max(1, tabWidth)))
                return
            }
            let pairs: [String: String] = [
                "{": "}", "(": ")", "[": "]",
                "\"": "\"", "'": "'", "`": "`",
            ]
            if let trailing = pairs[symbol] {
                // 插入期间暂时关闭自动配对，避免双重补全；光标放回括号中间
                let savedPairs = tv.characterPairs
                tv.characterPairs = []
                tv.insertText(symbol + trailing)
                tv.characterPairs = savedPairs
                if let sel = tv.selectedTextRange,
                   let pos = tv.position(from: sel.start, offset: -trailing.count),
                   let range = tv.textRange(from: pos, to: pos) {
                    tv.selectedTextRange = range
                }
            } else {
                tv.insertText(symbol)
            }
        }

        /// 符号栏右侧"隐藏键盘"按钮：收起键盘（编辑器侧无自动重弹逻辑，直接 resign 即可）。
        @objc private func hideKeyboardTapped() {
            textView?.resignFirstResponder()
        }
    }
}
