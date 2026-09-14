# 넓은 화면(아이폰 폴드·아이패드) 대응 — 현재 상태 조사

**작성일:** 2026-09-11 · **작성:** iOS 개발 세션 · **받는 곳:** 기획 세션(사양서 작성용)
**성격:** 사양서가 아니다. 기획이 「현재 상태」 절을 채울 재료와, 실제 화면 캡처로 확인한 사실만 적는다. 설계 제안은 없다.

> 배경 — 사용자 결정(2026-09-11): 대상 기기는 **아이폰 폴드 + 아이패드 전 기종**. 범위(폭만 채우기 / 열 수를 늘리는 새 배치)는 **기획이 정한다**.
> 조사 기준 코드: 웹은 `dev`(커밋 `6edd7393`), iOS 전용은 `feature/ios-app`(커밋 `0cdbdf3d` — dev 보다 712커밋 뒤).
> ⚠️ 줄 번호는 적지 않는다. 브랜치마다 다르고 곧 낡는다. 이름(선택자·함수·요소 id)으로 지목했으니 읽는 쪽이 그 자리를 찾는다.

---

## 1. 실제로 어떻게 보이나 (아이패드 미니 시뮬레이터, 개발서버 연결)

Xcode 26.6 시뮬레이터에는 **폴드 기기가 없다.** 가장 가까운 대체로 아이패드 미니(A17 Pro, 세로 744×1133 CSS px)를 썼다. 캡처 파일은 아래 경로(이 맥 안, 세션 임시 폴더 — 오래 보관되지 않으니 필요하면 옮길 것):

```
/private/tmp/claude-501/-Users-younggeunkim-Documents-projects-reverb-jp/949ca9a0-c10a-4e8e-b265-585ed25a1147/scratchpad/
  ipadmini-home-portrait2.png      홈 · 세로
  ipadmini-home-landscape-r.png    홈 · 가로
  ipad-list-portrait.png           캠페인 목록 · 세로
  ipad-detail-portrait.png         캠페인 상세(초대 전용 행사라 안내 화면) · 세로
  ipad-detail-landscape-r.png      같은 화면 · 가로
  ipad-login-portrait.png          로그인 · 세로
```

| 관찰 | 뜻 |
|---|---|
| 모든 화면이 **가운데 480px 기둥**, 양옆 회색(`#E5E5E5`) | 깨지지는 않는다. 폰 화면을 태블릿 한가운데 놓은 모양 |
| 가로로 돌리면 **화면의 절반 이상이 회색** | 아이패드는 회전이 열려 있다(아래 §4 「iOS 전용 — 네이티브 설정」). 가로에서 쓸 이유가 없는 화면 |
| 하단 탭바·「会員登録・ログイン」 떠 있는 버튼·뒤로 단추가 **기둥 안**에만 뜬다 | 기둥 기준으로 고정돼 있어서다(§2-1 「뿌리」). 기둥을 넓히면 같이 넓어진다 |
| 캠페인 목록은 2열 그대로 — 카드 한 장이 약 220px 정사각 | 기둥을 넓히면 카드가 그대로 커진다(열 수가 고정) |
| 로그인 카드는 기둥 폭(480)을 그대로 채운다. **회원가입** 카드(`#page-signup` 의 `auth-card`)만 인라인 `max-width:560px` 라 기둥에 눌려 있다 | 넓히면 회원가입 카드만 먼저 넓어진다 |
| 화면 **오른쪽 아래 구석에 회색 호(⌒) 하나가 모든 화면에서 계속 보인다** — 기둥 밖, 뷰포트 기준 | **원인 미확정.** 로딩 덮개(`.loading-overlay`)는 기본 숨김이고 가운데 정렬이라 그것은 아닌 듯하다. 웹 검사기로 요소를 짚어 봐야 안다. 폰에서는 화면 밖이라 안 보였을 자리 |

---

