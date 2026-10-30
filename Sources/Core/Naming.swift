import Foundation

/// Batch renaming applied to output file names during conversion.
/// Tokens: {原名} {标题} {作者} {序号} {页数} {格式} {日期}, with English aliases {name} {title} {author} {n} {pages} {format} {date}.
struct NamingRule: Codable, Equatable {
    var template = "{原名}"
    var start = 1
    /// Digits for {序号}; 0 = automatic (enough for the last number, at least 2).
    var padding = 0
    var find = ""
    var replace = ""
    var useRegex = false
    /// Removes 【…】 […] (…) （…） groups, typically scan-group and source tags in downloaded names.
    var stripBrackets = false

    static let tokens: [(token: String, help: String)] = [
        ("{原名}", "源文件名（去扩展名，已应用查找替换和去括号）"),
        ("{标题}", "书内元数据中的标题"),
        ("{作者}", "书内元数据中的作者"),
        ("{序号}", "按列表顺序编号"),
        ("{页数}", "页数"),
        ("{格式}", "输出格式，如 CBZ"),
        ("{日期}", "转换日期，如 2026-10-30"),
    ]
    private static let aliases = ["{name}": "{原名}", "{title}": "{标题}", "{author}": "{作者}", "{n}": "{序号}",
                                  "{pages}": "{页数}", "{format}": "{格式}", "{date}": "{日期}"]

    var isDefault: Bool { normalizedTemplate == "{原名}" && find.isEmpty && !stripBrackets }

    private var normalizedTemplate: String {
        Self.aliases.reduce(template) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }

    /// nil when the regex is valid (or unused); otherwise a message for the user.
    var regexError: String? {
        guard useRegex, !find.isEmpty else { return nil }
        do { _ = try NSRegularExpression(pattern: find) } catch { return "正则表达式无效：\(find)" }
        return nil
    }

    func cleaned(_ original: String) -> String {
        var s = original
        if !find.isEmpty {
            if useRegex, let re = try? NSRegularExpression(pattern: find) {
                s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: replace)
            } else if !useRegex {
                s = s.replacingOccurrences(of: find, with: replace)
            }
        }
        if stripBrackets {
            s = s.replacingOccurrences(of: "[\\[【(（][^\\]】)）]*[\\]】)）]", with: " ", options: .regularExpression)
        }
        return s
    }

    /// The output base name (no extension). Metadata tokens show a placeholder when `comic` is nil (previews).
    func name(original: String, index: Int, total: Int, comic: Comic?, format: OutputFormat) -> String {
        let number = start + index
        let digits = padding > 0 ? padding : max(2, String(start + max(total, 1) - 1).count)
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        let values: [String: String] = [
            "{原名}": cleaned(original),
            "{标题}": comic.map { cleaned($0.title) } ?? "‹标题›",
            "{作者}": comic.map { $0.authors.joined(separator: "、") } ?? "‹作者›",
            "{序号}": String(format: "%0\(digits)d", number),
            "{页数}": comic.map { String($0.pages.count) } ?? "‹页数›",
            "{格式}": format == .folder ? "图片" : format.rawValue.uppercased(),
            "{日期}": date.string(from: Date()),
        ]
        // One pass over the template, so token-like text inside a title or file name stays literal.
        let template = normalizedTemplate
        let re = try! NSRegularExpression(pattern: "\\{(原名|标题|作者|序号|页数|格式|日期)\\}")
        var s = "", last = template.startIndex
        for m in re.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            let r = Range(m.range, in: template)!
            s += template[last..<r.lowerBound] + values[String(template[r])]!
            last = r.upperBound
        }
        s += template[last...]
        s = Self.sanitize(s)
        if s.isEmpty { s = Self.sanitize(original) }
        return s.isEmpty ? "未命名" : s
    }

    /// Makes a string safe as a macOS file name: no path separators or control characters, no leading
    /// dot, collapsed whitespace, trimmed separators left behind by empty tokens, at most 200 UTF-8 bytes.
    static func sanitize(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-_·.,，、")))
        while s.utf8.count > 200 { s.removeLast() }
        return s
    }
}
