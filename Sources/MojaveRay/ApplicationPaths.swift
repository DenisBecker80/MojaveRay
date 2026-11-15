import Foundation
import Darwin
import MojaveRayCore

enum ApplicationPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MojaveRay", isDirectory: true)
    }

    static var configFile: URL {
        return supportDirectory.appendingPathComponent("config.json")
    }

    static var runtimeDirectory: URL {
        return supportDirectory.appendingPathComponent("Runtime", isDirectory: true)
    }

    static func prepare() throws {
        do {
            try FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createDirectory(
                at: runtimeDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            _ = chmod(supportDirectory.path, 0o700)
            _ = chmod(runtimeDirectory.path, 0o700)
        } catch {
            throw AppError.fileSystem(error.localizedDescription)
        }
    }

    static func writeConfig(_ data: Data) throws {
        do {
            try prepare()
            try data.write(to: configFile, options: .atomic)
            guard chmod(configFile.path, 0o600) == 0 else {
                throw AppError.fileSystem("не удалось установить права 0600 для конфигурации")
            }
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.fileSystem(error.localizedDescription)
        }
    }

    static func removeTransientConfig() {
        try? FileManager.default.removeItem(at: configFile)
    }

    static func bundledResource(_ relativePath: String) -> URL? {
        return Bundle.main.resourceURL?.appendingPathComponent(relativePath)
    }
}
