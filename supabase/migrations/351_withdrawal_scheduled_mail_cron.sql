-- ============================================================
-- 351_withdrawal_scheduled_mail_cron.sql
-- 2026-08-19
--
-- 목적:
--   회원 탈퇴 「대기(pending_payout) → 예정(scheduled)」 전이 메일
--   (notify-withdrawal-scheduled) pg_cron 등록.
--
-- 왜 350 이 아니라 별도 파일인가:
--   350(advance_withdrawal_states.sql)에 이 잡을 함께 넣고 "개발서버에서는
--   이 블록만 건너뛰라"는 경고를 달아 뒀었다. 그 방식은 이 저장소의 SQL
--   실행 안내가 늘 "파일을 통째로 복사해 SQL 편집기에 붙여넣기"이기
--   때문에(.claude/rules/supabase.md 「마이그레이션/SQL 실행 안내 시 절대
--   경로 명시」) 구조적으로 지켜지지 않는다 — 파일 중간의 "여기만 빼고"는
--   사람이 실수하기 딱 좋은 자리다. 이 저장소는 이미 같은 문제를 파일
--   분리로 풀어 놓은 선례가 있다(142·204·258 — 특히 204 는 이 파일과 똑같이
--   "개발: 미등록" 인 경우). 그 관례를 그대로 따른다.
--
--   ⚠️ 350 의 상태 전이 잡(withdrawal-states-advance-daily)은 **분리하지
--   않았다** — 그 잡은 외부 URL 을 부르지 않는 순수 SQL 함수라 개발·운영
--   양쪽에서 그대로 등록해도 위험이 없다. 위험한 건 **바깥(Edge Function)을
--   부르는 이 잡 하나뿐**이라 이것만 뺐다.
--
-- 사양서: docs/specs/2026-08-18-member-withdrawal.md §5-①(Q2 확정)
-- 작업표: docs/specs/2026-08-19-member-withdrawal-breakdown.md 작업 7
--
-- 선행(★필수 — 등록만 하고 아래가 안 갖춰지면 이 잡은 매일 조용히 실패한다):
--   1) 350_advance_withdrawal_states.sql 적용 완료(withdrawal_requests 의
--      scheduled_mail_sent_at·scheduled_mail_attempt_count 컬럼이 존재해야
--      Edge Function 이 읽고 쓸 수 있다).
--   2) supabase/functions/notify-withdrawal-scheduled/ Edge Function 배포
--      완료(그 환경에). 배포 안 된 상태로 이 잡만 등록하면 net.http_post 가
--      매일 404(함수 없음)로 실패한다 — SQL 은 실패를 감지하지 못하고
--      "성공적으로 요청을 큐에 넣었다"로 끝나므로(net.http_post 는 비동기),
--      배포 여부를 반드시 사람이 먼저 확인한다.
--   3) BREVO_API_KEY 등 Edge Function Secrets 설정 완료(그 환경에).
--
-- 발송 주기:
--   매일 09:00 KST (= UTC 00:00)  cron 표현식 '0 0 * * *'
--   (다른 인플루언서 대상 일일 메일 — notify-influencer-daily-digest 등 —
--   과 같은 시각. 상태 전이 자체는 350 이 매일 KST 04:45 에 먼저 돈다.)
--
-- 호출 방식 (142·204·258 과 동일):
--   - URL : https://<project-ref>.functions.supabase.co/notify-withdrawal-scheduled
--   - 인증: vault.decrypted_secrets 의 'edge_function_jwt' (service_role JWT)
--           ← 142·204 와 **같은 이름**을 그대로 쓴다(확인 완료 — 다른 이름을
--           쓰면 등록은 성공하지만 매일 조용히 인증 실패한다).
--   - body: {'source':'cron'} (Edge Function 은 source 를 로그에만 남기고
--           동작 분기에는 안 쓴다 — 대상 조회 자체가 상태값 기준이라
--           수동 호출과 cron 호출을 구분할 필요가 없다)
--
-- ⚠️ URL 의 project-ref 는 환경마다 다르다 — 실행 환경에 맞게 교체:
--   - 운영(production, 도쿄): nrwtujmlbktxjgdwlpjj   ← 아래 기본값
--   - 개발(staging, 도쿄)   : qysmxtipobomefudyixw
--
-- 적용 이력:
--   - 운영: 아직 미적용(2026-08-19 작성 시점 — 이 기능은 시행 전 잠금 상태,
--     작업 15 「시행 전 잠금」이 아직 없어 회원 화면[작업 9]도 없다. 그래도
--     대기(pending_payout) 신청이 생기면 대상이 될 수 있으므로, 350 을
--     운영에 적용하는 시점에 이 파일도 함께 적용하는 것을 권장한다 — 아래
--     「적용 순서」 참고).
--   - 개발: **미등록**(204 와 동일한 이유 — 개발서버 발송 시험 금지 정책,
--     .claude/rules/supabase.md 「메일 발송 테스트 환경 정책」). 필요 시
--     아래 URL 의 project-ref 만 qysmxtipobomefudyixw 로 바꿔 별도로 실행
--     할 수 있으나, 그 경우에도 실제 발송 시험은 하지 않는다(정책 — 대상이
--     0건인 상태에서 등록만 해 두는 것까지는 무방).
--
-- 적용 순서 (350 과의 관계):
--   1. 350 을 개발 데이터베이스에 적용(상태 전이 잡만 등록됨).
--   2. Edge Function 배포:
--        bash scripts/sync-email-templates.sh
--        supabase functions deploy notify-withdrawal-scheduled --project-ref qysmxtipobomefudyixw
--      (개발 — 환경 동기화만, 이 파일은 개발에 적용하지 않으므로 실제 호출은 없다)
--   3. dev → main 머지(운영 배포).
--   4. 350 을 운영 데이터베이스에 적용.
--   5. Edge Function 운영 배포 + secrets 설정:
--        supabase functions deploy notify-withdrawal-scheduled --project-ref nrwtujmlbktxjgdwlpjj
--        supabase secrets set BREVO_API_KEY=... PUBLIC_APP_URL=https://globalreverb.com --project-ref nrwtujmlbktxjgdwlpjj
--   6. **이 파일(351)을 운영 데이터베이스에 적용** — 여기서 처음으로 메일
--      잡이 실제로 등록된다.
--   7. 아래 「적용 후 확인」으로 실제 발송을 검증(운영 전용).
--
-- 롤백:
--   SELECT cron.unschedule('withdrawal-scheduled-mail-daily');
--   ⚠️ 이 잡을 지워도 350 이 만든 컬럼·함수·상태 전이 잡은 그대로 남는다
--   (독립적으로 동작 가능 — 다만 메일이 안 나갈 뿐, 회원은 로그인해 마이
--   페이지에서 직접 확인 가능하다). 반대로 350 을 롤백하려면 **이 파일을
--   먼저** 롤백할 것(350 파일 하단 롤백 절의 경고 참고 — 순서가 바뀌면
--   컬럼이 사라진 채로 이 잡이 계속 돌아 매 실행 실패한다).
-- ============================================================

