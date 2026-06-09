-- ============================================================
-- 175: 브랜드 병합 RPC (merge_brands)
--
-- 원본 브랜드(p_source)의 신청·캠페인을 정식 브랜드(p_target)로 이동하고
-- 채번을 p_target 기준으로 재발급(옛 번호 legacy_no 보존), 원본은 archived 처리.
-- 121 link_campaign_to_application 의 재채번 패턴(_accumulate_legacy_no +
-- numbering_legacy_map UPSERT + counter ON CONFLICT) 을 그대로 차용.
--
-- 이동 순서(채번 정합 필수):
--   ① source 신청 → p_target.brand_id + A-seq 재발급
--   ② ① 신청 파생 캠페인 → p_target.brand_id + C-seq 재발급 (B{t}-A{app}-C{new})
--   ③ source 외부 캠페인(source_application_id NULL) → p_target + 외부 C-seq (B{t}-C{new})
--   ④ 이동 campaigns.brand/brand_ja/brand_en → p_target 마스터값 (173 트리거 보완)
--   ⑤ p_source.status='archived'
--
-- 사양서: docs/specs/2026-06-09-brand-delete-merge.md (PR 2)
-- 의존: 088~090(채번), 121(_accumulate_legacy_no), 172·173(brand_ja/en), 174(delete_brand)
-- 롤백: DROP FUNCTION IF EXISTS public.merge_brands(uuid, uuid);
--   (※ 이미 실행된 병합은 함수 제거로 복원 안 됨 — 사전 스냅샷 필요)
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

  v_moved_apps      integer := 0;
  v_moved_campaigns integer := 0;
BEGIN
  -- 0. 권한 + 입력 검증
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)' USING ERRCODE = '42501';
  END IF;
  IF p_source IS NULL OR p_target IS NULL THEN
    RAISE EXCEPTION 'source_id 와 target_id 가 모두 필요합니다' USING ERRCODE = '22023';
  END IF;
  IF p_source = p_target THEN
    RAISE EXCEPTION '원본과 대상이 같은 브랜드입니다' USING ERRCODE = '22023';
  END IF;

  -- 1. 잠금 2단 (uuid 작은 쪽 먼저 — 데드락 회피)
  IF p_source < p_target THEN
    PERFORM pg_advisory_xact_lock(hashtext(p_source::text)::bigint);
    PERFORM pg_advisory_xact_lock(hashtext(p_target::text)::bigint);
  ELSE
    PERFORM pg_advisory_xact_lock(hashtext(p_target::text)::bigint);
    PERFORM pg_advisory_xact_lock(hashtext(p_source::text)::bigint);
  END IF;

  -- 2. 브랜드 행 조회 (FOR UPDATE)
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

  -- 3. 회사 검증 — 둘 다 회사 지정돼 있고 같아야 함.
  --    (회사 미지정 null 끼리는 "무관 브랜드"일 수 있어 병합 금지 — 회사 먼저 연결 유도)
  IF v_source.company_id IS NULL OR v_target.company_id IS NULL THEN
    RAISE EXCEPTION '회사가 지정되지 않은 브랜드는 병합할 수 없습니다. 먼저 회사를 연결하세요.'
      USING ERRCODE = '22023';
  END IF;
  IF v_source.company_id IS DISTINCT FROM v_target.company_id THEN
    RAISE EXCEPTION '원본과 대상의 소속 회사가 다릅니다 (company_id: % ≠ %)',
      v_source.company_id::text, v_target.company_id::text
      USING ERRCODE = '22023';
  END IF;

  -- 4. 멱등성 — source 이미 archived + 연결 0건이면 no-op
  IF v_source.status = 'archived'
     AND NOT EXISTS (SELECT 1 FROM public.brand_applications WHERE brand_id = p_source)
     AND NOT EXISTS (SELECT 1 FROM public.campaigns          WHERE brand_id = p_source)
  THEN
    RETURN jsonb_build_object(
      'source_id', p_source, 'target_id', p_target,
      'moved_apps', 0, 'moved_campaigns', 0,
      'source_archived', true, 'unchanged', true);
  END IF;

  -- 5. ① 신청 이동 + A-seq 재발급 (sync_brand_application_stats 트리거가 양쪽 집계 자동)
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

  -- 6. ② 신청 파생 캠페인 이동 + 재채번 (①로 신청 brand_id 이미 p_target)
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

  -- 7. ③ 외부 캠페인(source_application_id NULL) 이동 + 재채번
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

  -- 8. ④ 이동된(+기존) target 캠페인 비정규화 컬럼 동기화 (173 트리거 보완)
  UPDATE public.campaigns
     SET brand = v_target.name, brand_ja = v_target.name_ja, brand_en = v_target.name_en,
         updated_at = now()
   WHERE brand_id = p_target;

  -- 9. ⑤ 원본 보관 처리
  UPDATE public.brands SET status = 'archived' WHERE id = p_source;

  RETURN jsonb_build_object(
    'source_id', p_source, 'target_id', p_target,
    'moved_apps', v_moved_apps, 'moved_campaigns', v_moved_campaigns,
    'source_archived', true, 'unchanged', false);
END;
$$;

COMMENT ON FUNCTION public.merge_brands(uuid, uuid) IS
  '[175] 브랜드 병합. source 신청·캠페인을 target 으로 이동 + 채번 재발급(legacy_no 보존). 같은 company_id 강제. is_campaign_admin 가드. 121 패턴 재사용. 원본 archived.';

REVOKE ALL ON FUNCTION public.merge_brands(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.merge_brands(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.merge_brands(uuid, uuid) TO authenticated;

COMMIT;
