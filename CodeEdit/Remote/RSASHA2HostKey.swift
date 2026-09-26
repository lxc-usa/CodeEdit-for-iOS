import Foundation
import NIO
import NIOSSH
import Security

/// RSA-SHA2 主机密钥支持（RFC 8332：rsa-sha2-256 / rsa-sha2-512）。
///
/// 背景（2026-09-26 真机探针实测）：服务器 OpenSSH 10.0p2 的 KEXINIT 主机密钥
/// 算法只有 `rsa-sha2-512, rsa-sha2-256`。Citadel 的 `SSHAlgorithms.all` 只注册了
/// 旧式 `ssh-rsa`（SHA1 签名，OpenSSH 8.8+ 默认已禁用），fork 本身完全没有
/// RSA-SHA2，导致主机密钥这一项零交集 → keyExchangeNegotiationFailure。
/// 注意 KEX / 加密 / MAC 当时都是有交集的，之前"加密算法缺失"的推断是错的，
/// 真正缺的是 RSA-SHA2 主机密钥算法。
///
/// RFC 8332 的关键点：「签名算法名」和「密钥类型名」是分离的 ——
/// KEXINIT 里广播的是签名算法名（rsa-sha2-256），而服务器发来的主机密钥 blob
/// 里的 key type 永远是 `ssh-rsa`（密钥格式没变）。fork 的架构把这两个名字绑在
/// 同一个 `publicKeyPrefix` 上，所以拆成两类类型：
///   - `RSASSHHostKey`（prefix "ssh-rsa"）：真正解析 blob + 验签；
///   - `RSASHA256AdvertisedKey` / `RSASHA512AdvertisedKey`：只为把签名算法名
///     送进 KEXINIT 广播清单（解析/验签实际走 RSASSHHostKey）。
/// 另外 fork 的 `SSHKeyExchangeStateMachine.handle(keyExchangeReply:)` 里有个
/// guard 强制要求「解析出的密钥类型 == 协商出的算法名」，对 RSA-SHA2 不成立，
/// 已在 Vendor/swift-nio-ssh 里打了最小补丁（见 PATCHES.md）。
///
/// 验签用 Security.framework 的 SecKey（RSA PKCS#1 v1.5 + SHA-256 / SHA-512），
/// 不引入新依赖。

enum RSAHostKeyError: Error {
    case malformedPublicKey
    case malformedSignature
}

// MARK: - 签名类型

/// rsa-sha2-256 签名：wire 上算法名之后就是一串原始 RSA 签名字节（string）。
public struct RSASHA256Signature: NIOSSHSignatureProtocol {
    public static let signaturePrefix = "rsa-sha2-256"
    public let rawRepresentation: Data

    public init(rawRepresentation: Data) {
        self.rawRepresentation = rawRepresentation
    }

    public func write(to buffer: inout ByteBuffer) -> Int {
        buffer.oc_writeSSHString(rawRepresentation)
    }

    public static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let data = buffer.oc_readSSHString(), !data.isEmpty else {
            throw RSAHostKeyError.malformedSignature
        }
        return Self(rawRepresentation: data)
    }
}

/// rsa-sha2-512 签名：同上，只是哈希不同。
public struct RSASHA512Signature: NIOSSHSignatureProtocol {
    public static let signaturePrefix = "rsa-sha2-512"
    public let rawRepresentation: Data

    public init(rawRepresentation: Data) {
        self.rawRepresentation = rawRepresentation
    }

    public func write(to buffer: inout ByteBuffer) -> Int {
        buffer.oc_writeSSHString(rawRepresentation)
    }

    public static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let data = buffer.oc_readSSHString(), !data.isEmpty else {
            throw RSAHostKeyError.malformedSignature
        }
        return Self(rawRepresentation: data)
    }
}

// MARK: - 主机密钥（解析 + 验签）

