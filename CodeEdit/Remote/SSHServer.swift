import Foundation

/// SSH 服务器配置（复用 openCoder 的模型：密码只存 Keychain，不进 UserDefaults）。
struct ServerConfig: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String

    var displayAddress: String { "\(username)@\(host):\(port)" }
}

/// 服务器列表：UserDefaults 存配置，Keychain 存密码。
final class ServerStore: ObservableObject {
    @Published private(set) var servers: [ServerConfig] = []

    private let storageKey = "codeedit.servers"

    init() {
        load()
    }

    func server(id: UUID) -> ServerConfig? {
        servers.first { $0.id == id }
    }

    func add(_ server: ServerConfig, password: String) {
        servers.append(server)
        KeychainStore.save(password, account: KeychainStore.passwordAccount(for: server.id))
        persist()
    }

    func update(_ server: ServerConfig, password: String?) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        let old = servers[index]
        servers[index] = server
        if let password {
            KeychainStore.save(password, account: KeychainStore.passwordAccount(for: server.id))
        }
        // 主机或端口变了：旧 pin 作废、断开旧连接，下次连接重新 TOFU
        if old.host != server.host || old.port != server.port {
            HostKeyPinStore.shared.forget(key: HostKeyPinStore.pinKey(host: old.host, port: old.port))
            Task { await SSHManager.shared.disconnect(serverID: server.id) }
        }
        persist()
    }

    /// @MainActor：内部调 TerminalSessionCache.shared.discard（@MainActor 隔离）。
    @MainActor
    func delete(_ server: ServerConfig) {
        servers.removeAll { $0.id == server.id }
        KeychainStore.delete(account: KeychainStore.passwordAccount(for: server.id))
        HostKeyPinStore.shared.forget(key: HostKeyPinStore.pinKey(host: server.host, port: server.port))
        TerminalSessionCache.shared.discard(serverID: server.id)
        Task { await SSHManager.shared.disconnect(serverID: server.id) }
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data) else { return }
        servers = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
