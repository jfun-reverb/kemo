# 가입 확인 링크가 비밀번호 재설정 화면으로 빠지는 결함 — 착지 경로 정정

**작성일:** 2026-09-10
**근거 조사:** `docs/research/2026-09-10-signup-confirm-link-misrouted-to-reset.md`(개발 세션, 운영 로그·데이터베이스 직접 확인) — 이 사양서는 그 조사 위에서 **화면 흐름을 어떻게 바꿀지**만 정한다. 시각별 표·증거는 조사 문서가 단일 소스.
**관련 사양서:** `docs/specs/2026-07-20-influencer-password-reset-fix.md`(재설정 링크를 `#reset-pw?token_hash=` 새 형식으로 바꾼 작업) · `docs/specs/2026-07-20-admin-invite-mail-and-setpw.md`

---

## 0. 한 줄 요약

앱이 주소의 `?code=` 를 「비밀번호 재설정 중」으로 읽는데, **가입 확인 링크도 같은 모양으로 착지**한다. 그래서 새 회원이 확인 링크를 누르면 홈이 아니라 **「새 비밀번호 설정」 화면**에 떨어지고, 가입한 브라우저가 아니면 세션도 없어 「Auth session missing」으로 막힌다. `?code=` 를 재설정 신호에서 빼고, 확인 착지를 **세션 있음 → 홈(로그인 상태) / 세션 없음 → 로그인 화면 + 「메일 확인 완료」 안내**로 가른다. 함께: 로그인의 「프로필 없으면 만든다」 구제 경로가 **조회 실패를 0건으로 오해**하지 않게, CDN 의 supabase-js 를 **버전 고정**.

---

## 1. 현재 상태 (2026-09-10, `origin/dev` 기준 — 규칙 A)

### 1-1. 관련 코드·화면

| 영역 | 위치 | 지금 동작 |
|---|---|---|
| 재설정 조기 감지 | `dev/js/app.js` `detectRecoveryUrlEarly()`(맨 위, 2026-04-14 도입) | `?code=` **또는** `#…type=recovery`·`access_token=` **또는** `#reset-pw?` 면 `sessionStorage['reverb.recovery']='1'` |
| 부팅 초기 화면 | `app.js` `DOMContentLoaded` — `initPage = inRecovery ? 'reset-pw' : …` | 플래그가 서 있으면 첫 화면이 재설정 |
| 세션 복원 | `app.js` `init()` — `if (session && !inRecoveryInit)` | 플래그가 서 있으면 **세션이 있어도 로그인 취급 안 함** |
| 인증 이벤트 | `init()` 안 `onAuthStateChange` — `PASSWORD_RECOVERY` 면 플래그 세움 + 재설정 화면 / `SIGNED_IN` 인데 플래그면 재설정 화면 | 확인 링크로 세션이 생겨도 **재설정 화면으로 간다** |
| 초기 라우팅 건너뜀 | `init()` — `urlHasRecoveryCode = has('code') \|\| type=recovery \|\| access_token=` | `?code=` 만 있어도 홈 라우팅을 건너뛴다 |
| 재설정 새 형식 | `app.js` `handleRecoveryTokenLink(tokenHash)` — `#reset-pw?token_hash=` → `verifyOtp(type:'recovery')` | 2026-07-20 부터 **우리 재설정 메일은 이 형식만** 보낸다(`docs/email-templates/reset-password.html` 이 `{{ .SiteURL }}/#reset-pw?token_hash=…` 를 직접 만든다). 요청은 보조 클라이언트 `dbAuthRequest`(implicit·저장 없음) |
| 가입 확인 메일 | `docs/email-templates/confirm-signup.html` — `{{ .ConfirmationURL }}` 그대로 | 전역 클라이언트가 `flowType:'pkce'` 라 확인 링크는 **`{Site URL}/?code=…` 로 착지**한다(조사 문서 §1 — `auth.flow_state` 에 `email/signup` 행) |
| 가입 흐름 | `dev/js/auth.js` `handleSignup` — `signUp` 뒤 `data.session` 없으면 `#signupConfirmMsg`(「確認メールを送信しました」) 표시 후 return | 운영은 메일 확인 필수라 **항상 이 갈래** |
| 로그인 구제 경로 | `auth.js` `handleLogin` — `influencers` 조회 결과가 비면 `upsertInfluencer(...)` | `const {data:profile} = …` 로 **`error` 를 안 받는다** → 조회가 비로그인으로 나가 401 이어도 「0건」으로 보여 삽입을 시도한다(조사 §1 의 03:51·03:58 행) |
| 부팅 세션 복원의 프로필 조회 | `app.js` `init()` — 같은 모양 `const {data:profile} = …` | 실패해도 조용히 `null` |
| supabase-js | CDN `@supabase/supabase-js@2`(버전 없음) — **8개 파일**: `dev/index.html`·`dev/admin/index.html`·`dev/admin-setpw.html`·`dev/event-scan.html`·`dev/report.html`·`dev/sales/{orient,reviewer,seeding}.html` | 지금 실리는 것은 2.116.0(2026-09-07 배포). 배포 없이 라이브러리가 바뀐다 |
| 정상 거부 목록 | `dev/lib/shared.js` `APP_ERROR_EXPECTED_PATTERNS` — `/Auth session missing/i` 포함 | 그래서 이 결함으로 생긴 「Auth session missing」은 오류 로그에서 **정상 거부로 분류돼 배지에 안 뜬다**(2026-08-11 부터 65회가 조용히 쌓였다) |

