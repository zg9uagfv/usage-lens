import Foundation

// MARK: - 原生 HTTPS 传输抽象（严格域名绑定、禁止重定向、有界超时与流式体积上限）

public struct NativeHTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    public var expectedHost: String
    public var maxBytes: Int

    public init(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 3.0,
        expectedHost: String,
        maxBytes: Int = 1_048_576
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.expectedHost = expectedHost
        self.maxBytes = maxBytes
    }
}

public struct NativeHTTPResponse: Sendable {
    public var statusCode: Int
    public var finalURL: URL?
    public var headers: [String: String]
    public var body: Data

    public init(
        statusCode: Int,
        finalURL: URL?,
        headers: [String: String] = [:],
        body: Data
    ) {
        self.statusCode = statusCode
        self.finalURL = finalURL
        self.headers = headers
        self.body = body
    }
}

public enum NativeHTTPError: Error, Sendable, Equatable {
    case nonOfficialURL
    case redirected(statusCode: Int)
    case responseTooLarge(declaredBytes: Int?)
    case timedOut
    case network(String)
}

public protocol NativeHTTPTransport: Sendable {
    func send(_ request: NativeHTTPRequest) async throws -> NativeHTTPResponse
}

/// 线程安全的流式 HTTPS 代理：在响应头与分块流接收阶段实时执行域名校验、禁止重定向与 1MB 内存上限，
/// 一旦超限、遇 3xx 或任务取消立即中断传输，绝不先整包缓存到内存。
private final class StreamingHTTPDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let expectedHost: String
    private let maxBytes: Int
    private var continuation: CheckedContinuation<NativeHTTPResponse, Error>?
    private var session: URLSession?
    private weak var task: URLSessionDataTask?
    private var httpResponse: HTTPURLResponse?
    private var normalizedHeaders: [String: String] = [:]
    private var buffer = Data()
    private var finished = false

    init(
        expectedHost: String,
        maxBytes: Int,
        continuation: CheckedContinuation<NativeHTTPResponse, Error>
    ) {
        self.expectedHost = expectedHost
        self.maxBytes = max(0, maxBytes)
        self.continuation = continuation
    }

    func attach(session: URLSession, task: URLSessionDataTask) {
        let alreadyFinished: Bool = lock.withLock {
            if finished { return true }
            self.session = session
            self.task = task
            return false
        }
        if alreadyFinished {
            task.cancel()
            session.invalidateAndCancel()
        } else {
            task.resume()
        }
    }

    func cancelForTaskCancellation() {
        finish(with: .failure(NativeHTTPError.timedOut), cancelSession: true)
    }

    private func finish(with result: Result<NativeHTTPResponse, Error>, cancelSession: Bool) {
        let (cont, sess, activeTask): (
            CheckedContinuation<NativeHTTPResponse, Error>?,
            URLSession?,
            URLSessionDataTask?
        ) = lock.withLock {
            guard !finished else { return (nil, nil, nil) }
            finished = true
            let c = continuation
            continuation = nil
            let s = session
            session = nil
            let t = task
            task = nil
            buffer.removeAll(keepingCapacity: false)
            return (c, s, t)
        }
        if cancelSession {
            activeTask?.cancel()
            sess?.invalidateAndCancel()
        } else {
            sess?.finishTasksAndInvalidate()
        }
        cont?.resume(with: result)
    }

    /// 任何 3xx 一律不跟随：避免 Authorization / ChatGPT-Account-Id / refresh_token 被带到重定向目标。
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(with: .failure(NativeHTTPError.redirected(statusCode: response.statusCode)), cancelSession: true)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let alreadyFinished = lock.withLock { finished }
        if alreadyFinished {
            completionHandler(.cancel)
            return
        }

        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(with: .failure(NativeHTTPError.network("非 HTTP 响应")), cancelSession: true)
            return
        }

        if (300..<400).contains(http.statusCode) {
            completionHandler(.cancel)
            finish(with: .failure(NativeHTTPError.redirected(statusCode: http.statusCode)), cancelSession: true)
            return
        }

        if let finalURL = http.url,
           !NativeProbeSupport.isPinnedHTTPSURL(finalURL, expectedHost: expectedHost) {
            completionHandler(.cancel)
            finish(with: .failure(NativeHTTPError.nonOfficialURL), cancelSession: true)
            return
        }

        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String {
                headers[ks.lowercased()] = vs
            }
        }

        // 在接收任何响应体字节之前，先校验 Content-Length 与 expectedContentLength。
        if let rawLength = headers["content-length"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawLength.isEmpty {
            if let declared64 = Int64(rawLength) {
                if declared64 > Int64(maxBytes) {
                    completionHandler(.cancel)
                    finish(
                        with: .failure(NativeHTTPError.responseTooLarge(declaredBytes: Int(exactly: declared64))),
                        cancelSession: true
                    )
                    return
                }
            } else if rawLength.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.decimalDigits.contains($0) }) {
                completionHandler(.cancel)
                finish(with: .failure(NativeHTTPError.responseTooLarge(declaredBytes: nil)), cancelSession: true)
                return
            }
        }

        if http.expectedContentLength > Int64(maxBytes) {
            completionHandler(.cancel)
            finish(
                with: .failure(NativeHTTPError.responseTooLarge(declaredBytes: Int(exactly: http.expectedContentLength))),
                cancelSession: true
            )
            return
        }

        let shouldAllow: Bool = lock.withLock {
            guard !finished else { return false }
            self.httpResponse = http
            self.normalizedHeaders = headers
            let initialCapacity: Int
            if http.expectedContentLength > 0,
               let capped = Int(exactly: min(http.expectedContentLength, Int64(maxBytes))) {
                initialCapacity = capped
            } else {
                initialCapacity = 0
            }
            self.buffer = Data(capacity: initialCapacity)
            return true
        }
        completionHandler(shouldAllow ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded: Bool = lock.withLock {
            guard !finished else { return false }
            let remaining = maxBytes - buffer.count
            if data.count > remaining {
                return true
            }
            buffer.append(data)
            return false
        }
        if exceeded {
            finish(with: .failure(NativeHTTPError.responseTooLarge(declaredBytes: nil)), cancelSession: true)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let mapped: NativeHTTPError
            if let urlError = error as? URLError {
                if urlError.code == .timedOut {
                    mapped = .timedOut
                } else {
                    mapped = .network(SecretRedactor.redact(urlError.localizedDescription))
                }
            } else {
                mapped = .network(SecretRedactor.redact(error.localizedDescription))
            }
            finish(with: .failure(mapped), cancelSession: true)
            return
        }

        let snapshot: (HTTPURLResponse?, [String: String], Data, Bool) = lock.withLock {
            (httpResponse, normalizedHeaders, buffer, finished)
        }
        guard !snapshot.3 else { return }
        guard let http = snapshot.0 else {
            finish(with: .failure(NativeHTTPError.network("非 HTTP 响应")), cancelSession: true)
            return
        }
        let response = NativeHTTPResponse(
            statusCode: http.statusCode,
            finalURL: http.url,
            headers: snapshot.1,
            body: snapshot.2
        )
        finish(with: .success(response), cancelSession: false)
    }
}

