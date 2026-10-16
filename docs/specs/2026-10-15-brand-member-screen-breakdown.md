# 📋 작업 분해표 — 브랜드 페이지 멤버 관리·여러 브랜드 · 묶음 ② 브랜드 화면(`dev/brand/`)

**사양서:** `docs/specs/2026-07-15-brand-portal.md` §16-2~16-5, **§16-7(결정 정본)**, §15(화면 코드) · 「구현 결과 — 묶음 ①」·「운영 반영 전 남은 관문」
**받아 쓰는 계약:** 묶음 ① 작업표 `docs/specs/2026-10-15-brand-member-breakdown.md` + **실제 원본**(`supabase/migrations/530~533`, `supabase/functions/notify-brand-invite`·`brand-invite-accept`). 둘이 다르면 실제를 정본으로 적었다(아래 「stale 점검」).
**분해일:** 2026-10-15
**범위:** 묶음 ②(브랜드 화면)만. 묶음 ③(관리자 화면 `admin-brand.js`)은 공유 지점 경고로만 적는다.
**총 작업 조각:** 11개(조각 1~10 + 데이터베이스 조각 4a) · **병렬 가능:** 2줄기(조건부 — 조각 2 뒤 「5→6」 ∥ 「3→4→7→8」) + 데이터베이스 조각 4a 는 조각 4 전 언제든 따로 · **순차 필수:** 나머지

> **화면 문구 언어:** 한국어. `dev/brand/index.html` 이 `lang="ko"` 이고 지금 문구가 모두 한국어다(브랜드 담당자 = 한국 광고주). 일본어 문구는 이 묶음에 없다.
> **데이터베이스 변경:** **조각 4a 하나뿐** — S0-2 결정(피그마대로 이메일 칸을 보여 준다) 때문에 링크 판정 함수가 이메일을 돌려줘야 한다. 나머지는 묶음 ①의 함수 + 526 의 「본인 행 읽기」 정책으로 된다(번호는 작성 시 확정).
> 🔴 **개발서버 전용**(작업표 P-1): 새 코드는 모두 `brandDb`(운영 주소에서는 `null` — `initBrandClients`)를 통해서만 서버를 부른다. 운영 주소는 지금처럼 「준비 중」 카드만.

---

## 현재 상태 (2026-10-15 코드 확인)

| 항목 | 실제 |
|---|---|
| 화면 파일 | `dev/brand/index.html`(426줄 — 카드형 화면 14개 + 약관 창 + 개발서버 미리보기 막대) · `dev/js/brand-core.js`(175 — 연결 둘 `brandDb`·`brandSetupDb`, `brandRpc`, 오류 표시, 비밀번호 규칙 사본) · `brand-login.js`(593 — 로그인·찾기·설정·재설정·계속하기, 초대 수락·이메일 변경은 **가짜 요청 미리보기**) · `brand-app.js`(305 — 부팅·해시 라우팅·메일 링크 착지) · `dev/css/brand.css`(280) |
| 로그인 뒤 | **임시 첫 화면 `home` 카드 하나**(이름·이메일·연결 브랜드 목록·로그아웃). 좌측 메뉴·브랜드 전환·03~07 페이지 **전부 없음**. `routeBrand` 는 로그인 상태면 무조건 `home` |
| 로그인 판정 처리 | `applyBrandLoginState` — `state==='ok'` 아니면 **무조건 로그아웃**(`brand-login.js` 77~91행). 모르는 `state` 는 로그인 화면 + 「확인하지 못했습니다」 |
| 메일 링크 착지 | `handleBrandLinkLanding` 은 `mode=setup|reset` 만 받는다(128행) — 초대 메일 링크 `?link=…&kind=invite`(`notify-brand-invite` 221행)는 **지금 「쓸 수 없는 링크」로 떨어진다** |
| 공용 부품 | `brand-core.js` 에 `brandEsc`(글자 이스케이프)·`isEmailFormat`(이메일 형식)은 **있다**. 토스트·확인 창·날짜 표기 함수 **없음**(`ui.js` 를 싣지 않는 자립형 화면). 서버 함수 호출은 `requestBrandPasswordReset` 의 `fetch` 한 곳뿐(로그인 토큰 없이) |
| 빌드 | `dev/build.sh` 7절 `BRAND_CSS_FILES`·`BRAND_JS_FILES`. 원본 태그 제거 정규식은 **`../(lib|js)/…`·`../css/…` 일반식**이라 새 파일은 **목록만** 고치면 된다(관리자 빌드와 달리 정규식에 이름을 넣을 필요 없음) |
| 서버(묶음 ①, 개발서버 적용) | 대표 함수 7(531) · 받는 사람·본인 함수 + 로그인 판정 재정의(532) · 메일 함수 `notify-brand-invite`(로그인 토큰 필요) · `brand-invite-accept`(비로그인 공개) |
| 본인 행 읽기 | 526 정책 `brand_accounts_select`: `auth_id = auth.uid()` 면 본인 행 읽기 가능 → 마이페이지 연락처(`phone`)는 함수 없이 읽을 수 있다(로그인 판정 응답에는 `phone` 이 없다) |
| 미해결 백로그(이 묶음과 맞닿음) | 흔히 쓰는 비밀번호 경고(사양서 16-4 ⑤ 「경고만」, Figma w01-92·w07-01c)는 **브랜드 화면에 아직 없다** · 옛 오리엔시트 작성 링크 예외(w01-09)·오리엔시트 목록(w04-00)은 04 페이지 작업 몫 · 「대표 넘기기」가 담당자 목록을 옮기는 경로는 묶음 ③ 전까지 덮어쓰기 위험(공유 지점 경고) |

---

## 의심·경우의 수 (반대론자)

1. **(사용 흐름) 로그인 뒤 갈 곳이 없다** — 사양서는 「로그인 뒤 첫 페이지 = 오리엔시트 목록(w04-00)」인데 04 페이지는 이 묶음 밖이다. 멤버 관리·마이페이지만 만들면 좌측 메뉴의 다른 항목과 첫 페이지가 비어, 「눌렀는데 아무것도 없다」가 된다 → 선결 S0-1.
2. **(사용 흐름) 초대 링크가 지금 전부 막혀 있다** — 묶음 ①의 초대 메일이 개발서버에서 이미 나가는데, 화면은 `kind=invite` 를 모른다. 이 묶음 전까지 받은 초대 링크는 모두 「쓸 수 없는 링크」로 보인다(시험자가 「서버가 틀렸다」로 오판하기 쉽다).
3. **(기술) 수락 함수 오류가 400·500** — `functions.invoke` 는 2xx 가 아니면 본문을 오류 객체 안에 감춰 `reason` 을 못 읽고 「일반 실패」로 그리게 된다 → 공용 호출 도우미를 `fetch` 로 만들어 **상태 코드와 본문을 함께** 돌려준다(조각 1 계약).
4. **(데이터) 새 이메일 초대 화면에 이메일을 못 띄운다** — Figma w01-02b 는 이메일 칸(읽기 전용)이 있는데, 링크 판정 함수 `get_brand_invite_link_state` 는 이메일을 돌려주지 않는다(532 546~598행) → 선결 S0-2.
5. **(권한) 다른 계정으로 로그인된 브라우저에서 ⓑ 초대 링크를 염** — 링크 판정은 「누구에게 온 초대인지」를 안 알려 주므로(의도) 화면은 미리 막을 수 없고, 「수락」을 눌러야 서버가 `invalid` 로 거부한다 → 선결 S0-5.
6. **(기술) 비밀번호 변경의 현재 비밀번호 확인** — 작업표 설계 메모대로 「저장하지 않는 별도 연결로 현재 비밀번호 로그인 → `updateUser`」. 인증 설정 「Secure password change」(재인증 요구)가 켜져 있으면 `updateUser` 가 `reauthentication_needed` 로 막힌다 — 개발서버 설정을 착수 때 확인(조각 8 검문소).
7. **(데이터) 브랜드 정렬이 서버와 다르다** — 로그인 판정 `brands` 는 「대표 먼저 + 데이터베이스 이름순」, 화면 규칙은 「지금 브랜드 맨 위 + 한글 가나다 → 영문 ABC」. 화면이 다시 정렬해야 하고, 브라우저의 한국어 정렬이 한글을 영문보다 앞에 두는지 실제로 확인해야 한다(조각 2 완료 정의).
8. **(법률·약관) 「마지막 접속」 기록이 실제로 쌓이기 시작한다** — 이 묶음이 `touch_my_brand_activity` 를 처음 부른다. 이용 기록이라 운영 관문 10번(`/약관확인`·보관 기간)에 이미 걸려 있다 — 개발서버만이라 막지 않지만 운영 반영 전 판단에 포함.

**현재 구현과 충돌하는 지점:** ①`applyBrandLoginState` 의 「ok 아니면 로그아웃」(주의점 1) ②메일 링크 착지의 `mode` 전용 판정(위 2번) ③`routeBrand` 의 「로그인 상태면 무조건 `home`」 ④`home` 임시 카드(대체 대상).

