-- ============================================================
-- 266_campaign_change_history_trigger.sql
-- 캠페인 전체 항목 변경 이력 PR 1 — 2/2 (기록 트리거)
-- 사양서: docs/specs/2026-07-27-campaign-full-change-history.md §4-5
--
-- 전제: 265_campaign_change_history_table.sql (표·화이트리스트·RLS) 이미 적용
--
-- 목적:
--   campaigns 가 AFTER UPDATE 될 때마다 265 의 화이트리스트 컬럼만 비교해
--   바뀐 컬럼마다 campaign_change_history 에 1행을 남긴다. 브라우저가 별도로
--   호출하는 방식(캠페인 이력 기존 record_caution_history 패턴)이 아니라
--   서버 트리거로 한 이유 — 사양서 §2-1 ⑥: 캠페인 저장은 성공했는데 이력
--   기록 호출만 실패해도 admin.js 는 console.warn 만 남기고 넘어가 감사 공백이
--   조용히 발생한다. 트리거는 캠페인 저장과 같은 트랜잭션이라 이 공백이 없다.
--
-- 구현 방식 — 화이트리스트를 배열 1개로 관리:
--   079(brand_application_history)는 추적 컬럼이 5개라 컬럼마다 IF 블록을
--   직접 나열했다. 이번엔 48개라 같은 방식이면 파일이 지나치게 길어지고
--   컬럼을 늘릴 때마다 IF 블록을 새로 베껴 써야 해 오타 위험이 커진다.
--   대신 v_fields 배열 1개(265 의 CHECK 제약과 정확히 같은 48개, 같은 순서)에
--   to_jsonb(NEW)/to_jsonb(OLD) 를 컬럼명으로 인덱싱해 비교하는 FOREACH 루프로
--   구현한다. 비교 결과(바뀐 컬럼만 INSERT)는 079 의 IS DISTINCT FROM 방식과
--   동일 — jsonb 추출값끼리 비교하므로 NULL ↔ NULL 은 "변경 없음"으로 취급된다.
--
--   ⚠️ v_fields 배열은 265 의 CHECK 제약 목록과 반드시 항목·순서가 일치해야
--   한다(순서 자체는 의미 없지만 목록이 어긋나면 CHECK 위반으로 INSERT 가
--   실패한다). 향후 추적 컬럼을 추가/제외할 때는 265(CHECK)와 이 배열을
--   같은 마이그레이션에서 함께 고칠 것.
--
-- change_source 판정 (사양서 §4-5 의사코드 그대로):
--   auth.uid() 가 NULL                    → 'system' (로그인 세션 밖 호출 — 서버 함수·SQL 직접 수정)
--   status 단독 변경(다른 화이트리스트 컬럼은 전부 그대로) AND
--     아래 3패턴 중 하나에 정확히 일치     → 'auto'
--       scheduled → active  이고 recruit_start   <= 오늘(JST)
--       active    → closed  이고 deadline        <  오늘(JST)
--       closed    → ended   이고 submission_end  <  오늘(JST)
--     (autoOpenCampaigns/autoCloseCampaigns/autoEndCampaigns, dev/lib/storage.js
--      189/211/234 는 실제로 {status: 'x'} 한 컬럼만 UPDATE 하므로 이 조건과
--      정확히 대응한다 — 사양서 §2-1 C1 「자동 전이 행위자 오기」 완화책)
--   그 외                                  → 'admin'
--   "오늘"은 이 서비스의 주 시장 시간대인 Asia/Tokyo(+09:00) 기준으로 판정한다
--   (release-timing.md 「법적 집행·시각 판정은 서버측 + 타임존 명시」 원칙과
--   프로젝트 관례(_yesterday_kst_window 등) 를 따름). recruit_start/deadline/
--   submission_end 는 모두 date 컬럼(시각 없는 달력 날짜)이라 이 판정은 「자동」
--   표시 라벨 용도의 추정치이며 신청 자격·차단 로직에는 관여하지 않는다.
--
-- 알려진 한계 (설계로 흡수하지 않고 사용자 결정으로 수용 — 사양서 §2-1 참조):
--   - 브랜드명 동기화 트리거(173)가 브랜드 1건 수정으로 캠페인 수십 개의
--     brand_ja/brand_en 를 일괄 UPDATE 하면 이력도 수십 행 함께 생긴다(§2-1 C2).
--     화이트리스트에서 brand_ja/brand_en 를 빼면 이 소음은 없앨 수 있지만
--     정상적인 캠페인 편집으로 브랜드명이 바뀐 경우도 함께 못 보게 되므로
--     이 마이그레이션에서는 배제하지 않는다(사양서 §4-4 에 이미 포함으로 확정).
--   - trg_block_closed_caution_participation(BEFORE UPDATE) 이 예외를 던지면
--     UPDATE 자체가 롤백되어 이 AFTER 트리거가 실행되지 않는다 — "차단된 시도"는
--     이력에 남지 않는다(의도된 정상 동작, §2-1 C5).
--
-- 운영 규칙 (문서화, 이 마이그레이션이 강제하지 않음):
--   데이터 정리용 일괄 UPDATE 마이그레이션을 campaigns 에 돌릴 때는 실행 전
--   `ALTER TABLE public.campaigns DISABLE TRIGGER trg_campaign_change_history;`
--   로 끄고, 완료 후 `ENABLE TRIGGER` 로 반드시 되돌린다(선례: 메모리
--   project_sydney_storage_url_migration). 배포 후에는 아래 검증 SQL [3]으로
--   트리거가 켜져 있는지(tgenabled='O') 주기적으로 확인.
--
-- 영향:
--   campaigns 의 기존 트리거 5종(trg_campaign_no / trg_block_closed_caution_
--   participation / trg_campaigns_first_active_at / trg_reject_pending_on_
--   campaign_end / trg_block_delete_with_settlements) 과 이벤트가 겹치지 않는다
--   (이 트리거만 AFTER UPDATE FOR EACH ROW, 조건 없음). BEFORE 트리거가 예외를
--   던지면 이 AFTER 트리거는 아예 실행되지 않는 것이 Postgres 표준 동작.
--
-- 롤백:
--   DROP TRIGGER IF EXISTS trg_campaign_change_history ON public.campaigns;
--   DROP FUNCTION IF EXISTS public.record_campaign_change_history();
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.record_campaign_change_history()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  -- 265 의 field_name CHECK 제약과 정확히 동일한 48개 (순서는 CHECK 와 달라도 무방하나
  -- 유지보수를 위해 그룹·순서를 그대로 맞춤).
  v_fields text[] := ARRAY[
    'title','brand_id','brand','brand_ko','brand_ja','brand_en','product','product_ko','product_url',
    'recruit_type','channel','channel_match','primary_channel','slots','min_followers','category','content_types',
    'product_price','reward','reward_note',
    'recruit_start','deadline','purchase_start','purchase_end','visit_start','visit_end','submission_end','winner_announce',
    'description','appeal','guide','hashtags','mentions',
    'img1','img2','img3','img4','img5','img6','img7','img8','image_url','image_crops',
    'status','proxy_purchase','source_application_id',
    'deleted_at','deleted_by'
  ];
  v_group_id      uuid := gen_random_uuid();
  v_actor_id      uuid := auth.uid();
  v_actor_name    text;
  v_new_json      jsonb := to_jsonb(NEW);
  v_old_json      jsonb := to_jsonb(OLD);
  v_field         text;
  v_status_changed boolean;
  v_other_changed  boolean;
  v_today_jst      date;
  v_source         text;
