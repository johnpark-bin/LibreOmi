# 07 — 이슈 백로그 (한국어)

`scripts/create_issues.py` 가 이 파일을 파싱해 GitHub 마일스톤과 이슈를 생성합니다.
형식 규칙: `## Mx — 제목` 은 마일스톤, `### LO-nn · 제목` 은 이슈, 이슈 첫 줄의
`라벨:` 은 쉼표로 구분된 라벨 목록입니다. 완료 기준과 참고 문서는 영어 문서
(`docs/06-roadmap.md`) 와 동일한 ID 로 대응됩니다.

## M0 — 저장소 부트스트랩
빌드는 아직 없지만 모든 규약이 갖춰진 깨끗한 포크를 만든다.

### LO-01 · 업스트림 소스 가져오기 및 저장소 정리
라벨: area:repo, size:S
**목적** `kbdevs/omibutfree` 의 `lib/`, `assets/`, `pubspec.yaml`, `analysis_options.yaml`, `ios/` 만 가져오고 불필요한 산출물은 제외한다.

**작업**
- 제외: `OmiLocal/`(실패한 Swift 재작성), `.ralph/`, `build_log.txt`, `fix_build.sh`, `ios/Pods 2/`, `ios/Flutter/Flutter 2.podspec`, `Flutter 3.podspec`, `flutter_export_environment 2.sh`, `.flutter-plugins-dependencies 2`
- `LICENSE` 에 업스트림(kbdevs) 저작권 표기와 LibreOmi 표기를 함께 기재
- 히스토리 보존 여부 결정: `git filter-repo` 로 경로 필터링하거나 새로 시작(README 에 출처 명시)

**완료 기준** `git log` 가 깨끗하고 `LICENSE` 에 두 저작권 줄이 있다.

**참고** `docs/01-upstream-analysis.md` §2

### LO-02 · 툴체인 고정 (mise, Flutter stable, JDK 17)
라벨: area:repo, size:S
**목적** 사람과 에이전트, CI 가 동일한 SDK 를 쓰게 한다.

**작업**
- `mise.toml`: `flutter = "3.47.2"`(움직이는 `stable` 별칭이 아니라 구체 버전), `java = "temurin-17"`,
  `[env]` 로 `ANDROID_HOME` 주입
- 새 클론은 `mise trust` 를 한 번 실행해야 `mise.toml` 이 읽힌다
- 머신당 1회: Android SDK(platform 36/35, build-tools 36.0.0/35.0.0, platform-tools,
  cmdline-tools 22.0) 설치와 라이선스 수락 — 절차는 `docs/04` §1
- `flutter config --jdk-dir` 로 Flutter 쪽 JDK 고정 (`JAVA_HOME` 만으로는 Android Studio 의
  번들 JBR 에 밀린다)
- `docs/`, `AGENTS.md`, `CLAUDE.md` 커밋
- Gradle 이 `org.gradle.java.home` 없이 `JAVA_HOME` 만으로 동작하는지는 `android/` 가 생기는
  LO-10 에서 확인한다 (이 항목에서는 검증 불가)

**완료 기준** `docs/04` §1 의 머신 1회 설정을 마친 뒤, 새 클론에서 `mise install` 후
`mise exec -- flutter doctor` 의 Flutter / Android toolchain / Android licenses 가 ✓
(Xcode 항목은 기준 아님).

**참고** `docs/04-android-platform-notes.md` §1

### LO-03 · 앱 이름/패키지 변경 (libreomi)
라벨: area:repo, size:S
**작업**
- `pubspec.yaml` name → `libreomi`, description 갱신
- Android applicationId `org.libreomi.app` (소유자가 확정 전까지 임시), 앱 라벨 "LibreOmi"
- 아이콘: `flutter_launcher_icons` 설정을 Android 포함으로 변경, adaptive icon 추가
- Dart import 경로(`package:omi_local/…`)를 전부 갱신

**완료 기준** `flutter analyze` 통과.

