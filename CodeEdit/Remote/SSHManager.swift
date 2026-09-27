import Foundation
@preconcurrency import Citadel
import NIOSSH
import NIO

enum SSHManagerError: LocalizedError {
    case missingPassword
    case hostKeyMismatch(host: String)
    case cannotSerializeHostKey
    /// 带阶段上下文的连接/操作错误：underlying 的原始信息通过 describeSSHError 转成中文。
    case connectionFailed(stage: String, underlying: Error)
    /// 握手算法协商失败：已自动抓取服务器 KEXINIT，把双方算法清单摆出来，不再靠猜。
    case handshakeFailed(host: String, port: Int, probe: SSHKexProbe.Result?, raw: String)
    /// 终端会话"正常"结束但 SSH 主连接已死：掉线导致的假正常结束，
    /// 不能混成"shell 自己退出"，按连接失败处理。
    case sessionLost

    var errorDescription: String? {
        switch self {
        case .missingPassword:
            return String(localized: "Keychain 中没有该服务器的密码，请重新编辑服务器并填写密码")
        case .hostKeyMismatch(let host):
            return String(format: NSLocalizedString("⚠️ %@ 的主机密钥与首次连接时记录的不一致，可能遭遇中间人攻击，已拒绝连接", comment: ""), host)
        case .cannotSerializeHostKey:
            return String(localized: "无法读取服务器主机密钥")
        case .connectionFailed(let stage, let underlying):
            return String(format: NSLocalizedString("%@失败：%@", comment: ""), stage, describeSSHError(underlying))
        case .sessionLost:
            return String(localized: "终端连接已断开，请重试")
        case .handshakeFailed(let host, let port, let probe, let raw):
            var lines = [String(format: NSLocalizedString("连接 %@:%d 失败：SSH 算法协商不一致。", comment: ""), host, port)]
            if let p = probe, !p.isEmpty {
                lines.append("")
                lines.append(String(format: NSLocalizedString("【服务器提供】%@", comment: ""), p.banner))
                lines.append(String(format: NSLocalizedString("• 密钥交换：%@", comment: ""), p.keyExchange.joined(separator: ", ")))
                lines.append(String(format: NSLocalizedString("• 主机密钥：%@", comment: ""), p.hostKey.joined(separator: ", ")))
                lines.append(String(format: NSLocalizedString("• 加密(去)：%@", comment: ""), p.encryptionC2S.joined(separator: ", ")))
                lines.append(String(format: NSLocalizedString("• 加密(回)：%@", comment: ""), p.encryptionS2C.joined(separator: ", ")))
                lines.append(String(format: NSLocalizedString("• MAC(去)：%@", comment: ""), p.macC2S.joined(separator: ", ")))
                lines.append(String(format: NSLocalizedString("• MAC(回)：%@", comment: ""), p.macS2C.joined(separator: ", ")))
                lines.append("")
                lines.append(String(localized: "【本 App 提供】"))
                lines.append(String(format: NSLocalizedString("• 密钥交换：%@", comment: ""), SSHKexProbe.ourKeyExchange))
                lines.append(String(format: NSLocalizedString("• 主机密钥：%@", comment: ""), SSHKexProbe.ourHostKey))
                lines.append(String(format: NSLocalizedString("• 加密：%@", comment: ""), SSHKexProbe.ourEncryption))
                lines.append(String(format: NSLocalizedString("• MAC：%@", comment: ""), SSHKexProbe.ourMac))
            } else {
                lines.append(String(localized: "（未能读取服务器算法清单，请把这条完整信息发给开发者定位）"))
            }
            lines.append("")
            lines.append(String(format: NSLocalizedString("原始错误：%@", comment: ""), raw))
            return lines.joined(separator: "\n")
        }
    }
}

