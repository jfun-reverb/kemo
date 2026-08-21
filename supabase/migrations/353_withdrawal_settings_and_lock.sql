-- ============================================================
-- 353_withdrawal_settings_and_lock.sql
--
-- 회원 탈퇴 — 작업 15 「시행 전 잠금 · 자동 해제」 ①/② 중 ①
--   (② = 354_request_withdrawal_lock_gate.sql — 이 파일 뒤에 적용)
--
-- 사양서   : docs/specs/2026-08-18-member-withdrawal.md
--            §4-4(화면 세 모습) · §4-6 ⑭ · §5 ⑤ · §5 ⑧(2026-08-19 좁힘)
-- 작업표   : docs/specs/2026-08-19-member-withdrawal-breakdown.md 「작업 15」
--
-- 선행 마이그레이션:
--   345(withdrawal_requests 표) · 346(withdraw_reason 시드)
--   350(request_withdrawal 현재 원본 + _withdrawal_unpaid_count)
--   352(advance_withdrawal_states 현재 원본 + purge_withdrawn_personal_data)
--
-- 이 파일은 **읽기·판정만** 추가한다. 기존 함수를 하나도 재정의하지 않는다.
--   (실제 게이트를 request_withdrawal 에 끼우는 것은 354)
--
-- ============================================================
-- ① 무엇을 만드나
-- ============================================================
--   [A] 표   public.withdrawal_settings        (단일 행 — 시행일 보관)
--   [B] 함수 public.is_withdrawal_open()       (불리언만 — 열렸나)
--   [C] 함수 public._withdrawal_lock_blockers(uuid)  (내부 전용 — 걸린 것 세기)
--   [D] 함수 public.get_withdrawal_precheck(uuid)    (화면·관리자가 부르는 조회)
--
-- ============================================================
-- ② 왜 「시행일 전 = 전원 잠금」이 아닌가
-- ============================================================
--   사양서 §5 ⑧ 이 2026-08-19 에 잠금을 좁혔다. 30일 사전 통지가 필요한 것은
--   「탈퇴」 자체가 아니라 **회원에게 불리한 두 변경**(자동 철회 범위 축소 ·
--   파기 → 익명 보관)이고, 그 둘이 **발동하지 않는 회원**에게는 옛 약관과 새
--   약관의 결과가 같다. 그런 회원은 통지 전에 처리해도 불리해지지 않는다.
--
--   → 시행일 전에도 「깨끗한 회원」은 그대로 탈퇴가 돌고, 하나라도 걸린 회원만
--     문의 창구로 보낸다(운영팀이 개별 처리).
--
-- ============================================================
-- ③ ★ 잠금 조건이 셋인 이유 (사양서 §5 ⑧ 은 둘로 적었다 — 2026-08-19 확장)
-- ============================================================
--   사양서가 확정한 조건은 둘이었다:
--     1) 철회할 수 없는 응모 0건
--     2) 정산 기록 0건
--
--   여기에 **3) 받지 못한 보수 0건** 을 더한다. 2026-08-19 사용자 결정.
--
--   ⚠️ **2와 3은 다른 값이다.** 이것이 이 조건을 더한 이유 전부다.
--     · 2 = settlements 에 행이 있나 (상태 불문)
--     · 3 = _withdrawal_unpaid_count(350) — 정산대기·보류 행 **＋ 정산 행이
--           아직 없는 인증 성공 건**
--
--   작업 5의 브라우저 검증(2026-08-19)이 산 증거다 — 시험 계정 haruka.test 는
--   **정산 행 0건인데 미지급 2건**이었다(관리자가 정산 화면을 아직 안 열어
--   행이 안 생긴 건). 즉 조건 1·2 를 다 통과하고도 `pending_payout`(대기)로
--   들어가는 회원이 **정상적으로 생긴다**.
--
--   그 대기가 위험한 이유 둘:
--     ㄱ **대기 중 조건이 사후에 깨진다** — 관리자가 정산 화면을 여는 순간
--        settlements 행이 생겨 조건 2가 깨지는데, 예약 실행(352)은 입구 판정을
--        다시 보지 않으므로 그대로 확정된다. 통지 전에 불리한 변경이 적용된다.
--     ㄴ **그 사이 내내 현행 방침을 우리가 어긴다** — 지금 개인정보처리방침은
--        「탈퇴일로부터 5일 경과 후 지체 없이 파기」다. 개정안(「지급이 끝난 뒤
--        예정일 안내」)은 시행일 전이라 아직 효력이 없다. 대기가 몇 달이면
--        방침 위반 구간이 그만큼 이어진다.
--
--   → 조건 3을 더하면 잠금 기간의 경로가 **「신청 → 즉시 예정 → 5일 뒤 확정」
--     하나뿐**이 되어 위 두 구멍이 함께 사라진다. 보수가 남은 분은 문의
--     창구에서 사람이 안내한다(어차피 몇 달을 기다려야 하는 분들이다).
--
--   ⚠️ **시행일이 오면 이 세 조건은 전부 사라진다** — 그때는 전원 자동 처리다.
--     게이트 자체가 `IF NOT is_withdrawal_open()` 안에 있어서(354) 시행 후에는
--     **블록에 들어가지도 않는다.** 조건문을 물리적으로 걷어내는 정리는 작업 18
--     소관이고, **잊어도 동작은 안전하다**(들어가지 않으므로).
--
-- ============================================================
-- ④ 「걸린 것」을 어떻게 세나 — 판정을 한 곳에만 둔다
-- ============================================================
--   화면은 **누르기 전에** 세 모습 중 무엇을 그릴지 알아야 하는데, 「철회할 수
--   없는 응모」는 원래 cancel_application(309)을 실제로 돌려 봐야 나오는 값이다.
--   그렇다고 cancel_application 의 거부 규칙을 사전 판정으로 **베껴 쓰면** 이
--   저장소에서 반복된 「같은 판단이 여러 곳」 사고가 된다(마이그레이션 312 ·
--   「최신 영수증」 4곳 · 인증 성공 5곳).
--
--   → 그래서 조건을 **「무엇이 거부될까」가 아니라 「이 회원에게 무엇이 있나」**
--     로 다시 서술하고, 그 서술을 [C] 헬퍼 **한 곳**에만 둔다. 사전 조회([D])와
--     실제 게이트(354)가 **같은 헬퍼**를 부른다.
--
--   ⚠️ 그래도 헬퍼가 낡을 수 있다(새 차단 트리거가 붙는 등). 그 대비는 354 의
--     **백스톱**이 맡는다 — 게이트를 통과했는데 실제로 철회가 막힌 건이 나오면
--     그 반복문째 되돌리고 「사람에게 넘김」으로 착지시킨다. 드리프트의 결과가
--     「잘못된 처리」가 아니라 「사람에게 넘어감」이 되도록.
--
--   실제로 응모 철회를 막는 곳은 코드 실측 기준 셋뿐이다:
--     · cancel_application(309) 본문 3절 — 그 응모에 **승인된 결과물**이 있으면
--       `deliverable_already_approved`
--     · 트리거 guard_reject_with_paid_settlement(247) — **송금완료 정산**이 있으면
--     · 트리거 guard_event_application_status_change(289) — **행사(event_mode)
--       응모**는 일반 상태 변경 차단
--   이 중 둘째는 조건 2(정산 기록 0건)를 통과한 회원에게는 **원리적으로 불가능**
--   하다(송금완료 정산이 있으면 settlements 행이 있다). 그래서 헬퍼가 따로 세는
--   응모 조건은 **승인된 결과물 · 행사** 둘뿐이고 헬퍼가 커지지 않는다.
--
-- ============================================================
-- ⑤ 날짜는 절대 밖으로 내보내지 않는다
-- ============================================================
--   사양서 §5 ⑤ — 「N월부터 가능합니다」는 **지키지 못할 수 있는 약속**이다.
--   그래서 표는 관리자만 읽고([A] 정책), 회원에게 나가는 함수([B]·[D])는
--   **불리언과 mode 값만** 돌려준다. effective_date 자체는 어떤 반환값에도 없다.
--
--   ⚠️ 브라우저 시계 조작으로 열리지 않는다 — 판정이 전부 서버의
--     `(now() AT TIME ZONE 'Asia/Tokyo')::date` 다(§5 ⑤ · release-timing 규칙
--     「법적 집행은 서버측 판정」).
--
-- ============================================================
-- ⑥ 되돌리기
-- ============================================================
--   신설뿐이라 아래로 완전히 되돌아간다(354 를 먼저 되돌린 뒤에 할 것):
--     DROP FUNCTION IF EXISTS public.get_withdrawal_precheck(uuid);
--     DROP FUNCTION IF EXISTS public._withdrawal_lock_blockers(uuid);
--     DROP FUNCTION IF EXISTS public.is_withdrawal_open();
--     DROP TABLE IF EXISTS public.withdrawal_settings;
--
-- ⚠️ **이 파일에 날짜를 박지 않는다.** 시드는 반드시 NULL 이다. 개발서버에서
--    날짜를 넣었다 빼는 것은 **검증 절차의 일부**이지 마이그레이션 내용이 아니다.
--    (마이그레이션에 날짜를 박으면 운영에 적용하는 순간 운영도 열린다)
-- ============================================================

