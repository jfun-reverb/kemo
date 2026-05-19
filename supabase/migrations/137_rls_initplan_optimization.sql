-- ============================================================
-- 137_rls_initplan_optimization.sql
-- 행 단위 보안 정책(RLS) InitPlan 안티패턴 일괄 수정
--
-- 문제:
--   Supabase Performance Advisor 「Auth RLS Initialization Plan」 경고 88건.
--   USING/WITH CHECK 절에 auth.uid() 등을 직접 호출하면 행(row)마다 함수를
--   재호출한다. 인플루언서 1,000명+ 데이터 누적 시 단순 SELECT도 전체 행을
--   순회하며 함수를 반복 호출해 응답 지연 발생.
--
-- 해결:
--   (SELECT auth.uid()) 처럼 서브쿼리로 감싸면 쿼리 계획 단계에서 1회 평가
--   (InitPlan) 후 상수처럼 재사용. EXISTS/IN 서브쿼리 안의 auth.uid() 도 동일
--   패턴으로 감쌈 (서브쿼리 안에서도 InitPlan 적용됨).
--
-- 대상 정책 (운영 DB pg_policies 기준 26개 전수):
--
--   admin_email_subscriptions
--     - admin_email_sub_cud_self_or_super  (ALL)
--
--   admin_notice_reads
--     - admin_notice_reads_insert  (INSERT)
--
--   admin_notices
--     - admin_notices_delete  (DELETE)
--     - admin_notices_select  (SELECT)
--     - admin_notices_update  (UPDATE)
--
--   admins
--     - admins_delete  (DELETE)
--     - admins_insert  (INSERT)
--     - admins_update  (UPDATE)
--
--   applications
--     - applications_insert_own  (INSERT)
--     - applications_select_own  (SELECT)
--
--   brand_application_memo_reads
--     - brand_app_memo_reads_insert  (INSERT)
--
--   deliverable_events
--     - deliverable_events_select_own  (SELECT)
--
--   deliverables
--     - deliverables_delete_own_draft  (DELETE)
--     - deliverables_insert_own  (INSERT)
--     - deliverables_select_own  (SELECT)
--     - deliverables_update_own_draft_or_pending  (UPDATE)
--     - deliverables_update_own_rejected  (UPDATE)
--
--   influencers
--     - influencers_insert_allow  (INSERT)
--     - influencers_select_own  (SELECT)
--     - influencers_update_allow  (UPDATE)
--
--   notifications
--     - notifications_delete_own  (DELETE)
--     - notifications_select_own  (SELECT)
--     - notifications_update_own  (UPDATE)
--
--   receipts
--     - receipts_insert_own  (INSERT)
--     - receipts_select_own  (SELECT)
--     - receipts_update_own  (UPDATE)
--
-- 방식:
--   DROP POLICY IF EXISTS + CREATE POLICY 재생성
--   (ALTER POLICY는 USING/WITH CHECK 변경 미지원이라 DROP+CREATE가 안전)
--
-- 정책 의미 변경: 없음
--   (SELECT auth.uid()) 는 auth.uid() 와 완전히 동일한 값을 반환하며,
--   성능 힌트만 추가하는 방식임.
--
-- 롤백:
--   영향받는 각 정책을 원래 auth.uid() 직접 호출 형태로 되돌린다.
--   롤백 SQL은 파일 하단 주석 블록에 포함.
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) 먼저 적용 + 기능 검증
--   2. 운영서버(twofagomeizrtkwlhsuv) 적용
--   3. 적용 후 Supabase Performance Advisor 재확인 → 88건 → 0건
--
-- 운영 적용 권장 시간:
--   한국시간 기준 새벽 2~4시 (트래픽 최저)
--   DROP + CREATE 는 각 테이블에 짧은 잠금 발생 (~10ms 이내)
--
-- 작성일: 2026-05-19 (2026-05-19 v2 재작성 — 누락 7개 추가)
-- ============================================================


-- ============================================================
-- 1. admin_email_subscriptions 테이블
-- ============================================================

