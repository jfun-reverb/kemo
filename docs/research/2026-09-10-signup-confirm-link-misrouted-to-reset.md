# 조사: 가입 확인 링크가 비밀번호 재설정 화면으로 빠짐 + 아이폰 사파리 세션 유실

**조사일:** 2026-09-10 · **조사자:** 개발 세션 · **대상:** 운영 회원 1명(9월 10일 새벽 가입, 아이폰 사파리) 로그인 반복 실패 문의
**넘기는 곳:** 기획 세션 — 화면 흐름 변경이라 사양서가 필요하다. 이 문서는 **근거 기록**이고 설계 결정은 안 담았다.
**읽기 전에:** 회원 개인정보(이메일·아이피)는 적지 않았다. 필요하면 운영 오류 로그 화면에서 9월 10일 03:51·03:58 의 `handleLogin.upsertInfluencer` 행을 찾으면 된다.

---

## 1. 무엇이 일어났나 (한국 시각, 전부 운영 로그로 확인)

| 시각 | 회원 행동 | 서버(인증 로그·API 게이트웨이) | 앱 오류 로그 |
|---|---|---|---|
| 03:49:48 | 회원가입 (아이폰 사파리) | `/auth/v1/signup` 200 · `auth.flow_state` 생성(PKCE, `email/signup`) | — |
| 03:50:32 | 확인 메일 링크 클릭 | `GET /verify` 303 · `user_signedup` · flow_state 에 `auth_code_issued_at` 기록 → **주소에 `?code=` 를 달고 착지** | — |
| 03:50~03:51 | (착지 화면) | **`/token?grant_type=pkce` 호출 없음** — 교환을 시도조차 안 함 | — |
| 03:51:04 | 비밀번호로 로그인 | `/token` 200 · Login 이벤트 · **`auth.sessions` 행 생성** | `GET /rest/v1/influencers` 200(빈 결과) → `POST /rest/v1/influencers` **401** → 「new row violates row-level security policy」 (`handleLogin.upsertInfluencer`, 화면 해시 `#reset-pw`) |
| 03:56:51 / 04:05:04 / 04:05:21 / 04:06:17 | 확인 메일 링크 **재클릭 4회** | `GET /verify` 303 (이미 쓴 토큰) | — |
| 03:57:11 · 04:06:30 · 04:06:53 · 04:11:59 · 04:16:33 | 비밀번호 재설정 메일 요청 5회 | `/recover` (04:06:53 은 연타 제한 경고) | 「35초 뒤에 다시」 |
| 03:58:07 | 비밀번호로 로그인 (2회째) | `/token` 200 · 세션 행 생성 | 03:51 과 **완전히 같은** 401 |
| 04:07:33 · 04:12:29 · 04:16:58 | 재설정 링크 클릭 | `/verify` + Login 이벤트 · 세션 행 3개 생성 | 04:15:06·04:16:24 「Email link is invalid or has expired」(`handleRecoveryTokenLink` — 앞선 링크 재클릭) |
| 04:17:35 | 새 비밀번호 제출 | 요청 도달 안 함 | 「Auth session missing!」 (`handleResetPassword`) |
| 12:35:21 | **같은 이메일로 회원가입 재시도** | `/signup` 200 (기존 계정이라 가짜 응답, 메일 안 나감) | — |

**계정 상태(조사 시점):** 메일 확인 완료 · 차단 없음 · 탈퇴 신청 없음 · 관리자 겸직 아님 · 회원 행 정상(이름·생년월일·동의 시각 있음) · **비밀번호 변경 이력 없음**(`auth.users.updated_at` = 마지막 재설정 링크 검증 시각). `auth.sessions` 5행 모두 `refreshed_at` 비어 있음 = **어느 세션도 한 번도 쓰이지 않았다.** `auth.refresh_tokens` 5행 모두 미회수·미사용.

**같은 시간대 다른 회원(12:36 가입):** 가입 → 확인 → 5초 뒤 로그인 성공. 전면 장애가 아니다.

## 2. 확정된 앱 결함 — `?code=` 착지를 「재설정 중」으로 취급

`dev/js/app.js` 맨 위 `detectRecoveryUrlEarly()`:

```js
const hasCode = new URLSearchParams(location.search).has('code');
...
if (hasCode || hasRecoveryHash || hasNewRecoveryLink) sessionStorage.setItem('reverb.recovery', '1');
```

- 주석은 「PKCE flow: ?code=... (with recovery intent)」라 적혀 있지만, **가입 확인 링크(`{{ .ConfirmationURL }}`)도 PKCE 라 `?code=` 로 착지한다.** 인증 로그의 `user_signedup` + `flow_state.auth_code_issued_at` 이 그 증거다.
- 플래그가 서면 부팅 시 `initPage = 'reset-pw'`, `SIGNED_IN` 이 와도 `navigate('reset-pw')`, 세션이 있어도 로그인 취급 안 함(`inRecoveryInit`).
- supabase-js(2.116.0) 는 `_isPKCECallback` 에서 **저장소에 검증값(code verifier)이 있을 때만** 교환한다. 없으면 오류도 없이 그냥 넘어간다(`?code=` 는 주소에 남는다). 그래서 가입한 브라우저 저장소와 다른 곳에서 링크를 열면 **세션 없이 「새 비밀번호 설정」 화면**에 떨어지고, 제출하면 「Auth session missing」이다.
- 운영 오류 로그 「Auth session missing!」(`handleResetPassword`) 은 **2026-08-11 부터 65회**. 이 결함 경로와 재설정 링크 만료가 섞여 있어 몇 건이 이 경로인지는 구분 안 된다.

