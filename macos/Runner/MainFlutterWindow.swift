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

    let appIdentityChannel = FlutterMethodChannel(
      name: "com.chatgroup/native_app",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    appIdentityChannel.setMethodCallHandler { call, result in
      guard let arguments = call.arguments as? [String: Any] else {
        result(FlutterError(code: "invalid_arguments", message: nil, details: nil))
        return
      }
      guard call.method == "processes",
            let bundleId = arguments["bundleId"] as? String,
            let targetPath = arguments["appPath"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      let target = URL(fileURLWithPath: targetPath).standardizedFileURL.resolvingSymlinksInPath().path
      let matching = NSWorkspace.shared.runningApplications
        .filter { $0.bundleIdentifier == bundleId }
        .compactMap { application -> [String: Any]? in
          guard let url = application.bundleURL,
                let executableURL = application.executableURL else { return nil }
          return [
            "bundleId": bundleId,
            "appPath": url.standardizedFileURL.resolvingSymlinksInPath().path,
            "executablePath": executableURL.standardizedFileURL.resolvingSymlinksInPath().path,
            "pid": Int(application.processIdentifier),
          ]
        }
      let frontmost = NSWorkspace.shared.frontmostApplication
      let frontmostPath = frontmost?.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path
      result([
        "processes": matching,
        "frontmostMatches": frontmost?.bundleIdentifier == bundleId && frontmostPath == target,
      ])
    }

    self.sharingType = .readOnly
    self.collectionBehavior.insert(.moveToActiveSpace)
    self.center()
    self.makeKeyAndOrderFront(nil)
    self.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
  }
}
