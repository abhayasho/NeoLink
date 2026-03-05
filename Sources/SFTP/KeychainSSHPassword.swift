import Foundation
import Security

enum KeychainSSHPassword {
    private static let service = "NeoLink-SFTP"

    static func key(host: String, port: Int, username: String) -> String {
        "\(host):\(port):\(username)"
    }

    static func get(host: String, port: Int, username: String) -> String? {
        let account = key(host: host, port: port, username: username)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(host: String, port: Int, username: String, password: String) {
        let account = key(host: host, port: port, username: username)
        delete(host: host, port: port, username: username)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8)
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(host: String, port: Int, username: String) {
        let account = key(host: host, port: port, username: username)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
