import CryptoKit
import Foundation

// 명세 8절 — 라이선스 세션(실행 리스) 상태 기계. 참/거짓 하나로 이용 가능을 알리지 않는다.

/// 리스를 쥔 상태 — 기능 코드는 `claims`(exp · sid)를 쓴다.
public struct ActiveState: BydevModel {
    public internal(set) var session: SessionInfo
    public let licenseToken: LicenseTokenInfo
    public let claims: LicenseClaims

    var fields: [String: JSONValue] {
        ["session": session.json, "licenseToken": licenseToken.json, "claims": claims.json]
    }

    public var json: JSONValue { .object(fields) }
}

/// 하트비트가 실패하는 중 — `offlineUntil`까지는 계속 쓸 수 있다.
public struct DegradedState: BydevModel {
    public internal(set) var active: ActiveState
    public let consecutiveFailures: Int
    public let offlineUntil: String
    public let lastError: BydevError?

    public var json: JSONValue {
        var o = active.fields
        o["consecutiveFailures"] = .of(consecutiveFailures)
        o["offlineUntil"] = .string(offlineUntil)
        o["lastError"] = lastError?.json ?? .null
        return .object(o)
    }
}

/// 지금 쓰는 다른 기기(인수 판단에 보인다).
public struct ActiveSession: BydevModel {
    public let deviceId: String
    public let deviceName: String
    public let lastSeenAt: String

    public var json: JSONValue {
        .object(["deviceId": .string(deviceId), "deviceName": .string(deviceName), "lastSeenAt": .string(lastSeenAt)])
    }
}

/// 사용자 판단이 필요하다 — `DEVICE_IN_USE` · `INSTANCE_ALREADY_RUNNING`은 `takeOver()`, `DEVICE_LIMIT_EXCEEDED`는 기기 해제 뒤 `retry()`.
public struct NeedsDecisionState: BydevModel {
    public let reason: String
    public let activeSession: ActiveSession?
    public let maxDevices: Int?
    public let correlationId: String?

    public var json: JSONValue {
        .object([
            "reason": .string(reason), "activeSession": .of(activeSession), "maxDevices": .of(maxDevices),
            "correlationId": .of(correlationId),
        ])
    }
}

/// 잠금 — 오류 화면에 `correlationId`를 보인다. `retrying`이면 스스로 풀릴 수 있다(OFFLINE_EXPIRED).
public struct LockedState: BydevModel {
    public let code: String
    public let message: String
    public let correlationId: String?
    public let details: [String: JSONValue]?
    public let retrying: Bool

    public var json: JSONValue {
        .object([
            "code": .string(code), "message": .string(message), "correlationId": .of(correlationId),
            "details": details.map(JSONValue.object) ?? .null, "retrying": .of(retrying),
        ])
    }
}

/// 세션 상태(판별 유니온, 명세 8.1절). JSON은 `{"type": "Active", …}`.
public enum SessionState: BydevModel {
    case starting(attempt: Int, lastError: BydevError?)
    case active(ActiveState)
    case degraded(DegradedState)
    case needsDecision(NeedsDecisionState)
    case locked(LockedState)
    case stopped

    /// 명세 이름(`SessionStateType`).
    public var type: String {
        switch self {
        case .starting: SessionStateType.starting
        case .active: SessionStateType.active
        case .degraded: SessionStateType.degraded
        case .needsDecision: SessionStateType.needsDecision
        case .locked: SessionStateType.locked
        case .stopped: SessionStateType.stopped
        }
    }

    public var json: JSONValue {
        var o: [String: JSONValue]
        switch self {
        case .starting(let attempt, let lastError):
            o = ["attempt": .of(attempt), "lastError": lastError?.json ?? .null]
        case .active(let a): o = a.fields
        case .degraded(let d): o = d.json.objectValue ?? [:]
        case .needsDecision(let n): o = n.json.objectValue ?? [:]
        case .locked(let l): o = l.json.objectValue ?? [:]
        case .stopped: o = [:]
        }
        o["type"] = .string(type)
        return .object(o)
    }
}

/// 세션 획득 때 보내는 기기 정보다(`platform`은 `DevicePlatform`).
public struct DeviceInfo: Sendable, Equatable {
    public var name: String
    public var platform: String

    public init(name: String, platform: String) {
        self.name = name
        self.platform = platform
    }
}

/// 실행 중인 앱이다(명세 1절 · ADR-0049) — 배포 대상(`DistributionTarget`, 업데이트 확인의 `target`과 같은 값)과 콘솔에 업로드한 버전 문자열.
/// 세션 획득에 싣는다. 업데이트 제공 기한이 있는 영구 이용권은 이 값이 없으면 획득이 `ENTITLEMENT_VERSION_NOT_COVERED`로 거절된다.
public struct AppInfo: Sendable, Equatable {
    public var target: String
    public var version: String

