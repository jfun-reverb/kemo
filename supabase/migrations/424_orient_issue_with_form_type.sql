-- ============================================================
-- 424_orient_issue_with_form_type.sql
-- 2026-09-08 — 오리엔시트 단순화 재설계 1단계 · 마이그레이션 Ⓐ (작업 1)
--   사양서 docs/specs/2026-09-08-orient-sheet-simplify-and-quote.md §4-1 · §4-8 Ⓐ
--   작업표 docs/specs/2026-09-08-orient-sheet-simplify-and-quote-breakdown.md 작업 1
--
-- 무엇을 바꾸나
--   create_orient_sheet 에 형식·채널 인자를 더한다.
--     (p_brand_id uuid, p_application_id uuid DEFAULT NULL,
--      p_form_type text DEFAULT NULL, p_channel text DEFAULT NULL) RETURNS jsonb
--   · p_form_type 이 값을 가지면 → 새 구조로 발급: data.issued 를 심고 카드 1개를 미리 만들며
--     orient_sheets.form_type 칸에도 형식을 넣는다.
--   · p_form_type 이 NULL 이면 → 205 와 똑같이(옛 구조, issued 없음, cards 빈 배열).
--     ⚠️ 이 갈래는 「데이터베이스가 먼저 나가고 관리자 화면이 뒤에 나가는 전환 구간」에서
--     옛 화면의 2인자 호출을 살리기 위한 것이지 정식 경로가 아니다. 관리자 화면이 나가면
--     화면은 항상 형식을 보낸다.
--
-- 서버 검증(값이 있을 때만)
--   invalid_form_type : reviewer·seeding 외 전부 거부 — proxy_purchase(가구매)도 거부
--   channel_required  : seeding 인데 p_channel 이 비어 있음
--   invalid_channel   : 시딩 채널 5종(instagram_feed·instagram_reels·x·tiktok·youtube) 외
--   ⚠️ 시딩 채널 5종은 세 곳에 산다 — ①dev/sales/orient.html SEEDING_CHANNELS
--      ②dev/js/admin-orient.js OS_SEEDING_CHANNELS(작업 4) ③이 파일. 하나를 고치면 셋 다.
--
-- 🔴 인자 개수가 늘어 CREATE OR REPLACE 로는 안 된다 — 옛 2인자 함수를 DROP 한 뒤 새로
--    만든다. 그때 기존 실행 권한이 함께 사라지므로 같은 파일 안에서 다시 건다.
--    대상은 **authenticated** (익명 함수 3종의 anon 과 다르다 — 205 의 343~344줄, 작업표 stale ⑪).
--    anon 으로 잘못 걸면 누구나 오리엔시트를 발급할 수 있게 된다.
--
-- 반환 키는 205 그대로: success·id·token·token_expires_at·orient_no (+ 거부 시 reason).
--
-- 롤백
--   DROP FUNCTION IF EXISTS public.create_orient_sheet(uuid, uuid, text, text);
--   → 205 의 D 블록(CREATE OR REPLACE FUNCTION public.create_orient_sheet(uuid, uuid …))
--     + 권한 두 줄(REVOKE FROM PUBLIC / GRANT TO authenticated) 재실행.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.create_orient_sheet(uuid, uuid);

