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

        /// 符号栏容器：横屏（放得下时）键宽拉满整行、像系统键盘一样铺满；
        /// 竖屏放不下时保持可横滑。键帽样式对标系统键盘：圆角 + 细阴影。
        private final class SymbolBarView: UIView {
            var keyWidthConstraints: [NSLayoutConstraint] = []
            var symbolStack: UIStackView?
            var keyCount: Int = 0
            /// 铺满模式的键间距（贴近系统键盘的键缝）
            private let evenSpacing: CGFloat = 6
            /// 铺满模式的最小键宽：再窄就切回横滑，保证可点
            private let minEvenKeyWidth: CGFloat = 36
            /// 横滑模式的固定键宽
            private let scrollKeyWidth: CGFloat = 44

            override func layoutSubviews() {
                super.layoutSubviews()
                let w = bounds.width
                guard w > 0, keyCount > 0, !keyWidthConstraints.isEmpty else { return }
                // 键区宽度 = 全宽 - 两侧边距(8+8) - 隐藏按钮(40)
                //            - 按钮与滚动区间距(8) - 栈内边距(8+8)
                let keysArea = w - 72
                let count = CGFloat(keyCount)
                let evenWidth = (keysArea - evenSpacing * (count - 1)) / count
                let evenly = evenWidth >= minEvenKeyWidth
                let targetWidth = evenly ? evenWidth : scrollKeyWidth
                let targetSpacing: CGFloat = evenly ? evenSpacing : 8
                // 只在变化时改，避免布局循环
                for c in keyWidthConstraints where abs(c.constant - targetWidth) > 0.5 {
                    c.constant = targetWidth
                }
                if let stack = symbolStack, abs(stack.spacing - targetSpacing) > 0.01 {
                    stack.spacing = targetSpacing
                }
            }
        }

        /// 键帽样式对标 iOS 系统键盘：圆角 + 细阴影。
        /// 底色沿用 tertiarySystemBackground（浅色下为白、深色下为深灰，与系统键帽一致）。
        private func applyKeyCapStyle(_ button: UIButton) {
            button.backgroundColor = .tertiarySystemBackground
            button.layer.cornerRadius = 6
            button.layer.shadowColor = UIColor.black.cgColor
            button.layer.shadowOpacity = 0.25
            button.layer.shadowOffset = CGSize(width: 0, height: 1)
            button.layer.shadowRadius = 1
        }

        func makeSymbolBar() -> UIView {
            let container = SymbolBarView()
            container.backgroundColor = .secondarySystemBackground
            // inputAccessoryView 用 frame 定高，宽度由系统拉伸
            container.frame = CGRect(x: 0, y: 0, width: 0, height: 48)
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]

            // 右侧固定的"隐藏键盘"按钮：不随符号行滚动，常驻可点（样式与符号键一致）
            let hideButton = UIButton(type: .system)
            hideButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
            hideButton.setPreferredSymbolConfiguration(
                UIImage.SymbolConfiguration(pointSize: 18, weight: .regular), forImageIn: .normal)
            hideButton.tintColor = .label
            applyKeyCapStyle(hideButton)
            hideButton.accessibilityLabel = NSLocalizedString("隐藏键盘", comment: "Hide keyboard button on the editor symbol bar")
            hideButton.addTarget(self, action: #selector(hideKeyboardTapped), for: .touchUpInside)
            hideButton.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hideButton)

            let scrollView = UIScrollView()
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(scrollView)

            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 8
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(stack)

            // 符号快捷键：只放系统英文 123 首屏没有的符号，避免重复。
            // 系统首屏已有：- / : ; ( ) $ & @ " . , ? ! ' —— 这里不再放。
            let symbols = ["⇥", "{", "}", "[", "]", "=", "<", ">", "\\", "|",
                           "+", "*", "_", "#"]
            for symbol in symbols {
                let button = UIButton(type: .system)
                button.setTitle(symbol, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 20, weight: .regular)
                button.setTitleColor(.label, for: .normal)
                applyKeyCapStyle(button)
                // 宽由 SymbolBarView.layoutSubviews 按横竖屏分配（横屏铺满 / 竖屏横滑）
                let wc = button.widthAnchor.constraint(equalToConstant: 44)
                wc.isActive = true
                container.keyWidthConstraints.append(wc)
                button.heightAnchor.constraint(equalToConstant: 38).isActive = true
                button.addTarget(self, action: #selector(symbolTapped(_:)), for: .touchUpInside)
                stack.addArrangedSubview(button)
            }
            container.symbolStack = stack
            container.keyCount = symbols.count

            NSLayoutConstraint.activate([
                hideButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                hideButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                hideButton.widthAnchor.constraint(equalToConstant: 40),
                hideButton.heightAnchor.constraint(equalToConstant: 38),

                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: hideButton.leadingAnchor, constant: -8),
                scrollView.topAnchor.constraint(equalTo: container.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

                stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 5),
                stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -5),
                stack.heightAnchor.constraint(equalToConstant: 38),
            ])
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
