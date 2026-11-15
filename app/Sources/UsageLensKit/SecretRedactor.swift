import Foundation

/// 把可能混进文案里的凭据替换成 `***`。
/// 纵深防御：即使探针违约把 key 打到 stderr，界面和调试输出也只看到 `***`。
/// 规则宁可错杀，不做语义判断。
public enum SecretRedactor {
    /// 顺序有意义：先打具体形态，再兜底长随机串。
    private static let rules: [(pattern: String, replacement: String, options: NSRegularExpression.Options)] = [
        (#"sk-[A-Za-z0-9_-]{8,}"#, "***", []),
        (#"Bearer\s+\S+"#, "***", [.caseInsensitive]),
        (#"\b(?:api[_-]?key|key|token|secret|password)\b\s*[=:]\s*\S+"#, "***", [.caseInsensitive]),
        (#"[A-Za-z0-9_-]{32,}"#, "***", []),
    ]

    private static let compiled: [(NSRegularExpression, String)] = rules.compactMap { rule in
        guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else {
            return nil
        }
        return (regex, rule.replacement)
    }

    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for (regex, replacement) in compiled {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }
}
