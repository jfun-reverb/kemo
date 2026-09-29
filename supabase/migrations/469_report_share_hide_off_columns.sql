-- 469_report_share_hide_off_columns.sql
--   브랜드 공유 리포트 — 관리자가 **끈 열의 값을 서버 응답에서도 뺀다.**
--
-- 베이스: **457**(report_share_channel_match) — 414 → 449 → 457 → 이 파일. 본문은 457 을 글자 그대로
--   복사하고 아래 자리만 바꿨다(작성 스크립트가 바꿀 자리마다 「정확히 1곳」을 확인했다).
--
-- 왜 (2026-09-28 전수조사 3차 H-2)
--   457 은 `share_columns` 를 SNS 계정 4열에만 적용했다. 주문번호·구매일·구매금액·영수증 주소·
--   게시물 주소·결과물 사진·이름은 관리자가 꺼도 **응답에 그대로** 내려가, 화면만 숨겼다.
--   공유 링크를 받은 브랜드는 개발자 도구의 네트워크 응답에서 원본 값을 그대로 볼 수 있었다.
--
-- 판정은 화면과 같다 — `reportShareColOff`(dev/js/report-rows.js).
--   ①옛 열쇠 16개(`REPORT_SHARE_LEGACY_KEYS`)는 목록에 **없으면** 끈 것 ②새 열쇠는 `-열쇠` 가 **있으면** 끈 것
--   ③목록 자체가 NULL 이면 전부 켬.
--   🔴 **같은 판정이 두 벌이 됐다** — 화면 `reportShareColOff` · 이 파일 `_report_share_col_off`.
--      옛 열쇠 목록과 채널 대장(`REPORT_CHANNELS` 7개)을 고치면 이 파일의 두 함수도 함께 고친다.
--
-- 비우는 칸(열이 꺼졌을 때만)
--   결과물: order_number · purchase_date · purchase_amount · receipt_url(영수증 → 'receipt_url' 열 /
--           리뷰 사진 → 그 채널의 `ch_{코드}_url` 열) · review_image_url · post_url(그 채널 열)
--   채널이 비었거나 대장에 없는 코드 → `ch_etc_url`(「기타 결과물」 열)
--   회원: name_kanji · name_kana
--   외부 첨부: order_no · purchase_amount · receipt_url · qoo10_urls · cosme_urls
-- 비우지 않는 칸 — submitted_at·receipt_at·qoo10_at 등 날짜, status·kind·post_channel·has_receipt.
--   화면이 「최신 1건」 고르기와 인증 상태 판정에 쓴다. 날짜 열을 끄면 화면이 숨긴다(종전대로).
-- ⚠️ 알려진 부작용 — 채널 열을 끄면 그 채널 주소가 비어, 「요구 채널을 다 채웠는가」로 비우던
--   「기타 결과물」 칸에 옛 코드 행이 보일 수 있다(`_reportEtcCell`). 「기타」 열은 따로 끌 수 있다.
--
-- 🔴 **반드시 CREATE OR REPLACE 로만** — DROP 하면 413 이 비로그인 역할(anon)에 준 실행 권한이
--    풀려 **공유 링크가 전부 죽는다**. 이 파일에는 get_report_share_data 의 DROP 이 없다.
-- ⚠️ share_columns 는 **jsonb 배열**이다 — 원소 검사는 `?` 로(`= ANY` 는 부를 때 오류).

