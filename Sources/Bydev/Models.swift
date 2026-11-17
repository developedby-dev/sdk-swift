import Foundation

// 공개 API 응답의 SDK 모델 — JSON 이름은 contracts 그대로, 없을 수 있는 값은 옵셔널. 열거 값은 `String`(모르는 값도 — 명세 0절 5, 아는 값은
// 생성된 `EntitlementStatus` 등).

/// 모델은 모두 `json`(contracts 모양 — 기록 · 진단용)이 있다.
public protocol BydevModel: Sendable, Equatable {
    var json: JSONValue { get }
}

extension BydevModel {
    public func toJSON() -> String { json.jsonString }
}

/// 기간이다. `type`을 먼저 분기한다 — 영구(`PERPETUAL`)는 잔여 필드가 nil이다.
public struct EntitlementTerm: BydevModel {
    public let type: String
    public let expiresAt: String?
    public let remainingDays: Int?
    public let remainingSeconds: Int?

    public var json: JSONValue {
        .object([
            "type": .string(type), "expiresAt": .of(expiresAt), "remainingDays": .of(remainingDays),
            "remainingSeconds": .of(remainingSeconds),
        ])
    }
}

/// 구독형일 때만 있다.
public struct EntitlementSubscription: BydevModel {
    public let id: String
    public let status: String
    public let willRenew: Bool
    public let nextBillingAt: String?
    public let graceEndsAt: String?

    public var json: JSONValue {
        .object([
            "id": .string(id), "status": .string(status), "willRenew": .of(willRenew),
            "nextBillingAt": .of(nextBillingAt), "graceEndsAt": .of(graceEndsAt),
        ])
    }
}

/// 판매자가 정한 정책 수치다 — 앱에 하드코딩하지 않는다.
public struct LicensePolicy: BydevModel {
    public let maxDevices: Int
    public let maxConcurrent: Int
    public let heartbeatSec: Int
    public let offlineGraceHours: Int

    public var json: JSONValue {
        .object([
            "maxDevices": .of(maxDevices), "maxConcurrent": .of(maxConcurrent), "heartbeatSec": .of(heartbeatSec),
            "offlineGraceHours": .of(offlineGraceHours),
        ])
    }
}

/// 업데이트 제공 범위다(ADR-0049). `type`을 먼저 분기한다 — `.until`이면 그 시각 전에 출시된 버전을 실행할 수 있다. 모르는 방식이면
/// `.other`(방식 이름만).
public enum UpdateCoverage: BydevModel {
    /// 앞으로 출시되는 모든 버전
    case all
    /// 이 시각(ISO 8601) 전에 출시된 버전
    case until(String)
    case other(type: String)

    /// `ALL` · `UNTIL` …(`UpdateCoverageType`)
    public var type: String {
        switch self {
        case .all: UpdateCoverageType.all
        case .until: UpdateCoverageType.until
        case .other(let type): type
        }
    }

    public var json: JSONValue {
        switch self {
        case .until(let until): .object(["type": .string(type), "until": .string(until)])
        case .all, .other: .object(["type": .string(type)])
        }
    }
}

/// 이 제품의 이용권이다.
public struct Entitlement: BydevModel {
    public let id: String
    public let productId: String
    public let status: String
    public let term: EntitlementTerm
    /// 이 이용권으로 실행할 수 있는 버전의 범위다.
    public let updateCoverage: UpdateCoverage
    public let subscription: EntitlementSubscription?
    public let policy: LicensePolicy
    public let evaluatedAt: String

    public var json: JSONValue {
        .object([
            "id": .string(id), "productId": .string(productId), "status": .string(status), "term": term.json,
            "updateCoverage": updateCoverage.json, "subscription": .of(subscription), "policy": policy.json,
            "evaluatedAt": .string(evaluatedAt),
        ])
    }