## 2. 웹 공용 CSS(`dev/css/*.css`, `dev/index.html` 인라인) — 폭 480 이 박힌 자리

### 2-1. 뿌리 — 이 한 줄이 전부를 정한다
- `#appShell`(base.css): `position:fixed; left:50%; transform:translateX(-50%); width:100%; max-width:480px; overflow:hidden`. **앱 전체가 480px 상한 기둥**이다.
- 🔴 **`transform` 이 있어서 `#appShell` 이 자손 `position:fixed` 의 기준 상자가 된다.** components.css 에 「`#appShell` 이 transform 보유 → 자손 fixed 는 appShell(480px) 기준」이라는 주석이 있다. 그래서 탭바·떠 있는 버튼·토스트·모달 덮개 **전부(웹 12개 + iOS 3개)** 가 기둥 안에 뜬다. 기둥 폭을 바꾸면 이들이 전부 따라온다 — 반대로 기둥 구조를 없애면 전부 뷰포트로 튀어나간다.
- 나머지 480: `.container`·`.container-sm`·`.container-md`(셋이 같은 값, 이름만 셋) · `.modal` · `#detailFloatBar` · `#legalModal .legal-sheet` · `#policyNoticeModal .legal-sheet` · `#loginPromptOverlay` 안쪽(인라인). **합쳐 8곳**(`#appShell` 은 따로).
- 유일한 폭 미디어 쿼리: `@media(min-width:481px){body{background:#E5E5E5}}` — 회색 여백 칠하기뿐. 그 밖의 `@media` 는 `prefers-reduced-motion` 하나. `clamp()`·컨테이너 쿼리·방향 쿼리 **0건**.

### 2-2. 뷰포트(창) 기준으로 재는 값 — 기둥과 어긋나는 자리
기둥은 480 인데 아래는 **창 폭·높이** 기준이라 아이패드에서 비율이 달라진다.
- `#toast{max-width:min(90vw,440px)}` — 아이패드에선 440px 로 벌어짐(가운데는 기둥 기준)
- `.nav-panel-body{width:min(320px,82vw)}`(햄버거 패널)
- `max-height:90vh` — `.modal`·`#legalModal`·`#policyNoticeModal`·`#cropModal`; `85vh`/`80vh` — `#cautionCompareModal`·`#applyActionModal`·`#cancelDetailModal`
- 응모 폼 페이지 `padding-bottom:50vh`(키보드 여유)
- `env(safe-area-inset-top/bottom)` 만 쓰고 **`inset-left/right` 는 어디에도 없다** — 가로·분할 화면에서 좌우 안전영역을 안 본다

### 2-3. `position:fixed` 요소 전부 (기둥 안, 기둥 기준)
`#toast` · `.modal-overlay`(5개) · `.loading-overlay` · `.floating-auth-cta` · `.nav-panel` · `.notif-modal` · `#detailFloatBar` · `#legalModal` · `#policyNoticeModal` · `#policyNoticeBannerWrap`(**`top:56px` 가 `.gnb` 높이 56 을 손으로 박은 것**) · `#ptrIndicator` · `.msg-lightbox` · 인라인 4개(`#profileAlertOverlay`·`#ageGateOverlay`·`#cropModal`·`#loginPromptOverlay`).
- ⚠️ **`#cropModal` 만 실행 중에 `document.body` 로 옮겨진다**(ui.js) — 뷰포트 기준이 맞고, `max-width:500px` 라 이미 480 을 넘는다. 기둥 규칙에서 예외.
- `sticky`: `.apply-box{top:74px}`(56+18 손 계산) · `.legal-page-head` · `.mypage-sub-header` · `#campPageStickyHeader`.