/// 把底层错误转成中文说明。
/// 背景：NIOSSHError 是 struct，它的 diagnostics 是私有的，`localizedDescription`
/// 只能显示 "The operation couldn't be completed. (NIOSSH.NIOSSHError error 1.)"，
/// 真正的原因藏在公开的 `type` 字段里。这里把它挖出来。
func describeSSHError(_ error: Error) -> String {
    if let e = error as? SSHManagerError {
        // 避免双重包装
        if case .connectionFailed = e { return e.errorDescription ?? String(localized: "连接失败") }
        return e.errorDescription ?? String(localized: "SSH 错误")
    }
    if let e = error as? SSHClientError {
        switch e {
        case .allAuthenticationOptionsFailed:
            return String(localized: "身份认证失败：服务器拒绝了用户名/密码，请检查用户名和密码是否正确")
        case .unsupportedPasswordAuthentication:
            return String(localized: "服务器不支持密码认证")
        case .unsupportedPrivateKeyAuthentication:
            return String(localized: "服务器不支持私钥认证")
        case .unsupportedHostBasedAuthentication:
            return String(localized: "服务器不支持 host-based 认证")
        case .channelCreationFailed:
            return String(localized: "SSH 通道创建失败")
        }
    }
    if let e = error as? NIOSSHError {
        let t = e.type
        // 原始细节（包含私有 diagnostics 的文本形式），兜底时展示
        let raw = String(describing: e)
        switch t {
        case .keyExchangeNegotiationFailure:
            // 注意：NIOSSH 在密钥交换、主机密钥、加密、MAC 任一环节无交集，
            // 或双向协商结果不对称时都抛这个错，不只是"密钥交换算法"。
            return String(format: NSLocalizedString("SSH 握手失败：算法协商不一致（密钥交换 / 主机密钥 / 加密 / MAC 任一环节没有共同选项）（%@）", comment: ""), raw)
        case .unsupportedVersion:
            return String(format: NSLocalizedString("SSH 握手失败：服务器的 SSH 版本不受支持（%@）", comment: ""), raw)
        case .invalidExchangeHashSignature:
            return String(format: NSLocalizedString("SSH 握手失败：服务器主机密钥签名校验未通过（%@）", comment: ""), raw)
        case .invalidHostKeyForKeyExchange:
            return String(format: NSLocalizedString("SSH 握手失败：服务器发送的主机密钥与协商的不一致（%@）", comment: ""), raw)
        case .tcpShutdown:
            return String(format: NSLocalizedString("连接被中断：TCP 在 SSH 会话结束前关闭（%@）", comment: ""), raw)
        case .creatingChannelAfterClosure:
            return String(format: NSLocalizedString("SSH 连接已关闭，无法再打开通道，请重试（%@）", comment: ""), raw)
        case .channelSetupRejected:
            return String(format: NSLocalizedString("服务器拒绝了通道请求（%@）", comment: ""), raw)
        case .protocolViolation:
            return String(format: NSLocalizedString("SSH 协议异常（%@）", comment: ""), raw)
        case .invalidPacketFormat, .invalidSSHMessage, .unknownPacketType:
            return String(format: NSLocalizedString("收到无法解析的 SSH 数据包（%@）", comment: ""), raw)
        default:
            return String(format: NSLocalizedString("SSH 协议错误（%@）", comment: ""), raw)
        }
    }
    if let e = error as? SFTPError {
        switch e {
        case .missingResponse:
            return String(localized: "SFTP 无响应：15 秒内没有收到服务器回复，可能是打开的 SFTP 句柄太多")
        case .connectionClosed:
            return String(localized: "SFTP 连接已关闭")
        case .errorStatus(let status):
            return String(format: NSLocalizedString("SFTP 操作被服务器拒绝（%@）", comment: ""), String(describing: status))
        case .unsupportedVersion(let v):
            return String(format: NSLocalizedString("SFTP 版本不受支持（%@）", comment: ""), String(describing: v))
        default:
            return String(format: NSLocalizedString("SFTP 错误（%@）", comment: ""), String(describing: e))
        }
    }
    if let e = error as? ChannelError {
        // 通道在使用中途被关闭（并发丢弃、对端关闭、网络抖动）。
        // 正常已被 withSFTP 的重试消化，走到这里说明重试也失败了。
        // case 以 swift-nio 2.81.0 源码实锤为准。
        switch e {
        case .ioOnClosedChannel, .alreadyClosed:
            return String(localized: "SFTP 通道已关闭，请重试")
        case .outputClosed, .inputClosed, .eof:
            return String(localized: "服务器关闭了 SFTP 通道，请重试")
        default:
            return String(format: NSLocalizedString("SFTP 通道错误（%@）", comment: ""), String(describing: e))
        }
    }
    return error.localizedDescription
}

