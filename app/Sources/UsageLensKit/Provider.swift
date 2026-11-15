import Foundation

/// 一个 provider = 一行配置：id / 显示名 / 探针路径。
/// 加 provider 只需加探针脚本 + 在 `ProviderCatalog.all` 里加一行，渲染逻辑不用动。
public struct Provider: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let probeRelativePath: String

    public init(id: String, displayName: String, probeRelativePath: String) {
        self.id = id
        self.displayName = displayName
        self.probeRelativePath = probeRelativePath
    }

    public var probeFileName: String {
        (probeRelativePath as NSString).lastPathComponent
    }
}

public enum ProviderCatalog {
    public static let codex = Provider(
        id: "codex",
        displayName: "Codex",
        probeRelativePath: "probes/codex.py"
    )

    public static let deepseek = Provider(
        id: "deepseek",
        displayName: "DeepSeek",
        probeRelativePath: "probes/deepseek.py"
    )

    /// 首版只做 Codex + DeepSeek（Claude 已从首版范围移除）。
    /// tab 顺序 = 这里的顺序。
    public static let all: [Provider] = [codex, deepseek]

    public static func provider(id: String) -> Provider? {
        all.first { $0.id == id }
    }
}
