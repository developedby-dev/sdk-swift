import Foundation

// 명세 3 · 4절 — 요청 만들기 · 응답 읽기 · 발견 문서.

struct ApiResponse: Sendable {
    let headers: [String: String]
    let json: JSONValue
}

struct Req: Sendable {
    var method: String
    var url: String
    var body: JSONValue?
    var bearer: String?
    var idempotencyKey: String?

    init(_ method: String, _ url: String, body: JSONValue? = nil, bearer: String? = nil, idempotencyKey: String? = nil)
    {
        self.method = method
        self.url = url
        self.body = body
        self.bearer = bearer
        self.idempotencyKey = idempotencyKey
    }
}

final class Api: @unchecked Sendable {
    let baseURL: String
    let ports: ResolvedPorts
    private let userAgent: String
    private let doc = Locked<Discovery?>(nil)
    private let discovering = SingleFlight<Discovery>()

    init(baseURL: String, ports: ResolvedPorts, userAgent: String) {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        self.baseURL = base
        self.ports = ports
        self.userAgent = userAgent
    }

    /// 경로 조각 — 예약되지 않은 문자(A–Z a–z 0–9 - . _ ~)만 그대로.
    private static func escape(_ text: String, spacePlus: Bool) -> String {
        var out = ""
        for b in text.utf8 {
            switch b {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126: out.unicodeScalars.append(UnicodeScalar(b))
            case 32 where spacePlus: out += "+"
            default: out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// 경로 `{이름}`을 채우고 질의를 붙인다(이름순 — 언어마다 같은 URL).
    func url(_ path: String, params: [String: String] = [:], query: [(String, String)] = []) -> String {
        var out = baseURL
        var rest = Substring(path)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let after = rest.index(after: open)
            let close = rest[after...].firstIndex(of: "}") ?? rest.endIndex
            out += Self.escape(params[String(rest[after..<close])] ?? "", spacePlus: false)
            rest = close < rest.endIndex ? rest[rest.index(after: close)...] : ""
        }
        out += rest
        if !query.isEmpty {
            let pairs = query.sorted { $0.0 < $1.0 }.map {
                "\(Self.escape($0.0, spacePlus: true))=\(Self.escape($0.1, spacePlus: true))"
            }
            out += "?" + pairs.joined(separator: "&")
        }
        return out
    }

    /// 처음 한 번 받아 클라이언트 수명 동안 둔다. 실패하면 두지 않는다(명세 4절).
    func discovery() async throws -> Discovery {
        if let doc = doc.current { return doc }
        return try await discovering.run(ports.scheduler) {
            let res = try await send(Req("GET", baseURL + Routes.getOpenIdConfiguration.path))
            let found = try Discovery.read(res.json)
            var issuer = found.issuer
            while issuer.hasSuffix("/") { issuer.removeLast() }
            if issuer != baseURL {
                throw BydevError(
                    code: Codes.configuration, message: "발견 문서의 issuer(\(found.issuer))가 baseUrl(\(baseURL))과 다르다")
            }
            doc.withLock { $0 = found }
            return found
        }
    }

    func send(_ req: Req) async throws -> ApiResponse {
        var headers = ["accept": "application/json", "user-agent": userAgent]
        var body: Data?
        if let value = req.body {
            headers["content-type"] = "application/json"
            body = Data(value.jsonString.utf8)
        }
        if let bearer = req.bearer { headers["authorization"] = "Bearer \(bearer)" }
        if let key = req.idempotencyKey { headers["idempotency-key"] = key }
        let res: HTTPResponse
        do {
            res = try await ports.transport.send(
                HTTPRequest(method: req.method, url: req.url, headers: headers, body: body))
        } catch {
            throw BydevError.wrap(error, Codes.networkError, "API에 연결하지 못했다")
        }
        let correlation = res.headers["x-correlation-id"]
        let parsed = res.body.isEmpty ? nil : JSONValue.parse(res.body)
        if (200..<300).contains(res.status) {
            guard let json = parsed else {
                throw BydevError(
                    code: Codes.protocolError, message: "응답 본문이 JSON이 아니다", httpStatus: res.status,
                    correlationId: correlation)
            }
            return ApiResponse(headers: res.headers, json: json)
        }
        throw Self.error(status: res.status, headers: res.headers, parsed: parsed, correlation: correlation)
    }

    /// 3.2절. 실패 응답 → `BydevError`.
    private static func error(status: Int, headers: [String: String], parsed: JSONValue?, correlation: String?)
        -> BydevError
    {
        var retry = headers["retry-after"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap {
            $0 > 0 ? $0 : nil
        }
        if case .object(let m)? = parsed, case .string(let code)? = m["code"], case .string(let message)? = m["message"]
        {
            if case .number(let n)? = m["retryAfterSec"] { retry = Int(n) }
            return BydevError(
                code: code, message: message, httpStatus: status, correlationId: correlation, retryAfterSec: retry,
                details: m["details"]?.objectValue)
        }
        let code = status >= 500 ? Codes.internalError : status == 429 ? Codes.rateLimited : Codes.protocolError
        return BydevError(
            code: code, message: "HTTP \(status)", httpStatus: status, correlationId: correlation, retryAfterSec: retry)
    }
}
