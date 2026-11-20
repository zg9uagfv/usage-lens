import Foundation

/// 纯 Swift Gemini 本地日志探针。
///
/// 只读 `~/.gemini` 下的本地会话日志（不读凭据 / OAuth / Keychain，不发网络，不写文件）：
/// 1. Antigravity / Antigravity CLI / Antigravity IDE 转录：
///    `~/.gemini/{antigravity,antigravity-cli,antigravity-ide}/brain/*/.system_generated/logs/transcript.jsonl`
///    （跳过 `transcript_full.jsonl` 与 `antigravity-backup`，按 conversation_id 去重）
/// 2. Google Gemini CLI 会话日志：
///    `~/.gemini/tmp/*/chats/session-*.json`
///
/// 本地不落盘配额窗口进度，因此 `windows` 恒为空数组，不编造百分比。
public struct GeminiProbe: Sendable {
    public let geminiHome: URL
    public let maxCandidateFiles: Int
    public let maxScanBytes: UInt64
    public let spendWindowDays: Int
    private let nowProvider: @Sendable () -> Date

    private static let antigravitySubdirs = ["antigravity", "antigravity-cli", "antigravity-ide"]

    private struct PriceTier {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
    }

    /// Gemini API 公开参考牌价（USD / 百万 tokens，仅作估算，非官方账单）。
    private static let pricing: [String: PriceTier] = [
        "pro": PriceTier(input: 1.25, output: 10.0, cacheRead: 0.125, cacheWrite: 1.25),
        "flash": PriceTier(input: 0.30, output: 2.50, cacheRead: 0.03, cacheWrite: 0.30),
        "flash-lite": PriceTier(input: 0.10, output: 0.40, cacheRead: 0.01, cacheWrite: 0.10),
    ]

