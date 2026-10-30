import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum Images {
    static let extensions: Set<String> = ["jpg", "jpeg", "jpe", "png", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "avif", "jp2", "jxl"]

    /// Detects the real format from the file header; extensions inside comic archives are often wrong.
    static func kind(of url: URL) -> String {
        if let h = try? FileHandle(forReadingFrom: url) {
            defer { try? h.close() }
            if let d = try? h.read(upToCount: 16), let k = sniff([UInt8](d)) { return k }
        }
        let e = url.pathExtension.lowercased()
        return ["jpeg": "jpg", "jpe": "jpg", "tiff": "tif", "heif": "heic"][e] ?? e
    }

    static func sniff(_ b: [UInt8]) -> String? {
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.has("GIF8", at: 0) { return "gif" }
        if b.has("RIFF", at: 0) && b.has("WEBP", at: 8) { return "webp" }
        if b.starts(with: [0x49, 0x49, 0x2A, 0]) || b.starts(with: [0x4D, 0x4D, 0, 0x2A]) { return "tif" }
        if b.starts(with: [0, 0, 0, 0x0C, 0x6A, 0x50, 0x20, 0x20]) || b.starts(with: [0xFF, 0x4F, 0xFF, 0x51]) { return "jp2" }
        if b.starts(with: [0xFF, 0x0A]) || b.starts(with: [0, 0, 0, 0x0C, 0x4A, 0x58, 0x4C, 0x20]) { return "jxl" }
        if b.has("ftyp", at: 4), b.count >= 12 {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if brand.hasPrefix("avi") { return "avif" }
            if ["heic", "heix", "mif1", "msf1", "hevc"].contains(brand) { return "heic" }
        }
        if b.has("BM", at: 0) && b.count >= 14 { return "bmp" }
        return nil
    }

    /// Image files under `dir`, recursively, in Finder's natural order (page2 before page10).
    static func collect(in dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in e {
            if url.lastPathComponent == "__MACOSX" { e.skipDescendants(); continue }
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true, v?.isSymbolicLink != true, extensions.contains(url.pathExtension.lowercased()) else { continue }
            found.append(url)
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    static func decode(_ url: URL) throws -> CGImage {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else {
            throw ConvertError.invalid("无法解码图片 \(url.lastPathComponent)")
        }
        return img
    }

    static func encode(_ img: CGImage, as kind: String, quality: Double = 0.92) throws -> Data {
        let out = NSMutableData()
        let type = (kind == "png" ? UTType.png : UTType.jpeg).identifier as CFString
        guard let d = CGImageDestinationCreateWithData(out, type, 1, nil) else { throw ConvertError.tool("无法创建图片编码器") }
        CGImageDestinationAddImage(d, img, kind == "png" ? nil : [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(d) else { throw ConvertError.tool("图片编码失败") }
        return out as Data
    }

    /// Keeps pages whose format the target accepts and re-encodes the rest: lossless sources to PNG, others to JPEG.
    static func prepare(_ pages: [URL], allowed: Set<String>, in dir: URL, warnings: inout [String]) throws -> [(url: URL, kind: String)] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var converted = 0
        let result: [(url: URL, kind: String)] = try pages.enumerated().map { i, page in
            let k = kind(of: page)
            if allowed.contains(k) { return (page, k) }
            let target = ["bmp", "tif", "png"].contains(k) ? "png" : "jpg"
            let url = dir.appendingPathComponent("t\(i).\(target)")
            try encode(decode(page), as: target).write(to: url)
            converted += 1
            return (url, target)
        }
        if converted > 0 { warnings.append("\(converted) 页图片格式不被目标格式支持，已转为 JPEG/PNG") }
        return result
    }

    static func pageName(_ index: Int, of count: Int, kind: String) -> String {
        String(format: "%0\(max(4, String(count).count))d", index + 1) + "." + kind
    }
}
