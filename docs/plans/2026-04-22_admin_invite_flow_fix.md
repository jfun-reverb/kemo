# 관리자 초대 → 비밀번호 설정 → 로그인 플로우 결함 수정 계획

- **작성일**: 2026-04-22
- **배경**: reverb-supabase-expert 정적 감사에서 핵심 결함 2건 + 확인 필요 3건 발견
- **범위**: C-1 / C-2 / H-3 (H-4, M-1/M-3/N-2는 이번 범위 밖)
- **실행 타이밍**: 계획만 저장. 실제 수정은 추후 세션
- **운영 적용**: 개발 검증 후 다시 결정

---

## 1. 결함 요약

### Critical

#### C-1. 인플루언서 → 관리자 승격 시 auth 메타 누락
- 파일: `supabase/migrations/031_admin_invite_and_delete.sql` 32-40줄
- 기존 유저 UPDATE 분기가 4개 컬럼만 갱신 (`encrypted_password`, `email_confirmed_at`, `email_change`, `raw_app_meta_data`)
- **누락 항목**:
  1. `raw_user_meta_data`에 `email_verified: true` 세팅
  2. `auth.identities` 대응 행 (provider='email') INSERT (없을 경우만)
- **영향**: 운영(Confirm email ON)에서만 로그인 차단. 개발(OFF)에선 통과 → silent divergence

#### C-2. `sendResetEmail()`의 redirectTo 누락
- 파일: `dev/js/admin.js:3601` (관리자 계정 리스트의 "재발송" 버튼)
- `saveAdmin()` (line 3518)은 정상, `sendResetEmail`만 옵션 누락
- **영향**: 재발송 링크 클릭 시 Site URL(홈)로 떨어져 비밀번호 설정 화면 안 열림

### High

#### H-3. `reset_admin_password` 운영 DB 패치 적용 여부 불명
- `supabase/patches/2026-04-15_fix_reset_admin_password.sql`에서 `gen_salt('bf', 10)` + `extensions.crypt` 스키마 한정 수정됨
- 운영 DB에 적용됐는지 SQL 쿼리로 확인 필요

---

## 2. 진단 SQL (운영·개발 각각 실행)

### U-1: Redirect URLs (대시보드 수동 확인)
- 운영 `twofagomeizrtkwlhsuv` → Authentication → URL Configuration
  - Site URL = `https://globalreverb.com`
  - Redirect URLs에 `https://globalreverb.com/**`, `https://www.globalreverb.com/**` 존재 확인
- 개발 `qysmxtipobomefudyixw` → `https://dev.globalreverb.com`, `https://dev.globalreverb.com/**`
- 참고: `#reset-pw` fragment는 Supabase가 path까지만 매칭, fragment는 검사 안 함 → 별도 등록 불필요

### U-2: reset_admin_password 패치 적용 여부
```sql
SELECT p.proname,
       pg_get_function_identity_arguments(p.oid) AS args,
       (p.prosrc LIKE '%extensions.crypt%') AS uses_extensions_crypt,
       (p.prosrc LIKE '%gen_salt(''bf'', 10)%') AS uses_round10
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'reset_admin_password';
```
- **해석**: 둘 다 true → 패치됨, H-3 스킵 / 하나라도 false → 패치 재적용

### U-3: auth.identities 컬럼 NOT NULL 여부
```sql
SELECT column_name, is_nullable, data_type
FROM information_schema.columns
WHERE table_schema = 'auth' AND table_name = 'identities'
ORDER BY ordinal_position;
```
- **해석**: `last_sign_in_at` nullable=YES → OK / NO → migration 064에서 `last_sign_in_at = now()` 추가 필요

### 현재 invite_admin 본문 (031 이후 다른 수정이 있는지)
```sql
SELECT p.prosrc
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'invite_admin';
```

### 진단 결과 기록 체크리스트
- [ ] U-1 운영 Site URL / Redirect URLs 스크린샷
- [ ] U-1 개발 Site URL / Redirect URLs 스크린샷
- [ ] U-2 운영 결과: patched=(Y/N)
- [ ] U-2 개발 결과: patched=(Y/N)
- [ ] U-3 운영 결과: last_sign_in_at nullable=(Y/N)
- [ ] U-3 개발 결과: last_sign_in_at nullable=(Y/N)
- [ ] invite_admin 본문이 031 원본과 동일한지

---

## 3. 수정 작업

### 작업 1 — migration 064: invite_admin 기존 유저 승격 분기 보강 [C-1]
- **파일**: `supabase/migrations/064_invite_admin_upgrade_fix.sql` (신규)
- **내용**: `CREATE OR REPLACE FUNCTION public.invite_admin(...)` 전체 재정의 (031 베이스)
  - 기존 유저 UPDATE 분기에 추가:
    1. `raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('email_verified', true)`
    2. `auth.identities`에 `provider='email'` 행 `WHERE NOT EXISTS` 가드로 INSERT
  - U-3 결과로 last_sign_in_at NOT NULL이면 신규 유저 INSERT에도 `last_sign_in_at = now()` 추가
- **검증**: 기존 인플루언서 이메일 초대 후 `raw_user_meta_data ? 'email_verified'`=true, `auth.identities` 1행 존재 확인
- **롤백**: `CREATE OR REPLACE FUNCTION` 으로 031 원문 재적용

