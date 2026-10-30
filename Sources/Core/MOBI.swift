import Foundation

/// MOBI / AZW / AZW3 (KF8) / PRC: PalmDB containers whose images live in their own records.
enum MOBIComic {
    // MARK: Reading

    static func read(_ url: URL, work: URL) throws -> Comic {
        let bytes = [UInt8](try Data(contentsOf: url))
        if bytes.has("CONT", at: 0) || bytes.starts(with: [0xEA] + Array("DRMION".utf8)) {
            throw ConvertError.unsupported("KFX 格式。请先用 Calibre 的 KFX Input 插件转成 AZW3 或 EPUB")
        }
        let db = try PalmDB(bytes)
        guard db.type == "BOOKMOBI" else { throw ConvertError.invalid("不是 MOBI 电子书（类型 \(db.type)）") }
        let first = try Header(db.record(0))

        // Joint MOBI7+KF8 files carry the KF8 section after a boundary record; prefer it.
        var section = first, base = 0
        if let b = first.exthInt(121), b > 0, b < db.count, let k8 = try? Header(db.record(b)) { section = k8; base = b }
        if first.encryption != 0 || section.encryption != 0 { throw ConvertError.drm("MOBI 加密类型 \(max(first.encryption, section.encryption))") }

        var comic = Comic(title: first.title ?? url.deletingPathExtension().lastPathComponent)
        comic.authors = first.exthStrings(100)
        comic.rightToLeft = (first.exthStrings(527).first ?? section.exthStrings(527).first) == "rtl"

        // recindex / kindle:embed number every record from the first resource on (images, fonts, RESC,
        // placeholders…), not just images. Joint files share one resource block indexed from the MOBI6 header.
        let resources = [first.firstImage, base + section.firstImage].first { $0 > 0 && $0 < db.count }
        var order: [Int] = []
        if let resources {
            do {
                let text = String(decoding: try section.text(db, base: base), as: UTF8.self)
                let refs = section.version >= 8
                    ? matches("kindle:embed:([0-9A-Va-v]{4})", in: text).compactMap { Int($0, radix: 32) }
                    : matches("recindex\\s*=\\s*[\"']?(\\d+)", in: text).compactMap { Int($0) }
                order = refs.map { resources + $0 - 1 }
            } catch {
                comic.warnings.append("正文无法解码（\(error.localizedDescription)），已按图片记录顺序排列")
            }
        }
        var seen = Set<Int>()
        order = order.filter { image(db.record($0)) != nil && seen.insert($0).inserted }
        if order.isEmpty {
            // No usable references: take every image record outside the text, in record order.
            let text = Set((1...max(1, first.textRecords)).map { $0 } + (base > 0 ? (base...base + section.textRecords).map { $0 } : []))
            let thumb = resources.flatMap { r in first.exthInt(202).map { r + $0 } }
            order = (1..<db.count).filter { !text.contains($0) && $0 != thumb && image(db.record($0)) != nil }
            if !order.isEmpty, comic.warnings.isEmpty { comic.warnings.append("正文中没有可用的图片引用，已按图片记录顺序排列") }
        }
        guard !order.isEmpty else {
            let placeholders = (1..<db.count).contains { db.record($0).starts(with: [0xA0, 0xA0, 0xA0, 0xA0]) }
            throw ConvertError.invalid(placeholders
                ? "书中的图片只是占位符，高清图片存放在配套的 .azw.res 文件里（Kindle 商店书籍常见），本文件本身不含图片"
                : "书中没有图片记录（可能是纯文字电子书）")
        }

        let dir = work.appendingPathComponent("mobi", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, rec) in order.enumerated() {
            let (data, kind) = image(db.record(rec))!
            let file = dir.appendingPathComponent(String(format: "%05d", i + 1)).appendingPathExtension(kind)
            try Data(data).write(to: file)
            comic.pages.append(file)
        }
        return comic
    }

    /// Image bytes of a resource record; CRES records wrap an HD image behind a 12-byte header.
    private static func image(_ record: [UInt8]) -> ([UInt8], String)? {
        let data = record.has("CRES", at: 0) && record.count > 12 ? Array(record[12...]) : record
        return Images.sniff(Array(data.prefix(16))).map { (data, $0) }
    }

