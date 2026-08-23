import XCTest
@testable import DohProxy

final class ShadowsocksAEADTests: XCTestCase {
    func testEVPBytesToKeyLength() {
        XCTAssertEqual(ShadowsocksAEAD.evpBytesToKey(password: "secret", keyLength: 16).count, 16)
        XCTAssertEqual(ShadowsocksAEAD.evpBytesToKey(password: "secret", keyLength: 32).count, 32)
    }

    func testHKDFLength() {
        let ikm = Data(repeating: 1, count: 16)
        let salt = Data(repeating: 2, count: 16)
        let out = ShadowsocksAEAD.hkdfSHA1(ikm: ikm, salt: salt, info: Data("ss-subkey".utf8), length: 16)
        XCTAssertEqual(out.count, 16)
    }

    func testCipherInit() {
        XCTAssertEqual(ShadowsocksAEAD.Cipher(name: "aes-128-gcm")?.keyLength, 16)
        XCTAssertEqual(ShadowsocksAEAD.Cipher(name: "2022-blake3-aes-256-gcm")?.keyLength, 32)
        XCTAssertEqual(UpstreamHandshake.shadowsocksKeyLength(cipher: "2022-blake3-aes-256-gcm"), 32)
    }

    func testAEADRoundTrip() {
        let session = ShadowsocksAEADSession(password: "secret", cipher: .aes128gcm)
        let message = Data("hello shadowsocks".utf8)
        let cipher = session.encrypt(message)
        XCTAssertEqual(session.decrypt(cipher), message)
    }

    func testBlake3EmptyHash() {
        let digest = Blake3.hash(Data())
        XCTAssertEqual(
            digest.map { String(format: "%02x", $0) }.joined(),
            "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
        )
    }

    func test2022SessionEncrypts() {
        let psk = Data(repeating: 7, count: 32).base64EncodedString()
        let session = ShadowsocksAEADSession(password: psk, cipher: .blake3Aes256gcm)
        let blob = session.encrypt(Data("ping".utf8))
        XCTAssertGreaterThan(blob.count, 4 + 32)
    }
}
