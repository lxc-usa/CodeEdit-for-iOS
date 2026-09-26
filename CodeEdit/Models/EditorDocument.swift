import Combine
import Foundation
import Runestone

/// 一个打开的编辑器标签页。
final class EditorDocument: Identifiable, ObservableObject {
    let id: String
    let url: URL
    @Published var text: String
    @Published var isDirty = false
    /// 由文件扩展名判定的 Tree-sitter 语言，nil 表示纯文本。
    let language: TreeSitterLanguage?

    var displayName: String { url.lastPathComponent }

    init(url: URL, text: String) {
        self.url = url
        self.text = text
        self.id = url.path
        self.language = LanguageSupport.treeSitterLanguage(for: url)
    }

    func markDirty() {
        if !isDirty { isDirty = true }
    }

    /// 保存到磁盘。成功后清除 dirty，失败则保持 dirty 等待下次保存。
    func save() {
        guard isDirty else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
        } catch {
            // 保持 dirty，交由自动保存/手动保存重试，不抛错打断 UI
        }
    }
}
