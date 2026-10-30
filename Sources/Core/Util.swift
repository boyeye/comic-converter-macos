import Foundation

enum ConvertError: LocalizedError {
    case unsupported(String), drm(String), invalid(String), tool(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let m): return "不支持：\(m)"
        case .drm(let m): return "受 DRM 保护，无法转换（\(m)）"
        case .invalid(let m): return "无法解析：\(m)"
        case .tool(let m): return m
        }
    }
}

/// A comic is an ordered list of page images plus the little metadata every format can carry.
struct Comic {
    var title: String
    var authors: [String] = []
    var rightToLeft = false
    var pages: [URL] = []
    var warnings: [String] = []
}

enum ReadingDirection: String, CaseIterable, Identifiable {
    case auto, rtl, ltr
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "保持原书设置"
        case .rtl: return "从右到左（日漫）"
        case .ltr: return "从左到右"
        }
    }
}

extension Array where Element == UInt8 {
    func be16(_ o: Int) -> Int { o >= 0 && o + 2 <= count ? Int(self[o]) << 8 | Int(self[o + 1]) : 0 }
    func be32(_ o: Int) -> Int {
        guard o >= 0, o + 4 <= count else { return 0 }
        return Int(self[o]) << 24 | Int(self[o + 1]) << 16 | Int(self[o + 2]) << 8 | Int(self[o + 3])
    }
    func has(_ ascii: String, at o: Int) -> Bool {
        let p = Array(ascii.utf8)
        return o >= 0 && o + p.count <= count && Array(self[o..<o + p.count]) == p
    }
    mutating func put16(_ v: Int) { append(contentsOf: [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]) }
    mutating func put32(_ v: Int) { put16(v >> 16); put16(v) }
    mutating func set16(_ o: Int, _ v: Int) { self[o] = UInt8(truncatingIfNeeded: v >> 8); self[o + 1] = UInt8(truncatingIfNeeded: v) }
    mutating func set32(_ o: Int, _ v: Int) { set16(o, v >> 16); set16(o + 2, v) }
    mutating func le16(_ v: Int) { append(contentsOf: [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]) }
    mutating func le32(_ v: Int) { le16(v); le16(v >> 16) }
}

/// Runs a helper tool, folding its output into the error when it fails.
func runTool(_ path: String, _ args: [String], name: String) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        let tail = String(decoding: output, as: UTF8.self).split(separator: "\n").suffix(3).joined(separator: " ")
        throw ConvertError.tool("\(name)失败（退出码 \(p.terminationStatus)）：\(tail)")
    }
}

func makeWorkDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ComicConverter-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

func xmlUnescape(_ s: String) -> String {
    s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")
}

/// All captures of group 1, in document order.
func matches(_ pattern: String, in text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
        $0.range(at: 1).location == NSNotFound ? nil : ns.substring(with: $0.range(at: 1))
    }
}

func isDirectory(_ url: URL) -> Bool {
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
}
