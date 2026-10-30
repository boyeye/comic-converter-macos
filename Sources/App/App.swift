import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct ComicConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("漫画格式转换") {
            ContentView(model: Model.shared)
                .frame(minWidth: 640, minHeight: 420)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加文件…") { Model.shared.choose() }.keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) { Model.shared.add(urls) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

final class Model: ObservableObject {
    static let shared = Model()

    enum State {
        case waiting, running
        case done(ConversionResult)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var state = State.waiting
    }

    @Published var items: [Item] = []
    @Published var running = false
    @Published var format: OutputFormat { didSet { UserDefaults.standard.set(format.rawValue, forKey: "format") } }
    @Published var direction = ReadingDirection.auto
    @Published var outputFolder: URL?

    init() {
        format = UserDefaults.standard.string(forKey: "format").flatMap(OutputFormat.init) ?? .cbz
    }

    func add(_ urls: [URL]) {
        let known = Set(items.map(\.url))
        items += Converter.expand(urls).filter { !known.contains($0) }.map { Item(url: $0) }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择漫画文件，或包含漫画文件 / 图片的文件夹"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if panel.runModal() == .OK { outputFolder = panel.url }
    }

    func start() {
        let pending = items.filter { if case .done = $0.state { return false }; return true }.map(\.id)
        guard !pending.isEmpty, !running else { return }
        running = true
        let options = ConversionOptions(format: format, outputDirectory: outputFolder, direction: direction)
        DispatchQueue.global(qos: .userInitiated).async {
            for id in pending {
                guard let url = DispatchQueue.main.sync(execute: { self.items.first { $0.id == id }?.url }) else { continue }
                DispatchQueue.main.sync { self.update(id, .running) }
                let state: State
                do { state = .done(try Converter.convert(url, options: options)) } catch { state = .failed(error.localizedDescription) }
                DispatchQueue.main.sync { self.update(id, state) }
            }
            DispatchQueue.main.async { self.running = false }
        }
    }

    private func update(_ id: UUID, _ state: State) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].state = state }
    }

    func clearFinished() { items.removeAll { if case .done = $0.state { return true }; return false } }
}

struct ContentView: View {
    @ObservedObject var model: Model
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            settings.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            Divider()
            list
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    for p in providers {
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            if let url { DispatchQueue.main.async { model.add([url]) } }
                        }
                    }
                    return true
                }
            Divider()
            footer.padding(12)
        }
    }

    private var settings: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("输出格式").foregroundStyle(.secondary)
                Picker("", selection: $model.format) {
                    ForEach(OutputFormat.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 260, alignment: .leading)
            }
            GridRow {
                Text("阅读方向").foregroundStyle(.secondary)
                Picker("", selection: $model.direction) {
                    ForEach(ReadingDirection.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 260, alignment: .leading)
            }
            GridRow {
                Text("保存位置").foregroundStyle(.secondary)
                HStack {
                    Text(model.outputFolder?.path ?? "与源文件相同的文件夹")
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(model.outputFolder == nil ? .secondary : .primary)
                    Button("选择…") { model.chooseOutput() }
                    if model.outputFolder != nil { Button("恢复默认") { model.outputFolder = nil } }
                }
            }
            if let hint {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Label(hint, systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
                }
            }
        }
        .disabled(model.running)
    }

    private var hint: String? {
        switch model.format {
        case .azw3 where Calibre.ebookConvert == nil: return "未检测到 Calibre，无法输出 AZW3。请先安装 calibre-ebook.com"
        case .mobi: return "MOBI 是 Kindle 旧格式；新款 Kindle 建议用 EPUB（通过 Send to Kindle）或 AZW3"
        default: return nil
        }
    }

    @ViewBuilder private var list: some View {
        if model.items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "books.vertical").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("把漫画文件或文件夹拖到这里").font(.title3)
                Text("CBZ · CBR · CB7 · CBT · PDF · EPUB · MOBI · AZW3 · 图片文件夹").font(.callout).foregroundStyle(.secondary)
                Button("添加文件…") { model.choose() }.padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(targeted ? Color.accentColor.opacity(0.12) : Color.clear)
        } else {
            List(model.items) { item in
                Row(item: item)
                    .contextMenu {
                        if case .done(let r) = item.state {
                            Button("在 Finder 中显示结果") { NSWorkspace.shared.activateFileViewerSelecting([r.output]) }
                        }
                        Button("在 Finder 中显示源文件") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        Button("移除") { model.items.removeAll { $0.id == item.id } }.disabled(model.running)
                    }
            }
            .overlay(targeted ? RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3) : nil)
        }
    }

    private var footer: some View {
        HStack {
            Button("添加…") { model.choose() }
            Button("清除已完成") { model.clearFinished() }.disabled(model.running)
            Button("清空") { model.items.removeAll() }.disabled(model.running || model.items.isEmpty)
            Spacer()
            Text(summary).foregroundStyle(.secondary).font(.callout)
            Button(model.running ? "转换中…" : "开始转换") { model.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.running || model.items.isEmpty)
        }
    }

    private var summary: String {
        let done = model.items.filter { if case .done = $0.state { return true }; return false }.count
        let failed = model.items.filter { if case .failed = $0.state { return true }; return false }.count
        return model.items.isEmpty ? "" : "共 \(model.items.count) 项 · 完成 \(done)" + (failed > 0 ? " · 失败 \(failed)" : "")
    }
}

private struct Row: View {
    let item: Model.Item

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                detail.font(.caption).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done(let r): Image(systemName: r.warnings.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(r.warnings.isEmpty ? .green : .orange)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder private var detail: some View {
        switch item.state {
        case .waiting: Text(item.url.deletingLastPathComponent().path).foregroundStyle(.secondary)
        case .running: Text("正在转换…").foregroundStyle(.secondary)
        case .done(let r):
            VStack(alignment: .leading, spacing: 1) {
                Text("→ \(r.output.lastPathComponent) · \(r.pages) 页").foregroundStyle(.secondary)
                ForEach(r.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
            }
        case .failed(let message): Text(message).foregroundStyle(.red)
        }
    }
}
