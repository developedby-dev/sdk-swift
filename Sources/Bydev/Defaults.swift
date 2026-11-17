import Foundation

// 명세 2절 — 기본 구현. 운영체제 저장소 · 지문 출처는 앱이 고른다(OSPorts).

/// 시스템 시계 — SDK에서 시계를 직접 읽는 유일한 곳.
public struct SystemClock: WallClock {
    public init() {}

    public func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
}

/// `DispatchQueue` 타이머 · `Task.sleep` 스케줄러.
public struct DispatchScheduler: TaskScheduler {
    public init() {}

    public func schedule(afterMs delay: Int64, _ work: @escaping @Sendable () async -> Void) -> ScheduleHandle {
        let cancelled = Locked(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(max(0, delay)))) {
            if cancelled.current { return }
            Task.detached { await work() }
        }
        return ScheduleHandle { cancelled.withLock { $0 = true } }
    }

    public func sleep(ms: Int64) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
    }

    public func wait(for signal: Signal) async { await signal.wait() }
}

/// 운영체제 난수(`SystemRandomNumberGenerator` — 암호학적 난수).
public struct SystemRandom: RandomSource {
    public init() {}

    public func nextDouble() -> Double { Double.random(in: 0..<1) }

    public func uuid() -> String { UUID().uuidString.lowercased() }
}

/// 리다이렉트를 따라가지 않는다(명세 2절).
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// `URLSession` 전송 — 시간 초과 `Rules.httpTimeoutSec`, 쿠키 · 캐시 없음, 리다이렉트를 따라가지 않는다.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(timeoutSec: Double = Double(Rules.httpTimeoutSec)) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSec
        config.timeoutIntervalForResource = timeoutSec
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    /// 앱이 만든 `URLSession`(프록시 · 인증서 고정)을 쓴다 — 리다이렉트를 막는 것은 앱의 몫이다.
    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.url) else {
            throw BydevError(code: Codes.configuration, message: "주소를 읽지 못했다: \(request.url)")
        }
        var r = URLRequest(url: url)
        r.httpMethod = request.method
        for (name, value) in request.headers { r.setValue(value, forHTTPHeaderField: name) }
        r.httpBody = request.body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: r)
        } catch {
            throw BydevError(code: Codes.networkError, message: "API에 연결하지 못했다", cause: String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw BydevError(code: Codes.networkError, message: "HTTP 응답이 아니다")
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

/// 메모리 저장소 — 앱을 끄면 로그인이 사라진다. 클라이언트의 기본값이다(운영체제 저장소는 `OSPorts`에서 고른다).
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let record: Locked<CredentialRecord?>

    public init(_ initial: CredentialRecord? = nil) {
        record = Locked(initial)
    }

    public func load() throws -> CredentialRecord? { record.current }

    public func save(_ record: CredentialRecord) throws { self.record.withLock { $0 = record } }

    public func clear() throws { record.withLock { $0 = nil } }
}

/// 지문 출처 없음 — SDK가 수명 동안의 난수 ID로 물러난다(경고 로그).
struct NoFingerprint: FingerprintSource {
    func read() throws -> String? { nil }
}

/// 아무것도 하지 않는 로그.
public struct SilentLog: LogSink {
    public init() {}

    public func debug(_ message: String) {}

    public func info(_ message: String) {}

    public func warn(_ message: String) {}
}
