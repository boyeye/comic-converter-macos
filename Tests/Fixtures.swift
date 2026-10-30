import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Test helper: `pages <dir> <n>` writes numbered pages in mixed formats; `color <image>...` prints each
/// image's mean RGB; `textpdf <file>` writes a vector PDF page; `inspect <pdf>` lists image filters per page.
@main
struct Fixtures {
    static func hue(_ i: Int, _ n: Int) -> (CGFloat, CGFloat, CGFloat) {
        let h = CGFloat(i) / CGFloat(n) * 6, x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        switch Int(h) { case 0: return (1, x, 0); case 1: return (x, 1, 0); case 2: return (0, 1, x)
        case 3: return (0, x, 1); case 4: return (x, 0, 1); default: return (1, 0, x) }
    }

    static func main() throws {
        let a = CommandLine.arguments
        switch a[1] {
        case "pages":
            let dir = URL(fileURLWithPath: a[2]), n = Int(a[3])!
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let kinds: [(String, UTType)] = [("jpg", .jpeg), ("png", .png), ("jpg", .jpeg), ("heic", .heic), ("gif", .gif), ("tif", .tiff)]
            for i in 0..<n {
                let (w, h) = i == 2 ? (1600, 1200) : (800, 1200)
                let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                let (r, g, b) = hue(i, n)
                ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 40, y: 40, width: 30 * (i + 1), height: 30))
                let (ext, type) = kinds[i % kinds.count]
                // Zero-padded names would hide natural-sort bugs; "page10" must follow "page9".
                let url = dir.appendingPathComponent("page\(i + 1).\(ext)")
                let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(d, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                precondition(CGImageDestinationFinalize(d))
            }
        case "color":
            for path in a.dropFirst(2) {
                let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
                let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
                var px = [UInt8](repeating: 0, count: 4)
                let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.interpolationQuality = .medium
                // Sample the center area, away from the black page-number bar.
                let crop = img.cropping(to: CGRect(x: img.width / 4, y: img.height / 4, width: img.width / 2, height: img.height / 2))!
                ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                print("\(px[0]) \(px[1]) \(px[2]) \(img.width) \(img.height)")
            }
        case "textpdf":
            var box = CGRect(x: 0, y: 0, width: 595, height: 842)
            let ctx = CGContext(URL(fileURLWithPath: a[2]) as CFURL, mediaBox: &box, nil)!
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1)); ctx.fill(box)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Vector page", attributes: [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 48, nil)]))
            ctx.textPosition = CGPoint(x: 60, y: 400); CTLineDraw(line, ctx)
            ctx.endPDFPage(); ctx.closePDF()
        case "bigpdf":
            // A 200-inch square page: rendering it at 300 DPI would need a 3.6-gigapixel buffer.
            var box = CGRect(x: 0, y: 0, width: 14_400, height: 14_400)
            let ctx = CGContext(URL(fileURLWithPath: a[2]) as CFURL, mediaBox: &box, nil)!
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.5, blue: 0.1, alpha: 1)); ctx.fill(box)
            ctx.endPDFPage(); ctx.closePDF()
        case "watchdog":
            // watchdog <archive> <dir> <limitBytes>: the in-flight extraction limit, bypassing the declared-size precheck.
            do {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: a[3]), withIntermediateDirectories: true)
                try Archive.extractWatched(URL(fileURLWithPath: a[2]), to: URL(fileURLWithPath: a[3]), limit: Int64(a[4])!)
                print("extracted")
            } catch { print("stopped: \(error.localizedDescription)") }
        case "readcontained":
            // readcontained <file> <root> <limit>
            do {
                let d = try readContainedData(URL(fileURLWithPath: a[2]), in: URL(fileURLWithPath: a[3]), limit: Int(a[4])!)
                print("read \(d.count)")
            } catch { print("refused: \(error.localizedDescription)") }
        case "inspect":
            let doc = CGPDFDocument(URL(fileURLWithPath: a[2]) as CFURL)!
            for n in 1...doc.numberOfPages {
                var res: CGPDFDictionaryRef?, xo: CGPDFDictionaryRef?
                CGPDFDictionaryGetDictionary(doc.page(at: n)!.dictionary!, "Resources", &res)
                CGPDFDictionaryGetDictionary(res!, "XObject", &xo)
                var filters: [String] = []
                CGPDFDictionaryApplyBlock(xo!, { _, obj, _ in
                    var s: CGPDFStreamRef?; var name: UnsafePointer<CChar>?
                    if CGPDFObjectGetValue(obj, .stream, &s), CGPDFDictionaryGetName(CGPDFStreamGetDictionary(s!)!, "Filter", &name) { filters.append(String(cString: name!)) } else { filters.append("none") }
                    return true
                }, nil)
                print(filters.joined(separator: ","))
            }
        default: fatalError("unknown command")
        }
    }
}
