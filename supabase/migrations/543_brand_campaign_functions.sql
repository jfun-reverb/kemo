-- ============================================================
-- 543_brand_campaign_functions.sql
-- 2026-10-19 — 브랜드 페이지 「캠페인」 탭 1단계(모집 현황·진행 단계·일정) 함수
--   피그마 「[1차] 05 캠페인」 bw05-00·00a·01·bm05-00 · 사양서 docs/specs/2026-07-15-brand-portal.md §4 「현재 단계 정의」 캠페인 줄
--
-- 무엇을 하나 (이 파일이 하는 전부 — 함수 넷 추가, 기존 함수·표 변경 없음)
--   get_my_brand_campaigns(p_brand_id)        목록(STABLE)
--   get_my_brand_campaign(p_campaign_id)      상세(STABLE)
--   _brand_campaign_counts(p_campaign_id)     내부 — 응모·선정 수(두 함수가 같은 식을 쓰게 한 곳)
--   _brand_campaign_channel_names(p_channel)  내부 — 채널 코드 → 기준 데이터 한국어 이름
--   _brand_campaign_view_status(c, today)     내부 — 날짜로 다시 판정한 화면용 상태
--   적용만으로 바뀌는 기존 동작: 없음.
--
-- 계약
--   · 공개 둘은 SECURITY DEFINER SET search_path=''. 권한: GRANT TO postgres, authenticated, service_role → REVOKE FROM PUBLIC → REVOKE FROM anon(540 과 같은 순서).
--     내부 둘은 authenticated 에도 주지 않는다(정의자 권한 함수 안에서만 불린다 — 응모 수를 아무 캠페인에나 물어보지 못하게).
--   · 결과 {success:true, today, …} / {success:false, reason:'not_found'}. 거부는 하나로 뭉친다 —
--     캠페인 없음·남의 브랜드·브랜드 연결 없음·보관 브랜드·로그인 없음·보이지 않는 상태(「없는 캠페인」과 「남의 캠페인」을 가르지 않는다).
--   · 권한 판정 = 캠페인의 brand_id 로 public.is_my_brand()(530). 화면이 보낸 브랜드 번호는 목록에서만 쓰고 그 브랜드를 다시 판정한다.
--   · 반환 칸은 하나씩 골라 적는다 — 행을 통째로 싣지 않는다(제품 금액·긴급 발행 사유·옛 번호·서베이 신청 연결 같은 내부 칸이 섞인다).
--   · today = 일본 날짜(문자열 YYYY-MM-DD). 화면의 D-day·진행 단계 위치는 이 값으로 센다(기기 시계를 쓰지 않는다 — 결정 6).
--
-- 설계 판단 (2026-10-19 사용자 결정)
--   [A] 보일 캠페인 = status IN ('scheduled','active','closed','ended') 이고 deleted_at IS NULL(결정 1).
--       준비(draft)·노출 종료(expired)·삭제됨은 목록에서 빠지고 상세도 not_found.
--   [B] 응모 = 취소(cancelled) 아닌 응모 · 선정 = 지금 approved 인 응모(결정 3·4). 둘 다 감사용 계정(influencers.is_audit) 제외(181 과 같은 JOIN).
--       리뷰어형은 응모가 곧 당선(049 자동 승인)이라 선정 = 참여 인원이다 — 화면이 이름만 「참여」로 바꾼다.
--   [C] 결과물 숫자는 싣지 않는다 — 1단계에는 캠페인 「브랜드 공개」 장치가 없어 화면이 늘 「-」(결정 2). 공개 장치가 생길 때 이 함수의 베이스를 이 파일로 잡는다.
--   [D] 제품명 = product_ko → product → title(빈 문자열은 건너뛴다). 브랜드 화면이 한국어라 한국어 이름을 먼저.
--   [E] 채널 이름은 기준 데이터(lookup_values kind='channel')의 name_ko, 없으면 코드 그대로. 순서는 캠페인 칸의 순서.
--   [F] 정렬 = 만든 시각 내림차순(최신 캠페인 먼저 — 결정 7). 캠페인 번호 글자순은 쓰지 않는다 — 외부 형식(B…-C…)이 신청 연결 형식(B…-A…)보다
--       늘 위에 오고, 연결 때 번호가 다시 매겨지며, 세 자리를 넘으면 글자순이 깨진다(2026-10-19 데이터베이스 검토).
--   [G] 상세는 brand_id 를 싣는다 — 다른 내 브랜드의 캠페인 주소로 들어오면 화면이 그 브랜드로 바꾼 뒤 보여 준다.
--   [I] 🔴 상태는 저장값이 아니라 날짜로 다시 판정한 값(view_status)을 싣는다 — 저장된 status 는 **관리자 화면이 목록을 받을 때만**
--       날짜대로 바뀐다(storage.js autoOpenCampaigns → autoCloseCampaigns → autoEndCampaigns, 서버 정기 작업 없음).
--       관리자가 며칠 안 열면 마감이 지난 캠페인이 브랜드에게 「모집 중」으로 보인다. 판정식은 그 세 함수의 **사본**이다 —
--       그 식(일본 날짜 · 마감 당일은 안 지남 · 종료 기준 = campaignFinishDate: 제출 마감, 행사는 마지막 방문일)을 바꾸면 여기도 함께.
--       「보일 캠페인」 거르기([A])는 저장값으로 한다(draft·expired 는 날짜와 무관한 사람의 결정).
--   [H] 행사 칸 둘(event_mode·event_selection_mode)은 선정 단계 표시 조건(인플루언서 상세와 같은 식 — 화면 brand-campaigns.js 의 사본)에 쓴다.
--
-- 🔴 반환 칸을 나중에 바꾸려면 DROP 후 CREATE 라 실행 권한 회수(PUBLIC → anon)를 다시 걸어야 한다. 다음 재정의의 베이스는 이 파일(543).
-- 🔴 운영 반영 — 개발서버만. 브랜드 묶음(526~)과 함께, 530(is_my_brand) 뒤에.
-- 편집기 경고: 실행 구문에 DROP·DELETE 없음(CREATE OR REPLACE · GRANT/REVOKE · COMMENT).
--
-- 롤백(화면 brand-campaigns.js 를 먼저 되돌린 뒤):
--   DROP FUNCTION IF EXISTS public.get_my_brand_campaign(uuid);
--   DROP FUNCTION IF EXISTS public.get_my_brand_campaigns(uuid);
--   DROP FUNCTION IF EXISTS public._brand_campaign_counts(uuid);
--   DROP FUNCTION IF EXISTS public._brand_campaign_channel_names(text);
--   DROP FUNCTION IF EXISTS public._brand_campaign_view_status(public.campaigns, date);
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- [1] _brand_campaign_counts — 응모·선정 수(내부)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._brand_campaign_counts(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'applied_count',  count(*) FILTER (WHERE a.status <> 'cancelled'),
    'approved_count', count(*) FILTER (WHERE a.status = 'approved')
  )
    FROM public.applications a
    JOIN public.influencers i ON i.id = a.user_id AND i.is_audit = false
   WHERE a.campaign_id = p_campaign_id;
