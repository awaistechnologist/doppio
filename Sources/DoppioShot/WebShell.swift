import Foundation
import AppKit
import WebKit

/// A URL turned into a native-feeling app: system WebKit only, no bundled
/// engine, with website data stored under the Shot's own data directory so two
/// web Shots of the same site can hold different logins.
final class WebShell: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    let plan: LaunchPlan
    private var window: NSWindow!
    private var webView: WKWebView!
    /// Popup windows (OAuth consent screens) held until the page closes them.
    private var popupWindows: [NSWindow] = []

    init(plan: LaunchPlan) {
        self.plan = plan
    }

    func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = self
        app.run()
        exit(EXIT_SUCCESS)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        load()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore()
        configuration.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15"

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Lets the page title drive the window title.
        webView.addObserver(self, forKeyPath: "title", options: .new, context: nil)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = plan.name
        window.contentView = webView
        window.center()
        // Remembers position and size per Shot.
        window.setFrameAutosaveName("DoppioWebShell-\(plan.shotID)")
        window.makeKeyAndOrderFront(nil)
    }

    /// A persistent store keyed to this Shot.
    ///
    /// There is no public API for pointing WebKit at an arbitrary directory, and
    /// the `HOME` override does not work either: WebKit resolves storage through
    /// the real home, so `.default()` writes to
    /// `~/Library/WebKit/<wrapper bundle ID>/`. Isolation between Shots still
    /// holds (each wrapper has its own bundle ID), but the Shot's declared data
    /// directory stayed empty and "Show Data Folder" pointed at nothing.
    ///
    /// `init(forIdentifier:)` gives an explicitly keyed store on macOS 14+,
    /// which makes the location predictable and removable. Older systems fall
    /// back to `.default()`, which is still per-bundle-ID isolated.
    private func dataStore() -> WKWebsiteDataStore {
        if plan.ephemeral { return .nonPersistent() }
        if #available(macOS 14.0, *) {
            if let uuid = UUID(uuidString: plan.shotID) {
                return WKWebsiteDataStore(forIdentifier: uuid)
            }
        }
        return .default()
    }

    private func load() {
        guard let string = plan.url, let url = URL(string: string) else {
            StubLog.note("web Shot has no valid URL")
            let alert = NSAlert()
            alert.messageText = "“\(plan.name)” has no web address"
            alert.informativeText = "This Shot is damaged. Open Doppio and regenerate or delete it."
            alert.alertStyle = .warning
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        webView.load(URLRequest(url: url))
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                              change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "title" else { return }
        if let title = webView.title, !title.isEmpty {
            window.title = title
        }
    }

    // MARK: - Navigation policy

    /// Links that leave the Shot's own site open in the user's default browser,
    /// which keeps a web Shot feeling like an app rather than a browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        // Only a click in the *main* window on a different host goes to the
        // default browser. Popups are exempt: an OAuth consent screen is on a
        // different host by definition, and handing it to Safari would break
        // the sign-in.
        if navigationAction.navigationType == .linkActivated,
           webView === self.webView,
           let home = plan.url.flatMap(URL.init(string:)),
           let host = url.host, let homeHost = home.host,
           !Self.sameSite(host, homeHost) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// Whether two hosts should count as the same site.
    ///
    /// A leading `www.` is ignored on both sides: a Shot created for
    /// `www.example.com` should not treat a link to `example.com` as external
    /// and hand it to the default browser.
    static func sameSite(_ host: String, _ other: String) -> Bool {
        func base(_ h: String) -> String {
            let lower = h.lowercased()
            return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
        }
        let a = base(host), b = base(other)
        return a == b || a.hasSuffix("." + b) || b.hasSuffix("." + a)
    }

    /// `target="_blank"` and `window.open`.
    ///
    /// These must open a real child web view sharing this Shot's data store.
    /// Loading them in the main view instead (and returning nil) breaks every
    /// "Sign in with Google/Microsoft" flow: the opener is navigated away, so
    /// the popup can never post its result back and the handshake never
    /// completes — exactly the flow a web Shot exists for.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self

        let width = windowFeatures.width?.doubleValue ?? 620
        let height = windowFeatures.height?.doubleValue ?? 720
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = plan.name
        window.contentView = popup
        window.center()
        // Programmatic NSWindows default to isReleasedWhenClosed = true, so
        // closing an OAuth popup with the red button would release a window
        // this array still strongly references — an over-release crash.
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        popupWindows.append(window)
        // Prune on close as well as on window.close(): the user can dismiss a
        // consent screen manually, and the JS path never fires then.
        NotificationCenter.default.addObserver(
            self, selector: #selector(popupWindowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: window)
        return popup
    }

    @objc private func popupWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        popupWindows.removeAll { $0 === window }
    }

    /// The page called `window.close()` — typically the last step of an OAuth
    /// redirect.
    ///
    /// Closing is the *only* thing done here. `close()` fires
    /// `willCloseNotification` synchronously, and that observer is the single
    /// place the array is pruned. An earlier version also called
    /// `remove(at: index)` afterwards, by which point the observer had already
    /// shortened the array — an index-out-of-range trap at exactly the moment a
    /// sign-in popup completes.
    func webViewDidClose(_ webView: WKWebView) {
        guard let window = popupWindows.first(where: { $0.contentView === webView }) else { return }
        window.close()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        StubLog.note("navigation failed: \(error.localizedDescription)")
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(plan.name)", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(plan.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(plan.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        add(viewMenu, "Reload", #selector(reload), "r")
        add(viewMenu, "Back", #selector(goBack), "[")
        add(viewMenu, "Forward", #selector(goForward), "]")
        viewMenu.addItem(.separator())
        add(viewMenu, "Copy Current URL", #selector(copyURL), "l")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func reload() { webView.reload() }
    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func copyURL() {
        guard let url = webView.url?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
}