### 1-2. `?code=` 가 지금 어디서 오나 (재설정 신호에서 빼도 되는 근거)

| 출처 | `?code=` 로 오나 | 비고 |
|---|---|---|
| 가입 확인(`ConfirmationURL`, PKCE) | **온다** | 이 사양의 대상 |
| 비밀번호 재설정 메일 | **안 온다** — `#reset-pw?token_hash=`(2026-07-20) | 그 전 형식(`?code=`)의 링크는 1시간 만료라 지금 살아 있는 것이 없다 |
| 관리자 초대·비밀번호 찾기 | 안 온다 — 자립형 `admin-setpw.html`(서버 발급 링크) | 이 앱을 안 거친다 |
| 이메일 변경·매직링크·소셜 로그인 | 안 쓴다 | 소셜 로그인은 별도 사양서(2026-09-02)로 미착수 |

→ **이 앱에서 `?code=` 는 사실상 가입 확인뿐**이다. 「재설정 중」 신호로 남길 이유가 없다.

### 1-3. 운영 실측 (조사 문서에서 가져옴 — 여기서는 요약만)

- 9/10 새벽 회원 1명: 확인 링크 → 재설정 화면 착지 → 로그인 5회 서버 성공인데 브라우저는 세션을 못 붙잡음 → 지금도 로그인 불가. **아이폰 사파리 쪽 원인은 기기 없이 확정 불가**(조사 §3).
- 같은 시간대 다른 회원은 정상(가입 → 확인 → 5초 뒤 로그인). 전면 장애 아님.
- 「Auth session missing」(`handleResetPassword`) 2026-08-11~ **65회** — 이 결함과 재설정 링크 만료가 섞여 있어 몇 건이 이 경로인지 구분 안 됨.
- 최근 30일 가입 447명 중 메일 미확인 75명(17%, 2026-09-08 실측) — 이 결함이 확인율에 얼마나 기여했는지는 알 수 없다.

### 1-4. 이 제안과 충돌 가능성 있는 기존 동작

1. **`detectRecoveryUrlEarly` 의 `?code=` 조건은 2026-04-14 에 「Supabase 가 주소를 소비하기 전에 재설정을 감지」하려고 넣은 것**이다. 그때는 재설정 메일이 PKCE `?code=` 로 왔다. 2026-07-20 에 재설정 링크가 새 형식으로 바뀌면서 **이 조건의 존재 이유가 사라졌는데 조건만 남았다.** 빼도 재설정 흐름은 `#reset-pw?`·`PASSWORD_RECOVERY` 이벤트·옛 implicit 해시(`type=recovery`·`access_token=`)가 그대로 받는다(결정 ①). **유일한 예외는 옛 PKCE 형식 링크** — 확인 착지 판정에 먼저 걸려 「인증 완료」 토스트가 잘못 뜬 뒤 `PASSWORD_RECOVERY` 이벤트로 재설정 화면에 닿는다(우회 뒤 받음). 살아 있는 링크가 없어 감수한다(§2-7).
2. `init()` 의 `urlHasRecoveryCode` 도 같은 조건을 한 번 더 갖고 있다 — **두 곳을 함께** 빼야 한다. 한 곳만 빼면 첫 화면은 홈인데 초기 라우팅은 건너뛰는 어긋남이 생긴다.
3. 확인 착지에서 세션이 생기면 **기존 세션 복원(`init()`)이 로그인 처리를 하고 초기 라우팅이 홈으로 보낸다**(플래그만 없으면). `SIGNED_IN` 핸들러는 `currentUser` 가 이미 있으면 아무것도 안 하므로 겹쳐도 무해하다. **새 로그인 처리를 만들지 않는다 — 새로 더하는 것은 토스트 하나뿐.**
4. 정상 거부 목록의 `/Auth session missing/i` 는 그대로 둔다 — 재설정 링크 만료(정상)도 같은 문구다. 이 결함이 사라지면 그 문구의 발생 자체가 줄어야 하므로 **배포 뒤 4주간 발생 수를 본다**(§7).
5. `handleLogin` 구제 경로를 「조회 실패면 삽입 안 함」으로 바꾸면, **진짜로 프로필이 없는 계정**(가입 트리거 382 이전 극소수 잔존)의 구제는 그대로다(0건이면 여전히 삽입). 조회 실패일 때만 달라진다.
6. CDN 버전 고정은 **8개 파일**을 같이 고쳐야 한다. 한두 개만 고치면 앱마다 다른 판을 실어 「같은 라이브러리인데 화면마다 다르게 동작」하는 상태가 된다.

