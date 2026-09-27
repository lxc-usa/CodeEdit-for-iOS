import Foundation

/// SFTP 实现的 RemoteFileSystem：复用 openCoder 的 SSHManager（Citadel SFTP）。
final class SFTPFileSystem: RemoteFileSystem {
    let server: ServerConfig

    var urlScheme: String { "sftp" }
    var displayName: String { server.displayAddress }

    init(server: ServerConfig) {
        self.server = server
    }

    func list(path: String) async throws -> [RemoteFileEntry] {
        try await SSHManager.shared.listDirectory(server: server, path: path)
    }

    func read(path: String) async throws -> Data {
        try await SSHManager.shared.readFileData(server: server, path: path)
    }

    func write(path: String, data: Data) async throws {
        try await SSHManager.shared.writeFileData(server: server, path: path, data: data)
    }

    func createDirectory(path: String) async throws {
        try await SSHManager.shared.createDirectory(server: server, path: path)
    }

    func delete(path: String, isDirectory: Bool) async throws {
        if isDirectory {
            // 远端目录可能非空：递归删除，与本地 removeItem 行为一致
            try await SSHManager.shared.removeRecursive(server: server, path: path)
        } else {
            try await SSHManager.shared.remove(server: server, path: path, isDirectory: false)
        }
    }

    func rename(from: String, to: String) async throws {
        try await SSHManager.shared.rename(server: server, oldPath: from, newPath: to)
    }

    func homeDirectory() async throws -> String {
        try await SSHManager.shared.realPath(server: server, path: ".")
    }
}