-- 1-1. admin_email_sub_cud_self_or_super  (ALL)
--   qual: is_super_admin() OR admin_id IN (SELECT id FROM admins WHERE auth_id = auth.uid())
--   with_check: 동일
--   → IN 서브쿼리 안 auth.uid() 를 (SELECT auth.uid()) 로 감싸기
DROP POLICY IF EXISTS "admin_email_sub_cud_self_or_super" ON public.admin_email_subscriptions;
CREATE POLICY "admin_email_sub_cud_self_or_super"
  ON public.admin_email_subscriptions
  FOR ALL
  USING (
    public.is_super_admin()
    OR admin_id IN (
      SELECT admins.id
      FROM public.admins
      WHERE admins.auth_id = (SELECT auth.uid())
    )
  )
  WITH CHECK (
    public.is_super_admin()
    OR admin_id IN (
      SELECT admins.id
      FROM public.admins
      WHERE admins.auth_id = (SELECT auth.uid())
    )
  );


-- ============================================================
-- 2. admin_notice_reads 테이블
-- ============================================================

-- 2-1. admin_notice_reads_insert  (INSERT)
--   with_check: auth_id = auth.uid() AND is_admin()
DROP POLICY IF EXISTS "admin_notice_reads_insert" ON public.admin_notice_reads;
CREATE POLICY "admin_notice_reads_insert"
  ON public.admin_notice_reads FOR INSERT
  TO authenticated
  WITH CHECK (auth_id = (SELECT auth.uid()) AND public.is_admin());


-- ============================================================
-- 3. admin_notices 테이블
-- ============================================================

-- 3-1. admin_notices_delete  (DELETE)
--   qual: is_campaign_admin() AND (is_super_admin() OR created_by = auth.uid())
DROP POLICY IF EXISTS "admin_notices_delete" ON public.admin_notices;
CREATE POLICY "admin_notices_delete"
  ON public.admin_notices FOR DELETE
  USING (
    public.is_campaign_admin()
    AND (public.is_super_admin() OR created_by = (SELECT auth.uid()))
  );

-- 3-2. admin_notices_select  (SELECT)
--   qual: is_admin() AND (status='published' OR is_super_admin() OR created_by=auth.uid())
DROP POLICY IF EXISTS "admin_notices_select" ON public.admin_notices;
CREATE POLICY "admin_notices_select"
  ON public.admin_notices FOR SELECT
  USING (
    public.is_admin()
    AND (
      status = 'published'::text
      OR public.is_super_admin()
      OR created_by = (SELECT auth.uid())
    )
  );

-- 3-3. admin_notices_update  (UPDATE)
--   qual: is_campaign_admin() AND (is_super_admin() OR created_by = auth.uid())
--   with_check: 동일
DROP POLICY IF EXISTS "admin_notices_update" ON public.admin_notices;
CREATE POLICY "admin_notices_update"
  ON public.admin_notices FOR UPDATE
  USING (
    public.is_campaign_admin()
    AND (public.is_super_admin() OR created_by = (SELECT auth.uid()))
  )
  WITH CHECK (
    public.is_campaign_admin()
    AND (public.is_super_admin() OR created_by = (SELECT auth.uid()))
  );


-- ============================================================
-- 4. admins 테이블
-- ============================================================

-- 4-1. admins_delete  (DELETE)
--   qual: EXISTS (SELECT 1 FROM admins a WHERE a.auth_id = auth.uid() AND a.role = 'super_admin')
DROP POLICY IF EXISTS "admins_delete" ON public.admins;
CREATE POLICY "admins_delete"
  ON public.admins FOR DELETE
  USING (
    EXISTS (
      SELECT 1
      FROM public.admins admins_1
      WHERE admins_1.auth_id = (SELECT auth.uid())
        AND admins_1.role = 'super_admin'::text
    )
  );

-- 4-2. admins_insert  (INSERT)
--   with_check: EXISTS(super_admin) OR NOT EXISTS(any admin)
--   EXISTS 서브쿼리 안 auth.uid() 만 감싸기. NOT EXISTS 절에는 auth.uid() 없으므로 그대로 유지.
DROP POLICY IF EXISTS "admins_insert" ON public.admins;
CREATE POLICY "admins_insert"
  ON public.admins FOR INSERT
  WITH CHECK (
    (
      EXISTS (
        SELECT 1
        FROM public.admins admins_1
        WHERE admins_1.auth_id = (SELECT auth.uid())
          AND admins_1.role = 'super_admin'::text
      )
    )
    OR (
      NOT EXISTS (
        SELECT 1
        FROM public.admins admins_1
      )
    )
  );

