import CommonCrypto
import Foundation
import NIO
import NIOSSH

/// AES-CTR 系列传输保护（CommonCrypto 实现）。
///
/// 背景：依赖的 swift-nio-ssh fork（Wellz26 0.3.4）默认只带 AES-GCM 加密套件，
/// Citadel 的 `SSHAlgorithms.all` 只补了 `aes128-ctr`。实测某些服务器（如加固过的
/// sshd）在加密算法清单里既没有 GCM 也没有 `aes128-ctr`，握手会报
/// `NIOSSHError.keyExchangeNegotiationFailure`。这里补上 `aes256-ctr` 与
/// `aes192-ctr`，实现逻辑与 Citadel 的 `AES128CTR` 对齐（CTR 模式 + HMAC）。
enum AESCTRTransportError: Error {
    case invalidMac(String?)
    case cryptoFailure(status: CCCryptorStatus)
    case badPacket
}

/// 通用 AES-CTR 实现，子类通过 `keyBits` 区分 128/192/256。
class AESCTRTransportProtection: NIOSSHTransportProtection {
    /// 子类覆盖：128 / 192 / 256
    class var keyBits: Int { 128 }

    class var cipherName: String { "aes\(Self.keyBits)-ctr" }
    class var macNames: [String] { ["hmac-sha1", "hmac-sha2-256", "hmac-sha2-512"] }
    class var cipherBlockSize: Int { 16 }

    class func keySizes(forMac mac: String?) throws -> ExpectedKeySizes {
        let macKeySize: Int
        switch mac {
        case "hmac-sha1": macKeySize = Int(CC_SHA1_DIGEST_LENGTH)
        case "hmac-sha2-256": macKeySize = Int(CC_SHA256_DIGEST_LENGTH)
        case "hmac-sha2-512": macKeySize = Int(CC_SHA512_DIGEST_LENGTH)
        default: throw AESCTRTransportError.invalidMac(mac)
        }
        return ExpectedKeySizes(ivSize: 16, encryptionKeySize: Self.keyBits / 8, macKeySize: macKeySize)
    }

    var macBytes: Int { keySizes.macKeySize }

    private enum MacKind { case sha1, sha256, sha512 }

    private let macKind: MacKind
    private let keySizes: ExpectedKeySizes
    private var keys: NIOSSHSessionKeys
    private var encryptor: CCCryptorRef?
    private var decryptor: CCCryptorRef?

    required init(initialKeys: NIOSSHSessionKeys, mac: String?) throws {
        let ks = try Self.keySizes(forMac: mac)
        switch mac {
        case "hmac-sha1": macKind = .sha1
        case "hmac-sha2-256": macKind = .sha256
        case "hmac-sha2-512": macKind = .sha512
        default: throw AESCTRTransportError.invalidMac(mac)
        }
        self.keySizes = ks
        self.keys = initialKeys
        try setupCryptors(keys: initialKeys)
    }

    private func setupCryptors(keys: NIOSSHSessionKeys) throws {
        let keyLen = Self.keyBits / 8
        guard keys.outboundEncryptionKey.bitCount == keyLen * 8,
              keys.inboundEncryptionKey.bitCount == keyLen * 8,
              keys.initialOutboundIV.count == 16,
              keys.initialInboundIV.count == 16
        else { throw AESCTRTransportError.badPacket }

        if let e = encryptor { CCCryptorRelease(e); encryptor = nil }
        if let d = decryptor { CCCryptorRelease(d); decryptor = nil }

        let outKey = keys.outboundEncryptionKey.withUnsafeBytes { Array($0) }
        let inKey = keys.inboundEncryptionKey.withUnsafeBytes { Array($0) }
        encryptor = try makeCryptor(key: outKey, iv: keys.initialOutboundIV)
        decryptor = try makeCryptor(key: inKey, iv: keys.initialInboundIV)
    }

