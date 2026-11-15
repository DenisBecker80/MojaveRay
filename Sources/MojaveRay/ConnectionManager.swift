import Foundation
import MojaveRayCore

enum ConnectionMode: Int, Equatable {
    case tunnel = 0
    case systemProxy = 1
    case localProxy = 2

    var title: String {
        switch self {
        case .tunnel: return "Полный VPN — весь трафик"
        case .systemProxy: return "Системный прокси — запасной режим"
        case .localProxy: return "Локальный прокси — Chrome / Telegram"
        }
    }

    var connectedTitle: String {
        switch self {
        case .tunnel: return "VPN подключён"
        case .systemProxy: return "Системный прокси подключён"
        case .localProxy: return "Локальный прокси запущен"
        }
    }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(ConnectionMode)
    case disconnecting

    var isBusy: Bool {
        return self == .connecting || self == .disconnecting
    }
}

final class ConnectionManager {
    var onStateChange: ((ConnectionState) -> Void)?
    var onLog: ((String) -> Void)?
    /// The connection was dropped without a user action (repeated core
    /// crashes, or reconnecting after a network change failed).
    var onConnectionLost: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "com.denisbekker.MojaveRay.connection")
    private let processes = ManagedProcesses()
    private let network = PrivilegedNetworkController()
    private let monitor = NetworkChangeMonitor()
    private(set) var state: ConnectionState = .disconnected
    private var networkWasConfigured = false
    private let socksPort = 10_808

    // Session state, touched only on `queue`.
    private var activeLink: String?
    private var connectedNetwork: NetworkIdentity?
    /// Bumped on every connect/disconnect so delayed work from an older
    /// session never acts on a newer one.
    private var session = 0
    private var coreRestarts: [Date] = []
    private var coreRestartScheduled = false
    private var networkEventToken = 0
    private var pendingWake = false

    private let maxCoreRestarts = 5
    private let coreRestartWindow: TimeInterval = 300
    private let networkSettleDelay: TimeInterval = 3
    private let maxReconnectAttempts = 6
    private let reconnectRetryDelay: TimeInterval = 5

    init() {
        processes.onLog = { [weak self] message in
            self?.log(message)
        }
        processes.onUnexpectedExit = { [weak self] _ in
            self?.queue.async { self?.coreExitedUnexpectedly() }
        }
        monitor.onChange = { [weak self] in
            self?.queue.async { self?.scheduleNetworkCheck(wake: false) }
        }
        monitor.onWake = { [weak self] in
            self?.queue.async { self?.scheduleNetworkCheck(wake: true) }
        }
        monitor.start()
    }

    func recoverIfNeeded(completion: @escaping (Error?) -> Void) {
        queue.async {
            self.processes.recoverOrphans()
            guard self.network.hasStaleState else {
                ApplicationPaths.removeTransientConfig()
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.log("Обнаружены настройки от прерванного сеанса; восстанавливаю сеть")
            do {
                try self.network.stop()
                ApplicationPaths.removeTransientConfig()
                self.log("Обычные сетевые настройки восстановлены")
                DispatchQueue.main.async { completion(nil) }
            } catch {
                ApplicationPaths.removeTransientConfig()
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func connect(link: String, mode: ConnectionMode, completion: @escaping (Error?) -> Void) {
        queue.async {
            guard self.state == .disconnected else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.transition(to: .connecting)
            do {
                try self.establish(link: link, mode: mode)
                self.session += 1
                self.activeLink = link
                self.connectedNetwork = NetworkChangeMonitor.current()
                self.coreRestarts = []
                self.coreRestartScheduled = false
                self.transition(to: .connected(mode))
                self.log(AmneziaWG.isProfile(link)
                    ? "Режим: \(mode.title). Доступ через AmneziaWG проверьте открытием сайта."
                    : "Соединение установлено: \(mode.title)")
                DispatchQueue.main.async { completion(nil) }
            } catch {
                self.cleanupAfterFailedConnect()
                self.transition(to: .disconnected)
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func disconnect(completion: @escaping (Error?) -> Void) {
        queue.async {
            guard self.state != .disconnected else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let previousMode: ConnectionMode?
            if case .connected(let mode) = self.state {
                previousMode = mode
            } else {
                previousMode = nil
            }
            // Cancel pending restarts and reconnects before tearing down.
            self.session += 1
            self.transition(to: .disconnecting)
            do {
                if self.networkWasConfigured || self.network.hasStaleState {
                    try self.network.stop()
                }
                self.networkWasConfigured = false
                self.processes.stopAll()
                ApplicationPaths.removeTransientConfig()
                self.clearSession()
                self.transition(to: .disconnected)
                self.log("VPN отключён, исходные настройки сети восстановлены")
                DispatchQueue.main.async { completion(nil) }
            } catch {
                if let mode = previousMode {
                    self.transition(to: .connected(mode))
                } else {
                    self.transition(to: .disconnected)
                }
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func forceStopProcesses() {
        monitor.stop()
        processes.stopAll()
        ApplicationPaths.removeTransientConfig()
    }

    func manageSystemHelper(_ action: String, completion: @escaping (Error?) -> Void) {
        queue.async {
            guard self.state == .disconnected else {
                DispatchQueue.main.async { completion(AppError.tunnelFailed("сначала отключите VPN")) }
                return
            }
            self.transition(to: .disconnecting)
            do {
                try self.network.manageInstallation(action)
                self.transition(to: .disconnected)
                self.log(action == "install" ? "Системный помощник установлен" : "Системный помощник удалён")
                DispatchQueue.main.async { completion(nil) }
            } catch {
                self.transition(to: .disconnected)
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    // MARK: - Establishing

    /// Starts the core and configures the system for `mode`. On error the
    /// caller must run cleanupAfterFailedConnect().
    private func establish(link: String, mode: ConnectionMode) throws {
        networkWasConfigured = false
        if mode != .localProxy {
            log("Проверяю системный помощник; при первой установке потребуется пароль")
            try network.prepare()
        }
        if network.hasStaleState {
            try network.stop()
        }
        let profile = try startCore(link: link)
        switch mode {
        case .tunnel:
            guard let serverIPv4 = profile?.ipv4Host ?? AmneziaWG.endpointIPv4(link) else {
                throw AppError.tunnelFailed("для полного режима адрес сервера должен быть IPv4; используйте запасной режим прокси")
            }
            try network.startTunnel(serverIPv4: serverIPv4)
            log("Системный помощник настроил TUN без повторного запроса пароля")
        case .systemProxy:
            try network.startSystemProxy()
        case .localProxy:
            log("SOCKS5: 127.0.0.1:10808. Укажите эти параметры в расширении Chrome или в Telegram; логин и пароль пустые. Системные маршруты, DNS и прокси не меняются.")
        }
        networkWasConfigured = mode != .localProxy
    }

    /// Starts Xray or AmneziaWG and waits for the local SOCKS port.
    /// Returns the VLESS profile, or nil for AmneziaWG.
    @discardableResult
    private func startCore(link: String) throws -> VLESSProfile? {
        if AmneziaWG.isProfile(link) {
            try processes.startAmneziaWG(link)
            guard processes.isCoreRunning else {
                throw AppError.coreFailed("AmneziaWG завершился сразу после запуска")
            }
            return nil
        }
        let profile = try VLESSParser.parse(link)
        let configData = try XrayConfigBuilder.data(for: profile, socksPort: socksPort)
        try ApplicationPaths.writeConfig(configData)
        try processes.startXray(profile: profile)
        guard waitForLocalPort(socksPort, timeout: 8.0) else {
            throw AppError.coreFailed("локальный порт SOCKS не открылся за 8 секунд")
        }
        return profile
    }

    // MARK: - Core crash recovery

    /// The core died while connected. Routes and the system proxy keep
    /// pointing at 127.0.0.1:10808, so restarting the core on the same port is
    /// enough: tun2socks opens a new SOCKS connection for every flow.
    private func coreExitedUnexpectedly() {
        guard case .connected = state, let link = activeLink, !coreRestartScheduled else { return }
        let now = Date()
        coreRestarts = coreRestarts.filter { now.timeIntervalSince($0) < coreRestartWindow }
        guard coreRestarts.count < maxCoreRestarts else {
            loseConnection(AppError.coreFailed("ядро аварийно завершалось \(maxCoreRestarts) раз за 5 минут; соединение разорвано, сеть восстановлена"))
            return
        }
        coreRestarts.append(now)
        let delay = pow(2.0, Double(coreRestarts.count - 1))
        log("Перезапускаю ядро через \(Int(delay)) с (попытка \(coreRestarts.count) из \(maxCoreRestarts))")
        coreRestartScheduled = true
        let expectedSession = session
        queue.asyncAfter(deadline: .now() + delay) {
            guard self.session == expectedSession, case .connected = self.state else { return }
            self.coreRestartScheduled = false
            do {
                self.processes.stopAll()
                try self.startCore(link: link)
                self.log("Ядро перезапущено, соединение восстановлено")
            } catch {
                self.log("Не удалось перезапустить ядро: \(error.localizedDescription)")
                self.coreExitedUnexpectedly()
            }
        }
    }

    // MARK: - Network changes and wake

    private func scheduleNetworkCheck(wake: Bool) {
        guard case .connected = state else { return }
        pendingWake = pendingWake || wake
        networkEventToken += 1
        let token = networkEventToken
        let expectedSession = session
        // Let DHCP and Wi-Fi settle and coalesce bursts of events.
        queue.asyncAfter(deadline: .now() + networkSettleDelay) {
            guard token == self.networkEventToken, self.session == expectedSession else { return }
            let wake = self.pendingWake
            self.pendingWake = false
            self.handleNetworkCheck(wake: wake)
        }
    }

    private func handleNetworkCheck(wake: Bool) {
        guard case .connected(let mode) = state, let link = activeLink else { return }
        guard let current = NetworkChangeMonitor.current() else {
            log("Сеть недоступна; переподключусь, когда она появится")
            return
        }
        let changed = current != connectedNetwork
        guard changed || wake else { return }

        if mode == .localProxy || !changed {
            // Routes are still valid; only the core's sockets are stale.
            log(wake ? "Пробуждение после сна: перезапускаю ядро" : "Сеть изменилась: перезапускаю ядро")
            connectedNetwork = current
            do {
                processes.stopAll()
                try startCore(link: link)
                log("Ядро перезапущено")
            } catch {
                log("Не удалось перезапустить ядро: \(error.localizedDescription)")
                coreExitedUnexpectedly()
            }
            return
        }
        let previous = connectedNetwork.map { $0.description } ?? "нет"
        log("Сеть изменилась (\(previous) → \(current)); переподключаюсь, маршруты будут созданы заново")
        reestablish(link: link, mode: mode, attempt: 1)
    }

    /// Full teardown and setup. The host route to the server and the bound
    /// interface belong to the old network, so they must be rebuilt.
    /// Between teardown and setup traffic briefly goes directly.
    private func reestablish(link: String, mode: ConnectionMode, attempt: Int) {
        transition(to: .connecting)
        do {
            if networkWasConfigured || network.hasStaleState {
                try network.stop()
            }
            networkWasConfigured = false
            processes.stopAll()
            try establish(link: link, mode: mode)
            connectedNetwork = NetworkChangeMonitor.current()
            coreRestarts = []
            transition(to: .connected(mode))
            log("Переподключено: \(mode.title)")
        } catch {
            cleanupAfterFailedConnect()
            guard attempt < maxReconnectAttempts else {
                loseConnection(error)
                return
            }
            log("Переподключение не удалось (\(error.localizedDescription)); повтор через \(Int(reconnectRetryDelay)) с")
            let expectedSession = session
            queue.asyncAfter(deadline: .now() + reconnectRetryDelay) {
                guard self.session == expectedSession, self.state == .connecting else { return }
                self.reestablish(link: link, mode: mode, attempt: attempt + 1)
            }
        }
    }

    private func loseConnection(_ error: Error) {
        session += 1
        cleanupAfterFailedConnect()
        clearSession()
        transition(to: .disconnected)
        log("Соединение разорвано: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionLost?(error)
        }
    }

    private func clearSession() {
        activeLink = nil
        connectedNetwork = nil
        coreRestarts = []
        coreRestartScheduled = false
        pendingWake = false
    }

    // MARK: - Helpers

    private func cleanupAfterFailedConnect() {
        if networkWasConfigured || network.hasStaleState {
            try? network.stop()
        }
        networkWasConfigured = false
        processes.stopAll()
        ApplicationPaths.removeTransientConfig()
    }

    private func waitForLocalPort(_ port: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !processes.isCoreRunning {
                return false
            }
            if let result = try? ProcessRunner.run("/usr/bin/nc", arguments: ["-z", "-w", "1", "127.0.0.1", String(port)]),
               result.status == 0 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    private func transition(to newState: ConnectionState) {
        state = newState
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(newState)
        }
    }

    private func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onLog?(message)
        }
    }
}
