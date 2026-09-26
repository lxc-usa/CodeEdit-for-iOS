import Combine
import Foundation

/// 用户设置，UserDefaults 持久化。
final class SettingsStore: ObservableObject {
    @Published var themeName: String {
        didSet { UserDefaults.standard.set(themeName, forKey: "codeedit.themeName") }
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

    init() {
        let defaults = UserDefaults.standard
        themeName = defaults.string(forKey: "codeedit.themeName") ?? "Default (Dark)"
        let savedFontSize = defaults.double(forKey: "codeedit.fontSize")
        fontSize = savedFontSize > 0 ? savedFontSize : 14
        showLineNumbers = defaults.object(forKey: "codeedit.showLineNumbers") as? Bool ?? true
        wordWrap = defaults.object(forKey: "codeedit.wordWrap") as? Bool ?? false
        let savedTabWidth = defaults.double(forKey: "codeedit.tabWidth")
        tabWidth = savedTabWidth > 0 ? savedTabWidth : 4
        showInvisibles = defaults.object(forKey: "codeedit.showInvisibles") as? Bool ?? false
    }
}
