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

    private let queue = DispatchQueue(label: "com.denisbekker.MojaveRay.connection")
    private let processes = ManagedProcesses()
    private let network = PrivilegedNetworkController()
    private(set) var state: ConnectionState = .disconnected
    private var networkWasConfigured = false
    private let socksPort = 10_808

    init() {
        processes.onLog = { [weak self] message in
            self?.log(message)
        }
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
            self.networkWasConfigured = false

            do {
                let awg = AmneziaWG.isProfile(link)
                let profile: VLESSProfile? = awg ? nil : (try VLESSParser.parse(link))
                if mode != .localProxy {
                    self.log("Проверяю системный помощник; при первой установке потребуется пароль")
                    try self.network.prepare()
                }
                if self.network.hasStaleState {
                    try self.network.stop()
                }

                if let profile = profile {
                    let configData = try XrayConfigBuilder.data(for: profile, socksPort: self.socksPort)
                    try ApplicationPaths.writeConfig(configData)
                    try self.processes.startXray(profile: profile)
                } else {
                    try self.processes.startAmneziaWG(link)
                }
                guard awg || self.waitForLocalPort(self.socksPort, timeout: 8.0) else {
                    throw AppError.coreFailed("локальный порт SOCKS не открылся за 8 секунд")
                }

                switch mode {
                case .tunnel:
                    guard let serverIPv4 = profile?.ipv4Host ?? AmneziaWG.endpointIPv4(link) else {
                        throw AppError.tunnelFailed("для полного режима адрес сервера должен быть IPv4; используйте запасной режим прокси")
                    }
                    try self.network.startTunnel(serverIPv4: serverIPv4)
                    self.log("Системный помощник настроил TUN без повторного запроса пароля")
                case .systemProxy:
                    try self.network.startSystemProxy()
                case .localProxy:
                    self.log("SOCKS5: 127.0.0.1:10808. Укажите эти параметры в расширении Chrome или в Telegram; логин и пароль пустые. Системные маршруты, DNS и прокси не меняются.")
                }
                self.networkWasConfigured = mode != .localProxy
                self.transition(to: .connected(mode))
                self.log(awg ? "Режим: \(mode.title). Доступ через AmneziaWG проверьте открытием сайта." : "Соединение установлено: \(mode.title)")
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
            self.transition(to: .disconnecting)
            do {
                if self.networkWasConfigured || self.network.hasStaleState {
                    try self.network.stop()
                }
                self.networkWasConfigured = false
                self.processes.stopAll()
                ApplicationPaths.removeTransientConfig()
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
