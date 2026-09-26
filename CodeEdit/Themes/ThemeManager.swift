import UIKit

/// Bundle 内置主题：解析后的文件 + 设置页预览用的三色。
struct BundledTheme {
    let file: CEThemeFile
    let previewBackground: UIColor
    let previewText: UIColor
    let previewKeyword: UIColor
}

/// 主题加载与构造。bundled 只解析一次并缓存。
enum ThemeManager {
    static let bundled: [BundledTheme] = loadBundled()

    /// 内置主题不存在时的保底主题（深色）。
    static func fallbackFile() -> CEThemeFile {
        bundled.first { $0.file.displayName == "Default (Dark)" }?.file
            ?? bundled.first?.file
            ?? CEThemeFile(name: "fallback", displayName: "Default (Dark)", type: "dark", editor: [:])
    }

    static func file(named displayName: String) -> CEThemeFile {
        bundled.first { $0.file.displayName == displayName }?.file ?? fallbackFile()
    }

    static func makeTheme(named displayName: String, fontSize: CGFloat) -> CETheme {
        makeTheme(file(named: displayName), fontSize: fontSize)
    }

    static func makeTheme(_ file: CEThemeFile, fontSize: CGFloat) -> CETheme {
        var colors: [String: (color: UIColor, bold: Bool)] = [:]
        for (key, entry) in file.editor {
            if let color = CETheme.color(from: entry.color) {
                colors[key] = (color, entry.bold ?? false)
            }
        }
        return CETheme(
            displayName: file.displayName,
            isDark: file.isDark,
            colors: colors,
            fontSize: fontSize
        )
    }

    // MARK: - 私有

    private static func loadBundled() -> [BundledTheme] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "cetheme", subdirectory: nil) else {
            return []
        }
        var result: [BundledTheme] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(CEThemeFile.self, from: data) else { continue }
            result.append(BundledTheme(
                file: file,
                previewBackground: color(for: "background", in: file) ?? (file.isDark ? .black : .white),
                previewText: color(for: "text", in: file) ?? (file.isDark ? .white : .black),
                previewKeyword: color(for: "keywords", in: file) ?? .systemPink
            ))
        }
        return result.sorted { $0.file.displayName < $1.file.displayName }
    }

    private static func color(for key: String, in file: CEThemeFile) -> UIColor? {
        guard let entry = file.editor[key] else { return nil }
        return CETheme.color(from: entry.color)
    }
}
