-- ============================================================
-- 371_withdrawal_message_attachment_purge_cron.sql
-- 2026-08-21
--
-- 목적:
--   탈퇴 확정 6개월 뒤 **응모건 메시지 첨부 사진** 파기
--   (purge-withdrawal-message-attachments) pg_cron 등록.
--
-- 왜 368 이 아니라 별도 파일인가 (365·351·142·204·258 과 같은 이유):
--   이 잡은 **바깥(Edge Function)을 부른다.** 이 저장소의 SQL 실행 안내는
--   늘 「파일을 통째로 복사해 편집기에 붙여넣기」라, 파일 중간의 「여기만
--   빼고」는 구조적으로 안 지켜진다. 바깥을 부르는 잡만 파일로 분리한다.
--
--   365 와 같이 **개발서버에도 등록한다** — 메일을 안 보내므로
--   「개발서버 발송 시험 금지」 정책의 대상이 아니고, 오히려 개발에서
--   끝까지 돌려 봐야 한다(완료 기준이 「파일이 실제로 사라진 것을 본다」).
--
-- 사양서: docs/specs/2026-08-18-member-withdrawal.md
-- 작업표: docs/specs/2026-08-21-message-attachment-purge-breakdown.md 작업 12-B-3
--
-- 선행 (★필수 — 안 갖춰지면 이 잡은 매일 조용히 실패한다):
--   1) 368_withdrawal_message_attachment_purge.sql 적용 완료
--      (list_pending_… / mark_… 두 함수와
--       application_messages.attachments_purged_at 칸이 있어야 한다).
--   2) supabase/functions/purge-withdrawal-message-attachments/ 배포 완료(그 환경에).
--      ⚠️ 배포 안 된 상태로 이 잡만 등록하면 매일 404 로 실패하는데,
--      net.http_post 는 비동기라 **SQL 쪽은 성공으로 끝난다** — 실패가
--      아무 데도 안 남는다. 배포 여부를 사람이 먼저 확인할 것
--      (`supabase functions list --project-ref <ref>`).
--
-- 실행 시각:
--   매일 UTC 20:30 = **한국·일본 시각 05:30**
--
--   시간표(한국·일본 시각):
--     04:00 위반기록 정리 / 04:15 비밀번호찾기 정리 /
--     04:30 캠페인 보관 삭제·행사 티켓·재가입 해시 정리(셋) /
--     04:45 탈퇴 상태 전이 / 05:00 페이팔 주소 파기(363) /
--     05:15 영수증·인증샷 파기(365) / **05:30 — 이 파일**
--
--   ⚠️ 05:15 가 아니라 05:30 인 이유: 파기끼리 같은 분에 몰리면 하나가
--      실패했을 때 어느 쪽인지 가리기 어렵다(365 와 같은 판단).
--   ⚠️ 04:45(상태 전이)보다 **반드시 뒤여야 한다.**
--
-- 호출 방식 (365·142·204·258·351 과 동일):
--   - URL : https://<project-ref>.functions.supabase.co/purge-withdrawal-message-attachments
--   - 인증: vault.decrypted_secrets 의 'edge_function_jwt' (service_role JWT)
--           ← **같은 이름**을 그대로 쓴다(다른 이름을 쓰면 등록은 성공하지만
--           매일 조용히 인증 실패한다).
--   - body: {'source':'cron'}
--
-- ⚠️ URL 의 project-ref 는 환경마다 다르다 — 실행 환경에 맞게 교체:
--   - 운영(production, 도쿄): nrwtujmlbktxjgdwlpjj   ← 아래 기본값
--   - 개발(staging, 도쿄)   : qysmxtipobomefudyixw
--
-- 적용 이력:
--   - 개발: 미적용(2026-08-21 작성 시점)
--   - 운영: 미적용
--
-- 롤백:
--   SELECT cron.unschedule('withdrawal-message-attachment-purge-daily');
--   ⚠️ 이 잡을 지워도 368 의 칸·함수는 그대로 남는다(파기가 멈출 뿐이고,
--   밀린 건수는 계속 늘어 관리자 화면 경고에 드러난다 — 작업 12-B-5).
--   ⚠️ 368 을 되돌리려면 **이 파일을 먼저** 되돌릴 것.
-- ============================================================

SELECT cron.unschedule(jobid)
FROM   cron.job
WHERE  jobname = 'withdrawal-message-attachment-purge-daily';

