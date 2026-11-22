import Foundation

// MARK: - 原生 Swift Codex 探针

public struct CodexNativeProbe: Sendable {
    public static let officialHost = "chatgpt.com"
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let maxCandidateFiles = 50
    public static let todayTokenScanFiles = 50

    private struct CodexAuth {
        let accessToken: String
        let accountID: String?
        let email: String?
        let plan: String?
    }

    private struct LogFrame {
        let rateLimits: [String: Any]
        let epoch: TimeInterval?
        let fallbackEpoch: TimeInterval
        let name: String
    }

    private let transport: any NativeHTTPTransport
    private let maxScanBytes: Int

    public init(
        transport: any NativeHTTPTransport = PinnedURLSessionTransport(),
        maxScanBytes: Int = NativeProbeSupport.maxScanBytes
    ) {
        self.transport = transport
        self.maxScanBytes = maxScanBytes
    }

    public func run(
        environment: [String: String],
        now: Date = Date()
    ) async -> ProbeReport {
        let started = Date()
        let home = NativeProbeSupport.effectiveHomeDirectory(from: environment)
        let sessionsDir = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        var warnings: [String] = []

        let (todayTokens, tokenWarnings) = findTodayTokens(sessionsDir: sessionsDir, now: now)
        if Task.isCancelled {
            return ProbeReport(
                provider: ProviderCatalog.codex,
                failure: "探针已取消",
                finishedAt: Date(),
                duration: Date().timeIntervalSince(started)
            )
        }
        let usage = todayTokens.map { ProbeUsage(todayTokens: $0, source: "local") }
        let auth = loadAuth(environment: environment, home: home)

        if let auth {
            let (liveData, liveErr) = await fetchLiveUsage(auth: auth)
            if Task.isCancelled {
                return ProbeReport(
                    provider: ProviderCatalog.codex,
                    failure: "探针已取消",
                    finishedAt: Date(),
                    duration: Date().timeIntervalSince(started)
                )
            }
            if liveErr == nil, let liveData {
                var liveWarnings: [String] = []
                let (liveWindows, livePlan) = windowsFromLiveResponse(liveData, now: now, warnings: &liveWarnings)
                if liveWindows == nil {
                    warnings.append("实时查询 Codex 服务端失败（接口返回格式异常），已回退到本地会话日志")
                } else if liveWindows?.isEmpty == true {
                    warnings.append("实时查询 Codex 服务端未返回配额窗口，已回退到本地会话日志")
                } else if let liveWindows {
                    let envelope = ProbeEnvelope(
                        provider: ProviderCatalog.codex.id,
                        account: ProbeAccount(label: auth.email, plan: livePlan ?? auth.plan),
                        generatedAt: now,
                        observedAt: now,
                        stale: false,
                        windows: liveWindows,
                        usage: usage,
                        warnings: NativeProbeSupport.dedupeRedacted(liveWarnings + tokenWarnings),
                        error: nil
                    )
                    return ProbeReport(
                        provider: ProviderCatalog.codex,
                        envelope: envelope,
                        failure: nil,
                        finishedAt: Date(),
                        duration: Date().timeIntervalSince(started)
                    )
                }
            } else {
                warnings.append("实时查询 Codex 服务端失败（\(liveErr ?? "未知错误")），已回退到本地会话日志")
            }
        }

        let (frame, scanWarnings) = findLatestFrame(sessionsDir: sessionsDir)
        warnings.append(contentsOf: scanWarnings)
        warnings.append(contentsOf: tokenWarnings)

        var observedAt = now
        var windows: [ProbeWindow] = []
        var plan: String?
        var coverage: ProbeCoverage?
        var stale = false

        if let frame {
            let obsEpoch = frame.epoch ?? frame.fallbackEpoch
            observedAt = Date(timeIntervalSince1970: obsEpoch)
            let observedDay = NativeProbeSupport.localDayString(from: observedAt)
            for (key, id, label, defaultSeconds) in [
                ("primary", "5h", "5 小时", 18_000),
                ("secondary", "7d", "7 天", 604_800),
            ] {
                if let entry = windowEntry(
                    key: key,
                    id: id,
                    label: label,
                    defaultSeconds: defaultSeconds,
                    rateLimits: frame.rateLimits,
                    now: now,
                    observedDay: observedDay,
                    warnings: &warnings
                ) {
                    windows.append(entry)
                }
            }
            if let p = NativeProbeSupport.nonEmptyTrimmed(frame.rateLimits["plan_type"]) {
                plan = p
            }
            if !windows.isEmpty {
                coverage = ProbeCoverage(
                    from: observedDay,
                    to: observedDay,
                    note: "仅最后一帧窗口数据，非官方账单"
                )
                let age = now.timeIntervalSince1970 - obsEpoch
                let thresholdSeconds = windows.compactMap(\.windowSeconds).min() ?? 18_000
                let threshold = Double(thresholdSeconds)
                stale = age > threshold
                if stale {
                    let hours = max(thresholdSeconds / 3_600, 1)
                    warnings.append("数据来自 \(observedDay)（\(NativeProbeSupport.humanAge(seconds: age))），已超过 \(hours) 小时窗口，可能不是当前状态")
                }
            }
        }

        let envelope = ProbeEnvelope(
            provider: ProviderCatalog.codex.id,
            account: ProbeAccount(label: auth?.email, plan: plan ?? auth?.plan),
            generatedAt: now,
            observedAt: observedAt,
            stale: stale,
            windows: windows,
            usage: usage,
            coverage: coverage,
            warnings: NativeProbeSupport.dedupeRedacted(warnings),
            error: nil
        )
        return ProbeReport(
            provider: ProviderCatalog.codex,
            envelope: envelope,
            failure: nil,
            finishedAt: Date(),
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: - 凭据与实时服务端

    private func loadAuth(environment: [String: String], home: URL) -> CodexAuth? {
        if let envToken = NativeProbeSupport.nonEmptyTrimmed(environment["CODEX_ACCESS_TOKEN"]) {
            return CodexAuth(
                accessToken: envToken,
                accountID: NativeProbeSupport.nonEmptyTrimmed(environment["CODEX_ACCOUNT_ID"]),
                email: NativeProbeSupport.nonEmptyTrimmed(environment["CODEX_ACCOUNT_EMAIL"]),
                plan: nil
            )
        }
        let authURL = home.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let tokens = dict["tokens"] as? [String: Any],
              let accessToken = NativeProbeSupport.nonEmptyTrimmed(tokens["access_token"]) else {
            return nil
        }

        var accountID = NativeProbeSupport.nonEmptyTrimmed(tokens["account_id"])
        var email: String?
        var plan: String?
        if let claims = NativeProbeSupport.decodeJWTPayload(tokens["id_token"]) {
            email = NativeProbeSupport.nonEmptyTrimmed(claims["email"])
            if let authClaims = claims["https://api.openai.com/auth"] as? [String: Any] {
                if accountID == nil {
                    accountID = NativeProbeSupport.nonEmptyTrimmed(authClaims["chatgpt_account_id"])
                }
                plan = NativeProbeSupport.nonEmptyTrimmed(authClaims["chatgpt_plan_type"])
            }
        }
        return CodexAuth(accessToken: accessToken, accountID: accountID, email: email, plan: plan)
    }

    private func fetchLiveUsage(auth: CodexAuth) async -> ([String: Any]?, String?) {
        var headers: [String: String] = [
            "Authorization": "Bearer \(auth.accessToken)",
            "Accept": "application/json",
            "User-Agent": "usage-lens/1",
        ]
        if let accountID = auth.accountID {
            headers["ChatGPT-Account-Id"] = accountID
        }
        let req = NativeHTTPRequest(
            url: Self.usageURL,
            method: "GET",
            headers: headers,
            body: nil,
            timeout: NativeProbeSupport.httpTimeoutSeconds,
            expectedHost: Self.officialHost,
            maxBytes: NativeProbeSupport.httpMaxBytes
        )
        let response: NativeHTTPResponse
        do {
            response = try await transport.send(req)
        } catch let error as NativeHTTPError {
            switch error {
            case .nonOfficialURL: return (nil, "响应最终地址不是官方域名，已拒绝使用")
            case .redirected(let code): return (nil, "接口返回重定向（HTTP \(code)），已按安全策略拒绝跟随")
            case .responseTooLarge(let declared):
                if let declared { return (nil, "响应体过大（\(declared) 字节），已拒绝读取") }
                return (nil, "响应体超过 1MB 上限，已拒绝读取")
            case .timedOut: return (nil, "请求超时或中断")
            case .network(let reason): return (nil, SecretRedactor.redact("网络不可用（\(reason)）"))
            }
        } catch {
            return (nil, SecretRedactor.redact(error.localizedDescription))
        }

        if let finalURL = response.finalURL,
           !NativeProbeSupport.isPinnedHTTPSURL(finalURL, expectedHost: Self.officialHost) {
            return (nil, "响应最终地址不是官方域名，已拒绝使用")
        }
        if response.statusCode != 200 {
            let code = response.statusCode
            if [301, 302, 303, 307, 308].contains(code) {
                return (nil, "接口返回重定向（HTTP \(code)），已按安全策略拒绝跟随")
            }
            if [401, 403].contains(code) {
                return (nil, "登录态已过期或无效（HTTP \(code)）")
            }
            if code == 429 { return (nil, "请求被限流（HTTP 429）") }
            if (500..<600).contains(code) { return (nil, "服务暂时不可用（HTTP \(code)）") }
            return (nil, "HTTP \(code)")
        }
        if response.body.count > NativeProbeSupport.httpMaxBytes {
            return (nil, "响应体超过 1MB 上限，已拒绝读取")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: response.body) else {
            return (nil, "接口返回不是合法 JSON")
        }
        guard let dict = obj as? [String: Any] else {
            return (nil, "接口返回格式异常")
        }
        return (dict, nil)
    }

    private func cleanPercent(_ value: Any?, label: String, warnings: inout [String]) -> Double? {
        guard let num = NativeProbeSupport.finiteDouble(value) else { return nil }
        guard num >= 0.0 && num <= 100.0 else {
            warnings.append("\(label)的 used_percent 数值异常（不在 0-100），已置空")
            return nil
        }
        return (num * 100.0).rounded() / 100.0
    }

    private func windowsFromLiveResponse(
        _ data: [String: Any],
        now: Date,
        warnings: inout [String]
    ) -> ([ProbeWindow]?, String?) {
        guard let rateLimit = data["rate_limit"] as? [String: Any] else {
            return (nil, nil)
        }
        let livePlan = NativeProbeSupport.nonEmptyTrimmed(data["plan_type"])
        var windows: [ProbeWindow] = []
        let nowEpoch = now.timeIntervalSince1970

        for (liveKey, id, label, defaultSeconds) in [
            ("primary_window", "5h", "5 小时", 18_000),
            ("secondary_window", "7d", "7 天", 604_800),
        ] {
            guard let raw = rateLimit[liveKey] as? [String: Any] else { continue }
            var windowSeconds = defaultSeconds
            if let rawLimit = raw["limit_window_seconds"], !(rawLimit is NSNull) {
                if let checked = NativeProbeSupport.checkedPositiveIntSeconds(rawLimit, multiplier: 1.0) {
                    windowSeconds = checked
                } else {
                    warnings.append("\(label)的窗口时长数值异常，已回退默认时长")
                }
            } else if let rawMinutes = raw["window_minutes"], !(rawMinutes is NSNull) {
                if let checked = NativeProbeSupport.checkedPositiveIntSeconds(rawMinutes, multiplier: 60.0) {
                    windowSeconds = checked
                } else {
                    warnings.append("\(label)的窗口时长数值异常，已回退默认时长")
                }
            }

            var resetsEpoch: TimeInterval?
            for resetKey in ["reset_at", "resets_at"] {
                if let parsed = NativeProbeSupport.parseExpiryEpoch(raw[resetKey]) {
                    resetsEpoch = parsed
                    break
                }
            }
            if resetsEpoch == nil,
               let resetAfter = NativeProbeSupport.finiteDouble(raw["reset_after_seconds"]),
               resetAfter > 0 {
                let candidate = nowEpoch + resetAfter
                if candidate.isFinite {
                    resetsEpoch = candidate
                }
            }

            let expired = resetsEpoch.map { $0 < nowEpoch } ?? false
            if expired, let resetsEpoch {
                warnings.append("\(label)窗口已于 \(NativeProbeSupport.humanAge(seconds: nowEpoch - resetsEpoch))重置")
            }
            windows.append(
                ProbeWindow(
                    id: id,
                    label: label,
                    usedPercent: cleanPercent(raw["used_percent"], label: label, warnings: &warnings),
                    windowSeconds: windowSeconds,
                    resetsAt: resetsEpoch.map { Date(timeIntervalSince1970: $0) },
                    expired: expired,
                    basis: "server"
                )
            )
        }
        return (windows, livePlan)
    }

    // MARK: - 本地会话日志回退与今日 tokens

    private func rolloutFiles(in sessionsDir: URL) -> [(mtime: TimeInterval, url: URL)] {
        if Task.isCancelled { return [] }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var results: [(TimeInterval, URL)] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { return [] }
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
               values.isRegularFile == true,
               let mtime = values.contentModificationDate {
                results.append((mtime.timeIntervalSince1970, url))
            }
        }
        results.sort { a, b in
            if a.0 != b.0 { return a.0 > b.0 }
            return a.1.path > b.1.path
        }
        return results
    }

    private enum TokenRecordParseResult {
        case ignored
        case valid(Int)
        case invalid
    }

    private func findTodayTokens(sessionsDir: URL, now: Date) -> (Int?, [String]) {
        if Task.isCancelled { return (nil, []) }
        let files = rolloutFiles(in: sessionsDir)
        guard !files.isEmpty else { return (nil, []) }

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        var total = 0
        var found = false
        var overflowed = false
        var invalidCount = 0
        var truncatedCount = 0

        for item in files.prefix(Self.todayTokenScanFiles) {
            if Task.isCancelled { break }
            let mtimeDate = Date(timeIntervalSince1970: item.mtime)
            if calendar.startOfDay(for: mtimeDate) < todayStart {
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
              let event = obj as? [String: Any] else {
            return .ignored
        }
        let payload = event["payload"] as? [String: Any]
        let topType = event["type"] as? String
        let payloadType = payload?["type"] as? String
        guard topType == "token_usage_record" || payloadType == "token_usage_record" else { return .ignored }
        guard let ts = NativeProbeSupport.nonEmptyTrimmed(event["timestamp"]),
              let date = ProbeDate.parse(ts),
              calendar.startOfDay(for: date) == todayStart else {
            return .ignored
        }
        let usage = (payload?["usage"] as? [String: Any]) ?? (event["usage"] as? [String: Any])
        guard let rawTokens = usage?["total_tokens"], !(rawTokens is NSNull) else {
            return .ignored
        }
        guard let parsed = NativeProbeSupport.nonNegativeInt(rawTokens) else {
            return .invalid
        }
        return .valid(parsed)
    }

    private func findLatestFrame(sessionsDir: URL) -> (LogFrame?, [String]) {
        if Task.isCancelled { return (nil, []) }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDir.path, isDirectory: &isDir), isDir.boolValue else {
            return (nil, ["未找到 ~/.codex/sessions 目录（Codex 可能未安装或从未运行）"])
        }
        var candidates = rolloutFiles(in: sessionsDir)
        if Task.isCancelled { return (nil, []) }
        guard !candidates.isEmpty else {
            return (nil, ["~/.codex/sessions 下没有 rollout-*.jsonl 会话日志"])
        }
        var warnings: [String] = []
        if candidates.count > Self.maxCandidateFiles {
            warnings.append("Codex 会话日志较多，只检查最近 \(Self.maxCandidateFiles) 个")
            candidates = Array(candidates.prefix(Self.maxCandidateFiles))
        }

        var best: LogFrame?
        var truncatedCount = 0
        var corruptLines = 0

        for item in candidates {
            if Task.isCancelled { break }
            if let best, item.mtime < (best.epoch ?? best.fallbackEpoch) {
                break
            }
            guard let (lines, truncated) = try? NativeProbeSupport.readLinesReverse(
                at: item.url,
                maxBytes: maxScanBytes
            ) else {
                warnings.append("跳过 1 个无法读取的日志")
                continue
            }
            var foundInFile: LogFrame?
            for raw in lines {
                if Task.isCancelled { break }
                guard let obj = try? JSONSerialization.jsonObject(with: raw),
                      let event = obj as? [String: Any] else {
                    corruptLines += 1
                    continue
                }
                guard (event["type"] as? String) == "event_msg",
                      let payload = event["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count",
                      let rateLimits = payload["rate_limits"] as? [String: Any] else {
                    continue
                }
                let epoch = NativeProbeSupport.nonEmptyTrimmed(event["timestamp"])
                    .flatMap(ProbeDate.parse)?.timeIntervalSince1970
                foundInFile = LogFrame(
                    rateLimits: rateLimits,
                    epoch: epoch,
                    fallbackEpoch: item.mtime,
                    name: item.url.path
                )
                break
            }
            if let foundInFile {
                let newKey = (foundInFile.epoch ?? foundInFile.fallbackEpoch, foundInFile.name)
                if let currentBest = best {
                    let oldKey = (currentBest.epoch ?? currentBest.fallbackEpoch, currentBest.name)
                    if newKey > oldKey { best = foundInFile }
                } else {
                    best = foundInFile
                }
            } else if truncated {
                truncatedCount += 1
            }
        }

        if best == nil {
            var msg = "最近的 Codex 会话日志里没有 rate_limits 记录"
            if corruptLines > 0 { msg += "（另有 \(corruptLines) 行日志无法解析）" }
            warnings.append(msg)
        }
        if truncatedCount > 0 {
            warnings.append("有 \(truncatedCount) 个会话日志超过 4MB，只回扫了末尾部分，可能漏掉更早的帧")
        }
        return (best, warnings)
    }

    private func windowEntry(
        key: String,
        id: String,
        label: String,
        defaultSeconds: Int,
        rateLimits: [String: Any],
        now: Date,
        observedDay: String,
        warnings: inout [String]
    ) -> ProbeWindow? {
        guard let raw = rateLimits[key] as? [String: Any] else { return nil }
        var windowSeconds = defaultSeconds
        if let rawMinutes = raw["window_minutes"], !(rawMinutes is NSNull) {
            if let checked = NativeProbeSupport.checkedPositiveIntSeconds(rawMinutes, multiplier: 60.0) {
                windowSeconds = checked
            } else {
                warnings.append("\(label)的窗口时长数值异常，已回退默认时长")
            }
        }
        let resetsEpoch = NativeProbeSupport.parseExpiryEpoch(raw["resets_at"])
        let nowEpoch = now.timeIntervalSince1970
        let expired = resetsEpoch.map { $0 < nowEpoch } ?? false
        if expired, let resetsEpoch {
            warnings.append("\(label)窗口已于 \(NativeProbeSupport.humanAge(seconds: nowEpoch - resetsEpoch))重置（数据来自 \(observedDay)）")
        }
        return ProbeWindow(
            id: id,
            label: label,
            usedPercent: cleanPercent(raw["used_percent"], label: label, warnings: &warnings),
            windowSeconds: windowSeconds,
            resetsAt: resetsEpoch.map { Date(timeIntervalSince1970: $0) },
            expired: expired,
            basis: "server"
        )
    }
}