**권고(결정 뒤 갱신):** 데이터베이스는 조각 4a(링크 판정 이메일) 하나만, 나머지는 화면 — 11조각 순차. 첫 조각에서 **좌측 메뉴 틀 + 공용 부품(토스트·확인 창·서버 함수 호출·날짜 표기) + 새 파일 빌드 등록**을 한 번에 깔아, 뒤 조각이 `build.sh`(핫스팟)를 다시 만지지 않게 한다.

---

## ✅ 선결 결정 결과 (2026-10-15 사용자 결정)

| # | 결정 | 반영 |
|---|---|---|
| S0-1 | **전체 메뉴 + 준비 중** — 브랜드·오리엔시트·캠페인·멤버 관리·마이페이지 메뉴를 다 두고, 없는 화면은 「준비 중」 한 장. 첫 페이지 = 오리엔시트 자리 | 조각 1 |
| S0-2 | **피그마·화면 설명과 똑같이** — w01-02b 에 이메일 칸(읽기 전용 회색 모양, 초대받은 이메일). 피그마 설명 패널에는 이메일 칸 규칙 문장이 없고 그림만 있다(2026-10-15 읽음) → 링크 판정 함수가 `recipient='new'` 일 때 이메일을 돌려주게 고친다(조각 4a). ⚠️ 링크를 전달받은 사람에게도 초대받은 이메일이 보인다 — 사용자가 피그마대로 택함 | 조각 4a·4 |
| S0-3 | **마지막 조각으로 넣는다** — 흔한 비밀번호 경고(조각 9) | 조각 9 |
| S0-4 | **브랜드 바꾸기도 센다(마이페이지는 제외)** — 사람이 누른 메뉴 이동·저장 성공·브랜드 바꾸기는 「마지막 접속」으로 센다. 마이페이지로 가는 이동·마이페이지 안의 저장(정보 수정·비밀번호 변경·초대 수락·거절)·로그인 직후 자동 이동은 세지 않는다(계정 화면이라 어느 브랜드의 활동도 아니다) | 조각 1·2 |
| S0-5 | **수락 때 서버가 거부** — 데이터베이스 변경 없음. w01-03 의 「초대받은 계정」 칸 = **지금 로그인한 계정 이메일**(`brandSession.email` — 받는 사람이 로그인한 뒤에만 이 화면이 뜨므로 서버 값 없이 된다. 다른 계정이면 사람이 그 칸을 보고 알아챌 수 있다) | 조각 3·4 |
| S0-6 | **개발이 세로로 접는다** — 좁은 폭에서 표의 줄을 카드처럼 쌓는다. 피그마 모바일 그림이 생기면 맞춘다 | 조각 5·7 |

---

## 🚦 착수 전 선결 조건

| # | 선결 조건 | 근거 | 막는 조각 |
|---|---|---|---|
| S0-1 | **(결정됨 — 위 결정 표) 로그인 뒤 틀의 범위** | 16-4 「로그인 뒤 첫 페이지 = 오리엔시트 목록(w04-00)」인데 03·04·05 페이지는 이 묶음 밖 | 1 (이후 전부) |
| S0-2 | **(결정됨 — 위 결정 표) 새 이메일 초대 화면(w01-02b)의 이메일 칸** | Figma 에 이메일 칸이 있으나 링크 판정 함수가 이메일을 안 돌려줌 | 4 |
| S0-3 | **(결정됨 — 위 결정 표) 흔히 쓰는 비밀번호 경고를 이 묶음에 넣을지** | 16-4 ⑤ 「경고만」 · Figma w01-92·w07-01c · 지금 브랜드 화면에 없음 | 9 |
| S0-4 | **(결정됨 — 위 결정 표) 「마지막 접속」을 남기는 동작의 경계** | 16-4 「화면 정책 넷」 ③ 「사람이 누른 화면 이동·저장만」 — 브랜드 바꾸기·마이페이지 들어가기가 그에 드는지 미정 | 1·2 |
| S0-5 | **(결정됨 — 위 결정 표) 다른 계정으로 로그인된 채 ⓑ 초대 링크를 열 때** | 위 의심 5번 | 3·4 |
| S0-6 | **(결정됨 — 위 결정 표) 멤버 관리(06)·마이페이지(07) 모바일 모양** | §15 목록에 `m06`·`m07` 화면이 없다(웹만, 빨간 점 `m07-03` 뿐) | 5·7 |
| S0-7 | 개발서버 시험 데이터 준비 — 브랜드 둘 이상에 연결된 계정, 비밀번호를 정한 두 번째 브랜드 계정(ⓑ 갈래), 상한을 올린 시험 브랜드(`brand_member_limits` — 기본 5라 초대 5건째부터 `seat_full`) · 브랜드 8개 이상 연결 계정(검색 시험) | 묶음 ① 「시험 팁」 | 2·3·4·5 완료 확인 |
| S0-8 | 개발서버 인증 설정 「Secure password change」 켜짐 여부 확인 | 의심 6번 | 8 |


---

## ⚠️ 사양서·작업표 stale 점검

1. **초대 링크 착지 형식** — 작업표 조각 5 는 「`PUBLIC_BRAND_URL/brand/?link=…&kind=invite`」로 적었고 실제도 같다. 그런데 **브랜드 화면은 `mode` 만 본다** → 조각 4 에서 착지 판정에 `kind=invite` 갈래를 더한다(지금은 무조건 「쓸 수 없는 링크」).
2. **`notify-brand-invite` 응답** — 작업표 계약 `{sent, reason?, dev_mail?}` / 실제: 200 `{sent:true}` · 200 `{sent:true, dev_mail:{subject, text}}`(개발서버 두 겹 잠금) · 200 `{sent:false, reason:'not_pending'|'already_sent'|'send_failed'}` · 400 `invalid_request` · 401 `unauthorized` · 403 `forbidden` · 500 `server_error`. 개발서버에서는 `mail_sent_at` 을 안 남기지만 선점(`mail_sent_link_id`)은 해서 **같은 링크 두 번째 호출은 `already_sent`**.
3. **`brand-invite-accept` 응답** — 실제: 200 `{ok:true, email}` · 200 `{ok:false, reason:'invalid_link'|'password_rejected'}` · **400 `invalid_request`(작업표에 없던 값)** · 500 `server_error`. 서버 입력 한도 이름 100자·연락처 50자·약관 판 50자·비밀번호 최소 6자(화면 규칙 8자+소문자+기호는 화면 몫). 응답에 `brand_id` 가 없다 — 새 계정은 연결 브랜드가 하나뿐이라 로그인 판정의 `brands[0]` 으로 충분.
4. **`resend_brand_invite` 응답** — 작업표 `{result, invite_id}` / 실제 `{result, invite_id, seat_used, member_limit}`(키 4개, 531 `_brand_invite_result`). 취소·숨기기는 대표가 아니거나 줄이 없으면 전부 `not_owner`, 다시 보내기는 줄이 없거나 연결이 없으면 `not_found`.
5. **`get_brand_members`** — 실제 행 키: `kind`·`auth_id`(대표 호출만)·`invite_id`·`name`·`email`·`role`·`status`(`active|pending|expired|declined`)·`issued_at`·`expires_at`·`declined_at`·`last_active_at`. **발송 성공 여부(`mail_sent_at`)는 행에 없다** → 화면은 「메일 미발송」 줄을 따로 그릴 수 없다. 발송 실패는 그 순간 토스트로만 알린다(16-7 「발송 실패해도 대기 줄은 남긴다 — 다시 보내기로 복구」와 맞음).
6. **로그인 판정 `last_brand_id`** — 532 가 「지금 활성 연결일 때만 값, 아니면 NULL」로 걸러 준다. 대표 해제(`release_brand_member`·`admin_release_brand_account`)가 그 칸을 안 바꿔도 화면은 NULL 만 처리하면 된다 → 폴백 「이름순 첫 브랜드」는 **화면 몫**(조각 2).
7. **Figma w07-00b·w07-02 의 「10/21까지」(7일)** — 실제 초대 유효 24시간(16-7). 화면은 `expires_at` 을 그대로 그리므로 코드 영향 없음. Figma 정리는 기획 몫.
8. **브랜드 빌드 「두 곳」** — `build.sh` 주석·`build.md` 는 「목록과 정규식 두 곳」이라 하지만 브랜드 빌드 정규식은 일반식이다. 새 파일은 **목록 한 곳**만 고친다(문서 정정은 조각 10 에서 `build.sh` 주석 + `build.md` 는 고문에게 넘김).
9. **`brand-login.js` 머리 주석** — 「초대 수락(w01-03)은 미리보기 막대 전용(`brandFakeRequest`)」 → 조각 3 이후 거짓이 된다. 같은 조각에서 고친다. 이메일 변경(w01-04) 미리보기 마크업·`brandFakeRequest` 는 보류 화면이라 그대로 둔다.

---

