import SwiftUI
import SwiftTerm

/// 交互式 SSH 终端：PTY + xterm 仿真，可直接交互。
///
/// - 打开即进入远端 login shell，cd/环境变量等状态保留，可 apt/yum 安装程序
/// - 支持 top/htop/vi 等全屏程序（ANSI 转义、备用屏幕、光标定位由 SwiftTerm 仿真）
/// - 键盘上方自带 Esc/Ctrl/方向键/Tab 快捷栏（SwiftTerm TerminalAccessory），
///   其中的键盘按钮为三段式：正常（系统键盘）→ 半高（紧凑键盘）→ 隐藏 → 点终端回到正常
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

/// SwiftTerm.TerminalView 的子类：修复横竖屏切换后键盘快捷栏留白，
/// 并把 SwiftTerm 原生的键盘两段切换（正常↔半高）接管为三段式：
/// 正常（系统键盘）→ 半高（SwiftTerm 自绘紧凑键盘）→ 隐藏（收起并抑制重弹）→ 正常…
///
/// 根因（SwiftTerm v1.20.0 源码实锤）：TerminalAccessory 的
/// traitCollectionDidChange 里 setupUI() 被提前 return 掉了，只靠
/// bounds.didSet 重建；而 allowsSelfSizing 下键盘宿主缓存的尺寸可能与
/// 内部布局不一致，导致第一行键（esc/ctrl/方向键…）与系统键盘之间留白。
/// 这里在尺寸类型真的变化后，强制重建 accessory 并让键盘重新加载输入视图。
///
/// 三段式实现说明：TerminalAccessory 是 public 非 open，无法继承重写；
/// KeyboardView 也是内部类，外部建不出来。所以找到 accessory 上那个
/// action 为 toggleInputKeyboard 的原生键盘按钮，把它的 target 换成我们的
/// Coordinator（接管点击），"正常→半高"这半件事仍用 perform 调回 SwiftTerm
/// 自己的实现来做。setupUI()（旋转时）会重建按钮，用实例标识做幂等自愈。
@MainActor
private final class RotationSafeTerminalView: SwiftTerm.TerminalView {
    /// 终端键盘三段式当前所处阶段。
    enum KeyboardStage {
        case normal, half, hidden
    }
    var keyboardStage: KeyboardStage = .normal
    /// 三段式按钮的点击处理（Coordinator）：旋转重建按钮后需要它重新接管。
    weak var stageCoordinator: TerminalHostView.Coordinator?
    /// 已被我们接管的按钮实例：setupUI 重建后实例变化，触发重新接管。
    private weak var retargetedButton: UIButton?

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
            // setupUI 重建了按钮：重新接管三段式（已在主线程，直接 assume）
            MainActor.assumeIsolated {
                self.ensureKeyboardStageRetarget()
            }
        }
    }

    /// 键盘按钮三段式循环：正常 → 半高 → 隐藏 →（点终端任意处回到）正常。
    /// 注意隐藏后整个键盘（含快捷栏和这个按钮）都会收起，回来靠点终端视图
    /// （解除抑制、弹回键盘，见 updateUIView 的阶段同步）。
    func cycleKeyboardStage(button: UIButton, workspace: WorkspaceStore) {
        switch keyboardStage {
        case .normal:
            // 半高：委托 SwiftTerm 自己的 toggle 切出自绘紧凑键盘，成功才进 half。
            if invokeSwiftTermKeyboardToggle(sender: button) {
                keyboardStage = .half
            }
        case .half:
            // 隐藏：先把 inputView 复位（下次回到正常时是系统键盘），
            // 再走与导航栏"隐藏键盘"同一套抑制逻辑，避免远端输出把键盘顶回来。
            keyboardStage = .hidden
            inputView = nil
            workspace.isTerminalKeyboardSuppressed = true
            resignFirstResponder()
        case .hidden:
            keyboardStage = .normal
            workspace.isTerminalKeyboardSuppressed = false
            inputView = nil
            if !isFirstResponder {
                becomeFirstResponder()
            }
        }
        updateKeyboardStageIcon(button)
    }

    /// 按当前阶段刷新键盘按钮图标。
    func updateKeyboardStageIcon(_ button: UIButton) {
        let name: String
        switch keyboardStage {
        case .normal:
            name = "keyboard"
        case .half:
            // 半高时点按是"收起"：向下箭头
            name = "keyboard.chevron.compact.down"
        case .hidden:
            // 隐藏时按钮随键盘一起收起；防御性设置（点按即"叫回键盘"：向上箭头）
            name = "keyboard.chevron.compact.up"
        }
        button.setImage(UIImage(systemName: name), for: .normal)
    }

    /// 确保 SwiftTerm 的原生键盘按钮被我们接管（幂等；重建后自动重新接管）。
    /// 找不到按钮（SwiftTerm 改版）时静默放弃，原生两段切换继续可用。
    func ensureKeyboardStageRetarget() {
        guard let coordinator = stageCoordinator,
              let accessory = inputAccessoryView else { return }
        guard let button = Self.swiftTermKeyboardButton(in: accessory) else { return }
        if retargetedButton === button {
            // 已接管：只刷新图标（阶段可能被外部手势同步，如点终端回来）
            updateKeyboardStageIcon(button)
            return
        }
        let sel = NSSelectorFromString("toggleInputKeyboard:")
        button.removeTarget(accessory, action: sel, for: .touchDown)
        button.addTarget(coordinator, action: #selector(TerminalHostView.Coordinator.keyboardStageTapped(_:)), for: .touchDown)
        retargetedButton = button
        updateKeyboardStageIcon(button)
    }

    /// 在 accessory 层级里找 SwiftTerm 的原生键盘按钮：
    /// 以 accessory 为 target、action 为 toggleInputKeyboard: 的那个 UIButton。
    /// 注意 SwiftTerm 用的是 .touchDown（按下即触发），不是 .touchUpInside。
    private static func swiftTermKeyboardButton(in accessory: UIView) -> UIButton? {
        var stack: [UIView] = [accessory]
        while let view = stack.popLast() {
            if let button = view as? UIButton {
                let aimedAtAccessory = button.allTargets.contains {
                    ($0.base as AnyObject) === (accessory as AnyObject)
                }
                let actions = button.actions(forTarget: accessory, forControlEvent: .touchDown) ?? []
                if aimedAtAccessory && actions.contains("toggleInputKeyboard:") {
                    return button
                }
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// 直接调用 SwiftTerm TerminalAccessory 的 toggleInputKeyboard:，
    /// 在"正常"和"半高"之间切换（它内部负责创建 KeyboardView）。
    /// - Returns: 是否成功调用（accessory 不存在或改版时返回 false）。
    private func invokeSwiftTermKeyboardToggle(sender: UIButton) -> Bool {
        guard let accessory = inputAccessoryView else { return false }
        let sel = NSSelectorFromString("toggleInputKeyboard:")
        let target = accessory as NSObject
        guard target.responds(to: sel) else { return false }
        UIView.performWithoutAnimation {
            _ = target.perform(sel, with: sender)
        }
        return true
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
        // 三段式键盘按钮：把 SwiftTerm 原生按钮的点击接管为 正常→半高→隐藏 循环。
        // Coordinator 非隔离，只做转发；真正的状态机在 @MainActor 的 view 上。
        tv.stageCoordinator = context.coordinator
        context.coordinator.onKeyboardStageTap = { [weak tv, weak workspace] button in
            Task { @MainActor in
                guard let tv, let workspace else { return }
                tv.cycleKeyboardStage(button: button, workspace: workspace)
            }
        }
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
        // 三段式阶段同步：外部手势（点终端任意处解除抑制、切标签）把键盘叫回来后，
        // 阶段回到正常；同时确保 SwiftTerm 键盘按钮被我们接管（旋转重建后自愈）。
        if let rtv = tv as? RotationSafeTerminalView {
            if rtv.keyboardStage == .hidden && !workspace.isTerminalKeyboardSuppressed {
                rtv.keyboardStage = .normal
            }
            rtv.ensureKeyboardStageRetarget()
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
        /// 三段式键盘按钮被点击（已接管 SwiftTerm 原生按钮）。
        var onKeyboardStageTap: ((UIButton) -> Void)?

        /// 用户点终端视图：恢复输入意图（解除键盘抑制）。
        @objc func handleTap() {
            onTap?()
        }

        /// SwiftTerm 原生键盘按钮（已由 ensureKeyboardStageRetarget 接管）。
        @objc func keyboardStageTapped(_ sender: UIButton) {
            onKeyboardStageTap?(sender)
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
