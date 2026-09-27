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

        /// 符号栏容器：键保持系统键盘般的固定尺寸（不拉伸铺满），
        /// 放得下时整组键居中（贴近系统键盘的观感），放不下（竖屏）时可横滑。
        /// 键帽样式对标系统键盘：圆角 + 细阴影。
        private final class SymbolBarView: UIView {
            var scrollView: UIScrollView?
            var symbolStack: UIStackView?
            /// 键组与可见区边缘的最小间距
            private let minSideInset: CGFloat = 8

            override func layoutSubviews() {
                // super 会同步完成子视图布局，此后读 stack.bounds 才有效
                super.layoutSubviews()
                guard let sv = scrollView, let stack = symbolStack else { return }
                let visibleW = sv.bounds.width
                let contentW = stack.bounds.width
                guard visibleW > 0, contentW > 0 else { return }
                // 放得下时用 contentInset 把整组键居中；放不下时保持最小边距可横滑
                let side = max(minSideInset, (visibleW - contentW) / 2)
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
            // inputAccessoryView 用 frame 定高，宽度由系统拉伸
            // 行高对标系统键盘的行距：44pt 键 + 上下各 7pt
            container.frame = CGRect(x: 0, y: 0, width: 0, height: 58)
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
            stack.spacing = 6
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(stack)

            // 符号快捷键：只放系统英文 123 首屏没有的符号，避免重复。
            // 系统首屏已有：- / : ; ( ) $ & @ " . , ? ! ' —— 这里不再放。
            // 键尺寸固定为 44×44（对标系统键盘键帽，不随宽度拉伸）；
            // 横屏放得下时整组居中，竖屏放不下时横滑。
            let symbols = ["⇥", "{", "}", "[", "]", "=", "<", ">", "\\", "|",
                           "+", "*", "_", "#"]
            for symbol in symbols {
                let button = UIButton(type: .system)
                button.setTitle(symbol, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 22, weight: .regular)
                button.setTitleColor(.label, for: .normal)
                applyKeyCapStyle(button)
                button.widthAnchor.constraint(equalToConstant: 44).isActive = true
                button.heightAnchor.constraint(equalToConstant: 44).isActive = true
                button.addTarget(self, action: #selector(symbolTapped(_:)), for: .touchUpInside)
                stack.addArrangedSubview(button)
            }
            container.scrollView = scrollView
            container.symbolStack = stack

            NSLayoutConstraint.activate([
                hideButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                hideButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                hideButton.widthAnchor.constraint(equalToConstant: 44),
                hideButton.heightAnchor.constraint(equalToConstant: 44),

                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: hideButton.leadingAnchor, constant: -8),
                scrollView.topAnchor.constraint(equalTo: container.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

                // 水平边距由 SymbolBarView.layoutSubviews 经 contentInset 控制（居中/横滑）
                stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 7),
                stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -7),
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
