import Foundation
import Security

enum OpenAIKeychain {
    private static let service = "app.listenup.openai"
    private static let account = "api-key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw KeychainError.emptyKey }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status: OSStatus
        if SecItemCopyMatching(identity as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        } else {
            status = SecItemAdd(identity.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}

private enum KeychainError: Error, LocalizedError {
    case emptyKey
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "API 키를 입력해 주세요."
        case .status(let value):
            return "macOS 키체인에 API 키를 저장하지 못했습니다(\(value))."
        }
    }
}
