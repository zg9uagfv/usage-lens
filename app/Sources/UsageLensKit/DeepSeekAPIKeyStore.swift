import Foundation
import LocalAuthentication
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
            kSecUseAuthenticationContext as String: KeychainInteractionGuard.nonInteractiveContext(),
        ]
    }

    internal static func buildReadQuery() -> [String: Any] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    public static var hasSavedKey: Bool {
        load() != nil
    }

    /// Returns the key only to the DeepSeek probe runner; callers must never log it.
    public static func load() -> String? {
        guard !KeychainInteractionGuard.isInteractiveInProgress else { return nil }
        KeychainInteractionGuard.disableUserInteraction()
        let query = buildReadQuery()

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
        try check(KeychainInteractionGuard.upsertAppOwnedItem(baseQuery: baseQuery, value: value))
    }

    public static func delete() throws {
        KeychainInteractionGuard.disableUserInteraction()
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecItemNotFound else { try check(status); return }
    }

    /// 在写入钥匙串前，让 DeepSeek 探针用候选密钥请求官方余额接口。
    /// 密钥仅作为子进程环境变量存在，不会写文件或出现在错误文案中。
    public static func validationMessage(for rawKey: String, runner: ProbeRunner = ProbeRunner()) async -> String? {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "API Key 不能为空" }
        let report = await runner.report(
            for: ProviderCatalog.deepseek,
            environmentOverrides: ["DEEPSEEK_API_KEY": key]
        )
        guard report.failure == nil,
              report.envelope?.balance?.source?.lowercased() == "official" else {
            return report.failure ?? report.warnings.first ?? "API Key 验证失败，请检查后重试"
        }
        return nil
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