### 1-5. 미해결 백로그·관련 작업

- 확인 메일 **재발송 UI 가 없다** — 만료 링크(`?error=…expired`)로 착지하면 지금은 `forgot`(비밀번호 찾기)로 보내며 「リンクの有効期限が切れました」 토스트. 가입 확인이 만료된 회원이 할 수 있는 것은 「로그인 시도 → 미확인 안내」뿐이고 재발송 버튼이 없다. **이번 범위 밖**(§8-③).
- 아이폰 사파리 저장소 문제(조사 §3) — 기기 없이는 못 잡는다. 이번 사양은 **앱 결함만** 고친다.

---

## 2. 의심·경우의 수 (규칙 B)

1. **(기술) `?code=` 착지에서 「세션이 생겼는지」를 언제 판정하나.** supabase-js 는 클라이언트를 만들 때 주소의 `code` 를 보고 저장소에 검증값이 있으면 교환한다. `init()` 의 `getSession()` 은 그 초기화가 끝난 뒤 값을 주므로 **그 시점에 세션 유무로 가르면 된다.** ⚠️ 교환이 실패한 경우(검증값은 있는데 서버가 거부)는 `?error=` 로 오지 않고 조용히 세션 없음이 된다 — 세션 없음 갈래가 받는다.
2. **(UX) 세션 없는 갈래를 「로그인 화면」으로 보내면 회원은 「가입 끝났는데 또 로그인?」** — 그래서 안내 한 줄이 필수다: 「メール認証が完了しました。ログインしてください」. 안내 없이 로그인 화면만 보이면 지금(재설정 화면)보다 덜 나쁘지만 여전히 헷갈린다.
3. **(UX) 세션 있는 갈래를 홈으로 보내면 「환영」 토스트만 뜨고 끝** — 가입 완료를 알리는 한 줄(「メール認証が完了しました」)을 토스트로. 지금은 재설정 화면에서 비밀번호를 **다시 정하게** 하고 있었다 — 그 흐름은 사라진다(§8-② 확인).
4. **(데이터) 확인 링크를 다시 누른 경우**(조사 §1 — 회원이 4번 재클릭). 서버는 303 으로 보내며 토큰이 이미 쓰였으면 `?error=…expired` 로 착지한다(⚠️ `?code=` 도 `?error=` 도 없이 떨어지는 모양이 있다면 지금처럼 **비로그인 홈**이다 — 안내 없음. 이번에 따로 설계하지 않는다, 조사에서 관측되지 않은 모양). `?error=…expired` 는 기존 처리(`forgot` + 토스트)가 받는데 **가입 확인 만료에 「비밀번호 찾기」 화면은 틀린 안내**다 → 이번엔 문구를 「リンクの有効期限が切れました。ログインをお試しください」로 넓히고(§4-3) 화면은 `login` 으로(§4-1 `?error=` 처리). 재발송 UI 는 백로그.
5. **(권한·환경) 개발서버는 「Confirm email」이 꺼져 있어 이 착지가 아예 안 생긴다.** 재현하려면 개발서버 인증 설정에서 확인을 잠깐 켜야 한다(운영 가입은 배포 전 검증이 못 된다 — §7 준비) — §7 검증 절차에 적는다. **코드 읽기로만 「고쳐졌다」고 하지 않는다.**
6. **(다중 탭) `reverb.recovery` 는 `sessionStorage`(탭 단위)** — 확인 링크가 새 탭으로 열리면 그 탭엔 플래그가 없다. 이번 변경은 플래그를 **덜 세우는** 방향이라 탭 간 어긋남은 줄어든다.
7. **(회귀) 옛 형식(PKCE `?code=`) 재설정 링크가 살아 있다면 `?code=` 를 뺀 뒤 착지가 달라진다** — §4-1 의 확인 착지 판정이 먼저 걸려 「인증 완료」 토스트가 잘못 뜨고, 그 뒤 `PASSWORD_RECOVERY` 이벤트가 재설정 화면으로 보낸다(§1-4-1 과 같은 말). **알고 감수한다**: §1-2 대로 그 형식은 2026-07-20 이후 발송된 적이 없고 1시간 만료라 살아 있는 링크가 없다. 그 밖의 재설정 신호(§3 ①)는 그대로 받는다.
8. **(기술) CDN 버전을 고정하면 보안 수정도 안 따라온다** — 그게 목적(배포 없이 바뀌지 않게)이고, 올리는 것은 의도적으로 한다. 고정할 판은 **지금 운영에서 실제로 실리는 2.116.0** 으로(다른 회원이 정상이라 이 판은 검증된 셈). ⚠️ 8개 파일 중 `admin-setpw`·`event-scan`·`report`·sales 3종은 `dist/umd/supabase.js` 경로가 아니라 **패키지 루트**를 부른다 — 고정하면서 **경로도 `dist/umd/supabase.js` 로 통일**한다(§4-4. 둘 다 UMD 라 동작은 같고, 여덟 줄이 글자 그대로 같아야 다음에 판을 올릴 때 하나를 빠뜨리지 않는다).

