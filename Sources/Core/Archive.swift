import Foundation
import zlib

/// CBZ/CBR/CB7/CBT and plain image folders.
enum Archive {
    static let bsdtar = "/usr/bin/tar"

    static func extract(_ archive: URL, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // macOS bsdtar (libarchive) reads zip, rar/rar5, 7z and tar. Without -P it refuses absolute
        // paths, ".." components and extraction through symlinks.
        try runTool(bsdtar, ["-x", "-f", archive.path, "-C", dir.path], name: "解压")
    }

    static func read(_ url: URL, work: URL) throws -> Comic {
        let dir = work.appendingPathComponent("archive", isDirectory: true)
        try extract(url, to: dir)
        var comic = Comic(title: url.deletingPathExtension().lastPathComponent, pages: Images.collect(in: dir))
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
        guard data.count < 0xFFFF_FFFF, offset + data.count < 0xFFFF_FFFF, count < 0xFFFF else { throw ConvertError.unsupported("ZIP 输出超过 4 GB 或 65535 个文件") }
        let n = Array(name.utf8)
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
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil),
              let url = e.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent.lowercased() == "comicinfo.xml" }),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        func tag(_ name: String) -> String? {
            matches("<\(name)>(.*?)</\(name)>", in: text).first.map { xmlUnescape($0).trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let t = tag("Title") ?? tag("Series") { comic.title = t }
        if let w = tag("Writer") { comic.authors = w.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        if tag("Manga") == "YesAndRightToLeft" { comic.rightToLeft = true }
    }
}
