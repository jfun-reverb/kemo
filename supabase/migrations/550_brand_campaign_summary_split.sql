-- ============================================================
-- 550_brand_campaign_summary_split.sql — 브랜드 캠페인 목록·상세 「결과물 게시」 기준 바꾸기 + 숫자 나누기
--   작업표 docs/specs/2026-10-19-brand-campaign-results-breakdown.md 「조각 4b」(결정 S11·S25 — 2026-10-19 피그마 05-1 반영)
--
-- 무엇을 바꾸나 — _brand_campaign_summary(547) 하나만 다시 정의한다(547 베이스 · CREATE OR REPLACE · 반환 jsonb 그대로라 권한 보존)
--   · result_posted = 세 숫자의 「검수 완료」(approved — 외부 「완료」 줄 포함). 547 은 「제출」(submitted)이었다(S11)
--     공개 꺼짐이면 키를 싣지 않는다(547 그대로)
--   · 나눈 숫자 셋을 더한다(S25 — 화면이 「REVERB N + 외부 참가자 M」으로 나눠 적는다)
--       applied_reverb  — REVERB 응모(감사용 제외 · _brand_campaign_counts 그대로)
--       approved_reverb — REVERB 참여(선정)
--       ext_participants — 그 캠페인에 붙인 외부 결과 파일의 참가자 수(_campaign_ext_participant_count — 546)
--   · applied_count·approved_count 는 지금처럼 합계(= REVERB + 외부) — 1단계 화면이 그대로 읽는다
--
-- 부르는 곳: get_my_brand_campaigns · get_my_brand_campaign(547) — 본문은 바꾸지 않는다(이 함수 결과를 행에 붙인다)
-- 실행 권한: 547 이 건 회수(PUBLIC·anon·authenticated)가 CREATE OR REPLACE 로 그대로 남는다 — 아래에서 한 번 더 확인용으로 건다
--
-- 되돌리기: 547 의 _brand_campaign_summary 정의를 다시 실행(result_posted 가 submitted 로, 나눈 칸 셋이 빠진다 — 화면은 칸이 없으면 나누지 않는다)
-- 편집기 경고: 함수 정의만 있다. 표 변경·DROP 없음
-- ============================================================

CREATE OR REPLACE FUNCTION public._brand_campaign_summary(p_campaign_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_counts   jsonb   := public._brand_campaign_counts(p_campaign_id);
  v_ext      integer := coalesce(public._campaign_ext_participant_count(p_campaign_id), 0);
  v_applied  integer := coalesce((v_counts ->> 'applied_count')::integer, 0);
  v_approved integer := coalesce((v_counts ->> 'approved_count')::integer, 0);
  v_pub      boolean;
  v_out      jsonb;
BEGIN
  SELECT p.enabled INTO v_pub FROM public.campaign_brand_publish p WHERE p.campaign_id = p_campaign_id;
  v_pub := coalesce(v_pub, false);
  v_out := jsonb_build_object(
    'applied_count',    v_applied  + v_ext,
    'approved_count',   v_approved + v_ext,
    'applied_reverb',   v_applied,
    'approved_reverb',  v_approved,
    'ext_participants', v_ext,
    'results_public',   v_pub
  );
  IF v_pub THEN
    -- S11 — 「결과물 게시」 = 검수까지 끝난 결과물(최신 건 기준 · 외부 「완료」 포함). 분모는 화면이 approved_count(합계)로 그린다
    v_out := v_out || jsonb_build_object('result_posted', coalesce((public._brand_campaign_result_counts(p_campaign_id) ->> 'approved')::integer, 0));
  END IF;
  RETURN v_out;
END;
$$;

COMMENT ON FUNCTION public._brand_campaign_summary(uuid) IS
  '[550] 브랜드 캠페인 목록·상세에 붙는 칸 — 응모·참여 합계(REVERB+외부) + applied_reverb·approved_reverb·ext_participants + results_public + (공개 켜짐) result_posted = 검수 완료. 내부 전용.';

-- 실행 권한(547 과 같다 — 다시 걸어도 결과가 같다)
GRANT  EXECUTE ON FUNCTION public._brand_campaign_summary(uuid) TO postgres, service_role;
REVOKE ALL ON FUNCTION public._brand_campaign_summary(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._brand_campaign_summary(uuid) FROM anon, authenticated;
