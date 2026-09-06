import UIKit
import WebKit

/// The whole app: one web view pointed at the owner's dashboard, plus the
/// bridge that lets the player in that dashboard drive the device's brightness
/// and volume.
final class WebViewController: UIViewController {

    private let controls = SystemControls()
    private var webView: WKWebView!
    private var bridgeSource = ""

    private lazy var failureView = FailureView(
        onRetry: { [weak self] in self?.load() },
        onSettings: { [weak self] in self?.presentSettings() })

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background

        bridgeSource = Self.loadBridgeSource()
        buildWebView()

        failureView.isHidden = true
        failureView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(failureView)
        NSLayoutConstraint.activate([
            failureView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            failureView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            failureView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        controls.attach(to: view)
        controls.onChange = { [weak self] in self?.pushLevelsToPage() }

        load()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    /// Shake to reach the settings. The dashboard fills the screen and none of
    /// it belongs to the app, so a floating button would just be something in
    /// the way of the thing the viewer came for.
    override var canBecomeFirstResponder: Bool { true }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { presentSettings() }
    }

    // MARK: - Web view

    private func buildWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        // The player decides when to start; requiring a gesture here would make
        // its own autoplay handling look like a stall.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(
            WeakMessageHandler(self), name: "agpNative")
        enableElementFullscreen(on: configuration.preferences)
        installUserScripts(into: configuration.userContentController)

        webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = Theme.background
        webView.scrollView.backgroundColor = Theme.background
        // The dashboard's CSS already reads env(safe-area-inset-*) under
        // viewport-fit=cover, so the web view takes the whole screen and lets
        // the page place itself.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)
    }

    /// `Element.requestFullscreen` is off by default in `WKWebView`. Without it
    /// the player falls back to filling the viewport itself, which keeps the
    /// custom controls but never covers the status bar.
    ///
    /// The public switch arrived in iOS 15.4; older WebKits answer only to the
    /// underscored SPI. Neither is API on every SDK this builds against, so
    /// both are asked for rather than assumed — and KVC finds `_set…:` under
    /// the same key, which is why the keys drop the leading underscore.
    private func enableElementFullscreen(on preferences: WKPreferences) {
        let candidates = [
            ("setElementFullscreenEnabled:", "elementFullscreenEnabled"),
            ("_setFullScreenEnabled:", "fullScreenEnabled"),
        ]
        for (selector, key) in candidates
        where preferences.responds(to: NSSelectorFromString(selector)) {
            preferences.setValue(true, forKey: key)
            return
        }
    }

    private static func loadBridgeSource() -> String {
        guard let url = Bundle.main.url(forResource: "Bridge", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return source
    }

    /// Re-seeded for every navigation: a user script is fixed once the document
    /// starts, so the levels baked into it have to be the ones current at the
    /// moment the page is about to load.
    private func installUserScripts(into controller: WKUserContentController) {
        controller.removeAllUserScripts()
        let seed = "window.__AGP_NATIVE_SEED__ = {brightness: \(controls.brightness), volume: \(controls.volume)};"
        for source in [seed, bridgeSource] where !source.isEmpty {
            controller.addUserScript(WKUserScript(source: source,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true))
        }
    }

    private func pushLevelsToPage() {
        let script = "window.AgpNative && window.AgpNative._update("
            + "{brightness: \(controls.brightness), volume: \(controls.volume)});"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func load() {
        let url = ServerAddress.current
        failureView.isHidden = true
        webView.isHidden = false
        webView.load(URLRequest(url: url))
    }

    private func show(failure: Error) {
        // -999 is "a newer navigation replaced this one", which is not a
        // failure the viewer has any use for hearing about.
        if (failure as NSError).code == NSURLErrorCancelled { return }
        failureView.present(failure, address: ServerAddress.current)
        failureView.isHidden = false
        webView.isHidden = true
    }

    // MARK: - Settings

    private func presentSettings() {
        let sheet = UIAlertController(
            title: "伺服器位址",
            message: "輸入這台裝置連得到的 aniGamerPlus 主控台網址。",
            preferredStyle: .alert)
        sheet.addTextField { field in
            field.placeholder = "192.168.1.10:5000"
            field.text = ServerAddress.current.absoluteString
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        sheet.addAction(UIAlertAction(title: "連線", style: .default) { [weak self, weak sheet] _ in
            guard let self = self else { return }
            guard let typed = sheet?.textFields?.first?.text,
                  let url = ServerAddress.normalise(typed) else {
                return self.presentSettings()
            }
            ServerAddress.current = url
            self.load()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }
}

// MARK: - Navigation

extension WebViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        installUserScripts(into: webView.configuration.userContentController)
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The seed covers the gap before this lands; this covers the case where
        // a level moved between the policy decision and the document.
        pushLevelsToPage()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        show(failure: error)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        show(failure: error)
    }
}

// MARK: - Page chrome

extension WebViewController: WKUIDelegate {

    /// A page opened with `target="_blank"` gets no window of its own here, so
    /// without this the link simply does nothing.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "確定", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "確定", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        present(alert, animated: true)
    }
}

// MARK: - Bridge

extension WebViewController: WKScriptMessageHandler {

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let name = payload["name"] as? String else { return }
        let value = payload["value"] as? Double

        switch name {
        case "brightness":
            if let value = value { controls.brightness = value }
        case "volume":
            if let value = value { controls.volume = value }
        case "settings":
            presentSettings()
        default:
            break
        }
    }
}

/// `WKUserContentController` retains its message handlers, and the controller
/// belongs to the web view the handler owns — so handing it `self` directly
/// would be a cycle that outlives the controller.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {

    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
