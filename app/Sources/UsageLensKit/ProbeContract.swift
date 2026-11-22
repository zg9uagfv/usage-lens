import Foundation

/// 契约版本。App 只认这个 schema；不符就按「探针输出非法」处理，不猜。
public let probeSchema = "usage-lens/probe@1"

/// 所有字段名集中在一处，解码时共用。
public enum ProbeKey: String, CodingKey {
    case schema
    case provider
    case account
    case generatedAt = "generated_at"
    case observedAt = "observed_at"
    case stale
    case expired
    case windows
    case balance
    case spend
    case usage
    case coverage
    case warnings
    case error

    case id
    case label
    case plan
    case usedPercent = "used_percent"
    case windowSeconds = "window_seconds"
    case resetsAt = "resets_at"
    case basis

    case amount
    case currency
    case source
    case today
    case todayTokens = "today_tokens"
    case window
    case from
    case to
    case note
}

// MARK: - 容错解码辅助

// 探针是人写的脚本，字段偶尔会缺、会是 null、偶尔会是字符串化的数字。
// 这里统一「拿不到就是 nil」，绝不因为一个怪字段让整个 provider 变成崩溃或 0%。
extension KeyedDecodingContainer where Key == ProbeKey {
    func optionalString(_ key: ProbeKey) -> String? {
        (try? decode(String.self, forKey: key)) ?? nil
    }

    func optionalDouble(_ key: ProbeKey) -> Double? {
        if let value = try? decode(Double.self, forKey: key), value.isFinite { return value }
        if let value = try? decode(Int.self, forKey: key) { return Double(value) }
        if let raw = try? decode(String.self, forKey: key),
           let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           value.isFinite {
            return value
        }
        return nil
    }

    func optionalInt(_ key: ProbeKey) -> Int? {
        if let exact = try? decode(Int.self, forKey: key) { return exact }
        if let raw = try? decode(String.self, forKey: key),
           let exact = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return exact
        }
        guard let value = optionalDouble(key), value.isFinite else { return nil }
        return NativeProbeSupport.checkedInt(fromTruncating: value.rounded())
    }

    func optionalBool(_ key: ProbeKey) -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        if let raw = try? decode(String.self, forKey: key) {
            return ["true", "1", "yes"].contains(raw.lowercased())
        }
        return nil
    }

    func optionalDate(_ key: ProbeKey) -> Date? {
        if let raw = try? decode(String.self, forKey: key) { return ProbeDate.parse(raw) }
        if let seconds = try? decode(Double.self, forKey: key), seconds.isFinite {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    func optional<T: Decodable>(_ key: ProbeKey, as type: T.Type) -> T? {
        (try? decode(type, forKey: key)) ?? nil
    }
}

/// 宽松 ISO8601：接受带/不带毫秒、epoch 秒、纯日期。
public enum ProbeDate {
    private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dayOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = withFractional.date(from: trimmed) { return date }
        if let date = plain.date(from: trimmed) { return date }
        if let date = dayOnly.date(from: trimmed) { return date }
        if let seconds = Double(trimmed), seconds.isFinite { return Date(timeIntervalSince1970: seconds) }
        return nil
    }
}

// MARK: - 契约结构

public struct ProbeAccount: Decodable, Sendable, Equatable {
    public var label: String?
    public var plan: String?

    public init(label: String? = nil, plan: String? = nil) {
        self.label = label
        self.plan = plan
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ProbeKey.self)
        label = container.optionalString(.label)
        plan = container.optionalString(.plan)
    }
}

public struct ProbeWindow: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String?
    /// 契约要求 0–100 或 null。null = 未知，绝不当成 0。
    public var usedPercent: Double?
    public var windowSeconds: Int?
    public var resetsAt: Date?
    /// 探针基于 `resets_at < generated_at` 给出的判断；缺失时 App 用 resets_at 兜底。
    public var expired: Bool?
    /// `server` = 服务端返回；`local` = 本地推导。
    public var basis: String?

    public init(
        id: String,
        label: String? = nil,
        usedPercent: Double? = nil,
        windowSeconds: Int? = nil,
        resetsAt: Date? = nil,
        expired: Bool? = nil,
        basis: String? = nil
    ) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.windowSeconds = windowSeconds
        self.resetsAt = resetsAt
        self.expired = expired
        self.basis = basis
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ProbeKey.self)
        let position = decoder.codingPath.last?.intValue ?? 0
        if let rawID = container.optionalString(.id), !rawID.isEmpty {
            id = rawID
        } else {
            id = "window-\(position)"
        }
        label = container.optionalString(.label)
        usedPercent = container.optionalDouble(.usedPercent)
        windowSeconds = container.optionalInt(.windowSeconds)
        resetsAt = container.optionalDate(.resetsAt)
        expired = container.optionalBool(.expired)
        basis = container.optionalString(.basis)
    }
}

public struct ProbeBalance: Decodable, Sendable, Equatable {
    public var amount: Double?
    public var currency: String?
    public var source: String?

