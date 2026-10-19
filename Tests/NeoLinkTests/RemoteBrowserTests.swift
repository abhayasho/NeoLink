import XCTest
@testable import NeoLink

final class RemoteBrowserTests: XCTestCase {
    func testRemoteParentPreservesAbsoluteRoot() {
        XCTAssertEqual(RemotePath.parent(of: "/home"), "/")
        XCTAssertEqual(RemotePath.parent(of: "/"), "/")
        XCTAssertEqual(RemotePath.parent(of: "/home/user/"), "/home")
    }

    func testCanNavigateAboveRemoteHome() {
        XCTAssertEqual(RemotePath.parent(of: "."), "..")
        XCTAssertEqual(RemotePath.parent(of: ".."), "../..")
        XCTAssertEqual(RemotePath.parent(of: "../.."), "../../..")
        XCTAssertEqual(RemotePath.parent(of: "../project"), "..")
    }

    func testRemotePathJoining() {
        XCTAssertEqual(RemotePath.appending("file.txt", to: "/"), "/file.txt")
        XCTAssertEqual(RemotePath.appending("file.txt", to: "."), "file.txt")
        XCTAssertEqual(RemotePath.appending("file.txt", to: "/home/user"), "/home/user/file.txt")
        XCTAssertEqual(RemotePath.appending("file.txt", to: "/home/user/"), "/home/user/file.txt")
    }

    func testRemoteNamesCannotEscapeParentDirectory() {
        for name in ["", ".", "..", "../file", "folder/file", "bad\0name"] {
            XCTAssertFalse(RemotePath.isValidName(name), name)
        }
        XCTAssertTrue(RemotePath.isValidName("My document.txt"))
        XCTAssertTrue(RemotePath.isValidName(".config"))
    }

    func testLocalShellTitlesDoNotTriggerSFTP() {
        let hosts: Set<String> = ["My-Mac.local", "My-Mac"]
        for title in ["user@localhost:~", "user@127.0.0.1", "user@MY-MAC:~", "user@my-mac.local:/tmp", "user@0.0.0.0"] {
            XCTAssertNil(DetectedSSHEndpoint.parse(title, localHostnames: hosts), title)
        }
    }

    func testOnlyUnambiguousRemoteTitlesAreDetected() {
        let hosts: Set<String> = ["my-mac.local"]
        XCTAssertEqual(DetectedSSHEndpoint.parse("alice@server.example.com:~/work", localHostnames: hosts), DetectedSSHEndpoint(username: "alice", host: "server.example.com"))
        XCTAssertEqual(DetectedSSHEndpoint.parse("alice@login-ice-3:~", localHostnames: hosts)?.host, "login-ice.pace.gatech.edu")
        for title in ["", "@server", "alice@", "ssh alice@server", "alice@server running command", "alice@server@other", "alice@/tmp"] {
            XCTAssertNil(DetectedSSHEndpoint.parse(title, localHostnames: hosts), title)
        }
    }

    func testRemoteItemIdentitySurvivesRefresh() {
        let first = SftpItem(path: "/home/file", name: "file", isDirectory: false, size: 1, modifiedAt: nil)
        let refreshed = SftpItem(path: "/home/file", name: "file", isDirectory: false, size: 2, modifiedAt: nil)
        XCTAssertEqual(first.id, refreshed.id)
    }
}
