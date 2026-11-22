import Foundation

// MARK: - 原生 Swift DeepSeek 探针

public struct DeepSeekNativeProbe: Sendable {
    public static let officialHost = "api.deepseek.com"
    public static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    public static let defaultCurrency = "CNY"
    public static let spendWindowDays = 7
    public static let spendMaxFiles = 500
    public static let spendScanBudgetSeconds: TimeInterval = 3.0
    public static let zstdTimeoutSeconds: TimeInterval = 10.0
    public static let zstdMaxDecompressedBytes = 64 * 1024 * 1024

    // DeepSeek 公开牌价估算（CNY / 百万 tokens）
    private static let priceMissPerMillion = 2.0
    private static let priceHitPerMillion = 0.2
    private static let priceOutputPerMillion = 3.0

    internal struct ZstdDecompressOutcome: Sendable, Equatable {
        let text: String?
        let exitStatus: Int32?
        let timedOut: Bool
        let cancelled: Bool
        let overflowed: Bool
        let escalatedToSIGKILL: Bool
        let reaped: Bool
    }

    private struct TokenBuckets {
        var miss: Double = 0
        var hit: Double = 0
        var out: Double = 0

        var total: Double {
            let sum = miss + hit + out
            return sum.isFinite ? sum : 0
        }

        var estimatedCostCNY: Double {
            let cost = (miss * priceMissPerMillion + hit * priceHitPerMillion + out * priceOutputPerMillion) / 1_000_000.0
            return cost.isFinite && cost >= 0 ? cost : 0
        }

        mutating func add(_ other: TokenBuckets) -> Bool {
            let nextMiss = miss + other.miss
            let nextHit = hit + other.hit
            let nextOut = out + other.out
            let nextTotal = nextMiss + nextHit + nextOut
            guard nextMiss.isFinite, nextHit.isFinite, nextOut.isFinite, nextTotal.isFinite else {
                return false
            }
            miss = nextMiss
            hit = nextHit
            out = nextOut
            return true
        }
    }

    private let transport: any NativeHTTPTransport
    private let zstdBinaryOverride: String?
    private let zstdTimeoutSeconds: TimeInterval
    private let spendScanBudgetSeconds: TimeInterval
    private let zstdMaxDecompressedBytes: Int

    public init(
        transport: any NativeHTTPTransport = PinnedURLSessionTransport(),
        zstdBinaryOverride: String? = nil,
        zstdTimeoutSeconds: TimeInterval = DeepSeekNativeProbe.zstdTimeoutSeconds,
        spendScanBudgetSeconds: TimeInterval = DeepSeekNativeProbe.spendScanBudgetSeconds,
        zstdMaxDecompressedBytes: Int = DeepSeekNativeProbe.zstdMaxDecompressedBytes
    ) {
        self.transport = transport
        self.zstdBinaryOverride = zstdBinaryOverride
        self.zstdTimeoutSeconds = zstdTimeoutSeconds.isFinite ? max(zstdTimeoutSeconds, 0.05) : Self.zstdTimeoutSeconds
        self.spendScanBudgetSeconds = spendScanBudgetSeconds.isFinite ? max(spendScanBudgetSeconds, 0.05) : Self.spendScanBudgetSeconds
        self.zstdMaxDecompressedBytes = max(1, zstdMaxDecompressedBytes)
    }

