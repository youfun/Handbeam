import AppKit
import WebKit
import HandbeamCore

@MainActor
final class WebWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, NSToolbarDelegate {
    private let webView: WKWebView
    private let overlay = NSView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "重試", target: nil, action: nil)
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let panelButton = NSButton()
    private let workspaceTabs = NSSegmentedControl(
        labels: ["Changes", "Files", "Terminal"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let workspaceLabel = NSTextField(labelWithString: "")
    private let workspaceControls = NSStackView()
    private let toolbarTitleLabel = NSTextField(labelWithString: "Handbeam")
    private var origin = AppOrigin(hosts: DesktopConfig.loopbackHosts, port: DesktopConfig.defaultPort)
    private var loadedURL: URL?
    private var lastState: BackendController.State = .idle
    var onRetry: (() -> Void)?

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Handbeam"
        window.minSize = NSSize(width: 960, height: 640)
        window.setFrameAutosaveName("HandbeamMain")
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        super.init(window: window)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        installToolbar()
        installViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func apply(_ state: BackendController.State) {
        lastState = state
        switch state {
        case .idle, .starting:
            showOverlay("正在啟動 Handbeam…", retry: false)
        case .ready(let url, _):
            origin = AppOrigin(pageURL: url)
            window?.title = "Handbeam"
            if loadedURL != url {
                loadedURL = url
                showOverlay("正在載入工作區…", retry: false)
                webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
            }
        case .failed(let message):
            showOverlay(message, retry: true)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        switch NavigationPolicy.decide(url: url, origin: origin, mainFrame: mainFrame) {
        case .allow:
            decisionHandler(.allow)
        case .openExternally:
            openExternally(url)
            decisionHandler(.cancel)
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            let decision = NavigationPolicy.decide(url: url, origin: origin, mainFrame: true)
            if decision == .openExternally {
                openExternally(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        showOverlay("頁面載入失敗：\(nsError.localizedDescription)", retry: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("""
        document.documentElement.classList.add('handbeam-desktop-shell');
        if (!document.querySelector('#handbeam-desktop-shell-style')) {
          const style = document.createElement('style');
          style.id = 'handbeam-desktop-shell-style';
          style.textContent = '.workspace-panel-header, .workspace-panel-toggle { display: none !important; }';
          document.head.appendChild(style);
        }
        """)
        toolbarTitleLabel.stringValue = webView.title ?? "Handbeam"
        updateNavigationButtons()
        syncWorkspacePanelState()
        hideOverlay()
    }

    @objc private func goBack() {
        webView.goBack()
        updateNavigationButtons()
    }

    @objc private func goForward() {
        webView.goForward()
        updateNavigationButtons()
    }

    @objc private func reloadPage() {
        webView.reload()
    }

    @objc private func newConversation() {
        clickWebControl(".workspace-title-row.is-active .workspace-add-btn")
    }

    @objc private func toggleWorkspacePanel() {
        clickWebControl("#workspace-panel-toggle")
        workspaceControls.isHidden.toggle()
        updatePanelButton(collapsed: workspaceControls.isHidden)
        syncWorkspacePanelState(after: 0.15)
    }

    @objc private func selectWorkspacePanelView() {
        let views = ["changes", "files", "terminal"]
        guard views.indices.contains(workspaceTabs.selectedSegment) else { return }
        let view = views[workspaceTabs.selectedSegment]
        clickWebControl(
            "button[phx-click='select_right_panel_view'][phx-value-view='\(view)']"
        )
        syncWorkspacePanelState(after: 0.15)
    }

    @objc private func openSettings() {
        navigateWebControl("#open-settings")
    }

    private func openExternally(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "mailto", "tel"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func retry() {
        if loadedURL != nil, case .ready = lastState {
            hideOverlay()
            webView.reload()
            return
        }
        onRetry?()
    }

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "HandbeamToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifier = .handbeamTitle
        window?.toolbar = toolbar
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.navigation, .reload, .flexibleSpace, .handbeamTitle, .primaryActions]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.navigation, .reload, .flexibleSpace, .handbeamTitle, .flexibleSpace, .primaryActions]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .navigation:
            configureToolbarButton(backButton, symbol: "chevron.left", action: #selector(goBack), help: "返回")
            configureToolbarButton(forwardButton, symbol: "chevron.right", action: #selector(goForward), help: "前進")
            updateNavigationButtons()
            let stack = NSStackView(views: [backButton, forwardButton])
            stack.orientation = .horizontal
            stack.spacing = 2
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = stack
            item.label = "導覽"
            return item
        case .reload:
            let button = NSButton()
            configureToolbarButton(button, symbol: "arrow.clockwise", action: #selector(reloadPage), help: "重新載入")
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = button
            item.label = "重新載入"
            return item
        case .handbeamTitle:
            let icon = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 20),
                icon.heightAnchor.constraint(equalToConstant: 20),
            ])
            toolbarTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            toolbarTitleLabel.lineBreakMode = .byTruncatingTail
            let stack = NSStackView(views: [icon, toolbarTitleLabel])
            stack.orientation = .horizontal
            stack.spacing = 7
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = stack
            item.label = "Handbeam"
            return item
        case .primaryActions:
            let newButton = NSButton()
            configureToolbarButton(newButton, symbol: "plus", action: #selector(newConversation), help: "新對話")
            configureToolbarButton(
                panelButton,
                symbol: "sidebar.right",
                action: #selector(toggleWorkspacePanel),
                help: "切換工作區面板"
            )
            let settingsButton = NSButton()
            configureToolbarButton(settingsButton, symbol: "gearshape", action: #selector(openSettings), help: "設定")

            workspaceTabs.target = self
            workspaceTabs.action = #selector(selectWorkspacePanelView)
            workspaceTabs.selectedSegment = 1
            workspaceTabs.controlSize = .small
            workspaceLabel.font = .systemFont(ofSize: 12)
            workspaceLabel.textColor = .secondaryLabelColor
            workspaceLabel.lineBreakMode = .byTruncatingTail
            workspaceLabel.maximumNumberOfLines = 1
            workspaceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            workspaceControls.setViews([workspaceTabs, workspaceLabel], in: .leading)
            workspaceControls.orientation = .horizontal
            workspaceControls.spacing = 7

            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.heightAnchor.constraint(equalToConstant: 18).isActive = true

            let stack = NSStackView(
                views: [newButton, panelButton, settingsButton, separator, workspaceControls]
            )
            stack.orientation = .horizontal
            stack.spacing = 5
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = stack
            item.label = "動作"
            return item
        default:
            return nil
        }
    }

    private func configureToolbarButton(
        _ button: NSButton,
        symbol: String,
        action: Selector,
        help: String
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.target = self
        button.action = action
        button.isBordered = false
        button.toolTip = help
        button.setAccessibilityLabel(help)
    }

    private func clickWebControl(_ selector: String) {
        let encoded = try? JSONSerialization.data(withJSONObject: selector, options: .fragmentsAllowed)
        guard let encoded, let literal = String(data: encoded, encoding: .utf8) else { return }
        webView.evaluateJavaScript("document.querySelector(\(literal))?.click()")
    }

    private func navigateWebControl(_ selector: String) {
        let encoded = try? JSONSerialization.data(withJSONObject: selector, options: .fragmentsAllowed)
        guard let encoded, let literal = String(data: encoded, encoding: .utf8) else { return }
        webView.evaluateJavaScript("""
        (() => {
          const href = document.querySelector(\(literal))?.href;
          if (href) window.location.assign(href);
        })()
        """)
    }

    private func syncWorkspacePanelState(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let script = """
            (() => {
              const panel = document.querySelector('#workspace-panel');
              const toggle = document.querySelector('#workspace-panel-toggle');
              if (!panel || !toggle) return null;
              return {
                collapsed: toggle.getAttribute('aria-pressed') === 'false',
                view: document.querySelector('.workspace-panel-tab.active')?.getAttribute('phx-value-view') || '',
                label: document.querySelector('.workspace-panel-label')?.textContent?.trim() || '',
                terminal: Boolean(document.querySelector("button[phx-value-view='terminal']"))
              };
            })()
            """
            self.webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self, let state = result as? [String: Any] else {
                    self?.panelButton.isEnabled = false
                    self?.workspaceControls.isHidden = true
                    return
                }
                let collapsed = state["collapsed"] as? Bool ?? false
                self.panelButton.isEnabled = true
                self.workspaceControls.isHidden = collapsed
                self.updatePanelButton(collapsed: collapsed)
                self.workspaceLabel.stringValue = state["label"] as? String ?? ""
                self.workspaceTabs.setEnabled(
                    state["terminal"] as? Bool ?? false,
                    forSegment: 2
                )
                let views = ["changes", "files", "terminal"]
                self.workspaceTabs.selectedSegment = views.firstIndex(
                    of: state["view"] as? String ?? ""
                ) ?? -1
            }
        }
    }

    private func updatePanelButton(collapsed: Bool) {
        panelButton.image = NSImage(
            systemSymbolName: "sidebar.right",
            accessibilityDescription: collapsed ? "顯示工作區面板" : "收起工作區面板"
        )
        panelButton.toolTip = collapsed ? "顯示工作區面板" : "收起工作區面板"
        panelButton.setAccessibilityLabel(panelButton.toolTip)
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    private func installViews() {
        guard let content = window?.contentView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 13)
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.bezelStyle = .rounded
        overlay.addSubview(statusLabel)
        overlay.addSubview(retryButton)
        content.addSubview(webView)
        content.addSubview(overlay)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: content.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -16),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, constant: -48),
            retryButton.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
        ])
    }

    private func showOverlay(_ message: String, retry: Bool) {
        statusLabel.stringValue = message
        retryButton.isHidden = !retry
        overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        overlay.isHidden = false
    }

    private func hideOverlay() {
        overlay.isHidden = true
    }
}

private extension NSToolbarItem.Identifier {
    static let navigation = NSToolbarItem.Identifier("HandbeamNavigation")
    static let reload = NSToolbarItem.Identifier("HandbeamReload")
    static let handbeamTitle = NSToolbarItem.Identifier("HandbeamTitle")
    static let primaryActions = NSToolbarItem.Identifier("HandbeamPrimaryActions")
}