## 한눈에 보는 의존 순서

```
S0-1·S0-4 → 1 틀·공용 부품·빌드 등록        4a 링크 판정 이메일(데이터베이스, 언제든 — 4 전)
              ├→ 2 브랜드 고르기 → 3 초대 수락 화면(로그인 경로) → 4 메일 링크 초대 착지(ⓐ·ⓑ)
              │                         └→ 7 마이페이지(정보·받은 초대·빨간 점) → 8 비밀번호 변경
   (2 뒤)  └→ 5 멤버 관리 목록·초대 → 6 멤버 관리 정리 동작(취소·삭제·넘기기·해제)
   (4·8) → 9 흔히 쓰는 비밀번호 경고(S0-3 결정 — 넣는다) → 10 문서·처음부터 끝까지 확인
(병렬 가능은 조각 2 뒤 「5→6」 줄기와 「3→4→7→8」 줄기 둘 + 데이터베이스 조각 4a(조각 4 전 언제든) — 조건은 「공유 지점 경고」. 배분 제안은 1명 순차)
```

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약(요지) | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| 1 | 로그인 뒤 틀 + 공용 부품 + 새 파일 빌드 등록 | `dev/brand/index.html` · `dev/css/brand.css` · `dev/js/brand-core.js` · `dev/js/brand-app.js` · `dev/js/brand-login.js` · **새** `dev/js/brand-shell.js` · 빈 껍데기 `brand-invite.js`·`brand-members.js`·`brand-mypage.js` · `dev/build.sh` | `brandToast` · `brandConfirm` · `brandCallFunction` · `brandFormatDateTime` · `brandSession` · `enterBrandApp` · `refreshBrandLoginState` · `getCurrentBrandId` · `registerBrandPage` · `onBrandChanged` · `brandTouchActivity` · 해시 `#orient`·`#members`·`#mypage` 등 · `#brandShell` | S0-1·S0-4 | ✗ | 개발 |
| 2 | 좌측 위 브랜드 고르기(웹·모바일·8개 이상 검색) | `brand-shell.js` · `brand.css` · `index.html` | `switchBrand(id)` · 정렬 `sortBrandsForPicker` · `handleBrandNotLinked()` | 1 | ✗ | 개발 |
| 3 | 로그인 판정 갈래 + 초대 수락 화면 w01-03(로그인 경로) + 거절 확인 w01-10 | `brand-login.js` · `brand-invite.js` · `brand-app.js` · `index.html` · `brand.css` | `respondBrandInvite({inviteId, linkId, action})` · `showInviteScreen(source)` · `#invite` 실제 연결 | 2 | ✗ | 개발 |
| 4 | 메일 링크 초대 착지 — ⓑ 로그인해서 수락 · ⓐ 새 이메일 비밀번호 설정(w01-02b) | `brand-app.js` · `brand-invite.js` · `brand-login.js` · `index.html` | `kind=invite` 착지 · 세션 저장 칸 `reverb.brandInviteLink` · `brand-invite-accept` 호출 | 3 | ✗ | 개발 |
| 4a | 링크 판정 함수가 새 이메일 초대의 이메일을 돌려줌(데이터베이스) | 새 마이그레이션(번호 작성 시 확정) | `get_brand_invite_link_state` 응답에 `issued_at` + `email`(`recipient='new'` 일 때만) | 없음 | ○(1~3과) | 개발 |
| 5 | 멤버 관리(06) 목록 + 초대 모달 + 초대 메일 + 다시 보내기 | `brand-members.js` · `brand.css` | `#members` 페이지 · `sendBrandInviteMail(inviteId)` | 2 | △(3·4·7·8과) | 개발 |
| 6 | 멤버 관리 정리 동작 — 취소·삭제·대표 넘기기·해제 | `brand-members.js` · `brand.css` | 확인 모달 w06-02·w06-03 | 5 | △(3·4·7·8과) | 개발 |
| 7 | 마이페이지(07) — 계정 정보 보기·수정 · 연결된 브랜드 · 받은 초대 · 빨간 점 | `brand-mypage.js` · `brand-shell.js`(빨간 점 자리) · `brand.css` | `#mypage` 페이지 · `refreshInviteDot()` | 3 | ✗ | 개발 |
| 8 | 마이페이지 비밀번호 변경 모달(w07-01) | `brand-mypage.js` · `brand-core.js` · `brand.css` | 현재 비밀번호 확인용 일회 연결 `brandVerifyCurrentPassword`(→ 구현은 `brandChangePasswordWithCurrent` — 맨 아래 구현 결과) | 7·S0-8 | ✗ | 개발 |
| 9 | 흔히 쓰는 비밀번호 경고 | `brand-core.js` · `brand-login.js` · `brand-invite.js` · `brand-mypage.js` | `brandCommonPasswordCheck(pw)` | 4·8·S0-3 | ✗ | 개발 |
| 10 | 문서 + 개발서버 처음부터 끝까지 확인 | 사양서 「구현 결과」 · `docs/FEATURE_SPEC.md` · `CLAUDE.md` · `dev/build.sh` 주석 | — | 1~9·4a | ✗ | 개발(규칙 파일은 고문에게 넘김) |

---

## 조각별 상세

### 작업 1 — 로그인 뒤 틀 + 공용 부품 + 새 파일 빌드 등록
- **하는 일:** 임시 `home` 카드를 걷고 좌측 메뉴 틀(웹) + 맨 위 막대·메뉴 서랍(모바일, 오른쪽에서 나옴)을 만든다. 메뉴 맨 아래 「이름 · 마이페이지」·「로그아웃」은 늘 있다. 이 묶음이 쓰는 공용 부품(토스트·확인 창·서버 함수 호출·날짜 표기)을 `brand-core.js` 에 두고, 새 화면 파일 셋을 빈 껍데기로 빌드에 미리 등록해 뒤 조각이 `build.sh` 를 다시 만지지 않게 한다. 브랜드 고르기 자체(조각 2)·초대 화면(조각 3)은 아직 — 이 조각은 「브랜드가 하나 이상 있는 계정」만 틀로 들어온다(그 밖 갈래는 지금 처리 그대로).
- **담당 파일:** `dev/brand/index.html`(틀 마크업 · `home` 카드 제거 · 새 `<script>` 셋) · `dev/css/brand.css` · `dev/js/brand-core.js` · `dev/js/brand-app.js`(`routeBrand` 재작성 · 부팅) · `dev/js/brand-login.js`(`fillHomeScreen`·`initHome` 제거, 로그인 성공 뒤 `enterBrandApp`) · 새 `dev/js/brand-shell.js` · 빈 껍데기 `dev/js/brand-invite.js`·`brand-members.js`·`brand-mypage.js` · `dev/build.sh`(`BRAND_JS_FILES` 순서: `lib/supabase.js` → `brand-core` → `brand-login` → `brand-invite` → `brand-shell` → `brand-members` → `brand-mypage` → `brand-app` 맨 끝)
- **산출 계약:**
  - 공용 부품(`brand-core.js`)
    - `brandToast(msg)` — 글자만(아이콘·이모지 없음), 화면 아래 `role="status"`
    - `brandConfirm({title, body, okLabel, cancelLabel, danger}) → Promise<boolean>` — 모달을 **동적 생성**(index.html 을 조각마다 고치지 않게), `Esc`·바깥 클릭 = 취소, 열 때 첫 단추 초점, 닫을 때 원래 초점 복귀
    - `brandCallFunction(name, body, {auth}) → {status, body}` — `fetch(SUPABASE_URL + '/functions/v1/' + name)` + `apikey`. `auth:true` 면 `brandDb` 세션의 접근 토큰을 `Authorization` 에, 401 이면 `refreshSession` 뒤 한 번 다시. **상태 코드와 응답 본문(JSON)을 함께 돌려주고 2xx 가 아니어도 본문을 읽는다**(주의점 3). 연결 끊김은 `{status:0, body:null}`. `brandDb` 가 없으면(운영 주소) 바로 `{status:0, body:null}`
    - `brandFormatDateTime(iso)` → `2026/10/15 14:05` · `brandFormatDate(iso)` → `2026/10/15`(관리자 `formatDate`·`formatDateTime` 과 같은 모양 — `quality.md`. `ui.js` 를 못 실어 사본)
  - 세션 상태(`brand-shell.js`)
    - `brandSession` = `{ name, email, brands:[{id,name,role}], currentBrandId, hasPendingInvite, newInviteDot, passwordChangedAt }` — `get_my_brand_login_state` 의 칸을 옮긴다. 대응: `name`·`email`·`brands` 그대로 · `last_brand_id` → `currentBrandId`(폴백 적용 뒤 값) · `has_pending_invite` → `hasPendingInvite` · `new_invite_dot` → `newInviteDot` · `password_changed_at` → `passwordChangedAt`. 서버 키 이름을 바꾸지 않는 것이 공유 지점이다(화면 쪽 이름은 이 대응표가 정본)
    - `enterBrandApp(state, {preferBrandId}?)` — 첫 브랜드 = `preferBrandId`(활성 연결에 있을 때만) → `state.last_brand_id` → 이름순 첫 브랜드(조각 2 의 `sortBrandsForPicker` 를 쓰기 전까지는 서버 순서 첫 번째 — 조각 2 가 교체). 첫 페이지로 이동하되 **활동 기록은 남기지 않는다**(로그인 직후 자동 이동)
    - `refreshBrandLoginState() → state|null` — 다시 받아 `brandSession` 갱신. 지금 브랜드가 빠졌으면 `handleBrandNotLinked()`(조각 2) — 조각 1 에서는 첫 브랜드로 옮기기만
    - `getCurrentBrandId()` · `onBrandChanged(fn)`(브랜드가 바뀌면 각 페이지가 자기 목록을 다시 받는다)
    - `registerBrandPage(hash, {title, render, needsBrand})` — 페이지 파일(조각 5·7)이 자기를 등록
    - `brandTouchActivity()` — 지금 브랜드로 `touch_my_brand_activity(p_brand_id)`. **부르는 자리는 S0-4 결정을 따른다**(결정: 사람이 누른 메뉴 이동 · 저장 성공 직후 · 브랜드 바꾸기 — **마이페이지로 가는 이동은 세지 않는다**). 결과는 화면에 쓰지 않는다(실패해도 조용히)
  - 해시 경로: 로그인 뒤 `#orient`·`#brand`·`#campaigns`(S0-1 결과에 따라 「준비 중」 자리)·`#members`·`#mypage`. 기존 카드 화면 이름(`login`·`invite`·…)과 겹치지 않는다. 로그인 상태에서 카드 화면 해시(예 `#login`)로 오면 첫 페이지로, 로그아웃 상태에서 틀 해시로 오면 `#login`
  - 화면 요소 아이디: `#brandShell`(틀) · `#brandSideMenu` · `#brandTopbarMenuBtn`(모바일 ≡) · `#brandDrawer` · `#brandSwitcherHost`(조각 2 가 채움) · `#brandMyPageLink`(+ 빨간 점 자리 `.brand-dot`) · `#brandLogoutBtn` · `#brandPageHost`
