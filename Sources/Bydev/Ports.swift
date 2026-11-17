import Foundation

// 명세 2절 — 바꿔 끼울 수 있는 포트. SDK 안에서 시계 · 타이머 · 난수를 직접 읽지 않는다. 이름은 명세의 Transport · CredentialStore · Clock ·
// Scheduler · Random · FingerprintSource · Logger이고, 표준 라이브러리 · Combine · os의 같은 이름과 겹치지 않게 바꿨다.

/// 전송 포트가 보낼 요청이다. `body`가 nil이면 본문이 없다.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: String, headers: [String: String], body: Data?) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// 받은 응답이다. 헤더 이름은 소문자다.
public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// 요청을 보낸다. 연결 실패 · 시간 초과는 던진다(SDK가 `NETWORK_ERROR`로 감싼다). 3xx를 따라가지 않는다.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// 보안 저장소에 두는 기록이다(명세 3.6). access_token은 두지 않는다.
public struct CredentialRecord: Sendable, Equatable, Codable {
    public var version: Int
    public var refreshToken: String
    public var scope: String
    public var savedAt: String

    public init(version: Int, refreshToken: String, scope: String, savedAt: String) {
        self.version = version
        self.refreshToken = refreshToken
        self.scope = scope
        self.savedAt = savedAt
    }
}

/// 로그인 기록을 둔다. 없으면 `load`가 nil. 실패는 던진다(SDK가 `STORAGE_FAILED`로 감싼다).
public protocol CredentialStore: Sendable {
    func load() throws -> CredentialRecord?
    func save(_ record: CredentialRecord) throws
    func clear() throws
}

/// 지금 시각(Unix 밀리초) — 명세의 Clock.
public protocol WallClock: Sendable {
    func nowMs() -> Int64
}

/// 예약 취소 손잡이.
public struct ScheduleHandle: Sendable {
    private let onCancel: @Sendable () -> Void

    public init(cancel: @escaping @Sendable () -> Void) {
        onCancel = cancel
    }

    public func cancel() { onCancel() }
}

/// 나중 작업 · 기다림 — 명세의 Scheduler. SDK가 시간이나 다른 작업을 기다리는 곳은 모두 `sleep` · `wait`를 거친다(Swift 동시성은 협력 스레드 풀에서
/// 돌아 하네스가 기다림을 세야 한다 — 명세 2절의 블로킹 언어와 같다). SDK는 스스로 `Task`를 만들지 않고 이것으로만 백그라운드 작업을 시작한다.
public protocol TaskScheduler: Sendable {
    func schedule(afterMs delay: Int64, _ work: @escaping @Sendable () async -> Void) -> ScheduleHandle
    func sleep(ms: Int64) async
    func wait(for signal: Signal) async
}

/// `[0, 1)` 실수와 UUID v4(소문자) — 명세의 Random.
public protocol RandomSource: Sendable {
    func nextDouble() -> Double
    func uuid() -> String
}

/// 운영체제의 기기 식별자다. 없으면 nil — 원본은 SDK 밖으로 나가지 않는다(해시만, 명세 10절).
public protocol FingerprintSource: Sendable {
    func read() throws -> String?
}

/// 토큰 · 지문 출처 값은 넘어오지 않는다 — 명세의 Logger.
public protocol LogSink: Sendable {
    func debug(_ message: String)
    func info(_ message: String)
    func warn(_ message: String)
}

/// 클라이언트가 쓰는 포트 묶음이다. 비운 칸은 기본 구현이다.
public struct Ports: Sendable {
    public var transport: (any HTTPTransport)?
    public var store: (any CredentialStore)?
    public var clock: (any WallClock)?
    public var scheduler: (any TaskScheduler)?
    public var random: (any RandomSource)?
    public var fingerprint: (any FingerprintSource)?
    public var logger: (any LogSink)?

    public init(
        transport: (any HTTPTransport)? = nil, store: (any CredentialStore)? = nil, clock: (any WallClock)? = nil,
        scheduler: (any TaskScheduler)? = nil, random: (any RandomSource)? = nil,
        fingerprint: (any FingerprintSource)? = nil, logger: (any LogSink)? = nil
    ) {
        self.transport = transport
        self.store = store
        self.clock = clock
        self.scheduler = scheduler
        self.random = random
        self.fingerprint = fingerprint
        self.logger = logger
    }

    func resolve() -> ResolvedPorts {
        ResolvedPorts(
            transport: transport ?? URLSessionTransport(), store: store ?? MemoryCredentialStore(),
            clock: clock ?? SystemClock(), scheduler: scheduler ?? DispatchScheduler(),
            random: random ?? SystemRandom(),
            fingerprint: fingerprint ?? NoFingerprint(), logger: logger ?? SilentLog())
    }
}

/// 기본값을 채운 포트.
struct ResolvedPorts: Sendable {
    let transport: any HTTPTransport
    let store: any CredentialStore
    let clock: any WallClock
    let scheduler: any TaskScheduler
    let random: any RandomSource
    let fingerprint: any FingerprintSource
    let logger: any LogSink
}
