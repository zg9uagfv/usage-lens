import Foundation
import LocalAuthentication
import Security

// MARK: - AGY 钥匙串窄范围读写抽象（仅精确白名单 service="gemini", account="antigravity"）

public enum AgyKeychainReadResult: Sendable, Equatable {
    case payload(String)
    case missing
    case denied
    case timeout
    case nonzero
    case unreadable
}

public enum AgyKeychainWriteResult: Sendable, Equatable {
    case updated
    case missing
    case denied
    case timeout
    case nonzero
    case rejected
}

public protocol AgyKeychainReading: Sendable {
    func readGenericPassword(service: String, account: String) -> AgyKeychainReadResult
}

public protocol AgyKeychainWriting: Sendable {
    func updateGenericPassword(service: String, account: String, payload: String) -> AgyKeychainWriteResult
}

/// 生产环境：通过 macOS 原生 Security.SecItemCopyMatching / SecItemUpdate 读写精确白名单元组
/// `(service: "gemini", account: "antigravity")`。
/// - 禁止枚举钥匙串、禁止扩大 ACL、禁止删除或新建条目（仅允许对已存在精确条目执行原位原子 `SecItemUpdate`）；
/// - 显式附加 LAContext(interactionNotAllowed: true) 以拒绝受 LAContext 约束的交互认证弹窗
///   （传统基于文件的登录钥匙串 ACL/IPC 交互无法在进程内绝对阻止，由外层 2 秒有界超时与单飞门控兜底）。
public struct SystemAgyKeychainReader: AgyKeychainReading, AgyKeychainWriting {
    public init() {}

    public static func isAllowedTuple(service: String, account: String) -> Bool {
        service == AgyNativeProbe.keychainService && account == AgyNativeProbe.keychainAccount
    }

    public static func buildQuery(service: String, account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    public static func buildUpdateQuery(service: String, account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    public static func buildUpdateAttributes(payload: Data) -> [String: Any] {
        [
            kSecValueData as String: payload,
        ]
    }

    public func readGenericPassword(service: String, account: String) -> AgyKeychainReadResult {
        guard Self.isAllowedTuple(service: service, account: account) else {
            return .denied
        }
        let query = Self.buildQuery(service: service, account: account)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unreadable
            }
            return .payload(text)
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .denied
        default:
            return .nonzero
        }
    }

    public func updateGenericPassword(service: String, account: String, payload: String) -> AgyKeychainWriteResult {
        guard Self.isAllowedTuple(service: service, account: account) else {
            return .rejected
        }
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = payload.data(using: .utf8),
              !data.isEmpty else {
            return .rejected
        }
        let query = Self.buildUpdateQuery(service: service, account: account)
        let attributes = Self.buildUpdateAttributes(payload: data)
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return .updated
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .denied
        default:
            return .nonzero
        }
    }
}

/// 防止不可中断的底层钥匙串 IPC 卡死时每次轮询都堆积新阻塞线程（同一实例最多 1 个在途读写，超限即 fail-closed 返回 .timeout）。
private final class AgyKeychainSingleFlightGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = false

    func tryEnter() -> Bool {
        lock.withLock {
            guard !inFlight else { return false }
            inFlight = true
            return true
        }
    }

    func leave() {
        lock.withLock {
            inFlight = false
        }
    }
}

internal final class LockedBoundedKeychainContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var timer: DispatchSourceTimer?
    private var settled = false

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    /// 原子挂载并一次性激活限时看门狗：
    /// - 未收敛时在持锁期间 `timer.activate()`，保证任何并发 `finish` 取消前源已激活。
    /// - 已提前完成/取消（或重复挂载）时先清空事件回调、`cancel()` 再显式 `activate()` 一次，严禁释放未激活源。
    @discardableResult
    func attachTimer(_ timer: DispatchSourceTimer) -> Bool {
        let attached: Bool = lock.withLock {
            guard !settled, self.timer == nil else {
                return false
            }
            self.timer = timer
            timer.activate()
            return true
        }
        if !attached {
            timer.setEventHandler(handler: nil)
            timer.cancel()
            timer.activate()
        }
        return attached
    }

    func finish(with result: Value) {
        let (cont, activeTimer): (CheckedContinuation<Value, Never>?, DispatchSourceTimer?) = lock.withLock {
            guard !settled else { return (nil, nil) }
            settled = true
            let c = continuation
            continuation = nil
            let t = timer
            timer = nil
            return (c, t)
        }
        activeTimer?.cancel()
        cont?.resume(returning: result)
    }
}

internal typealias LockedKeychainContinuation = LockedBoundedKeychainContinuation<AgyKeychainReadResult>

internal final class LockedBoundedKeychainCancelBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var once: LockedBoundedKeychainContinuation<Value>?
    private var cancelled = false
    private let timeoutValue: Value

    init(timeoutValue: Value) {
        self.timeoutValue = timeoutValue
    }

    func register(_ once: LockedBoundedKeychainContinuation<Value>) -> Bool {
        lock.withLock {
            if cancelled { return false }
            self.once = once
            return true
        }
    }

    func cancel() {
        let target: LockedBoundedKeychainContinuation<Value>? = lock.withLock {
            cancelled = true
            let o = once
            once = nil
            return o
        }
        target?.finish(with: timeoutValue)
    }
}

internal final class LockedKeychainCancelBox: @unchecked Sendable {
    private let inner = LockedBoundedKeychainCancelBox<AgyKeychainReadResult>(timeoutValue: .timeout)

    func register(_ once: LockedKeychainContinuation) -> Bool {
        inner.register(once)
    }

    func cancel() {
        inner.cancel()
    }
}

// MARK: - AGY 凭据发现脱敏模型

public struct AgySourceAttempt: Sendable, Equatable {
    public let source: String
    public let outcome: String
    public let detail: String?

    public init(source: String, outcome: String, detail: String? = nil) {
        self.source = source
        self.outcome = outcome
        self.detail = detail
    }
}

public struct AgyCredentialDiscovery: Sendable, Equatable {
    public let attempts: [AgySourceAttempt]
    public let outcome: String
    public let selectedSource: String?
    public let detail: String?

    public init(
        attempts: [AgySourceAttempt],
        outcome: String,
        selectedSource: String? = nil,
        detail: String? = nil
    ) {
        self.attempts = attempts
        self.outcome = outcome
        self.selectedSource = selectedSource
        self.detail = detail
    }
}

// MARK: - 原生 Swift AGY 探针

public struct AgyNativeProbe: Sendable {
    public static let officialHost = "daily-cloudcode-pa.googleapis.com"
    public static let loadCodeAssistURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    public static let retrieveQuotaSummaryURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    public static let retrieveQuotaURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    public static let oauthTokenHost = "oauth2.googleapis.com"
    public static let oauthTokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    public static let agyUserAgent = "antigravity"
    public static let keychainService = "gemini"
    public static let keychainAccount = "antigravity"
    public static let goKeyringBase64Prefix = "go-keyring-base64:"
    public static let proactiveRefreshSkewSeconds: TimeInterval = 60.0
    public static let maxRefreshExpiresInSeconds: Int = 31_536_000
    public static let todayTokenScanFiles = 50
    public static let defaultKeychainTimeoutSeconds: TimeInterval = 2.0
    private static let supportedExpiryKeys = ["expiry_date", "expiry", "expires_at"]

