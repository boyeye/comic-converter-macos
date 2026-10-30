import Foundation
import zlib

/// CBZ/CBR/CB7/CBT and plain image folders.
enum Archive {
    static let bsdtar = "/usr/bin/tar"

    static let maxEntries = 100_000
    static let maxListingBytes = 64 << 20
    /// Ceiling on bytes an archive may expand to. COMICCONV_MAX_EXPAND_MB can lower it, never raise it.
    static var maxExpandedBytes: Int64 {
        let ceiling: Int64 = 20 << 30
        // Clamp in megabytes before converting, so an absurd value cannot overflow the shift.
        let mb = ProcessInfo.processInfo.environment["COMICCONV_MAX_EXPAND_MB"].flatMap(Int64.init).map { min(max($0, 1), ceiling >> 20) }
        return mb.map { $0 << 20 } ?? ceiling
    }
    static let minFreeBytes: Int64 = 1 << 30
    /// Largest single page accepted from an archive.
    static let maxPageBytes = 512 << 20

    static func extract(_ archive: URL, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let limit = maxExpandedBytes
        let declared = try declaredSize(archive)
        guard let free = freeSpace(dir) else { throw ConvertError.tool("无法查询磁盘剩余空间") }
        guard declared <= limit else { throw ConvertError.invalid("压缩包解开后约 \(declared >> 20) MB，超过 \(limit >> 20) MB 上限") }
        guard declared + minFreeBytes <= free else { throw ConvertError.invalid("磁盘剩余空间不足以解开压缩包（需要约 \(declared >> 20) MB）") }
        try extractWatched(archive, to: dir, limit: limit)
        try removeSymlinks(in: dir)
    }

