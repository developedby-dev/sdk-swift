import CryptoKit
import Foundation

// 명세 9절 — 토큰 검증 · JWKS 캐시 · 세대번호 단조 확인.

struct Expectation {
    let sid: String
    let deviceId: String
    let generation: Int
}

final class Verifier: @unchecked Sendable {
    private struct KeySet: Sendable {
        let keys: [String: Data]
        let fetchedAtMs: Int64
        let expiresAtMs: Int64
    }

    private let api: Api
    private let clientId: String
    private let set = Locked<KeySet?>(nil)
    private let fetching = SingleFlight<KeySet>()
    private let generations = Locked<[String: Int]>([:])

    init(api: Api, clientId: String) {
        self.api = api
        self.clientId = clientId
    }

    private static func invalid(_ message: String) -> BydevError {
        BydevError(code: Codes.tokenInvalid, message: message)
    }

    /// 9절 1 ~ 4. 페이로드를 돌려준다.
    private func verifySigned(_ token: String, typ: String) async throws -> JSONValue {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headRaw = Base64URL.decode(parts[0]), let bodyRaw = Base64URL.decode(parts[1]),
            let sig = Base64URL.decode(parts[2]), case .object(let header)? = JSONValue.parse(headRaw),
            let payload = JSONValue.parse(bodyRaw), payload.objectValue != nil
        else { throw Self.invalid("JWT를 읽지 못했다") }
        guard header["alg"]?.stringValue == "EdDSA" else {
            throw Self.invalid("alg \(header["alg"]?.jsonString ?? "null")")
        }
        guard header["typ"]?.stringValue == typ else {
            throw Self.invalid("typ \(header["typ"]?.jsonString ?? "null")")
        }
        guard let kid = header["kid"]?.stringValue else { throw Self.invalid("kid가 없다") }
        let raw = try await key(for: kid)
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
            key.isValidSignature(sig, for: Data("\(parts[0]).\(parts[1])".utf8))
        else { throw Self.invalid("서명이 맞지 않는다") }
        let doc = try await api.discovery()
        guard payload["iss"]?.stringValue == doc.issuer else { throw Self.invalid("iss가 다르다") }
        guard payload["aud"]?.stringValue == clientId else { throw Self.invalid("aud가 이 client_id가 아니다") }
        let nowSec = Double(api.ports.clock.nowMs()) / 1000
        guard let exp = payload["exp"]?.numberValue, exp > nowSec - Double(Rules.tokenClockLeewaySec) else {
            throw Self.invalid("만료된 토큰")
        }
        return payload
    }

    func verifyLicense(_ token: String, expect: Expectation?, minGeneration: Int) async throws -> LicenseClaims {
        let payload = try await verifySigned(token, typ: "license+jwt")
        guard let claims = try? LicenseClaims.read(payload) else { throw Self.invalid("클레임 모양이 다르다") }
        if let expect {
            if claims.sid != expect.sid { throw Self.invalid("sid가 세션과 다르다") }
            if claims.deviceId != expect.deviceId { throw Self.invalid("device_id가 세션과 다르다") }
            if claims.generation != expect.generation { throw Self.invalid("generation이 세션과 다르다") }
        }
        if minGeneration > 0, claims.generation < minGeneration {
            throw Self.regressed(claims.generation, minGeneration)
        }
        let slot = "\(claims.sub)|\(claims.deviceId)"
        let seen: Int? = generations.withLock { seen in
            if let s = seen[slot], claims.generation < s { return s }
            seen[slot] = max(seen[slot] ?? claims.generation, claims.generation)
            return nil
        }
        if let seen { throw Self.regressed(claims.generation, seen) }
        return claims
    }

    private static func regressed(_ got: Int, _ seen: Int) -> BydevError {
        BydevError(code: Codes.generationRegressed, message: "세대번호 \(got) < 이미 본 \(seen)")
    }

    /// 9.1절 — 지난 캐시는 쓰지 않는다 · 모르는 kid는 1분에 한 번만 다시 받는다.
    private func key(for kid: String) async throws -> Data {
        let now = api.ports.clock.nowMs()
        let keys: KeySet
        if let current = set.current, now < current.expiresAtMs {
            keys = current
        } else {
            keys = try await fetchKeys()
        }
        if let key = keys.keys[kid] { return key }
        if now - keys.fetchedAtMs < Int64(Rules.jwksUnknownKidRefetchMinIntervalSec) * 1000 {
            throw Self.invalid("모르는 kid \(kid)")
        }
        guard let key = try await fetchKeys().keys[kid] else { throw Self.invalid("모르는 kid \(kid)") }
        return key
    }

    private func fetchKeys() async throws -> KeySet {
        try await fetching.run(api.ports.scheduler) {
            let doc = try await api.discovery()
            let res = try await api.send(Req("GET", doc.jwksUri))
            var r = Reader()
            let root = r.object(res.json, "$")
            var keys: [String: Data] = [:]
            for item in r.array(root["keys"], "keys") {
                guard case .object(let jwk) = item, jwk["kty"]?.stringValue == "OKP",
                    jwk["crv"]?.stringValue == "Ed25519"
                else { continue }
                if let kid = jwk["kid"]?.stringValue, !kid.isEmpty, let x = jwk["x"]?.stringValue,
                    let raw = Base64URL.decode(x), raw.count == 32
                {
                    keys[kid] = raw
                } else {
                    api.ports.logger.warn("JWKS 키를 읽지 못했다")
                }
            }
            _ = try r.finish(())
            let age =
                res.headers["cache-control"]?.split(separator: ",").lazy.compactMap { part -> Int? in
                    let p = part.trimmingCharacters(in: .whitespaces)
                    return p.hasPrefix("max-age=") ? Int(p.dropFirst("max-age=".count)) : nil
                }.first ?? Rules.jwksDefaultMaxAgeSec
            let fetched = api.ports.clock.nowMs()
            let fresh = KeySet(keys: keys, fetchedAtMs: fetched, expiresAtMs: fetched + Int64(age) * 1000)
            set.withLock { $0 = fresh }
            return fresh
        }
    }
}
