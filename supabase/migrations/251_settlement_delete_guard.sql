-- ============================================================
-- 251_settlement_delete_guard.sql
-- 감사 후속 작업 묶음 2 — 정산 삭제 교착 (확정 방향 d: 사전 체크 + 명확한 안내)
-- 사양서: docs/specs/2026-07-22-audit-followup-consistency-fixes.md §작업 묶음 2
--
-- 문제:
--   settlements 의 부모 외래 키 3종(influencer_id·application_id·campaign_id,
--   마이그레이션 217)은 ON DELETE CASCADE 인데 settlement_events.settlement_id 는
--   ON DELETE RESTRICT(의도적 — 217 파일 상단 설명: 금전 감사는 결과물 감사보다
--   보존 요구 수준이 높아, deliverable_events CASCADE 로 대리 등록 회수 시 감사가
--   유실된 선례를 반복하지 않기 위함). 그 결과 정산이 걸린 인플루언서·캠페인·
--   신청을 삭제하면 cascade 가 settlements 행까지 내려갔다가 settlement_events
--   RESTRICT 에 막혀, "무슨 이유로 삭제가 실패했는지 알 수 없는" 불투명한 외래 키
--   오류로 삭제 전체가 실패한다.
--
-- 확정 방향(d) — 외래 키 구조는 무변경, 사전 체크로 명확한 안내만 추가:
--   settlement_events 의 RESTRICT 는 그대로 둔다(217의 감사 보존 의도를 훼손하지
--   않기 위해). 대신 정산으로 연쇄될 수 있는 삭제 지점에서, cascade 가 그 벽에
--   부딪히기 *전에* 먼저 "정산 기록이 있어 삭제할 수 없습니다" 를 명확히 던진다.
--
-- 삭제 경로 전수 확인 (2026-07-22, grep 기준):
--   ① delete_admin_completely(uuid) — 마이그레이션 031 (SECURITY DEFINER RPC).
--      DELETE FROM applications WHERE user_id=... 후 DELETE FROM influencers.
--   ② dev/js/admin.js executeDeleteCampaign() — RPC 가 아니라 클라이언트가
--      직접 db.from('applications').delete().eq('campaign_id', campId) 후
--      db.from('campaigns').delete().eq('id', campId) 를 호출(001_enable_rls.sql
--      의 campaigns_delete_admin/applications_delete_admin 정책이 is_admin() 만
--      확인 — RPC 경유가 아니므로 함수 안에 체크를 넣는 방식으로는 못 막는다).
--   ③ delete_brand(174·191) — 연결된 campaigns·brand_applications 가 1건이라도
--      있으면 이미 차단(병합 안내) → campaigns 를 절대 삭제하지 않으므로 대상 아님.
--   ④ delete_orient_sheet(199·239) — 삭제 대상 캠페인에 applications 가 1건이라도
--      있으면 이미 blocked_has_applications 로 차단. settlements.application_id 는
--      NOT NULL 이라 정산이 있으면 반드시 그 응모(application)가 아직 존재하므로,
--      이 경로는 이미 안전(추가 조치 불필요 — 확인만 하고 그대로 둠).
--   ⑤ purge_audit_data_all/for_campaign(179) — is_audit=true 행만 대상.
--      backfill_settlements() 가 is_audit=false 만 정산을 생성하므로 감사용 계정은
--      정산이 존재할 수 없음(대상 아님).
--   ⑥ 012(과거 테스트 계정 정리)·050(중복 응모 정리)는 이미 실행된 1회성
--      과거 마이그레이션 — 재발동 없음(대상 아님).
--   → 실질적으로 사전 체크가 필요한 지점은 ①·② 두 곳. ②는 RPC 가 아니라서
--     "함수에 체크 추가"가 불가능 → 테이블 트리거로 구현(아래 설계 참고).
--
-- 설계 — 함수별 개별 체크 대신 트리거 1개로 통일한 이유:
--   ②(executeDeleteCampaign)는 SECURITY DEFINER 함수가 아니라 클라이언트의 직접
--   DELETE 라, "삭제 함수에 체크를 추가"하는 방식 자체가 적용 불가능하다.
--   applications·campaigns(·influencers) 테이블에 BEFORE DELETE 트리거를 걸면
--   ①(RPC 경유)·②(클라 직접 DELETE) 양쪽을 같은 코드 하나로 커버하고, 앞으로
--   생길 수 있는 다른 삭제 경로도 자동으로 방어된다(함수마다 따로 체크를 심고
--   빠뜨리는 위험 자체를 없앰). 외래 키 정의는 전혀 건드리지 않으므로 방향(d)의
--   "삭제 연결 구조는 무변경" 을 그대로 지킨다.
--
-- 차단 대상 정산 상태 범위 — 전부(cancelled 포함), 상태로 거르지 않는 이유:
--   settlement_events 는 상태와 무관하게 모든 정산 생성 시 최소 1건('create')이
--   반드시 INSERT 된다(마이그레이션 218 backfill_settlements, 231 동일 로직).
--   즉 settlements 행이 어떤 상태(pending/paid/on_hold/cancelled)든 그 정산에
--   딸린 settlement_events 행이 항상 존재하므로, cascade 가 그 settlements 행까지
--   내려가면 상태와 무관하게 반드시 RESTRICT 벽에 부딪힌다. 따라서 "pending/paid
--   만 차단하고 cancelled 는 통과"처럼 상태로 거르면, cancelled 정산이 있는 대상을
--   삭제할 때 이 사전 체크를 그냥 지나쳤다가 결국 같은 불투명 오류를 다시 만난다
--   (사전 체크의 존재 의미가 없어짐). 그래서 상태 무관 "settlements 행이 1건이라도
--   있으면 차단"으로 구현한다 — 이건 안전 마진이 아니라 구조적으로 유일하게 맞는
--   조건이다.
--
-- 정산 정식 오픈 시점 재검토:
--   현재 정산은 운영에서 잠금 상태(settlement_settings.cutoff_at=NULL,
--   influencer_visible=false) → 운영 settlements 행 사실상 0건, 이 마이그레이션은
--   활성 버그 대응이 아니라 정식 오픈 전 예방 조치. 정식 오픈 후 "정산 걸린 대상은
--   원천적으로 삭제 자체를 차단"(방향 c)으로 강화할지는 이 마이그레이션 범위 밖의
--   후속 판단 사항으로 남긴다(사양서 §설계 참고).
--
-- 클라이언트 반영 (같은 커밋, DB 외 변경):
--   dev/js/admin-core.js friendlyError() — 'settlement_exists_cannot_delete' 코드어를
--     한국어 안내로 매핑.
--   dev/js/admin.js executeDeleteCampaign() — applications 삭제 결과의 error 를
--     기존에는 확인하지 않고 넘어갔던 것을 확인하도록 수정(이 트리거가 그 단계에서
--     막아도 사용자에게 조용히 무시되지 않게).
--   (관리자 완전 삭제 executeDeleteCompletely() 는 별도 모달 없이 공용 friendlyError()
--    경유 toast 로 충분해 admin-accounts.js 는 수정하지 않음 — 최종 결정.)
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 검증
--   2. 운영서버(nrwtujmlbktxjgdwlpjj) SQL Editor 실행 (정산 미가동이라 급하지 않음)
--
-- 검증 쿼리 (적용 후 실행 — 1단계씩):
--   -- [1] 함수·트리거 생성 확인
--   SELECT tgname, tgrelid::regclass FROM pg_trigger
--    WHERE tgname = 'trg_block_delete_with_settlements'
--    ORDER BY 2;
--   -- 기대값: applications/campaigns/influencers 3 rows
--
--   -- [2] 기능 검증 — 정산이 걸린 응모(개발 DB에 존재)를 직접 삭제 시도
--   --     DELETE FROM public.applications WHERE id = '<정산 걸린 응모 id>';
--   -- 기대값: ERROR — 'settlement_exists_cannot_delete: 정산 기록이 있는...'
--
--   -- [3] 정산이 없는 응모는 정상 삭제되는지 확인(회귀 없음)
--   --     (실제로 지우지 말고 트랜잭션 안에서 확인 권장)
--   --     BEGIN; DELETE FROM public.applications WHERE id = '<정산 없는 응모 id>'; ROLLBACK;
--   -- 기대값: 정상 성공(에러 없음), ROLLBACK 으로 실제 반영은 안 됨
--
-- 롤백:
--   DROP TRIGGER IF EXISTS trg_block_delete_with_settlements ON public.applications;
--   DROP TRIGGER IF EXISTS trg_block_delete_with_settlements ON public.campaigns;
--   DROP TRIGGER IF EXISTS trg_block_delete_with_settlements ON public.influencers;
--   DROP FUNCTION IF EXISTS public.block_delete_with_settlements();
-- ============================================================

