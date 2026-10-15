---
description: 일일 메일 3종(브랜드·관리자·인플루언서)·수신자 단위 발송 기록·1,000행 상한 — 세 함수에 같은 본문(복사 목록)이 있다(묶음 규칙)
paths:
  - "supabase/functions/notify-brand-daily-digest/**"
  - "supabase/functions/notify-admin-daily-digest/**"
  - "supabase/functions/notify-influencer-daily-digest/**"
  - "dev/js/admin-brand-ops.js"
  - "dev/lib/storage.js"
  - "supabase/migrations/*digest*"
  - "supabase/migrations/*action_alert*"
  - "supabase/migrations/*cert_success*"
  - "supabase/migrations/164_*"
---

# 일일 메일 3종·발송 기록 (CLAUDE.md 메일 파이프라인 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **브랜드 일일 보고** (`notify-brand-daily-digest`, 마이그203·cron 204): pg_cron 매일 KST 09:00(job `brand-daily-digest-0900kst`). 시각 기준 2섹션: 신규=`orient_sheets.submitted_at` 어제 KST / 재제출=`last_submitted_at` 어제 KST AND `submitted_at` < 어제시작. `brand_daily_digest_runs.digest_date UNIQUE` mutex + `digest_email_sent`(423). 0건=미발송. 수신자 = `get_subscribed_admin_emails('brand_digest')` + env `NOTIFY_ADMIN_EMAILS`(`lookup_values` `admin_email_kind` 코드 `brand_digest`). 사양서 `docs/specs/2026-06-30-orient-submit-notification.md`
- **관리자 일일 통합 다이제스트** (`notify-admin-daily-digest`): pg_cron 매일 KST 09:00. **5섹션** 1통(신청 접수·응모 취소·결과물 제출·재처리·**조치가 필요한 캠페인**), 캠페인별 표. 🔴 **다섯째 절만 시간 창을 안 쓴다**(앞 넷은 「어제 0~24시」) — 「오늘 기준」으로 `get_campaign_action_alerts()`(434)가 판정, **운영현황 일정 뷰도 같은 결과를 읽는다**. ⚠️ 사유 코드 → 문구 표는 **두 벌**(`admin-brand-ops.js` · 메일 함수) — **한쪽만 고치면 다른 말을 한다**. ⚠️ 이 절 때문에 **사실상 매일 발송**(`recruit_low`, 의도). 인증 성공 인원은 `_campaign_cert_success_counts`(현재 원본 **456**, 베이스 433) — **화면 판정 사본, 이제 여섯 곳**(아래 「같은 판정이 여섯 곳에 있다」). `admin_daily_digest_runs.digest_date UNIQUE` mutex + `digest_email_sent`(423). 수신자 = `get_subscribed_admin_emails('daily_digest')` + env `NOTIFY_ADMIN_EMAILS`(164 에서 `application_cancel`·`application_received` → `daily_digest`)
- **인플루언서 일일 다이제스트** (`notify-influencer-daily-digest`): pg_cron 매일 KST 09:00. 어제 신청·승인·반려 + 오늘 D-5/D-1 마감 4섹션. `deadline_reminder_email_sent` 4-tuple UNIQUE 재발송 차단. marketing_opt_in 무시(트랜잭션). ⚠️ **마감 임박 표 INSERT 는 사람별로 그 사람 발송 직후**(423) — 벌크 INSERT 로 되돌리면 반복문 도중 죽을 때 받은 사람의 D-N 행이 빠진다
- **다이제스트 3종의 수신자 단위 발송 기록**(`digest_email_sent`, 마이그레이션 **423** — 사양서 `docs/specs/2026-09-07-digest-per-recipient-send-record.md`): **공용 표 하나**, (종류·날짜·수신자 열쇠) 유일. 인플루언서 = 회원 id(**이메일 안 남김**) / 관리자·브랜드 = `normalizeRecipientKey`(trim+lower). **선점(`failed`+`in_flight@ISO시각`) → 발송 → 성공 뒤에만 `sent`**, 실패 `failed`+`send_failed`, 이메일 없음 `skipped`+`no_email`. 🔴 **선점 조건과 바꾸는 값이 `skip_reason` 한 칸** — 다르면 두 실행이 같은 사람을 잡는다. `CLAIM_STALE_MINUTES=10` 은 **실행 자물쇠 10분과 같아야** 한다. **실행 표 3종 CHECK 에 `partial`**(실패·진행 중·기록 실패가 남으면), 재진입은 `failed 또는 partial`+10분. **재호출은 당일만**. 🔴 **배포 순서 = 데이터베이스 먼저 → 함수** — 반대면 `record_error`(기록 못 하면 안 보낸다)로 그날 통째 `failed`. 발송 **뒤** 기록 실패(`recordLostAfterSend`)는 `partial` — 재호출에 한 통 더 갈 수 있다. ⚠️ **「복사 목록」 9개**(`CLAIM_STALE_MINUTES`·`inFlightMarker`·`staleInFlightCutoff`·`normalizeRecipientKey`·`claimRecipient`·`markSent`·`markFailed`·`markSkipped`·`digestRunStatus`)가 세 함수에 **같은 본문** — 세 벌 함께, diff 0 확인. 종류 값 `promo_admin_summary` 예약만. 90일 정리 `purge_old_digest_email_sent()` pg_cron 03:45(**개발·운영 양쪽**). 화면 없음 — SQL 편집기로만
- **1,000행 상한**(D-7): 다이제스트 3종의 행 조회는 **전부 `fetchAllPaged`**(함수마다 각자 든 도우미)로 감싼다 — 하루 창도 넘는다(하루 검수 1,305건인 날이 있었다) · PostgREST 는 잘려도 표시가 없다. id 목록 조회(`.in("id", …)`)는 **200개씩 끊어**(`fetchByIdsChunked`) 받는다(응답 잘림·주소 길이). 🔴 **인플루언서 일일 메일은 결과물·발송 이력 조회가 실패하면 마감 절을 통째로 건너뛴다** — 실패를 삼키면 **이미 낸 회원에게도 D-5·D-1 안내**가 나간다(`TypeError: Invalid URL` 로 실제로 그랬다). 새 조회는 빌더를 호출마다 새로 만들고 **`id` 정렬**을 반드시 건다
