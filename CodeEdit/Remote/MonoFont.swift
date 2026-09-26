import SwiftUI
import UIKit

/// 等宽字体选项：iOS 自带的经典等宽字体，终端与代码编辑器共用。
///
/// - SF Mono：Apple 现代等宽字体（走系统等宽 API）
/// - Menlo：macOS 终端的经典默认字体
/// - Courier New：Windows 记事本 / 终端的经典字体
/// - Courier：打字机风格等宽字体
enum MonoFont: String, CaseIterable, Identifiable {
    case sfMono
    case menlo
    case courierNew
    case courier

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sfMono: return "SF Mono"
        case .menlo: return "Menlo"
        case .courierNew: return "Courier New"
        case .courier: return "Courier"
        }
    }

    var note: String {
        switch self {
        case .sfMono: return String(localized: "Apple 现代等宽字体")
        case .menlo: return String(localized: "macOS 终端经典字体")
        case .courierNew: return String(localized: "Windows 终端经典字体")
        case .courier: return String(localized: "打字机风格")
        }
    }

    /// PostScript 名称；SF Mono 走系统等宽 API，此处为 nil。
    private var postScriptName: String? {
        switch self {
        case .sfMono: return nil
        case .menlo: return "Menlo-Regular"
        case .courierNew: return "CourierNewPSMT"
        case .courier: return "Courier"
        }
    }

    /// UIKit 字体（代码编辑器用）。指定字体在系统上缺失时回退到系统等宽字体，保证永远有字可用。
    func uiFont(size: CGFloat) -> UIFont {
        if let name = postScriptName, let font = UIFont(name: name, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// SwiftUI 字体（终端用）。指定字体在系统上缺失时回退到系统等宽字体，保证永远有字可用。
    func font(size: CGFloat) -> Font {
        if let name = postScriptName, UIFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, design: .monospaced)
    }
}
