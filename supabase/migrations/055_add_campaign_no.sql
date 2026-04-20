-- ============================================================
-- migration: 055_add_campaign_no
-- purpose  : campaigns 테이블에 사람이 기억하기 쉬운 번호 체계 추가
--            - 형식: CAMP-YYYY-NNNN (예: CAMP-2026-0001)
--            - 연도: JST 기준 (운영 Sydney / 개발 Tokyo)
--            - 연도별 4자리 순차 (연도 바뀌면 0001로 리셋)
--            - 트리거로 자동 채번. 기존 캠페인도 created_at 순 backfill.
--
-- 적용:
--   1. 개발 DB (qysmxtipobomefudyixw)
--   2. 운영 DB (twofagomeizrtkwlhsuv)
-- ============================================================


-- 1) 연도별 채번 카운터 (SECURITY DEFINER 트리거 전용)
CREATE TABLE IF NOT EXISTS campaigns_yearly_counter (
  year integer PRIMARY KEY,
  seq  integer NOT NULL DEFAULT 0
);
COMMENT ON TABLE campaigns_yearly_counter IS
  '[055] campaigns.campaign_no 채번 카운터 (JST 연도별). 직접 UPDATE 금지 — SECURITY DEFINER 트리거 전용.';

ALTER TABLE campaigns_yearly_counter ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "campaigns_yearly_counter_select_admin" ON campaigns_yearly_counter;
CREATE POLICY "campaigns_yearly_counter_select_admin"
  ON campaigns_yearly_counter FOR SELECT
  USING (public.is_admin());


-- 2) campaigns 컬럼 추가
ALTER TABLE campaigns
  ADD COLUMN IF NOT EXISTS campaign_no text;

COMMENT ON COLUMN campaigns.campaign_no IS
  '[055] 사람이 기억하기 쉬운 캠페인 번호. CAMP-YYYY-NNNN 형식. 트리거 자동 생성.';


-- 3) 트리거 함수: 신규 INSERT 시 자동 채번
CREATE OR REPLACE FUNCTION public.generate_campaign_no()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_year integer;
  v_seq  integer;
BEGIN
  -- 이미 채번된 값 있으면 덮어쓰지 않음 (backfill 안전장치)
  IF NEW.campaign_no IS NOT NULL AND NEW.campaign_no <> '' THEN
    RETURN NEW;
  END IF;

  -- JST 기준 연도
  v_year := EXTRACT(YEAR FROM (now() AT TIME ZONE 'Asia/Tokyo'))::integer;

  -- 연도별 카운터 atomic 증가
  INSERT INTO public.campaigns_yearly_counter (year, seq)
  VALUES (v_year, 1)
  ON CONFLICT (year)
  DO UPDATE SET seq = public.campaigns_yearly_counter.seq + 1
  RETURNING seq INTO v_seq;

  -- CAMP-2026-0001
  NEW.campaign_no := 'CAMP-' || v_year::text || '-' || lpad(v_seq::text, 4, '0');
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.generate_campaign_no IS
  '[055] campaigns BEFORE INSERT 트리거. JST 연도별 카운터 atomic 증가로 campaign_no 생성.';

DROP TRIGGER IF EXISTS trg_campaign_no ON campaigns;
CREATE TRIGGER trg_campaign_no
  BEFORE INSERT ON campaigns
  FOR EACH ROW EXECUTE FUNCTION public.generate_campaign_no();


-- 4) 기존 레코드 backfill — created_at 오름차순으로 연도별 순번 부여
DO $$
BEGIN
  -- 이미 채번된 캠페인은 스킵, NULL인 것만 채움
  IF EXISTS (SELECT 1 FROM campaigns WHERE campaign_no IS NULL) THEN
    WITH ranked AS (
      SELECT
        id,
        EXTRACT(YEAR FROM (created_at AT TIME ZONE 'Asia/Tokyo'))::integer AS year,
        ROW_NUMBER() OVER (
          PARTITION BY EXTRACT(YEAR FROM (created_at AT TIME ZONE 'Asia/Tokyo'))
          ORDER BY created_at, id
        ) AS seq
      FROM campaigns
      WHERE campaign_no IS NULL
    )
    UPDATE campaigns c
       SET campaign_no = 'CAMP-' || r.year::text || '-' || lpad(r.seq::text, 4, '0')
      FROM ranked r
     WHERE c.id = r.id;
  END IF;

  -- 카운터 테이블을 연도별 최대 seq로 초기화 (이후 INSERT가 안전하게 이어받음)
  INSERT INTO campaigns_yearly_counter (year, seq)
    SELECT
      EXTRACT(YEAR FROM (created_at AT TIME ZONE 'Asia/Tokyo'))::integer AS year,
      COUNT(*) AS seq
    FROM campaigns
    WHERE campaign_no IS NOT NULL
    GROUP BY 1
  ON CONFLICT (year) DO UPDATE
    SET seq = GREATEST(campaigns_yearly_counter.seq, EXCLUDED.seq);
END $$;


-- 5) UNIQUE + NOT NULL 제약 부여 (backfill 이후)
ALTER TABLE campaigns
  ALTER COLUMN campaign_no SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_campaigns_campaign_no
  ON campaigns (campaign_no);


-- ============================================================
-- 검증 쿼리 (적용 후 SQL Editor에서 실행)
-- ============================================================
-- -- 모든 캠페인이 채번됐는지
-- SELECT COUNT(*) FILTER (WHERE campaign_no IS NULL) AS unnumbered,
--        COUNT(*) AS total FROM campaigns;
--
-- -- 연도별 최댓값 + 카운터 일치 확인
-- SELECT EXTRACT(YEAR FROM (created_at AT TIME ZONE 'Asia/Tokyo'))::int AS y,
--        COUNT(*) AS campaign_count,
--        MAX(campaign_no) AS last_no
-- FROM campaigns GROUP BY 1 ORDER BY 1;
-- SELECT * FROM campaigns_yearly_counter ORDER BY year;
--
-- -- 신규 INSERT 테스트
-- INSERT INTO campaigns (title, brand, recruit_type, status)
-- VALUES ('[TEST] campaign_no', 'TEST', 'gifting', 'draft')
-- RETURNING campaign_no;
-- ROLLBACK;  -- 테스트 후 되돌리기


-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP INDEX IF EXISTS idx_campaigns_campaign_no;
-- ALTER TABLE campaigns DROP COLUMN IF EXISTS campaign_no;
-- DROP TRIGGER IF EXISTS trg_campaign_no ON campaigns;
-- DROP FUNCTION IF EXISTS public.generate_campaign_no();
-- DROP TABLE IF EXISTS campaigns_yearly_counter;
