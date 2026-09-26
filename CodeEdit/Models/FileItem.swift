import Combine
import Foundation

/// 文件树中的一个节点：文件或文件夹。
final class FileItem: Identifiable, ObservableObject {
    /// 用完整路径做 id，保证重命名/移动后身份变化可被 SwiftUI 正确 diff。
    let id: String
    let url: URL
    @Published var name: String
    let isDirectory: Bool
    /// nil 表示是文件，或文件夹尚未加载。
    @Published var children: [FileItem]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
        self.id = url.path
        self.name = url.lastPathComponent
    }
}
