import Foundation
import Security

public enum AppError: LocalizedError {
    case invalidLink(String)
    case invalidAmneziaWGProfile(String)
    case missingProfile
    case missingCore(String)
    case coreFailed(String)
    case tunnelFailed(String)
    case keychain(OSStatus)
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLink(let reason):
            return "Некорректная VLESS-ссылка: \(reason)"
        case .invalidAmneziaWGProfile(let reason):
            return "Не удалось импортировать профиль AmneziaWG: \(reason)"
        case .missingProfile:
            return "Сначала вставьте и сохраните VLESS-ссылку."
        case .missingCore(let name):
            return "В приложении отсутствует компонент \(name). Выполните чистую сборку проекта MojaveRay в Xcode."
        case .coreFailed(let reason):
            return "Xray не запустился: \(reason)"
        case .tunnelFailed(let reason):
            return "Не удалось настроить соединение: \(reason)"
        case .keychain(let status):
            return "Ошибка Связки ключей macOS (код \(status))."
        case .fileSystem(let reason):
            return "Ошибка файловой системы: \(reason)"
        }
    }
}
