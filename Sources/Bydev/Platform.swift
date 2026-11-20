import Foundation
import IOKit
import Security
import SystemConfiguration

// 명세 2절 표 — macOS 기본 구현. 클라이언트의 기본 저장소는 메모리다 — 앱이 이 중에서 고른다(보통 `OSPorts.defaultCredentialStore`).

public enum OSPorts {
    /// 앱 데이터 폴더(`~/Library/Application Support/<앱>`).
    public static func appDataDirectory(_ appName: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent("Library/Application Support/\(appName)")
    }

    /// `Configuration.device`의 기본값 — 컴퓨터 이름(64자까지)과 `MACOS`.
    public static func systemDeviceInfo() -> DeviceInfo {
        var name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = "Mac" }
        return DeviceInfo(name: String(name.prefix(64)), platform: DevicePlatform.macos)
    }

    /// 명세 10절 · 2절 표의 지문 출처 — `IOPlatformUUID`(IOKit, 명령을 띄우지 않는다). 읽지 못하면 `installIDFile`의 설치 ID(없으면 만든다).
    /// `installIDFile`이 nil이면 nil(SDK가 클라이언트 수명 동안의 난수 ID로 물러난다).
    public static func fingerprintSource(installIDFile: String? = nil) -> any FingerprintSource {
        OSFingerprint(installIDFile: installIDFile, machineID: platformUUID)
    }

    /// 키체인(일반 암호 항목 — 서비스 `Rules.storageService`, 계정 `account`). account는 clientId.
    public static func keychainCredentialStore(account: String) -> any CredentialStore {
        KeychainStore(account: account, backend: SecurityKeychain())
    }

    /// 사용자 전용 권한(0600) 파일 — **암호화하지 않는다.** 키체인을 쓸 수 없을 때만(warn 로그).
    public static func fileCredentialStore(path: String, logger: (any LogSink)? = nil) -> any CredentialStore {
        FileStore(path: path, logger: logger)
    }

    /// 운영체제 기본 저장소 — macOS는 키체인. account는 clientId.
    public static func defaultCredentialStore(account: String) -> any CredentialStore {
        keychainCredentialStore(account: account)
    }

    static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }

    static func parseRecord(_ data: Data?) -> CredentialRecord? {
        guard let data, case .object(let o)? = JSONValue.parse(data), let version = o["version"]?.numberValue,
            version == Double(Rules.storageRecordVersion), let token = o["refreshToken"]?.stringValue, !token.isEmpty
        else { return nil }
        return CredentialRecord(
            version: 1, refreshToken: token, scope: o["scope"]?.stringValue ?? "",
            savedAt: o["savedAt"]?.stringValue ?? "")
    }

    static func writeRecord(_ r: CredentialRecord) -> Data {
        Data(
            JSONValue.object([
                "version": .of(r.version), "refreshToken": .string(r.refreshToken), "scope": .string(r.scope),
                "savedAt": .string(r.savedAt),
            ]).jsonString.utf8)
    }
}

struct OSFingerprint: FingerprintSource {
    let installIDFile: String?
    let machineID: @Sendable () -> String?
    /// 다시 읽기 전 기다림(밀리초, 명세 10절) — 단위 시험은 기다리지 않게 바꿔 끼운다
    var sleep: @Sendable (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1000) }

    /// 실패하거나 빈 값이면 설치 ID로 물러나기 전에 다시 읽는다(명세 10절) — 일시적인 실패 하나로 같은 Mac이 다른 기기가 되지 않게.
    func read() throws -> String? {
        for attempt in 0..<max(Rules.fingerprintSourceReadAttempts, 1) {
            if attempt > 0 { sleep(Rules.fingerprintSourceReadRetryDelayMs) }
            if let id = machineID()?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return id }
        }
        guard let installIDFile else { return nil }
        if let data = FileManager.default.contents(atPath: installIDFile),
            let existing = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !existing.isEmpty
        {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        try PrivateFile.write(Data(created.utf8), to: installIDFile)
        return created
    }
}

/// 사용자만 읽는 권한(0600)으로 만들고 이름을 바꿔 넣는다(반쯤 쓴 파일이 남지 않게, 다른 사용자가 읽는 틈이 없게).
enum PrivateFile {
    static func write(_ data: Data, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let temp = (dir as NSString).appendingPathComponent(
            ".\((path as NSString).lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let written = data.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, data.count) }
        close(fd)
        guard written == data.count, rename(temp, path) == 0 else {
            unlink(temp)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

struct FileStore: CredentialStore {
    let path: String

    init(path: String, logger: (any LogSink)?) {
        self.path = path
        logger?.warn("로그인 기록을 암호화하지 않은 사용자 전용 파일에 둔다 — 키체인을 쓸 수 없는 환경")
    }

    func load() throws -> CredentialRecord? { OSPorts.parseRecord(FileManager.default.contents(atPath: path)) }

    func save(_ record: CredentialRecord) throws { try PrivateFile.write(OSPorts.writeRecord(record), to: path) }

    func clear() throws {
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
    }
}

/// 키체인 호출 — 단위 시험이 바꿔 끼운다(시험이 사용자 키체인을 건드리지 않게).
protocol KeychainBackend: Sendable {
    func copyData(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SecurityKeychain: KeychainBackend {
    func copyData(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// 키체인이 실패를 알린 상태 코드.
public struct KeychainError: Error, Sendable, CustomStringConvertible {
    public let status: OSStatus

    public var description: String {
        "키체인 \(status): \((SecCopyErrorMessageString(status, nil) as String?) ?? "알 수 없는 오류")"
    }
}

struct KeychainStore: CredentialStore {
    let account: String
    let backend: any KeychainBackend

    private var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Rules.storageService,
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> CredentialRecord? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = backend.copyData(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return OSPorts.parseRecord(data)
    }

    func save(_ record: CredentialRecord) throws {
        let data = OSPorts.writeRecord(record)
        let updated = backend.update(base, [kSecValueData as String: data])
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "bydev \(account)"
        let added = backend.add(attributes)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    func clear() throws {
        let status = backend.delete(base)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