    public init(target: String, version: String) {
        self.target = target
        self.version = version
    }
}

/// 구독 — `cancel()`로 끊는다(놓아도 끊지 않는다).
public struct SessionSubscription: Sendable {
    let onCancel: @Sendable () -> Void

    public func cancel() { onCancel() }
}

/// 라이선스 세션이다. `start` · `takeOver` · `retry` · `stop`과 상태 구독. 구독 함수는 SDK의 작업에서 불린다 — UI는 메인 액터로 넘긴다.
public final class LicenseSession: @unchecked Sendable {
    private struct Inner {
        var current: SessionState = .stopped
        var listeners: [(UInt64, @Sendable (SessionState) -> Void)] = []
        var nextListener: UInt64 = 0
        var run: UInt64 = 0
        var instance = ""
        var held: ActiveState?
        var failures = 0
        var heartbeat: ScheduleHandle?
        var offline: ScheduleHandle?
        var fallback: String?

        mutating func cancelTimers() {
            heartbeat?.cancel()
            heartbeat = nil
            offline?.cancel()
            offline = nil
        }
    }

    private let api: Api
    private let tokens: TokenManager
    private let verifier: Verifier
    private let device: DeviceInfo
    private let app: AppInfo?
    private let box = Locked(Inner())

    init(api: Api, tokens: TokenManager, verifier: Verifier, device: DeviceInfo, app: AppInfo?) {
        self.api = api
        self.tokens = tokens
        self.verifier = verifier
        self.device = device
        self.app = app
    }

    /// 지금 상태다.
    public var state: SessionState { box.current.current }

    /// 상태가 바뀔 때마다 부른다.
    @discardableResult
    public func subscribe(_ listener: @escaping @Sendable (SessionState) -> Void) -> SessionSubscription {
        let id: UInt64 = box.withLock { s in
            let id = s.nextListener
            s.nextListener += 1
            s.listeners.append((id, listener))
            return id
        }
        return SessionSubscription { [box] in box.withLock { $0.listeners.removeAll { $0.0 == id } } }
    }

    /// `stopped`에서만 의미가 있다(8.2절).
    public func start() {
        let started: Bool = box.withLock { s in
            guard s.current == .stopped else { return false }
            s.run += 1
            s.instance = api.ports.random.uuid()
            return true
        }
        if started { beginAcquire(force: false, lastError: nil) }
    }

    /// `needsDecision`(다른 기기 · 같은 기기 실행 중) 또는 `locked(SESSION_SUPERSEDED)`에서 인수한다 — 새 Idempotency-Key.
    public func takeOver() {
        let allowed: Bool
        switch state {
        case .needsDecision(let n): allowed = n.reason != NeedsDecisionReason.deviceLimitExceeded
        case .locked(let l): allowed = l.code == Codes.sessionSuperseded
        default: allowed = false
        }
        guard allowed else { return }
        box.withLock { $0.run += 1 }
        beginAcquire(force: true, lastError: nil)
    }

    /// `needsDecision`(기기 수) 또는 스스로 풀리지 않는 `locked`에서 다시 얻는다.
    public func retry() {
        let allowed: Bool
        switch state {
        case .needsDecision(let n): allowed = n.reason == NeedsDecisionReason.deviceLimitExceeded
        case .locked(let l): allowed = !l.retrying
        default: allowed = false
        }
        guard allowed else { return }
        box.withLock { $0.run += 1 }
        beginAcquire(force: false, lastError: nil)
    }

    /// 예약을 모두 취소하고 반납을 한 번 보낸다(8.7절). 진행 중인 요청의 결과는 버린다.
    public func stop() async {
        var wasStopped = false
        let sid: String? = box.withLock { s in
            if s.current == .stopped {
                wasStopped = true
                return nil
            }
            s.run += 1
            s.cancelTimers()
            s.instance = ""
            defer { s.held = nil }
            return s.held?.session.id
        }
        if wasStopped { return }
        if let sid {
            let url = api.url(Routes.releaseSession.path, params: ["sid": sid])
            do {
                _ = try await tokens.authed { [api] bearer in try await api.send(Req("DELETE", url, bearer: bearer)) }
            } catch {
                api.ports.logger.debug("세션 반납을 보내지 못했다 — 리스가 저절로 빈다")
            }
        }
        setState(.stopped)
    }

