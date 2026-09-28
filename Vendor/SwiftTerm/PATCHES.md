# SwiftTerm 本地补丁

上游：https://github.com/migueldeicaza/SwiftTerm
版本：v1.20.0（2026-09-28 vendoring）
方式：`project.yml` 用 `path: Vendor/SwiftTerm` 引用本地源码，不再从 GitHub 拉取。

## 补丁列表

### 1. 终端快捷栏横屏左右留白（2026-09-28，用户需求）

文件：`Sources/SwiftTerm/iOS/iOSAccessoryView.swift`

需求：横屏时快捷栏左右各空出一键宽。

改动：
- `setupUI()`：横屏（`frame.width > frame.height`）时，重要按键宽度的分母
  `importantKeysCount + 2`（11→13 / 13→15）。按键宽度 = 可用宽 / 按键数，
  分母 +2 恰好空出左右各一键宽，无需压缩或位移。
- 新增实例变量 `landscapeSideMargin`：横屏时 = 单键宽（`max(aditionalSpaceForImportantKeys, minWidth)`），
  竖屏为 0。
- `layoutSubviews()`：左组起点 `x = 2 + sideMargin`，右组终点
  `right = frame.width - 2 - sideMargin`；`sideMargin` 只在横屏时取
  `landscapeSideMargin`。

原理：分母+2 后算出的单键宽变小，总占用 = 13×小键宽 + 2×小键宽 = 原可用宽，
左右各空出一键宽。竖屏分母不变，行为与上游一致。

注意：横屏判断必须用 `UIScreen.main.bounds`，不能用 accessory 自身 frame——
accessory 是细长条（竖屏 393×36），宽永远大于高，会误判。

注意2：`addOptional`（F1–F10）计算剩余空间时必须减去 `2 × landscapeSideMargin`。
留白是真占用宽度的，不减会多加 3–4 个 F 键，它们被挤到方向键底下，
键名尾数从 `←`/`↓` 后面露出来（2026-09-28 真机实锤横屏"3"、竖屏"1"）。

## 精简（2026-09-28，CodeEdit for iOS）

- `Package.swift`：SwiftTerm target 的 `exclude` 增加 `Mac/` 下 6 个纯 macOS 文件
 （`MacCaretView.swift`、`MacDebugView.swift`、`MacExtensions.swift`、
  `MacFindBarView.swift`、`MacLocalTerminalView.swift`、`MacTerminalView.swift`）。
  它们全是 `#if os(macOS)` 守卫，iOS 编译时本来就被跳过（实测二进制里零残留），
  exclude 只省 CI 编译时间，不影响包大小。
- `Mac/MacAccessibilityService.swift` 保留：无守卫的 15 行小空壳，被 iOS 的
  `iOSTerminalView.swift` 引用，删了编不过。
- 结论：8.4MB 的包大小与 vendoring 无关（v1.0 远程依赖时也是 8.43MB）；
  大头是 Runestone、Tree-sitter、swift-nio 等功能依赖，SwiftTerm 本体很小。
