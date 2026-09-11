# iOS 앱 넓은 화면 배치 — 여백 없이 채우기 + iPad 2단·3단 — 사양서

**작성일:** 2026-09-11 · **작성:** 기획 세션 · **받는 곳:** iOS 개발 세션(`feature/ios-app`)
**짝 문서:** 웹 사양서 `docs/specs/2026-09-11-wide-screen-layout.md`(브라우저는 720 기둥) · 근거 조사 `docs/specs/2026-09-11-wide-screen-current-state-survey.md`
**사용자 결정(2026-09-11 오후, 기획 세션에서 확인 — 전부 확정):**
① 적용 대상 = **iOS 앱에서만**(아이패드 Safari·PC 웹은 웹 사양서의 720 기둥 그대로)
② 2단·3단 대상 화면 = **캠페인(목록+상세) · 마이페이지(목록+폼) · 메시지(응모이력+대화)** 세 화면
③ 폴드(iPhone Duo) 속 화면 = **세로(669)는 1단 채우기, 가로(951)만 2단**
④ 3단(왼쪽 세로 메뉴 + 목록 + 상세) = **13형 iPad 가로에서만**
⑤ 2단 시작 폭 = **820 이상**(11형 iPad 세로부터. iPad 미니 세로 744·폴드 속 세로 669 는 1단 채우기, 가로로 돌리면 2단)

> 2판(2026-09-11 저녁) — iOS 세션의 코드 대조(규칙 D, `feature/ios-app` `440e5228` 기준)와 정합성 점검 1회차를 반영해 §3 을 다시 세웠다. 초안의 「표시 규칙 하나·게이트 밖 변경 0줄」은 코드에서 성립하지 않았다(§1-1 「층위 둘」·§3-0).

---

## 0. 한 줄 결론

앱에서는 **기둥(480/720)을 풀어 화면 폭을 다 쓰고**, 폭에 따라 **배치 모드 셋** 중 하나로 그린다 — `fill`(820 미만: 1단, 여백 없이) · `split`(820~1299: 목록 320 + 상세) · `triple`(1300 이상: 세로 메뉴 320 + 목록 320 + 상세). 판정은 **앱에서만** 켜진다. 공용 자바스크립트는 지금은 iOS 브랜치에만 커밋되지만 언젠가 dev 에 합쳐질 파일이라, **웹에서는 동작이 한 픽셀도 안 바뀌어야 한다**(완료 기준 §3-6 ①).

---

## 1. 현재 상태 (규칙 A — 2026-09-11 기획 세션 직접 확인 + iOS 세션 코드 대조)

### 1-1. 화면 구조 (`feature/ios-app` `440e5228` = dev `4b4957f7` 병합 판)
- **한 번에 화면 하나** — `base.css` `.page{display:none}` / `.page.active{display:block;flex:1;overflow-y:auto}`. `#appShell` 은 `display:flex;flex-direction:column` 기둥. `navigate(page, pushHistory)`(`app.js`)가 **`#appShell .page` 전부에서 `.active` 를 떼고**(`querySelectorAll(...).forEach(p=>p.classList.remove('active'))`) 목적지 하나만 켠다.
- **층위가 둘이다** — ①**페이지**(`#appShell` 직계 `.page` 14개: `home`·`campaigns`·`detail`·`mypage`·`activity`·`messages`·`ticket`·`legal`·`login`·`signup`·`forgot`·`reset-pw`·`app-cancel`·`unsubscribe`) ②**마이페이지 뷰**(`#page-mypage` 안 `.mypage-view` 9개 = 서브 폼 8 `#mypage-sub-applications`·`-profile-basic`·`-profile-sns`·`-profile-address`·`-paypal`·`-password`·`-email-settings`·`-withdraw` + iOS 브랜치 전용 목록 `#mypage-sub-list`; `mypage.css` `.mypage-view{display:none;height:100%;overflow-y:auto}` / `.active{display:block}`). 뷰는 `openMypageSub(sub, pushHistory)`(`#page-mypage .mypage-view` 전부 `.active` 제거 뒤 하나 켬)·`openMypageList(pushHistory)` 가 켠다.
- 상세 진입 `openCampaign(id)`(`application.js`, 인자 하나 — `pushHistory` 없음) → `navigate('detail-'+id)`. 출처 `_detailFrom` 은 **그때 `.page.active` 인 페이지의 id 로** 정한다 — `page-campaigns`→`'campaigns'` / `page-mypage`(응모이력 뷰)→`'mypage'` / 그 밖→`'home'`(상세·활동관리에서 되돌아오는 호출은 덮지 않음). `navigateBackFromDetail()` 이 그 값으로 되돌아간다. popstate 처리기·딥링크 착지도 `openCampaign(id)` 를 **같은 형태로** 부른다.
- 탭바 `tabNav(tab)`(`app.js`) — 탭 4개 `data-tab` = `home`·`campaigns`·`activity`(응모이력)·`mypage`. `activity` 는 `navigate('mypage',false)`+`openMypageSub('applications',false)`, `mypage` 는 `navigate('mypage',false)`+`openMypageList(false)`. 활성 표시는 `updateActiveTab(tab)` 이 `#iosTabbar .ios-tab` 의 `data-tab` 과 대조.
- 메시지 `openMessagesPage(applicationId, from, pushHistory)`(`messaging.js`)가 `#page-messages` 를 그린다 — `navigate()` 로는 대화가 안 그려진다.
- 응모이력으로 되돌리는 `closeMypageSub()` 는 **무조건 `history.replaceState(…,'#mypage-applications')`** 를 한다. `navigate('mypage')` 분기가 이 함수를 부른다.
- 응모이력 필터를 상단바로 올리고 내리는 `moveApplyFilterToGnb(on)` 은 `mypage.js` 에 있고 **부르는 자리가 넷**이다 — `navigate()`(`app.js`, `pageName!=='mypage'` 면 내림) · `openMypageSub`(`sub==='applications'` 면 올림) · **`closeMypageSub`(무조건 올림)** · `openMypageList`(무조건 내림. 「같은 페이지 안의 전환이라 `navigate` 의 복귀 로직이 안 걸린다」는 주석이 붙어 있다).
- `closeMypageSub()` 는 **탭도 함께 켠다** — `updateActiveTab('activity')`(「`navigate('mypage')` 는 먼저 마이페이지 탭을 켜므로 화면을 실제로 바꾸는 여기서 되돌린다」는 주석). 그래서 `#mypage` 착지의 탭·필터는 이 함수가 이미 응모이력 기준으로 맞춰 놓는다.
- **DOM 순서**: `#page-messages` 가 `#page-mypage` 보다 **앞**이다(격자에 자동 배치하면 대화가 왼쪽에 앉는다). `#appShell` 직계 자식 37개 중 페이지 14개만 흐름 안이고 나머지(모달·토스트·탭바·상단바)는 `fixed`/`absolute`.
- `navigate()` 안의 네이티브 전용 동작: `_selfHeaderPages = ['legal','messages','ticket','app-cancel']` 이면 상단바 `.gnb` 를 `display:none`, 메시지면 `#iosTabbar` 도 숨김 · `pageName!=='mypage'` 면 `moveApplyFilterToGnb(false)`(응모이력 필터를 목록으로 되돌림) · `updateActiveTab({home,campaigns,mypage}[pageName]||'')`(상세·메시지는 빈 값 → **아무 탭도 안 켜짐**. `activity` 탭은 이 표에 없고 `tabNav('activity')` 가 따로 켠다).
- 기둥 `#appShell{left:50%;transform:translateX(-50%);max-width:…}`(`base.css`) — `transform` 때문에 안의 `fixed` 요소(탭바·응모 바·모달·토스트)가 **기둥을 기준**으로 놓인다. iOS 탭바 `.ios-tabbar{max-width:calc(100% - 32px)}`(테마)는 **기둥 폭에 기대어** 480 이 된다 — 기둥을 풀면 화면 폭이 된다(§3-1 이 상한을 새로 박는다). 뒤로 단추 켜짐 변형은 `calc(100% - 32px - var(--ios-tab-h) - 12px)`.
- 캠페인 목록 필터 접기 `filterArea.style.maxHeight='80px'`(`campaign.js`) — 폭이 좁아 칩 줄이 늘면 잘린다. 카드 마크업은 `<div class="camp-card" onclick="openCampaign('id')">` — **`id`·`data-*` 없음**.
- 당겨서 새로고침은 `#appShell` 의 `touchstart` 가 `.page.active` 만 본다. `#ptrIndicator` 는 기둥 가운데.
- 떠 있는 응모 바 `#detailFloatBar`: 웹은 `position:fixed;bottom:var(--tab-h)` 기둥 기준, iOS 테마가 위쪽으로 옮겨 붙이며(`setupFloatBarDock`, 관찰 root = `#page-detail`) 숨김/도킹 **두 상태 모두** `transform:translateX(-50%)…` 로 가운데 정렬을 겸한다(하나만 바꾸면 도킹 순간 오른쪽으로 절반 튄다 — 테마 주석에 같은 함정 기록).
- iOS 테마 `body:has(#page-detail.page.active:not(.past-hero) #campSlider) .gnb` — 상세 히어로 위에서 상단바를 투명하게.

