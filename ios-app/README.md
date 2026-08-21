# REVERB JP — iOS 하이브리드 앱 (실험용)

기존 인플루언서 웹앱(`dev/`)을 그대로 감싸 만든 **iOS 앱**입니다.
[Capacitor](https://capacitorjs.com)로 웹 화면을 iOS 앱 껍데기에 넣고, 그 위에
iOS 네이티브 느낌의 디자인 레이어(`www/ios-theme.css`)를 덧입혔습니다.

> ⚠️ **운영 웹 무영향**: 이 폴더(`ios-app/`)만 손대며, 운영 사이트(`globalreverb.com`)
> 코드(`dev/`)는 바꾸지 않습니다. 앱은 별도 산출물입니다.

---

## 지금 상태

- 앱 이름: **REVERB JP**, 앱 식별자: `com.reverbjp.app`
- 보고 있는 서버: **운영서버(production)** — 2026-08-21 전환
  🔴 **앱에서 하는 동작이 실제 서비스 데이터에 그대로 들어갑니다.** 응모·응모 취소·메시지
  발송·프로필 수정이 진짜 행으로 쌓이고, 관리자에게 실제 알림 메일이 나갑니다.
  테스트로 눌러볼 때는 **감사용 계정**(`influencers.is_audit=true`)을 쓰세요 — 그 계정의
  응모·결과물은 운영 통계·엑셀·광고주 보고에서 제외됩니다.
- iOS화된 화면: 홈 / 캠페인 목록(세그먼트 컨트롤) / 로그인 / 마이페이지(응모이력)
- 적용된 iOS 디자인: 안전영역(노치·홈바), 애플 시스템 폰트, 밝은 네비게이션 바 +
  어두운 상태바, iOS 그룹 배경 + 흰 카드, 캡슐 필터 칩, flat 버튼, 바텀시트 그래버 핸들,
  iOS 연회색 채움 입력 필드

---

## 폴더 구조

```
ios-app/
├── capacitor.config.json   # 앱 식별자·이름·배경색 설정
├── www/                    # 앱 안에 들어가는 웹 화면
│   ├── index.html          # dev 빌드 산출물 복사본 (sync-ios.sh가 생성)
│   └── ios-theme.css       # ★ iOS 디자인 레이어 (여기를 고치면 디자인이 바뀜)
├── sync-ios.sh             # dev 빌드 → www 복사 + iOS 테마 주입
├── ios/                    # Xcode 프로젝트 (Capacitor가 생성)
└── package.json
```

---

## 앱을 다시 빌드·실행하는 법

웹 화면(`dev/`)이나 iOS 테마(`www/ios-theme.css`)를 고친 뒤:

```bash
# 1) 인플루언서 웹앱 빌드 (dev → 루트 index.html)
cd ~/Documents/projects/reverb-jp/dev && bash build.sh

# 2) 빌드 결과를 앱으로 복사 + iOS 테마 주입
cd ../ios-app && bash sync-ios.sh

# 3) 앱 자산을 iOS 프로젝트에 반영
npx cap copy ios

# 4) 시뮬레이터로 빌드·실행
cd ios/App
xcodebuild -project App.xcodeproj -scheme App -configuration Debug \
  -sdk iphonesimulator -derivedDataPath build \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/App.app
xcrun simctl launch booted com.reverbjp.app
```

또는 Xcode로 직접 열어서 실행 버튼을 눌러도 됩니다:

```bash
cd ~/Documents/projects/reverb-jp/ios-app && npx cap open ios
```

---

## 디자인을 더 바꾸려면

`www/ios-theme.css` 한 파일만 고치면 됩니다. (기존 웹 스타일 위에 덧씌우는 레이어)
고친 뒤 위 빌드 단계 2~4만 다시 실행하면 반영됩니다.

상태바 글자색·세로고정 같은 iOS 네이티브 설정은
`ios/App/App/Info.plist`에 있습니다.

---

## 실제 아이폰에서 써보려면

1. 아이폰을 USB로 Mac에 연결
2. `npx cap open ios`로 Xcode 열기
3. Xcode 상단에서 연결한 아이폰 선택
4. `Signing & Capabilities` 탭에서 본인 Apple ID로 Team 설정 (무료 계정도 가능)
5. 실행(▶) 버튼

> 무료 Apple ID는 7일마다 재설치가 필요합니다. 앱스토어 등록 없이 본인 기기 테스트용입니다.

---

## 보는 서버를 바꾸려면

앱은 파일을 앱 안에 담아 띄우는 **번들 방식**이라 주소가 늘 `localhost` 입니다. 그래서
주소로는 운영/개발이 갈리지 않고, **빌드할 때 값을 심어** 정합니다(`sync-ios.sh` 가
`<head>` 에 넣고 `dev/lib/supabase.js` 가 그 값을 먼저 봅니다).

```bash
# 기본값 — 운영서버
bash sync-ios.sh

# 개발서버로 한 번만 만들고 싶을 때 (코드 수정 없이)
IOS_APP_ENV=staging bash sync-ios.sh
```

실행하면 마지막 줄에 `접속 서버: production` 처럼 **어디에 붙는지 찍힙니다.** 앱을 다시
빌드·설치해야 반영됩니다(번들이라 앱 안 파일이 바뀌어야 합니다).

⚠️ 기본값 자체를 바꾸려면 `sync-ios.sh` 의 `APP_ENV` 기본값 한 줄만 고칩니다. 다만
**개발서버로 바꿔 두고 그대로 커밋하지 않도록** 주의하세요 — 위 환경변수 방식이면 그럴 일이
없습니다.

### 서버를 바꾸면 함께 일어나는 일
- **로그인이 풀립니다.** 로그인 정보는 서버(프로젝트)별로 따로 저장돼, 다른 서버로 바꾸면
  이전 로그인을 못 찾습니다. 오류가 아니라 정상입니다 — 그 서버의 계정으로 다시 로그인하세요.
- 개발서버 테스트 계정(`sakura.test@reverb.jp` 등)은 **운영에 없습니다.**
- **비밀번호 재설정·회원가입 확인 메일의 링크는 앱이 아니라 웹사이트로 열립니다.** 앱 안에서
  그 흐름을 끝낼 수 없습니다. 운영은 가입 시 메일 확인이 켜져 있습니다.

---

## 앞으로 할 일 (착수 전에 반드시 읽을 것)

### 푸시 알림 발송 백엔드
지금은 **기기 토큰을 저장하는 데까지만** 돼 있습니다(마이그레이션 373·374). 실제 발송은 없습니다.

🔴 **발송을 만들기 전에 이것부터 결정하세요 — 토큰 주인 바꾸기**

토큰 등록 함수(`register_push_token`)는 **넘겨받은 토큰의 주인을 부른 사람으로 바꿉니다.**
같은 폰에서 A가 로그아웃하고 B가 로그인하면 주인이 B로 바뀌어야 하기 때문이고, 그건 맞습니다.

문제는 **그것이 탈취와 데이터상 구분되지 않는다**는 점입니다. 로그인한 회원이 남의 기기 토큰
값을 알면 자기 것으로 가져갈 수 있고, **원래 주인은 알림을 못 받게 됩니다.** 함수 안쪽에
「본인 것인지 확인」을 넣으면 계정 전환이 깨지므로, 코드로는 못 막습니다.

지금 위험이 낮은 이유는 두 가지뿐입니다 — ①토큰 값이 어느 조회 경로로도 남에게 안 나갑니다
②**발송이 없어서 못 받을 알림이 애초에 없습니다.** **두 번째 이유는 발송을 만드는 순간 사라집니다.**

착수할 때 정할 것: 주인이 바뀔 때 **기록을 남길지**(추적 가능하게) / 같은 토큰의 **주인 변경
빈도를 제한할지** / 그대로 갈지. 배경은 마이그레이션 `374_device_push_token_rpcs.sql` 주석에
있습니다.

그 밖에 필요한 것: 애플 개발자 계정의 푸시 인증 키(`.p8`), Xcode 의 푸시·백그라운드 권한 설정,
그리고 발송 함수(서버).

### 그 밖
- **로딩 방식 결정** — 지금은 화면 코드를 앱 안에 담는 방식이라, 웹을 고쳐도 앱은 안 바뀝니다
  (앱을 다시 빌드해야 합니다). 「웹 배포 = 앱 자동 반영」으로 갈지는 아직 결정 전입니다.
- 앱 아이콘

---

## 주의

- 화면 캡처용으로 잠시 넣었던 **자동 로그인/자동 이동 코드는 모두 제거**되었습니다
  (테스트 계정 비밀번호가 앱에 남지 않습니다).
- 이 앱은 실험용이며 앱스토어 등록은 하지 않은 상태입니다.