    public static let authRequiredWarning =
        "未检测到本机 AGY 登录态（本地凭据文件与钥匙串均未找到），请先运行 agy 登录后刷新以查看实时配额"
    public static let authDisabledWarning =
        "已通过 AGY_DISABLE_LOCAL_AUTH 禁用本机 AGY 登录态检测，当前无法查询 AGY 实时配额"
    public static let authIsolatedHomeWarning =
        "未检测到本机 AGY 登录态：当前处于隔离主目录环境，已跳过本机登录钥匙串读取；请在真实用户环境运行 agy 登录或提供 AGY 凭据后刷新以查看实时配额"
    public static let authKeychainDeniedWarning =
        "无法访问本机 AGY 钥匙串凭据（访问被拒绝或钥匙串已锁定），请解锁登录钥匙串或运行 agy 重新登录后刷新以查看实时配额"
    public static let authKeychainTimeoutWarning =
        "读取本机 AGY 钥匙串凭据超时，请解锁登录钥匙串或运行 agy 重新登录后刷新以查看实时配额"
    public static let authKeychainNonzeroWarning =
        "无法读取本机 AGY 钥匙串凭据（钥匙串查询失败），请检查登录钥匙串状态或运行 agy 重新登录后刷新以查看实时配额"
    public static let authKeychainUnreadableWarning =
        "无法读取本机 AGY 钥匙串凭据，请检查登录钥匙串或运行 agy 重新登录后刷新以查看实时配额"
    public static let authKeychainMalformedWarning =
        "本机 AGY 钥匙串凭据格式异常，请运行 agy 重新登录后刷新以查看实时配额"
    public static let authFileUnreadableWarning =
        "无法读取本机 AGY 本地凭据文件，请检查文件权限或运行 agy 重新登录后刷新以查看实时配额"
    public static let authFileMalformedWarning =
        "本机 AGY 本地凭据文件格式异常，请运行 agy 重新登录后刷新以查看实时配额"
    public static let keychainWriteMissingError =
        "刷新本机 AGY 登录态后写回钥匙串失败（未找到对应钥匙串条目，登录态可能已退出），请先运行 agy 重新登录后刷新"
    public static let keychainWriteDeniedError =
        "刷新本机 AGY 登录态后写回钥匙串被拒绝（钥匙串已锁定或权限受限），请解锁登录钥匙串或运行 agy 重新登录后刷新"
    public static let keychainWriteTimeoutError =
        "刷新本机 AGY 登录态后写回钥匙串超时，请解锁登录钥匙串或运行 agy 重新登录后刷新"
    public static let keychainWriteNonzeroError =
        "刷新本机 AGY 登录态后写回钥匙串失败，请检查登录钥匙串状态或运行 agy 重新登录后刷新"
    public static let keychainWriteRejectedError =
        "刷新本机 AGY 登录态后写回钥匙串校验未通过，已按安全策略中止更新，请运行 agy 重新登录后刷新"

    private enum CredentialOrigin: Sendable, Equatable {
        case env
        case localFile
        case keychain
    }

    private struct KeychainPayloadEnvelope: Sendable {
        var wrappedWithGoKeyringBase64: Bool
        var rawJSONData: Data
    }

    private struct Credentials: Sendable {
        var source: String // "manual" or "local"
        var origin: CredentialOrigin
        var email: String?
        var accessToken: String?
        var refreshToken: String?
        var expiryEpoch: TimeInterval?
        var clientID: String?
        var clientSecret: String?
        var projectID: String?
        var keychainEnvelope: KeychainPayloadEnvelope?
    }

    private struct RefreshedOAuthToken: Sendable {
        var accessToken: String
        var refreshToken: String?
        var tokenType: String?
        var idToken: String?
        var scope: String?
        var expiresInSeconds: Int
        var expiryEpoch: TimeInterval
    }

    private let transport: any NativeHTTPTransport
    private let keychain: any AgyKeychainReading
    private let keychainWriter: (any AgyKeychainWriting)?
    private let realUserHomeOverride: URL?
    private let maxScanBytes: Int
    private let keychainTimeoutSeconds: TimeInterval
    private let keychainGate = AgyKeychainSingleFlightGate()

    public init(
        transport: any NativeHTTPTransport = PinnedURLSessionTransport(),
        keychain: any AgyKeychainReading = SystemAgyKeychainReader(),
        keychainWriter: (any AgyKeychainWriting)? = nil,
        realUserHomeOverride: URL? = nil,
        maxScanBytes: Int = NativeProbeSupport.maxScanBytes,
        keychainTimeoutSeconds: TimeInterval = AgyNativeProbe.defaultKeychainTimeoutSeconds
    ) {
        self.transport = transport
        self.keychain = keychain
        self.keychainWriter = keychainWriter ?? (keychain as? any AgyKeychainWriting)
        self.realUserHomeOverride = realUserHomeOverride
        self.maxScanBytes = maxScanBytes
        self.keychainTimeoutSeconds = keychainTimeoutSeconds.isFinite
            ? min(max(keychainTimeoutSeconds, 0.05), 3_600)
            : Self.defaultKeychainTimeoutSeconds
    }

