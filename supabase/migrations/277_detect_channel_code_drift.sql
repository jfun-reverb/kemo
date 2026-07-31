-- ============================================================
-- 277_detect_channel_code_drift.sql
-- 채널 코드 어긋남 감지 함수 (재발 방지 ②, 조회 전용)
-- 사양: docs/specs/2026-07-30-cosme-channel-affected-report.md §4 조치 계획 10번
--
-- ▶ 왜 필요한가
--   2026-07-30 @cosme 사고에서 승인된 리뷰 인증샷 55건이 **두 달간** 화면·인증 성공·
--   정산 세 곳에서 사라져 보였는데 아무도 몰랐다. 관리자 검수 화면의 레거시 구제 장치
--   (hasLegacyReviewImage)는 post_channel 이 **빈 값일 때만** 작동해, 「값이 있고 그
--   값이 틀린」 이번 경우는 사각지대였다. 즉 감지 수단이 0이었던 것이 사고의 본질이다.
--
-- ▶ 3층으로 나눈 이유 — 사고의 시간 순서를 거슬러 올라가기 위해
--   이번 사고는 ①기준 데이터에서 옛 코드가 사라짐 → ②캠페인이 새 코드로 옮겨짐 →
--   ③결과물은 옛 코드로 남음 순서였다. C·B 는 A 보다 **먼저** 뜨므로 조기 경보가 된다.
--
--   A(실제 피해) : 결과물의 post_channel 이 그 응모가 속한 캠페인의 채널 목록에 없음
--                  → 지금 이 순간 화면·인증 성공·정산에서 빠져 있는 상태
--   B(앞선 신호) : campaigns.channel 의 토큰이 lookup_values 에 없음
--                  → 아직 결과물은 안 깨졌지만 기준이 흔들린 상태
--   C(구조 확정) : deliverables.post_channel 이 lookup_values 에 없는 값('other' 등)
--                  → 어떤 캠페인 채널 목록과도 **영원히** 일치할 수 없음
--
-- ▶ ★ covered 규칙 — 「같은 응모·같은 종류에 캠페인 채널과 일치하는 행이 있으면 뺀다」
--   (A층·C층 공통 적용. 상태(승인/검수중/반려) 불문 — 아래 참고)
--   이 한 줄이 옛·새 코드가 공존하는 26건(2026-07-31 「그대로 유지」 결정)을 **예외 목록·
--   하드코딩·시각 컷오프 없이** 자동 통과시킨다. 그 26건은 새 코드 행이 존재하므로
--   실제로는 정상 동작 중이기 때문이다. 반대로 55건처럼 정상 행이 없는 진짜 문제는 잡힌다.
--
--   ⚠️ **승인(approved) 요구 없음 — review_image(리뷰 인증샷)는 상태 불문 "그 채널에
--      행이 존재하는지"만으로 결정된다.** 실제 판단 로직은 세 곳이 전부 채널 문자열이
--      정확히 일치하는 행만 본다(상태는 안 봄) — ①화면 _finalizeMonitorReprs
--      (admin-deliverables.js:572, `g.reviewByChannel[campaignChannel]`) ②검수대기 배지
--      count_pending_review_applications(마이그레이션 250, review_image 만 채널별 최신)
--      ③정산 후보 _settlement_cert_candidates()(마이그레이션 232·262·264)의
--      review_channel_latest·channel_cert. 세 곳 다 "그 채널 행이 있으면 그 행의 상태로
--      추적되고, 없으면 'none'/미제출로 빠진다"는 동일 구조라, 승인을 요구하면 "정확한
--      채널로 재제출했지만 아직 검수 전"인 정상 진행 건까지 A층 오탐(false positive)이
--      된다. (admin-deliverables.js:699 `hasValidApprovedPost` 는 **kind='post'
--      [gifting/visit] 전용 UI 배지 숨김 로직**이라 review_image 의 실제 판정 근거가
--      아니다 — 처음엔 이걸 근거로 인용했으나 부정확해 위 세 곳으로 정정했다.)
--
--   ⚠️ kind='post'(gifting/visit)는 애초에 채널 무관이다 — post_latest·g.result 모두
--      "신청당 최신 1건"을 채널 구분 없이 잡는다(마이그레이션 250 명시). 즉 post 의
--      채널 불일치는 인증 성공·정산 판정에 실질 영향이 없는 **데이터 정리 신호**에
--      가깝다(기존 관리자 화면 mismatchedBox 청소 기능과 같은 성격). 그래도 covered
--      규칙을 동일 적용해 두는 이유는 review_image 와 SQL 을 하나로 유지하기 위해서고,
--      실무 판단(정리 우선순위)은 운영자가 review_image/post 를 구분해서 본다.
--
--   ⚠️ **인증 성공 판정(computeCertStatus)을 재현하지 않는다.** 그 판정은 이미
--      _settlement_cert_candidates()(마이그레이션 232·262·264)와 화면에 복제돼 있어,
--      여기에 또 옮기면 **네 번째 복제**가 되고 넷이 어긋날 위험이 커진다. 위 규칙만으로
--      같은 결과(26건 제외·55건 검출)를 얻으므로 더 좁은 규칙을 택했다.
--
--   ⚠️ **C층에도 covered 를 적용한다.** channel-96r9y3 는 마이그레이션 193 에서
--      lookup_values 에서 하드 삭제됐다(교체가 아니라 DELETE). 즉 26건은 A층뿐 아니라
--      C층 조건("lookup_values 에 그 코드가 아예 없음")에도 100% 걸린다. covered 를
--      A층에만 걸면 26건이 층만 바뀐 채 그대로 다시 뜬다 — 사양서
--      2026-07-30-cosme-channel-affected-report.md §4 조치 계획 10번이 경고한
--      "감지 장치가 늑대소년이 된다"가 C층에서 재발하는 것과 같다.
--
-- ▶ 그 외 A층 제외 — 이미 다른 이유로 판정에서 빠져 있어 세면 경보가 과장된다
--   · post_channel 이 NULL·빈 값(레거시 미지정 — 별도 구제 장치 소관)
--   · status='draft'(아직 제출 아님)
--   · 신청이 rejected·cancelled(isCertExcluded 규칙 — 이미 인증·정산에서 제외됨)
--   · 캠페인이 보관 삭제됨(deleted_at)
--   · 감사용 계정(influencers.is_audit — 운영 통계에서 격리되는 계정)
--
-- ▶ 개인정보 — 인플루언서 식별 정보를 반환하지 않는다
--   결과물 관리 페인은 campaign_manager 도 들어오는데, 그 등급은 민감정보 가림막 뷰
--   (마이그레이션 212·213)로 개인정보가 차단돼 있다. 이 함수가 인플루언서 정보를 실어
--   보내면 그 차단을 우회하게 되므로 **캠페인 정보와 건수까지만** 반환한다.
--   (개별 건 추적이 필요하면 결과물 관리 화면에서 캠페인으로 필터해 확인한다.)
--
-- ▶ 권한 — is_admin() (세 등급 전부). 조회 전용이라 쓰기 부작용 없음.
--
-- ▶ 화면 노출은 이 마이그레이션 범위 밖
--   경보를 화면에 켜는 시점의 실측치가 0 이 아니면 「원래 빨간 숫자가 있는 화면」으로
--   학습되어, 두 달간 아무도 몰랐던 이번 사고와 같은 결과가 난다. 먼저 이 함수로
--   운영 실측 → 남은 어긋남 정리 → 그 다음 화면 노출 순서로 간다.
--
-- ▶ 롤백
--   DROP FUNCTION IF EXISTS public.detect_channel_code_drift();
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.detect_channel_code_drift()
RETURNS TABLE (
  layer          text,     -- 'A' | 'B' | 'C'
  campaign_id    uuid,     -- B·A 는 캠페인 단위, C 는 NULL(캠페인 무관 값 문제)
  campaign_no    text,
  campaign_title text,
  channel_code   text,     -- 어긋난 코드
  kind           text,     -- A·C: 결과물 종류 / B: NULL
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
  -- ── A층: 결과물 채널이 그 캠페인의 요구 채널 목록에 없음 (실제 피해) ──
  WITH camp_ch AS (
    -- 캠페인별 요구 채널 토큰 (콤마 구분 → 행 전개, 소문자·공백 정리)
    SELECT c.id AS cid, lower(btrim(t.tok)) AS tok
      FROM public.campaigns c
      CROSS JOIN LATERAL unnest(string_to_array(COALESCE(c.channel, ''), ',')) AS t(tok)
     WHERE btrim(t.tok) <> ''
  ),
  deliv AS (
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
  ),
  -- ★ 같은 응모·같은 종류에 「캠페인 채널과 정확히 일치하는 행」이 있으면 제외.
  --   상태(승인/검수중/반려) 불문 — _finalizeMonitorReprs·_settlement_cert_candidates()
  --   모두 "그 채널에 행이 존재하는지"만으로 그 채널을 추적하기 때문(위 문서 상단 참고).
  --   A층·C층 양쪽에서 재사용한다(C층도 26건이 다시 걸리는 것을 막기 위해 필수).
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

  -- ── B층: 캠페인의 요구 채널 토큰이 기준 데이터에 없음 (앞선 신호) ──
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

  -- ── C층: 결과물 채널이 기준 데이터에 아예 없는 값 (구조적으로 영원히 불일치) ──
  --   'other' 처럼 lookup_values 에 없는 값. 캠페인과 무관하게 값 자체가 문제다.
  --   ★ covered 제외 필수 — channel-96r9y3 는 lookup_values 에서 하드 삭제됐으므로
  --   (마이그레이션 193) 이 조건에 그대로 걸린다. covered 로 26건을 빼지 않으면
  --   A층에서 뺀 걸 C층이 그대로 다시 띄운다(문서 상단 「C층에도 covered」 참고).
  SELECT 'C'::text, NULL::uuid, NULL::text, NULL::text,
         lower(btrim(d.post_channel)), d.kind, count(*)::bigint
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
  '[277] 채널 코드 어긋남 감지 (조회 전용). A=결과물 채널이 캠페인 요구 채널에 없음(실제 피해,
   review_image 는 인증 판정에 실영향·post 는 채널 무관이라 데이터 정리 신호에 가까움) /
   B=캠페인 채널 토큰이 기준 데이터에 없음(조기 경보) / C=결과물 채널이 기준 데이터에 없는 값.
   A층·C층 모두 「같은 응모·같은 종류에 캠페인 채널과 정확히 일치하는 행이 있으면」(상태 불문)
   제외한다(covered CTE) — 옛·새 코드 공존 26건이 예외 목록 없이 자동 통과한다. C층에도
   적용하는 이유는 channel-96r9y3 가 lookup_values 에서 하드 삭제돼(마이그레이션 193) C층
   조건에도 걸리기 때문(covered 없으면 26건이 층만 바뀌어 재출현). 인증 성공 판정을
   재현하지 않는다(이미 세 곳에 복제돼 있어 네 번째를 만들지 않는다). 인플루언서 개인정보
   미반환. 사양: 2026-07-30-cosme-channel-affected-report.md §4.';

