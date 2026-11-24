import Foundation

// MARK: - 探针输出

public struct ProbeReport: Sendable {
    public var provider: Provider
    /// 能解析出来的 JSON（即使探针失败也可能带 error / warnings）。
    public var envelope: ProbeEnvelope?
    /// 人话失败原因；nil = 这次探针成功。
    public var failure: String?
    public var warnings: [String]
    public var finishedAt: Date
    /// 探针本身未安装/未接入 —— 按「无数据」处理，不算错误。
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
        // 没显式给 warnings 时沿用 envelope 里的，避免调用方漏传。
        let rawWarnings = warnings.isEmpty ? (envelope?.warnings ?? []) : warnings
        self.warnings = rawWarnings.map(SecretRedactor.redact)
        self.finishedAt = finishedAt
        self.isMissingProbe = isMissingProbe
        self.isIncompatibleSchema = isIncompatibleSchema
        self.duration = duration
    }
}

/// 探针数据来源的抽象：正常运行是原生 Swift ProbeRunner，测试里可注入假实现。
public protocol ProbeProviding: Sendable {
    func report(for provider: Provider) async -> ProbeReport
    func report(for provider: Provider, allowInteractiveKeychain: Bool) async -> ProbeReport
}

public extension ProbeProviding {
    func report(for provider: Provider, allowInteractiveKeychain: Bool) async -> ProbeReport {
        await report(for: provider)
    }
}

// MARK: - 仓库根定位（仅兼容旧工具/测试接口，原生运行时不再依赖外部 Python 脚本）

public enum RepoLocator {
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment["USAGE_LENS_ROOT"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
            if isRepoRoot(url, fileManager: fileManager) { return url }
        }

        var seeds: [URL] = [bundleURL]
        if let resourcesURL = Bundle(url: bundleURL)?.resourceURL {
            seeds.append(resourcesURL)
        }
        if let executableURL {
            seeds.append(executableURL.deletingLastPathComponent())
        }
        seeds.append(URL(fileURLWithPath: workingDirectory, isDirectory: true))

        for seed in seeds {
            var directory = seed.standardizedFileURL
            for _ in 0..<12 {
                if isRepoRoot(directory, fileManager: fileManager) { return directory }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return nil
    }

    static func isRepoRoot(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.appendingPathComponent("probes").path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return true
        }
        return fileManager.fileExists(atPath: url.appendingPathComponent("docs/ARCHITECTURE.md").path)
    }
}

// MARK: - 原生 Swift 探针编排器（零 Python 子进程）

/// 按厂商调度原生 Swift 探针并强制执行凭据/环境变量边界隔离。
public struct ProbeRunner: ProbeProviding {
    public static let defaultTimeout: TimeInterval = 6
    /// Gemini / AGY 本机凭据刷新 + 项目发现 + 配额查询最多串行 4 次 3s 请求，给足有界预算。
    public static let defaultProviderTimeouts: [String: TimeInterval] = [
        ProviderCatalog.gemini.id: 15,
        ProviderCatalog.agy.id: 15,
    ]

    public var root: URL?
    public var timeout: TimeInterval
    public var providerTimeouts: [String: TimeInterval]
    private let deepSeekAPIKeyLoader: @Sendable () -> String?
    private let geminiAccountLoader: @Sendable () -> GeminiAccount?
    private let baseEnvironmentProvider: @Sendable () -> [String: String]
    private let codexProbe: CodexNativeProbe
    private let agyProbe: AgyNativeProbe
    private let geminiProbe: GeminiNativeProbe
    private let deepSeekProbe: DeepSeekNativeProbe
    private let openCodeProbe: OpenCodeNativeProbe

