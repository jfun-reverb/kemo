-- ============================================================
-- 422_withdrawal_guards_deliverable_and_rerequest.sql
-- 전수조사 2차(2026-09-02) 3-6(C-6)·3-7(C-7), 둘 다 낮음 — 탈퇴 확정 계정의 남은 구멍 둘
--   docs/research/2026-09-02-codebase-audit-findings.md
--   docs/specs/2026-09-02-audit-remediation-plan.md
--
-- [A] C-7 — 결과물 제출 차단. 359 는 프로필 수정·응모 삽입·행사 예약 셋을 막았는데 결과물
--     (deliverables) 삽입은 「안 막는 것」 목록에도 없이 빠져 있었다(검토 흔적 없음). 확정된 회원이
--     남은 세션으로 영수증·게시물을 올리면 개인정보(영수증 사진)가 새로 쌓인다. 359 의 응모 가드를
--     **글자 그대로** 따른다 — 판정은 358 `_withdrawal_account_blocked()` 하나, 통과 조항 둘
--     (예약 실행·관리자). ⚠️ 관리자 대리 등록(`admin_create_deliverable_proxy`)은 is_admin() 으로
--     통과한다 — 탈퇴 회원의 결과물을 관리자가 대신 올릴 일은 없지만 막을 이유도 없다.
--     ⚠️ 트리거 이름 `trg_account_withdrawn_guard` — 359 와 같은 이름·같은 이유(알파벳 순으로
--        마감 가드 `trg_deliverable_deadline_guard`(274)보다 먼저 돈다. 뒤면 「마감 지남」이라는
--        엉뚱한 이유가 뜬다).
--     🔴 **INSERT OR UPDATE** 다(검토 지적) — 게시물·리뷰 인증샷 재제출은 새 행이 아니라 **기존 행 UPDATE**
--        (`insertDraftDeliverable`, 채널별 교체)라 INSERT 만 막으면 3종 중 2종의 재제출이 그대로 통과한다.
--        359 가 행사 예약에서 같은 함정(「되살리기는 새 행을 안 만든다」)을 겪고 INSERT OR UPDATE 로 건 것과
--        같은 판단. 관리자 승인·반려·대리 교체는 is_admin() 으로, 예약 파기는 auth.uid() 없음으로 통과한다.
--        본인의 임시저장→제출(`submitDrafts`, 상태만 바뀜)도 막힌다 — 탈퇴 절차 중인 계정이 제출을 마무리하는
--        것을 막는 게 맞다(막히면 화면은 account_withdrawn 문구).
--
-- [B] C-6 — 확정자 재신청 차단. request_withdrawal(357)·request_withdrawal_for_member(357)는
--     「활성 신청(대기·예정)이 있는가」만 봐서, 이미 done 인 회원이 남은 세션으로 다시 신청하면
--     새 줄이 생기고 배치가 그 회원을 한 번 더 확정·파기·(실패하는) 메일 시도까지 한다.
--     두 함수를 재정의하는 대신 withdrawal_requests **삽입 트리거**로 막는다 — 함수 둘(각 150줄)을
--     통째로 다시 베끼는 위험보다 작다. ⚠️ 여기에는 통과 조항이 없다 — 관리자 대행이든 본인이든
--     확정된 회원에게 두 번째 신청은 없다. 오류는 P0001 'already_withdrawn' — 화면 등록 두 곳(ui.js 오류 문구 =
--     account_withdrawn 과 같은 문구 / shared.js 정상 거부 목록)에 함께 넣었다(359 ⑤절 「한 세트」 규약). 확정 회원은
--     이 오류를 실제로 볼 경로는 남은 세션뿐이다.
--
-- 운영 영향: 확정 탈퇴 3건(2026-09-07 실측) — 소급 정리 없음(새 삽입만 막는다).
-- ============================================================

BEGIN;

-- [A] 결과물 삽입 가드 (C-7)
CREATE OR REPLACE FUNCTION public.check_account_withdrawn_deliverable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  IF public._withdrawal_account_blocked(NEW.user_id) THEN
    RAISE EXCEPTION 'account_withdrawn: 탈퇴 절차가 진행 중인 계정입니다'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION public.check_account_withdrawn_deliverable() IS
  '[422] 탈퇴가 확정됐거나 예정일이 지난 회원의 결과물(영수증·게시물·인증샷) 삽입·수정을 막는다 — 재제출은 '
  'UPDATE 라 INSERT OR UPDATE. 판정은 358 의 _withdrawal_account_blocked() 하나(단일 소스). 예약 실행·관리자는 통과 — 359 와 같다.';

DROP TRIGGER IF EXISTS trg_account_withdrawn_guard ON public.deliverables;
CREATE TRIGGER trg_account_withdrawn_guard
  BEFORE INSERT OR UPDATE ON public.deliverables
  FOR EACH ROW EXECUTE FUNCTION public.check_account_withdrawn_deliverable();

-- [B] 확정자 재신청 가드 (C-6)
CREATE OR REPLACE FUNCTION public.check_withdrawal_rerequest()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.withdrawal_requests w
     WHERE w.influencer_id = NEW.influencer_id
       AND w.status = 'done'
  ) THEN
    RAISE EXCEPTION 'already_withdrawn: 이미 탈퇴가 확정된 계정입니다'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION public.check_withdrawal_rerequest() IS
  '[422] 탈퇴가 이미 확정(done)된 회원에게 두 번째 신청 줄이 생기는 것을 막는다. 통과 조항 없음 — '
  '본인·관리자 대행 모두. 357 의 두 신청 함수는 활성 신청만 봐서 확정자를 못 걸렀다.';