REVOKE ALL ON FUNCTION public.detect_channel_code_drift() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.detect_channel_code_drift() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (SQL Editor — 1단계씩 순서대로. 결과 확인 후 다음 단계)
-- ============================================================
--
-- 1단계 — 함수 존재·시그니처:
--   SELECT proname, prosecdef, provolatile, pronargs
--     FROM pg_proc
--    WHERE proname = 'detect_channel_code_drift' AND pronamespace = 'public'::regnamespace;
--   → prosecdef=true, provolatile='s', pronargs=0
--
-- 2단계 — 실측은 SQL Editor 에서 직접 호출로 안 된다. SQL Editor 는 service_role
--   세션이라 auth.uid() 가 NULL → is_admin() 이 항상 false 라 함수 안 RAISE
--   EXCEPTION 에 걸린다(권한 있는 postgres 소유자 role 이어도 마찬가지 — 이 차단은
--   GRANT/REVOKE 가 아니라 함수 본문 코드로 거는 것이라 소유자 우회가 안 통한다.
--   233·264 등 다른 함수가 쓰는 "postgres 소유자는 GRANT 없이도 호출 가능" 트릭은
--   그쪽이 GRANT 기반 차단이라 통하는 것이고 여긴 다르다).
--   → 반드시 **관리자로 로그인한 브라우저**에서 호출할 것(운영/개발 관리자 페이지
--     열어 로그인한 채로 개발자 콘솔에서):
--       await db.rpc('detect_channel_code_drift').then(r => console.table(r.data))
--     (db 는 dev/lib/supabase.js 가 만든 전역 Supabase 클라이언트)
--   → A층 0행이 목표. B·C 층은 정리 대상 목록.
--
-- 3단계 — 26건이 A층에서 실제로 제외되는지 확인 (같은 브라우저 콘솔에서):
--   await db.rpc('detect_channel_code_drift').then(r =>
--     console.table(r.data.filter(x => x.layer==='A' && x.channel_code==='channel-96r9y3')))
--   → 0행 기대. 나오면 covered 규칙이 안 먹은 것이다.
--
-- 4단계 — 같은 26건이 C층에서도 제외되는지 확인 (covered 를 C층에 적용한 이유가
--   바로 이 26건 — channel-96r9y3 는 lookup_values 에서 하드 삭제됐으므로[마이그레이션
--   193] C층 조건에도 원래는 걸린다):
--   await db.rpc('detect_channel_code_drift').then(r =>
--     console.table(r.data.filter(x => x.layer==='C' && x.channel_code==='channel-96r9y3')))
--   → 0행 기대. 26이 나오면 C층 covered 적용이 안 먹은 것이다(3단계는 통과하고
--     이 4단계만 실패하는 패턴이 실제로 나올 수 있는 부분이니 반드시 따로 확인).
-- ============================================================