    public init(amount: Double? = nil, currency: String? = nil, source: String? = nil) {
        self.amount = amount
        self.currency = currency
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ProbeKey.self)
        amount = container.optionalDouble(.amount)
        currency = container.optionalString(.currency)
        source = container.optionalString(.source)
    }
}

public struct ProbeSpend: Decodable, Sendable, Equatable {
    public var today: Double?
    public var window: Double?
    public var currency: String?
    public var source: String?

    public init(today: Double? = nil, window: Double? = nil, currency: String? = nil, source: String? = nil) {
        self.today = today
        self.window = window
        self.currency = currency
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ProbeKey.self)
        today = container.optionalDouble(.today)
        window = container.optionalDouble(.window)
        currency = container.optionalString(.currency)
        source = container.optionalString(.source)
    }
}

/// 本地日志推导的非货币用量。没有记录时为 nil，绝不把它显示为 0。
public struct ProbeUsage: Decodable, Sendable, Equatable {
    public var todayTokens: Int?
    public var source: String?

    public init(todayTokens: Int? = nil, source: String? = nil) {
        self.todayTokens = todayTokens
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ProbeKey.self)
        todayTokens = container.optionalInt(.todayTokens)
        source = container.optionalString(.source)
    }
}

public struct ProbeCoverage: Decodable, Sendable, Equatable {
    public var from: String?
    public var to: String?
    public var note: String?

    public init(from: String? = nil, to: String? = nil, note: String? = nil) {
        self.from = from
        self.to = to
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ProbeKey.self)
        from = container.optionalString(.from)
        to = container.optionalString(.to)
        note = container.optionalString(.note)
    }
}

public struct ProbeEnvelope: Decodable, Sendable, Equatable {
    public var schema: String
    public var provider: String?
    public var account: ProbeAccount?
    public var generatedAt: Date?
    /// 数据源那一帧的时间；缺失时由 `effectiveObservedAt` 退回 generated_at。
    public var observedAt: Date?
    /// 数据源帧早于窗口长度 → 探针置 true，App 整块灰化并显示「数据来自 X 前」。
    public var stale: Bool?
    public var windows: [ProbeWindow]
    public var balance: ProbeBalance?
    public var spend: ProbeSpend?
    public var usage: ProbeUsage?
    public var coverage: ProbeCoverage?
    /// 人话警告，直接进 UI。
    public var warnings: [String]
    /// 非空 = 探针自己报告的致命错误。
    public var error: String?

    public init(
        schema: String = probeSchema,
        provider: String? = nil,
        account: ProbeAccount? = nil,
        generatedAt: Date? = nil,
        observedAt: Date? = nil,
        stale: Bool? = nil,
        windows: [ProbeWindow] = [],
        balance: ProbeBalance? = nil,
        spend: ProbeSpend? = nil,
        usage: ProbeUsage? = nil,
        coverage: ProbeCoverage? = nil,
        warnings: [String] = [],
        error: String? = nil
    ) {
        self.schema = schema
        self.provider = provider
        self.account = account
        self.generatedAt = generatedAt
        self.observedAt = observedAt
        self.stale = stale
        self.windows = windows
        self.balance = balance
        self.spend = spend
        self.usage = usage
        self.coverage = coverage
        self.warnings = warnings
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ProbeKey.self)
        schema = container.optionalString(.schema) ?? ""
        provider = container.optionalString(.provider)
        account = container.optional(.account, as: ProbeAccount.self)
        generatedAt = container.optionalDate(.generatedAt)
        observedAt = container.optionalDate(.observedAt)
        stale = container.optionalBool(.stale)
        windows = container.optional(.windows, as: [ProbeWindow].self) ?? []
        balance = container.optional(.balance, as: ProbeBalance.self)
        spend = container.optional(.spend, as: ProbeSpend.self)
        usage = container.optional(.usage, as: ProbeUsage.self)
        coverage = container.optional(.coverage, as: ProbeCoverage.self)
        error = container.optionalString(.error)

        if let list = container.optional(.warnings, as: [String].self) {
            warnings = list
        } else if let single = container.optionalString(.warnings) {
            warnings = [single]
        } else {
            warnings = []
        }
    }

    /// schema 不符时的说明；nil 表示合规。
    public var schemaMismatch: String? {
        guard schema != probeSchema else { return nil }
        return schema.isEmpty ? "缺少 schema 字段" : "schema 不符：\(schema)"
    }
}


// MARK: - 过期与陈旧语义

public extension ProbeWindow {
    /// 契约的 `expired` 是权威；字段缺失时按 resets_at 是否已过去兜底。
    func isExpired(now: Date = Date()) -> Bool {
        if let expired { return expired }
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

public extension ProbeEnvelope {
    /// 显示「数据 X 天前」时用的时间：observed_at 优先，缺失退回 generated_at。
    var effectiveObservedAt: Date? { observedAt ?? generatedAt }

    /// 契约的 stale：数据源帧太旧，整块灰化。
    var dataIsStale: Bool { stale ?? false }
}
