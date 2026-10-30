import Foundation

enum OutputFormat: String, CaseIterable, Identifiable {
    case cbz, cb7, cbt, pdf, epub, mobi, azw3, folder
    var id: String { rawValue }

    var label: String {
        switch self {
        case .cbz: return "CBZ（ZIP 漫画包）"
        case .cb7: return "CB7（7z 漫画包）"
        case .cbt: return "CBT（TAR 漫画包）"
        case .pdf: return "PDF"
        case .epub: return "EPUB（固定版式）"
        case .mobi: return "MOBI（Kindle 旧格式）"
        case .azw3: return "AZW3（Kindle，需 Calibre）"
        case .folder: return "图片文件夹"
        }
    }
}

struct ConversionOptions {
    var format: OutputFormat = .cbz
    /// nil writes next to each source file.
    var outputDirectory: URL?
    var direction: ReadingDirection = .auto
    /// Resolution for PDF pages that are not a single embedded image.
    var dpi: Double = 300
}

struct ConversionResult {
    let output: URL
    let pages: Int
    let warnings: [String]
}

enum Converter {
    static let archiveExtensions: Set<String> = ["cbz", "zip", "cbr", "rar", "cb7", "7z", "cbt", "tar"]
    static let mobiExtensions: Set<String> = ["mobi", "azw3", "azw", "prc"]
    static let inputExtensions = archiveExtensions.union(mobiExtensions).union(["pdf", "epub", "kepub", "kfx", "azw8"])

    /// Expands folders: a folder holding comic files is a batch, a folder holding only images is one comic.
    static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            guard isDirectory(url) else {
                if inputExtensions.contains(url.pathExtension.lowercased()) { result.append(url) }
                continue
            }
            let files = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
                .compactMap { $0 as? URL } ?? [])
                .filter { inputExtensions.contains($0.pathExtension.lowercased()) && !isDirectory($0) }
            if !files.isEmpty {
                result += files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if !Images.collect(in: url).isEmpty {
                result.append(url)
            }
        }
        return result
    }

    static func read(_ url: URL, work: URL, options: ConversionOptions) throws -> Comic {
        if isDirectory(url) { return Archive.readFolder(url) }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case _ where archiveExtensions.contains(ext): return try Archive.read(url, work: work)
        case _ where mobiExtensions.contains(ext): return try MOBIComic.read(url, work: work)
        case "pdf": return try PDFComic.read(url, work: work, dpi: options.dpi)
        case "epub", "kepub": return try EPUBComic.read(url, work: work)
        case "kfx", "azw8": throw ConvertError.unsupported("KFX 格式。请先用 Calibre 的 KFX Input 插件转成 AZW3 或 EPUB")
        default: throw ConvertError.unsupported("无法识别的文件类型 .\(ext)")
        }
    }

    static func convert(_ input: URL, options: ConversionOptions) throws -> ConversionResult {
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        var comic = try read(input, work: work, options: options)
        guard !comic.pages.isEmpty else { throw ConvertError.invalid("没有找到任何页面图片") }
        if options.direction != .auto { comic.rightToLeft = options.direction == .rtl }

        let dir = options.outputDirectory ?? input.deletingLastPathComponent()
        let base = isDirectory(input) ? input.lastPathComponent : input.deletingPathExtension().lastPathComponent
        let temp = work.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let built = temp.appendingPathComponent(options.format == .folder ? base : "\(base).\(options.format.rawValue)")
        try write(&comic, format: options.format, to: built, work: work)

        let dest = uniqueDestination(base: base, format: options.format, in: dir)
        try FileManager.default.moveItem(at: built, to: dest)
        return ConversionResult(output: dest, pages: comic.pages.count, warnings: comic.warnings)
    }

    static func write(_ comic: inout Comic, format: OutputFormat, to out: URL, work: URL) throws {
        switch format {
        case .cbz: try Archive.writeZip(comic, to: out)
        case .cb7: try Archive.writeTar(comic, format: "7zip", to: out, work: work)
        case .cbt: try Archive.writeTar(comic, format: "ustar", to: out, work: work)
        case .folder: _ = try Archive.stage(comic, in: out, comicInfo: false)
        case .pdf: try PDFComic.write(comic, to: out)
        case .epub: try EPUBComic.write(&comic, to: out, work: work)
        case .mobi: try MOBIComic.write(&comic, to: out, work: work)
        case .azw3:
            guard let calibre = Calibre.ebookConvert else {
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
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(n))\(ext)")
            n += 1
        }
        return url
    }
}

enum Calibre {
    static var ebookConvert: String? {
        let env = ProcessInfo.processInfo.environment["COMICCONV_CALIBRE"].map { [$0] } ?? []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (env + ["/Applications/calibre.app/Contents/MacOS/ebook-convert", "\(home)/Applications/calibre.app/Contents/MacOS/ebook-convert",
                       "/opt/homebrew/bin/ebook-convert", "/usr/local/bin/ebook-convert"])
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
