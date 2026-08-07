-- ============================================================
-- 319_drift_detection_strict_channel_match.sql
-- 채널 코드 어긋남 감지(A층) 비교 규칙을 실제 판정과 통일 — 대소문자·공백 엄격 비교
-- 사양: 전수조사 후속 조치 묶음 G — G-5
--
-- ▶ 재정의 베이스 확인 (feedback_function_redefine_latest_base 메모리 규칙)
--   grep -l "FUNCTION public.detect_channel_code_drift" supabase/migrations/*.sql
--     → 277, 278 두 곳. **이 함수의 현재 유효한 원본은 278번이다**(277 이 아니다 —
--     278 이 반려 결과물 제외 조건을 추가한 최신 정의). 이 파일은 278 본문을
--     베이스로 CREATE OR REPLACE 하며, 아래 「무엇을 바꿨나」에 적은 두 곳
--     (camp_ch·deliv CTE 의 채널 값 정규화)만 고친다. 그 외(3층 구조·covered
--     규칙·278 의 반려 제외 조건·권한·반환 형태)는 278 과 완전히 동일하다.
--
-- ▶ 왜 — 감지 장치가 「덮였다」로 오판하는 사각지대가 있었다
--   실제 인증 성공·정산 판정은 채널을 **글자 그대로**(대소문자·트림 방식까지)
--   비교한다. 두 곳에서 직접 확인:
--     · 정산 판정  — 300_settlement_amount_receipt_basis.sql 190~192행, 259~261행
--         `rcl.post_channel = btrim(ch.name)`
--         (캠페인 쪽 토큰만 btrim, 결과물 쪽 post_channel 은 원본 그대로 —
--          대소문자 구분 · 트림도 안 함)
--     · 화면 판정  — dev/js/admin-deliverables.js 556~558행, 585·591행
--         `g.reviewByChannel[d.post_channel]` (원본 그대로 키) 를
--         `channels = campaign.channel.split(',').map(c=>c.trim())` (트림만, 대소문자는
--          그대로) 로 조회 — 같은 규칙.
--   그런데 278(원본은 277)의 감지 장치는 camp_ch·deliv 양쪽 다 `lower(btrim(...))`
--   로 대소문자·공백을 지우고 비교했다. 즉 **대소문자만 다른 값은 실제 판정에서는
--   어긋나는데(인증 실패·정산 누락) 감지 장치는 "덮였다(covered)"로 통과시켜
--   버젓이 화면 경보 없이 넘어가는 사각지대가 있었다.** @cosme 사고(채널 코드
--   자체가 달랐던 경우)와는 다른 종류지만 같은 결과(리뷰 인증샷·정산이 조용히
--   빠짐)를 낳을 수 있는 두 번째 사각지대였다.
--
-- ▶ 결정된 방향 (사용자 확인 완료 — 재논의 대상 아님)
--   감지 장치를 **판정에 맞춰 엄격하게** 바꾼다(판정을 관대하게 바꾸는 반대
--   방향은 인증 성공·정산 결과 자체를 바꾸는 것이라 훨씬 위험하다). 근거:
--   운영 실측(M6 전수조사)에서 게시물 채널(post_channel)에 대소문자·공백이
--   섞인 값이 0건으로 확인됐다 — 엄격하게 바꿔도 오늘 시점 경보 건수가
--   늘어나지 않는다. 아래 [사전 확인용] 조회로 적용 직전 다시 한 번 이 전제를
--   확인할 수 있다.
--
-- ▶ 무엇을 바꿨나 (278 대비 딱 두 줄)
--   1) camp_ch CTE  — `lower(btrim(t.tok)) AS tok` → `btrim(t.tok) AS tok`
--      (대소문자를 더는 지우지 않는다. 트림만 유지 — 실제 판정도 캠페인 쪽
--       토큰은 btrim 만 하고 대소문자는 그대로 둔다)
--   2) deliv CTE    — `lower(btrim(d.post_channel)) AS dch` → `d.post_channel AS dch`
--      (결과물 쪽은 트림조차 걸지 않는다 — 실제 판정이 결과물 쪽에 아무
--       가공도 하지 않기 때문. 이 필드가 그대로 mismatched·covered 의 비교값이자
--       A층 화면 표시값(channel_code)이 된다 — 원본 그대로 보여주는 편이
--       "정확히 무엇이 다른지" 진단에 더 도움이 된다)
--   그 외 — mismatched CTE 의 `cc.tok = dv.dch` 비교 자체는 문자 그대로 유지.
--   위 두 CTE 의 값 정규화만 바뀌었으므로 비교가 자동으로 엄격해진다.
--
-- ▶ covered 는 A층·C층 어디에도 손대지 않았지만 결과가 함께 엄격해진다
--   covered CTE 는 `cc.tok = ok.dch` 로 같은 camp_ch·deliv 를 재사용하므로,
--   camp_ch·deliv 를 고치면 covered 도 자동으로 같은 규칙(엄격 비교)을 쓰게
--   된다. mismatched·covered 를 "따로" 고치지 않고 **원천(두 CTE)만 고쳐서
--   둘이 항상 같은 규칙을 쓰도록 강제**했다 — 한쪽만 엄격해지고 다른 쪽이
--   느슨한 채로 남는 사고(어긋난 행이 mismatched 에는 뜨는데 covered 판정은
--   옛 규칙으로 계속 덮어 버리는 경우)를 구조적으로 막는다.
--   C층은 covered CTE 를 그대로 재사용해 제외 여부만 결정하므로(278 상단
--   설명 그대로) 역시 자동으로 엄격해진 covered 를 물려받는다.
--
-- ▶ B층·C층의 lookup_values(기준 데이터) 대조는 그대로 둔다(lower 유지)
--   B층("캠페인 채널 토큰이 기준 데이터에 없다")과 C층의 "결과물 채널이
--   기준 데이터에 없는 값"은 애초에 위 두 곳(정산·화면)이 하지 않는 비교라
--   — 즉 "실제 판정과 통일"할 대상 자체가 없다. 여기를 엄격하게 바꾸면
--   근거 없이 경보만 늘어날 위험이 있어 손대지 않았다.
--
-- ▶ C층에 미치는 영향 (요청받은 확인 사항)
--   covered 가 엄격해지면 C층의 "NOT EXISTS (SELECT 1 FROM covered cv ...)"
--   제외 조건도 함께 엄격해진다 — 즉 지금까지 "덮였다"로 C층에서 빠졌던 행 중
--   대소문자 차이로만 덮여 있던 행이 있었다면 C층에 다시 나타날 수 있다.
--   운영 실측(M6)에서 그런 사각 사례가 0건으로 확인됐으므로 이론상 영향은
--   없어야 하지만, 이 파일 하단 [사전 확인용 3] 조회로 적용 직전 실제로
--   0건인지 재확인할 것.
--
-- ▶ 옛 @cosme 26건(사양서 §4 「26건 유지 결정 근거」)에 영향이 있는가 — 확인 결과
--   패치 supabase/patches/2026-07-30-fix-cosme-review-image-channel-code.sql 의
--   B그룹 정의를 보면, 이 26건은 "같은 응모에 옛 코드(channel-96r9y3) 행과
--   **새 코드(cosme) 행이 둘 다 있는**" 경우다. 새 코드 행의 post_channel 값은
--   그 패치가 이미 붙인 값이 아니라 **원래부터 정상 제출된 값**이며,
--   lookup_values 의 채널 코드 자체가 `cosme`(전부 소문자)로 정의돼 있고
--   캠페인의 channel 컬럼도 같은 코드값을 콤마로 나열해 저장한다 — 즉 이
--   26건의 "새 코드" 행은 대소문자까지 포함해 캠페인 채널 토큰과 **정확히
--   같은 문자열**이어야 covered 판정(같은 응모·같은 종류에 캠페인 채널과
--   일치하는 행이 있으면 제외)이 성립한다. 엄격 비교로 바꿔도 이 26건은
--   계속 covered 로 덮여야 한다는 것이 코드 상 판단이다 — 아래
--   [사전 확인용 4] 조회로 이 26건이 실제로 대소문자까지 정확히 일치하는지
--   적용 전 눈으로 확인할 것(이론과 실측을 분리해서 보고한다).
--
-- ▶ 롤백
--   278 파일의 CREATE OR REPLACE 블록을 그대로 재실행하면 이 변경만 되돌아간다.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.detect_channel_code_drift()
RETURNS TABLE (
  layer          text,
  campaign_id    uuid,
  campaign_no    text,
  campaign_title text,
  channel_code   text,
  kind           text,
  affected_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'permission_denied: 관리자만 조회할 수 있습니다'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH camp_ch AS (
    -- [319] 대소문자를 지우지 않는다(btrim 만 유지) — 실제 판정(정산 300번·화면
    -- admin-deliverables.js)이 캠페인 쪽 토큰에 btrim 만 걸고 대소문자는 그대로
    -- 두는 것과 통일.
    SELECT c.id AS cid, btrim(t.tok) AS tok
      FROM public.campaigns c
      CROSS JOIN LATERAL unnest(string_to_array(COALESCE(c.channel, ''), ',')) AS t(tok)
     WHERE btrim(t.tok) <> ''
  ),
  deliv AS (
    -- ⚠️ 반려는 여기서 빼지 않는다(278 규칙 그대로 — 「조건을 넣는 위치」 참고).
    --    covered 가 「그 채널에 행이 있는가」를 상태 불문으로 봐야 하기 때문.
    -- [319] dch 는 원본 post_channel 그대로(트림·대소문자 변환 없음) — 실제 판정이
    -- 결과물 쪽 값에 아무 가공도 하지 않는 것과 통일. 이 값이 그대로 A층 화면
    -- 표시(channel_code)로도 쓰이므로, 저장 시 섞여 들어간 공백·대소문자 오류가
    -- 있다면 그 자체가 진단 정보가 된다.
    SELECT d.id, d.campaign_id AS cid, d.kind AS dkind,
           d.post_channel AS dch,
           d.status AS dstatus, d.application_id
      FROM public.deliverables d
      JOIN public.applications a ON a.id = d.application_id
      JOIN public.campaigns    c ON c.id = d.campaign_id
      LEFT JOIN public.influencers i ON i.id = a.user_id
     WHERE d.post_channel IS NOT NULL
       AND btrim(d.post_channel) <> ''
       AND d.status <> 'draft'
       AND a.status NOT IN ('rejected', 'cancelled')
       AND c.deleted_at IS NULL
       AND COALESCE(i.is_audit, false) = false
  ),
  mismatched AS (
    SELECT dv.*
      FROM deliv dv
     WHERE NOT EXISTS (
       SELECT 1 FROM camp_ch cc WHERE cc.cid = dv.cid AND cc.tok = dv.dch
     )
       -- 278 — 반려된 결과물은 경보 후보에서 뺀다(이미 무효라 아무 판정에 안 쓰임)
       AND dv.dstatus <> 'rejected'
  ),
  covered AS (
    SELECT DISTINCT m.application_id, m.dkind
      FROM mismatched m
     WHERE EXISTS (
       SELECT 1
         FROM deliv ok
         JOIN camp_ch cc ON cc.cid = ok.cid AND cc.tok = ok.dch
        WHERE ok.application_id = m.application_id
          AND ok.dkind = m.dkind
     )
  )
  SELECT 'A'::text, c.id, c.campaign_no, c.title, m.dch, m.dkind, count(*)::bigint
    FROM mismatched m
    JOIN public.campaigns c ON c.id = m.cid
   WHERE NOT EXISTS (
     SELECT 1 FROM covered cv
      WHERE cv.application_id = m.application_id AND cv.dkind = m.dkind
   )
   GROUP BY c.id, c.campaign_no, c.title, m.dch, m.dkind

  UNION ALL

  -- B층 — 캠페인 채널 토큰이 기준 데이터에 없음(대소문자 무시 대조, 손대지 않음)
  SELECT 'B'::text, c.id, c.campaign_no, c.title, lower(btrim(t.tok)), NULL::text, 1::bigint
    FROM public.campaigns c
    CROSS JOIN LATERAL unnest(string_to_array(COALESCE(c.channel, ''), ',')) AS t(tok)
   WHERE c.deleted_at IS NULL
     AND btrim(t.tok) <> ''
     AND NOT EXISTS (
       SELECT 1 FROM public.lookup_values lv
        WHERE lv.kind = 'channel' AND lower(lv.code) = lower(btrim(t.tok))
     )

  UNION ALL

  -- C층 — 결과물 채널이 기준 데이터에 없는 값(대소문자 무시 대조, 손대지 않음).
  -- covered 제외 조건만 위에서 엄격해진 규칙을 그대로 물려받는다.
  SELECT 'C'::text, NULL::uuid, NULL::text, NULL::text,
         lower(btrim(d.post_channel)), d.kind, count(*)::bigint
    FROM public.deliverables d
    JOIN public.applications a ON a.id = d.application_id
    JOIN public.campaigns    c ON c.id = d.campaign_id
    LEFT JOIN public.influencers i ON i.id = a.user_id
   WHERE d.post_channel IS NOT NULL
     AND btrim(d.post_channel) <> ''
     AND d.status <> 'draft'
     -- 278 — 반려 제외(mismatched 와 같은 이유)
     AND d.status <> 'rejected'
     AND a.status NOT IN ('rejected', 'cancelled')
     AND c.deleted_at IS NULL
     AND COALESCE(i.is_audit, false) = false
     AND NOT EXISTS (
       SELECT 1 FROM public.lookup_values lv
        WHERE lv.kind = 'channel' AND lower(lv.code) = lower(btrim(d.post_channel))
     )
     AND NOT EXISTS (
       SELECT 1 FROM covered cv
        WHERE cv.application_id = d.application_id AND cv.dkind = d.kind
     )
   GROUP BY lower(btrim(d.post_channel)), d.kind

   ORDER BY 1, 3, 5;
END;
$$;

COMMENT ON FUNCTION public.detect_channel_code_drift() IS
  '[319] 채널 코드 어긋남 감지 (조회 전용). A=결과물 채널이 캠페인 요구 채널에 없음(실제 피해) /
   B=캠페인 채널 토큰이 기준 데이터에 없음(조기 경보) / C=결과물 채널이 기준 데이터에 없는 값.
   [319] A층의 채널 비교(camp_ch·deliv·mismatched·covered)는 실제 인증·정산 판정(300번·
   admin-deliverables.js)과 동일하게 **대소문자·공백을 엄격하게** 비교한다(캠페인 쪽만 btrim,
   결과물 쪽은 원본 그대로) — 278 까지는 양쪽 다 lower(btrim()) 로 느슨하게 비교해 대소문자만
   다른 어긋남을 "덮였다"로 오판하는 사각지대가 있었다. B·C층의 기준 데이터(lookup_values)
   대조는 대소문자 무시(lower) 그대로 유지 — 실제 판정이 하지 않는 비교라 통일 대상이 아님.
   A층·C층 모두 「같은 응모·같은 종류에 캠페인 채널과 일치하는 행이 있으면」(상태 불문) 제외한다
   (covered) — 옛·새 코드 공존 26건이 예외 목록 없이 자동 통과. 반려된 결과물은 경보하지
   않는다(278). 사양: 전수조사 후속 조치 묶음 G-5.';

REVOKE ALL ON FUNCTION public.detect_channel_code_drift() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.detect_channel_code_drift() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 — 1단계씩 순서대로. 관리자로 로그인한 브라우저 콘솔에서 실행
-- (SQL Editor 는 서비스 키라 is_admin() 이 false 로 판정돼 함수 호출 자체가
--  거부된다 — 아래 [사전 확인용]은 SQL Editor 에서 직접 돌리는 일반 조회다)
-- ============================================================
--
-- ── [사전 확인용 1] 적용 전 먼저 돌릴 것 — 대소문자만 다른 매칭이 몇 건인지 ──
-- 지금(278 기준) "덮였다(covered)"로 처리되고 있지만, 대소문자까지 엄격하게
-- 보면 실제로는 캠페인 채널과 정확히 일치하지 않는 결과물 행을 찾는다.
-- 0건이면 이 마이그레이션을 적용해도 오늘 시점 경보 건수는 변하지 않는다는
-- 뜻이다(파일 상단 "결정된 방향" 근거를 다시 한 번 실측으로 확인).
--
-- WITH camp_ch_ci AS (
--   SELECT c.id AS cid, lower(btrim(t.tok)) AS tok_ci, btrim(t.tok) AS tok_exact
--     FROM public.campaigns c
--     CROSS JOIN LATERAL unnest(string_to_array(COALESCE(c.channel, ''), ',')) AS t(tok)
--    WHERE btrim(t.tok) <> ''
-- ),
-- deliv_ci AS (
--   SELECT d.id, d.campaign_id AS cid, d.kind AS dkind, d.application_id,
--          d.post_channel AS dch_exact, lower(btrim(d.post_channel)) AS dch_ci, d.status
--     FROM public.deliverables d
--     JOIN public.applications a ON a.id = d.application_id
--     JOIN public.campaigns    c ON c.id = d.campaign_id
--    WHERE d.post_channel IS NOT NULL AND btrim(d.post_channel) <> ''
--      AND d.status <> 'draft' AND d.status <> 'rejected'
--      AND a.status NOT IN ('rejected','cancelled')
--      AND c.deleted_at IS NULL
-- )
-- SELECT dv.cid, dv.dkind, dv.application_id, dv.dch_exact AS 결과물_채널값,
--        cc.tok_exact AS 캠페인_채널토큰
--   FROM deliv_ci dv
--   JOIN camp_ch_ci cc ON cc.cid = dv.cid AND cc.tok_ci = dv.dch_ci
--  WHERE cc.tok_exact <> dv.dch_exact   -- 대소문자·공백만 다름(엄격화하면 어긋나게 됨)
--  ORDER BY 1, 2;
-- → 기대값: 0행 (M6 실측 근거와 일치해야 안전하게 적용 가능)
-- → 0행이 아니면 즉시 멈추고, 나온 행들이 실제로 문제(진짜 어긋남)인지
--    아니면 정당한 사유가 있는 값인지 먼저 판단할 것 — 그대로 적용하면
--    이 마이그레이션이 새 경보를 만들어낸다.
--
-- ── [사전 확인용 2] 적용 후 — A/B/C 층 전체 결과 (브라우저 콘솔) ──
-- const r = await db.rpc('detect_channel_code_drift');
-- console.log('error:', r.error);
-- console.table(r.data || []);
-- → [사전 확인용 1]이 0행이었다면 이 결과도 278 적용 시점(전부 0행)과 같아야 한다.
--
-- ── [사전 확인용 3] C층 영향 확인 — covered 가 엄격해지며 새로 나타나는 행이 있는지 ──
-- [사전 확인용 1]이 0행이면 이 조회도 0행이어야 한다(covered 가 mismatched 를
-- 그대로 재사용하므로 논리적으로 함께 0이 된다). 굳이 따로 확인하고 싶다면
-- [사전 확인용 2]의 결과에서 layer='C' 인 행이 278 적용 시점의 C층 결과와
-- 같은지 눈으로 대조.
--
-- ── [사전 확인용 4] 옛 @cosme 26건이 여전히 covered 로 덮이는지 실측 ──
-- SELECT a.id AS application_id, d.post_channel, d.status,
--        c.channel AS campaign_channel_raw
--   FROM public.deliverables d
--   JOIN public.applications a ON a.id = d.application_id
--   JOIN public.campaigns c ON c.id = d.campaign_id
--  WHERE d.kind = 'review_image'
--    AND d.application_id IN (
--      SELECT application_id FROM public.deliverables
--       WHERE kind = 'review_image' AND post_channel = 'channel-96r9y3'
--      INTERSECT
--      SELECT application_id FROM public.deliverables
--       WHERE kind = 'review_image' AND post_channel = 'cosme'
--    )
--  ORDER BY a.id, d.post_channel;
-- → post_channel='cosme' 행의 값이 campaign_channel_raw 안의 토큰과 대소문자까지
--   정확히 일치하는지(콤마로 나눠 btrim 한 값 중 'cosme' 이 그대로 있는지) 눈으로
--   확인. 일치하면 파일 상단 "옛 @cosme 26건" 판단이 실측으로도 맞다는 뜻.
-- ============================================================