    static func read(_ json: JSONValue) throws -> Entitlement {
        var r = Reader()
        let root = r.object(json, "$")
        let e = r.object(root["entitlement"], "entitlement")
        let t = r.object(e["term"], "entitlement.term")
        let type = r.str(t["type"], "entitlement.term.type")
        var term = EntitlementTerm(type: type, expiresAt: nil, remainingDays: nil, remainingSeconds: nil)
        if type != "PERPETUAL" {
            term = EntitlementTerm(
                type: type, expiresAt: r.optStr(t["expiresAt"], "entitlement.term.expiresAt"),
                remainingDays: r.optInt(t["remainingDays"], "entitlement.term.remainingDays"),
                remainingSeconds: r.optInt(t["remainingSeconds"], "entitlement.term.remainingSeconds"))
        }
        let c = r.object(e["updateCoverage"], "entitlement.updateCoverage")
        let coverageType = r.str(c["type"], "entitlement.updateCoverage.type")
        let updateCoverage: UpdateCoverage
        switch coverageType {
        case UpdateCoverageType.all: updateCoverage = .all
        case UpdateCoverageType.until:
            updateCoverage = .until(r.str(c["until"], "entitlement.updateCoverage.until"))
        default: updateCoverage = .other(type: coverageType)
        }
        let p = r.object(e["policy"], "entitlement.policy")
        let policy = LicensePolicy(
            maxDevices: r.int(p["maxDevices"], "entitlement.policy.maxDevices"),
            maxConcurrent: r.int(p["maxConcurrent"], "entitlement.policy.maxConcurrent"),
            heartbeatSec: r.int(p["heartbeatSec"], "entitlement.policy.heartbeatSec"),
            offlineGraceHours: r.int(p["offlineGraceHours"], "entitlement.policy.offlineGraceHours"))
        var subscription: EntitlementSubscription?
        if let sub = e["subscription"], sub != .null {
            let s = r.object(sub, "entitlement.subscription")
            subscription = EntitlementSubscription(
                id: r.str(s["id"], "entitlement.subscription.id"),
                status: r.str(s["status"], "entitlement.subscription.status"),
                willRenew: r.bool(s["willRenew"], "entitlement.subscription.willRenew"),
                nextBillingAt: r.optStr(s["nextBillingAt"], "entitlement.subscription.nextBillingAt"),
                graceEndsAt: r.optStr(s["graceEndsAt"], "entitlement.subscription.graceEndsAt"))
        }
        let out = Entitlement(
            id: r.str(e["id"], "entitlement.id"), productId: r.str(e["productId"], "entitlement.productId"),
            status: r.str(e["status"], "entitlement.status"), term: term, updateCoverage: updateCoverage,
            subscription: subscription, policy: policy, evaluatedAt: r.str(e["evaluatedAt"], "entitlement.evaluatedAt"))
        return try r.finish(out)
    }
}

/// 등록된 기기다.
public struct Device: BydevModel {
    public let id: String
    public let name: String
    public let platform: String
    public let registeredAt: String
    public let lastSeenAt: String

    public var json: JSONValue {
        .object([
            "id": .string(id), "name": .string(name), "platform": .string(platform),
            "registeredAt": .string(registeredAt), "lastSeenAt": .string(lastSeenAt),
        ])
    }
}

/// 기기 목록 한 쪽이다. `nextCursor`가 nil이면 마지막 쪽이다.
public struct DevicePage: BydevModel {
    public let items: [Device]
    public let nextCursor: String?

    public var json: JSONValue { .object(["items": .array(items.map(\.json)), "nextCursor": .of(nextCursor)]) }

    static func read(_ json: JSONValue) throws -> DevicePage {
        var r = Reader()
        let page = r.object(json, "$")
        var items: [Device] = []
        for v in r.array(page["items"], "items") {
            let d = r.object(v, "items[]")
            items.append(
                Device(
                    id: r.str(d["id"], "items[].id"), name: r.str(d["name"], "items[].name"),
                    platform: r.str(d["platform"], "items[].platform"),
                    registeredAt: r.str(d["registeredAt"], "items[].registeredAt"),
                    lastSeenAt: r.str(d["lastSeenAt"], "items[].lastSeenAt")))
        }
        return try r.finish(DevicePage(items: items, nextCursor: r.optStr(page["nextCursor"], "nextCursor")))
    }
}

/// 기기 해제 결과다.
public struct DeviceRelease: BydevModel {
    public let id: String
    public let status: String
    public let releasedAt: String

    public var json: JSONValue {
        .object(["id": .string(id), "status": .string(status), "releasedAt": .string(releasedAt)])
    }

    static func read(_ json: JSONValue) throws -> DeviceRelease {
        var r = Reader()
        let d = r.object(r.object(json, "$")["device"], "device")
        let out = DeviceRelease(
            id: r.str(d["id"], "device.id"), status: r.str(d["status"], "device.status"),
            releasedAt: r.str(d["releasedAt"], "device.releasedAt"))
        return try r.finish(out)
    }
}