    /// 8.5절 — 다른 인증 응답의 `X-Lease-Expires-At`.
    func noteLease(_ value: String?) {
        guard let value, !value.isEmpty else { return }
        let next: SessionState? = box.withLock { s in
            guard s.held != nil else { return nil }
            var next = s.current
            switch next {
            case .active(var a):
                if a.session.leaseExpiresAt == value { return nil }
                a.session.leaseExpiresAt = value
                next = .active(a)
            case .degraded(var d):
                if d.active.session.leaseExpiresAt == value { return nil }
                d.active.session.leaseExpiresAt = value
                next = .degraded(d)
            default:
                return nil
            }
            s.held?.session.leaseExpiresAt = value
            return next
        }
        if let next { setState(next) }
    }

    // ── 안 ──────────────────────────────────────────────────────

    private func setState(_ next: SessionState) {
        let listeners: [@Sendable (SessionState) -> Void]? = box.withLock { s in
            if s.current == next { return nil }
            s.current = next
            return s.listeners.map(\.1)
        }
        for listener in listeners ?? [] { listener(next) }
    }

    private func live(_ run: UInt64) -> Bool { box.current.run == run }

    private func after(_ delay: Int64, _ work: @escaping @Sendable () async -> Void) {
        let handle = api.ports.scheduler.schedule(afterMs: delay, work)
        let old = box.withLock { s in
            defer { s.heartbeat = handle }
            return s.heartbeat
        }
        old?.cancel()
    }

    private func beginAcquire(force: Bool, lastError: BydevError?) {
        let run: UInt64 = box.withLock { s in
            s.cancelTimers()
            s.held = nil
            s.failures = 0
            return s.run
        }
        setState(.starting(attempt: 0, lastError: lastError))
        let key = api.ports.random.uuid()
        after(0) { [self] in await acquire(run: run, force: force, key: key, attempt: 0) }
    }

    private func fingerprintHash() -> String {
        let ports = api.ports
        let source = (try? ports.fingerprint.read())?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String
        if let source, !source.isEmpty {
            value = source
        } else {
            value = box.withLock { s in
                if let fallback = s.fallback { return fallback }
                ports.logger.warn("기기 지문 출처를 읽지 못해 이번 실행 동안만 쓰는 ID를 쓴다 — 출처 포트를 준다(명세 10절)")
                let id = ports.random.uuid()
                s.fallback = id
                return id
            }
        }
        return hex(SHA256.hash(data: Data((value + Rules.fingerprintSalt).utf8)))
    }

    /// 8.2절. 일시적 실패의 재시도는 같은 키.
    private func acquire(run: UInt64, force: Bool, key: String, attempt: Int) async {
        guard live(run) else { return }
        let instance = box.current.instance
        var fields: [String: JSONValue] = [
            "device": .object([
                "fingerprintHash": .string(fingerprintHash()), "name": .string(device.name),
                "platform": .string(device.platform),
            ]),
            "instanceId": .string(instance), "force": .bool(force),
        ]
        // 설정에 있을 때만 — 인수(force) · 재획득도 같다
        if let app { fields["app"] = .object(["target": .string(app.target), "version": .string(app.version)]) }
        let body: JSONValue = .object(fields)
        let url = api.url(Routes.acquireSession.path)
        let failure: BydevError
        do {
            let res = try await tokens.authed { [api] bearer in
                try await api.send(Req("POST", url, body: body, bearer: bearer, idempotencyKey: key))
            }
            guard live(run) else { return }
            try await adopt(run: run, res.json)
            return
        } catch {
            guard live(run) else { return }
            failure = BydevError.wrap(error, Codes.protocolError, "세션 응답을 읽지 못했다")
        }
        if failure.isTransient {
            let delays = Rules.sessionStartRetryDelaysSec
            let base = delays[min(attempt, delays.count - 1)]
            setState(.starting(attempt: attempt + 1, lastError: failure))
            let delay = jittered(
                api.ports.random, baseMs: seconds(base), min: Rules.sessionHeartbeatJitterMin,
                max: Rules.sessionHeartbeatJitterMax)
            after(delay) { [self] in await acquire(run: run, force: force, key: key, attempt: attempt + 1) }
        } else if Rules.needsDecisionReasons.contains(failure.code) {
            let details = failure.details
            let activeSession = details?["activeSession"]?.objectValue.map { a in
                ActiveSession(
                    deviceId: a["deviceId"]?.stringValue ?? "", deviceName: a["deviceName"]?.stringValue ?? "",
                    lastSeenAt: a["lastSeenAt"]?.stringValue ?? "")
            }
            let maxDevices = details?["maxDevices"]?.numberValue.map { Int($0) }
            setState(
                .needsDecision(
                    NeedsDecisionState(
                        reason: failure.code, activeSession: activeSession, maxDevices: maxDevices,
                        correlationId: failure.correlationId)))
        } else {
            lock(with: failure, retrying: false)
        }
    }

