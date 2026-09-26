import AppKit
import Darwin
import HandbeamCore

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var instanceLock: SingleInstanceLock?
    private var menuBar: MenuBarController?
    private var backend: BackendController?
    private var windows: WebWindowController?
    private var activity: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let instanceLock = SingleInstanceLock.acquire() else {
            activateExistingInstance()
            NSApp.terminate(nil)
            return
        }
        self.instanceLock = instanceLock

        ProcessInfo.processInfo.disableSuddenTermination()
        NSApp.setActivationPolicy(.regular)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Handbeam local UI"
        )
        installSignalForwarding()
        installMainMenu()

        let menuBar = MenuBarController()
        menuBar.install()
        self.menuBar = menuBar

        let backend = BackendController()
        let window = WebWindowController()
        window.onRetry = { [weak backend] in
            backend?.start()
        }
        backend.onChange = { [weak window] state in
            window?.apply(state)
        }
        self.backend = backend
        self.windows = window
        window.show()
        window.apply(.starting)
        backend.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        backend?.stopOwnedBackend()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        menuBar?.shouldTerminateWhenLastWindowClosed ?? true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            windows?.show()
        }
        return true
    }

    private func activateExistingInstance() {
        let current = ProcessInfo.processInfo.processIdentifier

        NSRunningApplication.runningApplications(withBundleIdentifier: DesktopConfig.bundleIdentifier)
            .first(where: { $0.processIdentifier != current })?
            .activate(options: [])
    }

    private func installSignalForwarding() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Handbeam", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Handbeam", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Handbeam", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Handbeam",
            .applicationVersion: "0.1.0",
            .credits: NSAttributedString(string: "本機 WebKit 殼。聊天介面由捆綁的 Handbeam Web 後端提供。"),
        ])
    }
}

private final class SingleInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire() -> SingleInstanceLock? {
        let fileManager = FileManager.default
        let support = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Handbeam", isDirectory: true)

        do {
            try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let lockURL = support.appendingPathComponent("app.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }

        return SingleInstanceLock(descriptor: descriptor)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
