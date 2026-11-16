import Foundation
import Security

/// DeepSeek API key lives in the user's macOS login Keychain.
public enum DeepSeekAPIKeyStore {
    private static let service = "dev.usage-lens.deepseek"
    private static let account = "api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static var hasSavedKey: Bool {
        load() != nil
    }

    /// Returns the key only to the DeepSeek probe runner; callers must never log it.
    public static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    public static func save(_ rawKey: String) throws {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw DeepSeekAPIKeyStoreError.emptyKey }

        let value = Data(key.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = value
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(query as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    public static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecItemNotFound else { try check(status); return }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw DeepSeekAPIKeyStoreError.keychain(status)
        }
    }
}

public enum DeepSeekAPIKeyStoreError: LocalizedError {
    case emptyKey
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyKey:
            "API Key 不能为空"
        case .keychain(let status):
            "无法访问 macOS 钥匙串（错误码 \(status)）"
        }
    }
}
