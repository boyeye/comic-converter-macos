import Foundation

enum OutputFormat: String, CaseIterable, Identifiable {
    case cbz, cbr, cb7, cbt, epub, mobi, azw3, pdf, folder
    var id: String { rawValue }

    static let comicArchives: [OutputFormat] = [.cbz, .cbr, .cb7, .cbt]
    static let ebooks: [OutputFormat] = [.epub, .mobi, .azw3, .pdf]

    var label: String {
        switch self {
        case .cbz: return "CBZ（推荐）"
        case .cbr: return "CBR"
        case .cb7: return "CB7"
        case .cbt: return "CBT"
        case .epub: return "EPUB"
        case .mobi: return "MOBI"
        case .azw3: return "AZW3"
        case .pdf: return "PDF"
        case .folder: return "图片文件夹"
        }
    }

    var summary: String {
        switch self {
        case .cbz: return "ZIP 打包的漫画，几乎所有漫画阅读器都支持"
        case .cbr: return "RAR 打包的漫画。RAR 是专有格式，需要安装 RARLAB 的 rar 命令行工具"
        case .cb7: return "7z 打包的漫画，体积最小，但支持它的阅读器较少"
        case .cbt: return "TAR 打包的漫画，不压缩，很少使用，一般用不到"
        case .epub: return "固定版式电子书，适合 Apple Books、Kobo，也可以用 Send to Kindle 发送"
        case .mobi: return "Kindle 旧格式，适合老款 Kindle"
        case .azw3: return "Kindle 新格式，需要安装 Calibre"
        case .pdf: return "每页一张图片，任何设备都能打开"
        case .folder: return "按页码命名的图片文件"
        }
    }
}

/// What a source file is. Detected from content, so a mislabeled ".cbr" that is really a ZIP still converts.
enum InputFormat: String, CaseIterable, Identifiable {
    case auto, cbz, cbr, cb7, cbt, pdf, epub, mobi, folder
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "自动识别（推荐）"
        case .cbz: return "CBZ / ZIP"
        case .cbr: return "CBR / RAR"
        case .cb7: return "CB7 / 7Z"
        case .cbt: return "CBT / TAR"
        case .pdf: return "PDF"
        case .epub: return "EPUB"
        case .mobi: return "MOBI / AZW3 / AZW / PRC"
        case .folder: return "图片文件夹"
        }
    }

    var extensions: Set<String> {
        switch self {
        case .auto: return []
        case .cbz: return ["cbz", "zip"]
        case .cbr: return ["cbr", "rar"]
        case .cb7: return ["cb7", "7z"]
        case .cbt: return ["cbt", "tar"]
        case .pdf: return ["pdf"]
        case .epub: return ["epub", "kepub"]
        case .mobi: return ["mobi", "azw3", "azw", "prc"]
        case .folder: return []
        }
    }

    static let readableExtensions = Set(allCases.flatMap(\.extensions))

    /// Content sniffing first, extension second. nil means not a comic this tool can read.
    static func detect(_ url: URL) -> InputFormat? {
        if isDirectory(url) { return Images.collect(in: url).isEmpty ? nil : .folder }
        var head: [UInt8] = []
        if let h = try? FileHandle(forReadingFrom: url) {
            head = [UInt8]((try? h.read(upToCount: 1024)) ?? Data())
            try? h.close()
        }
        let ext = url.pathExtension.lowercased()
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            return head.has("mimetypeapplication/epub+zip", at: 30) || ext == "epub" || ext == "kepub" ? .epub : .cbz
        }
        if head.has("Rar!", at: 0) { return .cbr }
        if head.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .cb7 }
        if head.has("%PDF", at: 0) || String(decoding: head, as: UTF8.self).contains("%PDF-") { return .pdf }
        if head.has("BOOKMOBI", at: 60) { return .mobi }
        if head.has("ustar", at: 257) { return .cbt }
        return allCases.first { $0.extensions.contains(ext) }
    }
}

struct ConversionOptions {
    var format: OutputFormat = .cbz
    /// .auto detects each file from its content; anything else forces that reader.
    var input: InputFormat = .auto
    /// nil writes next to each source file.
    var outputDirectory: URL?
    var direction: ReadingDirection = .auto
    /// Resolution for PDF pages that are not a single embedded image.
    var dpi: Double = 300
    var naming = NamingRule()
}

struct ConversionResult {
    let output: URL
    let pages: Int
    let warnings: [String]
}

enum Converter {
    static let kfxExtensions: Set<String> = ["kfx", "azw8"]

    /// Expands folders: a folder holding comic files is a batch, a folder holding only images is one comic.
    /// With a forced input format, only files of that format are taken from folders.
    static func expand(_ urls: [URL], input: InputFormat = .auto) -> [URL] {
        func wanted(_ url: URL) -> Bool {
            let ext = url.pathExtension.lowercased()
            if input == .auto { return InputFormat.readableExtensions.contains(ext) || kfxExtensions.contains(ext) }
            return input.extensions.contains(ext) || InputFormat.detect(url) == input
        }
        var result: [URL] = []
        for url in urls {
            guard isDirectory(url) else {
                // Files named explicitly are always kept; a forced format only filters folder contents.
                if wanted(url) || InputFormat.detect(url) != nil { result.append(url) }
                continue
            }
            let files = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
                .compactMap { $0 as? URL } ?? [])
                .filter { !isDirectory($0) && wanted($0) }
            if input != .folder, !files.isEmpty {
                result += files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if input == .auto || input == .folder, !Images.collect(in: url).isEmpty {
                result.append(url)
            }
        }
        return result
    }