-- ① 열이 꺼졌는가 — 화면 reportShareColOff 와 같은 규칙
CREATE OR REPLACE FUNCTION public._report_share_col_off(p_saved jsonb, p_key text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN p_key IS NULL THEN false
    WHEN p_saved IS NULL OR jsonb_typeof(p_saved) <> 'array' THEN false
    WHEN p_key = ANY (ARRAY['no','campaign_no','campaign_name','purchase_period','status',
                            'order_no','purchase_date','amount','receipt_url','receipt_uploaded_at',
                            'name_kanji','name_kana',
                            'ch_qoo10_url','ch_qoo10_at','ch_cosme_url','ch_cosme_at'])
      THEN NOT (p_saved ? p_key)
    ELSE (p_saved ? ('-' || p_key))
  END
$$;

-- ② 결과물의 채널 코드 → 그 결과물이 그려지는 열쇠. 대장(REPORT_CHANNELS)에 없거나 비었으면 「기타」.
CREATE OR REPLACE FUNCTION public._report_share_chan_col(p_channel text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN p_channel IN ('qoo10','cosme','lips','instagram','tiktok','x','youtube') THEN 'ch_' || p_channel || '_url'
    ELSE 'ch_etc_url'
  END
$$;

-- 두 도우미는 안쪽 전용 — 계산만 하고 표를 안 읽지만 회수 방향 둘 다 닫는다(369·370 규칙).
REVOKE ALL ON FUNCTION public._report_share_col_off(jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._report_share_col_off(jsonb, text) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public._report_share_chan_col(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._report_share_chan_col(text) FROM anon, authenticated;

-- ③ 공유 데이터 — 457 본문 + 위 판정
CREATE OR REPLACE FUNCTION public.get_report_share_data(p_token uuid, p_ticket text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r      public.campaign_reports%ROWTYPE;
  v_ok   boolean;
  v_camp uuid[];
  v_out  jsonb;
  v_cols jsonb;   -- 469: 관리자가 고른 열 목록(없으면 NULL = 전부 켬)
BEGIN
  IF p_token IS NULL OR p_ticket IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO r FROM public.campaign_reports WHERE share_token = p_token;
  IF r.id IS NULL OR NOT r.share_enabled OR (r.share_expires_at IS NOT NULL AND r.share_expires_at < now()) THEN RETURN NULL; END IF;
  SELECT EXISTS (SELECT 1 FROM public.campaign_report_view_tickets t
                  WHERE t.report_id = r.id AND t.token_hash = encode(extensions.digest(p_ticket, 'sha256'), 'hex') AND t.expires_at > now())
    INTO v_ok;
  IF NOT v_ok THEN RETURN NULL; END IF;

  -- 🔴 토큰이 가리키는 캠페인만
  SELECT coalesce(array_agg(campaign_id) FILTER (WHERE campaign_id IS NOT NULL), '{}') INTO v_camp
    FROM public.campaign_report_campaigns WHERE report_id = r.id;

  UPDATE public.campaign_reports SET share_last_viewed_at = now() WHERE id = r.id;
  v_cols := r.share_columns;

  SELECT jsonb_build_object(
    'title',         r.title,
    'created_at',    r.created_at,
    'updated_at',    r.updated_at,
    'include_audit', r.include_audit,
    'columns',       r.share_columns,
    'campaigns', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'campaign_id', rc.campaign_id, 'campaign_no', rc.campaign_no, 'campaign_title', rc.campaign_title, 'sort_order', rc.sort_order,
        'campaign_exists', rc.campaign_id IS NOT NULL) ORDER BY rc.sort_order)
        FROM public.campaign_report_campaigns rc WHERE rc.report_id = r.id), '[]'::jsonb),
    -- 캠페인 실물(표 만들기가 쓰는 칸만) — 브랜드가 알아도 되는 값
    'campaign_rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', c.id, 'campaign_no', c.campaign_no, 'title', c.title, 'recruit_type', c.recruit_type, 'channel', c.channel,
        'proxy_purchase', c.proxy_purchase, 'purchase_start', c.purchase_start, 'purchase_end', c.purchase_end,
        'visit_start', c.visit_start, 'visit_end', c.visit_end))
        FROM public.campaigns c WHERE c.id = ANY(v_camp)), '[]'::jsonb),
    -- 결과물 — 임시저장 제외(관리자 화면과 같다). 감사용 계정은 리포트 설정대로.
    --   ⚠️ 414 부터 receipt_url 을 **모든 종류**에 준다(영수증 사진 포함 — 사용자 결정 2026-09-04, 방침 §3.1 제공 항목에 추가).
    --   413 은 영수증(kind=receipt)만 빼고 리뷰 사진(review_image)의 주소를 review_image_url 로 따로 줬다.
    --   review_image_url 은 옛 화면이 아직 캐시돼 있을 때를 위해 남긴다.
    'deliverables', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', d.id, 'kind', d.kind, 'status', d.status, 'campaign_id', d.campaign_id, 'application_id', d.application_id, 'user_id', d.user_id,
        'order_number',    CASE WHEN public._report_share_col_off(v_cols, 'order_no')      THEN NULL ELSE d.order_number END,
        'purchase_date',   CASE WHEN public._report_share_col_off(v_cols, 'purchase_date') THEN NULL ELSE d.purchase_date END,
        'purchase_amount', CASE WHEN public._report_share_col_off(v_cols, 'amount')        THEN NULL ELSE d.purchase_amount END,
        'post_url', CASE WHEN public._report_share_col_off(v_cols, public._report_share_chan_col(d.post_channel)) THEN NULL ELSE d.post_url END, 'post_channel', d.post_channel, 'submitted_at', d.submitted_at,
        'has_receipt', d.receipt_url IS NOT NULL,
        'receipt_url', CASE
                         WHEN d.kind = 'receipt' AND public._report_share_col_off(v_cols, 'receipt_url') THEN NULL
                         WHEN d.kind = 'review_image' AND public._report_share_col_off(v_cols, public._report_share_chan_col(d.post_channel)) THEN NULL
                         ELSE d.receipt_url END,
        'review_image_url', CASE WHEN d.kind = 'review_image'
                                  AND NOT public._report_share_col_off(v_cols, public._report_share_chan_col(d.post_channel))
                                 THEN d.receipt_url END,
        'applications', jsonb_build_object('status', a.status),
        'campaigns', jsonb_build_object('id', c.id, 'campaign_no', c.campaign_no, 'title', c.title, 'recruit_type', c.recruit_type,
                                        'channel', c.channel, 'channel_match', c.channel_match, 'proxy_purchase', c.proxy_purchase,
                                        'purchase_start', c.purchase_start, 'purchase_end', c.purchase_end, 'visit_start', c.visit_start, 'visit_end', c.visit_end)))
        FROM public.deliverables d
        JOIN public.applications a ON a.id = d.application_id
        JOIN public.campaigns c ON c.id = d.campaign_id
        JOIN public.influencers i ON i.id = d.user_id
        WHERE d.campaign_id = ANY(v_camp) AND d.status <> 'draft' AND (r.include_audit OR NOT coalesce(i.is_audit, false))), '[]'::jsonb),
    -- 회원 — 🔴 이메일 없음. 이름은 가려서.
    --   449: SNS 계정 4종 추가. 회원별로 「관계있는 채널 집합」을 서브쿼리 하나로 구해
    --   그 안에 있는 채널만 계정을 싣는다(나머지는 NULL). 끈 채널(-ch_{코드}_acct)은
    --   관계와 무관하게 전원 NULL. 감사용 회원은 표에 안 나오므로 계정도 NULL.
    --   ⚠️ share_columns 는 **jsonb 배열**이다 — 원소 검사는 `?` 로 한다. `= ANY(...)` 는 Postgres 배열 전용이라
    --      jsonb 에 쓰면 함수를 만들 때는 통과하고 **부르는 순간** 오류가 난다(= 공유 링크가 전부 죽는다).
    'users', coalesce((SELECT jsonb_object_agg(i.id, jsonb_build_object(
        'id', i.id,
        'name_kanji', CASE WHEN public._report_share_col_off(v_cols, 'name_kanji') THEN NULL
                           ELSE public._mask_report_name(coalesce(i.name_kanji, i.name), 2, '**') END,
        'name_kana',  CASE WHEN public._report_share_col_off(v_cols, 'name_kana') THEN NULL
                           ELSE public._mask_report_name(i.name_kana, 3, '***') END,
        'is_audit', coalesce(i.is_audit, false),
        'ig', CASE WHEN NOT (coalesce(r.share_columns, '[]'::jsonb) ? '-ch_instagram_acct')
                    AND (r.include_audit OR NOT coalesce(i.is_audit, false))
                    AND 'instagram' = ANY(ch.codes)
                   THEN nullif(btrim(i.ig), '') END,
        'tiktok', CASE WHEN NOT (coalesce(r.share_columns, '[]'::jsonb) ? '-ch_tiktok_acct')
                    AND (r.include_audit OR NOT coalesce(i.is_audit, false))
                    AND 'tiktok' = ANY(ch.codes)
                   THEN nullif(btrim(i.tiktok), '') END,
        'x', CASE WHEN NOT (coalesce(r.share_columns, '[]'::jsonb) ? '-ch_x_acct')
                    AND (r.include_audit OR NOT coalesce(i.is_audit, false))
                    AND 'x' = ANY(ch.codes)
                   THEN nullif(btrim(i.x), '') END,
        'youtube', CASE WHEN NOT (coalesce(r.share_columns, '[]'::jsonb) ? '-ch_youtube_acct')
                    AND (r.include_audit OR NOT coalesce(i.is_audit, false))
                    AND 'youtube' = ANY(ch.codes)
                   THEN nullif(btrim(i.youtube), '') END))
        FROM public.influencers i
        LEFT JOIN LATERAL (
          -- 이 회원이 v_camp 안에서 임시저장이 아닌 결과물로 「관계있는」 채널 코드 집합.
          -- (가) 결과물이 낸 캠페인이 요구하는 채널 전부(campaigns.channel 콤마 분해, btrim)
          -- (나) 그 결과물 자신의 post_channel
          SELECT array_agg(DISTINCT code) AS codes
          FROM (
            SELECT btrim(x.val) AS code
              FROM public.deliverables d2
              JOIN public.campaigns c2 ON c2.id = d2.campaign_id
              CROSS JOIN LATERAL unnest(string_to_array(coalesce(c2.channel, ''), ',')) AS x(val)
             WHERE d2.user_id = i.id AND d2.campaign_id = ANY(v_camp) AND d2.status <> 'draft'
               AND btrim(x.val) <> ''
            UNION ALL
            SELECT d2.post_channel AS code
              FROM public.deliverables d2
             WHERE d2.user_id = i.id AND d2.campaign_id = ANY(v_camp) AND d2.status <> 'draft'
               AND d2.post_channel IS NOT NULL
          ) codes_raw
        ) ch ON true
        WHERE i.id IN (SELECT DISTINCT d.user_id FROM public.deliverables d WHERE d.campaign_id = ANY(v_camp) AND d.status <> 'draft')), '{}'::jsonb),
    -- 외부 첨부 — 🔴 account_id 키 없음(414 에서 receipt_url 은 열었다)
    'sources', coalesce((SELECT jsonb_agg(jsonb_build_object('id', s.id, 'ext_campaign_no', s.ext_campaign_no, 'ext_campaign_name', s.ext_campaign_name,
        'attached_at', s.attached_at, 'row_count', s.row_count) ORDER BY s.attached_at)
        FROM public.campaign_report_sources s WHERE s.report_id = r.id), '[]'::jsonb),
    'ext_rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'source_id', x.source_id, 'member_no', x.member_no, 'mission_status', x.mission_status,
        'order_no',        CASE WHEN public._report_share_col_off(v_cols, 'order_no')     THEN NULL ELSE x.order_no END,
        'purchase_amount', CASE WHEN public._report_share_col_off(v_cols, 'amount')       THEN NULL ELSE x.purchase_amount END,
        'receipt_url',     CASE WHEN public._report_share_col_off(v_cols, 'receipt_url')  THEN NULL ELSE x.receipt_url END,
        'receipt_at', x.receipt_at, 'review_kind', x.review_kind,
        'qoo10_urls', CASE WHEN public._report_share_col_off(v_cols, 'ch_qoo10_url') THEN NULL ELSE x.qoo10_urls END,
        'qoo10_at', x.qoo10_at,
        'cosme_urls', CASE WHEN public._report_share_col_off(v_cols, 'ch_cosme_url') THEN NULL ELSE x.cosme_urls END,
        'cosme_at', x.cosme_at))
        FROM public.campaign_report_ext_rows x JOIN public.campaign_report_sources s ON s.id = x.source_id
        WHERE s.report_id = r.id), '[]'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END; $$;

