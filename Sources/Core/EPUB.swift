import Foundation

enum EPUBComic {
    // MARK: Reading

    static func read(_ url: URL, work: URL) throws -> Comic {
        let root = work.appendingPathComponent("epub", isDirectory: true).standardizedFileURL
        try Archive.extract(url, to: root)
        let meta = root.appendingPathComponent("META-INF")
        if FileManager.default.fileExists(atPath: meta.appendingPathComponent("rights.xml").path) ||
            ((try? String(contentsOf: meta.appendingPathComponent("encryption.xml"), encoding: .utf8)) ?? "").contains("xmlenc#aes") {
            throw ConvertError.drm("EPUB 内容已加密")
        }
        guard let container = try? String(contentsOf: meta.appendingPathComponent("container.xml"), encoding: .utf8),
              let opfPath = matches("full-path\\s*=\\s*[\"']([^\"']+)[\"']", in: container).first,
              let opfURL = resolve(opfPath, from: root, root: root),
              let opfData = try? Data(contentsOf: opfURL) else { throw ConvertError.invalid("EPUB 缺少 OPF 清单") }
        let opf = OPFParser()
        let parser = XMLParser(data: opfData)
        parser.delegate = opf
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw ConvertError.invalid("OPF 清单格式错误") }

        let opfDir = opfURL.deletingLastPathComponent()
        var comic = Comic(title: opf.title ?? url.deletingPathExtension().lastPathComponent, authors: opf.creators,
                          rightToLeft: opf.direction == "rtl")
        var seen = Set<String>()
        func add(_ u: URL?) {
            guard let u, Images.extensions.contains(u.pathExtension.lowercased()) || Images.sniff(head(u)) != nil,
                  seen.insert(u.path).inserted else { return }
            comic.pages.append(u)
        }
        for id in opf.spine {
            guard let item = opf.manifest[id], let file = resolve(item.href, from: opfDir, root: root) else { continue }
            if item.type.hasPrefix("image/") { add(file); continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let refs = matches("<(?:img|image)\\b[^>]*?\\s(?:src|xlink:href|href)\\s*=\\s*[\"']([^\"']+)[\"']", in: text)
            refs.forEach { add(resolve(xmlUnescape($0), from: file.deletingLastPathComponent(), root: root)) }
        }
        if comic.pages.isEmpty {
            opf.order.compactMap { opf.manifest[$0] }.filter { $0.type.hasPrefix("image/") }
                .forEach { add(resolve($0.href, from: opfDir, root: root)) }
            if !comic.pages.isEmpty { comic.warnings.append("未能从正文确定页序，已按清单顺序排列图片") }
        }
        return comic
    }

