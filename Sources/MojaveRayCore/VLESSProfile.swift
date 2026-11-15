import Foundation

public struct VLESSProfile: Equatable {
    public let id: String
    public let host: String
    public let port: Int
    public let transport: String
    public let security: String
    public let publicKey: String
    public let fingerprint: String
    public let serverName: String
    public let shortID: String
    public let spiderX: String
    public let serviceName: String
    public let authority: String
    public let flow: String?
    public let displayName: String

    public var summary: String {
        return "VLESS · REALITY · \(transport.uppercased()) · порт \(port)"
    }

    public var redactionTokens: [String] {
        return [id, host, publicKey, shortID, serverName, serviceName]
            .filter { $0.count >= 3 }
    }

    public var ipv4Host: String? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        for part in parts {
            guard let value = Int(part), value >= 0, value <= 255,
                  String(value) == String(part) else {
                return nil
            }
        }
        return host
    }
}