BEGIN;

-- ============================================================
-- [A] withdrawal_settings — 시행일 단일 행 설정 표
--
--   선례 그대로: age_policy_settings(180). 단일 행 CHECK · 날짜 NULL 이면
--   비활성 · 조회는 관리자 · 수정은 최고 관리자.
--
--   ⚠️ 수정을 최고 관리자로 좁히는 이유 — 이 한 칸이 **전 회원의 탈퇴 가부**를
--     좌우한다. 누가 실수로 NULL 로 되돌리면 시행 후에도 전원이 다시 잠긴다.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.withdrawal_settings (
  id                 integer      PRIMARY KEY DEFAULT 1
                                  CONSTRAINT withdrawal_settings_singleton
                                    CHECK (id = 1),
  effective_date     date         NULL,
  description        text         NULL,
  updated_at         timestamptz  NOT NULL DEFAULT now(),
  updated_by         uuid         NULL REFERENCES auth.users(id) ON DELETE SET NULL
);

COMMENT ON TABLE public.withdrawal_settings IS
  '[353] 회원 탈퇴 자동 처리 시행일 설정. 항상 1행. effective_date=NULL 이면 '
  '시행 전(잠금). 이 날짜부터 조건 없이 전원 자동 처리된다. 조회는 관리자, '
  '수정은 최고 관리자만 — 이 한 칸이 전 회원의 탈퇴 가부를 좌우한다.';