CREATE OR REPLACE FUNCTION public.block_delete_with_settlements()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_count bigint;
BEGIN
  -- SECURITY DEFINER 필수: 이 트리거는 campaign_manager(정산 조회 권한 hidden,
  -- has_permission('settlement.view')=false) 가 캠페인/신청을 지울 때도 실행된다.
  -- SECURITY INVOKER 였다면 settlements 의 RLS(settlements_select_admin) 때문에
  -- 그 관리자 세션에는 정산 행이 안 보여 count=0 으로 오판, 체크가 무력화된다.
  IF TG_TABLE_NAME = 'applications' THEN
    SELECT count(*) INTO v_count
      FROM public.settlements
     WHERE application_id = OLD.id;

    IF v_count > 0 THEN
      RAISE EXCEPTION 'settlement_exists_cannot_delete: 정산 기록이 있는 신청은 삭제할 수 없습니다. 먼저 정산 관리 화면에서 상태를 확인해 주세요.'
        USING ERRCODE = '22023';
    END IF;

  ELSIF TG_TABLE_NAME = 'campaigns' THEN
    SELECT count(*) INTO v_count
      FROM public.settlements
     WHERE campaign_id = OLD.id;

    IF v_count > 0 THEN
      RAISE EXCEPTION 'settlement_exists_cannot_delete: 정산 기록이 있는 신청이 포함된 캠페인은 삭제할 수 없습니다. 먼저 정산 관리 화면에서 상태를 확인해 주세요.'
        USING ERRCODE = '22023';
    END IF;

  ELSIF TG_TABLE_NAME = 'influencers' THEN
    SELECT count(*) INTO v_count
      FROM public.settlements
     WHERE influencer_id = OLD.id;

    IF v_count > 0 THEN
      RAISE EXCEPTION 'settlement_exists_cannot_delete: 정산 기록이 있는 인플루언서 계정은 완전 삭제할 수 없습니다. 관리자 권한 해제만 가능합니다.'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  RETURN OLD;
