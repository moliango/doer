import XCTest
@testable import Doer

@MainActor
final class NativeLoginSessionTests: XCTestCase {
    func testParsesInvalidCredentials() {
        let body = #"{"failed":"FAILED","message":"Incorrect username, email or password","reason":"invalid_credentials"}"#
        if case .failure(let message) = NativeLoginSessionRunner.parseSession(status: 200, body: body) {
            XCTAssertTrue(message.contains("密码") || message.lowercased().contains("invalid") || !message.isEmpty)
        } else {
            XCTFail("expected failure")
        }
    }

    func testParsesSecondFactor() {
        let body = #"{"error":"invalid second factor","reason":"invalid_second_factor","totp_enabled":true}"#
        if case .secondFactor(let totp) = NativeLoginSessionRunner.parseSession(status: 200, body: body) {
            XCTAssertTrue(totp)
        } else {
            XCTFail("expected second factor")
        }
    }

    func testParsesChineseSecondFactorWithoutReason() {
        let body = #"{"failed":"FAILED","error":"双重身份无法校验"}"#
        if case .secondFactor = NativeLoginSessionRunner.parseSession(status: 200, body: body) {
            return
        }
        XCTFail("expected second factor from chinese error")
    }

    func testParsesSuccessUser() {
        let body = #"{"user":{"id":1,"username":"naine"}}"#
        if case .success = NativeLoginSessionRunner.parseSession(status: 200, body: body) {
            return
        }
        XCTFail("expected success")
    }
}
