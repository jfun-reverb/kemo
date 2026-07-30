-- ============================================================
-- 275_campaigns_version_optimistic_lock.sql
-- 캠페인 편집 동시 저장 방어(낙관적 락) — version 컬럼 신설
-- 사양서: docs/specs/2026-07-29-deadline-server-enforcement.md 「남은 백로그」
--
-- 문제:
--   campaigns 에는 version 컬럼이 없다(광고주 신청 052 · 결과물 035 · 정산 217 에는
--   있음). 관리자 두 명이 같은 캠페인을 동시에 편집·저장하면 나중 저장이 앞 저장을
--   조용히 덮는다. 2026-07-29 마감일 변경 확인창(2026-07-30 admin.js saveCampaignEdit)은
--   "편집 화면을 열었을 때의 마감일" 을 기준으로 판정하므로 이 위험을 그대로 탄다.
--   ⚠️ migration 121 이 이미 "사양서의 version 낙관적 락은 campaigns.version 컬럼이
--   없어 advisory lock 단독으로 대체" 라고 남겨둔 미해결 항목 — 이번에 해소한다.
--
-- ────────────────────────────────────────────────────────────
-- 설계 판단 1 — 버전을 누가·언제 올리는가: "노이즈 제외 목록"(denylist) 방식 채택
-- ────────────────────────────────────────────────────────────
--   campaigns 를 UPDATE 하는 경로를 전수 조사(2026-07-30, 아래 근거는 실제 코드 확인):
--     ① 편집 폼 저장 — dev/js/admin.js saveCampaignEdit → dev/lib/storage.js
--        updateCampaign() (admin.js:2267). title/brand/product/기간/리워드/이미지 등
--        전체 편집 필드 + 주의사항·참여방법·NG 스냅샷을 한 번에 SET.
--     ② 상태 드롭다운 변경 — changeCampStatus (admin.js:3122) → updateCampaign()
--        (status[+지금마감 시 deadline] 만 SET, updated_at 은 updateCampaign() 이 항상 추가)
--     ③ 순서 변경(드래그) — moveCampOrder (admin.js:3164-3165) → updateCampaign()
--        (order_index 만 SET, updated_at 은 역시 wrapper 가 항상 추가)
--     ④ 조회수 +1 — increment_campaign_view() RPC (263) — view_count 단일 컬럼만
--        SET, updated_at 미포함, 관리자 아닌 인플루언서·비로그인이 초 단위로 호출
--     ⑤ 신청 수 재계산 — recompute_campaign_applied_count() (058, 179 로 감사용 제외
--        보강) — applied_count 단일 컬럼만 SET, applications 상태 변경마다 트리거 발화
--     ⑥ 자동 상태 전이 — autoOpenCampaigns/autoCloseCampaigns/autoEndCampaigns
--        (storage.js:176-240) — status 단일 컬럼만 SET(updateCampaign() 미경유,
--        updated_at 없음), 목록 조회(fetchCampaigns) 때마다 대상 여부 확인
--     ⑦ 노출 토글 — toggleCampaignVisibility (storage.js:246-265) — status 단일
--        컬럼(updateCampaign() 미경유)
--     ⑧ 캠페인↔신청 연결/해제 — link/unlink_campaign_to_application (121) —
--        source_application_id/brand_id/campaign_no/legacy_no/updated_at SET,
--        advisory_xact_lock 으로 이미 직렬화되어 있음(위 문제 설명 참조)
--     ⑨ 브랜드 병합 — merge_brands (175) — brand_id/brand/brand_ja/brand_en/
--        campaign_no/legacy_no/updated_at SET(대상 브랜드 소속 캠페인 다건 일괄)
--     ⑩ 브랜드명 동기화 — trg_brands_sync_campaigns (173) — brand/brand_ja/brand_en/
--        updated_at SET(브랜드 1건 수정 시 소속 캠페인 다건 일괄, AFTER UPDATE 트리거)
--     ⑪ 보관 삭제/복구 — soft_delete_campaign/restore_campaign (255/256) —
--        deleted_at/deleted_by 만 SET, 자체 FOR UPDATE 행 잠금 + 멱등 가드 보유
--     ⑫ 완전 삭제 — purge_campaign (257) — DELETE 라 UPDATE 아님, version 무관
--     ⑬ 그 외 069/089/097/110/172/179/193 등은 전부 1회성 데이터 정리 마이그레이션
--        (이미 적용 완료, 향후 재실행 없음 — 현재·향후 동시성 위협과 무관)
--
--   ④⑤⑥⑦(조회수·신청수·자동전이·노출토글)은 관리자의 "편집 의도" 와 무관하게
--   실사용 트래픽마다 자동으로 도는 시스템성 갱신이라, 이것들이 version 을 올리면
--   관리자가 편집 화면을 잠깐만 열어둬도(조회수 1회만 올라가도!) 저장이 매번
--   "충돌" 로 거부되어 실사용이 불가능해진다. 반대로 ①②③⑧⑨⑩⑪(편집 저장·상태
--   변경·순서·연결변경·브랜드 병합/동기화·보관삭제)은 전부 관리자가 실제로 이
--   캠페인 행의 내용을 바꾸는 행위이므로, 이 행위들이 겹치면 정확히 우리가 막고
--   싶은 "나중 저장이 앞 저장을 덮는" 상황이다.
--
--   ⇒ 두 방식을 저울질했다:
--     (A) 허용 목록(allowlist) — 265/266(campaign_change_history) 이 이미 쓰는
--         "48개 컬럼 화이트리스트" 를 그대로 재사용해 BEFORE UPDATE OF <48개> 로
--         트리거를 스코프. 266 의 주석이 이미 세 곳(265 CHECK·266 v_fields 배열·
--         266 트리거 OF 목록)을 항상 맞춰야 한다고 경고하는데, 이 방식은 그 목록을
--         "네 번째 장소"에 또 복제해야 한다. 게다가 캠페인 편집 폼이 실제로 SET
--         하는 caution_set_id/caution_items/participation_set_id/participation_steps/
--         ng_set_id/ng_items 는 265 가 의도적으로 48개에서 뺐다(campaign_caution_history
--         병존 설계) — 지금은 편집 폼이 이 필드들을 항상 다른 48개-컬럼과 같은
--         UPDATE 문에 묶어 보내므로 트리거가 우연히 함께 발화하지만, 앞으로
--         "번들만 저장" 같은 독립 경로가 생기면 그 저장은 버전 보호를 못 받는
--         구멍이 생긴다(허용 목록은 새 컬럼·새 저장경로에 대해 기본이 "보호 안 함"
--         — fail-open).
--     (B) 제외 목록(denylist) — 이번 마이그레이션이 채택. BEFORE UPDATE 를 컬럼
--         스코프 없이(모든 UPDATE 문에서) 발화시키되, 함수 내부에서 "조회수·
--         신청수·순서·자동수정일·최초게시시각·버전 자체" 6개 컬럼만 비교에서
--         제외하고 나머지가 하나라도 달라지면 버전을 올린다. 새 컬럼이
--         campaigns 에 추가되면 자동으로 "보호 대상" 에 포함된다(fail-closed —
--         명시적으로 제외 목록에 넣지 않는 한 안전한 쪽으로 동작). 유지보수
--         지점이 6개짜리 제외 목록 하나뿐이라 265/266 의 48개 목록과 별개로
--         관리된다(다른 목적: 265/266 은 "무엇을 감사에 남길지" 결정, 이 목록은
--         "무엇이 편집 충돌과 무관한 시스템 갱신인지" 결정 — 같은 48개를 재사용할
--         근거가 약하다).
--     성능: (B) 는 조회수·신청수 갱신 때도 매번 to_jsonb() 2회 + jsonb 비교 1회가
--     도는데, 단일 행 UPDATE 에서 수십 마이크로초 수준이라 이 프로젝트 트래픽
--     규모(캠페인당 일 조회수 수십~수백 단위)에서는 무의미한 비용이다. 266 이
--     "낭비 제거" 목적으로 OF 스코프를 쓴 것과는 트리거의 목적 자체가 다르다
--     (266 은 48개 컬럼 각각을 순회하며 이력 행을 만드는 무거운 루프라 스코프가
--     의미 있었고, 이 트리거는 O(1) 비교 1번뿐이다).
--   ⇒ (B) 채택. 위 ①②③⑧⑨⑩⑪ 은 모두 제외 6개 중 하나만 SET 하는 경우가 없거나
--     (①⑧⑨⑩은 항상 다른 실질 컬럼과 함께 SET), 제외 6개 중 하나만 SET 하더라도
--     그 자체가 실질 변경(②③⑪) 이라 자동으로 버전이 오른다 — 상세 근거는 각 항목:
--       ②: status(+deadline) SET, 어느 쪽도 제외 6개가 아님 → 버전 상승(의도됨 —
--          관리자가 화면에서 상태를 드롭다운으로 바꾸는 동안 편집 폼이 열려
--          있었다면, 편집 폼의 저장은 이 변경을 되돌리면 안 되므로 충돌 처리돼야 함)
--       ③: order_index 만 SET → 제외 목록에 있어 버전 유지(편집 폼은 order_index
--          를 다루지 않으므로 순서 변경이 편집 폼 저장과 겹쳐도 데이터 훼손 없음)
--       ⑧⑨⑩: source_application_id/brand_id/brand/brand_ja/brand_en 중 최소 하나는
--          항상 SET 되고 전부 제외 목록 밖 → 버전 상승(의도됨 — 편집 폼이 이
--          필드들의 옛 값을 그대로 되돌려 저장하면 링크·병합·브랜드명 동기화
--          결과가 조용히 무효화되는데, 이 트리거가 그 저장을 충돌로 막아준다)
--       ⑪: deleted_at/deleted_by 만 SET, 제외 목록 밖 → 버전 상승(의도됨 —
--          삭제된 캠페인에 편집 폼이 stale 데이터를 저장하는 것을 막음)
--
-- ────────────────────────────────────────────────────────────
-- 설계 판단 2 — 클라이언트 계약: brand_applications(052) 패턴을 그대로 재사용
-- ────────────────────────────────────────────────────────────
--   deliverables(035)/settlements(217) 는 "전용 RPC + p_expected_version 인자"
--   방식(update_deliverable_status 등) — 승인/반려/보류처럼 서버가 상태 전이
--   규칙까지 함께 검증해야 하는 좁은 쓰기 경로에 맞는 방식이다.
--   brand_applications(052) 는 "BEFORE UPDATE 트리거가 항상 자동 증가 + 클라이언트는
--   평범한 .update(patch).eq('id',id).eq('version',expectedVersion).select(...) 만
--   호출" 방식 — dev/lib/storage.js updateBrandApplication() 이 이미 이 계약으로
--   11곳(admin-brand.js)에서 쓰이고 있다.
--   campaigns 의 updateCampaign() 은 052 의 updateBrandApplication() 과 성격이
--   같다(범용 UPDATE 래퍼, 승인/반려 같은 상태 기계가 아님) — 전용 RPC 를 새로
--   만들 필요 없이 052 패턴을 그대로 재사용한다. 클라이언트 쪽 변경은 별도
--   섹션(메인 세션 작업)에 정리.
--
-- ────────────────────────────────────────────────────────────
-- 기존 캠페인 백필
-- ────────────────────────────────────────────────────────────
--   NOT NULL DEFAULT 1 로 충분 — PostgreSQL 11+ 는 상수 DEFAULT 를 가진
--   ADD COLUMN 을 테이블 전체 재작성 없이(메타데이터만) 처리하므로 별도 UPDATE
--   백필이 필요 없다(263/265 등 최근 마이그레이션도 이 전제로 작성됨).
--
-- ────────────────────────────────────────────────────────────
-- 기존 트리거·기능과의 충돌 점검
-- ────────────────────────────────────────────────────────────
--   · campaign_change_history(265/266): version 은 48개 화이트리스트에 없으므로
--     이 트리거가 만드는 이력에 "version" 행이 절대 남지 않는다(v_fields 배열이
--     읽는 키가 아니라 존재해도 무시됨). 반대로 이 마이그레이션도 265/266 을
--     전혀 수정하지 않는다 — 서로 다른 트리거(BEFORE vs AFTER), 서로 다른 목적.
--   · trg_block_closed_caution_participation(075/097/108/156, BEFORE UPDATE,
--     컬럼 스코프 없음): 알파벳 순으로 'trg_block...' 이 'trg_campaigns...' 보다
--     먼저 실행된다. 이 트리거가 예외를 던지면 UPDATE 문 자체가 중단되어 이번
--     트리거의 버전 증가도 함께 롤백된다(정상 — 실패한 저장은 버전이 안 올라야
--     맞다). 이 트리거가 통과하면 그 다음 이번 트리거가 정상 실행된다.
--   · trg_campaigns_first_active_at(140, BEFORE UPDATE OF status): 알파벳 순으로는
--     'trg_campaigns_bump_version'(b…) 이 'trg_campaigns_first_active_at'(f…) 보다
--     **먼저** 실행된다(2026-07-30 정정 — 서술이 반대로 적혀 있었다). 다만
--     first_active_at 은 제외 6개 중 하나라 어느 순서든 이번 트리거의 비교 결과는
--     동일하다(결론 자체는 변함 없음).
--   · trg_reject_pending_on_campaign_end(176, AFTER UPDATE OF status): AFTER
--     트리거라 이번 BEFORE 트리거보다 항상 나중에 실행 — 이번 트리거가 만든
--     NEW.version 은 이미 행에 반영된 뒤라 서로 영향 없음.
--   · trg_submission_deadline_change_notify(273, AFTER UPDATE OF submission_end):
--     위와 동일한 이유로 무관.
--   · soft_delete_campaign/restore_campaign(255/256): 자체 FOR UPDATE 행 잠금 +
--     멱등 가드(이미 삭제/이미 복구 상태면 예외 또는 no-op)로 동시성을 따로
--     보장하고 있어 version 도입으로 깨지지 않는다. 오히려 "편집 폼이 열린 채
--     캠페인이 삭제됨" 케이스를 이번 트리거가 부가로 방어(위 ⑪ 참조).
--   · purge_campaign(257)/purge_expired_deleted_campaigns(258): DELETE 이므로
--     version 과 무관. campaign_change_history 는 campaign_id ON DELETE CASCADE
--     라 완전삭제 시 이력도 함께 사라지는데(265 Q6 결정), version 컬럼도 행 자체가
--     사라지므로 별도 정리가 필요 없다.
--   · link/unlink_campaign_to_application(121)·merge_brands(175): 자체
--     pg_advisory_xact_lock 직렬화를 이미 갖고 있어 version 도입이 필수는 아니지만,
--     이 트리거가 부가로 "그 사이 편집 폼이 stale source_application_id/brand_id 를
--     되돌려 저장" 하는 경로를 막아준다(위 ⑧⑨ 참조). 121 이 남겨둔 "version 컬럼이
--     없어 advisory lock 으로 대체" 코멘트가 가리키던 그 결여를 이번에 채운다.
--
-- ────────────────────────────────────────────────────────────
-- 롤백:
--   DROP TRIGGER IF EXISTS trg_campaigns_bump_version ON public.campaigns;
--   DROP FUNCTION IF EXISTS public.campaigns_bump_version();
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS version;
--   (버전 값 자체는 단순 증가 카운터라 복원 의미가 없음 — 컬럼만 제거하면 충분)
-- ============================================================

