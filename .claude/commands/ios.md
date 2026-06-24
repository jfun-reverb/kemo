---
description: iOS 앱 개발 컨텍스트 로드 — Capacitor 하이브리드 앱(ios-app/) 작업 시작
---

iOS 앱 개발 세션을 시작한다. 아래 컨텍스트를 숙지하고 "iOS 개발자"로서 작업하라.

## 대상
- `ios-app/` — 인플루언서 웹앱(`dev/`)을 **Capacitor**로 감싼 iOS 앱. `feature/ios-app` 브랜치, **개발서버**, **운영 무영향**, **커밋 안 함**(실험·앱스토어 미등록).
- 디자인 레이어: `ios-app/www/ios-theme.css` — 웹 스타일 위에 덧씌우는 iOS 테마. 디자인 변경은 여기만.

## 빌드·실행 순서
1. `cd dev && bash build.sh` (dev → 루트 `index.html`)
2. `cd ../ios-app && bash sync-ios.sh` (루트 index.html → `www/` 복사 + `ios-theme.css`·`native-push.js` 주입)
3. `npx cap copy ios` (`www/` → `ios/App/App/public/`)
4. 테마 변경 시 `cp www/ios-theme.css ios/App/App/public/ios-theme.css`
5. `xcodebuild -project ios/App/App.xcodeproj -scheme App -configuration Debug -destination 'platform=iOS Simulator,id=<SIM_ID>' -derivedDataPath ios/App/build build`
6. `xcrun simctl install <SIM_ID> ios/App/build/Build/Products/Debug-iphonesimulator/App.app && xcrun simctl terminate <SIM_ID> com.reverbjp.app; xcrun simctl launch <SIM_ID> com.reverbjp.app`
- 시뮬레이터 확인: `xcrun simctl list devices booted` (iPhone 17 계열). `ios-theme.css`만 바꿨으면 1·2단계 생략하고 cp + xcodebuild 가능.

## 캡처
- `xcrun simctl io <SIM_ID> screenshot /tmp/x.png` → 스샷이 커서 Read 한도 초과 → `sips -Z 1400 /tmp/x.png --out /tmp/x_s.png` 후 `/tmp/x_s.png` Read.
- **로그인 화면 캡처**: `www/index.html`에 임시 자동로그인 스크립트 주입(테스트 계정 `sakura.test@reverb.jp` / `test1234`, 로그인 후 `location.reload()` → 원하는 화면으로 `tabNav`/`navigate`) → 빌드·캡처 → **반드시 `bash sync-ios.sh`로 원복**하고 `grep -c sakura.test www/index.html` 잔존 0 확인.

## iOS 전용 UI 분리 패턴 (핵심)
요소는 `dev/index.html`에 두고: `components.css`에서 `display:none`(웹 숨김) + `ios-theme.css`에서 표시(앱만 오버라이드). JS 토글은 `window.Capacitor?.isNativePlatform()` 가드. 선례: GNB 알림버튼·바텀탭바(`.ios-tabbar`)·GNB 화면제목(`.gnb-title`)·햄버거 제거(`.gnb-burger{display:none}`).

## ⚠️ 사고 이력 (반복 금지)
- **sync-ios.sh 자산명 주석 금지**: dev 코드의 주석/문자열에 `"ios-theme.css"`·`"native-push.js"`를 쓰면 `sync-ios.sh`의 `not in h` 중복검사가 오판 → `<link>`/`<script>` 주입 누락 → iOS 테마 통째 미적용(safe-area 깨짐). 검사는 정확한 태그로. (2026-06-23)
- Capacitor는 웹뷰 `console.log`를 OSLog로 안 보냄 → 화면 디버그 박스로 진단. `simctl` tap/swipe 미지원·`osascript` 접근성 권한 막힘 → 제스처 재현은 사용자 협조.
- 안전영역 `env(safe-area-inset-*)`, 네비바 높이 변수 `--ios-nav-h`.

## 게이트
- 빌드/커밋 전 `reverb-reviewer` 호출. DB·Auth·RLS·마이그레이션 변경 시 `reverb-supabase-expert`.

먼저 메모리 `project_ios_hybrid_app.md`(전체 이력·구조·사고)와 현재 `ios-app/` 상태를 확인하고 작업을 시작하라.

$ARGUMENTS
