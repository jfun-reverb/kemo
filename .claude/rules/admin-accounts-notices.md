---
description: 관리자 계정·비밀번호 찾기 요청 기록·메일 수신 구독·관리자 공지 표(묶음 규칙)
paths:
  - "dev/js/admin-accounts.js"
  - "dev/admin-setpw.html"
  - "dev/js/admin-notices.js"
  - "dev/js/admin-core.js"
  - "dev/js/admin-dashboard.js"
  - "dev/lib/storage.js"
  - "supabase/functions/notify-admin-invite/**"
  - "supabase/functions/admin-password-reset-request/**"
  - "supabase/functions/notify-*digest*/**"
  - "supabase/functions/notify-brand-application/**"
  - "supabase/functions/notify-orient-submitted/**"
  - "supabase/migrations/*admin*"
  - "supabase/migrations/*notice*"
---

# 관리자 계정·공지 표 (CLAUDE.md 「인플루언서·관리자」 표 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- `admins` — 관리자 계정. `auth_id`, `email`, `name`, `role`(super_admin/campaign_admin/campaign_manager). 초대 추적 4종(마이그레이션 244·245): `invite_mail_sent_at`/`invite_mail_sent_to`· `invite_completed_at`(비밀번호 최초 설정 시각) · `promoted_at`(승격 시각 — 메일 문구 분기). 전부 NULL 허용
- `admin_password_reset_requests` — 관리자 비밀번호 찾기 요청 기록(마이그레이션 243, 요청 제한 판정 전용). `email_hash`(sha256 — **원문 이메일 미저장**: 공개 경로라 유출 시 관리자 명단이 된다)·`requested_at`·`matched`(내부 통계). RLS SELECT `is_super_admin()` / 쓰기 정책 없음(service_role 전용). 판정 `check_admin_password_reset_rate_limit(email_hash, matched)`(service_role 만, `pg_advisory_xact_lock` 직렬화, 항상 1행 기록 — 미매칭도 세야 난사로 메일 한도를 태우는 걸 막는다). 30일 경과 행 삭제 `purge_old_admin_password_reset_requests()` + pg_cron `admin-password-reset-requests-retention-daily`(KST 04:15)
- `admin_email_subscriptions` — 관리자별 메일 수신 구독. `(admin_id, mail_kind)` UNIQUE. `mail_kind` 는 `lookup_values(kind='admin_email_kind')` code 참조(활성 `brand_notify`/`daily_digest`/`campaign_promo`. 구 `application_cancel`·`application_received` 는 164 에서 `daily_digest` 로 통합). RLS SELECT 관리자 전체, CUD 본인 또는 super_admin. 헬퍼 `get_subscribed_admin_emails(p_mail_kind)`
- `admin_notices` — `category`(system_update/release/warning/general), `pin`, `title`, `body_html`, `status CHECK(draft|published)`, `published_at`/`published_by`/`published_by_name`, `created_by`/`created_at`/`updated_at`. SELECT RLS 는 published OR `is_super_admin()` OR `created_by=auth.uid()`. XSS 방어는 저장+렌더 이중 sanitize
- `admin_notice_reads` — 관리자별 읽음. `(notice_id, auth_id)` **기본 키** + `read_at`. `upsert_admin_notice_read` RPC. ⚠️ **칸 이름은 `admin_id` 가 아니라 `auth_id`**(063 원본) — `admin_id` 로 조회하면 「칸이 없다」로 실패한다. ⚠️ 공지 행이 지워지면 읽음 기록도 사라진다(`ON DELETE CASCADE`)
