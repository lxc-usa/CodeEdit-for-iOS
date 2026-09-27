import Foundation

/// 简单的内存调试日志（用于真机问题排查）。
/// 在设置页「调试」区可查看、复制、清空。
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()
    private var lines: [String] = []
    private let lock = NSLock()
    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    func append(_ msg: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append("[\(dateFmt.string(from: Date()))] \(msg)")
        if lines.count > 800 {
            lines.removeFirst(lines.count - 800)
        }
    }

    func all() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
    }
}
