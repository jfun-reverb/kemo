-- ============================================================
-- 084_security_advisor_cleanup.sql
-- Supabase Security Advisor 경고 73건 일괄 해소
--
-- 목적:
--   1. SECURITY DEFINER 함수 PUBLIC EXECUTE 권한 정리
--      - 트리거 전용 함수: REVOKE FROM PUBLIC + REVOKE FROM authenticated
--      - 관리자 전용 함수: REVOKE FROM PUBLIC + GRANT TO authenticated (변경 없는 것은 명시적 재확인)
--      - anon 의도 함수: 현행 유지 (GRANT TO anon, authenticated 명시)
--   2. brand_applications INSERT 정책 Always True 해소
--      - RPC BYPASSRLS 이므로 anon 직접 INSERT 정책 제거 (영향 없음)
--   3. storage.campaign-images LIST 경고는 의도된 public 버킷이므로 변경하지 않음
--      (아래 롤백 섹션에 결정 근거 기록)
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor에서 실행
--   2. 개발서버 Security Advisor 재점검 + 기능 회귀 없음 확인
--   3. 운영서버(twofagomeizrtkwlhsuv) SQL Editor에서 동일 SQL 실행
--
-- 롤백:
--   롤백 섹션 참고. 각 REVOKE에 대응하는 GRANT 복원문 준비됨.
--
-- 영향 범위:
--   - sales/reviewer.html, sales/seeding.html: submit_brand_application() RPC 경유 — 영향 없음
--   - dev/lib/storage.js: update_deliverable_status, submit_deliverable 등 authenticated 호출 — 영향 없음
--   - 트리거 함수들: DB 내부에서만 호출됨 — 클라이언트 직접 호출 없음
--   - brand_applications INSERT 직접 호출: 없음 (코드 grep 확인 완료)
-- ============================================================

BEGIN;

-- ============================================================
-- §1. 트리거 전용 함수 — REVOKE FROM PUBLIC + REVOKE FROM authenticated
--     이 함수들은 트리거에서 자동 호출되며, 클라이언트에서 직접 호출할 이유가 없음.
--     RETURNS trigger 함수는 트리거 선언 없이 직접 호출해도 에러이므로 방어적으로 차단.
-- ============================================================

-- handle_new_user: auth.users INSERT 시 influencers 레코드 자동 생성 (014)
REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.handle_new_user() FROM authenticated;
REVOKE ALL ON FUNCTION public.handle_new_user() FROM anon;

-- touch_lookup_values_updated_at: lookup_values 업데이트 트리거 (024)
REVOKE ALL ON FUNCTION public.touch_lookup_values_updated_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.touch_lookup_values_updated_at() FROM authenticated;
REVOKE ALL ON FUNCTION public.touch_lookup_values_updated_at() FROM anon;

-- set_deliverables_updated_at: deliverables 업데이트 트리거 (035)
REVOKE ALL ON FUNCTION public.set_deliverables_updated_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_deliverables_updated_at() FROM authenticated;
REVOKE ALL ON FUNCTION public.set_deliverables_updated_at() FROM anon;

-- record_deliverable_status_event: 결과물 상태 변경 이력 트리거 (035 → 073 재정의)
REVOKE ALL ON FUNCTION public.record_deliverable_status_event() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_deliverable_status_event() FROM authenticated;
REVOKE ALL ON FUNCTION public.record_deliverable_status_event() FROM anon;

-- sync_receipt_to_deliverable: receipts → deliverables dual-write 트리거 (035)
REVOKE ALL ON FUNCTION public.sync_receipt_to_deliverable() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sync_receipt_to_deliverable() FROM authenticated;
REVOKE ALL ON FUNCTION public.sync_receipt_to_deliverable() FROM anon;

-- notify_deliverable_status: 결과물 상태 변경 시 알림 생성 트리거 (037)
REVOKE ALL ON FUNCTION public.notify_deliverable_status() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.notify_deliverable_status() FROM authenticated;
REVOKE ALL ON FUNCTION public.notify_deliverable_status() FROM anon;

-- check_monitor_slots: 리뷰어 캠페인 슬롯 초과 신청 차단 트리거 (048)
REVOKE ALL ON FUNCTION public.check_monitor_slots() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.check_monitor_slots() FROM authenticated;
REVOKE ALL ON FUNCTION public.check_monitor_slots() FROM anon;

