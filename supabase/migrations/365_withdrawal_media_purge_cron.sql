-- ============================================================
-- 365_withdrawal_media_purge_cron.sql
-- 2026-08-20
--
-- 목적:
--   탈퇴 확정 6개월 뒤 영수증·인증샷 파일 파기(purge-withdrawal-media)
--   pg_cron 등록.
--
-- 왜 364 가 아니라 별도 파일인가 (351·142·204·258 과 같은 이유):
--   이 잡은 **바깥(Edge Function)을 부른다.** 이 저장소의 SQL 실행 안내는
--   늘 「파일을 통째로 복사해 편집기에 붙여넣기」라, 파일 중간의 「여기만
--   빼고」는 구조적으로 안 지켜진다. 그래서 바깥을 부르는 잡만 파일로
--   분리하는 관례가 있다.
--
--   ⚠️ 다만 351(메일)과 **다른 점이 하나 있다: 이 잡은 개발서버에도
--   등록한다.**
--     - 351 을 개발에 안 넣은 이유는 「개발서버 메일 발송 시험 금지」
--       정책이었다(.claude/rules/supabase.md).
--     - 이 함수는 **메일을 안 보낸다.** Brevo 를 쓰지 않고 저장소 파일만
--       지운다. 그 정책의 대상이 아니다.
--     - 오히려 개발에서 **끝까지 돌려 봐야 한다** — 작업 12 의 완료 기준이
--       「만들었다」가 아니라 「저장소에서 파일이 실제로 사라진 것을 눈으로
--       본다」이기 때문이다.
--
-- 사양서: docs/specs/2026-08-18-member-withdrawal.md
-- 작업표: docs/specs/2026-08-19-member-withdrawal-breakdown.md 작업 12
--
-- 선행 (★필수 — 아래가 안 갖춰지면 이 잡은 매일 조용히 실패한다):
--   1) 364_withdrawal_media_purge.sql 적용 완료
--      (list_pending_withdrawal_media_purge / mark_withdrawal_media_purged
--       두 함수와 deliverables.media_purged_at 칸이 있어야 한다).
--   2) supabase/functions/purge-withdrawal-media/ 배포 완료(그 환경에).
--      ⚠️ 배포 안 된 상태로 이 잡만 등록하면 매일 404 로 실패하는데,
--      net.http_post 는 비동기라 **SQL 쪽은 성공으로 끝난다** — 실패가
--      아무 데도 안 남는다. 배포 여부를 사람이 먼저 확인할 것.
--
-- 실행 시각:
--   매일 UTC 20:15 = **한국·일본 시각 05:15**
--
--   시간표(한국·일본 시각):
--     04:00 위반기록 정리 / 04:15 비밀번호찾기 정리 /
--     04:30 캠페인 보관 삭제·행사 티켓·재가입 해시 정리(셋) /
--     04:45 탈퇴 상태 전이 / 05:00 페이팔 주소 파기(363) /
--     **05:15 — 이 파일**
--
--   ⚠️ 05:00 이 아니라 05:15 인 이유: 파기 두 개가 같은 분에 몰리면 하나가
--      실패했을 때 어느 쪽인지 가리기 어렵다.
--   ⚠️ 04:45(상태 전이)보다 **반드시 뒤여야 한다** — 그날 확정(done)된 건이
--      이 실행에 포함되려면 상태 전이가 먼저 돌아야 한다. 실제로는 확정
--      6개월 뒤가 대상이라 같은 날 확정분이 바로 대상이 되지는 않지만,
--      순서를 뒤집을 이유가 없다.
--
-- 호출 방식 (142·204·258·351 과 동일):
--   - URL : https://<project-ref>.functions.supabase.co/purge-withdrawal-media
--   - 인증: vault.decrypted_secrets 의 'edge_function_jwt' (service_role JWT)
--           ← 142·204·351 과 **같은 이름**을 그대로 쓴다(다른 이름을 쓰면
--           등록은 성공하지만 매일 조용히 인증 실패한다).
--   - body: {'source':'cron'}
--
-- ⚠️ URL 의 project-ref 는 환경마다 다르다 — 실행 환경에 맞게 교체:
--   - 운영(production, 도쿄): nrwtujmlbktxjgdwlpjj   ← 아래 기본값
--   - 개발(staging, 도쿄)   : qysmxtipobomefudyixw
--
-- 적용 이력:
--   - 개발: 미적용(2026-08-20 작성 시점)
--   - 운영: 미적용
--
-- 롤백:
--   SELECT cron.unschedule('withdrawal-media-purge-daily');
--   ⚠️ 이 잡을 지워도 364 의 칸·함수는 그대로 남는다(파기가 멈출 뿐이고,
--   밀린 건수는 계속 늘어 관리자 화면 경고에 드러난다 — 작업 14).
--   ⚠️ 364 를 되돌리려면 **이 파일을 먼저** 되돌릴 것. 순서가 바뀌면 함수가
--   사라진 채로 이 잡이 계속 돌아 매 실행 실패한다.
-- ============================================================