$$;

COMMENT ON FUNCTION public._brand_campaign_counts(uuid) IS
  '[543] 브랜드 캠페인 탭 — 응모(취소 제외)·선정(approved) 수, 감사용 계정 제외. 정의자 권한 함수 안에서만 부른다.';

GRANT  EXECUTE ON FUNCTION public._brand_campaign_counts(uuid) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_campaign_counts(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_campaign_counts(uuid) FROM anon, authenticated;

-- ------------------------------------------------------------
-- [2] _brand_campaign_channel_names — 채널 코드 → 한국어 이름(내부)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._brand_campaign_channel_names(p_channel text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(jsonb_agg(COALESCE(NULLIF(btrim(lv.name_ko), ''), ch.code) ORDER BY ch.ord), '[]'::jsonb)
    FROM (
      SELECT btrim(x) AS code, ord
        FROM unnest(string_to_array(COALESCE(p_channel, ''), ',')) WITH ORDINALITY AS t(x, ord)
       WHERE btrim(x) <> ''
    ) ch
    LEFT JOIN LATERAL (
      SELECT v.name_ko FROM public.lookup_values v
       WHERE v.kind = 'channel' AND v.code = ch.code
       LIMIT 1
    ) lv ON true;
$$;

COMMENT ON FUNCTION public._brand_campaign_channel_names(text) IS
  '[543] 브랜드 캠페인 탭 — 콤마로 이어진 채널 코드를 기준 데이터 한국어 이름 배열로(없으면 코드). 정의자 권한 함수 안에서만 부른다.';

GRANT  EXECUTE ON FUNCTION public._brand_campaign_channel_names(text) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_campaign_channel_names(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_campaign_channel_names(text) FROM anon, authenticated;

-- ------------------------------------------------------------
-- [2b] _brand_campaign_view_status — 날짜로 다시 판정한 상태(내부, 설계 판단 [I])
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._brand_campaign_view_status(c public.campaigns, p_today date)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v   text := c.status;
  fin date := COALESCE(c.submission_end::date, CASE WHEN c.event_mode IS TRUE THEN c.visit_end::date END);
BEGIN
  -- autoOpenCampaigns → autoCloseCampaigns → autoEndCampaigns 와 같은 순서로 이어서 본다
  IF v = 'scheduled' AND c.recruit_start IS NOT NULL AND c.recruit_start::date <= p_today THEN v := 'active'; END IF;
  IF v = 'active' AND c.deadline IS NOT NULL AND c.deadline::date < p_today THEN v := 'closed'; END IF;
  IF v = 'closed' AND fin IS NOT NULL AND fin < p_today THEN v := 'ended'; END IF;
  RETURN v;
END;
$$;

COMMENT ON FUNCTION public._brand_campaign_view_status(public.campaigns, date) IS
  '[543] 브랜드 캠페인 탭 — 저장된 상태를 일본 날짜로 다시 판정(storage.js auto* 세 함수의 사본). 정의자 권한 함수 안에서만 부른다.';

GRANT  EXECUTE ON FUNCTION public._brand_campaign_view_status(public.campaigns, date) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_campaign_view_status(public.campaigns, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_campaign_view_status(public.campaigns, date) FROM anon, authenticated;

-- ------------------------------------------------------------
-- [3] get_my_brand_campaigns — 목록
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_brand_campaigns(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_today date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_rows  jsonb;
BEGIN
  IF v_uid IS NULL OR p_brand_id IS NULL OR NOT public.is_my_brand(p_brand_id) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;

  SELECT COALESCE(jsonb_agg(row_json ORDER BY created_at DESC, id), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT c.id, c.created_at,
             jsonb_build_object(
               'id',            c.id,
               'campaign_no',   c.campaign_no,
               'product',       COALESCE(NULLIF(btrim(c.product_ko), ''), NULLIF(btrim(c.product), ''), c.title),
               'recruit_type',  c.recruit_type,
               'channel_names', public._brand_campaign_channel_names(c.channel),
               'status',        public._brand_campaign_view_status(c, v_today),
               'recruit_start', c.recruit_start,
               'deadline',      c.deadline,
               'slots',         c.slots
             ) || public._brand_campaign_counts(c.id) AS row_json
        FROM public.campaigns c
       WHERE c.brand_id = p_brand_id
         AND c.deleted_at IS NULL
         AND c.status IN ('scheduled', 'active', 'closed', 'ended')
    ) t;

  RETURN jsonb_build_object(
    'success',   true,
    'today',     to_char(v_today, 'YYYY-MM-DD'),
    'campaigns', v_rows
  );
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_campaigns(uuid) IS
  '[543] 브랜드 페이지 캠페인 목록 — is_my_brand 판정, 모집 예정·중·마감·종료만, 응모·선정 수(감사용 제외). 거부는 not_found 하나.';

GRANT  EXECUTE ON FUNCTION public.get_my_brand_campaigns(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_campaigns(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_campaigns(uuid) FROM anon;

-- ------------------------------------------------------------
-- [4] get_my_brand_campaign — 상세
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_brand_campaign(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_today date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  c       public.campaigns%ROWTYPE;
BEGIN
  IF v_uid IS NULL OR p_campaign_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;

  SELECT * INTO c FROM public.campaigns WHERE id = p_campaign_id;
  IF NOT FOUND
     OR c.deleted_at IS NOT NULL
     OR c.status NOT IN ('scheduled', 'active', 'closed', 'ended')
     OR c.brand_id IS NULL
     OR NOT public.is_my_brand(c.brand_id) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;

  RETURN jsonb_build_object(
    'success',  true,
    'today',    to_char(v_today, 'YYYY-MM-DD'),
    'campaign', jsonb_build_object(
      'id',                   c.id,
      'brand_id',             c.brand_id,
      'campaign_no',          c.campaign_no,
      'product',              COALESCE(NULLIF(btrim(c.product_ko), ''), NULLIF(btrim(c.product), ''), c.title),
      'recruit_type',         c.recruit_type,
      'channel',              c.channel,
      'channel_names',        public._brand_campaign_channel_names(c.channel),
      'status',               public._brand_campaign_view_status(c, v_today),
      'slots',                c.slots,
      'recruit_start',        c.recruit_start,
      'deadline',             c.deadline,
      'selection_start',      c.selection_start,
      'selection_end',        c.selection_end,
      'purchase_start',       c.purchase_start,
      'purchase_end',         c.purchase_end,
      'visit_start',          c.visit_start,
      'visit_end',            c.visit_end,
      'submission_end',       c.submission_end,
      'event_mode',           c.event_mode,
      'event_selection_mode', c.event_selection_mode
    ) || public._brand_campaign_counts(c.id)
  );
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_campaign(uuid) IS
  '[543] 브랜드 페이지 캠페인 상세 — 캠페인의 brand_id 로 is_my_brand 판정. 없는·남의·안 보이는 캠페인은 모두 not_found.';

GRANT  EXECUTE ON FUNCTION public.get_my_brand_campaign(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_campaign(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_campaign(uuid) FROM anon;

COMMIT;

-- ============================================================
-- 적용 뒤 확인 (SQL 편집기 — 서비스 키라 is_my_brand 갈래는 여기서 못 본다. 브랜드 로그인 화면으로 본다)
--   1) 함수 넷이 있는가
--      SELECT proname, prosecdef, proacl::text FROM pg_proc
--       WHERE proname IN ('get_my_brand_campaigns','get_my_brand_campaign','_brand_campaign_counts','_brand_campaign_channel_names');
--      → 공개 둘의 proacl 에 authenticated=X 있고 맨 앞 =X/ 없음 · anon 없음. 내부 둘은 authenticated·anon 모두 없음.
--   2) 로그인 없이 부르면 not_found
--      SELECT public.get_my_brand_campaigns('00000000-0000-0000-0000-000000000000');
-- ============================================================