-- ------------------------------------------------------------
-- 검증
-- ------------------------------------------------------------
-- [V1] 권한 — anon true / PUBLIC 없음(414·457 과 같다)
-- SELECT has_function_privilege('anon', 'public.get_report_share_data(uuid, text)', 'EXECUTE'),
--        (p.proacl::text LIKE '{=X/%') AS public_remains
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.proname = 'get_report_share_data';
-- 기대: true, false
--
-- [V2] 판정 함수 — 화면 reportShareColOff 와 같은 답
-- SELECT public._report_share_col_off(NULL, 'order_no')                      AS null_all_on,     -- false
--        public._report_share_col_off('["no"]'::jsonb, 'order_no')           AS legacy_absent,   -- true
--        public._report_share_col_off('["order_no"]'::jsonb, 'order_no')     AS legacy_present,  -- false
--        public._report_share_col_off('["-ch_lips_url"]'::jsonb, 'ch_lips_url') AS new_off,       -- true
--        public._report_share_col_off('[]'::jsonb, 'ch_lips_url')            AS new_default_on,  -- false
--        public._report_share_chan_col('other')                              AS etc,             -- ch_etc_url
--        public._report_share_chan_col(NULL)                                 AS etc_null;        -- ch_etc_url
--
-- [V3] 공유 링크를 열어 네트워크 응답에서 **끈 열의 칸이 null** 인지, 켠 열은 값이 있는지 눈으로.
--
-- 되돌리기: 457 파일을 그대로 다시 실행(두 도우미는 남아도 무해).