    /// A content-free structural summary, for diagnosing books that fail to convert.
    static func inspect(_ url: URL) throws -> String {
        let bytes = [UInt8](try Data(contentsOf: url))
        if bytes.has("CONT", at: 0) || bytes.starts(with: [0xEA] + Array("DRMION".utf8)) { return "KFX 容器（不支持）" }
        let db = try PalmDB(bytes)
        var lines = ["文件大小 \(bytes.count) 字节，PalmDB 类型 \(db.type)，记录数 \(db.count)"]
        guard db.type == "BOOKMOBI" else { return lines.joined(separator: "\n") }
        let first = try Header(db.record(0))
        func describe(_ h: Header, _ name: String) -> String {
            "\(name)：版本 \(h.version)，压缩 \(h.compression)，加密 \(h.encryption)，正文记录 \(h.textRecords)，首资源 \(h.firstImage)，附加标志 0x\(String(h.extraFlags, radix: 16))"
        }
        lines.append(describe(first, "主头部"))
        if let b = first.exthInt(121), b > 0, b < db.count, let k8 = try? Header(db.record(b)) { lines.append(describe(k8, "KF8 段（记录 \(b)）")) }
        var kinds: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        for i in 1..<db.count {
            let r = db.record(i)
            let kind: String
            if let (_, k) = image(r) { kind = r.has("CRES", at: 0) ? "CRES/\(k)" : k }
            else if r.starts(with: [0xA0, 0xA0, 0xA0, 0xA0]) { kind = "占位符" }
            else if r.count >= 4, r.prefix(4).allSatisfy({ (0x41...0x5A).contains($0) }) { kind = String(decoding: r.prefix(4), as: UTF8.self) }
            else if r == [0xE9, 0x8E, 0x0D, 0x0A] { kind = "EOF" }
            else { kind = "其他" }
            kinds[kind, default: 0] += 1
            if firstSeen[kind] == nil { firstSeen[kind] = i }
        }
        lines.append("记录类型：" + kinds.sorted { firstSeen[$0.key]! < firstSeen[$1.key]! }.map { "\($0.key)×\($0.value)（首次在 \(firstSeen[$0.key]!)）" }.joined(separator: "，"))
        return lines.joined(separator: "\n")
    }

    struct PalmDB {
        let bytes: [UInt8], offsets: [Int], type: String

        init(_ b: [UInt8]) throws {
            guard b.count >= 78 else { throw ConvertError.invalid("文件太小") }
            let n = b.be16(76)
            guard n > 0, 78 + 8 * n <= b.count else { throw ConvertError.invalid("PalmDB 记录表损坏") }
            offsets = (0..<n).map { b.be32(78 + 8 * $0) }
            guard zip(offsets, offsets.dropFirst()).allSatisfy({ $0 <= $1 }), offsets.last! <= b.count, offsets[0] >= 78 + 8 * n else {
                throw ConvertError.invalid("PalmDB 记录偏移异常")
            }
            type = String(decoding: b[60..<68], as: UTF8.self)
            bytes = b
        }

        var count: Int { offsets.count }

        func record(_ i: Int) -> [UInt8] {
            guard i >= 0, i < count else { return [] }
            return Array(bytes[offsets[i]..<(i + 1 < count ? offsets[i + 1] : bytes.count)])
        }
    }

    struct Header {
        let compression, textRecords, encryption, version, encoding, firstImage, extraFlags: Int
        let title: String?
        private(set) var exth: [Int: [[UInt8]]] = [:]

