// Swift SDK의 적합성 하네스(sdks/spec/harness-protocol.md). 표준 입출력 JSON 줄로 실행기와 이야기하며 SDK를 가상 시계 · 가상 스케줄러 · 대리 전송으로
// 몬다.
//
// 정착 판정은 블로킹 언어와 같다(Swift 동시성은 협력 스레드 풀에서 돈다): SDK 일을 하는 작업 수(`running`)를 세고, 전송 · `sleep` · `wait`에서 기다리는
// 작업은 그 기다림의 신호를 등록한다. `running`이 0이고, 답을 기다리는 요청이 없고, 등록된 신호가 하나도 켜지지 않았으면(깨어날 작업이 없으면) 할 일이 없다.
import Bydev
import Foundation

final class Harness: @unchecked Sendable {
    static let shared = Harness()

    final class Timer: @unchecked Sendable {
        let due: Int64
        let seq: UInt64
        let work: @Sendable () async -> Void
        var cancelled = false

        init(due: Int64, seq: UInt64, work: @escaping @Sendable () async -> Void) {
            self.due = due
            self.seq = seq
            self.work = work
        }
    }

    final class Exchange: @unchecked Sendable {
        let done = Signal()
        var response: HTTPResponse?
    }

    private let lock = NSLock()
    private let outLock = NSLock()
    private var now: Int64 = 0
    private var timers: [Timer] = []
    private var seq: UInt64 = 0
    private var running = 0
    private var waiters: [UInt64: Signal] = [:]
    private var waiterId: UInt64 = 0
    private var pending: [String: Exchange] = [:]
    private var randoms: [Double] = []
    private var uuids = 0
    private var httpSeq = 0
    private var record: CredentialRecord?
    private var failLoad = false
    private var failSave = false
    private var failClear = false
    private var client: LicenseClient?
    private var login: LoginAttempt?

    private let inbox = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var queue: [[String: JSONValue]] = []

    func locked<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var clock: Int64 { locked { now } }

