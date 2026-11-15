import Foundation
import Security
import MojaveRayCore

struct SavedVLESSProfile: Codable {
    let id: String
    var name: String
    var link: String
}

struct SavedVLESSProfiles: Codable {
    var profiles: [SavedVLESSProfile]
    var selectedID: String?
}

final class KeychainStore {
    func loadProfiles() throws -> SavedVLESSProfiles {
        if let value = try load(account: "profiles-v2") {
            return try JSONDecoder().decode(SavedVLESSProfiles.self, from: Data(value.utf8))
        }
        // Commit migration before removing the legacy key. Never migrate again
        // after the user deliberately deletes their last profile.
        var result = SavedVLESSProfiles(profiles: [], selectedID: nil)
        if let link = try load() {
            let parsed = try VLESSParser.parse(link)
            let profile = SavedVLESSProfile(id: UUID().uuidString,
                name: parsed.displayName.isEmpty ? "Основной" : parsed.displayName, link: link)
            result.profiles = [profile]
            result.selectedID = profile.id
        }
        try saveProfiles(result)
        // Migration is durable even if legacy cleanup fails.
        try? delete()
        return result
    }

    func saveProfiles(_ value: SavedVLESSProfiles) throws {
        let data = try JSONEncoder().encode(value)
        try save(String(decoding: data, as: UTF8.self), account: "profiles-v2")
    }

    private let service = "com.denisbekker.MojaveRay.vless"

    func save(_ value: String, account: String = "default-profile") throws {
        guard let data = value.data(using: .utf8) else {
            throw AppError.invalidLink("не удалось преобразовать ссылку в UTF-8")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw AppError.keychain(updateStatus)
        }

        var addQuery = query
        for (key, value) in attributes {
            addQuery[key] = value
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AppError.keychain(addStatus)
        }
    }

    func load(account: String = "default-profile") throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw AppError.keychain(status)
        }
        return value
    }

    func delete(account: String = "default-profile") throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.keychain(status)
        }
    }
}