    /// 200 응답 → 검증(9절) → Active → 다음 하트비트.
    private func adopt(run: UInt64, _ json: JSONValue) async throws {
        let (session, token) = try readSessionResponse(json)
        let claims = try await verifier.verifyLicense(
            token.token,
            expect: Expectation(sid: session.id, deviceId: session.deviceId, generation: session.generation),
            minGeneration: 0)
        guard live(run) else { return }
        let active = ActiveState(session: session, licenseToken: token, claims: claims)
        let offline: ScheduleHandle? = box.withLock { s in
            s.held = active
            s.failures = 0
            defer { s.offline = nil }
            return s.offline
        }
        offline?.cancel()
        setState(.active(active))
        scheduleHeartbeat(run: run, heartbeatSec: session.heartbeatSec, retryAfterSec: 0)
    }

    private func scheduleHeartbeat(run: UInt64, heartbeatSec: Int, retryAfterSec: Int) {
        let delay = max(
            jittered(
                api.ports.random, baseMs: Int64(max(0, heartbeatSec)) * 1000, min: Rules.sessionHeartbeatJitterMin,
                max: Rules.sessionHeartbeatJitterMax),
            Int64(retryAfterSec) * 1000)
        after(delay) { [self] in await beat(run: run) }
    }

    /// 8.3절 하트비트.
    private func beat(run: UInt64) async {
        guard let held = box.withLock({ s in s.run == run ? s.held : nil }) else { return }
        let url = api.url(Routes.heartbeatSession.path, params: ["sid": held.session.id])
        let body: JSONValue = .object(["generation": .of(held.session.generation)])
        let failure: BydevError
        do {
            let res = try await tokens.authed { [api] bearer in
                try await api.send(Req("POST", url, body: body, bearer: bearer))
            }
            guard live(run) else { return }
            try await adopt(run: run, res.json)
            return
        } catch {
            guard live(run) else { return }
            failure = BydevError.wrap(error, Codes.protocolError, "세션 응답을 읽지 못했다")
        }
        if failure.isTransient {
            let (failures, holding): (Int, Bool) = box.withLock { s in
                s.failures += 1
                switch s.current {
                case .active, .degraded: return (s.failures, true)
                default: return (s.failures, false)
                }
            }
            if holding {
                let offlineUntil = held.licenseToken.expiresAt
                setState(
                    .degraded(
                        DegradedState(
                            active: held, consecutiveFailures: failures, offlineUntil: offlineUntil, lastError: failure)
                    ))
                armOfflineExpiry(run: run, offlineUntil: offlineUntil)
            }
            let retry = failure.code == Codes.rateLimited || failure.httpStatus == 429 ? failure.retryAfterSec ?? 0 : 0
            scheduleHeartbeat(run: run, heartbeatSec: held.session.heartbeatSec, retryAfterSec: retry)
        } else if failure.code == Codes.sessionRevoked {
            // 리스가 끝났을 때도 이 코드다 — 한 번 다시 얻는다(같은 instanceId, 새 키)
            beginAcquire(force: false, lastError: failure)
        } else {
            lock(with: failure, retrying: false)
        }
    }

    /// 8.4절 — `offlineUntil`이 지나도록 성공하지 못하면 잠근다. 재시도는 그대로.
    private func armOfflineExpiry(run: UInt64, offlineUntil: String) {
        if box.current.offline != nil { return }
        let now = api.ports.clock.nowMs()
        let delay = ISOTime.parse(offlineUntil).map { max(0, $0 - now) } ?? 0
        let handle = api.ports.scheduler.schedule(afterMs: delay) { [self] in
            let ok: Bool = box.withLock { s in
                s.offline = nil
                if case .degraded = s.current { return s.run == run }
                return false
            }
            if ok {
                setState(
                    .locked(
                        LockedState(
                            code: Codes.offlineExpired, message: "하트비트에 성공하지 못한 채 licenseToken이 만료됐다",
                            correlationId: nil, details: nil, retrying: true)))
            }
        }
        box.withLock { $0.offline = handle }
    }

    private func lock(with error: BydevError, retrying: Bool) {
        box.withLock { $0.cancelTimers() }
        setState(
            .locked(
                LockedState(
                    code: error.code, message: error.message, correlationId: error.correlationId,
                    details: error.details, retrying: retrying)))
    }
}
