import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let controller = FlutterViewController()
    let originalFrame = frame
    contentViewController = controller
    setFrame(originalFrame, display: true)
    RegisterGeneratedPlugins(registry: controller)
    super.awakeFromNib()

    // shortcut: P0 waits 3s for this sample; production needs an engine-ready handshake.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      guard ProcessInfo.processInfo.environment["P0_ENABLE_NATIVE_SEMANTICS"] == "1" else { return }
      let engine = controller.engine
      // shortcut: private property verified on Flutter 3.27.1; revalidate for every engine version.
      precondition(engine.responds(to: NSSelectorFromString("setSemanticsEnabled:")))
      engine.setValue(true, forKey: "semanticsEnabled")
    }
  }
}
