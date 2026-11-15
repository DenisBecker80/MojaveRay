import Foundation
import Darwin
import MojaveRayCore

final class ManagedProcesses {
    var onLog: ((String) -> Void)?

    private var coreProcess: Process?
    private var redactionTokens: [String] = []
    private let lock = NSLock()

    var isCoreRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return coreProcess?.isRunning == true
    }

    func tun2SocksURL() throws -> URL {
        guard let tunURL = ApplicationPaths.bundledResource("bin/tun2socks"),
              FileManager.default.isExecutableFile(atPath: tunURL.path) else {
            throw AppError.missingCore("tun2socks 2.5.0")
        }
        return tunURL
    }

    func startXray(profile: VLESSProfile) throws {
        guard let xrayURL = ApplicationPaths.bundledResource("bin/xray"),
              FileManager.default.isExecutableFile(atPath: xrayURL.path) else {
            throw AppError.missingCore("Xray 1.8.1")
        }

        lock.lock()
        let alreadyRunning = coreProcess?.isRunning == true
        lock.unlock()
        guard !alreadyRunning else { return }

        redactionTokens = profile.redactionTokens
        let process = Process()
        process.launchPath = xrayURL.path
        process.arguments = ["run", "-config", ApplicationPaths.configFile.path]
        process.currentDirectoryURL = xrayURL.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["XRAY_LOCATION_ASSET"] = xrayURL.deletingLastPathComponent().path
        process.environment = environment

        attachLogPipes(to: process, prefix: "Xray")
        process.terminationHandler = { [weak self] terminated in
            self?.emit("Xray завершён, код \(terminated.terminationStatus)")
        }

        do {
            try process.run()
        } catch {
            throw AppError.coreFailed(error.localizedDescription)
        }
        lock.lock()
        coreProcess = process
        lock.unlock()
        writePID(process.processIdentifier, name: "xray.pid")
        emit("Xray запущен")
    }


    func startAmneziaWG(_ profile: String) throws {
        let url = try AmneziaWG.binary()
        let input = try AmneziaWG.configInput(profile)
        defer { input.closeFile() }
        let process = Process()
        process.executableURL = url
        process.standardInput = input
        redactionTokens = []
        let ready = DispatchSemaphore(value: 0)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        var marker = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            marker.append(data)
            if String(data: marker, encoding: .utf8) == "AWG_SOCKS_READY\n" {
                ready.signal()
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else if let text = String(data: data, encoding: .utf8) {
                self?.emit("AmneziaWG: \(text)")
            }
        }
        try process.run()
        guard ready.wait(timeout: .now() + 8) == .success, process.isRunning else {
            stop(process)
            throw AppError.coreFailed("AmneziaWG не открыл локальный SOCKS5; см. журнал")
        }
        emit("AmneziaWG: локальный SOCKS5 готов")
        lock.lock()
        coreProcess = process
        lock.unlock()
        writePID(process.processIdentifier, name: "awg.pid")
    }

    func stopAll() {
        lock.lock()
        let xray = coreProcess
        coreProcess = nil
        lock.unlock()

        stop(xray)
        removePID(name: "xray.pid")
        removePID(name: "awg.pid")
        emit("Сетевые процессы остановлены")
    }

    func recoverOrphans() {
        recoverPID(name: "xray.pid", expectedCommand: "MojaveRay.app/Contents/Resources/bin/xray")
        recoverPID(name: "awg.pid", expectedCommand: "MojaveRay.app/Contents/Resources/bin/awg-bridge")
    }

    private func attachLogPipes(to process: Process, prefix: String) {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.emit("\(prefix): \(text)")
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.emit("\(prefix): \(text)")
        }
    }

    private func stop(_ process: Process?) {
        guard let process = process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            Darwin.kill(pid_t(process.processIdentifier), SIGKILL)
        }
    }

    private func emit(_ rawMessage: String) {
        var message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in redactionTokens where !token.isEmpty {
            message = message.replacingOccurrences(of: token, with: "[скрыто]")
        }
        guard !message.isEmpty else { return }
        onLog?(message)
    }

    private func writePID(_ pid: Int32, name: String) {
        try? ApplicationPaths.prepare()
        let url = ApplicationPaths.runtimeDirectory.appendingPathComponent(name)
        try? String(pid).write(to: url, atomically: true, encoding: .utf8)
        _ = chmod(url.path, 0o600)
    }

    private func removePID(name: String) {
        let url = ApplicationPaths.runtimeDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }

    private func recoverPID(name: String, expectedCommand: String) {
        let url = ApplicationPaths.runtimeDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let value = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1,
              let result = try? ProcessRunner.run("/bin/ps", arguments: ["-p", String(pid), "-o", "command="]),
              result.status == 0,
              result.standardOutput.contains(expectedCommand) else {
            return
        }
        Darwin.kill(pid, SIGTERM)
    }
}