### 현재 구현과 어긋나는 지점
§1-4 여섯 가지. 그 밖에 충돌 없음 — 재설정 새 형식·관리자 초대·탈퇴 로그아웃(`enforceWithdrawalLogout` 은 재설정 중이면 안 돈다 — 플래그가 안 서면 정상 회원처럼 돈다, 의도)·방문자 집계 4개 영역 확인.

### 의도 모호점
- 개발 세션이 「기획이 정할 것」으로 넘긴 넷은 §3 에 결정으로 적었다. 확정이 필요한 것은 §8.

---

## 3. 결정

| # | 결정 | 근거 |
|---|---|---|
| ① | **`?code=` 는 재설정 신호가 아니다** — `detectRecoveryUrlEarly` 와 `init()` 의 `urlHasRecoveryCode` 두 곳에서 뺀다. 재설정 신호로 남기는 것은 `#reset-pw?` · `PASSWORD_RECOVERY` 이벤트 · 옛 implicit 해시(`type=recovery`·`access_token=`) 셋 | §1-2. 우리 재설정 메일은 `?code=` 를 안 쓴다 |
| ② | 확인 착지에서 **세션이 생겼으면 홈(로그인 상태) + 「メール認証が完了しました」 토스트** | 세션을 버리고 로그인 화면으로 보낼 이유가 없다. 재설정 화면으로 보내 비밀번호를 다시 정하게 하던 흐름은 결함으로 본다(§8-2 확인 전제) |
| ③ | 확인 착지에서 **세션이 없으면 로그인 화면 + 사라지지 않는 안내 「メール認証が完了しました。ログインしてください」** | 다른 브라우저에서 연 경우가 정상 사례다(폰에서 메일, PC 에서 가입). 재설정 화면은 틀린 자리 |
| ④ | 착지 뒤 **주소의 `?code=` 를 지운다**(`history.replaceState`) | 남겨 두면 새로고침 때마다 같은 판정을 반복하고, 이미 쓴 값이 주소창에 남는다. 재설정 새 형식이 `token_hash` 를 지우는 것과 같은 이유 |
| ⑤ | `?error=…expired` 착지는 **로그인 화면**으로 보내고 문구를 「リンクの有効期限が切れました。ログインをお試しください」로 | 지금은 비밀번호 찾기로 보내는데 가입 확인 만료에는 틀린 안내. 로그인을 시도하면 미확인이면 「未認証」 안내가 뜬다(그 뒤 재발송은 백로그) |
| ⑥ | `handleLogin`·`init()` 의 프로필 조회는 **`error` 를 받아 조회 실패와 0건을 가른다.** 실패면 삽입하지 않고 `logAppError('handleLogin.profileFetch', error)` 후 프로필 없이 진행 | 이 저장소 원칙(조회 실패 `null` / 0건 `[]`). 조사 §1 에서 비로그인 401 이 「0건」으로 읽혀 삽입까지 갔다 |
| ⑦ | supabase-js CDN 을 **8개 파일 모두 `@2.116.0` 으로 고정** | 배포 없이 라이브러리가 바뀌는 상태를 끝낸다. 올릴 때는 의도적으로 |
| ⑧ | 아이폰 사파리 세션 유실은 **이번 범위 밖** — 회원 대응은 조사 §4 대로 | 기기 없이 확정 불가 |

---

## 4. 설계

### 4-1. `dev/js/app.js`

