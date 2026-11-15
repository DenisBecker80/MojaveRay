import Foundation
import XCTest
@testable import MojaveRayCore

final class VLESSParserTests: XCTestCase {
    private let sample = "vless://11111111-2222-4333-8444-555555555555@203.0.113.10:443?type=grpc&serviceName=&authority=&security=reality&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&fp=random&sni=example.com&sid=0123456789abcdef&spx=%2F#Test"

    func testParsesRealityGrpcLinkWithEmptyServiceName() throws {
        let profile = try VLESSParser.parse(sample)
        XCTAssertEqual(profile.host, "203.0.113.10")
        XCTAssertEqual(profile.port, 443)
        XCTAssertEqual(profile.transport, "grpc")
        XCTAssertEqual(profile.security, "reality")
        XCTAssertEqual(profile.serviceName, "")
        XCTAssertEqual(profile.authority, "")
        XCTAssertEqual(profile.fingerprint, "random")
        XCTAssertEqual(profile.serverName, "example.com")
        XCTAssertEqual(profile.shortID, "0123456789abcdef")
        XCTAssertEqual(profile.spiderX, "/")
        XCTAssertEqual(profile.ipv4Host, "203.0.113.10")
    }

    func testBuildsExpectedXrayConfig() throws {
        let profile = try VLESSParser.parse(sample)
        let data = try XrayConfigBuilder.data(for: profile)
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let config = raw as? [String: Any],
              let outbounds = config["outbounds"] as? [[String: Any]],
              let proxy = outbounds.first,
              let stream = proxy["streamSettings"] as? [String: Any],
              let grpc = stream["grpcSettings"] as? [String: Any],
              let reality = stream["realitySettings"] as? [String: Any] else {
            XCTFail("Неверная структура JSON")
            return
        }
        XCTAssertEqual(stream["network"] as? String, "grpc")
        XCTAssertEqual(stream["security"] as? String, "reality")
        XCTAssertEqual(grpc["serviceName"] as? String, "")
        XCTAssertEqual(reality["serverName"] as? String, "example.com")
        XCTAssertEqual(reality["fingerprint"] as? String, "random")
    }

    func testRejectsWrongSecurity() {
        let invalid = sample.replacingOccurrences(of: "security=reality", with: "security=tls")
        XCTAssertThrowsError(try VLESSParser.parse(invalid))
    }

    func testRejectsOddShortID() {
        let invalid = sample.replacingOccurrences(of: "sid=0123456789abcdef", with: "sid=abc")
        XCTAssertThrowsError(try VLESSParser.parse(invalid))
    }

    func testRejectsNonEmptyAuthorityUnsupportedByPinnedCore() {
        let unsupported = sample.replacingOccurrences(of: "authority=&", with: "authority=edge.example&")
        XCTAssertThrowsError(try VLESSParser.parse(unsupported))
    }
}
