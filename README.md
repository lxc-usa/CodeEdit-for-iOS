# CodeEdit for iOS

基于 [CodeEdit](https://github.com/CodeEditApp/CodeEdit)（macOS）打造的 iPhone / iPad 代码编辑器，首个正式版本 v1.0。

> CodeEdit macOS 版的核心编辑器基于 AppKit，无法直接编译到 iOS。本项目保留它的设计语言与主题体系，编辑器内核采用 iOS 原生的 [Runestone](https://github.com/simonbs/Runestone)（Tree-sitter 语法高亮）。

<!-- ipa-release:start -->
## 📦 固定取包地址（永久有效）

**下载（链接永久不变）：** [CodeEdit-latest.ipa](https://raw.githubusercontent.com/lxc-usa/CodeEdit-for-iOS/main/dist/CodeEdit-latest.ipa)

| 项目 | 内容 |
|---|---|
| 当前版本 | v21.18（横屏 F 键残影修复） |
| 文件大小 | 8,431,627 字节（约 8.0 MB） |
| MD5 | `9d3ff43dc5dd96d6b2e908861d8cf593` |
| SHA256 | `586dc26d78a6db86711b96b930b34b30faaa81fc63474e3a79f13356ddbaba53` |
| Bundle ID | `one.lxc.codeedit` |
| 系统要求 | iOS 17.0+ |

每次有新包，更新的都是上面这一个地址，不再发临时链接。

### 安装步骤（未签名 IPA）
1. 点上面的固定地址下载 IPA；
2. 用爱思助手 / Sideloadly / AltStore 等工具自行签名后安装到 iPhone/iPad；
3. 安装前可核对文件大小与校验值，确认下载完整。

> 若本节暂时没有可下载的包，会明确写"暂无可下载版本"，不会留空。
<!-- ipa-release:end -->

## 功能

### 代码编辑
- **Tree-sitter 语法高亮**：22 种语言（Swift、Python、JavaScript/TypeScript、C/C++、Java、Go、Rust、Ruby、PHP、HTML/CSS、JSON、YAML 等）
- **CodeEdit 主题**：内置 Default / GitHub / Solarized（深色+浅色）6 套主题，直接解析 macOS 版 `.cetheme` 文件
- 行号、当前行高亮、括号自动补全
- **符号快捷栏**：常用符号一键输入，横屏 15 键一屏
- 查找替换（系统标准查找面板）
- 多标签页，自动保存（防抖 1.2s + 切后台保存）
- 跟随系统深浅色

### 远程终端
- **SSH 连接**：连接远程服务器，完整终端仿真（SwiftTerm）
- **会话保持**：转屏、切换标签、开关文件夹都不掉线，只有手动关闭才结束
- **三段式键盘**：正常 → 半高 → 隐藏，隐藏后点终端恢复
- 终端与编辑器共用字体字号设置

### 远程文件
- **SFTP 文件浏览**：连接服务器后逐层浏览远程目录
- **多远程文件夹**：同时打开多个，关闭其中一个不影响其他
- 直接在源位置编辑，不复制不导入

### 界面
- **顶栏自动显隐**：上滑隐藏、下滑显示，最大化可视区（设置 → 界面 可关闭）
- 顶部标题显示当前工作区名（无工作区时显示文件名/服务器名）
- 中英双语

## 下载

[v1.0 Release](https://github.com/lxc-usa/CodeEdit-for-iOS/releases/tag/v1.0) 提供未签名 IPA，需自行签名后安装（Bundle ID `one.lxc.codeedit`，需 iOS 17+）。

## 构建

需要 Xcode 16+（macOS）：

```bash
brew install xcodegen
xcodegen generate
open CodeEdit.xcodeproj
```

GitHub Actions 会在 `main` 有推送时自动构建未签名 IPA（Artifacts 下载）。

## 技术栈

- SwiftUI + Runestone 0.5.2（编辑器）
- simonbs/TreeSitterLanguages 0.1.10（22 种语言的 Tree-sitter 解析器）
- SwiftTerm（终端仿真）
- swift-nio-ssh（SSH，vendored）
- XcodeGen 项目管理

## 许可

本项目代码 MIT。Runestone、Tree-sitter 各语言解析器、SwiftTerm 遵循各自许可；`.cetheme` 主题文件来自 CodeEdit（MIT）。