    func emit(_ message: [String: JSONValue]) {
        let line = JSONValue.object(message).jsonString + "\n"
        outLock.lock()
        defer { outLock.unlock() }
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    func fatal(_ message: String) -> Never {
        emit(["type": .string("fatal"), "message": .string(message)])
        exit(1)
    }

    /// SDK 작업이 포트에서 기다리는 동안 `running`에서 빠지고 신호를 등록한다.
    func block(_ done: Signal) async {
        let id: UInt64 = locked {
            running -= 1
            waiterId += 1
            waiters[waiterId] = done
            return waiterId
        }
        await done.wait()
        locked {
            waiters[id] = nil
            running += 1
        }
    }

    // ── 포트 ──────────────────────────────────────────────────────

    struct Ports: HTTPTransport, CredentialStore, WallClock, TaskScheduler, RandomSource, FingerprintSource, LogSink {
        let h: Harness
        let fingerprint: String?

        func nowMs() -> Int64 { h.clock }

        func schedule(afterMs delay: Int64, _ work: @escaping @Sendable () async -> Void) -> ScheduleHandle {
            let timer: Timer = h.locked {
                let t = Timer(due: h.now + max(0, delay), seq: h.seq, work: work)
                h.seq += 1
                h.timers.append(t)
                return t
            }
            return ScheduleHandle { [h] in h.locked { timer.cancelled = true } }
        }

        func sleep(ms: Int64) async {
            let done = Signal()
            _ = schedule(afterMs: ms) { done.fire() }
            await h.block(done)
        }

        func wait(for signal: Signal) async { await h.block(signal) }

        func nextDouble() -> Double {
            let value: Double? = h.locked { h.randoms.isEmpty ? nil : h.randoms.removeFirst() }
            guard let value else { h.fatal("시나리오의 random 값을 다 썼다 — random에 더 적는다") }
            return value
        }

        func uuid() -> String {
            let n: Int = h.locked {
                h.uuids += 1
                return h.uuids
            }
            return String(format: "00000000-0000-4000-8000-%012x", n)
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let exchange = Exchange()
            let (id, at): (String, Int64) = h.locked {
                h.httpSeq += 1
                let id = "h\(h.httpSeq)"
                h.pending[id] = exchange
                return (id, h.now)
            }
            var headers: [String: JSONValue] = [:]
            for (k, v) in request.headers { headers[k.lowercased()] = .string(v) }
            h.emit([
                "type": .string("http.request"), "id": .string(id), "now": .number(Double(at)),
                "request": .object([
                    "method": .string(request.method), "url": .string(request.url), "headers": .object(headers),
                    "body": request.body.map { .string(String(decoding: $0, as: UTF8.self)) } ?? .null,
                ]),
            ])
            await h.block(exchange.done)
            guard let response = h.locked({ exchange.response }) else {
                throw BydevError(code: Codes.networkError, message: "대리 전송 실패")
            }
            return response
        }

        func load() throws -> CredentialRecord? {
            try h.locked {
                if h.failLoad { throw HarnessError("저장소 읽기 실패(시험)") }
                return h.record
            }
        }

        func save(_ record: CredentialRecord) throws {
            let at: Int64 = try h.locked {
                if h.failSave { throw HarnessError("저장소 쓰기 실패(시험)") }
                h.record = record
                return h.now
            }
            h.emit([
                "type": .string("event"), "now": .number(Double(at)),
                "event": .object([
                    "kind": .string("storage"), "op": .string("save"), "record": Harness.recordJSON(record),
                ]),
            ])
        }

        func clear() throws {
            let at: Int64 = try h.locked {
                if h.failClear { throw HarnessError("저장소 지우기 실패(시험)") }
                h.record = nil
                return h.now
            }
            h.emit([
                "type": .string("event"), "now": .number(Double(at)),
                "event": .object(["kind": .string("storage"), "op": .string("clear")]),
            ])
        }

        func read() throws -> String? { fingerprint }

        func debug(_ message: String) {}

        func info(_ message: String) {}

        func warn(_ message: String) { FileHandle.standardError.write(Data("warn: \(message)\n".utf8)) }
    }

    struct HarnessError: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) { self.description = description }
    }

    static func recordJSON(_ r: CredentialRecord) -> JSONValue {
        .object([
            "version": .number(Double(r.version)), "refreshToken": .string(r.refreshToken), "scope": .string(r.scope),
            "savedAt": .string(r.savedAt),
        ])
    }

    // ── 정착 ──────────────────────────────────────────────────────

    private func quiet() -> Bool {
        locked { running == 0 && pending.isEmpty && !waiters.values.contains { $0.isFired } }
    }

    private func waitQuiet() {
        while !quiet() { usleep(50) }
    }

    /// `limit`까지 온, 취소되지 않은 가장 이른 예약을 꺼낸다.
    private func takeTimer(limit: Int64) -> Timer? {
        timers.removeAll { $0.cancelled }
        guard
            let index = timers.indices.filter({ timers[$0].due <= limit }).min(by: {
                (timers[$0].due, timers[$0].seq) < (timers[$1].due, timers[$1].seq)
            })
        else { return nil }
        return timers.remove(at: index)
    }

    /// 지금 시각까지 온 예약 작업을 하나씩 — 앞 작업이 끝나거나 기다릴 때까지 — 돌린다.
    private func settle() {
        while true {
            waitQuiet()
            let timer: Timer? = locked {
                let t = takeTimer(limit: now)
                if t != nil { running += 1 }
                return t
            }
            guard let timer else { return }
            Task.detached { [self] in
                await timer.work()
                locked { running -= 1 }
            }
        }
    }

    private func advance(_ ms: Int64) {
        let target = clock + ms
        while true {
            settle()
            let next: Int64? = locked {
                timers.removeAll { $0.cancelled }
                return timers.filter { $0.due <= target }.map(\.due).min()
            }
            guard let next else { break }
            locked { now = next }
        }
        locked { now = target }
        settle()
    }

    // ── 호출 ──────────────────────────────────────────────────────

    private func arg(_ args: [String: JSONValue], _ key: String) -> String {
        guard let value = args[key]?.stringValue else { fatal("인자 \(key)가 문자열이 아니다") }
        return value
    }

    private func invoke(_ method: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        guard let c = locked({ client }) else { fatal("init 전에 호출했다") }
        func session() -> LicenseSession {
            do { return try c.session() } catch { fatal("세션: \(error)") }
        }
        switch method {
        case "login.start":
            let attempt = try await c.startLogin()
            locked { login = attempt }
            return .object([
                "userCode": .string(attempt.userCode), "verificationUri": .string(attempt.verificationUri),
                "verificationUriComplete": .string(attempt.verificationUriComplete),
                "expiresAt": .string(attempt.expiresAt),
            ])
        case "login.wait":
            guard let attempt = locked({ login }) else { fatal("login.start 전에 login.wait") }
            return try await attempt.wait().json
        case "login.cancel":
            locked { login }?.cancel()
            return .null
        case "hasCredentials":
            return .bool(try c.hasCredentials())
        case "entitlement":
            return try await c.entitlement().json
        case "devices":
            return try await c.devices(
                cursor: args["cursor"]?.stringValue, limit: args["limit"]?.numberValue.map { Int($0) }
            )
            .json
        case "releaseDevice":
            return try await c.releaseDevice(arg(args, "deviceId")).json
        case "profile":
            return try await c.profile().json
        case "checkForUpdate":
            return try await c.checkForUpdate(target: arg(args, "target"), currentVersion: arg(args, "currentVersion"))
                .json
        case "verifyDownload":
            guard let data = Data(base64Encoded: arg(args, "dataBase64")) else { fatal("dataBase64를 읽지 못했다") }
            try c.verifyDownload(data, sha256: arg(args, "sha256"))
            return .null
        case "verifyToken":
            return try await c.verifyToken(arg(args, "token")).json
        case "logout":
            return .object(["serverRevoked": .bool(try await c.logout())])
        case "session.start":
            session().start()
            return .null
        case "session.takeOver":
            session().takeOver()
            return .null
        case "session.retry":
            session().retry()
            return .null
        case "session.stop":
            await session().stop()
            return .null
        case "session.state":
            return session().state.json
        default:
            fatal("모르는 호출 \(method)")
        }
    }

    private func startCall(id: String, method: String, args: [String: JSONValue]) {
        locked { running += 1 }
        Task.detached { [self] in
            var message: [String: JSONValue] = ["type": .string("result"), "id": .string(id)]
            do {
                let value = try await invoke(method, args)
                message["ok"] = .bool(true)
                message["value"] = value
            } catch let e as BydevError {
                message["ok"] = .bool(false)
                message["error"] = e.json
            } catch {
                message["ok"] = .bool(false)
                message["error"] = .object(["code": .string("HARNESS_ERROR"), "message": .string("\(error)")])
            }
            message["now"] = .number(Double(clock))
            emit(message)
            locked { running -= 1 }
        }
    }

    // ── 명령 ──────────────────────────────────────────────────────

    private func initialize(_ message: [String: JSONValue]) {
        guard let config = message["config"]?.objectValue, let device = config["device"]?.objectValue,
            let started = message["now"]?.stringValue.flatMap(ISOTime.parse)
        else { fatal("init를 읽지 못했다") }
        func text(_ o: [String: JSONValue], _ key: String) -> String {
            guard let v = o[key]?.stringValue else { fatal("init.\(key)") }
            return v
        }
        locked {
            now = started
            randoms =
                (message["random"].flatMap { v -> [JSONValue]? in
                    if case .array(let a) = v { return a }
                    return nil
                } ?? []).compactMap(\.numberValue)
            if let s = message["storage"]?.objectValue, let token = s["refreshToken"]?.stringValue {
                record = CredentialRecord(
                    version: Int(s["version"]?.numberValue ?? 1), refreshToken: token,
                    scope: s["scope"]?.stringValue ?? "", savedAt: s["savedAt"]?.stringValue ?? "")
            }
        }
        let scopes: [String]
        if case .array(let a)? = config["scopes"] { scopes = a.compactMap(\.stringValue) } else { scopes = [] }
        let ports = Ports(h: self, fingerprint: device["fingerprintSource"]?.stringValue)
        // 시나리오가 적을 때만 온다
        let app = config["app"]?.objectValue.map { AppInfo(target: text($0, "target"), version: text($0, "version")) }
        let made: LicenseClient
        do {
            made = try LicenseClient(
                .init(
                    baseURL: text(config, "baseUrl"), clientId: text(config, "clientId"),
                    productId: text(config, "productId"), scopes: scopes,
                    device: DeviceInfo(name: text(device, "name"), platform: text(device, "platform")), app: app,
                    ports: Bydev.Ports(
                        transport: ports, store: ports, clock: ports, scheduler: ports, random: ports,
                        fingerprint: ports,
                        logger: ports)))
            try made.session().subscribe { [self] state in
                emit([
                    "type": .string("event"), "now": .number(Double(clock)),
                    "event": .object(["kind": .string("session.state"), "state": state.json]),
                ])
            }
        } catch {
            fatal("LicenseClient: \(error)")
        }
        locked { client = made }
    }

    private func onHTTPResponse(_ message: [String: JSONValue]) {
        let id = message["id"]?.stringValue ?? ""
        // 지우기와 켜기를 한 잠금 안에서 — 둘 사이에 "할 일 없음"으로 보이는 틈이 없게
        let known: Bool = locked {
            guard let exchange = pending.removeValue(forKey: id) else { return false }
            if let r = message["response"]?.objectValue {
                var headers: [String: String] = [:]
                for (k, v) in r["headers"]?.objectValue ?? [:] { headers[k.lowercased()] = v.stringValue ?? "" }
                exchange.response = HTTPResponse(
                    status: Int(r["status"]?.numberValue ?? 0), headers: headers,
                    body: Data((r["body"]?.stringValue ?? "").utf8))
            }
            exchange.done.fire()
            return true
        }
        if !known { fatal("모르는 http.response id \(id)") }
    }

    private func next() -> [String: JSONValue] {
        arrived.wait()
        inbox.lock()
        defer { inbox.unlock() }
        return queue.removeFirst()
    }

    private func enqueue(_ message: [String: JSONValue]) {
        inbox.lock()
        queue.append(message)
        inbox.unlock()
        arrived.signal()
    }

    func run() -> Never {
        emit([
            "type": .string("ready"), "sdk": .string("swift"), "version": .string(LicenseClient.sdkVersion),
            "specVersion": .string(Spec.version),
        ])
        let reader = Thread { [self] in
            while let line = readLine() {
                guard let message = JSONValue.parse(line)?.objectValue else { fatal("JSON이 아닌 입력: \(line)") }
                if message["type"]?.stringValue == "http.response" {
                    onHTTPResponse(message)
                } else {
                    enqueue(message)
                }
            }
            enqueue(["type": .string("end")])
        }
        reader.start()
        while true {
            let message = next()
            switch message["type"]?.stringValue ?? "" {
            case "init":
                initialize(message)
                settle()
            case "call":
                if case .array(let calls)? = message["calls"] {
                    for call in calls {
                        guard let c = call.objectValue else { continue }
                        startCall(
                            id: c["id"]?.stringValue ?? "", method: c["method"]?.stringValue ?? "",
                            args: c["args"]?.objectValue ?? [:])
                    }
                }
                settle()
            case "advance":
                advance(Int64(message["ms"]?.numberValue ?? 0))
            case "set":
                let value = message["value"] == .bool(true)
                locked {
                    switch message["key"]?.stringValue ?? "" {
                    case "storage.failLoad": failLoad = value
                    case "storage.failSave": failSave = value
                    case "storage.failClear": failClear = value
                    default: break
                    }
                }
                settle()
            case "end":
                exit(0)
            case let other:
                fatal("모르는 명령 \(other)")
            }
            emit(["type": .string("idle"), "now": .number(Double(clock))])
        }
    }
}

Harness.shared.run()