### LO-04 · CI: analyze / test / debug APK 빌드
라벨: area:ci, size:M
**작업**
- GitHub Actions 워크플로: `subosito/flutter-action`(mise 버전과 동일), JDK 17, `flutter analyze`, `flutter test`, `flutter build apk --debug`
- PR 과 `main` push 에서 실행, Gradle/pub 캐시

**완료 기준** `main` 에서 녹색.

### LO-05 · 이슈/PR 템플릿, 라벨, 마일스톤 생성
라벨: area:repo, size:S
**작업**
- `.github/ISSUE_TEMPLATE/*.md`, `.github/pull_request_template.md` (한국어)
- 라벨: `area:*`, `size:S/M/L`, `needs-device-test`
- `scripts/create_issues.py --repo <owner>/LibreOmi` 로 본 백로그 등록

**완료 기준** GitHub 에서 마일스톤 M0~M6 과 이슈가 보인다.

## M1 — Android 빌드 브링업 (첫 라이브 자막)
Omi → Android 폰 → Deepgram → 화면에 자막. 앱은 포그라운드 상태.

### LO-10 · Android 플랫폼 폴더 생성 및 SDK 레벨 설정
라벨: area:android, size:S
**작업**
- `flutter create --platforms=android --org org.libreomi --project-name libreomi .`
- `minSdk 26`, `targetSdk 35`, `compileSdk 36`, Kotlin DSL (`compileSdk` 는 Flutter 3.47.2 요구값,
  `targetSdk` 는 Play 정책값 — 템플릿 기본값 36 을 35 로 되돌려야 한다)
- debug 빌드 `ndk.abiFilters = ["arm64-v8a"]`
- `isMinifyEnabled = false` (v1)

**완료 기준** 실기기에서 `flutter run` 으로 업스트림 UI 가 뜬다.

**참고** `docs/04-android-platform-notes.md` §2, §7

### LO-11 · 권한 선언 및 런타임 권한 흐름
라벨: area:android, size:M, needs-device-test
**작업**
- `AndroidManifest.xml` 에 `docs/04 §3` 권한 매트릭스 반영 (`BLUETOOTH_SCAN` 에 `neverForLocation`)
- `platform/permissions.dart`: API 31+ 는 SCAN/CONNECT, ≤30 은 FINE_LOCATION, 33+ 는 POST_NOTIFICATIONS, 마이크는 폰 마이크 선택 시에만
- 앱 시작 시 알림 권한만 요청, 스캔 버튼에서 BLE 권한 요청

**완료 기준** Android 12+ 와 Android 10 기기 모두에서 스캔이 동작한다.

### LO-12 · BLE: MTU 512 요청, 연결 우선순위, 캐릭터리스틱 캐시
라벨: area:ble, size:M, needs-device-test
**목적** Android 기본 MTU(23) 로는 83바이트 오디오 패킷이 잘린다. 업스트림에는 이 처리가 없다.

**작업**
- 연결 직후 `device.requestMtu(512)`; 결과 MTU < 86 이면 세션 시작 거부 + 오류 표시
- 스트리밍 중 `requestConnectionPriority(high)`, 유휴 시 `balanced`
- `discoverServices()` 는 연결당 1회, UUID → characteristic 캐시 (배터리/게인/LED/햅틱/스토리지 모두 캐시 사용)
- 연결 해제 시 모든 구독 취소, 캐시 초기화 (버튼 구독 누수 수정)

**완료 기준** logcat 에서 협상된 MTU ≥ 86, 오디오 패킷 길이 83 이 연속으로 찍힌다.

**참고** `docs/05-omi-ble-protocol.md` "Connection sequence", `docs/01 §5.1, §5.7, §5.8`

### LO-13 · 알림: Android 아이콘/채널 정리, 누락 사운드 리소스 제거
라벨: area:android, size:S
**작업**
- `res/drawable/ic_notification.xml` 단색 아이콘 추가, `awesome_notifications` 초기화에 지정
- `soundSource: 'resource://raw/res_custom_notification'` 제거
- 채널: `session`(low), `ai_responses`(max), `task_reminders`(high), `device`(default)

