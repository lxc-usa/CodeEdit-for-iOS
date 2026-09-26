import Foundation
import Runestone
import TreeSitterBashRunestone
import TreeSitterCRunestone
import TreeSitterCPPRunestone
import TreeSitterCSharpRunestone
import TreeSitterCSSRunestone
import TreeSitterGoRunestone
import TreeSitterHTMLRunestone
import TreeSitterJavaRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterJSONRunestone
import TreeSitterLuaRunestone
import TreeSitterMarkdownRunestone
import TreeSitterPHPRunestone
import TreeSitterPythonRunestone
import TreeSitterRubyRunestone
import TreeSitterRustRunestone
import TreeSitterSCSSRunestone
import TreeSitterSQLRunestone
import TreeSitterSwiftRunestone
import TreeSitterTOMLRunestone
import TreeSitterTSXRunestone
import TreeSitterTypeScriptRunestone
import TreeSitterYAMLRunestone

/// 文件扩展名 -> Tree-sitter 语言。
enum LanguageSupport {
    /// 未知扩展名返回 nil，编辑器按纯文本处理。
    static func treeSitterLanguage(for url: URL) -> TreeSitterLanguage? {
        switch url.pathExtension.lowercased() {
        case "swift": return .swift
        case "py", "pyw", "pyi": return .python
        case "js", "jsx", "mjs", "cjs": return .javaScript
        case "ts", "mts", "cts": return .typeScript
        case "tsx": return .tsx
        case "json", "jsonc", "geojson": return .json
        case "html", "htm", "xhtml": return .html
        case "css": return .css
        case "scss": return .scss
        case "c", "h": return .c
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx": return .cpp
        case "cs": return .cSharp
        case "java": return .java
        case "go": return .go
        case "rs": return .rust
        case "rb", "gemspec": return .ruby
        case "php", "phtml": return .php
        case "sh", "bash", "zsh": return .bash
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        case "md", "markdown", "mdown": return .markdown
        case "sql": return .sql
        case "lua": return .lua
        default: return nil
        }
    }

    /// 状态栏/标签页展示用的语言名。
    static func languageDisplayName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift": return "Swift"
        case "py", "pyw", "pyi": return "Python"
        case "js", "jsx", "mjs", "cjs": return "JavaScript"
        case "ts", "mts", "cts": return "TypeScript"
        case "tsx": return "TSX"
        case "json", "jsonc", "geojson": return "JSON"
        case "html", "htm", "xhtml": return "HTML"
        case "css": return "CSS"
        case "scss": return "SCSS"
        case "c", "h": return "C"
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx": return "C++"
        case "cs": return "C#"
        case "java": return "Java"
        case "go": return "Go"
        case "rs": return "Rust"
        case "rb", "gemspec": return "Ruby"
        case "php", "phtml": return "PHP"
        case "sh", "bash", "zsh": return "Bash"
        case "yaml", "yml": return "YAML"
        case "toml": return "TOML"
        case "md", "markdown", "mdown": return "Markdown"
        case "sql": return "SQL"
        case "lua": return "Lua"
        default: return NSLocalizedString("纯文本", comment: "Plain text language name")
        }
    }
}