- **선행 의존:** S0-1(메뉴 항목·첫 페이지) · S0-4(활동 기록 자리).
- **완료 정의:** 빌드 오류 없음 + 루트 `brand/index.html` 에 새 파일 셋 내용이 실림(원본 `<script src="../js/brand-*.js">` 태그 0개) · 개발서버에서 시험 대표 계정 로그인 → 좌측 메뉴 틀 + 첫 페이지(S0-1 대로) · 새로고침해도 같은 페이지 · 「로그아웃」 → 로그인 화면, 저장 칸 `reverb.brandAuth` 비어 있음 · 좁은 폭(600px 이하)에서 ≡ → 서랍 열림·닫힘, 서랍 안 키보드 Tab 순서 · 데이터베이스에서 로그인만 한 직후 그 계정의 `brand_account_links.last_active_at` 이 바뀌지 않음, 메뉴를 눌러 이동하면 바뀜 · 운영 주소 흉내(코드에서 `IS_STAGING=false`)면 「준비 중」 카드만.
- **필요 검문소:** `reverb-reviewer`(전역 이름 충돌 — 단순 이어붙이기 빌드라 `brand-*.js` 끼리 전역 하나 · 남은 `home`·`homeBrands` 참조 0건 확인).
- **주의·롤백:** 화면 파일만. 되돌리기 = 이 병합 요청 되돌림. `brandSignOutLocal` 의 `scope:'local'` 유지(다른 기기 세션 보호).

### 작업 2 — 좌측 위 브랜드 고르기
- **하는 일:** 연결 브랜드가 둘 이상이면 좌측 위 브랜드명에 ⌃⌄ + 펼친 목록(w03-01), 모바일은 서랍 맨 위 브랜드 묶음(m03-01). 8개 이상이면 웹은 검색 칸 + 7줄 반 높이 스크롤(w03-01a·01b), 모바일은 서랍에 지금 브랜드 한 줄 → 전체 화면 고르기(m03-02·02a). 바꾸면 보던 메뉴의 첫 화면으로, 화면 값을 모두 새로 받는다.
- **담당 파일:** `brand-shell.js` · `brand.css` · `index.html`(필요하면 틀 안 자리만)
- **산출 계약:**
  - `sortBrandsForPicker(brands, currentId)` — 지금 브랜드 맨 위 + 나머지 이름순(한글 가나다 → 영문 ABC). `Intl.Collator('ko')` 를 쓰되 한글이 영문 앞에 오지 않으면 「글자 종류(한글 → 그 밖) → 같은 종류 안 정렬」 비교로 바꾼다. 역할(대표/멤버)은 싣지 않는다(16-4 ①)
  - 「8개 이상」 기준 = `brandSession.brands.length`(로그인 판정이 이미 활성 연결만 준다)
  - 검색 = `name` 일부 일치, 영문 대소문자·띄어쓰기 무시, 입력할 때마다, 0건이면 「‘검색어’와 일치하는 브랜드가 없어요」. 목록을 닫았다 열면 검색어 비움
  - `switchBrand(id)` — `set_my_brand_last_viewed(id)` → `ok` 면 `currentBrandId` 교체 + `onBrandChanged` 알림 + 보던 메뉴 첫 화면 + (S0-4 결정대로) 활동 기록 / `not_linked` 면 `handleBrandNotLinked()`
  - `handleBrandNotLinked()` — 토스트 「이 브랜드에서 빠져서 바꿀 수 없어요」(w03-90) → `refreshBrandLoginState()` → 남은 브랜드 1개면 ⌃⌄ 사라짐 / 0개면 조각 3 의 갈래(대기 초대 있으면 초대 수락 화면, 없으면 로그아웃 + 「연결된 브랜드 없음」). **조각 3 병합 전 임시 동작: 0개면 대기 초대와 상관없이 로그아웃 + 「연결된 브랜드 없음」** — 조각 3 이 이 갈래를 바꾼다. **조각 5·7 의 서버 함수가 `not_linked` 를 돌려줄 때도 이것을 부른다**
  - `enterBrandApp` 의 폴백을 `sortBrandsForPicker` 첫 브랜드로 교체(폴백일 때는 `set_my_brand_last_viewed` 를 부르지 않는다 — 기록은 사람이 고를 때와 사양서 예외 둘에만)
- **선행 의존:** 1 · S0-4(브랜드 바꾸기를 활동으로 센다).
- **완료 정의:** 브랜드 1개 계정 — ⌃⌄ 없음, 서랍에 브랜드 묶음 없음 · 2~7개 — 목록 순서(지금 브랜드 맨 위, 한글 뒤 영문)를 화면으로 확인 · 8개 이상 — 검색 칸, 「하루」 입력 시 걸러짐, 없는 말이면 빈 안내 · 다른 브랜드 고르기 → 다른 기기(다른 브라우저)로 로그인하면 그 브랜드로 열림(`last_brand_id`) · SQL 로 그 계정의 연결 하나를 해제한 뒤 그 브랜드를 고르면 토스트 + 목록에서 사라짐 · 모바일 전체 화면 고르기 「←」 → 서랍으로.
- **필요 검문소:** `reverb-reviewer`(키보드 조작·`aria-expanded`·목록 `role` · 바꾼 뒤 옛 브랜드 값이 남는 화면이 없는지).