COMMENT ON COLUMN public.withdrawal_settings.effective_date IS
  '탈퇴 자동 처리 시행일(일본 시각 기준 날짜). NULL = 시행 전. 이 날짜는 약관 '
  '개정 공고가 알린 시행일과 **같은 값이어야 한다**(작업 18과 짝). 어긋나면 '
  '약관은 바뀌었는데 화면이 안 열리거나, 화면이 먼저 열려 통지 전에 새 규칙이 '
  '적용된다.';

-- 초기 1행 — 반드시 NULL(시행 전)
INSERT INTO public.withdrawal_settings (id, effective_date, description)
VALUES (1, NULL, '초기값 — 시행일 미정. 약관 개정 공고 30일 경과 후 그 시행일로 UPDATE 할 것(작업 18).')
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.withdrawal_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "withdrawal_settings_select" ON public.withdrawal_settings;
CREATE POLICY "withdrawal_settings_select"
  ON public.withdrawal_settings FOR SELECT
  TO authenticated
  USING (public.is_admin());

DROP POLICY IF EXISTS "withdrawal_settings_update" ON public.withdrawal_settings;
CREATE POLICY "withdrawal_settings_update"
  ON public.withdrawal_settings FOR UPDATE
  TO authenticated
  USING (public.is_super_admin())
  WITH CHECK (public.is_super_admin());

