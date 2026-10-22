import Cocoa
import FlutterMacOS
import WebKit

class MainFlutterWindow: NSWindow {
  private var browserTestSessions: [String: WorkBrowserTestSession] = [:]

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

    let browserTestChannel = FlutterMethodChannel(
      name: "com.chatgroup/browser_test",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    browserTestChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self,
            let arguments = call.arguments as? [String: Any],
            let operation = arguments["operation"] as? String,
            let sessionRef = arguments["sessionRef"] as? String else {
        result(FlutterError(code: "invalid_arguments", message: nil, details: nil))
        return
      }
      self.handleBrowserTest(operation, sessionRef: sessionRef, arguments: arguments, result: result)
    }

    self.sharingType = .readOnly
    self.collectionBehavior.insert(.moveToActiveSpace)
    self.center()
    self.makeKeyAndOrderFront(nil)
    self.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
  }

  private func handleBrowserTest(
    _ operation: String,
    sessionRef: String,
    arguments: [String: Any],
    result: @escaping FlutterResult
  ) {
    switch operation {
    case "session-status":
      result(["activeSessionCount": browserTestSessions.count])
    case "open":
      guard browserTestSessions.count < 2,
            browserTestSessions[sessionRef] == nil,
            let filePath = arguments["filePath"] as? String,
            let rootPath = arguments["rootPath"] as? String else {
        result(FlutterError(code: "invalid_open", message: "候选或浏览器会话无效。", details: nil))
        return
      }
      let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL.resolvingSymlinksInPath()
      let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
      let fileValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
      guard fileURL.pathExtension.lowercased() == "html",
            fileValues?.isRegularFile == true,
            fileURL.path.hasPrefix(rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/") else {
        result(FlutterError(code: "candidate_rejected", message: "只允许读取候选目录内的单个 HTML 文件。", details: nil))
        return
      }
      let queryParameters = arguments["queryParameters"] as? [String: String] ?? [:]
      guard arguments["queryParameters"] == nil || arguments["queryParameters"] is [String: String],
            queryParameters.count <= 8,
            queryParameters.allSatisfy({ entry in
              let (key, value) = entry
              return key.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil &&
                key.range(of: "(?:api[-_]?key|token|secret|pass(?:word)?|auth(?:orization)?|credential|cookie)", options: [.regularExpression, .caseInsensitive]) == nil &&
                value.utf16.count <= 256 &&
                !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
            }),
            queryParameters.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count + 2 }) <= 1024,
            var pageComponents = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) else {
        result(FlutterError(code: "invalid_query_parameters", message: "测试参数无效，或超过安全边界。", details: nil))
        return
      }
      pageComponents.queryItems = queryParameters.keys.sorted().map {
        URLQueryItem(name: $0, value: queryParameters[$0])
      }
      guard let pageURL = pageComponents.url else {
        result(FlutterError(code: "invalid_query_parameters", message: "测试参数无法转换为候选页面地址。", details: nil))
        return
      }
      compileOfflineRules { [weak self] rules, error in
        DispatchQueue.main.async {
          guard let self = self, let rules = rules, error == nil else {
            result(FlutterError(code: "browser_unavailable", message: "离线浏览器规则初始化失败。", details: nil))
            return
          }
          let session = WorkBrowserTestSession(fileURL: fileURL, pageURL: pageURL, rules: rules)
          self.browserTestSessions[sessionRef] = session
          session.open { outcome in
            switch outcome {
            case .success(let snapshot): result(["snapshot": snapshot])
            case .failure(let error):
              self.browserTestSessions.removeValue(forKey: sessionRef)
              result(FlutterError(code: "browser_open_failed", message: String(describing: error), details: nil))
            }
          }
        }
      }
    case "close":
      guard let session = browserTestSessions.removeValue(forKey: sessionRef) else {
        result(["closed": true, "alreadyClosed": true])
        return
      }
      session.close()
      result(["closed": true])
    case "observe", "click", "assert":
      guard let session = browserTestSessions[sessionRef] else {
        result(FlutterError(code: "session_missing", message: "浏览器会话已关闭。", details: nil))
        return
      }
      if operation == "observe" {
        session.observe(completion: result)
      } else if operation == "click" {
        guard let label = arguments["label"] as? String, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          result(FlutterError(code: "invalid_action", message: "点击必须指定可见控件的完整文字。", details: nil))
          return
        }
        session.click(label: label, completion: result)
      } else {
        guard let expectedText = arguments["expectedText"] as? String, !expectedText.isEmpty else {
          result(FlutterError(code: "invalid_assertion", message: "断言必须指定非空可见文字。", details: nil))
          return
        }
        session.assertVisible(expectedText: expectedText, completion: result)
      }
    case "resize":
      guard let session = browserTestSessions[sessionRef],
            let width = arguments["width"] as? Int,
            let height = arguments["height"] as? Int,
            (320...1440).contains(width),
            (480...1200).contains(height) else {
        result(FlutterError(code: "invalid_resize", message: "浏览器窗口尺寸必须在 320×480 至 1440×1200 之间。", details: nil))
        return
      }
      session.resize(width: width, height: height, completion: result)
    default:
      result(FlutterError(code: "unsupported_operation", message: "不支持此浏览器操作。", details: nil))
    }
  }

  private func compileOfflineRules(completion: @escaping (WKContentRuleList?, Error?) -> Void) {
    // WebKit content rules do not support regular-expression alternation.
    let source = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
    WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: "com.chatgroup.offlineCandidate",
      encodedContentRuleList: source,
      completionHandler: completion
    )
  }
}

