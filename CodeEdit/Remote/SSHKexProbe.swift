import Foundation
import Network

/// SSH 算法探针：只做版本交换并读取服务器的 KEXINIT，不做任何加密握手、不认证。
///
/// 用途：握手报 `keyExchangeNegotiationFailure` 时自动抓取服务器的真实算法清单，
/// 把"猜服务器配了什么"变成"看服务器给了什么"。探针失败返回 nil，不影响主流程。
enum SSHKexProbe {
    struct Result {
        var banner: String = ""
        var keyExchange: [String] = []
        var hostKey: [String] = []
        var encryptionC2S: [String] = []
        var encryptionS2C: [String] = []
        var macC2S: [String] = []
        var macS2C: [String] = []

        var isEmpty: Bool { keyExchange.isEmpty && hostKey.isEmpty }
    }

    /// 本 App 在 KEXINIT 里实际广播的算法清单（与 SSHManager 配置保持一致，
    /// 改算法配置时同步改这里）。用于握手失败时与服务器清单对照。
    static let ourKeyExchange =
        "ecdh-sha2-nistp384, ecdh-sha2-nistp256, ecdh-sha2-nistp521, " +
        "curve25519-sha256, curve25519-sha256@libssh.org, " +
        "diffie-hellman-group14-sha1, diffie-hellman-group14-sha256"
    static let ourHostKey =
        "ssh-ed25519, ecdsa-sha2-nistp384, ecdsa-sha2-nistp256, ecdsa-sha2-nistp521, " +
        "ssh-rsa, rsa-sha2-256, rsa-sha2-512"
    static let ourEncryption =
        "aes256-gcm@openssh.com, aes128-gcm@openssh.com, " +
        "aes256-ctr, aes192-ctr, aes128-ctr"
    static let ourMac = "hmac-sha1, hmac-sha2-256, hmac-sha2-512"

    enum ProbeError: Error {
        case closed
        case malformed
        case badPort
    }

    /// 最多等待 `timeout` 秒；拿不到 KEXINIT 返回 nil。
    static func probe(host: String, port: Int, timeout: TimeInterval = 8) async -> Result? {
        await withCheckedContinuation { (cont: CheckedContinuation<Result?, Never>) in
            let state = ProbeState(cont)
            let queue = DispatchQueue(label: "one.lxc.opencoder.kexprobe")
            guard port > 0, port <= 65535,
                  let nwPort = NWEndpoint.Port(rawValue: UInt16(port))
            else { state.resume(with: nil); return }

            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            state.connection = conn
            // 看门狗：超时直接结束
            queue.asyncAfter(deadline: .now() + timeout) { state.resume(with: nil) }
            conn.stateUpdateHandler = { s in
                switch s {
                case .ready:
                    Task { await runSession(conn: conn, state: state) }
                case .failed, .cancelled:
                    state.resume(with: nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    // MARK: - 会话

    private static func runSession(conn: NWConnection, state: ProbeState) async {
        do {
            var reader = Reader(conn: conn)
            // 1. 读版本横幅（有些服务器先发多行文本，只认 SSH- 开头的行）
            var banner = ""
            for _ in 0..<5 {
                let line = try await reader.readLine()
                if line.hasPrefix("SSH-") { banner = line; break }
            }
            guard banner.hasPrefix("SSH-") else { state.resume(with: nil); return }

            // 2. 回发我们的版本行
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                conn.send(content: Data("SSH-2.0-openCoder-kexprobe\r\n".utf8),
                          completion: .contentProcessed { err in
                              if let err { c.resume(throwing: err) } else { c.resume() }
                          })
            }

            // 3. 读一个 binary packet（握手前无加密：4 字节长度 + 内容）
            let lenBytes = try await reader.readExactly(4)
            let packetLength = lenBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard packetLength >= 16, packetLength <= 35000 else { state.resume(with: nil); return }
            let packet = try await reader.readExactly(Int(packetLength))

            // 4. 解析 KEXINIT
            var result = try parseKexInit(packet)
            result.banner = banner
            state.resume(with: result.isEmpty ? nil : result)
        } catch {
            state.resume(with: nil)
        }
    }

    // MARK: - KEXINIT 解析（RFC 4253 §7.1）

    private static func parseKexInit(_ packet: Data) throws -> Result {
        var cursor = 0
        func readByte() throws -> UInt8 {
            guard cursor < packet.count else { throw ProbeError.malformed }
            defer { cursor += 1 }
            return packet[cursor]
        }
        func readBytes(_ n: Int) throws -> Data {
            guard n >= 0, cursor + n <= packet.count else { throw ProbeError.malformed }
            defer { cursor += n }
            return packet[cursor..<(cursor + n)]
        }
        func readNameList() throws -> [String] {
            let length = try readBytes(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let bytes = try readBytes(Int(length))
            guard let s = String(data: bytes, encoding: .utf8) else { throw ProbeError.malformed }
            return s.isEmpty ? [] : s.split(separator: ",").map(String.init)
        }

        let paddingLength = Int(try readByte())
        let payloadEnd = packet.count - paddingLength
        guard payloadEnd > cursor else { throw ProbeError.malformed }
        let messageType = try readByte()
        guard messageType == 20 else { throw ProbeError.malformed } // 20 = KEXINIT
        _ = try readBytes(16) // cookie

        var r = Result()
        r.keyExchange = try readNameList()
        r.hostKey = try readNameList()
        r.encryptionC2S = try readNameList()
        r.encryptionS2C = try readNameList()
        r.macC2S = try readNameList()
        r.macS2C = try readNameList()
        return r
    }

    // MARK: - 内部件

    /// 保证 continuation 只 resume 一次。
    private final class ProbeState: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private let cont: CheckedContinuation<Result?, Never>
        var connection: NWConnection?

        init(_ cont: CheckedContinuation<Result?, Never>) { self.cont = cont }

        func resume(with result: Result?) {
            lock.lock()
            guard !resumed else { lock.unlock(); return }
            resumed = true
            lock.unlock()
            connection?.cancel()
            cont.resume(returning: result)
        }
    }

    private struct Reader {
        let conn: NWConnection
        var buffer = Data()

        mutating func receiveChunk() async throws -> Data {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                    if let error { c.resume(throwing: error); return }
                    guard let data, !data.isEmpty else { c.resume(throwing: ProbeError.closed); return }
                    c.resume(returning: data)
                }
            }
        }

        mutating func readExactly(_ n: Int) async throws -> Data {
            while buffer.count < n {
                buffer.append(try await receiveChunk())
            }
            let out = buffer.prefix(n)
            buffer.removeFirst(n)
            return Data(out)
        }

        mutating func readLine() async throws -> String {
            while true {
                if let idx = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.prefix(upTo: idx)
                    buffer.removeFirst(idx + 1)
                    return String(data: line, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                buffer.append(try await receiveChunk())
            }
        }
    }
}
