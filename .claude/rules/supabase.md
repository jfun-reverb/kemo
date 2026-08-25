---
description: Supabase DB/Storage/Auth 접근 패턴 규칙
globs: "dev/lib/*.js,dev/js/*.js,supabase/**/*.sql"
---

# Supabase 규칙

## 환경 분리
- **운영서버**: `nrwtujmlbktxjgdwlpjj.supabase.co` (🇯🇵 Tokyo `ap-northeast-1`, Pro / NANO compute) — 2026-05-27 도쿄 이관 완료
- **개발서버**: `qysmxtipobomefudyixw.supabase.co` (🇯🇵 Tokyo `ap-northeast-1`, Pro / MICRO compute) — Org 레벨 PRO라 양 프로젝트 모두 Pro 혜택
- URL/Key 관리는 `dev/lib/supabase.js`의 `SUPABASE_ENVS`에서만 (하드코딩 금지)
- 도메인 분기: `globalreverb.com` / `www.globalreverb.com` → 운영, 나머지 → 개발
- DB 변경 흐름(개발서버 먼저 → 검증 → 운영 적용)은 `.claude/rules/git.md` 「배포 워크플로 (필수)」 정의처 참조

## DB 접근 패턴
- DB 참조 시 항상 `db?.from()` 사용 (null-safe, DEMO_MODE 대응)
- `.single()` 절대 금지 → 반드시 `.maybeSingle()` 사용
- DB 함수는 반드시 `dev/lib/storage.js`에 집중 (다른 파일에서 직접 쿼리 금지)
- 새 DB 함수 추가 시 기존 패턴 따르기: `async function fetchXxx()`, `async function insertXxx()`, `async function updateXxx()`

## Supabase Client 옵션
- PKCE flow 필수 (`flowType: 'pkce'`) — 비밀번호 재설정 링크 안정성 보장
- `detectSessionInUrl: true`, `persistSession: true`, `autoRefreshToken: true`
- service_role key는 절대 클라이언트 코드에 넣지 않음

## Auth Confirm email 환경별 설정
- **운영 프로젝트** (nrwtujmlbktxjgdwlpjj): Authentication → Sign In / Providers → Email → `Confirm email` **ON** 유지 필수 (보안·메일 유효성 검증)
- **개발 프로젝트** (qysmxtipobomefudyixw): `Confirm email` **OFF** — 테스트 인플루언서 계정 즉시 로그인 가능 (2026-04-16 설정)
- 클라이언트 코드는 `signUp` 응답의 `data.session` 유무로 분기 (auth.js:57-65): session 있으면 바로 홈으로, 없으면 메일 확인 안내 화면
- **대시보드 수동 설정은 repo에 반영되지 않음** — Supabase 프로젝트 재구축 시 이 섹션 참고하여 다시 설정

## Auth 레코드 완전성 (매우 중요)
관리자/유저 생성 시 `auth.users`에 아래 필드 모두 채우지 않으면 로그인 실패 발생:
- `email_confirmed_at` = now() (NULL이면 로그인 차단)
- `raw_app_meta_data` = `{"provider":"email","providers":["email"]}`
- `raw_user_meta_data` = `{"sub":"<uuid>","email":"...","email_verified":true,"phone_verified":false}`
- `email_change`, `phone_change`, 각종 token 필드 = `''` (NULL 금지, 빈 문자열 필수)
- `auth.identities`에 대응 행 필수 (provider='email', provider_id=auth_id)
- bcrypt round는 10 사용 (`gen_salt('bf', 10)`)

## 관리자 추가 (필수)
- `invite_admin(email, name, role)` 원격 호출 함수로 계정 생성
- 이어서 **`sendAdminInviteMail(email, 'invite')`**(storage.js) → Edge Function `notify-admin-invite` 가 **서버에서** 비밀번호 설정 링크를 발급하고 관리자 전용 한국어 메일을 Brevo 로 보낸다
- 받은 사람은 자립형 페이지 `/admin-setpw.html` 에서 직접 설정
- 🔴 **`resetPasswordForEmail()` 을 쓰지 않는다** — 되살리지 말 것. 이유 둘: ①메일 양식이 종류별로 하나뿐이라 인플루언서 비밀번호 찾기와 문구를 공유하게 된다 ②`flowType:'pkce'` 라 코드 교환 검증값이 **호출한 브라우저**(초대한 관리자)에 저장돼, 링크를 여는 초대 대상의 다른 브라우저에서는 교환이 **반드시 실패**한다. 메일은 정상 도착하고 링크만 안 먹어서 실패가 조용하다. 2026-07-20 개편(사양서 `docs/specs/2026-07-20-admin-invite-mail-and-setpw.md`)
- ⚠️ 위 금지는 **관리자 초대 경로에만** 해당한다. 인플루언서 비밀번호 찾기(`dev/js/auth.js`)는 지금도 `resetPasswordForEmail` 을 쓰며 그게 맞다
- **`create_admin()` 함수는 deprecated — 호출 시 예외 발생** (migration 032)

