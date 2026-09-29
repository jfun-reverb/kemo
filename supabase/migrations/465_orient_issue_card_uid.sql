-- 465_orient_issue_card_uid.sql
-- 새 구조 오리엔시트 발급 때 미리 만드는 카드에 고유 번호(uid)를 넣는다.
--
-- 🔴 베이스 **447**(190→192→195→205→424→447). 그 파일의 함수 본문을 그대로 옮기고 두 줄(카드 둘의 'uid')과
--    주석만 더했다. 인자는 그대로(5개)라 CREATE OR REPLACE — 447 이 건 실행 권한이 보존된다(그래도 아래서 다시 건다).
--
-- 왜: 카드별 내부 메모는 카드 uid 에 붙는데(297), 새 구조는 카드를 발급 때 만들면서 uid 를 안 넣어
--     브랜드가 처음 저장하기 전까지 관리자 상세가 「고유 번호가 없어 메모를 남길 수 없습니다」였다.
-- 형식은 저장 함수 293 `_orient_apply_card_uids` 와 같다(replace(gen_random_uuid()::text,'-','')).
-- 첫 저장 때 293 ①「있으면 유지」로 그대로 이어지고, ②「개수 같으면 물려받기」와도 충돌하지 않는다.
-- 이미 발급된 시트는 첫 저장 때 붙으므로 백필하지 않는다.
-- 옛 구조 발급(p_form_type NULL — 카드 0개)은 변화 없음.
--
-- 롤백: 447 의 CREATE FUNCTION 블록을 CREATE OR REPLACE 로 바꿔 재실행.

BEGIN;

CREATE OR REPLACE FUNCTION public.create_orient_sheet(
  p_brand_id        uuid,
  p_application_id  uuid DEFAULT NULL,
  p_form_type       text DEFAULT NULL,   -- [424] 'reviewer' | 'seeding' | NULL(옛 구조, 전환 구간 전용)
  p_channel         text DEFAULT NULL,   -- [424] 시딩 채널 1개(5종). 리뷰어면 무시
  p_recruit_fee_krw bigint DEFAULT NULL  -- [447] 이 시트만 모집비(리뷰어)·진행비(시딩)를 1건당 이 값으로. NULL = 기준값의 구간 단가
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

  -- [447] 모집비 직접 지정 — 0 이상만. 🔴 0 은 허용한다(무료 진행) — 「비움(기준값)」과 「0(공짜)」은 다른 뜻이라 **키의 유무**로 가른다.
  --   옛 구조(형식 없음) 발급에는 issued 가 없어 담을 자리가 없다 → 값이 와도 버린다(아래 v_form_type 분기).
  IF p_recruit_fee_krw IS NOT NULL AND p_recruit_fee_krw < 0 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_recruit_fee');
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
    --   카드 1개를 발급 때 미리 만든다. [465] uid 도 발급 때 넣는다 — 293 과 같은 모양(하이픈 뺀 uuid).
    --   예전엔 첫 저장 때 붙어서, 브랜드가 저장하기 전에는 관리자가 카드 메모를 남길 수 없었다.
    --   첫 저장 때는 293 ①「있으면 유지」로 그대로 이어진다.
    --   ⚠️ cards 배열은 그대로 둔다 — uid·메모·발행 표시·연결/해제·삭제가 전부 cards[i] 를 본다.
    IF v_form_type = 'seeding' THEN
      v_card := jsonb_build_object(
        'uid',       replace(gen_random_uuid()::text, '-', ''),   -- [465]
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
        'uid',          replace(gen_random_uuid()::text, '-', ''),   -- [465]
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
        'issued_at', now(),
        -- [447] NULL 이면 strip 으로 키 자체가 빠진다 = 기준값의 구간 단가. 0 은 숫자라 남는다.
        --   issued 아래라 445(=425)의 서버 키 보존이 그대로 지켜 준다 — 브랜드 폼이 덮어쓰지 못한다.
        --   읽는 곳: _orient_compute_quote(443) 의 v_override
        'recruit_fee_krw', p_recruit_fee_krw
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

REVOKE EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid, text, text, bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid, text, text, bigint) FROM anon;
GRANT  EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid, text, text, bigint) TO authenticated;

COMMENT ON FUNCTION public.create_orient_sheet(uuid, uuid, text, text, bigint) IS
  '[195+205+424+447+465] 오리엔시트 발급. is_admin() 가드 — campaign_manager 포함 전체 관리자. '
  'p_form_type(reviewer|seeding) 이 있으면 새 구조: data.issued{form_type,channel,issued_at[,recruit_fee_krw]} + 카드 1개 미리 생성 '
  '(465: 그 카드에 uid 도 넣는다 — 발급 직후부터 카드 메모 가능). '
  '[447] p_recruit_fee_krw(0 이상, NULL=기준값) → issued.recruit_fee_krw. '
  '실행 권한 authenticated 만. 🔴 다음 재정의의 베이스는 465.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ── 확인 ──
-- [V0] 정의에 uid 가 들어갔는지(SQL 편집기):
--   SELECT position('[465]' in pg_get_functiondef('public.create_orient_sheet(uuid,uuid,text,text,bigint)'::regprocedure)) > 0 AS has_uid,
--          has_function_privilege('anon','public.create_orient_sheet(uuid,uuid,text,text,bigint)','EXECUTE') AS anon_exec,
--          has_function_privilege('authenticated','public.create_orient_sheet(uuid,uuid,text,text,bigint)','EXECUTE') AS auth_exec;
--   -- 기대: true / false / true
-- [V1] 관리자 로그인 브라우저: 발급 → 그 시트 data.cards[0].uid 가 32자, 상세 모달에서 바로 메모를 남길 수 있다.
--   시험으로 만든 시트는 관리자 화면 「삭제」로 지운다.
