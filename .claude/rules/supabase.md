---
description: Supabase DB/Storage/Auth 접근 패턴 규칙
globs: "dev/lib/*.js,dev/js/*.js,supabase/**/*.sql"
---

# Supabase 규칙

## 환경 분리
- **운영서버**: `twofagomeizrtkwlhsuv.supabase.co` (🇦🇺 Sydney `ap-southeast-2`, Pro / NANO compute)
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
- **운영 프로젝트** (twofagomeizrtkwlhsuv): Authentication → Sign In / Providers → Email → `Confirm email` **ON** 유지 필수 (보안·메일 유효성 검증)
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
- `invite_admin(email, name, role)` RPC 사용
- 클라이언트는 RPC 성공 후 `resetPasswordForEmail()` 호출하여 초대 메일 발송
- 받은 사람이 메일 링크로 직접 비밀번호 설정 (이메일 유효성 자동 검증)
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
- **Brevo 플랜: Starter 20,000 emails/월** (Monthly $29, 갱신일 매월 16일). Marketing+Transactional 공용 쿼터. 2026-04-16 Free 300/일 폭주로 Starter 업그레이드
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
