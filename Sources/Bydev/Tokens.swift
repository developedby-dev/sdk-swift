import Foundation

// 명세 3.5 · 3.6 · 6절 — 기록 보관 · 갱신 · 인증 요청 감싸기 · 로그아웃.

final class TokenManager: @unchecked Sendable {
    let api: Api
    private let clientId: String
    private let access = Locked<(token: String, expiresAtMs: Int64)?>(nil)
    private let refreshing = SingleFlight<String>()

    init(api: Api, clientId: String) {
        self.api = api
        self.clientId = clientId
    }

    func load() throws -> CredentialRecord? {
        let record: CredentialRecord?
        do {
            record = try api.ports.store.load()
        } catch {
            throw BydevError.storage(error, "보안 저장소를 읽지 못했다")
        }
        return record?.version == Rules.storageRecordVersion ? record : nil
    }

    /// 6절 3 · 5절 — 저장한 뒤에 쓴다.
    func adopt(_ set: TokenSet) throws {
        access.withLock { $0 = nil }
        let ports = api.ports
        let record = CredentialRecord(
            version: 1, refreshToken: set.refreshToken, scope: set.scope,
            savedAt: ISOTime.format(ms: ports.clock.nowMs()))
        do {
            try ports.store.save(record)
        } catch {
            throw BydevError.storage(error, "새 로그인을 보안 저장소에 두지 못했다 — 새 토큰을 쓰지 않는다")
        }
        let expiresAtMs = ports.clock.nowMs() + Int64(set.expiresIn) * 1000
        access.withLock { $0 = (set.accessToken, expiresAtMs) }
    }

    private func accessToken() async throws -> String {
        let now = api.ports.clock.nowMs()
        if let a = access.current, a.expiresAtMs - Int64(Rules.tokenRefreshSkewSec) * 1000 > now { return a.token }
        return try await refresh()
    }

    /// 6절 1 — 한 번에 하나.
    func refresh() async throws -> String {
        access.withLock { $0 = nil }
        return try await refreshing.run(api.ports.scheduler) { try await doRefresh() }
    }

    private func doRefresh() async throws -> String {
        guard let record = try load() else {
            throw BydevError(code: Codes.notSignedIn, message: "로그인이 없다 — 먼저 로그인한다")
        }
        let doc = try await api.discovery()
        var attempt = 0
        while true {
            let body: JSONValue = .object([
                "grant_type": .string("refresh_token"), "client_id": .string(clientId),
                "refresh_token": .string(record.refreshToken),
            ])
            do {
                let res = try await api.send(Req("POST", doc.tokenEndpoint, body: body))
                let set = try TokenSet.read(res.json)
                try adopt(set)
                return set.accessToken
            } catch let e as BydevError {
                if e.code == Codes.invalidGrant {
                    forgetStored()
                    throw e
                }
                if !e.isTransient || attempt >= Rules.tokenRefreshRetryDelaysSec.count { throw e }
                await api.ports.scheduler.sleep(ms: seconds(Rules.tokenRefreshRetryDelaysSec[attempt]))
                attempt += 1
            }
        }
    }

    /// 3.5절 — 만료면 한 번만 갱신하고 다시 보낸다.
    func authed(_ send: (String) async throws -> ApiResponse) async throws -> ApiResponse {
        let token = try await accessToken()
        do {
            return try await send(token)
        } catch let e as BydevError where e.code == Codes.expiredToken {
            // 아래에서 한 번 갱신하고 다시
        }
        let fresh = try await refresh()
        do {
            return try await send(fresh)
        } catch let e as BydevError where e.code == Codes.expiredToken {
            // 갓 받은 토큰도 거절됐다 — 다음 요청이 같은 토큰을 다시 쓰지 않게 버린다
            access.withLock { $0 = nil }
            throw e
        }
    }

    private func forgetStored() {
        access.withLock { $0 = nil }
        do {
            try api.ports.store.clear()
        } catch {
            api.ports.logger.warn("끝난 로그인의 기록을 지우지 못했다")
        }
    }

    /// 7절 — 폐기 요청은 한 번, 결과와 상관없이 지운다. 서버가 폐기했는지를 돌려준다.
    func logout() async throws -> Bool {
        let record = try load()
        var revoked = false
        if let record, let doc = try? await api.discovery() {
            let body: JSONValue = .object([
                "client_id": .string(clientId), "token": .string(record.refreshToken),
                "token_type_hint": .string("refresh_token"),
            ])
            revoked = (try? await api.send(Req("POST", doc.revocationEndpoint, body: body))) != nil
        }
        access.withLock { $0 = nil }
        do {
            try api.ports.store.clear()
        } catch {
            throw BydevError.storage(error, "로그인 기록을 지우지 못했다")
        }
        return revoked
    }
}
