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
        "\(theme.displayName)-\(settings.fontSize)"
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

        func makeSymbolBar() -> UIView {
            let container = UIView()
            container.backgroundColor = .secondarySystemBackground
            // inputAccessoryView 用 frame 定高，宽度由系统拉伸
            container.frame = CGRect(x: 0, y: 0, width: 0, height: 46)
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]

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

            let symbols = ["⇥", "{", "}", "(", ")", "[", "]", ";", ":", "=",
                           "\"", "'", "<", ">", "/", "\\", "|", ".", ",",
                           "+", "-", "*", "_", "#", "$", "!", "?", "&"]
            for symbol in symbols {
                let button = UIButton(type: .system)
                button.setTitle(symbol, for: .normal)
                button.titleLabel?.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
                button.setTitleColor(.label, for: .normal)
                button.backgroundColor = .tertiarySystemBackground
                button.layer.cornerRadius = 6
                button.contentEdgeInsets = UIEdgeInsets(top: 5, left: 11, bottom: 5, right: 11)
                button.addTarget(self, action: #selector(symbolTapped(_:)), for: .touchUpInside)
                stack.addArrangedSubview(button)
            }

            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: container.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

                stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 6),
                stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -6),
                stack.heightAnchor.constraint(equalToConstant: 34),
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
    }
}
