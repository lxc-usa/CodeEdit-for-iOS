import UIKit

/// 顶部栏（导航栏 + 标签页条）自动显隐的滚动方向跟踪器，编辑器与终端共用。
///
/// 行为：用户上滑（查看下方内容）→ 隐藏顶部栏，最大化可视区；
/// 用户下滑（回看上方内容）或回到顶部 → 重新显示。
/// 只响应用户手势滚动；程序化滚动（查找跳转、终端输出跟随等）只更新基准，不触发显隐。
///
/// 防护（2026-09-27 真机崩溃复盘）：
/// 崩溃日志是看门狗杀进程（FRONTBOARD 0x8BADF00D，scene-update 10 秒超时），
/// 不是普通闪退。主线程当时卡在旋转布局里反复执行
/// setNavigationBarHidden:animated: + 全量重排 + 终端重排版，10 秒烧满 CPU。
/// 成因：旋转时 bounds/safeArea/inset 变化会来回拽 contentOffset；若滚动视图
/// 仍处在用户手势状态（如下滑后的 isDecelerating），守卫放行，±28pt 阈值被
/// 正反交替越过 → 顶部栏 hide/show 来回横跳；每次横跳都是一次导航栏动画 +
/// SwiftUI 重排 + 终端重排版，而这些布局又会继续扰动 contentOffset → 更多
/// KVO → 更多横跳，旋转的 scene-update 事务永远排不空，看门狗直接 SIGKILL。
/// 因此加两道闸：旋转期间直接忽略滚动事件；每次真正应用显隐变化后冷却 0.5 秒。
final class TopBarScrollTracker {
    private weak var workspace: WorkspaceStore?
    private var lastY: CGFloat = 0
    private var accumulator: CGFloat = 0
    /// 累积位移阈值：慢速拖动也能触发，避免逐帧抖动
    private let threshold: CGFloat = 28
    /// 上次真正应用显隐变化的时间：阻断布局抖动引发的反复横跳
    private var lastApplied = Date.distantPast
    /// 显隐变化冷却：大于导航栏动画（0.25s）+ 布局收敛时间
    private let cooldown: TimeInterval = 0.5
    /// 旋转抑制截止时间：旋转动画约 0.3～0.5s，留足余量
    private var rotationSuppressUntil = Date.distantPast
    private let rotationSuppression: TimeInterval = 1.0
    private var orientationObserver: NSObjectProtocol?

    init(workspace: WorkspaceStore) {
        self.workspace = workspace
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 只认真正的横竖屏切换，faceUp/faceDown 等不算
            switch UIDevice.current.orientation {
            case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight:
                self?.rotationSuppressUntil = Date().addingTimeInterval(self?.rotationSuppression ?? 1.0)
            default:
                break
            }
        }
    }

    deinit {
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    /// 在 UIScrollView.contentOffset 的 KVO 回调里调用（主线程）。
    func handleScroll(_ scrollView: UIScrollView) {
        let y = scrollView.contentOffset.y
        // 旋转期间：只同步基准，不触发显隐。旋转中的 bounds/inset 变化
        // 会让 contentOffset 上下乱跳，任何一次误判都可能点燃
        // "横跳 → 导航栏动画 → 重排 → 更多横跳" 的死循环（见类注释）。
        guard Date() >= rotationSuppressUntil else {
            lastY = y
            accumulator = 0
            return
        }
        // 非用户手势的滚动不同步显隐，只更新基准
        guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else {
            lastY = y
            accumulator = 0
            return
        }
        let dy = y - lastY
        lastY = y
        // 回到顶部：必显示
        if y <= 0 {
            accumulator = 0
            setHidden(false)
            return
        }
        accumulator += dy
        if accumulator > threshold {
            accumulator = 0
            setHidden(true)
        } else if accumulator < -threshold {
            accumulator = 0
            setHidden(false)
        }
    }

    private func setHidden(_ hidden: Bool) {
        // 冷却期内忽略：导航栏动画/键盘/inset 收敛引发的 contentOffset 抖动
        // 会在短时间内把显隐来回翻转，每次翻转都是一次全量重排，主线程会被
        // 拖到看门狗超时。首次变化立即应用，正常滚动的手感不受影响。
        let now = Date()
        guard now.timeIntervalSince(lastApplied) >= cooldown else { return }
        lastApplied = now
        // 调用方保证主线程；WorkspaceStore 是 @MainActor
        MainActor.assumeIsolated { [weak self] in
            self?.workspace?.setTopBarsHidden(hidden)
        }
    }
}
