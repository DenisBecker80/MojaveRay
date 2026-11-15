import Foundation

public enum XrayConfigBuilder {
    public static func data(for profile: VLESSProfile, socksPort: Int = 10_808, httpPort: Int = 10_809) throws -> Data {
        var user: [String: Any] = [
            "id": profile.id,
            "encryption": "none"
        ]
        if let flow = profile.flow { user["flow"] = flow }

        let realitySettings: [String: Any] = [
            "show": false,
            "fingerprint": profile.fingerprint,
            "serverName": profile.serverName,
            "publicKey": profile.publicKey,
            "shortId": profile.shortID,
            "spiderX": profile.spiderX
        ]
        var stream: [String: Any] = [
            "network": profile.transport == "tcp" ? "tcp" : "grpc",
            "security": "reality",
            "realitySettings": realitySettings
        ]
        if profile.transport == "grpc" {
            // Do not put grpcSettings into a TCP/RAW stream.
            // Health checks detect a gRPC stream silently stalled by DPI or
            // by sleep: without them Xray waits for the long TCP timeout.
            var grpcSettings: [String: Any] = [
                "serviceName": profile.serviceName,
                "multiMode": false,
                "idle_timeout": 60,
                "health_check_timeout": 20,
                "permit_without_stream": false
            ]
            if !profile.authority.isEmpty { grpcSettings["authority"] = profile.authority }
            stream["grpcSettings"] = grpcSettings
        }
        let proxyOutbound: [String: Any] = [
            "tag": "proxy",
            "protocol": "vless",
            "settings": [
                "vnext": [[
                    "address": profile.host,
                    "port": profile.port,
                    "users": [user]
                ]]
            ],
            "streamSettings": stream
        ]
        let config: [String: Any] = [
            "log": ["loglevel": "warning"],
            "inbounds": [
                ["tag": "socks-in", "listen": "127.0.0.1", "port": socksPort,
                 "protocol": "socks", "settings": ["auth": "noauth", "udp": true]],
                ["tag": "http-in", "listen": "127.0.0.1", "port": httpPort,
                 "protocol": "http", "settings": [:]]
            ],
            "outbounds": [
                proxyOutbound,
                ["tag": "direct", "protocol": "freedom", "settings": [:]],
                ["tag": "block", "protocol": "blackhole", "settings": [:]]
            ],
            "routing": [
                "domainStrategy": "AsIs",
                "rules": [[
                    "type": "field",
                    "inboundTag": ["socks-in", "http-in"],
                    "outboundTag": "proxy"
                ]]
            ]
        ]
        guard JSONSerialization.isValidJSONObject(config) else {
            throw AppError.fileSystem("не удалось сформировать JSON-конфигурацию")
        }
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }
}