- `detectRecoveryUrlEarly()`: `hasCode` 삭제. 조건은 `hasRecoveryHash || hasNewRecoveryLink`. `init()` 안 주석 「PKCE flow: ?code=… (with recovery intent)」(한 곳 — 리뷰어 확인)도 지운다 — **주석이 남으면 다음 사람이 조건을 되살린다.**
- `init()`:
  - `urlHasRecoveryCode` 에서 `has('code')` 삭제.
  - 세션 복원 블록 **앞**에 「확인 착지 판정」 한 곳을 둔다(제안 이름 `handleSignupConfirmLanding`, 새 함수):
    ```
    const confirmCode = new URLSearchParams(location.search).get('code');
    if (confirmCode && !inRecoveryInit) {
      // 주소 정리 — 판정보다 먼저(새로고침 반복 방지). 해시는 그대로 둔다
      history.replaceState(history.state, '', location.pathname + location.hash);
      const {data:{session}} = await db.auth.getSession();
      if (session) { _confirmLandingToast = true; }         // 기존 세션 복원이 로그인 처리, 초기 라우팅이 홈으로(§1-4-3) — 여기서는 토스트 표시만 세운다
      else { _confirmLandingNotice = true; }                // 아래 초기 라우팅에서 login + 안내
    }
    ```
  - 세션 복원 뒤 `_confirmLandingToast` 면 `toast(t('auth.confirm.done'), 'success')`. 초기 라우팅에서 `_confirmLandingNotice` 면 `navigate('login', false)` + `#loginNotice`(신설) 에 `t('auth.confirm.doneLogin')` 표시(사라지지 않는 안내 — `enforceWithdrawalLogout` 이 `#loginError` 에 남기는 것과 같은 방식이되 **오류 상자가 아니라 초록 안내 상자**, §4-3).
  - 🔴 **`inRecoveryInit` 이 참이면 이 판정을 건너뛴다** — `#reset-pw?…` 와 `?code=` 가 함께 오는 주소는 없지만, 있다면 재설정이 이긴다(안전한 쪽). 이 판정은 **그 시점에 플래그가 서 있는지**만 본다(탭 저장소 값 — 주소의 `#reset-pw?`·옛 implicit 해시로 방금 섰든, 같은 탭에서 앞서 선 채 남아 있든). 옛 PKCE 형식처럼 **판정 뒤에** 이벤트로 서는 경우는 덮지 않는다(§2-7 감수).
  - `?error=` 처리(지금 동작은 §1-5 — `forgot` + 고정 문구 토스트): `isExpired` 갈래를 `navigate('login')` + 토스트 문구 `auth.confirm.linkExpired` 로. `else` 갈래(홈)는 그대로.
- ⚠️ **`SIGNED_IN` 핸들러는 손대지 않는다.** 로그인 처리·홈 이동은 §1-4-3 대로 기존 세션 복원과 초기 라우팅이 하고, 이 핸들러는 그때 `currentUser` 가 이미 있어 아무것도 안 한다. 토스트는 세션 복원 뒤에, 안내 상자는 초기 라우팅에서 건다(위).

### 4-2. `dev/js/auth.js` `handleLogin` / `app.js` `init()` 세션 복원

- `const {data:profile, error:profileErr} = await db.from('influencers')…maybeSingle();`
- `profileErr` 면: `logAppError('handleLogin.profileFetch', profileErr)`(정상 거부 아님 — 배지에 뜬다, 의도), 삽입 시도 **안 함**, `currentUserProfile = null` 로 진행. `init()` 쪽도 같은 형태(삽입은 원래 없다 — 기록만).
- `!profile && !profileErr` 면: 지금처럼 `upsertInfluencer` 구제.

### 4-3. 화면·문구 (`dev/index.html` · `dev/lib/i18n/ja.js` · `ko.js`)

| 열쇠말 | 일본어 | 한국어 뜻 | 자리 |
|---|---|---|---|
| `auth.confirm.done` | メール認証が完了しました | 메일 인증이 완료되었습니다 | 세션 있는 착지 — 토스트 |
| `auth.confirm.doneLogin` | メール認証が完了しました。ログインしてください | 메일 인증이 완료되었습니다. 로그인해 주세요 | 세션 없는 착지 — 로그인 화면 안내 상자 |
| `auth.confirm.linkExpired` | リンクの有効期限が切れました。ログインをお試しください | 링크 유효기간이 지났습니다. 로그인을 시도해 주세요 | `?error=…expired` 착지 — 토스트(기존 고정 문구 대체) |

- `#page-login` 에 안내 상자 `#loginNotice`(class **`form-success`** — 비밀번호 찾기 화면의 `#forgotSuccess` 와 같은 초록 상자, `dev/css/auth.css`. 기본 숨김) 추가 — `#loginError`(빨강) 와 **별도**. 같은 요소를 쓰면 다음 로그인 실패가 안내를 지우거나, 안내가 오류처럼 보인다. 「인증 완료」는 좋은 소식이라 주황(`form-notice`)이 아니라 초록이다.
- 기존 토스트 「リンクの有効期限が切れました。もう一度お試しください。」(코드에 박힌 고정 문구) → 열쇠말로 옮긴다.

### 4-4. CDN 버전 고정 (8개 파일)

`https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.116.0/dist/umd/supabase.js` 로 통일(경로까지). `dev/index.html`·`dev/admin/index.html` 은 `onload/onerror` 속성 유지. ⚠️ **빌드 산출물(루트 `index.html`·`admin/index.html`·`sales/*.html`)은 `dev/build.sh` 가 만든다 — 직접 고치지 않는다.**

### 4-5. 손대지 않는 것

- `handleRecoveryTokenLink`·`handleResetPassword`·`handleForgotPassword`·`dbAuthRequest` — 재설정 흐름은 이번 결함과 무관하고 2026-07-20 에 검증됐다.
- `APP_ERROR_EXPECTED_PATTERNS` 의 `/Auth session missing/i` — §1-4-4.
- `enforceWithdrawalLogout`·방문자 집계·초대 링크 복귀(`consumeInviteReturn`) — 플래그가 안 서면 정상 회원과 같은 경로.