private final class LockedHTTPCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var delegate: StreamingHTTPDelegate?
    private var cancelled = false

    func register(_ delegate: StreamingHTTPDelegate) -> Bool {
        lock.withLock {
            if cancelled { return false }
            self.delegate = delegate
            return true
        }
    }

    func cancel() {
        let target: StreamingHTTPDelegate? = lock.withLock {
            cancelled = true
            let d = delegate
            delegate = nil
            return d
        }
        target?.cancelForTaskCancellation()
    }
}

public struct PinnedURLSessionTransport: NativeHTTPTransport {
    private let protocolClasses: [AnyClass]?

    public init() {
        self.protocolClasses = nil
    }

    internal init(protocolClasses: [AnyClass]?) {
        self.protocolClasses = protocolClasses
    }

    public func send(_ request: NativeHTTPRequest) async throws -> NativeHTTPResponse {
        guard NativeProbeSupport.isPinnedHTTPSURL(request.url, expectedHost: request.expectedHost) else {
            throw NativeHTTPError.nonOfficialURL
        }
        if Task.isCancelled {
            throw NativeHTTPError.timedOut
        }

        let timeout = request.timeout.isFinite ? max(request.timeout, 0.05) : NativeProbeSupport.httpTimeoutSeconds
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        if let protocolClasses {
            config.protocolClasses = protocolClasses
        }

        var urlRequest = URLRequest(url: request.url, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let cancelBox = LockedHTTPCancellationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = StreamingHTTPDelegate(
                    expectedHost: request.expectedHost,
                    maxBytes: request.maxBytes,
                    continuation: continuation
                )
                guard cancelBox.register(delegate) else {
                    delegate.cancelForTaskCancellation()
                    return
                }
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                let dataTask = session.dataTask(with: urlRequest)
                delegate.attach(session: session, task: dataTask)
            }
        } onCancel: {
            cancelBox.cancel()
        }
    }
}

// MARK: - 原生探针公共工具

public enum NativeProbeSupport {
    public static let httpTimeoutSeconds: TimeInterval = 3.0
    public static let httpMaxBytes: Int = 1_048_576
    public static let tailChunkBytes: Int = 256 * 1024
    public static let maxScanBytes: Int = 4 * 1024 * 1024

