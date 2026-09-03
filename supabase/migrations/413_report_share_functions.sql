-- ============================================================
-- 413. 리포트 공유 — 관리자 함수 6종 + 익명 함수 2종
-- ============================================================
-- 작업표: 「작업 21·22」(+ 작업 23 이 부를 관리자 함수) · 사양서 「공유 링크 잠금」·「칸별 규칙」
--
-- 🔴 익명(anon)에 여는 것은 (가) verify_report_share_password · (나) get_report_share_data 둘뿐이다.
--    브랜드는 로그인이 없다. 무엇을 왜 열었는지:
--      (가) 비밀번호 확인 → 열람 표 발급. **데이터는 한 줄도 안 준다.** 시도 제한 10분 10회.
--      (나) 열람 표를 **안에서 다시 검증**하고 그 리포트의 결과물만 준다.
--    둘 다 표에 직접 접근하는 정책은 없다(SECURITY DEFINER 로 읽는다).
-- 🔴 가리는 방법은 (나) 안 **한 곳**에 둔다 — 흩어지면 한쪽만 고쳐져 원본이 샌다.
--    · 계정 아이디·영수증 주소 = 응답에 **아예 없다**(빈칸이 아니라 키 자체가 없다)
--    · 이름(한자) 앞 2글자 + `**` / 이름(가나) 앞 3글자 + `***`
--    · 주문번호·구매금액·날짜·결과물 주소 = 그대로 (⚠️ 주문번호는 가리지 않는다 — 가렸다고 적으면 거짓 안내)
-- 🔴 열람 표: 원문은 브라우저(sessionStorage)가 들고, 표에는 sha256 만. 유효 12시간.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 공용: 이름 가리기 (한 곳)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mask_report_name(p_name text, p_keep integer, p_stars text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN coalesce(p_name,'') = '' THEN '' ELSE left(p_name, p_keep) || p_stars END;
$$;
REVOKE ALL ON FUNCTION public._mask_report_name(text, integer, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._report_share_event(p_report uuid, p_kind text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_name text;
BEGIN
  IF auth.uid() IS NOT NULL THEN SELECT a.name INTO v_name FROM public.admins a WHERE a.auth_id = auth.uid(); END IF;
  INSERT INTO public.campaign_report_share_events (report_id, kind, actor, actor_name) VALUES (p_report, p_kind, auth.uid(), v_name);
END; $$;
REVOKE ALL ON FUNCTION public._report_share_event(uuid, text) FROM PUBLIC, anon, authenticated;

-- ============================================================
-- 관리자 쪽 — 전부 has_permission('report.share','write') (상태 조회만 read)
-- ============================================================

-- ① 공유 켜기 (처음이면 토큰·비밀번호 필수. 다시 켜면 기존 토큰·비밀번호 유지)
CREATE OR REPLACE FUNCTION public.enable_report_share(p_report_id uuid, p_password text, p_expires_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.campaign_reports%ROWTYPE;
BEGIN
  IF NOT public.has_permission('report.share', 'write') THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  SELECT * INTO r FROM public.campaign_reports WHERE id = p_report_id FOR UPDATE;
  IF r.id IS NULL THEN RAISE EXCEPTION '없는 리포트입니다' USING ERRCODE = '22023'; END IF;
  IF r.share_password_cipher IS NULL AND coalesce(length(p_password), 0) < 4 THEN
    RAISE EXCEPTION '비밀번호는 4자 이상이어야 합니다' USING ERRCODE = '22023';
  END IF;
  UPDATE public.campaign_reports SET
    share_token           = coalesce(share_token, gen_random_uuid()),
    share_password_cipher = CASE WHEN p_password IS NOT NULL AND length(p_password) >= 4 THEN public._encrypt_report_password(p_password) ELSE share_password_cipher END,
    share_expires_at      = p_expires_at,                 -- NULL = 무기한
    share_enabled         = true
  WHERE id = p_report_id RETURNING * INTO r;
  PERFORM public._report_share_event(p_report_id, 'link_on');
  RETURN jsonb_build_object('token', r.share_token, 'expires_at', r.share_expires_at);
END; $$;

-- ② 공유 끄기 — 🔴 열람 표도 지운다(브랜드가 보던 화면이 다음 조회에서 닫힌다)
CREATE OR REPLACE FUNCTION public.disable_report_share(p_report_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT public.has_permission('report.share', 'write') THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  UPDATE public.campaign_reports SET share_enabled = false WHERE id = p_report_id AND share_enabled = true;
  IF NOT FOUND THEN RETURN false; END IF;
  DELETE FROM public.campaign_report_view_tickets WHERE report_id = p_report_id;
  PERFORM public._report_share_event(p_report_id, 'link_off');
  RETURN true;
END; $$;

-- ③ 비밀번호 다시 정하기 — 🔴 열람 표를 지운다(옛 비밀번호로 연 화면이 죽는다). 화면이 「브랜드에 다시 알려야 함」을 말한다.
CREATE OR REPLACE FUNCTION public.reset_report_share_password(p_report_id uuid, p_password text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT public.has_permission('report.share', 'write') THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  IF coalesce(length(p_password), 0) < 4 THEN RAISE EXCEPTION '비밀번호는 4자 이상이어야 합니다' USING ERRCODE = '22023'; END IF;
  UPDATE public.campaign_reports SET share_password_cipher = public._encrypt_report_password(p_password) WHERE id = p_report_id;
  IF NOT FOUND THEN RETURN false; END IF;
  DELETE FROM public.campaign_report_view_tickets WHERE report_id = p_report_id;
  PERFORM public._report_share_event(p_report_id, 'pw_reset');
  RETURN true;
END; $$;

-- ④ 비밀번호 보기 — 🔴 원문을 볼 수 있는 유일한 통로. 누가 언제 봤는지 남긴다.
CREATE OR REPLACE FUNCTION public.reveal_report_share_password(p_report_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c bytea;
BEGIN
  IF NOT public.has_permission('report.share', 'write') THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  SELECT share_password_cipher INTO c FROM public.campaign_reports WHERE id = p_report_id;
  IF c IS NULL THEN RETURN NULL; END IF;
  PERFORM public._report_share_event(p_report_id, 'pw_reveal');
  RETURN public._decrypt_report_password(c);
END; $$;

-- ⑤ 만료일·열 목록 바꾸기
CREATE OR REPLACE FUNCTION public.update_report_share_settings(p_report_id uuid, p_expires_at timestamptz, p_columns jsonb)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT public.has_permission('report.share', 'write') THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  IF p_columns IS NOT NULL AND jsonb_typeof(p_columns) <> 'array' THEN RAISE EXCEPTION '열 목록은 배열이어야 합니다' USING ERRCODE = '22023'; END IF;
  UPDATE public.campaign_reports SET share_expires_at = p_expires_at, share_columns = p_columns WHERE id = p_report_id;
  RETURN FOUND;
END; $$;

-- ⑥ 공유 상태 (설정 창이 읽는다). 비밀번호 원문은 안 준다 — has_password 만.
CREATE OR REPLACE FUNCTION public.get_report_share_status(p_report_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.campaign_reports%ROWTYPE; ev jsonb;
BEGIN
  IF NOT public.has_permission('menu.reports', 'read') THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  SELECT * INTO r FROM public.campaign_reports WHERE id = p_report_id;
  IF r.id IS NULL THEN RETURN NULL; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('kind', e.kind, 'actor_name', e.actor_name, 'at', e.at) ORDER BY e.at DESC), '[]'::jsonb)
    INTO ev FROM (SELECT * FROM public.campaign_report_share_events WHERE report_id = p_report_id ORDER BY at DESC LIMIT 30) e;
  RETURN jsonb_build_object(
    'enabled', r.share_enabled, 'token', r.share_token, 'expires_at', r.share_expires_at,
    'has_password', r.share_password_cipher IS NOT NULL, 'last_viewed_at', r.share_last_viewed_at,
    'columns', r.share_columns, 'events', ev,
    'view_count', (SELECT count(*) FROM public.campaign_report_share_events WHERE report_id = p_report_id AND kind = 'view'));
END; $$;

-- ============================================================
-- 익명 쪽
-- ============================================================

-- (가) 비밀번호 확인 → 열람 표. 데이터 0줄.
CREATE OR REPLACE FUNCTION public.verify_report_share_password(p_token uuid, p_password text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r        public.campaign_reports%ROWTYPE;
  v_fails  integer;
  v_ticket text;
  v_exp    timestamptz;
BEGIN
  IF p_token IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'link_expired'); END IF;
  SELECT * INTO r FROM public.campaign_reports WHERE share_token = p_token;
  -- 꺼졌거나 만료된 링크면 **비밀번호를 보기 전에** 거절 — 없는 토큰도 같은 답(존재 여부 비노출)
  IF r.id IS NULL OR NOT r.share_enabled OR (r.share_expires_at IS NOT NULL AND r.share_expires_at < now()) OR r.share_password_cipher IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'link_expired');
  END IF;

  -- 시도 제한: 최근 10분 실패 10회 이상이면 잠금 (🔴 서버가 센다 — 화면은 새로고침에 초기화된다)
  SELECT count(*) INTO v_fails FROM public.campaign_report_pw_attempts
   WHERE report_id = r.id AND NOT succeeded AND attempted_at > now() - interval '10 minutes';
  IF v_fails >= 10 THEN
    INSERT INTO public.campaign_report_pw_attempts (report_id, succeeded) VALUES (r.id, false);
    RETURN jsonb_build_object('ok', false, 'reason', 'locked');
  END IF;

  IF p_password IS NULL OR public._decrypt_report_password(r.share_password_cipher) <> p_password THEN
    INSERT INTO public.campaign_report_pw_attempts (report_id, succeeded) VALUES (r.id, false);
    RETURN jsonb_build_object('ok', false, 'reason', 'wrong');   -- 몇 번 남았는지는 알리지 않는다
  END IF;

  INSERT INTO public.campaign_report_pw_attempts (report_id, succeeded) VALUES (r.id, true);
  v_ticket := encode(extensions.gen_random_bytes(32), 'hex');
  v_exp    := now() + interval '12 hours';
  INSERT INTO public.campaign_report_view_tickets (report_id, token_hash, expires_at)
  VALUES (r.id, encode(extensions.digest(v_ticket, 'sha256'), 'hex'), v_exp);
  PERFORM public._report_share_event(r.id, 'view');
  RETURN jsonb_build_object('ok', true, 'ticket', v_ticket, 'expires_at', v_exp);
END; $$;

-- (나) 데이터 — 🔴 열람 표를 여기서 다시 검증한다. 실패하면 NULL(0줄).
--     결과물 그룹핑·표 만들기는 화면(report-rows.js — 관리자와 같은 원본)이 한다. 서버는 **가린 원자료**만 준다.
CREATE OR REPLACE FUNCTION public.get_report_share_data(p_token uuid, p_ticket text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r      public.campaign_reports%ROWTYPE;
  v_ok   boolean;
  v_camp uuid[];
  v_out  jsonb;
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
    -- 결과물 — 🔴 receipt_url 키 자체를 안 넣는다. 임시저장 제외(관리자 화면과 같다). 감사용 계정은 리포트 설정대로.
    'deliverables', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', d.id, 'kind', d.kind, 'status', d.status, 'campaign_id', d.campaign_id, 'application_id', d.application_id, 'user_id', d.user_id,
        'order_number', d.order_number, 'purchase_date', d.purchase_date, 'purchase_amount', d.purchase_amount,
        'post_url', d.post_url, 'post_channel', d.post_channel, 'submitted_at', d.submitted_at,
        'has_receipt', d.receipt_url IS NOT NULL,
        -- 리뷰 화면 사진(review_image)의 주소는 receipt_url 칸에 들어 있다 — 그것은 결과물이라 준다. 영수증(kind=receipt)은 안 준다.
        'review_image_url', CASE WHEN d.kind = 'review_image' THEN d.receipt_url END,
        'applications', jsonb_build_object('status', a.status),
        'campaigns', jsonb_build_object('id', c.id, 'campaign_no', c.campaign_no, 'title', c.title, 'recruit_type', c.recruit_type,
                                        'channel', c.channel, 'proxy_purchase', c.proxy_purchase,
                                        'purchase_start', c.purchase_start, 'purchase_end', c.purchase_end, 'visit_start', c.visit_start, 'visit_end', c.visit_end)))
        FROM public.deliverables d
        JOIN public.applications a ON a.id = d.application_id
        JOIN public.campaigns c ON c.id = d.campaign_id
        JOIN public.influencers i ON i.id = d.user_id
        WHERE d.campaign_id = ANY(v_camp) AND d.status <> 'draft' AND (r.include_audit OR NOT coalesce(i.is_audit, false))), '[]'::jsonb),
    -- 회원 — 🔴 이메일 없음. 이름은 가려서.
    'users', coalesce((SELECT jsonb_object_agg(i.id, jsonb_build_object(
        'id', i.id,
        'name_kanji', public._mask_report_name(coalesce(i.name_kanji, i.name), 2, '**'),
        'name_kana',  public._mask_report_name(i.name_kana, 3, '***'),
        'is_audit', coalesce(i.is_audit, false)))
        FROM public.influencers i
        WHERE i.id IN (SELECT DISTINCT d.user_id FROM public.deliverables d WHERE d.campaign_id = ANY(v_camp) AND d.status <> 'draft')), '{}'::jsonb),
    -- 외부 첨부 — 🔴 account_id·receipt_url 키 없음
    'sources', coalesce((SELECT jsonb_agg(jsonb_build_object('id', s.id, 'ext_campaign_no', s.ext_campaign_no, 'ext_campaign_name', s.ext_campaign_name,
        'attached_at', s.attached_at, 'row_count', s.row_count) ORDER BY s.attached_at)
        FROM public.campaign_report_sources s WHERE s.report_id = r.id), '[]'::jsonb),
    'ext_rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'source_id', x.source_id, 'member_no', x.member_no, 'mission_status', x.mission_status, 'order_no', x.order_no,
        'purchase_amount', x.purchase_amount, 'receipt_at', x.receipt_at, 'review_kind', x.review_kind,
        'qoo10_urls', x.qoo10_urls, 'qoo10_at', x.qoo10_at, 'cosme_urls', x.cosme_urls, 'cosme_at', x.cosme_at))
        FROM public.campaign_report_ext_rows x JOIN public.campaign_report_sources s ON s.id = x.source_id
        WHERE s.report_id = r.id), '[]'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END; $$;

