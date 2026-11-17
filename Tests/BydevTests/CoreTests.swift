import Foundation
import Testing

@testable import Bydev

/// 명세 3.4 — 일시적 실패 분류.
@Test(
    arguments: [
        (Codes.rateLimited, 429, true), (Codes.internalError, 503, true), (Codes.networkError, nil, true),
        // 429인 한도 초과 코드는 끝난 실패다
        (Codes.takeoverLimitExceeded, 429, false), (Codes.deviceReleaseLimitExceeded, 429, false),
        // 모르는 코드만 HTTP 상태로
        ("FUTURE_THROTTLE", 429, true), ("FUTURE_OUTAGE", 502, true), ("FUTURE_FORBIDDEN", 403, false),
        ("FUTURE_NOTHING", nil, false), (Codes.storageFailed, nil, false),
    ] as [(String, Int?, Bool)])
func transient(code: String, status: Int?, want: Bool) {
    #expect(BydevError(code: code, message: "시험", httpStatus: status).isTransient == want)
}

/// 키는 언제나 다 있다 — 없는 값은 null. 한글을 \uXXXX로 바꾸지 않는다.
@Test func errorJSON() {
    let e = BydevError(
        code: Codes.rateLimited, message: "잠시 뒤에", httpStatus: 429, correlationId: "req_err0001", retryAfterSec: 30)
    #expect(
        e.toJSON()
            == #"{"code":"RATE_LIMITED","correlationId":"req_err0001","details":null,"httpStatus":429,"message":"잠시 뒤에","retryAfterSec":30}"#
    )
}

@Test func isoTimeRoundTrip() {
    let t = ISOTime.parse("2026-10-06T13:00:00Z")
    #expect(t == 1_791_291_600_000)
    #expect(ISOTime.format(ms: 1_791_291_600_000) == "2026-10-06T13:00:00Z")
    #expect(ISOTime.format(ms: 1_791_291_600_250) == "2026-10-06T13:00:00.250Z")
    #expect(ISOTime.parse("2026-10-06T22:00:00.5+09:00") == 1_791_291_600_500)
    #expect(ISOTime.parse("1970-01-01T00:00:00Z") == 0)
    #expect(ISOTime.format(ms: 951_782_400_000) == "2000-02-29T00:00:00Z")
    #expect(ISOTime.parse("2026-10-06 13:00:00Z") == nil)
    #expect(ISOTime.parse("2026-10-06T13:00:00") == nil)
    #expect(ISOTime.parse("2026-10-06T13:00:00Zjunk") == nil)
}

/// 빠진 필드 · 틀린 형은 PROTOCOL_ERROR — 모르는 필드는 버린다.
@Test func lenientButStrictReading() throws {
    let ok = try Profile.read(JSONValue.parse(#"{"profile":{"pseudonymousId":"psub_1","nickname":"코드장인","extra":1}}"#)!)
    #expect(ok == Profile(pseudonymousId: "psub_1", nickname: "코드장인", email: nil))
    do {
        _ = try Profile.read(JSONValue.parse(#"{"profile":{"nickname":"코드장인"}}"#)!)
        Issue.record("빠진 필드를 읽었다")
    } catch let e as BydevError {
        #expect(e.code == Codes.protocolError)
    }
}

/// 업데이트 제공 범위(ADR-0049) — 모르는 `type`은 이름만 남기고, 빠지거나 `UNTIL`에 `until`이 없으면 PROTOCOL_ERROR.
@Test func updateCoverageReading() throws {
    func entitlement(_ coverage: String?) -> JSONValue {
        let field = coverage.map { #""updateCoverage":\#($0),"# } ?? ""
        return JSONValue.parse(
            #"{"entitlement":{"id":"ent_1","productId":"prod_1","status":"ACTIVE","#
                + #""term":{"type":"PERPETUAL","expiresAt":null,"remainingDays":null,"remainingSeconds":null},"#
                + field
                + #""subscription":null,"policy":{"maxDevices":3,"maxConcurrent":1,"heartbeatSec":150,"#
                + #""offlineGraceHours":0},"evaluatedAt":"2026-10-06T14:00:00Z"}}"#)!
    }
    #expect(try Entitlement.read(entitlement(#"{"type":"ALL"}"#)).updateCoverage == .all)
    let until = try Entitlement.read(entitlement(#"{"type":"UNTIL","until":"2027-11-12T03:00:00Z"}"#))
    #expect(until.updateCoverage == .until("2027-11-12T03:00:00Z"))
    #expect(until.updateCoverage.json.jsonString == #"{"type":"UNTIL","until":"2027-11-12T03:00:00Z"}"#)
    let unknown = try Entitlement.read(entitlement(#"{"type":"BY_RELEASE_LINE","line":"2.x"}"#))
    #expect(unknown.updateCoverage == .other(type: "BY_RELEASE_LINE"))
    #expect(unknown.updateCoverage.json.jsonString == #"{"type":"BY_RELEASE_LINE"}"#)
    for bad in [nil, #"{"type":"UNTIL"}"#] {
        do {
            _ = try Entitlement.read(entitlement(bad))
            Issue.record("잘못된 updateCoverage를 읽었다: \(bad ?? "(없음)")")
        } catch let e as BydevError {
            #expect(e.code == Codes.protocolError)
        }
    }
}

/// 업데이트 확인의 `entitled` — 없으면 nil(json에도 없다), `release`는 최상위와 같은 규칙으로 읽는다.
@Test func entitledUpdateReading() throws {
    let top =
        #""product":{"id":"prod_1"},"target":"MACOS_UNIVERSAL","#
        + #""latest":{"version":"2.0.0","releasedAt":"2027-12-01T06:00:00Z","notes":null},"#
        + #""update":{"status":"AVAILABLE"},"install":{"mode":"EXTERNAL","channels":[]}"#
    let plain = try UpdateCheck.read(JSONValue.parse("{\(top)}")!)
    #expect(plain.entitled == nil)
    #expect(plain.json["entitled"] == nil)
    let covered = try UpdateCheck.read(
        JSONValue.parse(
            "{\(top),"
                + #""entitled":{"coveredUntil":"2027-11-12T03:00:00Z","release":{"#
                + #""latest":{"version":"1.4.2","releasedAt":"2027-10-02T06:00:00Z","notes":null},"#
                + #""update":{"status":"UP_TO_DATE"},"install":{"mode":"SIDELOAD"}}}}"#)!)
    #expect(covered.entitled?.coveredUntil == "2027-11-12T03:00:00Z")
    #expect(covered.entitled?.release?.latest.version == "1.4.2")
    #expect(covered.entitled?.release?.install == .other(mode: "SIDELOAD"))
    let none = try UpdateCheck.read(
        JSONValue.parse("{\(top)," + #""entitled":{"coveredUntil":"2027-11-12T03:00:00Z","release":null}}"#)!)
    #expect(none.entitled?.json.jsonString == #"{"coveredUntil":"2027-11-12T03:00:00Z","release":null}"#)
    do {
        _ = try UpdateCheck.read(
            JSONValue.parse("{\(top)," + #""entitled":{"coveredUntil":"2027-11-12T03:00:00Z","release":{}}}"#)!)
        Issue.record("빈 entitled.release를 읽었다")
    } catch let e as BydevError {
        #expect(e.code == Codes.protocolError)
        #expect(e.message.contains("entitled.release.latest"))
    }
}
