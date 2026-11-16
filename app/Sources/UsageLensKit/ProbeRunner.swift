import Foundation

// MARK: - 探针输出

public struct ProbeReport: Sendable {
    public var provider: Provider
    /// 能解析出来的 JSON（即使探针 exit 非 0 也可能有，带着 error / warnings）。
    public var envelope: ProbeEnvelope?
    /// 人话失败原因；nil = 这次探针成功。
    public var failure: String?
    public var warnings: [String]
    public var finishedAt: Date
    /// 探针脚本本身不存在 —— 按「无数据」处理，不算错误。
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
        // 进 UI 的失败文案与 warnings 统一在这里脱敏（stderr 也经由 failure 进来）。
        self.failure = failure.map(SecretRedactor.redact)
        // 没显式给 warnings 时沿用 JSON 里的，避免调用方漏传。
        let rawWarnings = warnings.isEmpty ? (envelope?.warnings ?? []) : warnings
        self.warnings = rawWarnings.map(SecretRedactor.redact)
        self.finishedAt = finishedAt
        self.isMissingProbe = isMissingProbe
        self.isIncompatibleSchema = isIncompatibleSchema
        self.duration = duration
    }
}

/// 探针数据来源的抽象：正常运行是 ProbeRunner，测试里可以喂固定结果。
public protocol ProbeProviding: Sendable {
    func report(for provider: Provider) async -> ProbeReport
}

// MARK: - 仓库根定位

/// 按仓库根相对定位探针：从 App bundle / 可执行文件所在位置向上找，
/// 找到含 `probes/` 或 `docs/ARCHITECTURE.md` 的目录为止。
/// 不硬编码任何用户家目录；`USAGE_LENS_ROOT` 仅供开发与测试指定根目录。
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

// MARK: - 执行探针

/// 定位脚本、运行并解析 stdout。DeepSeek 凭据只从钥匙串传给 DeepSeek 探针子进程。
public struct ProbeRunner: ProbeProviding {
    public var root: URL?
    public var timeout: TimeInterval

    public init(root: URL? = nil, timeout: TimeInterval = 6) {
        self.root = root
        self.timeout = timeout
    }

    public func report(for provider: Provider) async -> ProbeReport {
        await report(for: provider, environmentOverrides: [:])
    }

    /// 候选密钥验证时传入仅供本次子进程使用的环境变量，不会写入钥匙串。
    public func report(
        for provider: Provider,
        environmentOverrides: [String: String]
    ) async -> ProbeReport {
        let started = Date()
        let resolvedRoot = root ?? RepoLocator.locate()

        guard let resolvedRoot else {
            return ProbeReport(
                provider: provider,
                failure: "未找到仓库根目录（probes/ 不在其中）",
                finishedAt: started,
                isMissingProbe: true
            )
        }

        let probeURL = resolvedRoot.appendingPathComponent(provider.probeRelativePath)
        guard FileManager.default.fileExists(atPath: probeURL.path) else {
            return ProbeReport(
                provider: provider,
                failure: "未安装探针 \(provider.probeRelativePath)",
                finishedAt: started,
                isMissingProbe: true
            )
        }

        let execution = await execute(
            probe: probeURL,
            workingDirectory: resolvedRoot,
            timeout: timeout,
            provider: provider,
            environmentOverrides: environmentOverrides
        )
        let duration = Date().timeIntervalSince(started)

        switch execution {
        case .failedToStart(let message):
            return ProbeReport(provider: provider, failure: "探针无法启动：\(message)", finishedAt: Date(), duration: duration)
        case .output(let output):
            if output.overflowed {
                return ProbeReport(
                    provider: provider,
                    failure: "探针输出超限（>8MB/流），已终止",
                    finishedAt: Date(),
                    duration: duration
                )
            }
            if output.timedOut {
                return ProbeReport(provider: provider, failure: "探针超时（>\(Int(timeout))s）", finishedAt: Date(), duration: duration)
            }
            if output.drainTimedOut {
                return ProbeReport(
                    provider: provider,
                    failure: "探针输出未正常关闭（子进程仍持有管道），本次结果不可信",
                    finishedAt: Date(),
                    duration: duration
                )
            }
            return decode(
                provider: provider,
                stdout: String(decoding: output.stdout, as: UTF8.self),
                stderr: String(decoding: output.stderr, as: UTF8.self),
                status: output.status,
                finishedAt: Date(),
                duration: duration
            )
        }
    }

    // MARK: 解析

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

        // schema 不符 = 整份输出非法：不保留任何数字，也不当成「上次成功值」。
        if let mismatch = envelope.schemaMismatch {
            return ProbeReport(
                provider: provider,
                failure: "探针输出格式不兼容（\(mismatch)）",
                finishedAt: finishedAt,
                duration: duration,
                isIncompatibleSchema: true
            )
        }

