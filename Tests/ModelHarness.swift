import Foundation
import SwiftUI

/// Drives the app's Model and Appearance without UI: checkboxes, multi-select, input filtering,
/// the background queue and backdrop colors. Usage: model-harness <dir with src.mobi src.cbz src.pdf> <out dir>
@main
struct ModelHarness {
    static var failures = 0
    static func check(_ name: String, _ ok: Bool) { print((ok ? "PASS " : "FAIL ") + name); if !ok { failures += 1 } }

    static func main() {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1]), out = URL(fileURLWithPath: CommandLine.arguments[2])
        let m = Model.shared
        m.format = .cbz
        m.outputFolder = out
        m.add(["src.mobi", "src.cbz", "src.pdf", "src.azw3"].map { dir.appendingPathComponent($0) })
        check("加入 4 个文件且默认全部勾选", m.items.count == 4 && m.checkedCount == 4)
        check("AZW3 标签显示为 AZW3", m.items[3].badge == "AZW3" && m.items[0].badge == "MOBI")
        m.add([dir.appendingPathComponent("src.mobi")])
        check("重复加入被忽略", m.items.count == 4)

        m.input = .mobi
        check("输入格式选 MOBI 时只勾选 MOBI/AZW3", m.items.filter(\.checked).map(\.url.pathExtension) == ["mobi", "azw3"])
        m.input = .auto
        check("切回自动识别后全部勾选", m.checkedCount == 4)

        let ids = Set(m.items.prefix(2).map(\.id))
        m.selection = ids
        m.setChecked(m.selection, false)
        check("多选后批量取消勾选", m.checkedCount == 2 && !m.items[0].checked && !m.items[1].checked)
        m.remove(Set([m.items[1].id]))
        check("移除所选项并同步更新选择", m.items.count == 3 && m.selection.count == 1)

        m.start()
        let deadline = Date().addingTimeInterval(60)
        while (m.running || m.items.allSatisfy({ if case .waiting = $0.state { return true }; return false })) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let states = m.items.map { item -> String in
            switch item.state { case .done: return "done"; case .failed(let e): return "failed: \(e)"; case .waiting: return "waiting"; case .running: return "running" }
        }
        check("只转换已勾选项（未勾选项保持等待）", states == ["waiting", "done", "done"])
        check("输出文件已生成", (try? FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasSuffix(".cbz") }.count) == 2)

        let a = Appearance.shared
        a.choice = "preset:sakura"
        check("浅色预设使用浅色外观", a.scheme == .light && a.preset?.name == "樱花粉")
        a.choice = "preset:midnight"
        check("深色预设使用深色外观", a.scheme == .dark)
        a.setColor(Color(hex: "#1A1A33")!)
        check("自定义深色按亮度切到深色外观", a.choice == "color:#1A1A33" && a.scheme == .dark)
        a.setColor(.white)
        check("自定义浅色按亮度切到浅色外观", a.scheme == .light)
        a.choice = "system"
        check("跟随系统", a.scheme == nil)
        print(failures == 0 ? "MODEL OK" : "MODEL FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
