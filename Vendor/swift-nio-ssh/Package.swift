// swift-tools-version:5.10
//
// 本地 vendoring 的 swift-nio-ssh（上游：Wellz26/swift-nio-ssh @ 0.3.4，
// 即 apple/swift-nio-ssh 的社区 fork）。
//
// Vendoring 原因：openCoder 需要 RSA-SHA2 主机密钥算法（RFC 8332，
// rsa-sha2-256 / rsa-sha2-512），而上游的 SSHKeyExchangeStateMachine 在
// handle(keyExchangeReply:) 里用 guard 强制要求「收到的主机密钥类型 ==
// 协商出的算法名」。RSA-SHA2 里这两者天然不一致（协商名 rsa-sha2-256，
// 密钥 blob 类型 ssh-rsa），标准 API 路径走不通，只能打补丁。
// 上游 0.3.4 在 2026-09-26 时没有这个支持。
//
// 本地补丁（PATCHES.md 有详细说明）：
//   1. Sources/NIOSSH/Key Exchange/SSHKeyExchangeStateMachine.swift
//      的 client 侧 guard 允许 rsa-sha2-* 协商配 ssh-rsa 密钥 blob。
//
// 同步上游时：用上游 0.3.4（或更新 tag）的 Sources/NIOSSH 整体替换，
// 再重新应用 PATCHES.md 里的补丁。

import PackageDescription

let package = Package(
    name: "swift-nio-ssh",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .watchOS(.v6),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "NIOSSH", targets: ["NIOSSH"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"4.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "NIOSSH",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Atomics", package: "swift-atomics"),
            ]
        ),
    ]
)