    public init(
        root: URL? = nil,
        timeout: TimeInterval = defaultTimeout,
        providerTimeouts: [String: TimeInterval] = defaultProviderTimeouts,
        deepSeekAPIKeyLoader: @escaping @Sendable () -> String? = { DeepSeekAPIKeyStore.load() },
        geminiAccountLoader: @escaping @Sendable () -> GeminiAccount? = { GeminiAccountStore.load() },
        baseEnvironmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        transport: any NativeHTTPTransport = PinnedURLSessionTransport(),
        agyKeychain: any AgyKeychainReading = SystemAgyKeychainReader(),
        agyKeychainWriter: (any AgyKeychainWriting)? = nil,
        realUserHomeOverride: URL? = nil,
        agyKeychainTimeout: TimeInterval = AgyNativeProbe.defaultKeychainTimeoutSeconds,
        deepSeekZstdBinaryOverride: String? = nil,
        deepSeekZstdTimeout: TimeInterval = DeepSeekNativeProbe.zstdTimeoutSeconds,
        deepSeekScanBudget: TimeInterval = DeepSeekNativeProbe.spendScanBudgetSeconds
    ) {
        self.root = root
        self.timeout = timeout
        self.providerTimeouts = providerTimeouts
        self.deepSeekAPIKeyLoader = deepSeekAPIKeyLoader
        self.geminiAccountLoader = geminiAccountLoader
        self.baseEnvironmentProvider = baseEnvironmentProvider
        self.codexProbe = CodexNativeProbe(transport: transport)
        self.agyProbe = AgyNativeProbe(
            transport: transport,
            keychain: agyKeychain,
            keychainWriter: agyKeychainWriter,
            realUserHomeOverride: realUserHomeOverride,
            keychainTimeoutSeconds: agyKeychainTimeout
        )
        self.geminiProbe = GeminiNativeProbe(transport: transport)
        self.deepSeekProbe = DeepSeekNativeProbe(
            transport: transport,
            zstdBinaryOverride: deepSeekZstdBinaryOverride,
            zstdTimeoutSeconds: deepSeekZstdTimeout,
            spendScanBudgetSeconds: deepSeekScanBudget
        )
        self.openCodeProbe = OpenCodeNativeProbe()
    }

    public func effectiveTimeout(for provider: Provider) -> TimeInterval {
        providerTimeouts[provider.id] ?? timeout
    }

    public func report(for provider: Provider) async -> ProbeReport {
        await report(for: provider, allowInteractiveKeychain: false)
    }

    public func report(for provider: Provider, allowInteractiveKeychain: Bool) async -> ProbeReport {
        await report(for: provider, environmentOverrides: [:], allowInteractiveKeychain: allowInteractiveKeychain)
    }

    /// 候选凭据验证与单测时传入仅供本次执行的隔离环境变量，绝不落盘、绝不跨厂商泄露。
    public func report(
        for provider: Provider,
        environmentOverrides: [String: String],
        allowInteractiveKeychain: Bool = false
    ) async -> ProbeReport {
        let started = Date()
        let allowInteractive = provider.id == ProviderCatalog.agy.id && allowInteractiveKeychain
        let baseTimeout = effectiveTimeout(for: provider)
        let effectiveTimeout = allowInteractive ? max(baseTimeout, 45) : baseTimeout
        let scopedEnv = buildEnvironment(
            baseEnvironment: baseEnvironmentProvider(),
            for: provider,
            overrides: environmentOverrides
        )

        let report = await runWithTimeout(seconds: effectiveTimeout, provider: provider, started: started) {
            await self.dispatchNativeProbe(
                for: provider,
                environment: scopedEnv,
                allowInteractiveKeychain: allowInteractive
            )
        }
        return report
    }

    private func dispatchNativeProbe(
        for provider: Provider,
        environment: [String: String],
        allowInteractiveKeychain: Bool
    ) async -> ProbeReport {
        switch provider.id {
        case ProviderCatalog.codex.id:
            return await codexProbe.run(environment: environment)
        case ProviderCatalog.agy.id:
            return await agyProbe.run(
                environment: environment,
                allowInteractiveKeychain: allowInteractiveKeychain
            )
        case ProviderCatalog.gemini.id:
            return await geminiProbe.run(environment: environment)
        case ProviderCatalog.deepseek.id:
            return await deepSeekProbe.run(environment: environment)
        case ProviderCatalog.opencode.id:
            return await openCodeProbe.run(environment: environment)
        default:
            return ProbeReport(
                provider: provider,
                failure: "未安装原生探针 \(provider.id)",
                finishedAt: Date(),
                isMissingProbe: true
            )
        }
    }