    private static func head(_ url: URL) -> [UInt8] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        return [UInt8]((try? h.read(upToCount: 16)) ?? Data())
    }

    /// Resolves a relative href, refusing anything that escapes the extracted book or is a symlink.
    private static func resolve(_ href: String, from dir: URL, root: URL) -> URL? {
        let path = String(href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        guard !path.isEmpty, !path.contains("://"), let decoded = path.removingPercentEncoding else { return nil }
        let url = URL(fileURLWithPath: decoded, relativeTo: dir).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"),
              let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              v.isRegularFile == true, v.isSymbolicLink != true else { return nil }
        return url
    }

    // MARK: Writing

    /// Fixed-layout EPUB 3 with one page per image, plus the Kindle comic metadata KCC uses.
    static func write(_ comic: inout Comic, to out: URL, work: URL) throws {
        let pages = try Images.prepare(comic.pages, allowed: ["jpg", "png", "gif"], in: work.appendingPathComponent("epub-images"), warnings: &comic.warnings)
        let sizes = pages.map { Images.pixelSize($0.url) ?? (1200, 1800) }
        let uuid = UUID().uuidString.lowercased()
        let modified = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        let mime = ["jpg": "image/jpeg", "png": "image/png", "gif": "image/gif"]
        let title = xmlEscape(comic.title)
        let maxW = sizes.map(\.0).max() ?? 1200, maxH = sizes.map(\.1).max() ?? 1800

        let zip = try ZipWriter(url: out)
        try zip.add("mimetype", data: Data("application/epub+zip".utf8))
        try zip.add("META-INF/container.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>

            """.utf8))

        var manifest = "", spine = "", navItems = "", ncxItems = ""
        for (i, page) in pages.enumerated() {
            let n = String(format: "%04d", i + 1)
            let (w, h) = sizes[i]
            try zip.add("OEBPS/images/p\(n).\(page.kind)", data: Data(contentsOf: page.url, options: .mappedIfSafe))
            try zip.add("OEBPS/text/p\(n).xhtml", data: Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE html>
                <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
                <head><title>\(title) - \(i + 1)</title><meta name="viewport" content="width=\(w), height=\(h)"/>
                <style>html,body{margin:0;padding:0;width:\(w)px;height:\(h)px;overflow:hidden}img{display:block;width:\(w)px;height:\(h)px}</style></head>
                <body><img src="../images/p\(n).\(page.kind)" alt="\(i + 1)"/></body>
                </html>

                """.utf8))
            manifest += "    <item id=\"img\(n)\" href=\"images/p\(n).\(page.kind)\" media-type=\"\(mime[page.kind]!)\"\(i == 0 ? " properties=\"cover-image\"" : "")/>\n"
            manifest += "    <item id=\"p\(n)\" href=\"text/p\(n).xhtml\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "    <itemref idref=\"p\(n)\"/>\n"
            if i == 0 {
                navItems += "<li><a href=\"text/p\(n).xhtml\">\(title)</a></li>"
                ncxItems += "<navPoint id=\"np1\" playOrder=\"1\"><navLabel><text>\(title)</text></navLabel><content src=\"text/p\(n).xhtml\"/></navPoint>"
            }
        }
        let creators = comic.authors.map { "    <dc:creator>\(xmlEscape($0))</dc:creator>\n" }.joined()
        try zip.add("OEBPS/content.opf", data: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">urn:uuid:\(uuid)</dc:identifier>
                <dc:title>\(title)</dc:title>
                <dc:language>und</dc:language>
            \(creators)    <meta property="dcterms:modified">\(modified)</meta>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:orientation">auto</meta>
                <meta property="rendition:spread">landscape</meta>
                <meta name="cover" content="img0001"/>
                <meta name="fixed-layout" content="true"/>
                <meta name="book-type" content="comic"/>
                <meta name="original-resolution" content="\(maxW)x\(maxH)"/>
                <meta name="primary-writing-mode" content="\(comic.rightToLeft ? "horizontal-rl" : "horizontal-lr")"/>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            \(manifest)  </manifest>
              <spine toc="ncx" page-progression-direction="\(comic.rightToLeft ? "rtl" : "ltr")">
            \(spine)  </spine>
            </package>

            """.utf8))
        try zip.add("OEBPS/nav.xhtml", data: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>\(title)</title></head>
            <body><nav epub:type="toc" id="toc"><ol>\(navItems)</ol></nav></body>
            </html>

            """.utf8))
        try zip.add("OEBPS/toc.ncx", data: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head><meta name="dtb:uid" content="urn:uuid:\(uuid)"/></head>
            <docTitle><text>\(title)</text></docTitle>
            <navMap>\(ncxItems)</navMap>
            </ncx>

            """.utf8))
        try zip.finish()
    }
}

private final class OPFParser: NSObject, XMLParserDelegate {
    struct Item { let href: String, type: String }
    var title: String?
    var creators: [String] = []
    var manifest: [String: Item] = [:]
    var order: [String] = []
    var spine: [String] = []
    var direction: String?
    private var capture: String?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch element.split(separator: ":").last.map(String.init) ?? element {
        case "item":
            if let id = a["id"], let href = a["href"] {
                manifest[id] = Item(href: href, type: (a["media-type"] ?? "").lowercased())
                order.append(id)
            }
        case "itemref": if let id = a["idref"] { spine.append(id) }
        case "spine": direction = a["page-progression-direction"]
        case "title", "creator": capture = element; text = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if capture != nil { text += string } }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        guard capture == element else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            if element.hasSuffix("title") { title = title ?? value } else { creators.append(value) }
        }
        capture = nil
    }
}