    public func run(
        environment: [String: String],
        now: Date = Date()
    ) async -> ProbeReport {
        let started = Date()
        let home = NativeProbeSupport.effectiveHomeDirectory(from: environment)
        let (todayTokens, tokenWarnings) = findTodayTokens(home: home, now: now)
        let usage = todayTokens.map { ProbeUsage(todayTokens: $0, source: "local") }

        if Task.isCancelled {
            return ProbeReport(
                provider: ProviderCatalog.agy,
                failure: "探针已取消",
                finishedAt: Date(),
                duration: Date().timeIntervalSince(started)
            )
        }

        let (maybeCreds, discovery) = await resolveCredentialsWithDiscoveryAsync(environment: environment, home: home)
        if Task.isCancelled {
            return ProbeReport(
                provider: ProviderCatalog.agy,
                failure: "探针已取消",
                finishedAt: Date(),
                duration: Date().timeIntervalSince(started)
            )
        }
        guard let creds = maybeCreds else {
            let warnings = NativeProbeSupport.dedupeRedacted([discoveryWarning(discovery)] + tokenWarnings)
            let envelope = ProbeEnvelope(
                provider: ProviderCatalog.agy.id,
                account: ProbeAccount(label: nil, plan: nil),
                generatedAt: now,
                observedAt: now,
                stale: false,
                windows: [],
                usage: usage,
                warnings: warnings,
                error: nil
            )
            return ProbeReport(
                provider: ProviderCatalog.agy,
                envelope: envelope,
                failure: nil,
                finishedAt: Date(),
                duration: Date().timeIntervalSince(started)
            )
        }

        let source = creds.source
        let email = creds.email
        var accessToken = creds.accessToken
        var projectID = creds.projectID ?? ""
        var refreshedOnce = false

        func failReport(_ reason: String, plan: String? = nil) -> ProbeReport {
            let cleanReason = SecretRedactor.redact(reason)
            if let usage {
                let warnings = NativeProbeSupport.dedupeRedacted(
                    ["实时查询 AGY 服务端失败（\(cleanReason)），当前仅显示本地今日 tokens"] + tokenWarnings
                )
                let envelope = ProbeEnvelope(
                    provider: ProviderCatalog.agy.id,
                    account: ProbeAccount(label: email, plan: plan),
                    generatedAt: now,
                    observedAt: now,
                    stale: false,
                    windows: [],
                    usage: usage,
                    warnings: warnings,
                    error: nil
                )
                return ProbeReport(
                    provider: ProviderCatalog.agy,
                    envelope: envelope,
                    failure: nil,
                    finishedAt: Date(),
                    duration: Date().timeIntervalSince(started)
                )
            }
            let errorMessage = cleanReason.hasPrefix("查询 AGY 用量失败：")
                ? cleanReason
                : SecretRedactor.redact("查询 AGY 用量失败：\(cleanReason)")
            let envelope = ProbeEnvelope(
                provider: ProviderCatalog.agy.id,
                account: ProbeAccount(label: email, plan: plan),
                generatedAt: now,
                observedAt: now,
                stale: false,
                windows: [],
                warnings: NativeProbeSupport.dedupeRedacted(tokenWarnings),
                error: errorMessage
            )
            return ProbeReport(
                provider: ProviderCatalog.agy,
                envelope: envelope,
                failure: errorMessage,
                finishedAt: Date(),
                duration: Date().timeIntervalSince(started)
            )
        }

        if source == "local" {
            let needsProactive = accessToken == nil
                || (creds.expiryEpoch != nil && creds.expiryEpoch! <= now.timeIntervalSince1970 + Self.proactiveRefreshSkewSeconds)
            if needsProactive {
                let (refreshed, refreshErr) = await refreshAndPersistAccessToken(
                    creds: creds,
                    environment: environment,
                    now: now
                )
                if let refreshErr {
                    return failReport(refreshErr)
                }
                accessToken = refreshed?.accessToken
                refreshedOnce = true
            }
        }

        guard var currentToken = accessToken else {
            return failReport("本机 AGY 登录态已过期，请先运行 agy 重新登录后刷新")
        }

        func postWithRetry(url: URL, bodyObj: [String: Any]) async -> (data: [String: Any]?, err: String?, refreshFailed: Bool) {
            if Task.isCancelled { return (nil, "请求超时或中断", false) }
            let (data, err, status) = await postJSON(url: url, accessToken: currentToken, bodyObj: bodyObj, source: source)
            if Task.isCancelled { return (nil, "请求超时或中断", false) }
            if status == 401 && source == "local" && !refreshedOnce {
                let (refreshed, refreshErr) = await refreshAndPersistAccessToken(
                    creds: creds,
                    environment: environment,
                    now: now
                )
                if let refreshErr {
                    return (nil, refreshErr, true)
                }
                if let newToken = refreshed?.accessToken {
                    currentToken = newToken
                    refreshedOnce = true
                    let (retryData, retryErr, _) = await postJSON(url: url, accessToken: currentToken, bodyObj: bodyObj, source: source)
                    return (retryData, retryErr, false)
                }
            }
            return (data, err, false)
        }

        var plan: String?
        if projectID.isEmpty {
            let loadBody: [String: Any] = [
                "metadata": [
                    "ideType": "IDE_UNSPECIFIED",
                    "platform": "PLATFORM_UNSPECIFIED",
                    "pluginType": "GEMINI",
                ],
            ]
            let loadRes = await postWithRetry(url: Self.loadCodeAssistURL, bodyObj: loadBody)
            if let loadErr = loadRes.err {
                return failReport(loadErr)
            }
            if let loadData = loadRes.data {
                projectID = NativeProbeSupport.nonEmptyTrimmed(loadData["cloudaicompanionProject"]) ?? ""
                plan = extractPlan(loadData)
            }
        }

        let quotaReq: [String: Any] = projectID.isEmpty ? [:] : ["project": projectID]
        let summaryRes = await postWithRetry(url: Self.retrieveQuotaSummaryURL, bodyObj: quotaReq)
        if summaryRes.refreshFailed, let err = summaryRes.err {
            return failReport(err, plan: plan)
        }

        let quotaRes = await postWithRetry(url: Self.retrieveQuotaURL, bodyObj: quotaReq)
        if quotaRes.refreshFailed, let err = quotaRes.err {
            return failReport(err, plan: plan)
        }

        if summaryRes.data == nil && quotaRes.data == nil {
            return failReport(summaryRes.err ?? quotaRes.err ?? "未知错误", plan: plan)
        }

        var warnings: [String] = []
        if let summaryErr = summaryRes.err, quotaRes.data != nil {
            warnings.append("AGY 配额汇总接口查询失败（\(summaryErr)），仅使用模型配额数据")
        } else if let quotaErr = quotaRes.err, summaryRes.data != nil {
            warnings.append("AGY 模型配额接口查询失败（\(quotaErr)），仅使用配额汇总数据")
        }

        let buckets = collectBuckets(summaryData: summaryRes.data, quotaData: quotaRes.data)
        let windows = normalizeBuckets(buckets, now: now, warnings: &warnings)
        let envelope = ProbeEnvelope(
            provider: ProviderCatalog.agy.id,
            account: ProbeAccount(label: email, plan: plan),
            generatedAt: now,
            observedAt: now,
            stale: false,
            windows: windows,
            usage: usage,
            warnings: NativeProbeSupport.dedupeRedacted(warnings + tokenWarnings),
            error: nil
        )
        return ProbeReport(
            provider: ProviderCatalog.agy,
            envelope: envelope,
            failure: nil,
            finishedAt: Date(),
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: - 凭据发现（严格白名单、只读、脱敏、有界超时）

    public func discoverOnly(environment: [String: String]) -> AgyCredentialDiscovery {
        let home = NativeProbeSupport.effectiveHomeDirectory(from: environment)
        return resolveCredentialsWithDiscoverySync(environment: environment, home: home).1
    }

    private func resolveEnvAndFilePrefix(
        environment: [String: String],
        home: URL
    ) -> (
        resolved: (Credentials?, AgyCredentialDiscovery)?,
        attempts: [AgySourceAttempt],
        fileAttempt: AgySourceAttempt,
        envEmail: String?,
        envProject: String?
    ) {
        var attempts: [AgySourceAttempt] = []
        let envToken = NativeProbeSupport.nonEmptyTrimmed(environment["AGY_ACCESS_TOKEN"])
        let envEmail = NativeProbeSupport.nonEmptyTrimmed(environment["AGY_ACCOUNT_EMAIL"])
        let envProject = NativeProbeSupport.nonEmptyTrimmed(environment["AGY_PROJECT_ID"])

        if let envToken {
            attempts.append(AgySourceAttempt(source: "env", outcome: "available"))
            let creds = Credentials(
                source: "manual",
                origin: .env,
                email: envEmail,
                accessToken: envToken,
                refreshToken: nil,
                expiryEpoch: nil,
                clientID: nil,
                clientSecret: nil,
                projectID: envProject,
                keychainEnvelope: nil
            )
            let result = (creds, AgyCredentialDiscovery(attempts: attempts, outcome: "available", selectedSource: "env"))
            return (result, attempts, AgySourceAttempt(source: "local_file", outcome: "skipped"), envEmail, envProject)
        }
        attempts.append(AgySourceAttempt(source: "env", outcome: "missing"))

        if NativeProbeSupport.nonEmptyTrimmed(environment["AGY_DISABLE_LOCAL_AUTH"]) == "1" {
            attempts.append(AgySourceAttempt(source: "local_file", outcome: "disabled"))
            attempts.append(AgySourceAttempt(source: "keychain", outcome: "disabled"))
            let result: (Credentials?, AgyCredentialDiscovery) = (nil, AgyCredentialDiscovery(attempts: attempts, outcome: "disabled"))
            return (result, attempts, AgySourceAttempt(source: "local_file", outcome: "disabled"), envEmail, envProject)
        }

        let authURL: URL
        if let customPath = NativeProbeSupport.nonEmptyTrimmed(environment["AGY_AUTH_FILE"]) {
            authURL = URL(fileURLWithPath: customPath)
        } else {
            authURL = home
                .appendingPathComponent(".gemini", isDirectory: true)
                .appendingPathComponent("antigravity-cli", isDirectory: true)
                .appendingPathComponent("auth.json")
        }

        var localCreds: Credentials?
        let fileAttempt: AgySourceAttempt
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: authURL.path, isDirectory: &isDir) {
            fileAttempt = AgySourceAttempt(source: "local_file", outcome: "missing")
        } else if isDir.boolValue {
            fileAttempt = AgySourceAttempt(source: "local_file", outcome: "unreadable")
        } else {
            if let data = try? Data(contentsOf: authURL),
               let rawText = String(data: data, encoding: .utf8) {
                localCreds = decodeKeyringPayload(rawText, environment: environment, origin: .localFile)
                fileAttempt = AgySourceAttempt(
                    source: "local_file",
                    outcome: localCreds != nil ? "available" : "malformed"
                )
            } else {
                fileAttempt = AgySourceAttempt(source: "local_file", outcome: "unreadable")
            }
        }
        attempts.append(fileAttempt)

        if var local = localCreds {
            local.email = envEmail ?? local.email
            local.projectID = envProject
            let result: (Credentials?, AgyCredentialDiscovery) = (
                local,
                AgyCredentialDiscovery(attempts: attempts, outcome: "available", selectedSource: "local_file")
            )
            return (result, attempts, fileAttempt, envEmail, envProject)
        }

        return (nil, attempts, fileAttempt, envEmail, envProject)
    }

    private func finalizeKeychainDiscovery(
        readResult: AgyKeychainReadResult,
        attempts baseAttempts: [AgySourceAttempt],
        fileAttempt: AgySourceAttempt,
        envEmail: String?,
        envProject: String?,
        environment: [String: String]
    ) -> (Credentials?, AgyCredentialDiscovery) {
        var attempts = baseAttempts
        let (keychainCreds, keychainAttempt) = mapKeychainReadResult(readResult, environment: environment)
        attempts.append(keychainAttempt)
        if var kc = keychainCreds {
            kc.email = envEmail ?? kc.email
            kc.projectID = envProject
            return (kc, AgyCredentialDiscovery(attempts: attempts, outcome: "available", selectedSource: "keychain"))
        }

        let overallOutcome: String
        let overallDetail: String?
        if ["denied", "timeout", "malformed", "nonzero", "unreadable"].contains(keychainAttempt.outcome) {
            overallOutcome = keychainAttempt.outcome
            overallDetail = "keychain"
        } else if ["malformed", "unreadable"].contains(fileAttempt.outcome) {
            overallOutcome = fileAttempt.outcome
            overallDetail = "local_file"
        } else if keychainAttempt.outcome == "isolated_home" {
            overallOutcome = "isolated_home"
            overallDetail = "keychain"
        } else {
            overallOutcome = "missing"
            overallDetail = nil
        }

        return (nil, AgyCredentialDiscovery(attempts: attempts, outcome: overallOutcome, detail: overallDetail))
    }

    private func resolveCredentialsWithDiscoverySync(
        environment: [String: String],
        home: URL
    ) -> (Credentials?, AgyCredentialDiscovery) {
        let prefix = resolveEnvAndFilePrefix(environment: environment, home: home)
        if let resolved = prefix.resolved {
            return resolved
        }

        let realHome = realUserHomeOverride ?? NativeProbeSupport.realLoginUserHomeDirectory()
        if NativeProbeSupport.isHomeIsolated(effectiveHome: home, realUserHome: realHome) {
            var attempts = prefix.attempts
            attempts.append(AgySourceAttempt(source: "keychain", outcome: "isolated_home"))
            let outcome = ["malformed", "unreadable"].contains(prefix.fileAttempt.outcome)
                ? prefix.fileAttempt.outcome
                : "isolated_home"
            let detail = ["malformed", "unreadable"].contains(prefix.fileAttempt.outcome)
                ? "local_file"
                : "keychain"
            return (nil, AgyCredentialDiscovery(attempts: attempts, outcome: outcome, detail: detail))
        }

        let readResult = readKeychainBoundedSync(service: Self.keychainService, account: Self.keychainAccount)
        return finalizeKeychainDiscovery(
            readResult: readResult,
            attempts: prefix.attempts,
            fileAttempt: prefix.fileAttempt,
            envEmail: prefix.envEmail,
            envProject: prefix.envProject,
            environment: environment
        )
    }

    private func resolveCredentialsWithDiscoveryAsync(
        environment: [String: String],
        home: URL
    ) async -> (Credentials?, AgyCredentialDiscovery) {
        let prefix = resolveEnvAndFilePrefix(environment: environment, home: home)
        if let resolved = prefix.resolved {
            return resolved
        }

        let realHome = realUserHomeOverride ?? NativeProbeSupport.realLoginUserHomeDirectory()
        if NativeProbeSupport.isHomeIsolated(effectiveHome: home, realUserHome: realHome) {
            var attempts = prefix.attempts
            attempts.append(AgySourceAttempt(source: "keychain", outcome: "isolated_home"))
            let outcome = ["malformed", "unreadable"].contains(prefix.fileAttempt.outcome)
                ? prefix.fileAttempt.outcome
                : "isolated_home"
            let detail = ["malformed", "unreadable"].contains(prefix.fileAttempt.outcome)
                ? "local_file"
                : "keychain"
            return (nil, AgyCredentialDiscovery(attempts: attempts, outcome: outcome, detail: detail))
        }

        let readResult = await readKeychainBoundedAsync(service: Self.keychainService, account: Self.keychainAccount)
        return finalizeKeychainDiscovery(
            readResult: readResult,
            attempts: prefix.attempts,
            fileAttempt: prefix.fileAttempt,
            envEmail: prefix.envEmail,
            envProject: prefix.envProject,
            environment: environment
        )
    }

    private func mapKeychainReadResult(
        _ readResult: AgyKeychainReadResult,
        environment: [String: String]
    ) -> (Credentials?, AgySourceAttempt) {
        switch readResult {
        case .payload(let raw):
            if let creds = decodeKeyringPayload(raw, environment: environment, origin: .keychain) {
                return (creds, AgySourceAttempt(source: "keychain", outcome: "available"))
            }
            return (nil, AgySourceAttempt(source: "keychain", outcome: "malformed"))
        case .missing:
            return (nil, AgySourceAttempt(source: "keychain", outcome: "missing"))
        case .denied:
            return (nil, AgySourceAttempt(source: "keychain", outcome: "denied"))
        case .timeout:
            return (nil, AgySourceAttempt(source: "keychain", outcome: "timeout"))
        case .nonzero:
            return (nil, AgySourceAttempt(source: "keychain", outcome: "nonzero"))
        case .unreadable:
            return (nil, AgySourceAttempt(source: "keychain", outcome: "unreadable"))
        }
    }

    /// 异步有界钥匙串操作通用核心：在独立 GCD 队列执行同步 Security 调用，受限时器与 Task 取消双重约束，
    /// 即使底层钥匙串 IPC 阻塞也绝不阻塞 Swift Concurrency 协作线程池或超过 keychainTimeoutSeconds。
    private func runKeychainBoundedAsync<ResultType: Sendable>(
        timeoutResult: ResultType,
        onBeforeAttachTimer: (@Sendable () -> Void)? = nil,
        operation: @escaping @Sendable () -> ResultType
    ) async -> ResultType {
        if Task.isCancelled { return timeoutResult }
        guard keychainGate.tryEnter() else {
            return timeoutResult
        }

        let gate = keychainGate
        let timeout = keychainTimeoutSeconds
        let cancelBox = LockedBoundedKeychainCancelBox<ResultType>(timeoutValue: timeoutResult)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let once = LockedBoundedKeychainContinuation<ResultType>(continuation)
                guard cancelBox.register(once) else {
                    gate.leave()
                    once.finish(with: timeoutResult)
                    return
                }

                // 先完成定时器配置并原子挂载/激活，再派发阻塞式 Keychain 操作；
                // 若在挂载前已被取消，则安全释放定时器并立即归还单飞门控，不再派发无效调用。
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
                let deadlineNs = Int(min(timeout * 1_000_000_000, Double(Int.max / 2)))
                timer.schedule(deadline: .now() + .nanoseconds(deadlineNs))
                timer.setEventHandler {
                    once.finish(with: timeoutResult)
                }

                onBeforeAttachTimer?()
                guard once.attachTimer(timer) else {
                    gate.leave()
                    return
                }

                DispatchQueue.global(qos: .utility).async {
                    defer { gate.leave() }
                    let result = operation()
                    once.finish(with: result)
                }
            }
        } onCancel: {
            cancelBox.cancel()
        }
    }

    /// 异步有界钥匙串读取（严格限制精确白名单元组）。
    internal func readKeychainBoundedAsync(
        service: String,
        account: String,
        onBeforeAttachTimer: (@Sendable () -> Void)? = nil
    ) async -> AgyKeychainReadResult {
        guard SystemAgyKeychainReader.isAllowedTuple(service: service, account: account) else {
            return .denied
        }
        let reader = keychain
        return await runKeychainBoundedAsync(timeoutResult: .timeout, onBeforeAttachTimer: onBeforeAttachTimer) {
            reader.readGenericPassword(service: service, account: account)
        }
    }

    /// 异步有界钥匙串原位更新（仅允许精确白名单元组 `gemini` / `antigravity`，共享单飞门控与超时保护）。
    internal func updateKeychainBoundedAsync(
        service: String,
        account: String,
        payload: String,
        onBeforeAttachTimer: (@Sendable () -> Void)? = nil
    ) async -> AgyKeychainWriteResult {
        guard SystemAgyKeychainReader.isAllowedTuple(service: service, account: account),
              !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let writer = keychainWriter else {
            return .rejected
        }
        return await runKeychainBoundedAsync(timeoutResult: .timeout, onBeforeAttachTimer: onBeforeAttachTimer) {
            writer.updateGenericPassword(service: service, account: account, payload: payload)
        }
    }

    /// 同步有界钥匙串读取（供 discoverOnly 使用）：同样受 keychainTimeoutSeconds 与单飞门控保护。
    private func readKeychainBoundedSync(service: String, account: String) -> AgyKeychainReadResult {
        guard SystemAgyKeychainReader.isAllowedTuple(service: service, account: account) else {
            return .denied
        }
        guard keychainGate.tryEnter() else {
            return .timeout
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedSyncKeychainResultBox()
        let reader = keychain
        let gate = keychainGate

        DispatchQueue.global(qos: .utility).async {
            defer {
                gate.leave()
                semaphore.signal()
            }
            box.set(reader.readGenericPassword(service: service, account: account))
        }

        let waited = semaphore.wait(timeout: .now() + keychainTimeoutSeconds)
        if waited == .timedOut {
            return .timeout
        }
        return box.get() ?? .timeout
    }

    private func decodeKeyringPayload(
        _ raw: String,
        environment: [String: String],
        origin: CredentialOrigin
    ) -> Credentials? {
        guard let text = NativeProbeSupport.nonEmptyTrimmed(raw) else { return nil }
        let wrappedWithBase64: Bool
        let jsonData: Data
        if text.hasPrefix(Self.goKeyringBase64Prefix) {
            wrappedWithBase64 = true
            let b64 = String(text.dropFirst(Self.goKeyringBase64Prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let decoded = Data(base64Encoded: b64) else { return nil }
            jsonData = decoded
        } else {
            wrappedWithBase64 = false
            jsonData = Data(text.utf8)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData),
              let data = obj as? [String: Any] else {
            return nil
        }

        let nestedTokenObj = data["token"] as? [String: Any]
        let tokenObj = nestedTokenObj ?? data
        let accessToken = NativeProbeSupport.nonEmptyTrimmed(tokenObj["access_token"])
        let refreshToken = NativeProbeSupport.nonEmptyTrimmed(tokenObj["refresh_token"])
        guard accessToken != nil || refreshToken != nil else { return nil }

        let expiryEpoch = Self.extractExpiryEpoch(tokenObj: tokenObj, rootObj: data, hasNestedToken: nestedTokenObj != nil)
        var email = NativeProbeSupport.nonEmptyTrimmed(data["id_token_email"])
            ?? NativeProbeSupport.nonEmptyTrimmed(data["email"])
        if email == nil {
            let claims = NativeProbeSupport.decodeJWTPayload(tokenObj["id_token"] ?? data["id_token"])
            email = NativeProbeSupport.nonEmptyTrimmed(claims?["email"])
        }

        // 仅允许 AGY 自身的 OAuth client，绝不借用 GEMINI_OAUTH_CLIENT_*。
        let clientID = NativeProbeSupport.nonEmptyTrimmed(data["client_id"])
            ?? NativeProbeSupport.nonEmptyTrimmed(tokenObj["client_id"])
            ?? NativeProbeSupport.nonEmptyTrimmed(environment["AGY_OAUTH_CLIENT_ID"])
        let clientSecret = NativeProbeSupport.nonEmptyTrimmed(data["client_secret"])
            ?? NativeProbeSupport.nonEmptyTrimmed(tokenObj["client_secret"])
            ?? NativeProbeSupport.nonEmptyTrimmed(environment["AGY_OAUTH_CLIENT_SECRET"])

        let envelope: KeychainPayloadEnvelope? = origin == .keychain
            ? KeychainPayloadEnvelope(wrappedWithGoKeyringBase64: wrappedWithBase64, rawJSONData: jsonData)
            : nil

        return Credentials(
            source: "local",
            origin: origin,
            email: email,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiryEpoch: expiryEpoch,
            clientID: clientID,
            clientSecret: clientSecret,
            projectID: nil,
            keychainEnvelope: envelope
        )
    }

    private static func parseAgyExpiryEpoch(_ value: Any?, allowZeroAsExpired: Bool) -> TimeInterval? {
        if let num = NativeProbeSupport.finiteDouble(value) {
            if num == 0 {
                return allowZeroAsExpired ? 0.0 : nil
            }
            guard num > 0 else { return nil }
            let epoch = num > 1e11 ? num / 1000.0 : num
            return epoch.isFinite ? epoch : nil
        }
        guard let str = NativeProbeSupport.nonEmptyTrimmed(value) else { return nil }
        if let date = ProbeDate.parse(str) {
            return date.timeIntervalSince1970
        }
        // 兼容 Go time.RFC3339Nano（>3 位小数秒，例如 2026-11-22T07:30:00.123456789Z）
        if let normalized = normalizeSubMillisecondRFC3339(str),
           let date = ProbeDate.parse(normalized) {
            return date.timeIntervalSince1970
        }
        return nil
    }

    private static func normalizeSubMillisecondRFC3339(_ raw: String) -> String? {
        guard let dotIdx = raw.firstIndex(of: ".") else { return nil }
        let afterDot = raw.index(after: dotIdx)
        var fracEnd = afterDot
        while fracEnd < raw.endIndex && raw[fracEnd].isASCII && raw[fracEnd].isNumber {
            fracEnd = raw.index(after: fracEnd)
        }
        let digitCount = raw.distance(from: afterDot, to: fracEnd)
        guard digitCount > 3, fracEnd < raw.endIndex else { return nil }
        let suffix = raw[fracEnd...]
        guard suffix.hasPrefix("Z") || suffix.hasPrefix("z") || suffix.hasPrefix("+") || suffix.hasPrefix("-") else {
            return nil
        }
        let prefix = raw[..<afterDot]
        let millis = raw[afterDot..<raw.index(afterDot, offsetBy: 3)]
        return "\(prefix)\(millis)\(suffix)"
    }

    private static func extractExpiryEpoch(
        tokenObj: [String: Any],
        rootObj: [String: Any],
        hasNestedToken: Bool
    ) -> TimeInterval? {
        var candidates: [TimeInterval] = []
        for key in supportedExpiryKeys {
            if let epoch = parseAgyExpiryEpoch(tokenObj[key], allowZeroAsExpired: true) {
                candidates.append(epoch)
            }
        }
        if candidates.isEmpty && hasNestedToken {
            for key in supportedExpiryKeys {
                if let epoch = parseAgyExpiryEpoch(rootObj[key], allowZeroAsExpired: true) {
                    candidates.append(epoch)
                }
            }
        }
        return candidates.min()
    }

    private static func formatRFC3339UTC(epoch: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: epoch.rounded()))
    }

    private static func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }

    private static func isNumericBoolean(_ value: Any) -> Bool {
        if value is Bool { return true }
        if let num = value as? NSNumber {
            return CFGetTypeID(num) == CFBooleanGetTypeID()
        }
        return false
    }

    private static func encodedExpiryValue(
        matchingExisting existing: Any?,
        key: String,
        newExpiryEpoch: TimeInterval
    ) -> Any {
        let roundedSeconds = Int64(newExpiryEpoch.rounded())
        let roundedMillis = Int64((newExpiryEpoch * 1000.0).rounded())

        if let str = existing as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if let num = Double(trimmed), num.isFinite {
                return num > 1e11 ? String(roundedMillis) : String(roundedSeconds)
            }
            return formatRFC3339UTC(epoch: newExpiryEpoch)
        }
        if let existing, !isNumericBoolean(existing), let num = existing as? NSNumber {
            let val = num.doubleValue
            if val.isFinite && val > 1e11 {
                return NSNumber(value: roundedMillis)
            }
            if val.isFinite && val > 0 {
                return NSNumber(value: roundedSeconds)
            }
            // 原值为 0 等边界：expiry_date 保持毫秒纪元，其余保持秒纪元
            return key == "expiry_date" ? NSNumber(value: roundedMillis) : NSNumber(value: roundedSeconds)
        }
        return key == "expiry_date"
            ? NSNumber(value: roundedMillis)
            : formatRFC3339UTC(epoch: newExpiryEpoch)
    }

    private func discoveryWarning(_ discovery: AgyCredentialDiscovery) -> String {
        switch discovery.outcome {
        case "disabled": return Self.authDisabledWarning
        case "isolated_home": return Self.authIsolatedHomeWarning
        case "denied": return Self.authKeychainDeniedWarning
        case "timeout": return Self.authKeychainTimeoutWarning
        case "nonzero": return Self.authKeychainNonzeroWarning
        case "malformed":
            return discovery.detail == "local_file" ? Self.authFileMalformedWarning : Self.authKeychainMalformedWarning
        case "unreadable":
            return discovery.detail == "local_file" ? Self.authFileUnreadableWarning : Self.authKeychainUnreadableWarning
        default:
            return Self.authRequiredWarning
        }
    }

    // MARK: - 网络刷新与钥匙串原子写回

    private func httpErrorReason(code: Int, source: String, oauth: Bool = false) -> String {
        if oauth && [400, 401, 403].contains(code) {
            return "本机 AGY 登录态已过期或刷新失败（HTTP \(code)），请先运行 agy 重新登录后刷新"
        }
        let prefix = oauth ? "刷新本机 AGY 登录态失败：" : ""
        if [301, 302, 303, 307, 308].contains(code) {
            return "\(prefix)接口返回重定向（HTTP \(code)），已按安全策略拒绝跟随"
        }
        if code == 401 {
            if source == "local" {
                return "本机 AGY 登录态已过期或认证被拒（HTTP 401），请先运行 agy 重新登录后刷新"
            }
            return "AGY 凭据无效或已过期（HTTP 401），请更新 AGY 凭据后刷新"
        }
        if code == 403 {
            if source == "local" {
                return "AGY 服务端拒绝访问（HTTP 403），可能是项目权限、策略或配额资格受限，请检查 AGY 账号权限或运行 agy 重新登录后刷新"
            }
            return "AGY 服务端拒绝访问（HTTP 403），可能是项目权限、策略或凭据权限受限，请检查配置或更新 AGY 凭据后刷新"
        }
        if code == 429 {
            return "\(prefix)请求被限流（HTTP 429），请稍后重试"
        }
        if (500..<600).contains(code) {
            return "\(prefix)服务暂时不可用（HTTP \(code)），请稍后重试"
        }
        return "\(prefix)HTTP \(code)"
    }

    private func postJSON(
        url: URL,
        accessToken: String,
        bodyObj: [String: Any],
        source: String
    ) async -> ([String: Any]?, String?, Int?) {
        guard let rawBody = try? JSONSerialization.data(withJSONObject: bodyObj) else {
            return (nil, "请求体编码失败", nil)
        }
        let req = NativeHTTPRequest(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": Self.agyUserAgent,
            ],
            body: rawBody,
            timeout: NativeProbeSupport.httpTimeoutSeconds,
            expectedHost: Self.officialHost,
            maxBytes: NativeProbeSupport.httpMaxBytes
        )
        return await executePinnedJSON(
            req,
            errorPrefix: "",
            httpErrorFormatter: { code in httpErrorReason(code: code, source: source) }
        )
    }

    private func refreshAndPersistAccessToken(
        creds: Credentials,
        environment: [String: String],
        now: Date
    ) async -> (RefreshedOAuthToken?, String?) {
        let (refreshed, refreshErr) = await refreshAccessToken(creds: creds, now: now)
        if let refreshErr {
            return (nil, refreshErr)
        }
        guard let refreshed else {
            return (nil, "刷新本机 AGY 登录态失败：接口未返回有效访问令牌")
        }

        // 仅当凭据来自精确钥匙串条目 `(gemini, antigravity)` 时才执行原子原位写回；
        // 本地 auth.json / $AGY_AUTH_FILE / 环境变量覆盖绝不写盘、绝不写入钥匙串。
        guard creds.origin == .keychain else {
            return (refreshed, nil)
        }
        if Task.isCancelled {
            return (nil, "刷新本机 AGY 登录态失败：请求超时或中断")
        }
        guard let envelope = creds.keychainEnvelope,
              let updatedPayload = buildUpdatedKeychainPayload(
                  envelope: envelope,
                  refreshed: refreshed,
                  environment: environment,
                  now: now
              ) else {
            return (nil, Self.keychainWriteRejectedError)
        }

        let writeResult = await updateKeychainBoundedAsync(
            service: Self.keychainService,
            account: Self.keychainAccount,
            payload: updatedPayload
        )
        switch writeResult {
        case .updated:
            return (refreshed, nil)
        case .missing:
            return (nil, Self.keychainWriteMissingError)
        case .denied:
            return (nil, Self.keychainWriteDeniedError)
        case .timeout:
            return (nil, Self.keychainWriteTimeoutError)
        case .nonzero:
            return (nil, Self.keychainWriteNonzeroError)
        case .rejected:
            return (nil, Self.keychainWriteRejectedError)
        }
    }

    private func refreshAccessToken(creds: Credentials, now: Date) async -> (RefreshedOAuthToken?, String?) {
        guard let refreshToken = creds.refreshToken,
              let clientID = creds.clientID else {
            return (nil, "本机 AGY 登录态已过期，请先运行 agy 重新登录后刷新")
        }
        var fields: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ]
        if let secret = creds.clientSecret {
            fields.append(("client_secret", secret))
        }
        let req = NativeHTTPRequest(
            url: Self.oauthTokenURL,
            method: "POST",
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            ],
            body: NativeProbeSupport.formURLEncoded(fields),
            timeout: NativeProbeSupport.httpTimeoutSeconds,
            expectedHost: Self.oauthTokenHost,
            maxBytes: NativeProbeSupport.httpMaxBytes
        )
        let (data, err, _) = await executePinnedJSON(
            req,
            errorPrefix: "刷新本机 AGY 登录态失败：",
            httpErrorFormatter: { code in httpErrorReason(code: code, source: "local", oauth: true) }
        )
        if let err { return (nil, err) }
        guard let data else {
            return (nil, "刷新本机 AGY 登录态失败：接口返回格式异常")
        }
        return parseAndVerifyRefreshResponse(data, now: now)
    }

    private func parseAndVerifyRefreshResponse(
        _ data: [String: Any],
        now: Date
    ) -> (RefreshedOAuthToken?, String?) {
        guard let accessToken = NativeProbeSupport.nonEmptyTrimmed(data["access_token"]),
              !Self.containsControlCharacters(accessToken) else {
            return (nil, "刷新本机 AGY 登录态失败：接口未返回有效访问令牌")
        }

        let nowEpoch = now.timeIntervalSince1970
        let maxExpiryEpoch = nowEpoch + TimeInterval(Self.maxRefreshExpiresInSeconds)

        var parsedExpiresIn: Int?
        if let rawExpiresIn = data["expires_in"], !(rawExpiresIn is NSNull) {
            guard let seconds = NativeProbeSupport.checkedPositiveIntSeconds(rawExpiresIn, multiplier: 1.0),
                  seconds <= Self.maxRefreshExpiresInSeconds else {
                return (nil, "刷新本机 AGY 登录态失败：接口返回的令牌过期元数据无效")
            }
            parsedExpiresIn = seconds
        }

        var explicitExpiries: [TimeInterval] = []
        for key in Self.supportedExpiryKeys {
            guard let rawVal = data[key], !(rawVal is NSNull) else { continue }
            guard let epoch = Self.parseAgyExpiryEpoch(rawVal, allowZeroAsExpired: false),
                  epoch.isFinite,
                  epoch > nowEpoch,
                  epoch <= maxExpiryEpoch else {
                return (nil, "刷新本机 AGY 登录态失败：接口返回的令牌过期元数据无效")
            }
            explicitExpiries.append(epoch)
        }

        let finalExpiryEpoch: TimeInterval
        let finalExpiresInSeconds: Int
        if let expiresIn = parsedExpiresIn {
            let computedEpoch = nowEpoch + TimeInterval(expiresIn)
            let chosenEpoch = explicitExpiries.min().map { min(computedEpoch, $0) } ?? computedEpoch
            guard chosenEpoch.isFinite, chosenEpoch > nowEpoch else {
                return (nil, "刷新本机 AGY 登录态失败：接口返回的令牌过期元数据无效")
            }
            finalExpiryEpoch = chosenEpoch
            finalExpiresInSeconds = max(
                1,
                NativeProbeSupport.checkedInt(fromTruncating: (chosenEpoch - nowEpoch).rounded()) ?? expiresIn
            )
        } else if let explicitMin = explicitExpiries.min() {
            let delta = explicitMin - nowEpoch
            guard delta >= 1.0,
                  let derivedSeconds = NativeProbeSupport.checkedInt(fromTruncating: delta),
                  derivedSeconds >= 1,
                  derivedSeconds <= Self.maxRefreshExpiresInSeconds else {
                return (nil, "刷新本机 AGY 登录态失败：接口返回的令牌过期元数据无效")
            }
            finalExpiryEpoch = explicitMin
            finalExpiresInSeconds = derivedSeconds
        } else {
            return (nil, "刷新本机 AGY 登录态失败：接口未返回有效的令牌过期元数据")
        }

        var rotatedRefreshToken: String?
        if let rawRefresh = data["refresh_token"], !(rawRefresh is NSNull) {
            guard let rt = NativeProbeSupport.nonEmptyTrimmed(rawRefresh),
                  !Self.containsControlCharacters(rt) else {
                return (nil, "刷新本机 AGY 登录态失败：接口返回的刷新令牌格式异常")
            }
            rotatedRefreshToken = rt
        }

        let tokenType = NativeProbeSupport.nonEmptyTrimmed(data["token_type"])
        let idToken = NativeProbeSupport.nonEmptyTrimmed(data["id_token"])
        let scope = NativeProbeSupport.nonEmptyTrimmed(data["scope"])

        return (
            RefreshedOAuthToken(
                accessToken: accessToken,
                refreshToken: rotatedRefreshToken,
                tokenType: tokenType,
                idToken: idToken,
                scope: scope,
                expiresInSeconds: finalExpiresInSeconds,
                expiryEpoch: finalExpiryEpoch
            ),
            nil
        )
    }

    private func buildUpdatedKeychainPayload(
        envelope: KeychainPayloadEnvelope,
        refreshed: RefreshedOAuthToken,
        environment: [String: String],
        now: Date
    ) -> String? {
        guard let parsed = try? JSONSerialization.jsonObject(with: envelope.rawJSONData),
              var root = parsed as? [String: Any] else {
            return nil
        }

        let isNestedToken = (root["token"] as? [String: Any]) != nil
        var target = (root["token"] as? [String: Any]) ?? root
        let hadRefreshToken = NativeProbeSupport.nonEmptyTrimmed(target["refresh_token"]) != nil

        target["access_token"] = refreshed.accessToken
        if let rotatedRefresh = refreshed.refreshToken {
            target["refresh_token"] = rotatedRefresh
        }
        if let tokenType = refreshed.tokenType {
            target["token_type"] = tokenType
        }
        if let idToken = refreshed.idToken {
            target["id_token"] = idToken
        }
        if let scope = refreshed.scope {
            target["scope"] = scope
        }
        if target["expires_in"] != nil {
            target["expires_in"] = refreshed.expiresInSeconds
        }

        var updatedAnyExpiry = false
        for key in Self.supportedExpiryKeys {
            if let existing = target[key], !(existing is NSNull) {
                target[key] = Self.encodedExpiryValue(
                    matchingExisting: existing,
                    key: key,
                    newExpiryEpoch: refreshed.expiryEpoch
                )
                updatedAnyExpiry = true
            }
        }
        if isNestedToken {
            for key in Self.supportedExpiryKeys {
                if let existing = root[key], !(existing is NSNull) {
                    root[key] = Self.encodedExpiryValue(
                        matchingExisting: existing,
                        key: key,
                        newExpiryEpoch: refreshed.expiryEpoch
                    )
                    updatedAnyExpiry = true
                }
            }
        }
        if !updatedAnyExpiry {
            if isNestedToken {
                target["expiry"] = Self.formatRFC3339UTC(epoch: refreshed.expiryEpoch)
                target["expires_in"] = refreshed.expiresInSeconds
            } else {
                target["expiry_date"] = NSNumber(value: Int64((refreshed.expiryEpoch * 1000.0).rounded()))
            }
        }

        if isNestedToken {
            root["token"] = target
        } else {
            root = target
        }

        guard JSONSerialization.isValidJSONObject(root),
              let encodedData = try? JSONSerialization.data(
                  withJSONObject: root,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              !encodedData.isEmpty else {
            return nil
        }

        let candidate: String
        if envelope.wrappedWithGoKeyringBase64 {
            candidate = Self.goKeyringBase64Prefix + encodedData.base64EncodedString()
        } else {
            guard let jsonText = String(data: encodedData, encoding: .utf8), !jsonText.isEmpty else {
                return nil
            }
            candidate = jsonText
        }

        // 写回前自检（fail-closed）：确保新载荷可完整回读，令牌、刷新令牌与未来过期时间全部一致。
        guard let verified = decodeKeyringPayload(candidate, environment: environment, origin: .keychain),
              verified.accessToken == refreshed.accessToken,
              let verifiedExpiry = verified.expiryEpoch,
              verifiedExpiry > now.timeIntervalSince1970 else {
            return nil
        }
        if let rotatedRefresh = refreshed.refreshToken {
            guard verified.refreshToken == rotatedRefresh else { return nil }
        } else if hadRefreshToken {
            guard verified.refreshToken != nil else { return nil }
        }

        return candidate
    }

    private func executePinnedJSON(
        _ request: NativeHTTPRequest,
        errorPrefix: String,
        httpErrorFormatter: (Int) -> String
    ) async -> ([String: Any]?, String?, Int?) {
        let response: NativeHTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as NativeHTTPError {
            switch error {
            case .nonOfficialURL:
                return (nil, "\(errorPrefix)响应最终地址不是官方域名，已拒绝使用", nil)
            case .redirected(let code):
                return (nil, SecretRedactor.redact(httpErrorFormatter(code)), code)
            case .responseTooLarge(let declared):
                if let declared {
                    return (nil, "\(errorPrefix)响应体过大（\(declared) 字节），已拒绝读取", nil)
                }
                return (nil, "\(errorPrefix)响应体超过 1MB 上限，已拒绝读取", nil)
            case .timedOut:
                return (nil, "\(errorPrefix)请求超时或中断", nil)
            case .network(let reason):
                return (nil, SecretRedactor.redact("\(errorPrefix)网络不可用（\(reason)）"), nil)
            }
        } catch {
            return (nil, SecretRedactor.redact("\(errorPrefix)\(error.localizedDescription)"), nil)
        }

        if let finalURL = response.finalURL,
           !NativeProbeSupport.isPinnedHTTPSURL(finalURL, expectedHost: request.expectedHost) {
            return (nil, "\(errorPrefix)响应最终地址不是官方域名，已拒绝使用", nil)
        }
        if response.statusCode != 200 {
            return (nil, SecretRedactor.redact(httpErrorFormatter(response.statusCode)), response.statusCode)
        }
        if response.body.count > request.maxBytes {
            return (nil, "\(errorPrefix)响应体超过 1MB 上限，已拒绝读取", nil)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: response.body) else {
            return (nil, "\(errorPrefix)接口返回不是合法 JSON", nil)
        }
        guard let dict = obj as? [String: Any] else {
            return (nil, "\(errorPrefix)接口返回格式异常", nil)
        }
        return (dict, nil, 200)
    }

    // MARK: - 窗口归类与保守聚合

    private func extractPlan(_ loadData: [String: Any]) -> String? {
        for key in ["paidTier", "currentTier"] {
            if let tier = loadData[key] as? [String: Any] {
                if let plan = NativeProbeSupport.nonEmptyTrimmed(tier["name"]) ?? NativeProbeSupport.nonEmptyTrimmed(tier["id"]) {
                    return plan
                }
            } else if let plan = NativeProbeSupport.nonEmptyTrimmed(loadData[key]) {
                return plan
            }
        }
        return nil
    }

    private func collectBuckets(summaryData: [String: Any]?, quotaData: [String: Any]?) -> [[String: Any]] {
        var collected: [[String: Any]] = []
        if let groups = summaryData?["groups"] as? [[String: Any]] {
            for group in groups {
                if let buckets = group["buckets"] as? [[String: Any]] {
                    collected.append(contentsOf: buckets)
                }
            }
        }
        if let buckets = quotaData?["buckets"] as? [[String: Any]] {
            collected.append(contentsOf: buckets)
        }
        return collected
    }

    private func classifyWindow(_ bucket: [String: Any], resetsEpoch: TimeInterval?, nowEpoch: TimeInterval) -> String? {
        let keys = [
            "window", "bucketId", "windowDuration", "quotaDuration",
            "duration", "period", "windowSeconds", "window_seconds", "id",
        ]
        for key in keys {
            guard let raw = bucket[key] else { continue }
            if let str = raw as? String {
                let norm = str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["5h", "five_hour", "5 小时", "5小时"].contains(norm) || norm.hasSuffix("-5h") || norm.hasSuffix("_5h") {
                    return "5h"
                }
                if ["weekly", "7d", "7 天", "7天"].contains(norm) || norm.hasSuffix("-weekly") || norm.hasSuffix("_weekly") || norm.hasSuffix("-7d") || norm.hasSuffix("_7d") {
                    return "7d"
                }
            }
            if let secs = NativeProbeSupport.parseDurationSeconds(raw) {
                if (14_400...21_600).contains(secs) { return "5h" }
                if (518_400...691_200).contains(secs) { return "7d" }
            }
        }
        if let resetsEpoch {
            return (resetsEpoch - nowEpoch) <= 24 * 3_600 ? "5h" : "7d"
        }
        return nil
    }

    private func usedPercent(from bucket: [String: Any], label: String, warnings: inout [String]) -> Double? {
        if let rawRem = bucket["remainingFraction"], !(rawRem is NSNull) {
            guard let rem = NativeProbeSupport.finiteDouble(rawRem), rem >= 0.0, rem <= 1.0 else {
                warnings.append("\(label)的 remainingFraction 数值异常，已置空")
                return nil
            }
            return ((1.0 - rem) * 100.0 * 100.0).rounded() / 100.0
        }
        for key in ["usedPercent", "used_percent"] {
            if let rawPct = bucket[key], !(rawPct is NSNull) {
                guard let pct = NativeProbeSupport.finiteDouble(rawPct), pct >= 0.0, pct <= 100.0 else {
                    warnings.append("\(label)的 used_percent 数值异常，已置空")
                    return nil
                }
                return (pct * 100.0).rounded() / 100.0
            }
        }
        return nil
    }

    private func normalizeBuckets(_ buckets: [[String: Any]], now: Date, warnings: inout [String]) -> [ProbeWindow] {
        struct Candidate {
            let usedPercent: Double?
            let resetsEpoch: TimeInterval?
        }
        let nowEpoch = now.timeIntervalSince1970
        let specs: [(id: String, label: String, seconds: Int)] = [
            ("5h", "5 小时", 18_000),
            ("7d", "7 天", 604_800),
        ]
        var grouped: [String: [Candidate]] = ["5h": [], "7d": []]

        for item in buckets {
            let resetRaw = NativeProbeSupport.nonEmptyTrimmed(item["resetTime"])
                ?? NativeProbeSupport.nonEmptyTrimmed(item["resets_at"])
            let resetsEpoch = resetRaw.flatMap(ProbeDate.parse)?.timeIntervalSince1970
            guard let windowID = classifyWindow(item, resetsEpoch: resetsEpoch, nowEpoch: nowEpoch),
                  let spec = specs.first(where: { $0.id == windowID }) else {
                continue
            }
            let used = usedPercent(from: item, label: spec.label, warnings: &warnings)
            grouped[windowID, default: []].append(Candidate(usedPercent: used, resetsEpoch: resetsEpoch))
        }

        var windows: [ProbeWindow] = []
        for spec in specs {
            let candidates = grouped[spec.id] ?? []
            guard !candidates.isEmpty else { continue }
            let valid = candidates.filter { $0.usedPercent != nil }
            let chosen: Candidate
            if !valid.isEmpty {
                chosen = valid.max { a, b in
                    let pa = a.usedPercent ?? -1
                    let pb = b.usedPercent ?? -1
                    if pa != pb { return pa < pb }
                    let ra = a.resetsEpoch ?? Double.infinity
                    let rb = b.resetsEpoch ?? Double.infinity
                    return ra > rb
                }!
            } else {
                chosen = candidates.min { a, b in
                    (a.resetsEpoch ?? Double.infinity) < (b.resetsEpoch ?? Double.infinity)
                }!
            }

            let expired = chosen.resetsEpoch.map { $0 < nowEpoch } ?? false
            if expired, let resetsEpoch = chosen.resetsEpoch {
                warnings.append("\(spec.label)窗口已于 \(NativeProbeSupport.humanAge(seconds: nowEpoch - resetsEpoch))重置")
            }
            windows.append(
                ProbeWindow(
                    id: spec.id,
                    label: spec.label,
                    usedPercent: chosen.usedPercent,
                    windowSeconds: spec.seconds,
                    resetsAt: chosen.resetsEpoch.map { Date(timeIntervalSince1970: $0) },
                    expired: expired,
                    basis: "server"
                )
            )
        }

        if windows.isEmpty {
            warnings.append("AGY 接口未返回 5 小时或 7 天配额窗口")
        } else {
            let present = Set(windows.map(\.id))
            if !present.contains("5h") { warnings.append("AGY 接口未返回 5 小时配额窗口") }
            if !present.contains("7d") { warnings.append("AGY 接口未返回 7 天配额窗口") }
        }
        return windows
    }

    // MARK: - 本地今日 tokens 统计

    private enum TokenRecordParseResult {
        case ignored
        case valid(Int)
        case invalid
        case overflow
    }

    private func findTodayTokens(home: URL, now: Date) -> (Int?, [String]) {
        if Task.isCancelled { return (nil, []) }
        let brainDirs = [
            home.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true),
            home.appendingPathComponent(".gemini/antigravity/brain", isDirectory: true),
        ]
        let fm = FileManager.default
        var seenPaths: Set<String> = []
        var candidates: [(mtime: Date, url: URL)] = []

        for base in brainDirs {
            if Task.isCancelled { return (nil, []) }
            guard let children = try? fm.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for convDir in children {
                if Task.isCancelled { return (nil, []) }
                let transcript = convDir.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: transcript.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let resolved = transcript.resolvingSymlinksInPath().path
                guard seenPaths.insert(resolved).inserted else { continue }
                if let attrs = try? fm.attributesOfItem(atPath: transcript.path),
                   let mtime = attrs[.modificationDate] as? Date {
                    candidates.append((mtime, transcript))
                }
            }
        }

        guard !candidates.isEmpty else { return (nil, []) }
        candidates.sort { $0.mtime > $1.mtime }

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        var total = 0
        var found = false
        var overflowed = false
        var invalidCount = 0
        var truncatedCount = 0

        for item in candidates.prefix(Self.todayTokenScanFiles) {
            if Task.isCancelled { break }
            if calendar.startOfDay(for: item.mtime) < todayStart {
                break
            }
            guard let (lines, truncated) = try? NativeProbeSupport.readLinesReverse(
                at: item.url,
                maxBytes: maxScanBytes
            ) else { continue }
            if truncated { truncatedCount += 1 }
            for raw in lines {
                if Task.isCancelled { break }
                switch todayTokenRecord(raw, todayStart: todayStart, calendar: calendar) {
                case .ignored:
                    continue
                case .invalid:
                    invalidCount += 1
                case .overflow:
                    overflowed = true
                case .valid(let val):
                    found = true
                    if !overflowed {
                        if let next = NativeProbeSupport.checkedAdd(total, val) {
                            total = next
                        } else {
                            overflowed = true
                        }
                    }
                }
            }
        }

        var warnings: [String] = []
        if truncatedCount > 0 {
            warnings.append("今日 tokens 仅扫描了 \(truncatedCount) 个大日志的末尾 4MB，统计可能不完整")
        }
        if invalidCount > 0 {
            warnings.append("今日 tokens 存在 \(invalidCount) 条异常或溢出数值记录，已跳过")
        }
        if overflowed {
            warnings.append("今日 tokens 累计值超出整数上限，已置空")
            return (nil, warnings)
        }
        return (found ? total : nil, warnings)
    }

    private func todayTokenRecord(_ raw: Data, todayStart: Date, calendar: Calendar) -> TokenRecordParseResult {
        guard let obj = try? JSONSerialization.jsonObject(with: raw),
              let record = obj as? [String: Any],
              (record["type"] as? String) == "PLANNER_RESPONSE",
              let createdStr = NativeProbeSupport.nonEmptyTrimmed(record["created_at"]),
              let createdDate = ProbeDate.parse(createdStr),
              calendar.startOfDay(for: createdDate) == todayStart else {
            return .ignored
        }
        var subtotal = 0
        var hasField = false
        for key in ["input_tokens", "output_tokens", "cache_read_tokens"] {
            guard let rawVal = record[key], !(rawVal is NSNull) else { continue }
            guard let val = NativeProbeSupport.nonNegativeInt(rawVal) else {
                return .invalid
            }
            guard let next = NativeProbeSupport.checkedAdd(subtotal, val) else {
                return .overflow
            }
            subtotal = next
            hasField = true
        }
        return hasField ? .valid(subtotal) : .ignored
    }
}

private final class LockedSyncKeychainResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: AgyKeychainReadResult?

    func set(_ value: AgyKeychainReadResult) {
        lock.withLock { result = value }
    }

    func get() -> AgyKeychainReadResult? {
        lock.withLock { result }
    }
}
