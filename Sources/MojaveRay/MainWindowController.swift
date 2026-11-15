import AppKit
import Foundation
import MojaveRayCore

final class MainWindowController: NSWindowController {
    var onConnectionStateChange: ((ConnectionState) -> Void)?
    private let connectionManager: ConnectionManager
    private let keychain = KeychainStore()

    private var savedProfiles = SavedVLESSProfiles(profiles: [], selectedID: nil)
    private var profilesLoaded = false
    private let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField(frame: .zero)
    private let importAWGButton = NSButton(title: "Импорт AmneziaWG…", target: nil, action: nil)
    private let editButton = NSButton(title: "Изменить ключ", target: nil, action: nil)
    private let profileField = NSSecureTextField(frame: .zero)
    private let profileStatusLabel = NSTextField(labelWithString: "Профиль не сохранён")
    private let saveButton = NSButton(title: "Сохранить ключ", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Удалить", target: nil, action: nil)
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let proxyHint = NSTextField(wrappingLabelWithString: "")
    private let connectButton = NSButton(title: "Подключить", target: nil, action: nil)
    private let statusDot = NSTextField(labelWithString: "●")
    private let statusLabel = NSTextField(labelWithString: "Не подключено")
    private let ipLabel = NSTextField(labelWithString: "Внешний IP: —")
    private let progressIndicator = NSProgressIndicator(frame: .zero)
    private let logTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 650, height: 180))

    init(connectionManager: ConnectionManager) {
        self.connectionManager = connectionManager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 690),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MojaveRay"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
        bindManager()
        do {
            savedProfiles = try keychain.loadProfiles()
            profilesLoaded = true
            refreshProfileList()
        } catch {
            showError(error)
        }
        updateForState(.disconnected)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func recoverInterruptedSessionIfNeeded() {
        connectionManager.recoverIfNeeded { [weak self] error in
            if let error = error {
                self?.showError(error)
            }
        }
    }

    func disconnectForTermination(completion: @escaping (Bool) -> Void) {
        appendLog("Завершение приложения: восстанавливаю сеть")
        connectionManager.disconnect { [weak self] error in
            if let error = error {
                self?.showError(error)
                completion(false)
            } else {
                completion(true)
            }
        }
    }

    func connectFromStatusMenu() {
        guard connectionManager.state == .disconnected else { return }
        connect()
    }

    func disconnectFromStatusMenu() {
        guard case .connected = connectionManager.state else { return }
        connectionManager.disconnect { [weak self] error in
            if let error = error {
                self?.showError(error)
            }
        }
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.distribution = .fill
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        let titleLabel = NSTextField(labelWithString: "VPN для macOS Mojave")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 22)
        let subtitleLabel = wrappingLabel("VLESS + REALITY · AmneziaWG · профили в Связке ключей")
        subtitleLabel.textColor = .secondaryLabelColor

        let profilesTitle = sectionLabel("Профили подключения")
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged)
        profilePopup.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = "Название профиля"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        editButton.target = self
        editButton.action = #selector(editProfile)
        let selectionRow = NSStackView(views: [profilePopup, deleteButton])
        selectionRow.orientation = .horizontal
        selectionRow.spacing = 8
        selectionRow.translatesAutoresizingMaskIntoConstraints = false
        importAWGButton.target = self
        importAWGButton.action = #selector(importAmneziaWG)
        let nameRow = NSStackView(views: [nameField, editButton, importAWGButton])
        nameRow.orientation = .horizontal
        nameRow.spacing = 8
        nameRow.translatesAutoresizingMaskIntoConstraints = false
        let profileTitle = sectionLabel("VLESS-ссылка (для добавления или замены ключа)")
        profileField.placeholderString = "Вставьте vless://…"
        profileField.translatesAutoresizingMaskIntoConstraints = false
        profileField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        saveButton.target = self
        saveButton.action = #selector(saveProfile)
        deleteButton.target = self
        deleteButton.action = #selector(deleteProfile)

        let profileRow = NSStackView(views: [profileField, saveButton])
        profileRow.orientation = .horizontal
        profileRow.alignment = .centerY
        profileRow.spacing = 8
        profileRow.translatesAutoresizingMaskIntoConstraints = false

        profileStatusLabel.textColor = .secondaryLabelColor
        profileStatusLabel.font = NSFont.systemFont(ofSize: 11)

        let modeTitle = sectionLabel("Режим соединения")
        modePopup.addItems(withTitles: [ConnectionMode.tunnel.title, ConnectionMode.systemProxy.title, ConnectionMode.localProxy.title])
        let savedMode = ConnectionMode(rawValue: UserDefaults.standard.integer(forKey: "connectionMode")) ?? .tunnel
        modePopup.selectItem(at: savedMode.rawValue)
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        proxyHint.font = NSFont.systemFont(ofSize: 11)
        proxyHint.textColor = .secondaryLabelColor
        proxyHint.isSelectable = true
        modeChanged()

        statusDot.textColor = .systemGray
        statusDot.font = NSFont.systemFont(ofSize: 18)
        statusLabel.font = NSFont.boldSystemFont(ofSize: 13)
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progressIndicator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        progressIndicator.usesThreadedAnimation = false
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        let statusRow = NSStackView(views: [statusDot, statusLabel, progressIndicator])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 7

        connectButton.target = self
        connectButton.action = #selector(toggleConnection)
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"

        let quitButton = NSButton(title: "Выйти", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quitButton.bezelStyle = .rounded
        let actionRow = NSStackView(views: [connectButton, ipLabel, quitButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 18

        let logTitle = sectionLabel("Журнал")
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.font = NSFont(name: "Menlo", size: 11) ?? NSFont.systemFont(ofSize: 11)
        logTextView.textColor = .textColor
        logTextView.backgroundColor = .textBackgroundColor
        logTextView.drawsBackground = true
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        logTextView.autoresizingMask = [.width]
        logTextView.minSize = NSSize(width: 0, height: 0)
        logTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logTextView.textContainer?.containerSize = NSSize(width: 650, height: CGFloat.greatestFiniteMagnitude)
        logTextView.textContainer?.widthTracksTextView = true
        logTextView.string = ""
        logTextView.textContainerInset = NSSize(width: 7, height: 7)
        let logScrollView = NSScrollView()
        logScrollView.hasVerticalScroller = true
        logScrollView.borderType = .bezelBorder
        logScrollView.documentView = logTextView
        logScrollView.translatesAutoresizingMaskIntoConstraints = false

        let note = wrappingLabel("Пароль администратора нужен только при установке или обновлении системного помощника. Обычное подключение и отключение — без пароля. Удалить помощник можно через меню MojaveRay.")
        note.textColor = .secondaryLabelColor
        note.font = NSFont.systemFont(ofSize: 11)

        [titleLabel, subtitleLabel, profilesTitle, selectionRow, nameRow, profileTitle, profileRow, profileStatusLabel, modeTitle,
         modePopup, proxyHint, statusRow, actionRow, logTitle, logScrollView, note].forEach {
            rootStack.addArrangedSubview($0)
        }

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),

            selectionRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            nameRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            profilePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            profileRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            profileField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            modePopup.widthAnchor.constraint(equalToConstant: 310),
            proxyHint.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            connectButton.widthAnchor.constraint(equalToConstant: 160),
            logScrollView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            logScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            note.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])
    }

    private func bindManager() {
        connectionManager.onStateChange = { [weak self] state in
            self?.updateForState(state)
            self?.onConnectionStateChange?(state)
        }
        connectionManager.onLog = { [weak self] message in
            self?.appendLog(message)
        }
        connectionManager.onConnectionLost = { [weak self] error in
            self?.showError(error)
        }
    }

    @objc private func modeChanged() {
        let mode = ConnectionMode(rawValue: modePopup.indexOfSelectedItem) ?? .tunnel
        UserDefaults.standard.set(mode.rawValue, forKey: "connectionMode")
        proxyHint.isHidden = mode != .localProxy
        proxyHint.stringValue = "В расширении Chrome или Telegram включите SOCKS5: сервер 127.0.0.1, порт 10808, логин и пароль пустые. Через VPN работают только программы, в которых указан этот прокси. После отключения MojaveRay выключите прокси в Telegram для прямого доступа."
    }

    private var selectedProfile: SavedVLESSProfile? {
        return savedProfiles.profiles.first { $0.id == savedProfiles.selectedID }
    }

    private func refreshProfileList() {
        profilePopup.removeAllItems()
        profilePopup.addItem(withTitle: "＋ Новый профиль")
        profilePopup.addItems(withTitles: savedProfiles.profiles.enumerated().map { "\($0.offset + 1). \($0.element.name)" })
        if let index = savedProfiles.profiles.firstIndex(where: { $0.id == savedProfiles.selectedID }) {
            profilePopup.selectItem(at: index + 1)
        } else {
            profilePopup.selectItem(at: 0)
        }
        nameField.stringValue = selectedProfile?.name ?? ""
        profileField.stringValue = ""
        refreshSavedProfileStatus()
        updateForState(connectionManager.state)
    }

    @objc private func profileChanged() {
        guard connectionManager.state == .disconnected, profilesLoaded else { return }
        var updated = savedProfiles
        let index = profilePopup.indexOfSelectedItem - 1
        updated.selectedID = updated.profiles.indices.contains(index) ? updated.profiles[index].id : nil
        do {
            try keychain.saveProfiles(updated)
            savedProfiles = updated
        } catch {
            showError(error)
        }
        refreshProfileList()
    }


    @objc private func importAmneziaWG() {
        guard profilesLoaded, connectionManager.state == .disconnected else { return }
        let panel = NSOpenPanel()
        panel.title = "Открыть конфигурацию AmneziaWG"
        panel.allowedFileTypes = ["conf", "ovpn"]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let input = try FileHandle(forReadingFrom: url)
            defer { input.closeFile() }
            let data = input.readData(ofLength: 65_537)
            guard data.count <= 65_536, let config = String(data: data, encoding: .utf8) else {
                throw AppError.invalidAmneziaWGProfile("нужен текстовый файл размером до 64 КБ")
            }
            try AmneziaWG.validate(config)
            var updated = savedProfiles
            let profile = SavedVLESSProfile(id: UUID().uuidString,
                name: url.deletingPathExtension().lastPathComponent, link: config)
            updated.profiles.append(profile)
            updated.selectedID = profile.id
            try keychain.saveProfiles(updated)
            savedProfiles = updated
            refreshProfileList()
            appendLog("Профиль AmneziaWG сохранён в Связке ключей")
        } catch {
            showError(error)
        }
    }

    @objc private func editProfile() {
        guard connectionManager.state == .disconnected else { return }
        if let saved = selectedProfile, AmneziaWG.isProfile(saved.link) {
            window?.makeFirstResponder(nameField)
            return
        }
        profileField.stringValue = selectedProfile?.link ?? ""
        window?.makeFirstResponder(profileField)
    }

    private func persistEditedProfile() throws {
        guard profilesLoaded else { throw AppError.missingProfile }
        let raw = profileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = raw.isEmpty ? (selectedProfile?.link ?? "") : raw
        let awg = AmneziaWG.isProfile(link)
        let parsed: VLESSProfile? = awg ? nil : (try VLESSParser.parse(link))
        if awg { try AmneziaWG.validate(link) }
        let displayName = parsed?.displayName ?? "AmneziaWG"
        let enteredName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = enteredName.isEmpty ? (displayName.isEmpty ? "Сервер \(savedProfiles.profiles.count + 1)" : displayName) : enteredName
        var updated = savedProfiles
        if let index = updated.profiles.firstIndex(where: { $0.id == updated.selectedID }) {
            updated.profiles[index].name = name
            updated.profiles[index].link = link
        } else {
            let profile = SavedVLESSProfile(id: UUID().uuidString, name: name, link: link)
            updated.profiles.append(profile)
            updated.selectedID = profile.id
        }
        try keychain.saveProfiles(updated)
        savedProfiles = updated
        refreshProfileList()
    }

    @objc private func saveProfile() {
        guard connectionManager.state == .disconnected else { return }
        do {
            try persistEditedProfile()
            appendLog("Профиль проверен и сохранён в Связке ключей")
        } catch {
            showError(error)
        }
    }

    @objc private func deleteProfile() {
        guard connectionManager.state == .disconnected, let selected = selectedProfile else { return }
        let alert = NSAlert()
        alert.messageText = "Удалить профиль «\(selected.name)»?"
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            var updated = savedProfiles
            updated.profiles.removeAll { $0.id == selected.id }
            updated.selectedID = updated.profiles.first?.id
            try keychain.saveProfiles(updated)
            savedProfiles = updated
            refreshProfileList()
            appendLog("Сохранённый профиль удалён")
        } catch {
            showError(error)
        }
    }

    @objc private func toggleConnection() {
        switch connectionManager.state {
        case .disconnected:
            connect()
        case .connected:
            connectionManager.disconnect { [weak self] error in
                if let error = error {
                    self?.showError(error)
                }
            }
        case .connecting, .disconnecting:
            break
        }
    }

    private func connect() {
        do {
            if !profileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try persistEditedProfile()
            }
            guard let selected = selectedProfile else { throw AppError.missingProfile }
            let link = selected.link

            let mode = ConnectionMode(rawValue: modePopup.indexOfSelectedItem) ?? .tunnel
            connectionManager.connect(link: link, mode: mode) { [weak self] error in
                if let error = error {
                    self?.showError(error)
                } else {
                    if mode == .localProxy {
                        self?.ipLabel.stringValue = "SOCKS5: 127.0.0.1:10808"
                    } else {
                        self?.refreshExternalIP()
                    }
                }
            }
        } catch {
            showError(error)
        }
    }

    private func updateForState(_ state: ConnectionState) {
        let busy = state.isBusy
        let canEdit = profilesLoaded && state == .disconnected
        profilePopup.isEnabled = canEdit
        nameField.isEnabled = canEdit
        importAWGButton.isEnabled = canEdit
        editButton.isEnabled = canEdit && selectedProfile != nil
        profileField.isEnabled = canEdit
        saveButton.isEnabled = canEdit
        deleteButton.isEnabled = canEdit && selectedProfile != nil
        modePopup.isEnabled = !busy && state == .disconnected
        connectButton.isEnabled = !busy

        if busy {
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(self)
        } else {
            progressIndicator.stopAnimation(self)
            progressIndicator.isHidden = true
        }

        switch state {
        case .disconnected:
            statusDot.textColor = .systemGray
            statusLabel.stringValue = "Не подключено"
            connectButton.title = "Подключить"
            ipLabel.stringValue = "Внешний IP: —"
        case .connecting:
            statusDot.textColor = .systemOrange
            statusLabel.stringValue = "Подключение…"
            connectButton.title = "Подключение…"
        case .connected(let mode):
            statusDot.textColor = .systemGreen
            statusLabel.stringValue = mode.connectedTitle
            connectButton.title = "Отключить"
        case .disconnecting:
            statusDot.textColor = .systemOrange
            statusLabel.stringValue = "Отключение…"
            connectButton.title = "Отключение…"
        }
    }

    private func refreshSavedProfileStatus() {
        if let saved = selectedProfile, AmneziaWG.isProfile(saved.link) {
            profileStatusLabel.stringValue = "Выбран: \(saved.name) · AmneziaWG"
            profileStatusLabel.textColor = .systemGreen
        } else if let saved = selectedProfile, let parsed = try? VLESSParser.parse(saved.link) {
            profileStatusLabel.stringValue = "Выбран: \(saved.name) · \(parsed.summary)"
            profileStatusLabel.textColor = .systemGreen
        } else {
            profileStatusLabel.stringValue = "Вставьте VLESS-ссылку или импортируйте профиль AmneziaWG"
            profileStatusLabel.textColor = .secondaryLabelColor
        }
    }

    private func refreshExternalIP() {
        guard let url = URL(string: "https://api.ipify.org?format=json") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let rawObject = try? JSONSerialization.jsonObject(with: data),
                  let object = rawObject as? [String: Any],
                  let ip = object["ip"] as? String else { return }
            DispatchQueue.main.async {
                self?.ipLabel.stringValue = "Внешний IP: \(ip)"
            }
        }.resume()
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.textColor,
            .font: NSFont(name: "Menlo", size: 11) ?? NSFont.systemFont(ofSize: 11)
        ]
        guard let storage = logTextView.textStorage else { return }
        storage.append(NSAttributedString(string: line, attributes: attributes))
        // Keep the journal bounded: an unstable network can log for days.
        let maxCharacters = 200_000
        if storage.length > maxCharacters {
            let text = storage.string as NSString
            let cut = text.range(of: "\n", options: [], range: NSRange(location: storage.length - maxCharacters, length: maxCharacters / 2))
            let end = cut.location == NSNotFound ? storage.length - maxCharacters : cut.location + 1
            storage.deleteCharacters(in: NSRange(location: 0, length: end))
        }
        logTextView.scrollToEndOfDocument(self)
    }

    private func showError(_ error: Error) {
        if window?.isVisible != true {
            NSApp.setActivationPolicy(.regular)
            (NSApp.delegate as? AppDelegate)?.restoreApplicationIcon()
            showWindow(self)
            window?.makeKeyAndOrderFront(self)
            NSApp.activate(ignoringOtherApps: true)
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "MojaveRay"
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            alert.informativeText = description
        } else {
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: "OK")
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.boldSystemFont(ofSize: 12)
        return label
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        return label
    }
}
