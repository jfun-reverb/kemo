---
description: 브랜드 계정·로그인 — 표 셋·계정 함수·링크 번호·인플루언서 앱 차단·기존 함수 보호(개발서버만)
paths:
  - "dev/brand/**"
  - "dev/js/brand-*.js"
  - "dev/js/admin-brand.js"
  - "supabase/functions/notify-brand-account-setup/**"
  - "supabase/functions/brand-password-reset-request/**"
  - "supabase/migrations/526_brand_accounts_base.sql"
  - "supabase/migrations/527_brand_account_functions.sql"
  - "supabase/migrations/528_brand_account_guards.sql"
---

# 브랜드 계정·로그인 (CLAUDE.md 에서 옮겨 옴 — 2026-10-15)

#### 브랜드 계정·로그인 (마이그레이션 526~ — 🔴 **개발서버만**, 운영 반영 보류)
> 사양서 `docs/specs/2026-07-15-brand-portal.md` §16-6 · 작업표 `docs/specs/2026-10-14-brand-login-breakdown.md`(조각 11개 · 결정 기록) · 인수인계 `…-brand-login-handoff.md`
> 🔴 **운영 관문**: 브랜드용 이용약관·개인정보처리방침 + `/약관확인` 전에는 운영 데이터베이스에 넣지 않는다. 화면 코드는 `IS_STAGING` 일 때만 계정 생성·판정을 부른다(작업표 P-1) — 출시 때 그 조건을 걷는다
- 표 셋(526): `brand_accounts`(`auth_id` = `auth.users` 1:1, 이메일 `lower(btrim())` 강제·유일) · `brand_account_links`(브랜드 참조 `ON DELETE RESTRICT`, 브랜드당 활성 대표 1명) · `brand_password_reset_requests`(243 복제, 해시만). 셋 다 쓰기 정책 없음 — 읽기는 본인 또는 `is_admin()`(요청 기록은 최고 관리자)
- 🔴 **브랜드 계정 표시는 앱 메타데이터 `raw_app_meta_data.account_kind='brand'`** — 사용자 메타데이터는 공개 키 가입으로 누구나 채우고 383 이 지운다. 계정은 `invite_admin`(417) 방식 직접 삽입 + `email_confirmed_at=now()` 로 만든다(🔴 `auth.admin.createUser` 는 497 가입 관문에 걸린다)
- 🔴 **인플루언서 표 삽입 거부 트리거 `trg_block_influencer_row_for_brand`**(526, DEFINER) — `NEW.id` 가 브랜드 계정이면 `brand_account_not_influencer`. 판정은 `auth.uid()` 가 아니라 `NEW.id`(137 삽입 정책이 로그인만 보면 통과). 인플루언서 앱 `handleLogin` 의 프로필 자동 생성이 이 거부에 걸린다 — 인플루언서 앱 차단(작업표 조각 9)은 **판정 실패(`null`)를 「차단」으로 처리하지 않는다**(함수 없는 서버에서 전원 로그인 불가)
- `get_my_account_kind()`(526) → `'brand'|'other'`, `authenticated` 만(로그아웃 호출은 권한 오류)
- 함수(527, 전부 DEFINER): 관리자 `admin_upsert_brand_owner_account(brand, 이전 대표 줄 id, 이전 이메일)`(캠페인 관리자 이상 — 판정 표는 527 머리말 B. 🔴 화면은 상세를 연 시점의 대표 줄 id·이메일을 **반드시** 넘긴다 — 안 넘기면 이메일 변경으로 본다) · `admin_get_brand_account_status`(관리자 아니면 42501 — 🔴 실패를 「계정 없음」으로 그리지 않는다) · 비로그인 `get_brand_link_state(링크, 'setup'|'reset')` · 임시 세션 `complete_brand_account_setup`(🔴 `updateUser` 먼저 — 비밀번호가 비면 `password_not_set`)·`complete_brand_password_reset` · 로그인 판정 `get_my_brand_login_state`(보관 브랜드 제외) · 서비스 키 전용 `service_issue_brand_account_link`·`service_mark_brand_setup_mail_sent`·`check_brand_password_reset_rate_limit` · 정기 정리 `brand-password-reset-requests-retention-daily`(UTC 21:00, 30일)
- 🔴 **링크 번호 칸 `brand_accounts.setup_link_id` 하나를 계정 만들기·재설정 링크가 같이 쓴다**(피그마 「링크는 보낸 때의 계정 상태에 묶인다」) — 새로 보내면 옛 링크 무효, 설정·재설정을 마치면 비운다
- ⚠️ 알려진 틈(기록만, 다음 작업): 인플루언서 「비밀번호 찾기」·가입 인증번호(499)가 브랜드 이메일에도 동작
- 화면(개발서버만 — 판정 `_brandAccountEnabled()` 한 곳): 인플루언서 앱 차단(`auth.js` `handleLogin`·`app.js` 부팅·로그인 이벤트 — 🔴 판정 실패 `null` 은 차단 아님) · 관리자 브랜드 상세 「계정」 줄(`admin-brand.js` — 🔴 「대표 이메일이 새로·바뀔 때만」은 **화면이** 지킨다: 527 은 계정 없는 브랜드면 이전 값을 안 본다) · 브랜드 화면 `/brand/`
- 기존 함수 보호(528): 계정 연결(활성)이 있는 브랜드는 삭제·병합(원본) 거부, 해제 이력만 있어도 삭제 거부(이력 보존 — 병합으로 안내), 관리자 초대는 브랜드 계정 이메일 거부. ⚠️ **연결 해제 기능이 아직 없다** — 운영 전 어느 조각에서 만들지 정할 것. ⚠️ 병합·초대 거부 문구는 화면 매핑 전이라 영문 코드·일반 오류로 보인다(조각 10)
