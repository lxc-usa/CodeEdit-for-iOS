import Combine
import Foundation

/// 终端标签页：一个标签对应一台服务器的 SSH 会话。
/// 会话本身由 TerminalSessionCache 按 serverID 持有，这里只记录标签身份与展示名。
final class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    let serverID: UUID
    @Published var title: String

    init(serverID: UUID, title: String) {
        self.serverID = serverID
        self.title = title
    }
}