    internal func runWithTimeout(
        seconds: TimeInterval,
        provider: Provider,
        started: Date,
        onBeforeAttachTimer: (@Sendable () -> Void)? = nil,
        onBeforeAttachWorkTask: (@Sendable () -> Void)? = nil,
        operation: @escaping @Sendable () async -> ProbeReport
    ) async -> ProbeReport {
        let finiteSeconds = seconds.isFinite ? seconds : Self.defaultTimeout
        let boundedSeconds = min(max(finiteSeconds, 0.05), 3_600)

        if Task.isCancelled {
            return ProbeReport(
                provider: provider,
                failure: "探针已取消",
                finishedAt: Date(),
                duration: Date().timeIntervalSince(started)
            )
        }

        let stateBox = LockedProbeRunBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let once = LockedOnceProbeContinuation(continuation)
                guard stateBox.register(once) else {
                    once.finish(
                        with: ProbeReport(
                            provider: provider,
                            failure: "探针已取消",
                            finishedAt: Date(),
                            duration: Date().timeIntervalSince(started)
                        ),
                        cancelWork: true
                    )
                    return
                }

                // 先完整配置看门狗定时器并原子挂载/激活，再启动非结构化任务，
                // 确保操作运行期间始终存在活跃看门狗，且不会释放未激活的 DispatchSourceTimer。
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
                let deadlineNs = Int(min(boundedSeconds * 1_000_000_000, Double(Int.max / 2)))
                timer.schedule(deadline: .now() + .nanoseconds(deadlineNs))
                timer.setEventHandler {
                    once.finish(
                        with: ProbeReport(
                            provider: provider,
                            failure: "探针超时（>\(Self.formattedTimeoutSeconds(finiteSeconds))s）",
                            finishedAt: Date(),
                            duration: Date().timeIntervalSince(started)
                        ),
                        cancelWork: true
                    )
                }

                onBeforeAttachTimer?()
                guard once.attachTimer(timer) else {
                    return
                }

                // 在独立非结构化任务中执行，确保超时后立即返回而非阻塞等待不可中断的系统调用。
                let workTask = Task.detached(priority: .utility) {
                    let report = await operation()
                    once.finish(with: report, cancelWork: false)
                }

                onBeforeAttachWorkTask?()
                once.attachWorkTask(workTask)
            }
        } onCancel: {
            stateBox.cancel(provider: provider, started: started)
        }
    }

    // MARK: - 厂商环境边界（最终过滤：父环境、钥匙串注入与覆盖均无法绕过）

    /// 绝不允许传递给任何当前 OAuth/本地探针的 API Key 或 ADC 凭据变量。
    private static let alwaysExcludedEnvKeys: Set<String> = [
        "GEMINI_API_KEY",
        "GOOGLE_API_KEY",
        "GOOGLE_APPLICATION_CREDENTIALS",
        "GOOGLE_CREDENTIALS",
        "CLOUDSDK_AUTH_ACCESS_TOKEN",
    ]

    /// 仅允许传递给 Gemini 探针用于项目路由上下文的 Google Cloud 项目别名。
    private static let geminiOnlyProjectKeys: Set<String> = [
        "GOOGLE_CLOUD_PROJECT",
        "GOOGLE_CLOUD_PROJECT_ID",
    ]

    /// 构造最终厂商隔离环境：合并父环境、受控钥匙串注入与覆盖后，在最后统一执行边界裁剪。
    public func buildEnvironment(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        for provider: Provider?,
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var environment = baseEnvironment

        if provider?.id == ProviderCatalog.deepseek.id {
            if let key = deepSeekAPIKeyLoader() {
                environment["DEEPSEEK_API_KEY"] = key
            }
        }
        if provider?.id == ProviderCatalog.gemini.id {
            if let account = geminiAccountLoader() {
                environment["GEMINI_ACCOUNT_EMAIL"] = account.email
                environment["GEMINI_ACCESS_TOKEN"] = account.accessToken
                if let projectID = account.projectID, !projectID.isEmpty {
                    environment["GEMINI_PROJECT_ID"] = projectID
                }
            }
        }

        for (name, value) in overrides {
            environment[name] = value
        }

        Self.enforceEnvironmentBoundary(&environment, for: provider)
        return environment
    }

    private static func enforceEnvironmentBoundary(
        _ environment: inout [String: String],
        for provider: Provider?
    ) {
        let providerID = provider?.id
        for key in Array(environment.keys) {
            if alwaysExcludedEnvKeys.contains(key) {
                environment.removeValue(forKey: key)
                continue
            }
            if key == "DEEPSEEK_API_KEY" && providerID != ProviderCatalog.deepseek.id {
                environment.removeValue(forKey: key)
                continue
            }
            if key.hasPrefix("GEMINI_") && providerID != ProviderCatalog.gemini.id {
                environment.removeValue(forKey: key)
                continue
            }
            if geminiOnlyProjectKeys.contains(key) && providerID != ProviderCatalog.gemini.id {
                environment.removeValue(forKey: key)
                continue
            }
            if key.hasPrefix("AGY_") && providerID != ProviderCatalog.agy.id {
                environment.removeValue(forKey: key)
                continue
            }
            if key.hasPrefix("CODEX_") && providerID != ProviderCatalog.codex.id {
                environment.removeValue(forKey: key)
                continue
            }
        }
    }

    // MARK: - 契约解析（保留供契约与脱敏单测使用）

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

    private static func formattedTimeoutSeconds(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "\(Int(Self.defaultTimeout))" }
        if seconds.rounded() == seconds, let exact = NativeProbeSupport.checkedInt(fromTruncating: seconds) {
            return "\(exact)"
        }
        return String(format: "%.1f", seconds)
    }
}

