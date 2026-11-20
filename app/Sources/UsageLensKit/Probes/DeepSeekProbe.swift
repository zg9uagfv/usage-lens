import Foundation

/// 纯 Swift DeepSeek 探针。
///
/// DeepSeek 没有窗口配额，因此 `windows` 恒为空数组。
/// 1. 余额：有 API Key 时直连官方 `GET https://api.deepseek.com/user/balance`（3s 超时），
///    通过自定义 `URLSessionTaskDelegate` 拒绝一切 3xx 重定向，防止 `Authorization` 泄露。
///    无 Key 时不发起任何网络请求。
/// 2. 花费估算（主 → 次）：
///    - 主源：`~/.dsh/storages/session_projcache/sessions/*.json` 的 `record.rows.tokenUsage.val.totals`
///    - 次源：`~/.dsh/sessions/**/session.v4.jsonl.zstd` 的事件 `data.usage`
public struct DeepSeekProbe: Sendable {
    public typealias BalanceFetcher = @Sendable (_ apiKey: String) async -> (ProbeBalance?, [String])

    public static let officialURLString = "https://api.deepseek.com/user/balance"
    public static let officialHost = "api.deepseek.com"
    public static let balanceTimeoutSeconds: TimeInterval = 3.0
    public static let balanceMaxBytes = 1024 * 1024
    public static let defaultCurrency = "CNY"

    public let projcacheDirectory: URL
    public let sessionsDirectory: URL
    public let spendWindowDays: Int
    public let maxSpendFiles: Int
    public let spendScanBudgetSeconds: TimeInterval
    public let zstdPath: String
    public let zstdTimeoutSeconds: TimeInterval
    private let balanceFetcher: BalanceFetcher
    private let nowProvider: @Sendable () -> Date

    /// DeepSeek 公开牌价（deepseek-chat，CNY / 百万 tokens，仅作估算）。
    private static let priceMissPerMillion = 2.0
    private static let priceHitPerMillion = 0.2
    private static let priceOutPerMillion = 3.0
    private static let zstdMaxDecompressedBytes = 64 * 1024 * 1024

    public init(
        projcacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/storages/session_projcache/sessions", isDirectory: true),
        sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/sessions", isDirectory: true),
        spendWindowDays: Int = 7,
        maxSpendFiles: Int = 500,
        spendScanBudgetSeconds: TimeInterval = 3.0,
        zstdPath: String = "/opt/homebrew/bin/zstd",
        zstdTimeoutSeconds: TimeInterval = 10.0,
        balanceFetcher: BalanceFetcher? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.projcacheDirectory = projcacheDirectory
        self.sessionsDirectory = sessionsDirectory
        self.spendWindowDays = spendWindowDays
        self.maxSpendFiles = maxSpendFiles
        self.spendScanBudgetSeconds = spendScanBudgetSeconds
        self.zstdPath = zstdPath
        self.zstdTimeoutSeconds = zstdTimeoutSeconds
        self.balanceFetcher = balanceFetcher ?? { key in
            await Self.fetchOfficialBalance(apiKey: key)
        }
        self.nowProvider = now
    }

    public func run(apiKey: String?) async -> ProbeReport {
        let started = Date()
        let now = nowProvider()
        var warnings: [String] = []

        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let balance: ProbeBalance?
        if let key = trimmedKey, !key.isEmpty {
            let (fetched, balanceWarnings) = await balanceFetcher(key)
            balance = fetched
            warnings.append(contentsOf: balanceWarnings)
        } else {
            balance = nil
            warnings.append("余额需要 API key")
        }

        let (spend, coverage, spendWarnings) = collectSpend(now: now)
        warnings.append(contentsOf: spendWarnings)

        let envelope = ProbeEnvelope(
            schema: probeSchema,
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
            warnings: warnings,
            error: nil
        )

        return ProbeReport(
            provider: ProviderCatalog.deepseek,
            envelope: envelope,
            failure: nil,
            warnings: warnings,
            finishedAt: Date(),
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: - 余额（官方接口 + 禁重定向）

    /// 只认 `https://api.deepseek.com`（默认端口 443，无 userinfo 欺骗）。
    public static func isOfficialURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.host?.lowercased() == officialHost else {
            return false
        }
        if let port = components.port, port != 443 {
            return false
        }
        return true
    }

    public static func fetchOfficialBalance(
        apiKey: String,
        endpoint: String = officialURLString,
        timeout: TimeInterval = balanceTimeoutSeconds
    ) async -> (ProbeBalance?, [String]) {
        guard let url = URL(string: endpoint) else {
            return (nil, ["查询 DeepSeek 余额失败：请求地址无效"])
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpShouldSetCookies = false

        let delegate = RejectRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (nil, ["查询 DeepSeek 余额失败：未收到合法 HTTP 响应"])
            }
            if (300..<400).contains(http.statusCode) {
                return (nil, [httpErrorMessage(http.statusCode)])
            }
            if http.statusCode < 200 || http.statusCode >= 300 {
                return (nil, [httpErrorMessage(http.statusCode)])
            }
            guard let finalURL = http.url?.absoluteString, isOfficialURL(finalURL) else {
                return (nil, ["查询 DeepSeek 余额失败：响应最终地址不是官方域名，已拒绝使用"])
            }
            if data.count > balanceMaxBytes {
                return (nil, ["查询 DeepSeek 余额失败：响应体过大（\(data.count) 字节），已拒绝读取"])
            }
            return parseBalanceBody(data)
        } catch let urlError as URLError {
            if urlError.code == .timedOut {
                return (nil, ["查询 DeepSeek 余额失败：请求超时"])
            }
            return (nil, ["查询 DeepSeek 余额失败：网络不可用（\(urlError.localizedDescription)）"])
        } catch {
            return (nil, ["查询 DeepSeek 余额失败：\(error.localizedDescription)"])
        }
    }