**완료 기준** Android 13+ 에서 즉시 알림이 표시된다.

### LO-14 · Deepgram 라이브 경로 Android 검증 및 사용량 집계 수정
라벨: area:transcription, size:S, needs-device-test
**작업**
- Opus 패스스루(`encoding=opus`) 로 자막 확인
- 사용량 분 집계를 `is_final == true` 결과 또는 종료 시 `Metadata` 기준으로 변경 (중간 결과 중복 집계 제거)
- Deepgram 모델명을 설정값으로 (기본 `nova-2` 유지, 이후 변경 가능)

**완료 기준** 발화 후 2초 내 자막 표시.

### LO-15 · 폰 마이크 경로 Android 검증
라벨: area:audio, size:S, needs-device-test
**작업** `RECORD_AUDIO` 요청 후 `record` PCM16 16 kHz 스트림 → Deepgram `linear16`.

**완료 기준** 폰 마이크로 자막이 나온다.

### LO-16 · 대화 마무리 파이프라인 Android 검증 및 리마인더 알람 방식 변경
라벨: area:session, size:S, needs-device-test
**작업**
- 침묵 2분 → OpenAI 요약 → 메모리/태스크 저장 확인
- 태스크 리마인더는 `preciseAlarm: false`(inexact) 기본, 정확 알람은 옵트인
- 알림 ID 를 `String.hashCode` 대신 DB 정수 컬럼으로 (LO-35 에서 스키마, 여기서는 임시로 `created_at` 기반 정수)

**완료 기준** History 에 제목/요약이 있는 대화가 생긴다.

### LO-17 · 기기 설정 페이지 검증
라벨: area:ble, size:S, needs-device-test
**작업** 배터리, 펌웨어/모델/제조사, 마이크 게인, LED 밝기, 햅틱 3단계 읽기·쓰기 확인 (캐시 기반).

**완료 기준** 모든 항목이 성공한다.

## M2 — 백그라운드 안정성
화면 꺼짐/백그라운드에서 수 시간 동안 자막이 계속 쌓인다.

### LO-20 · BackgroundRunner 추상화 + flutter_foreground_task 구현
라벨: area:android, area:session, size:M, needs-device-test
**작업**
- `platform/background_runner.dart` 인터페이스, Android 구현은 `flutter_foreground_task`
- 매니페스트 service `foregroundServiceType="connectedDevice|microphone"`
- 세션이 listening 으로 진입하기 **전에** 서비스 시작, idle+미연결이면 중지
- 상시 알림에 연결 상태/현재 대화 길이 표시 (`session` 채널)
- Android 14+: 마이크 타입 서비스는 포그라운드 UI 액션에서만 시작

**완료 기준** 화면 끄고 1시간 후에도 세션이 살아 있고 자막이 누적된다.

**참고** `docs/03-architecture.md` §5, `docs/04 §4`