### 작업 2 — admin.js sendResetEmail [C-2]
- **파일**: `dev/js/admin.js:3601`
- **수정**: `resetPasswordForEmail(email)` → `resetPasswordForEmail(email, {redirectTo: location.origin + '/#reset-pw'})`
- **검증**: 재발송 링크 클릭 시 `#reset-pw` 페이지 진입 확인
- **롤백**: 1커밋 revert

### 작업 3 — reset_admin_password 운영 패치 확인·재적용 [H-3]
- U-2 결과가 false면 `supabase/patches/2026-04-15_fix_reset_admin_password.sql` 재실행
- 재검증 U-2로 true 확인

---

## 4. 배포 순서

### Phase A — 진단 (추후 세션 시작 시)
1. U-1/U-2/U-3 SQL 운영·개발 각각 실행
2. 결과에 따라 064 구체 구현 확정

### Phase B — 개발서버 적용
3. migration 064 작성 → 개발 SQL Editor 실행
4. `dev/js/admin.js:3601` 수정 → `cd dev && bash build.sh`
5. H-3 필요 시 개발 DB에 패치 재적용
6. dev 브랜치 커밋·푸시 → Vercel 자동 배포
7. **reverb-reviewer** 호출 (커밋 직전)
8. 개발서버에서 QA 시나리오(§5) 실행

### Phase C — 운영서버 적용 (사용자 승인 후)
9. 운영 SQL Editor에 migration 064 실행
10. H-3 필요 시 운영에도 패치 재적용
11. dev → main PR merge → Vercel 자동 배포
12. 운영 QA 재실행 (테스트 계정만)

---

## 5. QA 시나리오

### 5-A. 신규 이메일 초대 해피패스
1. super_admin → 관리자 계정 → 초대 → 신규 이메일 입력
2. 메일 수신 → 링크 클릭 → `#reset-pw` 진입 → 비밀번호 설정
3. 로그인 → 관리자 페이지 자동 오픈

### 5-B. 기존 인플루언서 승격 (C-1 핵심 회귀)
1. 사전 조건: `sakura.test@reverb.jp` (기존 인플루언서) 준비
2. invite_admin 실행
3. SQL 검증:
```sql
SELECT raw_user_meta_data ? 'email_verified' AS has_flag,
       (raw_user_meta_data->>'email_verified')::boolean AS flag_value
FROM auth.users WHERE email = 'sakura.test@reverb.jp';

SELECT count(*) FROM auth.identities
WHERE user_id = (SELECT id FROM auth.users WHERE email = 'sakura.test@reverb.jp')
  AND provider = 'email';
```
4. 기대: has_flag=true, flag_value=true, identities=1행
5. 초대 메일 링크 클릭 → 새 비밀번호 설정 → 로그인 성공

### 5-C. 재발송 버튼 회귀 (C-2)
1. 관리자 리스트에서 "이메일로 재설정 링크 보내기" 클릭
2. 메일 링크 URL hover → `redirect_to=...%23reset-pw` 포함 확인
3. 링크 클릭 → `#reset-pw` 진입 → 비밀번호 설정 → 로그인

### 5-D. 링크 만료 후 재발송
1. 초대 메일 링크 24시간+ 방치 → 클릭 → 만료 안내
2. 재설정 요청 → 새 링크 → 정상 설정

### 5-E. 자기 자신 삭제 차단
1. super_admin이 자기 계정 "완전 삭제" 시도 → DB에서 차단 (Cannot delete own account)

---

## 6. 경우의 수 분기

| 진단 항목 | 결과 | 대응 |
|---|---|---|
| U-1 운영 Redirect URLs 정상 | OK | 추가 작업 없음 |
| U-1 누락 | 추가 | 대시보드에서 `https://globalreverb.com/**` 등록 |
| U-2 운영 patched=true | OK | H-3 스킵 |
| U-2 운영 patched=false | 패치 | SQL Editor에서 패치 파일 실행 |
| U-3 last_sign_in_at nullable=YES | OK | 064에서 해당 컬럼 미삽입 유지 |
| U-3 last_sign_in_at nullable=NO | 보강 | 064 신규 유저 분기에 `last_sign_in_at=now()` 추가 |
| invite_admin 본문 diff 있음 | 조사 | 누가 언제 고쳤는지 확인 후 064 베이스 재조정 |

---

## 7. 범위 밖 (별도 이슈로 트래킹)

- **M-1**: `reset_admin_password`(비번 직접 설정) vs `resetPasswordForEmail`(링크) UX 이원화 정책 통일
- **M-3**: 링크 만료 시 인플루언서 `#page-forgot`으로 자동 이동 UX 개선
- **N-2**: Supabase 기본 "Reset your password" 템플릿 → "관리자 초대" 맥락 커스터마이징

이 3건은 GitHub Issue로 별도 생성.

---

## 8. 관련 파일 (절대경로)

- `supabase/migrations/031_admin_invite_and_delete.sql` (수정 대상 원본)
- `supabase/migrations/014_auto_create_influencer.sql` (H-4 참조)
- `supabase/patches/2026-04-15_fix_reset_admin_password.sql` (H-3 패치)
- `dev/js/admin.js` (3518 참고, 3601 수정 대상)
- `dev/js/auth.js:161` (기준 패턴)
- `dev/admin/index.html:1342` (sendResetEmail 버튼)
- 신규 예정: `supabase/migrations/064_invite_admin_upgrade_fix.sql`
