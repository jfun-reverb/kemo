---
description: 웹훅 메일 — 광고주 접수·오리엔시트 제출·검수 결과·번역, 선점 먼저·요청 본문 불신·호출자 검사(묶음 규칙)
paths:
  - "supabase/functions/notify-brand-application/**"
  - "supabase/functions/notify-orient-submitted/**"
  - "supabase/functions/notify-deliverable-decision/**"
  - "supabase/functions/notify-policy-change/**"
  - "supabase/functions/translate-message/**"
  - "supabase/functions/notify-admin-invite/**"
  - "supabase/functions/notify-orient-sheet/**"
  - "supabase/migrations/*orient_submit*"
  - "supabase/migrations/*orient_notify*"
  - "supabase/migrations/*notifications*"
  - "supabase/functions/notify-admin-daily-digest/**"
  - "supabase/functions/notify-brand-daily-digest/**"
  - "supabase/functions/notify-campaign-promo-digest/**"
  - "supabase/functions/notify-influencer-daily-digest/**"
  - "supabase/functions/notify-withdrawal-scheduled/**"
  - "supabase/functions/purge-withdrawal-message-attachments/**"
  - "supabase/functions/purge-withdrawal-media/**"
  - "supabase/functions/notify-brand-account-setup/**"
  - "supabase/functions/brand-password-reset-request/**"
---

# 웹훅 메일 (CLAUDE.md 메일 파이프라인 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **광고주 신청 접수 알림** (`notify-brand-application`): `brand_applications` INSERT 직후. 수신자 = `get_subscribed_admin_emails('brand_notify')` + env `NOTIFY_ADMIN_EMAILS`
- **오리엔시트 제출 알림** (`notify-orient-submitted`, 마이그레이션 202·234): 제출 즉시 관리자 1인 1통. 트리거 = `orient_sheets` UPDATE 웹훅(Row filter `status='submitted'`). 제목은 `old_record.submitted_at IS NULL` 로 갈린다(「[신규 제출]/[수정 재제출] {브랜드명}」). 본문=브랜드명·형식·제출시각·연결 신청번호·관리자 링크(**`data jsonb` 는 안 싣는다**). 수신자 = `get_subscribed_admin_emails('brand_notify')` + env `NOTIFY_ADMIN_EMAILS`. 제출 트랜잭션과 분리. 🔴 **과다 발송 방지 게이트 2단**(234): ①`last_submitted_at` 이 `old_record` 와 같으면 스킵 — 부분 발행(`mark_orient_card_consumed`)은 `status='submitted'` 유지 UPDATE 라 Row filter 를 재통과한다(**자기 `last_notified_at` UPDATE 무한루프도 이 게이트가 막는다**) ②재제출은 `last_submitted_at - last_notified_at < 30분`이면 스킵, 신규는 항상. 성공 시 `last_notified_at` 갱신. ⚠️ 웹훅·Edge Function 배포는 **Dashboard 수동**(개발·운영 각각). 사양서 `docs/specs/2026-06-30-orient-submit-notification.md`
- **알림 1건 = 메일 1통인 함수는 「선점 먼저」**(D-19 — `notify-deliverable-decision`): `UPDATE notifications SET mail_sent_at = now() WHERE id = … AND mail_sent_at IS NULL` 이 0행이면 종료, 통과한 실행만 보낸다(실패면 선점을 되돌린다). 「SELECT → 발송 → UPDATE」는 웹훅 재시도가 겹치면 **두 번** 나간다. ⚠️ **선점 상태는 「진행 중」이어야 한다**(D-9, `notify-policy-change`): `sent` 로 먼저 넣으면 죽은 회원이 영원히 「보냄」이고 유일 제약이 재시도도 막는다 → `failed`+`in_flight@시각` 선점, 성공 뒤 `sent`. 🔴 **재시도 선점은 조건과 바뀌는 값이 같은 칸이어야 한다** — `status=failed` 는 두고 `skip_reason` 만 바꾸면 여러 실행이 동시에 잡는다. D-19 는 `mail_sent_at IS NULL` 과 `mail_sent_at` 이 같은 칸이라 안전
- **웹훅 메일은 요청 본문을 믿지 않는다**(전수조사 3차 ④-4): `notify-deliverable-decision` 은 선점 UPDATE 가 돌려준 알림 행 값으로, `notify-brand-application` 은 신청 행을 다시 읽어 받는 사람·내용을 정한다(본문에서는 id 만). 🔴 **`translate-message` 는 호출자 검사가 빠져 있었다**(2026-10-01 추가 — 회원이 남의 메시지 번역문을 덮어쓸 수 있었다) — 지금은 같은 검사 + 메시지 행 재조회 + 이미 처리된 메시지는 재번역 안 함. 그래서 **같은 검사 본문(`rejectPublicKeyCaller`)을 가진 웹훅 함수는 12개**. 점검 결과 `notify-admin-invite`(최고 관리자 + 대상이 관리자 행)·`notify-orient-sheet`(관리자만, 수신 주소 지정은 의도) 은 안전, `notify-orient-submitted` 는 수신자가 DB 관리자 목록이라 낮음(본문 내용만 페이로드)
- **브랜드 계정 메일 두 함수**(마이그레이션 527 과 짝 — 🔴 **개발서버만**, 운영 보류. 사양서 `docs/specs/2026-07-15-brand-portal.md` §16-6 · 작업표 `docs/specs/2026-10-14-brand-login-breakdown.md`): 둘 다 **웹훅이 아니라 화면이 직접 부른다** — 그래서 위 `rejectPublicKeyCaller` 검사가 **일부러 없고** 12개 수에 안 든다(설정 메일은 관리자 화면이 브라우저에서 부르고, 비밀번호 찾기는 비로그인 공개). 이 검사를 「빠졌다」고 넣으면 두 화면이 전부 막힌다
  - `notify-brand-account-setup`(설정 메일): 캠페인 관리자 이상만, **받는 사람은 서버가 `brand_id` 로 다시 읽는다**(요청 본문 불신 — 위 원칙 그대로). 링크 번호를 발송 **전에** 교체하므로 발송 실패면 옛 링크도 무효 — 「다시 보내기」로 복구. 🔴 개발서버 두 겹 잠금(`BRAND_SETUP_DEV_ECHO=1` **그리고** 개발 프로젝트 주소)일 때만 메일 대신 응답에 `dev_link` — 하나라도 지우면 운영에서 링크가 응답에 실린다. **운영에 `BRAND_SETUP_DEV_ECHO` 를 넣지 않는다**. 비밀값 `PUBLIC_BRAND_URL` 기본값 없음
  - `brand-password-reset-request`(비밀번호 찾기): 늘 `200 {ok:true}`·최소 2.5초. 🔴 실제 처리는 `EdgeRuntime.waitUntil` 로 **응답 뒤에** — 기다렸다 응답하면 걸린 시간으로 브랜드 계정 여부가 드러난다. 🔴 개발서버 잠금이어도 **응답·로그에 링크를 싣지 않는다**(공개 함수라 누구나 남의 재설정 링크를 받게 된다). ⚠️ 설정 메일의 「다시 보냄」 문구 사본이 두 함수에 한 벌씩 — 고치면 둘 다
