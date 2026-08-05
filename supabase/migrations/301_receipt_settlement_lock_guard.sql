-- ============================================================
-- 301_receipt_settlement_lock_guard.sql
-- 정산이 이미 처리된 응모에 영수증을 새로 제출하는 것을 데이터베이스에서 차단
-- 사양서: docs/specs/2026-08-05-settlement-receipt-amount-switch.md §3-4 ★(영수증 신규
--   제출 가드) — 「단계 배정」 표에 따라 이 마이그레이션의 서버 차단만 1단계 범위이고,
--   인플루언서 화면 사유 안내(2.5단계)·관리자 화면 경고(2단계)·영수증 사후 수정 재계산
--   가드(2단계)는 이번 범위 밖이다.
--
-- ── 왜 막아야 하는가 ──
--   영수증(kind='receipt')은 재제출할 때마다 기존 행을 재사용하지 않고 **새 행이
--   쌓인다**(§1-3 — review_image/post 와 달리 "기존 행 교체" 분기가 storage.js
--   insertDraftDeliverable() 에 없다). 정산(settlements) 은 그 응모의 "최신 영수증"
--   (receipt_latest — 마이그레이션 300 헬퍼, submitted_at DESC 최신 1건)을 근거로
--   금액을 계산해 이미 저장했다. 정산이 만들어진 뒤에 그보다 나중 시각의 새 영수증
--   행이 하나라도 생기면, 그 순간부터 "최신 영수증"의 정의가 바뀌어 판정·금액이
--   가리키는 행이 서로 어긋난다 — §3-1 "판정·금액 단일 소스" 원칙이 깨지는 지점.
--
-- ── 무엇을 막는가 ──
--   그 응모(application_id)에 status IN ('paid','on_hold') 인 정산행이
--   하나라도 있으면, 그 응모에 새로 kind='receipt' 행을 draft 또는 pending 상태로
--   저장(INSERT 또는 UPDATE)하는 것을 막는다. **정산대기(pending) 상태는 막지 않는다**
--   (사양서 §3-4 — 정산대기는 제출은 허용하되 관리자 화면에 경고만 띄운다. 그 경고
--   UI·제출 시 정산액 재계산은 2단계 범위).
--
-- ── 왜 취소(cancelled)는 막지 않는가 (2026-08-05 사용자 결정) ──
--   초안은 관리자 영수증 수정 가드와 같은 3종 집합으로 맞췄다가 뺐다. 두 가드는 목적이
--   다르다 — 관리자 금액 수정 차단은 "확정된 금전 기록이 흔들리는 것"을 막는 것이라
--   취소분에도 타당하지만, 영수증 제출 차단은 "정산 금액과 영수증이 어긋나는 것"을
--   막는 것이고 **취소된 정산은 지급 자체를 하지 않으므로 어긋날 금액이 없다.**
--   ⚠️ 결정적 이유: 취소(cancelled)는 **되돌아올 길이 없는 종료 상태**다.
--   mark_settlement_revert(224)는 on_hold 에서만 pending 으로 되돌리고, 관리자 화면에도
--   cancelled 행에는 처리 버튼이 없으며, settlement_events 의 ON DELETE RESTRICT 때문에
--   정산행 삭제도 사실상 불가능하다. 여기에 영수증 제출까지 막으면 그 응모는 **영구히
--   새 영수증을 못 내는 상태로 굳는다**(인플루언서가 갇힘).
--
-- ── 왜 INSERT 뿐 아니라 UPDATE 도 막는가 ──
--   실제 저장 경로는 두 단계다: ①storage.js insertDraftDeliverable() 가 새 행을
--   status='draft' 로 INSERT ②같은 화면의 "提出" 버튼이 submitDrafts() 를 호출해
--   그 행을 status='pending' 으로 UPDATE. ①에서 막으면 ②까지 갈 필요가 없는 게
--   보통이지만, "정산이 아직 없을 때 draft 를 만들어 두고 한참 뒤에야 제출 버튼을
--   누르는" 순서가 뒤바뀐 경우 ①은 통과하고 그 사이에 정산이 paid/on_hold
--   가 될 수 있다 — 이때 ②(UPDATE)도 막아야 실제로 안전하다. 그래서 BEFORE INSERT
--   OR UPDATE 로 둘 다 검사한다.
--
-- ── 왜 kind='receipt' 로만 좁히는가 ──
--   이 문제(정산 생성 후 "최신 행"이 바뀌는 위험)는 §1-3 이 지적한 대로 영수증에만
--   있다 — review_image·post 는 채널당 1행을 그대로 UPDATE 로 재사용하므로 새 행이
--   추가되지 않는다(created_at 이 바뀌지 않아 receipt_latest 류 CTE 의 "최신" 판정에
--   영향이 없다). 다른 kind 까지 이 트리거로 막으면 근거 없는 과잉 차단이 된다.
--
-- ── 관리자 경로가 걸리지 않는 근거(직접 추적 확인) ──
--   - 관리자 대리 등록(admin_create_deliverable_proxy, 마이그레이션 160)은 영수증을
--     INSERT 할 때 항상 status='approved' 로 즉시 저장한다(160 섹션 6 "⑦ deliverables
--     INSERT — status='approved'"). 이 트리거는 NEW.status IN ('draft','pending') 일 때만
--     차단하므로, 'approved' 로 들어오는 대리 등록 INSERT 는 조건 자체에 걸리지 않는다
--     — is_admin() 예외를 별도로 둘 필요조차 없지만, 아래 판정 함수는 방어적으로
--     관리자를 먼저 통과시킨다(대리 등록 외에 향후 관리자 경로가 draft/pending 상태로
--     영수증을 만들 가능성에 대비한 안전판, 274 의 관리자 예외와 같은 사고방식).
--   - 관리자 영수증 사후 수정(update_receipt_admin, 마이그레이션 178)은 order_number·
--     purchase_date·purchase_amount 3개 컬럼만 UPDATE 하고 status 는 건드리지 않는다
--     (178 SQL: "UPDATE public.deliverables SET order_number=…, purchase_date=…,
--     purchase_amount=…" — status 없음). 즉 NEW.status = OLD.status 로 유지되고,
--     정산이 존재하는 응모의 영수증은 정의상 이미 승인(approved)된 행이므로
--     NEW.status IN ('draft','pending') 에 해당하지 않는다 — 애초에 이 트리거의
--     검사 대상이 아니다. (다만 178 이 편집하는 대상 행의 상태가 어떤 이유로든
--     draft/pending 이면 관리자 예외로 통과시킨다 — 아래 판정 함수 참고.)
--
-- ── 이 마이그레이션이 다루지 않는 것(2단계로 이월, 사양서 §4) ──
--   - 정산대기(pending) 상태에서 새 영수증이 승인됐을 때 정산액을 다시 계산하는 로직
--     (§3-1 스냅샷 예외, §3-4 "영수증 수정 가드(재계산 포함)") — 2단계.
--   - 관리자 화면의 "정산 후 영수증이 다시 제출됨" 경고 UI — 2단계.
--   - 인플루언서 화면에 "이미 정산 처리된 응모라 제출할 수 없습니다" 를 일본어로
--     안내하는 문구(dev/js/ui.js friendlyErrorJa) — 2.5단계. 이 마이그레이션 배포
--     직후에는 차단될 때 원문 예외 메시지(한국어)가 그대로 노출된다. 자동 백필
--     (cutoff_at 미설정, §1-5)이 꺼져 있고 실제로 이 트리거에 걸릴 인플루언서가
--     당장은 사실상 없으므로 노출 빈도는 낮지만, 2.5단계 배포 전까지 남는 알려진 간극.
--
-- ── 롤백 ──
--   DROP TRIGGER IF EXISTS trg_receipt_settlement_lock ON public.deliverables;
--   DROP FUNCTION IF EXISTS public.check_receipt_settlement_lock();
-- ============================================================

CREATE OR REPLACE FUNCTION public.check_receipt_settlement_lock()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_locked boolean;
BEGIN
  -- 0. 배치·마이그레이션·서비스 키 — 로그인 세션이 없으면 통과.
  --    (익명 쓰기는 deliverables_insert_own/update_own_* 행 단위 보안 정책이 이미
  --     차단해 여기까지 도달하지 못한다 — 274 와 동일 논리)
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- 1. 관리자 — 대리 등록·사후 수정·되돌리기 전부 면제. 이 가드의 목적은 "인플루언서의
  --    신규 제출"만 막는 것이지, 관리자가 하는 정정·교정 작업을 막는 것이 아니다.
  --    (실제로는 대리 등록이 항상 status='approved' 로 INSERT 하고, 사후 수정은
  --    status 를 건드리지 않아 아래 2번 조건에서도 걸리지 않는 게 보통이지만,
  --    관리자 경로 전반의 방어판으로 명시적으로 먼저 통과시킨다.)
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  -- 2. 영수증이 아니거나(kind<>'receipt') 저장하려는 상태가 draft/pending 이 아니면
  --    (=본인이 만드는 "신규 제출/재제출" 방향 연산이 아니면) 무관 — 통과.
  IF NEW.kind <> 'receipt' OR NEW.status NOT IN ('draft', 'pending') THEN
    RETURN NEW;
  END IF;

  -- 3. 그 응모에 이미 처리된(=더 이상 되돌릴 수 없거나 손댈 필요가 없는) 정산이
  --    있는지 확인. settlements.application_id 는 UNIQUE(마이그레이션 217) 이라
  --    최대 1행만 매칭된다.
  SELECT EXISTS (
    SELECT 1 FROM public.settlements s
     WHERE s.application_id = NEW.application_id
       AND s.status IN ('paid', 'on_hold')  -- cancelled 제외(파일 상단 「왜 취소는 막지 않는가」)
  ) INTO v_locked;

  IF v_locked THEN
    -- 머신 판독용 코드 접두어(콜론 뒤는 한국어 원문 — 인플루언서 대상 일본어 안내로
    -- 바꾸는 작업은 2.5단계, dev/js/ui.js friendlyErrorJa 에 패턴 추가 예정. 파일
    -- 상단 "이 마이그레이션이 다루지 않는 것" 참고).
    RAISE EXCEPTION 'settlement_locked_receipt_submission: 이미 정산 처리된 응모에는 영수증을 새로 제출할 수 없습니다. 문의사항은 관리자에게 연락해 주세요.'
      USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.check_receipt_settlement_lock() IS
  '[301] 정산(settlements)이 paid/on_hold 인 응모에 새 영수증(kind=receipt,
   status IN (draft,pending))을 저장하려 하면 차단하는 트리거 함수. BEFORE INSERT OR
   UPDATE ON deliverables, WHEN(NEW.kind=''receipt''). 정산대기(pending)는 막지 않는다
   (제출은 허용, 재계산·경고 UI는 2단계). 관리자(is_admin())와 로그인 세션 없는 호출은
   면제. 사양서 docs/specs/2026-08-05-settlement-receipt-amount-switch.md §3-4 ★.';

DROP TRIGGER IF EXISTS trg_receipt_settlement_lock ON public.deliverables;
CREATE TRIGGER trg_receipt_settlement_lock
  BEFORE INSERT OR UPDATE ON public.deliverables
  FOR EACH ROW
  WHEN (NEW.kind = 'receipt')
  EXECUTE FUNCTION public.check_receipt_settlement_lock();

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
--   ⚠️ 마이그레이션 299·300 까지 적용된 뒤에 실행할 것(settlements 표·함수 의존 없음이지만
--   같은 기능 세트이므로 순서를 맞춘다).
-- ============================================================
/*

-- [V0] 함수·트리거 생성 확인
SELECT p.proname, p.prosecdef,
       t.tgname, t.tgenabled
  FROM pg_proc p
  LEFT JOIN pg_trigger t ON t.tgfoid = p.oid
 WHERE p.proname = 'check_receipt_settlement_lock'
   AND p.pronamespace = 'public'::regnamespace;
-- 기대: prosecdef=true, tgname='trg_receipt_settlement_lock', tgenabled='O'

-- [V1] deliverables 트리거 전체 목록 확인(간섭 재확인 — 5개여야 함: 301 적용 전 4개 + 이번 1개)
SELECT tgname FROM pg_trigger
 WHERE tgrelid = 'public.deliverables'::regclass AND NOT tgisinternal
 ORDER BY tgname;

-- [V2] 테스트 대상 확보 — status IN ('paid','on_hold') 정산이 걸린 응모 1건
SELECT s.application_id, s.status, a.user_id
  FROM public.settlements s
  JOIN public.applications a ON a.id = s.application_id
 WHERE s.status IN ('paid', 'on_hold')
 LIMIT 1;

-- [V2-b] 취소(cancelled)는 막지 않는다는 것도 함께 확인할 대상 — 이 응모에서는
--   영수증 신규 제출이 **정상 동작해야** 한다(막히면 잘못된 것).
SELECT s.application_id, s.status, a.user_id
  FROM public.settlements s
  JOIN public.applications a ON a.id = s.application_id
 WHERE s.status = 'cancelled'
 LIMIT 1;

-- [V3] 실제 차단 확인 (SQL Editor 는 서비스 키라 auth.uid() 가 NULL 로 통과되어 이
--   트리거를 있는 그대로 재현하지 못함 — 274 와 동일 제약). 아래 두 방법 중 하나:
--
--   방법 1 (권장) — 개발서버에 실제 로그인한 인플루언서 브라우저에서, 정산이 paid/
--   on_hold 인 응모의 활동관리 화면에 진입해 영수증을 새로 제출해 본다.
--   → 「settlement_locked_receipt_submission: …」 오류가 나야 한다.
--   반대로 정산이 pending·cancelled 인 응모에서는 **정상 제출돼야** 한다.
--
--   방법 2 — SQL Editor 에서 request.jwt.claims 를 흉내내 auth.uid() 를 설정(272·274
--   와 동일 패턴). 반드시 ROLLBACK 할 것:
--   BEGIN;
--     SELECT set_config('request.jwt.claims',
--       json_build_object('sub', '<위 V2 에서 확보한 user_id>')::text, true);
--     INSERT INTO public.deliverables (application_id, user_id, campaign_id, kind, status, receipt_url)
--     VALUES ('<위 V2 의 application_id>'::uuid, '<user_id>'::uuid,
--             (SELECT campaign_id FROM public.applications WHERE id = '<application_id>'),
--             'receipt', 'draft', 'https://example.com/test.jpg');
--     -- 기대: ERROR: settlement_locked_receipt_submission: 이미 정산 처리된 응모에는 ...
--   ROLLBACK;

-- [V4] 정산대기(pending)는 막히지 않는지 확인(회귀) — status='pending' 인 정산이 걸린
--   응모로 같은 절차(V3 방법 1 또는 2)를 반복. 정상적으로 draft 저장이 성공해야 한다.

-- [V5] 관리자 대리 등록·영수증 수정이 여전히 정상 동작하는지(회귀) — 개발서버 관리자
--   화면에서 정산이 paid 인 응모를 골라 ①대리 등록(영수증) ②영수증 인플레이스 수정을
--   각각 시도. 둘 다 차단 없이 정상 저장되어야 한다.

*/