/// 닉네임과 가명 식별자다. `pseudonymousId`를 판매자 쪽 고객 키로 쓴다.
public struct Profile: BydevModel {
    public let pseudonymousId: String
    public let nickname: String
    public let email: String?

    public var json: JSONValue {
        .object(["pseudonymousId": .string(pseudonymousId), "nickname": .string(nickname), "email": .of(email)])
    }

    static func read(_ json: JSONValue) throws -> Profile {
        var r = Reader()
        let p = r.object(r.object(json, "$")["profile"], "profile")
        let out = Profile(
            pseudonymousId: r.str(p["pseudonymousId"], "profile.pseudonymousId"),
            nickname: r.str(p["nickname"], "profile.nickname"), email: r.optStr(p["email"], "profile.email"))
        return try r.finish(out)
    }
}

/// 외부 채널의 설치 위치다.
public struct ExternalChannel: BydevModel {
    public let channel: String
    public let locator: String

    public var json: JSONValue { .object(["channel": .string(channel), "locator": .string(locator)]) }
}

/// 설치 방법이다. 모르는 방식이면 `.other`(방식 이름만).
public enum ProductInstall: BydevModel {
    case hosted(buildId: String, downloadUrl: String, downloadUrlExpiresAt: String, sha256: String, sizeBytes: Int)
    case external(channels: [ExternalChannel])
    case other(mode: String)

    public var mode: String {
        switch self {
        case .hosted: InstallMode.hosted
        case .external: InstallMode.external
        case .other(let mode): mode
        }
    }

    /// 호스팅이면 SHA-256(설치 전 `verifyDownload`) — 아니면 nil.
    public var sha256: String? {
        if case .hosted(_, _, _, let sha256, _) = self { return sha256 }
        return nil
    }

    public var json: JSONValue {
        switch self {
        case .hosted(let buildId, let downloadUrl, let downloadUrlExpiresAt, let sha256, let sizeBytes):
            .object([
                "mode": .string(mode), "buildId": .string(buildId), "downloadUrl": .string(downloadUrl),
                "downloadUrlExpiresAt": .string(downloadUrlExpiresAt), "sha256": .string(sha256),
                "sizeBytes": .of(sizeBytes),
            ])
        case .external(let channels):
            .object(["mode": .string(mode), "channels": .array(channels.map(\.json))])
        case .other:
            .object(["mode": .string(mode)])
        }
    }
}

/// 최신 버전.
public struct UpdateLatest: BydevModel {
    public let version: String
    public let releasedAt: String
    public let notes: String?

    public var json: JSONValue {
        .object(["version": .string(version), "releasedAt": .string(releasedAt), "notes": .of(notes)])
    }
}

/// 최신 버전 · 업데이트 판정 · 설치 방법이다 — 업데이트 확인의 최상위와 `entitled.release`가 같은 모양이다.
public struct UpdateRelease: BydevModel {
    public let latest: UpdateLatest
    /// `UP_TO_DATE` · `AVAILABLE` · `REQUIRED` …(`UpdateStatus`)
    public let updateStatus: String
    public let install: ProductInstall

    var fields: [String: JSONValue] {
        ["latest": latest.json, "update": .object(["status": .string(updateStatus)]), "install": install.json]
    }

    public var json: JSONValue { .object(fields) }

    /// `prefix`는 오류 경로의 앞(`""` · `"entitled.release."`).
    static func read(_ r: inout Reader, _ o: [String: JSONValue], prefix: String) -> UpdateRelease {
        let l = r.object(o["latest"], prefix + "latest")
        let latest = UpdateLatest(
            version: r.str(l["version"], prefix + "latest.version"),
            releasedAt: r.str(l["releasedAt"], prefix + "latest.releasedAt"),
            notes: r.optStr(l["notes"], prefix + "latest.notes"))
        let status = r.str(r.object(o["update"], prefix + "update")["status"], prefix + "update.status")
        let i = r.object(o["install"], prefix + "install")
        let mode = r.str(i["mode"], prefix + "install.mode")
        let install: ProductInstall
        switch mode {
        case InstallMode.hosted:
            install = .hosted(
                buildId: r.str(i["buildId"], prefix + "install.buildId"),
                downloadUrl: r.str(i["downloadUrl"], prefix + "install.downloadUrl"),
                downloadUrlExpiresAt: r.str(i["downloadUrlExpiresAt"], prefix + "install.downloadUrlExpiresAt"),
                sha256: r.str(i["sha256"], prefix + "install.sha256"),
                sizeBytes: r.int(i["sizeBytes"], prefix + "install.sizeBytes"))
        case InstallMode.external:
            var channels: [ExternalChannel] = []
            for v in r.array(i["channels"], prefix + "install.channels") {
                let c = r.object(v, prefix + "install.channels[]")
                channels.append(
                    ExternalChannel(
                        channel: r.str(c["channel"], prefix + "install.channels[].channel"),
                        locator: r.str(c["locator"], prefix + "install.channels[].locator")))
            }
            install = .external(channels: channels)
        default:
            install = .other(mode: mode)
        }
        return UpdateRelease(latest: latest, updateStatus: status, install: install)
    }
}