-- INSERT·DELETE 정책 없음 — 단일 행이라 늘리거나 지울 일이 없다.

-- ============================================================
-- [B] is_withdrawal_open() — 「열렸나」만 돌려주는 판정 함수
--
--   선례: is_settlement_public()(240) · is_brand_survey_open()(206).
--   회원은 [A] 표를 읽을 권한이 없으므로(정책이 관리자 한정) 이 함수가 필요하다.
--
--   fail-closed — 행이 없거나 날짜가 NULL 이면 false(잠김).
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_withdrawal_open()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    (SELECT effective_date IS NOT NULL
              AND (now() AT TIME ZONE 'Asia/Tokyo')::date >= effective_date
       FROM public.withdrawal_settings
      WHERE id = 1),
    false
  );
$$;

COMMENT ON FUNCTION public.is_withdrawal_open() IS
  '[353] 회원 탈퇴 자동 처리가 시행됐나(boolean). 판정은 서버의 일본 시각 날짜 — '
  '브라우저 시계를 앞당겨도 열리지 않는다. fail-closed(설정 행 없거나 날짜 NULL '
  '이면 false). **날짜 자체는 절대 반환하지 않는다**(「N월부터」라는 지키지 못할 '
  '약속을 만들지 않기 위해 — 사양서 §5 ⑤). authenticated 전용.';

REVOKE ALL ON FUNCTION public.is_withdrawal_open() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_withdrawal_open() TO authenticated;