## 관리자 삭제 (2택)
- `remove_admin_role(auth_id)` — admins 행만 제거, 인플루언서 계정/데이터 유지
- `delete_admin_completely(auth_id)` — applications, receipts(Stage 7에서 deliverables로 통합 예정), admins, influencers, identities, auth.users까지 cascade
- 자기 자신 삭제 차단 (`target_auth_id = auth.uid()` 검증)

## 비밀번호 재설정 플로우
- 클라이언트: `resetPasswordForEmail(email, {redirectTo: location.origin + '/#reset-pw'})`
- app.js: PASSWORD_RECOVERY 이벤트 + sessionStorage `reverb.recovery` 플래그로 다중 탭 대응
- 재설정 성공 후 반드시 `signOut()` + 플래그 제거 + 로그인 페이지로 이동
- **초기 로드 시 URL에서 즉시 navigate 금지** (Supabase SDK의 비동기 세션 확립 전 URL hash 소실 위험)

## RLS 주의사항
- campaigns: SELECT 공개, CUD는 관리자만
- influencers: 본인 데이터만 SELECT/UPDATE, 관리자는 전체 SELECT
- applications: 본인 INSERT/SELECT, 관리자는 전체 접근
- `is_admin()`: admins 테이블에서 auth.uid() 조회 (JWT email 하드코딩 금지)
- CUD 함수는 `retryWithRefresh()` 래퍼 사용 (세션 만료 시 자동 갱신 후 재시도)
- 새 테이블 추가 시 반드시 RLS 정책 포함
- anon key는 공개 전제 → RLS가 유일한 방어선 (감사 필수)

## Storage
- 이미지 업로드: Supabase Storage `campaign-images` 버킷 사용
- `uploadImage()` 함수 사용 (dev/lib/storage.js)
- localStorage에 base64 이미지 직접 저장 금지 (용량 초과 위험)
- 양 서버에 동일 버킷 생성 + Storage 정책 복제 필수

## SMTP / 이메일
- 양 서버 모두 **Brevo** Custom SMTP 사용 (`smtp-relay.brevo.com:587`)
- **Brevo 플랜: Starter 20,000 emails/월** ($32/월, **2026-08-25 재구독**). Marketing+Transactional **공용 쿼터**. 2026-04-16 Free 300/일 폭주로 Starter 업그레이드
  - ⚠️ **금액·용량·갱신일을 문서로 믿지 말 것** — 이 줄은 오래 「$29 · 갱신일 매월 16일」이었는데 **셋 다 사실과 달랐다**(2026-08-25 실측: 만료 전 40,000통/월, 만료일 8/20, 재구독가 $32). 판단이 필요하면 **Brevo 우측 상단 「Usage and plan」을 직접 열어** 볼 것
  - 실사용량 참고(2026-08-25 실측): **7월 931통 · 8월 1~20일 1,487통**, 홍보 시작 후 피크 **하루 200통 이상**

### 🔴 메일이 안 나갈 때 보는 순서 (2026-08-25 확립)

**구독이 만료되면 Brevo 는 발송을 멈추고 큐에 쌓아 둔다 — 오류가 아니라 침묵이다.** 2026-08-20 20:25 만료 후 **5일간 회원가입 확인·비밀번호 재설정·검수 알림이 전부 안 나갔고**, 끊긴 것을 **회원 문의로만** 알았다(큐 476통).