CREATE FUNCTION public.create_orient_sheet(
  p_brand_id        uuid,
  p_application_id  uuid DEFAULT NULL,
  p_form_type       text DEFAULT NULL,   -- [424] 'reviewer' | 'seeding' | NULL(옛 구조, 전환 구간 전용)
  p_channel         text DEFAULT NULL    -- [424] 시딩 채널 1개(5종). 리뷰어면 무시
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  -- 205 채번용 변수
  v_brand_seq     integer;
  v_brands_name   text;
  v_app_brand_id  uuid;
  v_brand_name    text;
  v_orient_seq    integer;
  v_orient_no     text;
  -- INSERT 용
  v_new_id        uuid;
  v_new_token     uuid;
  v_expires_at    timestamptz;
  v_init_data     jsonb;
  -- [424]
  v_form_type     text;      -- 정리된 형식(NULL = 옛 구조)
  v_channel       text;      -- 정리된 채널(시딩만)
  v_card          jsonb;     -- 발급 때 미리 만드는 카드 1개
BEGIN
  -- ── 권한 가드: campaign_manager 포함 전체 관리자 (205 와 동일) ──────────
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (관리자 로그인 필요)' USING ERRCODE = '42501';
  END IF;

  -- ── [424] 형식·채널 검증 — 값이 있을 때만. 빈 문자열은 NULL 로 본다 ──────
  v_form_type := NULLIF(btrim(COALESCE(p_form_type, '')), '');
  v_channel   := NULLIF(btrim(COALESCE(p_channel, '')), '');

  IF v_form_type IS NOT NULL THEN
    IF v_form_type NOT IN ('reviewer', 'seeding') THEN
      -- proxy_purchase(가구매)도 여기서 거부 — 새 구조에서는 가구매를 발급할 수 없다(§4-1)
      RETURN jsonb_build_object('success', false, 'reason', 'invalid_form_type');
    END IF;
    IF v_form_type = 'seeding' THEN
      IF v_channel IS NULL THEN
        RETURN jsonb_build_object('success', false, 'reason', 'channel_required');
      END IF;
      IF v_channel NOT IN ('instagram_feed', 'instagram_reels', 'x', 'tiktok', 'youtube') THEN
        RETURN jsonb_build_object('success', false, 'reason', 'invalid_channel');
      END IF;
    ELSE
      v_channel := NULL;   -- 리뷰어는 채널 개념이 없다 — 들어와도 버린다
    END IF;
  END IF;

  -- ── 브랜드 존재 검증 + brand_seq + brands.name 취득 (205 와 동일) ──────
  SELECT b.brand_seq, b.name
    INTO v_brand_seq, v_brands_name
    FROM public.brands b
   WHERE b.id = p_brand_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'brand_not_found');
  END IF;

  IF v_brand_seq IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'brand_seq_missing');
  END IF;

  -- ── brand.name prefill 결정 (205 와 동일) ─────────────────────────────
  IF p_application_id IS NOT NULL THEN
    SELECT ba.brand_id, ba.brand_name
      INTO v_app_brand_id, v_brand_name
      FROM public.brand_applications ba
     WHERE ba.id = p_application_id;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'reason', 'application_not_found');
    END IF;

    IF v_app_brand_id IS DISTINCT FROM p_brand_id THEN
      RETURN jsonb_build_object('success', false, 'reason', 'brand_mismatch');
    END IF;

    IF v_brand_name IS NULL OR v_brand_name = '' THEN
      v_brand_name := v_brands_name;
    END IF;
  ELSE
    v_brand_name := v_brands_name;
  END IF;

  -- ── 동시성 + 카운터 + orient_no (205 와 동일) ─────────────────────────
  PERFORM pg_advisory_xact_lock(hashtext(p_brand_id::text)::bigint);

  INSERT INTO public.brand_orient_counter (brand_id, last_seq)
  VALUES (p_brand_id, 1)
  ON CONFLICT (brand_id)
  DO UPDATE SET last_seq = public.brand_orient_counter.last_seq + 1
  RETURNING last_seq INTO v_orient_seq;

  IF v_orient_seq > 999 THEN
    RAISE EXCEPTION
      '[create_orient_sheet] O-seq 오버플로 (>999) for brand_id=%', p_brand_id
      USING ERRCODE = '22003';
  END IF;

  v_orient_no := 'B' || lpad(v_brand_seq::text, 4, '0')
              || '-O' || lpad(v_orient_seq::text, 3, '0');

  -- ── data 초기값 ───────────────────────────────────────────────────────
  IF v_form_type IS NULL THEN
    -- 옛 구조 (205 와 동일) — §15-11: {brand:{name,intro,official_accounts}, cards:[]}
    v_init_data := jsonb_build_object(
      'brand', jsonb_build_object(
        'name',              COALESCE(v_brand_name, ''),
        'intro',             '',
        'official_accounts', ''
      ),
      'cards', '[]'::jsonb
    );
  ELSE
    -- [424] 새 구조 (사양서 §4-1 JSON 그대로) — brand 에 intro·official_accounts 키 없음,
    --   카드 1개를 발급 때 미리 만든다(uid 는 첫 저장 때 서버가 붙인다 — 293).
    --   ⚠️ cards 배열은 그대로 둔다 — uid·메모·발행 표시·연결/해제·삭제가 전부 cards[i] 를 본다.
    IF v_form_type = 'seeding' THEN
      v_card := jsonb_build_object(
        'form_type', 'seeding',
        'product',   jsonb_build_object('name', '', 'slots', ''),
        'recruit',   jsonb_build_object('recruit_start', ''),
        'sale',      jsonb_build_object('market', 'Qoo10', 'url', '', 'price_regular', ''),
        'seeding',   jsonb_build_object(
                       'channels',       jsonb_build_array(v_channel),
                       'appeal',         '',
                       'hashtags',       '[]'::jsonb,
                       'account_tags',   '',
                       'shooting_guide', '',
                       'shipping_note',  ''
                     ),
        'ng',        '',
        'cautions',  '',
        'images',    '[]'::jsonb
      );
    ELSE
      v_card := jsonb_build_object(
        'form_type',    'reviewer',
        'product',      jsonb_build_object('name', '', 'slots', ''),
        'recruit',      jsonb_build_object('recruit_start', ''),
        'sale',         jsonb_build_object('market', 'Qoo10', 'url', '', 'price_regular', ''),
        'review_guide', '',
        'images',       '[]'::jsonb
      );
    END IF;

    v_init_data := jsonb_build_object(
      'issued', jsonb_strip_nulls(jsonb_build_object(
        'form_type', v_form_type,
        'channel',   v_channel,        -- 리뷰어는 NULL → strip 으로 키 자체가 빠진다
        'issued_at', now()
      )),
      'brand', jsonb_build_object(
        'name',         COALESCE(v_brand_name, ''),
        'contact_name', '',
        'email',        '',
        'phone',        ''
      ),
      'cards', jsonb_build_array(v_card)
    );
  END IF;

  -- ── INSERT (205 와 동일 — form_type 칸만 [424] 값 반영) ────────────────
  v_new_id     := gen_random_uuid();
  v_new_token  := gen_random_uuid();
  v_expires_at := now() + interval '30 days';

  INSERT INTO public.orient_sheets (
    id, brand_id, application_id, form_type, token, token_expires_at,
    created_by, status, data, version, orient_no
  ) VALUES (
    v_new_id, p_brand_id, p_application_id,
    v_form_type,          -- [424] 새 구조면 형식 사본(목록 필터·집계용), 옛 구조면 NULL(205 와 같음)
    v_new_token, v_expires_at, auth.uid(), 'draft', v_init_data, 0, v_orient_no
  );

  RETURN jsonb_build_object(
    'success',          true,
    'id',               v_new_id,
    'token',            v_new_token,
    'token_expires_at', v_expires_at,
    'orient_no',        v_orient_no
  );