enum AmneziaWG {
    static func isProfile(_ value: String) -> Bool {
        return value.components(separatedBy: .newlines).contains {
            $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
                .lowercased() == "[interface]"
        }
    }

    static func binary() throws -> URL {
        #if arch(x86_64)
        let needsCompatibilityBridge = !ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 0))
        let name = needsCompatibilityBridge ? "awg-bridge-mojave" : "awg-bridge"
        #else
        let name = "awg-bridge"
        #endif
        guard let url = ApplicationPaths.bundledResource("bin/" + name),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw AppError.missingCore("AmneziaWG")
        }
        return url
    }

    static func configInput(_ value: String) throws -> FileHandle {
        guard value.utf8.count <= 65_536 else {
            throw AppError.invalidAmneziaWGProfile("файл больше 64 КБ")
        }
        try ApplicationPaths.prepare()
        let path = ApplicationPaths.runtimeDirectory.appendingPathComponent("awg.XXXXXX").path
        var pattern = Array(path.utf8CString)
        let fd = pattern.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let ptr = buffer.baseAddress else { return -1 }
            let fd = mkstemp(ptr)
            if fd >= 0 && unlink(ptr) != 0 {
                _ = Darwin.close(fd)
                return -1
            }
            return fd
        }
        guard fd >= 0 else { throw AppError.fileSystem("не удалось открыть временный дескриптор AmneziaWG") }
        let data = Data(value.utf8)
        let written = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard let address = buffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(fd, address.advanced(by: offset), buffer.count - offset)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { return false }
                offset += result
            }
            return true
        }
        guard written, lseek(fd, 0, SEEK_SET) == 0 else {
            _ = Darwin.close(fd)
            throw AppError.fileSystem("не удалось подготовить данные AmneziaWG")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func validate(_ value: String) throws {
        guard isProfile(value) else {
            throw AppError.invalidAmneziaWGProfile("ожидается конфигурация с секциями [Interface] и [Peer]. Файлы OpenVPN не поддерживаются.")
        }
        let process = Process()
        process.executableURL = try binary()
        process.arguments = ["-validate"]
        let input = try configInput(value)
        defer { input.closeFile() }
        process.standardInput = input
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // The bridge emits fixed error messages and never prints key material.
            throw AppError.invalidAmneziaWGProfile(message.isEmpty ? "движок отклонил профиль" : message)
        }
    }

    static func endpointIPv4(_ value: String) -> String? {
        for line in value.components(separatedBy: .newlines) {
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let pair = content.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, String(pair[0]).trimmingCharacters(in: .whitespaces).lowercased() == "endpoint" else { continue }
            let address = String(pair[1]).trimmingCharacters(in: .whitespaces)
            let parts = address.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let ip = String(parts[0])
            var addr = in_addr()
            return inet_pton(AF_INET, ip, &addr) == 1 ? ip : nil
        }
        return nil
    }
}
