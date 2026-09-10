# ListenUp 베타 설치 안내

이 ListenUp 베타는 Apple의 Developer ID 서명과 공증을 받지 않았습니다. 신뢰할 수 있는 GitHub Release에서 직접 받은 파일인지 확인한 뒤 설치해 주세요.

## 설치

1. 내려받은 `ListenUp-*-arm64-unsigned.dmg`를 엽니다.
2. `ListenUp.app`을 `Applications` 폴더로 끌어다 놓습니다.
3. 응용 프로그램 폴더에서 ListenUp을 실행합니다.
4. macOS가 개발자를 확인할 수 없다고 표시하면 창을 닫습니다.
5. **시스템 설정 → 개인정보 보호 및 보안**을 엽니다.
6. 보안 영역에서 ListenUp의 **확인 없이 열기**를 누릅니다.
7. 암호 또는 Touch ID로 승인한 뒤 다시 **열기**를 누릅니다.

이 예외를 승인한 뒤에는 일반적으로 응용 프로그램 폴더에서 바로 실행할 수 있습니다. 새 베타로 교체하면 macOS가 다시 확인을 요청할 수 있습니다.

## 지원 환경

- Apple Silicon Mac
- macOS 15 이상
- 사용자가 발급한 OpenAI API 키
- 마이크 녹음 시 마이크 권한
- 앱 소리 녹음 시 화면 및 시스템 오디오 기록 권한

## 다운로드 확인

Release에 첨부된 `.sha256` 파일과 내려받은 DMG의 체크섬을 비교할 수 있습니다.

```sh
shasum -a 256 ListenUp-*-arm64-unsigned.dmg
```

## 제거

OpenAI API 키까지 지우려면 먼저 ListenUp 설정에서 **키 삭제**를 실행합니다. 그다음 `/Applications/ListenUp.app`을 휴지통으로 옮깁니다.

사용자가 선택한 세션 폴더의 녹음, 전사, 요약은 앱을 제거해도 유지됩니다.

