import Foundation

/// 로그인이 끝났을 때 받은 스코프다.
public struct LoginResult: BydevModel {
    public let scope: String

    public var json: JSONValue { .object(["scope": .string(scope)]) }
}

/// 디바이스 플로우 하나다(명세 5절). 화면에 `userCode` · `verificationUriComplete`(QR)를 보이고 `wait()`로 기다린다. 코드를 받은 순간부터 폴링한다.
public final class LoginAttempt: @unchecked Sendable {
    public let userCode: String
    public let verificationUri: String
    public let verificationUriComplete: String
    /// 코드가 만료되는 시각(ISO 8601).
    public let expiresAt: String

    private struct State {
        var interval: Int
        var settled = false
        var handle: ScheduleHandle?
        var result: Result<LoginResult, BydevError>?
    }

    private let expiresAtMs: Int64
    private let deviceCode: String
    private let clientId: String
    private let api: Api
    private let tokens: TokenManager
    private let done = Signal()
    private let state: Locked<State>

    init(code: DeviceCode, clientId: String, api: Api, tokens: TokenManager) {
        let expiresAtMs = api.ports.clock.nowMs() + Int64(code.expiresIn) * 1000
        self.expiresAtMs = expiresAtMs
        deviceCode = code.deviceCode
        self.clientId = clientId
        self.api = api
        self.tokens = tokens
        state = Locked(State(interval: code.interval))
        userCode = code.userCode
        verificationUri = code.verificationUri
        verificationUriComplete = code.verificationUriComplete
        expiresAt = ISOTime.format(ms: expiresAtMs)
    }

    /// 로그인이 끝나기를 기다린다. 실패는 `BydevError`(`EXPIRED_TOKEN` · `INVALID_GRANT` · `LOGIN_CANCELLED` · `STORAGE_FAILED` …).
    public func wait() async throws -> LoginResult {
        await api.ports.scheduler.wait(for: done)
        switch state.current.result {
        case .success(let result)?: return result
        case .failure(let error)?: throw error
        case nil: throw BydevError(code: Codes.loginCancelled, message: "로그인을 취소했다")
        }
    }

    /// 로그인을 취소한다 — `wait()`는 `LOGIN_CANCELLED`로 끝난다.
    public func cancel() {
        finish(.failure(BydevError(code: Codes.loginCancelled, message: "로그인을 취소했다")))
    }

    private func finish(_ result: Result<LoginResult, BydevError>) {
        var handle: ScheduleHandle?
        let first: Bool = state.withLock { s in
            if s.settled { return false }
            s.settled = true
            s.result = result
            handle = s.handle
            s.handle = nil
            return true
        }
        guard first else { return }
        handle?.cancel()
        done.fire()
    }

    private var settled: Bool { state.current.settled }

    /// 폴링 지터는 위로만(interval보다 이르면 SLOW_DOWN이다).
    func schedulePoll() {
        let ports = api.ports
        let interval = state.current.interval
        let delay = jittered(
            ports.random, baseMs: Int64(max(0, interval)) * 1000, min: Rules.loginPollJitterMin,
            max: Rules.loginPollJitterMax)
        if ports.clock.nowMs() + delay > expiresAtMs {
            finish(.failure(BydevError(code: Codes.expiredToken, message: "로그인 코드가 만료됐다 — 처음부터 다시")))
            return
        }
        let handle = ports.scheduler.schedule(afterMs: delay) { [self] in await poll() }
        let late: Bool = state.withLock { s in
            if s.settled { return true }
            s.handle = handle
            return false
        }
        if late { handle.cancel() }
    }

    private func poll() async {
        if settled { return }
        let outcome: Result<ApiResponse, BydevError>
        do {
            let doc = try await api.discovery()
            let body: JSONValue = .object([
                "grant_type": .string(Spec.deviceCodeGrantType), "client_id": .string(clientId),
                "device_code": .string(deviceCode),
            ])
            outcome = .success(try await api.send(Req("POST", doc.tokenEndpoint, body: body)))
        } catch {
            outcome = .failure(BydevError.wrap(error, Codes.networkError, "API에 연결하지 못했다"))
        }
        if settled { return }
        switch outcome {
        case .success(let res):
            do {
                let set = try TokenSet.read(res.json)
                try tokens.adopt(set)
                finish(.success(LoginResult(scope: set.scope)))
            } catch {
                finish(.failure(BydevError.wrap(error, Codes.protocolError, "로그인 응답을 읽지 못했다")))
            }
        case .failure(let e):
            if e.code == Codes.authorizationPending || e.isTransient {
                schedulePoll()
            } else if e.code == Codes.slowDown {
                state.withLock { s in
                    if let n = e.retryAfterSec, n > 0 {
                        s.interval = n
                    } else {
                        s.interval += Rules.loginSlowDownIncrementSec
                    }
                }
                schedulePoll()
            } else {
                finish(.failure(e))
            }
        }
    }
}
