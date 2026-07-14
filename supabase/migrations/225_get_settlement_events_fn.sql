-- ============================================================
-- 225_get_settlement_events_fn.sql
-- 인플루언서 정산 관리 — 정산 이력 조회 RPC
-- 사양서: docs/specs/2026-06-22-influencer-settlement.md §5, §7-1
--
-- get_settlement_events(p_settlement_id) — 관리자 정산 화면(admin-settlements.js,
-- 별도 세션 작업)에서 정산 1건의 상태 변경 이력(settlement_events, 마이그레이션 217)을
-- 타임라인으로 보여줄 때 호출. settlement_events.actor 는 auth.users.id(uuid) 라
-- 화면에서 바로 쓸 수 없으므로, 이 함수가 admins 테이블과 조인해 관리자 이름 문자열로
-- 변환해서 반환한다(actor_name).
--
-- SECURITY DEFINER 를 쓰는 이유: settlement_events RLS(마이그레이션 217)는 조회를
-- has_permission('settlement.view','read') 로만 게이트하고, admins 테이블 조회 권한과는
-- 무관하다. 일반 authenticated 세션으로 admins 를 직접 JOIN 하려면 admins 테이블
-- RLS(관리자만 SELECT)도 통과해야 하는데, 이 함수를 SECURITY DEFINER 로 만들면 함수
-- 내부에서 그 RLS 를 우회해 조인을 1번에 처리할 수 있다 — 대신 함수 진입점에서
-- has_permission 가드를 반드시 다시 걸어야 한다(그렇지 않으면 정의자 권한으로 아무나
-- 이력을 볼 수 있게 됨). settlements 테이블 자체의 SELECT 정책과 동일 기준
-- (settlement.view, read) 을 그대로 사용 — 화면에서 정산 목록을 볼 수 있는 사람만
-- 그 이력도 볼 수 있어야 자연스럽다.
--
-- actor_name 규칙:
--   - settlement_events.actor 가 NULL (예: backfill_settlements 자동 생성 이력, 217
--     COMMENT "auth.uid() 있으면 그 관리자, 없으면 NULL" 참고) → actor_name NULL
--   - actor 가 있지만 admins 테이블에 없는 경우(관리자 권한 해제 후 등) → actor_name NULL
--     (LEFT JOIN 이라 매치 안 되면 자연히 NULL)
--   - 화면은 actor_name 이 NULL 이면 "자동/시스템" 등으로 표시할 것(이 함수 책임 아님).
--
-- 정렬: at ASC (오래된 것부터 — 타임라인 순서로 위→아래 시간 흐름).
--
-- 권한: has_permission('settlement.view','read') — settlements/settlement_events
-- SELECT 정책과 동일 기준. campaign_manager 는 이 기능이 hidden(마이그레이션 220
-- 시드)이라 42501 로 차단.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_settlement_events(
  p_settlement_id uuid
)
RETURNS TABLE (
  action      text,
  prev_status text,
  next_status text,
  actor_name  text,
  memo        text,
  at          timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- ── 권한 가드: settlement.view 최소 read (settlements/settlement_events SELECT 정책과 동일 기준) ──
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'permission_denied: 정산 이력 조회 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    e.action,
    e.prev_status,
    e.next_status,
    a.name AS actor_name,
    e.memo,
    e.at
  FROM public.settlement_events e
  LEFT JOIN public.admins a ON a.auth_id = e.actor
  WHERE e.settlement_id = p_settlement_id
  ORDER BY e.at ASC;
END;
$$;

COMMENT ON FUNCTION public.get_settlement_events(uuid) IS
  '[225] 정산(settlements) 1건의 상태 변경 이력(settlement_events) 을 관리자 이름으로 '
  '변환해 반환. SECURITY DEFINER, has_permission(''settlement.view'',''read'') 게이트. '
  'actor 가 NULL 이거나 admins 에 없으면 actor_name NULL(화면이 "자동/시스템" 등으로 표시).';

REVOKE ALL ON FUNCTION public.get_settlement_events(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_settlement_events(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] 함수 생성 확인
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'get_settlement_events';

-- [V1] 이력이 있는 정산행 1건 확보 (마이그레이션 222~224 스모크 테스트로 이미
--   settlement_events 가 쌓여 있으면 그 id 사용, 없으면 아무 settlements id 선택)
SELECT s.id, s.status, count(e.id) AS event_count
FROM public.settlements s
LEFT JOIN public.settlement_events e ON e.settlement_id = s.id
GROUP BY s.id, s.status
ORDER BY event_count DESC
LIMIT 5;

-- [V2] 스모크 호출 (앱에서 campaign_admin 이상 로그인 세션으로 — SQL Editor 직접 실행은
--   auth.uid() 가 NULL 이라 permission_denied 로 막힐 수 있음, 정상 동작)
-- SELECT * FROM public.get_settlement_events('<위 id>'::uuid);
-- 기대: action/prev_status/next_status/actor_name/memo/at 컬럼으로 시간순(오래된 것부터) 행 반환.
--   actor_name 은 처리한 관리자 이름 문자열(자동 생성 이력이면 NULL).

-- [V3] campaign_manager 권한으로 호출 시 42501 차단 확인 (settlement.view 가 hidden 인 계정)
-- SELECT * FROM public.get_settlement_events('<id>'::uuid);  -- 기대: ERROR permission_denied

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.get_settlement_events(uuid);