        // 探针的失败信息以 JSON 里的 `error` / `warnings` 为准。
        // exit code 只在拿不到 JSON 时作为补充线索，避免把「exit 非 0 但给了数据」误判成无数据。
        let failure = envelope.error.flatMap { $0.isEmpty ? nil : $0 }
        return ProbeReport(
            provider: provider,
            envelope: envelope,
            failure: failure,
            finishedAt: finishedAt,
            duration: duration
        )
    }

    // MARK: 进程

    /// 每流输出上限：死循环输出不许把内存吃穿。
    static let outputLimit = 8 * 1024 * 1024
    /// 进程退出后等读端收尾的上限；到点直接停掉读取，主流程不再等。
    static let drainTimeout: TimeInterval = 2

    /// 边跑边排空两条管道，再等进程退出 + 超时。
    /// 关键点：
    /// 1. 绝不能先 `waitUntilExit()` 再读（>64KB 会死锁）；
    /// 2. 等 reader 的上限必须真的可超时，不能挂在不可取消的 continuation 上；
    /// 3. 子进程继承管道时，到点直接停读（等价于关读端），别等它退出。
    func execute(
        probe: URL,
        workingDirectory: URL,
        timeout: TimeInterval,
        provider: Provider? = nil,
        environmentOverrides: [String: String] = [:]
    ) async -> ProbeProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", probe.path]
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        // 契约要求 stdout 无颜色码；这里兜底，免得解析被 ANSI 污染。
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        if provider?.id == ProviderCatalog.deepseek.id,
           let key = DeepSeekAPIKeyStore.load() {
            // 仅注入 DeepSeek 探针；不会传给 Codex 或写入日志 / 文件。
            environment["DEEPSEEK_API_KEY"] = key
        }
        // 仅用于保存前验证候选密钥；优先级高于钥匙串，绝不落盘。
        for (name, value) in environmentOverrides {
            environment[name] = value
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return .failedToStart(error.localizedDescription)
        }

        let stdoutBuffer = LockedOutputBuffer(limit: Self.outputLimit)
        let stderrBuffer = LockedOutputBuffer(limit: Self.outputLimit)
        let readers = DispatchGroup()
        let stdoutDrainer = PipeDrainer(pipe: stdoutPipe, buffer: stdoutBuffer, group: readers)
        let stderrDrainer = PipeDrainer(pipe: stderrPipe, buffer: stderrBuffer, group: readers)
        stdoutDrainer.start()
        stderrDrainer.start()

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        var overflowed = false

        while process.isRunning && Date() < deadline {
            if stdoutBuffer.overflows || stderrBuffer.overflows {
                // 输出超限：立刻杀，不再等它自然结束。
                overflowed = true
                stdoutDrainer.stop()
                stderrDrainer.stop()
                Self.terminate(process)
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if !overflowed && process.isRunning {
            timedOut = true
            Self.terminate(process)
        }

        // 等 reader 收尾：有上限，到点就停读，主流程立刻继续（不会挂 20s）。
        var drainTimedOut = false
        if !overflowed {
            let drained = await Self.waitForReaders(readers, timeout: Self.drainTimeout)
            if !drained {
                drainTimedOut = true
                stdoutDrainer.stop()
                stderrDrainer.stop()
            }
        }

        if !process.isRunning {
            process.waitUntilExit()
        }

        return .output(
            ProbeProcessOutput(
                stdout: stdoutBuffer.snapshot,
                stderr: stderrBuffer.snapshot,
                status: process.isRunning ? -1 : process.terminationStatus,
                timedOut: timedOut,
                overflowed: overflowed || stdoutBuffer.overflows || stderrBuffer.overflows,
                drainTimedOut: drainTimedOut
            )
        )
    }

    /// terminate + 短暂等待 + SIGKILL；绝不阻塞超过 ~600ms。
    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let giveUp = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < giveUp {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// 在后台线程上做 `group.wait(timeout:)`，主流程拿到结果就返回。
    /// 不能用 `withTaskGroup` + continuation：group 退出时会等那个不可取消的 continuation。
    private static func waitForReaders(_ group: DispatchGroup, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = group.wait(timeout: .now() + timeout)
                continuation.resume(returning: result == .success)
            }
        }
    }
}

// MARK: - 进程输出

struct ProbeProcessOutput: Sendable {
    var stdout: Data
    var stderr: Data
    var status: Int32
    var timedOut: Bool
    var overflowed: Bool
    var drainTimedOut: Bool
}

enum ProbeProcessResult: Sendable {
    case failedToStart(String)
    case output(ProbeProcessOutput)
}

/// 两条管道各有一个读取器；用锁拼块，并带字节上限。
private final class LockedOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var didOverflow = false

    init(limit: Int) {
        self.limit = limit
    }

    /// 返回 false 表示超限，调用方应停止读取。
    func append(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didOverflow else { return false }
        if storage.count + chunk.count > limit {
            didOverflow = true
            return false
        }
        storage.append(chunk)
        return true
    }

    var overflows: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didOverflow
    }

    var snapshot: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// 用 readabilityHandler 读管道：回调只做非阻塞可用数据拷贝，停读时不会卡在阻塞 read 上。
private final class PipeDrainer {
    private let handle: FileHandle
    private let buffer: LockedOutputBuffer
    private let group: DispatchGroup
    private let stateLock = NSLock()
    private var finished = false

    init(pipe: Pipe, buffer: LockedOutputBuffer, group: DispatchGroup) {
        self.handle = pipe.fileHandleForReading
        self.buffer = buffer
        self.group = group
        group.enter()
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            self?.consume(handle)
        }
    }

    /// 停读：等价于关掉读端，强制 reader 不再等待（进程/孙进程是否活着都不影响）。
    func stop() {
        handle.readabilityHandler = nil
        finish()
    }

    private func consume(_ handle: FileHandle) {
        let chunk = handle.availableData
        if chunk.isEmpty {
            handle.readabilityHandler = nil
            finish()
            return
        }
        if !buffer.append(chunk) {
            handle.readabilityHandler = nil
            finish()
        }
    }

    private func finish() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !finished else { return }
        finished = true
        group.leave()
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
