import SwiftUI
import SwiftTerm

/// 交互式 SSH 终端：PTY + xterm 仿真，可直接交互。
///
/// - 打开即进入远端 login shell，cd/环境变量等状态保留，可 apt/yum 安装程序
/// - 支持 top/htop/vi 等全屏程序（ANSI 转义、备用屏幕、光标定位由 SwiftTerm 仿真）
/// - 键盘上方自带 Esc/Ctrl/方向键/Tab 快捷栏（SwiftTerm TerminalAccessory）
/// - 离开页面时会话结束（发送 exit）
@MainActor
struct TerminalView: View {
    let serverID: UUID
    /// 从 SFTP 页点终端图标进入时，打开后自动 cd 到的远端路径；nil 表示不 cd。
    /// 仅新会话生效；复用保持中的会话时不执行（保持"继续之前状态"的语义）。
    let initialPath: String?
    @ObservedObject var servers: ServerStore
    @ObservedObject var settings: SettingsStore
    @Environment(\.colorScheme) private var colorScheme

    /// 会话来自 TerminalSessionCache（按服务器保留），"会话保持"打开时可复用。
    @StateObject private var shell: InteractiveShell

    init(serverID: UUID, initialPath: String?, servers: ServerStore, settings: SettingsStore) {
        self.serverID = serverID
        self.initialPath = initialPath
        self.servers = servers
        self.settings = settings
        _shell = StateObject(wrappedValue: TerminalSessionCache.shared.shell(for: serverID))
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
                TerminalHostView(shell: shell, settings: settings, colorScheme: colorScheme)
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
        .navigationTitle(servers.server(id: serverID)?.name ?? "SSH 终端")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: connect)
        .onDisappear {
            if settings.terminalResumeSession {
                // 会话保持：只与视图解绑，会话在后台继续（输出暂存，重进时补上）
                shell.detach()
            } else {
                shell.stop()
            }
        }
    }

    private func connect() {
        guard let server = servers.server(id: serverID) else { return }
        // 会话保持且上次会话还活着：直接复用，不重开；
        // makeUIView 重建时会重新把 onData 挂到新视图。
        if settings.terminalResumeSession && shell.isAlive { return }
        // 非保持模式（或旧会话已死）：先确保旧会话结束再开新会话。
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
    var colorScheme: ColorScheme

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
        // 远端输出 → xterm 仿真器（InteractiveShell 保证主线程回调）
        shell.onData = { bytes in
            tv.feed(byteArray: ArraySlice(bytes))
        }
        // 打开即聚焦，可直接打字
        DispatchQueue.main.async {
            tv.becomeFirstResponder()
        }
        return tv
    }

    func updateUIView(_ tv: SwiftTerm.TerminalView, context: Context) {
        let want = terminalUIFont()
        if tv.font.pointSize != want.pointSize || tv.font.fontName != want.fontName {
            tv.font = want
        }
        applyAppearance(to: tv)
    }

    private func terminalUIFont() -> UIFont {
        settings.monoFont.uiFont(size: CGFloat(settings.monoFontSize))
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