### LO-21 · 배터리 최적화 제외 요청 + 제조사별 안내 페이지
라벨: area:android, size:S
**작업** 첫 세션 시작 시 설명 화면 → `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 인텐트; 거절 시 `device_info_plus` 제조사 기준 dontkillmyapp 링크.

**완료 기준** 프롬프트가 1회만 뜨고 설정에서 다시 열 수 있다.

### LO-22 · 재연결 전략 (autoConnect, 백오프, GATT 133 재시도)
라벨: area:ble, size:M, needs-device-test
**작업**
- 저장된 기기는 `autoConnect: true` 로 상시 대기, 수동 스캔은 5s→60s 지수 백오프 (업스트림의 5초 고정 타이머 제거)
- GATT 133/257 은 1~2초 간격 3회 재시도
- 스캔은 30초에 5회 제한을 넘지 않게

**완료 기준** 범위 이탈 후 복귀 시 30초 내 재연결되고 오디오가 재개된다.

### LO-23 · 마무리 요청 재시도 큐 (Doze 중 네트워크)
라벨: area:session, size:M
**작업** 요약/추출 요청을 SQLite 큐에 넣고 네트워크 복구 시 재시도 (`connectivity_plus`). 대화는 요약 없이 먼저 저장하고 나중에 갱신.

**완료 기준** 비행기 모드에서 침묵 타임아웃 → 네트워크 복구 후 요약이 채워진다.

### LO-24 · 웨이크락 및 유휴 시 서비스 종료
라벨: area:android, size:S
**완료 기준** 미연결 상태에서는 상시 알림이 없다.

### LO-25 · API 키 보안 저장소 이전
라벨: area:data, size:S
**작업** `flutter_secure_storage`(EncryptedSharedPreferences) 로 Deepgram/OpenAI 키 이전, 첫 실행 시 1회 마이그레이션, Auto Backup 제외.

**완료 기준** 업그레이드 후 키가 유지되고 `shared_prefs` XML 에 평문이 없다.

## M3 — 코어 리팩터링과 테스트
`AppProvider` 를 `docs/03-architecture.md` 구조로 분해해 이후 작업을 테스트 가능하게 만든다.

### LO-30 · core 모델 + omi_gatt 파서 + 단위 테스트
라벨: area:core, size:M
**작업**
- `TranscriptSegment` 에 `startAt/endAt`(벽시계) 추가
- `device/omi_gatt.dart`: UUID 상수, 코덱 enum, 오디오 헤더 제거, 버튼 uint32 LE 파서, 스토리지 리스트/패킷 파서
- 각 파서에 대한 `test/` 작성

**완료 기준** 테스트 녹색.

### LO-31 · OmiDevice 인터페이스, BLE 구현, FakeOmiDevice 리플레이
라벨: area:ble, area:test, size:L
**작업**
- `OmiDevice` 추상화와 `OmiBleDevice`(flutter_blue_plus) 구현
- 디버그 토글 "BLE 세션 캡처" → `test/fixtures/*.bin` 기록
- `FakeOmiDevice` 가 픽스처를 리플레이해 바이트→SQLite 전체 파이프라인을 데스크톱 `flutter test` 에서 실행

**완료 기준** 픽스처 기반 통합 테스트가 데스크톱에서 통과.

### LO-32 · AudioSource / StreamingTranscriber / LlmClient 인터페이스 도입
라벨: area:core, size:M
**작업** 기존 서비스를 인터페이스 뒤로 이동 (동작 변경 없음). `OpenAIService` → 타입드 `ConversationInsights`.

**완료 기준** 기기에서 동작 동일.

### LO-33 · RecordingSession / ButtonHandler / SilenceDetector 상태기계 + 단일 ConversationFinalizer
라벨: area:session, size:L, needs-device-test
**작업**
- `docs/03 §4` 상태기계 구현, 단위 테스트
- 라이브 경로와 SD 카드 경로에 중복된 요약→메모리→태스크 코드를 `ConversationFinalizer` 하나로 통합
- hold-to-ask 답변을 알림뿐 아니라 채팅 페이지에도 기록

**완료 기준** 상태기계 테스트 통과 + 기기 스모크 체크리스트.

### LO-34 · UI 컨트롤러 분리 및 AppProvider 제거
라벨: area:ui, size:M
**작업** `DeviceController`, `SessionController`, `LibraryController`, `ChatController` 로 분리하고 페이지 재연결. `AppProvider` 삭제.

**완료 기준** 모든 페이지 동작, `AppProvider` 파일 없음.

### LO-35 · 리포지토리 분리 + 스키마 v5 마이그레이션
라벨: area:data, size:S
**작업** `lib/data/` 리포 분리(`DatabaseService` 는 파사드로 유지), `tasks.notification_id INTEGER`, `chat_messages` 영속화, v3→v4→v5 마이그레이션 테스트(`sqflite_common_ffi`).

**완료 기준** v3 DB 업그레이드 시 데이터 보존과 `notification_id` 백필.

## M4 — Android 온디바이스 음성인식

### LO-40 · 모델 스토어 (다운로드 진행률, 검증, 삭제, 설정 UI)
라벨: area:transcription, size:M
**작업** `model_store.dart`; 앱 support 디렉터리 하위 저장(백업 제외); 설정에서 용량 표시/삭제; 취소 가능한 다운로드.

**완료 기준** tiny 모델 다운로드 진행률 표시 후 삭제 가능.

### LO-41 · Sherpa 스트리밍 Zipformer 백그라운드 isolate + 타임스탬프
라벨: area:transcription, size:M, needs-device-test
**작업** 디코딩을 `Isolate.run`/long-lived isolate 로 이동; 엔드포인트마다 벽시계 시작/종료 기록.

**완료 기준** 인식 중 UI 60fps 유지, History 에 지속시간 표시.

### LO-42 · Whisper 배치 + Silero VAD
라벨: area:transcription, size:M, needs-device-test
**작업** 3초 타이머를 sherpa-onnx Silero VAD 발화 구간으로 교체; 타임스탬프.

**완료 기준** 2분 테스트에서 단어 중간 끊김 없음.

### LO-43 · 코덱 인식 라우팅
라벨: area:audio, size:S
**작업** 트랜스크라이버가 PCM 을 요구할 때만 Opus 디코드; Deepgram 경로는 패스스루 유지.

### LO-44 · 한국어 오프라인 모델 옵션
라벨: area:transcription, size:M
**작업** sherpa-onnx 다국어 zipformer 또는 whisper 다국어 모델 선택지 추가.

**완료 기준** 한국어 발화가 오프라인으로 인식된다.

## M5 — SD 카드 동기화 완성

### LO-50 · OmiStorage 전송 계층 (목록/읽기/중지/삭제)
라벨: area:ble, size:M, needs-device-test
**작업** 업스트림 전송 루프 이식, `0x03` 중지 명령 추가, 83/440바이트 패킷 모두 처리, 진행률/ETA.

**완료 기준** 5분 녹음이 진행률 표시와 함께 동기화된다.

### LO-51 · 파일 트랜스크라이버 (Deepgram pre-recorded, sherpa offline)
라벨: area:transcription, size:M
**목적** 업스트림의 `_transcribeWith*` 는 플레이스홀더 문자열을 반환하는 스텁이다.

**작업** `.bin` → PCM/WAV 디코드; Deepgram pre-recorded API 업로드; sherpa 오프라인 인식; 결과를 `ConversationFinalizer` 로 전달.

**완료 기준** 동기화된 파일이 요약이 있는 대화가 된다.

### LO-52 · SD 카드 페이지 마무리
라벨: area:ui, size:S
**완료 기준** 플레이스홀더 없이 업스트림 UX 와 동일하게 동작.

## M6 — 마무리와 릴리스

### LO-60 · 설정: OpenAI 호환 base URL, 모델 목록, 가격표 편집
라벨: area:intelligence, size:S
**완료 기준** Ollama/OpenRouter 엔드포인트로 요약이 동작.

### LO-61 · JSON 내보내기/가져오기
라벨: area:data, size:S
**완료 기준** 라운드트립 후 모든 행 보존.

### LO-62 · i18n 스캐폴딩 (영어/한국어)
라벨: area:ui, size:M
**완료 기준** 시스템 언어를 따른다.

### LO-63 · 릴리스 엔지니어링 (서명, split APK, App Bundle, CHANGELOG)
라벨: area:ci, size:M
**작업** 서명 키는 환경변수/시크릿; `--split-per-abi` APK 를 GitHub Release 에; Play 내부 테스트용 AAB.

**완료 기준** `v0.1.0` 태그로 다운로드 가능한 APK 생성.

### LO-64 · 권한/개인정보 안내 화면
라벨: area:ui, size:S

### LO-65 · iOS 빌드 재검증
라벨: area:ios, size:S
**완료 기준** `flutter build ios` 성공 (기능 추가 없음).
