# LibreOmi 설계 요약 (프로젝트 소유자용)

작성일 2026-09-05. 영어 설계 문서(`docs/`)의 결론과, 개발자 본인이 직접 알고 있어야
하거나 직접 해야 하는 일만 한국어로 정리한 것입니다.

## 1. 결론

**omibutfree 를 Flutter 그대로 포크해서 Android 타깃을 추가한다. 네이티브(Kotlin) 재작성은 하지 않는다.**

근거는 세 가지입니다.

- omibutfree 가 "iOS 전용"인 이유는 코드가 아니라 저자가 `android/` 폴더를 지웠기
  때문입니다. `.metadata` 에 android 플랫폼 생성 기록이 남아 있고, `pubspec.lock` 의
  모든 플러그인(BLE, Opus, sherpa-onnx, 녹음, SQLite, 알림 등)이 Android 구현체를
  이미 갖고 있습니다. Dart 코드에는 iOS 분기가 한 줄도 없습니다.
- "플러터를 써도 iOS/Android 구현체가 다르다"는 우려는 맞지만, 그 차이는 전부
  플러그인 안에 있습니다. 이 앱이 직접 다뤄야 하는 Android 고유 사항은 딱 두 가지,
  **BLE MTU 512 요청**과 **포그라운드 서비스**입니다. 공식 Omi 앱도 Flutter 이고 같은
  방식(`flutter_foreground_task`, MTU 512)으로 해결했음을 소스에서 확인했습니다.
- 네이티브 재작성은 약 9,300줄을 다시 쓰는 일이고, 얻는 것은 개인용 클라이언트에
  필요 없는 수준의 백그라운드 제어권뿐입니다.

## 2. 업스트림에서 발견한 문제 (포팅 시 반드시 고칠 것)

1. MTU 협상 없음 → Android 에서는 오디오 패킷(83바이트)이 잘려 아무것도 안 됨.
2. 백그라운드 전략 없음 → Android 는 몇 분 안에 프로세스가 얼어붙음.
3. SD 카드 동기화 후 음성인식 부분이 **스텁**(플레이스홀더 문자열 반환).
4. 로컬 음성인식(sherpa/whisper) 세그먼트에 타임스탬프가 0 → 대화 길이 표시 안 됨.
5. Whisper 모드는 VAD 없이 3초마다 자름 → 단어가 잘림.
6. `AppProvider` 1,400줄짜리 신(god) 객체, 요약 파이프라인 중복, 테스트 0개.
7. BLE 읽기/쓰기마다 서비스 재탐색, 구독 누수, 싱글톤 dispose 후 복구 불가.
8. API 키 평문 저장, 알림 ID 를 `String.hashCode` 로 생성, 존재하지 않는 사운드 리소스 참조.

전체 목록은 `docs/01-upstream-analysis.md` §5.

## 3. 개발 순서

| 단계 | 목표 | 누가 주도하면 좋은가 |
|------|------|----------------------|
| M0 | 포크 정리, 툴체인 고정, CI, 이슈 등록 | 에이전트 |
| M1 | Android 에서 Omi → Deepgram → 자막 (포그라운드) | **본인** (권한 다이얼로그·기기 동작은 사람이 봐야 함) |
| M2 | 화면 꺼져도 몇 시간 동작 (포그라운드 서비스, 재연결, 배터리 최적화 제외) | **본인** + 에이전트 |
| M3 | `AppProvider` 분해, 인터페이스 도입, 가짜 기기 리플레이 테스트 | 에이전트 |
| M4 | 온디바이스 인식 (isolate, VAD, 타임스탬프, 한국어 모델) | 에이전트 |
| M5 | SD 카드 동기화 완성 (파일 음성인식) | 에이전트 |
| M6 | 설정 확장, i18n, 서명·릴리스 | 에이전트 |

M4 와 M5 는 M3 이후 병렬 가능. 상세 완료 기준은 `docs/06-roadmap.md`, 한국어 이슈는
`docs/07-backlog.ko.md` (39개), 등록 스크립트는 `scripts/create_issues.py`.

## 4. 본인이 직접 해야 하는 일

환경:
- Flutter stable 설치 (`mise use -g flutter@stable` 또는 `brew install --cask flutter`). 현재 이 맥에는 Flutter 가 없습니다.
- **JDK 17** 설치. 현재 JDK 25 만 있는데 Android Gradle Plugin 8.x 가 17 을 요구합니다.
- Android SDK (platform 35, build-tools, cmdline-tools) 와 `flutter doctor --android-licenses`.
- **실제 Android 폰** (BLE 는 에뮬레이터 불가). 가능하면 삼성 1대 + 픽셀 1대, Android 12 이상.
- Omi 기기 펌웨어 버전 확인 (기기 설정 페이지에 표시됨). 버튼 이벤트 값과 SD 카드 프로토콜은 omibutfree 에서 관찰된 값이라 본인 펌웨어로 재검증이 필요합니다.

계정/키:
- Deepgram API 키 (가입 시 무료 크레딧), OpenAI API 키. 앱 안에서만 입력하고 저장소에는 절대 커밋하지 않습니다.
- GitHub 저장소 생성 (`gh` 는 `johnpark-bin` 계정으로 로그인되어 있음). 생성 후 `scripts/create_issues.py --repo <owner>/LibreOmi` 실행.

결정할 것:
- 앱 ID: 임시로 `org.libreomi.app`. 도메인이 있으면 그에 맞게.
- 배포 채널: GitHub Release APK 만 할지, Play 내부 테스트까지 할지 (M6).
- 업스트림 git 히스토리 보존 여부 (LO-01).
- 라이선스는 MIT 유지 + 업스트림 저작권 표기 (변경 여지 없음).

## 5. 언어 정책

- 코드, 주석, 커밋 메시지, `docs/`: 영어.
- 이슈·PR: 한국어 (PR 본문 마지막에 영어 한 줄 요약). 템플릿은 `.github/` 에 준비됨.
- 에이전트가 본인에게 보고할 때: 한국어.
- `AGENTS.md`(= `CLAUDE.md`) 에 이 규칙과 문서 지도가 있어 다른 구독 도구(Codex, Cursor 등)도 같은 규약으로 움직입니다.

## 6. 리스크

- 제조사 배터리 관리(삼성/샤오미)가 포그라운드 서비스를 죽일 수 있음 → M2 에서 배터리 최적화 제외 + 안내 페이지. 그래도 안 되면 네이티브 Kotlin 서비스가 후속 옵션.
- sherpa-onnx 네이티브 라이브러리로 APK 가 ABI 당 15~20MB 커짐 → arm64 전용 개발 빌드, 릴리스는 split APK.
- `flutter_blue_plus` 2.x 가 API 를 바꿨음 → 업스트림이 쓰는 1.36.x 에 고정하고 업그레이드는 별도 이슈로.

## 7. 다음 행동

1. Flutter / JDK 17 / Android SDK 설치, `flutter doctor` 클린.
2. GitHub 에 `LibreOmi` 저장소 생성, 이 디렉터리 커밋, `scripts/create_issues.py` 실행.
3. LO-01~LO-05 를 에이전트에 위임.
4. LO-10~LO-12 는 폰을 손에 들고 직접 진행 (MTU 로그 확인이 첫 관문).
