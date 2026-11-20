# 데브 SDK: Swift

데브 라이선스 API의 공식 Swift SDK입니다. macOS 앱(SwiftUI, AppKit)에서 씁니다.

외부 의존성은 없으며, 애플 프레임워크(`URLSession`, CryptoKit,
Security, IOKit)만 사용합니다. 모든 언어의 SDK가 함께 따르는 [공통 동작 명세](https://github.com/developedby-dev/sdk-spec/blob/main/spec/README.md)대로 동작하고,
[적합성 시험 시나리오](https://github.com/developedby-dev/sdk-spec/tree/main/conformance/scenarios)를 모두 통과합니다.

| 지원 | 버전 |
|---|---|
| 동작 명세 | 1.2.0 |
| API | v1 |
| Swift | 6.0 이상(Swift 6 언어 모드, 엄격한 동시성) |
| 운영체제 | macOS 12 이상 |

Swift 패키지 이름과 라이브러리 이름은 모두 `Bydev`입니다. 공개 미러 저장소와 버전 태그는 서비스 오픈을 준비할 때 공개합니다.

그 전에는 이 저장소
안에서만 쓸 수 있습니다.

## 빠른 시작

```swift
import Bydev

let clientId = "cli_01J9M0Y6X4N3Q8ZD5R2KT7VCPW"  // 판매자 콘솔에서 제품마다 발급받습니다
let client = try LicenseClient(
    .init(
        baseURL: "https://api.developedby.dev", clientId: clientId, productId: "prod_01J9KZ3F7W2X8YQ4N6M5R1TBCD",
        scopes: ["entitlement.read", "session.write", "version.read"], device: OSPorts.systemDeviceInfo(),
        app: AppInfo(target: DistributionTarget.macosUniversal, version: "1.4.0"),  // 콘솔에 업로드한 빌드의 버전과 같게
        ports: Ports(
            store: OSPorts.defaultCredentialStore(account: clientId),  // 키체인에 저장합니다
            fingerprint: OSPorts.fingerprintSource(
                installIDFile: OSPorts.appDataDirectory("MyApp") + "/install-id"))))

if try !client.hasCredentials() {
    let login = try await client.startLogin()
    showCode(login.userCode, login.verificationUriComplete)  // 화면에 코드와 QR 코드를 보여 줍니다
    _ = try await login.wait()  // 사용자가 브라우저에서 승인할 때까지 기다립니다. 취소는 login.cancel()로 합니다
}

let session = try client.session()
let subscription = session.subscribe { state in
    Task { @MainActor in  // SDK 내부 작업에서 불리므로, UI는 메인 액터에서 바꿉니다
        switch state {
        case .active(let a): enableFeatures(a.claims)  // exp와 sid는 기능 코드에서 쓰고, 참/거짓 하나로만 판단하지 마세요
        case .degraded(let d): enableFeatures(d.active.claims)  // offlineUntil까지는 계속 쓸 수 있습니다
        case .needsDecision(let n): askUser(n)  // DEVICE_IN_USE: "여기서 사용할까요?"에 동의하면 session.takeOver()를 부릅니다
        case .locked(let l): lockApp(l.code, l.correlationId)  // 오류 화면에 correlationId를 보여 주세요
        case .starting, .stopped: break
        }
    }
}
session.start()
// 앱을 끌 때
await session.stop()
subscription.cancel()
```

## 포트

포트는 SDK가 HTTP 전송, 로그인 정보 저장, 시계 같은 바깥 기능을 쓰는 연결 지점입니다. 앱이 원하는 구현으로 교체할 수 있습니다.

명세에서 쓰는 포트 이름 일부가 표준 라이브러리(`Clock`), Combine(`Scheduler`), os(`Logger`)의 이름과 겹쳐서, Swift SDK에서는 다른 이름을 붙였습니다.

| 포트(명세 이름) | 기본 구현 | 직접 구현하거나 설정할 항목 |
|---|---|---|
| `HTTPTransport`(Transport) | `URLSessionTransport`입니다. 시간 초과는 30초이고, 쿠키와 캐시를 쓰지 않으며, 리다이렉트를 따라가지 않습니다. | 프록시나 인증서 고정이 필요하면 `URLSessionTransport(session:)`에 직접 만든 세션을 전달해 주세요. 이때 리다이렉트를 막는 것은 앱이 맡습니다. |
| `CredentialStore` | **메모리**에만 둡니다. 앱을 끄면 로그인이 사라집니다. | `OSPorts.defaultCredentialStore`, `keychainCredentialStore`(키체인), `fileCredentialStore`(권한 0600 파일에 저장하고 경고를 남깁니다) |
| `FingerprintSource` | 없습니다. 실행할 때마다 새 기기로 보일 수 있으며, 이때 경고 로그를 남깁니다. | `OSPorts.fingerprintSource(installIDFile:)`를 사용해 주세요. IOKit의 `IOPlatformUUID`를 쓰고, 읽지 못하면 설치 ID를 씁니다. |
| `WallClock`, `TaskScheduler`, `RandomSource`(Clock, Scheduler, Random) | 시스템 시계, `DispatchScheduler`, `SystemRandomNumberGenerator` | 시험할 때 교체합니다. SDK는 시간이나 다른 작업을 기다릴 때 `sleep`과 `wait(for:)`만 씁니다. |
| `LogSink`(Logger) | 아무것도 기록하지 않습니다(`SilentLog`). | 로그에는 토큰이나 기기 지문 원본이 넘어오지 않습니다. |

키체인에는 일반 암호 항목으로 저장합니다. 서비스는 `dev.developedby.sdk`, 계정은 clientId이며, 로그인 키체인에 둡니다.

데이터 보호
키체인(`kSecUseDataProtectionKeychain`)은 앱 서명에 키체인 접근 그룹 권한이 있어야 해서 쓰지 않습니다. 앱에서 SDK 버전을 올려도 같은 항목을 읽습니다.

## 사용 조건

- **업데이트**: `checkForUpdate(target:currentVersion:)`가 반환한 `updateStatus`가 `REQUIRED`이면, 업데이트하기 전까지 앱 실행을 막아 주세요.
  다운로드한 파일은 설치하기 전에 `verifyDownload(data, sha256: check.install.sha256!)`로 확인해 주세요.
  업데이트 제공 기한이 있는 구매자는 결과에 `entitled`가 들어 있습니다. 그때는 최상위 대신 `entitled?.release`를 따라 주세요.
  최상위 최신 버전은 그 구매자가 실행할 수 없는 버전일 수 있고, `entitled?.release`가 비어 있으면 그 대상에 제공 범위 안의 버전이 없습니다.
- **오류**: 실패하면 `BydevError`가 발생합니다. 분기는 `code`로 하고, 비교할 값은 생성된 상수 `Codes.*`에 있습니다. `message`는 화면에 보여 주는
  용도로만 사용해 주세요. `isTransient`가 참이면 다시 시도해 볼 만한 오류입니다.
- **모르는 값**: `EntitlementStatus` 같은 열거 값은 `String`입니다. 그래서 이 버전의 SDK가 모르는 새 값이 와도 그대로 담깁니다. `switch`에는
  `default`를 두어 주세요.

  모든 모델에는 `json`과 `toJSON()`이 있어서 기록하거나 진단할 때 쓸 수 있습니다.
- 판매자 서버용 도우미(웹훅 서명 검증, 토큰 검증)는 서버에서 도는 언어의 SDK에 들어 있습니다. TS, .NET, Kotlin/Java, Python, Go, Rust SDK가
  그렇습니다.
- 라이선스는 MIT 또는 Apache-2.0입니다.

## 출처 확인

이 꾸러미는 공개 저장소 `developedby-dev/sdk-swift`의 GitHub Actions가 판 태그에서 짓고 올립니다. 판 태그마다 올린 소스 묶음에는 GitHub 출처 증명이 있습니다. 받은 파일을 `gh attestation verify <파일> --repo developedby-dev/sdk-swift`로 확인할 수 있습니다.

## 개발

| 명령 | 하는 일 |
|---|---|
| `swift build` | 라이브러리와 적합성 하네스(`BydevConformanceHarness`)를 빌드합니다. |
| `swift test` | 단위 시험(swift-testing)을 돌립니다. 실제 전송 시험은 적합성 시험용 가짜 서버를 HTTP 모드로 node에서 띄워 확인하며, 쓸 node는 `BYDEV_NODE`로 바꿀 수 있습니다. 키체인은 가짜를 써서 사용자 키체인을 건드리지 않습니다. |
| `pnpm sdk:check swift` | `swift format lint --strict`, 빌드, 시험(경고도 오류로 봅니다), 적합성 시나리오 48개를 모두 돌립니다. |

`Sources/Bydev/Generated.swift`는 생성된 파일이며, `pnpm --filter @bydev/sdk-codegen generate`로 다시 만듭니다.
