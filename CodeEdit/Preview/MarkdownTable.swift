import UIKit

// MARK: - GFM 表格模型

/// GFM 表格：表头 + 每列对齐 + 数据行。
///
/// 系统 `AttributedString(markdown:)` 不支持表格，这里只把表格抽出来，
/// 用 TextKit 的 NSTextTable 手工拼回去，其余部分继续走系统原生渲染。
struct MarkdownTable {
    enum Alignment {
        case left, center, right
    }
    let headers: [String]
    let alignments: [Alignment]
    let rows: [[String]]
}

/// markdown 切段：普通文本 / 表格。
enum MarkdownSegment {
    case text(String)
    case table(MarkdownTable)
}

// MARK: - 切段：按表格边界拆分

/// 把 markdown 按 GFM 表格边界切成段。代码围栏块内的 `|` 不识别为表格。
func parseMarkdownSegments(_ markdown: String) -> [MarkdownSegment] {
    let lines = markdown.components(separatedBy: "\n")
    var segments: [MarkdownSegment] = []
    var textBuffer: [String] = []
    var i = 0
    var inFence = false
    var fenceChar: Character = "`"

    func flushText() {
        if !textBuffer.isEmpty {
            segments.append(.text(textBuffer.joined(separator: "\n")))
            textBuffer = []
        }
    }

    while i < lines.count {
        let line = lines[i]
        if let fence = fenceMarker(line) {
            if !inFence {
                inFence = true
                fenceChar = fence
            } else if fence == fenceChar {
                inFence = false
            }
            textBuffer.append(line)
            i += 1
            continue
        }
        if !inFence, !line.trimmingCharacters(in: .whitespaces).isEmpty,
           i + 1 < lines.count,
           let alignments = parseDelimiterRow(lines[i + 1]) {
            // 表头 + 分隔行：吃掉后面连续的数据行
            flushText()
            var bodyLines: [String] = []
            var j = i + 2
            while j < lines.count {
                let bodyLine = lines[j]
                if bodyLine.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if fenceMarker(bodyLine) != nil { break }
                if startsBlockElement(bodyLine) { break }
                bodyLines.append(bodyLine)
                j += 1
            }
            let colCount = alignments.count
            let headers = normalizeCells(splitTableRow(line), to: colCount)
            let rows = bodyLines.map { normalizeCells(splitTableRow($0), to: colCount) }
            segments.append(.table(MarkdownTable(headers: headers, alignments: alignments, rows: rows)))
            i = j
            continue
        }
        textBuffer.append(line)
        i += 1
    }
    flushText()
    return segments
}

/// 围栏标记：``` 或 ~~~（最多 3 个前导空格，4 个算缩进代码块）。
private func fenceMarker(_ line: String) -> Character? {
    let stripped = line.drop(while: { $0 == " " })
    guard line.count - stripped.count < 4 else { return nil }
    if stripped.hasPrefix("```") { return "`" }
    if stripped.hasPrefix("~~~") { return "~" }
    return nil
}

/// 表格数据行结束条件：空行，或另一个块级元素的开始（标题/引用/列表/分隔线）。
private func startsBlockElement(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return true }
    if t.hasPrefix("#") || t.hasPrefix(">") { return true }
    if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { return true }
    if t == "-" || t == "*" || t == "+" { return true }
    // 有序列表：1. / 2) 等
    let head = t.prefix(while: { $0.isNumber })
    if !head.isEmpty && head.count <= 3 {
        let rest = t.dropFirst(head.count)
        if rest.hasPrefix(". ") || rest.hasPrefix(") ") || rest == "." || rest == ")" { return true }
    }
    // 分隔线：*** / --- / ___
    let compact = t.filter { !$0.isWhitespace }
    if compact.count >= 3 && compact.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) { return true }
    return false
}