### 작업 3 — 로그인 판정 갈래 + 초대 수락 화면(로그인 경로) + 거절 확인
- **하는 일:** `applyBrandLoginState` 를 고쳐 `no_active_brand` + `has_pending_invite=true` 면 **로그아웃하지 않고** 초대 수락 화면 w01-03 으로 보낸다(주의점 1). w01-03 을 미리보기에서 실제로 바꾼다 — 브랜드명·초대한 사람·받은 날·수락 기한 · 「초대받은 계정」 칸 = 지금 로그인한 계정 이메일(`brandSession.email`, 읽기 전용 회색 칸 — S0-5) · 「수락」·「거절」(확인 모달 w01-10)·「나중에」. 들어오는 길은 이 조각에서 「로그인 경로」 셋(대기 초대만 있는 계정의 로그인 · 비밀번호를 정한 뒤 · 브랜드 전환 중 연결 0개), 메일 링크 길은 조각 4.
- **담당 파일:** `brand-login.js`(`applyBrandLoginState`) · `brand-invite.js` · `brand-app.js`(새로고침 복원의 같은 갈래) · `index.html`(w01-03 마크업 정리) · `brand.css`
- **산출 계약:**
  - `respondBrandInvite({inviteId, linkId, action}) → {result, brand_id}|null` — `respond_brand_invite(p_invite_id, p_link_id, p_action)` 감싸기. 결과 `ok`·`already_member`·`invalid`·`not_brand`·`setup_incomplete`, 호출 실패 `null`. **조각 7(마이페이지 받은 초대)도 이 함수를 쓴다**(같은 서버 함수 — 16-4)
  - `showInviteScreen({source:'login'|'link', invite})` — `invite` = `get_my_brand_invites()` 첫 항목(로그인 경로) 또는 링크 판정 결과(조각 4)
  - 수락 `ok` → `set_my_brand_last_viewed(brand_id)`(사양서 예외 — 초대 수락 화면에서 수락하면 그 브랜드로 연다) → `refreshBrandLoginState()` → `enterBrandApp(state, {preferBrandId: brand_id})`
  - 거절 `ok` → 토스트 「초대를 거절했어요」 → 갈래: 연결 브랜드 있음 = 첫 페이지 / 남은 초대 있음 = 다음 초대 화면 / 둘 다 없음 = 로그아웃 + 「연결된 브랜드 없음」
  - `invalid` → 토스트 「이 초대는 더 이상 쓸 수 없어요」 → 「거절 뒤」와 같은 갈래 · `already_member` → 수락 `ok` 와 같은 처리 · 호출 실패 → 화면에 남아 「연결·서버 오류로 실패했어요. 다시 눌러 주세요」(w01-92)
  - 「나중에」 → 연결 브랜드 있음 = 첫 페이지 / 대기 초대만 = 로그아웃 + 안내 「초대는 기한까지 메일 링크나 다시 로그인해서 수락할 수 있어요」
  - 모르는 `state` 값 · 판정 호출 실패는 **지금 처리 그대로**(로그아웃 + 「확인하지 못했습니다」 / 새로고침 실패는 「다시 시도」 화면)
  - `brand-login.js` 머리 주석의 「초대 수락은 미리보기 전용」 문장 고침. 미리보기 막대의 `invite` 항목은 예시 값으로 남긴다
- **선행 의존:** 2(`handleBrandNotLinked` 의 0개 갈래가 이 화면으로 온다) · S0-5(「초대받은 계정」 칸).
- **완료 정의:** 시험 — 모든 브랜드에서 해제된 계정에 다른 브랜드 대표가 초대 → 그 계정 로그인 → 로그아웃되지 않고 w01-03(브랜드명·초대한 사람·기한) · 「수락」 → 그 브랜드 오리엔시트 자리(S0-1)로, 데이터베이스 연결 1행·초대 `accepted`·`last_brand_id` = 그 브랜드 · 다른 계정으로 「거절」 → 확인 모달 → 초대 `declined`, 대기 초대 없으므로 로그아웃 + 「연결된 브랜드 없음」 · 「나중에」 → 로그아웃 + 안내 · 수락 직전에 SQL 로 초대 취소 → 토스트 「더 이상 쓸 수 없어요」 · 새로고침 복원도 같은 갈래.
- **필요 검문소:** `reverb-reviewer`(로그아웃하지 않는 갈래가 늘어 세션이 남는 경로를 전수로 — 대기 초대만 있는 계정이 틀(03~07)에 들어가지 못하는지).

### 작업 4 — 메일 링크 초대 착지(ⓑ 로그인해서 수락 · ⓐ 새 이메일 비밀번호 설정)
- **하는 일:** `?link=…&kind=invite` 를 받는다. `get_brand_invite_link_state(p_link_id)` → `invalid` 면 「쓸 수 없는 링크」 · `valid` 면 링크 확인 화면 w01-08(제목 「초대를 확인할까요?」 — Figma F-6) → 「계속하기」 → `recipient` 로 갈린다. ⓑ`existing`: 이 브라우저에 브랜드 세션이 있으면 w01-03(링크 번호로), 없으면 로그인 화면 + 안내 「초대를 수락하려면 로그인해 주세요」 → 로그인 뒤 w01-03. ⓐ`new`: 비밀번호 설정 화면의 멤버판 w01-02b(설명 「「브랜드명」 브랜드의 ○○님이 회원님을 멤버로 초대했어요」 · 이름 필수 · 연락처 선택 · 비밀번호 · 약관 동의) → `brand-invite-accept` → 로그인 → 그 브랜드의 첫 페이지.
- **담당 파일:** `brand-app.js`(착지 갈래) · `brand-invite.js` · `brand-login.js`(로그인 성공 뒤 대기 링크 처리 · w01-02b 제출 분기) · `index.html`
- **산출 계약:**
  - 링크 번호 보관: 메모리 + `sessionStorage['reverb.brandInviteLink']`(로그인을 거치는 ⓑ 갈래와 새로고침용). **쓰면 즉시 지운다** · 로그아웃·「비밀번호 찾기」로 빠지면 지운다 · 주소에서는 확인 뒤 `history.replaceState` 로 쿼리를 걷는다. 링크 번호를 로그·토스트·오류 보고에 싣지 않는다
  - ⓑ 수락·거절은 조각 3 의 `respondBrandInvite({linkId, action})`(링크 번호로 지목)
  - ⓐ 제출: `brandCallFunction('brand-invite-accept', {link_id, password, name, phone, terms_version: BRAND_TERMS_VERSION})`(로그인 토큰 없음) → `ok` 면 이 브라우저의 기존 브랜드 세션을 `brandSignOutLocal` 로 먼저 정리 → `signInWithPassword(email, password)` → `enterBrandApp` / 로그인 실패면 로그인 화면 + 이메일 채움 + 「비밀번호를 설정했어요. 새 비밀번호로 로그인해 주세요」(기존 문구 재사용)
  - 결과 처리: `invalid_link` → 「쓸 수 없는 링크」 · `password_rejected` → 비밀번호 칸 오류 「쓸 수 없는 비밀번호입니다…」(기존 `weakPassword` 문구) · 400 `invalid_request`·500·연결 끊김 → 「비밀번호 설정을 마치지 못했습니다. 잠시 후 다시 눌러 주세요」 + **같은 화면에 남는다**(같은 링크 재시도는 서버가 같은 계정을 다시 쓴다 — 묶음 ① 조각 6)
  - 이메일 칸: 피그마대로 **읽기 전용 회색 칸**에 조각 4a 의 `email` 을 보여 준다(입력 불가 — 제출 본문에 싣지 않는다, 서버가 링크로 이메일을 안다). `email` 이 비어 오면(4a 미적용 서버) 칸을 숨긴다
  - 링크 확인 화면 제목은 기존 `fillConfirmScreen(mode)` 에 `'invite'` 를 더한다
- **선행 의존:** 3 · 4a(이메일 칸) · S0-5(다른 계정 링크).
- **완료 정의:** 개발서버 — 대표가 새 이메일로 초대(조각 5 전이면 SQL·서버 함수 직접 호출로 초대 줄 생성 + `notify-brand-invite` 의 `dev_mail` 링크 사용) → 링크 열기 → w01-08 → w01-02b → 제출 → 데이터베이스에 인증 계정 1·`brand_accounts`(이름·동의 시각·약관 판)·멤버 연결·초대 `accepted`·인플루언서 행 0 → 로그인된 채 그 브랜드 첫 페이지 · 같은 링크 다시 열기 → 「쓸 수 없는 링크」 · 비밀번호를 정한 다른 브랜드 계정 이메일로 초대(ⓑ) → 링크 → 로그인 화면(로그아웃 상태) → 로그인 → w01-03 → 수락 → 그 브랜드로 열림 · 링크 확인 화면을 띄운 채 새로고침해도 이어지거나 「쓸 수 없는 링크」(토큰이 없는 흐름이라 이어져도 된다 — 어느 쪽인지 기록) · 주소창에 `link=` 가 남지 않음.
- **필요 검문소:** `reverb-supabase-expert`(새 계정이 비밀번호를 정한 순간 로그인 연결과 인증 설정이 맞는지 · 대기 링크 보관 위치) · `reverb-reviewer`(비밀번호 원문이 화면 상태·저장소에 남지 않는지 · 링크 번호 노출 · `brandSetupDb` 흐름과 섞이지 않는지).
- **주의·롤백:** 비밀번호 거부·장애 뒤 사람이 떠나면 **비밀번호 없는 반쪽 계정이 남는다**(자동 정리 없음 — 묶음 ① 넘김 3). 같은 링크로 다시 오면 그 계정을 쓰고, 기한이 지나면 관리자 「계정 만들기」에서 겹침으로 보인다. 화면이 따로 할 일은 없다 — 시험 계정은 528 가드 때문에 **연결부터** SQL 로 지운다.