-- 4-3. admins_update  (UPDATE)
--   qual: EXISTS(super_admin WHERE auth_id=auth.uid()) OR auth_id = auth.uid()
DROP POLICY IF EXISTS "admins_update" ON public.admins;
CREATE POLICY "admins_update"
  ON public.admins FOR UPDATE
  USING (
    (
      EXISTS (
        SELECT 1
        FROM public.admins admins_1
        WHERE admins_1.auth_id = (SELECT auth.uid())
          AND admins_1.role = 'super_admin'::text
      )
    )
    OR auth_id = (SELECT auth.uid())
  );


-- ============================================================
-- 5. applications 테이블
-- ============================================================

-- 5-1. applications_select_own  (SELECT)
DROP POLICY IF EXISTS "applications_select_own" ON public.applications;
CREATE POLICY "applications_select_own"
  ON public.applications FOR SELECT
  USING ((SELECT auth.uid()) = user_id);

-- 5-2. applications_insert_own  (INSERT)
DROP POLICY IF EXISTS "applications_insert_own" ON public.applications;
CREATE POLICY "applications_insert_own"
  ON public.applications FOR INSERT
  WITH CHECK ((SELECT auth.uid()) = user_id);


-- ============================================================
-- 6. brand_application_memo_reads 테이블
-- ============================================================

-- 6-1. brand_app_memo_reads_insert  (INSERT)
--   with_check: auth_id = auth.uid() AND is_admin()
DROP POLICY IF EXISTS "brand_app_memo_reads_insert" ON public.brand_application_memo_reads;
CREATE POLICY "brand_app_memo_reads_insert"
  ON public.brand_application_memo_reads FOR INSERT
  TO authenticated
  WITH CHECK (auth_id = (SELECT auth.uid()) AND public.is_admin());


-- ============================================================
-- 7. deliverable_events 테이블
-- ============================================================

-- 7-1. deliverable_events_select_own  (SELECT)
--   qual: actor_id = auth.uid() OR EXISTS(SELECT 1 FROM deliverables d WHERE d.id=... AND d.user_id=auth.uid())
--   actor_id 비교 + EXISTS 안 user_id 비교 모두 감싸기
DROP POLICY IF EXISTS "deliverable_events_select_own" ON public.deliverable_events;
CREATE POLICY "deliverable_events_select_own"
  ON public.deliverable_events FOR SELECT
  USING (
    actor_id = (SELECT auth.uid())
    OR EXISTS (
      SELECT 1
      FROM public.deliverables d
      WHERE d.id = deliverable_events.deliverable_id
        AND d.user_id = (SELECT auth.uid())
    )
  );


-- ============================================================
-- 8. deliverables 테이블
-- ============================================================

-- 8-1. deliverables_select_own  (SELECT)
DROP POLICY IF EXISTS "deliverables_select_own" ON public.deliverables;
CREATE POLICY "deliverables_select_own"
  ON public.deliverables FOR SELECT
  USING ((SELECT auth.uid()) = user_id);

-- 8-2. deliverables_insert_own  (INSERT)
--   with_check: auth.uid() = user_id AND status IN ('draft','pending')
DROP POLICY IF EXISTS "deliverables_insert_own" ON public.deliverables;
CREATE POLICY "deliverables_insert_own"
  ON public.deliverables FOR INSERT
  WITH CHECK (
    (SELECT auth.uid()) = user_id
    AND status = ANY (ARRAY['draft'::text, 'pending'::text])
  );

-- 8-3. deliverables_update_own_draft_or_pending  (UPDATE)
--   USING: auth.uid() = user_id AND status IN ('draft','pending')
--   WITH CHECK: 동일
DROP POLICY IF EXISTS "deliverables_update_own_draft_or_pending" ON public.deliverables;
CREATE POLICY "deliverables_update_own_draft_or_pending"
  ON public.deliverables FOR UPDATE
  USING (
    (SELECT auth.uid()) = user_id
    AND status = ANY (ARRAY['draft'::text, 'pending'::text])
  )
  WITH CHECK (
    (SELECT auth.uid()) = user_id
    AND status = ANY (ARRAY['draft'::text, 'pending'::text])
  );