    /// CTR 加解密共用一个操作（kCCEncrypt）：CTR 是对称的。
    /// cryptor 在整个连接生命周期内保持，计数器状态连续。
    private func makeCryptor(key: [UInt8], iv: [UInt8]) throws -> CCCryptorRef {
        var ref: CCCryptorRef?
        let status = key.withUnsafeBytes { kp in
            iv.withUnsafeBytes { ivp in
                guard let kpBase = kp.baseAddress, let ivpBase = ivp.baseAddress else {
                    return CCCryptorStatus(kCCParamError)
                }
                return CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivpBase, kpBase, key.count,
                    nil, 0, 0, 0,
                    &ref)
            }
        }
        guard status == kCCSuccess, let ref else {
            throw AESCTRTransportError.cryptoFailure(status: status)
        }
        return ref
    }

    private func crypt(_ cryptor: CCCryptorRef, data: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count)
        let outCount = out.count // withUnsafeMutableBytes 期间不能再访问 out（独占访问规则）
        var moved = 0
        let status = data.withUnsafeBytes { inp in
            out.withUnsafeMutableBytes { outp in
                CCCryptorUpdate(cryptor,
                                inp.baseAddress, data.count,
                                outp.baseAddress, outCount,
                                &moved)
            }
        }
        guard status == kCCSuccess, moved == outCount else {
            throw AESCTRTransportError.cryptoFailure(status: status)
        }
        return out
    }

    func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        self.keys = newKeys
        try setupCryptors(keys: newKeys)
    }

    func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        guard source.readableBytes >= Self.cipherBlockSize,
              let d = decryptor,
              let block = source.getBytes(at: source.readerIndex, length: Self.cipherBlockSize)
        else { throw AESCTRTransportError.badPacket }
        // 原地解密前 16 字节（含包长度）；计数器状态由 cryptor 保持，
        // decryptAndVerifyRemainingPacket 会用同一个 cryptor 继续解密剩余部分。
        let plain = try crypt(d, data: block)
        source.setBytes(plain, at: source.readerIndex)
    }

    func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer {
        guard let d = decryptor,
              var plaintext = source.readBytes(length: Self.cipherBlockSize),
              let ciphertext = source.readBytes(length: source.readableBytes - keySizes.macKeySize),
              let macHash = source.readBytes(length: keySizes.macKeySize),
              ciphertext.count % Self.cipherBlockSize == 0
        else { throw AESCTRTransportError.badPacket }

        if !ciphertext.isEmpty {
            plaintext += try crypt(d, data: ciphertext)
        }
        guard plaintext.count % Self.cipherBlockSize == 0 else {
            throw AESCTRTransportError.badPacket
        }

        var macInput = withUnsafeBytes(of: sequenceNumber.bigEndian) { Array($0) }
        macInput += plaintext
        let expect = hmac(data: macInput, inbound: true)
        guard expect == macHash else { throw AESCTRTransportError.invalidMac("mismatch") }

        plaintext.removeFirst(4) // packet_length
        let paddingLength = Int(plaintext.removeFirst()) // padding_length
        guard paddingLength < plaintext.count else { throw AESCTRTransportError.badPacket }
        plaintext.removeLast(paddingLength)
        return ByteBuffer(bytes: plaintext)
    }

    func encryptPacket(_ packet: NIOSSHEncryptablePayload,
                       to outboundBuffer: inout ByteBuffer,
                       sequenceNumber: UInt32) throws {
        guard let e = encryptor else { throw AESCTRTransportError.badPacket }

        let packetLengthIndex = outboundBuffer.writerIndex
        let packetLengthLength = MemoryLayout<UInt32>.size
        let packetPaddingIndex = outboundBuffer.writerIndex + packetLengthLength
        let packetPaddingLength = MemoryLayout<UInt8>.size
        outboundBuffer.moveWriterIndex(forwardBy: packetLengthLength + packetPaddingLength)

        let payloadBytes = outboundBuffer.writeEncryptablePayload(packet)

        // padding 规则：(padding_length + 内容 + padding) 为块大小整数倍，且 padding >= 4。
        // 注意 CTR 下包长度字段是被加密的，这里 padding 计算排除长度字段本身。
        let headerLength = packetLengthLength + packetPaddingLength
        let writtenBytes = headerLength + payloadBytes
        var paddingLength = Self.cipherBlockSize - (writtenBytes % Self.cipherBlockSize)
        if paddingLength < 4 { paddingLength += Self.cipherBlockSize }
        if headerLength + payloadBytes + paddingLength < Self.cipherBlockSize {
            paddingLength = Self.cipherBlockSize - headerLength - payloadBytes
        }

        outboundBuffer.writeSSHPaddingBytes(count: paddingLength)
        let encryptedBufferSize = headerLength + payloadBytes + paddingLength
        precondition(encryptedBufferSize % Self.cipherBlockSize == 0)

        outboundBuffer.setInteger(UInt32(encryptedBufferSize - packetLengthLength), at: packetLengthIndex)
        outboundBuffer.setInteger(UInt8(paddingLength), at: packetPaddingIndex)

        let plaintext = outboundBuffer.getBytes(at: packetLengthIndex, length: encryptedBufferSize)!
        var macInput = withUnsafeBytes(of: sequenceNumber.bigEndian) { Array($0) }
        macInput += plaintext
        let macHash = hmac(data: macInput, inbound: false)

        let ciphertext = try crypt(e, data: plaintext)
        outboundBuffer.setBytes(ciphertext, at: packetLengthIndex)
        outboundBuffer.writeBytes(macHash)
    }

    // MARK: - HMAC

    private func macKeyBytes(inbound: Bool) -> [UInt8] {
        let k = inbound ? keys.inboundMACKey : keys.outboundMACKey
        return k.withUnsafeBytes { Array($0) }
    }

    private func hmac(data: [UInt8], inbound: Bool) -> [UInt8] {
        let key = macKeyBytes(inbound: inbound)
        let algo: CCHmacAlgorithm
        let len: Int
        switch macKind {
        case .sha1: algo = CCHmacAlgorithm(kCCHmacAlgSHA1); len = Int(CC_SHA1_DIGEST_LENGTH)
        case .sha256: algo = CCHmacAlgorithm(kCCHmacAlgSHA256); len = Int(CC_SHA256_DIGEST_LENGTH)
        case .sha512: algo = CCHmacAlgorithm(kCCHmacAlgSHA512); len = Int(CC_SHA512_DIGEST_LENGTH)
        }
        var out = [UInt8](repeating: 0, count: len)
        key.withUnsafeBytes { kp in
            data.withUnsafeBytes { dp in
                CCHmac(algo, kp.baseAddress, key.count, dp.baseAddress, data.count, &out)
            }
        }
        return out
    }

    deinit {
        if let e = encryptor { CCCryptorRelease(e) }
        if let d = decryptor { CCCryptorRelease(d) }
    }
}

/// aes256-ctr
final class AES256CTRTransportProtection: AESCTRTransportProtection {
    override class var keyBits: Int { 256 }
    override class var cipherName: String { "aes256-ctr" }
}

/// aes192-ctr
final class AES192CTRTransportProtection: AESCTRTransportProtection {
    override class var keyBits: Int { 192 }
    override class var cipherName: String { "aes192-ctr" }
}
