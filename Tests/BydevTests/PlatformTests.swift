import Foundation
import Security
import Testing

@testable import Bydev

private let record = CredentialRecord(
    version: 1, refreshToken: "rt_node_test_00000000001", scope: "entitlement.read", savedAt: "2026-10-06T13:00:00Z")

/// 키체인 호출을 기록하는 가짜 — 시험이 사용자 키체인을 건드리지 않는다.
private final class FakeKeychain: KeychainBackend, @unchecked Sendable {
    var item: Data?
    var calls: [(String, [String: Any])] = []
    var failWith: OSStatus?

    func copyData(_ query: [String: Any]) -> (OSStatus, Data?) {
        calls.append(("copy", query))
        if let failWith { return (failWith, nil) }
        return item.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        calls.append(("add", attributes))
        item = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        calls.append(("update", query))
        guard item != nil else { return errSecItemNotFound }
        item = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        calls.append(("delete", query))
        defer { item = nil }
        return item == nil ? errSecItemNotFound : errSecSuccess
    }
}

private final class RecordingLog: LogSink, @unchecked Sendable {
    var warns: [String] = []

    func debug(_ message: String) {}

    func info(_ message: String) {}

    func warn(_ message: String) { warns.append(message) }
}

@Test func keychainStore() throws {
    let fake = FakeKeychain()
    let store = KeychainStore(account: "cli_test", backend: fake)
    #expect(try store.load() == nil)  // 항목 없음
    try store.save(record)  // 없으면 update → add
    #expect(fake.calls.map(\.0) == ["copy", "update", "add"])
    let added = fake.calls[2].1
    #expect(added[kSecAttrService as String] as? String == Rules.storageService)
    #expect(added[kSecAttrAccount as String] as? String == "cli_test")
    // 비밀은 값(kSecValueData)에만 — 이름 · 설명 속성에 없다
    for (key, value) in added where key != kSecValueData as String {
        #expect(!String(describing: value).contains(record.refreshToken))
    }
    #expect(try store.load() == record)
    try store.save(record)  // 있으면 update만
    #expect(fake.calls.map(\.0).suffix(1) == ["update"])
    try store.clear()
    try store.clear()  // 없는 항목 지우기는 실패가 아니다
    #expect(try store.load() == nil)
    fake.failWith = errSecAuthFailed
    #expect(throws: KeychainError.self) { try store.load() }
}

@Test func fileStoreRealDisk() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bydev-swift-test-\(UUID().uuidString)")
        .path
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = (dir as NSString).appendingPathComponent("sub/bydev-credentials")
    let log = RecordingLog()
    let store = OSPorts.fileCredentialStore(path: path, logger: log)
    #expect(log.warns.count == 1)  // 암호화하지 않는다는 warn
    #expect(try store.load() == nil)
    try store.save(record)
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    #expect(try store.load() == record)
    // 판이 다른 기록은 없는 것으로 읽는다
    try Data(#"{"version":99,"refreshToken":"x"}"#.utf8).write(to: URL(fileURLWithPath: path))
    #expect(try store.load() == nil)
    try store.clear()
    try store.clear()  // 없는 파일 지우기는 실패가 아니다
    #expect(try FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent).isEmpty)
}

@Test func fingerprintInstallIDFallback() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bydev-swift-test-\(UUID().uuidString)")
        .path
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let file = (dir as NSString).appendingPathComponent("install-id")
    let source = OSFingerprint(installIDFile: file, machineID: { nil })
    let first = try #require(try source.read())
    #expect(UUID(uuidString: first) != nil)
    #expect(String(decoding: FileManager.default.contents(atPath: file) ?? Data(), as: UTF8.self) == first)
    try Data("kept-install-id\n".utf8).write(to: URL(fileURLWithPath: file))
    #expect(try source.read() == "kept-install-id")
    // 파일 자리도 없으면 nil(SDK가 수명 동안의 난수 ID로 물러난다)
    #expect(try OSFingerprint(installIDFile: nil, machineID: { nil }).read() == nil)
    #expect(try OSFingerprint(installIDFile: file, machineID: { " A1B2-UUID \n" }).read() == "A1B2-UUID")
}

/// 이 기기의 실제 지문 출처 · 기기 정보를 한 번 읽는다(값은 출력하지 않는다).
@Test func thisMachine() throws {
    #expect(!(try OSPorts.fingerprintSource().read() ?? "").isEmpty, "IOPlatformUUID를 읽지 못했다")
    let device = OSPorts.systemDeviceInfo()
    #expect((1...64).contains(device.name.count) && device.platform == DevicePlatform.macos)
    #expect(OSPorts.appDataDirectory("App").hasSuffix("Library/Application Support/App"))
}

/// 이 Mac의 로그인 키체인에 실제로 넣고 · 고치고 · 읽고 · 지운다 — `BYDEV_KEYCHAIN_CHECK=1`일 때만(사용자 키체인을 건드린다 — launch-checklist A31).
/// 항목은 서비스 `dev.developedby.sdk` · 계정 `bydev-keychain-check` 하나이고 끝나면 지운다.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BYDEV_KEYCHAIN_CHECK"] == "1"))
func realKeychain() throws {
    let store = OSPorts.keychainCredentialStore(account: "bydev-keychain-check")
    try store.clear()
    defer { try? store.clear() }
    #expect(try store.load() == nil)
    try store.save(record)  // 없으면 넣기
    #expect(try store.load() == record)
    let rotated = CredentialRecord(
        version: 1, refreshToken: "rt_keychain_rotated_000001", scope: record.scope, savedAt: record.savedAt)
    try store.save(rotated)  // 있으면 고치기
    #expect(try store.load() == rotated)
    try store.clear()
    #expect(try store.load() == nil)
}
