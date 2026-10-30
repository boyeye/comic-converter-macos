import Foundation

@main
struct CLI {
    static let usage = """
    用法：comicconv -t <格式> [选项] <文件或文件夹>...

    输出格式（-t, --to）：\(OutputFormat.allCases.map(\.rawValue).joined(separator: " "))
    可读取：cbz zip cbr rar cb7 7z cbt tar pdf epub mobi azw3 azw prc，以及图片文件夹

    选项：
      -o, --output <目录>   输出目录（默认与源文件相同；同名时自动加序号，不覆盖）
      --rtl / --ltr         强制阅读方向（默认沿用原书）
      --dpi <数值>          渲染非图片型 PDF 页面的分辨率（默认 300）
      -h, --help            显示帮助
      --version             显示版本

    示例：
      comicconv -t cbz ~/Comics/mobi/
      comicconv -t epub --rtl -o ~/Desktop 海贼王.cbz
    """

    static func main() {
        var options = ConversionOptions()
        var format: OutputFormat?
        var inputs: [URL] = []
        var args = CommandLine.arguments.dropFirst()
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("comicconv: \(message)\n".utf8))
            exit(2)
        }
        while let arg = args.popFirst() {
            switch arg {
            case "-h", "--help": print(usage); exit(0)
            case "--version": print("comicconv \(AppVersion.string)"); exit(0)
            case "-t", "--to":
                guard let v = args.popFirst(), let f = OutputFormat(rawValue: v.lowercased()) else { fail("-t 需要以下格式之一：\(OutputFormat.allCases.map(\.rawValue).joined(separator: " "))") }
                format = f
            case "-o", "--output":
                guard let v = args.popFirst() else { fail("-o 需要目录") }
                let url = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
                guard isDirectory(url) else { fail("输出目录不存在：\(v)") }
                options.outputDirectory = url
            case "--rtl": options.direction = .rtl
            case "--ltr": options.direction = .ltr
            case "--dpi":
                guard let v = args.popFirst().flatMap(Double.init), (36...1200).contains(v) else { fail("--dpi 需要 36–1200 之间的数值") }
                options.dpi = v
            case _ where arg.hasPrefix("-") && arg.count > 1: fail("未知选项 \(arg)，使用 --help 查看用法")
            default:
                let url = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: url.path) else { fail("找不到 \(arg)") }
                inputs.append(url)
            }
        }
        guard let format else { fail("请用 -t 指定输出格式。\n\n\(usage)") }
        guard !inputs.isEmpty else { fail("请指定至少一个输入文件或文件夹") }
        options.format = format

        let files = Converter.expand(inputs)
        guard !files.isEmpty else { fail("没有找到可转换的漫画文件") }
        var failed = 0
        for (i, file) in files.enumerated() {
            let prefix = "[\(i + 1)/\(files.count)] \(file.lastPathComponent)"
            do {
                let r = try Converter.convert(file, options: options)
                print("✓ \(prefix) → \(r.output.path)（\(r.pages) 页）")
                r.warnings.forEach { print("  ⚠︎ \($0)") }
            } catch {
                failed += 1
                print("✗ \(prefix)：\(error.localizedDescription)")
            }
        }
        print("完成：成功 \(files.count - failed)，失败 \(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}
