import Foundation

/// 远程目录条目。
struct RemoteFileEntry: Hashable {
    let name: String
    /// 远端绝对路径（如 "/home/user/a.txt"）。
    let path: String
    let isDirectory: Bool
    let size: UInt64?
}

/// 远程文件系统抽象。
///
/// WorkspaceStore 经这个协议操作远程文件，UI 流程与本地完全一致
/// （树形浏览、打开编辑、自动保存、新建/重命名/删除）。
/// SFTP 已实现；WebDAV / FTP / SMB 后续实现此协议即可即插即用。
protocol RemoteFileSystem: AnyObject {
    /// 合成 URL 的 scheme（如 "sftp"），用于区分本地 file://。
    var urlScheme: String { get }
    /// 展示用（如 "user@host:22"）。
    var displayName: String { get }

    /// 列出目录直属条目（只一层，不递归）。
    func list(path: String) async throws -> [RemoteFileEntry]
    /// 读文件全部字节。
    func read(path: String) async throws -> Data
    /// 写文件（不存在则创建，存在则截断覆盖）。
    func write(path: String, data: Data) async throws
    func createDirectory(path: String) async throws
    func delete(path: String, isDirectory: Bool) async throws
    func rename(from: String, to: String) async throws
    /// 解析远端主目录（"~" / "" 的落点）。
    func homeDirectory() async throws -> String
}
