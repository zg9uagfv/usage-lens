import Foundation

// MARK: - 探针输出

public struct ProbeReport: Sendable {
    public var provider: Provider
    /// 采集结果（可能附带 error / warnings）。
    public var envelope: ProbeEnvelope?
    /// 人话失败原因；nil = 这次探针成功。
    public var failure: String?
    public var warnings: [String]
    public var finishedAt: Date
    /// 该厂商尚未内置原生探针 —— 按「无数据」处理，不算运行错误。
    public var isMissingProbe: Bool
    /// schema 不是 usage-lens/probe@1：整份输出作废，不展示任何数字。
    public var isIncompatibleSchema: Bool
    public var duration: TimeInterval

    public init(
        provider: Provider,
        envelope: ProbeEnvelope? = nil,
        failure: String? = nil,
        warnings: [String] = [],
        finishedAt: Date = Date(),
        isMissingProbe: Bool = false,
        duration: TimeInterval = 0,
        isIncompatibleSchema: Bool = false
    ) {
        self.provider = provider
        self.envelope = envelope
        // 进 UI 的失败文案与 warnings 统一在这里脱敏。
        self.failure = failure.map(SecretRedactor.redact)
        let rawWarnings = warnings.isEmpty ? (envelope?.warnings ?? []) : warnings
        self.warnings = rawWarnings.map(SecretRedactor.redact)
        self.finishedAt = finishedAt
        self.isMissingProbe = isMissingProbe
        self.isIncompatibleSchema = isIncompatibleSchema
        self.duration = duration
    }
}

/// 探针数据来源的抽象：正常运行是纯 Swift `ProbeRunner`，测试里可以喂固定结果。
public protocol ProbeProviding: Sendable {
    func report(for provider: Provider) async -> ProbeReport
}

// MARK: - 纯 Swift 原生探针调度器

/// 直接在进程内调用各厂商的纯 Swift 探针（零 Python 依赖、零子进程开销）。
/// DeepSeek 凭据仅在内存内从 macOS 钥匙串读取并用于官方余额请求，不落盘、不进日志。
public struct ProbeRunner: ProbeProviding {
    public let codex: CodexProbe
    public let gemini: GeminiProbe
    public let deepseek: DeepSeekProbe

    public init(
        codex: CodexProbe = CodexProbe(),
        gemini: GeminiProbe = GeminiProbe(),
        deepseek: DeepSeekProbe = DeepSeekProbe()
    ) {
        self.codex = codex
        self.gemini = gemini
        self.deepseek = deepseek
    }

    public func report(for provider: Provider) async -> ProbeReport {
        await report(for: provider, apiKeyOverride: nil)
    }

    /// 候选密钥验证时传入仅供本次内存请求使用的 API Key，不会写入钥匙串。
    public func report(
        for provider: Provider,
        apiKeyOverride: String?
    ) async -> ProbeReport {
        switch provider.id {
        case ProviderCatalog.codex.id:
            let probe = self.codex
            return await Task.detached(priority: .utility) { probe.run() }.value

        case ProviderCatalog.gemini.id:
            let probe = self.gemini
            return await Task.detached(priority: .utility) { probe.run() }.value

        case ProviderCatalog.deepseek.id:
            let key = apiKeyOverride
                ?? DeepSeekAPIKeyStore.load()
                ?? ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
            return await deepseek.run(apiKey: key)

        default:
            return ProbeReport(
                provider: provider,
                failure: "暂未内置 \(provider.displayName) 探针",
                finishedAt: Date(),
                isMissingProbe: true
            )
        }
    }

    // MARK: - 契约 JSON 校验（供兼容解析与单测使用）

    func decode(
        provider: Provider,
        stdout: String,
        stderr: String,
        status: Int32,
        finishedAt: Date,
        duration: TimeInterval
    ) -> ProbeReport {
        guard let envelope = ProbeJSON.decode(stdout) else {
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty
                ? "探针没有输出内容"
                : "探针输出无法解析为 JSON"
            let stderrLine = ProbeJSON.firstMeaningfulLine(stderr)
            let failure: String
            if let stderrLine {
                failure = "\(detail)（\(stderrLine)）"
            } else if status != 0 {
                failure = "\(detail)（退出码 \(status)）"
            } else {
                failure = detail
            }
            return ProbeReport(provider: provider, failure: failure, finishedAt: finishedAt, duration: duration)
        }

        if let mismatch = envelope.schemaMismatch {
            return ProbeReport(
                provider: provider,
                failure: "探针输出格式不兼容（\(mismatch)）",
                finishedAt: finishedAt,
                duration: duration,
                isIncompatibleSchema: true
            )
        }

        let failure = envelope.error.flatMap { $0.isEmpty ? nil : $0 }
        return ProbeReport(
            provider: provider,
            envelope: envelope,
            failure: failure,
            finishedAt: finishedAt,
            duration: duration
        )
    }
}

// MARK: - JSON 容错

public enum ProbeJSON {
    /// 解析 JSON：正常是单个对象；也容忍前后有杂行（取第一个能解析的对象）。
    public static func decode(_ stdout: String) -> ProbeEnvelope? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(ProbeEnvelope.self, from: Data(trimmed.utf8)) {
            return envelope
        }

        for line in trimmed.split(separator: "\n", omittingEmptySubsequences: true) {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard candidate.hasPrefix("{"), candidate.hasSuffix("}") else { continue }
            if let envelope = try? decoder.decode(ProbeEnvelope.self, from: Data(candidate.utf8)) {
                return envelope
            }
        }
        return nil
    }

    /// 取文本里第一行有内容的话，截断到 120 字。
    public static func firstMeaningfulLine(_ text: String) -> String? {
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            return line.count > 120 ? String(line.prefix(120)) + "…" : line
        }
        return nil
    }
}
