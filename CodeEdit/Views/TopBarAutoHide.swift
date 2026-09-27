import UIKit

/// 顶部栏（导航栏 + 标签页条）自动显隐的滚动方向跟踪器，编辑器与终端共用。
///
/// 行为：用户上滑（查看下方内容）→ 隐藏顶部栏，最大化可视区；
/// 用户下滑（回看上方内容）或回到顶部 → 重新显示。
/// 只响应用户手势滚动；程序化滚动（查找跳转、终端输出跟随等）只更新基准，不触发显隐。
final class TopBarScrollTracker {
    private weak var workspace: WorkspaceStore?
    private var lastY: CGFloat = 0
    private var accumulator: CGFloat = 0
    /// 累积位移阈值：慢速拖动也能触发，避免逐帧抖动
    private let threshold: CGFloat = 28

    init(workspace: WorkspaceStore) {
        self.workspace = workspace
    }

    /// 在 UIScrollView.contentOffset 的 KVO 回调里调用（主线程）。
    func handleScroll(_ scrollView: UIScrollView) {
        let y = scrollView.contentOffset.y
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
        // 调用方保证主线程；WorkspaceStore 是 @MainActor
        MainActor.assumeIsolated { [weak self] in
            self?.workspace?.setTopBarsHidden(hidden)
        }
    }
}
