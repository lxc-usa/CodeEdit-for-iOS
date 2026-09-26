import Combine
import Foundation

/// 文件树中的一个节点：文件或文件夹。
/// 本地用 file:// URL；远程工作区用合成 URL（如 sftp://<serverID>/<path>），
/// id 取 absoluteString，保证跨服务器唯一。
final class FileItem: Identifiable, ObservableObject {
    /// 用完整 URL 字符串做 id，保证重命名/移动后身份变化可被 SwiftUI 正确 diff。
    let id: String
    let url: URL
    @Published var name: String
    let isDirectory: Bool
    /// nil 表示是文件，或文件夹尚未加载。
    @Published var children: [FileItem]?
    /// 父节点（远程懒加载展开时用；本地可为空）。
    weak var parent: FileItem?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
        self.id = url.absoluteString
        self.name = url.lastPathComponent
    }

    /// 该节点是否属于远程工作区。
    var isRemote: Bool { url.scheme != "file" }

    /// 远程目录的"加载中…"占位子节点：让 disclosure 三角出现，展开时触发真实加载。
    var isLoadingPlaceholder: Bool { url.scheme == "codeedit-placeholder" }

    static func loadingPlaceholder(parent: FileItem) -> FileItem {
        let item = FileItem(url: URL(string: "codeedit-placeholder://loading")!, isDirectory: false)
        item.name = NSLocalizedString("加载中…", comment: "Remote folder loading placeholder")
        item.parent = parent
        return item
    }
}
