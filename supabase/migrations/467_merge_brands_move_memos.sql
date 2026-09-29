-- ============================================================
-- 467_merge_brands_move_memos.sql
-- 2026-09-23
--
-- 목적:
--   브랜드를 병합할 때 원본 브랜드의 **영업 메모(brand_memos, 마이그레이션 466)**
--   를 대상 브랜드로 함께 옮긴다. 사용자 결정(2026-09-23) — 원본은 `archived` 로
--   보관되기만 해서, 메모를 그대로 두면 목록 상태 필터 때문에 사실상 다시 못 본다.
--
-- 사양서: docs/specs/2026-09-23-brand-memo-entries.md §3-B (결정 C)
--
-- 🔴 베이스는 **328**이다(175 가 아니다).
--   merge_brands 는 175 → 328 로 바뀌었고, 328 이 **오리엔시트 이동·멱등성 판정·
--   moved_orient_sheets 반환**을 더했다. 175 를 베이스로 잡으면 그것이 통째로 사라진다.
--   이 파일은 328 본문을 그대로 두고 네 곳만 더한다:
--     ①v_moved_memos 선언 ②멱등성 판정에 brand_memos ③메모 이동 UPDATE
--     ④반환값 moved_memos(no-op 반환에도 같이)
--
-- ⚠️ 되돌릴 수 없는 함수다 — 개발서버에서 **실제 병합을 한 번 돌려** 확인한 뒤 운영에 넣는다.
--   「적용 성공」은 검증이 아니다(함수 본문의 칸 참조는 첫 호출에서 터진다).
--
-- 롤백: 마이그레이션 328 의 함수 정의를 그대로 다시 실행하면 이 변경만 되돌아간다
--       (이미 옮겨진 메모는 되돌아가지 않는다 — 병합 자체가 되돌릴 수 없다).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.merge_brands(
  p_source uuid,
  p_target uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_source        record;
  v_target        record;

  v_app           record;
  v_old_app_no    text;
  v_new_app_seq   integer;
  v_new_app_no    text;

  v_camp          record;
  v_old_camp_no   text;
  v_new_camp_no   text;
  v_app_seq_parsed integer;
  v_new_camp_seq  integer;
  v_new_ext_seq   integer;
  v_new_app_no_for_camp text;

  v_moved_apps         integer := 0;
  v_moved_campaigns    integer := 0;
  v_moved_orient_sheets integer := 0;  -- [328, I-5]
  v_moved_memos        integer := 0;  -- [467] 영업 메모(brand_memos)
BEGIN
  -- 0. 권한 + 입력 검증 (175 원본과 동일)
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)' USING ERRCODE = '42501';
  END IF;
  IF p_source IS NULL OR p_target IS NULL THEN
    RAISE EXCEPTION 'source_id 와 target_id 가 모두 필요합니다' USING ERRCODE = '22023';
  END IF;
  IF p_source = p_target THEN
    RAISE EXCEPTION '원본과 대상이 같은 브랜드입니다' USING ERRCODE = '22023';
  END IF;

  -- 1. 잠금 2단 (uuid 작은 쪽 먼저 — 데드락 회피) (175 원본과 동일)
  IF p_source < p_target THEN
    PERFORM pg_advisory_xact_lock(hashtext(p_source::text)::bigint);
    PERFORM pg_advisory_xact_lock(hashtext(p_target::text)::bigint);
  ELSE
    PERFORM pg_advisory_xact_lock(hashtext(p_target::text)::bigint);
    PERFORM pg_advisory_xact_lock(hashtext(p_source::text)::bigint);
  END IF;

  -- 2. 브랜드 행 조회 (FOR UPDATE) (175 원본과 동일)
  SELECT id, name, name_ja, name_en, company_id, brand_seq, status
    INTO v_source FROM public.brands WHERE id = p_source FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '원본 브랜드를 찾을 수 없습니다: %', p_source USING ERRCODE = '22023';
  END IF;

  SELECT id, name, name_ja, name_en, company_id, brand_seq, status
    INTO v_target FROM public.brands WHERE id = p_target FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '대상 브랜드를 찾을 수 없습니다: %', p_target USING ERRCODE = '22023';
  END IF;

  -- 3. 회사 검증 없음 (175 원본과 동일, 무변경)

  -- [328, I-5] 4. 멱등성 — source 이미 archived + 연결 0건(신청·캠페인·오리엔시트
  --   모두)이면 no-op. orient_sheets 를 새로 추가한 것이 이 파일의 핵심 변경점 —
  --   위 파일 상단 "멱등성 체크에 orient_sheets 추가(필수)" 참고.
  IF v_source.status = 'archived'
     AND NOT EXISTS (SELECT 1 FROM public.brand_applications WHERE brand_id = p_source)
     AND NOT EXISTS (SELECT 1 FROM public.campaigns          WHERE brand_id = p_source)
     AND NOT EXISTS (SELECT 1 FROM public.orient_sheets      WHERE brand_id = p_source)
     -- [467] 메모만 남은 보관 브랜드가 재호출에서 안 옮겨지는 함정을 막는다(328 이 오리엔시트에서 겪은 것과 같다)
     AND NOT EXISTS (SELECT 1 FROM public.brand_memos       WHERE brand_id = p_source)
  THEN
    RETURN jsonb_build_object(
      'source_id', p_source, 'target_id', p_target,
      'moved_apps', 0, 'moved_campaigns', 0, 'moved_orient_sheets', 0, 'moved_memos', 0,
      'source_archived', true, 'unchanged', true);
  END IF;

  -- 5. ① 신청 이동 + A-seq 재발급 (175 원본과 동일)
  FOR v_app IN
    SELECT id, application_no, legacy_no
      FROM public.brand_applications
     WHERE brand_id = p_source
     ORDER BY created_at
  LOOP
    v_old_app_no := v_app.application_no;

    INSERT INTO public.brand_application_counter (brand_id, last_seq)
    VALUES (p_target, 1)
    ON CONFLICT (brand_id)
    DO UPDATE SET last_seq = public.brand_application_counter.last_seq + 1
    RETURNING last_seq INTO v_new_app_seq;

    IF v_new_app_seq > 999 THEN
      RAISE EXCEPTION 'A-seq 오버플로 (>999): target brand_id=%', p_target USING ERRCODE = '22003';
    END IF;

    v_new_app_no := 'B' || lpad(v_target.brand_seq::text, 4, '0')
                 || '-A' || lpad(v_new_app_seq::text, 3, '0');

    UPDATE public.brand_applications
       SET brand_id = p_target,
           application_no = v_new_app_no,
           legacy_no = public._accumulate_legacy_no(v_app.legacy_no, v_old_app_no)
     WHERE id = v_app.id;

    INSERT INTO public.numbering_legacy_map (entity_type, entity_id, legacy_no, new_no, migrated_at)
    VALUES ('brand_application', v_app.id, COALESCE(v_app.legacy_no, v_old_app_no), v_new_app_no, now())
    ON CONFLICT (entity_type, entity_id)
    DO UPDATE SET new_no = EXCLUDED.new_no, migrated_at = now();

    v_moved_apps := v_moved_apps + 1;
  END LOOP;

  -- 6. ② 신청 파생 캠페인 이동 + 재채번 (175 원본과 동일)
  FOR v_camp IN
    SELECT c.id, c.campaign_no, c.legacy_no, c.source_application_id
      FROM public.campaigns c
      JOIN public.brand_applications ba ON ba.id = c.source_application_id
     WHERE ba.brand_id = p_target
       AND c.brand_id  = p_source
     ORDER BY c.created_at
  LOOP
    v_old_camp_no := v_camp.campaign_no;

    SELECT application_no INTO v_new_app_no_for_camp
      FROM public.brand_applications WHERE id = v_camp.source_application_id;

    IF v_new_app_no_for_camp SIMILAR TO 'B[0-9]{4}-A[0-9]{3}' THEN
      v_app_seq_parsed := split_part(v_new_app_no_for_camp, '-A', 2)::integer;
    ELSE
      RAISE EXCEPTION '신청번호 형식이 예상과 다릅니다: % (기대값 B####-A###)', v_new_app_no_for_camp
        USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.application_campaign_counter (application_id, last_seq)
    VALUES (v_camp.source_application_id, 1)
    ON CONFLICT (application_id)
    DO UPDATE SET last_seq = public.application_campaign_counter.last_seq + 1
    RETURNING last_seq INTO v_new_camp_seq;

    IF v_new_camp_seq > 999 THEN
      RAISE EXCEPTION 'C-seq 오버플로 (>999): application_id=%', v_camp.source_application_id USING ERRCODE = '22003';
    END IF;

    v_new_camp_no := 'B' || lpad(v_target.brand_seq::text, 4, '0')
                  || '-A' || lpad(v_app_seq_parsed::text, 3, '0')
                  || '-C' || lpad(v_new_camp_seq::text, 3, '0');

    UPDATE public.campaigns
       SET brand_id = p_target,
           campaign_no = v_new_camp_no,
           legacy_no = public._accumulate_legacy_no(v_camp.legacy_no, v_old_camp_no),
           updated_at = now()
     WHERE id = v_camp.id;

    INSERT INTO public.numbering_legacy_map (entity_type, entity_id, legacy_no, new_no, migrated_at)
    VALUES ('campaign', v_camp.id, COALESCE(v_camp.legacy_no, v_old_camp_no), v_new_camp_no, now())
    ON CONFLICT (entity_type, entity_id)
    DO UPDATE SET new_no = EXCLUDED.new_no, migrated_at = now();

    v_moved_campaigns := v_moved_campaigns + 1;
  END LOOP;

  -- 7. ③ 외부 캠페인(source_application_id NULL) 이동 + 재채번 (175 원본과 동일)
  FOR v_camp IN
    SELECT id, campaign_no, legacy_no
      FROM public.campaigns
     WHERE brand_id = p_source AND source_application_id IS NULL
     ORDER BY created_at
  LOOP
    v_old_camp_no := v_camp.campaign_no;

    INSERT INTO public.brand_external_campaign_counter (brand_id, last_seq)
    VALUES (p_target, 1)
    ON CONFLICT (brand_id)
    DO UPDATE SET last_seq = public.brand_external_campaign_counter.last_seq + 1
    RETURNING last_seq INTO v_new_ext_seq;

    IF v_new_ext_seq > 999 THEN
      RAISE EXCEPTION '외부 C-seq 오버플로 (>999): target brand_id=%', p_target USING ERRCODE = '22003';
    END IF;

    v_new_camp_no := 'B' || lpad(v_target.brand_seq::text, 4, '0')
                  || '-C' || lpad(v_new_ext_seq::text, 3, '0');

    UPDATE public.campaigns
       SET brand_id = p_target,
           campaign_no = v_new_camp_no,
           legacy_no = public._accumulate_legacy_no(v_camp.legacy_no, v_old_camp_no),
           updated_at = now()
     WHERE id = v_camp.id;

    INSERT INTO public.numbering_legacy_map (entity_type, entity_id, legacy_no, new_no, migrated_at)
    VALUES ('campaign', v_camp.id, COALESCE(v_camp.legacy_no, v_old_camp_no), v_new_camp_no, now())
    ON CONFLICT (entity_type, entity_id)
    DO UPDATE SET new_no = EXCLUDED.new_no, migrated_at = now();

    v_moved_campaigns := v_moved_campaigns + 1;
  END LOOP;

  -- [328, I-5] 7-2. 오리엔시트 이동 — brand_id 만 옮긴다(재채번 없음, 위 파일
  --   상단 "orient_no 를 재채번하지 않는 이유" 참고). 캠페인·신청 이동이 모두
  --   끝난 뒤에 옮기지만, 사실 순서와 무관하게 안전하다(orient_sheets 는 다른
  --   테이블의 이동 로직에 값을 공급하지도, 그로부터 값을 받지도 않는다 —
  --   application_id 참조는 이미 ①에서 옮겨진 brand_applications.id 를 그대로
  --   가리키므로 무변경으로 계속 유효하다).
  UPDATE public.orient_sheets
     SET brand_id   = p_target,
         updated_at = now()
   WHERE brand_id = p_source;
  GET DIAGNOSTICS v_moved_orient_sheets = ROW_COUNT;

  -- 8. ④ 이동된(+기존) target 캠페인 비정규화 컬럼 동기화 (175 원본과 동일)
  UPDATE public.campaigns
     SET brand = v_target.name, brand_ja = v_target.name_ja, brand_en = v_target.name_en,
         updated_at = now()
   WHERE brand_id = p_target;

  -- 9. ⑤ 원본 보관 처리 (175 원본과 동일)
  -- [467] 영업 메모를 대상 브랜드로 옮긴다(사용자 결정 2026-09-23).
  --   🔴 본문 앞에 **어느 브랜드 시절 글인지**를 남긴다 — 안 남기면 두 브랜드 기록이 한 줄에 섞여
  --      나중에 구분할 방법이 없다. 되돌릴 수 없는 함수라 이 표시가 유일한 단서다.
  --   ⚠️ author_id·author_name 은 **그대로 둔다**(누가 썼는지는 병합과 무관하다).
  --   ⚠️ 이미 표시가 붙은 글에는 또 붙이지 않는다(두 번 병합된 브랜드에서 접두가 겹친다).
  --   ⚠️ updated_at 트리거가 돌아 「수정됨」으로 보이는 것은 감수한다 — 본문이 실제로 바뀌기 때문이다.
  UPDATE public.brand_memos
     SET brand_id  = p_target,
         body_html = CASE
           WHEN body_html LIKE '<p>(구 %' THEN body_html
           ELSE '<p>(구 ' || COALESCE(v_source.name, '이름 없음') || ')</p>' || body_html
         END
   WHERE brand_id = p_source;
  GET DIAGNOSTICS v_moved_memos = ROW_COUNT;

  UPDATE public.brands SET status = 'archived' WHERE id = p_source;

  RETURN jsonb_build_object(
    'source_id', p_source, 'target_id', p_target,
    'moved_apps', v_moved_apps, 'moved_campaigns', v_moved_campaigns,
    'moved_orient_sheets', v_moved_orient_sheets,  -- [328, I-5] 신규
    'moved_memos', v_moved_memos,                  -- [467] 신규
    'source_archived', true, 'unchanged', false);
END;
$$;

COMMENT ON FUNCTION public.merge_brands(uuid, uuid) IS
  '[467] 브랜드 병합 — 신청·캠페인·오리엔시트·영업 메모를 대상 브랜드로 옮기고 채번을 재발급한다. '
  '원본은 archived. is_campaign_admin 가드. 멱등성 판정에 brand_applications·campaigns·'
  'orient_sheets·brand_memos 존재 여부를 모두 본다(328 + 467). '
  '메모는 본문 앞에 「(구 원본브랜드명)」 을 붙여 어느 브랜드 시절 글인지 남긴다.';

COMMIT;

-- ============================================================
-- [적용 뒤 확인 — 개발서버에서 실제로 한 번 돌려 본다]
--   -- ① 시험용 브랜드 둘을 만들고 원본에 메모를 하나 남긴 뒤
--   -- ② SELECT public.merge_brands('<원본id>', '<대상id>');
--   --    → moved_memos 가 1 이고, 대상 브랜드 메모 본문 앞에 「(구 …)」 가 붙는다
--   -- ③ 같은 호출을 한 번 더 → unchanged:true (멱등)
-- ============================================================