-- auto_approve_monitor: 리뷰어 캠페인 자동 승인 트리거 (049)
REVOKE ALL ON FUNCTION public.auto_approve_monitor() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.auto_approve_monitor() FROM authenticated;
REVOKE ALL ON FUNCTION public.auto_approve_monitor() FROM anon;

-- generate_brand_application_no: 광고주 신청 채번 트리거 (052 → 078 재정의)
REVOKE ALL ON FUNCTION public.generate_brand_application_no() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generate_brand_application_no() FROM authenticated;
REVOKE ALL ON FUNCTION public.generate_brand_application_no() FROM anon;

-- recalc_brand_application_totals: 광고주 신청 금액 재계산 트리거 (052)
REVOKE ALL ON FUNCTION public.recalc_brand_application_totals() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.recalc_brand_application_totals() FROM authenticated;
REVOKE ALL ON FUNCTION public.recalc_brand_application_totals() FROM anon;

-- brand_applications_touch: 광고주 신청 updated_at 트리거 (052)
REVOKE ALL ON FUNCTION public.brand_applications_touch() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.brand_applications_touch() FROM authenticated;
REVOKE ALL ON FUNCTION public.brand_applications_touch() FROM anon;

-- generate_campaign_no: 캠페인 번호 채번 트리거 (055)
REVOKE ALL ON FUNCTION public.generate_campaign_no() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generate_campaign_no() FROM authenticated;
REVOKE ALL ON FUNCTION public.generate_campaign_no() FROM anon;