SELECT cron.unschedule(jobid)
FROM   cron.job
WHERE  jobname = 'withdrawal-scheduled-mail-daily';

SELECT cron.schedule(
  'withdrawal-scheduled-mail-daily',
  '0 0 * * *',                      -- 매일 UTC 00:00 = KST 09:00
  $$
  SELECT net.http_post(
    url     := 'https://nrwtujmlbktxjgdwlpjj.functions.supabase.co/notify-withdrawal-scheduled',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || (
        SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'edge_function_jwt' LIMIT 1
      )
    ),
    body    := jsonb_build_object('source', 'cron')
  );
  $$
);

-- ============================================================
-- 적용 후 확인 (⚠️ 「적용 성공」은 「동작 확인」이 아니다 — .claude/rules/supabase.md
-- 「신규 데이터베이스 함수는 적용 성공이 동작 확인이 아니다」. 1단계씩 순서대로
-- 실행하며 결과를 확인할 것 — 한 번에 다 실행하지 말 것)
-- ============================================================
--
-- [V0] (SQL 편집기 가능 — 읽기 전용) 등록 확인
--   SELECT jobid, jobname, schedule, active, command
--     FROM cron.job WHERE jobname = 'withdrawal-scheduled-mail-daily';
--   기대: 1행, schedule='0 0 * * *', active=true.
--
-- [V1] (SQL 편집기 가능 — 읽기 전용) 대상이 실제로 있는지 확인
--   SELECT id, influencer_id, scheduled_date, scheduled_mail_sent_at
--     FROM public.withdrawal_requests
--    WHERE status = 'scheduled' AND scheduled_mail_sent_at IS NULL;
--   → 운영에 아직 실사용 탈퇴 신청이 없다면 0행일 수 있다(정상 — 이번
--   기능은 시행 전 잠금 상태, 작업 15 이번 범위 밖). 0행이면 수동으로 1건
--   만들어 시험한다(주의 — 운영 데이터에 시험 행을 남기므로 시험 전용
--   계정으로 만들고 시험 후 [V5]로 정리):
--     INSERT INTO public.withdrawal_requests
--       (influencer_id, status, scheduled_date, requested_by_kind)
--     VALUES ('<운영 시험 인플루언서 id>', 'scheduled',
--             (now() AT TIME ZONE 'Asia/Tokyo')::date + 5, 'self');
--
-- [V2] cron 이 도는 시각(KST 09:00)을 기다리거나, 수동으로 즉시 호출:
--     curl -X POST https://nrwtujmlbktxjgdwlpjj.functions.supabase.co/notify-withdrawal-scheduled \
--       -H "Authorization: Bearer <service_role key 또는 edge_function_jwt>" \
--       -H "Content-Type: application/json" -d '{"source":"manual-verify"}'
--   기대: 응답 {"ok":true,"sent":N,"failed":0,...}(N ≥ [V1]에서 확인한 건수).
--
-- [V3] (SQL 편집기 가능 — 읽기 전용) 실제로 표시됐는지 + 받은편지함 도착 확인:
--     SELECT id, scheduled_mail_sent_at, scheduled_mail_attempt_count
--       FROM public.withdrawal_requests WHERE id = '<[V1]에서 쓴 id>';
--   기대: scheduled_mail_sent_at IS NOT NULL. 동시에 그 인플루언서 메일함에
--   실제 메일 도착 확인(제목에 예정일 포함, 4줄 푸터 정상 렌더, LINE·사이트
--   링크 클릭 가능).
--
-- [V4] ★ 재발송 차단 확인. [V2]를 한 번 더 호출(같은 curl):
--   기대: 응답의 sent=0(이미 scheduled_mail_sent_at 이 채워져 대상 조회에서
--   빠짐) — 메일이 중복으로 오지 않았는지 실제 받은편지함에서도 확인.
--
-- [V5] 시험 데이터였다면 정리(실사용 신청이었다면 그대로 둘 것):
--     DELETE FROM public.withdrawal_requests WHERE id = '<시험 id>';
-- ============================================================