    /// 严格域名绑定：只认 https + 指定官方域名 + 默认端口 443 + 无 userinfo。
    public static func isPinnedHTTPSURL(_ url: URL, expectedHost: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        guard components.scheme?.lowercased() == "https" else { return false }
        guard components.user == nil, components.password == nil else { return false }
        guard components.host?.lowercased() == expectedHost.lowercased() else { return false }
        if let port = components.port, port != 443 {
            return false
        }
        return true
    }

    public static func isPinnedHTTPSURLString(_ raw: String, expectedHost: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        return isPinnedHTTPSURL(url, expectedHost: expectedHost)
    }

    public static func nonEmptyTrimmed(_ value: Any?) -> String? {
        guard let str = value as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func finiteDouble(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if value is Bool { return nil }
        if let num = value as? NSNumber {
            // 排除 CFBoolean（JSONSerialization 会把 true/false 解码成 NSNumber）
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
            let d = num.doubleValue
            return d.isFinite ? d : nil
        }
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let d = Double(trimmed), d.isFinite else { return nil }
            return d
        }
        return nil
    }

    /// 将有限浮点数安全截断为 Int；超出 Int 可精确表示范围时返回 nil，绝不触发运行时 trap。
    /// 注：IEEE-754 下 Double(Int.max) 向上舍入到 2^63，故上界必须严格小于 Double(Int.max)。
    public static func checkedInt(fromTruncating double: Double) -> Int? {
        guard double.isFinite else { return nil }
        let truncated = double.rounded(.towardZero)
        guard truncated >= Double(Int.min), truncated < Double(Int.max) else {
            return nil
        }
        return Int(truncated)
    }