-- ------------------------------------------------------------
-- 실행 권한 — 관리자 6종: 로그인만 / 익명 2종: 🔴 anon 에 일부러 연다(두 방향 회수 뒤 GRANT)
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.enable_report_share(uuid, text, timestamptz)              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.disable_report_share(uuid)                                FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reset_report_share_password(uuid, text)                   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reveal_report_share_password(uuid)                        FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_report_share_settings(uuid, timestamptz, jsonb)    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_report_share_status(uuid)                             FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enable_report_share(uuid, text, timestamptz)           TO authenticated;
GRANT EXECUTE ON FUNCTION public.disable_report_share(uuid)                             TO authenticated;
GRANT EXECUTE ON FUNCTION public.reset_report_share_password(uuid, text)                TO authenticated;
GRANT EXECUTE ON FUNCTION public.reveal_report_share_password(uuid)                     TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_report_share_settings(uuid, timestamptz, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_report_share_status(uuid)                          TO authenticated;

REVOKE ALL ON FUNCTION public.verify_report_share_password(uuid, text) FROM PUBLIC, authenticated;
REVOKE ALL ON FUNCTION public.get_report_share_data(uuid, text)         FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.verify_report_share_password(uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_report_share_data(uuid, text)         TO anon, authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';

/* 검증(로그인 관리자 콘솔 · 비로그인 탭)
 1. 관리자: enable → status.token → (비로그인) verify 틀림 ×11 → 마지막 locked
 2. (비로그인) verify 맞음 → ticket → get_report_share_data(token, ticket) 응답 원문에
    'receipt_url' 키 0개 · 'email' 0개 · name_kanji 가 田中** 모양 · 다른 리포트 캠페인 0줄
 3. get_report_share_data(token, '아무거나') → null
 4. disable → get_report_share_data(token, 유효 ticket) → null (열람 표 삭제됨)
*/
