-- ============================================================
-- 593_admin_notices_audience.sql
-- 관리자 공지사항에 「보일 곳」(관리자 / 브랜드 페이지) 칸 추가
--
-- 왜: 브랜드 페이지 공지는 따로 표를 만들지 않고 기존 관리자 「공지사항」에서 쓴다
--     (사양서 docs/specs/2026-07-15-brand-portal.md §16-8 표 3번 · 피그마 a11 공지사항).
--
-- 칸 넷:
--   audience        — 'admin'(기본, 기존 행 전부) | 'brand'
--   brand_kind      — 브랜드 공지 종류: terms(약관) · maintenance(점검) · outage(장애) · info(안내)
--   help_show_from  — 브랜드 「도움말」 메뉴 최근 공지 줄에 보이기 시작하는 시각
--   help_show_until — 보이기를 끝내는 시각 (from 보다 뒤)
--
-- 묶음 제약 admin_notices_audience_shape:
--   admin → category 있음 · brand_kind·기간 없음 (고정 공지 그대로 가능)
--   brand → category 없음 · brand_kind·기간 둘 다 있음 · until > from · 고정 안 함
--   그래서 category 의 NOT NULL 을 푼다(063 의 값 목록 검사는 그대로 — NULL 은 통과).
--
-- 범위 밖: 브랜드 계정이 공지를 읽는 길(조회 정책·함수) — 다음 작업. 지금 조회 정책 admin_notices_select
--   (관리자만 — 게시본 또는 작성자·최고관리자)·읽음 표 admin_notice_reads 는 그대로.
--   ⚠️ 다음 작업 메모: 브랜드 계정의 읽음 기록은 admin_notice_reads 에 섞지 않고 따로 둔다
--   (그 표의 조회·쓰기 정책이 is_admin() 전제다).
-- 함께 정리: 부르는 곳이 없던 storage.js fetchUnreadAdminNotices 를 지웠다(브랜드 공지가 섞일 수 있어서).
--
-- 운영: 브랜드 페이지 1차 출시 묶음과 함께(보류). 칸이 없어도 관리자 공지 저장은 새 칸을 안 보내므로 화면은 산다.
--
-- ROLLBACK (브랜드 공지 행을 먼저 지워야 category NOT NULL 복구가 된다):
--   DELETE FROM public.admin_notices WHERE audience = 'brand';
--   ALTER TABLE public.admin_notices DROP CONSTRAINT IF EXISTS admin_notices_audience_shape;
--   ALTER TABLE public.admin_notices ALTER COLUMN category SET NOT NULL;
--   ALTER TABLE public.admin_notices
--     DROP COLUMN IF EXISTS help_show_until, DROP COLUMN IF EXISTS help_show_from,
--     DROP COLUMN IF EXISTS brand_kind,      DROP COLUMN IF EXISTS audience;
-- ============================================================
BEGIN;

ALTER TABLE public.admin_notices
  ADD COLUMN IF NOT EXISTS audience text NOT NULL DEFAULT 'admin'
    CONSTRAINT admin_notices_audience_check CHECK (audience IN ('admin','brand')),
  ADD COLUMN IF NOT EXISTS brand_kind text NULL
    CONSTRAINT admin_notices_brand_kind_check CHECK (brand_kind IN ('terms','maintenance','outage','info')),
  ADD COLUMN IF NOT EXISTS help_show_from  timestamptz NULL,
  ADD COLUMN IF NOT EXISTS help_show_until timestamptz NULL;

ALTER TABLE public.admin_notices ALTER COLUMN category DROP NOT NULL;

ALTER TABLE public.admin_notices DROP CONSTRAINT IF EXISTS admin_notices_audience_shape;
ALTER TABLE public.admin_notices
  ADD CONSTRAINT admin_notices_audience_shape CHECK (
    (audience = 'admin'
       AND category IS NOT NULL
       AND brand_kind IS NULL
       AND help_show_from IS NULL
       AND help_show_until IS NULL)
    OR
    (audience = 'brand'
       AND category IS NULL
       AND brand_kind IS NOT NULL
       AND help_show_from IS NOT NULL
       AND help_show_until IS NOT NULL
       AND help_show_until > help_show_from
       AND is_pinned = false)
  );

COMMENT ON COLUMN public.admin_notices.audience IS
  '[593] 보일 곳 — admin(관리자 공지, 기본) | brand(브랜드 페이지 공지 — 모든 브랜드의 모든 계정). 묶음 제약 admin_notices_audience_shape';
COMMENT ON COLUMN public.admin_notices.brand_kind IS
  '[593] 브랜드 공지 종류 — terms 약관 · maintenance 점검 · outage 장애 · info 안내. audience=brand 일 때만';
COMMENT ON COLUMN public.admin_notices.help_show_from IS
  '[593] 브랜드 「도움말」 최근 공지 줄에 보이기 시작하는 시각. audience=brand 일 때만(필수)';
COMMENT ON COLUMN public.admin_notices.help_show_until IS
  '[593] 브랜드 「도움말」 최근 공지 줄에 보이기를 끝내는 시각(from 보다 뒤). audience=brand 일 때만(필수)';

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '593', '593_admin_notices_audience.sql');
COMMIT;
