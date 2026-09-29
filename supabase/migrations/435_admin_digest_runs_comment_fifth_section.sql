-- ============================================================
-- 435_admin_digest_runs_comment_fifth_section.sql
-- 관리자 일일 메일 「조치가 필요한 캠페인」 절 — 낡아진 칸 주석 정정
--
-- 관리자 일일 통합 다이제스트가 **네 절에서 다섯 절**이 되면서(2026-09-11,
-- 마이그레이션 434 + Edge Function notify-admin-daily-digest) 실행 기록 표의
-- 칸 주석 **둘**이 거짓이 됐다.
--
--   · status          — 「skipped_no_data (4섹션 모두 0건)」
--   · sections_summary — 「4섹션 건수 {…키 넷…}」
--
-- 🔴 **둘이다.** 사양서 §3-4 는 sections_summary 하나만 적었는데, 착수 전 코드
--    대조에서 status 쪽도 같이 낡는다는 것이 나왔다(132_admin_daily_digest_runs.sql:74).
--    한쪽만 고치면 다음 사람이 나머지를 현재 동작으로 읽는다.
--
-- ⚠️ **이미 적용된 132 파일을 고치지 않는다** — 새 마이그레이션으로만 덮어쓴다.
--    (적용된 파일을 고치면 이미 돈 데이터베이스와 저장소가 갈린다.)
--
-- ⚠️ 표 구조는 안 바꾼다 — sections_summary 가 jsonb 라 키가 늘어도 그대로다.
--
-- ⚠️ 이 마이그레이션은 **주석만** 바꾼다. 동작 영향 0, 되돌릴 것도 없다.
--
-- 사양서: docs/specs/2026-09-11-admin-digest-deadline-section.md §3-4
-- 착수 전 대조: docs/specs/2026-09-11-admin-digest-deadline-section-precheck.md
-- ============================================================

BEGIN;

COMMENT ON COLUMN public.admin_daily_digest_runs.status IS
  'sent (정상 발송) / skipped_no_data (5섹션 모두 0건) / failed (오류 또는 in-flight 크래시). '
  '⚠️ 다섯째 절(조치가 필요한 캠페인)은 시간 창을 안 쓰는 「오늘 기준」 판정이라, '
  '앞 네 절이 0건인 날에도 이 절이 있으면 발송된다 — 그래서 skipped_no_data 는 예전보다 드물다.';

COMMENT ON COLUMN public.admin_daily_digest_runs.sections_summary IS
  '5섹션 건수 {"received": N, "cancelled": N, "submitted": N, "reprocessed": N, "action": N}. '
  'action = 조치가 필요한 캠페인(마이그레이션 434 get_campaign_action_alerts, 2026-09-11 신설). '
  '⚠️ 앞 네 절은 감사용 계정을 뺀 뒤의 수이고, action 은 서버 함수가 이미 빼고 세어 돌려준 수다.';

COMMIT;

/* ────────────────────────────────────────────────────────────
   적용 뒤 확인

   [V1] 두 주석이 새 문구인지 — 「5섹션」이 둘 다 보여야 한다.
     SELECT a.attname, col_description(a.attrelid, a.attnum) AS comment
       FROM pg_attribute a
      WHERE a.attrelid = 'public.admin_daily_digest_runs'::regclass
        AND a.attname IN ('status', 'sections_summary')
      ORDER BY a.attname;

   ⚠️ 실행 기록에 실제로 다섯째 키가 들어가는지는 **여기서 확인 못 한다.**
      그 행을 쓰는 것은 메일 함수 본체뿐이고 개발서버에서 돌리면 메일이 나간다
      (저장소 규칙상 금지). 더미 스크립트는 발송 없이 본문만 뽑아 실행 기록을 안 남긴다.
      → **운영 배포 뒤 첫 발송**에서 확인한다(사양서 §3-6 ⑥).
   ──────────────────────────────────────────────────────────── */

-- 롤백: 필요 없다(주석뿐). 되돌리려면 132 의 옛 문구로 COMMENT 를 다시 건다.
