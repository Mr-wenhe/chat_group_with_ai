import Cocoa

final class SampleDelegate: NSObject, NSApplicationDelegate {
    let input = NSTextField(string: "")
    let result = NSTextField(labelWithString: "尚未保存")
    var window: NSWindow!
    let dataURL: URL

    override init() {
        // 测试数据必须显式指定，禁止退回用户的 Application Support。
        guard let path = ProcessInfo.processInfo.environment["CHAT_GROUP_TEST_DATA_DIR"]
                ?? ProcessInfo.processInfo.environment["P0_DATA_DIR"],
              path.hasPrefix("/"), !path.isEmpty else {
            fatalError("P0_DATA_DIR must be an absolute test directory")
        }
        dataURL = URL(fileURLWithPath: path).appendingPathComponent("note.txt")
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "P0 持久化样本"
        window.setAccessibilityIdentifier("p0-window")
        input.placeholderString = "输入一条便签"
        input.setAccessibilityIdentifier("p0-note")
        input.setAccessibilityLabel("便签内容")
        result.setAccessibilityIdentifier("p0-result")
        do {
            if FileManager.default.fileExists(atPath: dataURL.path) {
                input.stringValue = try String(contentsOf: dataURL, encoding: .utf8)
                result.stringValue = "已恢复：\(input.stringValue)"
            }
        } catch {
            result.stringValue = "读取失败：\(error.localizedDescription)"
        }
        let save = NSButton(title: "保存便签", target: self, action: #selector(saveNote))
        save.setAccessibilityIdentifier("p0-save")
        let stack = NSStackView(views: [input, save, result])
        stack.orientation = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 32),
            input.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func saveNote() {
        guard !input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result.stringValue = "请输入便签内容"
            return
        }
        do {
            try FileManager.default.createDirectory(at: dataURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            #if P0_BUG
            let saved = "错误：内容未持久化"
            #else
            let saved = input.stringValue
            #endif
            try saved.write(to: dataURL, atomically: true, encoding: .utf8)
            result.stringValue = "已保存：\(input.stringValue)"
        } catch {
            result.stringValue = "保存失败：\(error.localizedDescription)"
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = SampleDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