    /// nil when the volume cannot be queried; callers refuse rather than assume space is unlimited.
    static func freeSpace(_ dir: URL) -> Int64? {
        try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    /// Sums the sizes the archive declares, streaming bsdtar's listing so an archive with millions of
    /// entries is stopped early instead of buffered. Any line that cannot be parsed rejects the archive:
    /// an entry of unknown size must not count as zero.
    static func declaredSize(_ archive: URL) throws -> Int64 {
        // bsdtar -tv --numeric-owner (LC_ALL=C): mode links uid gid SIZE Mon DD HH:MM|YYYY name. Numeric ids
        // leave no free text before the size, so owner names cannot fake a size field.
        let re = try! NSRegularExpression(pattern: "^\\S+\\s+\\d+\\s+\\d+\\s+\\d+\\s+(\\d+)\\s+[A-Z][a-z]{2}\\s+\\d{1,2}\\s+(?:\\d{1,2}:\\d{2}|\\d{4})\\s")
        var entries = 0, total: Int64 = 0, failure: ConvertError?
        try streamLines(bsdtar, ["-t", "-v", "--numeric-owner", "-f", archive.path], name: "读取压缩包目录", environment: ["LC_ALL": "C"],
                        maxBytes: maxListingBytes) { line in
            entries += 1
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let size = Int64(ns.substring(with: m.range(at: 1))) else {
                failure = .invalid("无法识别压缩包目录中的条目：\(line.prefix(120))"); return false
            }
            // A crafted header can declare a size near Int64.max; overflow must reject, not trap.
            let (sum, overflow) = total.addingReportingOverflow(size)
            if overflow { failure = .invalid("压缩包声明的大小异常"); return false }
            total = sum
            if entries > maxEntries { failure = .invalid("压缩包内文件超过 \(maxEntries) 个"); return false }
            if total > maxExpandedBytes { failure = .invalid("压缩包解开后超过 \(maxExpandedBytes >> 20) MB 上限"); return false }
            return true
        }
        if let failure { throw failure }
        return total
    }

    /// Runs the extraction while watching what it actually writes: the declared sizes are a promise the
    /// archive makes, not one bsdtar enforces for every format. Exceeding `limit` bytes on disk, or
    /// leaving less than 1 GB free, stops bsdtar and discards the partial output.
    static func extractWatched(_ archive: URL, to dir: URL, limit: Int64) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bsdtar)
        // Without -P bsdtar refuses absolute paths, ".." components, hard links leaving the target and
        // extraction through symlinks.
        p.arguments = ["-x", "-f", archive.path, "-C", dir.path]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        try p.run()
        let reader = drain(pipe)
        // Free space is cheap to read, so it is checked every tick; walking the tree costs more and runs
        // once a second. Both are checked again after bsdtar exits.
        func check(walk: Bool) -> String? {
            guard let free = freeSpace(dir) else { return "无法查询磁盘剩余空间" }
            if free < minFreeBytes { return "解压时磁盘剩余空间低于 1 GB" }
            guard walk else { return nil }
            guard let used = usage(dir) else { return "无法统计解出的数据量" }
            return used > limit ? "实际解出的数据超过 \(limit >> 20) MB 上限" : nil
        }
        var exceeded: String?, tick = 0
        while p.isRunning {
            Thread.sleep(forTimeInterval: 0.2)
            tick += 1
            exceeded = check(walk: tick % 5 == 0)
            if exceeded != nil { p.terminate(); break }
        }
        p.waitUntilExit()
        let output = reader()
        if exceeded == nil { exceeded = check(walk: true) }
        if let exceeded {
            try? FileManager.default.removeItem(at: dir)
            throw ConvertError.invalid(exceeded + "，已停止并删除解出的内容")
        }
        guard p.terminationStatus == 0 else {
            let tail = String(decoding: output, as: UTF8.self).split(separator: "\n").suffix(3).joined(separator: " ")
            throw ConvertError.tool("解压失败（退出码 \(p.terminationStatus)）：\(tail)")
        }
    }

    /// The larger of logical size and disk allocation over the tree: sparse or compressed files allocate
    /// little but read back huge. nil when any entry cannot be measured, so the caller fails closed.
    static func usage(_ dir: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        var failed = false
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in failed = true; return true }) else { return nil }
        var logical: Int64 = 0, allocated: Int64 = 0
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
            guard let regular = v.isRegularFile else { return nil }
            guard regular else { continue }
            guard let size = v.fileSize, let alloc = v.totalFileAllocatedSize else { return nil }
            let (l, o1) = logical.addingReportingOverflow(Int64(size)), (a, o2) = allocated.addingReportingOverflow(Int64(alloc))
            if o1 || o2 { return nil }
            logical = l; allocated = a
        }
        return failed ? nil : max(logical, allocated)
    }

    /// Archives may carry symlinks pointing anywhere on disk; following one would copy a local file
    /// into the output. Pages never need them, so every symlink is deleted before anything is read.
    static func removeSymlinks(in dir: URL) throws {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func read(_ url: URL, work: URL) throws -> Comic {
        let dir = work.appendingPathComponent("archive", isDirectory: true)
        try extract(url, to: dir)
        var comic = Comic(title: url.deletingPathExtension().lastPathComponent, pages: Images.collect(in: dir))
        if let big = comic.pages.first(where: { ((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max) > maxPageBytes }) {
            throw ConvertError.invalid("页面 \(big.lastPathComponent) 超过 \(maxPageBytes >> 20) MB，不像是漫画页")
        }
        ComicInfo.read(from: dir, into: &comic)
        return comic
    }

    static func readFolder(_ url: URL) -> Comic {
        var comic = Comic(title: url.lastPathComponent, pages: Images.collect(in: url))
        ComicInfo.read(from: url, into: &comic)
        return comic
    }

    /// Copies pages under sequential names so every output sorts the same in any reader.
    static func stage(_ comic: Comic, in dir: URL, comicInfo: Bool) throws -> [String] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var names: [String] = []
        for (i, page) in comic.pages.enumerated() {
            let name = Images.pageName(i, of: comic.pages.count, kind: Images.kind(of: page))
            try FileManager.default.copyItem(at: page, to: dir.appendingPathComponent(name))
            names.append(name)
        }
        if comicInfo {
            try Data(ComicInfo.xml(for: comic).utf8).write(to: dir.appendingPathComponent("ComicInfo.xml"))
            names.append("ComicInfo.xml")
        }
        return names
    }

    static func writeTar(_ comic: Comic, format: String, to out: URL, work: URL) throws {
        let dir = work.appendingPathComponent("stage", isDirectory: true)
        let names = try stage(comic, in: dir, comicInfo: true)
        try runTool(bsdtar, ["--format", format, "-c", "-f", out.path, "-C", dir.path] + names, name: "打包")
    }

    static func writeRar(_ comic: Comic, rar: String, to out: URL, work: URL) throws {
        let dir = work.appendingPathComponent("stage", isDirectory: true)
        let names = try stage(comic, in: dir, comicInfo: true)
        // a: add, -m0: store (pages are already compressed), -ep1: drop the staging path, -idq: quiet.
        try runTool(rar, ["a", "-m0", "-ep1", "-idq", out.path] + names.map { dir.appendingPathComponent($0).path }, name: "RAR 打包")
    }

    static func writeZip(_ comic: Comic, to out: URL) throws {
        let zip = try ZipWriter(url: out)
        for (i, page) in comic.pages.enumerated() {
            try zip.add(Images.pageName(i, of: comic.pages.count, kind: Images.kind(of: page)), data: Data(contentsOf: page, options: .mappedIfSafe))
        }
        try zip.add("ComicInfo.xml", data: Data(ComicInfo.xml(for: comic).utf8))
        try zip.finish()
    }
}