    /// zstd 子进程严格最小化环境白名单：绝不继承父进程环境，也绝不传递任何厂商凭据（含 DEEPSEEK_API_KEY）。
    public static func minimalZstdEnvironment(from scopedEnvironment: [String: String]) -> [String: String] {
        let allowedKeys = ["PATH", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR"]
        var minimal: [String: String] = [:]
        for key in allowedKeys {
            if let value = scopedEnvironment[key], !value.isEmpty {
                minimal[key] = value
            }
        }
        if minimal["PATH"] == nil {
            minimal["PATH"] = "/usr/bin:/bin"
        }
        return minimal
    }

    public func run(
        environment: [String: String],
        now: Date = Date()
    ) async -> ProbeReport {
        let started = Date()
        let home = NativeProbeSupport.effectiveHomeDirectory(from: environment)
        var warnings: [String] = []

        let (balance, balanceWarnings) = await fetchBalance(
            apiKey: NativeProbeSupport.nonEmptyTrimmed(environment["DEEPSEEK_API_KEY"])
        )
        warnings.append(contentsOf: balanceWarnings)

        if Task.isCancelled {
            return ProbeReport(
                provider: ProviderCatalog.deepseek,
                failure: "探针已取消",
                finishedAt: Date(),
                duration: Date().timeIntervalSince(started)
            )
        }

        let dshHome = home.appendingPathComponent(".dsh", isDirectory: true)
        let projcacheDir = dshHome.appendingPathComponent("storages/session_projcache/sessions", isDirectory: true)
        let sessionsDir = dshHome.appendingPathComponent("sessions", isDirectory: true)
        let (spend, coverage, spendWarnings) = await collectSpend(
            projcacheDir: projcacheDir,
            sessionsDir: sessionsDir,
            environment: environment,
            now: now
        )
        warnings.append(contentsOf: spendWarnings)

        let envelope = ProbeEnvelope(
            provider: ProviderCatalog.deepseek.id,
            account: ProbeAccount(label: nil, plan: nil),
            generatedAt: now,
            observedAt: now,
            stale: false,
            windows: [],
            balance: balance,
            spend: spend,
            usage: nil,
            coverage: coverage,
            warnings: NativeProbeSupport.dedupeRedacted(warnings),
            error: nil
        )
        return ProbeReport(
            provider: ProviderCatalog.deepseek,
            envelope: envelope,
            failure: nil,
            finishedAt: Date(),
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: - 官方余额

    private func fetchBalance(apiKey: String?) async -> (ProbeBalance?, [String]) {
        guard let apiKey else {
            return (nil, ["余额需要 API key"])
        }
        let req = NativeHTTPRequest(
            url: Self.balanceURL,
            method: "GET",
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json",
            ],
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
            case .nonOfficialURL:
                return (nil, ["查询 DeepSeek 余额失败：响应最终地址不是官方域名，已拒绝使用"])
            case .redirected(let code):
                return (nil, ["查询 DeepSeek 余额失败：接口返回重定向（HTTP \(code)），已按安全策略拒绝跟随"])
            case .responseTooLarge(let declared):
                if let declared {
                    return (nil, ["查询 DeepSeek 余额失败：响应体过大（\(declared) 字节），已拒绝读取"])
                }
                return (nil, ["查询 DeepSeek 余额失败：响应体超过 1MB 上限，已拒绝读取"])
            case .timedOut:
                return (nil, ["查询 DeepSeek 余额失败：请求超时或中断"])
            case .network(let reason):
                return (nil, [SecretRedactor.redact("查询 DeepSeek 余额失败：网络不可用（\(reason)）")])
            }
        } catch {
            return (nil, [SecretRedactor.redact("查询 DeepSeek 余额失败：\(error.localizedDescription)")])
        }

        if let finalURL = response.finalURL,
           !NativeProbeSupport.isPinnedHTTPSURL(finalURL, expectedHost: Self.officialHost) {
            return (nil, ["查询 DeepSeek 余额失败：响应最终地址不是官方域名，已拒绝使用"])
        }
        if response.statusCode != 200 {
            let code = response.statusCode
            if [301, 302, 303, 307, 308].contains(code) {
                return (nil, ["查询 DeepSeek 余额失败：接口返回重定向（HTTP \(code)），已按安全策略拒绝跟随"])
            }
            if code == 401 { return (nil, ["查询 DeepSeek 余额失败：API key 无效或已过期（HTTP 401）"]) }
            if code == 403 { return (nil, ["查询 DeepSeek 余额失败：没有权限（HTTP 403）"]) }
            if code == 429 { return (nil, ["查询 DeepSeek 余额失败：请求被限流（HTTP 429），请稍后重试"]) }
            if (500..<600).contains(code) { return (nil, ["查询 DeepSeek 余额失败：服务暂时不可用（HTTP \(code)），请稍后重试"]) }
            return (nil, ["查询 DeepSeek 余额失败：HTTP \(code)"])
        }
        if response.body.count > NativeProbeSupport.httpMaxBytes {
            return (nil, ["查询 DeepSeek 余额失败：响应体超过 1MB 上限，已拒绝读取"])
        }
        return parseBalanceBody(response.body)
    }

    private func parseBalanceBody(_ body: Data) -> (ProbeBalance?, [String]) {
        guard let obj = try? JSONSerialization.jsonObject(with: body),
              let data = obj as? [String: Any] else {
            return (nil, ["查询 DeepSeek 余额失败：返回不是合法 JSON"])
        }
        guard let infos = data["balance_infos"] as? [[String: Any]], !infos.isEmpty else {
            return (nil, ["DeepSeek 余额接口没有返回余额明细"])
        }
        var warnings: [String] = []
        let chosen: [String: Any]
        if let cny = infos.first(where: { ($0["currency"] as? String) == Self.defaultCurrency }) {
            chosen = cny
        } else {
            chosen = infos[0]
            if infos.count > 1 {
                let curr = NativeProbeSupport.nonEmptyTrimmed(chosen["currency"]) ?? "未知币种"
                warnings.append("余额有多种币种，已展示 \(curr)")
            }
        }
        guard let amount = NativeProbeSupport.finiteDouble(chosen["total_balance"]) else {
            return (nil, ["DeepSeek 余额接口没有可读的余额数字"])
        }
        let scaled = amount * 100.0
        guard scaled.isFinite else {
            return (nil, ["DeepSeek 余额接口返回异常数值"])
        }
        let currency = NativeProbeSupport.nonEmptyTrimmed(chosen["currency"]) ?? Self.defaultCurrency
        let rounded = scaled.rounded() / 100.0
        return (ProbeBalance(amount: rounded, currency: currency, source: "official"), warnings)
    }

    // MARK: - 本地花费估算（主源 projcache，次源 zstd 会话事件）

    private func collectSpend(
        projcacheDir: URL,
        sessionsDir: URL,
        environment: [String: String],
        now: Date
    ) async -> (ProbeSpend?, ProbeCoverage?, [String]) {
        if Task.isCancelled { return (nil, nil, []) }
        var warnings: [String] = []
        let calendar = Calendar.current
        let projSessions = collectProjcache(in: projcacheDir, calendar: calendar, warnings: &warnings)

        var daily: [String: TokenBuckets] = [:]
        let note: String
        let source: String

        if !projSessions.isEmpty {
            source = "projcache"
            for (day, buckets) in projSessions {
                _ = daily[day, default: TokenBuckets()].add(buckets)
            }
            note = "按会话聚合，日期为会话创建日期（本地时区），非官方账单"
        } else {
            let eventDaily = await collectEvents(
                in: sessionsDir,
                environment: environment,
                calendar: calendar,
                warnings: &warnings
            )
            if !eventDaily.isEmpty {
                daily = eventDaily
                source = "events"
                note = "按事件时间逐日聚合（本地时区），本地日志覆盖，非官方账单"
            } else {
                warnings.append("本地没有可识别的 DeepSeek token 用量记录，无法估算花费")
                return (nil, nil, warnings)
            }
        }

        let sortedDays = daily.keys.sorted()
        let todayStr = NativeProbeSupport.localDayString(from: now, calendar: calendar)
        let windowStartDate = calendar.date(byAdding: .day, value: -Self.spendWindowDays, to: calendar.startOfDay(for: now)) ?? now
        let windowStartStr = NativeProbeSupport.localDayString(from: windowStartDate, calendar: calendar)

        var todayCost = 0.0
        var windowCost = 0.0
        for day in sortedDays {
            let amount = daily[day]?.estimatedCostCNY ?? 0.0
            if day == todayStr && (todayCost + amount).isFinite { todayCost += amount }
            if day >= windowStartStr && day <= todayStr && (windowCost + amount).isFinite { windowCost += amount }
        }

        let todayRounded = (todayCost * 10_000.0).isFinite ? (todayCost * 10_000.0).rounded() / 10_000.0 : nil
        let windowRounded = (windowCost * 10_000.0).isFinite ? (windowCost * 10_000.0).rounded() / 10_000.0 : nil

        warnings.append("花费按 token 与公开牌价估算（\(source)），非官方账单")
        let spend = ProbeSpend(
            today: todayRounded,
            window: windowRounded,
            currency: Self.defaultCurrency,
            source: "estimate"
        )
        let coverage = ProbeCoverage(
            from: sortedDays.first,
            to: sortedDays.last,
            note: "\(note)；window=近 \(Self.spendWindowDays) 天，total=全部可读记录"
        )
        return (spend, coverage, warnings)
    }

    private func collectProjcache(
        in dir: URL,
        calendar: Calendar,
        warnings: inout [String]
    ) -> [(String, TokenBuckets)] {
        if Task.isCancelled { return [] }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" })
            .sorted(by: { $0.path < $1.path }) else {
            return []
        }

        let scanDeadline = Date().addingTimeInterval(spendScanBudgetSeconds)
        var sessions: [(String, TokenBuckets)] = []
        var unreadable = 0
        var zeroCount = 0

        for url in files {
            if Task.isCancelled { break }
            if Date() >= scanDeadline {
                warnings.append("会话日志较多，花费估算只覆盖最近一部分")
                break
            }
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let root = obj as? [String: Any],
                  let record = root["record"] as? [String: Any],
                  let rows = record["rows"] as? [String: Any],
                  let tokenUsage = rows["tokenUsage"] as? [String: Any],
                  let val = tokenUsage["val"] as? [String: Any],
                  let totals = val["totals"] as? [String: Any] else {
                unreadable += 1
                continue
            }
            let uncached = max(0, NativeProbeSupport.finiteDouble(totals["uncachedInputTokens"]) ?? 0)
            let cacheWrite = max(0, NativeProbeSupport.finiteDouble(totals["cacheWriteTokens"]) ?? 0)
            let hit = max(0, NativeProbeSupport.finiteDouble(totals["cacheReadTokens"]) ?? 0)
            let out = max(0, NativeProbeSupport.finiteDouble(totals["outputTokens"]) ?? 0)
            let miss = uncached + cacheWrite
            guard miss.isFinite, hit.isFinite, out.isFinite else {
                unreadable += 1
                continue
            }
            let buckets = TokenBuckets(miss: miss, hit: hit, out: out)
            if buckets.total <= 0 {
                zeroCount += 1
                continue
            }
            let identity = record["identity"] as? [String: Any]
            let createdEpoch = NativeProbeSupport.parseExpiryEpoch(identity?["createdAt"])
            let date: Date
            if let createdEpoch {
                date = Date(timeIntervalSince1970: createdEpoch)
            } else if let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let mtime = attrs[.modificationDate] as? Date {
                date = mtime
            } else {
                date = Date()
            }
            sessions.append((NativeProbeSupport.localDayString(from: date, calendar: calendar), buckets))
        }

        if unreadable > 0 { warnings.append("跳过 \(unreadable) 个无法解析的 projcache 文件") }
        if zeroCount > 0 && sessions.isEmpty { warnings.append("projcache 里的 token 用量为 0") }
        return sessions
    }

    private func collectEvents(
        in sessionsDir: URL,
        environment: [String: String],
        calendar: Calendar,
        warnings: inout [String]
    ) async -> [String: TokenBuckets] {
        if Task.isCancelled { return [:] }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDir.path, isDirectory: &isDir), isDir.boolValue else {
            warnings.append("未找到 ~/.dsh/sessions 目录，跳过会话事件来源")
            return [:]
        }
        let enumerated = Self.enumerateEventSessionFiles(in: sessionsDir)
        if Task.isCancelled { return [:] }
        var files = enumerated
        guard !files.isEmpty else {
            warnings.append("~/.dsh/sessions 下没有可用的会话日志")
            return [:]
        }
        guard let zstdBin = resolveZstdBinary() else {
            warnings.append("未找到 zstd，无法解压会话日志，跳过花费估算")
            return [:]
        }
        files.sort { $0.mtime > $1.mtime }
        if files.count > Self.spendMaxFiles {
            warnings.append("会话日志较多，花费估算只覆盖最近 \(Self.spendMaxFiles) 个")
            files = Array(files.prefix(Self.spendMaxFiles))
        }

        let scanDeadline = Date().addingTimeInterval(spendScanBudgetSeconds)
        var daily: [String: TokenBuckets] = [:]
        var skipped = 0
        var sawUnrecognized = false
        var approxDay = false

        for item in files {
            if Task.isCancelled { break }
            let remainingBudget = scanDeadline.timeIntervalSinceNow
            if remainingBudget <= 0 {
                warnings.append("会话日志较多，花费估算只覆盖最近一部分")
                break
            }
            let perFileTimeout = min(zstdTimeoutSeconds, remainingBudget)
            let outcome = await decompressZstd(
                at: item.url,
                zstdBin: zstdBin,
                environment: environment,
                timeout: perFileTimeout
            )
            if outcome.cancelled {
                break
            }
            guard let text = outcome.text else {
                skipped += 1
                if outcome.timedOut && scanDeadline.timeIntervalSinceNow <= 0 {
                    warnings.append("会话日志较多，花费估算只覆盖最近一部分")
                    break
                }
                continue
            }
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if Task.isCancelled { break }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(rawLine.utf8)),
                      let event = obj as? [String: Any] else { continue }
                let dataDict = event["data"] as? [String: Any]
                guard let usage = (dataDict?["usage"] as? [String: Any]) ?? (event["usage"] as? [String: Any]) else {
                    continue
                }
                let hasAny = [
                    "inputTokens", "outputTokens", "cacheReadTokens",
                    "cacheWriteTokens", "reasoningTokens", "totalTokens", "uncachedInputTokens",
                ].contains { NativeProbeSupport.finiteDouble(usage[$0]) != nil }
                if !hasAny {
                    sawUnrecognized = true
                    continue
                }
                let input = max(0, NativeProbeSupport.finiteDouble(usage["inputTokens"]) ?? 0)
                let cacheWrite = max(0, NativeProbeSupport.finiteDouble(usage["cacheWriteTokens"]) ?? 0)
                let hit = max(0, NativeProbeSupport.finiteDouble(usage["cacheReadTokens"]) ?? 0)
                let out = max(0, NativeProbeSupport.finiteDouble(usage["outputTokens"]) ?? 0)
                let miss = input + cacheWrite
                guard miss.isFinite, hit.isFinite, out.isFinite else { continue }
                let buckets = TokenBuckets(miss: miss, hit: hit, out: out)
                guard buckets.total > 0 else { continue }
                let dayDate: Date
                if let epoch = NativeProbeSupport.parseExpiryEpoch(event["time"]) {
                    dayDate = Date(timeIntervalSince1970: epoch)
                } else if let iso = NativeProbeSupport.nonEmptyTrimmed(event["timestamp"]) ?? NativeProbeSupport.nonEmptyTrimmed(event["createdAt"]),
                          let parsed = ProbeDate.parse(iso) {
                    dayDate = parsed
                } else {
                    dayDate = item.mtime
                    approxDay = true
                }
                let dayStr = NativeProbeSupport.localDayString(from: dayDate, calendar: calendar)
                _ = daily[dayStr, default: TokenBuckets()].add(buckets)
            }
        }

        if skipped > 0 { warnings.append("跳过 \(skipped) 个无法解压的会话日志") }
        if sawUnrecognized { warnings.append("会话日志有 usage 事件，但字段未识别（既不是 inputTokens 也不是 uncachedInputTokens 口径）") }
        if approxDay { warnings.append("部分 usage 事件没有时间戳，已按文件修改时间归日（近似）") }
        return daily
    }

    private static func enumerateEventSessionFiles(in sessionsDir: URL) -> [(mtime: Date, url: URL)] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [(mtime: Date, url: URL)] = []
        for case let url as URL in enumerator where url.lastPathComponent == "session.v4.jsonl.zstd" {
            if Task.isCancelled { return [] }
            if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
               vals.isRegularFile == true {
                files.append((vals.contentModificationDate ?? Date.distantPast, url))
            }
        }
        return files
    }

    private func resolveZstdBinary() -> String? {
        if let override = zstdBinaryOverride, !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 带严格最小环境、流式字节上限、超时看门狗、SIGTERM→SIGKILL 升级、确认回收与退出码校验的 zstd 解压。
    internal func decompressZstd(
        at url: URL,
        zstdBin: String,
        environment: [String: String],
        timeout: TimeInterval
    ) async -> ZstdDecompressOutcome {
        if Task.isCancelled {
            return ZstdDecompressOutcome(
                text: nil,
                exitStatus: nil,
                timedOut: false,
                cancelled: true,
                overflowed: false,
                escalatedToSIGKILL: false,
                reaped: true
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstdBin)
        process.arguments = ["-dc", url.path]
        // 严格最小化环境，阻断父进程环境变量与所有凭据泄露。
        process.environment = Self.minimalZstdEnvironment(from: environment)
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        let terminationGroup = DispatchGroup()
        let terminationState = ZstdTerminationState(group: terminationGroup)
        process.terminationHandler = { finished in
            terminationState.markTerminated(status: finished.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            terminationState.cancelWithoutLaunch()
            return ZstdDecompressOutcome(
                text: nil,
                exitStatus: nil,
                timedOut: false,
                cancelled: false,
                overflowed: false,
                escalatedToSIGKILL: false,
                reaped: true
            )
        }

        // 在父进程关闭写端，确保子进程退出时读端立刻收到 EOF。
        try? stdoutPipe.fileHandleForWriting.close()

        let readerGroup = DispatchGroup()
        let buffer = ZstdBoundedBuffer(maxBytes: zstdMaxDecompressedBytes)
        let readHandle = stdoutPipe.fileHandleForReading

        readerGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readerGroup.leave() }
            while !buffer.shouldStop {
                let chunk: Data
                do {
                    chunk = try readHandle.read(upToCount: 65_536) ?? Data()
                } catch {
                    break
                }
                if chunk.isEmpty { break }
                if !buffer.append(chunk) {
                    try? readHandle.close()
                    break
                }
            }
        }

        let effectiveTimeout = min(max(timeout.isFinite ? timeout : zstdTimeoutSeconds, 0.05), zstdTimeoutSeconds)
        let deadline = Date().addingTimeInterval(effectiveTimeout)

        while !terminationState.hasTerminated && !buffer.overflows && !Task.isCancelled && Date() < deadline {
            try? await Task.sleep(nanoseconds: 15_000_000)
        }

        let cancelled = Task.isCancelled
        let overflowed = buffer.overflows
        let timedOut = !terminationState.hasTerminated && !cancelled && !overflowed && Date() >= deadline
        var escalatedToSIGKILL = false

        if cancelled || overflowed || timedOut || !terminationState.hasTerminated {
            buffer.stop()
            try? readHandle.close()
            if !terminationState.hasTerminated && process.isRunning {
                process.terminate()
                let exitedAfterTerm = await Self.waitForGroup(terminationGroup, timeout: 0.25)
                if !exitedAfterTerm && !terminationState.hasTerminated {
                    escalatedToSIGKILL = true
                    kill(process.processIdentifier, SIGKILL)
                    _ = await Self.waitForGroup(terminationGroup, timeout: 0.5)
                }
            } else {
                _ = await Self.waitForGroup(terminationGroup, timeout: 0.5)
            }
            _ = await Self.waitForGroup(readerGroup, timeout: 0.2)
            return ZstdDecompressOutcome(
                text: nil,
                exitStatus: terminationState.status,
                timedOut: timedOut,
                cancelled: cancelled,
                overflowed: overflowed,
                escalatedToSIGKILL: escalatedToSIGKILL,
                reaped: terminationState.hasTerminated
            )
        }

        let drained = await Self.waitForGroup(readerGroup, timeout: 0.5)
        if !drained {
            buffer.stop()
            try? readHandle.close()
        }
        let reaped = await Self.waitForGroup(terminationGroup, timeout: 0.5)
        let status = terminationState.status

        guard reaped, drained, !buffer.overflows, status == 0 else {
            return ZstdDecompressOutcome(
                text: nil,
                exitStatus: status,
                timedOut: false,
                cancelled: false,
                overflowed: buffer.overflows,
                escalatedToSIGKILL: false,
                reaped: reaped
            )
        }

        let text = String(data: buffer.snapshot, encoding: .utf8)
        return ZstdDecompressOutcome(
            text: text,
            exitStatus: status,
            timedOut: false,
            cancelled: false,
            overflowed: false,
            escalatedToSIGKILL: false,
            reaped: true
        )
    }

    /// 在非协作队列上做有界 DispatchGroup.wait，既不阻塞 Swift Concurrency 线程池，也不受 Task.isCancelled 影响。
    private static func waitForGroup(_ group: DispatchGroup, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = group.wait(timeout: .now() + max(timeout, 0.01))
                continuation.resume(returning: result == .success)
            }
        }
    }
}