---

## 5. 조각 (작업표를 따로 만들지 않고 이 표가 대신한다 — 파일 12개(A 5 + B 8, `dev/index.html` 겹침)·데이터베이스 변경 없음·조각 2개)

| 조각 | 담당 파일 | 산출 계약 | 완료 정의 |
|---|---|---|---|
| **A. 착지 경로 정정** | `dev/js/app.js` · `dev/js/auth.js` · `dev/index.html`(로그인 화면 안내 상자) · `dev/lib/i18n/ja.js` · `ko.js` | 결정 ①~⑥ · 열쇠말 3개 · `#loginNotice` · `handleLogin.profileFetch` 기록 자리 | §7 의 시나리오 1~6 통과 |
| **B. CDN 버전 고정** | `dev/index.html`(스크립트 태그)·`dev/admin/index.html`·`dev/admin-setpw.html`·`dev/event-scan.html`·`dev/report.html`·`dev/sales/{orient,reviewer,seeding}.html` 8개 + 빌드 | 결정 ⑦ | 빌드 산출물 전부에 `@2.116.0` 이 실리고, **여덟 파일이 만드는 화면 전부**(인플루언서·관리자·관리자 비밀번호 설정·현장 확인·리포트·sales 3종)가 한 번씩 실제로 뜬다(§7-7) |

- A 와 B 가 겹치는 파일은 `dev/index.html` 하나(A 는 로그인 화면 안내 상자, B 는 스크립트 태그 — 다른 줄). **같은 병합 요청에 넣는 것을 권장**하고, 나눈다면 A 를 먼저 병합한 뒤 B.
- 검문소: `reverb-supabase-expert`(인증 흐름 변경) → `reverb-reviewer` → **개발서버 브라우저 재현(§7)** → dev 병합 → 운영은 사용자 확인.

---

## 6. 영향 없는 것 (명시)

- 데이터베이스·마이그레이션·Edge Function·메일 양식 — 변경 없음(가입 확인 메일은 `ConfirmationURL` 그대로).
- 관리자 앱 — B 의 CDN 고정만 닿는다.

---

## 7. 검증 절차 (개발서버 — 「Confirm email」이 꺼져 있어 준비가 필요)

**준비**: 개발 Supabase → Authentication → Providers → Email → 「Confirm email」을 **잠깐 켠다**(끝나면 반드시 끈다 — 개발서버는 발송 시험 금지 정책이라 **이 검증에 필요한 최소량만** 허용: 확인 메일 2통(시나리오 1·2 는 각각 새 링크가 필요하다) + 재설정 메일 1통(시나리오 5), `.claude/rules/supabase.md`). ⚠️ 운영에서 가입해 보는 것은 **병합 전 검증이 될 수 없다**(그 시점 운영에는 고친 코드가 없다) — 운영 가입은 **운영 배포 뒤** 시나리오 1·2 를 한 번 더 확인하는 용도다.

| # | 시나리오 | 기대 |
|---|---|---|
| 1 | **같은 브라우저**에서 가입 → 확인 메일 링크 클릭 | 홈 · 로그인 상태 · 「メール認証が完了しました」 토스트 · 주소에 `?code=` 없음 · 재설정 화면 **안 뜸** |
| 2 | **다른 브라우저**(또는 시크릿 창)에서 링크 클릭 | 로그인 화면 · 안내 상자 「…ログインしてください」 · 비밀번호로 로그인하면 홈 |
| 3 | 시나리오 2 의 화면에서 새로고침 | 안내는 사라져도 되고, **재설정 화면으로 가지 않는다** |
| 4 | 이미 쓴 확인 링크 재클릭(`?error=…expired`) | 로그인 화면 + 「リンクの有効期限が切れました。ログインをお試しください」 |
| 5 | 비밀번호 찾기 → 메일 링크(`#reset-pw?token_hash=`) | 지금과 같이 재설정 화면·검증·변경 성공(**회귀 없음** 확인) |
| 6 | 로그인 시 프로필 조회를 일부러 실패시킴(개발자 도구로 요청 차단) | 삽입 시도 없음 · 오류 로그에 `handleLogin.profileFetch` 1건 · 홈 진입 |
| 7 | (B) 여덟 파일이 만드는 화면 전부 부팅 — 인플루언서 · 관리자 · `admin-setpw.html`(`?mode=login`) · `event-scan.html` · `report.html` · sales 3종(리뷰어·시딩·오리엔 폼) | 각 화면 콘솔에 `supabase-js` 2.116.0 로드, 오류 없음 |

**운영 배포 뒤 4주 관찰**: 오류 로그 「Auth session missing」(`handleResetPassword`) 주간 발생 수가 **줄어야** 한다(8/11~9/10 65회 기준). 안 줄면 재설정 링크 만료 쪽이 주원인이었다는 뜻이고, 그건 별개 문제다.