-- ============================================================
-- [C] _withdrawal_lock_blockers(uuid) — 「이 회원에게 무엇이 있나」
--
--   ★ 잠금 판정의 **유일한 정의처**. 사전 조회([D])와 실제 게이트(354)가 둘 다
--     이 함수를 부른다. 위 ④ 참조.
--
--   내부 전용(밑줄 접두어) — _withdrawal_unpaid_count(350)와 같은 관례로
--   REVOKE ALL 만 하고 authenticated 에 GRANT 하지 않는다. 밖에서 부를 일이
--   있으면 [D] 를 통한다(거기서 본인·관리자 확인을 한다).
-- ============================================================
CREATE OR REPLACE FUNCTION public._withdrawal_lock_blockers(
  p_influencer_id uuid
) RETURNS TABLE (
  approved_deliverable_apps integer,  -- 승인된 결과물이 있는 살아있는 응모 수
  event_apps                integer,  -- 행사(오프라인 팝업) 살아있는 응모 수
  settlement_rows           integer,  -- 정산 기록 수(상태 불문)
  unpaid_count              integer   -- 받지 못한 보수 건수
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    -- ① 승인된 결과물이 있는 응모 — cancel_application(309) 3절이 막는 조건
    --    그대로. 「살아있는 응모」의 범위(pending·approved)도 350 의 철회
    --    반복문과 같은 집합이어야 한다(다르면 세는 대상과 도는 대상이 갈린다).
    (SELECT count(*)
       FROM public.applications a
      WHERE a.user_id = p_influencer_id
        AND a.status IN ('pending', 'approved')
        AND EXISTS (SELECT 1
                      FROM public.deliverables d
                     WHERE d.application_id = a.id
                       AND d.status = 'approved'))::integer,

    -- ② 행사(event_mode) 응모 — 트리거 guard_event_application_status_change
    --    (289)가 막는 조건. 예약은 「진행현황 → 예약 현황」에서 따로 취소해야
    --    한다.
    --    ⚠️ 350 의 배치가 뒤이어 행사 예약을 정리하지만, 그것은 **신청이
    --      접수된 뒤** 이야기다. 잠금 판정은 접수 이전이라 여기서 센다.
    (SELECT count(*)
       FROM public.applications a
       JOIN public.campaigns c ON c.id = a.campaign_id
      WHERE a.user_id = p_influencer_id
        AND a.status IN ('pending', 'approved')
        AND COALESCE(c.event_mode, false))::integer,

    -- ③ 정산 기록 — 상태를 가리지 않는다(사양서 §5 ⑧ 조건 2).
    (SELECT count(*)
       FROM public.settlements s
      WHERE s.influencer_id = p_influencer_id)::integer,

    -- ④ 받지 못한 보수 — 350 이 뽑아 둔 공용 함수를 **그대로 재사용**한다.
    --    여기서 다시 세면 신청 함수·예약 실행과 기준이 갈린다(350 헤더 ①이
    --    막으려던 바로 그 사고).
    public._withdrawal_unpaid_count(p_influencer_id);
$$;

COMMENT ON FUNCTION public._withdrawal_lock_blockers(uuid) IS
  '[353] 시행일 전 탈퇴 자동 처리를 막는 것이 이 회원에게 몇 건씩 있나 — 잠금 '
  '판정의 유일한 정의처. 사전 조회(get_withdrawal_precheck)와 실제 게이트'
  '(request_withdrawal, 354)가 둘 다 이 함수를 부른다. 넷 다 0이어야 자동 '
  '처리된다. ⚠️ cancel_application 의 거부 규칙을 베낀 것이 아니라 「이 회원에게 '
  '무엇이 있나」로 독립 서술한 것이다 — 그래도 낡을 수 있으므로 354 에 백스톱이 '
  '있다. 내부 전용 — authenticated 에 GRANT 하지 않는다.';

REVOKE ALL ON FUNCTION public._withdrawal_lock_blockers(uuid) FROM PUBLIC;

-- ============================================================
-- [D] get_withdrawal_precheck(uuid) — 화면이 누르기 전에 부르는 조회
--
--   반환 jsonb:
--     { ok: true,
--       mode: 'open' | 'locked_auto' | 'locked_support',
--       is_open: boolean,
--       blockers: { approved_deliverable_apps, event_apps,
--                   settlement_rows, unpaid_count },
--       active_request: { status, scheduled_date } | null }
--   실패:
--     { ok:false, reason:'not_authenticated'|'not_found'|'forbidden'|
--                        'audit_account_blocked' }
--
--   ★ mode 를 **서버가 정한다**는 것이 이 함수의 핵심이다.
--     화면이 「시행일 전인데 조건이 …」를 스스로 계산하면 시행 후에 지워야 할
--     자리가 화면마다 생긴다. 화면은 mode 만 보고 세 모습을 그린다 →
--     **시행 후 화면은 손댈 것이 0** 이 된다.
--
--     · open           — 시행됨. 화면은 평소 탈퇴 화면
--     · locked_auto    — 시행 전이지만 걸린 것이 없다. 화면은 평소 탈퇴 화면
--                        (사양서 §5 ⑧ — 이 회원은 옛·새 약관 결과가 같다)
--     · locked_support — 걸린 것이 있다. 화면은 「무엇이 걸렸는지」 + 문의 창구
--
--   ⚠️ locked_auto 와 open 은 **화면이 같다**. 굳이 나눈 이유는 관리자 화면과
--     기록·문의 응대에서 「지금 시행 전인가」를 알아야 하기 때문이다. 화면이
--     둘을 합쳐 그리는 것은 정상이다.
--
--   인자:
--     · NULL(기본) — 본인
--     · 값 있음     — 그 회원. **관리자만** 허용(작업 14 관리자 화면이 같은
--                     함수를 쓰도록. 안 그러면 거기서 판정을 또 만든다)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_withdrawal_precheck(
  p_influencer_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller      uuid := auth.uid();
  v_target      uuid;
  v_inf         public.influencers%ROWTYPE;
  v_is_open     boolean;
  v_b           record;
  v_active      public.withdrawal_requests%ROWTYPE;
  v_has_active  boolean := false;
  v_mode        text;
BEGIN
  -- 1. 본인 확인
  IF v_caller IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  v_target := COALESCE(p_influencer_id, v_caller);

  -- 2. 남의 것을 보려면 관리자여야 한다
  --    ⚠️ is_admin() 은 등급을 안 가린다 — 이 조회는 개인정보를 돌려주지 않고
  --      건수만 돌려주므로 관리자 전원에게 연다(관리자 화면 정합).
  IF v_target <> v_caller AND NOT public.is_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT * INTO v_inf FROM public.influencers WHERE id = v_target;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  -- 3. 감사용 계정은 애초에 탈퇴할 수 없다(347/350 이 거부한다) — 화면이
  --    「탈퇴하기」를 그렸다가 눌러서 거부당하는 일이 없도록 여기서도 같은
  --    답을 준다.
  IF v_inf.is_audit THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'audit_account_blocked');
  END IF;

  v_is_open := public.is_withdrawal_open();

  SELECT * INTO v_b FROM public._withdrawal_lock_blockers(v_target);

  -- 4. 지금 진행 중인 신청이 있으면 함께 알려준다 — 화면이 「신청함/취소하기」를
  --    그리려면 필요하고, 이걸 안 주면 화면이 표를 따로 조회하게 된다.
  SELECT * INTO v_active
    FROM public.withdrawal_requests
   WHERE influencer_id = v_target
     AND status IN ('pending_payout', 'scheduled')
   ORDER BY requested_at DESC
   LIMIT 1;
  v_has_active := FOUND;

  -- 5. mode 판정 — 조건 셋(위 헤더 ③) 전부 0일 때만 잠금 기간에도 자동 처리
  IF v_is_open THEN
    v_mode := 'open';
  ELSIF v_b.approved_deliverable_apps = 0
    AND v_b.event_apps = 0
    AND v_b.settlement_rows = 0
    AND v_b.unpaid_count = 0 THEN
    v_mode := 'locked_auto';
  ELSE
    v_mode := 'locked_support';
  END IF;

  RETURN jsonb_build_object(
    'ok',      true,
    'mode',    v_mode,
    'is_open', v_is_open,
    'blockers', jsonb_build_object(
      'approved_deliverable_apps', v_b.approved_deliverable_apps,
      'event_apps',                v_b.event_apps,
      'settlement_rows',           v_b.settlement_rows,
      'unpaid_count',              v_b.unpaid_count
    ),
    'active_request',
      CASE WHEN v_has_active
        THEN jsonb_build_object(
               'status',         v_active.status,
               'scheduled_date', v_active.scheduled_date)
        ELSE NULL
      END
  );
END;
$$;

COMMENT ON FUNCTION public.get_withdrawal_precheck(uuid) IS
  '[353] 탈퇴 화면이 **누르기 전에** 부르는 조회. mode 3종(open/locked_auto/'
  'locked_support)을 서버가 정해 주므로 화면은 mode 만 보고 그린다 — 시행 후 '
  '화면을 고칠 자리가 없다. 걸린 것 건수·진행 중 신청도 함께 준다. **시행일 '
  '날짜는 반환하지 않는다.** 인자 없으면 본인, 값을 주면 그 회원(관리자만).';

REVOKE ALL ON FUNCTION public.get_withdrawal_precheck(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_withdrawal_precheck(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 데이터베이스 적용 후 — 1단계씩 실행, 결과 확인 후 다음으로)
--
-- ⚠️ **[V3] 이후는 SQL 편집기로 검증할 수 없다.** SQL 편집기는 서비스 키라
--    auth.uid() 가 비어 본인 확인 분기(not_authenticated)에서 바로 끝난다.
--    **실제 로그인한 브라우저 콘솔**에서 해야 한다(마이그레이션 272·332 와
--    같은 함정).
-- ============================================================
/*

-- ── SQL 편집기에서 (구조 확인) ──────────────────────────────

-- [V0] 표가 생겼고 행이 1개이며 날짜가 NULL 인가
SELECT id, effective_date, description FROM public.withdrawal_settings;
-- 기대: 1행, effective_date = NULL

-- [V1] 판정 함수 — 날짜가 NULL 이므로 false(잠김)
SELECT public.is_withdrawal_open();
-- 기대: false

-- [V2] 헬퍼가 도는가 (아무 인플루언서 1명으로 — 숫자 4개가 나오면 된다)
SELECT * FROM public._withdrawal_lock_blockers(
  (SELECT id FROM public.influencers WHERE is_audit = false LIMIT 1)
);
-- 기대: 정수 4칸. 오류가 나면 자료형·컬럼 참조 문제(42804·42702) —
--       「적용 성공」은 함수 본문을 검사하지 않는다(.claude/rules/supabase.md)

-- [V2-b] 표 권한 — 관리자만 읽어야 한다. 정책이 붙었는지 목록으로 확인
SELECT policyname, cmd FROM pg_policies
 WHERE schemaname = 'public' AND tablename = 'withdrawal_settings';
-- 기대: withdrawal_settings_select(SELECT) · withdrawal_settings_update(UPDATE) 2행


-- ── 로그인한 브라우저 콘솔에서 (개발서버) ─────────────────────

-- [V3] 깨끗한 인플루언서 계정으로 로그인 후:
--   await db.rpc('get_withdrawal_precheck', {})
--   기대: { ok:true, mode:'locked_auto', is_open:false,
--           blockers:{ 전부 0 }, active_request:null }

-- [V4] 걸린 것이 있는 계정(승인된 결과물 · 행사 응모 · 정산 기록 · 미지급 중
--      하나라도)으로:
--   await db.rpc('get_withdrawal_precheck', {})
--   기대: mode:'locked_support' 이고 blockers 의 **해당 종류만** 0보다 크다
--   ★ haruka.test@reverb.jp 는 「정산 행 0건 · 미지급 2건」이라 이 항목의 산
--     증거다 — 반드시 포함할 것. unpaid_count 만 0보다 커야 한다

-- [V5] 시행일을 어제로 넣고(관리자·최고 관리자 세션 또는 SQL 편집기에서
--      UPDATE public.withdrawal_settings SET effective_date = (now() AT TIME ZONE 'Asia/Tokyo')::date - 1 WHERE id = 1;)
--      [V4] 계정에서 다시:
--   await db.rpc('get_withdrawal_precheck', {})
--   기대: mode:'open' — **새로고침만으로** 열린다(사람이 켜는 곳이 없다)

-- [V6] 브라우저 시계를 앞당겨도 안 열리는지 — 시행일을 내일로 바꾼 뒤
--      기기 날짜를 모레로 돌리고 다시 호출
--   기대: 여전히 mode 가 locked_* (판정이 서버라서)

-- [V7] 남의 것 조회 — 인플루언서 계정에서 다른 회원 아이디를 넣어
--   await db.rpc('get_withdrawal_precheck', {p_influencer_id:'<다른 사람 uuid>'})
--   기대: { ok:false, reason:'forbidden' }
--   같은 호출을 관리자 계정에서 하면 정상 반환

-- [V8] 감사용 계정으로
--   기대: { ok:false, reason:'audit_account_blocked' }

-- [V9] 검증 끝나면 **반드시** 시행일을 NULL 로 되돌린다
--   UPDATE public.withdrawal_settings SET effective_date = NULL WHERE id = 1;
--   SELECT public.is_withdrawal_open();  -- 기대: false

*/
