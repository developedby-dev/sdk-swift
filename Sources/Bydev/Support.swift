import Foundation

/// 잠금으로 지키는 값 — 잠근 채 포트를 부르지 않는다(명세 2절). `NSLock`을 비동기 함수에서 직접 잠그지 않으려고 동기 메서드로 감쌌다.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
}

/// 한 번 켜지는 신호 — 다른 작업의 끝(single-flight · 로그인)을 기다릴 때 쓴다. SDK는 `wait()`를 직접 부르지 않고 `TaskScheduler.wait(for:)`를 거친다
/// (하네스가 기다림을 셀 수 있게 — 명세 2절).
public final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// 켠다. 기다리던 쪽이 모두 깨어난다. 두 번째부터는 아무것도 하지 않는다.
    public func fire() {
        let woken: [CheckedContinuation<Void, Never>]
        do {
            lock.lock()
            defer { lock.unlock() }
            if fired { return }
            fired = true
            woken = waiters
            waiters = []
        }
        for waiter in woken { waiter.resume() }
    }

    public var isFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    /// 켜질 때까지 기다린다.
    public func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !register(continuation) { continuation.resume() }
        }
    }

    private func register(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        waiters.append(continuation)
        return true
    }
}

/// 한 번에 하나만 도는 작업이다 — 기다리는 쪽은 `TaskScheduler.wait(for:)`로 기다린다(명세 2절 · 6절 1).
final class SingleFlight<T: Sendable>: @unchecked Sendable {
    private final class Flight: @unchecked Sendable {
        let done = Signal()
        let result = Locked<Result<T, Error>?>(nil)
    }

    private let current = Locked<Flight?>(nil)

    func run(_ scheduler: any TaskScheduler, _ work: () async throws -> T) async throws -> T {
        var mine: Flight?
        let running: Flight? = current.withLock { slot in
            if let flight = slot { return flight }
            let flight = Flight()
            slot = flight
            mine = flight
            return nil
        }
        if let running {
            await scheduler.wait(for: running.done)
            guard let result = running.result.current else {
                throw BydevError(code: Codes.protocolError, message: "작업 결과가 없다")
            }
            return try result.get()
        }
        let flight = mine!
        let result: Result<T, Error>
        do {
            result = .success(try await work())
        } catch {
            result = .failure(error)
        }
        flight.result.withLock { $0 = result }
        current.withLock { $0 = nil }
        flight.done.fire()
        return try result.get()
    }
}

/// `floor(x + 0.5)` 밀리초 — 명세 2절의 반올림.
func roundedMs(_ x: Double) -> Int64 { Int64((x + 0.5).rounded(.down)) }

/// 초(소수 가능) → 밀리초.
func seconds(_ sec: Double) -> Int64 { roundedMs(sec * 1000) }

/// `round(base × (min + (max − min) × r))`.
func jittered(_ random: any RandomSource, baseMs: Int64, min: Double, max: Double) -> Int64 {
    roundedMs(Double(baseMs) * (min + (max - min) * random.nextDouble()))
}

/// 소문자 16진.
func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

enum Base64URL {
    static func decode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// UTC 시각 ↔ ISO 8601(밀리초가 0이면 뗀다 — `2026-10-06T13:00:00Z` · `…:00.250Z`). 날짜 계산은 H. Hinnant의 civil 알고리즘(다른 SDK와 같다).
public enum ISOTime {
    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 { a >= 0 ? a / b : -((-a + b - 1) / b) }

    private static func daysFromCivil(_ y0: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y = m <= 2 ? y0 - 1 : y0
        let era = floorDiv(y, 400)
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ z0: Int64) -> (Int64, Int64, Int64) {
        let z = z0 + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? yoe + era * 400 + 1 : yoe + era * 400, m, d)
    }

    public static func format(ms: Int64) -> String {
        let secs = floorDiv(ms, 1000)
        let millis = ms - secs * 1000
        let days = floorDiv(secs, 86_400)
        let (y, mo, d) = civilFromDays(days)
        let rem = secs - days * 86_400
        let base = String(
            format: "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld", y, mo, d, rem / 3600, rem % 3600 / 60, rem % 60)
        return millis == 0 ? base + "Z" : base + String(format: ".%03lldZ", millis)
    }

    /// RFC 3339(`Z` 또는 `±hh:mm`, 소수 초 허용) → Unix 밀리초. 읽지 못하면 nil.
    public static func parse(_ text: String) -> Int64? {
        let b = Array(text.utf8)
        func num(_ from: Int, _ len: Int) -> Int64? {
            guard from + len <= b.count else { return nil }
            var v: Int64 = 0
            for c in b[from..<from + len] {
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int64(c - 48)
            }
            return v
        }
        guard b.count >= 20, b[4] == 45, b[7] == 45, b[10] == 84 || b[10] == 116, b[13] == 58, b[16] == 58,
            let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2),
            let s = num(17, 2), (1...12).contains(mo), (1...31).contains(d), h <= 23, mi <= 59, s <= 60
        else { return nil }
        var i = 19
        var millis: Int64 = 0
        if i < b.count, b[i] == 46 {
            let start = i + 1
            i = start
            while i < b.count, b[i] >= 48, b[i] <= 57 { i += 1 }
            guard i > start else { return nil }
            var digits = Array(b[start..<i].prefix(3))
            while digits.count < 3 { digits.append(48) }
            millis = digits.reduce(0) { $0 * 10 + Int64($1 - 48) }
        }
        guard i < b.count else { return nil }
        let offsetMin: Int64
        let c = b[i]
        if (c == 90 || c == 122) && i + 1 == b.count {
            offsetMin = 0
        } else if (c == 43 || c == 45) && i + 6 == b.count && b[i + 3] == 58 {
            guard let oh = num(i + 1, 2), let om = num(i + 4, 2) else { return nil }
            offsetMin = c == 43 ? oh * 60 + om : -(oh * 60 + om)
        } else {
            return nil
        }
        return ((daysFromCivil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + s - offsetMin * 60) * 1000) + millis
    }
}
