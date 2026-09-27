import SwiftUI
import SwiftTerm

/// 交互式 SSH 终端：PTY + xterm 仿真，可直接交互。
///
/// - 打开即进入远端 login shell，cd/环境变量等状态保留，可 apt/yum 安装程序
/// - 支持 top/htop/vi 等全屏程序（ANSI 转义、备用屏幕、光标定位由 SwiftTerm 仿真）
/// - 键盘上方自带 Esc/Ctrl/方向键/Tab 快捷栏（SwiftTerm TerminalAccessory）
/// - 作为标签页显示在主界面编辑区；切到终端标签时自动聚焦（弹出终端键盘），
///   切走时让出焦点
/// - 会话生命周期与视图解耦：横竖屏切换、布局重建不会结束会话；
///   只有显式关闭标签（或删除服务器）才真正结束会话
/// - 字体/字号与代码编辑器共用同一套设置
@MainActor
struct TerminalView: View {
    /// 标签页：shell 退出时直接关闭的就是这个标签。
    let tab: TerminalTab
    /// 从 SFTP 页点终端图标进入时，打开后自动 cd 到的远端路径；nil 表示不 cd。
    /// 仅新会话生效；复用保持中的会话时不执行（保持"继续之前状态"的语义）。
    let initialPath: String?
    /// 是否为当前选中的标签；切标签时驱动键盘聚焦/让出。
    let isActive: Bool
    @ObservedObject var servers: ServerStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var workspace: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme

    /// 会话来自 TerminalSessionCache（按服务器保留），横竖屏切换等视图重建
    /// 不影响会话；只有显式关闭标签才结束（见 WorkspaceStore.closeTerminal）。
    @StateObject private var shell: InteractiveShell

    init(tab: TerminalTab, initialPath: String?, servers: ServerStore, settings: SettingsStore, workspace: WorkspaceStore, isActive: Bool = true) {
        self.tab = tab
        self.initialPath = initialPath
        self.isActive = isActive
        self.servers = servers
        self.settings = settings
        self.workspace = workspace
        _shell = StateObject(wrappedValue: TerminalSessionCache.shared.shell(for: tab.serverID))
    }

    var body: some View {
        Group {
            switch shell.state {
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在连接…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .connected:
                TerminalHostView(shell: shell, settings: settings, workspace: workspace, colorScheme: colorScheme, isActive: isActive)
            case .failed(let message):
                EmptyState(
                    icon: "wifi.exclamationmark",
                    title: "连接失败",
                    message: "\(message)",
                    actionTitle: "重试",
                    action: connect
                )
            case .ended:
                EmptyState(
                    icon: "terminal",
                    title: "会话已结束",
                    message: "远端 shell 已退出",
                    actionTitle: "重新连接",
                    action: connect
                )
            }
        }
        .navigationTitle(servers.server(id: tab.serverID)?.name ?? "SSH 终端")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: connect)
        .onChange(of: shell.state) { _, newState in
            // 远端 shell 自己退出（用户敲了 exit）：直接关闭当前标签，
            // 不展示"连接失败"。closeTerminal 幂等，重复调用无害。
            // 注意：重试路径（connect() 里 stop→start 背靠背）不会经过
            // .ended——旧任务的收尾被 generation 守卫拦下，所以这里不会
            // 误关正在重连的标签。
            if case .ended = newState {
                workspace.closeTerminal(tab)
            }
        }
        // 注意：这里故意没有 onDisappear。横竖屏切换时 ContentView 会在
        // compact/split 两种布局间重建整个编辑区，onDisappear 会被触发；
        // 若在此结束会话，旋转一次就掉一次连接（远端 shell 被写 exit 杀掉）。
        // 会话只在显式关闭标签时结束（WorkspaceStore.closeTerminal → discard）。
    }

    private func connect() {
        guard let server = servers.server(id: tab.serverID) else { return }
        // 会话还活着（旋转重建、切标签回来）：直接复用，不重开；
        // makeUIView 重建时会重新把 onData 挂到新视图，暂存的输出自动补上。
        if shell.isAlive { return }
        // 旧会话已死：先确保旧会话结束再开新会话。
        // stop() 是同步的，配合 generation 守卫，旧 task 的异步收尾不会污染新会话。
        shell.stop()
        shell.start(server: server, initialPath: initialPath)
    }
}

/// SwiftTerm.TerminalView 的子类：修复横竖屏切换后键盘快捷栏留白。
///
/// 根因（SwiftTerm v1.20.0 源码实锤）：TerminalAccessory 的
/// traitCollectionDidChange 里 setupUI() 被提前 return 掉了，只靠
/// bounds.didSet 重建；而 allowsSelfSizing 下键盘宿主缓存的尺寸可能与
/// 内部布局不一致，导致第一行键（esc/ctrl/方向键…）与系统键盘之间留白。
/// 这里在尺寸类型真的变化后，强制重建 accessory 并让键盘重新加载输入视图。
@MainActor
private final class RotationSafeTerminalView: SwiftTerm.TerminalView {
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        let old = previousTraitCollection
        let new = traitCollection
        guard old?.horizontalSizeClass != new.horizontalSizeClass ||
              old?.verticalSizeClass != new.verticalSizeClass else { return }
        // 等一帧，让旋转动画先更新 accessory 的 bounds，再按最终宽度重建
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let accessory = self.inputAccessoryView as? TerminalAccessory {
                accessory.setupUI()
                accessory.setNeedsLayout()
                accessory.layoutIfNeeded()
            }
            self.reloadInputViews()
        }
    }
}

