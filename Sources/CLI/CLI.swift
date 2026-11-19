import Foundation

@main
struct CLI {
    static let usage = [
        String(localized: "用法：comicconv -t <格式> [选项] <文件或文件夹>..."),
        String(localized: "      comicconv --inspect <MOBI/AZW3 文件>..."),
        "",
        String(localized: "输出格式（-t, --to）：\(OutputFormat.allCases.map(\.rawValue).joined(separator: " "))"),
        String(localized: "  \(OutputFormat.allCases.map { String(localized: "\($0.rawValue)：\($0.summary)") }.joined(separator: "\n      "))"),
        String(localized: "输入格式（-f, --from，默认 auto 按文件内容识别）：\(InputFormat.allCases.map(\.rawValue).joined(separator: " "))"),
        "",
        String(localized: "选项："),
        String(localized: "  -o, --output <目录>   输出目录（默认与源文件相同；同名时自动加序号，不覆盖）"),
        String(localized: "  -f, --from <格式>     只处理并按此格式读取（文件夹批量时用于筛选）"),
        String(localized: "  --name <模板>         批量命名，如 \"{标题} 第{序号}卷\"；可用 \(NamingRule.tokens.map(\.token).joined(separator: " "))"),
        String(localized: "  --start <数字>        {序号} 起始值（默认 1）"),
        String(localized: "  --pad <位数>          {序号} 位数（默认自动，至少 2 位）"),
        String(localized: "  --find <文本> --replace <文本>   对原名和标题做查找替换（加 --regex 使用正则）"),
        String(localized: "  --strip-brackets      去掉【】[]()（）括号及其内容"),
        String(localized: "  --rtl / --ltr         强制阅读方向（默认沿用原书）"),
        String(localized: "  --dpi <数值>          渲染非图片型 PDF 页面的分辨率（默认 300）"),
        String(localized: "  -h, --help            显示帮助"),
        String(localized: "  --version             显示版本"),
        "",
        String(localized: "示例："),
        String(localized: "  comicconv -t cbz ~/Comics/mobi/"),
        String(localized: "  comicconv -t epub --rtl -o ~/Desktop 海贼王.cbz"),
        String(localized: "  comicconv -t cbz -f mobi ~/Downloads/          # 只转换其中的 MOBI/AZW3"),
        String(localized: "  comicconv -t cbz --name \"海贼王 第{序号}卷\" --strip-brackets ~/Comics/海贼王/")
    ].joined(separator: "\n")

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
            case "-AppleLanguages": _ = args.popFirst()
            case "-h", "--help": print(usage); exit(0)
            case "--version": print("comicconv \(AppVersion.string)"); exit(0)
            case "-t", "--to":
                guard let v = args.popFirst(), let f = OutputFormat(rawValue: v.lowercased()) else { fail(String(localized: "-t 需要以下格式之一：\(OutputFormat.allCases.map(\.rawValue).joined(separator: " "))")) }
                format = f
            case "-f", "--from":
                guard let v = args.popFirst(), let f = InputFormat(rawValue: v.lowercased()) else { fail(String(localized: "-f 需要以下格式之一：\(InputFormat.allCases.map(\.rawValue).joined(separator: " "))")) }
                options.input = f
            case "--inspect":
                // Structure only, never content: safe to paste into a bug report.
                guard !args.isEmpty else { fail(String(localized: "--inspect 需要 MOBI/AZW3 文件")) }
                while let path = args.popFirst() {
                    if path == "-AppleLanguages" { _ = args.popFirst(); continue }
                    print("== \((path as NSString).lastPathComponent)")
                    do { print(try MOBIComic.inspect(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))) } catch { print(String(localized: "无法解析：\(error.localizedDescription)")) }
                }
                exit(0)
            case "-o", "--output":
                guard let v = args.popFirst() else { fail(String(localized: "-o 需要目录")) }
                let url = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
                guard isDirectory(url) else { fail(String(localized: "输出目录不存在：\(v)")) }
                options.outputDirectory = url
            case "--name":
                guard let v = args.popFirst(), !v.isEmpty else { fail(String(localized: "--name 需要命名模板")) }
                options.naming.template = v
            case "--start":
                guard let v = args.popFirst().flatMap(Int.init), v >= 0 else { fail(String(localized: "--start 需要非负整数")) }
                options.naming.start = v
            case "--pad":
                guard let v = args.popFirst().flatMap(Int.init), (1...8).contains(v) else { fail(String(localized: "--pad 需要 1–8")) }
                options.naming.padding = v
            case "--find":
                guard let v = args.popFirst(), !v.isEmpty else { fail(String(localized: "--find 需要文本")) }
                options.naming.find = v
            case "--replace":
                guard let v = args.popFirst() else { fail(String(localized: "--replace 需要文本（可为空字符串）")) }
                options.naming.replace = v
            case "--regex": options.naming.useRegex = true
            case "--strip-brackets": options.naming.stripBrackets = true
            case "--rtl": options.direction = .rtl
            case "--ltr": options.direction = .ltr
            case "--dpi":
                guard let v = args.popFirst().flatMap(Double.init), (36...1200).contains(v) else { fail(String(localized: "--dpi 需要 36–1200 之间的数值")) }
                options.dpi = v
            case _ where arg.hasPrefix("-") && arg.count > 1: fail(String(localized: "未知选项 \(arg)，使用 --help 查看用法"))
            default:
                let url = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: url.path) else { fail(String(localized: "找不到 \(arg)")) }
                inputs.append(url)
            }
        }
        guard let format else { fail(String(localized: "请用 -t 指定输出格式。\n\n\(usage)")) }
        guard !inputs.isEmpty else { fail(String(localized: "请指定至少一个输入文件或文件夹")) }
        options.format = format
        if let error = options.naming.regexError { fail(error) }

        sweepStaleWorkDirectories()
        let files = Converter.expand(inputs, input: options.input)
        guard !files.isEmpty else { fail(String(localized: "没有找到可转换的漫画文件")) }
        var failed = 0
        for (i, file) in files.enumerated() {
            let prefix = "[\(i + 1)/\(files.count)] \(file.lastPathComponent)"
            do {
                let r = try Converter.convert(file, options: options, index: i, total: files.count)
                print(String(localized: "✓ \(prefix) → \(r.output.path)（\(String(r.pages)) 页）"))
                r.warnings.forEach { print("  ⚠︎ \($0)") }
            } catch {
                failed += 1
                print(String(localized: "✗ \(prefix)：\(error.localizedDescription)"))
            }
        }
        print(String(localized: "完成：成功 \(String(files.count - failed))，失败 \(String(failed))"))
        exit(failed == 0 ? 0 : 1)
    }
}