END;
$$;

COMMENT ON FUNCTION public.block_delete_with_settlements() IS
  '[251] applications/campaigns/influencers 행이 삭제되기 전에, 연결된 settlements(정산) '
  '행이 하나라도 있으면(상태 무관 — settlement_events 가 항상 존재해 결국 RESTRICT 에 '
  '부딪히므로) 불투명한 외래 키 오류 대신 명확한 한국어 예외로 미리 차단. '
  'settlement_events.settlement_id ON DELETE RESTRICT(217) 는 무변경. SECURITY DEFINER 필수 '
  '(campaign_manager 등 settlement.view 권한 없는 세션도 settlements 존재 여부를 정확히 판정해야 함).';

-- applications: delete_admin_completely(031)·executeDeleteCampaign(admin.js) 양쪽 경유
DROP TRIGGER IF EXISTS trg_block_delete_with_settlements ON public.applications;
CREATE TRIGGER trg_block_delete_with_settlements
  BEFORE DELETE ON public.applications
  FOR EACH ROW
  EXECUTE FUNCTION public.block_delete_with_settlements();

-- campaigns: executeDeleteCampaign(admin.js) 직접 삭제 경로 방어(대개 applications
-- 트리거가 먼저 막지만, 향후 캠페인만 직접 지우는 경로가 생겨도 대비하는 이중 방어)
DROP TRIGGER IF EXISTS trg_block_delete_with_settlements ON public.campaigns;
CREATE TRIGGER trg_block_delete_with_settlements
  BEFORE DELETE ON public.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public.block_delete_with_settlements();

-- influencers: delete_admin_completely(031) 가 applications 를 먼저 지우므로 실무상
-- 이 트리거까지 도달할 일은 드물지만, influencers 를 직접 지우는 미래 경로 대비
DROP TRIGGER IF EXISTS trg_block_delete_with_settlements ON public.influencers;
CREATE TRIGGER trg_block_delete_with_settlements
  BEFORE DELETE ON public.influencers
  FOR EACH ROW
  EXECUTE FUNCTION public.block_delete_with_settlements();
