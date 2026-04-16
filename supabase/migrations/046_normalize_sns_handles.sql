-- ============================================================
-- 046_normalize_sns_handles.sql
-- influencers 테이블의 SNS 컬럼(ig/x/tiktok/youtube)에 들어간
-- URL·공백·중복 @를 핸들만으로 정제.
--
-- 정책:
--   - 핸들만 저장 (@ 없이). 표시할 때 UI에서 @ prefix 부여
--   - URL이면 path 첫 segment 추출 (쿼리 파라미터 제거)
--   - 매칭 실패 시 원본 trim 후 leading @ 만 제거 (데이터 손실 방지)
--   - 빈 문자열은 NULL 변환
--
-- 백업: influencers_sns_backup_046 테이블에 정제 전 스냅샷 저장
--       (롤백 7일 후 수동 DROP 권장)
--
-- rollback:
--   UPDATE influencers
--      SET ig = b.ig, x = b.x, tiktok = b.tiktok, youtube = b.youtube
--     FROM influencers_sns_backup_046 b
--    WHERE influencers.id = b.id;
--   -- 검증 후 정리:
--   -- DROP TABLE influencers_sns_backup_046;
-- ============================================================

BEGIN;

-- 1. 백업 테이블 (idempotent)
CREATE TABLE IF NOT EXISTS influencers_sns_backup_046 (
  id           uuid PRIMARY KEY,
  ig           text,
  x            text,
  tiktok       text,
  youtube      text,
  backed_up_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO influencers_sns_backup_046 (id, ig, x, tiktok, youtube)
  SELECT id, ig, x, tiktok, youtube FROM influencers
  ON CONFLICT (id) DO NOTHING;

-- 2. SNS 컬럼 정제
--    각 컬럼: URL이면 첫 path segment 추출 → leading @ 제거 → 양끝 공백 trim
UPDATE influencers SET
  ig = NULLIF(BTRIM(regexp_replace(
         regexp_replace(COALESCE(ig,''), '^.*instagram\.com/([^/?#\s]+).*$', '\1'),
         '^@+', '')), ''),
  x = NULLIF(BTRIM(regexp_replace(
         regexp_replace(COALESCE(x,''), '^.*(?:x|twitter)\.com/([^/?#\s]+).*$', '\1'),
         '^@+', '')), ''),
  tiktok = NULLIF(BTRIM(regexp_replace(
         regexp_replace(COALESCE(tiktok,''), '^.*tiktok\.com/@?([^/?#\s]+).*$', '\1'),
         '^@+', '')), ''),
  youtube = NULLIF(BTRIM(regexp_replace(
         regexp_replace(COALESCE(youtube,''), '^.*youtube\.com/(?:@|c/|channel/|user/)?([^/?#\s]+).*$', '\1'),
         '^@+', '')), '');

-- 3. 백업 테이블 RLS (관리자 전용)
ALTER TABLE influencers_sns_backup_046 ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admins only" ON influencers_sns_backup_046;
CREATE POLICY "admins only" ON influencers_sns_backup_046
  FOR ALL TO authenticated
  USING (is_admin())
  WITH CHECK (is_admin());

COMMIT;

-- 4. 검증 쿼리 (수동 실행)
--    잔존 URL 형태 확인:
--    SELECT id, email, ig, x, tiktok, youtube FROM influencers
--     WHERE ig LIKE '%/%' OR x LIKE '%/%' OR tiktok LIKE '%/%' OR youtube LIKE '%/%'
--        OR ig LIKE '%@%' OR x LIKE '%@%' OR tiktok LIKE '%@%' OR youtube LIKE '%@%';
--
--    백업 vs 현재 비교:
--    SELECT i.id, i.email,
--           b.ig AS old_ig, i.ig AS new_ig,
--           b.x AS old_x, i.x AS new_x,
--           b.tiktok AS old_tt, i.tiktok AS new_tt,
--           b.youtube AS old_yt, i.youtube AS new_yt
--      FROM influencers i
--      JOIN influencers_sns_backup_046 b ON b.id = i.id
--     WHERE COALESCE(b.ig,'')      <> COALESCE(i.ig,'')
--        OR COALESCE(b.x,'')       <> COALESCE(i.x,'')
--        OR COALESCE(b.tiktok,'')  <> COALESCE(i.tiktok,'')
--        OR COALESCE(b.youtube,'') <> COALESCE(i.youtube,'')
--     ORDER BY i.created_at DESC;
