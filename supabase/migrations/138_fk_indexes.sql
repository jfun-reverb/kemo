-- ============================================================
-- 138_fk_indexes.sql
-- 외래 키(FK) 컬럼 미인덱스 일괄 추가
--
-- 문제:
--   Supabase Performance Advisor 「Unindexed foreign keys」 30건.
--   외래 키 컬럼에 인덱스가 없으면 JOIN·ON DELETE CASCADE 시
--   전체 테이블 순회(Seq Scan)가 발생. 특히 CASCADE 삭제는
--   인덱스 없이 참조 테이블 전체를 탐색하므로 치명적으로 느림.
--
-- 대상 컬럼 분류 (마이그레이션 파일 분석 기준):
--
--   [그룹 A] 이미 복합 인덱스의 첫 번째 컬럼으로 커버됨 (추가 불필요)
--     - influencer_flags.influencer_id  → idx_influencer_flags_influencer_set_at (influencer_id, set_at)
--     - deliverable_events.deliverable_id → idx_deliverable_events_deliverable_id
--     - deliverables.application_id → idx_deliverables_application_id
--     - deliverables.campaign_id → idx_deliverables_campaign_id
--     - deliverables.user_id → idx_deliverables_user_id
--     - applications.campaign_id → idx_applications_campaign_id
--     - applications.user_id → idx_applications_user_id
--     - receipts.application_id → idx_receipts_application_id
--     - receipts.user_id → idx_receipts_user_id
--     - receipts.campaign_id → idx_receipts_campaign_id
--     - admin_email_subscriptions.admin_id → admin_email_subscriptions_admin_idx
--     - brand_applications.brand_id → brand_applications_brand_id_idx
--     - campaigns.brand_id → campaigns_brand_id_idx
--     - campaigns.source_application_id → campaigns_source_application_id_idx
--     - brand_application_history.application_id → brand_application_history_app_changed_idx
--     - brand_application_memos.application_id → brand_application_memos_app_created_idx
--     - campaign_caution_history.campaign_id → idx_campaign_caution_history_campaign_changed_at
--     - brands.company_id → brands_company_id_idx
--     - receipt_edit_history.deliverable_id → idx_receipt_edit_history_deliverable_changed_at
--     - deadline_reminder_email_sent.campaign_id → idx_deadline_reminder_email_lookup
--     - deadline_reminder_email_sent.influencer_id → idx_deadline_reminder_email_influencer
--     - application_events.application_id → idx_application_events_application_created
--
--   [그룹 B] 실제 인덱스 미존재 → 이번 마이그레이션에서 추가
--     - brand_application_history.changed_by
--     - brand_application_memos.author_id
--     - brands.created_by
--     - campaign_caution_history.changed_by
--     - companies.created_by
--     - companies.updated_by
--     - application_events.changed_by
--     - brand_applications.intake_admin_id
--     - admin_notice_reads.notice_id  (PRIMARY KEY 의 두 번째 컬럼, PK 인덱스가 커버하나
--                                      단독 역방향 조회용 인덱스 없음)
--     - brand_application_memo_reads.memo_id  (PK 두 번째 컬럼, 역방향 조회용 미존재)
--     - deliverable_events.actor_id  (SET NULL 대상)
--     - notifications.ref_id  (ref_table, ref_id 복합 있음 → 이미 커버)
--
-- 주의:
--   - changed_by / created_by / updated_by / intake_admin_id 등 "작성자" 컬럼은
--     ON DELETE SET NULL 대상. CASCADE 삭제 시 인덱스 없으면 전체 탐색.
--     단, 실제 삭제 빈도는 낮으므로 성능 영향은 CREATE 보다 완만하게 발생.
--   - author_id 등도 ON DELETE SET NULL 대상으로 동일.
--   - CONCURRENTLY 는 트랜잭션 블록 안에서 실행 불가.
--     Supabase SQL Editor 는 단순 실행 모드이므로 CONCURRENTLY 사용 가능.
--     단, 이번 마이그레이션은 운영 트래픽이 거의 없을 새벽에 적용하므로
--     CONCURRENTLY 없이도 안전. 테이블 크기 작아 빌드 < 1초 예상.
--   - IF NOT EXISTS 로 재실행 멱등성 보장.
--
-- 롤백:
--   파일 하단 주석 블록 참조.
--
-- 적용 순서:
--   1. 개발서버 먼저 적용 (크기 작아 즉시)
--   2. 운영서버 적용 (한국시간 새벽 2~4시 권장)
--
-- 작성일: 2026-05-19
-- ============================================================