END;
$$;

-- 🔴 DROP 으로 옛 권한이 사라졌다 — 같은 파일에서 다시 건다. 대상은 authenticated(anon 아님 — 205·stale ⑪)
REVOKE EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid, text, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.create_orient_sheet(uuid, uuid, text, text) IS
  '[195+205+424] 오리엔시트 발급. is_admin() 가드 — campaign_manager 포함 전체 관리자. '
  'p_brand_id 필수. p_application_id 선택(연결 시 brand_id 정합 + brand_name prefill). '
  '[424] p_form_type(reviewer|seeding) 이 있으면 새 구조: data.issued{form_type,channel,issued_at} + 카드 1개 미리 생성 + form_type 칸 기록. '
  '시딩은 p_channel 필수(instagram_feed|instagram_reels|x|tiktok|youtube). 거부 reason: invalid_form_type(proxy_purchase 포함)·channel_required·invalid_channel. '
  'p_form_type NULL 이면 205 와 같은 옛 구조(issued 없음, cards 빈 배열) — 전환 구간 전용. '
  'orient_no = B{brand_seq 4자리}-O{orient_seq 3자리} 자동 채번. token_expires_at = now()+30일, status=draft. '
  'SECURITY DEFINER + search_path 고정. 실행 권한 authenticated 만.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 적용 후)
-- ============================================================
-- [V1] 4인자 함수 1개만 남았는지
--   SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args, p.proacl::text
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE n.nspname='public' AND p.proname='create_orient_sheet';
--   -- 기대: 1행 (uuid, uuid, text, text). proacl 에 authenticated=X 있고, 맨 앞 =X/ 없음, anon 없음
--
-- [V2] 실제 호출은 관리자 로그인 브라우저 콘솔에서(is_admin 가드는 SQL 편집기로 재현 안 됨):
--   const b = (await db.from('brands').select('id').limit(1)).data[0].id;
--   await db.rpc('create_orient_sheet', {p_brand_id:b, p_application_id:null, p_form_type:'seeding', p_channel:'instagram_feed'})   // success, issued 값, cards 1
--   await db.rpc('create_orient_sheet', {p_brand_id:b, p_application_id:null})                                                          // success, issued 없음, cards []
--   await db.rpc('create_orient_sheet', {p_brand_id:b, p_application_id:null, p_form_type:'proxy_purchase'})                            // invalid_form_type
--   await db.rpc('create_orient_sheet', {p_brand_id:b, p_application_id:null, p_form_type:'seeding'})                                   // channel_required
--   await db.rpc('create_orient_sheet', {p_brand_id:b, p_application_id:null, p_form_type:'seeding', p_channel:'qoo10'})                // invalid_channel
--   ⚠️ 시험 발급한 시트는 관리자 화면 「삭제」로 지운다.
