import Foundation

public enum UsageFormat {
    /// 33%；nil 一律「未知」，绝不显示 0%。
    /// 有真实用量但不足 1% 时给一位小数，避免把「0.4%」说成「0%」。
    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "未知" }
        let clamped = min(max(value, 0), 100)
        if clamped > 0, clamped < 1 {
            return String(format: "%.1f%%", clamped)
        }
        return "\(Int(clamped.rounded()))%"
    }

    /// 「已用 33%」/「未知」。
    public static func usedText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "未知" }
        return "已用 \(percent(value))"
    }

    /// 0…1 的进度比例；nil = 未知，UI 不画填充。
    public static func fraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value / 100, 0), 1)
    }

    /// 「2 小时 13 分后重置」/「45 分后重置」/「已过重置时间」。
    public static func resetCountdown(until date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "窗口已过期" }
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) 分后重置" }
        if minutes < 24 * 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours) 小时后重置" : "\(hours) 小时 \(remainder) 分后重置"
        }
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        return "\(days) 天 \(hours) 小时后重置"
    }

    /// 「刚刚」/「3 小时前」/「5 天前」；nil = 不知道数据时间。
    public static func dataAgeText(from date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 3600 { return "刚刚" }
        if seconds < 86_400 { return "\(seconds / 3600) 小时前" }
        return "\(seconds / 86_400) 天前"
    }

    /// expired 窗口的说明文案：不显示倒计时，只说明数据有多旧。
    public static func expiredMessage(observedAt: Date?, now: Date = Date()) -> String {
        guard let age = dataAgeText(from: observedAt, now: now) else { return "窗口已过期" }
        return "窗口已过期（数据 \(age)）"
    }

    /// stale 数据的说明文案。
    public static func staleMessage(observedAt: Date?, now: Date = Date()) -> String {
        guard let age = dataAgeText(from: observedAt, now: now) else { return "数据时间未知" }
        return "数据来自 \(age)"
    }

    /// 「刚刚更新」/「3 分钟前更新」/「2 小时前更新」。
    public static func updatedText(at date: Date?, now: Date = Date()) -> String {
        guard let date else { return "尚未更新" }
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 60 { return "刚刚更新" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前更新" }
        if seconds < 86_400 { return "\(seconds / 3600) 小时前更新" }
        return "\(seconds / 86_400) 天前更新"
    }

    /// `¥12.34` / `$0.42` / `12.34 EUR`。
    public static func money(_ amount: Double?, currency: String?) -> String? {
        guard let amount, amount.isFinite else { return nil }
        let formatted = String(format: "%.2f", amount)
        switch currency?.uppercased() {
        case "CNY", "RMB": return "¥\(formatted)"
        case "USD": return "$\(formatted)"
        case .some(let other) where !other.isEmpty: return "\(formatted) \(other)"
        default: return formatted
        }
    }

    /// `server` → 服务端；`local` → 本地推导。
    public static func basisLabel(_ basis: String?) -> String? {
        switch basis?.lowercased() {
        case "server": return "服务端"
        case "local": return "本地推导"
        case .some(let raw) where !raw.isEmpty: return raw
        default: return nil
        }
    }

    /// `official` → 官方；`estimate` → 估算。
    public static func sourceLabel(_ source: String?) -> String? {
        switch source?.lowercased() {
        case "official": return "官方"
        case "estimate": return "估算"
        case .some(let raw) where !raw.isEmpty: return raw
        default: return nil
        }
    }

    /// `plus` / `pro` → `Plus` / `Pro`。
    public static func planLabel(_ plan: String?) -> String? {
        guard let plan, !plan.isEmpty else { return nil }
        let normalized = plan.replacingOccurrences(of: "_", with: " ")
        return normalized
            .split(separator: " ")
            .map { String($0.prefix(1)).uppercased() + String($0.dropFirst()) }
            .joined(separator: " ")
    }
}
