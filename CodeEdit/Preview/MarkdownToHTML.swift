import Foundation

// MARK: - 零依赖 Markdown → HTML
//
// CommonMark 常用子集 + GFM 表格/删除线：
// ATX/setext 标题、段落、粗体、斜体、删除线、行内代码、代码围栏、
// 链接、图片、自动链接、无序/有序列表、引用块、分隔线、GFM 表格（含对齐）。

/// Markdown 全文 → HTML 片段（不含 <html> 壳，调用方用 wrappedHTML 包装）。
func markdownToHTML(_ markdown: String) -> String {
    let lines = markdown.components(separatedBy: "\n")
    var html: [String] = []
    var i = 0
    while i < lines.count {
        let line = lines[i]
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { i += 1; continue }

        // 1. 代码围栏（内容原样转义，不解析 markdown）
        if let fence = fenceMarker(line) {
            let lang = t.dropFirst(3).trimmingCharacters(in: .whitespaces)
            var code: [String] = []
            i += 1
            while i < lines.count {
                if let f2 = fenceMarker(lines[i]), f2 == fence { break }
                code.append(lines[i])
                i += 1
            }
            i += 1 // 跳过闭合围栏（没有也照样结束）
            let cls = lang.isEmpty ? "" : " class=\"language-\(escapeHTML(String(lang)))\""
            html.append("<pre><code\(cls)>\(escapeHTML(code.joined(separator: "\n")))</code></pre>")
            continue
        }

        // 2. ATX 标题
        if let (level, text) = parseATXHeading(t) {
            html.append("<h\(level)>\(renderInlineMarkdown(text))</h\(level)>")
            i += 1
            continue
        }

        // 3. GFM 表格
        if let (table, next) = parseTable(at: lines, index: i) {
            html.append(tableToHTML(table))
            i = next
            continue
        }

        // 4. 引用块（内部递归解析，支持嵌套）
        if t.hasPrefix(">") {
            var inner: [String] = []
            while i < lines.count {
                let lt = lines[i].trimmingCharacters(in: .whitespaces)
                guard lt.hasPrefix(">") else { break }
                var stripped = String(lt.dropFirst())
                if stripped.hasPrefix(" ") { stripped = String(stripped.dropFirst()) }
                inner.append(stripped)
                i += 1
            }
            html.append("<blockquote>\n\(markdownToHTML(inner.joined(separator: "\n"))\n</blockquote>")
            continue
        }

        // 5. 分隔线（必须在列表之前：* * * 是 hr 不是列表）
        if isHR(t) {
            html.append("<hr>")
            i += 1
            continue
        }

        // 6. 列表（连续同种标记成组）
        if let marker = listMarker(t) {
            let ordered = marker.ordered
            var items: [String] = []
            while i < lines.count {
                let lt = lines[i].trimmingCharacters(in: .whitespaces)
                guard let m = listMarker(lt), m.ordered == ordered else { break }
                items.append(String(lt.dropFirst(m.length)).trimmingCharacters(in: .whitespaces))
                i += 1
            }
            let tag = ordered ? "ol" : "ul"
            html.append("<\(tag)>" + items.map { "<li>\(renderInlineMarkdown($0))</li>" }.joined() + "</\(tag)>")
            continue
        }

        // 7. 段落（含 setext 标题：下一行是 === / --- 则整段变标题）
        var para: [String] = []
        var setext: Int?
        while i < lines.count {
            let cur = lines[i]
            let lt = cur.trimmingCharacters(in: .whitespaces)
            if lt.isEmpty { break }
            if fenceMarker(cur) != nil { break }
            if parseATXHeading(lt) != nil { break }
            if lt.hasPrefix(">") { break }
            if isHR(lt) { break }
            if listMarker(lt) != nil { break }
            if parseTable(at: lines, index: i) != nil { break }
            // setext 优先于 hr：foo\n--- 是二级标题不是分隔线
            if let lv = setextLevel(lt), !para.isEmpty { setext = lv; i += 1; break }
            para.append(cur)
            i += 1
        }
        if let lv = setext {
            html.append("<h\(lv)>\(renderInlineMarkdown(para.joined(separator: " ")))</h\(lv)>")
        } else if !para.isEmpty {
            let rendered = para.map { pl -> String in
                var l = pl
                var br = ""
                if l.hasSuffix("  ") { br = "<br>"; l = String(l.dropLast(2)) }
                else if l.hasSuffix("\\") { br = "<br>"; l = String(l.dropLast()) }
                return renderInlineMarkdown(l) + br
            }.joined(separator: "\n")
            html.append("<p>\(rendered)</p>")
        }
    }
    return html.joined(separator: "\n")
}

// MARK: - ATX 标题 / 列表标记

/// `# 标题` → (级别, 文本)；`#标签`（无空格）不是标题。
func parseATXHeading(_ t: String) -> (level: Int, text: String)? {
    var idx = t.startIndex
    var level = 0
    while idx < t.endIndex, t[idx] == "#", level < 6 {
        level += 1
        idx = t.index(after: idx)
    }
    guard level > 0 else { return nil }
    if idx < t.endIndex, t[idx] != " ", t[idx] != "\t" { return nil }
    var text = String(t[idx...]).trimmingCharacters(in: .whitespaces)
    // 闭合序列：行尾的 #（前面有空格才算），如 `## 标题 ##`
    if let r = text.range(of: #"\s+#+\s*$"#, options: .regularExpression) {
        text = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
    }
    return (level, text)
}