### 작업 4a — 링크 판정 함수가 새 이메일 초대의 이메일을 돌려줌 (데이터베이스)
- **하는 일:** `get_brand_invite_link_state(p_link_id)` 를 `CREATE OR REPLACE` 로 다시 정의해, `state='valid'` 면 `issued_at`(w01-03 「받은 날」)을, 그중 `recipient='new'` 일 때만 `email`(초대 줄의 이메일)을 더한다. `existing` 갈래·무효 링크에는 `email` 을 싣지 않는다(w01-03 은 로그인한 계정 이메일을 쓴다 — S0-5).
- **담당 파일:** 새 마이그레이션 `supabase/migrations/NNN_brand_invite_link_state_email.sql`(번호는 작성 시 `ls supabase/migrations | tail -5` 로 확정)
- **산출 계약:** 응답 `{state:'valid', recipient:'new', brand_name, inviter_name, issued_at, expires_at, email}` / `{state:'valid', recipient:'existing', brand_name, inviter_name, issued_at, expires_at}`(`issued_at` 은 w01-03 「받은 날」용으로 둘 다 더한다) / `{state:'invalid'}`. 🔴 현재 원본 = **532** 를 베이스로(예외 1·2 갈래 그대로). 🔴 **`DROP` 하지 않는다** — 532 의 실행 권한(비로그인 포함 부여 + PUBLIC 회수)이 그대로 남게 `CREATE OR REPLACE` 로만. 함수 설명 주석에 「링크 소지자에게 이메일을 주는 것은 S0-2 사용자 결정 — 피그마 w01-02b」
- **선행 의존:** 없음(조각 1~3 과 병렬 가능 — 데이터베이스만). 조각 4 보다 먼저 개발서버에 적용.
- **완료 정의:** 개발서버 적용 후 SQL 로 — 새 이메일 초대 링크 → `email` 있음 · 기존 브랜드 계정 초대 링크 → `email` 없음 · 없는 링크 번호 → `{state:'invalid'}` 한 칸 · 비로그인 역할 실행 권한 유지(`p.proacl` 확인 — 맨 앞 `=X/` 없음)
- **필요 검문소:** `reverb-supabase-expert` · `reverb-reviewer`
- **주의·롤백:** 되돌리기 = 532 정의를 다시 실행. 운영 반영 묶음(526 → … → 533)의 뒤에 이 번호가 붙는다 — 사양서 「운영 반영 전 남은 관문」 적용 순서에 추가(조각 10).

### 작업 5 — 멤버 관리(06) 목록 + 초대 모달 + 초대 메일 + 다시 보내기
- **하는 일:** `#members` 페이지. 대표 화면(w06-00): 대표·멤버·초대 줄(대기·만료·거절함), 「n / m명」, 열 이름·이메일·역할·상태·마지막 접속(초대 줄은 「—」), 「초대」 단추. 멤버 화면(w06-00a): 사용 중인 사람 줄만, 단추 없음, 「n / m명」은 보인다(n 이 줄 수보다 클 수 있음 — 의도). 초대 모달(w06-01, 가득 차면 w06-01a). 줄의 「다시 보내기」(대기·만료).
- **담당 파일:** `brand-members.js` · `brand.css`
- **산출 계약:**
  - `registerBrandPage('members', …)` · 브랜드가 바뀌면(`onBrandChanged`) 다시 받는다
  - 목록: `get_brand_members(p_brand_id)` → `{my_role, seat_used, member_limit, rows[]}` / `{result:'not_linked'}` 면 `handleBrandNotLinked()` / 호출 실패 `null` 은 **오류 상태**(「불러오지 못했어요 · 다시 시도」), 0건은 있을 수 없다(본인 줄) — 실패를 빈 목록으로 그리지 않는다. 불러오는 중 상태 있음
  - 줄 문구: 대기 = 「초대 대기 · ~날짜 시각까지」 · 만료 = 「초대 만료」 · 거절함 = 「거절함 · 날짜」(「수에서 빠짐」 같은 덧말 없음 — 16-4 06). 자리 계산 안내문은 목록 아래 한 줄
  - 초대: 이메일 형식 검사(`isEmailFormat`) → `create_brand_invite(p_brand_id, p_email)` → 결과 문구
    - `ok` → `sendBrandInviteMail(invite_id)` → 토스트 「초대를 보냈습니다」(ⓐⓑⓒ 어느 경우든 같은 문구 — 겹침 비노출)
    - `already_pending` → 「이미 초대한 이메일이에요. 목록에서 「다시 보내기」를 눌러 주세요」 · `already_member` → 「이미 이 브랜드의 멤버예요」 · `self_email` → 「본인 이메일은 초대할 수 없어요」 · `seat_full` → w06-01a 「멤버가 가득 찼어요 — 운영팀에 늘려 달라고 요청해 주세요」 · `invalid_email` → 형식 오류 문구 · `not_owner`·`brand_inactive` → 「대표 담당자만 초대할 수 있어요」 + 목록 새로 받기
  - `sendBrandInviteMail(inviteId)` — `brandCallFunction('notify-brand-invite', {invite_id}, {auth:true})`. `sent:true` = 끝 · `dev_mail` 이 있으면(개발서버) 「개발서버 — 메일 대신 보기」 상자에 제목·본문(링크 포함)을 띄운다(`IS_STAGING` 일 때만 그린다) · `send_failed`·500·연결 끊김 → 토스트 「초대 줄은 만들었지만 메일을 보내지 못했어요. 「다시 보내기」를 눌러 주세요」 · `already_sent` → 성공과 같게(토스트 「초대를 보냈습니다」, 실패 토스트 없음) · `not_pending`·403 → 목록 새로 받기
  - 다시 보내기: `resend_brand_invite(p_invite_id)` → `ok` 면 `sendBrandInviteMail` / `seat_full`(만료 줄만) → w06-01a 문구 / `not_resendable`·`not_found`·`not_owner` → 목록 새로 받기
  - 가득 참 사전 표시: `seat_used >= member_limit` 면 「초대」·만료 줄 「다시 보내기」를 막아 둔다(대기 줄 「다시 보내기」는 막지 않는다 — 16-2). 최종 판정은 서버
  - 마지막 접속: `last_active_at` → `brandFormatDateTime`, 없으면 「—」
  - 저장 성공 뒤 `brandTouchActivity()`(S0-4 결정)
- **선행 의존:** 2(`handleBrandNotLinked`) · S0-6(모바일 모양).
- **완료 정의:** 대표 로그인 → 목록에 본인 대표 줄 + 「1 / 5명」 · 새 이메일·브랜드 계정 이메일·인플루언서 이메일 세 번 초대 → 세 번 모두 같은 토스트, 「4 / 5명」, 개발서버 `dev_mail` 상자의 문구가 갈래마다 다름(문구는 시험자만 봄) · 같은 이메일 다시 초대 → `already_pending` 문구 · 상한 채운 뒤 「초대」 막힘 · SQL 로 초대 하나의 `issued_at`·`expires_at` 을 과거로 → 「초대 만료」 + 「다시 보내기」 → 대기로 돌아옴 · 멤버로 로그인 → 초대 줄 없음, 단추 없음, 「n / m명」은 대표와 같은 숫자 · 같은 초대 링크로 `notify-brand-invite` 두 번째 → 실패 토스트 없이 성공 토스트.
- **필요 검문소:** `reverb-reviewer`(초대 줄 이메일은 `brandEsc` · 갈래를 짐작할 화면 차이 0 · 실패 `null` 과 빈 목록 구분).

### 작업 6 — 멤버 관리 정리 동작(취소·삭제·대표 넘기기·해제)
- **하는 일:** 대표만 보이는 줄 단추 — 대기 줄 「취소」 · 만료·거절함 줄 「삭제」(만료 줄은 「다시 보내기」와 「삭제」 둘 다 — 16-7) · 멤버 줄 「대표 넘기기」(확인 모달 w06-02) · 「해제」(확인 모달 w06-03).
- **담당 파일:** `brand-members.js` · `brand.css`
- **산출 계약:**
  - 취소 `cancel_brand_invite(p_invite_id)` → `ok` 토스트 + 목록 · `not_pending`(그사이 만료) → 목록 새로 받기 · `not_owner` → 목록 새로 받기
  - 삭제 `hide_brand_invite(p_invite_id)` → `ok`·`not_hideable`·`not_owner`
  - 넘기기 `transfer_brand_ownership(p_brand_id, p_new_owner_auth_id)` — 확인 모달에 「넘기면 나는 멤버가 되고 초대 관리는 ○○님이 해요」 → `ok` → `refreshBrandLoginState()`(역할이 바뀐다) → 목록을 멤버 화면으로 다시 그림 · `not_member` → 목록 새로 받기. 메일 없음(16-7 가정)
  - 해제 `release_brand_member(p_brand_id, p_auth_id)` → `ok`·`not_member`. 확인 모달에 「해제하면 이 브랜드의 화면을 더 쓸 수 없어요. 다시 쓰려면 새로 초대해야 해요」
  - 확인 창은 조각 1 의 `brandConfirm`. 되돌릴 수 없는 동작(넘기기·해제)은 위험 모양(빨간 단추)
  - 성공 뒤 `brandTouchActivity()`(저장으로 셈)