SELECT cron.unschedule(jobid)
FROM   cron.job
WHERE  jobname = 'withdrawal-media-purge-daily';

SELECT cron.schedule(
  'withdrawal-media-purge-daily',
  '15 20 * * *',                    -- 매일 UTC 20:15 = 한국·일본 05:15
  $$
  SELECT net.http_post(
    url     := 'https://nrwtujmlbktxjgdwlpjj.functions.supabase.co/purge-withdrawal-media',
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
-- 🔴 **이 작업의 완료 기준은 「만들었다」가 아니라 「돌았다」다.**
--    저장소에서 파일이 실제로 사라진 것을 눈으로 보고,
--    일부러 실패시키면 완료 표시가 **안 붙는 것**까지 확인한다.
--    1단계씩 순서대로 진행할 것.
-- ============================================================
--
-- [V0] 등록 확인
--   SELECT jobid, jobname, schedule, active FROM cron.job
--    WHERE jobname = 'withdrawal-media-purge-daily';
--   기대: 1행, schedule='15 20 * * *', active=true.
--
-- [V1] 지금 대상이 있는지 (없는 게 정상 — 확정된 탈퇴가 아직 0건)
--   SELECT count(*) FROM public.list_pending_withdrawal_media_purge(500);
--   기대: 0.
--
-- [V2] 대상 0건인 채로 한 번 불러 본다(빈손 실행이 정상 종료하는지):
--   curl -X POST https://qysmxtipobomefudyixw.functions.supabase.co/purge-withdrawal-media \
--     -H "Authorization: Bearer <개발 service_role key>" \
--     -H "Content-Type: application/json" -d '{"source":"manual-verify"}'
--   기대: {"ok":true,"candidates":0,"deleted_files":0,"marked":0}
--
-- ============================================================
-- [V3] ★★★ 진짜 검증 — 개발서버에서 파일이 사라지는 것을 눈으로 본다
-- ============================================================
--   ⚠️ **개발서버에서만.** 운영에서 하지 말 것 — 되돌릴 수 없는 삭제다.
--   ⚠️ 아래는 개발 데이터를 실제로 바꾼다. [V6] 으로 반드시 정리할 것.
--
--   1) 시험용 결과물 1건을 고른다(영수증 주소가 실제로 있는 것):
--        SELECT id, user_id, kind, receipt_url FROM public.deliverables
--         WHERE kind IN ('receipt','review_image') AND receipt_url IS NOT NULL
--         LIMIT 3;
--      → 그 주소를 브라우저에 붙여넣어 **파일이 지금은 열리는지** 먼저 확인.
--        (열려야 한다 — campaign-images 는 공개 통이다.)
--
--   2) 그 회원의 탈퇴를 6개월 전에 확정된 것으로 꾸민다:
--        INSERT INTO public.withdrawal_requests
--          (influencer_id, status, requested_by_kind, completed_at)
--        VALUES ('<1)의 user_id>', 'done', 'self', now() - interval '7 months');
--
--   3) 대상으로 잡히는지:
--        SELECT * FROM public.list_pending_withdrawal_media_purge(10);
--      기대: 1)의 결과물이 나오고 storage_path 가 'receipts/...' 형태이며
--            **NULL 이 아니어야** 한다. should_delete_file 도 확인.
--
--   4) [V2] 의 curl 을 다시 실행.
--      기대: {"ok":true,"candidates":N,"deleted_files":N,"marked":N,...}
--
--   5) ★ **1)의 주소를 브라우저에서 다시 열어 본다.**
--      기대: **파일이 없다**(404 / "Object not found").
--      → 여기까지 확인해야 이 작업이 끝난 것이다. 데이터베이스만 보고
--        끝내지 말 것 — 표시는 됐는데 파일이 남아 있는 실패가 이 기능에서
--        가장 나쁜 실패다.
--
--      🔴 **주소창에 그냥 열면 지워진 뒤에도 파일이 그대로 보인다**
--      (2026-08-20 실측 — 브라우저·전송망 캐시). 「안 지워졌다」고
--      오판하기 딱 좋은 자리다. **캐시를 우회해서** 확인할 것 —
--      브라우저 콘솔에서:
--        await fetch(URL+'?cb='+Math.random(),{cache:'no-store'})
--             .then(r=>r.status)
--      기대: **400**(본문이 {"statusCode":"404","error":"not_found"}).
--
--      ⚠️ 이 캐시는 파기 뒤에도 한동안 남는다는 뜻이기도 하다. 개인정보
--      파기 관점에서 「즉시 접근 불가」가 아니라 **「원본은 지워졌고 캐시는
--      만료를 기다린다」**가 정확한 서술이다 — 방침 문구를 쓸 때 참고.
--
--   6) 데이터베이스 쪽도 확인:
--        SELECT id, receipt_url, media_purged_at FROM public.deliverables
--         WHERE id = '<1)의 id>';
--      기대: receipt_url IS NULL, media_purged_at IS NOT NULL.
--
-- [V4] ★ 삭제 실패를 실제로 감지하는지 (일부러 실패시켜 본다)
--   Edge Function 의 BUCKET 상수를 존재하지 않는 이름으로 바꿔 배포한 뒤
--   [V3]-2·3·4 를 다시 한다(다른 결과물로).
--   기대: 응답이 **{"ok":false,"error":"bucket_unavailable"}** 이고
--        SELECT media_purged_at ... → **NULL 그대로**, receipt_url 도 **그대로**.
--   확인 뒤 원래 값으로 되돌려 재배포.
--
--   🔴 **이 단계에서 실제로 결함을 하나 잡았다(2026-08-20 개발서버).**
--   처음 판본에는 통 존재 검사가 없었고, 그 상태로 돌리니
--   **`remove()` 가 없는 통에 대해서도 오류를 내지 않아** 파기 표시가
--   그대로 붙었다(`marked:1`) — 파일은 남아 있는데 주소 칸만 비워진,
--   이 기능에서 가장 나쁜 실패다. Edge Function 앞에 통 존재 확인을
--   넣어 해결했다. **그 검사를 지우면 이 실패가 그대로 되살아난다.**
--
--   ⚠️ 「없는 파일」과 「없는 통」을 응답으로 구분하려 하지 말 것 —
--   저장소는 둘 다 성공으로 답한다. 통은 시작할 때 한 번만 확인하고,
--   그 뒤로는 빈 결과를 「이미 없음」으로 안전하게 해석한다.
--
-- [V5] 재실행이 멱등한지: [V3]-4 의 curl 을 한 번 더.
--   기대: candidates=0 (이미 표시돼 목록에서 빠짐).
--
-- [V6] 시험 데이터 정리 (개발서버):
--   DELETE FROM public.withdrawal_requests
--    WHERE influencer_id = '<[V3]-1)의 user_id>' AND status = 'done';
--   ⚠️ **지워진 파일은 안 돌아온다.** 시험에 쓸 결과물은 없어져도 되는
--      것으로 고를 것.
--
-- [V7] 관리자 브라우저 콘솔(로그인 상태)에서 밀린 건수 2종:
--   await db.rpc('count_overdue_withdrawal_media_purge')
--   await db.rpc('count_overdue_withdrawal_email_blocks')
--   기대: 둘 다 {data: 0, error: null}.
-- ============================================================