/// 업데이트 제공 기한이 있는 구매자에게만 오는 값이다(ADR-0049 4절). 있으면 앱은 최상위 대신 `release`를 따른다 — 최상위 최신은 그 구매자가
/// 실행할 수 없는 버전일 수 있다(범위 밖 버전을 설치하면 세션 획득이 `ENTITLEMENT_VERSION_NOT_COVERED`로 거절된다). 이 대상에 범위 안 버전이
/// 없으면 `release`는 nil.
public struct EntitledUpdate: BydevModel {
    public let coveredUntil: String
    public let release: UpdateRelease?

    public var json: JSONValue { .object(["coveredUntil": .string(coveredUntil), "release": .of(release)]) }
}

/// 업데이트 확인 결과다. `updateStatus`가 `REQUIRED`면 업데이트 전까지 실행을 막는다. `entitled`가 있으면 최상위 대신 `entitled.release`를 따른다.
public struct UpdateCheck: BydevModel {
    public let productId: String
    public let target: String
    public let latest: UpdateLatest
    /// `UP_TO_DATE` · `AVAILABLE` · `REQUIRED` …(`UpdateStatus`)
    public let updateStatus: String
    public let install: ProductInstall
    /// 업데이트 제공 기한이 있는 구매자에게만 있다.
    public let entitled: EntitledUpdate?

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "product": .object(["id": .string(productId)]), "target": .string(target), "latest": latest.json,
            "update": .object(["status": .string(updateStatus)]), "install": install.json,
        ]
        // 계약에서 생략 가능한 필드다 — 없으면 키도 없다
        if let entitled { o["entitled"] = entitled.json }
        return .object(o)
    }

    static func read(_ json: JSONValue) throws -> UpdateCheck {
        var r = Reader()
        let o = r.object(json, "$")
        let productId = r.str(r.object(o["product"], "product")["id"], "product.id")
        let target = r.str(o["target"], "target")
        let top = UpdateRelease.read(&r, o, prefix: "")
        var entitled: EntitledUpdate?
        if let value = o["entitled"], value != .null {
            let e = r.object(value, "entitled")
            var release: UpdateRelease?
            if let rel = e["release"], rel != .null {
                release = UpdateRelease.read(&r, r.object(rel, "entitled.release"), prefix: "entitled.release.")
            }
            entitled = EntitledUpdate(coveredUntil: r.str(e["coveredUntil"], "entitled.coveredUntil"), release: release)
        }
        return try r.finish(
            UpdateCheck(
                productId: productId, target: target, latest: top.latest, updateStatus: top.updateStatus,
                install: top.install, entitled: entitled))
    }
}

/// 세션(실행 리스)이다.
public struct SessionInfo: BydevModel {
    public let id: String
    public let productId: String
    public let deviceId: String
    public let generation: Int
    public internal(set) var leaseExpiresAt: String
    public let heartbeatSec: Int

    public var json: JSONValue {
        .object([
            "id": .string(id), "productId": .string(productId), "deviceId": .string(deviceId),
            "generation": .of(generation), "leaseExpiresAt": .string(leaseExpiresAt), "heartbeatSec": .of(heartbeatSec),
        ])
    }
}

/// 세션 보유 증명 JWT와 그 만료(오프라인 유예의 끝)다.
public struct LicenseTokenInfo: BydevModel {
    public let token: String
    public let expiresAt: String

    public var json: JSONValue { .object(["token": .string(token), "expiresAt": .string(expiresAt)]) }
}

