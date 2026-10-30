import Foundation
import CoreGraphics
import ImageIO

enum PDFComic {
    // MARK: Reading

    static func read(_ url: URL, work: URL, dpi: Double) throws -> Comic {
        guard let doc = CGPDFDocument(url as CFURL) else { throw ConvertError.invalid("无法打开 PDF") }
        if doc.isEncrypted, !doc.isUnlocked, !doc.unlockWithPassword("") { throw ConvertError.drm("PDF 需要密码") }
        let dir = work.appendingPathComponent("pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var comic = Comic(title: info(doc, "Title") ?? url.deletingPathExtension().lastPathComponent)
        if let a = info(doc, "Author") { comic.authors = [a] }
        var rendered = 0
        for n in stride(from: 1, through: doc.numberOfPages, by: 1) {
            guard let page = doc.page(at: n) else { continue }
            let base = dir.appendingPathComponent(String(format: "%05d", n))
            let (data, kind, didRender) = try pageImage(page, dpi: dpi)
            rendered += didRender ? 1 : 0
            let file = base.appendingPathExtension(kind)
            try data.write(to: file)
            comic.pages.append(file)
        }
        if rendered > 0 { comic.warnings.append("\(rendered) 页不是单张整页图片，已重新渲染") }
        return comic
    }

    private static func info(_ doc: CGPDFDocument, _ key: String) -> String? {
        var s: CGPDFStringRef?
        guard let dict = doc.info, CGPDFDictionaryGetString(dict, key, &s), let s, let text = CGPDFStringCopyTextString(s) as String? else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// A scanned page is one full-page image: copy its JPEG bytes untouched. Anything else is rendered,
    /// at the embedded image's own resolution when there is one.
    private static func pageImage(_ page: CGPDFPage, dpi: Double) throws -> (Data, String, Bool) {
        guard let image = soleImage(page), let dict = CGPDFStreamGetDictionary(image) else {
            return (try render(page, pixelWidth: nil, dpi: dpi, lossless: false), "jpg", true)
        }
        var w = 0 as CGPDFInteger, h = 0 as CGPDFInteger
        CGPDFDictionaryGetInteger(dict, "Width", &w)
        CGPDFDictionaryGetInteger(dict, "Height", &h)
        var size = page.getBoxRect(.cropBox).size
        if page.rotationAngle % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        guard w > 0, h > 0, size.width > 0, size.height > 0,
              abs(Double(w) / Double(h) - size.width / size.height) / (size.width / size.height) < 0.03 else {
            return (try render(page, pixelWidth: nil, dpi: dpi, lossless: false), "jpg", true)
        }
        var obj: CGPDFObjectRef?
        let transforms: [String] = ["SMask", "Mask", "Decode"]
        let plain = page.rotationAngle % 360 == 0 && !transforms.contains { CGPDFDictionaryGetObject(dict, $0, &obj) }
        if plain {
            var format = CGPDFDataFormat.raw
            if let data = CGPDFStreamCopyData(image, &format) as Data? {
                if format == .jpegEncoded, Images.sniff([UInt8](data.prefix(16))) == "jpg" { return (data, "jpg", false) }
                if format == .JPEG2000, let src = CGImageSourceCreateWithData(data as CFData, nil),
                   let img = CGImageSourceCreateImageAtIndex(src, 0, nil) { return (try Images.encode(img, as: "png"), "png", false) }
            }
        }
        return (try render(page, pixelWidth: Int(w), dpi: dpi, lossless: true), "png", false)
    }

    private static func soleImage(_ page: CGPDFPage) -> CGPDFStreamRef? {
        // Resources may be inherited from an ancestor page-tree node.
        var node = page.dictionary
        var resources: CGPDFDictionaryRef?
        while let n = node, resources == nil {
            if !CGPDFDictionaryGetDictionary(n, "Resources", &resources) {
                var parent: CGPDFDictionaryRef?
                node = CGPDFDictionaryGetDictionary(n, "Parent", &parent) ? parent : nil
            }
        }
        var xobjects: CGPDFDictionaryRef?
        guard let resources, CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return nil }
        var images: [CGPDFStreamRef] = []
        var other = false
        CGPDFDictionaryApplyBlock(xobjects, { _, obj, _ in
            var stream: CGPDFStreamRef?
            var subtype: UnsafePointer<CChar>?
            if CGPDFObjectGetValue(obj, .stream, &stream), let stream, let d = CGPDFStreamGetDictionary(stream),
               CGPDFDictionaryGetName(d, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" {
                images.append(stream)
            } else {
                other = true
            }
            return true
        }, nil)
        return images.count == 1 && !other ? images[0] : nil
    }

    static let maxRenderPixels = 80_000_000.0

    private static func render(_ page: CGPDFPage, pixelWidth: Int?, dpi: Double, lossless: Bool) throws -> Data {
        var size = page.getBoxRect(.cropBox).size
        if page.rotationAngle % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0, size.width < 1e6, size.height < 1e6 else {
            throw ConvertError.invalid("PDF 页面尺寸异常")
        }
        var scale = pixelWidth.map { Double($0) / size.width } ?? dpi / 72
        // Cap the longest side and the total pixel count (80 MP ≈ 320 MB of RGBA) of the render buffer.
        scale = min(scale, 12_000 / max(size.width, size.height), (maxRenderPixels / (size.width * size.height)).squareRoot())
        guard scale.isFinite, scale > 0 else { throw ConvertError.invalid("PDF 渲染分辨率异常") }
        var w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        if Double(w) * Double(h) > maxRenderPixels {
            // Rounding up can overshoot the cap by a few pixels; shrink both sides until it holds.
            let f = (maxRenderPixels / (Double(w) * Double(h))).squareRoot()
            w = max(1, Int(Double(w) * f)); h = max(1, Int(Double(h) * f))
        }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConvertError.tool("无法分配 \(w)×\(h) 渲染缓冲")
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(w) / size.width, y: CGFloat(h) / size.height)
        // At an unscaled target rect the drawing transform only rotates and translates.
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        guard let img = ctx.makeImage() else { throw ConvertError.tool("PDF 渲染失败") }
        return try Images.encode(img, as: lossless ? "png" : "jpg")
    }

    // MARK: Writing

    static func write(_ comic: Comic, to out: URL) throws {
        var info: [CFString: Any] = [kCGPDFContextTitle: comic.title, kCGPDFContextCreator: "Comic Converter"]
        if !comic.authors.isEmpty { info[kCGPDFContextAuthor] = comic.authors.joined(separator: ", ") }
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, info as CFDictionary) else { throw ConvertError.tool("无法创建 PDF") }
        for page in comic.pages {
            let image = try embeddable(page)
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(image, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    /// JPEG and PNG images built from their data providers are embedded by Quartz without re-encoding.
    private static func embeddable(_ url: URL) throws -> CGImage {
        let kind = Images.kind(of: url)
        if let provider = CGDataProvider(url: url as CFURL) {
            if kind == "jpg", let img = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) { return img }
            if kind == "png", let img = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) { return img }
        }
        return try Images.decode(url)
    }
}