-- 8-4. deliverables_update_own_rejected  (UPDATE)
--   USING: auth.uid() = user_id AND status = 'rejected'
--   WITH CHECK: auth.uid() = user_id AND status = 'pending'
DROP POLICY IF EXISTS "deliverables_update_own_rejected" ON public.deliverables;
CREATE POLICY "deliverables_update_own_rejected"
  ON public.deliverables FOR UPDATE
  USING ((SELECT auth.uid()) = user_id AND status = 'rejected'::text)
  WITH CHECK ((SELECT auth.uid()) = user_id AND status = 'pending'::text);

-- 8-5. deliverables_delete_own_draft  (DELETE)
--   USING: auth.uid() = user_id AND status = 'draft'
DROP POLICY IF EXISTS "deliverables_delete_own_draft" ON public.deliverables;
CREATE POLICY "deliverables_delete_own_draft"
  ON public.deliverables FOR DELETE
  USING ((SELECT auth.uid()) = user_id AND status = 'draft'::text);


-- ============================================================
-- 9. influencers 테이블
-- ============================================================

-- 9-1. influencers_select_own  (SELECT)
DROP POLICY IF EXISTS "influencers_select_own" ON public.influencers;
CREATE POLICY "influencers_select_own"
  ON public.influencers FOR SELECT
  USING ((SELECT auth.uid()) = id);

-- 9-2. influencers_insert_allow  (INSERT)
--   with_check: is_admin() OR auth.uid() = id OR auth.uid() IS NOT NULL
DROP POLICY IF EXISTS "influencers_insert_allow" ON public.influencers;
CREATE POLICY "influencers_insert_allow"
  ON public.influencers FOR INSERT
  WITH CHECK (
    public.is_admin()
    OR (SELECT auth.uid()) = id
    OR (SELECT auth.uid()) IS NOT NULL
  );

-- 9-3. influencers_update_allow  (UPDATE)
--   USING: is_admin() OR auth.uid() = id
--   WITH CHECK: 동일
DROP POLICY IF EXISTS "influencers_update_allow" ON public.influencers;
CREATE POLICY "influencers_update_allow"
  ON public.influencers FOR UPDATE
  USING (public.is_admin() OR (SELECT auth.uid()) = id)
  WITH CHECK (public.is_admin() OR (SELECT auth.uid()) = id);


-- ============================================================
-- 10. notifications 테이블
-- ============================================================

-- 10-1. notifications_select_own  (SELECT)
DROP POLICY IF EXISTS "notifications_select_own" ON public.notifications;
CREATE POLICY "notifications_select_own"
  ON public.notifications FOR SELECT
  USING ((SELECT auth.uid()) = user_id);

-- 10-2. notifications_update_own  (UPDATE)
--   USING: auth.uid() = user_id
--   WITH CHECK: auth.uid() = user_id
DROP POLICY IF EXISTS "notifications_update_own" ON public.notifications;
CREATE POLICY "notifications_update_own"
  ON public.notifications FOR UPDATE
  USING ((SELECT auth.uid()) = user_id)
  WITH CHECK ((SELECT auth.uid()) = user_id);

-- 10-3. notifications_delete_own  (DELETE)
DROP POLICY IF EXISTS "notifications_delete_own" ON public.notifications;
CREATE POLICY "notifications_delete_own"
  ON public.notifications FOR DELETE
  USING ((SELECT auth.uid()) = user_id);


-- ============================================================
-- 11. receipts 테이블
-- ============================================================

-- 11-1. receipts_select_own  (SELECT)
DROP POLICY IF EXISTS "receipts_select_own" ON public.receipts;
CREATE POLICY "receipts_select_own"
  ON public.receipts FOR SELECT
  USING ((SELECT auth.uid()) = user_id);

-- 11-2. receipts_insert_own  (INSERT)
DROP POLICY IF EXISTS "receipts_insert_own" ON public.receipts;
CREATE POLICY "receipts_insert_own"
  ON public.receipts FOR INSERT
  WITH CHECK ((SELECT auth.uid()) = user_id);

-- 11-3. receipts_update_own  (UPDATE)
--   USING: auth.uid() = user_id
--   WITH CHECK: auth.uid() = user_id
DROP POLICY IF EXISTS "receipts_update_own" ON public.receipts;
CREATE POLICY "receipts_update_own"
  ON public.receipts FOR UPDATE
  USING ((SELECT auth.uid()) = user_id)
  WITH CHECK ((SELECT auth.uid()) = user_id);


