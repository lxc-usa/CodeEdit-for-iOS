import Combine
import Foundation
import Runestone

/// 源码 / 预览视图模式（仅 md/html 等可预览文件有效）。
enum DocumentViewMode: Hashable {
    case source
    case preview
}

/// 一个打开的编辑器标签页。
final class EditorDocument: Identifiable, ObservableObject {
    let id: String
    let url: URL
    @Published var text: String
    @Published var isDirty = false
    /// 源码 / 预览切换（仅 isPreviewable 时有效），默认源码。
    @Published var viewMode: DocumentViewMode = .source
    /// 由文件扩展名判定的 Tree-sitter 语言，nil 表示纯文本。
    let language: TreeSitterLanguage?
    /// 远程文档：打开时由 WorkspaceStore 注入，保存时走远程文件系统。
    var remoteFS: (any RemoteFileSystem)?

    /// 可预览的文件扩展名：markdown / html。
    private static let previewableExtensions: Set<String> = ["md", "markdown", "htm", "html"]

    /// 是否支持源码/预览切换（按扩展名判定）。
    var isPreviewable: Bool {
        Self.previewableExtensions.contains(url.pathExtension.lowercased())
    }

    var displayName: String { url.lastPathComponent }

    init(url: URL, text: String) {
        self.url = url
        self.text = text
        self.id = url.absoluteString
        self.language = LanguageSupport.treeSitterLanguage(for: url)
    }

    func markDirty() {
        if !isDirty { isDirty = true }
    }

    /// 异步保存并等待完成（重命名/删除/切换工作区前调用，避免竞态）。
    func saveAndWait() async {
        guard isDirty else { return }
        if let fs = remoteFS {
            do {
                try await fs.write(path: url.path, data: Data(text.utf8))
                isDirty = false
            } catch {
                // 保持 dirty，交由自动保存/手动保存重试
            }
            return
        }
        save()
    }

    /// 保存。本地写磁盘，远程走 RemoteFileSystem；成功后清除 dirty，
    /// 失败则保持 dirty 等待下次保存。
    func save() {
        guard isDirty else { return }
        if let fs = remoteFS {
            let text = text
            let path = url.path
            Task { [weak self] in
                do {
                    try await fs.write(path: path, data: Data(text.utf8))
                    await MainActor.run { self?.isDirty = false }
                } catch {
                    // 保持 dirty，交由自动保存/手动保存重试，不抛错打断 UI
                }
            }
            return
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
        } catch {
            // 保持 dirty，交由自动保存/手动保存重试，不抛错打断 UI
        }
    }
}