BEGIN
  -- 1) 변경자 이름 스냅샷 (admins 행이 나중에 삭제돼도 이력에 이름이 남도록)
  IF v_actor_id IS NOT NULL THEN
    SELECT name INTO v_actor_name
    FROM public.admins
    WHERE auth_id = v_actor_id
    LIMIT 1;
  END IF;

  -- 2) change_source 판정
  v_status_changed := (NEW.status IS DISTINCT FROM OLD.status);

  -- status 를 제외한 나머지 화이트리스트 컬럼 중 하나라도 바뀌었는지
  v_other_changed := EXISTS (
    SELECT 1
    FROM unnest(v_fields) AS f(name)
    WHERE f.name <> 'status'
      AND (v_new_json -> f.name) IS DISTINCT FROM (v_old_json -> f.name)
  );

  v_today_jst := (now() AT TIME ZONE 'Asia/Tokyo')::date;

  IF v_actor_id IS NULL THEN
    v_source := 'system';
  ELSIF v_status_changed AND NOT v_other_changed AND (
        (OLD.status = 'scheduled' AND NEW.status = 'active'
           AND NEW.recruit_start IS NOT NULL AND NEW.recruit_start <= v_today_jst)
     OR (OLD.status = 'active' AND NEW.status = 'closed'
           AND NEW.deadline IS NOT NULL AND NEW.deadline < v_today_jst)
     OR (OLD.status = 'closed' AND NEW.status = 'ended'
           AND NEW.submission_end IS NOT NULL AND NEW.submission_end < v_today_jst)
  ) THEN
    v_source := 'auto';
  ELSE
    v_source := 'admin';
  END IF;

  -- 3) 화이트리스트 컬럼을 하나씩 비교, 바뀐 것마다 1행 INSERT
  --    (아무 것도 안 바뀌면 루프가 한 번도 INSERT 하지 않음 — 사양서 §4-5 5))
  FOREACH v_field IN ARRAY v_fields LOOP
    IF (v_new_json -> v_field) IS DISTINCT FROM (v_old_json -> v_field) THEN
      INSERT INTO public.campaign_change_history (
        campaign_id, change_group_id, changed_by, changed_by_name,
        field_name, old_value, new_value, change_source
      ) VALUES (
        NEW.id, v_group_id, v_actor_id, v_actor_name,
        v_field, v_old_json -> v_field, v_new_json -> v_field, v_source
      );
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.record_campaign_change_history IS
  '[266] campaigns AFTER UPDATE 트리거. 265 화이트리스트(48개) 를 IS DISTINCT FROM 으로 '
  '비교해 바뀐 컬럼마다 campaign_change_history 에 1행 INSERT, 같은 UPDATE 는 change_group_id 로 묶음. '
  'SECURITY DEFINER — 클라이언트 RLS 우회하여 이력 기록.';

