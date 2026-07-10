import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    self.sharingType = .readOnly
    self.collectionBehavior.insert(.moveToActiveSpace)
    self.center()
    self.makeKeyAndOrderFront(nil)
    self.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
  }
}