### 1-2. iOS 앱 구조
- **번들 스냅샷** — 웹을 빌드해 `ios-app/www` 로 복사(`sync-ios.sh`)하고 `</head>` 앞에 `<link rel="stylesheet" href="/ios-theme.css">`(빌드 산출물의 인라인 `<style>` 보다 **뒤**), `</body>` 앞에 `native-push.js` 를 주입. 화면을 고치면 **재빌드**해야 앱에 실린다(로딩 방식 A/B/C 는 미결 — 독립).
- **iOS 전용 CSS = `ios-app/www/ios-theme.css` 하나**(앱 빌드에만 주입되므로 선택자 접두 없음). 미디어 쿼리 0건. 나중에 선언되므로 **같거나 높은 특이도**의 웹 규칙을 덮는다(`@media` 는 특이도를 안 올린다 → 웹의 `@media(min-width:600px){:root{--shell-max:720px}}` 를 테마의 맨 `:root{--shell-max:none}` 이 이긴다. 관련 선택자에 웹 쪽 `!important` 없음 — 확인). ⚠️ 웹 사양서의 `#appShell .form-row` 처럼 특이도가 높은 규칙은 테마도 **같은 형태**로 적어야 이긴다.
- **네이티브 분기는 공용 자바스크립트 안에 인라인** — `window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform()` 을 **11곳**(`app.js` 7 · `mypage.js` 3 · `auth.js` 1)에서 각자 계산(공용 헬퍼 없음). ⚠️ **`application.js`·`campaign.js`·`messaging.js` 에는 0곳** — 이 사양이 그 셋에 넣는 분할 가지가 **그 파일의 첫 네이티브 분기**가 된다(§3-4). **dev(웹 브랜치)에는 0건** — iOS 전용 동작을 담은 공용 파일은 아직 dev 에 합쳐진 적이 없다(2026-07-14 인수인계의 전제 그대로).
- iOS 전용 마크업(`#iosTabbar` 4탭·`#iosTabBack`·`#gnbTitle`)은 iOS 브랜치 `dev/index.html` 에 각 1개, 웹 `components.css` 가 `display:none`, 테마가 켠다. `#mypage-sub-list`(목록 셀)는 iOS 브랜치에만 — 셀은 **6개**(기본정보·SNS·배송지·PayPal·비밀번호·메일 수신). 서브 폼 8종 중 응모이력은 탭바 `activity` 가, 탈퇴는 셀 밖 진입이 담당해 셀에 없다 — 그래서 §3-2 표의 오른쪽(뷰 8종)과 왼쪽(셀 6개)의 수가 다르다.
- `Info.plist`: 아이폰 세로만 · 아이패드 네 방향 · `UIRequiresFullScreen` 없음. 빌드 도구 **Xcode 26.6**.

### 1-3. 웹 사양서와의 관계 (전제)
- 웹 사양서가 dev 에 들어가면 `base.css` 에 `--shell-max`(기본 480, `≥600` 에서 720)·`--reading-max`(560)가 생기고, `≥600` 블록 안에 카드 3열 · 시트 4자리 가운데 카드 560 · 읽기 폭 **20자리** · `#campSlider` 560 정사각(가로일 때 `70vh`) · `#appShell` 좌우 안전영역이 들어간다. 앱은 그 CSS 를 그대로 실으므로 **이 사양은 그 위에서 「덮어쓰기」로 동작한다.**
- 🔴 **착수 순서: 웹 사양서 조각 2~6 이 dev 에 병합 → iOS 브랜치가 dev 재병합 → 이 사양.** 그 전에 하면 덮어쓸 변수가 없다.