    /// 溢出检查的整数加法，溢出返回 nil 而不触发 trap。
    public static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : sum
    }

    /// 安全将正数秒/分钟值乘以系数并转换为正 Int（溢出、非有限、非正数一律返回 nil，绝不 trap）。
    public static func checkedPositiveIntSeconds(_ value: Any?, multiplier: Double = 1.0) -> Int? {
        guard multiplier.isFinite, multiplier > 0,
              let raw = finiteDouble(value), raw > 0 else {
            return nil
        }
        let scaled = raw * multiplier
        guard scaled.isFinite, scaled >= 1.0,
              let converted = checkedInt(fromTruncating: scaled),
              converted > 0 else {
            return nil
        }
        return converted
    }

    /// 安全非负整数解析：支持 Int/Int64/Double/数字字符串；布尔值、负数、NaN/Inf、超出 Int.max 一律返回 nil，绝不 trap。
    public static func nonNegativeInt(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if value is Bool { return nil }
        if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
            if num is NSDecimalNumber || CFNumberIsFloatType(num) {
                let d = num.doubleValue
                guard d.isFinite, d >= 0 else { return nil }
                return checkedInt(fromTruncating: d)
            }
            let d = num.doubleValue
            guard d.isFinite, d >= 0, d <= Double(Int.max) else { return nil }
            let i64 = num.int64Value
            guard i64 >= 0 else { return nil }
            return Int(exactly: i64)
        }
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let exact = Int(trimmed) {
                return exact >= 0 ? exact : nil
            }
            guard let d = Double(trimmed), d.isFinite, d >= 0 else { return nil }
            return checkedInt(fromTruncating: d)
        }
        return nil
    }

    /// 只读解码 JWT payload（仅提取非敏感 email / 账号元信息，绝不打印或落盘令牌）。
    public static func decodeJWTPayload(_ token: Any?) -> [String: Any]? {
        guard let str = token as? String else { return nil }
        let parts = str.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let raw = Data(base64Encoded: base64),
              let obj = try? JSONSerialization.jsonObject(with: raw),
              let dict = obj as? [String: Any] else {
            return nil
        }
        return dict
    }

    public static func parseExpiryEpoch(_ value: Any?) -> TimeInterval? {
        if let num = finiteDouble(value) {
            guard num > 0 else { return nil }
            let epoch = num > 1e11 ? num / 1000.0 : num
            return epoch.isFinite ? epoch : nil
        }
        if let str = nonEmptyTrimmed(value), let date = ProbeDate.parse(str) {
            return date.timeIntervalSince1970
        }
        return nil
    }

    public static func parseDurationSeconds(_ value: Any?) -> Double? {
        if let d = finiteDouble(value) {
            return d > 0 ? d : nil
        }
        guard let text = nonEmptyTrimmed(value) else { return nil }

        // ISO8601 duration: P[nD][T[nH][nM][nS]]
        let isoPattern = #"^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#
        if let regex = try? NSRegularExpression(pattern: isoPattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            func capture(_ idx: Int) -> Double {
                guard let range = Range(match.range(at: idx), in: text) else { return 0 }
                return Double(text[range]) ?? 0
            }
            let total = capture(1) * 86_400 + capture(2) * 3_600 + capture(3) * 60 + capture(4)
            if total.isFinite && total > 0 { return total }
        }

        // Suffix duration: e.g. "5h", "7d", "30m", "18000s"
        let suffixPattern = #"^(\d+(?:\.\d+)?)\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)$"#
        if let regex = try? NSRegularExpression(pattern: suffixPattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let valRange = Range(match.range(at: 1), in: text),
           let unitRange = Range(match.range(at: 2), in: text),
           let val = Double(text[valRange]),
           val.isFinite {
            let unit = text[unitRange].lowercased()
            let factor: Double
            if unit.hasPrefix("d") { factor = 86_400 }
            else if unit.hasPrefix("h") { factor = 3_600 }
            else if unit.hasPrefix("m") { factor = 60 }
            else { factor = 1 }
            let total = val * factor
            return total.isFinite && total > 0 ? total : nil
        }

        return nil
    }

    public static func humanAge(seconds: Double) -> String {
        guard seconds.isFinite else { return "很久以前" }
        if seconds >= 86_400 {
            if let days = checkedInt(fromTruncating: seconds / 86_400) {
                return "\(days) 天前"
            }
            return "很久以前"
        }
        if seconds >= 3_600 {
            if let hours = checkedInt(fromTruncating: seconds / 3_600) {
                return "\(hours) 小时前"
            }
            return "很久以前"
        }
        if seconds >= 60 {
            if let mins = checkedInt(fromTruncating: seconds / 60) {
                return "\(mins) 分钟前"
            }
            return "很久以前"
        }
        return "刚刚"
    }

    public static func dedupeRedacted(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for item in items {
            let cleaned = SecretRedactor.redact(item)
            if !cleaned.isEmpty, seen.insert(cleaned).inserted {
                result.append(cleaned)
            }
        }
        return result
    }

    public static func effectiveHomeDirectory(from environment: [String: String]) -> URL {
        if let home = nonEmptyTrimmed(environment["HOME"]) {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// 真实登录用户主目录（来自 getpwuid），用于判断测试隔离 HOME。
    public static func realLoginUserHomeDirectory() -> URL? {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }

    public static func isHomeIsolated(
        effectiveHome: URL,
        realUserHome: URL? = realLoginUserHomeDirectory()
    ) -> Bool {
        guard let realUserHome else { return true }
        let lhs = effectiveHome.resolvingSymlinksInPath().standardizedFileURL.path
        let rhs = realUserHome.resolvingSymlinksInPath().standardizedFileURL.path
        return lhs != rhs
    }

    /// 从文件末尾往前按块读，逐行倒序返回，最多回扫 maxBytes；被截断时丢弃最前端半行。
    /// 支持协作取消（默认检查 Task.isCancelled），避免大文件扫描阻塞超时返回。
    public static func readLinesReverse(
        at url: URL,
        maxBytes: Int = maxScanBytes,
        chunkSize: Int = tailChunkBytes,
        shouldCancel: () -> Bool = { Task.isCancelled }
    ) throws -> (lines: [Data], truncated: Bool) {
        if shouldCancel() { return ([], false) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let safeMaxBytes = UInt64(max(0, maxBytes))
        let safeChunkSize = UInt64(max(1, chunkSize))
        let fileSize = try handle.seekToEnd()
        var position = fileSize
        var consumed: UInt64 = 0
        var buffered = Data()
        var lines: [Data] = []
        let newline = UInt8(ascii: "\n")

        while position > 0 && consumed < safeMaxBytes {
            if shouldCancel() { return ([], false) }
            let remainingBudget = safeMaxBytes - consumed
            let step64 = min(safeChunkSize, min(position, remainingBudget))
            guard let step = Int(exactly: step64), step > 0 else { break }
            position -= step64
            consumed += step64
            try handle.seek(toOffset: position)
            let chunk = try handle.read(upToCount: step) ?? Data()
            var combined = Data(capacity: chunk.count + buffered.count)
            combined.append(chunk)
            combined.append(buffered)

            let parts = combined.split(separator: newline, omittingEmptySubsequences: false)
            if let first = parts.first {
                buffered = Data(first)
            } else {
                buffered = Data()
            }
            if parts.count > 1 {
                for segment in parts.dropFirst().reversed() {
                    if !segment.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                        lines.append(Data(segment))
                    }
                }
            }
        }

        if !shouldCancel(), position == 0 && !buffered.isEmpty && !buffered.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
            lines.append(buffered)
        }
        return (lines, fileSize > safeMaxBytes)
    }

    /// URL form-urlencoded 编码（严格编码 OAuth refresh_token / client_id 等字段）。
    public static func formURLEncoded(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { key, value -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    public static func localDayString(from date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}
