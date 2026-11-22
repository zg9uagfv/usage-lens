import Foundation

// MARK: - 原生 Swift Gemini 探针

public struct GeminiNativeProbe: Sendable {
    public static let officialHost = "cloudcode-pa.googleapis.com"
    public static let loadCodeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    public static let retrieveQuotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    public static let oauthTokenHost = "oauth2.googleapis.com"
    public static let oauthTokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    public static let proactiveRefreshSkewSeconds: TimeInterval = 60.0

    public static let accountRequiredWarning = "请先在配置中提供 Gemini 账号以查看 5 小时与 7 天用量"
    public static let invalidProjectNumberError =
        "Gemini 项目配置无效：请使用 Google Cloud 项目 ID（字符串标识），不要填写纯数字项目编号"
    public static let missingProjectError =
        "未能从 Gemini 服务端发现可用的 Google Cloud 项目，请配置 GEMINI_PROJECT_ID 或 GOOGLE_CLOUD_PROJECT（并确认已启用 Gemini for Cloud API 与相应 IAM 权限）后重试"
    public static let projectEnvPrecedence = [
        "GEMINI_PROJECT_ID",
        "GOOGLE_CLOUD_PROJECT",
        "GOOGLE_CLOUD_PROJECT_ID",
    ]

    private struct Credentials {
        var source: String // "manual" or "local"
        var email: String?
        var accessToken: String?
        var refreshToken: String?
        var expiryEpoch: TimeInterval?
        var clientID: String?
        var clientSecret: String?
        var projectID: String?
        var projectError: String?
    }

    private let transport: any NativeHTTPTransport

    public init(transport: any NativeHTTPTransport = PinnedURLSessionTransport()) {
        self.transport = transport
    }