func readSessionResponse(_ json: JSONValue) throws -> (SessionInfo, LicenseTokenInfo) {
    var r = Reader()
    let o = r.object(json, "$")
    let s = r.object(o["session"], "session")
    let t = r.object(o["licenseToken"], "licenseToken")
    let session = SessionInfo(
        id: r.str(s["id"], "session.id"), productId: r.str(s["productId"], "session.productId"),
        deviceId: r.str(s["deviceId"], "session.deviceId"), generation: r.int(s["generation"], "session.generation"),
        leaseExpiresAt: r.str(s["leaseExpiresAt"], "session.leaseExpiresAt"),
        heartbeatSec: r.int(s["heartbeatSec"], "session.heartbeatSec"))
    let token = LicenseTokenInfo(
        token: r.str(t["token"], "licenseToken.token"), expiresAt: r.str(t["expiresAt"], "licenseToken.expiresAt"))
    return try r.finish((session, token))
}

/// 검증된 licenseToken 클레임이다(명세 9절). JSON 이름은 JWT 그대로(`product_id` · `device_id`).
public struct LicenseClaims: BydevModel {
    public let iss: String
    public let sub: String
    public let aud: String
    public let productId: String
    public let deviceId: String
    public let sid: String
    public let generation: Int
    public let iat: Int
    public let exp: Int
    /// 세션을 얻을 때 앱이 보낸 대상 · 버전(설정 `app`)으로 서버가 확정한 빌드(`build_id`, ADR-0049). 확정하지 못했으면 nil.
    public let buildId: String?

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "iss": .string(iss), "sub": .string(sub), "aud": .string(aud), "product_id": .string(productId),
            "device_id": .string(deviceId), "sid": .string(sid), "generation": .of(generation), "iat": .of(iat),
            "exp": .of(exp),
        ]
        // JWT에서 생략 가능한 클레임이다 — 없으면 키도 없다
        if let buildId { o["build_id"] = .string(buildId) }
        return .object(o)
    }

    static func read(_ json: JSONValue) throws -> LicenseClaims {
        var r = Reader()
        let c = r.object(json, "claims")
        let out = LicenseClaims(
            iss: r.str(c["iss"], "claims.iss"), sub: r.str(c["sub"], "claims.sub"), aud: r.str(c["aud"], "claims.aud"),
            productId: r.str(c["product_id"], "claims.product_id"), deviceId: r.str(c["device_id"], "claims.device_id"),
            sid: r.str(c["sid"], "claims.sid"), generation: r.int(c["generation"], "claims.generation"),
            iat: r.int(c["iat"], "claims.iat"), exp: r.int(c["exp"], "claims.exp"),
            buildId: r.optStr(c["build_id"], "claims.build_id"))
        return try r.finish(out)
    }
}

struct TokenSet: Sendable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String
    let scope: String

    static func read(_ json: JSONValue) throws -> TokenSet {
        var r = Reader()
        let t = r.object(json, "$")
        let out = TokenSet(
            accessToken: r.str(t["access_token"], "access_token"), expiresIn: r.int(t["expires_in"], "expires_in"),
            refreshToken: r.str(t["refresh_token"], "refresh_token"), scope: r.str(t["scope"], "scope"))
        return try r.finish(out)
    }
}

struct DeviceCode: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String
    let expiresIn: Int
    let interval: Int

    static func read(_ json: JSONValue) throws -> DeviceCode {
        var r = Reader()
        let d = r.object(json, "$")
        let out = DeviceCode(
            deviceCode: r.str(d["device_code"], "device_code"), userCode: r.str(d["user_code"], "user_code"),
            verificationUri: r.str(d["verification_uri"], "verification_uri"),
            verificationUriComplete: r.str(d["verification_uri_complete"], "verification_uri_complete"),
            expiresIn: r.int(d["expires_in"], "expires_in"), interval: r.int(d["interval"], "interval"))
        return try r.finish(out)
    }
}

struct Discovery: Sendable {
    let issuer: String
    let jwksUri: String
    let deviceAuthorizationEndpoint: String
    let tokenEndpoint: String
    let revocationEndpoint: String

    static func read(_ json: JSONValue) throws -> Discovery {
        var r = Reader()
        let d = r.object(json, "$")
        let out = Discovery(
            issuer: r.str(d["issuer"], "issuer"), jwksUri: r.str(d["jwks_uri"], "jwks_uri"),
            deviceAuthorizationEndpoint: r.str(d["device_authorization_endpoint"], "device_authorization_endpoint"),
            tokenEndpoint: r.str(d["token_endpoint"], "token_endpoint"),
            revocationEndpoint: r.str(d["revocation_endpoint"], "revocation_endpoint"))
        return try r.finish(out)
    }
}
