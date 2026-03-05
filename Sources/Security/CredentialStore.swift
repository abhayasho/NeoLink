import Foundation

@MainActor
final class CredentialStore {
    static let shared = CredentialStore()
    private init() {}

    func savePassword(_ password: String, for account: String) {
        // TODO: Keychain integration
    }

    func loadPassword(for account: String) -> String? {
        nil
    }
}