/// 解析分隔行（如 `|:---|:---:|---:|`），返回每列对齐；不是分隔行返回 nil。
/// 裸 `---` 可能是 setext 二级标题的下划线（GitHub 也优先按标题处理），
/// 必须含 `|` 或 `:` 才算表格分隔行。
private func parseDelimiterRow(_ line: String) -> [MarkdownTable.Alignment]? {
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
private func splitTableRow(_ line: String) -> [String] {
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
private func normalizeCells(_ cells: [String], to count: Int) -> [String] {
    if cells.count >= count { return Array(cells.prefix(count)) }
    return cells + Array(repeating: "", count: count - cells.count)
}

// MARK: - NSTextTable 拼表

/// 把 GFM 表格拼成 NSAttributedString（TextKit 1 的 NSTextTable）。
/// 风格：表头加粗 + 底色，简洁无线框（现代渲染器风格）。
func makeTableAttributedString(
    _ table: MarkdownTable,
    baseFont: UIFont,
    isDark: Bool
) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let nstTable = NSTextTable()
    let colCount = table.alignments.count
    nstTable.numberOfColumns = colCount

    let headerFont = UIFont.boldSystemFont(ofSize: baseFont.pointSize)
    let headerBG = UIColor.secondarySystemBackground
    let cellPadding: CGFloat = 8

    let allRows: [[String]] = [table.headers] + table.rows
    for (r, row) in allRows.enumerated() {
        let isHeader = (r == 0)
        for c in 0..<colCount {
            let block = NSTextTableBlock(
                table: nstTable,
                startingRow: r, rowSpan: 1,
                startingColumn: c, columnSpan: 1
            )
            if isHeader {
                block.backgroundColor = headerBG
            }
            let para = NSMutableParagraphStyle()
            para.textBlocks = [block]
            switch table.alignments[c] {
            case .left: para.alignment = .left
            case .center: para.alignment = .center
            case .right: para.alignment = .right
            }
            // 左对齐列用 headIndent 做内边距；居中/右对齐靠 alignment 本身
            if table.alignments[c] == .left {
                para.headIndent = cellPadding
                para.firstLineHeadIndent = cellPadding
            }
            para.paragraphSpacingBefore = 3
            para.paragraphSpacingAfter = 3

            let cellMarkdown = c < row.count ? row[c] : ""
            let cellContent = renderInlineMarkdown(cellMarkdown, baseFont: isHeader ? headerFont : baseFont)
            let cell = NSMutableAttributedString(attributedString: cellContent)
            if cell.length == 0 {
                // 空单元格也要占位，否则 textBlock 塌掉
                cell.append(NSAttributedString(string: " "))
            }
            cell.addAttribute(.paragraphStyle, value: para,
                              range: NSRange(location: 0, length: cell.length))
            fillMissingFont(cell, isHeader ? headerFont : baseFont)
            result.append(cell)
            // 每个单元格必须是独立段落，换行分隔
            result.append(NSAttributedString(string: "\n"))
        }
    }
    return result
}

/// 单元格内的行内 markdown（加粗/链接/行内代码）继续走系统原生解析。
private func renderInlineMarkdown(_ text: String, baseFont: UIFont) -> NSAttributedString {
    guard !text.isEmpty else { return NSAttributedString() }
    guard let parsed = try? AttributedString(
        markdown: text,
        options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    ) else {
        return NSAttributedString(string: text)
    }
    return NSAttributedString(parsed)
}

/// 没有字体的 run 补上 baseFont（已有字体如加粗/标题不覆盖）。
func fillMissingFont(_ attr: NSMutableAttributedString, _ font: UIFont) {
    guard attr.length > 0 else { return }
    attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length), options: []) { value, range, _ in
        if value == nil {
            attr.addAttribute(.font, value: font, range: range)
        }
    }
}

// MARK: - 整文档渲染

/// Markdown 整文档渲染：切段 → 文本段走系统原生，表格段走 NSTextTable。
func renderMarkdown(_ markdown: String, theme: CETheme) -> NSAttributedString {
    let baseFont = UIFont.systemFont(ofSize: 17)
    let segments = parseMarkdownSegments(markdown)
    let result = NSMutableAttributedString()
    for (index, segment) in segments.enumerated() {
        switch segment {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let parsed = try? AttributedString(markdown: trimmed) {
                    let ns = NSMutableAttributedString(parsed)
                    fillMissingFont(ns, baseFont)
                    result.append(ns)
                } else {
                    // 解析失败兜底：纯文本
                    result.append(NSAttributedString(string: trimmed, attributes: [.font: baseFont]))
                }
            }
        case .table(let table):
            result.append(makeTableAttributedString(table, baseFont: baseFont, isDark: theme.isDark))
        }
        if index < segments.count - 1 {
            result.append(NSAttributedString(string: "\n\n"))
        }
    }
    return result
}