---

## 8. 사용자 확인 필요

1. 결정 ②③(세션 있으면 홈, 없으면 로그인 화면 + 안내) — 이대로 가도 되는지. 대안: 둘 다 로그인 화면(단순하지만 생긴 세션을 버린다).
2. 지금까지 **정상 회원도 확인 링크 뒤 「새 비밀번호 설정」 화면을 봤다**(같은 브라우저 갈래). 그 화면을 없애면 「가입 뒤 비밀번호를 한 번 더 정하는」 절차가 사라진다 — 그게 의도된 절차였는지(아니라고 본다).
3. 확인 메일 **재발송 UI**(백로그) — 이번에 같이 할지, 뒤로 미룰지. 권고: 미룬다(이번 결함과 별개, 화면 하나가 더 든다).
4. CDN 고정 판을 **2.116.0** 으로 — 지금 운영에서 실리는 판. 다른 판을 원하면 그 판으로 검증부터.

---

## 구현 결과

**구현일:** 2026-09-10 · **브랜치:** `feature/가입확인-착지` · **데이터베이스 변경:** 없음

### 초안 대비 변경 사항
- **달라진 것 ①** — `?code=` 유무를 `init()` 이 아니라 **스크립트 로드 직후**(`detectRecoveryUrlEarly` 옆, `_signupConfirmCodeSeen`)에 봐 둔다. Supabase 전문 검토(jsdom 재현)에서 supabase-js 2.116.0 이 **교환에 성공하면 초기화 도중 스스로 주소의 `?code=` 를 지운다**는 것이 확인됐다 — `init()` 시점에 주소를 보면 성공한 착지(시나리오 1)의 토스트가 절대 안 뜬다. 실패·미시도 착지에는 `?code=` 가 남아 있어 그때만 `replaceState` 로 지운다(§4-1 의 「판정보다 먼저 지운다」는 이 순서로 바뀜).
- **달라진 것 ②** — 제안된 새 함수 `handleSignupConfirmLanding` 대신 `init()` 세션 복원 자리에 인라인으로 두었다(판정이 여덟 줄이고 세션 값을 그 자리에서 이미 갖고 있다).
- **추가된 것** — `handleLogin` 이 로그인 시도 순간 `#loginNotice` 를 걷는다(§4-3 에 없던 한 줄 — 안내가 로그인 실패 오류와 함께 남지 않게).
- **빠진 것** — 없음.

### 구현 중 확인된 것 (Supabase 전문 검토, 2026-09-10)
- 교환 성공 이벤트는 `SIGNED_IN`(`PASSWORD_RECOVERY` 아님) — 운영 로그의 `user_signedup` 과 일치.
- 옛 PKCE 형식 재설정 링크가 나올 경로는 코드상 없음(`resetPasswordForEmail` 호출부 1곳, implicit 보조 클라이언트 + 양식이 `token_hash` 직접 조립). ⚠️ **대시보드에 붙여 넣은 양식이 저장소 파일과 같은지는 대시보드를 열어야 안다** — 이번엔 확인하지 않았다.
- `?error=` 착지는 쿼리·해시 어느 쪽으로 와도 기존 코드가 양쪽을 본다.
- CDN `@2`(미고정)와 `@2.116.0/dist/umd/supabase.js` 는 **바이트까지 같은 파일** — 고정으로 동작이 바뀌지 않는다.
- ✅ **초대 링크 복귀(`consumeInviteReturn`)가 가입 확인 착지 경로에서 안 돌던 것은 같은 날 후속 조각으로 해소**(아래 「후속 조각 — 초대 링크 복귀」). 원인은 `SIGNED_IN` 핸들러의 `if (!currentUser)` 안에만 있어 세션 복원이 먼저 `currentUser` 를 세우는 이 착지에서는 닿지 않던 것(수정 전에는 재설정 플래그가 먼저 빠져나갔다).

