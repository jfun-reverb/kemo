# REVERB JP — iOS 하이브리드 앱 (실험용)

기존 인플루언서 웹앱(`dev/`)을 그대로 감싸 만든 **iOS 앱**입니다.
[Capacitor](https://capacitorjs.com)로 웹 화면을 iOS 앱 껍데기에 넣고, 그 위에
iOS 네이티브 느낌의 디자인 레이어(`www/ios-theme.css`)를 덧입혔습니다.

> ⚠️ **운영 웹 무영향**: 이 폴더(`ios-app/`)만 손대며, 운영 사이트(`globalreverb.com`)
> 코드(`dev/`)는 바꾸지 않습니다. 앱은 별도 산출물입니다.

---

## 지금 상태

- 앱 이름: **REVERB JP**, 앱 식별자: `com.reverbjp.app`
- 보고 있는 서버: **개발서버(dev)** — 앱은 주소창이 없어 자동으로 개발 데이터에 붙습니다
  (실험에 안전, 운영 데이터 무영향)
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

## 서버를 운영 데이터로 바꾸려면 (선택)

지금은 개발서버를 봅니다. 운영 캠페인을 보려면 별도 설정이 필요합니다(추후 작업).
실험·테스트 단계에서는 개발서버 그대로 두는 것을 권장합니다.

---

## 주의

- 화면 캡처용으로 잠시 넣었던 **자동 로그인/자동 이동 코드는 모두 제거**되었습니다
  (테스트 계정 비밀번호가 앱에 남지 않습니다).
- 이 앱은 실험용이며 앱스토어 등록은 하지 않은 상태입니다.