BEGIN;

-- ══════════════════════════════════════
-- 1) version 컬럼 추가
-- ══════════════════════════════════════
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS version integer NOT NULL DEFAULT 1;

COMMENT ON COLUMN public.campaigns.version IS
  '[275] 낙관적 락용 버전. 편집 저장 시 클라이언트가 알고 있던 값과 다르면 '
  '0행 UPDATE(충돌)로 처리한다. 증가는 아래 campaigns_bump_version() 트리거가 '
  '전담 — 조회수/신청수/순서/수정일/최초게시시각 6개 컬럼만 바뀐 경우는 증가하지 않는다.';

-- ══════════════════════════════════════
-- 2) 버전 증가 트리거 함수 — "제외 목록"(denylist) 방식
--    (설계 판단 1 참조 — 265/266 의 48개 허용 목록과 별개, 재사용하지 않음)
-- ══════════════════════════════════════
CREATE OR REPLACE FUNCTION public.campaigns_bump_version()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  -- 실사용 트래픽마다 자동으로 바뀌는 시스템성 컬럼만 제외한다. 캠페인에 새 컬럼이
  -- 추가되면 이 목록에 명시적으로 넣지 않는 한 자동으로 "보호 대상" 이 된다
  -- (fail-closed — 265/266 의 48개 "허용" 목록과 반대 방향의 안전 기본값).
  v_noise_cols text[] := ARRAY[
    'version',        -- 자기 자신(비교 대상에서 당연히 제외)
    'updated_at',      -- updateCampaign() 이 모든 저장에 항상 덧붙이는 타임스탬프
    'view_count',      -- increment_campaign_view(263) — 인플루언서 열람마다 갱신
    'applied_count',   -- recompute_campaign_applied_count(058/179) — 신청 상태 변경마다 갱신
    'order_index',     -- moveCampOrder 드래그 순서 변경 — 편집 폼이 다루지 않는 값
    'first_active_at'  -- trg_campaigns_first_active_at(140) — 최초 게시 시각 자동 기록
  ];
  v_new_json jsonb := to_jsonb(NEW) - v_noise_cols;
  v_old_json jsonb := to_jsonb(OLD) - v_noise_cols;