### 검증
- 로컬(빌드 산출물 + 개발 데이터베이스, 2026-09-10): 시나리오 **2·3·4·5·7 통과**(세션 없는 `?code=` 착지 → 로그인 화면+초록 안내·주소 정리·플래그 없음 / 새로고침 후 홈 / 만료 착지 → 로그인+토스트 / `#reset-pw?token_hash=` 종전대로 / 8개 화면 2.116.0 부팅·콘솔 오류 0).
- 개발서버(2026-09-10, 이 사양서 구현 병합 요청 #1454 배포 뒤, 「Confirm email」을 잠깐 켜고 검증 후 껐다): 시나리오 **1·2·5·6 통과**. 위 로컬(2·3·4·5·7)과 합쳐 **§7 의 7개 시나리오 전부가 실제 브라우저에서 확인됐다**(3·4·7 은 로컬에서만 — 착지 판정·부팅은 개발 데이터베이스에 붙은 로컬 산출물로 같은 코드가 돈다).
  - 1(같은 브라우저): 서버가 발급한 실제 교환 코드로 착지 → 홈·로그인 상태·「メール認証が完了しました」 토스트·주소에서 `?code=` 제거·재설정 화면 안 뜸. **`_signupConfirmCodeSeen` 이 없었다면 이 토스트는 안 떴다**(라이브러리가 초기화 중 코드를 지운다).
  - 2(다른 브라우저): 같은 크롬에서 **저장된 검증값 3개를 지워** 재현(실제 확인 링크 GET → `?code=` 착지). 로그인 화면 + 초록 안내, 세션 없음, 재설정 화면 안 뜸. §7 기대의 「비밀번호로 로그인하면 홈」은 이 계정으로는 안 눌러 봤고, 같은 로그인 경로를 시나리오 6(다른 시험 계정)에서 홈 진입까지 확인했다.
  - 5: 실제 재설정 메일의 해시로 만든 `#reset-pw?token_hash=` → 검증·폼·비밀번호 변경·로그인 화면 복귀, 이후 새 비밀번호로 로그인 성공(회귀 없음). ⚠️ 같은 화면 안에서 해시만 바꿔 넣으면 검증이 안 돈다(새 페이지로 열려야 한다 — 실제 메일 링크는 그렇다).
  - 6: 프로필 조회를 코드로 401 실패시킨 채 로그인 → 삽입 요청 0건·홈 진입·오류 로그 `handleLogin.profileFetch` 1건(`is_expected=false`).
  - **메일함을 열지 않고 검증한 방법**(발송 자체는 됐다 — 확인 2통·재설정 1통, §7 준비가 허용한 범위): 가입 뒤 `auth.users.confirmation_token`(해시)을 `GET /auth/v1/verify?token=<해시>&type=signup` 에 그대로 넣으면 서버가 메일 링크와 똑같이 처리한다(`token_hash=` 는 GET 에서 안 받는다). 재설정은 `recovery_token` 을 `#reset-pw?token_hash=` 에. 시험 회원 2명·시험 오류 기록은 검증 뒤 삭제했다.
  - 관찰(이번 변경과 무관): 재설정 링크를 열면 **같은 브라우저의 다른 탭**이 재설정 화면으로 함께 넘어간다(탭 동기화, 기존 동작).

### 후속 조각 — 초대 링크 복귀 (2026-09-10, 사용자 지시로 「행사 켜기 전」에서 앞당김)
- **무엇**: 초대 링크(`#detail-{id}?invite=…`)로 들어와 가입한 회원이 **같은 브라우저**에서 확인 링크로 돌아오면 홈이 아니라 **그 캠페인 상세**로 되돌린다(토스트는 그대로). 브랜치 `feature/초대복귀-확인착지`, `dev/js/app.js` 한 곳.
- **어디**: `init()` 초기 라우팅 사슬에서 `confirmLandingNotice` 갈래 다음에 `else if (confirmLandingToast && consumeInviteReturn())` — 캠페인 목록이 실린 뒤라 상세를 열 수 있고, `consumeInviteReturn` 이 한 번 쓰면 지우므로 `SIGNED_IN` 핸들러 자리(그대로 둠, 주석만 정정)와 겹쳐도 두 번 열리지 않는다. 초대가 없는 일반 가입은 `false` 를 받아 종전대로 홈.
- **안 되는 것(원래 한계)**: 세션 없음 갈래(다른 브라우저)는 저장소가 달라 돌아갈 곳이 없다 — 로그인 성공 자리(`auth.js`)가 받는다.
- ⚠️ 리뷰 지적(후속 과제): 확인 메일을 늦게 눌러 그 캠페인이 삭제·비공개가 된 경우 `openCampaign` 이 조용히 돌아가 화면은 홈인데 주소만 `#detail-{id}` 로 남는다 — `openCampaign` 의 기존 동작이고 이 갈래로 도달 가능해졌다.
- **검증**: ⚠️ **브라우저 실증 미완**(2026-09-10 세션 종료 시점). 리뷰어가 코드 추적으로 ①②③④(openCampaign 시점·이중 열림 없음·일반 가입은 홈·홈 replaceState 와 충돌 없음)를 확인했고 dev 병합 #1459 로 개발서버에 올라가 있으나, 초대 링크 → 가입 → 확인 링크 → 캠페인 상세 복귀를 실제 브라우저로는 아직 보지 않았다. 다음 세션이 할 것: 개발서버 「Confirm email」 켜기 → 초대 링크(`#detail-{초대 전용 시험 캠페인}?invite=…`) → 게이트 「会員登録」 → 가입 → `auth.users.confirmation_token` 으로 `GET /auth/v1/verify?token=…&type=signup` → 같은 탭에서 그 캠페인 상세 + 「メール認証が完了しました」 토스트 확인 → 일반 가입은 홈(회귀) → 「Confirm email」 끄기·시험 회원 삭제. **운영 배포는 그 뒤에.**
