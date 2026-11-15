import AppKit
import Foundation
import Darwin
import MojaveRayCore

final class PrivilegedNetworkController {
    private let targetUID = String(getuid())

    var hasStaleState: Bool {
        guard let result = try? request(["status"]) else { return false }
        return result.status == 0 && result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "OK 1 active"
    }

    func prepare() throws {
        if let result = try? request(["status"]), result.status == 0,
            result.standardOutput.hasPrefix("OK 1 ") { return }
        try manageInstallation("install")
        let status = try request(["status"])
        guard status.status == 0 && status.standardOutput.hasPrefix("OK 1 ") else {
            throw AppError.tunnelFailed("системный помощник не ответил после установки")
        }
    }

    func startTunnel(serverIPv4: String) throws {
        try perform(["start-full", String(getpid()), serverIPv4])
    }

    func startSystemProxy() throws {
        try perform(["start-proxy", String(getpid())])
    }

    func stop() throws {
        // Never open a password dialog for a normal disconnect.
        try perform(["stop"])
    }

    private func request(_ arguments: [String]) throws -> CommandResult {
        guard let client = ApplicationPaths.bundledResource("bin/control"),
            FileManager.default.isExecutableFile(atPath: client.path) else {
            throw AppError.missingCore("клиент системного помощника")
        }
        return try ProcessRunner.run(client.path, arguments: ["client", targetUID] + arguments)
    }

    private func perform(_ arguments: [String]) throws {
        let result = try request(arguments)
        guard result.status == 0 else {
            let detail = (result.standardOutput + result.standardError)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.tunnelFailed(detail.isEmpty ? "нет ответа от системного помощника" : detail)
        }
    }

    func manageInstallation(_ action: String) throws {
        guard action == "install" || action == "uninstall",
            let installer = ApplicationPaths.bundledResource("mojaveray-service-install.sh"),
            FileManager.default.fileExists(atPath: installer.path) else {
            throw AppError.missingCore("установщик системного помощника")
        }
        // Only installation/removal escalates privileges. No stored password.
        let command = ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                       "LC_ALL=C", "/bin/bash", installer.path, action, targetUID]
            .map(posixQuote).joined(separator: " ")
        var executionError: Error?
        let execute = {
            let source = "do shell script \(self.appleScriptLiteral(command)) with administrator privileges"
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                executionError = AppError.tunnelFailed("не удалось открыть установщик")
                return
            }
            _ = script.executeAndReturnError(&errorInfo)
            if let info = errorInfo {
                let number = info[NSAppleScript.errorNumber] as? Int ?? 0
                let message = number == -128 ? "установка или удаление помощника отменены" :
                    (info[NSAppleScript.errorMessage] as? String ?? "ошибка установки помощника")
                executionError = AppError.tunnelFailed(message)
            }
        }
        if Thread.isMainThread { execute() }
        else { DispatchQueue.main.sync(execute: execute) }
        if let error = executionError { throw error }
    }

    private func posixQuote(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
