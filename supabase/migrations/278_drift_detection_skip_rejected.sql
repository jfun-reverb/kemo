-- ============================================================
-- 278_drift_detection_skip_rejected.sql
-- 채널 코드 어긋남 감지 — **반려된 결과물은 경보하지 않는다**
-- 사양: docs/specs/2026-07-30-cosme-channel-affected-report.md §4 조치 계획 10번
--
-- ▶ 재정의 베이스 확인 (feedback_function_redefine_latest_base 메모리 규칙)
--   grep -l "FUNCTION public.detect_channel_code_drift" supabase/migrations/*.sql
--     → 277 단 1곳. 277 이 "가장 큰 번호의 정의" == "유일한 정의".
--   이 파일은 277 본문을 베이스로 CREATE OR REPLACE 하며, **아래 두 곳에만** 조건을
--   더한다. 그 외(층 정의·covered 규칙·제외 조건·권한·반환 형태)는 277 과 동일하다.
--
-- ▶ 왜 — 반려는 이미 「무효」로 판정된 결과물이다
--   운영 실측(2026-07-31)에서 C층에 `other` 2건이 남았는데, 둘 다 **반려 상태**였다.
--   반려된 결과물은 인증 성공 판정에도 정산 후보에도 쓰이지 않으므로, 채널이 어긋나
--   있어도 **아무도 손해를 보지 않는다.** 그런 건을 세면 화면 경보가 0 으로 시작하지
--   못하고, 「원래 빨간 숫자가 있는 화면」으로 학습되어 **두 달간 아무도 몰랐던 이번
--   사고가 그대로 반복된다**(사양서 §4 10번이 경고한 늑대소년 문제).
--   데이터를 지우는 대신 세지 않는 쪽을 택했다 — 지우면 검수 이력이 함께 사라진다.
--
-- ▶ ★ 조건을 넣는 위치가 핵심 — deliv 가 아니라 mismatched·C층에만 넣는다
--   `deliv` CTE 자체에서 반려를 빼면 **covered 판정까지 약해진다.** covered 는
--   「같은 응모·같은 종류에 캠페인 채널과 정확히 일치하는 행이 있는가」인데, 그 판정은
--   상태를 보지 않는 것이 맞다 — 실제 판정 세 곳(_finalizeMonitorReprs ·
--   count_pending_review_applications · _settlement_cert_candidates())이 전부
--   「그 채널에 행이 존재하는지」만으로 채널을 추적하기 때문이다(277 상단 참고).
--   그래서 **올바른 채널에 반려 행만 있는 경우에도 그 채널은 점유된 것**으로 봐야 하고,
--   deliv 에서 반려를 빼면 그 점유가 사라져 어긋난 행이 엉뚱하게 A층에 뜬다.
--
--   정리:
--     · deliv          — 반려 포함(그대로). covered 가 채널 점유를 정확히 보게 한다
--     · mismatched     — 반려 제외(신설). 경보 후보에서만 뺀다
--     · C층 조회        — 반려 제외(신설). 같은 이유
--
-- ▶ 이 변경으로 달라지는 것
--   운영 기준 C층 `other` 2건(둘 다 반려) → 0건. A·B층은 이미 0이라 변화 없음.
--   즉 **화면 경보를 0 에서 시작할 수 있게 된다**(다음 단계의 전제 조건).
--
-- ▶ 롤백
--   277 파일의 CREATE OR REPLACE 블록을 그대로 재실행하면 이 변경만 되돌아간다.
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
    SELECT c.id AS cid, lower(btrim(t.tok)) AS tok
      FROM public.campaigns c
      CROSS JOIN LATERAL unnest(string_to_array(COALESCE(c.channel, ''), ',')) AS t(tok)
     WHERE btrim(t.tok) <> ''
  ),
  deliv AS (
    -- ⚠️ 여기서는 반려를 빼지 않는다(위 「조건을 넣는 위치」 참고).
    --    covered 가 「그 채널에 행이 있는가」를 상태 불문으로 봐야 하기 때문.
    SELECT d.id, d.campaign_id AS cid, d.kind AS dkind,
           lower(btrim(d.post_channel)) AS dch,
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
       -- ★ 278 신설 — 반려된 결과물은 경보 후보에서 뺀다(이미 무효라 아무 판정에 안 쓰임)
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

  SELECT 'C'::text, NULL::uuid, NULL::text, NULL::text,
         lower(btrim(d.post_channel)), d.kind, count(*)::bigint
    FROM public.deliverables d
    JOIN public.applications a ON a.id = d.application_id
    JOIN public.campaigns    c ON c.id = d.campaign_id
    LEFT JOIN public.influencers i ON i.id = a.user_id
   WHERE d.post_channel IS NOT NULL
     AND btrim(d.post_channel) <> ''
     AND d.status <> 'draft'
     -- ★ 278 신설 — 반려 제외(mismatched 와 같은 이유)
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
  '[278] 채널 코드 어긋남 감지 (조회 전용). A=결과물 채널이 캠페인 요구 채널에 없음(실제 피해) /
   B=캠페인 채널 토큰이 기준 데이터에 없음(조기 경보) / C=결과물 채널이 기준 데이터에 없는 값.
   A층·C층 모두 「같은 응모·같은 종류에 캠페인 채널과 정확히 일치하는 행이 있으면」(상태 불문)
   제외한다(covered) — 옛·새 코드 공존 26건이 예외 목록 없이 자동 통과. **반려된 결과물은
   경보하지 않는다(278)** — 이미 무효라 인증·정산 어느 판정에도 쓰이지 않으므로, 세면 경보가
   0 에서 시작하지 못해 늑대소년이 된다. ⚠️ 반려 제외는 mismatched·C층에만 넣고 deliv 에는
   넣지 않는다 — covered 는 채널 점유를 상태 불문으로 봐야 하기 때문.
   사양: 2026-07-30-cosme-channel-affected-report.md §4.';

REVOKE ALL ON FUNCTION public.detect_channel_code_drift() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.detect_channel_code_drift() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (관리자로 로그인한 브라우저 콘솔에서 — SQL Editor 는 is_admin() 이 false 라 거부됨)
-- ============================================================
--   const r = await db.rpc('detect_channel_code_drift');
--   console.log('error:', r.error);
--   console.table(r.data || []);
--
-- 기대(운영 기준, 2026-07-31 실측):
--   · C층의 `other` 2건(둘 다 반려) → **사라짐**
--   · A·B층 → 이미 0이라 변화 없음
--   · 전체 0행 = 화면 경보를 0 에서 시작할 수 있는 상태
--
-- SQL Editor 에서 확인하려면 함수 본문의 조회부를 직접 실행할 것(is_admin 가드 제외).
-- ============================================================