**정상 회원에게도 일어난다** — 같은 브라우저에서 확인 링크를 열면 교환이 성공해 세션이 생기지만, 플래그 때문에 `SIGNED_IN` 핸들러가 **홈이 아니라 재설정 화면으로** 보낸다. 거기서 새 비밀번호를 넣으면 성공하고 로그아웃 → 로그인 화면. 「가입했더니 비밀번호를 또 정하라고 한다」는 흐름이 지금 기본 동작이다. (이번 조사에서 실측한 것은 세션 없는 갈래이고, 세션 있는 갈래는 코드 읽기로만 확인했다 — 사양 전에 개발서버에서 한 번 재현해 볼 것.)

## 3. 확정 못 한 것 — 그 사파리는 왜 세션을 못 붙잡았나

- 가입도 같은 아이폰 사파리(같은 UA)였는데 확인 링크 착지에서 검증값이 없었다.
- 비밀번호 로그인은 서버에서 성공했는데(세션 행 생성) 바로 다음 요청(`admins`·`influencers` 조회, `influencers` 삽입)이 **비로그인(anon)** 으로 나갔다 — 401 은 PostgREST 가 anon 역할에 주는 코드다.
- 재설정 링크 검증(`verifyOtp`) 성공 뒤 37초 만에 `updateUser` 가 「세션 없음」.
- 앱 코드에는 이 흐름에서 `signOut` 하는 자리가 없다(`enforceWithdrawalLogout` 은 재설정 중이면 안 돈다). supabase-js 의 `_saveSession` 은 저장 실패를 삼키지 않는다(실패했으면 로그인 함수가 예외를 던져 다른 오류가 남았을 것).
- 남는 가설: 그 기기의 사이트 저장소가 쓰기는 되는데 읽기가 안 되는 상태(사파리 프로필 분리, 사이트 데이터 손상 등). **기기 없이는 확정 불가.**
- 참고: 앱은 CDN 에서 `@supabase/supabase-js@2` 를 **버전 고정 없이** 받는다. 지금 실리는 2.116.0 은 2026-09-07 배포다. 회귀가 의심되면 고정을 검토할 것 — 다만 다른 회원은 정상이라 이번 건의 원인으로 단정하지 않는다.

## 4. 회원 대응 (코드 변경 없이 지금 할 수 있는 것)

1. 회원가입을 다시 하지 말 것(이미 가입돼 있고, 재가입 요청은 서버가 조용히 무시한다).
2. 크롬 등 **다른 브라우저나 PC** 에서 비밀번호 찾기 → 메일 링크도 **같은 브라우저**에서 열어 새 비밀번호 설정.
3. 그래도 안 되면 사파리 설정에서 globalreverb.com 사이트 데이터 삭제 후 재시도.

## 5. 기획이 정할 것 (개발 의견 — 결정 아님)

- 확인 링크 착지에서 **검증값이 없을 때**: 재설정 화면 대신 **로그인 화면 + 「메일 확인이 끝났습니다. 로그인해 주세요」** 안내. `?code=` 만으로 재설정 플래그를 세우지 않는 방법이 필요하다(재설정 링크는 이미 `#reset-pw?token_hash=` 새 형식이라 `?code=` 에 기대는 재설정 경로가 아직 남아 있는지부터 확인).
- 검증값이 **있을 때**(세션 생김): 홈으로 보낼지, 지금처럼 재설정 화면을 둘지.
- `handleLogin` 의 「프로필이 없으면 만든다」 구제 경로: 조회가 비로그인으로 나가면 **없는 것처럼 보여** 삽입을 시도한다. 조회 실패와 0건을 구분해야 한다(이 저장소의 「조회 실패 null / 0건 [] 구분」 원칙).
- supabase-js CDN 버전 고정 여부.

## 6. 확인에 쓴 자리

- 운영 Supabase SQL 편집기(읽기만): `auth.users`·`auth.identities`·`auth.sessions`·`auth.refresh_tokens`·`auth.flow_state`·`public.influencers`·`public.withdrawal_requests`·`public.admins`·`public.client_error_logs`·`pg_policies`(influencers 4정책)
- 운영 로그: Auth 로그(회원 id 검색) · API 게이트웨이 로그(`influencers`·`signup` 검색)
- 앱 코드: `dev/js/app.js`(`detectRecoveryUrlEarly`·`init`·`onAuthStateChange`) · `dev/js/auth.js`(`handleLogin`·`handleResetPassword`·`handleForgotPassword`) · `dev/lib/supabase.js` · `dev/lib/storage.js`(`upsertInfluencer`·`retryWithRefresh`)
- `auth.audit_log_entries` 는 운영에서 0행(비어 있다) — 다음에 찾지 말 것.
