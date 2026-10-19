import XCTest
@testable import NeoLink

final class SSHSessionInputTests: XCTestCase {
    func testHostnamesAliasesAndIPv6AreAccepted() {
        for host in ["server.example.com", "my-ssh-alias", "192.168.1.10", "2001:db8::1"] {
            XCTAssertTrue(SSHSessionInput.isValid(host: host, username: "user", port: "22"))
        }
    }

    func testInvalidPortAndCommandLikeValuesAreRejected() {
        for port in ["0", "65536", "-1", "", "abc"] {
            XCTAssertFalse(SSHSessionInput.isValid(host: "server", username: "user", port: port))
        }
        for host in ["", "-oProxyCommand=command", "user@host", "host\nother", "host name"] {
            XCTAssertFalse(SSHSessionInput.isValid(host: host, username: "user", port: "22"))
        }
        for username in ["", "-user", "user@host", "user name"] {
            XCTAssertFalse(SSHSessionInput.isValid(host: "host", username: username, port: "22"))
        }
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertTrue(SSHSessionInput.isValid(host: " server.example.com ", username: " user ", port: "2222"))
    }
}