| # | 어디 | 무엇을 보나 |
|---|---|---|
| 1 | **Supabase 대시보드 → Logs → Auth** | 그 이메일로 검색. `/signup` 응답 코드 + `event_message` 의 `auth_event.action`(`user_confirmation_requested` 면 **발송 요청은 된 것**) |
| 2 | **Brevo → Transactional → Logs** | 같은 주소로 검색. **0건이면 Brevo 에 도달조차 안 한 것** |
| 3 | 🔴 **Brevo → 우측 상단 「Usage and plan」** | **구독 만료 · 크레딧 0 · `N paused emails`(큐)**. 2026-08-25 사고의 답이 여기 있었다 |
| 4 | Brevo → Statistics | 기간을 넓혀 **발송이 언제 끊겼는지** |

⚠️ **함정 셋 — 전부 「화면에 보이는 것을 확인 없이 사실로 읽은」 것이다**
1. **`First opening`·`Opened`·`Clicked` 는 열람이지 발송이 아니다.** 발송을 보려면 **More filters → Events → `Sent`** 로 거른다. 이걸 오독해 「지금도 메일이 나가고 있다」고 잘못 보고했다
2. **「Usage and plan」 팝업은 페이지 로드 시점 값이라 갱신되지 않는다.** 결제 뒤에도 옛 값(만료·큐 476)을 보여줘 「아직 복구 안 됨」으로 오판했다 — **새로고침하고 Real time 화면으로** 확인할 것
3. **Brevo 수신자 검색은 정확 일치**다. 도메인으로 보려면 검색 종류를 **`Recipient domain`**, 제목은 **`Subject line`** 으로 바꾼다

⚠️ **아직 없는 것** — 발송이 끊긴 것을 **자동으로 알려 주는 장치가 없다.** 그 알림도 메일이면 함께 죽으므로 **다른 경로**여야 한다.
- Supabase 기본 메일 서버는 3-4건/시간 제한이라 운영 불가
- Site URL은 반드시 `https://` 프로토콜 포함 (슬래시 누락 사고 사례 있음)
- Redirect URLs에 양 환경 URL 모두 등록 (`https://globalreverb.com/**`, `https://dev.globalreverb.com/**`)
- 발신 도메인은 Brevo에서 DNS 인증 필수 (SPF/DKIM/DMARC)
- Auth Rate Limits (Authentication → Rate Limits):
  - 운영: `Rate limit for sending emails` = **100 emails/h** (2026-04-16 30→100 상향)
  - 개발: 30/h 유지 (Confirm email OFF, 트래픽 적어 충분)
  - 한도 소진 증상: `429 email rate limit exceeded`. Logs & Analytics → Auth에서 확인
  - 대시보드 수동 설정이라 repo에 반영 안 됨 — 재구축 시 이 섹션 참고

## 메일 발송 테스트 환경 정책 (2026-05-19 사용자 명시)

- **개발서버는 환경(코드·DB·Edge Function 배포)만 운영과 동일하게 구축, 실제 발송 테스트는 운영에서만**
- 신규 메일 파이프라인 Edge Function 작성·머지 시 흐름:
  1. dev 브랜치 commit + push → 개발서버 코드 자동 배포
  2. 개발 데이터베이스 SQL Editor 에서 마이그레이션 적용 (환경 동기화 목적)
  3. `supabase functions deploy <fn> --project-ref qysmxtipobomefudyixw` 로 개발 Edge Function 배포 (환경 동기화 목적)
  4. **수동 호출·발송 테스트는 건너뜀** — curl / Dashboard Test function 안내 생략
  5. 운영 dev → main 머지 후 운영 데이터베이스 + Edge Function 배포 + 운영에서 수동 호출로 발송 검증
- 적용 대상: 캠페인 홍보 메일 같은 **대량 다이제스트·마케팅 메일**. 영수증 검수 메일 등 트랜잭션 메일은 별도 판단
- 운영에서 첫 수동 호출 시 `*_runs` 로그 + 인박스 도착 + `*_digest_sent` 행을 단계별로 확인
- cron 자동 등록은 별도 PR (PR 5 패턴)에서 수동 호출 안정성 검증 후 진행

**Why:** 개발서버 DB 에도 실제 인플 데이터가 있어 잘못 발송 시 실수 발송 위험 + Brevo 일일 한도 소모 누적. 운영 적용 단계에서 같은 SQL Editor + 같은 deploy 명령으로 한 번에 검증하는 패턴을 사용자가 선호. 영구 메모리 `feedback_dev_no_mail_test.md` 와 함께 영구 적용.

