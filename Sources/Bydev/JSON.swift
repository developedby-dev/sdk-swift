import Foundation

/// JSON 값 — 에러 상세(`details`)처럼 모양이 정해지지 않은 값과, 모델의 `json`(기록 · 진단용)이다.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// 간결한 JSON 문자열 — 객체 키는 이름순(언제나 같은 문자열).
    public var jsonString: String {
        var out = ""
        Self.write(self, into: &out)
        return out
    }

    /// JSON 문자열(또는 바이트)을 읽는다. JSON이 아니면 nil.
    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func parse(_ text: String) -> JSONValue? { parse(Data(text.utf8)) }

    private static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n):
            if n.rounded() == n, abs(n) < 9e15 {
                out += String(Int64(n))
            } else {
                out += "\(n)"
            }
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, key) in o.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                writeString(key, into: &out)
                out += ":"
                write(o[key]!, into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }
}

/// 모델에서 JSON 값을 만드는 도우미.
extension JSONValue {
    static func of(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
    static func of(_ n: Int?) -> JSONValue { n.map { .number(Double($0)) } ?? .null }
    static func of(_ b: Bool) -> JSONValue { .bool(b) }
    static func of(_ v: (some BydevModel)?) -> JSONValue { v?.json ?? .null }
}

/// 응답 읽기(명세 3.2) — 처음 어긋난 곳을 `PROTOCOL_ERROR`로 기억하고 기본값으로 이어 읽는다. 모르는 필드는 버린다.
struct Reader {
    private(set) var error: BydevError?

    private mutating func fail(_ path: String, _ want: String, _ got: JSONValue?) {
        guard error == nil else { return }
        let message = got == nil ? "응답에 \(path)가 없다" : "응답의 \(path)가 \(want)가 아니다 (\(got!.jsonString))"
        error = BydevError(code: Codes.protocolError, message: message)
    }

    mutating func object(_ v: JSONValue?, _ path: String) -> [String: JSONValue] {
        if case .object(let o)? = v { return o }
        fail(path, "객체", v)
        return [:]
    }

    mutating func str(_ v: JSONValue?, _ path: String) -> String {
        if case .string(let s)? = v { return s }
        fail(path, "문자열", v)
        return ""
    }

    mutating func int(_ v: JSONValue?, _ path: String) -> Int {
        if case .number(let n)? = v, n.rounded() == n, abs(n) < 9e15 { return Int(n) }
        fail(path, "정수", v)
        return 0
    }

    mutating func bool(_ v: JSONValue?, _ path: String) -> Bool {
        if case .bool(let b)? = v { return b }
        fail(path, "참/거짓", v)
        return false
    }

    mutating func array(_ v: JSONValue?, _ path: String) -> [JSONValue] {
        if case .array(let a)? = v { return a }
        fail(path, "배열", v)
        return []
    }

    mutating func optStr(_ v: JSONValue?, _ path: String) -> String? {
        if v == nil || v == .null { return nil }
        return str(v, path)
    }

    mutating func optInt(_ v: JSONValue?, _ path: String) -> Int? {
        if v == nil || v == .null { return nil }
        return int(v, path)
    }

    func finish<T>(_ value: T) throws -> T {
        if let error { throw error }
        return value
    }
}
