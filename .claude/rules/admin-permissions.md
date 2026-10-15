---
description: 관리자 동적 권한 관리 — 등급×기능 표·has_permission 비대칭·슈퍼관리자 잠금 방지·민감정보 가림막(묶음 규칙)
paths:
  - "dev/js/admin-permissions.js"
  - "dev/js/admin-accounts.js"
  - "dev/js/admin-core.js"
  - "dev/admin/app.js"
  - "dev/lib/shared.js"
  - "dev/lib/storage.js"
  - "supabase/migrations/*permission*"
  - "supabase/migrations/*admin_view*"
  - "supabase/migrations/*pii*"
  - "supabase/migrations/*is_campaign_admin*"
---

# 관리자 동적 권한 관리 (CLAUDE.md 「인플루언서·관리자」 표 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **동적 권한 관리 (마이그레이션 207~215)**: super_admin 이 `/admin#permissions` 에서 등급×기능별 쓰기/읽기/숨김 설정 → 사이드바 노출 변경, **민감정보는 서버 가림막 뷰로 실제 차단**(마이그212·213). 메뉴 숨김은 fail-open, `has_permission` 서버 판정은 fail-closed.
  - `role_permissions` — `(role, feature_key)` PK, `access_level CHECK(write|read|hidden)`, `default_level CHECK(write|read|hidden) NOT NULL`(복원 baseline — 마이그214, 207 시드+213 반영), `role CHECK(campaign_admin|campaign_manager|**super_admin**)` — **268 에서 super_admin 추가**. `role_permission_history.role` CHECK 도 함께 확장(빠뜨리면 저장 트랜잭션 전체 롤백). RLS SELECT `is_admin()` / CUD `is_super_admin()`. 시드 = 등급 2종 74행 + **super_admin 42행(전부 write/write)**.
  - `role_permission_history` — 권한 변경 이력. RLS SELECT `is_super_admin()`, INSERT 는 RPC 만.
  - `has_permission(p_feature, p_min default 'read')` RPC (SECURITY DEFINER + `search_path=''`) — 서열 write>read>hidden. ⚠️ **미등록 시 판정이 등급별로 반대(269, 비대칭 계약)**: super_admin 은 행이 없으면 **통과**(시드 누락이 슈퍼 잠금으로 이어지지 않게), campaign_admin·campaign_manager 는 **거부**.
  - `update_role_permissions(p_changes jsonb)` RPC (마이그레이션 211, SECURITY DEFINER `search_path=''`) — 일괄 저장(UPDATE + history INSERT 원자). 가드: is_super_admin·role/level 검증·feature_key 존재·**denylist 2종(방향이 반대라 분리 블록 — 270)**: 등급 2종은 `permissions.manage`/`admin.manage` 가 **hidden 외 거부**(권한 상승 차단), super_admin 은 `permissions.manage`/`admin.manage`/`menu.permissions` 가 **write 외 거부**(잠금 방지)·낙관적 락(prev_level `SELECT FOR UPDATE`)·일괄 상한 200(42키×3등급=126칸).
  - `restore_role_permissions_defaults()` RPC (마이그레이션 215, SECURITY DEFINER `search_path=''`·is_super_admin 가드) — `access_level<>default_level` 행만 되돌림. ⚠️ baseline 이 213 반영이라 **복원해도 campaign_manager sensitive_pii 는 hidden 유지**. 버튼 `admin-permissions.js` `restorePermDefaults`(현재값=기본값이면 비활성). ⚠️ **향후 정책 변경 마이그레이션(213처럼 access_level 의도 변경)은 default_level 도 함께 UPDATE**(드리프트 방지).
  - **슈퍼관리자 자기 제한**(마이그레이션 268·269·270): **슈퍼관리자 열도 편집 가능**. 되돌릴 길을 끊는 4종(`permissions.manage`·`admin.manage`·`menu.permissions`·`menu.admin-accounts`)만 「쓰기(고정)」. **잠금 방지 3중**: ①서버가 그 4종의 write 이탈 거부(270·271) ②진입 가드가 `permissions` 페인만 숨김 판정을 건너뜀(`switchAdminPane`) ③「관리자 계정」 화면이 항상 노출되고 그 안의 「권한 관리」 버튼(`#btnPermManageBtn`)이 **유일한 진입점**. ⚠️ 사이드바에 「권한 관리」 상설 항목은 **없다**(카탈로그에도 `menu.permissions` 없음). 응급 복구는 `UPDATE public.role_permissions SET access_level = default_level WHERE role='super_admin';`(**직접 UPDATE** — 함수는 로그인 세션 필요). 배지 3종(`permSuperEffect`, shared.js) — **서버 차단 5개**(`influencer.sensitive_pii`·`settlement.view`·`settlement.pay`·`outbound.view`·`campaign.caution_history_view`) / **화면에서만**(menu.* + `influencer.excel_sensitive`) / **설정 미적용 12개**(`is_campaign_admin()` 하드코딩). ⚠️ **이 배지는 슈퍼관리자만의 이야기가 아니다** — 「설정 미적용」 12개는 **캠페인관리자·캠페인매니저 칸도 똑같이 무효**라 배지 문구가 **등급 중립**이다(안 그러면 「숨김」으로 두고 **막혔다고 믿는다**). 「슈퍼관리자만 복원」(`restoreSuperPermDefaults`). ⚠️ 이 설정은 **계정별이 아니라 등급 전체**. 사양서 `docs/specs/2026-07-29-super-admin-self-restriction.md`
  - 권한 카탈로그 = `ADMIN_PERMISSION_CATALOG`(shared.js, 화면 21[`menu.settlements` 포함] + 주요기능 19 — `settlement.view`/`settlement.pay` 포함[220 시드, campaign_admin=write·campaign_manager=hidden]). 클라 헬퍼 `permLevel/canWrite/canRead/isHidden`, 부팅 시 `fetchRolePermissions`, `applyLookupMenuVisibility`. 설정 화면 `dev/js/admin-permissions.js`. `switchAdminPane` 진입 가드(permissions=super 전용·hidden 페인 대시보드 리다이렉트). 사양서 `docs/specs/2026-06-15-admin-permission-management.md`
- **`is_campaign_admin()` search_path 정정(마이그레이션 210)**: `search_path='public, pg_temp'` → `''`(`public.admins` 명시). 판정·GRANT 불변(`CREATE OR REPLACE` 시그니처 동일)
