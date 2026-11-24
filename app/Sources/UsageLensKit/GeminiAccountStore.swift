import Foundation
import LocalAuthentication
import Security

/// Gemini 凭据来源：严格区分手动钥匙串账号、本机 CLI 只读复用与未配置状态。
public enum GeminiCredentialSource: Sendable, Equatable {
    /// 用户在配置页手动保存到钥匙串的账号（最高优先级）。
    case manualKeychain(email: String)
    /// 自动复用本机 Gemini CLI / AGY 登录态（~/.gemini/oauth_creds.json）。
    case localCLI(email: String?)
    /// 未配置任何凭据。
    case unconfigured
}

/// 本机 Gemini CLI 登录态的非敏感元信息（绝不包含任何令牌）。
public struct GeminiLocalAuthInfo: Sendable, Equatable {
    public let email: String?

    public init(email: String?) {
        self.email = email
    }
}

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
            kSecUseAuthenticationContext as String: KeychainInteractionGuard.nonInteractiveContext(),
        ]
    }

    internal func buildReadQuery() -> [String: Any] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    public func loadData() -> Data? {
        guard !KeychainInteractionGuard.isInteractiveInProgress else { return nil }
        KeychainInteractionGuard.disableUserInteraction()
        let query = buildReadQuery()

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              !data.isEmpty else {
            return nil
        }
        return data
    }

    public func saveData(_ data: Data) throws {
        try check(KeychainInteractionGuard.upsertAppOwnedItem(baseQuery: baseQuery, value: data))
    }

    public func deleteData() throws {
        KeychainInteractionGuard.disableUserInteraction()
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

    /// 只读探测本机 Gemini CLI / AGY 登录态（~/.gemini/oauth_creds.json）。
    /// 仅检查有效令牌是否存在并提取非敏感邮箱元数据，绝不返回或持久保存任何令牌明文。
    public static func detectLocalCLIAuth(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> GeminiLocalAuthInfo? {
        let geminiDir = homeDirectory.appendingPathComponent(".gemini", isDirectory: true)
        let credsURL = geminiDir.appendingPathComponent("oauth_creds.json")
        guard let data = try? Data(contentsOf: credsURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }

        let hasAccess = (dict["access_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let hasRefresh = (dict["refresh_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        guard hasAccess || hasRefresh else {
            return nil
        }

        var email: String?
        let accountsURL = geminiDir.appendingPathComponent("google_accounts.json")
        if let accData = try? Data(contentsOf: accountsURL),
           let accObj = try? JSONSerialization.jsonObject(with: accData),
           let accDict = accObj as? [String: Any],
           let active = (accDict["active"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !active.isEmpty {
            email = active
        }

        if email == nil, let idToken = dict["id_token"] as? String {
            email = decodeJWTEmail(from: idToken)
        }

        return GeminiLocalAuthInfo(email: email)
    }

    /// 按优先级解析当前生效的 Gemini 凭据来源：手动钥匙串 > 本机 CLI 只读复用 > 未配置。
    public static func credentialSource(
        storage: any GeminiKeychainStorage = SystemGeminiKeychainStorage(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> GeminiCredentialSource {
        if let saved = savedAccountEmail(storage: storage) {
            return .manualKeychain(email: saved)
        }
        if let local = detectLocalCLIAuth(homeDirectory: homeDirectory) {
            return .localCLI(email: local.email)
        }
        return .unconfigured
    }

    private static func decodeJWTEmail(from token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let payloadData = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: payloadData),
              let claims = object as? [String: Any],
              let rawEmail = claims["email"] as? String else {
            return nil
        }
        let trimmed = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
            "GEMINI_DISABLE_LOCAL_AUTH": "1",
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