BEGIN
  IF v_new_json IS DISTINCT FROM v_old_json THEN
    NEW.version := OLD.version + 1;
  ELSE
    -- 제외 목록 컬럼만 바뀌었거나 실질적으로 아무것도 안 바뀜 — 버전 유지.
    -- 클라이언트가 SET 절에 version 을 직접 담아 보내도 여기서 무시하고
    -- 항상 서버가 계산한 값(OLD.version)으로 덮는다(변조 방지).
    NEW.version := OLD.version;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.campaigns_bump_version() IS
  '[275] campaigns BEFORE UPDATE 트리거. 제외 6개 컬럼(조회수/신청수/순서/수정일/'
  '최초게시시각/버전 자체)을 뺀 나머지가 하나라도 바뀌면 version 을 1 증가시킨다. '
  '컬럼 스코프 없이 모든 UPDATE 에서 발화(성능 비용은 O(1) jsonb 비교 1회 — 무시 가능).';

DROP TRIGGER IF EXISTS trg_campaigns_bump_version ON public.campaigns;

CREATE TRIGGER trg_campaigns_bump_version
  BEFORE UPDATE ON public.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public.campaigns_bump_version();

COMMENT ON TRIGGER trg_campaigns_bump_version ON public.campaigns IS
  '[275] 낙관적 락 버전 증가. trg_block_closed_caution_participation(075/097/108/156) '
  '이 알파벳 순으로 먼저 실행되어 예외를 던지면(잠긴 캠페인의 주의사항 변경 등) '
  'UPDATE 자체가 중단돼 이 트리거도 실행되지 않는다(정상 — 실패한 저장은 버전 불변).';

