# 로컬 모델 통합 smoke — 2026-09-09

이 기록은 Apple M1 Pro 16GiB, macOS 26.6.2에서 ListenUp의 고정 WhisperKit/Qwen 실행 경로가 실제 로컬 가중치를 열고 결과를 만드는지 확인한 개발 smoke다. 짧은 합성 입력이므로 실제 강의·회의 품질이나 60분 처리 성능의 합격 판정이 아니다.

## 입력과 모델

- 합성 음성: macOS Yuna TTS로 만든 14.741초, 16kHz mono Int16 WAV
- 음성 문장: 시험 일정 논의, 지민의 금요일 화면 초안 약속, 모델 속도 미측정, 다음 회의 날짜 미정
- 고정 가중치: `.build/validation-models/whisper`, `.build/validation-models/whisper/tokenizer`, `.build/validation-models/qwen`
- 모든 manifest 파일의 byte count와 SHA-256 확인
- 전체 크기: 2,910,072,539 bytes
- 검증 사본은 `.build/` 아래의 개발 전용 파일이며 앱 bundle에 포함하지 않음

## 관찰 결과

| 실행 | 관찰 | 벽시계·메모리 |
| --- | --- | --- |
| 첫 전체 실행 | Whisper가 4문장을 인식했지만 특수 토큰이 노출됨. Qwen은 SwiftPM 실행 파일에 MLX metallib가 없어 시작 실패 | 267.81초, host max RSS 461,733,888 bytes. MLX 실패 전 값이므로 Qwen 메모리 수치가 아님 |
| Xcode shader 수정 후 전체 실행 | Xcode로 `default.metallib` 생성. Whisper 특수 토큰 제거와 4문장 전사 확인. Qwen 로딩·생성 성공, 모델의 `id:"UUID1"` 때문에 당시 Domain decode 실패 | 264.81초, peak footprint 약 3.35GB |
| 첫 Qwen-only 고정 전사 | production DTO decoder가 UUID를 앱에서 생성. 지민/금요일 약속을 action으로 유지하고 미측정 속도와 미정 회의 날짜를 open issue/uncertainty로 유지 | 19.11초, peak footprint 약 3.415GB |
| held-out Qwen-only 전사 | 수연/화요일 약속 외에도 제안·미실행·미정 문장을 action으로 잘못 만들고 근거 없는 정규 날짜를 생성 | 24.04초, peak footprint 약 3.486GB. 의미 안전성 실패 |
| held-out + production guard | 명시적 약속 1개를 근거 문장 그대로 action으로 유지. 잘못 생성한 3개 후보는 근거 ID가 있는 `[확인 필요]` uncertainty로 이동. 근거 없는 정규 날짜 없음 | 15.94초, peak footprint 약 3.482GB |
| 네트워크 차단 전체 순차 재실행 | sandbox에서 네트워크를 거부한 채 Whisper 4문장 전사 → Qwen production summary 완료. action 1개와 원문 기반 `[확인 필요]` 2개 | 260.12초, peak footprint 3,332,492,216 bytes. Core ML 준비가 대부분을 차지 |

held-out 실패 뒤 production 후처리는 action을 근거 문장의 명시적 약속으로 보수적으로 제한하고, 기준일 없는 `dueNormalized`는 `nil`로 강제한다. 거부한 후보는 근거 ID와 함께 `[확인 필요]` uncertainty로 이동한다. 모델 원출력은 held-out 4문장을 모두 action으로 잘못 분류했고 owner/due 필드도 비워 두었으므로, 위 결과는 4B 모델 단독의 구조 추출 품질 합격이 아니라 앱의 보수적 guard가 작동했다는 증거다. 확정 action은 원문 문장 전체를 보존하며, 모호한 owner는 구조 필드에 넣지 않는다. 이 좁은 문법 규칙은 환각 위험을 줄이는 대신 간접적으로 표현한 유효한 요청을 놓칠 수 있으므로 사용자가 `[확인 필요]` 항목을 검토해야 한다.

## 아직 확인하지 않은 항목

- 실제 마이크·선택 앱 시스템 오디오 권한과 녹음 품질
- 두 입력 동시 녹음 중 15초 재생과 피드백 방지
- 실제 한국어 강의·회의 CER, 전문용어, 숫자, 동시 발화
- 60분 처리 시간, 반복 warm 실행, memory pressure, 2시간 저장·복구
- 앱 UI 자동화 smoke와 실제 Notion 테스트 페이지 붙여넣기

UI 자동화 도구로 빌드 앱을 열려 한 시도는 ScreenCaptureKit `SCStreamError -3811`로 실패했으므로 UI 확인 완료로 세지 않는다.