    public static func isNumericProjectNumber(_ value: String) -> Bool {
        let candidate = value.hasPrefix("projects/") ? String(value.dropFirst("projects/".count)) : value
        return !candidate.isEmpty && candidate.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.decimalDigits.contains($0) }
    }

    public static func resolveProjectContext(environment: [String: String]) -> (projectID: String?, error: String?) {
        for key in projectEnvPrecedence {
            guard let trimmed = NativeProbeSupport.nonEmptyTrimmed(environment[key]) else {
                continue
            }
            if isNumericProjectNumber(trimmed) {
                return (nil, invalidProjectNumberError)
            }
            return (trimmed, nil)
        }
        return (nil, nil)
    }

    public func run(
        environment: [String: String],
        now: Date = Date()
    ) async -> ProbeReport {
        let started = Date()
        let home = NativeProbeSupport.effectiveHomeDirectory(from: environment)

        // 零网络账号门控：无 OAuth 凭据时不发起任何网络请求，项目别名与 API Key 均不构成账号认证。
        guard let creds = resolveCredentials(environment: environment, home: home) else {
            let envelope = ProbeEnvelope(
                provider: ProviderCatalog.gemini.id,
                account: ProbeAccount(label: nil, plan: nil),
                generatedAt: now,
                observedAt: now,
                stale: false,
                windows: [],
                warnings: [Self.accountRequiredWarning],
                error: nil
            )
            return ProbeReport(
                provider: ProviderCatalog.gemini,
                envelope: envelope,
                failure: nil,
                finishedAt: Date(),
                duration: Date().timeIntervalSince(started)
            )
        }

        let source = creds.source
        let email = creds.email
        var accessToken = creds.accessToken
        let selectedProject = creds.projectID
        var refreshedOnce = false

        func errorReport(_ message: String, plan: String? = nil) -> ProbeReport {
            let clean = SecretRedactor.redact(message)
            let envelope = ProbeEnvelope(
                provider: ProviderCatalog.gemini.id,
                account: ProbeAccount(label: email, plan: plan),
                generatedAt: now,
                observedAt: now,
                stale: false,
                windows: [],
                warnings: [],
                error: clean
            )
            return ProbeReport(
                provider: ProviderCatalog.gemini,
                envelope: envelope,
                failure: clean,
                finishedAt: Date(),
                duration: Date().timeIntervalSince(started)
            )
        }

        if let projectErr = creds.projectError {
            return errorReport(projectErr)
        }

        if source == "local" {
            let needsProactive = accessToken == nil
                || (creds.expiryEpoch != nil && creds.expiryEpoch! <= now.timeIntervalSince1970 + Self.proactiveRefreshSkewSeconds)
            if needsProactive {
                let (newToken, refreshErr) = await refreshAccessToken(creds: creds)
                if let refreshErr {
                    return errorReport(refreshErr)
                }
                accessToken = newToken
                refreshedOnce = true
            }
        }

        guard var currentToken = accessToken else {
            return errorReport("本机 Gemini 登录态已过期且缺少刷新凭据，请在 Gemini CLI 重新登录或在配置中手动提供账号")
        }

        var metadata: [String: String] = ["ideType": "GEMINI_CLI", "platform": "MACOS"]
        let loadBody: [String: Any]
        if let selectedProject {
            metadata["duetProject"] = selectedProject
            loadBody = [
                "cloudaicompanionProject": selectedProject,
                "metadata": metadata,
            ]
        } else {
            loadBody = ["metadata": metadata]
        }

        if Task.isCancelled {
            return errorReport("查询 Gemini 用量失败：请求超时或中断")
        }

        var (loadData, loadErr, loadStatus) = await postJSON(
            url: Self.loadCodeAssistURL,
            accessToken: currentToken,
            bodyObj: loadBody,
            source: source
        )
        if Task.isCancelled {
            return errorReport("查询 Gemini 用量失败：请求超时或中断")
        }
        if loadStatus == 401 && source == "local" && !refreshedOnce {
            let (newToken, refreshErr) = await refreshAccessToken(creds: creds)
            if let refreshErr {
                return errorReport(refreshErr)
            }
            if let newToken {
                currentToken = newToken
                refreshedOnce = true
                (loadData, loadErr, _) = await postJSON(
                    url: Self.loadCodeAssistURL,
                    accessToken: currentToken,
                    bodyObj: loadBody,
                    source: source
                )
            }
        }
        if let loadErr {
            return errorReport(loadErr)
        }
        if Task.isCancelled {
            return errorReport("查询 Gemini 用量失败：请求超时或中断")
        }

        let plan = loadData.flatMap(extractPlan)
        let effectiveProject: String
        if let selectedProject {
            // 已显式选择项目时绝不静默替换。
            effectiveProject = selectedProject
        } else {
            let discovered = NativeProbeSupport.nonEmptyTrimmed(loadData?["cloudaicompanionProject"])
            guard let discovered, !Self.isNumericProjectNumber(discovered) else {
                return errorReport(Self.missingProjectError, plan: plan)
            }
            effectiveProject = discovered
        }

        let quotaReq: [String: Any] = ["project": effectiveProject]
        var (quotaData, quotaErr, quotaStatus) = await postJSON(
            url: Self.retrieveQuotaURL,
            accessToken: currentToken,
            bodyObj: quotaReq,
            source: source
        )
        if quotaStatus == 401 && source == "local" && !refreshedOnce {
            let (newToken, refreshErr) = await refreshAccessToken(creds: creds)
            if let refreshErr {
                return errorReport(refreshErr, plan: plan)
            }
            if let newToken {
                currentToken = newToken
                refreshedOnce = true
                (quotaData, quotaErr, _) = await postJSON(
                    url: Self.retrieveQuotaURL,
                    accessToken: currentToken,
                    bodyObj: quotaReq,
                    source: source
                )
            }
        }
        if let quotaErr {
            return errorReport(quotaErr, plan: plan)
        }

        var warnings: [String] = []
        let rawBuckets = quotaData?["buckets"] as? [[String: Any]] ?? []
        let windows = normalizeBuckets(rawBuckets, now: now, warnings: &warnings)

        let envelope = ProbeEnvelope(
            provider: ProviderCatalog.gemini.id,
            account: ProbeAccount(label: email, plan: plan),
            generatedAt: now,
            observedAt: now,
            stale: false,
            windows: windows,
            warnings: NativeProbeSupport.dedupeRedacted(warnings),
            error: nil
        )
        return ProbeReport(
            provider: ProviderCatalog.gemini,
            envelope: envelope,
            failure: nil,
            finishedAt: Date(),
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: - 凭据解析（严格只读、不消费 API Key）

    private func resolveCredentials(environment: [String: String], home: URL) -> Credentials? {
        let envToken = NativeProbeSupport.nonEmptyTrimmed(environment["GEMINI_ACCESS_TOKEN"])
        let envEmail = NativeProbeSupport.nonEmptyTrimmed(environment["GEMINI_ACCOUNT_EMAIL"])
        let (envProject, projectErr) = Self.resolveProjectContext(environment: environment)

        if let envToken {
            return Credentials(
                source: "manual",
                email: envEmail,
                accessToken: envToken,
                refreshToken: nil,
                expiryEpoch: nil,
                clientID: nil,
                clientSecret: nil,
                projectID: envProject,
                projectError: projectErr
            )
        }

        if NativeProbeSupport.nonEmptyTrimmed(environment["GEMINI_DISABLE_LOCAL_AUTH"]) == "1" {
            return nil
        }

        guard var local = loadLocalCredentials(home: home, environment: environment) else {
            return nil
        }
        local.email = envEmail ?? local.email
        local.projectID = envProject
        local.projectError = projectErr
        return local
    }

    private func loadLocalCredentials(home: URL, environment: [String: String]) -> Credentials? {
        let geminiDir = home.appendingPathComponent(".gemini", isDirectory: true)
        let credsURL = geminiDir.appendingPathComponent("oauth_creds.json")
        guard let data = try? Data(contentsOf: credsURL),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return nil
        }

        let accessToken = NativeProbeSupport.nonEmptyTrimmed(dict["access_token"])
        let refreshToken = NativeProbeSupport.nonEmptyTrimmed(dict["refresh_token"])
        guard accessToken != nil || refreshToken != nil else { return nil }

        let expiryEpoch = NativeProbeSupport.parseExpiryEpoch(dict["expiry_date"])
        let clientID = NativeProbeSupport.nonEmptyTrimmed(dict["client_id"])
            ?? NativeProbeSupport.nonEmptyTrimmed(environment["GEMINI_OAUTH_CLIENT_ID"])
        let clientSecret = NativeProbeSupport.nonEmptyTrimmed(dict["client_secret"])
            ?? NativeProbeSupport.nonEmptyTrimmed(environment["GEMINI_OAUTH_CLIENT_SECRET"])

        var email: String?
        let accountsURL = geminiDir.appendingPathComponent("google_accounts.json")
        if let accData = try? Data(contentsOf: accountsURL),
           let accObj = try? JSONSerialization.jsonObject(with: accData),
           let accDict = accObj as? [String: Any] {
            email = NativeProbeSupport.nonEmptyTrimmed(accDict["active"])
        }
        if email == nil {
            let claims = NativeProbeSupport.decodeJWTPayload(dict["id_token"])
            email = NativeProbeSupport.nonEmptyTrimmed(claims?["email"])
        }

        return Credentials(
            source: "local",
            email: email,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiryEpoch: expiryEpoch,
            clientID: clientID,
            clientSecret: clientSecret,
            projectID: nil,
            projectError: nil
        )
    }

    // MARK: - 网络与内存刷新

    private func httpErrorMessage(code: Int, source: String) -> String {
        if [301, 302, 303, 307, 308].contains(code) {
            return "查询 Gemini 用量失败：接口返回重定向（HTTP \(code)），已按安全策略拒绝跟随"
        }
        if code == 401 {
            if source == "local" {
                return "本机 Gemini 登录态无效或已过期（HTTP 401），请在 Gemini CLI 重新登录或在配置中手动提供账号"
            }
            return "Gemini 账号凭据无效或已过期（HTTP 401），请在配置中重新提供账号"
        }
        if code == 403 {
            if source == "local" {
                return "Gemini 服务端拒绝访问（HTTP 403），请检查 Google Cloud 项目配置（GEMINI_PROJECT_ID / GOOGLE_CLOUD_PROJECT）、Gemini for Cloud API 启用状态与 IAM 权限，或在 Gemini CLI 重新登录"
            }
            return "Gemini 服务端拒绝访问（HTTP 403），请检查 Google Cloud 项目配置（GEMINI_PROJECT_ID / GOOGLE_CLOUD_PROJECT）、Gemini for Cloud API 启用状态与 IAM 权限，或在配置中更新账号凭据"
        }
        if code == 429 {
            return "查询 Gemini 用量失败：请求被限流（HTTP 429），请稍后重试"
        }
        if (500..<600).contains(code) {
            return "查询 Gemini 用量失败：服务暂时不可用（HTTP \(code)），请稍后重试"
        }
        return "查询 Gemini 用量失败：HTTP \(code)"
    }

    private func postJSON(
        url: URL,
        accessToken: String,
        bodyObj: [String: Any],
        source: String
    ) async -> ([String: Any]?, String?, Int?) {
        guard let rawBody = try? JSONSerialization.data(withJSONObject: bodyObj) else {
            return (nil, "查询 Gemini 用量失败：请求体编码失败", nil)
        }
        let req = NativeHTTPRequest(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json",
                "Accept": "application/json",
            ],
            body: rawBody,
            timeout: NativeProbeSupport.httpTimeoutSeconds,
            expectedHost: Self.officialHost,
            maxBytes: NativeProbeSupport.httpMaxBytes
        )
        return await executePinnedJSON(
            req,
            errorPrefix: "查询 Gemini 用量失败：",
            httpErrorFormatter: { code in httpErrorMessage(code: code, source: source) }
        )
    }

    private func refreshAccessToken(creds: Credentials) async -> (String?, String?) {
        guard let refreshToken = creds.refreshToken,
              let clientID = creds.clientID else {
            return (nil, "本机 Gemini 登录态已过期且缺少刷新凭据，请在 Gemini CLI 重新登录或在配置中手动提供账号")
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
            errorPrefix: "刷新本机 Gemini 登录态失败：",
            httpErrorFormatter: { code in
                if [301, 302, 303, 307, 308].contains(code) {
                    return "刷新本机 Gemini 登录态失败：接口返回重定向（HTTP \(code)），已按安全策略拒绝跟随"
                }
                if [400, 401, 403].contains(code) {
                    return "本机 Gemini 登录态已过期或刷新失败（HTTP \(code)），请在 Gemini CLI 重新登录或在配置中手动提供账号"
                }
                if code == 429 {
                    return "刷新本机 Gemini 登录态失败：请求被限流（HTTP 429），请稍后重试"
                }
                if (500..<600).contains(code) {
                    return "刷新本机 Gemini 登录态失败：服务暂时不可用（HTTP \(code)），请稍后重试"
                }
                return "刷新本机 Gemini 登录态失败：HTTP \(code)"
            }
        )
        if let err { return (nil, err) }
        guard let token = NativeProbeSupport.nonEmptyTrimmed(data?["access_token"]) else {
            return (nil, "刷新本机 Gemini 登录态失败：接口未返回有效访问令牌")
        }
        return (token, nil)
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

    // MARK: - 窗口归类与归一化

    private func extractPlan(_ loadData: [String: Any]) -> String? {
        if let tier = loadData["currentTier"] as? [String: Any] {
            return NativeProbeSupport.nonEmptyTrimmed(tier["id"]) ?? NativeProbeSupport.nonEmptyTrimmed(tier["name"])
        }
        return NativeProbeSupport.nonEmptyTrimmed(loadData["currentTier"])
    }

    private func classifyWindow(_ bucket: [String: Any], resetsEpoch: TimeInterval?, nowEpoch: TimeInterval) -> String? {
        let keys = [
            "windowDuration", "quotaDuration", "duration", "period",
            "windowSeconds", "window_seconds", "window", "id",
        ]
        for key in keys {
            guard let raw = bucket[key] else { continue }
            if let str = raw as? String {
                let norm = str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["5h", "5 小时", "5小时"].contains(norm) { return "5h" }
                if ["7d", "7 天", "7天"].contains(norm) { return "7d" }
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
            warnings.append("Gemini 接口未返回 5 小时或 7 天配额窗口")
        } else {
            let present = Set(windows.map(\.id))
            if !present.contains("5h") { warnings.append("Gemini 接口未返回 5 小时配额窗口") }
            if !present.contains("7d") { warnings.append("Gemini 接口未返回 7 天配额窗口") }
        }
        return windows
    }
}