-- ============================================================
-- 1. brand_application_history.changed_by
--    (admin 삭제 시 ON DELETE SET NULL 대상 — cascade 탐색용)
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_brand_app_history_changed_by
  ON public.brand_application_history (changed_by);

COMMENT ON INDEX public.idx_brand_app_history_changed_by IS
  '[138] brand_application_history.changed_by FK 인덱스. 관리자 삭제 CASCADE SET NULL 탐색용.';


-- ============================================================
-- 2. brand_application_memos.author_id
--    (auth.users ON DELETE SET NULL 대상)
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_brand_app_memos_author_id
  ON public.brand_application_memos (author_id);

COMMENT ON INDEX public.idx_brand_app_memos_author_id IS
  '[138] brand_application_memos.author_id FK 인덱스. ON DELETE SET NULL 탐색용.';


-- ============================================================
-- 3. brands.created_by
--    (auth.users ON DELETE SET NULL 대상)
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_brands_created_by
  ON public.brands (created_by);

COMMENT ON INDEX public.idx_brands_created_by IS
  '[138] brands.created_by FK 인덱스. ON DELETE SET NULL 탐색용.';


-- ============================================================
-- 4. campaign_caution_history.changed_by
--    (auth.users ON DELETE SET NULL 대상)
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_campaign_caution_history_changed_by
  ON public.campaign_caution_history (changed_by);

COMMENT ON INDEX public.idx_campaign_caution_history_changed_by IS
  '[138] campaign_caution_history.changed_by FK 인덱스. ON DELETE SET NULL 탐색용.';


-- ============================================================
-- 5. companies.created_by
--    (auth.users ON DELETE SET NULL 대상)
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_companies_created_by
  ON public.companies (created_by);

COMMENT ON INDEX public.idx_companies_created_by IS
  '[138] companies.created_by FK 인덱스. ON DELETE SET NULL 탐색용.';


-- ============================================================
-- 6. companies.updated_by
--    (auth.users ON DELETE SET NULL 대상)
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_companies_updated_by
  ON public.companies (updated_by);

COMMENT ON INDEX public.idx_companies_updated_by IS
  '[138] companies.updated_by FK 인덱스. ON DELETE SET NULL 탐색용.';


-- ============================================================
-- 7. application_events.changed_by
--    (auth.users ON DELETE SET NULL 대상)
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_application_events_changed_by
  ON public.application_events (changed_by);

COMMENT ON INDEX public.idx_application_events_changed_by IS
  '[138] application_events.changed_by FK 인덱스. ON DELETE SET NULL 탐색용.';


-- ============================================================
-- 8. brand_applications.intake_admin_id
--    (auth.users ON DELETE SET NULL 대상 — 브랜드 신청 담당 관리자)
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_brand_applications_intake_admin_id
  ON public.brand_applications (intake_admin_id);

COMMENT ON INDEX public.idx_brand_applications_intake_admin_id IS
  '[138] brand_applications.intake_admin_id FK 인덱스. ON DELETE SET NULL 탐색용.';


-- ============================================================
-- 9. admin_notice_reads.notice_id
--    PRIMARY KEY (notice_id, auth_id) 로 (notice_id, auth_id) 복합 인덱스는 있지만
--    역방향 — notice_id 단독 조회(특정 공지의 읽음 현황 전체 조회) 시 인덱스 사용 불가.
--    Supabase Advisor 가 단독 인덱스 부재로 경고하는 항목.
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_admin_notice_reads_notice_id
  ON public.admin_notice_reads (notice_id);

