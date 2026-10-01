---
description: 관리자 계정·비밀번호 찾기 요청 기록·메일 수신 구독·관리자 공지 표(묶음 규칙)
paths:
  - "dev/js/admin-accounts.js"
  - "dev/admin-setpw.html"
  - "dev/js/admin-notices.js"
  - "dev/js/admin-core.js"
  - "dev/js/admin-dashboard.js"
  - "dev/js/admin-roadmap.js"
  - "dev/lib/shared.js"
  - "dev/js/auth.js"
  - "dev/js/ui.js"
  - "dev/build.sh"
  - "supabase/functions/password-range-lookup/**"
  - "supabase/migrations/417_*"
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

## CLAUDE.md 기준 데이터·번들·관리자 계정 절에서 옮겨 온 것 — 오픈 예정 보드·관리자 공지·관리자 계정 (2026-10-01 조각 D′)
- **오픈 예정 기능 보드**(`/admin#upcoming`, 관리자 전원 읽기): 시행 예정 기능·D-day 카드(가까운 순). **DB 미사용** — `dev/lib/shared.js` 의 `UPCOMING_FEATURES` 상수(배포 시 1줄 등록). 시행 후 14일 뒤 숨김. 판정은 클라 `+09:00` 날짜 단위. ⚠️ **예고판일 뿐 기능 스위치 아님**(`effectiveDate`는 실제 시행일과 단일 소스). 렌더 `dev/js/admin-roadmap.js`, 헬퍼 `upcomingFeatureStatus`/`Dday`/`visibleUpcomingFeatures`. 사양서 `docs/specs/2026-06-15-admin-upcoming-features-board.md`
- **관리자 공지사항**(`/admin#admin-notices`): 사이드바 최상단 + 미읽음 배지. 카테고리 4종(system_update/release/warning/general), 고정(push_pin), Quill. **draft/published 분리** — 신규·draft는 `[초안 저장][게시하기]`, published는 `[게시 유지하며 저장][초안으로 되돌리고 저장]`. 작성자/super 한정 `[지금 게시]`/`[게시 회수]`. 노출은 published 만. 초안은 `/공지초안-관리자`
- **관리자 계정**: 3단계 권한(super_admin > campaign_admin > campaign_manager)
  - **추가**: super_admin 이 이메일+이름+역할 입력 → `invite_admin()` RPC(현재 원본 **417**, 베이스 245 — 이메일 `lower(btrim())` 정규화) → Edge Function `notify-admin-invite` 가 **서버에서** 링크 발급(`auth.admin.generateLink`) + **한국어** 메일 Brevo 발송 → 자립형 `/admin-setpw.html` 에서 설정. 재발송은 「재발송」(super_admin, 서버도 가드) 또는 `mode=reset`. `storage.js` `sendAdminInviteMail(email, mode)`
    - **발송 상태 표시**(마이그레이션 244): `invite_completed_at` 있으면 「설정 완료」 / `invite_mail_sent_at` 있으면 「발송 {날짜}」 / 없으면 「미발송」. 발송 기록은 Edge Function, 설정 완료는 자립형 페이지가 본인 행 UPDATE(`.is(null)` 최초 1회)
    - **기존 계정 승격 시 비밀번호 보존**(마이그레이션 245): 🔴 **기존 비밀번호를 덮어쓰지 않는다** — 덮어쓰면 인플루언서 로그인이 즉시 끊기고, 메일이 스팸함으로 가면 계정에서 잠긴다. `admins.promoted_at` 로 메일 문구가 갈린다(승격자=「권한이 추가되었습니다」 / 신규=「비밀번호를 설정해 주세요」)
    - ⚠️ 이메일로 `admins` 조회 시 **`ilike` + 와일드카드 이스케이프**(`escapeLikePattern`). `eq` 는 대소문자를 구분해 못 찾고, 이스케이프 없는 `ilike` 는 `_`·`%` 든 이메일이 다른 행에 매칭된다
    - ⚠️ **`resetPasswordForEmail` 을 안 쓰는 이유**: ①템플릿이 인플루언서 비밀번호 찾기와 공유 ②`flowType:'pkce'` 라 검증값이 **호출한 브라우저**(super_admin)에 저장돼 초대 대상 브라우저에선 교환 실패. 서버 발급은 이 문제가 없음
    - **랜딩이 `/admin/` 밖인 이유**: 관리자 앱은 세션 없으면 리다이렉트(`dev/admin/app.js`). `dev/admin-setpw.html` → `build.sh` 가 루트로 복사. 사양서 `docs/specs/2026-07-20-admin-invite-mail-and-setpw.md`
  - **관리자 전용 로그인 화면**(`/admin-setpw.html?mode=login`): `/admin/` 세션 없음·만료·로그아웃 시 이 화면(옛 `/#login` 대체). 인플루언서 앱에서 관리자 로그인 시 `/admin/` 으로 가는 경로(`auth.js`)는 보존. 관리자 아닌 계정은 안내 + 인플루언서 앱 버튼. ⚠️ **`persistSession` 이 모드마다 다름** — `login`=true / `setpw`=false(임시 세션이 저장소를 공유해 「비밀번호 바꾸기 전에 다른 탭에서 `/admin/` 이 열리는」 사고 방지) + 완료 후 `signOut()`
  - **관리자 비밀번호 찾기**(로그인 화면 → forgot): 익명 Edge Function `admin-password-reset-request` 가 관리자면 발송, 아니면 아무것도 안 함. **계정 존재 여부 비노출** — 모든 분기가 `{ok:true}` 200 + 최소 2500밀리초로 수렴. **요청 제한 3층**(이메일별 5분1회·24시간5회 / 전역 시간당 30건 / 형식·길이) — Brevo 직접 발송이라 Auth Rate Limits 보호가 없고, 한도 소진 시 다른 메일까지 죽기 때문. 제한에 걸려도 「요청이 많습니다」 비노출. 마이그레이션 243
  - **흔한 비밀번호 거부**(관리자 비밀번호를 정하는 세 곳 — 초대·재설정 화면·「내 계정」·슈퍼관리자 초기화): 브라우저가 SHA-1 앞 5글자만 서버 함수 `password-range-lookup` 에 보내 Have I Been Pwned 목록과 대조(`commonPasswordCheck` — `ui.js`·`admin-setpw.html` **두 곳**). 🔴 **Supabase 「유출 비밀번호 검사」는 일부러 꺼 둔다**(켜면 회원까지 거부 — 회원은 경고만이 결정). 🔴 **서버 함수를 먼저, 화면을 나중에** 배포 — 함수가 없으면 판정이 조용히 `'unknown'`(통과)이 되어 효과 0이고 오류도 안 난다. 함수는 git 병합으로 반영되지 않아 개발·운영에 따로 배포. 사양서 `docs/specs/2026-09-29-common-password-warning.md`
  - **삭제 2택**: `remove_admin_role`(권한만 해제) / `delete_admin_completely`(auth/influencers/applications/receipts cascade). 자기 삭제 불가
  - **「최근 접속」 열**(마이그레이션 436 → **437**): `get_admin_last_sign_in()` 이 `last_sign_in_at` 과 **`last_active_at` = GREATEST(로그인 시각, `auth.sessions.updated_at` 최댓값)** 을 주고 화면은 뒤쪽을 쓴다(auth 스키마라 브라우저가 못 읽음). 🔴 **로그인 시각만 쓰면 안 된다** — 토큰 연장만 일어나 오늘 쓴 사람이 「어제」로 보인다(436). 🔴 **슈퍼관리자 전용, 두 겹** — `is_super_admin()` 가드 + 실행 권한(PUBLIC·`anon`·`service_role` 회수, `authenticated` 만 부여). 🔴 반환 칸을 바꾸려면 `DROP` 후 `CREATE` 라 **회수를 다시 걸어야 한다**(437). **화면에서 열을 숨기는 것은 보안이 아니다**. ⚠️ 「관리자 화면에 들어온 날」과 다르다 — ①겸직 회원은 인플루언서 화면만 써도 오르고 ②**로그아웃하면 세션 행이 지워져 로그인 시각으로 돌아간다**(툴팁). ⚠️ 열 노출 판정은 **`showLastSignIn` 하나**이고 머리글·셀·빈 상태 `colspan` 이 그것만 본다 — 나누면 표가 밀린다. ⚠️ 조회 실패는 **`null`**(0건 `{}` 와 구분) → 열을 안 그린다. ⚠️ 권한 관리 화면에 이 열 열쇠말이 **없다**(슈퍼 고정) — 열려면 마이그레이션 필요
- **메일 수신 설정**(`/admin#admin-accounts`): 「메일받기」 셀 칩 + 「설정」 모달(종류별 체크박스). `admin_email_subscriptions` + `lookup_values(kind='admin_email_kind')`. super_admin 은 타인 편집 가능. 새 종류는 `lookup_values` 한 줄로
- **내 계정**: 이름/비밀번호
