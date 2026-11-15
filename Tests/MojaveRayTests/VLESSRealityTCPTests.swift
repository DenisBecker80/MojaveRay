import Foundation
import XCTest
@testable import MojaveRayCore

final class VLESSRealityTCPTests: XCTestCase {
    private let pbk = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    private let uuid = "11111111-2222-4333-8444-555555555555"
    private var grpc: String {
        "vless://\(uuid)@203.0.113.10:443?type=grpc&serviceName=&authority=&security=reality&pbk=\(pbk)&fp=chrome&sni=example.com&sid=0123456789abcdef&spx=%2F#Old%20Tallinn"
    }
    private var tcp: String {
        "vless://\(uuid)@203.0.113.20:443?type=tcp&security=reality&encryption=none&pbk=\(pbk)&fp=chrome&sni=www.microsoft.com&sid=abcdef1234567890&spx=%2F&flow=xtls-rprx-vision#Tallinn%20RAW"
    }
    private func outbound(_ link: String) throws -> ([String: Any], [String: Any], [String: Any]) {
        let data = try XrayConfigBuilder.data(for: VLESSParser.parse(link))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let proxy = try XCTUnwrap((config["outbounds"] as? [[String: Any]])?.first)
        let stream = try XCTUnwrap(proxy["streamSettings"] as? [String: Any])
        let settings = try XCTUnwrap(proxy["settings"] as? [String: Any])
        let endpoint = try XCTUnwrap((settings["vnext"] as? [[String: Any]])?.first)
        let user = try XCTUnwrap((endpoint["users"] as? [[String: Any]])?.first)
        return (stream, user, config)
    }
    func testTCPVision() throws {
        let profile = try VLESSParser.parse(tcp)
        XCTAssertEqual(profile.transport, "tcp")
        XCTAssertEqual(profile.flow, "xtls-rprx-vision")
        XCTAssertEqual(profile.displayName, "Tallinn RAW")
        let (stream, user, _) = try outbound(tcp)
        XCTAssertEqual(stream["network"] as? String, "tcp")
        XCTAssertEqual(stream["security"] as? String, "reality")
        XCTAssertNil(stream["grpcSettings"])
        XCTAssertEqual(user["flow"] as? String, "xtls-rprx-vision")
    }
    func testRAWAlias() throws {
        let alias = tcp.replacingOccurrences(of: "type=tcp", with: "type=raw")
        XCTAssertEqual(try VLESSParser.parse(alias).transport, "tcp")
        XCTAssertEqual(try outbound(alias).0["network"] as? String, "tcp")
    }
    func testOldGRPCStillWorks() throws {
        let profile = try VLESSParser.parse(grpc)
        XCTAssertEqual(profile.transport, "grpc")
        XCTAssertEqual(profile.displayName, "Old Tallinn")
        let (stream, user, _) = try outbound(grpc)
        XCTAssertEqual(stream["network"] as? String, "grpc")
        XCTAssertNotNil(stream["grpcSettings"])
        XCTAssertNil(user["flow"])
    }
    func testRejectsGRPCWithVisionFlow() {
        let link = grpc.replacingOccurrences(of: "type=grpc", with: "type=grpc&flow=xtls-rprx-vision")
        XCTAssertThrowsError(try VLESSParser.parse(link))
    }
    func testRejectsMalformedPublicKey() {
        XCTAssertThrowsError(try VLESSParser.parse(tcp.replacingOccurrences(of: pbk, with: "INVALID")))
    }
    func testRejectsOtherTransport() {
        XCTAssertThrowsError(try VLESSParser.parse(tcp.replacingOccurrences(of: "type=tcp", with: "type=ws")))
    }
    func testRejectsUnsupportedEncryption() {
        XCTAssertThrowsError(try VLESSParser.parse(tcp.replacingOccurrences(of: "encryption=none", with: "encryption=aes")))
    }
    func testNoDoubleDecodingFragment() throws {
        let link = tcp.replacingOccurrences(of: "#Tallinn%20RAW", with: "#rate%2520")
        XCTAssertEqual(try VLESSParser.parse(link).displayName, "rate%20")
    }
}
