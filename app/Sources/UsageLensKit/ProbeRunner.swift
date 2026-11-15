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
    public var duration: TimeInterval

    public init(
        provider: Provider,
        envelope: ProbeEnvelope? = nil,
        failure: String? = nil,
        warnings: [String] = [],
        finishedAt: Date = Date(),
        isMissingProbe: Bool = false,
        duration: TimeInterval = 0
    ) {
        self.provider = provider
        self.envelope = envelope
        self.failure = failure
        // 没显式给 warnings 时沿用 JSON 里的，避免调用方漏传。
        self.warnings = warnings.isEmpty ? (envelope?.warnings ?? []) : warnings
        self.finishedAt = finishedAt
        self.isMissingProbe = isMissingProbe
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

/// 只做三件事：定位脚本、跑它、解析 stdout。不碰凭据、不写文件、不发网络请求。
public struct ProbeRunner: ProbeProviding {
    public var root: URL?
    public var timeout: TimeInterval

    public init(root: URL? = nil, timeout: TimeInterval = 6) {
        self.root = root
        self.timeout = timeout
    }

    public func report(for provider: Provider) async -> ProbeReport {
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

        let execution = await execute(probe: probeURL, workingDirectory: resolvedRoot, timeout: timeout)
        let duration = Date().timeIntervalSince(started)

        switch execution {
        case .failedToStart(let message):
            return ProbeReport(provider: provider, failure: "探针无法启动：\(message)", finishedAt: Date(), duration: duration)
        case .timedOut:
            return ProbeReport(provider: provider, failure: "探针超时（>\(Int(timeout))s）", finishedAt: Date(), duration: duration)
        case .finished(let stdout, let stderr, let status):
            return decode(
                provider: provider,
                stdout: stdout,
                stderr: stderr,
                status: status,
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
        var report = ProbeReport(provider: provider, finishedAt: finishedAt, duration: duration)

        guard let envelope = ProbeJSON.decode(stdout) else {
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty
                ? "探针没有输出内容"
                : "探针输出无法解析为 JSON"
            let stderrLine = ProbeJSON.firstMeaningfulLine(stderr)
            if let stderrLine {
                report.failure = "\(detail)（\(stderrLine)）"
            } else if status != 0 {
                report.failure = "\(detail)（退出码 \(status)）"
            } else {
                report.failure = detail
            }
            return report
        }

        report.envelope = envelope
        report.warnings = envelope.warnings

        if let mismatch = envelope.schemaMismatch {
            report.failure = mismatch
            return report
        }

        if let error = envelope.error, !error.isEmpty {
            report.failure = error
            return report
        }

        // 探针的失败信息以 JSON 里的 `error` / `warnings` 为准。
        // exit code 只在拿不到 JSON 时作为补充线索，避免把「exit 非 0 但给了数据」误判成无数据。
        return report
    }

    // MARK: 进程

    private enum Execution: Sendable {
        case failedToStart(String)
        case timedOut
        case finished(stdout: String, stderr: String, status: Int32)
    }

    private func execute(probe: URL, workingDirectory: URL, timeout: TimeInterval) async -> Execution {
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

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            for _ in 0..<20 where process.isRunning {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        // 子进程结束后管道写端关闭；加一个上限，避免探针遗留孙进程时读数卡死。
        async let stdoutTask = readAll(stdoutPipe.fileHandleForReading, limit: 2)
        async let stderrTask = readAll(stderrPipe.fileHandleForReading, limit: 2)
        let stdoutData = await stdoutTask
        let stderrData = await stderrTask

        process.waitUntilExit()

        if timedOut {
            return .timedOut
        }
        return .finished(
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            status: process.terminationStatus
        )
    }

    private func readAll(_ handle: FileHandle, limit: TimeInterval) async -> Data {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                handle.readDataToEndOfFile()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? Data()
        }
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