## 브라우저에서 직접 호출하는 Edge Function은 CORS 필수 (2026-07-01, 오리엔 발급 메일 사고)

이 프로젝트의 Edge Function은 대부분 **웹훅·pg_cron·DB 트리거**로 실행돼 CORS(브라우저가 다른 도메인의 함수를 부를 때 필요한 허용 헤더)가 필요 없다. 하지만 **브라우저(관리자·인플 화면)에서 `functions.invoke()` 로 직접 호출**하는 함수는 다르다. `globalreverb.com`(브라우저)이 `*.supabase.co`(함수)를 부르면 교차 출처라서, 함수가 CORS 허용 헤더와 `OPTIONS` 사전요청(preflight)을 처리하지 않으면 **브라우저가 응답을 차단**(`CORS error`, 응답 크기 0)한다.

- **판정**: `grep -rlE "functions\.invoke\(['\"]<함수명>|/functions/v1/<함수명>" dev/` 로 클라이언트 호출부(`dev/lib/storage.js` 등) 유무 확인. 있으면 브라우저 직접 호출 함수.
- **필수**: 브라우저 직접 호출 함수는 ① `Access-Control-Allow-Origin`(+ headers·methods) 응답 헤더 ② `if (req.method === 'OPTIONS')` preflight 분기 — 둘 다 있어야 한다. 표준 패턴은 기존 CORS 처리 함수를 참고.
- **런타임 검증 (배포 전 1회)**: CORS 누락은 코드를 읽어서는 안 보이고 **실제 브라우저 호출로만** 드러난다. 개발서버 「실제 메일 발송 테스트 금지」 정책과 **CORS 검증은 분리 가능** — `OPTIONS` preflight 나 빈/무효 페이로드 호출은 **메일을 보내지 않으면서** CORS 응답만 확인할 수 있다. 새로 만들거나 고친 브라우저 직접 호출 함수는 개발서버에서 이 최소 호출을 1회 거친다.
- reverb-reviewer 는 `supabase/functions/*` 변경 시 이 CORS 유무를 정적 점검한다(에이전트 정의 「Edge Function CORS」).

**Why:** 오리엔시트 발급 메일(`notify-orient-sheet`)이 이 프로젝트에서 **유일하게 브라우저에서 직접 호출**하는 함수인데 CORS 처리가 없어, 리뷰 GO·운영 배포까지 통과했지만 실제로는 한 번도 성공하지 못했다. 원인은 ① 리뷰어 점검 항목에 CORS 축이 없었고 ② 「기존 메일 함수엔 CORS 없음」이 반례가 됐으며(그 함수들은 웹훅·크론 실행이라 브라우저 호출이 아님) ③ 발송 테스트 금지 + qa light 로 배포 전 브라우저 호출이 0회였던 것. 정적 리뷰(CORS 항목)와 런타임 검증(preflight 1회)을 둘 다 걸어 재발을 막는다.

## 웹훅 전용 Edge Function 은 공개 키 호출을 거부한다 (2026-08-10, 전수조사 F-10)

**공개 키(`sb_publishable_…`)는 사이트에 그대로 박혀 있다.** 그런데 Edge Function 은 **인증 없이 부르면 401 이지만 그 공개 키로 부르면 200 이 나온다**(2026-08-10 운영에서 직접 확인). 즉 **웹훅으로만 불려야 하는 함수를 누구나 임의 내용으로 부를 수 있다** — 관리자에게 가짜 알림 메일을 보내게 하는 식.

- **대상 판정**: 데이터베이스 웹훅·pg_cron 으로만 호출되는 함수. `grep -rlE "functions\.invoke\(['\"]<함수명>" dev/` 가 0건이면 브라우저 호출이 없는 것 → 이 규칙 대상
- **막는 방법**: 공개 키로 온 호출을 **거부**한다(`rejectPublicKeyCaller` — `notify-brand-application`·`notify-orient-submitted` 참고)
- ⚠️ **「특정 값이어야 통과」로 만들지 마라.** 웹훅 설정은 대시보드에서 손으로 하고 저장소·문서에 기록이 없어, **정상 웹훅이 무엇을 보내는지 확인할 방법이 없다.** 그 값이 아니면 그 메일이 통째로 죽는다 — **메일이 죽는 쪽이 임의 촉발보다 나쁘다**(신청이 들어와도 아무도 모른다)
- ⚠️ **토큰을 로그에 남기지 마라.** 비교 결과(불리언)만 남긴다
- ⚠️ **공개 키를 교체하면** 각 함수의 목록도 함께 갱신해야 한다
- **좁힐 수 있는 조건**: 로그로 정상 웹훅이 실제로 보내는 값을 확인한 뒤에만 「그 값이어야 통과」로 바꿀 것