/// RSA 主机密钥：解析服务器发来的 `ssh-rsa` blob（mpint e, mpint n），
/// 并用 RSA-SHA2 验证 exchange hash 上的签名。
///
/// publicKeyPrefix 必须是 "ssh-rsa"：blob 里的 key type 就是这个名字，
/// NIOSSH 靠它把 blob 路由到本类型。KEXINIT 广播的签名算法名
///（rsa-sha2-256/512）由下面的 AdvertisedKey 类型负责。
public struct RSASSHHostKey: NIOSSHPublicKeyProtocol {
    public static let publicKeyPrefix = "ssh-rsa"

    /// 公钥指数 e（mpint 原始字节，原样保存以便写回）。
    public let exponent: Data
    /// 模数 n（mpint 原始字节，原样保存以便写回）。
    public let modulus: Data

    public init(exponent: Data, modulus: Data) {
        self.exponent = exponent
        self.modulus = modulus
    }

    public var rawRepresentation: Data { exponent + modulus }

    public func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        let sigBytes: Data
        let algorithm: SecKeyAlgorithm
        switch signature {
        case let s as RSASHA256Signature:
            sigBytes = s.rawRepresentation
            algorithm = .rsaSignatureMessagePKCS1v15SHA256
        case let s as RSASHA512Signature:
            sigBytes = s.rawRepresentation
            algorithm = .rsaSignatureMessagePKCS1v15SHA512
        default:
            // 旧式 ssh-rsa（SHA1）签名我们不支持：直接拒绝，不降级。
            return false
        }
        guard let key = RSASecKey.publicKey(modulus: modulus, exponent: exponent) else {
            return false
        }
        var error: Unmanaged<CFError>?
        return SecKeyVerifySignature(key, algorithm, Data(data) as CFData, sigBytes as CFData, &error)
    }

    public func write(to buffer: inout ByteBuffer) -> Int {
        // e / n 原样写回：SSH 里 mpint 和 string 的编码都是「长度 + 字节」，
        // 原样写回保证 exchange hash 的输入与服务器 blob 字节完全一致，
        // TOFU pin 的字节也保持稳定。
        var written = 0
        written += buffer.oc_writeSSHString(exponent)
        written += buffer.oc_writeSSHString(modulus)
        return written
    }

    public static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let eData = buffer.oc_readSSHString(),
              let nData = buffer.oc_readSSHString(),
              !eData.isEmpty, !nData.isEmpty else {
            throw RSAHostKeyError.malformedPublicKey
        }
        return Self(exponent: eData, modulus: nData)
    }
}

// MARK: - KEXINIT 广播类型

/// 只为把 "rsa-sha2-256" 送进 KEXINIT 主机密钥算法清单。
/// blob 解析与签名验证实际由 RSASSHHostKey 完成（blob 的 key type 是
/// "ssh-rsa"，NIOSSH 按名字路由不到这里）；这里的解析/验签为完整起见
/// 同样正确实现（复用 RSASSHHostKey），避免留下"调了就炸"的死代码。
public struct RSASHA256AdvertisedKey: NIOSSHPublicKeyProtocol {
    public static let publicKeyPrefix = "rsa-sha2-256"
    private let inner: RSASSHHostKey

    private init(inner: RSASSHHostKey) { self.inner = inner }

    public var rawRepresentation: Data { inner.rawRepresentation }

    public func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        inner.isValidSignature(signature, for: data)
    }

    public func write(to buffer: inout ByteBuffer) -> Int {
        inner.write(to: &buffer)
    }

    public static func read(from buffer: inout ByteBuffer) throws -> Self {
        Self(inner: try RSASSHHostKey.read(from: &buffer))
    }
}

/// 只为把 "rsa-sha2-512" 送进 KEXINIT 主机密钥算法清单，其余同上。
public struct RSASHA512AdvertisedKey: NIOSSHPublicKeyProtocol {
    public static let publicKeyPrefix = "rsa-sha2-512"
    private let inner: RSASSHHostKey

    private init(inner: RSASSHHostKey) { self.inner = inner }

    public var rawRepresentation: Data { inner.rawRepresentation }

    public func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        inner.isValidSignature(signature, for: data)
    }

    public func write(to buffer: inout ByteBuffer) -> Int {
        inner.write(to: &buffer)
    }

    public static func read(from buffer: inout ByteBuffer) throws -> Self {
        Self(inner: try RSASSHHostKey.read(from: &buffer))
    }
}

