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

/// Runs a helper tool and returns its combined output, folding the output into the error when it fails.
@discardableResult
func runTool(_ path: String, _ args: [String], name: String, environment: [String: String]? = nil) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let environment { p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let reader = drain(pipe)
    p.waitUntilExit()
    let output = reader()
    guard p.terminationStatus == 0 else {
        let tail = String(decoding: output, as: UTF8.self).split(separator: "\n").suffix(3).joined(separator: " ")
        throw ConvertError.tool("\(name)失败（退出码 \(p.terminationStatus)）：\(tail)")
    }
    return String(decoding: output, as: UTF8.self)
}

let workDirectoryPrefix = "ComicConverter-"

func makeWorkDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(workDirectoryPrefix + UUID().uuidString, isDirectory: true)
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
func matches(_ pattern: String, in text: String, multiline: Bool = false) -> [String] {
    let options: NSRegularExpression.Options = multiline ? [.anchorsMatchLines] : [.caseInsensitive, .dotMatchesLineSeparators]
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
        $0.range(at: 1).location == NSNotFound ? nil : ns.substring(with: $0.range(at: 1))
    }
}

/// Work directories left behind by a crash or forced quit; anything older than a day is no longer in use.
func sweepStaleWorkDirectories(olderThan age: TimeInterval = 24 * 3600) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    // Only names this app creates (prefix + UUID) and only directories.
    let pattern = "^" + workDirectoryPrefix + "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"
    for url in entries where url.lastPathComponent.range(of: pattern, options: .regularExpression) != nil && isDirectory(url) {
        if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(date) > age {
            try? fm.removeItem(at: url)
        }
    }
}

/// Reads a regular file that must lie inside `root`, refusing more than `limit` bytes. The checks and the
/// read act on one open descriptor (no symlink as the last component, real path from the descriptor),
/// so the file cannot be swapped between checking and reading.
func readContainedData(_ url: URL, in root: URL, limit: Int) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw ConvertError.invalid("无法打开 \(url.lastPathComponent)") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw ConvertError.invalid("\(url.lastPathComponent) 不是普通文件") }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(fd, F_GETPATH, &buffer) == 0, let base = realpath(root.path, nil) else { throw ConvertError.invalid("无法确认 \(url.lastPathComponent) 的位置") }
    let rootPath = String(cString: base)
    free(base)
    guard String(cString: buffer).hasPrefix(rootPath + "/") else { throw ConvertError.invalid("\(url.lastPathComponent) 位于书籍目录之外") }
    guard st.st_size <= limit else { throw ConvertError.invalid("\(url.lastPathComponent) 过大（\(st.st_size >> 20) MB）") }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw ConvertError.invalid("\(url.lastPathComponent) 过大") }
    return data
}

func readContained(_ url: URL, in root: URL, limit: Int = 16 << 20) throws -> String {
    String(decoding: try readContainedData(url, in: root, limit: limit), as: UTF8.self)
}

/// Reads a pipe to EOF on a background queue so the child never blocks on a full pipe, keeping only
/// the first `keep` bytes. Call the returned function after the process exits to collect them.
func drain(_ pipe: Pipe, keep: Int = 64 << 10) -> () -> Data {
    var kept = Data()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let h = pipe.fileHandleForReading
        while true {
            let chunk = h.availableData
            if chunk.isEmpty { break }
            if kept.count < keep { kept += chunk.prefix(keep - kept.count) }
        }
        done.signal()
    }
    return { done.wait(); return kept }
}

/// Streams a tool's stdout line by line; `onLine` returns false to stop early, which terminates the tool.
/// Output beyond `maxBytes` also terminates it.
func streamLines(_ path: String, _ args: [String], name: String, environment: [String: String], maxBytes: Int,
                 onLine: (String) -> Bool) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
    try p.run()
    let errReader = drain(err)
    var pending = Data(), seen = 0, stopped = false
    let handle = out.fileHandleForReading
    reading: while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        seen += chunk.count
        if seen > maxBytes { stopped = true; break }
        pending += chunk
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
            pending = Data(pending[(nl + 1)...])
            if !onLine(line) { stopped = true; break reading }
        }
    }
    if stopped { p.terminate() }
    p.waitUntilExit()
    let errData = errReader()
    if seen > maxBytes { throw ConvertError.invalid("\(name)：输出超过 \(maxBytes >> 20) MB") }
    if !stopped, !pending.isEmpty { _ = onLine(String(decoding: pending, as: UTF8.self)) }
    guard stopped || p.terminationStatus == 0 else {
        let tail = String(decoding: errData, as: UTF8.self).split(separator: "\n").suffix(3).joined(separator: " ")
        throw ConvertError.tool("\(name)失败（退出码 \(p.terminationStatus)）：\(tail)")
    }
}

func isDirectory(_ url: URL) -> Bool {
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
}
