import Foundation
import Security

/// 用户配置的 Gemini 账号凭据（仅保存在 macOS 登录钥匙串）。
public struct GeminiAccount: Sendable, Equatable {
    public let email: String
    public let accessToken: String
    public let projectID: String?

    public init(email: String, accessToken: String, projectID: String? = nil) {
        self.email = email
        self.accessToken = accessToken
        self.projectID = projectID
    }
}

/// 钥匙串读写抽象：生产环境走 macOS login Keychain，单元测试可注入内存实现。
public protocol GeminiKeychainStorage: Sendable {
    func loadData() -> Data?
    func saveData(_ data: Data) throws
    func deleteData() throws
}

public struct SystemGeminiKeychainStorage: GeminiKeychainStorage {
    public static let service = "dev.usage-lens.gemini"
    public static let account = "oauth-account"

    public init() {}

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    public func loadData() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              !data.isEmpty else {
            return nil
        }
        return data
    }

    public func saveData(_ data: Data) throws {
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(query as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    public func deleteData() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecItemNotFound else {
            try check(status)
            return
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw GeminiAccountStoreError.keychain(status)
        }
    }
}

public final class InMemoryGeminiKeychainStorage: GeminiKeychainStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    public init(initialData: Data? = nil) {
        self.data = initialData
    }

    public func loadData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    public func saveData(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
    }

    public func deleteData() throws {
        lock.lock()
        defer { lock.unlock() }
        self.data = nil
    }
}

/// Gemini 账号凭据存储与保存前验证。
public enum GeminiAccountStore {
    private struct StoredPayload: Codable {
        let email: String
        let accessToken: String
        let projectID: String?

        enum CodingKeys: String, CodingKey {
            case email
            case accessToken = "access_token"
            case projectID = "project_id"
        }
    }

    public static var hasSavedAccount: Bool {
        hasSavedAccount(storage: SystemGeminiKeychainStorage())
    }

    public static func hasSavedAccount(storage: any GeminiKeychainStorage) -> Bool {
        load(storage: storage) != nil
    }

    /// 仅返回非敏感的账号邮箱标签供配置界面展示，绝不暴露 accessToken。
    public static func savedAccountEmail(
        storage: any GeminiKeychainStorage = SystemGeminiKeychainStorage()
    ) -> String? {
        load(storage: storage)?.email
    }

    /// 仅供 ProbeRunner 注入 Gemini 子进程使用；调用方不得打印或持久化 accessToken。
    public static func load(
        storage: any GeminiKeychainStorage = SystemGeminiKeychainStorage()
    ) -> GeminiAccount? {
        guard let data = storage.loadData(),
              let payload = try? JSONDecoder().decode(StoredPayload.self, from: data) else {
            return nil
        }
        let email = payload.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = payload.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = payload.projectID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !token.isEmpty else { return nil }
        return GeminiAccount(
            email: email,
            accessToken: token,
            projectID: (project?.isEmpty ?? true) ? nil : project
        )
    }

    public static func save(
        email rawEmail: String,
        accessToken rawToken: String,
        projectID rawProjectID: String? = nil,
        storage: any GeminiKeychainStorage = SystemGeminiKeychainStorage()
    ) throws {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { throw GeminiAccountStoreError.emptyEmail }

        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GeminiAccountStoreError.emptyAccessToken }

        let trimmedProject = rawProjectID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectID = (trimmedProject?.isEmpty ?? true) ? nil : trimmedProject

        let payload = StoredPayload(email: email, accessToken: token, projectID: projectID)
        let data = try JSONEncoder().encode(payload)
        try storage.saveData(data)
    }

    public static func delete(
        storage: any GeminiKeychainStorage = SystemGeminiKeychainStorage()
    ) throws {
        try storage.deleteData()
    }

    /// 在写入钥匙串前，通过 Gemini 探针用临时环境变量验证账号凭据。
    public static func validationMessage(
        email rawEmail: String,
        accessToken rawToken: String,
        projectID rawProjectID: String? = nil,
        runner: ProbeRunner = ProbeRunner()
    ) async -> String? {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return "Gemini 账号邮箱不能为空" }

        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return "访问令牌不能为空" }

        var overrides: [String: String] = [
            "GEMINI_ACCOUNT_EMAIL": email,
            "GEMINI_ACCESS_TOKEN": token,
        ]
        if let project = rawProjectID?.trimmingCharacters(in: .whitespacesAndNewlines), !project.isEmpty {
            overrides["GEMINI_PROJECT_ID"] = project
        }

        let report = await runner.report(
            for: ProviderCatalog.gemini,
            environmentOverrides: overrides
        )
        guard report.failure == nil,
              !report.isMissingProbe,
              !report.isIncompatibleSchema,
              let envelope = report.envelope else {
            return report.failure ?? report.warnings.first ?? "Gemini 账号验证失败，请检查后重试"
        }

        let hasAccountPrompt = report.warnings.contains { $0.contains("请先在配置中提供 Gemini 账号") }
        let verified = !envelope.windows.isEmpty || (envelope.account?.label != nil && !hasAccountPrompt)
        guard verified else {
            return report.warnings.first ?? "Gemini 账号验证失败，请检查后重试"
        }
        return nil
    }
}

public enum GeminiAccountStoreError: LocalizedError, Equatable {
    case emptyEmail
    case emptyAccessToken
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyEmail:
            "Gemini 账号邮箱不能为空"
        case .emptyAccessToken:
            "访问令牌不能为空"
        case .keychain(let status):
            "无法访问 macOS 钥匙串（错误码 \(status)）"
        }
    }
}
