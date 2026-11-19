import Foundation

/// 一个 provider = 一行配置：id / 显示名 / 探针路径。
public struct Provider: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let probeRelativePath: String
    public let requiresAPIKey: Bool

    public init(id: String, displayName: String, probeRelativePath: String, requiresAPIKey: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.probeRelativePath = probeRelativePath
        self.requiresAPIKey = requiresAPIKey
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
        probeRelativePath: "probes/deepseek.py",
        requiresAPIKey: true
    )

    public static let claude = Provider(
        id: "claude",
        displayName: "Claude",
        probeRelativePath: "probes/claude.py"
    )

    public static let gemini = Provider(
        id: "gemini",
        displayName: "Gemini",
        probeRelativePath: "probes/gemini.py"
    )

    public static let opencode = Provider(
        id: "opencode",
        displayName: "OpenCode",
        probeRelativePath: "probes/opencode.py"
    )

    /// 可添加的厂商。显示顺序由这里决定。
    public static let available: [Provider] = [codex, claude, gemini, opencode, deepseek]

    /// 默认开启 Codex、Claude、Gemini、OpenCode；用户可在设置中修改。
    public static let defaultActiveIDs = ["codex", "claude", "gemini", "opencode"]

    /// `all` 保留为全部厂商，供初始化状态使用；界面应使用 `active`。
    public static var all: [Provider] { available }

    public static var active: [Provider] {
        let raw = UserDefaults.standard.string(forKey: "usageLens.providers")
        let ids = raw?.split(separator: ",").map(String.init) ?? defaultActiveIDs
        let selected = Set(ids)
        let providers = available.filter { selected.contains($0.id) }
        return providers.isEmpty ? [codex] : providers
    }

    public static func provider(id: String) -> Provider? {
        available.first { $0.id == id }
    }
}