/// SwiftTerm iOS TerminalView 的 SwiftUI 封装。
///
/// 注意：SwiftTerm 也有个 `TerminalView`（UIView），这里用 `SwiftTerm.TerminalView` 显式区分。
@MainActor
private struct TerminalHostView: UIViewRepresentable {
    @ObservedObject var shell: InteractiveShell
    var settings: SettingsStore
    @ObservedObject var workspace: WorkspaceStore
    var colorScheme: ColorScheme
    /// 当前标签是否被选中：选中时抢键盘焦点（弹出终端键盘），切走时让出。
    var isActive: Bool

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let tv = RotationSafeTerminalView(frame: .zero, font: terminalUIFont())
        applyAppearance(to: tv)
        tv.terminalDelegate = context.coordinator
        // Coordinator 是非隔离的（SwiftTerm 的 delegate 方法都是非隔离要求），
        // 只做转发；真正调 @MainActor 的 shell 的部分 hop 到 MainActor。
        // 外层闭包是非 Sendable 的，捕获 weak shell 合法；内层 Task 与 shell
        // 同为 MainActor 隔离，捕获合法（Swift 6 允许同隔离域捕获）。
        let onSend: ([UInt8]) -> Void = { [weak shell] bytes in
            Task { @MainActor in shell?.send(bytes) }
        }
        let onResize: (Int, Int) -> Void = { [weak shell] cols, rows in
            Task { @MainActor in shell?.resize(cols: cols, rows: rows) }
        }
        context.coordinator.onSend = onSend
        context.coordinator.onResize = onResize
        // 点终端任意处 = 重新获得输入意图：解除"隐藏键盘"抑制，弹回键盘。
        // 手势不吞事件（cancelsTouchesInView=false），不影响 SwiftTerm 自己的
        // 点选/滚动处理。
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = false
        tv.addGestureRecognizer(tap)
        context.coordinator.onTap = { [weak workspace] in
            Task { @MainActor in workspace?.isTerminalKeyboardSuppressed = false }
        }
        // 远端输出 → xterm 仿真器（InteractiveShell 保证主线程回调）
        shell.onData = { bytes in
            tv.feed(byteArray: ArraySlice(bytes))
        }
        // 打开即聚焦，可直接打字（标签页场景下由 updateUIView 按 isActive 管理）
        if isActive {
            DispatchQueue.main.async {
                tv.becomeFirstResponder()
            }
        }
        return tv
    }

    func updateUIView(_ tv: SwiftTerm.TerminalView, context: Context) {
        let want = terminalUIFont()
        if tv.font.pointSize != want.pointSize || tv.font.fontName != want.fontName {
            tv.font = want
        }
        applyAppearance(to: tv)
        // 标签切换时切换键盘：选中终端 → 弹出终端键盘（含 Esc/Ctrl 快捷栏）；
        // 切到文件标签 → 让出焦点，键盘收回（文件编辑器被点时再按需弹出）。
        // 用户点了"隐藏键盘"后抑制自动重弹（isTerminalKeyboardSuppressed），
        // 否则远端每来一次输出、每次 updateUIView 都会把键盘再顶出来。
        let wantKeyboard = isActive && !workspace.isTerminalKeyboardSuppressed
        if wantKeyboard {
            if !tv.isFirstResponder {
                DispatchQueue.main.async {
                    tv.becomeFirstResponder()
                }
            }
        } else if tv.isFirstResponder {
            tv.resignFirstResponder()
        }
    }

    private func terminalUIFont() -> UIFont {
        // 与代码编辑器共用同一套字体/字号设置
        settings.monoFont.uiFont(size: CGFloat(settings.fontSize))
    }

    private func applyAppearance(to tv: SwiftTerm.TerminalView) {
        let dark = colorScheme == .dark
        tv.nativeForegroundColor = dark ? .white : .black
        tv.nativeBackgroundColor = dark ? .black : .white
        tv.keyboardAppearance = dark ? .dark : .light
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// 非隔离：只为满足 SwiftTerm TerminalViewDelegate（其方法全是 nonisolated
    /// 要求），把事件经闭包转出去，不直接碰 @MainActor 的 shell。
    final class Coordinator: NSObject, TerminalViewDelegate {
        var onSend: (([UInt8]) -> Void)?
        var onResize: ((Int, Int) -> Void)?
        var onTap: (() -> Void)?

        /// 用户点终端视图：恢复输入意图（解除键盘抑制）。
        @objc func handleTap() {
            onTap?()
        }

        /// 用户按键 → SSH 通道。
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            onSend?(Array(data))
        }

        /// 视图尺寸变化 → 通知远端 PTY（top/vi 重排版靠它）。
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            onResize?(newCols, newRows)
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