internal final class LockedOnceProbeContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProbeReport, Never>?
    private var timer: DispatchSourceTimer?
    private var workTask: Task<Void, Never>?
    private var settled = false
    private var shouldCancelWork = false

    init(_ continuation: CheckedContinuation<ProbeReport, Never>) {
        self.continuation = continuation
    }

    /// 原子挂载并一次性激活看门狗定时器：
    /// - 若尚未收敛：在持锁期间完成 `timer.activate()`，保证任何并发 `finish` 取出并 `cancel()` 前源已激活。
    /// - 若已提前完成/取消（或重复挂载）：清空事件回调、`cancel()` 后显式 `activate()` 一次再释放，满足 libdispatch 生命周期硬约束。
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

    func attachWorkTask(_ workTask: Task<Void, Never>) {
        let cancelNow: Bool = lock.withLock {
            if settled {
                return shouldCancelWork
            }
            self.workTask = workTask
            return false
        }
        if cancelNow {
            workTask.cancel()
        }
    }

    func finish(with report: ProbeReport, cancelWork: Bool) {
        let (cont, activeTimer, activeTask): (
            CheckedContinuation<ProbeReport, Never>?,
            DispatchSourceTimer?,
            Task<Void, Never>?
        ) = lock.withLock {
            guard !settled else { return (nil, nil, nil) }
            settled = true
            shouldCancelWork = cancelWork
            let c = continuation
            continuation = nil
            let t = timer
            timer = nil
            let w = workTask
            workTask = nil
            return (c, t, w)
        }
        activeTimer?.cancel()
        if cancelWork {
            activeTask?.cancel()
        }
        cont?.resume(returning: report)
    }
}

internal final class LockedProbeRunBox: @unchecked Sendable {
    private let lock = NSLock()
    private var once: LockedOnceProbeContinuation?
    private var cancelled = false

    func register(_ once: LockedOnceProbeContinuation) -> Bool {
        lock.withLock {
            if cancelled { return false }
            self.once = once
            return true
        }
    }

    func cancel(provider: Provider, started: Date) {
        let target: LockedOnceProbeContinuation? = lock.withLock {
            cancelled = true
            let o = once
            once = nil
            return o
        }
        target?.finish(
            with: ProbeReport(
                provider: provider,
                failure: "探针已取消",
                finishedAt: Date(),
                duration: Date().timeIntervalSince(started)
            ),
            cancelWork: true
        )
    }
}

// MARK: - JSON 容错

public enum ProbeJSON {
    /// 解析 stdout：正常是单个对象；也容忍前后有杂行（取第一个能解析的对象）。
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

    /// 取 stderr 里第一行有内容的话，截断到 120 字，避免把整段 traceback 塞进 UI。
    public static func firstMeaningfulLine(_ text: String) -> String? {
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            return line.count > 120 ? String(line.prefix(120)) + "…" : line
        }
        return nil
    }
}
