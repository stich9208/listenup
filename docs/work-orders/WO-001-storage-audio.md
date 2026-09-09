# WO-001 — 저장·녹음·재생 기반

담당 모델: Luna / Medium · 소유 경로: `Sources/ListenUpStorage`, `Sources/ListenUpAudio`, 대응 테스트 · 공용 계약 수정 금지

## 목표

Domain 타입을 사용해 세션 폴더 생성·원자 저장·리비전 보존과 파일 기반 마이크 녹음/가져오기/재생을 구현한다. 시스템 오디오 캡처는 ScreenCaptureKit 실제 권한과 필터를 제공하되 사용자 동의 없는 녹음을 시작하지 않는다.

## 완료 조건

- SessionStore actor가 안전한 폴더명, 상대 경로, temp→rename 원자 저장, JSONL journal, session.json 재열기를 제공한다.
- annotation/transcript/summary는 불변 revision 파일로 커밋하고 기존 파일을 덮어쓰지 않는다.
- AVAudioEngine 마이크 캡처가 5초 단위 CAF 조각을 `.partial` 후 확정하며 callback에서 JSON/네트워크 작업을 하지 않는다.
- ScreenCaptureKit은 현재 프로세스 오디오 제외 설정과 앱 목록/선택 캡처 인터페이스를 제공한다.
- ReplayEngine은 확정 조각만 사용하고 recording head와 독립된 playhead, 15초 뒤로/seek/stop/live 복귀를 제공한다.
- 로컬 파일 가져오기는 원본을 복사하고 원본 파일을 수정하지 않는다.
- 합성 fixture 기반 테스트가 경로 탈출 거부, 왕복 저장, 리비전 보존, playhead 독립성, 손상 파일 오류를 검증한다.

## 제한

실제 마이크 또는 화면 녹음 권한을 자동 요청하거나 주변음을 녹음해 테스트하지 않는다. UI·AI·Package.swift·Domain·docs는 수정하지 않는다. 실제 기기 수동 시험이 남으면 명시한다.

## 검증

`rtk swift test --filter ListenUpStorageTests` 및 `rtk swift test --filter ListenUpAudioTests`.
