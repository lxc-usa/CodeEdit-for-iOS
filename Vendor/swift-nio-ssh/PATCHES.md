# 本地补丁记录

上游：https://github.com/Wellz26/swift-nio-ssh @ 0.3.4（2026-09-26 时的最新）。

## 补丁 1：允许 RSA-SHA2 主机密钥（RFC 8332）

文件：`Sources/NIOSSH/Key Exchange/SSHKeyExchangeStateMachine.swift`
位置：`handle(keyExchangeReply:)`，client 分支的 guard。

### 为什么需要

SSH 握手里「主机密钥算法名」和「主机密钥 blob 类型」是两个概念。
RFC 8332（rsa-sha2-256 / rsa-sha2-512）只定义了*签名算法*：KEXINIT 里
广播的是 `rsa-sha2-256`，但服务器发来的主机密钥 blob 类型永远是 `ssh-rsa`。

上游的 guard 写成：

```swift
guard message.hostKey.keyPrefix.elementsEqual(negotiated.negotiatedHostKeyAlgorithm.utf8) else {
    throw NIOSSHError.invalidHostKeyForKeyExchange(...)
}
```

它假设「密钥类型 == 算法名」，对 ed25519 / ECDSA 成立，对 RSA-SHA2
不成立。于是即使 App 端完整实现了 RSA-SHA2（广播名、签名解析、验签），
握手也会在这里被毙掉，标准 API 没有任何绕行办法。

### 改了什么

协商出的算法名是 `rsa-sha2-256` / `rsa-sha2-512` 时，期望的密钥类型
改为 `ssh-rsa`；其他算法保持原逻辑不变。

```swift
case .client:
    // RFC 8332: rsa-sha2-256 / rsa-sha2-512 是签名算法名，
    // 主机密钥 blob 的类型仍是 ssh-rsa，两者不一致是合法的。
    let negotiatedAlgorithm = negotiated.negotiatedHostKeyAlgorithm.utf8
    let keyMatches: Bool
    if negotiatedAlgorithm.elementsEqual("rsa-sha2-256".utf8)
        || negotiatedAlgorithm.elementsEqual("rsa-sha2-512".utf8) {
        keyMatches = message.hostKey.keyPrefix.elementsEqual("ssh-rsa".utf8)
    } else {
        keyMatches = message.hostKey.keyPrefix.elementsEqual(negotiated.negotiatedHostKeyAlgorithm.utf8)
    }
    guard keyMatches else {
        throw NIOSSHError.invalidHostKeyForKeyExchange(expected: negotiated.negotiatedHostKeyAlgorithm,
                                                       got: message.hostKey.keyPrefix)
    }
```

### 安全说明

这个放宽只针对 RSA-SHA2（SHA-256 / SHA-512 签名），没有放宽旧式
`ssh-rsa`（SHA1）。服务器仍然必须出示与协商算法匹配的密钥类型，
只是匹配规则按 RFC 8332 做了正确的映射。
