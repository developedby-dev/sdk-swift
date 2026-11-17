import Foundation

/// SDK의 에러 하나다(명세 3.3). `code`로 분기하고(생성된 `Codes`) `message`는 보여 주기만 한다. 앱의 오류 화면에 `correlationId`를 보이면 문의를 바로
/// 찾는다.
public struct BydevError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String
    public let httpStatus: Int?
    public let correlationId: String?
    public let retryAfterSec: Int?
    /// 에러 상세(객체) — 없으면 nil.
    public let details: [String: JSONValue]?
    /// 감싼 원인(포트가 던진 에러)의 설명 — 진단용, 분기에 쓰지 않는다.
    public let cause: String?

    public init(
        code: String, message: String, httpStatus: Int? = nil, correlationId: String? = nil, retryAfterSec: Int? = nil,
        details: [String: JSONValue]? = nil, cause: String? = nil
    ) {
        self.code = code
        self.message = message
        self.httpStatus = httpStatus
        self.correlationId = correlationId
        self.retryAfterSec = retryAfterSec
        self.details = details
        self.cause = cause
    }

    /// 일시적 실패인지다(명세 3.4). 아는 코드는 그 뜻대로 — 429인 한도 초과 코드는 끝난 실패 — 모르는 코드만 HTTP 상태로 나눈다.
    public var isTransient: Bool {
        if Rules.transientCodes.contains(code) { return true }
        if Codes.apiHTTPStatus[code] != nil || Codes.sdk.contains(code) { return false }
        guard let status = httpStatus else { return false }
        return Rules.transientUnknownCodeStatuses.contains(status)
            || Rules.transientUnknownCodeStatusRanges.contains { $0.contains(status) }
    }

    public var description: String { "\(code): \(message)" }

    /// `{"code","message","httpStatus","correlationId","retryAfterSec","details"}` — 키는 언제나 다 있다(없는 값은 null).
    public var json: JSONValue {
        .object([
            "code": .string(code), "message": .string(message), "httpStatus": .of(httpStatus),
            "correlationId": .of(correlationId), "retryAfterSec": .of(retryAfterSec),
            "details": details.map(JSONValue.object) ?? .null,
        ])
    }

    public func toJSON() -> String { json.jsonString }

    /// 포트가 던진 에러를 `code`로 감싼다 — 이미 `BydevError`면 그대로.
    static func wrap(_ error: Error, _ code: String, _ message: String) -> BydevError {
        if let e = error as? BydevError { return e }
        return BydevError(code: code, message: message, cause: String(describing: error))
    }

    /// 저장소 실패는 언제나 `STORAGE_FAILED`(명세 2절).
    static func storage(_ error: Error, _ message: String) -> BydevError {
        if let e = error as? BydevError, e.code == Codes.storageFailed { return e }
        return BydevError(code: Codes.storageFailed, message: message, cause: String(describing: error))
    }
}
