# ListenUp

ListenUp은 macOS에서 마이크와 사용자가 선택한 앱의 소리를 녹음하고, OpenAI API로 전사와 요약을 생성하는 SwiftUI 앱입니다. 오디오, 전사, 요약, Markdown 내보내기는 사용자가 선택한 로컬 폴더에 저장됩니다.

## 현재 구현

- 마이크, 선택 앱 시스템 오디오, 두 소스 동시 녹음과 5초 단위 확정 파일
- 녹음 중 확정 구간 15초 뒤로 듣기, 정지, 실시간 위치 복귀
- 기존 오디오 가져오기와 저장된 세션 다시 열기
- journal/checkpoint 기반 세션 저장과 중단 상태 복구
- OpenAI `gpt-transcribe` 전사와 `gpt-5.6-luna` 요약
- 설정에서 저비용 전사 모델과 품질 우선 요약 모델 선택
- 완료된 전사가 있으면 재전사하지 않고 요약에 재사용
- 강의와 회의에 맞춘 서로 다른 요약 구조와 전사 근거 연결
- 전체 전사, 목적별 요약, 합본 Markdown 저장과 서식 있는 클립보드 복사

로컬 Whisper와 Qwen 가중치 및 추론 라이브러리는 앱에서 제거했습니다. OpenAI API 키는 macOS 키체인에 저장하며 세션 파일에는 기록하지 않습니다. 전사할 오디오와 요약할 전사문은 처리할 때 OpenAI API로 전송됩니다. Responses API 요청은 `store: false`로 보냅니다.

## 빌드와 실행

필요 환경은 Apple Silicon Mac, macOS 15 이상, Swift 6, Xcode입니다. 외부 Swift 패키지 의존성은 없습니다.

```sh
./scripts/build-app.sh Release
open dist/ListenUp.app
```

빌드 스크립트는 실행 파일과 Info.plist로 앱 번들을 만들고 로컬 실행용 ad-hoc 서명을 적용합니다. Developer ID 서명과 notarization은 포함하지 않습니다.

테스트는 다음 명령으로 실행합니다.

```sh
swift test
```

## 사용 순서

1. 앱 설정이나 새 녹음 화면에서 OpenAI API 키를 입력해 키체인에 저장하고 **연결 확인**을 실행합니다.
2. 세션 저장 폴더를 선택합니다.
3. 새 녹음에서 제목, 용도, 입력 소스를 정합니다. 시스템 오디오는 실행 중인 앱 하나를 선택해야 합니다.
4. 녹음을 끝내거나 기존 오디오를 가져온 뒤 현재 결과에서 **OpenAI 처리 시작**을 누릅니다.
5. 결과를 세션의 `exports/` 폴더에서 열거나 클립보드로 복사해 Notion에 붙여넣습니다.

긴 오디오는 앱에서 60초 단위 16kHz mono WAV로 변환해 순서대로 전송합니다. 전사 리비전이 완전하게 저장된 세션에서는 요약을 다시 만들 때 기존 전사를 사용하므로 STT 비용이 다시 발생하지 않습니다.

마이크와 시스템 오디오는 macOS 권한이 필요합니다. 시스템 오디오는 선택한 앱 단위이며 브라우저 탭 하나만 분리한다고 보장하지 않습니다.

현재 API 전환 설계와 검증 항목은 [OpenAI API 전환 문서](docs/OPENAI_API_MIGRATION.md)에 있습니다. 기존 로컬 모델 평가 문서는 결정 기록으로 보존합니다.

첫 베타는 Apple Developer Program 없이 미서명 DMG로 배포합니다. 패키징과 향후 서명·공증 전환 계획은 [배포 설계 문서](docs/DISTRIBUTION_PLAN.md), 사용자 설치 과정은 [미서명 베타 설치 안내](docs/UNSIGNED_INSTALL.md)에 있습니다.

미서명 베타 DMG는 다음 명령으로 생성합니다.

```sh
./scripts/package-unsigned-dmg.sh
```
