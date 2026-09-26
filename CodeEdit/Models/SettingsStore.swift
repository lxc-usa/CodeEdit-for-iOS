import Combine
import Foundation

/// 用户设置，UserDefaults 持久化。
final class SettingsStore: ObservableObject {
    @Published var themeName: String {
        didSet { UserDefaults.standard.set(themeName, forKey: "codeedit.themeName") }
    }
    /// 跟随系统配色：同一配色方案家族内按系统深浅自动切换。
    @Published var followSystemTheme: Bool {
        didSet { UserDefaults.standard.set(followSystemTheme, forKey: "codeedit.followSystemTheme") }
    }
    /// 跟随系统配色时选中的配色方案家族（如 "Default"）。
    @Published var themeFamily: String {
        didSet { UserDefaults.standard.set(themeFamily, forKey: "codeedit.themeFamily") }
    }
    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: "codeedit.fontSize") }
    }
    @Published var showLineNumbers: Bool {
        didSet { UserDefaults.standard.set(showLineNumbers, forKey: "codeedit.showLineNumbers") }
    }
    @Published var wordWrap: Bool {
        didSet { UserDefaults.standard.set(wordWrap, forKey: "codeedit.wordWrap") }
    }
    @Published var tabWidth: Double {
        didSet { UserDefaults.standard.set(tabWidth, forKey: "codeedit.tabWidth") }
    }
    @Published var showInvisibles: Bool {
        didSet { UserDefaults.standard.set(showInvisibles, forKey: "codeedit.showInvisibles") }
    }
    // MARK: - 远程终端（复用 openCoder 的 MonoFont / InteractiveShell）
    /// 终端等宽字体。
    @Published var monoFont: MonoFont {
        didSet { UserDefaults.standard.set(monoFont.rawValue, forKey: "codeedit.monoFont") }
    }
    /// 终端字号。
    @Published var monoFontSize: Double {
        didSet { UserDefaults.standard.set(monoFontSize, forKey: "codeedit.monoFontSize") }
    }
    /// 终端会话保持：离开终端页后会话在后台继续，回来时接上。
    @Published var terminalResumeSession: Bool {
        didSet { UserDefaults.standard.set(terminalResumeSession, forKey: "codeedit.terminalResumeSession") }
    }

    init() {
        let defaults = UserDefaults.standard
        themeName = defaults.string(forKey: "codeedit.themeName") ?? "Default (Dark)"
        followSystemTheme = defaults.object(forKey: "codeedit.followSystemTheme") as? Bool ?? false
        themeFamily = defaults.string(forKey: "codeedit.themeFamily") ?? "Default"
        let savedFontSize = defaults.double(forKey: "codeedit.fontSize")
        fontSize = savedFontSize > 0 ? savedFontSize : 14
        showLineNumbers = defaults.object(forKey: "codeedit.showLineNumbers") as? Bool ?? true
        wordWrap = defaults.object(forKey: "codeedit.wordWrap") as? Bool ?? false
        let savedTabWidth = defaults.double(forKey: "codeedit.tabWidth")
        tabWidth = savedTabWidth > 0 ? savedTabWidth : 4
        showInvisibles = defaults.object(forKey: "codeedit.showInvisibles") as? Bool ?? false
        monoFont = MonoFont(rawValue: defaults.string(forKey: "codeedit.monoFont") ?? "") ?? .sfMono
        let savedMonoSize = defaults.double(forKey: "codeedit.monoFontSize")
        monoFontSize = savedMonoSize > 0 ? savedMonoSize : 13
        terminalResumeSession = defaults.object(forKey: "codeedit.terminalResumeSession") as? Bool ?? false
    }
}