### 1-4. 기기·Apple 지침 사실
- **iPhone Duo**(2026-09-09 발표): 밖 466×678pt · 속 **669×951pt**(개발자 계산값). 아이폰 분류, 속 화면은 가로·세로 모두 regular, **방향 잠금을 무시**한다. 다이내믹 아일랜드가 세로로 서 있어 **좌우 안전영역 인셋이 비대칭**. 🔴 **iOS 27 SDK 이전 빌드는 속 화면에서 「익숙한 크기」로만 뜬다** — Xcode 27.1(9월 말 베타) 재빌드 전엔 Duo 에서 이 사양의 효과를 볼 수 없고, Duo 시뮬레이터도 그때까지 없다.
- iPad CSS 폭: 미니 **744**(세로)/1133(가로) · 11형 **820~834**/1180~1210 · 13형 **1032**/**1366~1376**.
- Apple 분할 뷰(UISplitViewController): **주 열(사이드바) 320pt**(기기 따라 375) · **보조 열(목록) 320pt** · 상세는 나머지. 본문 글은 「읽기 폭 가이드」 **약 672pt** 안에.

### 1-5. 이 제안과 충돌 가능성 있는 기존 동작 (§1-1 의 사실이 그대로 충돌 목록이다)
| 자리 | 지금 | 이 사양이 하는 것 |
|---|---|---|
| `navigate()` 의 `.active` 전부 제거 | 한 화면 구조 | **그대로** — 왼쪽 짝은 `.active` 가 아니라 `.split-left` 라 이 루프가 안 건드린다(§3-2 ㉠) |
| `openMypageSub`·`closeMypageSub` 의 뷰 `.active` 전부 제거 | 한 뷰 구조 | **그대로** — 같은 이유(§3-2 ㉠). 뷰 짝의 왼쪽 목록 셀도 `.split-left` 만 |
| `closeMypageSub()` 의 `replaceState('#mypage-applications')` | 응모이력 복귀가 주소를 덮음 | 왼쪽 짝을 켤 때 **이 경로를 안 탄다** — 주소를 안 건드리는 함수 신설(§3-2 ㉡). ⚠️ 예외는 목적지가 `mypage` 인 가지뿐 — 응모이력 탭·`#mypage` 착지는 덮이는 값이 곧 목적지 해시이고, 마이페이지 탭은 그 뒤 `tabNav` 가 `#mypage-list` 로 다시 덮는다(둘 다 무해) |
| `_selfHeaderPages` 상단바·탭바 숨김 | 메시지 화면은 자체 헤더 | 분할 모드 **이고 `pageName==='messages'`** 이면 안 숨긴다 — 나머지 셋(`legal`·`ticket`·`app-cancel`)은 그대로 숨긴다(§3-2 ㉦) |
| `moveApplyFilterToGnb(false)` | 마이페이지 밖이면 필터를 목록으로 | 기존 호출은 그대로 두고, 분할 모드에서는 **오른쪽을 켜는 가지가 마지막에 결과 상태로 다시 맞춘다**(탭 활성과 같은 자리) — 자리 기준·맞추는 자리 모두 §3-2 ㉦ 한 곳에만 정의 |
| `updateActiveTab` 빈 값 | 상세·메시지에서 탭 미표시 | 분할 모드에서는 페이지 짝은 **왼쪽 기준**, 뷰 짝은 **오른쪽 뷰 기준**(§3-2 ㉦) |
| `_detailFrom` = `.page.active` 의 id(`application.js`) | 출처 판정 | 분할 모드에서는 왼쪽이 `.active` 가 아니라 **`splitFromApplications()`**(`.split-left` id + 뷰 상태)로 판정하고, 「덮지 않음」 예외는 그대로(§3-2 ㉧). `detail-` 가지가 그 결과만 읽는다(㉢) — 탭·필터는 ㉦ 이 결과 상태로 따로 정한다 |
| 캠페인 필터 `maxHeight:80px` | 폭 의존 상수 | 분할 모드에서는 **접지 않는다**(§3-2 ㉧) |
| 당겨서 새로고침 | `.page.active` 기준 | 분할 모드에서는 **끈다**(§3-2 ㉧) |
| `#detailFloatBar` 두 상태 transform | 가운데 정렬 겸함 | 분할 모드에서 **두 상태 모두** 다시 적는다(§3-2 ㉤) |
| 히어로 위 투명 상단바 `body:has(…) .gnb` | 상세 히어로 위에서 상단바가 **폭 전체** 투명 | `fill` 에서만(§3-2 ㉦) |
| `#iosTabbar` 폭 `calc(100% - 32px)` | 기둥 480 에 기대어 480 | 상한 480 을 **새로** 박음(§3-1), `triple` 은 사이드바로 대체(§3-3) |
| 웹 사양서 `≥600` 규칙 | 앱에도 실림 | 변수 덮어쓰기(§3-1) |

### 1-6. 미해결 백로그·관련 작업
- 로딩 방식 A/B/C — 독립.
- 웹 공용 수정 2건 이식(`2026-08-26-ios-shared-fixes-handoff.md`) — `application.js` 를 함께 만지므로 **이 사양 착수 전에 처리**(§3-7).
- Apple 지침 화면 재설계 — 이 사양은 **배치**만. 카드·상세·폼·대화의 안쪽 모양은 그대로.

---

## 2. 의심·경우의 수 (규칙 B)

1. **(기술 — 가장 큼) 공용 자바스크립트가 웹에 새어 나간다.** `app.js`·`mypage.js`·`messaging.js`·`campaign.js` 는 웹도 쓴다. 격자 CSS 는 앱에만 실리므로 웹이 2단이 되지는 않지만, 게이트 하나만 빠지면 PC 크롬에서 카드에 선택 표시가 남거나 `_detailFrom`·탭 표시·필터 위치가 어긋난다(픽셀 diff 에 걸린다). → 판정 헬퍼 **한 곳**(§3-0), 완료 기준은 「**웹 동작 변화 0 = 픽셀 diff 0**」(§3-6 ①). 이 사양의 공용 파일 변경은 **iOS 브랜치에만** 들어간다(§1-2) — 그래도 게이트는 넣는다(언젠가 합쳐진다).
2. **(기술) 모드가 실행 중 바뀐다** — 회전·분할 화면 폭 조절·폴드 접기/펴기. 한 번 판정하고 끝내면 세로로 돌린 순간 두 열이 겹친다. → `matchMedia` 변화에서 **재판정 + 현재 해시로 재배치**(§3-2 ㉥). 두 번 불려도 같은 결과(멱등).
3. **(UX — 필수) 오른쪽 열이 빈 채로 시작한다.** 캠페인 탭 첫 진입엔 상세가 없다. → 빈 상태 페이지(§3-2 ㉢)에 안내 한 줄. **첫 항목 자동 선택은 안 한다**(조회수가 오르고 응모 바가 뜬다 — 고른 것처럼 기록된다).
4. **(UX) 뒤로 단추의 뜻** — 분할 모드에서 상세의 「뒤로」는 갈 곳이 없다. → 오른쪽 열 화면에서 뒤로 단추 숨김(§3-2 ㉧). 시스템 뒤로(스와이프·popstate)는 해시 기준으로 그대로.
5. **(UX) 응모 바가 목록 위를 덮는다** → 상세 열 안에(§3-2 ㉤).
6. **(UX) 시트·알림** — 모달은 전부 `#appShell` 안 `fixed;inset:0` 이라 두 열을 덮는다(확인). 열 안에 가두지 않는다. ⚠️ **시트가 열린 채 모드가 바뀌면** 재배치가 밑 화면을 갈아 끼운다 → 시트가 열려 있으면 재배치를 **닫힌 뒤로 미룬다**(§3-2 ㉥).
7. **(UX) 메시지 짝에서 상단바·탭바가 사라진다** — 지금 코드가 메시지 화면에서 둘 다 숨긴다. 분할 모드에서 왼쪽 응모이력이 상단바도 탭바도 없이 뜬다. → 게이트(§3-2 ㉦).
8. **(UX) 마이페이지 짝의 기본 오른쪽** — `tabNav('mypage')` 경로는 목록만 켜고 뷰를 전부 끈다(오른쪽이 빈다). 응모이력을 기본으로 켜면 「응모이력」 탭과 같은 화면이 되어 두 탭을 가를 수 없다. → 분할 모드에서 `openMypageList` 가 **기본정보 뷰**(목록 첫 셀)를 오른쪽에 함께 켠다(§3-2 ㉢).
9. **(데이터) 조회수** — `#detail-{id}` 를 열 때만 올라간다(`openCampaign` 안). 빈 상태에서는 아무것도 안 열므로 영향 없음. 🔴 **모드 전환 재라우팅은 다르다** — ㉥ 이 현재 해시를 다시 태우므로 상세를 보는 중에 회전하면(iPad 미니 744↔1133 이 정확히 이 경계) 같은 상세가 다시 열려 **회전 한 번에 조회수가 1 오른다**. → **모드 전환 재라우팅에서는 조회수만 건너뛴다**(§3-2 ㉥ — 표시 `{fromModeChange:true}` 로 가른다. 「이미 열려 있나」를 따로 검사하지 않는다. popstate·딥링크는 기존 동작 그대로).
10. **(환경) 검증 수단** — 웹 브라우저는 네이티브가 아니라 **어떤 모드도 재현 못 한다**(헬퍼가 `'web'`). iPad 는 시뮬레이터 세 종으로 지금 된다. 폴드는 회전·분할 화면 폭 조절로 **모드 전환 자체**를 대신 보고, 폴드 고유 사항(비대칭 인셋·접힘선)은 Xcode 27.1 + 실기기 뒤.
11. **(권한·법률·약관)** 없음.
12. **(순서)** 웹 사양서보다 먼저 하면 덮어쓸 변수가 없다(§1-3). 웹 공용 수정 2건 이식과 `application.js` 가 겹친다(§1-6).

**현재 구현과 어긋나는 지점** — §1-5 표 13줄이 전부. **의도 모호점** — 「좌우 여백 없이」= 기둥 회색 제거(글줄은 읽기 폭 672 안, 카드는 열 수로 채움) / 「2단·3단」= Apple 열 폭(320/320/나머지)만 따르고 화면 안쪽은 그대로 / 「iOS 앱에서만」= 같은 아이패드에서 앱과 Safari 가 다르게 보이는 것을 **의도**로 확정(①).

---

## 3. 설계

### 3-0. 원칙
- **모드 셋**: `fill`(폭 < 820) · `split`(820 ≤ 폭 < 1300) · `triple`(≥ 1300). 경계 근거 — 목록 320 + 상세 **최소 500** = 820 / 320 + 320 + 상세 660 = 1300. 1300 은 iPad 폭 목록(§1-4)에서 13형 가로(1366·1376)만 넘는 값이고 **1300~1365 폭의 기기는 없다** — 실제 `triple` 의 상세 열은 726~736 이라 읽기 폭 672 가 그 안에 든다. 상세 열의 본문 읽기 폭 672 는 **상한**이라, 열이 그보다 좁으면(`split` 820~991) 열 폭이 곧 본문 폭이다.
- **판정은 한 곳**: `app.js` 의 `iosLayoutMode()` — 네이티브(`window.Capacitor?.isNativePlatform?.()`)가 아니면 **`'web'`**, 네이티브면 `matchMedia('(min-width:820px)')`·`'(min-width:1300px)'` 로 `fill`/`split`/`triple`. **「분할 모드」 = `split` 또는 `triple`** — 자바스크립트의 새 가지는 전부 이 조건 안. `web` 은 새 가지를 타지 않는다. `fill` 은 **배치**가 CSS 만으로 되고, 자바스크립트는 모드 판정·`data-layout` 부착·모드 전환 처리(㉥ — 어느 전환이든 같은 사슬 `data-layout` 갱신 → `splitClearLeft()` → 재라우팅)만 돈다. 기존 인라인 판정 11곳은 손대지 않는다.
- **모드는 `<html data-layout="fill|split|triple">` 로, 지금 짝을 보이는지는 `<html data-split="page|view|none">` 으로 CSS 에 전달**(웹에는 둘 다 안 붙는다). `data-split` 은 `splitShowLeft`/`splitClearLeft`(㉡)만 바꾼다 — `page` = 페이지 층위 짝(캠페인·응모이력→상세·메시지) / `view` = 뷰 층위 짝(마이페이지) / `none` = 짝 없는 화면(격자 없음 — 단 `triple` 은 사이드바 열 때문에 늘 격자, §3-3). 배치 규칙 중 **모드로 갈리는 것**은 `html[data-layout="…"]` 선택자로, **앱이면 늘 적용되는 것**(기둥 해제·안전영역·읽기 폭 변수)은 접두 없이 — 어느 쪽이든 `ios-theme.css` 는 앱에만 실리므로 웹은 무관.
- **표기 규칙** — 이 문서에서 `html[data-layout="split"]` 로 적은 선택자는 실제 CSS 에서 **`html[data-layout="split"] …, html[data-layout="triple"] …` 둘을 나열**한다(속성 선택자는 상속되지 않는다). `triple` 이 따로 정하는 것은 §3-3 의 다섯 — 상시 격자·열 번호·응모 바 `left`·사이드바·탭바 숨김 — 뿐이고, 그 규칙은 `triple` 단독 선택자로 **뒤에** 적어 이긴다. 🔴 **덮을 때 특이도를 맞춘다** — 뒤에 적는 것만으로는 **같은 특이도일 때만** 이긴다. `split` 쪽을 아이디로 적었으면(`#page-split-empty.active`) `triple` 쪽도 **아이디로** 다시 적는다. 클래스 선택자(`.page.active`)로는 아이디 규칙을 못 덮는다.
- **CSS 는 `ios-theme.css` 에만.** 공용 CSS 는 `components.css` 의 **숨김 두 줄**(`#page-split-empty`·`#iosSidebar`, 탭바와 같은 자리)만 더한다.
- **완료 기준은 「게이트 밖 변경 0줄」이 아니라 「웹 동작 변화 0」** — 분할 가지는 전부 `iosLayoutMode()` 가 `split`/`triple` 을 돌려줄 때만 도는 조건문 안에 들어가고, 웹에서는 그 조건이 늘 거짓이라 결과가 같다. 기존 `.active` 제거 루프는 손대지 않는다(왼쪽 짝은 `.active` 가 아니다 — ㉠). 검증은 픽셀 diff(§3-6 ①).
- **화면 안쪽 모양은 안 바꾼다** — 바꾸는 것은 「어느 열에 얼마나 넓게」뿐.

### 3-1. 앱 공통 + `fill` (CSS 만, `ios-theme.css`)
**앱이면 늘**:
- `:root{--shell-max:none}` — 기둥 상한 해제. 웹 사양서의 9자리(`#appShell`·`.container` 3종·시트 4자리·`#detailFloatBar`)가 이 변수를 쓰므로 한 줄로 풀린다. `#appShell` 의 `left:50%;transform:translateX(-50%)` 는 **그대로**(떠 있는 요소의 기준 상자·폭 100% 면 화면을 덮는다).
- `:root{--reading-max:672px}` — 읽기 폭을 Apple 기준으로(웹의 **20자리**가 이 변수를 쓴다 — 웹 구현 중 `.pw-policy`·`.email-tx-desc`·`#withdrawViewBody` 셋이 더해져 17→20 이 됐다. 덮어쓰기라 **그 셋도 자동으로 따라온다**). **시트 4자리는 예외** — **`#appShell .modal`**·`#legalModal .legal-sheet`·`#policyNoticeModal .legal-sheet`·`.login-prompt-sheet{max-width:560px}` 를 다시 박는다(대화창은 672 가 너무 넓다). 🔴 **`.modal` 을 그냥 쓰지 않는다** — 관리자도 쓰는 공용 클래스라 웹 구현에서 실제로 관리자 확인창이 함께 바뀌는 회귀가 났다(웹 사양서 §5 「관리자 회귀」). iOS 테마는 앱 전용 파일이라 관리자 빌드에 안 실려 **지금은 무해하지만**, 선택자를 웹과 다르게 적으면 특이도가 갈려 덮어쓰기가 빗나간다. ⚠️ 웹 규칙과 **같은 선택자·같은 특이도**로 적는다(§1-2).
- `#appShell{padding-left:env(safe-area-inset-left);padding-right:env(safe-area-inset-right)}` — **폭 무관**(웹 사양서는 `≥600` 에서만 건다). 🔴 **근거는 폭이 아니라 「조건을 하나로 두는 것」** — 인셋이 0인 기기·방향에서는 패딩도 0이라 무해하고, 모드·폭마다 조건을 나누면 경계에서 어긋난다(폴드 속 세로 669 는 웹 규칙으로도 덮이지만, 그 사실에 기대면 600 언저리에서 규칙이 둘로 갈린다).
- `#campSlider` 560 정사각·가로 `70vh` 는 웹 규칙 그대로.
- 카드 `@media(min-width:600px){.camp-grid{grid-template-columns:repeat(auto-fill,minmax(200px,1fr))}}` — 폭을 따라 열이 는다(669 → 3열, 744 → 3열, 1180 의 홈 → 5열). **홈의 캠페인 절도 같은 클래스라 함께** 는다(의도). 🔴 600 미만은 웹과 같이 2열 고정. 분할 모드의 왼쪽 320 열만 ㉠ 이 1열로 덮는다.
- 탭바 상한 480 을 **새로** 박는다(§1-1 — 지금 480 은 기둥에서 오는 값): `.ios-tabbar{max-width:min(calc(100% - 32px),480px)}`, 뒤로 단추 켜짐 변형은 `min(calc(100% - 32px - var(--ios-tab-h) - 12px), calc(480px - var(--ios-tab-h) - 12px))`. 자리는 그대로(아래 가운데).
**`fill` 에서(`html[data-layout="fill"]`)**: 위 「앱이면 늘」로 끝난다 — `fill` 전용 규칙은 없다(히어로 위 투명 상단바를 `fill` 로 한정하는 것은 ㉦).
- 짝 없는 화면 열(§3-2 ㉢ 목록)은 **어느 모드에서든 1단 전체**(`triple` 은 사이드바 320 을 뺀 나머지 — §3-3).

### 3-2. `split` — 목록 320 + 상세 (820~1299, 짝 넷)
**짝 넷과 층위** (`data-split` 값이 곧 격자 층위):
| 짝 | 왼쪽(320) | 오른쪽(나머지) | `data-split` | 해시 | 탭 |
|---|---|---|---|---|---|
| 캠페인 | `#page-campaigns`(카드 1열) | `#page-detail` | `page`(`#appShell` 격자) | `#detail-{id}` | `campaigns` |
| 응모이력→상세 | `#page-mypage`(응모이력 뷰 `#mypage-sub-applications` 만 켠 상태) | `#page-detail` | `page` | `#detail-{id}` | `activity` |
| 메시지 | `#page-mypage`(위와 같은 상태) | `#page-messages` | `page` | `#messages-{id}` | `activity` |
| 마이페이지 | `#mypage-sub-list`(목록 셀 6개) | `#mypage-sub-*` 뷰 8종(응모이력 포함) | `view`(`#page-mypage` 안 격자) | `#mypage-{sub}` — 마이페이지 탭 진입만 `#mypage-list`(오른쪽은 기본정보, ㉧ 의 유일한 해시 예외) | `mypage`(오른쪽이 응모이력 뷰면 `activity`) |

⚠️ 사용자 결정 ② 의 「세 화면」은 위 네 짝이다 — 응모이력에서 캠페인을 누르는 길(`_detailFrom='mypage'`)이 지금도 있어 짝으로 세지 않으면 그 순간 왼쪽이 캠페인 목록으로 갈려 버린다. 응모이력 뷰는 **두 자리에 선다** — 마이페이지 짝의 오른쪽(목록 셀 옆, `view`)으로 먼저 도달하고, 거기서 캠페인·메시지를 누르면 **`#page-mypage` 째 왼쪽으로 옮겨**(`page`) 상세·대화의 짝이 된다. 어느 짝인지는 **목적지 + `_detailFrom`**(응모이력에서 왔으면 `'mypage'` — 판정은 ㉧ 한 곳)으로 정한다(㉢).

**㉠ 표시 규칙(CSS)** — 격자는 **짝을 보일 때만**(`data-split`) 켠다. 짝 없는 화면은 격자 없이 기둥 `flex` 그대로라 `fill`·웹과 같은 규칙으로 1단이 된다(`triple` 제외 — §3-3 이 사이드바 열 때문에 늘 격자). 🔴 **왼쪽 짝은 `.split-left` 만 달고 `.active` 는 달지 않는다** — 기존 `.active` 제거 루프 셋(`navigate`·`openMypageSub`·`closeMypageSub`)이 그대로 돌아도 왼쪽이 안 꺼지고, 아래 열 지정이 겹치지 않는다.
- `data-split="page"`: `html[data-layout="split"][data-split="page"] #appShell{display:grid;grid-template-columns:320px 1fr;grid-template-rows:1fr}` · `.page.split-left{display:block;grid-column:1;height:100%;min-height:0;overflow-y:auto}` · `html[data-split="page"] .page.active{grid-column:2;height:100%;min-height:0}`. **열 지정은 명시**(DOM 순서상 `#page-messages` 가 앞이라 자동 배치가 뒤집힌다)·**`min-height:0`·`height:100%` 필수**(없으면 열이 내용 높이만 되고 기둥 `overflow:hidden` 이 아래를 잘라 스크롤이 죽는다). 이때 `#page-mypage.split-left` 는 **1열 통째**(안의 응모이력 뷰만 `.active` — 뷰의 `.active` 는 그대로 쓴다) — 아래 뷰 격자는 `view` 에서만 켜지므로 겹치지 않는다.
- `data-split="view"`: `html[data-layout="split"][data-split="view"] #page-mypage.active{display:grid;grid-template-columns:320px 1fr;grid-template-rows:1fr}` · `.mypage-view.split-left{display:block;grid-column:1;height:100%;min-height:0;overflow-y:auto}` · `html[data-split="view"] .mypage-view.active{grid-column:2;min-height:0}`. `#appShell` 은 격자가 아니라 `#page-mypage.active` 가 기둥 폭 전체(`flex:1`)를 차지한다.
- `data-split="none"`: 격자 규칙 없음. `.split-left` 도 없다(㉡ `splitClearLeft` 가 뗀다).
- **빈 상태 페이지를 켜는 규칙**(`#iosSidebar` 와 같은 형태): `html[data-layout="split"] #page-split-empty.active{display:block;grid-column:2;height:100%;min-height:0}`. 🔴 **없으면 안 보인다** — 공용 CSS 의 숨김이 아이디 선택자(`#page-split-empty{display:none}`)라 `.page.active{display:block}`(클래스)보다 세서, ㉢ 이 `.active` 를 켜도 오른쪽 열이 빈 화면으로 남는다(§3-6 ④ 가 그것을 본다).
- 왼쪽 320 열의 카드는 1열: `html[data-layout="split"] .split-left .camp-grid{grid-template-columns:1fr}`(§3-1 의 `auto-fill` 을 덮는다 — 안 덮으면 320 안에 200px 열이 하나뿐이라 결과는 같지만 규칙으로 못 박는다).

**㉡ 왼쪽 짝 켜기·끄기 — 주소를 안 건드리는 새 함수 둘(`app.js`, 네이티브 전용. `splitShowLeft` 는 분할 모드에서만, `splitClearLeft` 는 `split`→`fill` 전환 때도 부른다 — ㉥)**
- `splitShowLeft(kind)`: `kind='campaigns'` → `#page-campaigns.split-left`, `data-split="page"` / `kind='applications'` → `#page-mypage.split-left` + 응모이력 뷰 `.active`(다른 뷰 끔), `data-split="page"` / `kind='mypage-list'` → `#mypage-sub-list.split-left`, `data-split="view"`. 다른 `.split-left` 는 뗀다. **`history` 를 만지지 않는다** — 🔴 기존 `closeMypageSub()`·`navigate('mypage')` 를 재사용하면 `replaceState('#mypage-applications')` 가 오른쪽 해시(`#messages-{id}` 등)를 덮는다.
- `splitClearLeft()`: `.split-left` 전부 떼고 `data-split="none"`. 짝 없는 화면 진입·**모든 모드 전환**(㉥)에서 부른다.
- **둘 다 일을 마친 뒤 선택 표시를 전부 뗀다**(㉣ — 붙이는 것은 그 뒤 오른쪽을 켜는 가지가 한다). ⚠️ **필터 자리는 여기서 안 건드린다** — 오른쪽이 아직 안 정해졌다. 그것은 ㉦ 대로 오른쪽을 켜는 가지의 마지막에서.

**㉢ `navigate()`·진입 함수의 분할 가지** — 왼쪽 챙기기는 **목적지를 켜는 함수** 안에 둔다.
- **「응모이력에서 왔나」 판정은 한 곳 — `openCampaign` 의 `_detailFrom`(㉧)**. 상세로 가는 길은 전부 `openCampaign(id)` → `navigate('detail-…')` 라(§1-1) `navigate` 의 `detail-` 가지는 **판정을 다시 하지 않고 방금 정해진 `_detailFrom` 만 읽는다**(`'mypage'` = 응모이력에서 왔다). ⚠️ 이 값은 **상세 진입에만** 쓴다 — 탭 활성·필터 자리는 ㉦ 이 결과 상태로 따로 정한다. 그래서 `navigate` 의 `.active` 제거 루프 앞뒤 어디서 읽어도 같다. 판정 재료(`splitFromApplications()`, `app.js`)는 ㉧ 에.
- `detail`: `navigate()` 의 `detail-` 가지. `_detailFrom==='mypage'` 면 `splitShowLeft('applications')`(응모이력→상세 짝 — 마이페이지 짝에서 왔으면 이 호출이 목록 셀을 떼고 `#page-mypage` 를 왼쪽으로 옮긴다), 아니면 `splitShowLeft('campaigns')`(캠페인 짝 — 홈 카드에서 들어와도 왼쪽은 캠페인 목록). `openCampaign` 자체는 `_detailFrom` 판정(㉧)만 바뀐다.
- `messages`: `openMessagesPage` 가 `splitShowLeft('applications')` 뒤 `#page-messages.active`. 마이페이지 짝(`view`)에서 응모이력 뷰의 메시지 단추를 눌러도 같은 길 — `data-split` 이 `view`→`page` 로 바뀌며 목록 셀이 사라지고 응모이력이 왼쪽으로 온다.
- 마이페이지 뷰: `openMypageSub(sub)` 가 `splitShowLeft('mypage-list')` 뒤 그 뷰 `.active`. **응모이력 뷰(`applications`)도 이 짝의 오른쪽**이다(`#mypage-applications`, 탭은 ㉦).
- `navigate('mypage')` 가지: **목적지가 `mypage` 인 세 경로 전부에서 돈다**(마이페이지 탭·응모이력 탭·`#mypage` 착지 — 셋 다 같은 인자로 들어오므로 `navigate()` 안에서 가르지 않는다). 기존 `closeMypageSub()` 뒤 `splitShowLeft('mypage-list')` 를 불러 **왼쪽을 목록 셀로 세우고**, 오른쪽 뷰는 **뒤따르는 함수가 멱등으로 덮는다** — 마이페이지 탭이면 `openMypageList` 가 기본정보, 응모이력 탭이면 `openMypageSub('applications')` 가 응모이력, 뒤따르는 것이 없는 `#mypage` 착지면 `closeMypageSub()` 가 켠 응모이력 그대로(= 응모이력 탭과 같은 배치). **이 가지도 마지막에 ㉦(탭·필터)·㉣(선택 표시)를 부른다** — 뒤따르는 것이 없는 경로에서도 탭이 `activity`, 필터가 상단바로 맞춰진다. `mypage` 는 짝 없는 화면 열에 없고 이 가지가 맡는다(안 두면 직전 `.split-left` 옆에 `#page-mypage` 가 앉아 표에 없는 짝이 생긴다).
- 목적지가 **왼쪽 화면**: 캠페인 탭(`navigate('campaigns')`) → 분할 가지가 **목적지 켜기를 갈아 끼운다** — `#page-campaigns` 에는 `.active` 를 켜지 않고(㉠ 🔴) `splitShowLeft('campaigns')` 로 `.split-left` 만, `.active` 는 **빈 상태 페이지 `#page-split-empty`** 에 켠다(새 `.page`, `#appShell` 직계 — 「왼쪽에서 선택해 주세요」 한 줄·아이콘. 웹 숨김). 오른쪽은 항상 빈 상태. 직전 상세를 남기지 않는다 — 주소가 `#campaigns` 인데 오른쪽에 상세가 있으면 ㉧ 「해시 = 오른쪽 화면」이 깨지고 새로고침 결과와 달라진다. 마이페이지 탭 → `openMypageList` 분할 가지가 `splitShowLeft('mypage-list')` + **기본정보 뷰(`profile-basic`, 목록 첫 셀)를 오른쪽에 함께** 켠다(빈 상태 페이지는 뷰 층위에 안 쓴다. 응모이력을 기본으로 켜면 「응모이력」 탭과 같은 화면이 된다 — §2-8). 주소는 `tabNav` 가 쓰는 `#mypage-list` 그대로 두고, 그 해시로 착지(새로고침·popstate·㉥)해도 같은 배치를 만든다 — ㉧ 의 **유일한 해시 예외**.
- **짝 없는 화면 열(10)** = 페이지 14 중 짝에 든 4(`campaigns`·`detail`·`mypage`·`messages`)를 뺀 것: `home`·`activity`·`ticket`·`legal`·`login`·`signup`·`forgot`·`reset-pw`·`app-cancel`·`unsubscribe`. `navigate()` 가 `splitClearLeft()` 를 부르고 그 페이지 하나만 `.active` — 격자가 없으니 웹과 같은 규칙으로 1단 전체(`triple` 제외 — §3-3).

**㉣ 선택 표시**
- 오른쪽에 떠 있는 항목의 왼쪽 요소에 `.is-selected`(하나만). **떼는 자리** = `splitShowLeft`·`splitClearLeft`(㉡)가 **마지막에** 전부 뗀다 — 그래서 빈 상태·짝 없는 화면·모드 전환에서 선택 표시가 남지 않는다. **붙이는 자리** = ㉢ 의 분할 가지 중 오른쪽에 항목이 뜨는 넷(`campaigns`·`mypage` 가지는 붙일 항목이 없어 떼기만 한다): `detail-` 가지가 `.split-left [data-id="{id}"]`(카드 또는 응모이력 카드) / `openMessagesPage` 가 응모이력 카드 / `openMypageSub` 가 `#mypage-sub-list` 의 셀(대응 셀이 없는 응모이력·탈퇴 뷰는 안 붙인다) / `openMypageList` 가 기본정보 셀. 색은 `ios-theme.css`(`html[data-layout="split"] .is-selected{background:…}`). 🔴 카드 마크업에 식별 속성이 없다 → `campaign.js` 카드 렌더에 **`data-id`** 추가(웹에는 속성만 붙고 아무 규칙도 없다). 응모이력 카드는 `data-id` 가 캠페인 id·응모 id 둘 중 무엇인지, 목록 셀은 `onclick` 의 `sub` 이름을 어떻게 읽을지 **구현 때 확인**(안 봤다) — 결과를 §5 에 적는다.

**㉤ 응모 바**
- `html[data-layout="split"] #detailFloatBar{left:calc(320px + env(safe-area-inset-left));right:env(safe-area-inset-right);width:auto;max-width:none}`(표기 규칙대로 `triple` 도 함께 — `left` 만 §3-3 이 640 기준으로 덮는다). 양쪽에 인셋을 더하는 이유 — 격자 열은 `#appShell` 의 안전영역 패딩 **안쪽**에서 시작하는데 `fixed` 요소의 `left`·`right` 는 기둥의 패딩 상자 가장자리에서 재므로(§1-1), 인셋만큼 어긋나 바가 상세 열 밖까지 뻗는다(Duo 비대칭 인셋에서 드러난다) + 숨김·도킹 **두 상태 모두** `transform` 을 `translateX(0)` 기준으로 다시 적는다(§1-1 함정). `setupFloatBarDock` 은 관찰 root 가 `#page-detail`(오른쪽 열)이라 JS 무변경.

**㉥ 모드 전환(실행 중)**
- `matchMedia` 두 개의 `change` → `iosLayoutMode()` 재판정 → `data-layout` 갱신 → **현재 해시를 popstate 처리기와 같은 분기로 다시 태운다.** popstate 처리기 본문을 **`routeHash(hash, opts)`** 로 빼서 둘이 같은 함수를 쓰되, 모드 전환에서만 `{fromModeChange:true}` 를 준다 — 🔴 **그때 `routeHash` 의 `detail-` 가지**(㉢ 의 `navigate()` 가지와 다른 자리다)**가 `openCampaign(id, {skipViewCount:true})` 로 불러 조회수 증가만 건너뛴다**(그냥 다시 태우면 회전 한 번에 조회수가 1 오른다 — §2-9). ⚠️ **호출을 생략하는 것이 아니다** — 상세는 정상적으로 다시 그려지고 왼쪽 짝(㉢)·`_detailFrom` 예외(㉧)도 그대로 돈다. popstate 는 표시를 안 줘 **기존 동작 그대로**(뒤로가기로 상세에 돌아오면 조회수가 오르는 현재 동작 유지). 그 밖의 호출 형태는 popstate 가 지금 쓰는 그대로(`openCampaign(id)` 인자 하나 · `openMypageSub(sub,false)` · `openMessagesPage(id,'mypage',false)` · `openMypageList(false)`). 🔴 맨 `navigate()` 로는 마이페이지 서브가 응모이력으로 되돌아가고 대화가 다시 안 그려진다. 시트(`.modal-overlay.open` 등)가 열려 있으면 **사슬 전체**(`data-layout` 갱신·`splitClearLeft()`·재라우팅)를 닫힌 뒤로 미룬다 — `data-layout` 만 먼저 바뀌면 격자가 풀려 시트 밑 화면이 바뀐다.
- 🔴 **사슬은 어느 전환이든 하나다 — `data-layout` 갱신 → `splitClearLeft()` → 재라우팅.** 전환 방향마다 분기를 두지 않는다. 결과가 저절로 갈린다: `fill` 로 바뀌었으면 재라우팅의 분할 가지가 안 돌아 **그 해시가 가리키는 화면 하나만** 1단으로 남는다(`#detail-{id}`·`#messages-{id}` 면 상세·대화, `#campaigns` 면 캠페인 목록 — 빈 상태는 꺼진다) / `split`·`triple` 로 바뀌었으면 ㉢ 대로 왼쪽을 다시 켠다(`#campaigns`·`#home` 등 왼쪽·짝 없는 해시도 ㉢ 의 그 가지) / `split`↔`triple` 은 같은 배치를 다시 만들고(가지가 멱등) 실제로 달라지는 것은 `data-layout` 뿐 — 열 번호·사이드바·탭바 표시는 전부 CSS(§3-3)가 한다.

**㉦ 상단바·탭바·필터(분할 모드 게이트)**
- `_selfHeaderPages` 숨김: 분할 모드 **이고 `pageName==='messages'`** 이면 상단바·탭바를 숨기지 않는다(왼쪽 응모이력이 살아 있다). 나머지 셋(`legal`·`ticket`·`app-cancel`)은 짝 없는 화면이라 웹·`fill` 과 같이 숨긴다. ⚠️ **`triple` 에서는 탭바가 어차피 안 보인다** — 이 게이트는 「자바스크립트가 숨기지 않는다」까지이고, `triple` 의 탭바 숨김은 CSS 가 따로 한다(§3-3 — 사이드바가 대체). 즉 `triple` + 메시지 짝의 결과는 **상단바 보임 + 탭바 없음 + 사이드바**.
- **응모이력 필터의 자리 — 이 문서에서 여기 한 곳만 정한다.** 기준은 목적지도 경로도 아니라 **결과 상태 하나**: 🔴 **응모이력 목록이 지금 화면에 있으면 상단바, 없으면 목록 안.** 왼쪽이든 오른쪽이든 보이기만 하면 상단바다(응모이력 탭은 오른쪽, 응모이력→상세·메시지 짝은 왼쪽 — 셋 다 상단바 / 마이페이지 탭·캠페인 짝·짝 없는 화면은 목록 안).
  - **맞추는 자리는 탭 활성과 같다** — **㉢ 의 분할 가지 여섯**(`detail-`·`campaigns`·`mypage`·`openMessagesPage`·`openMypageSub`·`openMypageList`)이 **각자 마지막에** `updateActiveTab` 과 나란히 `moveApplyFilterToGnb(응모이력 목록이 화면에 있나)` 를 한 번 부른다. 🔴 **겹칠 때는 「뒤에 부른 것이 이긴다」 — 멱등이 아니다.** 한 동작에서 둘이 이어 도는 경로(마이페이지 탭 = `navigate('mypage')` → `openMypageList`)는 **오른쪽이 확정된 뒤의 마지막 호출**이 결과를 정한다 — 앞은 `closeMypageSub()` 가 켠 응모이력을 보고 상단바로, 뒤는 기본정보 뷰로 갈린 뒤 목록 안으로(§3-6 ⑥ 이 그 「돌아간다」를 본다). **중복처럼 보여도 뒤쪽 호출을 생략하면 안 된다.** 뒤따르는 것이 없는 `#mypage` 착지는 앞의 호출 하나로 맞는다. 🔴 **왼쪽을 바꾸는 함수(㉡)에 두면 안 된다** — 그 시점에는 오른쪽이 아직 안 정해져 낡은 상태를 읽는다.
  - ⚠️ **기존 호출 넷은 손대지 않는다**(§1-1 목록 그대로) — `navigate()`(`app.js`) · `openMypageSub` · **`closeMypageSub`**(무조건 올림) · `openMypageList`(무조건 내림) 넷 다 그대로. **새 가지가 늘 그 뒤**라 기존 호출과의 순서는 따지지 않아도 된다 — ㉢ 의 `navigate('mypage')` 가지가 `closeMypageSub()` **뒤**에 오고(그 호출은 `navigate()` 함수 맨 끝 `pageName==='mypage'` 블록 안이다), §3-4 도 `closeMypageSub` 를 안 고친다. 웹·`fill` 에서는 분할 가지가 안 돌아 기존 동작 그대로.
- `updateActiveTab`: 분할 모드의 탭은 **§3-2 표 「탭」 열** — 페이지 짝은 왼쪽 기준(`#page-campaigns`→`'campaigns'` / `#page-mypage` 응모이력→`'activity'`), 뷰 짝은 오른쪽 뷰 기준(응모이력 뷰→`'activity'` / 그 밖→`'mypage'`). **오른쪽을 켜는 가지(㉢)가 마지막에** `updateActiveTab` 을 부른다 — `navigate()` 안의 세 값 표는 그대로 두고 그 뒤에 덮는다. `tabNav` 가 끝에 부르는 `updateActiveTab(tab)` 은 같은 값을 다시 쓰므로 순서가 바뀌어도 결과가 같다.
- 히어로 위 투명 상단바: 테마의 `body:has(#page-detail.page.active…) .gnb` 를 **`html[data-layout="fill"]`** 로 한정(분할에서는 상단바가 두 열 폭이라 왼쪽 목록까지 투명해진다).
- 탭바 폭: 모드 무관이라 §3-1(앱이면 늘)에 있다. 여기서는 손대지 않는다.

**㉧ 그 밖의 분할 게이트**
- 뒤로 단추(`setGnbBack`·`.ios-tab-back`): 오른쪽 열 화면에서는 켜지 않는다. 상단 제목 `#gnbTitle` 은 오른쪽 화면 이름.
- `_detailFrom`(`application.js` `openCampaign`): 기존 **「덮지 않음」 예외는 그대로** — `.page.active` 가 상세·활동관리면 값을 유지한다(§1-1. `fill` 에서 응모이력→상세로 들어온 채 `split` 으로 바뀐 재라우팅, 상세→활동관리→뒤로 경로가 여기 걸려 `'mypage'` 가 살아남는다). 덮는 경우에만 분할 모드에서는 `.page.active` 의 id 대신 **`splitFromApplications()`(`app.js`)** 로 판정 — ①지금 `.split-left` 가 `#page-mypage`(응모이력→상세·메시지 짝) ②`data-split="view"` 이고 `#mypage-sub-applications.active`(마이페이지 짝의 오른쪽이 응모이력) 둘 중 하나면 `'mypage'`, 아니면 `'campaigns'`(`'home'` 은 분할 모드에서 안 나온다). 왼쪽이 `.active` 가 아니라 기존 판정이 홈으로 새는 것 방지 — `split`→`fill` 뒤 뒤로가기가 보던 목록으로 간다. 홈 카드에서 들어온 상세는 왼쪽이 캠페인 목록이 되므로 뒤로도 캠페인 목록(의도). 이 값을 ㉢ `detail-` 가지·㉦ 필터가 읽는다.
- 캠페인 필터 접기(`maxHeight:80px`): 분할 모드에서는 **접지 않는다**(왼쪽 320 에서 칩 줄이 늘어 잘린다).
- 당겨서 새로고침: 분할 모드에서는 **끈다**(`.page.active` 기준이라 왼쪽에서 당기면 오른쪽이 움직인다).
- 해시·새로고침·딥링크: 해시는 오른쪽 화면 기준 그대로. 착지 시 `routeHash` 가 짝의 왼쪽을 함께 켠다. `#campaigns` 착지는 오른쪽 빈 상태. **유일한 예외 `#mypage-list`** — 마이페이지 탭 진입 해시로, 오른쪽은 기본정보 뷰인데 주소는 목록(㉢. `tabNav`·popstate 의 `sub==='list'` 분기가 이미 이 해시를 쓰므로 재활용하고 다시 쓰지 않는다).
- 폴드: 속 세로 669 → `fill`, 속 가로 951 → `split`(③).

### 3-3. `triple` — 세로 메뉴 320 + 목록 320 + 상세 (≥1300, 13형 iPad 가로)
- `triple` 은 `data-split` 과 무관하게 **`#appShell` 이 늘 격자**(첫 열이 사이드바): `html[data-layout="triple"] #appShell{display:grid;grid-template-columns:320px 1fr;grid-template-rows:1fr}` · `[data-split="page"]` 면 `320px 320px 1fr`. 첫 열 = **`#iosSidebar`**(새 마크업 `dev/index.html`, `#appShell` 직계, `grid-column:1` — 탭바와 같은 4항목 홈·캠페인·응모이력·마이페이지 + 알림 벨, `data-tab` 동일. 웹 `components.css` 숨김, 테마가 `triple` 에서만 켬).
- 열 번호(㉠ 의 `split` 규칙을 `triple` 단독 선택자로 덮는다): `page` 짝 → `.page.split-left{grid-column:2}`·`.page.active{grid-column:3}` **+ `#page-split-empty.active{grid-column:3}`**(㉠ 의 빈 상태 규칙이 아이디라 클래스로는 못 덮는다 — 표기 규칙 🔴. 빠지면 빈 상태가 2열에 앉아 목록과 겹치고 3열이 빈다) / `view` 짝·짝 없는 화면 → `.page.active{grid-column:2;height:100%;min-height:0}`(㉠ 의 두 속성은 `page` 선택자에만 걸려 있어 여기서 다시 적는다 — 빠지면 스크롤이 죽는다. 뷰 격자는 그 안에서 ㉠ 그대로) / 그 밖의 `.page` 는 `display:none` 그대로.
- `#iosTabbar` 는 `triple` 에서 숨긴다(사이드바가 대체). `updateActiveTab` 이 사이드바 항목에도 같은 `data-tab` 으로 활성 표시.
- 응모 바는 `html[data-layout="triple"] #detailFloatBar{left:calc(640px + env(safe-area-inset-left))}`(㉤ 의 나머지 값과 인셋을 더하는 이유는 표기 규칙대로 이미 `triple` 에 걸려 있다).
- 그 밖(㉡·㉢·㉣·㉥·㉦·㉧ 의 자바스크립트 가지, ㉠·㉤·㉦ 의 CSS)은 §3-0 표기 규칙대로 `split`·`triple` 공통 — 이 절이 따로 적지 않은 것은 전부 §3-2 가 정한다.

### 3-4. 바꾸는 파일 (전부 `feature/ios-app`)
| 파일 | 무엇 | 웹 영향 |
|---|---|---|
| `ios-app/www/ios-theme.css` | §3-1 덮어쓰기(변수·시트·안전영역·카드 열·탭바 상한) · `html[data-layout]`·`[data-split]` 배치 규칙(㉠ 격자·빈 상태 페이지 켜기·㉣ 색·㉤·㉦ 투명 상단바·§3-3 사이드바) | 없음(앱 빌드에만 주입) |
| `dev/js/app.js` | `iosLayoutMode()` · `data-layout` 부착·`matchMedia` 리스너(㉥) · `routeHash` 추출(㉥) · `splitShowLeft`·`splitClearLeft`(㉡) · `splitFromApplications()`(㉢) · `navigate` 분할 가지(㉢ `detail-`·`campaigns`(왼쪽 목적지 → `#page-campaigns` 는 `.split-left` 만, `.active` 는 `#page-split-empty` 에)·`mypage`·짝 없는 화면 · 가지 끝의 ㉣ 선택 표시·㉦ 탭·필터 · ㉦ 상단바 숨김 · ㉧ 뒤로 단추·새로고침) · `updateActiveTab` 사이드바 | 동작 변화 0(diff 로 검증) |
| `dev/js/application.js` | `openCampaign` 의 `_detailFrom` 판정 분할 가지(㉧) · **선택 인자 `opts.skipViewCount`**(㉥ — 모드 전환 재라우팅만 준다) | 동작 변화 0(인자를 안 주면 기존과 같다) |
| `dev/js/mypage.js` | `openMypageList`·`openMypageSub` 분할 가지(㉢ · 가지 끝의 ㉣ 셀·㉦ 탭·필터) — `closeMypageSub` 는 손대지 않는다 | 동작 변화 0 |
| `dev/js/messaging.js` | `openMessagesPage` 분할 가지(㉢ · 가지 끝의 ㉣ 응모이력 카드·㉦ 탭 `activity`·필터) | 동작 변화 0 |
| `dev/js/campaign.js` | 카드 `data-id`(㉣) · 필터 접기 게이트(㉧) | 속성 하나 추가·동작 변화 0 |
| `dev/index.html` | `#page-split-empty`·`#iosSidebar` 마크업 | 웹은 `display:none` |
| `dev/css/components.css` | 위 둘의 `display:none` 두 줄 | 숨김만 |
🔴 공용 파일 일곱은 **iOS 브랜치에 커밋되고 dev 에는 안 간다**(§1-2). 나중을 위해 게이트는 처음부터. `application.js` 는 웹 공용 수정 2건 이식(§1-6)과 겹치므로 그 이식 뒤에 만진다.

### 3-5. 하지 않는 것
- 탭바를 iPad 상단으로 옮기기(iPadOS 최신 관습) — 후속. `triple` 만 사이드바.
- 카드·상세·폼·대화의 안쪽 재설계 — Apple 지침 화면 재설계 몫.
- 짝 없는 화면 열(§3-2 ㉢)의 2단 — 1단 전체(`triple` 은 사이드바 320 을 뺀 나머지).
- 접힘선(크리스) 대응 — 실기기 뒤 후속. (Duo 비대칭 인셋은 「하지 않는 것」이 아니다 — §3-1 안전영역 패딩이 처리하고 ⑨ 에서 확인만 미룬다.)
- 기존 네이티브 인라인 판정 11곳의 헬퍼 통합 — 범위 밖.
- 로딩 방식 A/B/C · 앱스토어.

### 3-6. 검증 (완료 기준)
1. **웹 무변화(양성 대조)** — 기준은 **iOS 브랜치의 착수 직전 커밋**(dev 판이 아니다 — iOS 브랜치는 dev 에 없는 마크업·분기를 이미 갖고 있어 dev 와는 원래 다르다). 착수 전에 그 커밋의 웹 빌드(`index.html`)를 로컬 미리보기로 띄워 **390·1180** 폭에서 홈·목록·상세·마이페이지(응모이력·프로필)·메시지 6화면을 찍어 두고, 구현 뒤 같은 조건으로 다시 찍어 **픽셀 단위로 같다**(웹에는 `data-layout`·`data-split` 이 안 붙는다). 🔴 0이 아니면 게이트가 샌 것.
   - 🔴 **크롬 창을 줄이는 방법으로는 390 을 못 만든다** — 이 기기의 크롬은 **뷰포트가 606px 아래로 안 내려간다**(2026-09-11 웹 구현 세션 실측). 1180 은 그대로 된다.
   - → **390 은 폭을 지정한 iframe 안에 같은 원본 미리보기를 띄워** 그 영역을 찍는다(iframe 안 뷰포트가 390 이 된다). **먼저 그 방법이 이 기기에서 실제로 되는지 확인하고 시작한다** — 안 되면 아래 폴백으로 바꾸고 그 사실을 「구현 결과」에 적는다.
   - **폴백(그 방법이 안 되면)** — ①배포 전후 CSS 전문을 **줄 단위로 대조**(웹 구현 세션이 실제로 쓴 방법)하고 ②이 사양의 공용 자바스크립트 변경이 **전부 `iosLayoutMode()` 가 `split`/`triple` 일 때만 도는 조건문 안**에 있는지 분기마다 눈으로 확인한다. ⚠️ **①만으로는 부족하다** — 이 사양에서 웹에 샐 위험이 큰 쪽은 CSS 가 아니라 자바스크립트다(§2 ①).
2. **아이패드 시뮬레이터 세 종**(iOS 세션) — 미니(744 세로 `fill` 카드 3열 / 1133 가로 `split`) · 11형(820 세로 `split` / 1180 가로 `split`) · 13형(1032 세로 `split` / 1376 가로 `triple`). 각 모드에서 네 짝이 §3-2 표대로, 짝 없는 화면은 1단(`triple` 은 사이드바 옆 1단).
3. **실행 중 모드 전환** — 앱을 켠 채 회전, 분할 화면 폭을 끌어 820·1300 을 넘나든다: 열 겹침·빈 화면·스크롤 죽음 없음. 시트가 열린 채 돌려도 시트 밑 화면이 안 바뀐다. **상세를 보는 중 회전 전후로 그 캠페인 조회수가 안 오른다**(㉥ — 관리자 캠페인 목록의 조회 열로 대조. 미니 744↔1133 이 정확히 모드 경계라 여기서 본다). (폴드 접기·펴기의 **모드 전환**은 이것으로 대신.)
4. **빈 상태·선택·뒤로** — 캠페인 탭 첫 진입에 빈 상태 페이지, 카드를 누르면 오른쪽 상세 + 카드 `.is-selected`(응모이력 카드→상세·메시지, 목록 셀→폼도 각각 선택 표시 하나만), 오른쪽 화면에서 뒤로 단추 없음, 응모 바가 상세 열 안(도킹 전·후 모두 안 튄다). **`triple`(13형 가로)에서도 같은 진입에 빈 상태가 3열**(사이드바·목록 오른쪽)이고 2열과 안 겹친다(§3-3 — 아이디 특이도를 안 맞추면 여기서 드러난다). 응모이력 탭(목록 셀 + 응모이력 뷰)에서 캠페인을 누르면 목록 셀이 사라지고 왼쪽이 응모이력, 탭이 「응모이력」. 마이페이지 탭은 목록 셀 + 기본정보 뷰, 탭이 「마이페이지」, 주소 `#mypage-list`. 상세를 보다 캠페인 탭을 누르면 오른쪽이 빈 상태로 돌아가고 **카드의 선택 표시도 사라진다**(잔상 없음). 홈·활동관리 등 짝 없는 화면은 1단 전체·왼쪽 잔상 없음.
5. **해시** — `#detail-{id}`·`#messages-{id}`·`#mypage-profile-basic` 로 새로고침·딥링크 착지 시 왼쪽 짝이 함께 켜지고 **주소가 안 바뀐다**(㉡).
6. **메시지 짝**(`split` 기준 — `triple` 은 탭바 대신 사이드바, ⑧에서 본다) — 상단바·탭바가 보이고, 응모이력 필터가 상단바에 있고, 탭 활성이 「응모이력」(`activity`). **거기서 마이페이지 탭으로 옮기면 필터가 목록으로 돌아간다**(㉦ — 오른쪽이 기본정보 뷰라 응모이력 목록이 화면에서 사라지므로). 응모이력 탭(목록 셀 + 응모이력 뷰)에서 메시지 단추를 누르면 목록 셀이 사라지고 응모이력이 왼쪽으로 온다.
7. **시트** — 응모 모달·약관·알림이 두 열을 덮는 가운데 카드(560).
8. **탭바·사이드바** — `fill`·`split` 탭바 480 상한, `triple` 탭바 숨김 + 사이드바 활성(**메시지 짝에서도** 그렇다 — ㉦ 게이트는 자바스크립트 숨김만 끄고 `triple` 의 숨김은 CSS 몫).
9. **Duo**(Xcode 27.1 + 실기기 뒤) — 속 세로 `fill`, 속 가로 `split`, 좌우 인셋 비대칭.

### 3-7. 순서·배포
1. **선행**: 웹 사양서 조각 2~6 dev 병합 → 웹 공용 수정 2건 이식(`application.js`) → iOS 브랜치 dev 재병합.
2. **1단계 `fill`** — `ios-theme.css` 만(§3-1). 앱 빌드 → 미니 세로.
3. **2단계 `split`** — 짝을 **캠페인 → 마이페이지(뷰) → 응모이력→상세 → 메시지** 순으로. 첫 짝에서 ㉠·㉡·㉥ 토대가 들어가고, **마이페이지 짝이 둘째**인 이유는 응모이력→상세·메시지 짝의 **정상 진입 경로**가 응모이력 탭(= `navigate('mypage')` 가지 + `openMypageSub('applications')` 가지의 `splitShowLeft('mypage-list')`)이라, 그 짝을 먼저 두어야 셋째·넷째를 사용자 동선대로 검증할 수 있기 때문. 딥링크(`#messages-{id}`)·`fill`→`split` 회전으로도 닿지만 그것은 ㉥·§3-6 ③⑤ 의 별도 검증 항목이다. 짝마다 앱 빌드·시뮬레이터. 각 커밋에 `reverb-reviewer`(리뷰 항목: **웹 동작 변화 0** — 게이트 조건이 분할 모드로 닫혀 있는지).
4. **3단계 `triple`** — 사이드바. 13형 가로.
5. 데이터베이스 없음 → supabase-expert 불필요. qa-tester 는 ①에 한해 light 권장(단일 세션·사용자 트리거).
6. **Xcode 27.1** 로 재빌드 → ⑨.

---

## 4. 사용자 확인
| # | 물은 것 | 결정 |
|---|---|---|
| Q1 | 적용 범위 | **iOS 앱에서만** |
| Q2 | 대상 화면 | **캠페인·마이페이지·메시지 세 화면** |
| Q3 | 폴드 속 화면 | **세로 1단 채우기·가로만 2단** |
| Q4 | 3단 범위 | **13형 iPad 가로에서만** |
| Q5 | 2단 시작 폭 | **820 이상** |

**아직 안 물은 것(권고안대로 진행, 반대면 알려 주세요)**: 캠페인 짝의 오른쪽 빈 상태는 안내 문구 「왼쪽에서 선택해 주세요」(첫 항목 자동 선택 안 함) · 마이페이지 탭의 오른쪽 기본은 **기본정보 뷰**(응모이력 탭과 같은 화면이 되지 않게 — §2-8) · 앱 카드는 폭 따라 열 수 자동(200px 최소, 홈 포함 — 분할 모드 왼쪽 320 열만 1열) · 앱 읽기 폭 672(시트는 560) · 탭바는 `fill`·`split` 그대로, `triple` 만 사이드바.

---

## 5. 구현 결과 (iOS 개발 세션이 채울 것)
- 단계별 커밋 · 웹 동작 변화 0 확인(§3-6 ①) · 시뮬레이터 세 종(②) · 모드 전환(③) · Duo(⑨, 뒤에)
- 응모이력 카드·목록 셀의 식별 속성(㉣)을 어떻게 했나 · 홈 카드→상세의 뒤로가 캠페인 목록으로 가는 것(㉧)이 실제로 어색하지 않았나
- 초안 대비 변경(추가/빠짐/달라짐)
