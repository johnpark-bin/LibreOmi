# 09 — 실기기 검증 런북 (소유자용)

이 문서는 **한국어**다. `docs/` 는 원칙적으로 영어지만(`08-dev-workflow.md` §1),
이 런북의 독자는 폰과 Omi 기기를 손에 들고 한 줄씩 따라가는 프로젝트 소유자 한 명뿐이라
소유자 언어로 쓴다. §1 의 언어 정책 표에 이 예외를 적어 두었다.

M0~M6 의 병합된 PR **39건**(#40~#86 중 실존하는 전부) 본문에 흩어져 있던
"소유자 확인 필요" 절차를 중복을 걷어내고 **검증 동선 순서**로 재배열한 것이다.
어떤 PR 의 어떤 절이 어디로 갔는지는 [부록 A](#부록-a--pr-별-추출-대조표)에 전부 적혀 있다.
아직 결론이 나지 않아 이 주말에 **데이터를 모아 와야 하는** 항목은
[부록 B](#부록-b--알려진-미확정-사항--이번-검증에서-데이터를-모아야-하는-것)에 따로 모았다.

에이전트는 BLE·실기기·API 키에 접근할 수 없다. 아래 항목은 전부 **사람만 확인할 수 있는 것**이고,
그래서 여기 남아 있다.

## 이 문서를 쓰는 법

- §0 을 먼저 끝낸다. 준비물이 없으면 중간에 멈춘다.
- §1 → §10 순서대로 간다. 순서에는 이유가 있다: 앞 단계가 뒤 단계의 전제다.
  (설치가 되어야 권한이 뜨고, 연결이 되어야 자막이 나오고, 자막이 나와야 저장·요약이 돈다.)
- 각 항목은 **절차 / 기대값 / 캡처 / 실패 시** 네 줄로 되어 있다.
  - **캡처** 는 "무엇을 찍어 어디에 붙일지"다. 붙일 곳은 해당 PR 코멘트이며 PR 번호를 적어 두었다.
  - **실패 시** 는 어디를 먼저 의심하고 어느 이슈에 붙일지다.
- 한 번에 다 못 해도 된다. §1~§6 이 핵심(M1·M2 완료 기준)이고, §7~§10 은 독립적으로 나눠 해도 된다.

---

## §0 준비물

### 0.0 시작 전에 — §1 과 §8 은 서로 반대되는 상태를 요구한다

§1 은 앱을 **지운 상태**에서 시작하고 §1.2 는 **앱 데이터 삭제**까지 요구한다.
§8 은 **업그레이드 경로**를 보는 절이라 그 반대, 즉 **옛 빌드가 만든 데이터가 이미 기기에 있는 상태**를 요구한다.

해소 방법은 "§8 을 §1 앞뒤 어디에 두느냐" 가 아니다. **§8 의 각 항목이 자기 전제를 스스로 만든다**는 것이다.

#### §8 의 각 항목은 독립적이다

§8.1·§8.2·§8.4 는 서로 **다른 옛 빌드**를 요구하므로 한 번의 준비로 묶을 수 없다.
하나씩, 아래 4단계를 반복한다. **항목 사이에는 앱 데이터를 지워도 된다** — 다음 항목이 자기 전제를 다시 만들기 때문이다.

1. 그 항목이 요구하는 **옛 커밋을 체크아웃해 빌드·설치**한다.
2. 그 빌드에서 **필요한 데이터를 만든다**(항목마다 다르다 — 아래 표).
3. **이 브랜치 빌드를 덮어 설치**한다(`adb install -r` 또는 `flutter run`). **uninstall 하지 않는다.**
4. 항목의 기대값을 확인한다.

| 항목 | 필요한 옛 빌드 | 2단계에서 만들 것 |
|---|---|---|
| §8.1 v4 → v5 | **`cc1748d37^`** (#60 병합의 부모) — 확인: `dbVersion = 4` | 대화·메모리 + **마감이 있는 태스크**(알림이 예약되게) |
| §8.2 v5 → v6 | **`a3e692db5^`** (#82 병합의 부모) — 확인: `schemaVersion = 5` | 채팅 몇 줄(질문·답변 쌍) |
| §8.3 읽기 호환 | **`78c7145a4^`** (#85 병합의 부모) — `schemaVersion = 6` | 대화·메모리·태스크·채팅 각 1건 이상 |
| §8.4 키 보안 저장소 | **`17d55a3fa^`** (#55 병합의 부모) — `_dbVersion = 3`, **평문 키 시절** | Settings 에서 Deepgram·OpenAI 키 입력 |
| §8.5 내보내기/가져오기 | **없음** — 현재 빌드로 바로 된다 | (준비 불필요) |

옛 커밋 빌드는 이런 식이다(워크트리를 따로 쓰면 이 브랜치를 건드리지 않는다):

```bash
git worktree add /tmp/lo-old cc1748d37^     # §8.1 의 v4 시점. 항목마다 커밋만 바꾼다
cd /tmp/lo-old && mise exec -- flutter run -d <device-id>
```

> ⚠️ **`main` 빌드는 "옛 빌드" 가 아니다.** 이 브랜치는 문서만 바꾸므로 코드가 `main` 과 동일하고,
> 지금 `main` 의 스키마는 이미 **v6** (`lib/data/db.dart`) 이다. `main` 을 깔았다가 이 브랜치를 덮어 설치하면
> 아무 마이그레이션도 일어나지 않아 §8.1·§8.2·§8.4 가 성립하지 않는다.

> 💡 **기기에 예전 LibreOmi 빌드가 이미 깔려 있다면 그게 최고의 소스다.** 그 앱의 스키마 버전을
> `adb shell run-as org.libreomi.app sqlite3 databases/libreomi.db "PRAGMA user_version;"` 로 먼저 읽고,
> 나온 버전에 해당하는 항목부터 하면 옛 커밋을 빌드할 필요가 없다.
> 옛 커밋 빌드까지 해서 지난 마이그레이션을 되짚을 가치가 있는지는 소유자 판단이다 —
> **§8.5 만 하고 §8.1~§8.4 를 건너뛰어도 §1~§7·§9·§10 에는 아무 영향이 없다.**

#### 그래서 §1 과 §8 의 순서는

**서로 간섭하지 않는다.** §1 은 지운 상태에서 시작하고, §8 의 각 항목은 자기가 옛 빌드를 다시 깔며 시작한다.
문서 순서대로 §1 → … → §8 로 가면 된다. §8 안에서만 위 4단계를 항목마다 반복하면 된다.

기기가 2대라면(§0.1 이 어차피 Android 14+ 1대와 Android 10 1대를 요구한다) 어느 쪽에서 §8 을 하든 상관없지만,
**§1.3 의 Android 10 항목과 §5.5 의 Android 14+ 항목은 각각 그 기기에서만 되므로**
§8 때문에 두 기기 중 하나를 오래 점유하지 않는 편이 좋다. §8 은 마지막에 몰아서 하는 것이 무난하다.

### 0.1 기기

| 필요한 것 | 왜 |
|---|---|
| **Android 14 이상** 실기기 1대 (arm64) | 정확 알람 옵트인 흐름(§5.5)은 14+ 에서만 재현된다. 13 이하는 권한이 자동 부여된다 (#81) |
| **Android 10 (API 29)** 실기기 1대 | BLE 스캔에 위치 권한이 필요한 마지막 세대. §1.3 은 이 기기에서만 확인된다 (#48) |
| Omi Friend / DevKit 1대 + 충전 | 펌웨어 버전을 적어 둘 것 |
| (선택) iOS 기기 + Apple 개발자 팀 | §10. 서명 없이는 아무것도 증명되지 않는다 (#86) |

> ⚠️ 디버그 APK 는 **arm64-v8a 전용**이다(#49). arm64 가 아닌 기기는 설치는 되지만
> 첫 네이티브 로드에서 `UnsatisfiedLinkError` 로 죽는다.

기록해 둘 것 — 각 PR 체크리스트 머리에 그대로 들어간다:

```
기기: <제조사/모델/Android 버전>   펌웨어: <Omi firmware>   빌드: <commit>
```

### 0.2 계정·키

앱 안에서만 입력하며 저장소에 커밋하지 않는다(`08-dev-workflow.md` §6).

| 키 | 어디에 쓰는가 | 없으면 못 하는 항목 |
|---|---|---|
| **Deepgram API Key** | 클라우드 스트리밍 전사, SD 카드 pre-recorded 전사 | §3.1, §7.5(A), §8 사용량 확인 |
| **OpenAI (또는 OpenAI 호환) API Key** | 요약·제목·메모리·태스크 추출, 싱글탭 질의응답 | §4.2, §5.1~§5.4, §9.1 |
| **Ollama 서버** (선택, PC) | OpenAI 호환 엔드포인트 검증 | §9.1 |
| **OpenRouter Key** (선택) | 같은 위 | §9.1 |

Ollama 를 쓸 경우 PC 에서:

```bash
OLLAMA_HOST=0.0.0.0 ollama serve
ollama pull llama3.2
```

폰과 같은 네트워크여야 하고, 앱에는 `localhost` 가 아니라 **폰에서 닿는 주소**
(예: `http://192.168.0.10:11434/v1`)를 넣는다 (#78).

### 0.3 빌드

디버그 경로 — §1~§9 는 전부 이걸로 된다:

```bash
mise trust
mise install
mise exec -- flutter pub get
mise exec -- flutter run -d <android-device-id>
```

릴리스 서명 경로 — **§9.3(릴리스 빌드 스모크)만 이걸 요구한다.** 나머지는 건너뛰어도 된다 (#77):

1. 키스토어를 만들고 **이 저장소 밖·이 노트북 밖에 백업한다.** 잃어버리면 설치된 앱을 영원히 업데이트할 수 없다.
   ```bash
   keytool -genkey -v -keystore ~/libreomi-release.jks \
     -keyalg RSA -keysize 4096 -validity 10000 -alias libreomi
   ```
2. `android/key.properties` 에 `storeFile` / `storePassword` / `keyAlias` / `keyPassword` 를 적는다(gitignore 됨).
3. `scripts/release.sh --dry-run` — 자세한 순서는 `08-dev-workflow.md` §7.2·§7.3.

> GitHub Actions 는 계정 수준에서 꺼져 있다(#43). CI 가 빨간 것은 브랜치 문제가 아니므로
> 이 검증에서 CI 결과는 보지 않는다.

### 0.4 미리 받아 둘 모델

전사 항목(§3)은 모델 다운로드가 전제다. §3 시작 전에 **Wi-Fi 에서** 받아 두면 시간이 절약된다.
Settings → Transcription Engine → Manage models:

| 모델 | 다운로드 / 설치 후 | 쓰는 곳 |
|---|---|---|
| Streaming Zipformer (English, 20M) | — | §3.2 (#68) |
| Streaming Zipformer (Korean) | ~399 MB / ~300 MB | §3.4 (#70) |
| Whisper tiny | 111 MB / 146 MB | §3.3, §7.5(B) (#67, #69) |
| Whisper base | — / 279 MB | §3.5 마이그레이션 확인 (#79) |
| SenseVoice (multilingual) | 155 MB / 228 MB | §3.5 (#79) |
| Silero VAD | ~0.6 MB | §3.3·§3.5 의 **전제**. 없으면 세션이 오류로 뜬다 (#69, #79) |

### 0.5 상비 명령

logcat 은 항목 시작 전에 `adb logcat -c` 로 비우고 켜 두는 편이 캡처하기 쉽다.
SD 카드처럼 긴 항목은 파일로 받는다: `adb logcat ... > lo50.log`

```bash
# 전체 (기본)
adb logcat -s flutter:V FlutterBluePlus:V BluetoothGatt:V

# 항목별
adb logcat -s flutter:V AwesomeNotifications:V                       # §1 알림 채널
adb logcat -s flutter:V FlutterBluePlus:V BluetoothGatt:V | grep -E "LibreOmi/BLE|MTU"   # §2
adb logcat -s flutter:V | grep -i "LOCAL Sherpa\|LOCAL Whisper\|offline transcription\|model file missing"  # §3
adb logcat -s flutter:V | grep -i "finaliz"                          # §5 요약 재시도
adb logcat -s flutter:V | grep -i "Scheduled notification\|Cancelled notification"       # §5 리마인더
adb logcat -s flutter:V ForegroundService:V                          # §6
adb logcat -s flutter:V | grep -i "Processing local audio\|Whisper worker\|Deepgram"     # §7
adb logcat -s flutter:V | grep -i "sqlite\|database\|migrat"          # §8
adb logcat -s flutter:V | grep -i "json mode"                        # §9 LLM 폴백
```

상태 조회:

```bash
adb shell dumpsys package org.libreomi.app | grep -A40 "runtime permissions"
adb shell dumpsys notification --noredact | grep -A3 'libreomi'
adb shell dumpsys activity services | grep -i libreomi
adb shell dumpsys deviceidle whitelist | grep libreomi
adb shell dumpsys alarm | grep -A2 org.libreomi.app
adb shell run-as org.libreomi.app ls shared_prefs/
adb shell run-as org.libreomi.app sqlite3 databases/libreomi.db "PRAGMA table_info(tasks);"
adb shell ls /data/user/0/org.libreomi.app/files/models
```

### 0.6 캡처 원칙

- **로그는 구간으로.** 관련 있는 앞뒤 20~30줄. 전체 덤프는 붙이지 않는다.
- **스크린샷은 상태가 보이게.** 오류 문구를 찍을 때는 목록/파일이 남아 있는 것까지 한 화면에.
- **붙일 곳은 각 항목의 "캡처" 줄이 지정한 PR 코멘트.** 실패했을 때만 새 이슈를 연다.
- **키는 절대 찍지 않는다.** 설정 화면을 찍을 때 API Key 입력란이 들어가지 않게 한다.

---

## §1 설치 · 권한 · 첫 실행

> ⚠️ **§1 은 반드시 앱을 지운(uninstall) 상태에서 시작한다.**
> `awesome_notifications` 는 사라진 채널을 지우지 않아서, 예전 빌드를 돌린 적이 있는 기기에는
> 옛 채널(`omi_ai_responses`, `omi_task_reminders`)이 설정 화면에 남아 새 채널과 나란히 보인다 (#44).
> 반대로 §8 의 업그레이드 확인은 **지우면 안 된다.** 두 요구는 충돌하지 않는다 —
> §8 의 각 항목이 시작할 때 자기가 옛 빌드를 다시 설치하기 때문이다.
> 왜 그런지는 [§0.0](#00-시작-전에--1-과-8-은-서로-반대되는-상태를-요구한다) 에 있다.

### 1.1 설치와 기동 (#49 / 이슈 #6)

- **절차**: `mise exec -- flutter run -d <android-device-id>`
- **기대값**: 설치·기동 성공, 업스트림 첫 화면이 뜬다. 이전보다 설치가 눈에 띄게 빠르다(APK 가 절반 이하).
- **캡처**: 실패했을 때만 — 설치 로그.
- **실패 시**: `UnsatisfiedLinkError` 면 arm64 기기가 아니다. PR #49 에 기기 ABI 와 함께 코멘트.

### 1.2 첫 실행 = 개인정보 안내 화면 (#83 / 이슈 #38)

- **절차**
  1. (이미 설치돼 있었다면) 설정 → 앱 → LibreOmi → 저장공간 → **데이터 삭제** 후 앱 실행.
  2. 각 권한 행의 상태를 본다.
  3. **Continue** 를 누른다.
  4. 앱을 완전히 종료하고 다시 실행한다.
  5. Live 탭 앱바의 **방패 아이콘** → 화면을 다시 연다. 설정 탭 → Privacy → Permissions & privacy 로도 열어 본다.
  6. Omi 연결 상태·녹음 중 상태에서도 앱바 아이콘이 그대로 보이는지 본다.
- **기대값**
  - 1: 홈이 아니라 **Permissions & privacy** 화면이 뜨고 **뒤로가기 화살표가 없다.** 이 시점에 알림 권한 다이얼로그는 **아직 뜨지 않는다.**
  - 2: 대부분 `Not granted`, 배터리 행은 `Not exempt`.
  - 3: 홈으로 전환되고 **그 직후에** 알림 권한 다이얼로그가 뜬다(Android 13+).
  - 4: 안내 화면이 **다시 뜨지 않는다.**
  - 5: 화면이 열리고 이번에는 **뒤로가기 화살표가 있다.** 권한을 허용하고 다시 열면 행이 `Granted` 로 바뀐다.
  - 7(추가): 권한을 "다시 묻지 않음" 으로 거부하면 행이 `Denied — open settings` 가 되고 **Open settings** 가 시스템 설정을 연다.
- **캡처**: 첫 실행 안내 화면 1장 + 권한 허용 후 같은 화면 1장 → PR #83.
- **실패 시**: 이 화면은 Play 사전 신고의 근거다(`08-dev-workflow.md` §8). 문구가 매니페스트와 어긋나면 PR #83 에 코멘트.

### 1.3 런타임 권한 흐름 (#48 / 이슈 #7)

**Android 12+ (API 31+)**

- **절차**
  1. 앱 최초 실행.
  2. Device 탭 → **Scan**.
  3. 허용한다.
  4. 거부한다 → 다시 Scan.
  5. 두 번 거부해 영구 거부 상태로 만든 뒤 Scan.
  6. 시스템 설정에서 허용하고 돌아와 Scan.
  7. 폰 마이크 시작 버튼.
- **기대값**
  - 1: **알림 권한 다이얼로그만** 뜬다. BLE·마이크 다이얼로그는 이 시점에 뜨면 안 된다.
    (Android 12 = API 31/32 는 `POST_NOTIFICATIONS` 자체가 없어 아무것도 안 뜨는 게 정상)
  - 2: "기기 주변" 다이얼로그(BLUETOOTH_SCAN/CONNECT). **위치 권한 다이얼로그는 뜨지 않아야 한다** — `neverForLocation` 확인 지점.
  - 3: 스캔 목록에 Omi 가 뜬다.
  - 4: "Bluetooth permission is needed…" 스낵바. 다시 Scan 하면 다이얼로그 재시도.
  - 5: 스낵바에 **Settings** 버튼이 뜨고, 누르면 앱 설정 화면으로 간다.
  - 6: 다이얼로그 없이 바로 스캔.
  - 7: 마이크 권한 다이얼로그. 거부 시 스낵바, 영구 거부 시 Settings 버튼.

**Android 10 (API 29)** — 이 기기가 있어야만 확인된다

- **절차**: Scan → 허용 → 스캔. 그 다음 **시스템 위치 토글을 끈 상태**로 한 번 더 Scan.
- **기대값**: BLE 다이얼로그가 아니라 **위치 권한 다이얼로그**가 뜬다. 허용하면 Omi 가 보인다.
  위치 토글이 꺼져 있으면 권한이 허용돼도 **스캔 결과가 조용히 빈다** — 이 상태를 한 번 봐 두면
  후속 이슈(스캔 실패 안내)의 근거가 된다.
- **캡처**: `adb shell dumpsys package org.libreomi.app | grep -A40 "runtime permissions"` 출력 + 위치 토글 OFF 일 때의 빈 스캔 화면 1장 → PR #48.
- **실패 시**: 다이얼로그 순서가 다르면 PR #48. 매니페스트가 진실이고 문서가 사본이다(`04-android-platform-notes.md` §3).

### 1.4 알림 채널 (#44 / 이슈 #9)

- **절차**
  1. 알림 권한을 허용한다.
  2. 설정 → 앱 → LibreOmi → 알림.
  3. 기기 연결/해제 등으로 즉시 알림 1건을 발생시킨다.
  4. 상태바 아이콘을 본다 — 알림 그림자를 내려 확대해서 본다.
  5. 채널별 중요도를 체감한다.
- **기대값**
  - 2: 그룹 **LibreOmi** 아래 채널 4개(Session / AI Responses / Task Reminders / Device)가 보이고, 옛 `omi_*` 채널은 **없다**.
  - 3: 알림이 **즉시** 표시된다.
  - 4: 흰 사각형이 아니라 **단색 마이크 글리프**.
  - 5: AI 응답은 헤드업으로 튀고, Device 알림은 조용히 쌓인다.
- **캡처**: 알림 설정 화면(채널 4개가 보이게) 1장 + 상태바 아이콘 확대 1장 → PR #44.
- **실패 시**: 옛 채널이 보이면 uninstall 을 안 한 것이다. 지우고 다시. 그래도 남으면 PR #44.

---

## §2 BLE 연결

### 2.1 MTU · 연결 우선순위 · 패킷 길이 (#46 / 이슈 #8)

- **절차**
  ```bash
  adb logcat -c
  adb logcat -s flutter:V FlutterBluePlus:V BluetoothGatt:V | grep -E "LibreOmi/BLE|MTU"
  ```
  스캔 → 연결 → 세션 시작 → (자막 확인 후) 세션 정지.
- **기대값** — 연결 → 세션 시작 순서로 아래가 찍힌다.
  ```
  [LibreOmi/BLE] negotiated MTU=512 (minimum 86)      ← 512 가 아니어도 86 이상이면 통과
  [LibreOmi/BLE] connection priority set to ConnectionPriority.high
  [LibreOmi/BLE] audio packet length=83               ← 첫 오디오 패킷
  [LibreOmi/BLE] audio packets=1000 length=83         ← 이후 1000패킷마다
  ```
  - 스캔에서 Omi 표시, **연결 10초 이내**.
  - 세션 정지 후 `connection priority set to ConnectionPriority.balanced`.
  - MTU 가 86 미만인 기기에서는 연결이 거부되고
    `[LibreOmi/BLE] MTU too small: negotiated=<n>, required minimum=86` 이 찍혀야 한다(정상 동작).
- **캡처**: `negotiated MTU` 부터 첫 `audio packet length` 까지의 로그 구간 → PR #46.
  **협상값이 512 가 아니면 그 값을 반드시 적어 달라** — [부록 B-2](#b-2-mtu-최소값-86-의-근거-46) 의 데이터다.
- **실패 시**: `audio packet length=` 가 83 이 아닌 값으로 여러 번 찍히면 협상 MTU 나 코덱을 의심한다
  (길이 변화 로그는 스트림당 5회까지만 찍힌다). 프로토콜 상수는 `05-omi-ble-protocol.md` 가 정본이고,
  실제와 다르면 그 문서를 고쳐야 한다. PR #46 에 로그와 함께.

### 2.2 파서 회귀 — "변경 전과 동일" (#58 / 이슈 #20, #61 / 이슈 #21)

리팩터링 PR 들의 판정 기준은 전부 "이전과 같아야 한다"다. §2~§5 를 도는 김에 함께 본다.

- **절차/기대값**
  - `adb logcat -s flutter:V | grep "negotiated MTU"` → MTU=512, 경고 없음 (#58)
  - 더블탭·싱글탭 해석이 변경 전과 동일 — 버튼 파서는 §4 에서 본다 (#58)
  - 햅틱 길이까지: **더블탭 500ms, 싱글탭 시작 50ms, 종료 20ms** (#61)
  - 기기 설정 화면의 **마이크 게인 / LED 디밍 / 배터리·펌웨어 읽기·쓰기** (#46 캐시 경로 회귀, #61, #63)
  - 연결 해제 후 재연결 시 **버튼 이벤트가 1회만** 발생 — 구독 누수 수정 확인 (#46)
- **캡처**: 기기 설정 화면(게인·LED·배터리 값이 보이게) 1장 → PR #61.
- **실패 시**: 버튼 이벤트가 두 번 오면 #46 의 구독 누수 수정이 깨진 것 → PR #46.

### 2.3 BLE 세션 캡처 픽스처 만들기 (#61 / 이슈 #21) — **요청 사항**

에이전트가 `FakeOmiDevice` 리플레이 테스트를 실제 기기 트래픽으로 돌리려면 이 파일이 필요하다.
주말에 한 번만 해 주면 이후 회귀는 CI 에서 잡힌다.

- **절차**
  1. 설정 → Developer → **"Capture BLE session"** 을 켠다.
  2. 기기를 연결하고 **20초 이상** 말한 뒤 싱글탭·더블탭을 한 번씩 누른다.
     ⚠️ 이 파일에는 **실제 오디오 트래픽이 그대로 들어간다**. 공개 저장소의 PR 코멘트에 붙일 것이므로
     날씨 이야기처럼 **아무 의미 없는 문장만** 말할 것.
  3. 연결을 끊는다(캡처는 연결 해제 시 flush 된다).
  4. 파일을 꺼낸다.
     ```bash
     adb exec-out run-as org.libreomi.app ls files/../
     adb exec-out run-as org.libreomi.app cat <path>/ble_session_<timestamp>.jsonl > ble_session.jsonl
     ```
- **기대값**: `ble_session_<timestamp>.jsonl` 이 생기고 비어 있지 않다. 형식은 `test/fixtures/README.md` 참고.
- **캡처**: 파일 자체를 PR #61 코멘트에 첨부. (`test/fixtures/` 에 넣는 것은 그 다음 작업이다.)
- **실패 시**: 캡처 토글이 안 보이면 PR #61 에 코멘트.

### 2.4 재연결 (#56 / 이슈 #16)

이 항목은 §6 백그라운드와 이어진다. 시간이 없으면 §6 에서 한꺼번에 해도 된다.

- **절차/기대값**
  ```
  [ ] 연결된 상태에서 세션 시작 → 기기를 들고 범위 밖으로 이탈
  [ ] 알림 앞부분이 "Omi disconnected" 로 바뀌고 포그라운드 서비스가 유지된다(5분 이내)
  [ ] 5분 안에 범위 복귀 → 30초 내 자동 재연결, 자막(오디오) 재개
  [ ] 5분을 넘겨 이탈 → 알림/서비스가 내려간다. 복귀 후 앱을 열면 다시 붙는다
  [ ] 설정 화면 Disconnect → 다시 붙지 않는다(알림도 사라진다)
  [ ] Connect 버튼 → 다시 붙는다
  [ ] 수동 연결 중 GATT 133 이 뜨면 재시도 로그가 보이고 결국 붙는다
  [ ] 연결된 채 리스닝만 멈춘 상태에서 Audio test → 범위 이탈 → 복귀 시 재연결된다
  [ ] 저장 기기가 올라오는 중에 다른 기기로 Connect → 어느 쪽도 상태가 꼬이지 않는다
  ```
  기대 로그 (`adb logcat -s flutter:V FlutterBluePlus:V`):
  ```
  [LibreOmi/BLE] arming autoConnect for saved device: <id>
  [LibreOmi/BLE] auto-reconnect: next attempt in 5xxx ms (attempt 1)   # 이후 10/20/40/60s, ±10% 지터
  [LibreOmi/BLE] auto-connected to Omi device
  [LibreOmi/BLE] negotiated MTU=<86 이상>
  ```
- **소유자가 알고 있어야 할 한계 두 가지** (#56 이 명시)
  1. 무장 이후의 재연결 지연은 이 코드가 아니라 **안드로이드의 autoConnect 스케줄링**이 정한다.
     Doze·화면 꺼짐 상태에서는 30초를 넘길 수 있다. **"30초 내" 는 실기기 측정치이지 코드가 보장하는 값이 아니다.**
  2. 유예창(5분)을 넘기면 포그라운드 서비스가 내려가고, 그 뒤 OS 가 프로세스를 회수하면
     앱을 다시 열기 전까지 아무것도 재무장하지 않는다. **점심시간 같은 긴 이탈은 이 범위에서 복구되지 않는다**
     (부팅 리시버·Companion Device Manager 는 `06-roadmap.md` Later).
- **캡처**: 이탈 → 복귀 구간의 백오프 로그 30줄 + **복귀부터 재연결까지 실제 걸린 초** → PR #56.
- **실패 시**: 재연결이 안 되면 PR #56. 재연결 경로에 `startScan` 이 보이면 회귀다.

---

## §3 라이브 자막

각 엔진을 바꿔 가며 본다. 공통 기대값은 **자막이 2초 이내에 뜬다**(LO-14 완료 기준)이다.

### 3.1 Deepgram (클라우드) (#45 / 이슈 #10)

- **절차**
  1. 설정 → Deepgram API Key 입력, 모델 `Nova-2` 확인 → 앱 재시작(또는 세션 재연결).
  2. Omi 연결 후 발화.
  3. 통계 화면의 Deepgram 분(minutes)을 본다.
  4. 모델을 `Nova-3` 로 바꾸고 재연결.
  5. 세션을 종료한다.
- **기대값**
  - 2: **2초 내 자막 표시.**
  - 3: 실제 발화 시간과 근사.
  - 4: `adb logcat -s flutter:V` 에 `Connected to Deepgram (model: nova-3, ...)`.
  - 5: `Deepgram Metadata received (total duration: ...)` 로그 1회. 이 값과 통계 화면 증가분이 근사해야 한다
    (집계는 final 결과에서만 나오므로 두 값이 독립적으로 계산된 교차 검증이 된다).
- **캡처**: 통계 화면 1장 + `Deepgram Metadata received` 로그 줄 → PR #45.
- **실패 시** — [부록 B-4](#b-4-deepgram-interim_results-inert-가드-45) 를 먼저 읽을 것.
  **실제 과다 집계가 보인다면 원인은 `is_final` 이 아니다.** `DeepgramService` 인스턴스 중복 생성이나
  재연결 시 재집계를 먼저 본다. PR #45 에 숫자 두 개(로그값 / 통계 증가분)를 같이 적어 달라.
- **폰 마이크 경로도 한 번** — Deepgram + 폰 마이크로 자막이 같게 누적되는지 (#59).

### 3.2 Sherpa 스트리밍 Zipformer, 워커 isolate (#68 / 이슈 #27)

- **절차** — 먼저 Manage models 에서 **Streaming Zipformer (English, 20M)** 설치.
  1. 설정 → 전사 모드 = sherpa(로컬) → 녹음 시작.
  2. 자막이 나오는 동안 화면을 스크롤한다.
     ```bash
     adb shell dumpsys gfxinfo org.libreomi.app framestats
     ```
     또는 개발자 옵션 "GPU 렌더링 프로파일".
  3. 더블탭으로 저장.
  4. 모델을 지운 상태로 sherpa 모드를 켜 본다.
- **기대값**
  - 1: 모델 로딩 스피너 → 자막. Opus 디코드 경로 정상 (#59).
  - 2: 스크롤이 부드럽다(60fps). janky frames 비율이 Deepgram 모드와 비슷한 수준.
    (이전에는 디코드가 UI 를 막았다.)
  - 3: History 의 대화 항목에 **지속시간이 표시된다** (startAt/endAt 이 채워졌을 때만 나온다).
  - 4: `The streaming model must be present under …` 오류가 **자막 대신 오류로** 보인다.
  - `adb logcat -s flutter:V` 에 sherpa 관련 오류가 없다.
- **캡처**: `gfxinfo framestats` 의 janky frames 줄(Deepgram 모드 / sherpa 모드 각 1회) → PR #68.
- **실패 시**: 자막 중 UI 가 멈추면 isolate 이관이 깨진 것 → PR #68.

### 3.3 Whisper 배치 + Silero VAD (#69 / 이슈 #28)

- **절차**
  1. Settings → 전사 모드 = **Whisper (local)**, 모델 크기 `tiny`.
  2. Models 화면에서 **Whisper tiny** 와 **Silero VAD** 를 모두 설치.
     그 전에 **VAD 를 설치하지 않고 세션을 한 번 시작해 본다**(회귀 확인용).
  3. Omi 연결 후 **2분간 자연스럽게 발화** — 문장 사이에 1초 이상 쉼을 둔다.
  4. 더블탭으로 저장 → History 를 연다.
- **기대값**
  - 2: VAD 없이 시작하면 **Models 화면을 가리키는 오류 문구**가 뜬다.
  - 3: 자막이 **문장 단위**로 올라오고 **단어 중간에서 잘린 조각이 없다.**
    3초마다 균일하게 끊기면 **회귀다.** 발화 중 UI 가 버벅이지 않는다.
  - 4: 각 세그먼트의 지속시간/타임스탬프가 표시되고 **실제 발화 길이와 맞는다.**
  - `adb logcat -s flutter:V` 에 sherpa/VAD 예외 없음.
- **캡처**: 2분 발화 후의 자막 화면 1장(문장 단위인 것이 보이게) + History 세그먼트 타임스탬프 1장 → PR #69.
- **실패 시**: 3초 균일 절단이 보이면 VAD 분할이 안 먹은 것 → PR #69.

### 3.4 한국어 오프라인 (#70 / 이슈 #30)

- **절차/기대값**
  ```
  [ ] Settings → Transcription Engine → Local (Sherpa-ONNX) 선택
      → Language 행에 English / 한국어 가 뜨는가
  [ ] 한국어 선택 → Manage models 에 "Streaming Zipformer (Korean)" 가 ~399 MB 로 보이고
      다운로드가 끝나는가 (설치 후 표기 ~300 MB)
  [ ] 한국어 발화 → 라이브 자막이 한글로 뜨는가 (Sherpa ko 모델 경로)
  [ ] 모델 미설치 상태에서 한국어로 세션 시작 → Models 화면을 가리키는 오류 안내가 뜨는가
  [ ] Local (Whisper) + 한국어 + Whisper tiny → 한국어 발화가 한글로 전사되는가
      (영어 알파벳 음차가 아니라)
  [ ] 언어를 English 로 되돌리면 영어 전사가 예전과 동일하게 동작하는가 (회귀 확인)
  ```
  `adb logcat -s flutter:V | grep -i "LOCAL Sherpa\|LOCAL Whisper"` — 시작 로그에 선택한 언어가 찍힌다.
- **캡처**: 한국어 자막 화면 1장 + 시작 로그 줄 → PR #70.
- **실패 시**: 음차로 나오면 모델 선택이 안 먹은 것 → PR #70.

### 3.5 SenseVoice 다국어 (#79 / 이슈 #71)

- **절차/기대값**
  1. **설치·선택** — Settings → Transcription Engine → `Local (offline model)` →
     Model 드롭다운에 `Whisper tiny (146 MB)` / `Whisper base (279 MB)` /
     `SenseVoice (multilingual) (228 MB)` 세 항목이 보이는지. SenseVoice 선택.
  2. **다운로드** — Manage models 에서 `Download 155 MB · 228 MB on disk` 로 보이고,
     받은 뒤 `228 MB installed` 로 바뀌는지. (Silero VAD 도 설치되어 있어야 한다.)
  3. **미설치 방어** — SenseVoice 를 지운 상태로 세션 시작 →
     `SenseVoice (multilingual) model file missing: … Install the model from the Models screen …`
     취지의 오류가 뜨는지. **조용히 무자막이 되면 안 된다.**
  4. **한국어/영어 혼합** — 한 세션 안에서 한국어 문장과 영어 문장을 번갈아 말한다.
     기대: 둘 다 각각의 언어로 자막에 뜬다.
     ⚠️ Language 를 `English` 로 두어도 SenseVoice 는 그 언어로 핀되므로,
     **혼합 확인은 Language 를 실제 발화 언어에 맞춰 두고 각각 한 번씩** 하는 편이 낫다.
  5. **기존 사용자 마이그레이션** — 업데이트 **전**에 Whisper base 를 쓰던 기기에서,
     업데이트 후 Model 드롭다운이 `Whisper base` 로 남아 있는지.
     초기화되어 tiny 로 돌아가면 폴백이 깨진 것이다.
  6. **파일 전사** — SenseVoice 를 고른 상태에서 SD 카드 가져오기/파일 전사를 한 번 돌려 자막이 나오는지(§7.5 와 겹친다).
  ```bash
  adb logcat -s flutter:V | grep -i "offline transcription\|model file missing"
  ```
- **캡처**: 한국어·영어 각각의 자막 화면 1장씩 + 미설치 오류 문구 1장 → PR #79.
- **실패 시**: 5번(마이그레이션)이 깨지면 설정 폴백 문제 → PR #79.

### 3.6 모델 스토어 자체 (#67 / 이슈 #26)

§3.1~§3.5 를 하다 보면 대부분 지나가지만, 아래 두 개는 일부러 해야 한다.

- **절차/기대값**
  ```
  [ ] 설정 → Transcription Engine → Manage models 진입
  [ ] Whisper tiny 의 "Download 111 MB · 146 MB on disk" 확인 → Download
  [ ] 진행률 바와 "NN / 111 MB (NN%)" 가 올라가고, 이 사이 앱이 멈추지 않는다 (추출은 아이솔레이트)
  [ ] 중간에 Cancel → 행이 다시 Download 로 돌아오고 용량이 늘지 않는다     ← 일부러 할 것
  [ ] 다시 Download 완료 → "146 MB installed" 와 삭제 아이콘
  [ ] 모델 미설치 상태로 로컬 모드 세션 시작
      → "… is not downloaded yet. Open Settings → Models …" 오류가 보인다
  [ ] Manage models 에서 삭제 → 용량 회수, 행이 Download 로 복귀      ← 일부러 할 것
  [ ] (선택) adb shell ls /data/user/0/org.libreomi.app/files/models 로 경로 확인
  ```
- **캡처**: 다운로드 진행률 중간 1장 + 취소 직후 목록 1장 → PR #67.
- **실패 시**: 취소 후 용량이 남아 있으면 정리 경로 문제 → PR #67.

---

## §4 버튼 (싱글탭 질문 · 더블탭 저장)

### 4.1 기본 동작 (#46, #59 / 이슈 #22, #61, #63 / 이슈 #24)

- **절차/기대값**
  - **더블탭** → 대화 저장 알림, History 에 표시. 햅틱 500ms.
  - **싱글탭** → 질문 시작(햅틱 50ms) → 말한다 → **싱글탭** → 종료(햅틱 20ms) → 알림으로 답변.
    채팅 페이지에 질문·답변 쌍이 남는다.
  - 세션 정지 후 재시작이 정상(트랜스크라이버는 세션마다 새로 만든다).
- **캡처**: 답변 알림 1장 + 채팅 페이지의 질문·답변 쌍 1장 → PR #63.
- **실패 시**: 답변이 안 오면 OpenAI 키·네트워크를 먼저 본다 → PR #59.

### 4.2 세션 상태기계 — 리팩터링이 바꾼 동작 (#62 / 이슈 #23)

#62 는 "동작 불변" PR 이지만 **의도적으로 6가지를 고쳤다.** 소유자가 알고 봐야 할 것들이다.

- **절차/기대값**
  1. **시작 실패 시 오디오 트랜스포트가 닫힌다.** 예전에는 `startAudioStream()` 이후 실패하면
     기기 notification 이 켜진 채 남았다. 세션 시작이 실패한 뒤 기기가 계속 스트리밍하고 있지 않은지 본다.
  2. **답변 처리 중 오디오 드롭이 폰 마이크 경로에도 적용된다.** 폰 마이크 세션 중에 웨어러블 버튼을 눌러 본다.
  3. **설정의 오디오 테스트가 폰 마이크 경로에서도 녹음된다.** 예전에는 폰 마이크로 테스트하면 빈 버퍼로 아무것도 안 났다.
     → 설정 → Audio test 를 **폰 마이크 소스로** 3초 녹음·재생.
  4. **버튼 명령 실패가 앱 zone 으로 새지 않는다.** 예전에는 DB 쓰기 실패로 디바운스 플래그가 세워진 채 남아
     버튼이 프로세스 끝까지 죽었다. 버튼을 연타해도 계속 반응하는지 본다.
  5. **Omi 오디오 청크를 매번 디코드하지 않는다** — 결과 동일, 작업량만 감소. (관찰 불가, 참고용)
  6. **세션이 "녹음 중"이라고 거짓말하지 않는다.**
     - (a) 싱글탭으로 세션을 시작하다 실패하면 `holdToAsk` 로 넘어가지 않고 `idle` 에 머문다.
     - (b) 답변 대기(1.5초 + LLM 왕복) 중에 **연결이 끊기면**, 답변이 끝난 뒤 상태가 `listening` 으로 되돌아가지 않는다.
       → **일부러 해 볼 것**: 싱글탭 질문 후 답변을 기다리는 동안 기기를 범위 밖으로 뺀다.
         화면이 "듣는 중" 으로 남아 있으면 회귀다.
- **캡처**: 6-(b) 를 시도한 화면 1장(끊긴 뒤의 상태 표시) → PR #62.
- **실패 시**: 세션이 뜯긴 채 "듣는 중" 이면 PR #62. `StateError` 가 로그에 보이면 그것도 함께.

---

## §5 침묵 저장 · 요약 · 메모리 · 태스크 · 리마인더

이 절은 **OpenAI(또는 호환) 키가 있어야** 한다.

### 5.1 침묵 타임아웃 → 저장 → 요약 (#47 / 이슈 #12)

- **절차**
  1. 설정에서 OpenAI 키 입력.
  2. Omi 연결 → 1~2분 짧은 대화 → 말 멈추고 **2분 대기**(침묵 타임아웃).
- **기대값**: History 에 새 대화가 **제목 + 요약과 함께** 나타난다.
  요약이 태스크를 뽑았다면 Tasks 탭에 나타난다.
- **캡처**: History 목록 1장 + 대화 상세 1장 → PR #47.
- **실패 시**: 제목이 `Conversation 2026-...` 형태면 **요약이 실패한 것**이다.
  `adb logcat -s flutter:V | grep -i "Failed to summarize"` 를 붙여 PR #47.

### 5.2 네트워크 복구 시 요약 재시도 (#57 / 이슈 #17) — **핵심 시나리오**

- **절차**
  1. OpenAI 키가 들어 있는 상태에서 대화를 녹음한다.
  2. **비행기 모드를 켠다.**
  3. 말을 멈추고 침묵 타임아웃이 지나기를 기다린다.
  4. History 를 본다.
  5. 비행기 모드를 끈다.
  6. 다시 History 를 본다.
- **기대값**
  - 4: 대화가 `Conversation 2026-09-06 14:30` 형태의 임시 제목으로 **즉시** 나타난다. 요약은 비어 있다.
    (이전 동작: 제목만 임시로 채워지고 요약은 **영구히** 비었다.)
  - 6: **60초 안에**(연결 복구 이벤트가 잡히면 대체로 즉시) 같은 대화의 제목과 요약이 채워지고,
    추출된 메모리·태스크가 각 탭에 나타난다.
  ```bash
  adb logcat -s flutter:V | grep -i "finaliz"
  ```
  `Saved conversation:` → (네트워크 복구) → `Finalized conversation: <실제 제목>` 순서면 정상.
- **캡처**: 4의 임시 제목 화면 1장 + 6의 채워진 화면 1장 + 위 로그 구간 → PR #57.
- **실패 시**: 복구 후에도 비어 있으면 재시도 큐 문제 → PR #57.
- **덤**: 같은 시나리오를 SD 카드 임포트로도 한 번 — 비행기 모드에서 임포트하면
  `SD Card Recording` 제목으로 먼저 저장되고 복구 후 제목·요약이 채워진다(§7.5 와 겹친다).

### 5.3 메모리·태스크 편집과 알림 연동 (#63 / 이슈 #24)

- **절차/기대값**: 메모리 편집·삭제, 태스크 완료 토글 시 **리마인더 알림이 취소/재예약된다.**
- **캡처**: 실패했을 때만 → PR #63.
- **실패 시**: 완료 처리했는데 알림이 오면 §5.4 의 알림 ID 안정화 쪽이 먼저 깨졌을 수 있다.
  §5.4 를 통과했는데 여기서만 실패하면 컨트롤러 분해 회귀다 → PR #63.

### 5.4 리마인더 — inexact 기본 경로 (#47 / 이슈 #12)

- **절차/기대값**
  ```
  [ ] 마감이 약 10분 뒤인 태스크가 생기는 대화를 만든다
  [ ] 기대: 예정 시각 기준 ±수 분 이내에 알림 도착 (inexact 이므로 정시가 아님이 정상)
  [ ] 기대: 화면이 꺼져 있어도 도착한다 (Doze 중 앱당 9분 1회 제한)
  [ ] 태스크를 완료 처리 → 알림이 오지 않는다
  [ ] 태스크를 스와이프 삭제 → 알림이 오지 않는다
  [ ] 앱을 완전히 종료했다 다시 켠 뒤 완료 처리 → 알림이 오지 않는다
      ← hashCode 였을 때 깨지던 지점. 이번 수정의 핵심 확인 항목
  ```
  ```bash
  adb logcat -s flutter:V | grep -i "Scheduled notification\|Cancelled notification"
  ```
- **캡처**: 위 로그 구간(예약 → 취소가 같은 id 인 것이 보이게) → PR #47.
- **실패 시**: 재시작 후 취소가 안 먹으면 알림 ID 안정화가 깨진 것 → PR #47.

### 5.5 리마인더 — 정확 알람 옵트인 (#81 / 이슈 #50) — **Android 14+ 기기 필요**

- **절차/기대값**
  ```
  기기:            Android 버전(14+ 필요):            빌드:

  [ ] 설정 > Notifications 에 "Exact task reminders" 스위치가 보이고 기본 off
  [ ] 스위치 on → "Allow exact alarms" 다이얼로그 → "Open settings" →
      시스템 "알람 및 리마인더" 화면으로 이동
  [ ] 허용하고 뒤로가기 → 스위치가 on 으로 유지된다
  [ ] 마감 5분 뒤인 태스크를 만들고 화면을 끈다 → 리마인더가 예정 시각 ±1분 도착
  [ ] 시스템 설정에서 권한을 다시 끈다 → 앱의 스위치가 off 로 표시되고,
      새 리마인더는 예정 시각 이후 수 분 내 도착(inexact 폴백)
  [ ] 스위치를 켠 적이 없는 상태에서는 기존 동작 그대로 — 권한 요청이 뜨지 않는다
  ```
  ```bash
  adb logcat -s flutter:V | grep -i "Scheduled notification"   # 줄 끝 preciseAlarm: true/false 확인
  adb shell dumpsys alarm | grep -A2 org.libreomi.app          # 권한 상태 교차 확인
  ```
- **캡처**: `preciseAlarm: true` 와 `false` 각 한 줄씩 + 정확 알람이 ±1분에 도착한 알림 화면 → PR #81.
  **도착 오차 실측값을 적어 달라** — [부록 B-3](#b-3-android-14-정확-알람-실측-81) 의 데이터다.
- **실패 시**: 13 이하 기기에서는 권한이 자동 부여되어 이 흐름이 **재현되지 않는다.** 기기 버전을 먼저 확인.

### 5.6 개인정보 안내 화면의 Exact alarms 행 (#83 / 이슈 #38)

- **절차/기대값**: §5.5 에서 정확 알람을 허용한 뒤, §1.2 의 안내 화면을 다시 열면
  **Exact alarms** 행이 `Granted` 로 바뀐다. 거부 상태에서 그 행의 "Open settings" 는
  앱 설정이 아니라 **Alarms & reminders** 화면을 연다.
- **캡처**: 두 상태의 행 각 1장 → PR #83.
- **실패 시**: 행이 `Granted` 로 안 바뀌면 §5.5 의 스위치 자체가 off 로 돌아간 것은 아닌지 먼저 본다.
  §5.5 는 통과했는데 이 행만 틀리면 안내 화면의 상태 조회 문제다 → PR #83.

---

## §6 백그라운드

### 6.1 포그라운드 서비스와 상시 알림 (#54 / 이슈 #14, #18)

- **절차/기대값**
  ```
  기기:            펌웨어:            빌드:
  [ ] 리스닝 시작과 동시에 상시 알림 표시 — 문구 "Omi connected · mm:ss",
      소리·진동 없음(low importance), 스와이프로 지워지지 않음
  [ ] 대화가 이어지는 동안 알림의 시간이 30초 간격 이상으로 갱신
  [ ] 화면 끄고 1시간 후에도 세션 생존, 자막 누적          ← 핵심 완료 기준
  [ ] Omi 연결 해제 → 알림 문구가 즉시 "Omi disconnected …" 로 바뀌고,
      리스닝이 멈추면 알림이 사라짐
  [ ] 리스닝 중지(유휴) → 상시 알림 사라짐 (이슈 #18 기준)
  [ ] 폰 마이크 세션은 버튼 탭에서만 시작되고 Android 14+ 에서 예외 없이 뜸
  [ ] 설정 → 알림에 "Session" 채널이 하나만 보임 (awesome_notifications 와 채널 id 공유 확인)
  [ ] 세션 중 최근 앱에서 스와이프로 앱 종료 → 알림이 남지 않음 (좀비 서비스 없음).
      이때 세션도 함께 끝나는 것이 의도된 동작
  [ ] 앱 강제 종료 후 재시작 → 유령 고정 알림 없음 (시작 시 회수 동작)   (#63)
  [ ] 설정에서 명시적 연결 해제 → 고정 알림 즉시 사라지고 자동 재연결 안 함   (#63)
  ```
  ```bash
  adb shell dumpsys activity services | grep -i libreomi
  # → ForegroundService 가 isForeground=true, foregroundServiceType 에 connectedDevice(+microphone)
  adb logcat -s flutter:V ForegroundService:V
  ```
- **캡처**: **1시간 경과 후의 자막 화면 1장 + 상시 알림 1장**(이게 M2 의 완료 증거다) +
  위 `dumpsys activity services` 출력 → PR #54.
- **실패 시**: 1시간을 못 버티면 §6.2 배터리 최적화를 먼저 확인하고, 그래도면 PR #54 에
  제조사·모델과 함께 코멘트. OEM 배터리 관리자가 원인인 경우가 많다.

### 6.2 배터리 최적화 제외 (#53 / 이슈 #15)

- **절차/기대값**
  ```
  1) 앱 신규 설치 후 첫 "Start Listening" 탭
     기대: "Keep recording while the screen is off?" 다이얼로그가 1회 표시
  2) "Continue" → 시스템 배터리 최적화 제외 다이얼로그 표시 → 허용
     기대: adb shell dumpsys deviceidle whitelist | grep libreomi 에 패키지가 나타남
  3) 앱 재시작 후 다시 "Start Listening"
     기대: 다이얼로그가 다시 뜨지 않음 (거절했던 경우에도 자동으로는 다시 뜨지 않음)
  4) Settings > BACKGROUND RELIABILITY
     기대: 상태가 "Exempt from battery optimisation" /
           미허용 시 "Request exemption" 행으로 재요청 가능
  5) Settings > BACKGROUND RELIABILITY > Manufacturer guidance
     기대: 기기 제조사에 맞는 단계와 dontkillmyapp 링크, "Copy link" 로 클립보드 복사
  ```
- **캡처**: `dumpsys deviceidle whitelist` 출력 + 제조사 안내 페이지 1장 → PR #53.
- **실패 시**: 제조사 안내가 엉뚱한 제조사로 뜨면 매핑 문제 → PR #53 에 `ro.product.manufacturer` 값과 함께.

### 6.3 범위 이탈 → 재연결 (§2.4 와 동일)

§2.4 를 여기서 해도 된다. 오히려 백그라운드 상태에서 하는 편이 실제 사용에 가깝다.
그때는 [§2.4 의 "한계 두 가지"](#24-재연결-56--이슈-16)를 염두에 두고 **실측 초를 적어 달라.**

---

## §7 SD 카드

### 7.1 페이지 기본 동작 (#75 / 이슈 #33)

| # | 조작 | 기대값 |
|---|------|--------|
| 1 | 미연결 상태로 페이지 진입 | "Device Not Connected" 화면. **연결되면 자동으로** 대기 데이터 조회가 돌아 화면이 바뀐다(예전에는 Check Again 을 눌러야 했다) |
| 2 | 기기 연결 후 진입 | 상태 카드에 `Found 3m 12s of audio (5.4 MB)` 형태로 길이·크기 표시, 데이터가 없으면 "All Caught Up!" |
| 3 | Sync & Process | 원형 진행률이 0→100% 로 **되돌아가지 않고** 증가, 아래에 `Xm Ys remaining` ETA |
| 4 | 전송 중 Cancel | 즉시 멈추고 상태가 `Sync cancelled`, **빨간 오류 스낵바는 뜨지 않아야 함.** 기기 데이터는 남는다 |
| 5 | 다시 Sync & Process (재개) | 남은 데이터로 다시 전송 시작, 완료 시 `Sync complete!` + "Audio synced!" 스낵바 |
| 6 | 파일 행의 ▶ (Process & Transcribe) | 카드가 `Transcribing …` → `Saved — waiting for the summary…` → 전사문 카드 순으로 바뀌고, 제목은 `SD Card Recording` 에 `Summary pending` 이 함께 뜬다 |
| 7 | View in History | History 목록이 열리고 방금 만든 대화가 보인다. 잠시 뒤(요약 큐 처리 후) 제목이 요약 제목으로 바뀐다 |
| 8 | 처리 실패 유도(비행기 모드 + Deepgram) | 오류 문구 + Retry 버튼, `.bin` 이 목록에 **남아 있어야** 한다 |
| 9 | 개별 삭제 / Delete All | 확인 다이얼로그 → 목록과 헤더의 용량 표시가 함께 줄어든다 |
| 10 | Clear Device Storage | 확인 다이얼로그 → `Device storage cleared - refresh to verify`, Check Again 시 대기 데이터 없음 |
| 11 | 페이지를 나갔다 다시 진입 | 이전 방문의 **완료/실패 결과 카드는 사라져 있다**(진행 중인 것은 남는다) |

- **캡처**: 3의 진행률 화면 1장 + 8의 오류·파일 목록이 함께 보이는 1장 → PR #75.
- **실패 시**: 진행률이 되돌아가면 generation 처리 문제 → PR #72.

### 7.2 5분 녹음 동기화 (#72 / 이슈 #31)

시작 전에 로그를 파일로 받는다: `adb logcat -s flutter:V FlutterBluePlus:V BluetoothGatt:V > lo50.log`

- **절차**: Omi 를 폰과 떨어뜨려 **5분 이상** 녹음시킨 뒤 SD 카드 페이지에서 동기화.
- **기대값**: 진행률이 0 → 100% 로 되돌아가지 않고 증가, ETA 표시, 완료 시 "Sync complete!".
- **캡처**: 진행률 바 중간 스크린샷 1장 + `Syncing:` 로그 마지막 20줄 → PR #72.
- **실패 시**: PR #72.

### 7.3 취소와 재개 (#72 / 이슈 #31)

- **절차**: 동기화 중간(진행률 20~50%)에 취소. **취소 직후 다시 동기화를 누른다.**
- **기대값**: 즉시 멈추고 화면이 몇 분씩 멈춰 있지 않다. logcat 에 `Writing to storage` 없이 stop write 가 나가고
  이후 storage 알림이 끊긴다. 재동기화가 정상 진행된다(#72 의 generation 수정이 노리는 지점).
- **캡처**: 취소 전후 logcat 30줄 → PR #72.
- **실패 시**: 취소 후 재동기화가 진행되지 않거나 진행률이 되돌아가면 generation 처리 회귀다 →
  취소 전후 로그와 함께 PR #72. 화면이 몇 분간 멈추면 stop write 가 안 나간 것이므로 그 사실도 적어 달라.

### 7.4 완료 후 기기 저장소 비움 · 상태 코드 (#72 / 이슈 #31)

- **절차/기대값**
  - 동기화 완료 후 SD 카드 페이지 새로고침 → 대기 데이터 0,
    `Cleared SD card storage after syncing ...` 로그.
  - **첫 패킷 5초 타임아웃** — 이식 전에는 `ready`(`0x00`) 상태 바이트도 "첫 데이터"로 쳐서 타이머를 껐지만
    이제는 실제 오디오 패킷만 센다. 정상 기기라면 차이가 없다.
    확인: logcat 에서 `Storage command response: 0` 과 `First data received from SD card` **사이 시간이 5초 미만**인지.
    **5초를 넘으면 알려 달라 — 타이머 기준을 되돌려야 한다.**
  - **알 수 없는 상태 코드** — 이식 전에는 인식하지 못한 단일 바이트를 "완료"로 처리했지만
    이제는 실패로 처리한다(기기 저장소를 지우지 않으므로 데이터 손실은 없다).
    **예상치 못한 `Storage: Error code N` 이 보이면 N 값을 알려 달라.**
- **캡처**: `Cleared SD card storage` 로그 + 새로고침 후 화면 1장 → PR #72.
- **실패 시**: `Storage command response: 0` → `First data received from SD card` 가 **5초를 넘으면**
  타이머 기준을 되돌려야 하므로 그 초 수를, `Storage: Error code N` 이 보이면 N 값을 PR #72 에 적어 달라.
  완료 후에도 대기 데이터가 남으면 clear 명령이 안 나간 것이다 → 같은 PR.

### 7.5 SD 카드 파일 전사 (#73 / 이슈 #32)

BLE 연결 자체는 이 항목이 건드리지 않으므로 §2 전체를 다시 돌 필요는 없다.

**(A) 클라우드 경로 — Deepgram 키 있는 상태**

1. 설정 → Transcription mode = `cloud`, Deepgram 키 입력, 모델 확인(기본 `nova-2`).
2. Omi 를 SD 카드 녹음 상태로 두고(**최소 30초 이상** 말하기), SD Card 페이지에서 **Sync** → 파일이 목록에 뜨는지.
3. 그 파일의 **Process** 를 누른다.
4. **기대값**: 상태 문구가 `Transcribing audio...` → `Processing complete!` 로 바뀌고,
   History 에 **제목 `SD Card Recording`** 인 대화가 생긴다. 잠시 뒤 요약이 붙으면서 제목이 요약 제목으로 바뀐다.
   화자가 둘이면 세그먼트가 화자별로 나뉜다.
5. 설정 → API 사용량에서 **Deepgram 분(minutes)이 녹음 길이만큼 증가**했는지.
- **캡처**: History 대화 상세 1장 + 설정의 사용량 화면 1장 → PR #73.

**(B) 로컬 경로 — 키 없이**

1. 설정 → Transcription mode = `whisper`(또는 `sherpa` — 둘 다 같은 오프라인 경로),
   Whisper tiny 와 Silero VAD 설치.
2. (A)와 같이 Sync → Process.
3. **기대값**: 네트워크가 꺼져 있어도 History 에 `SD Card Recording` 대화가 생긴다
   (요약만 온라인 복귀 후 붙는다). 세그먼트는 전부 speaker 0.
4. **모델을 지운 상태**로 한 번 더 Process → **기대값**: `Transcription failed: ...` 상태 문구에
   **모델 설치 화면을 지목하는 메시지**가 그대로 보인다(대화는 저장되지 않는다).
- **캡처**: 3의 History 1장 + 4의 오류 문구 1장 → PR #73.

**(C) 실패해도 녹음이 지워지지 않는지**

1. `cloud` 모드로 두고 **Deepgram 키를 비운다.**
2. SD Card 페이지에서 Process.
3. **기대값**: `Transcription failed: Exception: Deepgram API key not configured` 가 뜨고,
   **`.bin` 파일이 목록에 그대로 남아 있다**(성공했을 때만 삭제된다).
   무음 녹음을 Process 했을 때도 `No speech recognized in ...` 로 실패하고 파일이 남는 것이 정상이다.
- **캡처**: 오류 문구와 파일 목록이 함께 보이는 1장 → PR #73.

```bash
adb logcat -s flutter:V | grep -i "Processing local audio\|Whisper worker\|Deepgram"
adb logcat -s flutter:V | grep -i "Starting SD card sync\|Saved N frames to:\|Sync cancelled"
```

- **실패 시**: (C)에서 **`.bin` 이 사라졌다면 데이터 손실이므로 가장 먼저 알려 달라** → PR #73.
  (A)는 되고 (B)만 안 되면 오프라인 모델 경로이므로 §3.3·§3.5 를 먼저 통과시킨 뒤 다시 온다.
  대화는 생겼는데 요약이 안 붙으면 그것은 §5.2 의 재시도 큐 문제다 → PR #57.

### 7.6 440바이트 패킷 hex 덤프 (#72 / 이슈 #31) — **가장 중요한 요청 사항**

이 데이터가 없으면 파서의 off-by-one 을 확정할 수 없다. [부록 B-1](#b-1-440바이트-패킷-off-by-one-72) 참고.

- **절차**
  1. Settings → Developer → **"Capture BLE session"** 을 켠다.
  2. §7.2 의 5분 동기화를 한 번 돌린다.
     ⚠️ §2.3 과 같은 이유로, **녹음 내용이 아무 의미 없는 것이어야 한다** — 이 파일은 공개 PR 에 붙는다.
     440바이트 패킷의 구조만 필요하지 말의 내용은 필요 없다.
  3. 앱 support 디렉터리의 `ble_session_*.jsonl` 을 꺼낸다.
     ```bash
     adb exec-out run-as org.libreomi.app ls files/../
     adb exec-out run-as org.libreomi.app cat <path>/ble_session_<ts>.jsonl > ble_session_sd.jsonl
     ```
- **기대값**: storage 알림 중 **길이 440 인 패킷이 1개 이상** 들어 있다.
- **캡처**: 파일을 PR #72 코멘트에 첨부. 파일이 너무 크면 **440바이트 패킷 하나의 raw hex 400바이트 정도**만 붙여도 된다.
- **실패 시**: 440 길이 패킷이 아예 안 보이면 그 사실 자체가 데이터다 — 관측된 길이들을 PR #72 에 적어 달라.

---

## §8 데이터 (내보내기 / 가져오기 / 업그레이드)

> ⚠️ **§8.1~§8.4 는 각각 자기 전제를 먼저 만들어야 한다.**
> [§0.0](#00-시작-전에--1-과-8-은-서로-반대되는-상태를-요구한다) 의 4단계(옛 커밋 빌드·설치 → 데이터 생성 →
> 이 브랜치 빌드 **덮어** 설치 → 확인)를 **항목마다** 반복한다. 어느 커밋이 필요한지는 §0.0 의 표에 있다.
> 항목 사이에는 앱 데이터를 지워도 된다. **§8.5 는 준비 없이 바로 된다.**
> 각 항목 안에서는 앱을 지우면 안 된다 — 지우면 마이그레이션을 지나친다.

### 8.1 스키마 마이그레이션 — v4 → v5 (#60 / 이슈 #25)

- **절차**: v4 가 설치된 기기에 이 빌드를 **덮어쓰기 설치**한다. **uninstall 하지 말 것** —
  재설치하면 v5 신규 생성이라 마이그레이션을 지나친다.
- **기대값**
  1. History / Memories / Tasks 목록이 업그레이드 전과 **행 수·내용·정렬 모두 그대로**.
  2. 업그레이드 전에 예약해 둔 **작업 알림이 예정 시각에 그대로 온다.** 그 작업을 완료·삭제하면 알림이 취소된다.
     (백필된 `notification_id` 가 예약 당시 id 와 같으므로 취소가 먹는다. 실패하면 예약이 남아 알림이 두 번 오거나 취소가 안 된다.)
  3. ```bash
     adb shell run-as org.libreomi.app sqlite3 databases/libreomi.db \
       "PRAGMA table_info(tasks); SELECT id, created_at, notification_id FROM tasks LIMIT 5;"
     ```
     기대: `notification_id` 컬럼 존재, 모든 행이 non-null, 값 = `created_at & 0x7fffffff`.
- **캡처**: 위 sqlite3 출력 → PR #60.
- **실패 시**: `notification_id` 가 null 이거나 기존 알림 취소가 안 먹으면 백필이 깨진 것 → PR #60.
  목록이 통째로 비면 3단계에서 덮어 설치가 아니라 uninstall 후 재설치를 한 것이다(마이그레이션을 지나쳤다) →
  [§0.0](#00-시작-전에--1-과-8-은-서로-반대되는-상태를-요구한다) 의 4단계부터 다시.

### 8.2 스키마 마이그레이션 — v5 → v6, 채팅 순서 (#82 / 이슈 #65)

- **절차/기대값**
  1. **업그레이드** — 이전 빌드가 설치된 기기에 덮어 설치(앱 데이터 삭제 금지).
     기대: 채팅 화면의 기존 기록이 **개수·순서 모두 그대로**.
     `adb logcat | grep -i libreomi` 에 sqlite 오류가 없어야 한다.
  2. **같은 밀리초 순서 유지** — 홀드-투-애스크로 질문을 **연속으로 빠르게** 3~4번 던져 답변까지 받은 뒤
     앱을 완전히 종료하고 재실행 → 채팅 화면.
     기대: 질문1 → 답변1 → 질문2 → 답변2 … 순서 그대로.
     (이전 빌드에서는 같은 밀리초에 걸린 쌍이 답변-질문 순으로 뒤집혀 보일 수 있었다.)
  3. (선택) **백업 왕복** — 내보내기 → 가져오기(replace). 기대: 채팅 순서가 내보내기 전과 동일.
     merge 로 같은 파일을 두 번 가져와도 기존 대화가 뒤로 밀리지 않는다.
- **캡처**: 2의 채팅 화면 1장 → PR #82.
- **실패 시**: 순서가 뒤집히면 `seq` 백필/정렬 회귀다 → 채팅 화면과 `adb logcat | grep -i libreomi` 의
  sqlite 줄을 함께 PR #82.

### 8.3 리포지토리·모델 이전 회귀 (#76 / 이슈 #64, #85 / 이슈 #66)

둘 다 "동작 불변" PR 이다. 위 §8.1·§8.2 를 하면서 함께 본다.

- **절차/기대값** (#85 — 데이터 읽기 호환이 목적)
  1. 기존 데이터가 있는 기기에 **그대로 업데이트 설치**(앱 데이터 삭제 금지).
  2. **대화 목록**에 기존 대화가 이전과 같은 개수·제목·요약으로 뜨는지.
     대화 하나를 열어 자막 세그먼트와 재생 시간(`5m 23s` 형식)이 이전과 동일한지.
  3. **메모리 목록**과 **작업 목록**이 이전과 같은 내용으로 뜨고, 작업의 마감일·완료 체크 상태가 유지되는지.
  4. **AI 채팅 화면**의 지난 기록이 순서대로 남아 있는지(schema v6 `seq` 순서).
  5. 설정 → 백업 **내보내기**를 한 번 실행하고, 나온 JSON 을 이전 버전에서 내보낸 파일과 비교했을 때 **키 구성이 같은지.**
  - **기대값**: 전 항목이 **이전 버전과 완전히 동일.** 하나라도 비거나 다르면 "동작 불변" 전제가 깨진 것이므로 되돌린다.
- **절차/기대값** (#76 — 선택. 파사드가 정말 아무 데서도 안 쓰였는지)
  - Settings → Export all data. 기대: JSON 에 `conversations`·`memories`·`tasks`·`chat_messages` 네 키가 모두 있고
    `chat_messages` 가 비어 있지 않으며, 각 task 에 `notification_id` 가 **정수**로 들어 있다.
  - `adb logcat -s flutter:V | grep -i "sqlite\|database\|migrat"` 에 예외가 없어야 한다.
    이미 최신 스키마라 마이그레이션이 다시 돌지 않으므로 스키마 관련 출력이 없는 것이 정상이다.
- **캡처**: 내보낸 JSON 의 최상단 20줄(키 4개가 보이게) → PR #85. 위 로그 → PR #76.
- **실패 시**: 목록이 비거나 내용이 달라지면 **"동작 불변" 전제가 깨진 것이므로 되돌려야 한다** —
  무엇이 어떻게 달랐는지와 함께 PR #85. `chat_messages` 만 비면 §8.2 를 먼저 본다.
  내보내기 JSON 의 키가 빠졌으면 PR #76.

### 8.4 API 키 보안 저장소 이전 (#55 / 이슈 #19)

- **절차/기대값**
  1. **업그레이드 시 키 유지** — [§0.0](#00-시작-전에--1-과-8-은-서로-반대되는-상태를-요구한다) 대로
     **`17d55a3fa^` 빌드**(평문 키 시절)를 설치하고 Settings 에서 Deepgram/OpenAI 키를 입력한다.
     그 위에 이 브랜치 빌드를 `flutter run` 또는 `adb install -r` 로 **덮어 설치**(데이터 유지)한 뒤 앱을 연다.
     ⚠️ 현재 `main` 빌드에서 키를 넣으면 이미 보안 저장소에 저장되므로 마이그레이션이 일어나지 않는다.
     기대: 두 키 입력란에 기존 키가 그대로 보이고, 전사·요약이 정상 동작한다.
  2. **평문이 남지 않음** — 위 직후:
     ```bash
     adb shell run-as org.libreomi.app cat shared_prefs/FlutterSharedPreferences.xml
     ```
     기대: `deepgram_api_key` / `openai_api_key` 항목이 **없다.** `secure_keys_migrated` 가 `true`.
     ```bash
     adb shell run-as org.libreomi.app ls shared_prefs/
     ```
     기대: `FlutterSecureStorage.xml`, `FlutterSecureKeyStorage.xml`,
     `FlutterSecureStorageConfiguration:FlutterSecureStorage.xml` 이 있고,
     `cat FlutterSecureStorage.xml` 의 값이 base64 암호문이다(**평문 키가 보이면 안 된다**).
  3. **백업 제외 동작** — 콜론이 든 파일 이름은 규칙 매칭이 육안으로 확실하지 않으니 한 번 확인해 둔다:
     ```bash
     adb shell bmgr backupnow org.libreomi.app
     adb logcat -d | grep -i backup
     ```
     기대: 백업이 성공하고, 제외 대상 파일이 전송 목록에 없다.
- **캡처**: ⚠️ **`FlutterSharedPreferences.xml` 출력에 키가 남아 있지 않은 것만** 확인하고,
  붙일 때는 **키 값이 보이지 않도록** 해당 줄만 잘라 PR #55.
- **실패 시**: 평문이 남아 있으면 마이그레이션 실패 — 그 사실만(값 없이) PR #55.

### 8.5 JSON 백업 내보내기 / 가져오기 (#80 / 이슈 #35)

- **절차/기대값**
  1. **내보내기** 설정 > Data > Export All Data → 공유 시트에서 파일 앱에 저장.
     기대: 파일명이 `libreomi-export-YYYYMMDD-HHMM.json`, 최상단에 `"format_version": 1`,
     `"app_version": "0.1.0"`, `"exported_at"`, 그리고 History/Memories/Tasks/Chat 개수와 일치하는 4개 배열.
  2. **파일 선택기** 설정 > Data > Import from Backup → 방금 저장한 `.json` 이 목록에 보이고 선택된다.
     기대: 확인 다이얼로그에 대화·메모리·태스크·채팅 개수와 내보낸 시각이 1번 파일과 같게 표시.
     ⚠️ **여기가 CI 로 못 잡는 유일한 지점이다** — Android 는 `allowedExtensions: ['json']` 을 MIME 로 변환하는데,
     기기·파일 앱에 따라 `.json` 이 **회색으로 비활성 표시**되는 사례가 알려져 있다.
     그렇게 보이면 알려 달라(선택기 타입을 `FileType.any` 로 바꾸고 확장자는 앱에서 검사하는 쪽으로 돌리면 된다).
     → [부록 B-5](#b-5-json-파일-선택기-회색-처리-80)
  3. **replace 복원** 앱 데이터 삭제(설정 > 앱 > LibreOmi > 저장공간 > 데이터 삭제) → 앱 실행 →
     2번 파일로 Import → Replace → 2차 경고에서 "Delete & Replace".
     기대: 스낵바가 `Imported <N> new, updated 0, skipped 0`,
     History / Memories / Tasks / Chat 네 화면이 삭제 전과 같은 내용으로 복원.
     **태스크의 예약 알림이 삭제 전과 같은 시각에 유지되는지**(알림 ID 보존)도 함께.
  4. **merge 복원** 3번 뒤에 같은 파일을 다시 Import → Merge.
     기대: 개수가 늘지 않고 `Imported 0 new, updated <N>, skipped 0`, 화면 내용도 그대로(중복 생성 없음).
  5. **손상 파일 거부** 저장한 `.json` 의 앞부분 몇 글자를 지워 깨뜨린 뒤 Import.
     기대: "Could not read backup file: ..." 스낵바가 뜨고 라이브러리는 그대로.
  6. **큰 백업의 반응성** 대화가 많은 상태에서 1·3번을 반복.
     기대: 인코딩/디코딩이 아이솔레이트에서 돌므로 진행 다이얼로그 동안 UI 가 얼지 않고,
     다이얼로그 표시 중 **뒤로가기를 눌러도 설정 화면이 닫히지 않는다.**
- **캡처**: 2의 파일 선택기 화면 1장(`.json` 이 선택 가능한지 보이게) + 3의 결과 스낵바 1장 → PR #80.
- **실패 시**: 2에서 `.json` 이 회색이면 [부록 B-5](#b-5-json-파일-선택기-회색-처리-80) 대로 기기·파일 앱 이름과 함께 PR #80.
  4(merge)에서 개수가 늘면 중복 생성이므로 스낵바 숫자와 함께 PR #80.
  3에서 태스크 알림 시각이 달라지면 알림 ID 보존이 깨진 것이다 → PR #80 과 PR #47 양쪽에 적어 달라.

> §8.5-3 은 앱 데이터를 지운다. **§8.1~§8.4 를 모두 끝낸 뒤에 한다** — 중간에 끼면
> 진행 중이던 항목의 옛 빌드 상태를 날려 그 항목만 처음부터 다시 해야 한다.
> §1~§7·§9 와는 무관하다.

---

## §9 설정

### 9.1 OpenAI 호환 엔드포인트 (#78 / 이슈 #34)

- **절차/기대값**
  1. **Ollama(로컬)** — 설정 → LLM → 프리셋 `Ollama (local)` 선택 →
     base URL 이 `http://localhost:11434/v1` 로 채워지면 **폰에서 닿는 주소**로 고쳐 입력 →
     API Key 는 비워 둔다 → **Test connection**.
     - 기대: `Connected — N models` 와 초록 체크. 모델 드롭다운에 없으면 "Add model" 로 `llama3.2` 추가 후 선택.
     - 이어서 대화를 하나 저장(더블탭 또는 SD 카드 가져오기)해 **요약·제목·메모리가 생성**되는지.
       Ollama 는 `response_format` 을 거부할 수 있는데, **그때 로그에 폴백 한 줄이 찍히고도 요약이 성공하는 것**이
       이 PR 의 핵심이다:
       ```bash
       adb logcat -s flutter:V | grep -i "json mode"
       ```
  2. **OpenRouter** — 프리셋 `OpenRouter`, API Key 에 OpenRouter 키, 모델 `openai/gpt-4.1-mini`.
     Test connection 성공 후 요약 1회.
  3. **실패 표시** — base URL 을 `http://127.0.0.1:1/v1` 같은 닿지 않는 주소로 바꾸고 Test connection →
     빨간 아이콘과 실패 사유가 뜨고 **앱이 죽지 않아야 한다.**
     키를 일부러 틀리게 넣으면 메시지에 `401` 이 보여야 한다(**키 자체는 절대 표시되지 않는다**).
  4. **가격표** — 설정 → LLM → Pricing 에서 쓰는 모델의 입력/출력 단가를 넣고,
     통계 화면의 LLM 비용이 `—` 에서 금액으로 바뀌는지.
     **가격을 두 칸 연달아 고쳤을 때 먼저 고친 값이 되돌아가지 않아야 한다**(심사에서 지적되어 고친 부분).
- **캡처**: Test connection 성공 화면 1장 + `json mode` 폴백 로그 줄 + 통계의 LLM 비용 1장 → PR #78.
  ⚠️ **API Key 입력란이 화면에 들어가지 않게 할 것.**
- **실패 시**: Test connection 은 되는데 요약이 실패하면 `json mode` 폴백이 안 먹은 것이다 —
  그 로그 줄과 모델 이름을 PR #78. 3에서 **앱이 죽으면 차단 결함**이므로 즉시 알려 달라.
  4에서 먼저 고친 가격이 되돌아가면 심사에서 고쳤던 회귀가 되살아난 것이다 → 같은 PR.
  ⚠️ 실패 메시지를 붙일 때 **키가 본문에 찍혀 있지 않은지 확인할 것**(`401` 만 보여야 정상이다).

### 9.2 i18n — 언어 전환 (#84 / 이슈 #36)

- **절차/기대값**
  1. **시스템 언어 따르기(기본)** — 휴대폰 언어를 한국어로 두고 앱을 새로 설치·실행.
     기대: 첫 화면(프라이버시 고지)이 한국어. 하단 탭 5개가 한국어. 설정의 모든 섹션 제목·항목이 한국어.
  2. **수동 전환** — 설정 → 언어 → English.
     기대: **재시작 없이 그 자리에서** 영어로 바뀐다. "시스템 설정 따르기" 로 되돌리면 한국어로 돌아온다.
     앱을 껐다 켜도 마지막 선택이 유지된다.
  3. **알림** — 한국어 상태에서 녹음을 시작.
     기대: 지속 알림이 `휴대폰 마이크 · 00:12` / `Omi 연결됨 · 00:12` 형태.
     마감이 몇 분 뒤인 태스크를 만들면 알림 제목이 `태스크 마감: <제목>`, 본문이 한국어.
     기기를 범위 밖으로 빼면 연결 해제 알림도 한국어.
  4. **날짜** — 대화 상세의 시각, 태스크 마감일, 통계의 첫 대화 날짜, 일주일 넘은 메모리의 날짜가
     한국어 표기(예: `2026. 9. 8.`, `오후 3:05`)인지.
  5. **지원하지 않는 언어** — 휴대폰 언어를 일본어 등으로. 기대: 앱이 죽지 않고 **영어**로 뜬다.
  6. **SD 카드 화면** — 파일 목록의 길이(`3분 20초`)와 시각(`방금 전`, `5분 전`)이 한국어인지.
- **캡처**: 한국어 홈 1장 + 한국어 알림 1장 + 일본어 설정에서의 영어 폴백 1장 → PR #84.
- **실패 시**: 영어 문자열이 섞여 나오면 그 화면을 찍어 PR #84 (`app_ko.arb` 누락).

### 9.3 릴리스 빌드 스모크 (#77 / 이슈 #37) — §0.3 릴리스 경로를 한 경우만

- **절차/기대값**
  1. **서명 확인** — `scripts/release.sh --dry-run`.
     기대: `Signer #1 certificate DN` 이 방금 만든 키의 DN 이고 **`CN=Android Debug` 경고가 뜨지 않는다.**
     뜨면 키가 안 읽힌 것이다.
  2. **설치 확인** — `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` 를 실기기에 설치(`adb install -r`).
     기대: 앱이 뜨고 §1~§6 이 통과한다. release 빌드는 R8 off 라 debug 와 동작이 같아야 한다.
  3. **CI 시크릿 등록**(Actions 를 다시 켤 때) — `LIBREOMI_KEYSTORE_BASE64`(`base64 -i <keystore>`),
     `LIBREOMI_KEYSTORE_PASSWORD`, `LIBREOMI_KEYSTORE_ALIAS`, `LIBREOMI_KEY_PASSWORD`.
  4. **첫 릴리스** — `08-dev-workflow.md` §7.3 순서대로.
     Actions 가 꺼져 있는 동안에는 태그를 밀어도 워크플로가 돌지 않으므로
     `scripts/release.sh` 를 로컬에서 실행해 draft release 를 만든다.
- **캡처**: `Signer #1 certificate DN` 줄(**DN 만**, 해시·비밀번호 제외) → PR #77.
- **실패 시**: 디버그 키로 서명되면 `android/key.properties` 경로를 먼저 본다 → PR #77.

---

## §10 iOS (선택)

`--no-codesign` 빌드는 컴파일만 증명한다. **서명된 빌드로만 아래가 확인된다** (#86 / 이슈 #39).

1. **서명·설치** — `Runner.xcodeproj` 에 팀을 지정하고 `mise exec -- flutter run --release -d <ios-device>`.
   - 기대: 설치·실행 성공.
   - **실패 시**: 번들 ID 가 업스트림 잔재인 `com.omilocal.omiLocal` 인 점을 **먼저 의심할 것.**
     이 PR 범위 밖이라 손대지 않았다 — **별도 이슈로 분리할지 판단 부탁드린다.**
2. **Keychain** — 설정 화면에서 Deepgram/OpenAI 키를 저장하고 앱을 완전히 종료했다 재실행.
   - 기대: 키가 유지된다.
   - **실패 시**: `flutter_secure_storage` 가 `-34018` 로 실패하면 Xcode 에서 **Keychain Sharing** capability 를
     켜야 한다는 뜻이고, 그때는 후속 이슈로 `Runner.entitlements` 에 `keychain-access-groups` 를 추가해야 한다.
     엔타이틀먼트는 서명될 때만 적용되므로 추측으로 넣지 않았다. → [부록 B-6](#b-6-ios-번들-id-와-keychain-엔타이틀먼트-86)
3. **BLE 백그라운드** — Omi 연결 후 화면을 끄고 5분.
   - 기대: `UIBackgroundModes` 의 `bluetooth-central` 덕에 연결과 자막 누적이 유지된다.
   - iOS 에는 포그라운드 서비스가 없으므로(`NoopBackgroundRunner`) **이것이 Android 대비 유일한 백그라운드 보증**이다.
4. **UIScene 전환 회귀** — 앱 전환·복귀, 알림 탭으로 진입.
   - 기대: 화면이 정상 복원된다. 라이프사이클 규약이 바뀌었으므로 한 번은 눈으로 볼 가치가 있다.
- **캡처**: 3의 5분 후 자막 화면 1장 → PR #86.

---

## 부록 A — PR 별 추출 대조표

#40~#86 중 **실제로 존재하는 PR 39건 전부**를 적는다.
(#50·#51·#52·#64·#65·#66·#71·#74 는 PR 번호가 아니라 이슈 번호다 — 이 구간에 그 번호의 PR 은 없다.)
"추출한 절" 이 **—** 인 행은 해당 PR 이 본문에서 **실기기 확인이 해당 없음이라고 명시**한 것이다.

| PR | 닫은 이슈 | 제목(축약) | 추출한 절 | 이 런북에서 |
|---|---|---|---|---|
| #40 | #1 | LO-01 업스트림 소스 가져오기 | — (해당 없음 명시: 파일 가져오기만, 동작 변경 0) | — |
| #41 | #2 | LO-02 툴체인 고정 | — (해당 없음 명시: BLE/오디오/세션/플랫폼 무변경) | §0.3 (mise 명령) |
| #42 | #3 | LO-03 패키지명·android 플랫폼 | — (해당 없음 명시. `flutter run` 확인은 #49 로 넘김) | §1.1 |
| #43 | #4 | LO-04 CI 워크플로 | — (해당 없음 명시. 단, **Actions 가 계정 수준에서 차단**) | §0.3 주석 |
| #44 | #9 | 알림 아이콘·채널 정리 | 소유자 확인 항목 (Android 13+ 실기기) | §1.4 |
| #45 | #10 | Deepgram 사용량 집계 | 소유자 확인 필요 (키·실기기 없음) | §3.1, 부록 B-4 |
| #46 | #8 | LO-12 MTU·연결 우선순위 | 소유자 확인 절차 (실기기) | §2.1, §2.2, 부록 B-2 |
| #47 | #12 | 리마인더 inexact·알림 ID | 테스트 방법 내 "소유자 확인 필요 (기기 + OpenAI 키)" | §5.1, §5.4 |
| #48 | #7 | LO-11 권한 선언·런타임 흐름 | ⚠️ 소유자 확인 필요 (실기기) | §1.3 |
| #49 | #6 | LO-10 arm64 전용 디버그 APK | 소유자 확인 필요 (실기기 없음) | §0.1, §1.1 |
| #53 | #15 | LO-21 배터리 최적화 제외 | 테스트 방법 내 "실기기 확인 필요 (소유자)" | §6.2 |
| #54 | #14, #18 | LO-20 포그라운드 서비스 | 소유자 확인 필요 (실기기) | §6.1 |
| #55 | #19 | LO-25 API 키 보안 저장소 | 소유자 확인 필요 (실기기·실제 API 키 없음) | §8.4 |
| #56 | #16 | LO-22 재연결 전략 | 테스트 방법 내 "실기기 스모크 (소유자 확인 필요)" + 한계 2건 | §2.4, §6.3 |
| #57 | #17 | LO-23 요약 재시도 큐 | 소유자 확인 필요 (실기기·API 키 없이 작업함) | §5.2 |
| #58 | #20 | LO-30 core 유틸·파서 단일화 | 테스트 방법 내 "실기기 스모크 — 소유자 확인 필요" | §2.2 |
| #59 | #22 | LO-32 인터페이스 도입 | 실기기 회귀 확인 — 소유자 확인 필요 | §3.1, §3.2, §4.1 |
| #60 | #25 | LO-35 리포지토리 분리·v5 | 소유자 확인 필요 (마이그레이션은 CI 재현 불가) | §8.1 (4항목 중 3개. 4번 "채팅 기록이 **아직** 남지 않는다" 는 #82·#85 가 채팅 영속화를 넣어 **무효가 된 기대값**이라 옮기지 않았다 — 지금 기대값은 §8.2·§8.3 의 "남아 있다"다) |
| #61 | #21 | LO-31 OmiDevice·FakeOmiDevice | 소유자 확인 필요 — 실기기 회귀 / — 실제 픽스처 만들기 | §2.2, §2.3 |
| #62 | #23 | LO-33 세션 상태기계 분리 | 의도한 동작 개선 (동작 불변의 예외 — 소유자가 알아야 할 것) 6건 | §4.2 |
| #63 | #24 | LO-34 컨트롤러 4개 분해 | 실기기 스모크 — 소유자 확인 필요 (13항목) | §4.1, §5.3, §6.1, §7.1 |
| #67 | #26 | LO-40 모델 스토어 | 소유자 확인 필요 (기기) | §0.4, §3.6 |
| #68 | #27 | LO-41 Sherpa 워커 isolate | 소유자 확인 필요 (실기기) | §3.2 |
| #69 | #28 | LO-42 Whisper + Silero VAD | 소유자 확인 필요 — 실기기 절차 | §3.3 |
| #70 | #30 | LO-44 한국어 오프라인 모델 | 소유자 확인 필요 (실기기) | §3.4 |
| #72 | #31 | LO-50 OmiStorage 전송 계층 | 소유자 확인 필요 (실기기) 6항목 + §5 스모크 | §7.2~§7.4, §7.6, 부록 B-1 |
| #73 | #32 | LO-51 SD 카드 파일 전사 | 🔴 소유자 확인 필요 (실기기·API 키) A/B/C | §7.5 |
| #75 | #33 | LO-52 SD 카드 페이지 | 소유자용 SD 카드 절차 (11항목 표) | §7.1 |
| #76 | #64 | DatabaseService 파사드 삭제 | 소유자 확인 필요 (선택, 주말 일괄 검증 때 곁다리로) | §8.3 |
| #77 | #37 | LO-63 릴리스 엔지니어링 | 소유자 확인 필요 (주말 실기기 배치에 넣어 주세요) 6항목 | §0.3, §9.3 |
| #78 | #34 | LO-60 OpenAI 호환 설정 | 소유자 확인 필요 (실기기 · API 키 필요) | §9.1 |
| #79 | #71 | LO-71 SenseVoice 어댑터 | 소유자 확인 필요 (실기기) 6항목 | §0.4, §3.5 |
| #80 | #35 | LO-61 JSON 백업 | 소유자 확인 필요 (실기기, CI·데스크톱 불가) 6항목 | §8.5, 부록 B-5 |
| #81 | #50 | 태스크 리마인더 정확 알람 | 테스트 방법 내 "소유자 확인 필요 (실기기)" — Android 14+ | §5.5, 부록 B-3 |
| #82 | #65 | 채팅 정렬 타이브레이크 v6 | 소유자 확인 필요 (실기기) 3항목 | §8.2 |
| #83 | #38 | LO-64 권한·개인정보 안내 화면 | 테스트 방법 내 "소유자 확인 필요 (실기기)" 7항목 | §1.2, §5.6 |
| #84 | #36 | LO-62 i18n 스캐폴딩 | 소유자 확인 필요 (실기기) 6항목 | §9.2 |
| #85 | #66 | 데이터 모델 lib/core/models 이전 | 소유자 확인 필요 (실기기 · 주말 일괄 검증) 5항목 | §8.3 |
| #86 | #39 | LO-65 iOS 빌드 재검증 | 소유자 확인 필요 (실기기·서명 없이는 증명 불가) 4항목 | §10, 부록 B-6 |

**추출 방법** — 39개 PR 본문을 헤딩 트리로 잘라
`소유자` / `실기기` / `기기 절차` / `스모크` / `logcat` / `adb` 가 걸리는 절을 뽑았고,
헤딩에 걸리지 않은 11건(#40·#41·#42·#43·#47·#53·#56·#58·#81·#82·#83)은 `## 테스트 방법` 절을
통째로 다시 확인해 누락을 막았다. 재현하려면:

```bash
gh pr list -R johnpark-bin/LibreOmi --state merged --limit 100 --json number,title,body
```

---

## 부록 B — 알려진 미확정 사항 (= 이번 검증에서 데이터를 모아야 하는 것)

아래는 **에이전트가 결론을 내리지 못하고 남긴 것들**이다. 절차는 본문에 있고, 여기는 "왜 필요한가"다.

### B-1 440바이트 패킷 off-by-one (#72)

`parseStoragePacket` 은 지금 **마지막 레코드가 패킷 끝에 정확히 닿을 때 그 레코드를 버린다.**
이 동작이 맞는지 틀린지는 실제 440바이트 패킷의 raw hex 없이는 확정할 수 없다.
`05-omi-ble-protocol.md` 와 파서를 함께 고칠지 말지가 이 데이터 하나에 달려 있다.
→ **절차: §7.6.** 붙일 곳: PR #72.

### B-2 MTU 최소값 86 의 근거 (#46)

`negotiated MTU=512 (minimum 86)` 의 **86 은 요구 최소값**이고, 512 는 협상 희망값이다.
실기기에서 512 가 아닌 값으로 협상되는 경우가 있는지, 있다면 몇인지가 미확정이다.
86 미만이면 연결을 거부하는데, 그 게이트가 실제 기기에서 발동한 적은 아직 없다.
→ **절차: §2.1.** 512 가 아니면 그 값을 PR #46 에 적어 달라.

### B-3 Android 14 정확 알람 실측 (#81)

정확 알람의 기대값은 "예정 시각 ±1분"이고, inexact 폴백은 "예정 시각 이후 수 분 내"다.
둘 다 **코드가 보장하는 값이 아니라 기대치**다. Doze 상태의 실제 오차가 미측정이다.
→ **절차: §5.5.** 두 경우의 실제 도착 오차를 PR #81 에 적어 달라.

### B-4 Deepgram `interim_results` inert 가드 (#45)

`buildListenUri` 는 `interim_results` 를 보내지 않고 Deepgram 기본값은 `false` 다.
따라서 지금 URL 로는 모든 `Results` 가 이미 `is_final: true` 로 오며,
#45 가 넣은 `is_final` 가드는 **맞지만 아직 작동하지 않는(inert) 방어 코드**다.
`interim_results=true` 를 켜는 순간부터 유효해진다.
→ **§3.1 의 3번 항목은 "고치지 않은 것을 검증했다"로 읽으면 안 된다.**
실기기에서 실제 과다 집계가 관측된다면 원인은 `is_final` 이 아니라
`DeepgramService` 인스턴스 중복 생성이나 재연결 시 재집계 쪽이다.

### B-5 `.json` 파일 선택기 회색 처리 (#80)

Android 는 `allowedExtensions: ['json']` 을 MIME 로 변환하는데,
기기·파일 앱에 따라 `.json` 이 **선택 불가(회색)** 로 보이는 사례가 알려져 있다.
이 저장소에서는 아직 관측되지 않았다.
→ **절차: §8.5-2.** 회색으로 보이면 PR #80 에 기기·파일 앱 이름과 함께.
그때는 선택기 타입을 `FileType.any` 로 바꾸고 확장자를 앱에서 검사하는 쪽으로 돌린다.

### B-6 iOS 번들 ID 와 Keychain 엔타이틀먼트 (#86)

- 번들 ID 가 업스트림 잔재인 `com.omilocal.omiLocal` 로 남아 있다. #86 범위 밖이라 손대지 않았다.
  **별도 이슈로 분리할지 판단이 필요하다.**
- `Runner.entitlements` 에 `keychain-access-groups` 를 넣을지도 미정이다.
  엔타이틀먼트는 서명될 때만 적용되므로 추측으로 넣지 않았다.
  `-34018` 이 실제로 나면 그때 후속 이슈를 연다.
→ **절차: §10-1, §10-2.**

### B-7 autoConnect 재연결 30초의 비보장성 (#56)

"범위 복귀 시 30초 내 재연결" 은 `08-dev-workflow.md` §5 체크리스트에 있지만
**실기기 측정치이지 코드가 보장하는 값이 아니다.** 무장 이후의 지연은 안드로이드의 autoConnect
스케줄링이 정하고, Doze·화면 꺼짐 상태에서는 30초를 넘길 수 있다.
또 유예창(5분)을 넘긴 긴 이탈은 이 범위에서 복구되지 않는다.
→ **절차: §2.4 / §6.3.** 실측 초를 모아 두면 §5 체크리스트의 문구를 고칠 근거가 된다.

---

## 부록 C — 확인 후 할 일

1. 각 항목의 "캡처" 가 지정한 PR 코멘트에 결과를 붙인다. **한국어로 써도 된다**(`08-dev-workflow.md` §1).
2. 실패한 항목은 그 PR 에 코멘트하고, 새 동작 변경이 필요하면 **새 이슈**를 연다
   (`07-backlog.ko.md` 형식을 따른다).
3. 부록 B 의 항목은 데이터를 모으는 것 자체가 목적이다. **"확인함" 이 아니라 관측값**을 남긴다.
4. `08-dev-workflow.md` §5 의 짧은 스모크 체크리스트는 **PR 마다 붙이는 요약본**이고,
   이 문서는 **한 번에 도는 전체 런북**이다. 둘 중 어느 쪽이 틀리면 같은 PR 에서 함께 고친다.
