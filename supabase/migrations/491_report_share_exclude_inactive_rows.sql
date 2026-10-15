-- 491_report_share_exclude_inactive_rows.sql
--   브랜드 공유 리포트 — ①반려·취소된 신청과 탈퇴가 확정된 회원의 결과물을 **응답에서 뺀다**
--                        ②브랜드가 열기만 해도 「업데이트」 시각이 바뀌던 것을 고친다.
--   (2026-10-01 전수조사 3차 ②-3 = ⑤-4 · ②-6)
--
-- 베이스: get_report_share_data 는 **469**(414 → 449 → 457 → 469 → 이 파일). 본문은 469 를 글자 그대로
--   복사하고 아래 네 자리만 바꿨다(작성 스크립트가 자리마다 개수를 확인했다 — 결과물 1 · 채널 집합 2 · 회원 1).
--   트리거 함수 touch_campaign_report_updated_at 은 **402** 가 베이스(그 뒤 재정의 없음).
--
-- ① 왜
--   관리자 리포트 표는 반려·취소된 신청을 「검수 불필요」 줄로 보여 주고, 공유 화면도 같은 원본(report-rows.js)으로
--   표를 만든다. 그래서 그 줄의 주문번호·구매금액·영수증 사진이 **브랜드에게 그대로** 갔다. 탈퇴 확정 회원은
--   이름은 비워져도(352) 영수증은 정산 때문에 6개월 남아(364) 「이름 없는 줄에 영수증」이 갔다.
--   운영 실측 2026-10-01: 켜진 공유 0개 → 실제로 나간 건 없음(잠복).
--   사용자 결정 2026-10-01 — 세 경우 모두 **줄째로 뺀다**. 관리자 표는 그대로(두 표의 줄 수가 달라진다).
--   「취소·반려 포함」 선택은 약관 확인 뒤 별도로. 탈퇴 확정 회원은 선택 없이 항상 뺀다.
--   판정은 `_report_share_row_included` **한 곳** — 결과물 목록·회원 목록·회원별 채널 집합 셋이 같은 것을 부른다.
--   셋 중 하나라도 빠지면 줄은 없는데 그 회원의 이름·SNS 계정이 응답에 남는다.
--   ⚠️ 탈퇴는 `done`(확정)만 — 진행 중(`pending_payout`·`scheduled`)은 되돌릴 수 있어 그대로 둔다.
--   ⚠️ 신청 행이 없는 결과물은 거짓(빼기) — 결과물 목록은 원래 신청과 JOIN 이라 빠져 있었다. 회원·채널 집합을 그에 맞췄다.
--
-- ② 왜
--   이 함수가 열 때마다 share_last_viewed_at 을 갱신하는데, 표의 BEFORE UPDATE 트리거(402)가 무조건
--   updated_at 을 now() 로 바꿨다. 공유 화면의 「업데이트」 = updated_at(report.html — 「구성 변경 시각」)이라
--   브랜드가 열 때마다 「방금 업데이트」로 보였다. → 바뀐 칸이 share_last_viewed_at 뿐이면 updated_at 을 두고 간다.
--   ⚠️ 이미 덮인 과거 updated_at 은 되돌릴 수 없다.
--
-- 🔴 **반드시 CREATE OR REPLACE 로만** — DROP 하면 413 이 비로그인 역할(anon)에 준 실행 권한이 풀려
--    공유 링크가 전부 죽는다. 이 파일에는 DROP 이 없다.

BEGIN;

-- ① 공유에 실을 결과물인가 — 신청이 반려·취소가 아니고, 회원 탈퇴가 확정되지 않았을 때만
CREATE OR REPLACE FUNCTION public._report_share_row_included(p_application_id uuid, p_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.applications a
                  WHERE a.id = p_application_id
                    AND coalesce(a.status, '') NOT IN ('rejected', 'cancelled'))
     AND NOT EXISTS (SELECT 1 FROM public.withdrawal_requests w
                      WHERE w.influencer_id = p_user_id AND w.status = 'done')
$$;

