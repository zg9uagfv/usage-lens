import Foundation

/// 纯 Swift Codex 本地日志探针。
///
/// 只读 `~/.codex/sessions/**/rollout-*.jsonl`，不读 `~/.codex/auth.json`，不发网络，不写文件。
/// 选帧规则：在候选日志里取「事件时间戳最大」的 `rate_limits` 帧（按 mtime 倒序扫，
/// 一旦已命中帧且某文件 mtime 早于该帧时间即剪枝停止，同秒 mtime 下结果仍由内容决定）。
public struct CodexProbe: Sendable {
    public let sessionsDirectory: URL
    public let maxScanBytes: UInt64
    public let maxCandidateFiles: Int
    public let todayTokenScanFiles: Int
    private let nowProvider: @Sendable () -> Date

    private static let tailChunkBytes: UInt64 = 256 * 1024

    public init(
        sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        maxScanBytes: UInt64 = 4 * 1024 * 1024,
        maxCandidateFiles: Int = 50,
        todayTokenScanFiles: Int = 50,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.maxScanBytes = maxScanBytes
        self.maxCandidateFiles = maxCandidateFiles
        self.todayTokenScanFiles = todayTokenScanFiles
        self.nowProvider = now
    }

    public func run() -> ProbeReport {
        let started = Date()
        let now = nowProvider()
        var warnings: [String] = []

        let (frame, scanWarnings) = findLatestFrame()
        warnings.append(contentsOf: scanWarnings)

        let (todayTokens, tokenWarnings) = findTodayTokens(now: now)
        warnings.append(contentsOf: tokenWarnings)

        var observedAt = now
        var windows: [ProbeWindow] = []
        var plan: String?
        var coverage: ProbeCoverage?
        var stale = false

        if let frame {
            let rateLimits = frame.rateLimits
            if let epoch = frame.epoch {
                observedAt = Date(timeIntervalSince1970: epoch)
            }
            for key in ["primary", "secondary"] {
                if let entry = buildWindow(key: key, rateLimits: rateLimits, now: now, observedAt: observedAt, warnings: &warnings) {
                    windows.append(entry)
                }
            }
            if let planValue = rateLimits["plan_type"] as? String, !planValue.isEmpty {
                plan = planValue
            }
            if !windows.isEmpty {
                let frameDay = Self.utcDayString(observedAt)
                coverage = ProbeCoverage(
                    from: frameDay,
                    to: frameDay,
                    note: "仅最后一帧窗口数据，非官方账单"
                )
                let frameEpoch = frame.epoch ?? now.timeIntervalSince1970
                let age = now.timeIntervalSince1970 - frameEpoch
                let threshold = windows.compactMap(\.windowSeconds).min() ?? 18_000
                stale = age > Double(threshold)
                if stale {
                    warnings.append(
                        "数据来自 \(Self.utcISOString(observedAt))（\(Self.humanAge(age))），已超过 \(max(threshold / 3600, 1)) 小时窗口，可能不是当前状态"
                    )
                }
            }
        }

        let usage: ProbeUsage? = todayTokens.map { ProbeUsage(todayTokens: $0, source: "local") }
        let envelope = ProbeEnvelope(
            schema: probeSchema,
            provider: ProviderCatalog.codex.id,
            account: ProbeAccount(label: nil, plan: plan),
            generatedAt: now,
            observedAt: observedAt,
            stale: stale,
            windows: windows,
            balance: nil,
            spend: nil,
            usage: usage,
            coverage: coverage,
            warnings: warnings,
            error: nil
        )

        return ProbeReport(
            provider: ProviderCatalog.codex,
            envelope: envelope,
            failure: nil,
            warnings: warnings,
            finishedAt: Date(),
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: - 选帧

    private struct RateLimitFrame {
        let rateLimits: [String: Any]
        let epoch: TimeInterval?
        let fallbackEpoch: TimeInterval
        let pathKey: String
    }

    private func findLatestFrame() -> (RateLimitFrame?, [String]) {
        var warnings: [String] = []
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            return (nil, ["未找到 ~/.codex/sessions 目录（Codex 可能未安装或从未运行）"])
        }

        let rolloutFiles = listRolloutFiles()
        if rolloutFiles.isEmpty {
            return (nil, ["~/.codex/sessions 下没有 rollout-*.jsonl 会话日志"])
        }

        var candidates: [(mtime: TimeInterval, name: String, url: URL, size: UInt64)] = []
        for url in rolloutFiles {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let modDate = attrs[.modificationDate] as? Date else {
                warnings.append("跳过 1 个无法读取的日志文件")
                continue
            }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            candidates.append((modDate.timeIntervalSince1970, url.path, url, size))
        }
        if candidates.isEmpty {
            warnings.append("没有可读的 Codex 会话日志")
            return (nil, warnings)
        }

        candidates.sort { lhs, rhs in
            if lhs.mtime != rhs.mtime { return lhs.mtime > rhs.mtime }
            return lhs.name > rhs.name
        }
        if candidates.count > maxCandidateFiles {
            warnings.append("Codex 会话日志较多，只检查最近 \(maxCandidateFiles) 个")
            candidates = Array(candidates.prefix(maxCandidateFiles))
        }

        var best: RateLimitFrame?
        var bestKey: (TimeInterval, String)?
        var truncated = 0
        var corruptLines = 0

        for item in candidates {
            if let current = best, item.mtime < (current.epoch ?? current.fallbackEpoch) {
                break
            }
            guard let (parsed, corrupt) = lastFrameInFile(item.url) else {
                warnings.append("跳过 1 个无法读取的日志")
                continue
            }
            corruptLines += corrupt
            guard let parsed else {
                if item.size > maxScanBytes {
                    truncated += 1
                }
                continue
            }
            let frame = RateLimitFrame(
                rateLimits: parsed.rateLimits,
                epoch: parsed.epoch,
                fallbackEpoch: item.mtime,
                pathKey: item.name
            )
            let key = (frame.epoch ?? item.mtime, item.name)
            if bestKey == nil || key.0 > bestKey!.0 || (key.0 == bestKey!.0 && key.1 > bestKey!.1) {
                best = frame
                bestKey = key
            }
        }

        if best == nil {
            var message = "最近的 Codex 会话日志里没有 rate_limits 记录"
            if corruptLines > 0 {
                message += "（另有 \(corruptLines) 行日志无法解析）"
            }
            warnings.append(message)
        }
        if truncated > 0 {
            warnings.append("有 \(truncated) 个会话日志超过 4MB，只回扫了末尾部分，可能漏掉更早的帧")
        }
        return (best, warnings)
    }

    private func lastFrameInFile(_ url: URL) -> ((rateLimits: [String: Any], epoch: TimeInterval?)?, Int)? {
        var found: (rateLimits: [String: Any], epoch: TimeInterval?)?
        var corruptLines = 0
        do {
            try Self.forEachLineReverse(in: url, maxBytes: maxScanBytes, chunkBytes: Self.tailChunkBytes) { lineData in
                guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    corruptLines += 1
                    return true
                }
                guard (obj["type"] as? String) == "event_msg",
                      let payload = obj["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count",
                      let rateLimits = payload["rate_limits"] as? [String: Any] else {
                    return true
                }
                let epoch = (obj["timestamp"] as? String).flatMap(ProbeDate.parse)?.timeIntervalSince1970
                found = (rateLimits, epoch)
                return false
            }
        } catch {
            return nil
        }
        return (found, corruptLines)
    }

    // MARK: - 今日 tokens

    private func findTodayTokens(now: Date) -> (Int?, [String]) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            return (nil, [])
        }

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)

        var candidates: [(mtime: TimeInterval, url: URL, size: UInt64)] = []
        for url in listRolloutFiles() {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let modDate = attrs[.modificationDate] as? Date {
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                candidates.append((modDate.timeIntervalSince1970, url, size))
            }
        }
        candidates.sort { $0.mtime > $1.mtime }
        candidates = Array(candidates.prefix(todayTokenScanFiles))

        var total = 0
        var found = false
        var truncated = 0

        for item in candidates {
            let modDate = Date(timeIntervalSince1970: item.mtime)
            if modDate < todayStart {
                break
            }
            do {
                try Self.forEachLineReverse(in: item.url, maxBytes: maxScanBytes, chunkBytes: Self.tailChunkBytes) { lineData in
                    if let tokens = parseTodayTokenRecord(lineData, calendar: calendar, now: now) {
                        total += tokens
                        found = true
                    }
                    return true
                }
                if item.size > maxScanBytes {
                    truncated += 1
                }
            } catch {
                continue
            }
        }

        var warnings: [String] = []
        if truncated > 0 {
            warnings.append("今日 tokens 仅扫描了 \(truncated) 个大日志的末尾 4MB，统计可能不完整")
        }
        return (found ? total : nil, warnings)
    }

    private func parseTodayTokenRecord(_ data: Data, calendar: Calendar, now: Date) -> Int? {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let payload = event["payload"] as? [String: Any]
        let payloadType = payload?["type"] as? String
        guard (event["type"] as? String) == "token_usage_record" || payloadType == "token_usage_record" else {
            return nil
        }
        guard let ts = event["timestamp"] as? String,
              let date = ProbeDate.parse(ts),
              calendar.isDate(date, inSameDayAs: now) else {
            return nil
        }
        let usage = (payload?["usage"] as? [String: Any]) ?? (event["usage"] as? [String: Any])
        guard let usage, let value = Self.finiteNonNegativeDouble(usage["total_tokens"]) else {
            return nil
        }
        return Int(value)
    }

    // MARK: - 窗口拼装

    private func buildWindow(
        key: String,
        rateLimits: [String: Any],
        now: Date,
        observedAt: Date,
        warnings: inout [String]
    ) -> ProbeWindow? {
        guard let raw = rateLimits[key] as? [String: Any] else { return nil }
        let spec: (id: String, label: String, defaultSeconds: Int) = key == "primary"
            ? ("5h", "5 小时", 18_000)
            : ("7d", "7 天", 604_800)

        var windowSeconds = spec.defaultSeconds
        if let minutes = Self.finitePositiveDouble(raw["window_minutes"]) {
            windowSeconds = Int(minutes * 60.0)
        }

        var resetsDate: Date?
        if let resetsEpoch = Self.finitePositiveDouble(raw["resets_at"]) {
            resetsDate = Date(timeIntervalSince1970: resetsEpoch)
        }

        var expired = false
        if let resetsDate, resetsDate < now {
            expired = true
            let dateStr = Self.utcMonthDayString(observedAt)
            warnings.append(
                "\(spec.label)窗口已于 \(Self.humanAge(now.timeIntervalSince(resetsDate)))重置（数据来自 \(dateStr)）"
            )
        }

        let usedPercent = Self.cleanPercent(raw["used_percent"], label: spec.label, warnings: &warnings)

        return ProbeWindow(
            id: spec.id,
            label: spec.label,
            usedPercent: usedPercent,
            windowSeconds: windowSeconds,
            resetsAt: resetsDate,
            expired: expired,
            basis: "server"
        )
    }

    // MARK: - 工具方法

    private func listRolloutFiles() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                results.append(url)
            }
        }
        return results
    }

    /// 从文件末尾按块回扫，逐行（倒序）回调；返回 false 即停止扫描。
    static func forEachLineReverse(
        in url: URL,
        maxBytes: UInt64,
        chunkBytes: UInt64,
        body: (Data) -> Bool
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var position = try handle.seekToEnd()
        var buffered = Data()
        var consumed: UInt64 = 0

        while position > 0 && consumed < maxBytes {
            let step = min(chunkBytes, position)
            position -= step
            consumed += step
            try handle.seek(toOffset: position)
            let chunk = try handle.read(upToCount: Int(step)) ?? Data()
            var combined = Data(capacity: chunk.count + buffered.count)
            combined.append(chunk)
            combined.append(buffered)

            let parts = combined.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            buffered = parts.first.map(Data.init) ?? Data()
            for part in parts.dropFirst().reversed() {
                if let trimmed = trimWhitespace(part), !trimmed.isEmpty {
                    if !body(trimmed) { return }
                }
            }
        }
        // 仅在扫描到文件头部时才处理剩余缓冲，避免把字节上限截断的半行误判为损坏行。
        if position == 0, let trimmed = trimWhitespace(buffered), !trimmed.isEmpty {
            _ = body(trimmed)
        }
    }

    private static func trimWhitespace(_ slice: Data.SubSequence) -> Data? {
        guard let first = slice.firstIndex(where: { !isASCIIWhitespace($0) }),
              let last = slice.lastIndex(where: { !isASCIIWhitespace($0) }) else {
            return nil
        }
        return Data(slice[first...last])
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }

    private static func isBoolNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func finitePositiveDouble(_ value: Any?) -> Double? {
        guard let value, !isBoolNumber(value), let number = value as? NSNumber else { return nil }
        let d = number.doubleValue
        return (d.isFinite && d > 0) ? d : nil
    }

    private static func finiteNonNegativeDouble(_ value: Any?) -> Double? {
        guard let value, !isBoolNumber(value), let number = value as? NSNumber else { return nil }
        let d = number.doubleValue
        return (d.isFinite && d >= 0) ? d : nil
    }

    private static func cleanPercent(_ value: Any?, label: String, warnings: inout [String]) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        guard !isBoolNumber(value), let number = value as? NSNumber else { return nil }
        let d = number.doubleValue
        if !d.isFinite || d < 0 || d > 100 {
            warnings.append("\(label)的 used_percent 数值异常（\(value)，不在 0-100），已置空")
            return nil
        }
        return (d * 100).rounded() / 100
    }

    private static func humanAge(_ seconds: TimeInterval) -> String {
        if seconds >= 86_400 { return "\(Int(seconds / 86_400)) 天前" }
        if seconds >= 3600 { return "\(Int(seconds / 3600)) 小时前" }
        if seconds >= 60 { return "\(Int(seconds / 60)) 分钟前" }
        return "刚刚"
    }

    private static func utcISOString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func utcDayString(_ date: Date) -> String {
        String(utcISOString(date).prefix(10))
    }

    private static func utcMonthDayString(_ date: Date) -> String {
        let iso = utcISOString(date)
        guard iso.count >= 10 else { return "未知日期" }
        let start = iso.index(iso.startIndex, offsetBy: 5)
        let end = iso.index(iso.startIndex, offsetBy: 10)
        return String(iso[start..<end])
    }
}