**Why:** 이 프로젝트는 「인증이 필요하니 안전하다」고 전제해 왔는데, 그 인증에 **공개 키가 통과**한다. 다만 반대로 조이면 메일 경로가 조용히 죽어 더 나쁘다 — 증명된 구멍만 닫고 나머지는 열어 두는 게 이 상황의 정답이다.

## 마이그레이션 관리
- `supabase/migrations/*.sql` — 영구 보관, 순번 유지, 삭제/이동 금지
- `supabase/patches/*.sql` — 운영 DB 수동 복구용 one-off (마이그레이션 체인 외)
- `supabase/seed/*.sql` — 초기 데이터 투입용 (lookup_values, test_influencers 등)
- Supabase 대시보드 SQL Editor의 저장된 스니펫은 삭제 무관 (repo 파일이 source of truth)

### 마이그레이션/SQL 실행 안내 시 절대경로 명시 (필수, 2026-05-21)
- 마이그레이션·SQL 파일을 생성한 뒤 사용자에게 "SQL Editor에서 실행해 주세요" 라고 안내할 때, **반드시 그 파일의 절대경로를 한 줄로 먼저 제시**한다.
  - 예: `/Users/younggeunkim/Documents/projects/reverb-jp-message-faq/supabase/migrations/146_xxx.sql`
- 특히 worktree(별도 작업 폴더)에서 작업 중이면 파일이 **메인 폴더(`reverb-jp`)의 migrations 목록에는 보이지 않는다**. 사용자가 평소 보는 VS Code 트리는 메인 폴더라서 "파일을 안 만들어줬다"고 오해한다.
- 안내 형식: ① 절대경로 한 줄 → ② "이 파일을 열어 전체 복사 → 개발(또는 운영) SQL Editor에 붙여넣고 Run" 순서.
- VS Code에서 안 보인다고 하면 `File > Add Folder to Workspace`로 해당 worktree 폴더를 함께 여는 방법도 안내.

**Why:** 개발 세션이 worktree에서 만든 마이그레이션 파일이 사용자가 보는 메인 폴더 트리에 안 떠서 "언제부턴가 파일을 안 올려준다"는 오해가 반복됨. 파일은 정상 생성됐고 위치만 다른 것 (2026-05-21 진단). 메모리 `feedback_migration_abspath_in_worktree.md` 와 함께 영구 적용.

### 기준 데이터(lookup_values 등) 추가 시 기존 중복 확인 (필수, 2026-06-23)
- `lookup_values`(채널·카테고리·콘텐츠 종류·반려사유 등) 같은 **기준 데이터/선택지성 행**을 추가하는 마이그레이션·시드는, 작성 **전에 반드시 기존 동종 항목(같은 `kind`)을 조회**해 의미 중복이 없는지 확인한다. 표기·대소문자·전각/반각 차이(`@Cosme` vs `@cosme`)도 중복으로 본다.
- ⚠️ **함정**: `supabase/seed/lookup_values.sql`(초기 데이터)에 이미 있는 항목을 후속 마이그레이션이 **다른 `code`로 또 추가**하면, 식별자가 달라 유니크 제약에 안 걸리고 **화면 선택지에 중복 노출**된다. 시드는 메인 폴더 트리에 늘 보이지만 개발 세션이 마이그레이션만 보고 시드를 안 읽는 경우 발생.
- 확인 절차(둘 다): ① `grep -rni '<항목명>' supabase/seed/ supabase/migrations/` 로 기존 정의 탐색 ② 개발 DB에서 `SELECT code, name_ko, name_ja, sort_order, active FROM lookup_values WHERE kind = '<kind>' ORDER BY sort_order;` 로 실제 현황 조회.
- `reverb-supabase-expert` 는 `lookup_values`·기준 데이터 추가 마이그레이션을 점검할 때 **기존 동종 항목과의 중복 여부를 필수 확인**한다.
- 이건 `planning.md` 「규칙 A — 현재 상태 검증」(사양서 작성 전, 기획 세션)의 **개발 세션·마이그레이션 작성 단계 짝**이다. 사양서에 안 잡혀도 마이그레이션 작성자가 한 번 더 막는다.

