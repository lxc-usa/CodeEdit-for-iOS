# CodeEdit for iOS

基于 [CodeEdit](https://github.com/CodeEditApp/CodeEdit)（macOS）打造的轻量级 iPhone / iPad 代码编辑器。

> CodeEdit macOS 版的核心编辑器基于 AppKit，无法直接编译到 iOS。本项目保留它的设计语言与主题体系，编辑器内核采用 iOS 原生的 [Runestone](https://github.com/simonbs/Runestone)（Tree-sitter 语法高亮）。

## 功能

- **文件管理**：浏览 App 文稿目录，新建 / 重命名 / 删除文件与文件夹，从"文件" App 导入，支持 iTunes 文件共享
- **代码编辑**：Tree-sitter 语法高亮（22 种语言：Swift、Python、JavaScript/TypeScript、C/C++、Java、Go、Rust、Ruby、PHP、HTML/CSS、JSON、YAML 等），行号、当前行高亮、括号自动补全
- **多标签页**：同时打开多个文件，自动保存（防抖 1.2s + 切后台保存）
- **CodeEdit 主题**：内置 Default / GitHub / Solarized（深色+浅色）6 套主题，直接解析 macOS 版 `.cetheme` 文件
- **移动端键盘栏**：符号快捷输入（括号、分号、Tab 等）
- **查找替换**：系统标准查找面板
- **中英双语**：中文 / English

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
- XcodeGen 项目管理

## 许可

本项目代码 MIT。Runestone、Tree-sitter 各语言解析器遵循各自许可；`.cetheme` 主题文件来自 CodeEdit（MIT）。