private final class ZstdTerminationState: @unchecked Sendable {
    private let lock = NSLock()
    private let group: DispatchGroup
    private var terminated = false
    private var exitStatus: Int32?

    init(group: DispatchGroup) {
        self.group = group
        group.enter()
    }

    func markTerminated(status: Int32) {
        let shouldLeave: Bool = lock.withLock {
            guard !terminated else { return false }
            terminated = true
            exitStatus = status
            return true
        }
        if shouldLeave {
            group.leave()
        }
    }

    func cancelWithoutLaunch() {
        let shouldLeave: Bool = lock.withLock {
            guard !terminated else { return false }
            terminated = true
            return true
        }
        if shouldLeave {
            group.leave()
        }
    }

    var hasTerminated: Bool {
        lock.withLock { terminated }
    }

    var status: Int32? {
        lock.withLock { exitStatus }
    }
}

private final class ZstdBoundedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private var data = Data()
    private var didOverflow = false
    private var stopped = false

    init(maxBytes: Int) {
        self.maxBytes = max(1, maxBytes)
    }

    func append(_ chunk: Data) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            if chunk.count > maxBytes - data.count {
                didOverflow = true
                stopped = true
                data.removeAll(keepingCapacity: false)
                return false
            }
            data.append(chunk)
            return true
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
        }
    }

    var shouldStop: Bool {
        lock.withLock { stopped }
    }

    var overflows: Bool {
        lock.withLock { didOverflow }
    }

    var snapshot: Data {
        lock.withLock { data }
    }
}
