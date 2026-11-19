import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct ComicConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(String(localized: "漫画格式转换")) {
            ContentView(model: Model.shared, appearance: Appearance.shared)
                .frame(minWidth: 720, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(String(localized: "添加文件…")) { Model.shared.choose() }.keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) { Model.shared.add(urls) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .utility).async { sweepStaleWorkDirectories() }
    }
}

struct BackdropView: View {
    @ObservedObject var appearance: Appearance

    var body: some View {
        if let preset = appearance.preset {
            swatch(preset.colors)
        } else if let color = appearance.customColor {
            color
        } else if appearance.choice == "image", let image = appearance.image {
            GeometryReader { geo in
                Image(nsImage: image).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
            }
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    @ViewBuilder func swatch(_ hexes: [String]) -> some View {
        let colors = hexes.compactMap { Color(hex: $0) }
        if colors.count == 1 { colors[0] } else { LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing) }
    }
}

struct AppearancePicker: View {
    @ObservedObject var appearance: Appearance
    @State private var custom = Color(hex: "#7FB3D5")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "背景")).font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 10), count: 4), spacing: 12) {
                tile(name: String(localized: "跟随系统"), selected: appearance.choice == "system") {
                    Color(nsColor: .windowBackgroundColor).overlay(Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary))
                } action: { appearance.choice = "system" }
                ForEach(Backdrop.presets) { p in
                    tile(name: p.name, selected: appearance.choice == "preset:" + p.id) {
                        BackdropView(appearance: appearance).swatch(p.colors)
                    } action: { appearance.choice = "preset:" + p.id }
                }
            }
            Divider()
            HStack {
                ColorPicker(String(localized: "自定义颜色"), selection: $custom, supportsOpacity: false)
                    .onChange(of: custom) { appearance.setColor($0) }
                Spacer()
                Button(String(localized: "选择图片…")) { appearance.pickImage() }
            }
            if appearance.choice == "image" {
                Text(String(localized: "当前使用自定义图片")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private func tile<V: View>(name: String, selected: Bool, @ViewBuilder content: () -> V, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                content()
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 3 : 1))
                Text(name).font(.caption2).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Main window

struct ContentView: View {
    @ObservedObject var model: Model
    @ObservedObject var appearance: Appearance
    @State private var targeted = false
    @State private var showAppearance = false
    @State private var showNaming = false

    var body: some View {
        VStack(spacing: 12) {
            settings
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            list
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    for p in providers {
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            if let url { DispatchQueue.main.async { model.add([url]) } }
                        }
                    }
                    return true
                }
            footer
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(14)
        .background(BackdropView(appearance: appearance).ignoresSafeArea())
        .preferredColorScheme(appearance.scheme)
        .toolbar {
            ToolbarItem {
                Button { showAppearance.toggle() } label: { Label(String(localized: "背景"), systemImage: "paintpalette") }
                    .help(String(localized: "更换背景颜色或图片"))
                    .popover(isPresented: $showAppearance, arrowEdge: .bottom) { AppearancePicker(appearance: appearance) }
            }
        }
    }

    private var settings: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text(String(localized: "输入格式")).foregroundStyle(.secondary)
                Picker("", selection: $model.input) {
                    ForEach(InputFormat.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 240, alignment: .leading)
            }
            GridRow {
                Text(String(localized: "输出格式")).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Picker("", selection: $model.format) {
                        Section(String(localized: "漫画包")) { ForEach(OutputFormat.comicArchives) { Text($0.label).tag($0) } }
                        Section(String(localized: "电子书")) { ForEach(OutputFormat.ebooks) { Text($0.label).tag($0) } }
                        Section(String(localized: "其他")) { Text(OutputFormat.folder.label).tag(OutputFormat.folder) }
                    }
                    .labelsHidden().frame(width: 240, alignment: .leading)
                    Text(model.format.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let hint {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Label(hint, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
            }
            GridRow {
                Text(String(localized: "阅读方向")).foregroundStyle(.secondary)
                Picker("", selection: $model.direction) {
                    ForEach(ReadingDirection.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 240, alignment: .leading)
            }
            GridRow {
                Text(String(localized: "文件命名")).foregroundStyle(.secondary)
                HStack {
                    Text(model.naming.isDefault ? String(localized: "保持原名") : model.naming.template)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(model.naming.isDefault ? .secondary : .primary)
                    Button(String(localized: "批量命名…")) { showNaming = true }
                    if !model.naming.isDefault { Button(String(localized: "恢复原名")) { model.naming = NamingRule() } }
                }
                .sheet(isPresented: $showNaming) { NamingSheet(model: model) }
            }
            GridRow {
                Text(String(localized: "保存位置")).foregroundStyle(.secondary)
                HStack {
                    Text(model.outputFolder?.path ?? String(localized: "与源文件相同的文件夹"))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(model.outputFolder == nil ? .secondary : .primary)
                    Button(String(localized: "选择…")) { model.chooseOutput() }
                    if model.outputFolder != nil { Button(String(localized: "恢复默认")) { model.outputFolder = nil } }
                }
            }
        }
        .disabled(model.running)
    }

    /// Only shown when the chosen output cannot be produced on this Mac.
    private var hint: String? {
        switch model.format {
        case .azw3 where Tools.ebookConvert == nil: return String(localized: "未检测到 Calibre，无法输出 AZW3。请先从 calibre-ebook.com 安装")
        case .cbr where Tools.rar == nil: return String(localized: "未检测到 rar 命令，无法输出 CBR。可在终端执行：brew install --cask rar")
        default: return nil
        }
    }

    @ViewBuilder private var list: some View {
        if model.items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "books.vertical").font(.system(size: 44)).foregroundStyle(.secondary)
                Text(String(localized: "把漫画文件或文件夹拖到这里")).font(.title3)
                Text(String(localized: "可读取：CBZ · CBR · CB7 · CBT · PDF · EPUB · MOBI · AZW3 · 图片文件夹")).font(.callout).foregroundStyle(.secondary)
                Button(String(localized: "添加文件…")) { model.choose() }.padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(targeted ? Color.accentColor.opacity(0.15) : Color.clear)
        } else {
            VStack(spacing: 0) {
                listHeader.padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
                let previews = model.previewNames()
                List(selection: $model.selection) {
                    ForEach(model.items) { item in
                        Row(item: item, preview: previews[item.id],
                            checked: Binding(get: { item.checked }, set: { model.setChecked([item.id], $0) }))
                            .tag(item.id)
                    }
                    .onMove { model.move(from: $0, to: $1) }
                }
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    contextMenu(for: ids)
                }
            }
            .overlay(targeted ? RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3) : nil)
        }
    }

    private var listHeader: some View {
        let all = model.checkedCount == model.items.count
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { all }, set: { model.setChecked(Set(model.items.map(\.id)), $0) }))
                .toggleStyle(.checkbox).labelsHidden()
                .help(all ? String(localized: "全部取消勾选") : String(localized: "全部勾选"))
            Text(String(localized: "已勾选 \(model.checkedCount) / \(model.items.count)")).font(.callout)
            Spacer()
            if !model.selection.isEmpty {
                Text(String(localized: "已选中 \(model.selection.count) 项")).font(.callout).foregroundStyle(.secondary)
                Button(String(localized: "勾选")) { model.setChecked(model.selection, true) }
                Button(String(localized: "取消勾选")) { model.setChecked(model.selection, false) }
                Button(String(localized: "移除")) { model.remove(model.selection) }.disabled(model.running)
            } else {
                Text(String(localized: "⌘ / ⇧ 点击多选 · 拖动调整顺序")).font(.callout).foregroundStyle(.secondary)
            }
            Button(String(localized: "按名称排序")) { model.sortByName() }.disabled(model.running)
        }
        .controlSize(.small)
    }

    @ViewBuilder private func contextMenu(for ids: Set<UUID>) -> some View {
        if !ids.isEmpty {
            Button(String(localized: "勾选")) { model.setChecked(ids, true) }
            Button(String(localized: "取消勾选")) { model.setChecked(ids, false) }
            Divider()
            if ids.count == 1, let item = model.items.first(where: { ids.contains($0.id) }) {
                if case .done(let r) = item.state {
                    Button(String(localized: "在 Finder 中显示结果")) { NSWorkspace.shared.activateFileViewerSelecting([r.output]) }
                }
                Button(String(localized: "在 Finder 中显示源文件")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Divider()
            }
            Button(String(localized: "移除 \(ids.count) 项")) { model.remove(ids) }.disabled(model.running)
        }
    }

    private var footer: some View {
        HStack {
            Button(String(localized: "添加…")) { model.choose() }
            Button(String(localized: "清除已完成")) { model.clearFinished() }.disabled(model.running)
            Button(String(localized: "清空")) { model.remove(Set(model.items.map(\.id))) }.disabled(model.running || model.items.isEmpty)
            Spacer()
            Text(summary).foregroundStyle(.secondary).font(.callout)
            Button(model.running ? String(localized: "转换中…") : String(localized: "转换已勾选（\(String(model.checkedCount))）")) { model.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.running || model.checkedCount == 0)
        }
    }

    private var summary: String {
        let done = model.items.filter { if case .done = $0.state { return true }; return false }.count
        let failed = model.items.filter { if case .failed = $0.state { return true }; return false }.count
        return model.items.isEmpty ? "" : String(localized: "完成 \(String(done))") + (failed > 0 ? String(localized: " · 失败 \(String(failed))") : "")
    }
}