-- ============================================================
-- 검증 SQL (적용 후 Supabase SQL Editor 에서 실행)
-- ============================================================
-- 아래 SQL 로 안티패턴(직접 호출) 이 남아있는 정책 조회:
-- 결과가 0건이어야 함.
--
-- SELECT tablename, policyname, cmd, qual, with_check
-- FROM pg_policies
-- WHERE schemaname = 'public'
--   AND (
--     qual    ~ 'auth\.uid\(\)'
--     OR with_check ~ 'auth\.uid\(\)'
--   )
--   AND NOT (
--     -- (SELECT auth.uid()) 패턴은 안티패턴 아님
--     (qual ~ '\(SELECT auth\.uid\(\)' OR qual IS NULL)
--     AND (with_check ~ '\(SELECT auth\.uid\(\)' OR with_check IS NULL)
--   )
-- ORDER BY tablename, policyname;
--
-- 운영 DB 26개 정책 전수 확인:
-- SELECT tablename, policyname, cmd
-- FROM pg_policies
-- WHERE schemaname = 'public'
-- ORDER BY tablename, policyname;
-- → 26행 반환이어야 함
-- ============================================================


-- ============================================================
-- 롤백 SQL (문제 발생 시 아래 실행)
-- ============================================================
/*

-- 롤백: admin_email_subscriptions
DROP POLICY IF EXISTS "admin_email_sub_cud_self_or_super" ON public.admin_email_subscriptions;
CREATE POLICY "admin_email_sub_cud_self_or_super"
  ON public.admin_email_subscriptions FOR ALL
  USING (
    public.is_super_admin()
    OR admin_id IN (SELECT admins.id FROM public.admins WHERE admins.auth_id = auth.uid())
  )
  WITH CHECK (
    public.is_super_admin()
    OR admin_id IN (SELECT admins.id FROM public.admins WHERE admins.auth_id = auth.uid())
  );

-- 롤백: admin_notice_reads
DROP POLICY IF EXISTS "admin_notice_reads_insert" ON public.admin_notice_reads;
CREATE POLICY "admin_notice_reads_insert"
  ON public.admin_notice_reads FOR INSERT TO authenticated
  WITH CHECK (auth_id = auth.uid() AND public.is_admin());

-- 롤백: admin_notices
DROP POLICY IF EXISTS "admin_notices_delete" ON public.admin_notices;
DROP POLICY IF EXISTS "admin_notices_select" ON public.admin_notices;
DROP POLICY IF EXISTS "admin_notices_update" ON public.admin_notices;
CREATE POLICY "admin_notices_delete" ON public.admin_notices FOR DELETE
  USING (public.is_campaign_admin() AND (public.is_super_admin() OR created_by = auth.uid()));
CREATE POLICY "admin_notices_select" ON public.admin_notices FOR SELECT
  USING (public.is_admin() AND (status = 'published'::text OR public.is_super_admin() OR created_by = auth.uid()));
CREATE POLICY "admin_notices_update" ON public.admin_notices FOR UPDATE
  USING (public.is_campaign_admin() AND (public.is_super_admin() OR created_by = auth.uid()))
  WITH CHECK (public.is_campaign_admin() AND (public.is_super_admin() OR created_by = auth.uid()));

-- 롤백: admins
DROP POLICY IF EXISTS "admins_delete" ON public.admins;
DROP POLICY IF EXISTS "admins_insert" ON public.admins;
DROP POLICY IF EXISTS "admins_update" ON public.admins;
CREATE POLICY "admins_delete" ON public.admins FOR DELETE
  USING (EXISTS (SELECT 1 FROM public.admins admins_1 WHERE admins_1.auth_id = auth.uid() AND admins_1.role = 'super_admin'::text));
CREATE POLICY "admins_insert" ON public.admins FOR INSERT
  WITH CHECK (
    (EXISTS (SELECT 1 FROM public.admins admins_1 WHERE admins_1.auth_id = auth.uid() AND admins_1.role = 'super_admin'::text))
    OR (NOT EXISTS (SELECT 1 FROM public.admins admins_1))
  );
CREATE POLICY "admins_update" ON public.admins FOR UPDATE
  USING (
    (EXISTS (SELECT 1 FROM public.admins admins_1 WHERE admins_1.auth_id = auth.uid() AND admins_1.role = 'super_admin'::text))
    OR auth_id = auth.uid()
  );

-- 롤백: applications
DROP POLICY IF EXISTS "applications_select_own" ON public.applications;
DROP POLICY IF EXISTS "applications_insert_own" ON public.applications;
CREATE POLICY "applications_select_own" ON public.applications FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "applications_insert_own" ON public.applications FOR INSERT WITH CHECK (auth.uid() = user_id);

-- 롤백: brand_application_memo_reads
DROP POLICY IF EXISTS "brand_app_memo_reads_insert" ON public.brand_application_memo_reads;
CREATE POLICY "brand_app_memo_reads_insert"
  ON public.brand_application_memo_reads FOR INSERT TO authenticated
  WITH CHECK (auth_id = auth.uid() AND public.is_admin());

-- 롤백: deliverable_events
DROP POLICY IF EXISTS "deliverable_events_select_own" ON public.deliverable_events;
CREATE POLICY "deliverable_events_select_own" ON public.deliverable_events FOR SELECT
  USING (actor_id = auth.uid() OR EXISTS (SELECT 1 FROM public.deliverables d WHERE d.id = deliverable_events.deliverable_id AND d.user_id = auth.uid()));

-- 롤백: deliverables
DROP POLICY IF EXISTS "deliverables_select_own"               ON public.deliverables;
DROP POLICY IF EXISTS "deliverables_insert_own"               ON public.deliverables;
DROP POLICY IF EXISTS "deliverables_update_own_draft_or_pending" ON public.deliverables;
DROP POLICY IF EXISTS "deliverables_update_own_rejected"      ON public.deliverables;
DROP POLICY IF EXISTS "deliverables_delete_own_draft"         ON public.deliverables;
CREATE POLICY "deliverables_select_own" ON public.deliverables FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "deliverables_insert_own" ON public.deliverables FOR INSERT WITH CHECK (auth.uid() = user_id AND status = ANY (ARRAY['draft'::text, 'pending'::text]));
CREATE POLICY "deliverables_update_own_draft_or_pending" ON public.deliverables FOR UPDATE
  USING (auth.uid() = user_id AND status = ANY (ARRAY['draft'::text, 'pending'::text]))
  WITH CHECK (auth.uid() = user_id AND status = ANY (ARRAY['draft'::text, 'pending'::text]));
CREATE POLICY "deliverables_update_own_rejected" ON public.deliverables FOR UPDATE
  USING (auth.uid() = user_id AND status = 'rejected'::text)
  WITH CHECK (auth.uid() = user_id AND status = 'pending'::text);
CREATE POLICY "deliverables_delete_own_draft" ON public.deliverables FOR DELETE USING (auth.uid() = user_id AND status = 'draft'::text);

-- 롤백: influencers
DROP POLICY IF EXISTS "influencers_select_own"   ON public.influencers;
DROP POLICY IF EXISTS "influencers_insert_allow" ON public.influencers;
DROP POLICY IF EXISTS "influencers_update_allow" ON public.influencers;
CREATE POLICY "influencers_select_own"  ON public.influencers FOR SELECT USING (auth.uid() = id);
CREATE POLICY "influencers_insert_allow" ON public.influencers FOR INSERT WITH CHECK (public.is_admin() OR auth.uid() = id OR auth.uid() IS NOT NULL);
CREATE POLICY "influencers_update_allow" ON public.influencers FOR UPDATE USING (public.is_admin() OR auth.uid() = id) WITH CHECK (public.is_admin() OR auth.uid() = id);

-- 롤백: notifications
DROP POLICY IF EXISTS "notifications_select_own" ON public.notifications;
DROP POLICY IF EXISTS "notifications_update_own" ON public.notifications;
DROP POLICY IF EXISTS "notifications_delete_own" ON public.notifications;
CREATE POLICY "notifications_select_own" ON public.notifications FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "notifications_update_own" ON public.notifications FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "notifications_delete_own" ON public.notifications FOR DELETE USING (auth.uid() = user_id);

-- 롤백: receipts
DROP POLICY IF EXISTS "receipts_select_own" ON public.receipts;
DROP POLICY IF EXISTS "receipts_insert_own" ON public.receipts;
DROP POLICY IF EXISTS "receipts_update_own" ON public.receipts;
CREATE POLICY "receipts_select_own" ON public.receipts FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "receipts_insert_own" ON public.receipts FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "receipts_update_own" ON public.receipts FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

*/