**Why:** 마이그레이션 157(LIPS·@cosme 채널 추가)이 시드 `lookup_values.sql` 의 「엣코스메(name_ja=`@Cosme`, code=`channel-96r9y3`)」를 확인하지 않고 「`@cosme`(code=`cosme`)」를 또 추가 → 캠페인 등록 화면 채널 선택지에 `@Cosme`·`@cosme` 가 나란히 중복 노출. 코드 정적 리뷰로는 못 잡는 **데이터 의미 중복**이라, 마이그레이션 작성 단계의 기존 항목 확인이 유일한 방어선 (2026-06-23 발견).

### 신규 데이터베이스 함수는 적용 성공이 동작 확인이 아니다 (필수, 2026-08-18)

마이그레이션에 **신규 함수(원격 호출 함수·트리거 함수)** 가 들어 있으면, 「적용 Success」 는 검증이 아니다. **함수를 만드는 구문은 본문의 자료형·컬럼 참조를 검사하지 않는다** — 적용은 성공으로 끝나고 **첫 호출에서 터진다.**

- **의무**: 개발 데이터베이스에 적용한 뒤 **신규 함수마다 최소 1회 실제 호출**한다. 빈 결과라도 좋다 — 자료형 불일치·컬럼 모호성·권한 가드가 그 순간 드러난다.
- **실측 사례 2종**: `42804`(반환 자료형이 선언과 불일치 — 2026-08-18 마이그레이션 335) · `42702`(`RETURNS TABLE` 의 출력 컬럼명과 본문의 한정 안 된 컬럼 참조 충돌 — 2026-05-20 응모건 메시지). 둘 다 **읽어서는 잘 안 보이고 실행하면 100% 터지는** 유형이다.
- ⚠️ **메일 발송 함수는 예외 없이 예외** — 발송이 없는 페이로드나 `OPTIONS` 사전요청으로만 호출한다(위 「메일 발송 테스트 환경 정책」 과 경계 유지).
- ⚠️ **관리자 가드가 걸린 함수는 SQL 편집기로 재현되지 않는다**(서비스 키에는 로그인 사용자가 없어 그 분기가 아예 안 돈다). 실제 로그인한 브라우저 세션의 콘솔에서 부른다.

**Why:** 이 조항은 원래 `.claude/agents/reverb-supabase-expert.md` 체크리스트에만 있었다. **에이전트 정의는 그 에이전트를 부를 때만 읽힌다** — 개발 세션이 마이그레이션을 직접 만들고 그 에이전트를 안 부르면 존재조차 모른다. 2026-08-18 에 정확히 그렇게 되어 같은 함정에 다시 빠졌다(마이그레이션 335 가 적용 성공 후 첫 호출에서 `42804`). **데이터베이스 전문 에이전트도 리뷰어도 원리적으로 못 잡는다** — 둘 다 파일을 읽을 뿐 데이터베이스에 접속할 수단이 없다. 늘 읽히는 규칙 파일로 올려 에이전트 호출 여부와 분리한다. 메모리 `feedback_db_function_smoke_test` 가 이 반영을 지시했으나 3개월간 이행되지 않았다.

## 접근 허가를 좁히는 변경 — 실패가 조용하다 (2026-08-18, 마이그레이션 312 사고)

행 단위 보안 정책(RLS)을 **없애거나 좁히는** 마이그레이션, 원본 표를 가림막 뷰로 갈아타는 변경은 **다른 종류의 위험**을 갖는다 — 막히면 오류가 아니라 **빈 결과(0행)** 가 돌아온다. 오류 로그(`client_error_logs`)에도 안 남고, 정적 코드 리뷰에도 안 걸리고, 화면은 그냥 「데이터 없음」으로 보인다. **아무도 모른 채 몇 주가 지난다.**

### 마이그레이션 작성 시 (의무)

