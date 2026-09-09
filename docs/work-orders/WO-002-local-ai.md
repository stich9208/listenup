# WO-002 — 로컬 모델·전사·목적별 요약

담당 모델: Luna / Medium · 소유 경로: `Sources/ListenUpAI`, 대응 테스트, `Benchmarks` · 공용 계약 수정 금지

## 목표

WhisperKit 1.1.0과 MLX Swift LM 3.31.4의 실제 공개 API로 로컬 전사·Qwen3 4B 요약을 연결한다. 가중치는 앱에 포함하지 않고 앱 관리 폴더에 사용자가 별도 설치한다. 음성·텍스트를 외부 서비스로 전송하는 경로는 구현하지 않는다.

## 완료 조건

- STTProvider/SummaryProvider 및 mock이 Sendable 비동기 계약을 갖는다.
- ModelCatalog/ModelManager가 Whisper 626MB 후보와 Qwen3 4B만 제공하고, 상태·진행률·취소·재개·SHA-256 검증·staging→active 활성화·삭제를 제공한다.
- 다운로드 URL과 파일 목록은 catalog data로 분리하며 세션 데이터 전송이 없다. Range/ETag 불일치 시 해당 partial만 안전하게 재시작한다.
- WhisperKit adapter는 앱이 설치한 로컬 모델 경로를 사용하고 한국어 hint와 segment timestamp를 Domain 결과로 변환한다.
- Qwen adapter는 로컬 디렉터리에서 model/tokenizer를 로드하며 강의/회의 JSON 프롬프트, 4~6K 입력 청크, 최대 1,500 출력 토큰, 근거 ID 검증을 제공한다.
- STT 모델 해제 후 요약 모델을 로드하도록 LocalProcessingCoordinator가 직렬 실행하며 새 녹음 우선 취소 지점을 둔다.
- mock 테스트가 목적별 schema 차이, 존재하지 않는 근거 거부, 부분 실패 partial, stale input hash, 자동 cloud fallback 부재를 검증한다.

## 제한

모델 파일은 다운로드하거나 저장소에 넣지 않는다. 실제 품질·속도 수치는 모델 설치와 사용자 샘플 없이 주장하지 않는다. Package.swift·Domain·Storage·Audio·UI·docs는 수정하지 않는다.

## 검증

`rtk swift test --filter ListenUpAITests`. 실제 패키지 API까지 컴파일한다.
