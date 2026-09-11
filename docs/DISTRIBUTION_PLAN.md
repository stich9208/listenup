# ListenUp 배포 설계

## 1. 현재 배포 결정

ListenUp은 Swift 앱을 유지하고, 첫 베타는 **Apple Developer Program 없이 만든 미서명·미공증 DMG**로 GitHub Releases에 배포한다.

DMG는 앱을 옮기기 쉽게 포장하는 파일이다. 미서명 상태를 신뢰된 앱으로 바꾸지는 않으므로, 사용자는 최초 실행 때 macOS의 보안 설정에서 ListenUp을 직접 허용해야 한다. 이 제약을 설치 안내와 Release 본문에 명확하게 표시한다.

Developer ID 서명과 Apple 공증은 일반 사용자를 대상으로 공개 배포할 시점에 선택적으로 도입한다. 현재 베타를 만들거나 사용하는 데 Apple 유료 개발자 계정은 필요하지 않다.

- [Apple: 미확인 개발자의 앱 열기](https://support.apple.com/guide/mac-help/open-an-app-by-overriding-security-settings-mh40617/mac)
- [Apple: Developer ID로 Mac 소프트웨어 서명](https://developer.apple.com/developer-id/)
- [GitHub Release 관리](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)

## 2. 배포 대상과 현재 상태

| 항목 | 베타 기준 |
|---|---|
| 지원 기기 | Apple Silicon Mac |
| 최소 OS | macOS 15 이상 |
| 앱 크기 | 약 4.5MB |
| Bundle ID | `app.listenup.local` 유지 |
| 코드 서명 | 로컬 실행을 위한 ad-hoc 서명 |
| Apple 공증 | 하지 않음 |
| 설치 파일 | `ListenUp-{version}-arm64-unsigned.dmg` |
| 업데이트 | GitHub Release에서 새 DMG를 받아 덮어쓰기 |
| 사용자 데이터 | 사용자가 선택한 로컬 세션 폴더에 유지 |
| OpenAI API 키 | macOS 키체인에 저장하며 DMG에 포함하지 않음 |

베타 기간에는 Bundle ID를 변경하지 않는다. Bundle ID 변경은 키체인 접근과 macOS 권한 동작을 다시 검증해야 하므로 Developer ID를 적용할 공개 배포 시점에 함께 결정한다.

## 3. 사용자가 경험하는 설치 과정

1. GitHub Release에서 DMG를 내려받는다.
2. DMG를 열고 `ListenUp.app`을 `Applications`로 끌어다 놓는다.
3. 응용 프로그램 폴더에서 ListenUp을 처음 실행한다.
4. macOS가 개발자를 확인할 수 없다고 차단하면 `시스템 설정 → 개인정보 보호 및 보안`으로 이동한다.
5. 보안 영역에서 ListenUp의 **그래도 열기**를 선택하고 암호 또는 Touch ID로 승인한다.
6. 앱에서 마이크와 화면 및 시스템 오디오 권한을 별도로 승인한다.

이 과정에서 `xattr`로 격리 속성을 일괄 제거하거나 Gatekeeper를 끄도록 안내하지 않는다. macOS가 제공하는 앱 단위 예외 기능만 사용한다.

조직에서 관리하는 Mac은 관리 정책에 따라 미서명 앱 실행이 막힐 수 있다. 이 경우 베타 DMG를 사용할 수 없으며 Developer ID 서명·공증판이 필요하다.

## 4. 릴리스 산출물

`./scripts/package-unsigned-dmg.sh`는 다음 파일을 만든다.

```text
release/
  ListenUp-0.2.0-arm64-unsigned.dmg
  ListenUp-0.2.0-arm64-unsigned.dmg.sha256
```

DMG에는 다음 항목을 넣는다.

```text
ListenUp.app
Applications -> /Applications
처음 실행 안내.txt
```

SHA-256 파일은 사용자가 받은 DMG가 GitHub Release에 올린 원본과 같은지 확인하는 용도다.

## 5. 미서명 DMG 생성

프로젝트 루트에서 다음 명령을 실행한다.

```sh
./scripts/package-unsigned-dmg.sh
```

버전은 `AppResources/Info.plist`의 `CFBundleShortVersionString`을 사용한다. 배포 버전을 변경할 때는 Info.plist를 먼저 수정해 앱 내부 버전과 DMG 파일 이름이 항상 일치하게 한다.

스크립트는 다음 순서로 실행된다.

1. `scripts/build-app.sh Release`로 arm64 Release 앱을 만든다.
2. 앱의 ad-hoc 서명을 검증한다.
3. 앱, Applications 링크, 최초 실행 안내를 임시 스테이징 폴더에 배치한다.
4. `hdiutil`로 압축 DMG를 만든다.
5. DMG를 검증하고 SHA-256 파일을 생성한다.

`release/`와 `dist/`는 Git에 올리지 않는다. GitHub Release에는 생성된 DMG와 SHA-256 파일만 직접 첨부한다.

## 6. GitHub Release 절차

첫 배포는 prerelease로 만든다.

1. 배포할 커밋에서 전체 테스트를 실행한다.
2. Info.plist 버전과 Release 버전을 맞춘다.
3. 미서명 DMG 생성 스크립트를 실행한다.
4. 깨끗한 macOS 사용자 계정 또는 다른 Mac에서 최초 설치를 시험한다.
5. `v0.2.0-beta.1`처럼 베타 태그를 만든다.
6. GitHub prerelease에 DMG와 SHA-256 파일을 첨부한다.
7. Release 본문 맨 위에 **Apple의 서명과 공증을 받지 않은 베타**라고 표시한다.
8. [최초 실행 안내](UNSIGNED_INSTALL.md), 지원 환경, 알려진 문제를 함께 적는다.

저장소가 비공개라면 GitHub에 로그인하고 접근 권한이 있는 사용자만 Release 파일을 받을 수 있다.

## 7. 배포 전 검수

### 앱과 DMG

- `swift test` 통과
- Release 앱 실행과 아이콘 확인
- `codesign --verify --deep --strict dist/ListenUp.app` 통과
- `hdiutil verify` 통과
- SHA-256 재계산 결과 일치
- DMG에서 Applications 폴더로 드래그 설치
- 미확인 개발자 차단 후 **그래도 열기**로 최초 실행

### 녹음과 권한

- 마이크만 녹음
- 앱 소리만 녹음
- 마이크와 앱 소리 동시 녹음
- 화면 기록 권한 승인 후 앱 목록 새로고침
- 다른 창으로 이동했을 때 녹음 중 표시 유지
- 앱을 종료하거나 녹음을 중단했을 때 파일 복구

### 데이터와 OpenAI

- API 키가 앱 번들, DMG, 로그, 세션 파일에 없는지 확인
- 키체인 저장·연결 확인·삭제
- 인증 오류와 네트워크 오류 안내 확인
- 전사 완료 후 요약만 다시 생성할 때 기존 전사를 재사용
- 회의와 강의 요약 형식 확인
- 화면 내용과 클립보드 복사 결과 일치
- 결과가 사용자가 선택한 로컬 폴더에만 저장되는지 확인

### 업데이트

- 기존 앱 위에 새 버전 덮어쓰기
- 기존 세션 폴더 다시 열기
- 기존 Keychain API 키 접근 확인
- 마이크 및 화면 기록 권한이 유지되는지 확인

ad-hoc 서명은 빌드마다 코드 정체성이 달라질 수 있으므로 업데이트 후 macOS가 일부 권한을 다시 요청할 가능성이 있다. 이 항목은 미서명 베타의 알려진 제약으로 Release에 표시한다.

## 8. 앱 제거와 API 키

사용자가 `ListenUp.app`을 휴지통으로 옮길 때 앱 코드는 실행되지 않으므로 키체인 항목을 자동으로 삭제할 수 없다.

제거 전 앱 설정에서 **키 삭제**를 실행한 다음 `/Applications/ListenUp.app`을 휴지통으로 옮긴다. 사용자가 선택한 세션 폴더의 녹음, 전사, 요약 파일은 자동으로 삭제하지 않는다.

정식 배포 전에는 API 키, 저장 폴더 bookmark, UserDefaults를 한 번에 지우는 **API 키 및 앱 설정 삭제** 기능을 추가한다.

## 9. 향후 서명·공증 전환

일반 사용자를 대상으로 설치 안내 없이 배포할 필요가 생기면 Apple Developer Program에 가입하고 다음 작업을 진행한다.

1. 최종 Bundle ID와 App ID 확정
2. Developer ID Application 인증서 발급
3. Hardened Runtime과 필요한 entitlement 적용
4. 앱과 DMG 서명
5. Apple 공증과 ticket staple
6. Gatekeeper 및 업데이트 권한 회귀 검증

이 단계에서도 앱 구조, Swift 코드, 로컬 저장 방식과 GitHub Release 채널은 유지할 수 있다. 패키징 과정에 서명과 공증 단계만 추가한다.

## 10. 남은 배포 순서

- [x] 미서명 DMG 생성 스크립트 구현
- [x] 최초 실행 안내 문서 작성
- [x] DMG 생성, 내부 구성, 체크섬 검증
- [ ] 별도 macOS 사용자 계정에서 최초 실행과 권한 시험
- [ ] 베타 버전과 Release notes 확정
- [ ] 개인 GitHub 계정에서 prerelease 생성
- [ ] 실제 녹음·전사·요약 베타 테스트
- [ ] 공개 대상이 넓어질 때 Developer ID 도입 여부 재검토