-- recompute_campaign_applied_count: 캠페인 applied_count 재계산 헬퍼 (058)
-- 참고: 이 함수는 트리거 내부에서만 호출되는 헬퍼. 클라이언트 직접 호출 불필요.
REVOKE ALL ON FUNCTION public.recompute_campaign_applied_count(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.recompute_campaign_applied_count(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.recompute_campaign_applied_count(uuid) FROM anon;

-- sync_campaign_applied_count: 신청 수 동기화 트리거 (058)
REVOKE ALL ON FUNCTION public.sync_campaign_applied_count() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sync_campaign_applied_count() FROM authenticated;
REVOKE ALL ON FUNCTION public.sync_campaign_applied_count() FROM anon;

-- guard_influencer_flag_columns: 인플루언서 플래그 컬럼 변경 권한 검증 트리거 (059)
REVOKE ALL ON FUNCTION public.guard_influencer_flag_columns() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.guard_influencer_flag_columns() FROM authenticated;
REVOKE ALL ON FUNCTION public.guard_influencer_flag_columns() FROM anon;

-- touch_admin_notices_updated_at: 관리자 공지 updated_at 트리거 (063)
REVOKE ALL ON FUNCTION public.touch_admin_notices_updated_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.touch_admin_notices_updated_at() FROM authenticated;
REVOKE ALL ON FUNCTION public.touch_admin_notices_updated_at() FROM anon;

-- record_brand_application_history: 광고주 신청 변경 이력 트리거 (079)
REVOKE ALL ON FUNCTION public.record_brand_application_history() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_brand_application_history() FROM authenticated;
REVOKE ALL ON FUNCTION public.record_brand_application_history() FROM anon;

-- touch_brand_application_memos_updated_at: 메모 updated_at 트리거 (080)
REVOKE ALL ON FUNCTION public.touch_brand_application_memos_updated_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.touch_brand_application_memos_updated_at() FROM authenticated;
REVOKE ALL ON FUNCTION public.touch_brand_application_memos_updated_at() FROM anon;

-- record_brand_application_memo_history: 메모 변경 이력 트리거 (081)
REVOKE ALL ON FUNCTION public.record_brand_application_memo_history() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_brand_application_memo_history() FROM authenticated;
REVOKE ALL ON FUNCTION public.record_brand_application_memo_history() FROM anon;

-- generate_brand_no: 브랜드 채번 트리거 (082)
REVOKE ALL ON FUNCTION public.generate_brand_no() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generate_brand_no() FROM authenticated;
REVOKE ALL ON FUNCTION public.generate_brand_no() FROM anon;

-- set_brand_name_normalized: 브랜드명 정규화 트리거 (082)
REVOKE ALL ON FUNCTION public.set_brand_name_normalized() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_brand_name_normalized() FROM authenticated;
REVOKE ALL ON FUNCTION public.set_brand_name_normalized() FROM anon;

-- sync_brand_application_stats: 브랜드 신청 통계 동기화 트리거 (082)
REVOKE ALL ON FUNCTION public.sync_brand_application_stats() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sync_brand_application_stats() FROM authenticated;
REVOKE ALL ON FUNCTION public.sync_brand_application_stats() FROM anon;


-- ============================================================
-- §2. RLS 내부용 함수 (is_admin / is_super_admin / is_campaign_admin)
--     이 함수들은 RLS 정책 USING 절에서 호출되므로 PUBLIC EXECUTE가 있어도
--     실질 위험은 없음(정보 반환만, 권한 행사 불가). 그러나 Advisor 경고 해소를 위해
--     PUBLIC 제거 후 authenticated 한정으로 좁힘.
--
--     주의: RLS USING 절에서 호출되는 함수는 클라이언트 role로 실행되므로
--     authenticated 권한이 있으면 RLS 평가에 문제없음. anon 사용자가 캠페인 SELECT 등
--     공개 RLS 정책을 통과할 때 is_admin()이 호출되는 경우가 있음.
--     → anon에도 EXECUTE를 유지해야 할 수 있음. 아래 경고 주석 참고.
--
--     !! 주의 !!
--     campaigns 테이블 SELECT 정책이 "USING (true)"처럼 is_admin()을 호출하지 않는다면
--     anon 제거 안전. 그러나 혹시라도 다른 테이블 RLS 정책이 anon + is_admin() 조합을
--     사용하면 anon EXECUTE 제거 시 해당 정책이 에러 처리됨.
--     → 안전하게 anon은 유지, PUBLIC만 명시적 REVOKE (PUBLIC != anon).
--
--     PostgreSQL에서 PUBLIC REVOKE 후 anon/authenticated 별도 GRANT는 안전합니다.
-- ============================================================

-- is_admin: RLS 내부 + 클라이언트 간접 호출 (via RLS)
REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_admin() TO anon;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;

-- is_super_admin: RLS 내부 + 클라이언트 간접 호출 (via RLS)
REVOKE ALL ON FUNCTION public.is_super_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_super_admin() TO anon;
GRANT EXECUTE ON FUNCTION public.is_super_admin() TO authenticated;

-- is_campaign_admin: RLS 내부 + 클라이언트 간접 호출 (via RLS)
REVOKE ALL ON FUNCTION public.is_campaign_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_campaign_admin() TO anon;
GRANT EXECUTE ON FUNCTION public.is_campaign_admin() TO authenticated;


-- ============================================================
-- §3. 관리자 전용 RPC — PUBLIC 제거, authenticated만 유지
--     함수 내부에서 is_admin()/is_super_admin() 추가 검증하므로
--     authenticated GRANT여도 일반 인플루언서가 호출하면 403 반환.
-- ============================================================

-- reset_admin_password: 관리자 비밀번호 직접 리셋 (008, 사용 빈도 낮음)
REVOKE ALL ON FUNCTION public.reset_admin_password(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reset_admin_password(uuid, text) TO authenticated;

-- create_admin: deprecated (032), 호출 시 RAISE EXCEPTION 발생
-- PUBLIC 제거는 deprecated 함수 보호를 위해 필요
REVOKE ALL ON FUNCTION public.create_admin(text, text, text, text) FROM PUBLIC;
-- authenticated GRANT도 제거: deprecated + 내부 RAISE EXCEPTION으로 어차피 실패
-- (향후 DROP 예정이므로 이중 차단)

-- invite_admin: 이미 GRANT TO authenticated 명시됨 (031) — PUBLIC만 REVOKE 재확인
REVOKE ALL ON FUNCTION public.invite_admin(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.invite_admin(text, text, text) TO authenticated;

-- remove_admin_role: 이미 GRANT TO authenticated 명시됨 (031) — PUBLIC만 REVOKE 재확인
REVOKE ALL ON FUNCTION public.remove_admin_role(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remove_admin_role(uuid) TO authenticated;

-- delete_admin_completely: 이미 GRANT TO authenticated 명시됨 (031) — PUBLIC만 REVOKE 재확인
REVOKE ALL ON FUNCTION public.delete_admin_completely(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_admin_completely(uuid) TO authenticated;

-- update_deliverable_status: 결과물 상태 변경 RPC (관리자 전용, 035)
-- 함수 내부에서 is_admin() 검증
REVOKE ALL ON FUNCTION public.update_deliverable_status(uuid, text, integer, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_deliverable_status(uuid, text, integer, text, text) TO authenticated;

-- record_caution_history: 주의사항 이력 기록 RPC (campaign_admin 이상, 077)
-- 이미 REVOKE FROM PUBLIC + GRANT TO authenticated 적용됨 — 재확인
REVOKE ALL ON FUNCTION public.record_caution_history(
  uuid, uuid, uuid, jsonb, jsonb, uuid, uuid, jsonb, jsonb, integer, boolean
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_caution_history(
  uuid, uuid, uuid, jsonb, jsonb, uuid, uuid, jsonb, jsonb, integer, boolean
) TO authenticated;


-- ============================================================
-- §4. 인플루언서 본인 호출 RPC — PUBLIC 제거, authenticated만
-- ============================================================

-- submit_deliverable: 결과물 제출 (인플루언서 본인, 035)
-- 함수 내부에서 user_id = auth.uid() 검증
REVOKE ALL ON FUNCTION public.submit_deliverable(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_deliverable(uuid) TO authenticated;

-- upsert_admin_notice_read: 공지 읽음 처리 (관리자 + 인플루언서, 063)
-- 이미 REVOKE FROM anon + GRANT TO authenticated 적용됨 — 재확인
REVOKE ALL ON FUNCTION public.upsert_admin_notice_read(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_admin_notice_read(uuid) TO authenticated;


-- ============================================================
-- §5. anon + authenticated 호출 허용 함수 — 현행 유지 (명시적 재확인)
-- ============================================================

-- submit_brand_application: sales 폼 익명 접수 RPC (068)
-- SECURITY DEFINER + postgres owner(BYPASSRLS)로 실행
-- anon 제거 불가 — sales 폼이 anon 세션에서 호출
REVOKE ALL ON FUNCTION public.submit_brand_application(
  text, text, text, text, text, jsonb, text, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_brand_application(
  text, text, text, text, text, jsonb, text, text, text
) TO anon;
GRANT EXECUTE ON FUNCTION public.submit_brand_application(
  text, text, text, text, text, jsonb, text, text, text
) TO authenticated;


-- ============================================================
-- §6. influencer flag RPC — 이미 정상 (재확인만)
-- ============================================================

-- set_influencer_verified (059): 이미 REVOKE FROM PUBLIC + GRANT TO authenticated 완료
REVOKE ALL ON FUNCTION public.set_influencer_verified(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_influencer_verified(uuid, boolean, text) TO authenticated;

-- set_influencer_blacklist (059): 이미 REVOKE FROM PUBLIC + GRANT TO authenticated 완료
REVOKE ALL ON FUNCTION public.set_influencer_blacklist(uuid, boolean, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_influencer_blacklist(uuid, boolean, text, text) TO authenticated;

-- record_influencer_violation (062, 4인자): 이미 REVOKE FROM PUBLIC + GRANT TO authenticated 완료
REVOKE ALL ON FUNCTION public.record_influencer_violation(uuid, text, text, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_influencer_violation(uuid, text, text, text[]) TO authenticated;

-- update_influencer_violation (062, 4인자): 이미 REVOKE FROM PUBLIC + GRANT TO authenticated 완료
REVOKE ALL ON FUNCTION public.update_influencer_violation(uuid, text, text, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_influencer_violation(uuid, text, text, text[]) TO authenticated;


-- ============================================================
-- §7. brand_applications INSERT 정책 Always True 해소
--     현재: WITH CHECK (true) — anon/authenticated 직접 INSERT 무조건 허용
--     변경: 정책 제거 → 직접 INSERT 차단
--
--     근거:
--     - submit_brand_application() RPC는 SECURITY DEFINER + BYPASSRLS
--       → RLS와 무관하게 항상 성공 (sales 폼 영향 없음)
--     - 관리자는 brand_applications를 INSERT하지 않음 (SELECT/UPDATE/DELETE만)
--     - 직접 INSERT를 허용할 이유가 없음
--
--     주의: 이 변경 후 직접 .from('brand_applications').insert() 호출은 42501 반환.
--     현재 코드(grep 확인): sales/reviewer.html, sales/seeding.html 모두 RPC만 사용 — 안전.
-- ============================================================

DROP POLICY IF EXISTS "brand_applications_insert_public" ON public.brand_applications;

-- GRANT 테이블 레벨도 anon INSERT 제거 (정책 없는 상태에서 GRANT가 남으면 혼란)
REVOKE INSERT ON TABLE public.brand_applications FROM anon;
-- authenticated INSERT GRANT는 관리자 작업용으로 유지 (RLS 정책 "select_admin" 등과 일관성)
-- 단, INSERT 정책이 없으므로 authenticated도 직접 INSERT 불가 (RLS 기본 차단)

-- ============================================================
-- §8. storage.campaign-images LIST 경고
--     결정: 변경하지 않음
--
--     근거:
--     - 버킷이 public=true인 것은 의도된 설계 (비로그인 인플루언서도 이미지 열람 가능)
--     - LIST와 SELECT를 분리하는 Storage RLS 정책은 Supabase에서 현재 지원 안 됨
--     - private으로 전환하면 anon 사용자 캠페인 이미지 접근 불가 → UX 회귀
--     - 실제 파일 경로가 uuid로 구성되어 있어 목록 노출의 실질 위험 낮음
--
--     향후: 버킷 private 전환 + signed URL 방식으로 전환 시 재검토.
-- ============================================================


-- ============================================================
-- 검증 쿼리 (적용 후 아래 쿼리로 결과 확인)
-- ============================================================
/*

-- 1. SECURITY DEFINER 함수별 EXECUTE 권한 현황
SELECT
  n.nspname || '.' || p.proname AS func,
  r.rolname AS grantee,
  'EXECUTE' AS privilege
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
JOIN pg_roles r ON r.oid = ANY(
  SELECT unnest(ARRAY[acldefault('f', p.proowner)]) -- 기본 ACL와 비교용
  UNION
  SELECT (aclexplode(p.proacl)).grantee
)
WHERE n.nspname = 'public'
  AND p.prosecdef = true -- SECURITY DEFINER만
ORDER BY 1, 2;

-- 2. 실용적 확인: 트리거 함수들이 anon/authenticated에서 EXECUTE 불가한지 확인
-- (아래는 anon으로 호출 시 permission denied가 나오면 정상)
-- SET ROLE anon; SELECT public.handle_new_user(); -- RETURNS trigger이므로 에러 다름
-- RESET ROLE;

-- 3. brand_applications INSERT 정책 확인 (없어야 함)
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE tablename = 'brand_applications'
  AND schemaname = 'public'
ORDER BY policyname;
-- 기대 결과: brand_applications_insert_public 행 없음

-- 4. submit_brand_application RPC anon 호출 가능 확인 (변경 없어야 함)
-- SELECT public.submit_brand_application('test',...) -- sales 폼 시뮬레이션

*/

COMMIT;

-- ============================================================
-- 롤백 (변경 취소 시 아래 실행)
-- ============================================================
/*

BEGIN;

-- §1 트리거 함수 롤백 (PUBLIC EXECUTE 복원)
GRANT EXECUTE ON FUNCTION public.handle_new_user() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.touch_lookup_values_updated_at() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_deliverables_updated_at() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_deliverable_status_event() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.sync_receipt_to_deliverable() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.notify_deliverable_status() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_monitor_slots() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.auto_approve_monitor() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.generate_brand_application_no() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.recalc_brand_application_totals() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.brand_applications_touch() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.generate_campaign_no() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.recompute_campaign_applied_count(uuid) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.sync_campaign_applied_count() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.guard_influencer_flag_columns() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.touch_admin_notices_updated_at() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_brand_application_history() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.touch_brand_application_memos_updated_at() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_brand_application_memo_history() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.generate_brand_no() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_brand_name_normalized() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.sync_brand_application_stats() TO PUBLIC;

-- §2 RLS 함수 롤백
GRANT EXECUTE ON FUNCTION public.is_admin() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_super_admin() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_campaign_admin() TO PUBLIC;

-- §3 관리자 함수 롤백
GRANT EXECUTE ON FUNCTION public.reset_admin_password(uuid, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_admin(text, text, text, text) TO PUBLIC;

-- §7 brand_applications INSERT 정책 롤백
CREATE POLICY "brand_applications_insert_public"
  ON public.brand_applications FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);
GRANT INSERT ON TABLE public.brand_applications TO anon;

COMMIT;

*/
