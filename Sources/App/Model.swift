import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Conversion queue

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
        let detected: InputFormat?
        var checked = true
        var state = State.waiting

        var badge: String {
            guard let detected else { return "未知格式" }
            let ext = url.pathExtension.uppercased()
            if detected == .mobi, ["AZW3", "AZW", "PRC"].contains(ext) { return ext }
            return detected.label.components(separatedBy: " ").first!
        }
    }

    @Published var items: [Item] = []
    @Published var selection = Set<UUID>()
    @Published var running = false
    @Published var format: OutputFormat { didSet { UserDefaults.standard.set(format.rawValue, forKey: "format") } }
    @Published var input = InputFormat.auto { didSet { applyInputFilter() } }
    @Published var direction = ReadingDirection.auto
    @Published var outputFolder: URL?

    init() {
        format = UserDefaults.standard.string(forKey: "format").flatMap(OutputFormat.init) ?? .cbz
    }

    func add(_ urls: [URL]) {
        let known = Set(items.map(\.url))
        items += Converter.expand(urls, input: input).filter { !known.contains($0) }.map { url in
            let detected = InputFormat.detect(url)
            return Item(url: url, detected: detected, checked: matches(detected))
        }
    }

    private func matches(_ detected: InputFormat?) -> Bool { input == .auto ? detected != nil : detected == input }

    /// Choosing an input format ticks exactly the files of that format; "auto" ticks every readable file.
    private func applyInputFilter() {
        for i in items.indices { items[i].checked = matches(items[i].detected) }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = input != .folder
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if !input.extensions.isEmpty {
            panel.allowedContentTypes = input.extensions.compactMap { UTType(filenameExtension: $0) }
        }
        panel.message = input == .auto ? "选择漫画文件，或包含漫画文件 / 图片的文件夹" : "选择 \(input.label) 文件，或包含它们的文件夹"
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

    var checkedCount: Int { items.filter(\.checked).count }

    func setChecked(_ ids: Set<UUID>, _ value: Bool) {
        for i in items.indices where ids.contains(items[i].id) { items[i].checked = value }
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    /// Converts every ticked item that has not already succeeded, one at a time, off the main thread.
    func start() {
        let pending = items.filter { item in
            if case .done = item.state { return false }
            return item.checked
        }.map(\.id)
        guard !pending.isEmpty, !running else { return }
        running = true
        let options = ConversionOptions(format: format, input: input, outputDirectory: outputFolder, direction: direction)
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

    func clearFinished() {
        remove(Set(items.filter { if case .done = $0.state { return true }; return false }.map(\.id)))
    }
}

// MARK: - Background appearance

struct Backdrop: Identifiable {
    let id: String
    let name: String
    let colors: [String]
    let dark: Bool

    static let presets: [Backdrop] = [
        Backdrop(id: "mint", name: "薄荷绿", colors: ["#D9F2E6"], dark: false),
        Backdrop(id: "haze", name: "雾霾蓝", colors: ["#DCE5F0"], dark: false),
        Backdrop(id: "sakura", name: "樱花粉", colors: ["#F8E1E7"], dark: false),
        Backdrop(id: "cream", name: "奶油白", colors: ["#F5EFE3"], dark: false),
        Backdrop(id: "morandi", name: "莫兰迪灰", colors: ["#D6D1CA"], dark: false),
        Backdrop(id: "lavender", name: "薰衣草", colors: ["#E3D5F5", "#C9DDF7"], dark: false),
        Backdrop(id: "peach", name: "蜜桃渐变", colors: ["#FFD3C2", "#FBC2EB"], dark: false),
        Backdrop(id: "sunset", name: "日落渐变", colors: ["#FF9A8B", "#FF6A88", "#C86DD7"], dark: true),
        Backdrop(id: "aurora", name: "极光渐变", colors: ["#1D976C", "#185A9D"], dark: true),
        Backdrop(id: "midnight", name: "午夜蓝", colors: ["#1B2440", "#2C3E66"], dark: true),
        Backdrop(id: "graphite", name: "石墨灰", colors: ["#2A2C31"], dark: true),
    ]
}

final class Appearance: ObservableObject {
    static let shared = Appearance()

    /// "system", "preset:<id>", "color:#RRGGBB" or "image".
    @Published var choice: String { didSet { UserDefaults.standard.set(choice, forKey: "backdrop") } }
    @Published private(set) var image: NSImage?

    private var imageURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ComicConverter")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("background")
    }

    init() {
        choice = UserDefaults.standard.string(forKey: "backdrop") ?? "system"
        image = NSImage(contentsOf: imageURL)
        if choice == "image", image == nil { choice = "system" }
    }

    var preset: Backdrop? { choice.hasPrefix("preset:") ? Backdrop.presets.first { "preset:" + $0.id == choice } : nil }
    var customColor: Color? { choice.hasPrefix("color:") ? Color(hex: String(choice.dropFirst(6))) : nil }

    /// Light backdrops force light text styling and dark ones dark, so labels stay readable.
    var scheme: ColorScheme? {
        if let preset { return preset.dark ? .dark : .light }
        if choice.hasPrefix("color:") { return Color.luminance(hex: String(choice.dropFirst(6))) > 0.5 ? .light : .dark }
        return nil
    }

    func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "选择背景图片"
        guard panel.runModal() == .OK, let src = panel.url, let img = NSImage(contentsOf: src) else { return }
        // Keep a private copy so the background survives the original being moved or deleted.
        try? FileManager.default.removeItem(at: imageURL)
        guard (try? FileManager.default.copyItem(at: src, to: imageURL)) != nil else { return }
        image = img
        choice = "image"
    }

    func setColor(_ color: Color) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
        choice = String(format: "color:#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

extension Color {
    init?(hex: String) {
        guard let v = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
        self.init(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static func luminance(hex: String) -> Double {
        let v = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return (0.299 * Double(v >> 16 & 0xFF) + 0.587 * Double(v >> 8 & 0xFF) + 0.114 * Double(v & 0xFF)) / 255
    }
}