// MARK: - SSH wire 编解码（本文件私有）

// NIOSSH 与 Citadel 的同名 helper 都是 internal，App target 不可见，
// 这里自己实现。SSH "string" = uint32 大端长度 + 原始字节，
// 与两家实现的线格式字节一致（已对照双方源码）。
fileprivate extension ByteBuffer {
    @discardableResult
    mutating func oc_writeSSHString(_ data: Data) -> Int {
        let count = data.count
        writeInteger(UInt32(count))
        writeBytes(data)
        return 4 + count
    }

    mutating func oc_readSSHString() -> Data? {
        guard let length = readInteger(as: UInt32.self),
              let bytes = readBytes(length: Int(length)) else {
            return nil
        }
        return Data(bytes)
    }
}

// MARK: - SecKey 构造（X.509 SPKI）

/// 把 SSH 的 (e, n) 组装成 SecKey 可用的 RSA 公钥。
/// 注意：DER 组装全程使用 [UInt8] 数组、最后一次性转 Data，绝不对 Data 做
/// removeFirst/insert 等原地修改。
/// 2026-09-26 真机崩溃根因（openCoder-2026-09-26-130435.ips）：
/// iOS 26 的 Foundation 里，Data.removeFirst/insert 经
/// InlineSlice.replaceSubrange 时触发 EXC_BREAKPOINT（Swift precondition），
/// 发生在握手验签服务器 RSA 主机密钥的 derInteger 路径上。
private enum RSASecKey {
    static func publicKey(modulus n: Data, exponent e: Data) -> SecKey? {
        guard !n.isEmpty, !e.isEmpty else { return nil }
        let spki = Data(spkiBytes(modulus: Array(n), exponent: Array(e)))
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(spki as CFData, attrs as CFDictionary, &error) else {
            return nil
        }
        return key
    }

    private static func derLengthBytes(_ count: Int) -> [UInt8] {
        precondition(count >= 0)
        if count < 128 { return [UInt8(count)] }
        var len = count
        var bytes: [UInt8] = []
        while len > 0 {
            bytes.insert(UInt8(len & 0xFF), at: 0)
            len >>= 8
        }
        return [UInt8(0x80 | bytes.count)] + bytes
    }

    private static func derIntegerBytes(_ raw: [UInt8]) -> [UInt8] {
        // SSH mpint 本来就是大端补码，与 DER INTEGER 的字节规则一致；
        // 这里只做规范化：去掉多余前导零（至少保留 1 字节），
        // 正数高位为 1 时补 0x00。
        guard !raw.isEmpty else { return [0x02, 0x01, 0x00] }
        var start = 0
        while start + 1 < raw.count && raw[start] == 0x00 {
            start += 1
        }
        let needsPad = raw[start] & 0x80 != 0
        var out: [UInt8] = [0x02]
        out.append(contentsOf: derLengthBytes((raw.count - start) + (needsPad ? 1 : 0)))
        if needsPad { out.append(0x00) }
        out.append(contentsOf: raw[start...])
        return out
    }

    private static func derSequenceBytes(_ body: [UInt8]) -> [UInt8] {
        [0x30] + derLengthBytes(body.count) + body
    }

    private static func spkiBytes(modulus n: [UInt8], exponent e: [UInt8]) -> [UInt8] {
        // PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
        let pkcs1 = derSequenceBytes(derIntegerBytes(n) + derIntegerBytes(e))
        // AlgorithmIdentifier ::= SEQUENCE { OID rsaEncryption (1.2.840.113549.1.1.1), NULL }
        let oidRSA: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        let algId = derSequenceBytes(oidRSA + [0x05, 0x00])
        // BIT STRING 包裹 PKCS#1（首字节 0x00 表示无未用比特）
        let bitString = [0x03] + derLengthBytes(pkcs1.count + 1) + [0x00] + pkcs1
        return derSequenceBytes(algId + bitString)
    }
}