    public init(
        geminiHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true),
        maxCandidateFiles: Int = 200,
        maxScanBytes: UInt64 = 8 * 1024 * 1024,
        spendWindowDays: Int = 7,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.geminiHome = geminiHome
        self.maxCandidateFiles = maxCandidateFiles
        self.maxScanBytes = maxScanBytes
        self.spendWindowDays = spendWindowDays
        self.nowProvider = now
    }

    public func run() -> ProbeReport {
        let started = Date()
        let now = nowProvider()
        let calendar = Calendar.current
        let todayKey = Self.localDayKey(now, calendar: calendar)

        let result = collectUsage(calendar: calendar)
        var warnings = result.warnings

        let observedAt = result.latestEventDate ?? now
        var usageBlock: ProbeUsage?
        var spendBlock: ProbeSpend?
        var coverageBlock: ProbeCoverage?

        if !result.daily.isEmpty {
            if let todayBucket = result.daily[todayKey], (todayBucket.input + todayBucket.output) > 0 {
                let todayTokens = Int(todayBucket.input + todayBucket.output)
                usageBlock = ProbeUsage(todayTokens: todayTokens, source: "local")
                let cacheToday = Int(todayBucket.cacheRead + todayBucket.cacheWrite)
                if cacheToday > 0 {
                    warnings.append("今日另有 cache tokens \(cacheToday)，不计入主数字")
                }
            }

            let windowStartDate = calendar.date(byAdding: .day, value: -spendWindowDays, to: calendar.startOfDay(for: now)) ?? now
            let windowStartKey = Self.localDayKey(windowStartDate, calendar: calendar)

            var todayCost = 0.0
            var windowCost = 0.0
            var totalCost = 0.0
            for (dayKey, bucket) in result.daily {
                totalCost += bucket.cost
                if dayKey == todayKey {
                    todayCost += bucket.cost
                }
                if dayKey >= windowStartKey && dayKey <= todayKey {
                    windowCost += bucket.cost
                }
            }

            if totalCost > 0 {
                spendBlock = ProbeSpend(
                    today: Self.round4(todayCost),
                    window: Self.round4(windowCost),
                    total: Self.round4(totalCost),
                    currency: "USD",
                    source: "estimate"
                )
                coverageBlock = ProbeCoverage(
                    from: result.minDay ?? todayKey,
                    to: result.maxDay ?? todayKey,
                    note: "按本地会话日志逐日聚合（本地时区）；window=近 \(spendWindowDays) 天，total=全部可读记录；花费按 Gemini 公开牌价估算，非官方账单"
                )
            }
        } else {
            warnings.append("本地没有可识别的 Gemini 用量记录，无法显示今日 tokens 与花费")
        }

        let envelope = ProbeEnvelope(
            schema: probeSchema,
            provider: ProviderCatalog.gemini.id,
            account: ProbeAccount(label: nil, plan: nil),
            generatedAt: now,
            observedAt: observedAt,
            stale: false,
            windows: [],
            balance: nil,
            spend: spendBlock,
            usage: usageBlock,
            coverage: coverageBlock,
            warnings: warnings,
            error: nil
        )

        return ProbeReport(
            provider: ProviderCatalog.gemini,
            envelope: envelope,
            failure: nil,
            warnings: warnings,
            finishedAt: Date(),
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: - 采集

    private enum SourceKind {
        case antigravity
        case geminiCLI
    }

    private struct SourceFile {
        let mtime: TimeInterval
        let kind: SourceKind
        let url: URL
    }

    private struct DayBucket {
        var input: Double = 0
        var output: Double = 0
        var cacheRead: Double = 0
        var cacheWrite: Double = 0
        var cost: Double = 0
    }

    private struct TokenEntry {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
        let model: String
        let timestamp: Date?
    }

    private struct CollectResult {
        var daily: [String: DayBucket] = [:]
        var warnings: [String] = []
        var minDay: String?
        var maxDay: String?
        var latestEventDate: Date?
    }

    private func discoverSources() -> ([SourceFile], [String]) {
        var warnings: [String] = []
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: geminiHome.path, isDirectory: &isDir), isDir.boolValue else {
            return ([], ["未找到 ~/.gemini 目录（Gemini / Antigravity 可能未安装或从未运行）"])
        }

        var agByConv: [String: SourceFile] = [:]
        var cliFiles: [SourceFile] = []
        var unreadable = 0

        for subdir in Self.antigravitySubdirs {
            let brainDir = geminiHome
                .appendingPathComponent(subdir, isDirectory: true)
                .appendingPathComponent("brain", isDirectory: true)
            guard let convDirs = try? fm.contentsOfDirectory(at: brainDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for convDir in convDirs {
                let transcriptURL = convDir
                    .appendingPathComponent(".system_generated", isDirectory: true)
                    .appendingPathComponent("logs", isDirectory: true)
                    .appendingPathComponent("transcript.jsonl")
                var fileIsDir: ObjCBool = false
                guard fm.fileExists(atPath: transcriptURL.path, isDirectory: &fileIsDir), !fileIsDir.boolValue else {
                    continue
                }
                guard let attrs = try? fm.attributesOfItem(atPath: transcriptURL.path),
                      let modDate = attrs[.modificationDate] as? Date else {
                    unreadable += 1
                    continue
                }
                let mtime = modDate.timeIntervalSince1970
                let convID = convDir.lastPathComponent
                if let existing = agByConv[convID], existing.mtime >= mtime {
                    continue
                }
                agByConv[convID] = SourceFile(mtime: mtime, kind: .antigravity, url: transcriptURL)
            }
        }

        let tmpDir = geminiHome.appendingPathComponent("tmp", isDirectory: true)
        if let projectDirs = try? fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for projectDir in projectDirs {
                let chatsDir = projectDir.appendingPathComponent("chats", isDirectory: true)
                guard let files = try? fm.contentsOfDirectory(at: chatsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                    continue
                }
                for file in files {
                    let name = file.lastPathComponent
                    guard name.hasPrefix("session-"), name.hasSuffix(".json") else { continue }
                    guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                          let modDate = attrs[.modificationDate] as? Date else {
                        unreadable += 1
                        continue
                    }
                    cliFiles.append(SourceFile(mtime: modDate.timeIntervalSince1970, kind: .geminiCLI, url: file))
                }
            }
        }

        if unreadable > 0 {
            warnings.append("跳过 \(unreadable) 个无法读取的 Gemini 会话目录或文件")
        }

        var candidates = Array(agByConv.values) + cliFiles
        candidates.sort { lhs, rhs in
            if lhs.mtime != rhs.mtime { return lhs.mtime > rhs.mtime }
            return lhs.url.path > rhs.url.path
        }
        if candidates.count > maxCandidateFiles {
            warnings.append("Gemini 会话日志较多，只统计最近 \(maxCandidateFiles) 个")
            candidates = Array(candidates.prefix(maxCandidateFiles))
        }
        if candidates.isEmpty {
            warnings.append("~/.gemini 下没有可识别的会话日志")
        }
        return (candidates, warnings)
    }

    private func collectUsage(calendar: Calendar) -> CollectResult {
        let (candidates, discoveryWarnings) = discoverSources()
        var result = CollectResult(warnings: discoveryWarnings)
        guard !candidates.isEmpty else { return result }

        var usedFiles = 0
        var truncated = 0
        var corruptLines = 0
        var corruptFiles = 0
        var sawUnknownModel = false

        func record(_ entry: TokenEntry, fileDate: Date) {
            let date = entry.timestamp ?? fileDate
            let dayKey = Self.localDayKey(date, calendar: calendar)
            var bucket = result.daily[dayKey] ?? DayBucket()
            bucket.input += entry.input
            bucket.output += entry.output
            bucket.cacheRead += entry.cacheRead
            bucket.cacheWrite += entry.cacheWrite
            let (cost, known) = Self.estimateCost(
                input: entry.input,
                output: entry.output,
                cacheRead: entry.cacheRead,
                cacheWrite: entry.cacheWrite,
                model: entry.model
            )
            if !known { sawUnknownModel = true }
            bucket.cost += cost
            result.daily[dayKey] = bucket

            if result.minDay == nil || dayKey < result.minDay! { result.minDay = dayKey }
            if result.maxDay == nil || dayKey > result.maxDay! { result.maxDay = dayKey }
            if let ts = entry.timestamp {
                if result.latestEventDate == nil || ts > result.latestEventDate! {
                    result.latestEventDate = ts
                }
            }
        }

        for candidate in candidates {
            let fileDate = Date(timeIntervalSince1970: candidate.mtime)
            var fileUsed = false

            switch candidate.kind {
            case .antigravity:
                guard let (data, wasTruncated) = readTailData(candidate.url) else {
                    corruptFiles += 1
                    continue
                }
                if wasTruncated { truncated += 1 }
                for rawLine in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                    let lineData = Data(rawLine)
                    guard let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                        corruptLines += 1
                        continue
                    }
                    if let entry = parseAntigravityEvent(event) {
                        record(entry, fileDate: fileDate)
                        fileUsed = true
                    }
                }

            case .geminiCLI:
                guard let entries = parseCLISessionFile(candidate.url) else {
                    corruptFiles += 1
                    continue
                }
                for entry in entries {
                    record(entry, fileDate: fileDate)
                    fileUsed = true
                }
            }

            if fileUsed { usedFiles += 1 }
        }

        if truncated > 0 {
            result.warnings.append("有 \(truncated) 个 Gemini 会话日志超过 8MB，只统计了末尾 8MB，可能漏掉更早记录")
        }
        if corruptFiles > 0 {
            result.warnings.append("跳过 \(corruptFiles) 个无法解析的 Gemini 会话文件")
        }
        if corruptLines > 0 {
            result.warnings.append("有 \(corruptLines) 行 Gemini 会话日志无法解析，已跳过")
        }
        if sawUnknownModel {
            result.warnings.append("部分用量未标注公开定价模型，花费按 Gemini Pro 公开牌价兜底估算")
        }
        if usedFiles == 0 {
            result.warnings.append("会话日志里没有可识别的 Gemini token 用量记录")
        }
        return result
    }

    private func readTailData(_ url: URL) -> (Data, Bool)? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            if size <= maxScanBytes {
                try handle.seek(toOffset: 0)
                return (try handle.readToEnd() ?? Data(), false)
            }
            try handle.seek(toOffset: size - maxScanBytes)
            let raw = try handle.readToEnd() ?? Data()
            // 丢弃截断的首行，避免误判损坏行
            if let newlineIdx = raw.firstIndex(of: UInt8(ascii: "\n")) {
                let next = raw.index(after: newlineIdx)
                return (Data(raw[next...]), true)
            }
            return (Data(), true)
        } catch {
            return nil
        }
    }

    private func parseAntigravityEvent(_ event: [String: Any]) -> TokenEntry? {
        let model = (event["model"] as? String) ?? ""
        if model == "<synthetic>" { return nil }

        let keys = [
            "input_tokens",
            "output_tokens",
            "cache_read_tokens",
            "cache_write_tokens",
            "cache_creation_input_tokens",
            "thoughts_tokens",
            "thought_tokens",
        ]
        guard keys.contains(where: { Self.asNonNegativeDouble(event[$0]) != nil }) else {
            return nil
        }

        let input = Self.asNonNegativeDouble(event["input_tokens"]) ?? 0
        let output = (Self.asNonNegativeDouble(event["output_tokens"]) ?? 0)
            + (Self.asNonNegativeDouble(event["thoughts_tokens"]) ?? Self.asNonNegativeDouble(event["thought_tokens"]) ?? 0)
        let cacheRead = Self.asNonNegativeDouble(event["cache_read_tokens"]) ?? 0
        let cacheWrite = Self.asNonNegativeDouble(event["cache_write_tokens"])
            ?? Self.asNonNegativeDouble(event["cache_creation_input_tokens"])
            ?? 0
        guard input + output + cacheRead + cacheWrite > 0 else { return nil }

        let timestamp = (event["created_at"] as? String).flatMap(ProbeDate.parse)
            ?? (event["timestamp"] as? String).flatMap(ProbeDate.parse)
        return TokenEntry(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            model: model,
            timestamp: timestamp
        )
    }

    private func parseCLISessionFile(_ url: URL) -> [TokenEntry]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              size <= maxScanBytes,
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let messages = root["messages"] as? [Any] else { return [] }

        let fallbackModel = (root["model"] as? String) ?? ""
        let fallbackDate = (root["lastUpdated"] as? String).flatMap(ProbeDate.parse)
            ?? (root["startTime"] as? String).flatMap(ProbeDate.parse)

        var entries: [TokenEntry] = []
        for item in messages {
            guard let msg = item as? [String: Any],
                  let tokens = msg["tokens"] as? [String: Any] else { continue }

            let rawInput = Self.asNonNegativeDouble(tokens["input"]) ?? 0
            let cached = Self.asNonNegativeDouble(tokens["cached"]) ?? 0
            let tool = Self.asNonNegativeDouble(tokens["tool"]) ?? 0
            let output = Self.asNonNegativeDouble(tokens["output"]) ?? 0
            let thoughts = Self.asNonNegativeDouble(tokens["thoughts"]) ?? 0

            let uncachedInput = max(0, rawInput - cached) + tool
            let totalOutput = output + thoughts
            guard uncachedInput + totalOutput + cached > 0 else { continue }

            let rawModel = msg["model"] as? String
            let model = (rawModel?.isEmpty == false) ? rawModel! : fallbackModel
            if model == "<synthetic>" { continue }

            let timestamp = (msg["timestamp"] as? String).flatMap(ProbeDate.parse) ?? fallbackDate
            entries.append(TokenEntry(
                input: uncachedInput,
                output: totalOutput,
                cacheRead: cached,
                cacheWrite: 0,
                model: model,
                timestamp: timestamp
            ))
        }
        return entries
    }

    // MARK: - 定价与格式化

    static func priceFamily(for model: String) -> (family: String, known: Bool) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("pro", false) }
        let lowered = trimmed.lowercased()
        if lowered.contains("flash-lite") || lowered.contains("flash_lite") || lowered.contains("lite") {
            return ("flash-lite", true)
        }
        if lowered.contains("flash") {
            return ("flash", true)
        }
        if lowered.contains("pro") {
            return ("pro", true)
        }
        return ("pro", false)
    }

    private static func estimateCost(
        input: Double,
        output: Double,
        cacheRead: Double,
        cacheWrite: Double,
        model: String
    ) -> (Double, Bool) {
        let (family, known) = priceFamily(for: model)
        let tier = pricing[family] ?? pricing["pro"]!
        let cost = (
            input * tier.input
                + output * tier.output
                + cacheRead * tier.cacheRead
                + cacheWrite * tier.cacheWrite
        ) / 1_000_000.0
        return (cost, known)
    }

    private static func asNonNegativeDouble(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let d = number.doubleValue
            return (d.isFinite && d >= 0) ? d : nil
        }
        if let raw = value as? String, let d = Double(raw), d.isFinite, d >= 0 {
            return d
        }
        return nil
    }

    private static func localDayKey(_ date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private static func round4(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }
}
