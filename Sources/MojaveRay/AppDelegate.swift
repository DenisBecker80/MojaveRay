import AppKit

@objc private protocol StandardEditMenuActions {
    func undo(_ sender: Any?)
    func cut(_ sender: Any?)
    func copy(_ sender: Any?)
    func paste(_ sender: Any?)
    func selectAll(_ sender: Any?)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let connectionManager = ConnectionManager()
    private var mainWindowController: MainWindowController?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var isSecondaryInstance = false
    private var isTerminating = false
    private var autostartMenuItem: NSMenuItem?
    static let isLoginLaunch = CommandLine.arguments.contains("--launch-at-login")

    private static let showWindowNotification = Notification.Name("com.denisbekker.MojaveRay.show-window")

    func applicationWillFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showMainWindow),
            name: AppDelegate.showWindowNotification,
            object: nil
        )

        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != currentPID }) else { return }

        isSecondaryInstance = true
        if AppDelegate.isLoginLaunch {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            AppDelegate.showWindowNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isSecondaryInstance else { return }
        restoreApplicationIcon()
        buildMainMenu()
        buildStatusItem()
        updateStatusItem(connectionManager.state)
        if AppDelegate.isLoginLaunch {
            NSApp.setActivationPolicy(.accessory)
        } else {
            showMainWindow()
        }
    }

    // Do not load the keychain or present recovery dialogs during login.
    private func ensureMainWindowController() -> MainWindowController {
        if let controller = mainWindowController { return controller }
        let controller = MainWindowController(connectionManager: connectionManager)
        mainWindowController = controller
        controller.window?.delegate = self
        controller.onConnectionStateChange = { [weak self] state in
            self?.updateStatusItem(state)
        }
        controller.recoverInterruptedSessionIfNeeded()
        return controller
    }

    func restoreApplicationIcon() {
        if let iconURL = Bundle.main.url(forResource: "MojaveRayIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isSecondaryInstance else { return }
        restoreApplicationIcon()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isSecondaryInstance { return .terminateNow }
        isTerminating = true
        guard connectionManager.state != .disconnected else {
            return .terminateNow
        }
        mainWindowController?.disconnectForTermination { success in
            sender.reply(toApplicationShouldTerminate: success)
            if !success {
                self.isTerminating = false
                self.mainWindowController?.showWindow(self)
                self.mainWindowController?.window?.makeKeyAndOrderFront(self)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        connectionManager.forceStopProcesses()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isTerminating else { return true }
        sender.orderOut(self)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        updateStatusItem(connectionManager.state)
        autostartMenuItem?.state = LoginLaunch.isEnabled ? .on : .off
    }

    private func updateStatusItem(_ state: ConnectionState) {
        guard let menu = statusMenu else { return }
        let connected: Bool
        let description: String
        switch state {
        case .connected(let mode):
            connected = true
            description = mode.connectedTitle
        case .disconnected:
            connected = false
            description = "VPN отключён"
        case .connecting:
            connected = false
            description = "Подключение…"
        case .disconnecting:
            connected = false
            description = "Отключение…"
        }
        statusItem?.button?.attributedTitle = NSAttributedString(string: "VPN", attributes: [
            .foregroundColor: connected ? NSColor.systemGreen : NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        ])
        statusItem?.button?.toolTip = description
        menu.item(at: 0)?.isEnabled = true
        menu.item(at: 2)?.isEnabled = state == .disconnected
        if case .connected = state {
            menu.item(at: 3)?.isEnabled = true
        } else {
            menu.item(at: 3)?.isEnabled = false
        }
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "VPN"
        item.button?.toolTip = "MojaveRay"

        let menu = NSMenu(title: "VPN")
        // AppKit must not overwrite the state-specific isEnabled values.
        menu.autoenablesItems = false
        menu.delegate = self
        let restore = menu.addItem(withTitle: "Вернуться в полный режим", action: #selector(showMainWindow), keyEquivalent: "")
        restore.target = self
        menu.addItem(NSMenuItem.separator())
        let connect = menu.addItem(withTitle: "Подключить VPN", action: #selector(connectFromStatusItem), keyEquivalent: "")
        connect.target = self
        let disconnect = menu.addItem(withTitle: "Отключить VPN", action: #selector(disconnectFromStatusItem), keyEquivalent: "")
        disconnect.target = self
        menu.addItem(NSMenuItem.separator())
        let autostart = menu.addItem(withTitle: "Запускать при входе в macOS", action: #selector(toggleAutostart), keyEquivalent: "")
        autostart.target = self
        autostart.state = LoginLaunch.isEnabled ? .on : .off
        autostartMenuItem = autostart
        menu.addItem(NSMenuItem.separator())
        let quit = menu.addItem(withTitle: "Выйти", action: #selector(quitFromStatusItem), keyEquivalent: "")
        quit.target = self

        item.menu = menu
        statusItem = item
        statusMenu = menu
    }

    @objc private func showMainWindow() {
        guard !isSecondaryInstance else { return }
        let controller = ensureMainWindowController()
        NSApp.setActivationPolicy(.regular)
        restoreApplicationIcon()
        // Dock registration completes after changing accessory -> regular.
        DispatchQueue.main.async { [weak self] in
            guard NSApp.activationPolicy() == .regular else { return }
            self?.restoreApplicationIcon()
        }
        controller.showWindow(self)
        if controller.window?.isMiniaturized == true {
            controller.window?.deminiaturize(self)
        }
        controller.window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func connectFromStatusItem() {
        ensureMainWindowController().connectFromStatusMenu()
    }

    @objc private func disconnectFromStatusItem() {
        mainWindowController?.disconnectFromStatusMenu()
    }

    @objc private func toggleAutostart() {
        do {
            try LoginLaunch.setEnabled(!LoginLaunch.isEnabled)
            autostartMenuItem?.state = LoginLaunch.isEnabled ? .on : .off
        } catch {
            showMainWindow()
            let alert = NSAlert()
            alert.messageText = "Не удалось изменить автозапуск"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quitFromStatusItem() {
        NSApp.terminate(self)
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)

        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "О MojaveRay", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let repair = applicationMenu.addItem(withTitle: "Переустановить системный помощник…", action: #selector(repairHelper), keyEquivalent: "")
        repair.target = self
        let remove = applicationMenu.addItem(withTitle: "Удалить системный помощник…", action: #selector(removeHelper), keyEquivalent: "")
        remove.target = self
        applicationMenu.addItem(NSMenuItem.separator())
        applicationMenu.addItem(withTitle: "Скрыть MojaveRay", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        applicationMenu.addItem(NSMenuItem.separator())
        applicationMenu.addItem(withTitle: "Завершить MojaveRay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu

        let editItem = NSMenuItem(title: "Правка", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Правка")
        editMenu.addItem(withTitle: "Отменить", action: #selector(StandardEditMenuActions.undo(_:)), keyEquivalent: "z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Вырезать", action: #selector(StandardEditMenuActions.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Копировать", action: #selector(StandardEditMenuActions.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(StandardEditMenuActions.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выбрать всё", action: #selector(StandardEditMenuActions.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func repairHelper() { manageHelper("install") }
    @objc private func removeHelper() { manageHelper("uninstall") }

    private func manageHelper(_ action: String) {
        guard connectionManager.state == .disconnected else {
            let alert = NSAlert()
            alert.messageText = "Сначала отключите VPN"
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = action == "install" ? "Переустановить системный помощник?" : "Удалить системный помощник?"
        alert.informativeText = action == "install"
            ? "macOS запросит пароль администратора. Помощник будет управлять только сетевыми операциями MojaveRay для вашей учётной записи."
            : "Служба будет удалена. VPN-ключ останется в Связке ключей. При следующем подключении потребуется установить службу заново."
        alert.addButton(withTitle: "Продолжить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        connectionManager.manageSystemHelper(action) { error in
            let result = NSAlert()
            result.messageText = error == nil ? "Готово" : "Не удалось выполнить операцию"
            result.informativeText = error?.localizedDescription ?? (action == "install" ? "Помощник установлен." : "Помощник удалён.")
            result.runModal()
        }
    }
}

// A per-user LaunchAgent works on macOS 10.14 without administrator access.
private enum LoginLaunch {
    private static let label = "com.denisbekker.MojaveRay.login"
    private static var agentURL: URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent(label + ".plist")
    }

    static var isEnabled: Bool {
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if !enabled {
            if isEnabled { try FileManager.default.removeItem(at: agentURL) }
            return
        }
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app",
              bundleURL.path.hasPrefix("/Applications/") ||
              bundleURL.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications").path + "/") else {
            throw NSError(domain: label, code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Сначала перенесите MojaveRay.app в папку Программы и запустите оттуда. Затем включите автозапуск."])
        }
        let settings: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", "-a", bundleURL.path,
                                 "--args", "--launch-at-login"],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: settings,
                                                     format: .xml, options: 0)
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true, attributes: nil)
        try data.write(to: agentURL, options: .atomic)
        // launchd reads this file at the next login; enabling must not launch a second instance.
    }
}