DROP TRIGGER IF EXISTS trg_campaign_change_history ON public.campaigns;

-- ⚠️ AFTER UPDATE **OF <컬럼목록>** — 화이트리스트 컬럼이 UPDATE 문에 언급될 때만 발화한다.
--    조회수(increment_campaign_view, 263)·신청 수(recompute_campaign_applied_count, 058)는
--    view_count / applied_count 단일 컬럼만 SET 하므로 트리거 자체가 안 돈다(인플루언서 트래픽
--    마다 to_jsonb 2회 + 48회 비교가 헛돌던 낭비 제거). 기존 관례와 동일(140·176이 OF status 사용).
--    ⚠️ 이 목록은 265 의 field_name CHECK · 위 v_fields 배열과 **항상 같은 집합**이어야 한다.
--       컬럼을 더하거나 뺄 때는 반드시 세 곳을 같은 마이그레이션에서 함께 고칠 것.
CREATE TRIGGER trg_campaign_change_history
  AFTER UPDATE OF
    title, brand_id, brand, brand_ko, brand_ja, brand_en, product, product_ko, product_url,
    recruit_type, channel, channel_match, primary_channel, slots, min_followers, category, content_types,
    product_price, reward, reward_note,
    recruit_start, deadline, purchase_start, purchase_end, visit_start, visit_end, submission_end, winner_announce,
    description, appeal, guide, hashtags, mentions,
    img1, img2, img3, img4, img5, img6, img7, img8, image_url, image_crops,
    status, proxy_purchase, source_application_id,
    deleted_at, deleted_by
  ON public.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public.record_campaign_change_history();

COMMIT;