    static func httpErrorMessage(_ code: Int) -> String {
        switch code {
        case 301, 302, 303, 307, 308:
            return "查询 DeepSeek 余额失败：接口返回重定向（HTTP \(code)），已按安全策略拒绝跟随"
        case 401:
            return "查询 DeepSeek 余额失败：API key 无效或已过期（HTTP 401）"
        case 403:
            return "查询 DeepSeek 余额失败：没有权限（HTTP 403）"
        case 429:
            return "查询 DeepSeek 余额失败：请求被限流（HTTP 429），请稍后重试"
        case 500..<600:
            return "查询 DeepSeek 余额失败：服务暂时不可用（HTTP \(code)），请稍后重试"
        default:
            return "查询 DeepSeek 余额失败：HTTP \(code)"
        }
    }

    static func parseBalanceBody(_ data: Data) -> (ProbeBalance?, [String]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, ["查询 DeepSeek 余额失败：返回不是合法 JSON"])
        }
        guard let infos = root["balance_infos"] as? [Any], !infos.isEmpty else {
            return (nil, ["DeepSeek 余额接口没有返回余额明细"])
        }
        let usable = infos.compactMap { $0 as? [String: Any] }
        guard !usable.isEmpty else {
            return (nil, ["DeepSeek 余额接口返回的明细格式不对"])
        }

        var warnings: [String] = []
        let chosen: [String: Any]
        if let cny = usable.first(where: { ($0["currency"] as? String) == defaultCurrency }) {
            chosen = cny
        } else {
            chosen = usable[0]
            if usable.count > 1 {
                let currencyName = (chosen["currency"] as? String) ?? "未知币种"
                warnings.append("余额有多种币种，已展示 \(currencyName)")
            }
        }

        guard let amount = asFiniteDouble(chosen["total_balance"]) else {
            return (nil, ["DeepSeek 余额接口没有可读的余额数字"])
        }
        let currency = (chosen["currency"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultCurrency
        let rounded = (amount * 100).rounded() / 100
        return (ProbeBalance(amount: rounded, currency: currency, source: "official"), warnings)
    }

    // MARK: - 花费估算

    private struct TokenBuckets {
        var miss: Double = 0
        var hit: Double = 0
        var out: Double = 0

        var total: Double { miss + hit + out }

        var estimatedCostCNY: Double {
            (miss * priceMissPerMillion + hit * priceHitPerMillion + out * priceOutPerMillion) / 1_000_000.0
        }

        mutating func add(_ other: TokenBuckets) {
            miss += other.miss
            hit += other.hit
            out += other.out
        }
    }

    private func collectSpend(now: Date) -> (ProbeSpend?, ProbeCoverage?, [String]) {
        let calendar = Calendar.current
        var warnings: [String] = []
        let projSessions = collectProjcache(calendar: calendar, warnings: &warnings)

        var daily: [String: TokenBuckets] = [:]
        let sourceName: String
        let note: String

        if !projSessions.isEmpty {
            sourceName = "projcache"
            for (dayKey, buckets) in projSessions {
                var current = daily[dayKey] ?? TokenBuckets()
                current.add(buckets)
                daily[dayKey] = current
            }
            note = "按会话聚合，日期为会话创建日期（本地时区），非官方账单"
        } else {
            let eventsDaily = collectEvents(calendar: calendar, warnings: &warnings)
            if !eventsDaily.isEmpty {
                daily = eventsDaily
                sourceName = "events"
                note = "按事件时间逐日聚合（本地时区），本地日志覆盖，非官方账单"
            } else {
                warnings.append("本地没有可识别的 DeepSeek token 用量记录，无法估算花费")
                return (nil, nil, warnings)
            }
        }

        let sortedDays = daily.keys.sorted()
        guard let firstDay = sortedDays.first, let lastDay = sortedDays.last else {
            return (nil, nil, warnings)
        }

        let todayKey = Self.localDayKey(now, calendar: calendar)
        let windowStartDate = calendar.date(byAdding: .day, value: -spendWindowDays, to: calendar.startOfDay(for: now)) ?? now
        let windowStartKey = Self.localDayKey(windowStartDate, calendar: calendar)

        var todayCost = 0.0
        var windowCost = 0.0
        var totalCost = 0.0

        for dayKey in sortedDays {
            let amount = daily[dayKey]!.estimatedCostCNY
            totalCost += amount
            if dayKey == todayKey { todayCost += amount }
            if dayKey >= windowStartKey && dayKey <= todayKey { windowCost += amount }
        }

        warnings.append("花费按 token 与公开牌价估算（\(sourceName)），非官方账单")
        let spend = ProbeSpend(
            today: Self.round4(todayCost),
            window: Self.round4(windowCost),
            total: Self.round4(totalCost),
            currency: Self.defaultCurrency,
            source: "estimate"
        )
        let coverage = ProbeCoverage(
            from: firstDay,
            to: lastDay,
            note: "\(note)；window=近 \(spendWindowDays) 天，total=全部可读记录"
        )
        return (spend, coverage, warnings)
    }

    private func collectProjcache(calendar: Calendar, warnings: inout [String]) -> [(String, TokenBuckets)] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projcacheDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let files = try? fm.contentsOfDirectory(at: projcacheDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            warnings.append("读取 projcache 目录失败")
            return []
        }

        let jsonFiles = files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        var sessions: [(String, TokenBuckets)] = []
        var unreadable = 0
        var zeroSessions = 0

        for url in jsonFiles {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let record = root["record"] as? [String: Any],
                  let rows = record["rows"] as? [String: Any],
                  let tokenUsage = rows["tokenUsage"] as? [String: Any],
                  let val = tokenUsage["val"] as? [String: Any],
                  let totals = val["totals"] as? [String: Any] else {
                unreadable += 1
                continue
            }
            let buckets = TokenBuckets(
                miss: Self.num(totals, "uncachedInputTokens") + Self.num(totals, "cacheWriteTokens"),
                hit: Self.num(totals, "cacheReadTokens"),
                out: Self.num(totals, "outputTokens")
            )
            guard buckets.total > 0 else {
                zeroSessions += 1
                continue
            }
            let identity = record["identity"] as? [String: Any]
            let dayDate = Self.dateFromEpochOrMs(identity?["createdAt"]) ?? Self.fileModDate(url)
            sessions.append((Self.localDayKey(dayDate, calendar: calendar), buckets))
        }

        if unreadable > 0 {
            warnings.append("跳过 \(unreadable) 个无法解析的 projcache 文件")
        }
        if zeroSessions > 0 && sessions.isEmpty {
            warnings.append("projcache 里的 token 用量为 0")
        }
        return sessions
    }

    private func collectEvents(calendar: Calendar, warnings: inout [String]) -> [String: TokenBuckets] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            warnings.append("未找到 ~/.dsh/sessions 目录，跳过会话事件来源")
            return [:]
        }

        var archives: [(mtime: TimeInterval, url: URL)] = []
        if let enumerator = fm.enumerator(at: sessionsDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where url.lastPathComponent == "session.v4.jsonl.zstd" {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
                archives.append((mtime, url))
            }
        }
        if archives.isEmpty {
            warnings.append("~/.dsh/sessions 下没有可用的会话日志")
            return [:]
        }

        guard let zstdBin = resolveZstd() else {
            warnings.append("未找到 zstd，无法解压会话日志，跳过花费估算")
            return [:]
        }

        archives.sort { $0.mtime > $1.mtime }
        if archives.count > maxSpendFiles {
            warnings.append("会话日志较多，花费估算只覆盖最近 \(maxSpendFiles) 个")
            archives = Array(archives.prefix(maxSpendFiles))
        }

        let started = Date()
        var daily: [String: TokenBuckets] = [:]
        var skipped = 0
        var timedOut = 0
        var truncatedFiles = 0
        var sawUnrecognized = false
        var approxDay = false

        for item in archives {
            if Date().timeIntervalSince(started) > spendScanBudgetSeconds {
                warnings.append("会话日志较多，花费估算只覆盖最近一部分")
                break
            }
            switch decompressZstd(item.url, zstdBin: zstdBin) {
            case .timedOut:
                timedOut += 1
                continue
            case .failed:
                skipped += 1
                continue
            case .success(let data, let truncated):
                if truncated { truncatedFiles += 1 }
                let fileDate = Date(timeIntervalSince1970: item.mtime)
                for lineSlice in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                    guard let event = try? JSONSerialization.jsonObject(with: Data(lineSlice)) as? [String: Any],
                          let usage = Self.findUsage(in: event) else {
                        continue
                    }
                    guard Self.hasAnyUsageField(usage) else {
                        sawUnrecognized = true
                        continue
                    }
                    let buckets = TokenBuckets(
                        miss: Self.num(usage, "inputTokens") + Self.num(usage, "cacheWriteTokens"),
                        hit: Self.num(usage, "cacheReadTokens"),
                        out: Self.num(usage, "outputTokens")
                    )
                    guard buckets.total > 0 else { continue }
                    let date: Date
                    if let parsed = Self.dateFromEpochOrMs(event["time"])
                        ?? (event["timestamp"] as? String).flatMap(ProbeDate.parse)
                        ?? (event["createdAt"] as? String).flatMap(ProbeDate.parse) {
                        date = parsed
                    } else {
                        date = fileDate
                        approxDay = true
                    }
                    let dayKey = Self.localDayKey(date, calendar: calendar)
                    var current = daily[dayKey] ?? TokenBuckets()
                    current.add(buckets)
                    daily[dayKey] = current
                }
            }
        }

        if skipped > 0 { warnings.append("跳过 \(skipped) 个无法解压的会话日志") }
        if timedOut > 0 { warnings.append("\(timedOut) 个会话日志解压超时（超过 \(Int(zstdTimeoutSeconds)) 秒），已跳过") }
        if truncatedFiles > 0 { warnings.append("\(truncatedFiles) 个会话日志解压后过大，只统计了前 64MB") }
        if sawUnrecognized { warnings.append("会话日志有 usage 事件，但字段未识别（既不是 inputTokens 也不是 uncachedInputTokens 口径）") }
        if approxDay { warnings.append("部分 usage 事件没有时间戳，已按文件修改时间归日（近似）") }

        return daily
    }

    private enum ZstdResult {
        case success(Data, truncated: Bool)
        case timedOut
        case failed
    }

    private func resolveZstd() -> String? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: zstdPath) { return zstdPath }
        for fallback in ["/usr/local/bin/zstd", "/usr/bin/zstd"] where fm.isExecutableFile(atPath: fallback) {
            return fallback
        }
        return nil
    }

    private func decompressZstd(_ url: URL, zstdBin: String) -> ZstdResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstdBin)
        process.arguments = ["-dc", url.path]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            return .failed
        }

        let lock = NSLock()
        var output = Data()
        var truncated = false
        let limit = Self.zstdMaxDecompressedBytes
        let group = DispatchGroup()
        group.enter()

        let readHandle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                let chunk = readHandle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                if output.count < limit {
                    let remaining = limit - output.count
                    output.append(chunk.prefix(remaining))
                    if chunk.count > remaining { truncated = true }
                } else {
                    truncated = true
                }
                let hitLimit = truncated
                lock.unlock()
                if hitLimit {
                    process.terminate()
                    break
                }
            }
        }

        let deadline = Date().addingTimeInterval(zstdTimeoutSeconds)
        var didTimeout = false
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            didTimeout = true
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        _ = group.wait(timeout: .now() + 1.0)
        if !process.isRunning {
            process.waitUntilExit()
        }

        if didTimeout { return .timedOut }
        lock.lock()
        let finalData = output
        let wasTruncated = truncated
        lock.unlock()

        if process.terminationStatus != 0 && !wasTruncated {
            return .failed
        }
        return .success(finalData, truncated: wasTruncated)
    }

    // MARK: - 辅助

    private static func findUsage(in event: [String: Any]) -> [String: Any]? {
        if let data = event["data"] as? [String: Any], let usage = data["usage"] as? [String: Any] {
            return usage
        }
        return event["usage"] as? [String: Any]
    }

    private static func hasAnyUsageField(_ usage: [String: Any]) -> Bool {
        let keys = [
            "inputTokens", "outputTokens", "cacheReadTokens",
            "cacheWriteTokens", "reasoningTokens", "totalTokens", "uncachedInputTokens",
        ]
        return keys.contains { asFiniteDouble(usage[$0]) != nil }
    }

    private static func num(_ mapping: [String: Any], _ key: String) -> Double {
        asFiniteDouble(mapping[key]) ?? 0
    }

    private static func asFiniteDouble(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let d = number.doubleValue
            return d.isFinite ? d : nil
        }
        if let str = value as? String, let d = Double(str), d.isFinite {
            return d
        }
        return nil
    }

    private static func dateFromEpochOrMs(_ value: Any?) -> Date? {
        guard let raw = asFiniteDouble(value), raw > 0 else { return nil }
        let seconds = raw > 1e11 ? raw / 1000.0 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    private static func fileModDate(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
    }

    private static func localDayKey(_ date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private static func round4(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }
}

/// 拒绝一切 3xx 重定向，防止 `Authorization` 请求头被转发至第三方域名。
final class RejectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
