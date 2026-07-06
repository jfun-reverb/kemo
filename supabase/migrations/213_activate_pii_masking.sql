-- ============================================================
-- 213_activate_pii_masking.sql
-- 관리자 동적 권한 관리 PR3 조각 C — 인플루언서 민감정보 실제 차단 발동
-- 사양서: docs/specs/2026-06-15-admin-permission-management.md
--
-- 배경:
--   - PR3 조각 A(마이그레이션 212): 가림막 뷰 influencers_admin_view 생성.
--     has_permission('influencer.sensitive_pii','read') 가 false 인 등급에게
--     전화·LINE·PayPal·우편번호·건물·상세주소 6종을 NULL 마스킹.
--   - PR3 조각 B(코드): fetchInfluencers/fetchInfluencersByIds 를 이 뷰로 교체 +
--     화면 배지·필터를 존재 여부 불리언(has_*) 기준으로 전환.
--   - 하지만 role_permissions 시드(마이그레이션 207)는 campaign_manager 의
--     influencer.sensitive_pii = 'read' 라, 뷰의 CASE 가 true → 아직 값이 그대로 보인다.
--
-- 이 조각 C 가 campaign_manager 의 influencer.sensitive_pii 를 'read' → 'hidden' 으로
--   낮춰 **실제 서버 차단을 발동**한다(사용자 결정: 배포 즉시 하위등급 차단, 2026-07-06).
--   이 순간부터 campaign_manager 로그인 세션은 뷰에서 민감정보 6종을 NULL 로 받는다
--   (네트워크 응답 자체에서 사라짐 — 화면 가림이 아니라 서버 차단).
--
-- 영향 범위:
--   - campaign_admin 은 'read' 유지 → 계속 민감정보 열람 가능(의도된 설계).
--   - super_admin 은 has_permission 이 무조건 true(잠금 방지) → 영향 없음.
--   - campaign_manager 만 차단. 인플루언서 본인은 base 테이블 RLS(본인 행)로 무관.
--
-- 멱등성: access_level='read' 인 경우만 UPDATE → 이미 'hidden' 이면 0행(재실행 안전).
-- 되돌림: 파일 하단 참고(read 로 복구).
-- ============================================================

-- 변경 이력(role_permission_history)도 함께 남긴다. update_role_permissions RPC 를
--   안 거치는 마이그레이션 직접 UPDATE 라, 이 중대한 권한 변경이 관리자 권한 화면의
--   이력 타임라인에 안 남는 걸 방지(reviewer Warning 3). actor=NULL(시스템 마이그레이션).
--   CTE 로 묶어 UPDATE 가 실제 행을 바꿨을 때만(read→hidden) 이력 INSERT → 멱등 유지.
WITH upd AS (
  UPDATE public.role_permissions
     SET access_level = 'hidden'
   WHERE role = 'campaign_manager'
     AND feature_key = 'influencer.sensitive_pii'
     AND access_level = 'read'
  RETURNING role, feature_key
)
INSERT INTO public.role_permission_history (role, feature_key, prev_level, next_level, actor)
SELECT role, feature_key, 'read', 'hidden', NULL FROM upd;

-- PostgREST 스키마 캐시 갱신(role_permissions 는 테이블이라 불필요하나, 권한 관련
--   함수 재평가 안전을 위해 명시)
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 되돌림 (campaign_manager 에게 다시 민감정보 열람 허용)
-- ============================================================
-- UPDATE public.role_permissions
--    SET access_level = 'read'
--  WHERE role = 'campaign_manager'
--    AND feature_key = 'influencer.sensitive_pii'
--    AND access_level = 'hidden';