/// Minimal streaming ZIP writer. Entries are stored, not deflated: page images are already
/// compressed, and EPUB requires an uncompressed leading `mimetype` entry.
final class ZipWriter {
    private let handle: FileHandle
    private var central: [UInt8] = []
    private var count = 0, offset = 0
    private let time: Int, date: Int

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ConvertError.tool("无法创建 \(url.lastPathComponent)") }
        handle = try FileHandle(forWritingTo: url)
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        time = c.hour! << 11 | c.minute! << 5 | c.second! / 2
        date = (c.year! - 1980) << 9 | c.month! << 5 | c.day!
    }

    func add(_ name: String, data: Data) throws {
        let n = Array(name.utf8)
        // Everything up to the start of the central directory must stay addressable with 32 bits.
        guard count < 0xFFFF, offset + 30 + n.count + data.count < 0xFFFF_FFFF else {
            throw ConvertError.unsupported("ZIP 输出超过 4 GB 或 65535 个文件")
        }
        let crc = data.withUnsafeBytes { Int(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
        var local: [UInt8] = []
        local.le32(0x0403_4b50); local.le16(20); local.le16(0x0800); local.le16(0); local.le16(time); local.le16(date)
        local.le32(crc); local.le32(data.count); local.le32(data.count); local.le16(n.count); local.le16(0); local += n
        central.le32(0x0201_4b50); central.le16(0x0314); central.le16(20); central.le16(0x0800); central.le16(0)
        central.le16(time); central.le16(date); central.le32(crc); central.le32(data.count); central.le32(data.count)
        central.le16(n.count); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
        central.le32(0o100644 << 16); central.le32(offset); central += n
        try handle.write(contentsOf: local)
        try handle.write(contentsOf: data)
        offset += local.count + data.count
        count += 1
    }

    func finish() throws {
        guard central.count < 0xFFFF_FFFF else { throw ConvertError.unsupported("ZIP 目录超过 4 GB") }
        var end: [UInt8] = []
        end.le32(0x0605_4b50); end.le16(0); end.le16(0); end.le16(count); end.le16(count)
        end.le32(central.count); end.le32(offset); end.le16(0)
        try handle.write(contentsOf: central + end)
        try handle.close()
    }
}

/// ComicRack metadata, understood by most CBZ readers (Komga, Kavita, Panels, YACReader…).
enum ComicInfo {
    static func xml(for c: Comic) -> String {
        var s = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<ComicInfo xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">\n"
        s += "  <Title>\(xmlEscape(c.title))</Title>\n"
        if !c.authors.isEmpty { s += "  <Writer>\(xmlEscape(c.authors.joined(separator: ", ")))</Writer>\n" }
        s += "  <PageCount>\(c.pages.count)</PageCount>\n"
        s += "  <Manga>\(c.rightToLeft ? "YesAndRightToLeft" : "No")</Manga>\n</ComicInfo>\n"
        return s
    }

    static func read(from dir: URL, into comic: inout Comic) {
        // Several candidates: the shallowest one describes the whole book.
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil),
              let url = e.compactMap({ $0 as? URL }).filter({ $0.lastPathComponent.lowercased() == "comicinfo.xml" })
                .min(by: { ($0.pathComponents.count, $0.path) < ($1.pathComponents.count, $1.path) }),
              let text = try? readContained(url, in: dir, limit: 1 << 20) else { return }
        func tag(_ name: String) -> String? {
            matches("<\(name)>(.*?)</\(name)>", in: text).first.map { xmlUnescape($0).trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let t = tag("Title") ?? tag("Series") { comic.title = t }
        if let w = tag("Writer") { comic.authors = w.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        if tag("Manga") == "YesAndRightToLeft" { comic.rightToLeft = true }
    }
}