SELECT cron.schedule(
  'withdrawal-message-attachment-purge-daily',
  '30 20 * * *',                    -- 매일 UTC 20:30 = 한국·일본 05:30
  $$
  SELECT net.http_post(
    url     := 'https://nrwtujmlbktxjgdwlpjj.functions.supabase.co/purge-withdrawal-message-attachments',
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
-- 적용 후 확인
--
-- 🔴 **완료 기준은 「만들었다」가 아니라 「돌았다」다.**
--    저장소에서 사진이 실제로 사라진 것을 확인하고,
--    일부러 실패시키면 완료 표시가 **안 붙는 것**까지 본다.
--    1단계씩 순서대로.
--
-- ⚠️ 365 와 **확인 방법이 다르다** — 이 통(`application-message-attachments`)은
--    **비공개**라 주소를 브라우저에 붙여넣어도 안 열린다. 아래처럼
--    서비스 키로 목록을 조회해 파일 존재를 확인한다.
-- ============================================================
--
-- [V0] 등록 확인
--   SELECT jobid, jobname, schedule, active FROM cron.job
--    WHERE jobname = 'withdrawal-message-attachment-purge-daily';
--   기대: 1행, schedule='30 20 * * *', active=true.
--
-- [V1] 지금 대상이 있는지 (없는 게 정상 — 확정된 탈퇴가 아직 0건)
--   SELECT count(*) FROM public.list_pending_withdrawal_message_attachment_purge(500);
--   기대: 0.
--
-- [V2] 대상 0건인 채로 한 번 불러 본다(빈손 실행이 정상 종료하는지):
--   curl -X POST https://qysmxtipobomefudyixw.functions.supabase.co/purge-withdrawal-message-attachments \
--     -H "Authorization: Bearer <개발 service_role key>" \
--     -H "Content-Type: application/json" -d '{"source":"manual-verify"}'
--   기대: {"ok":true,"candidates":0,"deleted_files":0,"marked":0}
--
-- ============================================================
-- [V3] ★★★ 진짜 검증 — 개발서버에서 사진이 사라지는 것을 확인한다
-- ============================================================
--   ⚠️ **개발서버에서만.** 운영에서 하지 말 것 — 되돌릴 수 없는 삭제다.
--   ⚠️ 아래는 개발 데이터를 실제로 바꾼다. [V6] 으로 반드시 정리할 것.
--
--   1) 첨부가 실제로 있는 회원 메시지 1건을 고른다:
--        SELECT am.id, am.attachments, a.user_id
--          FROM public.application_messages am
--          JOIN public.applications a ON a.id = am.application_id
--         WHERE am.sender_kind = 'influencer'
--           AND am.attachments <> '[]'::jsonb
--           AND am.attachments_purged_at IS NULL
--         LIMIT 3;
--      → attachments 안의 `path` 값을 적어 둔다.
--
--      ★ 파일이 **지금은 있는지** 먼저 확인(서비스 키 필요):
--        curl -s -X POST "https://qysmxtipobomefudyixw.supabase.co/storage/v1/object/list/application-message-attachments" \
--          -H "Authorization: Bearer <개발 service_role key>" \
--          -H "Content-Type: application/json" \
--          -d '{"prefix":"<path 의 폴더 부분>","limit":100}'
--      기대: 목록에 그 파일 이름이 **있다**.
--
--   2) 그 회원의 탈퇴를 6개월 전에 확정된 것으로 꾸민다:
--        INSERT INTO public.withdrawal_requests
--          (influencer_id, status, requested_by_kind, completed_at)
--        VALUES ('<1)의 user_id>', 'done', 'self', now() - interval '7 months');
--
--   3) 대상으로 잡히는지:
--        SELECT * FROM public.list_pending_withdrawal_message_attachment_purge(10);
--      기대: 1)의 메시지가 나오고 delete_paths 가 **빈 배열이 아니어야** 한다.
--            (빈 배열이면 주소 형식이 안 맞거나 다른 메시지도 그 파일을
--             가리키는 것이다 — keep_paths 를 함께 볼 것.)
--
--   4) [V2] 의 curl 을 다시 실행.
--      기대: {"ok":true,"candidates":N,"deleted_files":N,"marked":N,
--             "deferred_messages":0,...}
--
--   5) ★ **1)의 목록 조회를 다시 한다.**
--      기대: 그 파일 이름이 **목록에서 사라졌다**.
--      → 여기까지 확인해야 끝난 것이다. 데이터베이스만 보고 끝내지 말 것 —
--        표시는 됐는데 파일이 남아 있는 실패가 가장 나쁘다.
--
--   6) 데이터베이스 쪽도 확인:
--        SELECT id, attachments, attachments_purged_at
--          FROM public.application_messages WHERE id = '<1)의 id>';
--      기대: attachments 가 `[{"purged":true}, ...]` (개수는 그대로),
--            attachments_purged_at IS NOT NULL.
--
--   7) ★ **화면도 본다** — 관리자 받은편지함에서 그 대화를 연다.
--      기대: 사진 자리에 「보관기간이 지나 파기됨」 상자가 뜨고,
--            **깨진 이미지 표시가 아니다**(12-B-4 에서 만든 것).
--
-- [V4] ★ 삭제 실패를 실제로 감지하는지 (일부러 실패시켜 본다)
--   Edge Function 의 BUCKET 상수를 존재하지 않는 이름으로 바꿔 배포한 뒤
--   [V3]-2·3·4 를 다시 한다(다른 메시지로).
--   기대: 응답이 **{"ok":false,"error":"bucket_unavailable"}** 이고
--        attachments_purged_at → **NULL 그대로**, attachments 도 **그대로**.
--   확인 뒤 원래 값으로 되돌려 재배포.
--
--   🔴 이 검사가 왜 있는지는 365 [V4] 참고 — 저장소는 **없는 통에 대한
--   삭제도 조용히 성공으로 답한다**(2026-08-20 개발서버 실측). 통 존재
--   확인을 빼면 파일은 남았는데 표시만 붙는다.
--
-- [V5] 재실행이 멱등한지: [V3]-4 의 curl 을 한 번 더.
--   기대: candidates=0 (이미 표시돼 목록에서 빠짐).
--
-- [V6] 시험 데이터 정리 (개발서버):
--   DELETE FROM public.withdrawal_requests
--    WHERE influencer_id = '<[V3]-1)의 user_id>' AND status = 'done';
--   ⚠️ **지워진 사진은 안 돌아온다.** 시험에 쓸 메시지는 없어져도 되는
--      것으로 고를 것.
--
-- [V7] 관리자 브라우저 콘솔(로그인 상태)에서 밀린 건수 3종:
--   await db.rpc('count_overdue_withdrawal_media_purge')
--   await db.rpc('count_overdue_withdrawal_email_blocks')
--   await db.rpc('count_overdue_withdrawal_message_attachment_purge')
--   기대: 셋 다 {data: 0, error: null}.
-- ============================================================