private struct Row: View {
    let item: Model.Item
    let preview: String?
    @Binding var checked: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $checked).toggleStyle(.checkbox).labelsHidden()
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(item.badge)
                        .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                }
                detail.font(.caption).lineLimit(2)
            }
        }
        .opacity(checked ? 1 : 0.55)
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
        case .waiting:
            if let preview { Text(String(localized: "→ \(preview)")).foregroundStyle(Color.accentColor) }
            else { Text(item.url.deletingLastPathComponent().path).foregroundStyle(.secondary) }
        case .running: Text(String(localized: "正在转换…")).foregroundStyle(.secondary)
        case .done(let r):
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "→ \(r.output.lastPathComponent) · \(r.pages) 页")).foregroundStyle(.secondary)
                ForEach(r.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
            }
        case .failed(let message): Text(message).foregroundStyle(.red)
        }
    }
}

// MARK: - Batch naming

struct NamingSheet: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss

    private static let presets: [(String, String)] = [
        (String(localized: "保持原名"), String(localized: "{原名}")),
        (String(localized: "书内标题"), String(localized: "{标题}")),
        (String(localized: "作者 - 标题"), String(localized: "{作者} - {标题}")),
        (String(localized: "标题 第N卷"), String(localized: "{标题} 第{序号}卷")),
        (String(localized: "序号 原名"), String(localized: "{序号} {原名}")),
        (String(localized: "原名 [页数P]"), String(localized: "{原名} [{页数}P]")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "批量命名")).font(.title2.bold())
            Text(String(localized: "转换时按下面的规则命名输出文件。序号按列表中已勾选文件的顺序编号，拖动列表即可调整顺序。"))
                .font(.callout).foregroundStyle(.secondary)

            GroupBox(String(localized: "命名模板")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField(String(localized: "{原名}"), text: $model.naming.template).textFieldStyle(.roundedBorder)
                        Menu(String(localized: "常用模板")) {
                            ForEach(Self.presets, id: \.1) { p in Button(String(localized: "\(p.0)　\(p.1)")) { model.naming.template = p.1 } }
                        }
                        .fixedSize()
                    }
                    HStack(spacing: 6) {
                        Text(String(localized: "插入：")).font(.caption).foregroundStyle(.secondary)
                        ForEach(NamingRule.tokens, id: \.token) { t in
                            Button(t.token) { model.naming.template += t.token }
                                .controlSize(.small).help(t.help)
                        }
                    }
                    HStack(spacing: 16) {
                        Stepper(String(localized: "起始序号 \(model.naming.start)"), value: $model.naming.start, in: 0...99_999)
                        Picker(String(localized: "序号位数"), selection: $model.naming.padding) {
                            Text(String(localized: "自动")).tag(0)
                            ForEach(1...4, id: \.self) { Text(String(localized: "\($0) 位")).tag($0) }
                        }
                        .fixedSize()
                    }
                }
                .padding(6)
            }

            GroupBox(String(localized: "清理原名和标题")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField(String(localized: "查找"), text: $model.naming.find).textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField(String(localized: "替换为（可留空）"), text: $model.naming.replace).textFieldStyle(.roundedBorder)
                        Toggle(String(localized: "正则"), isOn: $model.naming.useRegex)
                    }
                    if let error = model.naming.regexError { Text(error).font(.caption).foregroundStyle(.red) }
                    Toggle(String(localized: "去掉【】[]（）() 括号及其中内容（如汉化组、来源标记）"), isOn: $model.naming.stripBrackets)
                }
                .padding(6)
            }

            GroupBox(String(localized: "预览")) {
                VStack(alignment: .leading, spacing: 4) {
                    let previews = model.previewNames()
                    let shown = model.items.filter(\.checked).prefix(6)
                    if shown.isEmpty {
                        Text(String(localized: "列表中还没有勾选的文件")).foregroundStyle(.secondary)
                    }
                    ForEach(Array(shown)) { item in
                        HStack(spacing: 6) {
                            Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            Text(previews[item.id] ?? item.url.deletingPathExtension().lastPathComponent + (model.format == .folder ? "" : ".\(model.format.rawValue)"))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .font(.callout)
                    }
                    if model.naming.template.contains("{标题}") || model.naming.template.contains("{作者}") || model.naming.template.contains("{页数}") || model.naming.template.contains("{title}") || model.naming.template.contains("{author}") || model.naming.template.contains("{pages}") {
                        Text(String(localized: "‹标题›‹作者›‹页数› 在转换时从书中读取后填入；书中没有作者时该项为空。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack {
                Button(String(localized: "恢复原名")) { model.naming = NamingRule() }
                Spacer()
                Button(String(localized: "完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}