- **선행 의존:** 5.
- **완료 정의:** 대기 줄 취소 → 줄 사라지고 「n」 1 감소 · 만료 줄·거절함 줄 삭제 → 사라짐(데이터베이스 `owner_hidden_at` 채워짐) · 멤버에게 넘기기 → 내 화면이 멤버 화면으로, 그 사람 화면은 대표 화면 · 데이터베이스 `brands.contacts` 의 대표 표시가 새 대표 이메일 줄로 옮겨짐 · 멤버 해제 → 그 사람이 새로고침하면 브랜드가 사라지고(연결 0개면 「연결된 브랜드 없음」) · 두 브라우저에서 같은 초대를 동시에 취소 → 한쪽은 목록 새로 받기로 끝남.
- **필요 검문소:** `reverb-reviewer`.
- **주의·롤백:** 🔴 **「대표 넘기기」가 서버에서 `brands.contacts` 를 고친다** — 묶음 ③ 전에는 관리자 브랜드 상세 편집 폼이 연 채 저장되면 옛 대표 표시로 되돌린다(공유 지점 경고). 시험할 때 관리자 브랜드 상세를 열어 둔 채 넘기지 않는다.

### 작업 7 — 마이페이지(07)
- **하는 일:** `#mypage`. 계정 정보(이름·이메일·연락처 — 평소 읽기 전용, 「수정」을 누르면 이름·연락처만 열림 w07-00a, 이메일은 늘 읽기 전용이고 바꾸는 안내도 두지 않는다 — 16-2) · 비밀번호 마지막 변경일 · 연결된 브랜드와 역할 + 안내 「좌측 위에서 브랜드를 바꿔 쓸 수 있어요. 브랜드에서 빠지려면 그 브랜드의 대표 담당자나 운영팀에 요청해 주세요」 · 받은 초대 묶음(w07-00b — 브랜드명·초대한 사람·받은 날·수락 기한·「수락」·「거절」(확인 w07-02)) · 로그아웃. 들어오면 빨간 점을 끈다.
- **담당 파일:** `brand-mypage.js` · `brand-shell.js`(빨간 점 표시 함수) · `brand.css`
- **산출 계약:**
  - 계정 정보: 이름·이메일·비밀번호 변경일은 `brandSession`, 연락처는 **본인 행 직접 읽기** `brandDb.from('brand_accounts').select('name, email, phone, password_changed_at').eq('auth_id', <로그인 사용자>).maybeSingle()`(526 정책 — 함수 추가 없이). 실패는 오류 상태
  - 수정 저장: `update_my_brand_profile(p_name, p_phone)` → `ok` 토스트 + `brandSession.name` 갱신(좌측 아래 이름도) · `name_required` → 칸 오류. 입력 한도는 설정 화면과 같게(이름 40·연락처 20). 담당자 목록과 맞추지 않는다. 마이페이지 저장·수락·거절은 `brandTouchActivity()` 를 부르지 않는다(S0-4)
  - 받은 초대: `get_my_brand_invites()` → `[{invite_id, brand_id, brand_name, inviter_name, issued_at, expires_at}]`. 수락·거절은 조각 3 의 `respondBrandInvite({inviteId, action})`. **마이페이지 수락은 지금 브랜드·마지막 브랜드를 바꾸지 않고 마이페이지에 머문다** → `refreshBrandLoginState()` + 받은 초대·연결된 브랜드 다시 그리기 + 브랜드 고르기 목록 갱신(둘이 되면 ⌃⌄ 생김) · `invalid` → 토스트 「이 초대는 더 이상 쓸 수 없어요」 + 목록 새로 받기 · 실패 → 토스트 「연결·서버 오류로 실패했어요」
  - 빨간 점: `refreshInviteDot()`(`brand-shell.js`) — `brandSession.newInviteDot` 이 참이면 웹 좌측 아래 「이름 · 마이페이지」·모바일 ≡ 단추·서랍 마이페이지 줄에 점(w07-03·m07-03). 마이페이지에 들어오면 `mark_my_brand_mypage_seen()` 뒤 점을 끈다(마이페이지 화면 안에는 점 없음). 점이 다시 켜지는 때 = 로그인 판정을 다시 받을 때(로그인·새로고침·브랜드 바꾸기·메뉴 이동 — 조각 1 의 `refreshBrandLoginState` 를 메뉴 이동마다 부를지는 개발 재량, 주기적 조회는 두지 않는다)
  - 연결된 브랜드 역할 표시는 여기만(브랜드 고르기 목록에는 없다)
- **선행 의존:** 3(`respondBrandInvite`) · S0-6(모바일 모양).
- **완료 정의:** 브랜드 둘 계정에 새 초대 → 로그인 → 좌측 아래 빨간 점 · 마이페이지 들어감 → 점 사라짐(데이터베이스 `mypage_seen_at` 갱신) + 받은 초대 1건 · 「수락」 → 마이페이지에 머물고 연결된 브랜드 셋, 지금 브랜드는 그대로 · 「거절」 → 확인 → 목록에서 사라짐, 대표 화면에 「거절함」 · 이름 비우고 저장 → 칸 오류 · 연락처만 바꿔 저장 → 새로고침해도 유지 · 대표가 「다시 보내기」하면 점이 다시 켜짐(새로고침 뒤).
- **필요 검문소:** `reverb-reviewer`(본인 행 직접 읽기가 정책상 남의 행을 못 읽는지 · 마이페이지 수락이 `last_brand_id` 를 안 건드리는지).

### 작업 8 — 마이페이지 비밀번호 변경 모달(w07-01)
- **하는 일:** 현재 비밀번호 · 새 비밀번호 · 새 비밀번호 확인. 현재 비밀번호를 확인한 뒤 바꾸고, 규칙은 비밀번호 설정 화면과 같다(`brandPasswordIssue`). 상태: 현재 비밀번호 틀림(01a) · 규칙 미달(01b).
- **담당 파일:** `brand-mypage.js` · `brand-core.js` · `brand.css`
- **산출 계약:**
  - `brandVerifyCurrentPassword(email, pw) → 'ok'|'wrong'|'too_many'|'error'` — **그때만 만드는 일회 연결**(`storageKey` 별도·`persistSession:false`·`autoRefreshToken:false`)로 `signInWithPassword` → 성공하면 그 연결을 `signOut({scope:'local'})`. 원문은 변수에만, 저장소·로그에 남기지 않는다(작업표 설계 메모 — 로그인 체계 횟수 제한을 그대로 받는다)
  - 확인되면 `brandDb.auth.updateUser({password})` → 오류는 기존 `brandUpdatePwErrorKind` 분류(`same` → 「지금 쓰는 비밀번호와 다른 비밀번호로」 · `weak_password` → 기존 문구) · `reauthentication_needed` 면 S0-8 결과에 따라 처리
  - 성공 → `mark_my_brand_password_changed()` → 토스트 「비밀번호를 바꿨어요」 + 마이페이지의 마지막 변경일 갱신. 다른 기기 세션은 **그대로 둔다**(사양서에 요구 없음 — 재설정 경로만 전체 로그아웃) → ⚠️ 불가능했다 — 서버가 끊는다(맨 아래 구현 결과)
- **선행 의존:** 7 · S0-8.
- **완료 정의:** 틀린 현재 비밀번호 → 01a 문구, 로그인 세션은 그대로 · 규칙 미달 → 01b · 정상 변경 → 로그아웃 후 새 비밀번호로 로그인 성공, 옛 비밀번호 실패 · 데이터베이스 `password_changed_at` 갱신 · 일회 연결이 `reverb.brandAuth` 를 건드리지 않음(변경 뒤에도 같은 탭 로그인 유지).
- **필요 검문소:** `reverb-supabase-expert`(인증 설정 재인증 요구·일회 연결이 만드는 세션 정리) · `reverb-reviewer`.

### 작업 9 — 흔히 쓰는 비밀번호 경고 (S0-3 결정 — 넣는다)
- **하는 일:** 비밀번호를 정하는 브랜드 화면 넷(w01-02 설정 · w01-02b 초대받은 멤버 · w01-07 재설정 · w07-01 변경)에 「흔히 쓰는 비밀번호예요 — 그래도 쓸 수 있어요」 경고만(막지 않는다 — 16-4 ⑤).
- **담당 파일:** `brand-core.js` · `brand-login.js` · `brand-invite.js` · `brand-mypage.js`
- **산출 계약:** `brandCommonPasswordCheck(pw) → 'common'|'ok'|'unknown'` — 서버 함수 `password-range-lookup` 을 그대로 쓴다(앞 5글자만 보냄). 🔴 **같은 판정의 셋째 사본**이 된다(`dev/js/ui.js` 638행 · `dev/admin-setpw.html` 447행) — 세 곳에 서로를 가리키는 주석. `'unknown'`(함수 없음·오류)은 경고 없이 통과.
- **선행 의존:** 4·8 · S0-3.
- **완료 정의:** `password1!` 같은 흔한 값 → 경고가 뜨고 그대로 저장됨 · 흔하지 않은 값 → 경고 없음 · 서버 함수 호출을 막아도(개발자 도구) 저장은 됨.
- **필요 검문소:** `reverb-reviewer`(사본 셋 문구·판정 일치).

