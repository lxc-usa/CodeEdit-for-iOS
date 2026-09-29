import Foundation

// MARK: - GFM 表格模型与解析、HTML 生成
//
// 教训（2026-09-29，CI 实锤）：NSTextTable / NSTextTableBlock 是 macOS AppKit 专属，
// UIKit 里根本不存在；NSParagraphStyle.textBlocks / paragraphSpacingAfter 同样没有。
// 预览统一走 WKWebView，表格直接生成 HTML <table>，比 NSTextTable 更简单可靠。

/// GFM 表格：表头 + 每列对齐 + 数据行。
struct MarkdownTable {
    enum Alignment {
        case left, center, right
    }
    let headers: [String]
    let alignments: [Alignment]
    let rows: [[String]]
}

/// 若 lines[i] 是表格表头、lines[i+1] 是分隔行，解析并返回 (表格, 表格结束后行号)。
func parseTable(at lines: [String], index i: Int) -> (MarkdownTable, Int)? {
    guard i + 1 < lines.count else { return nil }
    let headerLine = lines[i]
    guard headerLine.contains("|") else { return nil }
    guard let alignments = parseDelimiterRow(lines[i + 1]) else { return nil }
    let colCount = alignments.count
    var body: [[String]] = []
    var j = i + 2
    while j < lines.count {
        let bodyLine = lines[j]
        if bodyLine.trimmingCharacters(in: .whitespaces).isEmpty { break }
        if fenceMarker(bodyLine) != nil { break }
        if startsBlockElement(bodyLine) { break }
        body.append(normalizeCells(splitTableRow(bodyLine), to: colCount))
        j += 1
    }
    let headers = normalizeCells(splitTableRow(headerLine), to: colCount)
    return (MarkdownTable(headers: headers, alignments: alignments, rows: body), j)
}

/// 表格 → HTML（单元格内的行内 markdown 继续渲染）。
func tableToHTML(_ table: MarkdownTable) -> String {
    func alignStyle(_ a: MarkdownTable.Alignment) -> String {
        switch a {
        case .left: return "text-align:left"
        case .center: return "text-align:center"
        case .right: return "text-align:right"
        }
    }
    var s = "<table>\n<thead>\n<tr>"
    for (c, h) in table.headers.enumerated() {
        let a = c < table.alignments.count ? table.alignments[c] : .left
        s += "<th style=\"\(alignStyle(a))\">\(renderInlineMarkdown(h))</th>"
    }
    s += "</tr>\n</thead>\n<tbody>\n"
    for row in table.rows {
        s += "<tr>"
        for c in 0..<table.alignments.count {
            let cell = c < row.count ? row[c] : ""
            s += "<td style=\"\(alignStyle(table.alignments[c]))\">\(renderInlineMarkdown(cell))</td>"
        }
        s += "</tr>\n"
    }
    s += "</tbody>\n</table>"
    return s
}

// MARK: - 行级小工具（表格与块解析共用）

/// 围栏标记：``` 或 ~~~（最多 3 个前导空格，4 个算缩进代码块）。
func fenceMarker(_ line: String) -> Character? {
    let stripped = line.drop(while: { $0 == " " })
    guard line.count - stripped.count < 4 else { return nil }
    if stripped.hasPrefix("```") { return "`" }
    if stripped.hasPrefix("~~~") { return "~" }
    return nil
}

/// 表格数据行结束条件：空行，或另一个块级元素的开始（标题/引用/列表/分隔线）。
func startsBlockElement(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return true }
    if t.hasPrefix("#") || t.hasPrefix(">") { return true }
    if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { return true }
    if t == "-" || t == "*" || t == "+" { return true }
    let head = t.prefix(while: { $0.isNumber })
    if !head.isEmpty && head.count <= 9 {
        let rest = t.dropFirst(head.count)
        if rest.hasPrefix(". ") || rest.hasPrefix(") ") || rest == "." || rest == ")" { return true }
    }
    return isHR(t)
}

/// 分隔线：*** / --- / ___（允许空格分隔，如 * * *）。
func isHR(_ t: String) -> Bool {
    let compact = t.filter { !$0.isWhitespace }
    guard compact.count >= 3 else { return false }
    guard let first = compact.first, first == "-" || first == "*" || first == "_" else { return false }
    return compact.allSatisfy { $0 == first }
}

/// setext 标题下划线：=== → 一级，--- → 二级（含 | 的交给表格判定）。
func setextLevel(_ t: String) -> Int? {
    let c = t.filter { !$0.isWhitespace }
    guard !c.isEmpty, !c.contains("|") else { return nil }
    if c.allSatisfy({ $0 == "=" }) { return 1 }
    if c.allSatisfy({ $0 == "-" }) { return 2 }
    return nil
}

/// 解析分隔行（如 `|:---|:---:|---:|`），返回每列对齐；不是分隔行返回 nil。
/// 裸 `---` 可能是 setext 二级标题下划线，必须含 `|` 或 `:` 才算表格分隔行。
func parseDelimiterRow(_ line: String) -> [MarkdownTable.Alignment]? {
    guard line.contains("|") || line.contains(":") else { return nil }
    let cells = splitTableRow(line)
    guard !cells.isEmpty else { return nil }
    var alignments: [MarkdownTable.Alignment] = []
    for cell in cells {
        let c = cell.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return nil }
        let left = c.hasPrefix(":")
        let right = c.hasSuffix(":")
        let dashes = c.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
        if left && right { alignments.append(.center) }
        else if right { alignments.append(.right) }
        else { alignments.append(.left) }
    }
    return alignments
}

/// 按 `|` 切分表格行，处理 `\|` 转义；首尾的 `|` 是边框，不算数据。
func splitTableRow(_ line: String) -> [String] {
    var cells: [String] = []
    var current = ""
    let chars = Array(line)
    var k = 0
    while k < chars.count {
        let ch = chars[k]
        if ch == "\\", k + 1 < chars.count, chars[k + 1] == "|" {
            current.append("|")
            k += 2
        } else if ch == "|" {
            cells.append(current)
            current = ""
            k += 1
        } else {
            current.append(ch)
            k += 1
        }
    }
    cells.append(current)
    var result = cells
    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
    if result.first?.trimmingCharacters(in: .whitespaces).isEmpty == true, trimmedLine.hasPrefix("|") {
        result.removeFirst()
    }
    if result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true, trimmedLine.hasSuffix("|") {
        result.removeLast()
    }
    return result.map { $0.trimmingCharacters(in: .whitespaces) }
}

/// 单元格数对齐列数：多的截断，少的补空（GFM 行为）。
func normalizeCells(_ cells: [String], to count: Int) -> [String] {
    if cells.count >= count { return Array(cells.prefix(count)) }
    return cells + Array(repeating: "", count: count - cells.count)
}