/// 列表标记 → (是否有序, 标记长度)。`-`/`1.` 单独成行也算空条目。
func listMarker(_ t: String) -> (ordered: Bool, length: Int)? {
    if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { return (false, 2) }
    if t == "-" || t == "*" || t == "+" { return (false, 1) }
    var idx = t.startIndex
    var numCount = 0
    while idx < t.endIndex, t[idx].isNumber, numCount < 9 {
        numCount += 1
        idx = t.index(after: idx)
    }
    if numCount > 0, idx < t.endIndex, t[idx] == "." || t[idx] == ")" {
        let after = t.index(after: idx)
        if after == t.endIndex { return (true, numCount + 1) }
        if t[after] == " " { return (true, numCount + 2) }
    }
    return nil
}

// MARK: - 行内渲染

/// HTML 转义（必须在行内语法处理之前）。
func escapeHTML(_ s: String) -> String {
    var r = s
    r = r.replacingOccurrences(of: "&", with: "&amp;")
    r = r.replacingOccurrences(of: "<", with: "&lt;")
    r = r.replacingOccurrences(of: ">", with: "&gt;")
    r = r.replacingOccurrences(of: "\"", with: "&quot;")
    return r
}

private func regexReplace(_ pattern: String, in text: String, template: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
    return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text), withTemplate: template)
}

/// 行内 markdown → HTML：行内代码、图片、链接、粗斜体、删除线、自动链接。
func renderInlineMarkdown(_ text: String) -> String {
    var s = escapeHTML(text)

    // 1. 行内代码 → 私有区占位符（内容已转义，不再参与后续处理）
    var codeHTML: [String] = []
    if let re = try? NSRegularExpression(pattern: "`([^`\\n]+?)`") {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range
            out += ns.substring(with: NSRange(location: last, length: r.location - last))
            codeHTML.append("<code>\(ns.substring(with: m.range(at: 1)))</code>")
            out += "\u{E000}\(codeHTML.count - 1)\u{E001}"
            last = r.location + r.length
        }
        out += ns.substring(from: last)
        s = out
    }

    // 2. 图片（必须在链接之前，否则 ! 会残留）
    s = regexReplace(#"!\[([^\]]*)\]\(([^)\s]+)[^)]*\)"#, in: s, template: #"<img src="$2" alt="$1"/>"#)
    // 3. 链接
    s = regexReplace(#"\[([^\]]+)\]\(([^)\s]+)[^)]*\)"#, in: s, template: #"<a href="$2">$1</a>"#)
    // 4. 粗斜体（三重 → 粗体 → 斜体，顺序不能反）
    s = regexReplace(#"\*\*\*(.+?)\*\*\*"#, in: s, template: "<strong><em>$1</em></strong>")
    s = regexReplace(#"\*\*(.+?)\*\*"#, in: s, template: "<strong>$1</strong>")
    s = regexReplace(#"__(.+?)__"#, in: s, template: "<strong>$1</strong>")
    s = regexReplace(#"\*(.+?)\*"#, in: s, template: "<em>$1</em>")
    s = regexReplace(#"_(.+?)_"#, in: s, template: "<em>$1</em>")
    // 5. 删除线（GFM）
    s = regexReplace(#"~~(.+?)~~"#, in: s, template: "<del>$1</del>")
    // 6. 自动链接 <https://...>（转义后是 &lt;...&gt;）
    s = regexReplace(#"&lt;(https?://[^&<>\s]+)&gt;"#, in: s, template: #"<a href="$1">$1</a>"#)

    // 7. 还原行内代码
    for (idx, html) in codeHTML.enumerated() {
        s = s.replacingOccurrences(of: "\u{E000}\(idx)\u{E001}", with: html)
    }
    return s
}

// MARK: - HTML 包装（Markdown / HTML 预览共用）

/// HTML 包装：片段套壳，完整文档注入默认样式（低优先级，作者样式优先）。
func wrappedHTML(_ html: String, isDark: Bool) -> String {
    let bg = isDark ? "#000000" : "#ffffff"
    let fg = isDark ? "#e8e8e8" : "#1c1c1e"
    let link = isDark ? "#0a84ff" : "#0066cc"
    let codeBG = isDark ? "#2c2c2e" : "#f2f2f7"
    let border = isDark ? "#48484a" : "#d1d1d6"
    let thBG = isDark ? "#1c1c1e" : "#f2f2f7"

    let defaultCSS = """
        body{font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:17px;line-height:1.6;color:\(fg);background:\(bg);padding:16px 16px 48px;margin:0;word-wrap:break-word;-webkit-text-size-adjust:100%;}
        a{color:\(link);}
        img,video{max-width:100%;height:auto;}
        pre{overflow-x:auto;background:\(codeBG);padding:12px;border-radius:8px;}
        pre code{background:transparent;padding:0;}
        code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.85em;background:\(codeBG);padding:2px 6px;border-radius:6px;}
        table{border-collapse:collapse;margin:12px 0;display:block;overflow-x:auto;}
        th,td{border:1px solid \(border);padding:6px 12px;text-align:left;}
        th{background:\(thBG);}
        blockquote{border-left:3px solid \(border);margin:12px 0;padding:2px 12px;opacity:.85;}
        ul,ol{padding-left:24px;}
        li{margin:4px 0;}
        h1,h2,h3,h4,h5,h6{line-height:1.35;}
        hr{border:none;border-top:1px solid \(border);margin:20px 0;}
        """

    let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().contains("<html") {
        var full = html
        let injection = "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>\(defaultCSS)</style>"
        if let headRange = full.range(of: "<head[^>]*>", options: .regularExpression) {
            full.insert(contentsOf: injection, at: headRange.upperBound)
        } else {
            full = injection + full
        }
        return full
    }
    return """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>\(defaultCSS)</style></head><body>\(html)</body></html>
        """
}