        init(_ r: [UInt8]) throws {
            guard r.count >= 116, r.has("MOBI", at: 16) else { throw ConvertError.invalid("缺少 MOBI 头") }
            compression = r.be16(0); textRecords = r.be16(8); encryption = r.be16(12)
            let length = r.be32(20)
            encoding = r.be32(28); version = r.be32(36); firstImage = r.be32(108)
            extraFlags = length >= 0xE4 && r.count >= 0xF4 ? r.be16(0xF2) : 0
            if r.be32(128) & 0x40 != 0, r.has("EXTH", at: 16 + length) {
                var p = 16 + length + 12
                for _ in 0..<r.be32(16 + length + 8) {
                    let type = r.be32(p), size = r.be32(p + 4)
                    guard size >= 8, p + size <= r.count else { break }
                    exth[type, default: []].append(Array(r[(p + 8)..<(p + size)]))
                    p += size
                }
            }
            let nameOffset = r.be32(84), nameLength = r.be32(88)
            let name = nameLength > 0 && nameOffset + nameLength <= r.count ? Array(r[nameOffset..<nameOffset + nameLength]) : []
            let enc = encoding
            title = ((exth[503] ?? []) + [name]).map { Header.decode($0, encoding: enc).trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        }

        static func decode(_ b: [UInt8], encoding: Int) -> String {
            encoding == 65001 ? String(decoding: b, as: UTF8.self) : String(bytes: b, encoding: .windowsCP1252) ?? ""
        }

        func exthStrings(_ type: Int) -> [String] {
            (exth[type] ?? []).map { Header.decode($0, encoding: encoding).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        func exthInt(_ type: Int) -> Int? { exth[type]?.first.flatMap { $0.count == 4 ? $0.be32(0) : nil } }

        func text(_ db: PalmDB, base: Int) throws -> [UInt8] {
            guard compression == 1 || compression == 2 else { throw ConvertError.unsupported("HUFF/CDIC 压缩正文") }
            var out: [UInt8] = []
            for i in stride(from: 1, through: textRecords, by: 1) {
                let rec = trimTrailing(db.record(base + i))
                out += compression == 2 ? palmDoc(rec) : rec
            }
            return out
        }

        /// Strips the per-record trailing entries announced by the extra-data flags.
        private func trimTrailing(_ rec: [UInt8]) -> [UInt8] {
            var end = rec.count
            var flags = extraFlags >> 1
            while flags != 0 {
                if flags & 1 != 0 {
                    var size = 0
                    for b in rec[max(0, end - 4)..<end] {
                        if b & 0x80 != 0 { size = 0 }
                        size = size << 7 | Int(b & 0x7F)
                    }
                    end -= min(size, end)
                }
                flags >>= 1
            }
            if extraFlags & 1 != 0, end > 0 { end -= min(Int(rec[end - 1] & 3) + 1, end) }
            return Array(rec[0..<end])
        }
    }

    static func palmDoc(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(4096)
        var i = 0
        while i < input.count {
            let c = input[i]; i += 1
            switch c {
            case 1...8:
                out += input[i..<min(i + Int(c), input.count)]; i += Int(c)
            case 0x80...0xBF:
                guard i < input.count else { return out }
                let v = (Int(c) << 8 | Int(input[i])) & 0x3FFF; i += 1
                let distance = v >> 3
                guard distance > 0, distance <= out.count else { return out }
                for _ in 0..<(v & 7) + 3 { out.append(out[out.count - distance]) }
            case 0xC0...0xFF:
                out += [0x20, c ^ 0x80]
            default:
                out.append(c)
            }
        }
        return out
    }

    // MARK: Writing

    /// Writes a MOBI 6 (pre-KF8) book: one `<img recindex>` per page separated by page breaks.
    static func write(_ comic: inout Comic, to out: URL, work: URL) throws {
        let pages = try Images.prepare(comic.pages, allowed: ["jpg", "png", "gif"], in: work.appendingPathComponent("mobi-images"), warnings: &comic.warnings)
        let images = try pages.map { [UInt8](try Data(contentsOf: $0.url)) }
        if images.contains(where: { $0.count > 127 * 1024 }) {
            comic.warnings.append("部分图片超过 127 KB；旧款 Kindle 对 MOBI 可能不显示，可改用 AZW3 或 EPUB")
        }
        var html = "<html><head></head><body>"
        for i in images.indices {
            html += "<p><img recindex=\"\(String(format: "%05d", i + 1))\" /></p>" + (i < images.count - 1 ? "<mbp:pagebreak />" : "")
        }
        let text = Array((html + "</body></html>").utf8)
        let chunks = stride(from: 0, to: text.count, by: 4096).map { Array(text[$0..<min($0 + 4096, text.count)]) }
        let firstImage = chunks.count + 1
        let flis = firstImage + images.count

        var fcis: [UInt8] = Array("FCIS".utf8) + [0, 0, 0, 0x14, 0, 0, 0, 0x10, 0, 0, 0, 1, 0, 0, 0, 0]
        fcis.put32(text.count)
        fcis += [0, 0, 0, 0, 0, 0, 0, 0x20, 0, 0, 0, 8, 0, 1, 0, 1, 0, 0, 0, 0]
        let flisRecord: [UInt8] = Array("FLIS".utf8) + [0, 0, 0, 8, 0, 0x41, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF,
                                                        0, 1, 0, 3, 0, 0, 0, 3, 0, 0, 0, 1, 0xFF, 0xFF, 0xFF, 0xFF]
        var records: [[UInt8]] = [[]] + chunks + images + [flisRecord, fcis, [0xE9, 0x8E, 0x0D, 0x0A]]

        // Record 0: PalmDOC header, 232-byte MOBI header, EXTH, full name.
        var r = [UInt8](repeating: 0, count: 16 + 0xE8)
        r.set16(0, 1); r.set32(4, text.count); r.set16(8, chunks.count); r.set16(10, 4096)
        r.replaceSubrange(16..<20, with: Array("MOBI".utf8))
        r.set32(20, 0xE8); r.set32(24, 2); r.set32(28, 65001); r.set32(32, Int.random(in: 1..<0x7FFF_FFFF)); r.set32(36, 6)
        for o in stride(from: 40, to: 80, by: 4) { r.set32(o, 0xFFFF_FFFF) }
        r.set32(80, firstImage); r.set32(104, 6); r.set32(108, firstImage); r.set32(128, 0x50)
        r.set32(164, 0xFFFF_FFFF)
        r.set16(192, 1); r.set16(194, flis - 1); r.set32(196, 1); r.set32(200, flis + 1); r.set32(204, 1)
        r.set32(208, flis); r.set32(212, 1); r.set32(224, 0xFFFF_FFFF); r.set32(232, 0xFFFF_FFFF)
        r.set32(236, 0xFFFF_FFFF); r.set32(244, 0xFFFF_FFFF)

        var entries: [(Int, [UInt8])] = comic.authors.map { (100, Array($0.utf8)) } + [(503, Array(comic.title.utf8))]
        var zero: [UInt8] = []; zero.put32(0)
        entries += [(201, zero), (203, zero)]
        if comic.rightToLeft { entries += [(525, Array("horizontal-rl".utf8)), (527, Array("rtl".utf8))] }
        var exth: [UInt8] = []
        for (type, value) in entries { exth.put32(type); exth.put32(value.count + 8); exth += value }
        var block = Array("EXTH".utf8)
        block.put32(exth.count + 12); block.put32(entries.count); block += exth
        block += [UInt8](repeating: 0, count: (4 - block.count % 4) % 4)
        let name = Array(comic.title.utf8)
        r.set32(84, r.count + block.count); r.set32(88, name.count)
        r += block + name + [0, 0]
        r += [UInt8](repeating: 0, count: (4 - r.count % 4) % 4)
        records[0] = r

        var file = Array(comic.title.unicodeScalars.map { $0.isASCII && $0.value > 32 ? UInt8($0.value) : UInt8(ascii: "_") }.prefix(31))
        file += [UInt8](repeating: 0, count: 32 - file.count)
        let now = Int(Date().timeIntervalSince1970)
        file.put16(0); file.put16(0); file.put32(now); file.put32(now); file.put32(0); file.put32(0); file.put32(0); file.put32(0)
        file += Array("BOOKMOBI".utf8)
        file.put32(2 * records.count - 1); file.put32(0); file.put16(records.count)
        var offset = 78 + 8 * records.count + 2
        for (i, rec) in records.enumerated() {
            file.put32(offset); file.put32(2 * i)
            offset += rec.count
        }
        file += [0, 0]
        guard FileManager.default.createFile(atPath: out.path, contents: nil) else { throw ConvertError.tool("无法创建 \(out.lastPathComponent)") }
        let h = try FileHandle(forWritingTo: out)
        try h.write(contentsOf: file)
        for rec in records { try h.write(contentsOf: rec) }
        try h.close()
    }
}