/// 是否为算法协商失败。
/// NIOSSHError 的 diagnostics 是私有的，只能比对公开的 `type`；再加字符串兜底，
/// 防止 Citadel 在外层包了一层别的 Error 类型。
func isKeyExchangeNegotiationFailure(_ error: Error) -> Bool {
    if let e = error as? NIOSSHError, e.type == .keyExchangeNegotiationFailure { return true }
    return String(describing: error).contains("keyExchangeNegotiationFailure")
}

/// 主机密钥 TOFU 存储：pinKey（"host:port"）-> 主机密钥字节的 base64。单例，线程安全。
/// 用 host:port 而不是只用 host：同一主机不同端口可能是完全不同的服务器。
final class HostKeyPinStore: @unchecked Sendable {
    static let shared = HostKeyPinStore()

    private let lock = NSLock()
    private var pins: [String: String]
    private let defaultsKey = "opencoder.hostKeyPins"

    private init() {
        pins = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
    }

    static func pinKey(host: String, port: Int) -> String { "\(host):\(port)" }

    func pinned(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pins[key]
    }

    func pin(key: String, value: String) {
        lock.lock()
        defer { lock.unlock() }
        pins[key] = value
        UserDefaults.standard.set(pins, forKey: defaultsKey)
    }

    func forget(key: String) {
        lock.lock()
        defer { lock.unlock() }
        pins.removeValue(forKey: key)
        UserDefaults.standard.set(pins, forKey: defaultsKey)
    }
}

/// TOFU 主机密钥校验器：首次连接记录主机密钥，之后不一致则拒绝。
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let pinKey: String
    private let displayHost: String

    init(host: String, port: Int) {
        self.pinKey = HostKeyPinStore.pinKey(host: host, port: port)
        self.displayHost = "\(host):\(port)"
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        var buffer = ByteBufferAllocator().buffer(capacity: 512)
        let written = hostKey.write(to: &buffer)
        guard written > 0, let bytes = buffer.getBytes(at: 0, length: written) else {
            validationCompletePromise.fail(SSHManagerError.cannotSerializeHostKey)
            return
        }
        let fingerprint = Data(bytes).base64EncodedString()
        if let pinned = HostKeyPinStore.shared.pinned(forKey: pinKey) {
            if pinned == fingerprint {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHManagerError.hostKeyMismatch(host: displayHost))
            }
        } else {
            HostKeyPinStore.shared.pin(key: pinKey, value: fingerprint)
            validationCompletePromise.succeed(())
        }
    }
}