-- ════════════════════════════════════════════════════════════
-- [검증 SQL] — 개발 서버에서 마이그레이션 적용 후 SQL Editor 에서 1단계씩 실행
-- ════════════════════════════════════════════════════════════
/*
-- 사전 준비: 검증용 캠페인 1건 확인 (status='active' 이고 caution/participation/ng 잠금
-- 트리거(156)에 안 걸리게 draft/scheduled/active 캠페인 권장)
SELECT id, title, status, slots, deadline FROM public.campaigns
WHERE status IN ('draft','scheduled','active') ORDER BY created_at DESC LIMIT 3;

-- [1] 모집 인원만 변경 → 이력 1행, field_name='slots' 기대
UPDATE public.campaigns SET slots = slots + 1 WHERE id = '<검증용_ID>';
SELECT field_name, old_value, new_value, change_source, change_group_id
FROM public.campaign_change_history WHERE campaign_id = '<검증용_ID>'
ORDER BY changed_at DESC LIMIT 5;
-- 기대값: 1행, field_name='slots', change_source='admin'(SQL Editor 는 서비스 role 이라 auth.uid() 는
-- NULL 이 될 수 있음 — 그 경우 change_source='system' 이 정상. 실제 관리자 화면 저장으로 재현 시 'admin' 확인)

-- [2] 제목 + 모집 마감일 + 상태 동시 변경 → 3행, 같은 change_group_id 기대
UPDATE public.campaigns
  SET title = title || ' (검증)', deadline = deadline + 1, status = 'active'
WHERE id = '<검증용_ID>';
SELECT field_name, change_group_id FROM public.campaign_change_history
WHERE campaign_id = '<검증용_ID>' ORDER BY changed_at DESC LIMIT 5;
-- 기대값: 3행(title/deadline/status), change_group_id 3행 모두 동일

-- [3] 트리거 켜짐 확인
SELECT tgname, tgenabled FROM pg_trigger
WHERE tgrelid = 'public.campaigns'::regclass AND tgname = 'trg_campaign_change_history';
-- 기대값: 1행, tgenabled='O'

-- [4] 추적 제외 컬럼(view_count)만 변경 → 이력 0행 기대
SELECT count(*) AS cnt_before FROM public.campaign_change_history WHERE campaign_id = '<검증용_ID>';
UPDATE public.campaigns SET view_count = view_count + 1 WHERE id = '<검증용_ID>';
SELECT count(*) AS cnt_after FROM public.campaign_change_history WHERE campaign_id = '<검증용_ID>';
-- 기대값: cnt_before = cnt_after

-- [5] 아무 값도 안 바뀌는 UPDATE(동일 값 재대입) → 이력 0행 기대
UPDATE public.campaigns SET title = title WHERE id = '<검증용_ID>';
SELECT count(*) AS cnt_after_noop FROM public.campaign_change_history WHERE campaign_id = '<검증용_ID>';
-- 기대값: cnt_after_noop = 위 [4] 의 cnt_after 와 동일(증가 없음)

-- [6] 자동 전이 패턴(예: active→closed, deadline 이 과거) 재현 — 검증용 캠페인의 deadline 을
-- 과거로 만든 뒤 storage.js autoCloseCampaigns 와 동일한 단일 컬럼 UPDATE 로 재현
UPDATE public.campaigns SET deadline = (now() AT TIME ZONE 'Asia/Tokyo')::date - 1
WHERE id = '<검증용_ID>' AND status = 'active';
UPDATE public.campaigns SET status = 'closed' WHERE id = '<검증용_ID>';
SELECT field_name, old_value, new_value, change_source FROM public.campaign_change_history
WHERE campaign_id = '<검증용_ID>' AND field_name = 'status' ORDER BY changed_at DESC LIMIT 1;
-- 기대값: change_source='auto' (SQL Editor 는 service_role 이라 auth.uid() 가 NULL 일 수 있어
-- 'system' 이 나올 수 있음 — 그 경우 실제 관리자 세션에서 dev/lib/storage.js 의
-- autoCloseCampaigns 경로로 재현해 'auto' 확인)

-- [7] 최고 관리자 아닌 계정으로 조회 시도 → 0건 (RLS 확인, 클라이언트 세션에서)
--   const { data } = await db.from('campaign_change_history').select('*').limit(5);
--   campaign_admin/campaign_manager 로그인 상태 → data === [] 기대
--   super_admin 로그인 상태 → N건 반환 기대

-- [8] 화면에서 이력 표에 직접 쓰기 시도 → 거부 (RLS 확인)
--   const { error } = await db.from('campaign_change_history').insert({...});
--   → error 발생(정책 없음 = 암묵 거부) 기대

-- 검증 데이터 정리(선택)
-- DELETE FROM public.campaign_change_history WHERE campaign_id = '<검증용_ID>';
*/
