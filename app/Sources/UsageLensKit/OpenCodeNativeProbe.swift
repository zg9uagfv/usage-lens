import Foundation

// MARK: - 原生 Swift OpenCode 探针占位（零 Python 运行时依赖）

public struct OpenCodeNativeProbe: Sendable {
    public init() {}

    public func run(
        environment: [String: String],
        now: Date = Date()
    ) async -> ProbeReport {
        ProbeReport(
            provider: ProviderCatalog.opencode,
            failure: "OpenCode 暂未接入原生用量探针",
            finishedAt: now,
            isMissingProbe: true,
            duration: 0
        )
    }
}
