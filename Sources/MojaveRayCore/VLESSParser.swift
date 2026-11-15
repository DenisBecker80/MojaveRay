import Foundation

public enum VLESSParser {
    public static func parse(_ rawValue: String) throws -> VLESSProfile {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AppError.invalidLink("ссылка пуста") }
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "vless" else {
            throw AppError.invalidLink("ожидается схема vless://")
        }
        guard let user = components.user, UUID(uuidString: user) != nil else {
            throw AppError.invalidLink("UUID отсутствует или имеет неверный формат")
        }
        guard let host = components.host, !host.isEmpty else {
            throw AppError.invalidLink("не указан адрес сервера")
        }
        let port = components.port ?? 443
        guard (1...65535).contains(port) else {
            throw AppError.invalidLink("порт должен быть от 1 до 65535")
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let key = item.name.lowercased()
            guard query[key] == nil else {
                throw AppError.invalidLink("параметр \(key) указан несколько раз")
            }
            query[key] = item.value ?? ""
        }
        // Newer 3X-UI uses type=raw; older links use type=tcp.
        // Xray 1.8.1 expects the canonical network name "tcp".
        let rawType = (query["type"] ?? "tcp").lowercased()
        let transport: String
        switch rawType {
        case "tcp", "raw": transport = "tcp"
        case "grpc": transport = "grpc"
        default: throw AppError.invalidLink("транспорт \(rawType) не поддерживается (доступны TCP/RAW и gRPC)")
        }
        let security = (query["security"] ?? "none").lowercased()
        guard security == "reality" else {
            throw AppError.invalidLink("ожидается security=reality")
        }
        guard (query["encryption"] ?? "none").lowercased() == "none" else {
            throw AppError.invalidLink("VLESS поддерживает только encryption=none")
        }
        guard let publicKey = query["pbk"], isValidRealityPublicKey(publicKey) else {
            throw AppError.invalidLink("pbk должен содержать корректный REALITY-ключ (32 байта Base64URL)")
        }
        guard let serverName = query["sni"], !serverName.isEmpty else {
            throw AppError.invalidLink("отсутствует SNI")
        }
        let shortID = query["sid"] ?? ""
        if !shortID.isEmpty {
            let isHex = shortID.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
            }
            guard isHex, shortID.count <= 16, shortID.count % 2 == 0 else {
                throw AppError.invalidLink("short ID должен быть чётной HEX-строкой длиной не более 16 символов")
            }
        }
        let fingerprint = (query["fp"] ?? "chrome").lowercased()
        let allowedFP: Set<String> = ["chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized"]
        guard allowedFP.contains(fingerprint) else {
            throw AppError.invalidLink("неподдерживаемый отпечаток uTLS (fp)")
        }
        let spiderX = query["spx"].flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        let serviceName = query["servicename"] ?? ""
        let authority = query["authority"] ?? ""
        let flow = query["flow"].flatMap { $0.isEmpty ? nil : $0 }
        if transport == "tcp" {
            guard flow == nil || flow == "xtls-rprx-vision" else {
                throw AppError.invalidLink("неподдерживаемый flow для TCP/RAW")
            }
            guard (query["headertype"] ?? "none").lowercased() == "none" else {
                throw AppError.invalidLink("TCP с HTTP-обфускацией пока не поддерживается")
            }
        } else {
            guard flow == nil else {
                throw AppError.invalidLink("flow не должен применяться к gRPC")
            }
            guard authority.isEmpty else {
                throw AppError.invalidLink("непустой authority не поддерживается Xray 1.8.1")
            }
            let mode = (query["mode"] ?? "gun").lowercased()
            guard mode == "gun" else {
                throw AppError.invalidLink("для gRPC поддерживается только mode=gun")
            }
        }
        // URLComponents.fragment has already decoded percent escapes.
        let displayName = components.fragment ?? "VPN"
        return VLESSProfile(
            id: user.lowercased(), host: host, port: port,
            transport: transport, security: security, publicKey: publicKey,
            fingerprint: fingerprint, serverName: serverName,
            shortID: shortID, spiderX: spiderX,
            serviceName: serviceName, authority: authority, flow: flow,
            displayName: displayName
        )
    }

    private static func isValidRealityPublicKey(_ value: String) -> Bool {
        guard value.count == 43, value.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte) ||
            (48...57).contains(byte) || byte == 45 || byte == 95
        }) else { return false }
        let b64 = value.replacingOccurrences(of: "-", with: "+")
                       .replacingOccurrences(of: "_", with: "/") + "="
        return Data(base64Encoded: b64)?.count == 32
    }
}