### 2-4. 열 수가 고정된 배치
| 자리 | 값 |
|---|---|
| `.camp-grid`(캠페인 목록) | **2열 고정** |
| `.apply-stats` | 2열 |
| 홈 특징 3칸(index.html 인라인, `repeat(3, …)`) | 3열 — 가운데 칸에만 좌우 선(가운데 자식에 손으로 박음) |
| `.detail-layout` | **1열로 눌러 둠**. `.detail-sidebar` 는 빈 규칙 — 옛 PC 2단 배치를 접은 흔적 |
| `.form-row` | 1열(관리자 `#page-admin .form-row` 만 2열 — 공용 파일에 관리자 예외가 산다) |
| 가로 스크롤 칩 줄: `.filter-row`·`.event-date-tabs`·`.ticket-switch`·`#myApplicationsFilters`(iOS) | 좁은 폭 전략. 넓은 화면에선 짧은 칩 줄이 왼쪽에 몰린다 |

### 2-5. 글자·문단
- **전부 고정 px**, `clamp()` 없음. 기준 14px/1.6, 입력칸 16px(iOS 확대 방지). 제목: `.hero-h1` 24 · `.detail-h1` 22 · `.apply-reward` 24 · `.section-title` 18 · `.auth-title`·`.modal-title` 20.
- **본문 줄 길이 상한이 어디에도 없다** — `.legal-body`·`.legal-page-body`·`.rich-content`·`.hero-sub{max-width:100%}`(일부러 상한 없음)·`.guide-val`·`.caution-box li`·`.msg-faq-answer-body`·`.ticket-msg`. 기둥이 넓어지면 일본어 한 줄이 그대로 길어진다.
- ⚠️ `.dpb-step{white-space:pre-line}` 은 **좁은 폭에서 줄이 접혀서 단계처럼 보인다**는 주석이 붙어 있다 — 넓히면 모양이 달라진다. `.invite-gate-hint` 도 같은 방식.
- 장식 아이콘 크기 고정(`.camp-img` 36 · `.empty-icon` 48 · `.detail-img` 72 · 초대 게이트·티켓 44) — 기둥이 커지면 상대적으로 작아 보인다.

### 2-6. 이미지
- `.camp-img{aspect-ratio:1/1}` — 코드 전체에서 유일한 `aspect-ratio`(CSS 쪽). 480/2열이면 약 220px 정사각, 열 수를 안 바꾸고 넓히면 그대로 커진다.
- `.detail-img{height:200px}` 고정 높이(비율 아님).
- **캠페인 상세 사진 넘김은 있다**(CSS 조사가 「없다」고 봤는데 틀렸다 — 자바스크립트가 만든다). `application.js` 가 `#campSlider`(`aspect-ratio:1/1`)·`#campSlides` 를 인라인으로 만들고, `ui.js` 의 `slideTo()` 가 `translateX(-N%)` 로 움직인다. **퍼센트라 폭이 바뀌어도 다시 재지 않아도 된다**(§3 「웹 자바스크립트」). 스와이프 없음 — 화살표·점만.
- `.rich-img-sm/md/lg` = 기둥의 25/50/75% — 폭을 따라간다.
- 🔴 **썸네일이 480 기둥에 맞춰 저장된다**: 카드는 `{thumb:480}`, 저장 폭 표 `THUMB_WIDTH_BY_PREFIX = {campaigns:720, receipts:480, review-images:480, content:720}`(storage.js), 리치 본문은 `RICH_DISPLAY_WIDTH = 960`(shared.js — 「인플루언서 앱은 폭 480 … 두 배」 주석). `srcset`/`sizes` 없음. 기둥을 720 넘게 넓히면 **저장된 사본이 확대돼 흐려진다.** (관련 규칙: `CLAUDE.md` 「이미지 썸네일 — 유료 변환을 쓰지 않는다」, 목록 세 곳 동시 유지)

