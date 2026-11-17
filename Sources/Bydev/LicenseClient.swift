import CryptoKit
import Foundation

/// bydev 라이선스 API 클라이언트다. 서버 응답 하나의 참/거짓으로 기능을 열지 않는다 — `session()`의 상태와 검증된 토큰의 클레임을 쓴다.
public final class LicenseClient: @unchecked Sendable {
    /// User-Agent(`bydev-swift/<판>`)에 실린다.
    public static let sdkVersion = "0.1.0"
    static let userAgent = "bydev-swift/\(sdkVersion)"

    /// 명세 1절의 설정이다.
    public struct Configuration: Sendable {
        public var baseURL: String
        public var clientId: String
        public var productId: String
        public var scopes: [String]
        /// 세션을 쓰면 필요하다(`OSPorts.systemDeviceInfo()`).
        public var device: DeviceInfo?
        /// 실행 중인 앱의 배포 대상 · 버전이다 — 세션을 쓰면 넣는다(명세 1절 · ADR-0049).
        public var app: AppInfo?
        public var ports: Ports

        public init(
            baseURL: String, clientId: String, productId: String, scopes: [String], device: DeviceInfo? = nil,
            app: AppInfo? = nil, ports: Ports = Ports()
        ) {
            self.baseURL = baseURL
            self.clientId = clientId
            self.productId = productId
            self.scopes = scopes
            self.device = device
            self.app = app
            self.ports = ports
        }
    }

    private let configuration: Configuration
    private let api: Api
    private let tokens: TokenManager
    private let verifier: Verifier
    private let login = Locked<LoginAttempt?>(nil)
    private let licenseSession = Locked<LicenseSession?>(nil)

    public init(_ configuration: Configuration) throws {
        guard !configuration.scopes.isEmpty else {
            throw BydevError(code: Codes.configuration, message: "scopes가 비었다")
        }
        self.configuration = configuration
        api = Api(baseURL: configuration.baseURL, ports: configuration.ports.resolve(), userAgent: Self.userAgent)
        tokens = TokenManager(api: api, clientId: configuration.clientId)
        verifier = Verifier(api: api, clientId: configuration.clientId)
    }

    /// 디바이스 로그인을 시작한다(명세 5절). 진행 중인 로그인은 취소한다.
    public func startLogin() async throws -> LoginAttempt {
        login.withLock { previous in
            defer { previous = nil }
            return previous
        }?.cancel()
        let doc = try await api.discovery()
        let body: JSONValue = .object([
            "client_id": .string(configuration.clientId), "scope": .string(configuration.scopes.joined(separator: " ")),
        ])
        let res = try await api.send(Req("POST", doc.deviceAuthorizationEndpoint, body: body))
        let attempt = LoginAttempt(
            code: try DeviceCode.read(res.json), clientId: configuration.clientId, api: api, tokens: tokens)
        attempt.schedulePoll()
        login.withLock { $0 = attempt }
        return attempt
    }

    /// 저장된 로그인이 있는지다 — 이용 가능 여부가 아니다.
    public func hasCredentials() throws -> Bool { try tokens.load() != nil }

    private func get(_ path: String, params: [String: String] = [:], query: [(String, String)] = []) async throws
        -> JSONValue
    {
        let url = api.url(path, params: params, query: query)
        let res = try await tokens.authed { [api] bearer in try await api.send(Req("GET", url, bearer: bearer)) }
        noteLease(res)
        return res.json
    }

    private func noteLease(_ res: ApiResponse) {
        licenseSession.current?.noteLease(res.headers["x-lease-expires-at"])
    }

    /// 이 제품의 이용권이다.
    public func entitlement() async throws -> Entitlement {
        try Entitlement.read(try await get(Routes.getMyEntitlement.path))
    }

    /// 등록된 기기 한 쪽이다. 다음 쪽을 저절로 따라가지 않는다.
    public func devices(cursor: String? = nil, limit: Int? = nil) async throws -> DevicePage {
        var query: [(String, String)] = []
        if let cursor, !cursor.isEmpty { query.append(("cursor", cursor)) }
        if let limit, limit > 0 { query.append(("limit", String(limit))) }
        return try DevicePage.read(try await get(Routes.listDevices.path, query: query))
    }

    /// 기기를 해제한다(월 횟수 제한).
    public func releaseDevice(_ deviceId: String) async throws -> DeviceRelease {
        let key = api.ports.random.uuid()
        let url = api.url(Routes.releaseDevice.path, params: ["deviceId": deviceId])
        let res = try await tokens.authed { [api] bearer in
            try await api.send(Req("DELETE", url, bearer: bearer, idempotencyKey: key))
        }
        noteLease(res)
        return try DeviceRelease.read(res.json)
    }

    /// 닉네임과 가명 식별자다.
    public func profile() async throws -> Profile {
        try Profile.read(try await get(Routes.getProfile.path))
    }

    /// 업데이트 확인이다. `updateStatus`가 `REQUIRED`면 업데이트 전까지 실행을 막는다. 받은 파일은 설치 전에 `verifyDownload`.
    /// `entitled`가 있으면(업데이트 제공 기한이 있는 영구 이용권) 최상위 대신 `entitled.release`를 따른다 — 범위 밖 버전을 설치하면 세션 획득이 거절된다.
    public func checkForUpdate(target: String, currentVersion: String) async throws -> UpdateCheck {
        let json = try await get(
            Routes.getProductUpdates.path, params: ["id": configuration.productId],
            query: [("target", target), ("currentVersion", currentVersion)])
        return try UpdateCheck.read(json)
    }

    /// 내려받은 파일의 SHA-256을 확인한다 — 다르면 `DOWNLOAD_INTEGRITY`.
    public func verifyDownload(_ data: Data, sha256: String) throws {
        guard hex(SHA256.hash(data: data)) == sha256.lowercased() else {
            throw BydevError(code: Codes.downloadIntegrity, message: "내려받은 파일의 SHA-256이 다르다 — 설치하지 않는다")
        }
    }

    /// licenseToken을 검증한다(명세 9절) — 앱이 기능 코드 여러 곳에서 다시 검증할 때.
    public func verifyToken(_ token: String) async throws -> LicenseClaims {
        try await verifier.verifyLicense(token, expect: nil, minGeneration: 0)
    }

    /// 세션을 멈추고 폐기 요청을 한 번 보낸 뒤 기록을 지운다. 서버 폐기에 성공했는지를 돌려준다.
    public func logout() async throws -> Bool {
        login.withLock { previous in
            defer { previous = nil }
            return previous
        }?.cancel()
        if let session = licenseSession.current { await session.stop() }
        return try await tokens.logout()
    }

    /// 이 클라이언트의 세션이다(하나뿐).
    public func session() throws -> LicenseSession {
        try licenseSession.withLock { slot in
            if let session = slot { return session }
            guard let device = configuration.device else {
                throw BydevError(code: Codes.configuration, message: "세션을 쓰려면 device { name, platform }을 준다")
            }
            let session = LicenseSession(
                api: api, tokens: tokens, verifier: verifier, device: device, app: configuration.app)
            slot = session
            return session
        }
    }
}
