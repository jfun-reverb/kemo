-- ============================================================
-- 047_normalize_sns_residual.sql
-- 046 정제 후에도 남은 잔존 잣쓰레기 데이터 추가 정제.
--
-- 처리 대상:
--   1. 컬럼 도메인과 다른 URL이 박혀있는 경우 → NULL
--      예: tiktok 컬럼에 mail.google.com URL → NULL
--   2. 전각 공백/ASCII 공백만 있는 경우 → NULL
--      예: tiktok = '　' (전각 공백 1자)
--   3. 일본어 "없음" 표현 → NULL
--      대상: 'なし', 'ない', '無し', '無い', '無いです', 'なしです'
--      (사용자가 의도적으로 입력한 "SNS 없음")
--
-- 처리 제외 (수동 판단 필요):
--   - 'Akari hb makeup' 처럼 일반 텍스트(채널명 가능성) → 그대로 유지
--   - 관리자가 인플루언서 상세에서 직접 정리
--
-- 백업: 046에서 만든 influencers_sns_backup_046 사용
--       (047 변경분 복구도 동일 백업으로 가능)
--
-- rollback: 046과 동일
--   UPDATE influencers
--      SET ig = b.ig, x = b.x, tiktok = b.tiktok, youtube = b.youtube
--     FROM influencers_sns_backup_046 b
--    WHERE influencers.id = b.id;
-- ============================================================

BEGIN;

-- 헬퍼 패턴
--   - URL 판별: '^https?://' (대소문자 무관)
--   - 빈/공백 판별: '^[\s\u3000]*$' (ASCII + 전각 공백)
--   - 일본어 "없음" 표현: 양끝 공백 trim 후 정확 매칭

-- 1. ig: instagram.com 외 URL은 NULL
UPDATE influencers SET ig = NULL
 WHERE ig ~* '^https?://'
   AND ig !~* '^https?://([a-z0-9-]+\.)?instagram\.com/';

-- 2. x: x.com/twitter.com 외 URL은 NULL
UPDATE influencers SET x = NULL
 WHERE x ~* '^https?://'
   AND x !~* '^https?://([a-z0-9-]+\.)?(x|twitter)\.com/';

-- 3. tiktok: tiktok.com 외 URL은 NULL
UPDATE influencers SET tiktok = NULL
 WHERE tiktok ~* '^https?://'
   AND tiktok !~* '^https?://([a-z0-9-]+\.)?tiktok\.com/';

-- 4. youtube: youtube.com 외 URL은 NULL
UPDATE influencers SET youtube = NULL
 WHERE youtube ~* '^https?://'
   AND youtube !~* '^https?://([a-z0-9-]+\.)?youtube\.com/';

-- 5. 빈/공백만 (ASCII + 전각 공백) → NULL
UPDATE influencers SET ig      = NULL WHERE ig      ~ '^[[:space:]　]*$' AND ig      IS NOT NULL;
UPDATE influencers SET x       = NULL WHERE x       ~ '^[[:space:]　]*$' AND x       IS NOT NULL;
UPDATE influencers SET tiktok  = NULL WHERE tiktok  ~ '^[[:space:]　]*$' AND tiktok  IS NOT NULL;
UPDATE influencers SET youtube = NULL WHERE youtube ~ '^[[:space:]　]*$' AND youtube IS NOT NULL;

-- 6. 일본어 "없음" 표현 → NULL (양끝 공백 trim 후 정확 매칭)
UPDATE influencers SET ig = NULL
 WHERE BTRIM(ig, E' \t\n\r　') IN ('なし','ない','無し','無い','無いです','なしです','ありません','無し。','なし。');

UPDATE influencers SET x = NULL
 WHERE BTRIM(x, E' \t\n\r　') IN ('なし','ない','無し','無い','無いです','なしです','ありません','無し。','なし。');

UPDATE influencers SET tiktok = NULL
 WHERE BTRIM(tiktok, E' \t\n\r　') IN ('なし','ない','無し','無い','無いです','なしです','ありません','無し。','なし。');

UPDATE influencers SET youtube = NULL
 WHERE BTRIM(youtube, E' \t\n\r　') IN ('なし','ない','無し','無い','無いです','なしです','ありません','無し。','なし。');

COMMIT;

-- 7. 검증 쿼리 (수동 실행)
--    잔존 확인 — 결과는 'Akari hb makeup' 같은 수동 판단 대상만 남아야 함
--    SELECT id, email, ig, x, tiktok, youtube
--      FROM influencers
--     WHERE ig ~ '/|@|[[:space:]　]' OR x ~ '/|@|[[:space:]　]'
--        OR tiktok ~ '/|@|[[:space:]　]' OR youtube ~ '/|@|[[:space:]　]';
--
--    047 변경분 확인 (백업 vs 현재):
--    SELECT i.email,
--           b.ig AS old_ig, i.ig AS new_ig,
--           b.x AS old_x, i.x AS new_x,
--           b.tiktok AS old_tt, i.tiktok AS new_tt,
--           b.youtube AS old_yt, i.youtube AS new_yt
--      FROM influencers i
--      JOIN influencers_sns_backup_046 b ON b.id = i.id
--     WHERE COALESCE(b.ig,'') <> COALESCE(i.ig,'')
--        OR COALESCE(b.x,'')  <> COALESCE(i.x,'')
--        OR COALESCE(b.tiktok,'')  <> COALESCE(i.tiktok,'')
--        OR COALESCE(b.youtube,'') <> COALESCE(i.youtube,'');