DROP TRIGGER IF EXISTS trg_withdrawal_rerequest_guard ON public.withdrawal_requests;
CREATE TRIGGER trg_withdrawal_rerequest_guard
  BEFORE INSERT ON public.withdrawal_requests
  FOR EACH ROW EXECUTE FUNCTION public.check_withdrawal_rerequest();

COMMIT;

-- ── 적용 후 확인 ─────────────────────────────────────────────────
-- [V1] 트리거가 둘 다 걸렸나:
--   select tgrelid::regclass, tgname from pg_trigger
--    where tgname in ('trg_account_withdrawn_guard','trg_withdrawal_rerequest_guard') order by 1;
--   기대: applications·influencers·event_tickets·deliverables 에 trg_account_withdrawn_guard,
--         withdrawal_requests 에 trg_withdrawal_rerequest_guard.
-- [V2] C-6 — done 인 회원으로 삽입 시도(되돌리기):
--   DO $$ DECLARE v uuid; BEGIN
--     SELECT influencer_id INTO v FROM public.withdrawal_requests WHERE status='done' LIMIT 1;
--     IF v IS NULL THEN RAISE EXCEPTION '확정 회원 없음 — 시험 불가'; END IF;
--     INSERT INTO public.withdrawal_requests (influencer_id, status, requested_by_kind) VALUES (v, 'pending_payout', 'self');
--     RAISE EXCEPTION '막히지 않았다 — 결함';
--   END $$;
--   기대: 'already_withdrawn: …' 오류(트리거가 먼저 막는다).
-- [V3] C-7 — 서비스 키(SQL 편집기)로는 auth.uid() 가 비어 통과한다(의도). 실제 차단은 확정 회원의
--   로그인 세션으로만 재현되며, 확정 회원은 로그인이 막혀 있다 → 359 와 같은 한계. 되돌리기 트랜잭션에서
--   `set local role authenticated` + 확정 회원 sub 로 결과물 INSERT 를 시도하면 재현된다:
--   begin; set local role authenticated; select set_config('request.jwt.claims','{"sub":"<done 회원 id>","role":"authenticated"}',true);
--   insert into public.deliverables (application_id, user_id, campaign_id, kind, status) values ('<그 회원 응모 id>', '<done 회원 id>', '<캠페인 id>', 'post', 'pending');
--   rollback;   → 기대: account_withdrawn 오류(행 단위 보안 정책이 먼저 막을 수도 있다 — 그것도 차단이다).
--
-- [실측 블록 — 개발 2026-09-07] 개발에는 확정 탈퇴가 없어 블록 안에서 done 행을 심고 두 가드를 한 번에 시험했다
--   (마지막 RAISE 로 전부 되돌아간다). 결과:
--     C-6 재신청=[already_withdrawn: 이미 탈퇴가 확정된 계정입니다] | C-7 결과물=[account_withdrawn: 탈퇴 절차가 진행 중인 계정입니다]
--   ⚠️ C-7 은 set_config 로 회원 sub 만 흉내 낸 것이라 역할은 postgres 그대로다 — 행 단위 보안 정책은 안 걸리고
--      트리거의 auth.uid() 분기만 확인된다(트리거가 막는 것을 보려는 목적이라 충분).
-- DO $$ DECLARE m uuid; a record; r1 text := 'not-raised'; r2 text := 'not-raised'; BEGIN
--   SELECT a2.user_id, a2.id AS app_id, a2.campaign_id INTO a FROM public.applications a2 JOIN public.influencers i ON i.id=a2.user_id
--    WHERE i.is_audit=false AND NOT EXISTS (SELECT 1 FROM public.withdrawal_requests w WHERE w.influencer_id=a2.user_id) ORDER BY a2.created_at DESC LIMIT 1;
--   m := a.user_id;
--   INSERT INTO public.withdrawal_requests (influencer_id, status, scheduled_date, completed_at, requested_by_kind) VALUES (m, 'done', current_date - 1, now(), 'self');
--   BEGIN INSERT INTO public.withdrawal_requests (influencer_id, status, requested_by_kind) VALUES (m, 'pending_payout', 'self'); EXCEPTION WHEN others THEN r1 := SQLERRM; END;
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
--   BEGIN INSERT INTO public.deliverables (application_id, user_id, campaign_id, kind, status) VALUES (a.app_id, m, a.campaign_id, 'post', 'pending'); EXCEPTION WHEN others THEN r2 := SQLERRM; END;
--   RAISE EXCEPTION 'C-6 재신청=[%] | C-7 결과물=[%]', r1, r2;
-- END $$;
--
-- [실측 2 — INSERT OR UPDATE 로 바꾼 뒤, 개발 2026-09-07] 비관리자 회원의 결과물 UPDATE:
--     uid=<회원> admin=false | C-7 UPDATE=[account_withdrawn: 탈퇴 절차가 진행 중인 계정입니다]
--   ⚠️ 첫 시도는 「막히지 않았다」로 나왔는데, 뽑힌 회원이 **관리자 겸직 계정**이라 is_admin() 통과 조항으로
--      지나간 것이었다(의도된 통과). 시험 재료를 고를 때 admins 에 없는 회원으로 걸러야 한다.