### 2-7. 시트·모달
- 대화창은 전부 **아래 붙는 시트**(`align-items:flex-end` + `width:100%; max-width:480px` + 위쪽만 둥근 모서리): `.modal`(28px) · 약관 2종(18px) · `#loginPromptOverlay`(20px) · `.notif-modal-body`(`top:15%`). 넓은 화면에서 480 시트가 아래 가운데에 붙는다.
- 가운데 뜨는 대화창(둥근 모서리 사방)은 따로 상한이 있다: 360(`#profileAlertOverlay`·`#ageGateOverlay`) · 400(`#alertModal`·`#cancelDetailModal`) · 420(`#applyActionModal`) · 440(`#cautionCompareModal`) · 500(`#cropModal`). 이쪽은 넓은 화면에서도 크기가 맞아 보인다.
- 올라오는 애니메이션(`slideUp`·`translateY(100%)`·햄버거 `translateX(100%)`)은 아래/오른쪽 부착을 전제.

---

## 3. 웹 자바스크립트(`dev/js`·`dev/lib`, 관리자 제외) — 접었다 펼칠 때 다시 계산해야 하는 것

**결론: 폭을 읽는 코드가 하나도 없다.** `innerWidth`·`clientWidth`·`getBoundingClientRect`·`offsetWidth`·`matchMedia`·`screen.orientation`·`ResizeObserver`·`window` 의 `resize`/`orientationchange` 리스너 — **전부 0건.** 뷰포트 리스너는 `visualViewport` 의 `resize` 하나뿐이고 그것도 높이만 읽는다(아래 표). 가로 배치는 전부 CSS 가 정한다.

| 항목 | 상태 |
|---|---|
| 상세 사진 넘김(`slideTo` 의 `translateX(-N%)`, 슬라이드 `flex:0 0 100%`) | **폭 변화에 저절로 맞는다.** 다시 잴 것 없음 |
| `visualViewport` 처리기(app.js `adjustHeight`) — 앱 유일의 뷰포트 리스너 | **높이·offsetTop 만 읽는다.** 폭만 바뀌면 아무것도 안 한다(키보드로 오인할 여지 없음). 높이가 바뀌면 `#appShell.style.height/top` 를 px 로 다시 쓴다. ⚠️ `visualViewport` 없는 브라우저 대비 폴백 없음 |
| `IntersectionObserver` | `mountLazyList`(ui.js) 하나뿐인데 **인플루언서 쪽 호출부가 없다**(관리자용). 떠 있는 응모 바는 관찰자가 아니라 직접 켜고 끈다 |
| 요소 위치를 재서 px 로 박는 코드 | **없음.** 당겨서 새로고침(`RESISTANCE .5`·`TRIGGER_AT 90`·`MAX_PULL 130`)은 상수, 점 크기 16/6 은 상수 |
| 스크롤 저장·복원 | 없음(전부 맨 위/맨 아래로 되돌림). `mypage.js` 의 `window.scrollTo` 두 곳은 실제 스크롤 상자가 `.page.active` 라 **아무 효과 없는 호출**일 가능성 |

**처음 그린 뒤 다시 계산하지 않는 값(폭이 바뀌면 낡는 것)**
- `messaging.js` 메시지 입력칸 자동 높이(`scrollHeight` → px, 입력할 때만 갱신)
- `campaign.js` 캠페인 목록 필터 영역 `maxHeight:'80px'` 손 계산(칩이 두 줄에 들어간다는 전제 — 폭이 바뀌어 줄 수가 달라지면 잘리거나 남는다)
- `event-ticket.js` QR 캔버스 200×200 고정
- `shared.js` `RICH_DISPLAY_WIDTH=960` · 썸네일 480/720 상수(§2-6 「이미지」)
- 취소 화면 `setTimeout(300)` 뒤 `scrollIntoView`(키보드 안정 대기 — 접는 도중이면 어긋날 수 있으나 스크롤 위치만 영향)

---

## 4. iOS 전용(`feature/ios-app` 의 `ios-app/`) — 테마·네이티브 설정

