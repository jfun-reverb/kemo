-- ============================================================
-- 418_withdrawal_event_cancel_guards.sql
-- 전수조사 2차(2026-09-02) 3-2(C-2, 중간) + 3-5(C-5, 낮음)
--   docs/research/2026-09-02-codebase-audit-findings.md
--   docs/specs/2026-09-02-audit-remediation-plan.md
--
-- 베이스: 350 의 public._withdrawal_cancel_event_ticket(uuid) — 이 함수를 정의하는
--   파일은 350 하나뿐이다(352·359·369·370 은 호출·권한·주석만). 확인:
--     grep -ln "CREATE OR REPLACE FUNCTION public._withdrawal_cancel_event_ticket" supabase/migrations/*.sql
--
-- 무엇이 문제였나 (3-2)
--   회원 탈퇴 배치(advance_withdrawal_states, 현재 원본 352)가 행사 예약을 자동 취소할 때
--   응모 행을 **직접** cancelled 로 바꾼다. 그러면 320 의 자동 보류 트리거가 그 응모의
--   정산대기를 보류로 돌리고, 미지급 세기(_withdrawal_unpaid_count, 350)는 보류도
--   「받을 돈」으로 세므로 그 회원은 pending_payout 에서 **영영 못 나간다**. 본인 취소
--   (cancel_application 394)는 「승인 결과물 있으면 거부」로 이 상황을 막는데, 이 배치만
--   그 보호를 우회했다(가드가 송금완료 하나뿐).
--
-- 어떻게 고치나
--   가드 둘을 더한다 — ①정산이 정산대기·보류면 취소 안 함 ②정산 행은 없지만 인증 성공
--   (_settlement_cert_candidates() is_success — 미지급 세기 ②와 같은 함수)이면 취소 안 함.
--   둘을 합치면 정확히 _withdrawal_unpaid_count() > 0 인 응모다 — 「받을 돈이 남은 응모의
--   좌석은 배치가 안 건드린다」. 거부는 ok=false 로 돌려주므로 호출부(352)는 종전처럼
--   「정리 못 한 행사 예약 수」로 세어 관리자 화면에 남긴다 — 호출부 변경 없음.
--   ⚠️ 320 트리거를 우회하는 방식(응모는 취소하되 보류만 막기)은 택하지 않았다 — 그러면
--      「받을 돈이 남은 응모가 취소된 상태」가 생겨 정산 화면이 취소 응모의 정산을 다루게 된다.
--   ⚠️ 관리자 수동 취소(288)는 여전히 송금완료만 본다 — 관리자가 손으로 탈퇴 중인 회원의
--      좌석을 지우면 같은 사고(정산대기 → 보류, 사유는 「신청 반려로 자동 보류」)가 그 경로로
--      재현된다. 288 은 운영 중인 함수라 이번에 안 건드린다(350 의 결정 계승) — 후속 과제
--      (계획 문서 C-2 비고). 이 파일의 범위는 자동 배치 하나다.
--
-- 3-5 함께: 세워 둔 통과 표시(reverb.event_ticket_bypass)를 함수 끝에서 끈다.
--   짝이 되는 _withdrawal_cancel_applications(356)은 끄는데 이 함수만 안 껐다.
--
-- 🔴 CREATE OR REPLACE 로만 — 369 가 anon·authenticated 실행 권한을 회수했고
--   이 함수는 호출자 검사가 없어(배치 전용) 그 회수가 유일한 방어선이다. DROP 후
--   CREATE 하면 조용히 풀린다.
--
-- 운영 영향: 행사 기능은 아무도 켠 적이 없어 티켓 0건 — 잠복 결함. 소급 정리 없음.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._withdrawal_cancel_event_ticket(
  p_ticket_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_ticket      public.event_tickets%ROWTYPE;
  v_slot        public.event_slots%ROWTYPE;
  v_camp_title  text;
BEGIN
  SELECT * INTO v_ticket FROM public.event_tickets WHERE id = p_ticket_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  -- 이미 취소돼 있으면(경쟁 상태 — 예: 이 배치가 후보를 뽑은 뒤 관리자가 먼저
  -- 취소한 경우) 아무 일도 하지 않고 조용히 성공으로 본다. 새로 취소한 것은
  -- 아니므로 호출부(advance_withdrawal_states)는 이 경우를 "새로 성공"으로
  -- 세지 않는다(already_cancelled 플래그로 구분).
  IF v_ticket.status = 'cancelled' THEN
    RETURN jsonb_build_object('ok', true, 'already_cancelled', true);
  END IF;

  -- 288 과 동일한 가드 — 이미 입장한 티켓은 취소하지 않는다(파일 헤더 「②
  -- 행사 예약 취소」 절 참고, 288 파일 헤더의 판단 근거를 그대로 계승).
  IF v_ticket.entered_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_entered');
  END IF;

  -- 288 과 동일한 가드 — 송금완료된 정산이 걸려 있으면 취소하지 않는다.
  IF v_ticket.application_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.settlements s
        WHERE s.application_id = v_ticket.application_id
          AND s.status = 'paid'
     ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'settlement_paid_cannot_cancel');
  END IF;

  -- [418] 정산이 **정산대기·보류**여도 취소하지 않는다 — 여기서 응모를 cancelled 로
  --   바꾸면 320 트리거가 정산대기를 보류로 돌리고, _withdrawal_unpaid_count()(350)는
  --   보류도 「받을 돈」으로 세므로 그 회원은 pending_payout 에서 영영 못 나간다.
  --   게다가 그 보류의 사유가 「신청 반려로 자동 보류」로 적혀 관리자가 원인을 오독한다.
  --   본인 취소(cancel_application, 현재 원본 394)와 관리자 취소는 이 자리에 못 오지만
  --   이 배치만 그 보호를 우회하고 있었다(전수조사 2차 3-2).
  IF v_ticket.application_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.settlements s
        WHERE s.application_id = v_ticket.application_id
          AND s.status IN ('pending', 'on_hold')
     ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'settlement_pending_cannot_cancel');
  END IF;

  -- [418] 정산 행은 아직 없지만 **인증 성공**(받을 돈이 생긴) 응모면 취소하지 않는다 —
  --   _withdrawal_unpaid_count()(350) ②와 **같은 판정 함수**(_settlement_cert_candidates,
  --   현재 원본 331)를 쓴다. 응모를 취소하면 그 후보가 사라져 「받을 돈이 있는데
  --   셈에서 빠지는」 반대 방향의 어긋남이 생기기 때문.
  --   ⚠️ 「승인 결과물이 하나라도 있으면」(394 의 기준)으로 잡지 않는다 — 방문형은
  --      현장 사진만 먼저 승인되는 경우가 흔한데, 그건 인증 성공이 아니라 미지급 세기에
  --      안 들어가므로 탈퇴는 done 까지 가 버리고 좌석만 영원히 남는다(검토 지적).
  --      미지급 세기와 같은 함수를 써야 「탈퇴는 끝났는데 좌석은 못 지우는」 틈이 없다.
  IF v_ticket.application_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public._settlement_cert_candidates() c
        WHERE c.application_id = v_ticket.application_id
          AND c.is_success
     ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unpaid_cert_success_cannot_cancel');
  END IF;

  -- 슬롯 행을 잠근다 — _promote_next_event_waitlist·_renumber_event_waitlist
  -- (둘 다 288 신설)는 "호출부가 이미 슬롯 행을 잠근 상태"를 전제로 한다.
  SELECT * INTO v_slot FROM public.event_slots WHERE id = v_ticket.slot_id FOR UPDATE;

  -- 289 의 차단 트리거(guard_event_application_status_change)를 통과하기
  -- 위한 표시 — 288 과 동일한 장치.
  PERFORM set_config('reverb.event_ticket_bypass', 'on', true);

  UPDATE public.event_tickets
     SET status            = 'cancelled',
         waitlist_position = NULL,
         cancelled_at      = now(),
         cancelled_by      = NULL,       -- 사람이 아니다(시스템 배치)
         cancelled_by_role = 'admin',    -- CHECK 이 influencer|admin 뿐 — 'admin' 이
                                          -- "회원 본인이 아니다"를 가장 정확히 반영
         cancelled_by_name = '退会処理（自動）',
         admin_cancel_note = '会員退会に伴う自動キャンセル',
         version           = version + 1
   WHERE id = v_ticket.id;

  IF v_ticket.application_id IS NOT NULL THEN
    UPDATE public.applications
       SET status             = 'cancelled',
           previous_status    = CASE v_ticket.status
                                  WHEN 'confirmed' THEN 'approved'
                                  ELSE 'pending'
                                END,
           cancelled_at       = now(),
           cancel_phase       = 'other',
           -- 288 은 'admin_cancelled' 를 쓰지만, 이 배치는 347 이 이미 시드한
           -- 'withdrawal'(회원 탈퇴)을 쓴다 — 실제 원인이 다르다(위 헤더 참고).
           cancel_reason_code = 'withdrawal'
     WHERE id = v_ticket.application_id;
  END IF;

  -- 확정 자리가 빠졌으면 대기 1번 승격(288 이 뽑아 둔 공용 함수 재사용)
  IF v_ticket.status = 'confirmed' THEN
    PERFORM public._promote_next_event_waitlist(v_slot.id);
  END IF;

  -- 남은 대기자 순번 다시 매기기 — 승격 여부와 무관하게 항상 실행
  PERFORM public._renumber_event_waitlist(v_slot.id);

  -- 회원에게 알린다(best-effort — 288 과 같은 판단: 알림 실패가 취소·승격을
  -- 되돌리면 안 된다).
  BEGIN
    IF v_ticket.application_id IS NOT NULL THEN
      SELECT c.title INTO v_camp_title FROM public.campaigns c WHERE c.id = v_ticket.campaign_id;

      INSERT INTO public.notifications (
        user_id, kind, ref_table, ref_id, title, body
      ) VALUES (
        v_ticket.influencer_id,
        'application_cancelled',   -- 283/288 과 같은 기존 종류 재사용(신규 종류 불필요)
        'applications',
        v_ticket.application_id,
        'ご予約がキャンセルされました',
        COALESCE(v_camp_title, 'イベント')
          -- ⚠️ 「확정에 따라」라고 쓰면 안 된다 — 이 취소는 탈퇴가 확정(done)되기
          --    전, 신청만 들어온 단계에서도 매일 돈다(헤더 ③). 그때 「확정됐다」고
          --    하면 아직 취소할 수 있는 사람에게 거짓말이 된다.
          --    한국어 뜻: 「○○ 예약은 탈퇴 신청에 따라 취소되었습니다.
          --    탈퇴를 취소하셔도 이 예약은 되돌아오지 않습니다. 다시 예약하시려면
          --    캠페인 화면에서 신청해 주세요. 문의는 운영팀으로 연락 주세요.」
          || 'のご予約は、退会のお手続きに伴いキャンセルされました。'
          || '退会をキャンセルされた場合も、このご予約は元に戻りません。'
          || '再度ご予約される場合はキャンペーンページからお申し込みください。'
          || 'ご不明な点がございましたら運営までお問い合わせください。'
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  -- [418] 통과 표시를 끈다(전수조사 2차 3-5) — 트랜잭션 지역 값이라 같은 트랜잭션
  --   안에서 뒤이어 도는 상태 전이·파기가 289 의 응모 상태 가드를 모르고 지나치지 않게.
  --   응모 철회 쪽 _withdrawal_cancel_applications(356)도 자기 표시(reverb.withdrawal_actor_uid —
  --   **별개의 설정 키**, 다른 가드용)를 끝에서 끈다 — 「세운 쪽이 끝에서 끈다」는 관행만 같다.
  --   승격·순번 재정렬 뒤에 둔다(그 둘도 같은 표시를 전제로 돈다).
  PERFORM set_config('reverb.event_ticket_bypass', '', true);

  RETURN jsonb_build_object('ok', true, 'ticket_id', v_ticket.id);
END;
$$;

COMMENT ON FUNCTION public._withdrawal_cancel_event_ticket(uuid) IS
  '[418, 350 재정의] 가드 5종(이미 취소·이미 입장·송금완료 정산·**정산대기/보류 정산·미정산 인증 성공**[418 추가]) '
  '+ 끝에서 통과 표시를 끈다[418]. 아래는 350 원문. — 회원 탈퇴 배치(advance_withdrawal_states) 전용 — 로그인 사용자 개념이 없는 '
  'pg_cron 실행 컨텍스트에서 오프라인 행사 예약(event_tickets) 1건을 취소한다. '
  'cancel_event_ticket(283)·cancel_event_ticket_admin(288)은 auth.uid() 를 요구해 '
  '배치에서 못 쓴다(283·288 은 재정의하지 않는다 — 운영에 이미 배포돼 8/28~30 행사에서 '
  '쓰이는 함수라 재정의 위험이 더 크다고 판단, 위 헤더 「② 행사 예약 취소」 참고). '
  '가드 3종(이미 취소·이미 입장·송금완료 정산)과 UPDATE 로직은 288 을 그대로 '
  '옮겨 적은 것이고, 승격·순번 재정렬은 288 이 뽑아 둔 공용 함수 '
  '_promote_next_event_waitlist·_renumber_event_waitlist 를 재사용한다(복제 아님). '
  '내부 전용(밑줄 접두어) — authenticated 에 GRANT 하지 않는다.';

REVOKE ALL ON FUNCTION public._withdrawal_cancel_event_ticket(uuid) FROM PUBLIC;

-- 369 의 회수는 CREATE OR REPLACE 로 보존된다. 아래는 그 확인용(적용 후 실행).
--   select p.proacl::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--    where n.nspname='public' and p.proname='_withdrawal_cancel_event_ticket';
--   기대: authenticated=·anon= 항목 없음(=X/ 도 없음).

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 — 행사 데이터가 0건이라 시험 행을 심어야 한다. 아래 DO 블록은 마지막에
--   RAISE EXCEPTION 으로 결과를 실어 나르므로 **모든 쓰기가 되돌아간다**(따로 begin/
--   rollback 불필요). 개발(2026-09-07) 실측 결과 — 네 갈래 전부 기대와 일치:
--     1(정산대기)={"ok":false,"reason":"settlement_pending_cannot_cancel"}
--     2(미정산 인증성공)={"ok":false,"reason":"unpaid_cert_success_cannot_cancel"}
--     3(둘다없음)={"ok":true,...} | flag=[] | app3=cancelled | sett1=pending
--     4(승인 결과물은 있으나 인증 성공 아님)={"ok":true,...} — 방문형 현장 사진만 승인된 꼴은 막지 않는다
--   ⚠️ 개발 데이터베이스에는 「미정산 인증 성공」 응모가 0건이라 2번은 블록 안에서
--      기존 게시물을 승인으로 바꾸고 캠페인 보수를 올려 만들었다(전부 되돌아간다).
--   ⚠️ 네 응모는 **서로 다른 회원** 것이어야 하고, 시험 타임은 **티켓이 없는 캠페인**에
--      만들어야 한다 — event_tickets 의 (캠페인, 회원) 활성 티켓 유일 색인 때문.
-- ============================================================
-- DO $$
-- DECLARE
--   v_a1 record; v_a2 record; v_a3 record; v_a4 record;
--   v_camp uuid; v_slot uuid; v_t1 uuid; v_t2 uuid; v_t3 uuid; v_t4 uuid;
--   r1 jsonb; r2 jsonb; r3 jsonb; r4 jsonb; v_flag text; v_st text; v_sett text;
-- BEGIN
--   -- 재료 2: 유보수 시딩·방문형, 채널 1개, 정산 없음 → 게시물을 승인으로 바꿔 「미정산 인증 성공」을 만든다(전부 되돌아간다)
--   SELECT a.id, a.user_id, a.campaign_id, btrim(c.channel) AS ch INTO v_a2 FROM public.applications a
--    JOIN public.campaigns c ON c.id=a.campaign_id JOIN public.influencers i ON i.id=a.user_id
--    WHERE a.status='approved' AND i.is_audit=false AND c.recruit_type IN ('gifting','visit')
--      AND c.channel IS NOT NULL AND position(',' in c.channel)=0 AND btrim(c.channel)<>''
--      AND NOT EXISTS (SELECT 1 FROM public.settlements s WHERE s.application_id=a.id)
--      AND EXISTS (SELECT 1 FROM public.deliverables d WHERE d.application_id=a.id AND d.kind='post')
--    ORDER BY a.created_at DESC LIMIT 1;
--   UPDATE public.campaigns SET reward = GREATEST(COALESCE(reward,0), 1000) WHERE id = v_a2.campaign_id;
--   UPDATE public.deliverables SET status='approved', post_channel=v_a2.ch, reviewed_at=now() WHERE application_id=v_a2.id AND kind='post';
--   IF NOT EXISTS (SELECT 1 FROM public._settlement_cert_candidates() c WHERE c.application_id=v_a2.id AND c.is_success) THEN
--     RAISE EXCEPTION '재료 2 가 인증 성공으로 안 잡힘: app=% ch=%', v_a2.id, v_a2.ch;
--   END IF;
--   -- 재료 1: 승인 응모 + 정산 없음 + 승인 결과물 없음 (정산대기 행을 심는다)
--   SELECT a.id, a.user_id, a.campaign_id INTO v_a1 FROM public.applications a
--    WHERE a.status='approved' AND a.user_id <> v_a2.user_id
--      AND NOT EXISTS (SELECT 1 FROM public.settlements s WHERE s.application_id=a.id)
--      AND NOT EXISTS (SELECT 1 FROM public.deliverables d WHERE d.application_id=a.id AND d.status='approved')
--    ORDER BY a.created_at DESC LIMIT 1;
--   INSERT INTO public.settlements (influencer_id, application_id, campaign_id, amount_jpy, status)
--   VALUES (v_a1.user_id, v_a1.id, v_a1.campaign_id, 1000, 'pending');
--   -- 재료 4: 승인 결과물은 있으나 인증 성공은 아님 (방문형 현장 사진만 승인된 꼴) — 없으면 NULL
--   SELECT a.id, a.user_id, a.campaign_id INTO v_a4 FROM public.applications a
--    WHERE a.status='approved' AND a.user_id NOT IN (v_a1.user_id, v_a2.user_id)
--      AND NOT EXISTS (SELECT 1 FROM public.settlements s WHERE s.application_id=a.id)
--      AND EXISTS (SELECT 1 FROM public.deliverables d WHERE d.application_id=a.id AND d.status='approved')
--      AND NOT EXISTS (SELECT 1 FROM public._settlement_cert_candidates() c WHERE c.application_id=a.id AND c.is_success)
--    ORDER BY a.created_at DESC LIMIT 1;
--   -- 재료 3: 정산도 승인 결과물도 없음
--   SELECT a.id, a.user_id, a.campaign_id INTO v_a3 FROM public.applications a
--    WHERE a.status='approved' AND a.user_id NOT IN (v_a1.user_id, v_a2.user_id, COALESCE(v_a4.user_id, v_a1.user_id))
--      AND NOT EXISTS (SELECT 1 FROM public.settlements s WHERE s.application_id=a.id)
--      AND NOT EXISTS (SELECT 1 FROM public.deliverables d WHERE d.application_id=a.id AND d.status='approved')
--    ORDER BY a.created_at DESC LIMIT 1;
--   -- 시험 타임은 티켓이 하나도 없는 캠페인에 만든다(캠페인×회원 활성 티켓 유일 색인 회피)
--   SELECT c.id INTO v_camp FROM public.campaigns c WHERE NOT EXISTS (SELECT 1 FROM public.event_tickets t WHERE t.campaign_id=c.id) ORDER BY c.created_at DESC LIMIT 1;
--   INSERT INTO public.event_slots (campaign_id, slot_date, start_time, capacity)
--   VALUES (v_camp, current_date + 30, '11:00', 10) RETURNING id INTO v_slot;
--   INSERT INTO public.event_tickets (slot_id, campaign_id, influencer_id, application_id, ticket_code, status)
--   VALUES (v_slot, v_camp, v_a1.user_id, v_a1.id, 'ZZTEST01', 'confirmed') RETURNING id INTO v_t1;
--   INSERT INTO public.event_tickets (slot_id, campaign_id, influencer_id, application_id, ticket_code, status)
--   VALUES (v_slot, v_camp, v_a2.user_id, v_a2.id, 'ZZTEST02', 'confirmed') RETURNING id INTO v_t2;
--   INSERT INTO public.event_tickets (slot_id, campaign_id, influencer_id, application_id, ticket_code, status)
--   VALUES (v_slot, v_camp, v_a3.user_id, v_a3.id, 'ZZTEST03', 'confirmed') RETURNING id INTO v_t3;
--   IF v_a4.id IS NOT NULL THEN
--     INSERT INTO public.event_tickets (slot_id, campaign_id, influencer_id, application_id, ticket_code, status)
--     VALUES (v_slot, v_camp, v_a4.user_id, v_a4.id, 'ZZTEST04', 'confirmed') RETURNING id INTO v_t4;
--   END IF;
--   r1 := public._withdrawal_cancel_event_ticket(v_t1);
--   r2 := public._withdrawal_cancel_event_ticket(v_t2);
--   r3 := public._withdrawal_cancel_event_ticket(v_t3);
--   IF v_t4 IS NOT NULL THEN r4 := public._withdrawal_cancel_event_ticket(v_t4); END IF;
--   v_flag := current_setting('reverb.event_ticket_bypass', true);
--   SELECT status INTO v_st FROM public.applications WHERE id = v_a3.id;
--   SELECT status INTO v_sett FROM public.settlements WHERE application_id = v_a1.id;
--   RAISE EXCEPTION '결과 | 1(정산대기)=% | 2(미정산 인증성공)=% | 3(둘다없음)=% | 4(승인결과물만)=% | flag=[%] | app3=% | sett1=%', r1, r2, r3, r4, v_flag, v_st, v_sett;
-- END $$;
--
-- 되돌리기: 350 파일의 정의를 그대로 다시 CREATE OR REPLACE(가드 둘·표시 끄기만 없어진다).