-- 안쪽 전용 — 회수 방향 둘 다 닫는다(369·370 규칙. 469 도우미와 같다)
REVOKE ALL ON FUNCTION public._report_share_row_included(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._report_share_row_included(uuid, uuid) FROM anon, authenticated;

-- ② 공유 데이터 — 469 본문 + ① 판정
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
        WHERE d.campaign_id = ANY(v_camp) AND d.status <> 'draft' AND (r.include_audit OR NOT coalesce(i.is_audit, false))
          AND public._report_share_row_included(d.application_id, d.user_id)), '[]'::jsonb),  -- 491
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
               AND public._report_share_row_included(d2.application_id, d2.user_id)  -- 491
               AND btrim(x.val) <> ''
            UNION ALL
            SELECT d2.post_channel AS code
              FROM public.deliverables d2
             WHERE d2.user_id = i.id AND d2.campaign_id = ANY(v_camp) AND d2.status <> 'draft'
               AND public._report_share_row_included(d2.application_id, d2.user_id)  -- 491
               AND d2.post_channel IS NOT NULL
          ) codes_raw
        ) ch ON true
        WHERE i.id IN (SELECT DISTINCT d.user_id FROM public.deliverables d WHERE d.campaign_id = ANY(v_camp) AND d.status <> 'draft'
                          AND public._report_share_row_included(d.application_id, d.user_id))), '{}'::jsonb),  -- 491
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

-- ③ updated_at 자동 갱신 — 바뀐 칸이 「마지막 열람 시각」뿐이면 건드리지 않는다(402 베이스)
CREATE OR REPLACE FUNCTION public.touch_campaign_report_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF (to_jsonb(NEW) - 'share_last_viewed_at' - 'updated_at')
     = (to_jsonb(OLD) - 'share_last_viewed_at' - 'updated_at') THEN
    RETURN NEW;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

COMMIT;

-- ------------------------------------------------------------
-- 검증
-- ------------------------------------------------------------
-- [V1] 권한 — 공유 함수 anon true / PUBLIC 없음 · 새 도우미는 anon·authenticated 모두 false
-- SELECT has_function_privilege('anon', 'public.get_report_share_data(uuid, text)', 'EXECUTE') AS share_anon,
--        (SELECT p.proacl::text LIKE '{=X/%' FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--          WHERE n.nspname = 'public' AND p.proname = 'get_report_share_data') AS share_public_remains,
--        has_function_privilege('anon', 'public._report_share_row_included(uuid, uuid)', 'EXECUTE') AS helper_anon,
--        has_function_privilege('authenticated', 'public._report_share_row_included(uuid, uuid)', 'EXECUTE') AS helper_auth;
-- 기대: true, false, false, false
--
-- [V2] 판정 — 반려·취소 신청 하나와 승인 신청 하나로
-- SELECT a.status, public._report_share_row_included(a.id, a.user_id)
--   FROM public.applications a WHERE a.status IN ('approved','rejected','cancelled') LIMIT 6;
-- 기대: approved → true(탈퇴 확정 회원이면 false) / rejected·cancelled → false
--
-- [V3] 트리거 — 시험 리포트 하나로(트랜잭션 안에서 되돌린다)
-- BEGIN;
--   SELECT id, updated_at FROM public.campaign_reports ORDER BY created_at DESC LIMIT 1;  -- id 를 아래에
--   UPDATE public.campaign_reports SET share_last_viewed_at = now() WHERE id = '<id>' RETURNING updated_at;  -- 위와 같아야
--   UPDATE public.campaign_reports SET title = title || '' WHERE id = '<id>' RETURNING updated_at;            -- 같아야(값이 안 바뀜 — 491 부터 「값이 그대로인 저장」은 시각을 안 올린다. 의도)
--   UPDATE public.campaign_reports SET version = version + 1 WHERE id = '<id>' RETURNING updated_at;          -- 바뀌어야
-- ROLLBACK;
--
-- [V4] 반려·취소 응모가 든 캠페인으로 공유를 켜고 공유 화면을 열어, 관리자 표의 「검수 불필요」 줄이
--      공유 표에 없는지 + 네트워크 응답 users 에 그 회원이 없는지 눈으로.
--
-- 되돌리기: 469 파일의 ③ 함수 부분과 402 의 트리거 함수 부분을 그대로 다시 실행(새 도우미는 남아도 무해).