### 4-1. `ios-theme.css`
- **`@media` 0건, 방향 쿼리 0건.** 폭은 전부 기둥(`100%`=480)에서 파생.
- 토큰: `--ios-nav-h:48px` · `--ios-tab-h:56px` · `--ios-tab-space = tab-h + gap + env(safe-area-inset-bottom)`.
- `position:fixed` 3개(기둥 기준): `.ios-tabbar`(`left:50%`, `max-width:calc(100% - 32px)` → 448px 상한) · `.ios-tab-back`(왼쪽 아래 56px 원) · `#detailFloatBar`(위쪽으로 옮겨 붙임 — `top: nav-h + safe-top`). 뒤로 단추가 켜지면 탭바가 `calc(100% - 32px - tab-h - 12px)` 로 줄고 오른쪽으로 밀린다(짝 규칙 2벌, 키보드 열림 변형 포함).
- `#campSlider{width:calc(100% + 32px); margin: …  -16px}` — 컨테이너 여백 16px 을 손으로 뚫고 나가는 전면 사진. 여백 규칙이 바뀌면 같이 바뀌어야 한다.
- 세그먼트(모집 형식 탭)·언어 토글·티켓 스위치·필터 칩은 전부 flex 로 컨테이너 폭을 따른다. `.gnb-apply-filter{max-width:46%}`.
- 글자 크기 고정 px 약 20곳(`gnb-title` 17 · 이름 26 · 22 등).
- `env()` 는 top/bottom 만(웹과 같음). **left/right 없음.**

### 4-2. 네이티브 설정 — 무엇이 켜져 있고 무엇이 없나
| 항목 | 값 |
|---|---|
| `UISupportedInterfaceOrientations`(아이폰) | **세로만** |
| `UISupportedInterfaceOrientations~ipad` | **네 방향 전부** → 아이패드는 CSS 에 가로 대응이 없는데 회전이 열려 있다 |
| `TARGETED_DEVICE_FAMILY` | `"1,2"`(아이폰+아이패드, Debug·Release 둘 다) |
| `UIRequiresFullScreen` | **없음** → 아이패드 **분할 화면(Split View)·슬라이드 오버가 기본 허용**. 앱이 임의 폭(320~)으로 잘릴 수 있다 |
| 앱 시작 화면 `LaunchScreen.storyboard` | 375×667 고정 프레임 이미지, `autoresizingMask` 비어 있음, 제약 없음. `Splash` 1366×1366 정사각 `scaleAspectFill` 이라 어느 비율이든 채우긴 한다 |
| `capacitor.config.json` | `contentInset:"never"` — 안전영역을 웹뷰가 안 넣고 CSS `env()` 가 전부 한다 |
| 뷰포트 메타 | 웹과 **바이트 단위 동일**(`width=device-width … viewport-fit=cover`). `sync-ios.sh` 는 메타를 안 건드린다 |

⚠️ **폴드가 iOS 안에서 아이폰으로 분류되는지 아이패드로 분류되는지는 실기기·새 SDK 없이는 모른다.** 위 표에서 아이폰/아이패드 값이 다른 두 항목(방향 잠금·회전)이 그 분류를 따른다.

### 4-3. iOS 전용 배치 기능이 어디에 사는가 (기획이 「어느 파일을 고치면 웹이 바뀌나」를 알아야 하는 표)
| 기능 | 마크업 | 동작(JS) | 스타일 |
|---|---|---|---|
| 하단 탭바 `#iosTabbar` | `dev/index.html` **공용** | `dev/js/app.js`(`updateActiveTab`, 키보드 숨김) **공용**, `Capacitor.isNativePlatform()` 으로 분기 | 웹 `components.css` 는 `display:none`, iOS 는 `ios-theme.css` |
| 뒤로 단추 `#iosTabBack` | 공용 | `app.js` `setGnbBack` | 위와 같음 |
| 상단 제목 `#gnbTitle`·큰 제목 전환 | 공용 | `app.js` `setGnbTitle`·`setupLargeTitle`(IntersectionObserver, `rootMargin:-gnbH`) | `ios-theme.css` |
| 떠 있는 응모 바 위로 붙이기 | 공용 `#detailFloatBar` | `app.js` `setupFloatBarDock`/`teardownFloatBarDock`(**dev 에 없음** — iOS 브랜치 전용 JS) | `ios-theme.css` |
| 마이페이지 목록형 셀 | 공용 | `mypage.js`(네이티브 분기) | `ios-theme.css` |
| 응모이력 필터를 상단바로 옮김 | 공용 `#myApplyStatusSelect` | `mypage.js` `moveApplyFilterToGnb` | `ios-theme.css` |