-- PostgREST 스키마 캐시 즉시 재로드 (신규 컬럼 select('*') 즉시 노출)
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ════════════════════════════════════════════════════════════
-- [검증 SQL] — 개발 서버에서 마이그레이션 적용 후 SQL Editor 에서 1단계씩 실행
-- ════════════════════════════════════════════════════════════
/*
-- 사전 준비: 검증용 캠페인 1건 확인
SELECT id, title, status, version, view_count, applied_count, order_index
FROM public.campaigns
WHERE status IN ('draft','scheduled','active') ORDER BY created_at DESC LIMIT 3;

-- [1] 기존 캠페인 전체가 version=1 로 백필됐는지
SELECT count(*) AS total, count(*) FILTER (WHERE version IS NULL) AS null_version,
       min(version) AS min_v, max(version) AS max_v
FROM public.campaigns;
-- 기대값: null_version = 0, min_v/max_v 는 신규 컬럼이라 전부 1이어야 함(아직 아무 UPDATE 도 안 돌았다면)

-- [2] 실질 변경(title) → 버전 +1 기대
UPDATE public.campaigns SET title = title || ' (검증)' WHERE id = '<검증용_ID>';
SELECT version FROM public.campaigns WHERE id = '<검증용_ID>';
-- 기대값: 이전 조회한 version 보다 1 큼

-- [3] 조회수만 변경(increment_campaign_view 재현) → 버전 불변 기대
SELECT version, view_count FROM public.campaigns WHERE id = '<검증용_ID>';
SELECT public.increment_campaign_view('<검증용_ID>'::uuid);
SELECT version, view_count FROM public.campaigns WHERE id = '<검증용_ID>';
-- 기대값: view_count 는 +1, version 은 위 [2] 이후 값과 동일(불변)
--   (SQL Editor 는 service_role 세션이라 increment_campaign_view 내부의 관리자/감사용 제외
--   분기에 안 걸릴 수 있음 — v_uid 가 NULL 이면 그대로 통과하므로 정상 재현됨)

-- [4] 순서만 변경(order_index) → 버전 불변 기대
UPDATE public.campaigns SET order_index = COALESCE(order_index, 0) + 1 WHERE id = '<검증용_ID>';
SELECT version FROM public.campaigns WHERE id = '<검증용_ID>';
-- 기대값: [2] 이후 값과 동일(불변)

-- [5] 상태만 변경(자동 전이/드롭다운 재현) → 버전 +1 기대
UPDATE public.campaigns SET status = 'active' WHERE id = '<검증용_ID>';
SELECT version, status FROM public.campaigns WHERE id = '<검증용_ID>';
-- 기대값: status 가 실제로 바뀌었다면 version +1. 이미 active 였다면 값이 같아 버전 불변 —
--   그 경우 status 를 임시로 다른 값으로 바꿨다가 되돌려 재현

-- [6] 낙관적 락 충돌 재현 — 옛 버전으로 UPDATE 시도 시 0행
SELECT version FROM public.campaigns WHERE id = '<검증용_ID>'; -- 현재 버전 확인(예: N)
UPDATE public.campaigns SET title = title WHERE id = '<검증용_ID>' AND version = 0; -- 일부러 틀린 버전
-- 기대값: UPDATE 0 (영향받은 행 0건) — 클라이언트 updateCampaign() 이 이 경우를
--   {ok:false, conflict:true} 로 변환해야 함(코드 변경은 메인 세션이 아래 섹션대로 적용)

-- [7] 트리거·컬럼 존재 확인
SELECT column_name, data_type, column_default, is_nullable
FROM information_schema.columns
WHERE table_schema='public' AND table_name='campaigns' AND column_name='version';
SELECT tgname, tgenabled FROM pg_trigger
WHERE tgrelid = 'public.campaigns'::regclass AND tgname = 'trg_campaigns_bump_version';
-- 기대값: 컬럼 1행(integer, default 1, not null), 트리거 1행(tgenabled='O')

-- 검증 데이터 정리(선택) — [2][4][5]에서 title/order_index/status 를 바꿨다면 원복
-- UPDATE public.campaigns SET title = replace(title, ' (검증)', '') WHERE id = '<검증용_ID>';
*/