    static func read(_ url: URL, work: URL, options: ConversionOptions) throws -> Comic {
        if kfxExtensions.contains(url.pathExtension.lowercased()) {
            throw ConvertError.unsupported("KFX 格式。请先用 Calibre 的 KFX Input 插件转成 AZW3 或 EPUB")
        }
        let detected = InputFormat.detect(url)
        let format = options.input == .auto ? detected : options.input
        do {
            switch format {
            case .folder?: return Archive.readFolder(url)
            case .cbz?, .cbr?, .cb7?, .cbt?: return try Archive.read(url, work: work)
            case .mobi?: return try MOBIComic.read(url, work: work)
            case .pdf?: return try PDFComic.read(url, work: work, dpi: options.dpi)
            case .epub?: return try EPUBComic.read(url, work: work)
            case .auto?, nil: throw ConvertError.unsupported("无法识别的文件类型 .\(url.pathExtension)")
            }
        } catch let error as ConvertError {
            // A forced format that disagrees with the content is the likeliest cause; say so.
            if options.input != .auto, let detected, detected != options.input {
                throw ConvertError.invalid("按 \(options.input.label) 读取失败；文件内容看起来是 \(detected.label)。请改用「自动识别」")
            }
            throw error
        }
    }

    /// `index` and `total` place the file in its batch for the {序号} naming token.
    static func convert(_ input: URL, options: ConversionOptions, index: Int = 0, total: Int = 1) throws -> ConversionResult {
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        var comic = try read(input, work: work, options: options)
        guard !comic.pages.isEmpty else { throw ConvertError.invalid("没有找到任何页面图片") }
        if options.direction != .auto { comic.rightToLeft = options.direction == .rtl }

        let dir = options.outputDirectory ?? input.deletingLastPathComponent()
        let original = isDirectory(input) ? input.lastPathComponent : input.deletingPathExtension().lastPathComponent
        let base = options.naming.name(original: original, index: index, total: total, comic: comic, format: options.format)
        let temp = work.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let built = temp.appendingPathComponent(options.format == .folder ? base : "\(base).\(options.format.rawValue)")
        try write(&comic, format: options.format, to: built, work: work)

        // moveItem never replaces an existing item; if another process grabbed the name between the
        // check and the move, pick the next free name.
        for _ in 0..<100 {
            let dest = uniqueDestination(base: base, format: options.format, in: dir)
            do {
                try FileManager.default.moveItem(at: built, to: dest)
                return ConversionResult(output: dest, pages: comic.pages.count, warnings: comic.warnings)
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw ConvertError.tool("无法在 \(dir.path) 中找到可用的输出文件名")
    }

    static func write(_ comic: inout Comic, format: OutputFormat, to out: URL, work: URL) throws {
        switch format {
        case .cbz: try Archive.writeZip(comic, to: out)
        case .cb7: try Archive.writeTar(comic, format: "7zip", to: out, work: work)
        case .cbt: try Archive.writeTar(comic, format: "ustar", to: out, work: work)
        case .cbr:
            guard let rar = Tools.rar else {
                throw ConvertError.unsupported("输出 CBR 需要 RAR 命令行工具（RARLAB 共享软件）。可执行 brew install --cask rar 安装")
            }
            try Archive.writeRar(comic, rar: rar, to: out, work: work)
        case .folder: _ = try Archive.stage(comic, in: out, comicInfo: false)
        case .pdf: try PDFComic.write(comic, to: out)
        case .epub: try EPUBComic.write(&comic, to: out, work: work)
        case .mobi: try MOBIComic.write(&comic, to: out, work: work)
        case .azw3:
            guard let calibre = Tools.ebookConvert else {
                throw ConvertError.unsupported("输出 AZW3 需要先安装 Calibre（https://calibre-ebook.com）")
            }
            let epub = work.appendingPathComponent("calibre-input.epub")
            try EPUBComic.write(&comic, to: epub, work: work)
            try runTool(calibre, [epub.path, out.path], name: "Calibre 转换")
        }
    }

    /// Never overwrites: picks "name (1).ext", "name (2).ext"… when the name is taken.
    static func uniqueDestination(base: String, format: OutputFormat, in dir: URL) -> URL {
        let ext = format == .folder ? "" : ".\(format.rawValue)"
        var url = dir.appendingPathComponent(base + ext)
        var n = 1
        // attributesOfItem does not follow symlinks, so a dangling link also counts as taken.
        while (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
            url = dir.appendingPathComponent("\(base) (\(n))\(ext)")
            n += 1
        }
        return url
    }
}

enum Tools {
    static var ebookConvert: String? {
        find(env: "COMICCONV_CALIBRE", ["/Applications/calibre.app/Contents/MacOS/ebook-convert",
                                         "~/Applications/calibre.app/Contents/MacOS/ebook-convert",
                                         "/opt/homebrew/bin/ebook-convert", "/usr/local/bin/ebook-convert"])
    }

    static var rar: String? { find(env: "COMICCONV_RAR", ["/opt/homebrew/bin/rar", "/usr/local/bin/rar", "~/bin/rar"]) }

    private static func find(env: String, _ paths: [String]) -> String? {
        ((ProcessInfo.processInfo.environment[env].map { [$0] } ?? []) + paths)
            .map { ($0 as NSString).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