### 작업 10 — 문서 + 개발서버 처음부터 끝까지 확인
- **하는 일:** 사양서 「구현 결과」에 「묶음 ②」 절(실제 해시 경로·파일·결정 S0-1~S0-8 결과·달라진 것) · `docs/FEATURE_SPEC.md` 브랜드 절 · `CLAUDE.md` 브랜드 계정 절(화면 묶음 ② 완료 표기 — 「화면 묶음 ②·③ 미착수」 문장 갱신) · 사양서 「운영 반영 전 남은 관문」 적용 순서에 조각 4a 번호 추가(533 뒤) · `dev/build.sh` 브랜드 절 주석(「두 곳」 → 브랜드는 목록 한 곳) · 이 작업표 「구현 결과」. 고문에게 넘길 것: `.claude/rules/build.md` 의 「목록과 정규식 두 곳」(브랜드 빌드는 목록 한 곳) · `.claude/rules/brand-account.md` 에 브랜드 화면 파일·`sessionStorage` 칸 이름·`brandCallFunction` 규약.
- **완료 정의:** 처음부터 끝까지 한 번(개발서버, 실제 브라우저 — 마우스를 옮기며 `browser-qa.md` 대로): 관리자 계정 만들기 → 설정 → 로그인 → 멤버 초대(ⓐ) → 새 브라우저로 링크 → 가입·로그인 → 대표가 넘기기 → 새 대표가 옛 대표 해제 → 옛 대표 로그인 시 「연결된 브랜드 없음」. 시험 데이터 정리(528 가드 — 연결부터).
- **필요 검문소:** `reverb-reviewer` · `reverb-qa-tester` **권장**(다른 세션이 브라우저 시험을 안 쓸 때 한 세션에서만).

---

## ⚠️ 공유 지점 경고

- **`dev/brand/index.html`·`dev/css/brand.css`·`dev/js/brand-core.js`·`brand-app.js`·`brand-login.js`** — 거의 모든 조각이 만진다 → 같은 줄기 안에서 순차. 조각 5·6 은 모달을 **동적 생성**하고 자기 파일(`brand-members.js`)에만 쓰도록 계약했다 — 그래도 `brand.css` 는 겹치므로 병렬로 갈라지면 스타일을 파일 끝 자기 구역에만 더한다.
- **`dev/build.sh`(핫스팟)** — 조각 1 이 새 파일 셋을 한 번에 등록한다. 뒤 조각은 만지지 않는다(조각 10 의 주석 한 줄 예외).
- **`get_my_brand_login_state` 반환 모양** — 화면이 키(`state`·`name`·`email`·`brands`·`last_brand_id`·`has_pending_invite`·`new_invite_dot`·`password_changed_at`)를 그대로 쓴다. 서버가 키 이름을 바꾸면 이 묶음이 깨진다.
- **`brands.contacts`** — 조각 6 「대표 넘기기」가 서버 쪽 대표 표시 이동을 실제로 일으킨다. 🔴 묶음 ③(「브랜드 정보 저장은 담당자 칸을 보내지 않는다」) 전에는 관리자 브랜드 상세 편집 폼이 되돌릴 수 있다.
- **개발서버 잠금 스위치 `BRAND_SETUP_DEV_ECHO`** — `notify-brand-invite`·`notify-brand-account-setup`·(링크 발급만) `brand-password-reset-request` 가 함께 쓴다. 화면의 `dev_mail` 상자는 그 스위치 결과를 그릴 뿐 — 운영에 그 스위치를 넣지 않는다는 규칙은 그대로.
- **비밀번호 규칙 사본 셋**(`brandPasswordIssue` · `ui.js passwordPolicyIssue` · `admin-setpw.html validateAdminPassword`) — 이 묶음은 규칙을 바꾸지 않는다. 조각 9 를 하면 흔한 비밀번호 판정도 사본 셋이 된다.
- **묶음 ③(관리자 화면)** — 파일이 겹치지 않아 ②와 병렬 가능. 단 ③은 `dev/lib/shared.js`·`storage.js`(핫스팟)를 만진다 — 다른 작업과 겹치지 않게. 같은 데이터(멤버 수·마지막 접속)를 양쪽이 그리므로 **숫자 정의는 서버 값을 그대로**(브랜드 화면 「n / m명」= `seat_used` / 관리자 「초대 대기 N 포함」= `pending_invite_count` — 뜻이 다르다, §16 머리 정의).
- **범위 밖:** 오리엔시트(04)·브랜드 정보(03)·캠페인(05) 페이지 · 옛 오리엔시트 작성 링크(w01-09) 예외 · 「선정 발표」 여섯째 사본 · 브랜드 쪽 오리엔시트 「저장되지 않은 입력」 확인(w04-13).

## 🧭 배분 제안

- **개발 1명이 1 → 2 → 3 → 4a → 4 → 5 → 6 → 7 → 8 → 9 → 10 순서로.** 브랜드 화면은 파일이 작고 서로 얽혀 병렬 이득이 작다.
- 꼭 나눠야 하면 조각 2 병합 뒤 **둘로**(조각 5 가 조각 2 의 `handleBrandNotLinked` 를 쓴다): 개발 A = 3 → 4 → 7 → 8, 개발 B = 5 → 6. 조건 — B 는 `brand-members.js` 와 `brand.css` 끝 자기 구역만 만지고, `brand-shell.js`·`brand-app.js`·`index.html` 은 건드리지 않는다(필요하면 A 에게 요청).
- 묶음 ③(관리자 화면)은 이 묶음과 파일이 갈려 다른 세션이 병렬로 가도 된다.

---

## 사용자 확인 필요

없음 — S0-1~S0-6 은 2026-10-15 결정(맨 위 「선결 결정 결과」). S0-7(시험 데이터)·S0-8(인증 설정 확인)은 개발 몫.

---

**관련 파일 (절대경로)**
- 사양서: `/Users/choiwooyoung/kemo-브랜드포털/docs/specs/2026-07-15-brand-portal.md`
- 묶음 ① 작업표: `/Users/choiwooyoung/kemo-브랜드포털/docs/specs/2026-10-15-brand-member-breakdown.md`
- 로그인 작업표: `/Users/choiwooyoung/kemo-브랜드포털/docs/specs/2026-10-14-brand-login-breakdown.md`
- 화면: `/Users/choiwooyoung/kemo-브랜드포털/dev/brand/index.html` · `/Users/choiwooyoung/kemo-브랜드포털/dev/js/brand-core.js` · `/Users/choiwooyoung/kemo-브랜드포털/dev/js/brand-login.js` · `/Users/choiwooyoung/kemo-브랜드포털/dev/js/brand-app.js` · `/Users/choiwooyoung/kemo-브랜드포털/dev/css/brand.css` · `/Users/choiwooyoung/kemo-브랜드포털/dev/build.sh`(200~234행)
- 서버 계약 원본: `/Users/choiwooyoung/kemo-브랜드포털/supabase/migrations/531_brand_owner_functions.sql` · `/Users/choiwooyoung/kemo-브랜드포털/supabase/migrations/532_brand_recipient_self_functions.sql` · `/Users/choiwooyoung/kemo-브랜드포털/supabase/functions/notify-brand-invite/index.ts` · `/Users/choiwooyoung/kemo-브랜드포털/supabase/functions/brand-invite-accept/index.ts`

> 메인에게: 이 작업표는 단계 2개 이상·결정 표가 있어 규칙 C(다른 눈의 자기 정합성 점검) 대상이다. 저장 뒤 설계에 관여하지 않은 검토자에게 문서만 주고 점검시킬 것.

---

## 구현 결과 (2026-10-16, 개발 세션)

- 조각 1~9·4a 모두 dev 병합: #2075 · #2077 · #2078 · #2079(4a·4, 마이그레이션 534) · #2081 · #2082 · #2086 · #2088(피그마 「06」 대조 + 초대 메일 초안 문구) · #2089 · #2090. 조각 10(문서)은 이 커밋
- 상세(해시 경로·저장 칸·결정 S0-1~S0-8 결과·달라진 것·임시 문구·넘기는 것)는 사양서 `docs/specs/2026-07-15-brand-portal.md` 「구현 결과 — 묶음 ②」 한 곳에 적었다
- 이 작업표와 달라진 핵심 셋: ①조각 8 「다른 기기 세션은 그대로 둔다」는 불가능(서버가 끊는다 — 실측) · 계약 이름도 `brandVerifyCurrentPassword` 대신 `brandChangePasswordWithCurrent`(확인·저장·기록·세션 옮기기를 한 함수에서) ②조각 7 브랜드 번호 표시 안 함(사용자 결정) ③조각 7 「마이페이지 화면 안에는 점 없음」 — 피그마대로 「받은 초대 N」 옆 작은 점을 그렸다
- 조각 10 「처음부터 끝까지 확인」(관리자 계정 만들기 → 설정 → 초대 → 새 브라우저 가입 → 넘기기 → 옛 대표 해제)은 문서 병합 뒤 사용자와 함께 한다 — 결과는 이 절에 덧붙인다

