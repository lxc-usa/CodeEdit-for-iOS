import Runestone
import UIKit

// MARK: - .cetheme JSON 结构

/// CodeEdit 主题文件中单个颜色条目，如 {"color": "#FF7AB2", "bold": true}。
struct CEThemeEntry: Decodable {
    let color: String
    let bold: Bool?
}

/// CodeEdit .cetheme 主题文件（只解析 editor 部分需要的字段）。
struct CEThemeFile: Decodable {
    let name: String
    let displayName: String
    let type: String
    let editor: [String: CEThemeEntry]

    var isDark: Bool { type.lowercased() == "dark" }
}

// MARK: - Runestone Theme 实现

/// 由 CodeEdit .cetheme 文件驱动的 Runestone 主题。
final class CETheme: Theme {
    let displayName: String
    let isDark: Bool

    // 对外暴露，供编辑器配置光标/选中/背景色。
    let background: UIColor
    let caretColor: UIColor
    let selectionColor: UIColor

    let font: UIFont
    let textColor: UIColor
    let gutterBackgroundColor: UIColor
    let gutterHairlineColor: UIColor
    let lineNumberColor: UIColor
    let lineNumberFont: UIFont
    let selectedLineBackgroundColor: UIColor
    let selectedLinesLineNumberColor: UIColor
    let selectedLinesGutterBackgroundColor: UIColor
    let invisibleCharactersColor: UIColor
    let pageGuideHairlineColor: UIColor
    let pageGuideBackgroundColor: UIColor
    let markedTextBackgroundColor: UIColor

    /// cetheme key -> (颜色, 是否粗体)，如 "keywords" -> (#FF7AB2, true)。
    private let colors: [String: (color: UIColor, bold: Bool)]

    init(displayName: String, isDark: Bool, colors: [String: (color: UIColor, bold: Bool)], fontSize: CGFloat) {
        self.displayName = displayName
        self.isDark = isDark
        self.colors = colors

        let text = colors["text"]?.color ?? (isDark ? .white : .black)
        let bg = colors["background"]?.color ?? (isDark ? .black : .white)

        self.textColor = text
        self.background = bg
        self.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)

        self.caretColor = colors["insertionPoint"]?.color ?? .systemBlue
        // 选中高亮必须半透明，否则盖住文字看不清；主题给不透明色时降到 0.35，
        // 已有透明度但太浅时也补到 0.35，保证选中可见。
        let rawSelection = colors["selection"]?.color ?? UIColor.systemBlue.withAlphaComponent(0.3)
        var selectionAlpha: CGFloat = 0
        rawSelection.getRed(nil, green: nil, blue: nil, alpha: &selectionAlpha)
        self.selectionColor = rawSelection.withAlphaComponent(
            selectionAlpha >= 1 ? 0.35 : max(selectionAlpha, 0.35)
        )

        self.selectedLineBackgroundColor = colors["lineHighlight"]?.color ?? text.withAlphaComponent(0.06)
        self.invisibleCharactersColor = colors["invisibles"]?.color ?? text.withAlphaComponent(0.4)

        self.gutterBackgroundColor = bg
        self.gutterHairlineColor = text.withAlphaComponent(0.15)
        self.lineNumberColor = text.withAlphaComponent(0.45)
        self.lineNumberFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        self.selectedLinesLineNumberColor = text
        self.selectedLinesGutterBackgroundColor = .clear

        self.pageGuideHairlineColor = text.withAlphaComponent(0.2)
        self.pageGuideBackgroundColor = .clear
        self.markedTextBackgroundColor = text.withAlphaComponent(0.12)
    }

    // MARK: - 语法高亮

    /// Tree-sitter capture 名 -> cetheme 颜色键。
    private func themeKey(for rawHighlightName: String) -> String? {
        var name = rawHighlightName
        if name.hasPrefix("@") { name.removeFirst() }
        name = name.lowercased()
        // 顺序重要：更具体的规则在前
        if name == "comment" || name.hasPrefix("comment.") { return "comments" }
        if name == "string" || name.hasPrefix("string.") { return "strings" }
        if name == "character" || name.hasPrefix("character.") { return "characters" }
        if name == "number" || name.hasPrefix("number.") { return "numbers" }
        if name == "keyword" || name.hasPrefix("keyword.") { return "keywords" }
        if name == "operator" || name == "punctuation" || name.hasPrefix("punctuation.") { return nil }
        if name == "property" || name.hasPrefix("property.") { return "attributes" }
        if name == "attribute" || name.hasPrefix("attribute.") { return "attributes" }
        if name == "function" || name.hasPrefix("function.")
            || name == "method" || name.hasPrefix("method.") { return "commands" }
        if name == "type" || name.hasPrefix("type.") { return "types" }
        if name == "tag" || name.hasPrefix("tag.") { return "types" }
        if name == "variable.builtin" { return "values" }
        if name == "variable" || name.hasPrefix("variable.") { return "variables" }
        if name == "constant" || name.hasPrefix("constant.") { return "values" }
        if name == "boolean" || name.hasPrefix("boolean.") { return "values" }
        if name == "label" || name.hasPrefix("label.") { return "values" }
        return nil
    }

    /// 带 fallback 的颜色查找：characters 缺失用 strings，values/commands 缺失用 variables。
    private func entry(for themeKey: String) -> (color: UIColor, bold: Bool)? {
        if let e = colors[themeKey] { return e }
        switch themeKey {
        case "characters": return colors["strings"]
        case "values", "commands": return colors["variables"]
        default: return nil
        }
    }

    func textColor(for highlightName: String) -> UIColor? {
        guard let key = themeKey(for: highlightName) else { return nil }
        return entry(for: key)?.color
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        guard let key = themeKey(for: highlightName),
              let e = entry(for: key), e.bold else { return [] }
        return .bold
    }

    // MARK: - Hex 解析

    /// 支持 #RRGGBB 与 #RRGGBBAA。
    static func color(from hex: String) -> UIColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 6 {
            r = CGFloat((value & 0xFF0000) >> 16) / 255
            g = CGFloat((value & 0x00FF00) >> 8) / 255
            b = CGFloat(value & 0x0000FF) / 255
            a = 1
        } else {
            r = CGFloat((value & 0xFF000000) >> 24) / 255
            g = CGFloat((value & 0x00FF0000) >> 16) / 255
            b = CGFloat((value & 0x0000FF00) >> 8) / 255
            a = CGFloat(value & 0x000000FF) / 255
        }
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
}