@MainActor
private final class WorkBrowserTestSession: NSObject, WKNavigationDelegate {
  private let fileURL: URL
  private let pageURL: URL
  private let window: NSWindow
  private let webView: WKWebView
  private var openCompletion: ((Result<[String: Any], Error>) -> Void)?
  private var loadTimer: DispatchWorkItem?

  init(fileURL: URL, pageURL: URL, rules: WKContentRuleList) {
    self.fileURL = fileURL
    self.pageURL = pageURL
    let controller = WKUserContentController()
    controller.add(rules)
    let configuration = WKWebViewConfiguration()
    configuration.userContentController = controller
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    self.webView = WKWebView(frame: .zero, configuration: configuration)
    self.window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    super.init()
    webView.navigationDelegate = self
    // The session owns this programmatic window; close must not release it again.
    window.isReleasedWhenClosed = false
    window.title = "工作模式 · 隔离浏览器测试"
    window.contentView = webView
    window.center()
  }

  func open(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    openCompletion = completion
    let timeout = DispatchWorkItem { [weak self] in
      guard let self = self, let completion = self.openCompletion else { return }
      self.openCompletion = nil
      completion(.failure(NSError(domain: "ChatGroupBrowserTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "候选页面加载超过 20 秒。"])))
      self.close()
    }
    loadTimer = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    webView.loadFileURL(pageURL, allowingReadAccessTo: fileURL)
  }

  func close() {
    loadTimer?.cancel()
    loadTimer = nil
    openCompletion = nil
    webView.stopLoading()
    webView.navigationDelegate = nil
    window.close()
  }

  func resize(width: Int, height: Int, completion: @escaping FlutterResult) {
    window.setContentSize(NSSize(width: width, height: height))
    observe(completion: completion)
  }

  func observe(completion: @escaping FlutterResult) {
    evaluate(#"(() => { const body = document.body?.innerText ?? ''; const all = [...document.querySelectorAll('button,[role="button"],input[type="button"]')]; const visible = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length); const controls = all.filter(visible).slice(0, 100).map(e => ({label:(e.getAttribute('aria-label') || e.innerText || e.value || '').trim().slice(0,256), disabled:!!e.disabled, role:e.getAttribute('role') || e.tagName.toLowerCase()})); return JSON.stringify({title:document.title, readyState:document.readyState, viewport:{width:innerWidth,height:innerHeight}, visibleText:body.slice(0,8000), textTruncated:body.length>8000, controls, controlsTruncated:all.filter(visible).length>100}); })()"#) { [weak self] value in
      guard let self = self,
            let value = value as? [String: Any],
            let json = value["result"] as? String else {
        completion(FlutterError(code: "browser_result_invalid", message: "浏览器未返回页面观察结果。", details: nil))
        return
      }
      self.captureScreenshot { dataURI, error in
        guard let dataURI = dataURI, error == nil else {
          completion(FlutterError(code: "browser_screenshot_failed", message: "页面截图不可用，不能完成当前浏览器观察。", details: nil))
          return
        }
        completion([
          "result": json,
          "content": [
            ["type": "text", "text": "这是当前候选在隔离 WebKit 窗口中的实际页面与控件状态。"],
            ["type": "image_url", "image_url": ["url": dataURI]],
          ],
        ])
      }
    }
  }

  func click(label: String, completion: @escaping FlutterResult) {
    let encoded = Self.javascriptString(label)
    evaluate(
      """
      (() => {
        const wanted = \(encoded).trim();
        const all = [...document.querySelectorAll('button,[role="button"],input[type="button"]')];
        const visible = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
        const matches = all.filter(e => visible(e) && (e.getAttribute('aria-label') || e.innerText || e.value || '').trim() === wanted);
        if (matches.length !== 1) return JSON.stringify({ok:false, reason:matches.length === 0 ? '找不到唯一的可见控件' : '匹配到多个可见控件', label:wanted, matchCount:matches.length});
        const button = matches[0];
        if (button.disabled) return JSON.stringify({ok:false, reason:'控件当前不可用', label:wanted});
        button.click();
        return JSON.stringify({ok:true, label:wanted});
      })()
      """,
      completion: completion
    )
  }

  func assertVisible(expectedText: String, completion: @escaping FlutterResult) {
    let encoded = Self.javascriptString(expectedText)
    evaluate(
      """
      (() => {
        const text = document.body?.innerText ?? '';
        const expected = \(encoded);
        return JSON.stringify({matched:text.includes(expected), expected, visibleText:text.slice(0,20000), textTruncated:text.length>20000});
      })()
      """,
      completion: completion
    )
  }

  private func evaluate(_ script: String, completion: @escaping FlutterResult) {
    guard window.isVisible else {
      completion(FlutterError(code: "session_closed", message: "浏览器窗口已关闭。", details: nil))
      return
    }
    webView.evaluateJavaScript(script) { value, error in
      if let error = error {
        completion(FlutterError(code: "browser_script_failed", message: error.localizedDescription, details: nil))
      } else if let value = value as? String {
        completion(["result": value])
      } else {
        completion(FlutterError(code: "browser_result_invalid", message: "浏览器未返回文本结果。", details: nil))
      }
    }
  }

  private func captureScreenshot(completion: @escaping (String?, Error?) -> Void) {
    webView.takeSnapshot(with: nil) { image, error in
      guard error == nil,
            let image = image,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:]) else {
        completion(nil, error)
        return
      }
      let dataURI = "data:image/png;base64,\(png.base64EncodedString())"
      guard dataURI.utf8.count <= 7 * 1024 * 1024 else {
        completion(nil, NSError(domain: "ChatGroupBrowserTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "页面截图超过成员模型可接收的大小。"]))
        return
      }
      completion(dataURI, nil)
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    let target = navigationAction.request.url?.standardizedFileURL.resolvingSymlinksInPath()
    decisionHandler(target?.isFileURL == true && target?.path == fileURL.path ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let completion = openCompletion else { return }
    openCompletion = nil
    loadTimer?.cancel()
    loadTimer = nil
    observe { value in
      if let snapshot = value as? [String: Any], snapshot["result"] is String {
        completion(.success(snapshot))
      } else {
        completion(.failure(NSError(domain: "ChatGroupBrowserTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "浏览器未能观察候选页面。"])))
      }
    }
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    finishOpen(error: error)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finishOpen(error: error)
  }

  private func finishOpen(error: Error) {
    guard let completion = openCompletion else { return }
    openCompletion = nil
    loadTimer?.cancel()
    loadTimer = nil
    completion(.failure(error))
  }

  private static func javascriptString(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
          let result = String(data: data, encoding: .utf8) else { return "\"\"" }
    return result
  }
}
