-- 490_orient_create_recruit_fee_admin_only.sql
-- create_orient_sheet — 모집비 직접 지정(p_recruit_fee_krw)을 캠페인 관리자 이상으로 제한한다.
--
-- 🔴 베이스 **465**(190→192→195→205→424→447→465). 465 본문을 그대로 옮기고 is_admin() 가드 바로 뒤에
--    거부 한 블록(+ COMMENT 한 줄)만 더했다. 447 을 베이스로 잡으면 465 의 uid 심기가 사라진다.
--    인자 5개 불변이라 CREATE OR REPLACE(권한 보존) — 그래도 아래서 회수·부여를 다시 건다.
--
-- 왜: 사용자 결정 2026-10-01 — 모집비 직접 지정은 견적 금액을 좌우하므로 기준값 수정 권한(캠페인 관리자 이상)과 맞춘다.
--     전수조사 3차 ①-4. 이전에는 is_admin()(campaign_manager 포함)이면 누구나 지정할 수 있었다.
-- 거부 모양: {"success":false,"reason":"recruit_fee_forbidden"} — 465 의 다른 거부(invalid_recruit_fee 등)와 같다.
--   🔴 화면(admin-orient.js)이 이 reason 을 알아야 한다 — 모르면 일반 실패 문구로 덮인다(friendlyError 등록 확인).
--   🔴 화면에서 입력칸을 숨기는 것은 보안이 아니다 — 이 서버 가드가 유일한 방어선.
--
-- 롤백: 465_orient_issue_card_uid.sql 의 CREATE OR REPLACE FUNCTION 블록(+ REVOKE·GRANT·COMMENT)을 그대로 재실행.

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

  -- [490] 모집비 직접 지정은 캠페인 관리자 이상(기준값 수정 권한 update_quote_setting 과 맞춘다 — 사용자 결정 2026-10-01).
  --   campaign_manager 는 형식·채널만 정해 발급할 수 있고 모집비 직접 지정은 거부. 값 없음(NULL)은 통과.
  --   반환 모양은 이 함수의 다른 거부와 같다({success:false, reason}).
  IF p_recruit_fee_krw IS NOT NULL AND NOT public.is_campaign_admin() THEN
    RETURN jsonb_build_object('success', false, 'reason', 'recruit_fee_forbidden');
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
  '[195+205+424+447+465+490] 오리엔시트 발급. is_admin() 가드 — campaign_manager 포함 전체 관리자(단 [490] 모집비 직접 지정은 is_campaign_admin() 이상, 아니면 recruit_fee_forbidden). '
  'p_form_type(reviewer|seeding) 이 있으면 새 구조: data.issued{form_type,channel,issued_at[,recruit_fee_krw]} + 카드 1개 미리 생성 '
  '(465: 그 카드에 uid 도 넣는다 — 발급 직후부터 카드 메모 가능). '
  '[447] p_recruit_fee_krw(0 이상, NULL=기준값) → issued.recruit_fee_krw. '
  '실행 권한 authenticated 만. 🔴 다음 재정의의 베이스는 490.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ── 확인 (개발 DB 적용 후 — 한 단계씩) ──
-- [V1] 정의·권한 (기대: has_490=true, anon_exec=false, auth_exec=true, proacl 맨 앞이 '=X/' 가 아님)
--   SELECT position('[490]' in pg_get_functiondef('public.create_orient_sheet(uuid,uuid,text,text,bigint)'::regprocedure)) > 0 AS has_490,
--          md5(pg_get_functiondef('public.create_orient_sheet(uuid,uuid,text,text,bigint)'::regprocedure)) AS def_md5,
--          has_function_privilege('anon','public.create_orient_sheet(uuid,uuid,text,text,bigint)','EXECUTE') AS anon_exec,
--          has_function_privilege('authenticated','public.create_orient_sheet(uuid,uuid,text,text,bigint)','EXECUTE') AS auth_exec,
--          (SELECT p.proacl::text FROM pg_proc p WHERE p.oid='public.create_orient_sheet(uuid,uuid,text,text,bigint)'::regprocedure) AS proacl;
-- [V2] 🔴 관리자 가드 함수라 SQL 편집기로는 재현되지 않는다(서비스 키엔 로그인 사용자가 없다). 실제 로그인 브라우저 콘솔에서:
--   campaign_manager 로그인: db.rpc('create_orient_sheet',{p_brand_id:'<브랜드>',p_form_type:'reviewer',p_recruit_fee_krw:1000})
--     기대 {success:false, reason:'recruit_fee_forbidden'} (시트가 안 만들어진다)
--   campaign_manager 로그인, p_recruit_fee_krw 생략: 기대 success:true (발급은 그대로 된다)
--   campaign_admin 이상, p_recruit_fee_krw:0 / 1000: 기대 success:true, data.issued.recruit_fee_krw 에 값
--   시험으로 만든 시트는 관리자 화면 「삭제」로 지운다.