/// SSH / SFTP 连接管理：每个服务器复用一个 SSHClient 和一个 SFTP 通道。
actor SSHManager {
    static let shared = SSHManager()

    private var clients: [UUID: SSHClient] = [:]
    /// 每个服务器复用一个 SFTP 通道。
    /// 根因说明：之前每次 list/read/write 都调用 openSFTP() 开新通道却从不关闭，
    /// OpenSSH 默认 MaxSessions=10，进几次目录开满后服务器拒绝新通道，
    /// 报错 NIOSSHError.channelSetupRejected: Reason: 2 open failed。
    private var sftpClients: [UUID: SFTPClient] = [:]

    private init() {}

    // MARK: - SFTP 通道复用

    /// 取可用的 SFTP 通道：有缓存且通道仍存活则复用，否则重开。
    private func sftp(for server: ServerConfig) async throws -> SFTPClient {
        let client = try await client(for: server)
        if let cached = sftpClients[server.id], cached.isActive {
            return cached
        }
        // 旧通道已死（或从未创建）：丢弃并重开。
        // 注意：client(for:) 在 SSH 连接断开时已换新 client，旧 SFTP 通道
        // 此时 isActive 为 false，会走到这里重开，不会串到旧连接上。
        sftpClients.removeValue(forKey: server.id)
        let sftp = try await client.openSFTP()
        sftpClients[server.id] = sftp
        return sftp
    }

    private func dropSFTP(serverID: UUID) async {
        if let sftp = sftpClients.removeValue(forKey: serverID) {
            try? await sftp.close()
        }
    }

    // MARK: - SFTP 通道容错

    /// 通道已死的错误：并发 drop / 对端关闭 / 网络抖动导致通道不可用。
    /// 注意：ChannelError 的 case 以 swift-nio 源码为准（2.81.0 实锤），
    /// 不存在 remotePeerClosed / closedRemotely——凭记忆写那两个 case 会
    /// 直接编译失败，已按真实 case 修正。
    private func isDeadChannelError(_ error: Error) -> Bool {
        guard let e = error as? ChannelError else { return false }
        switch e {
        case .ioOnClosedChannel, .alreadyClosed, .outputClosed, .inputClosed, .eof:
            return true
        default:
            return false
        }
    }

    /// 在 SFTP 通道上执行操作；若通道在使用中途死亡，丢弃缓存通道、
    /// 重开后自动重试一次。
    ///
    /// 背景：SFTP 通道按服务器复用，但"关闭通道"（切工作区、删服务器）
    /// 与"使用通道"（列表/读写）不在同一个临界区里，`sftp(for:)` 的
    /// isActive check-then-use 存在 TOCTOU；对端也可能主动关闭空闲通道。
    /// 重试让 App 从这类竞态中自愈，而不是把 NIOCore.ChannelError 甩给用户。
    private func withSFTP<T>(
        server: ServerConfig,
        operation: (SFTPClient) async throws -> T
    ) async throws -> T {
        let sftpClient = try await sftp(for: server)
        do {
            return try await operation(sftpClient)
        } catch {
            guard isDeadChannelError(error) else { throw error }
            // 只丢弃"这次用的"旧通道：若并发中已有别人建好新通道并入缓存，
            // 用 identity 比较避免误杀。
            if sftpClients[server.id] === sftpClient {
                sftpClients.removeValue(forKey: server.id)
            }
            try? await sftpClient.close()
            let fresh = try await sftp(for: server)
            return try await operation(fresh)
        }
    }

    /// 只丢弃 SFTP 通道，不断开整条 SSH 连接。
    ///
    /// 终端 PTY 与 SFTP 共用 `clients[serverID]` 这一条连接：切工作区、
    /// 关文件夹时只须丢掉 SFTP 通道，连接留给终端会话继续用，
    /// 下次 SFTP 操作按需重开通道。整条连接只在编辑/删除服务器时才关闭。
    func dropSFTPChannel(serverID: UUID) async {
        await dropSFTP(serverID: serverID)
    }

    // MARK: - 连接

    func client(for server: ServerConfig) async throws -> SSHClient {
        if let existing = clients[server.id] {
            // 缓存的连接断开后不能再复用：channel 已死时 openSFTP 会抛
            // NIOSSHError.creatingChannelAfterClosure，必须丢弃重连。
            if existing.isConnected {
                return existing
            }
            clients.removeValue(forKey: server.id)
        }
        guard let password = KeychainStore.load(account: KeychainStore.passwordAccount(for: server.id)) else {
            throw SSHManagerError.missingPassword
        }
        let username = server.username
        var settings = SSHClientSettings(
            host: server.host,
            port: server.port,
            authenticationMethod: { .passwordBased(username: username, password: password) },
            hostKeyValidator: .custom(TOFUHostKeyValidator(host: server.host, port: server.port))
        )
        // 算法组装（不用 SSHAlgorithms.all，原因见下）。
        //
        // 1) 传输保护：fork 默认只有 AES-GCM；Citadel 的 .all 只补 aes128-ctr。
        //    这里再补上本 App 实现的 aes256-ctr / aes192-ctr（见 AESCTRCiphers.swift）。
        // 2) 密钥交换：沿用 .all 的 DH group14（兼容老服务器）。
        // 3) 主机密钥：**不用** .all 的旧式 ssh-rsa（SHA1，OpenSSH 8.8+ 已禁用）；
        //    改用本 App 实现的 RSA-SHA2（RFC 8332，见 RSASHA2HostKey.swift）。
        //    2026-09-26 真机探针实测：OpenSSH 10.0p2 只提供 rsa-sha2-256/512，
        //    不认旧 ssh-rsa，用 .all 的话主机密钥一项零交集直接握手失败。
        var sshAlgorithms = SSHAlgorithms()
        sshAlgorithms.transportProtectionSchemes = .add([
            AES256CTRTransportProtection.self,
            AES192CTRTransportProtection.self,
            AES128CTR.self,
        ])
        sshAlgorithms.keyExchangeAlgorithms = .add([
            DiffieHellmanGroup14Sha1.self,
            DiffieHellmanGroup14Sha256.self,
        ])
        sshAlgorithms.publicKeyAlgorihtms = .add([
            (RSASSHHostKey.self, RSASHA256Signature.self),
            (RSASHA256AdvertisedKey.self, RSASHA256Signature.self),
            (RSASHA512AdvertisedKey.self, RSASHA512Signature.self),
        ])
        settings.algorithms = sshAlgorithms
        do {
            let client = try await SSHClient.connect(to: settings)
            clients[server.id] = client
            return client
        } catch {
            if isKeyExchangeNegotiationFailure(error) {
                // 算法协商失败：自动抓服务器 KEXINIT，把双方清单摆出来，不再靠猜。
                let probe = await SSHKexProbe.probe(host: server.host, port: server.port)
                throw SSHManagerError.handshakeFailed(
                    host: server.host,
                    port: server.port,
                    probe: probe,
                    raw: String(describing: error)
                )
            }
            throw SSHManagerError.connectionFailed(
                stage: String(format: NSLocalizedString("连接 %@:%d", comment: ""), server.host, server.port),
                underlying: error
            )
        }
    }

    func disconnect(serverID: UUID) async {
        await dropSFTP(serverID: serverID)
        if let client = clients.removeValue(forKey: serverID) {
            try? await client.close()
        }
    }

    func disconnectAll() async {
        for serverID in Array(sftpClients.keys) {
            await dropSFTP(serverID: serverID)
        }
        let all = Array(clients.values)
        clients.removeAll()
        for client in all {
            try? await client.close()
        }
    }

    // MARK: - SFTP

    func listDirectory(server: ServerConfig, path: String) async throws -> [RemoteFileEntry] {
        do {
            return try await listDirectoryInner(server: server, path: path)
        } catch let e as SSHManagerError {
            throw e
        } catch {
            throw SSHManagerError.connectionFailed(stage: String(format: NSLocalizedString("读取目录 %@", comment: ""), path), underlying: error)
        }
    }

    private func listDirectoryInner(server: ServerConfig, path: String) async throws -> [RemoteFileEntry] {
        try await withSFTP(server: server) { sftp in
            // 解析为绝对路径，避免 "./" 前缀在后续读写中累积
            let basePath = try await sftp.getRealPath(atPath: path)
            let listing = try await sftp.listDirectory(atPath: basePath)
            var entries: [RemoteFileEntry] = []
            for name in listing {
                for component in name.components {
                    guard component.filename != ".", component.filename != ".." else { continue }
                    let mode = component.attributes.permissions ?? 0
                    let isDir = (mode & 0o170000) == 0o040000 || component.longname.hasPrefix("d")
                    let fullPath = basePath == "/" ? "/\(component.filename)" : "\(basePath)/\(component.filename)"
                    entries.append(RemoteFileEntry(
                        name: component.filename,
                        path: fullPath,
                        isDirectory: isDir,
                        size: component.attributes.size
                    ))
                }
            }
            return entries.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    func readFile(server: ServerConfig, path: String) async throws -> String {
        do {
            try await withSFTP(server: server) { sftp in
                var buffer = try await sftp.withFile(filePath: path, flags: .read) { file in
                    try await file.readAll()
                }
                return buffer.readString(length: buffer.readableBytes) ?? ""
            }
        } catch let e as SSHManagerError {
            throw e
        } catch {
            throw SSHManagerError.connectionFailed(stage: String(format: NSLocalizedString("读取文件 %@", comment: ""), path), underlying: error)
        }
    }

    func writeFile(server: ServerConfig, path: String, text: String) async throws {
        do {
            try await withSFTP(server: server) { sftp in
                var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
                buffer.writeString(text)
                let data = buffer
                try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
                    try await file.write(data, at: 0)
                }
            }
        } catch let e as SSHManagerError {
            throw e
        } catch {
            throw SSHManagerError.connectionFailed(stage: String(format: NSLocalizedString("保存文件 %@", comment: ""), path), underlying: error)
        }
    }

    // MARK: - SFTP 目录操作（供 RemoteFileSystem 用）

    /// 读文件全部字节（Data 版：调用方自己做二进制/大小检查）。
    func readFileData(server: ServerConfig, path: String) async throws -> Data {
        do {
            try await withSFTP(server: server) { sftp in
                var buffer = try await sftp.withFile(filePath: path, flags: .read) { file in
                    try await file.readAll()
                }
                return Data(buffer.readableBytesView)
            }
        } catch let e as SSHManagerError {
            throw e
        } catch {
            throw SSHManagerError.connectionFailed(stage: String(format: NSLocalizedString("读取文件 %@", comment: ""), path), underlying: error)
        }
    }

    /// 写文件全部字节（不存在则创建，存在则截断覆盖）。
    func writeFileData(server: ServerConfig, path: String, data: Data) async throws {
        do {
            try await withSFTP(server: server) { sftp in
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                let frozen = buffer
                try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
                    try await file.write(frozen, at: 0)
                }
            }
        } catch let e as SSHManagerError {
            throw e
        } catch {
            throw SSHManagerError.connectionFailed(stage: String(format: NSLocalizedString("保存文件 %@", comment: ""), path), underlying: error)
        }
    }

    func createDirectory(server: ServerConfig, path: String) async throws {
        do {
            try await withSFTP(server: server) { sftp in
                try await sftp.createDirectory(atPath: path)
            }
        } catch let e as SSHManagerError {
            throw e
        } catch {
            throw SSHManagerError.connectionFailed(stage: String(format: NSLocalizedString("新建文件夹 %@", comment: ""), path), underlying: error)
        }
    }

    /// 删除文件或目录（目录用 rmdir，要求为空；非空目录先由调用方确认）。
    func remove(server: ServerConfig, path: String, isDirectory: Bool) async throws {
        do {
            try await withSFTP(server: server) { sftp in
                if isDirectory {
                    try await sftp.rmdir(at: path)
                } else {
                    try await sftp.remove(at: path)
                }
            }
        } catch let e as SSHManagerError {
            throw e
        } catch {
            throw SSHManagerError.connectionFailed(stage: String(format: NSLocalizedString("删除 %@", comment: ""), path), underlying: error)
        }
    }

    /// 递归删除目录（rmdir 要求目录为空，先删内容）。
    func removeRecursive(server: ServerConfig, path: String) async throws {
        let entries = try await listDirectory(server: server, path: path)
        for entry in entries {
            if entry.isDirectory {
                try await removeRecursive(server: server, path: entry.path)
            } else {
                try await remove(server: server, path: entry.path, isDirectory: false)
            }
        }
        try await remove(server: server, path: path, isDirectory: true)
    }

    func rename(server: ServerConfig, oldPath: String, newPath: String) async throws {
        do {
            try await withSFTP(server: server) { sftp in
                try await sftp.rename(at: oldPath, to: newPath)
            }
        } catch let e as SSHManagerError {
            throw e
        } catch {
            throw SSHManagerError.connectionFailed(stage: String(format: NSLocalizedString("重命名 %@", comment: ""), oldPath), underlying: error)
        }
    }

    /// 解析远端路径为绝对路径（"." → 主目录）。
    func realPath(server: ServerConfig, path: String) async throws -> String {
        do {
            try await withSFTP(server: server) { sftp in
                try await sftp.getRealPath(atPath: path)
            }
        } catch let e as SSHManagerError {
            throw e
        } catch {
            throw SSHManagerError.connectionFailed(stage: String(format: NSLocalizedString("解析路径 %@", comment: ""), path), underlying: error)
        }
    }

    // MARK: - SSH 命令

    /// 执行一条非交互式命令，返回 stdout 文本。
    /// 注意：每条命令在独立 channel 中执行，无持久 shell（cd 等状态不保留）；
    /// 命令若向 stderr 输出或返回非零退出码，Citadel 会抛错。
    func runCommand(server: ServerConfig, command: String) async throws -> String {
        do {
            let client = try await client(for: server)
            var output = try await client.executeCommand(command)
            return output.readString(length: output.readableBytes) ?? ""
        } catch let e as SSHManagerError {
            throw e
        } catch {
            throw SSHManagerError.connectionFailed(stage: String(localized: "执行命令"), underlying: error)
        }
    }

    // MARK: - 交互式 PTY

    /// PTY 输入事件（UI → 远端）。全 Sendable，可跨 actor 传递。
    enum PTYInput: Sendable {
        /// 用户按键字节
        case bytes([UInt8])
        /// 终端尺寸变化
        case resize(cols: Int, rows: Int)
    }

    /// 运行交互式 PTY 会话（login shell），直到远端 shell 退出或抛错才返回。
    ///
    /// 并发隔离（Swift 6 region 隔离）：
    /// - `SSHClient` / `TTYOutput` / `TTYStdinWriter` / `ExecCommandOutput` 都不是
    ///   Sendable：全程只在本 actor 隔离域内创建、使用、销毁，绝不跨 actor，
    ///   因此 `client(for:)` 的返回值不需要 Sendable。
    /// - 与 UI 层只交换 Sendable 值：输入走 `AsyncStream<PTYInput>`，
    ///   输出走 `AsyncStream<[UInt8]>.Continuation`，
    ///   就绪信号走 `@Sendable` 闭包（只捕获 Sendable 的 continuation）。
    /// - `withPTY` 的 perform 闭包是非隔离的：`for try await` 直接跑在闭包体内，
    ///   `ExecCommandOutput` 转成 `[UInt8]` 后才交出去，不跨隔离域。
    /// - 输入转发子任务只捕获 `input` 流和装了 writer 的 `SendableBox`；
    ///   writer 本体是 NIO Channel 的轻量包装，write/changeSize 最终调用
    ///   `channel.writeAndFlush` / `triggerUserOutboundEvent`，NIO Channel 的
    ///   这两个方法是线程安全的，可在任意任务中调用（见 SendableBox 注释）。
    func runPTY(
        server: ServerConfig,
        cols: Int,
        rows: Int,
        input: AsyncStream<PTYInput>,
        output: AsyncStream<[UInt8]>.Continuation,
        onReady: @Sendable @escaping () -> Void
    ) async throws {
        let client = try await client(for: server)
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        // 会话是否曾经建好：只有"建好之后"的通道关闭才可能是 shell 自己退出；
        // 建好之前的失败一律是真连接失败。perform 闭包不是 @Sendable，
        // 捕获局部 var 合法；withPTY 只调用一次 perform，无并发写入。
        var sessionEstablished = false
        do {
            try await client.withPTY(request) { inbound, outbound in
                sessionEstablished = true
                // PTY 已建好，通知 UI 切 connected
                onReady()
                let writerBox = SendableBox(outbound)
                // 用户输入 → 远端。子任务只捕获 Sendable 值（input 流 + 盒子）。
                // 输出循环结束后 cancel；`for await` 不响应 cancel，真正的结束靠
                // UI 层 finish 输入流（stop() / 会话收尾必调），任务随即退出。
                let forwarder = Task {
                    for await event in input {
                        switch event {
                        case .bytes(let bytes):
                            guard !bytes.isEmpty else { continue }
                            var buffer = ByteBuffer()
                            buffer.writeBytes(bytes)
                            try? await writerBox.value.write(buffer)
                        case .resize(let cols, let rows):
                            try? await writerBox.value.changeSize(
                                cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                        }
                    }
                }
                defer { forwarder.cancel() }
                do {
                    for try await item in inbound {
                        let bytes: [UInt8]
                        switch item {
                        case .stdout(let buffer), .stderr(let buffer):
                            bytes = Array(buffer.readableBytesView)
                        }
                        if !bytes.isEmpty {
                            output.yield(bytes)
                        }
                }
            } catch {
                // 通道关闭或出错：shell 已退出，视为正常结束
            }
            output.finish()
        }
        } catch {
            // 用户敲 exit → shell 退出 → sshd 半关闭通道 → withPTY 尾部的
            // channel.close() 抛 ChannelError.inputClosed（真机实锤 code 6）。
            // 此时 SSH 主连接还活着（shell 退出不影响主连接），视为正常结束，
            // 直接返回；真掉线时主连接已死，照常抛错走"连接失败"。
            if sessionEstablished, isDeadChannelError(error), client.isConnected {
                return
            }
            throw error
        }
        // withPTY 正常返回但主连接已死：掉线导致的"假正常结束"——对端关闭通道时
        // Citadel 的输出流以 clean finish 收尾（handlerRemoved → .eof(nil)），
        // 不抛错。按连接失败处理，不能混成"shell 自己退出"。
        if !client.isConnected {
            throw SSHManagerError.sessionLost
        }
    }
}

/// 把非 Sendable 的值装进 Sendable 盒子，跨隔离域使用时必须在注释里写清安全理由。
///
/// 本文件唯一用途：装 `TTYStdinWriter` 给 runPTY 的输入转发子任务用。
/// 安全理由：`TTYStdinWriter` 内部只是 `Channel` 的轻量包装，无自身可变状态；
/// `write` / `changeSize` 最终调用 `Channel.writeAndFlush` /
/// `Channel.triggerUserOutboundEvent`，NIO 的 Channel 这两个方法是线程安全的，
/// 可在任意线程/任务调用。通道关闭后的写入由 `try?` 吞掉，不抛错。
private final class SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
