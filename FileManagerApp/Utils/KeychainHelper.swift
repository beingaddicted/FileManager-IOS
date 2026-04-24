import Foundation
import Security

// MARK: - KeychainHelper

final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    // MARK: - Save

    @discardableResult
    func save(_ value: String, key: String) -> Bool {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData:   data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Load

    func load(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrAccount:      key,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Delete

    @discardableResult
    func delete(key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Convenience for connections

    func password(for connection: ServerConnection) -> String {
        load(key: connection.keychainKey) ?? ""
    }

    func savePassword(_ password: String, for connection: ServerConnection) {
        save(password, key: connection.keychainKey)
    }

    // Token storage (OAuth)

    func saveToken(_ token: String, provider: ProviderType) {
        save(token, key: "fm_token_\(provider.rawValue)")
    }

    func token(for provider: ProviderType) -> String? {
        load(key: "fm_token_\(provider.rawValue)")
    }

    func deleteToken(for provider: ProviderType) {
        delete(key: "fm_token_\(provider.rawValue)")
    }
}