1. **고칠 자리 목록을 글자 검색만으로 만들지 않는다.** 세 형태를 각각 따로 찾는다 — 상세 표는 `.claude/rules/request-validation.md` 「이름 전파 점검」.
   - ① `db.from('표이름')` ② **표 이름을 인자로 받는 헬퍼** ③ **조회문 안쪽 임베드 조인**(`select('*, 표이름:열(…)')`)
   - ⚠️ **임베드 조인도 그 표의 정책을 그대로 받는다.** 바깥 표는 조회되는데 **끼워 넣은 쪽만 `null`** 이 되어, 화면은 목록이 나오면서 특정 열만 빈다 — 가장 알아채기 어려운 형태다.
2. **찾은 자리 수를 마이그레이션 파일 주석에 적고, 어떤 방법으로 찾았는지도 적는다.** 「관리자 화면 5곳」처럼 숫자만 적으면 다음 사람이 그 숫자를 믿는다.
3. **자립형 단독 화면을 빠뜨리지 않는다** — `dev/event-scan.html`·`dev/admin-setpw.html` 은 `storage.js` 를 안 쓰고 자체 조회를 갖고 있어 공용 함수를 고쳐도 안 따라온다.

### 적용 후 검증 (의무 — 숫자 대조로 갈음 금지)

- **실제 로그인한 브라우저에서** 영향 화면을 하나씩 열어 **눈으로** 확인한다. ⚠️ **SQL 편집기로는 재현되지 않는다** — 서비스 키에는 로그인 사용자가 없어 정책 분기가 아예 안 돈다(마이그레이션 272·332 와 같은 함정).
- 화면을 다 열기 어렵다면 최소한 관리자 세션 콘솔에서 **화면과 똑같은 조회문**을 그대로 실행해 행 수와 **끼워 넣은 쪽이 `null` 이 아닌지**를 본다.
- 데이터가 0건인 영역(예: 아직 안 열린 행사)은 **개발서버 시험 데이터로** 확인한다. 운영에 데이터가 없다고 「이상 없음」이 아니다 — 데이터가 생기는 날 터진다.

### 리뷰 의뢰 시

`reverb-reviewer` 에게 「같은 유형 누락 없는지」만 맡기지 않는다. **위 세 형태를 지목해서** 확인시킨다 — 리뷰어가 같은 글자 검색을 반복하면 같은 자리를 같이 놓친다.

**Why:** 마이그레이션 312 가 인플루언서 원본 표의 「관리자면 통과」 허가를 지우면서 고칠 자리를 `.from('influencers')` 글자 검색으로 모았다. ②형태 1곳(`_proxyFetchByIds('influencers', …)`)과 ③형태 3곳(`influencers:influencer_id (…)`)이 안 걸려 관리자 화면 4곳이 조용히 죽었다. 파일 주석은 「관리자 화면 5곳」이라 적었지만 실제로는 9곳이었다. ②는 **11일간** 아무도 몰랐고(결과물 대리 등록의 캠페인 검색), ③은 그 사고를 고친 날 리뷰어가 **같은 검색으로** 「누락 없음」이라 확인해 또 넘어갔다 — 그중 하나가 **행사 현장 입장 확인 화면**이라 열흘 뒤 현장에서 터질 뻔했다.

## 계정 열거 방지
- 정의·구현 패턴(비밀번호 찾기 조건부 메시지 등)은 `.claude/rules/security.md` 「계정 열거 방지 (Account Enumeration)」 정의처 참조

## localStorage 폴백 (DEMO_MODE)
- Supabase 미연결 시 자동으로 localStorage 동작
- DB 함수에서 `if (!db)` 체크 후 localStorage 폴백 처리
- localStorage 저장 시 이미지 데이터는 별도 키로 분리

## SQL 검증 순차 안내 (필수)
- 여러 SQL을 순서대로 실행해야 할 때 **한 번에 전부 안내 금지**
- 실행 → 결과 확인 → 다음 SQL 순서로 **1단계씩** 진행
- 결과에 따라 분기가 있으면 `AskUserQuestion`으로 결과를 먼저 물어본 후 다음 안내
- 오류 발생 시 즉시 멈추고 원인 파악 후 재안내

**Why:** SQL 10개를 한 번에 쏟아내면 3번째 오류 시 4~10번 설명이 모두 토큰 낭비. 결과 없이 A·B 분기를 모두 써놓으면 혼란 (2026-05-14 지적).