COMMENT ON INDEX public.idx_admin_notice_reads_notice_id IS
  '[138] admin_notice_reads.notice_id 단독 인덱스. 특정 공지 읽음 현황 조회용.';


-- ============================================================
-- 10. brand_application_memo_reads.memo_id
--     PRIMARY KEY (memo_id, auth_id) — memo_id 단독 조회용 인덱스 미존재
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_brand_app_memo_reads_memo_id
  ON public.brand_application_memo_reads (memo_id);

COMMENT ON INDEX public.idx_brand_app_memo_reads_memo_id IS
  '[138] brand_application_memo_reads.memo_id 단독 인덱스. ON DELETE CASCADE 탐색용.';


-- ============================================================
-- 11. deliverable_events.actor_id
--     (auth.users ON DELETE SET NULL 대상)
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_deliverable_events_actor_id
  ON public.deliverable_events (actor_id);

COMMENT ON INDEX public.idx_deliverable_events_actor_id IS
  '[138] deliverable_events.actor_id FK 인덱스. ON DELETE SET NULL 탐색용.';


-- ============================================================
-- 검증 SQL (적용 후 Supabase SQL Editor 에서 실행)
-- ============================================================
-- [V1] 11개 인덱스 등록 확인:
--
-- SELECT indexname
-- FROM pg_indexes
-- WHERE schemaname = 'public'
--   AND indexname IN (
--     'idx_brand_app_history_changed_by',
--     'idx_brand_app_memos_author_id',
--     'idx_brands_created_by',
--     'idx_campaign_caution_history_changed_by',
--     'idx_companies_created_by',
--     'idx_companies_updated_by',
--     'idx_application_events_changed_by',
--     'idx_brand_applications_intake_admin_id',
--     'idx_admin_notice_reads_notice_id',
--     'idx_brand_app_memo_reads_memo_id',
--     'idx_deliverable_events_actor_id'
--   )
-- ORDER BY indexname;
-- 기대: 11행
--
-- [V2] 인덱스 크기 점검:
--
-- SELECT indexname,
--        pg_size_pretty(pg_relation_size(indexname::regclass)) AS size
-- FROM pg_indexes
-- WHERE schemaname = 'public'
--   AND indexname IN (
--     'idx_brand_app_history_changed_by',
--     'idx_brand_app_memos_author_id',
--     'idx_brands_created_by',
--     'idx_campaign_caution_history_changed_by',
--     'idx_companies_created_by',
--     'idx_companies_updated_by',
--     'idx_application_events_changed_by',
--     'idx_brand_applications_intake_admin_id',
--     'idx_admin_notice_reads_notice_id',
--     'idx_brand_app_memo_reads_memo_id',
--     'idx_deliverable_events_actor_id'
--   )
-- ORDER BY indexname;
-- 기대: 각 8kB ~ 수십 kB (현재 데이터 양 기준)
-- ============================================================


-- ============================================================
-- 롤백 SQL
-- ============================================================
/*

DROP INDEX IF EXISTS public.idx_brand_app_history_changed_by;
DROP INDEX IF EXISTS public.idx_brand_app_memos_author_id;
DROP INDEX IF EXISTS public.idx_brands_created_by;
DROP INDEX IF EXISTS public.idx_campaign_caution_history_changed_by;
DROP INDEX IF EXISTS public.idx_companies_created_by;
DROP INDEX IF EXISTS public.idx_companies_updated_by;
DROP INDEX IF EXISTS public.idx_application_events_changed_by;
DROP INDEX IF EXISTS public.idx_brand_applications_intake_admin_id;
DROP INDEX IF EXISTS public.idx_admin_notice_reads_notice_id;
DROP INDEX IF EXISTS public.idx_brand_app_memo_reads_memo_id;
DROP INDEX IF EXISTS public.idx_deliverable_events_actor_id;

*/