→ **iOS 전용처럼 보이는 기능도 마크업·JS 는 공용 파일에 있고 실행 시점에 네이티브 여부로 갈린다(13곳).** `ios-theme.css` 만 iOS 전용이다. 이 사실이 「iOS 브랜치를 dev 에 합치면 웹 코드가 된다」는 2026-07-14 인수인계 판단의 근거다.

---

## 5. 이 조사가 드러낸, 사양서가 반드시 다뤄야 할 결정 지점 (제안이 아니라 「정해야 하는 것」 목록)

1. **기둥을 넓힐 것인가, 기둥 구조를 버릴 것인가.** 기둥(`#appShell` transform)이 fixed 요소 15개의 기준이다. 넓히면 전부 따라오고, 버리면 전부 다시 앉혀야 한다.
2. **상한을 어디에 둘 것인가.** 회원가입 카드는 이미 560, 가운데 대화창들은 360~500. 썸네일은 720 이 천장(그 위는 흐려진다).
3. **캠페인 목록 열 수**(지금 2열 고정)와 **홈 특징 3칸**·**상세 1열**(2단 흔적 있음).
4. **본문 줄 길이 상한** — 지금 어디에도 없다. 특히 `.dpb-step`·`.invite-gate-hint` 는 좁은 폭에 기대어 모양이 성립한다.
5. **아래 붙는 시트 7종을 넓은 화면에서 어떻게 앉힐 것인가**(480 시트가 아래 가운데에 붙는 지금 모습 그대로인가).
6. **아이패드 가로·분할 화면을 허용할 것인가.** 지금은 열려 있다(`UIRequiresFullScreen` 없음, `~ipad` 네 방향). 막는 것도 결정이고, 여는 것도 결정이다 — `env(safe-area-inset-left/right)` 가 어디에도 없다는 점 포함.
7. **폴드의 분류**(아이폰/아이패드)가 확정될 때까지 방향 잠금을 어느 쪽에 맞출 것인가.
8. **웹 PC 브라우저도 같이 바뀐다** — `dev/css` 를 고치면 PC 에서 보는 인플루언서 웹(지금 480 기둥)이 같이 바뀐다. iOS 테마에만 넣으면 두 벌.
9. 이 작업과 **애플 지침 기반 화면 재설계**(`planning.md`)·**앱 전환 결정**(2026-07-14 인수인계)의 선후.

---

## 6. 이번 조사에서 안 한 것 · 못 한 것
- 로그인 뒤 화면(마이페이지·활동관리·메시지) 캡처 — 자동 로그인 주입이 필요해 뺐다. 배치 규칙은 §2(웹 공용 CSS)로 갈음.
- 오른쪽 아래 회색 호의 원인(§1 「실제로 어떻게 보이나」) — 웹 검사기 연결이 필요하다.
- 폴드 실기기·폴드 시뮬레이터 확인 — 둘 다 없다.
- iOS 브랜치와 dev 의 CSS 차이 대조 — 이 조사는 웹은 dev, iOS 전용은 iOS 브랜치를 봤다. 두 브랜치의 `dev/css` 가 갈린 부분은 세지 않았다(712커밋 차이).

## 구현 결과
(해당 없음 — 조사 문서. 사양서는 기획이 별도 파일로 쓴다)
