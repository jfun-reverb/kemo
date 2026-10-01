# REVERB JP — 인플루언서 체험단 플랫폼

> 이 문서는 **현재 가동 중인 동작·핵심 컨벤션** 위주. 마이그레이션 번호·PR 노트·deprecated 메모 등 이력성 메타데이터는 [`docs/CLAUDE-ARCHIVE.md`](docs/CLAUDE-ARCHIVE.md) 참조.

## Overview
일본 시장 대상 인플루언서 체험단(리뷰어/기프팅/방문형) 모집 플랫폼.
브랜드가 캠페인을 등록하고, 인플루언서가 신청하는 구조.

## Tech Stack
- Language: HTML/CSS/JavaScript (vanilla, 프레임워크 없음)
- Backend: Supabase (Auth + Database + Storage) + localStorage 폴백
- Deployment: Vercel Pro (Team 플랜)
- Package Manager: 없음 (CDN 기반)
  - 🔴 **supabase-js 는 CDN 에서 `@2.116.0/dist/umd/supabase.js` 로 버전을 고정**(8개 HTML — 인플·관리자·`admin-setpw`·`event-scan`·`report`·sales 3종). `@2` 로 두면 배포 없이 라이브러리가 바뀐다. 올릴 때는 **여덟 줄을 같은 문자열로** 함께 올린다

## Key URLs
- 운영 (인플루언서): https://globalreverb.com
- 운영 (관리자): https://globalreverb.com/admin/
- 운영 (광고주 신청 폼): https://sales.globalreverb.com (별도 Vercel 프로젝트 `reverb-sales`, Root Directory=`sales/`)
- 스테이징 (인플루언서): https://dev.globalreverb.com
- 스테이징 (관리자): https://dev.globalreverb.com/admin/ (admin@kemo.jp / admin1234)
- GitHub: github.com/jfun-reverb/kemo
- Supabase (production): https://nrwtujmlbktxjgdwlpjj.supabase.co (🇯🇵 Tokyo `ap-northeast-1`, Pro/MICRO 1GB — 경위·메모리 현황은 `.claude/rules/supabase.md`)
- Supabase (staging): https://qysmxtipobomefudyixw.supabase.co (🇯🇵 Tokyo `ap-northeast-1`, Pro/MICRO)
- LINE: @reverb.jp

## Environments
- **도메인 기반 자동 분기**: `dev/lib/supabase.js`의 `resolveSupabaseEnv()`가 `location.hostname` 판별
  - `globalreverb.com`, `www.globalreverb.com` → 운영서버 Supabase
  - 그 외 (dev.globalreverb.com, localhost 등) → 개발서버 Supabase
- Supabase URL/Key는 `SUPABASE_ENVS` 객체에서만 관리 (다른 파일 하드코딩 금지)
- 관리자 페이지 헤더에 개발서버에서만 주황색 `STAGING` 배지 + `[DEV]` 탭 제목/파비콘 표시
- 운영 배포는 반드시 개발서버 검증 후 main merge
- Supabase Client 옵션: `flowType: 'pkce'`, `detectSessionInUrl: true` (비밀번호 재설정 안정성)

## Email / SMTP
- 양 서버 모두 **Brevo Custom SMTP** 사용 (`smtp-relay.brevo.com:587`)
- **Brevo 플랜: Starter 20,000 emails/월**(Marketing+Transactional 공용, 일일 한도 없음). 🔴 **금액·용량·갱신일은 이 문서가 아니라 Brevo 「Usage and plan」에서 볼 것**. 🔴 **구독이 만료되면 Brevo 는 오류 없이 조용히 큐에 쌓는다** — 모든 메일이 멈춰도 회원 문의로만 안다. 진단은 `.claude/rules/supabase.md` 「메일이 안 나갈 때 보는 순서」
- 발신: `noreply@globalreverb.com`, 발신명: 운영 `REVERB JP` / 개발 `REVERB JP [DEV]`
- 발신 도메인 DNS 인증 완료 (SPF/DKIM/DMARC, cafe24 DNS 관리)

### 가동 중인 메일 파이프라인 (세부 구현은 `supabase/functions/*` + 사양서가 source of truth)
- **광고주 신청 접수 알림** (`notify-brand-application`): `brand_applications` INSERT 직후. 수신자 = `get_subscribed_admin_emails('brand_notify')` + env `NOTIFY_ADMIN_EMAILS`
- **오리엔시트 제출 알림** (`notify-orient-submitted`, 마이그레이션 202·234): 제출 즉시 관리자 1인 1통. 트리거 = `orient_sheets` UPDATE 웹훅(Row filter `status='submitted'`). 제목은 `old_record.submitted_at IS NULL` 로 갈린다(「[신규 제출]/[수정 재제출] {브랜드명}」). 본문=브랜드명·형식·제출시각·연결 신청번호·관리자 링크(**`data jsonb` 는 안 싣는다**). 수신자 = `get_subscribed_admin_emails('brand_notify')` + env `NOTIFY_ADMIN_EMAILS`. 제출 트랜잭션과 분리. 🔴 **과다 발송 방지 게이트 2단**(234): ①`last_submitted_at` 이 `old_record` 와 같으면 스킵 — 부분 발행(`mark_orient_card_consumed`)은 `status='submitted'` 유지 UPDATE 라 Row filter 를 재통과한다(**자기 `last_notified_at` UPDATE 무한루프도 이 게이트가 막는다**) ②재제출은 `last_submitted_at - last_notified_at < 30분`이면 스킵, 신규는 항상. 성공 시 `last_notified_at` 갱신. ⚠️ 웹훅·Edge Function 배포는 **Dashboard 수동**(개발·운영 각각). 사양서 `docs/specs/2026-06-30-orient-submit-notification.md`
- **브랜드 일일 보고** (`notify-brand-daily-digest`, 마이그203·cron 204): pg_cron 매일 KST 09:00(job `brand-daily-digest-0900kst`). 시각 기준 2섹션: 신규=`orient_sheets.submitted_at` 어제 KST / 재제출=`last_submitted_at` 어제 KST AND `submitted_at` < 어제시작. `brand_daily_digest_runs.digest_date UNIQUE` mutex + `digest_email_sent`(423). 0건=미발송. 수신자 = `get_subscribed_admin_emails('brand_digest')` + env `NOTIFY_ADMIN_EMAILS`(`lookup_values` `admin_email_kind` 코드 `brand_digest`). 사양서 `docs/specs/2026-06-30-orient-submit-notification.md`
- **관리자 일일 통합 다이제스트** (`notify-admin-daily-digest`): pg_cron 매일 KST 09:00. **5섹션** 1통(신청 접수·응모 취소·결과물 제출·재처리·**조치가 필요한 캠페인**), 캠페인별 표. 🔴 **다섯째 절만 시간 창을 안 쓴다**(앞 넷은 「어제 0~24시」) — 「오늘 기준」으로 `get_campaign_action_alerts()`(434)가 판정, **운영현황 일정 뷰도 같은 결과를 읽는다**. ⚠️ 사유 코드 → 문구 표는 **두 벌**(`admin-brand-ops.js` · 메일 함수) — **한쪽만 고치면 다른 말을 한다**. ⚠️ 이 절 때문에 **사실상 매일 발송**(`recruit_low`, 의도). 인증 성공 인원은 `_campaign_cert_success_counts`(현재 원본 **456**, 베이스 433) — **화면 판정 사본, 이제 여섯 곳**(아래 「같은 판정이 여섯 곳에 있다」). `admin_daily_digest_runs.digest_date UNIQUE` mutex + `digest_email_sent`(423). 수신자 = `get_subscribed_admin_emails('daily_digest')` + env `NOTIFY_ADMIN_EMAILS`(164 에서 `application_cancel`·`application_received` → `daily_digest`)
- **인플루언서 일일 다이제스트** (`notify-influencer-daily-digest`): pg_cron 매일 KST 09:00. 어제 신청·승인·반려 + 오늘 D-5/D-1 마감 4섹션. `deadline_reminder_email_sent` 4-tuple UNIQUE 재발송 차단. marketing_opt_in 무시(트랜잭션). ⚠️ **마감 임박 표 INSERT 는 사람별로 그 사람 발송 직후**(423) — 벌크 INSERT 로 되돌리면 반복문 도중 죽을 때 받은 사람의 D-N 행이 빠진다
- **다이제스트 3종의 수신자 단위 발송 기록**(`digest_email_sent`, 마이그레이션 **423** — 사양서 `docs/specs/2026-09-07-digest-per-recipient-send-record.md`): **공용 표 하나**, (종류·날짜·수신자 열쇠) 유일. 인플루언서 = 회원 id(**이메일 안 남김**) / 관리자·브랜드 = `normalizeRecipientKey`(trim+lower). **선점(`failed`+`in_flight@ISO시각`) → 발송 → 성공 뒤에만 `sent`**, 실패 `failed`+`send_failed`, 이메일 없음 `skipped`+`no_email`. 🔴 **선점 조건과 바꾸는 값이 `skip_reason` 한 칸** — 다르면 두 실행이 같은 사람을 잡는다. `CLAIM_STALE_MINUTES=10` 은 **실행 자물쇠 10분과 같아야** 한다. **실행 표 3종 CHECK 에 `partial`**(실패·진행 중·기록 실패가 남으면), 재진입은 `failed 또는 partial`+10분. **재호출은 당일만**. 🔴 **배포 순서 = 데이터베이스 먼저 → 함수** — 반대면 `record_error`(기록 못 하면 안 보낸다)로 그날 통째 `failed`. 발송 **뒤** 기록 실패(`recordLostAfterSend`)는 `partial` — 재호출에 한 통 더 갈 수 있다. ⚠️ **「복사 목록」 9개**(`CLAIM_STALE_MINUTES`·`inFlightMarker`·`staleInFlightCutoff`·`normalizeRecipientKey`·`claimRecipient`·`markSent`·`markFailed`·`markSkipped`·`digestRunStatus`)가 세 함수에 **같은 본문** — 세 벌 함께, diff 0 확인. 종류 값 `promo_admin_summary` 예약만. 90일 정리 `purge_old_digest_email_sent()` pg_cron 03:45(**개발·운영 양쪽**). 화면 없음 — SQL 편집기로만
- **캠페인 홍보 메일** (`notify-campaign-promo-digest`): pg_cron 월·목 09:00. 🔴 **신규 = 모집 시작(`first_active_at`, 도쿄 날짜)이 발송일-13 ~ 발송일이고 마감이 다음 발송일 뒤이거나 없음 / 마감 임박 = 마감이 발송일(당일 포함) ~ 다음 발송일**(471. 다음 발송일은 `_promo_next_send_date` **한 벌**. 종류 값 `deadline_d1`·변수 `d1` 은 옛 이름). `first_active_at` 은 **삽입 때도** 기록(470). `marketing_opt_in=true` + 자격 맞는 인플루언서에게 1통씩(노출 최대 2회·클릭하면 제외), 첫 배치에서 `campaign_promo` 토글 관리자에게도. 🔴 **채널 문지기가 따로 있다** — `get_promo_digest_targets`(현재 원본 **471** — 141→143→259→321→360→387→417→471. ⚠️ **375 는 권한만 손댔다**. 풀 `get_promo_digest_campaign_pool` 도 471)가 **네 채널(instagram·tiktok·x·youtube)만** 안다 → **Qoo10·LIPS·@cosme 만 쓰는 캠페인은 대상이 아니다**. ⚠️ **결함이 아니라 결정이다** — 프로필에 그 칸이 없어 더하면 **채널 없는 사람에게도 나간다**. ⚠️ `_meets_min_followers` 를 고쳐도 문지기 때문에 **효과가 절반만 난다.** 🔴 **그 함수를 고칠 때** — 375 가 실행 권한을 회수했다(전엔 **로그인한 회원 누구나** 남의 이메일·이름·**수신거부 토큰**을 받아 남의 수신 설정을 끌 수 있었다). **`CREATE OR REPLACE` 는 권한 보존, `DROP` 후 `CREATE` 는 회수가 풀린다**(오류 없음). 375 순서는 **부여 먼저, 회수 나중**(`GRANT … TO postgres, service_role` → `REVOKE … FROM PUBLIC` → `REVOKE … FROM anon, authenticated`) — **회수만 넣으면 홍보 메일이 죽는다.** 두 줄인 이유는 「함수 실행 권한」 항목. 사양서 `docs/specs/2026-05-27-admin-promo-email-subscription.md`
- **약관·방침 개정 통지 메일**(`notify-policy-change`, **수동 1회 호출**. 전 회원 1인 1통, 수신 동의 무관): 🔴 **통지마다 갈아 끼울 자리가 넷** — ①`docs/email-templates/policy-change-notice.html`(→ 동기화 스크립트가 `_templates/` 와 **`templates.ts`** 생성, 함수는 `templates.ts` 를 읽는다) ②`CURRENT_NOTICE`(키·시행일) ③제목 ④텍스트 판 — **뒤 셋은 `index.ts` 에 박혀** 템플릿만 바꾸면 옛 제목으로 나간다. **탈퇴 확정 회원**(`@deleted.reverbjp.invalid`)은 `skipped`/`withdrawn`(진행 중 회원은 받는다). `noticeKey`·`effectiveDate` 가 `CURRENT_NOTICE` 와 다르면 **시험 발송까지 거부**(`notice_mismatch`) — 옛 키면 받은 회원이 「이미 받음」으로 빠진다. ⚠️ 짝인 **앱 안 공지**는 `POLICY_NOTICE`(shared.js) + `policyNotice.*`(ja·ko) — `id` 도 통지마다 새 값(옛 값이면 공지를 닫은 회원에게 안 뜬다). 메일 템플릿에 지금 든 것 = 개인정보처리방침 개정(메타 픽셀, 시행 2026-10-17). ⚠️ **앱 안 공지는 일반 문의 창구 공지(`inquiryDesk2026`, 시행 2026-10-06, 메일 통지 없음)로 바뀌어 메일과 짝이 아니다** — 공지 틀이 하나뿐이라 픽셀 공지를 대체했다(사용자 결정). 사양서 `docs/specs/2026-09-17-meta-pixel-policy-notice.md`
- **알림 1건 = 메일 1통인 함수는 「선점 먼저」**(D-19 — `notify-deliverable-decision`): `UPDATE notifications SET mail_sent_at = now() WHERE id = … AND mail_sent_at IS NULL` 이 0행이면 종료, 통과한 실행만 보낸다(실패면 선점을 되돌린다). 「SELECT → 발송 → UPDATE」는 웹훅 재시도가 겹치면 **두 번** 나간다. ⚠️ **선점 상태는 「진행 중」이어야 한다**(D-9, `notify-policy-change`): `sent` 로 먼저 넣으면 죽은 회원이 영원히 「보냄」이고 유일 제약이 재시도도 막는다 → `failed`+`in_flight@시각` 선점, 성공 뒤 `sent`. 🔴 **재시도 선점은 조건과 바뀌는 값이 같은 칸이어야 한다** — `status=failed` 는 두고 `skip_reason` 만 바꾸면 여러 실행이 동시에 잡는다. D-19 는 `mail_sent_at IS NULL` 과 `mail_sent_at` 이 같은 칸이라 안전
- **1,000행 상한**(D-7): 다이제스트 3종의 행 조회는 **전부 `fetchAllPaged`**(함수마다 각자 든 도우미)로 감싼다 — 하루 창도 넘는다(하루 검수 1,305건인 날이 있었다) · PostgREST 는 잘려도 표시가 없다. id 목록 조회(`.in("id", …)`)는 **200개씩 끊어**(`fetchByIdsChunked`) 받는다(응답 잘림·주소 길이). 🔴 **인플루언서 일일 메일은 결과물·발송 이력 조회가 실패하면 마감 절을 통째로 건너뛴다** — 실패를 삼키면 **이미 낸 회원에게도 D-5·D-1 안내**가 나간다(`TypeError: Invalid URL` 로 실제로 그랬다). 새 조회는 빌더를 호출마다 새로 만들고 **`id` 정렬**을 반드시 건다
- **웹훅 메일은 요청 본문을 믿지 않는다**(전수조사 3차 ④-4): `notify-deliverable-decision` 은 선점 UPDATE 가 돌려준 알림 행 값으로, `notify-brand-application` 은 신청 행을 다시 읽어 받는 사람·내용을 정한다(본문에서는 id 만). 🔴 **`translate-message` 는 호출자 검사가 빠져 있었다**(2026-10-01 추가 — 회원이 남의 메시지 번역문을 덮어쓸 수 있었다) — 지금은 같은 검사 + 메시지 행 재조회 + 이미 처리된 메시지는 재번역 안 함. 그래서 **같은 검사 본문(`rejectPublicKeyCaller`)을 가진 웹훅 함수는 12개**. 점검 결과 `notify-admin-invite`(최고 관리자 + 대상이 관리자 행)·`notify-orient-sheet`(관리자만, 수신 주소 지정은 의도) 은 안전, `notify-orient-submitted` 는 수신자가 DB 관리자 목록이라 낮음(본문 내용만 페이로드)
- **공통 패턴**: ①인플 대상 메일은 **4줄 푸터 필수**(自動送信 안내·LINE @reverb.jp·© JFUN·사이트 URL, 글자색 #999) — 신규 인플 메일 추가 시 의무 ②관리자 일괄 발송은 **1명당 1통 분리**(To 헤더 노출 차단) ③부분 실패는 `status='sent'`+실패 명단 누적(전원 실패만 `failed`)
- **메일 템플릿**: `docs/email-templates/` 가 source of truth(카탈로그 `index.html`). Edge Function 은 `_templates/` 미러를 `render({{key}})` 로 읽음 — 배포 전 `scripts/sync-email-templates.sh` 동기화 필수

### Auth URL Configuration
- 운영: Site URL `https://globalreverb.com` + Redirect `https://globalreverb.com/**`, `https://www.globalreverb.com/**`
- 개발: Site URL `https://dev.globalreverb.com` + Redirect `https://dev.globalreverb.com/**`

### Auth Rate Limits
- 운영: `Rate limit for sending emails` = **100 emails/h** (가입+초대+재설정 메일 공용)
- 개발: 기본값 30/h (Confirm email OFF, 트래픽 적어 충분)
- 한도 소진 시 `429 email rate limit exceeded`. Logs & Analytics → Auth 에서 확인

## i18n
- 인플루언서 페이지 KO/JA 토글 (마이페이지 메뉴)
- 키-값: `dev/lib/i18n/{ja,ko}.js`, 런타임: `dev/lib/i18n/index.js`
- HTML: `data-i18n="key"` (textContent), `data-i18n-html="key"` (innerHTML, `<br>` 허용)
- JS 동적: `t('key')` 헬퍼
- 기본값 `ja`, navigator.language 자동 감지 사용 안 함
- ⚠️ **운영 빌드에도 실려 있다**(`main` 산출물에 `setLang('ja')`·`setLang('ko')`·번역 런타임). **화면에 토글이 보이는지**는 미확인 — 운영에서 켤지 판단하려면 먼저 눈으로 볼 것
- 적용 범위: 마이페이지, 인증, GNB/홈, 캠페인 목록·상세, 신청 모달, 활동관리, 알림, DB 에러 메시지 로케일 분기 (`friendlyErrorJa`)

## 내부 문서 (개발서버 한정)
- `docs/service-flow.html` — 전체 서비스 플로우차트
- `docs/flowchart-i18n.html` — i18n 다국어 흐름도
- 접속: https://dev.globalreverb.com/docs/service-flow.html, https://dev.globalreverb.com/docs/flowchart-i18n.html
- **운영서버(main)에 머지하지 않음** — 내부 직원용 참고 자료

## Architecture
- 인플루언서 앱: `dev/index.html` (모바일 480px, GNB + 우측 슬라이드 햄버거 메뉴)
- 관리자 앱: `dev/admin/index.html` (PC 전체폭, 별도 페이지, **2단 고정 레이아웃** — 사이드바/메인 독립 스크롤, 상단 GNB 없음)
- **광고주 신청 앱(sales)**: `sales/{index,reviewer,seeding}.html` — **별도 Vercel 프로젝트 `reverb-sales`**(Root Directory=`sales/`), `sales.globalreverb.com` / `sales-dev.globalreverb.com`. anon 이 `submit_brand_application` 을 거쳐 `brand_applications` 에 넣는다. `cleanUrls`+catch-all rewrite 로 `/reviewer` → `reviewer.html`. **파일 업로드 없음**. ⚠️ 배포 대상이 달라 **커밋 머지 ≠ 페이지 반영**
- 배포용 산출물: 루트 `index.html`·`admin/index.html` (`dev/build.sh` 가 생성 — **직접 수정 금지**)
- **폴더 구조는 `ls dev/js/`·`dev/lib/`·`dev/css/` 로 본다**(목록을 베껴 적지 않는다). 빌드 목록 단일 소스는 **`dev/build.sh` 의 `CLIENT_JS_FILES`·`ADMIN_JS_FILES`**
- 🔴 **빌드는 ES 모듈이 아니라 단순 이어붙이기(concat)라 전역 스코프가 하나다** — `admin-core.js` 가 다른 `admin-*` 보다 **앞**, `admin.js` 가 페인 파일들보다 **뒤**, `admin/app.js` 가 **맨 마지막**(`dev/build.sh` 의 순서). 인플루언서 쪽은 `lib/*` 가 `js/*` 보다 앞, `js/app.js` 가 맨 마지막
- Supabase 미연결 시 localStorage 로 동작 (DEMO_MODE)
## Features — 인플루언서 (모바일)
> 상세는 주제별 규칙 파일(아래 지도) — 그 화면 파일을 Read 로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).

**현재 원본 번호**
- 가입 트리거(폼 값 저장) — **420**(382 → 420) · 모집 마감 후 응모 차단 트리거 — **326**(272 → 326)

> ⚠️ **아직 안 한 것**: 「올려두고 제출 안 함」 재발 방지의 관리자 대신 제출 기록(작업 9)·일일 메일 안내(작업 11)는 범위 밖, 자주 묻는 질문 노드(작업 12)는 작업 2·5 운영 배포 뒤에만

- 🔴 **가입 폼 값은 화면이 아니라 가입 트리거가 저장한다**·지우는 일은 쓰기마다(383)·확인 링크 `?code=` 는 재설정 신호가 아니다·가입 이메일 도메인 점검·흔한 비밀번호 경고 — 상세 `.claude/rules/member-signup-auth.md`
- 캠페인 목록(탭별 주소 판정 두 함수)·상세 뒤로 단추·마이페이지·메일 수신 설정(켜기는 서버 함수)·수신거부 라우트(🔴 템플릿 수신거부 줄 삭제 금지)·햄버거 메뉴·알림·응모이력·푸터 — 상세 `.claude/rules/member-app-screens.md`
- 신청 사전 체크·주의사항 동의 스냅샷·리뷰어형 정원 차단·🔴 **모집 마감 후 응모 차단은 서버 트리거가 유일한 최종 방어선**·본인 응모 취소(🔴 인플루언서 행은 `id` 로 찾는다 · 취소 알림은 서버가 만든다) — 상세 `.claude/rules/apply-and-cancel.md`
- 활동관리 결과물 제출·「올려두고 제출 안 함」 방지(채널 단위 버튼·떠날 때 확인 두 겹)·제출 마감 판정 `get_deliverable_gate`(⚠️ 조회 실패 `null` 과 0건 `[]` 구분) — 상세 `.claude/rules/deliverable-submit.md`
- 리뷰어형 기간·마감 문구 판정 헬퍼(회원 상세와 관리자 미리보기가 **같은 함수**) · 페이백 안내 문구 **두 벌**(i18n·`admin.js`) — 상세 `.claude/rules/campaign-period-wording.md`
- 응모건 메시지 회원 화면(🔴 취소 응모도 진입은 막지 않는다 · 페이지 재사용)·자동 번역 파이프라인 — 상세 `.claude/rules/member-messages.md`

## Features — 관리자 (PC)
- **사이드바**: Material Icons, 접기/펼치기 토글, `data-pane` 속성 기반 라우팅, pending 배지 항상 표시
- **페이지 새로고침**: `visibility:hidden` cloak 기법 (깜빡임 완전 방지), 서브패널 새로고침 시 부모 패널로 리다이렉트
- **대시보드**: KPI 카드(캠페인/인플/신청/승인), 상태별·채널별 캠페인 분포(복수 채널은 중복 집계), 가입 추이 차트(Chart.js, 7일/30일/전체), 오늘·이번주 가입 KPI, 프로필 완성률(SNS·배송지·PayPal), 도도부현 분포 도넛(Top 10 + 未登録/海外, 한국어 라벨), 최근 신청 테이블
- **로딩 UX**: 테이블·KPI·차트 영역 인라인 스피너

### 캠페인 관리
> 상세는 주제별 규칙 파일(아래 지도) — 그 화면 파일을 Read 로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).

- 캠페인 삭제 복구·번호 매기기(🔴 복제는 원본의 `brand_id`·`source_application_id` 를 둘 다 이어받는다)·등록/편집 폼·브랜드 변경 확인 창·가이드 칸 이름 판정(🔴 형식만 보고 바꾸면 기존 리뷰어형 제목이 한꺼번에 바뀐다)·미리보기·목록 「결과물 현황」 열(🔴 방문형 현장 사진도 `kind='receipt'`)·상태 6단계·노출 토글(신규 폼 안내 문구와 저장 상태를 같이 고친다)·상태 전이·마감일 연장 확인 — 상세 `.claude/rules/campaign-admin.md`
- 캠페인 리치 텍스트 편집기 이미지(⚠️ 정화·편집기 형식·CSS **세 곳이 한 세트** · `image-compress.js` 는 관리자 빌드에도 · 본문에서 빼도 저장소 파일은 남는다 — 복제본이 가리킨다) — 상세 `.claude/rules/rich-editor-images.md`

### 신청·결과물 관리
> 상세는 주제별 규칙 파일(아래 지도) — 그 화면 파일을 Read 로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).

**현재 원본 번호**
- `get_report_share_data` — **491**(414 → 449 → 457 → 469 → 491). 🔴 **`CREATE OR REPLACE` 로만** — `DROP` 하면 413 이 비로그인에 준 권한이 풀려 공유 링크가 전부 죽는다
- `touch_campaign_report_updated_at` — **491**

- 신청 관리·취소 되돌리기(🔴 `reviewed_at` 안 건드림 — 당선 메일 재발송 방지 · 탈퇴와 얽히면 항상 거부 · 정원은 이 함수가 유일한 방어선)·캠페인 진행현황 — 상세 `.claude/rules/application-admin.md`
- 결과물 검수·인증 상태/인증 성공일/구매금액 열(🔴 진행현황 표와 행 함수 공유 — 열을 늘리면 머리글·`colspan` 여러 곳)·검수대기 배지(배지 전용 재현)·영수증 수정(정산 재계산·「자동 보류」 연속 표현 금지)·엑셀 — 상세 `.claude/rules/deliverable-review.md`
- 캠페인 리포트·브랜드 공유(🔴 계정 열 채널 추가 시 고칠 자리 넷 · 공유 열 끄기 판정 사본 두 벌 · 끈 열 값은 서버가 비운다 · 반려·취소·탈퇴 줄은 공유 응답에 없다) — 상세 `.claude/rules/report-share.md`

### 브랜드 서베이 (광고주 신청 관리)
> 상세는 주제별 규칙 파일(아래 지도) — 그 화면 파일을 Read 로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).

**현재 원본 번호**
- `merge_brands` — **467**(175 → 328 → 467, 🔴 175 를 베이스로 잡으면 오리엔시트·메모 이동이 사라진다)

- 오리엔시트 발급·조회 페인(신규 발급 창의 신청 연결 칸은 잠김 · 발급 메일 수신자는 서버가 정함 · ⚠️ 재발송 버튼·발송 이력은 없다)·발급 목록 삭제 — 상세 `.claude/rules/orient-sheet.md`
- 브랜드 상세 모달(🔴 편집 폼이라 탭 전환은 `display` 토글만)·회사 관리·브랜드 삭제·병합(되돌리기 불가)·서베이 신청 목록·상태 10단계·제품별 메모·입금 칩·캠페인↔신청 연결 — 상세 `.claude/rules/brand-admin.md`
- 운영 현황 일정(간트)·브랜드 뷰(🔴 날짜→위치 변환은 `ganttDayOffset` 하나 · 선정 막대 조건은 다섯째 사본 · 경고 꼬리표는 브랜드 카드 경고의 화면 사본) — 상세 `.claude/rules/brand-ops.md`

### 인플루언서 관리
- **목록**: 채널/인증/위반 드롭다운 + 주소지(도도부현 다중, 「未登録」·「海外」) + 팔로워 범위(채널 기준, 전체=4채널 합계) + 통합 검색 + 인원수. 주소지·팔로워는 클라 필터(`getFilteredInfluencersForView` — 화면·엑셀 공용. `classifyPrefecture`/`followerValueByChannel`, admin-core.js). SNS 채널 선택 시 열은 항상 전체 10컬럼 고정
- **엑셀 내보내기**(`exportInfluencersExcel`, admin-excel.js): 현재 필터 결과(화면에 보이는 대상)를 .xlsx 로. 기본 16열(이름 한자/가나·이메일·대표SNS·4채널 핸들+팔로워·합계·도도부현·시군구·등록일). 민감정보 6열(전화·LINE·PayPal·우편번호·건물·상세주소)은 `canRead('influencer.excel_sensitive')` + 「민감정보 포함」 체크 시만. ⚠️ 그 열쇠말은 화면 열람용 `sensitive_pii` 와 **별개**다(엑셀 대량 유출을 따로 통제). **민감정보 서버 실차단(마이그레이션 212·213)**: `fetchInfluencers`/`fetchInfluencersByIds` 가 가림막 뷰 `influencers_admin_view`(security_invoker) 경유, `has_permission('influencer.sensitive_pii','read')` 가 false 인 등급(213으로 campaign_manager=hidden)에게 6종을 **서버에서 NULL 마스킹** + `has_phone`/`has_line`/`has_paypal` 불리언. 화면은 「열람 권한 없음」. **신청자·결과물 엑셀도 자동 마스킹**. `_excel*` 헬퍼 재사용
- **상태 관리**(인증/위반/블랙리스트): 상태 관리 카드 + 이력 카드(사유별 pill + 타임라인 + 위반 행 편집). 사유는 `blacklist_reason` ∪ `violation_reason`. 증빙은 `influencer-flag-evidence` 비공개 버킷(10MB, image/PDF). RPC: `setInfluencerVerified`/`setInfluencerBlacklist`/`recordInfluencerViolation`/`updateInfluencerViolation` (evidence_paths 미변경=null, 전체 삭제=[])
- **전화번호 표시**(`formatPhoneDisplay` in ui.js): KR/JP 정규화(11자리 3-4-4, 10자리 02/03/06 → 2-4-4 else 3-3-4, `+81`/`+82`). 실패 시 원문

### 아웃바운드 인플루언서 명단 (추천 도구 1·2단계 — ★**운영 반영 완료**)
- **별도 입구 URL + 화면 이동 드롭다운**(`/admin/?app=outbound`, `dev/admin/app.js`): 영업팀 전용 모드(아웃바운드·내계정 외 숨김). 전환은 **사이드바 하단 드롭다운**(`#adminScreenSelect`) — `switchAdminScreen(target)`, 현재값은 `setAdminScreenSelect()`. `window._adminAppMode`+`applyOutboundModeUI()`. **보안 경계 아님**(`outbound.view` RLS 서버 강제). 권한 없는 campaign_manager 는 모드 해제+대시보드. 페인 전환 시 쿼리 유지(`pushState('#'+pane)`).
- **명단 관리 페인**(`/admin#outbound`, `dev/js/admin-outbound.js`): globalreverb 미가입 별도 자산 명단. 기존 `influencers` 와 **분리한 신규 테이블**. 「명단 / 조건 추천」 탭. **명단 탭**: 등록/편집 모달(가격은 엔화·내부전용) + 삭제(네이티브 confirm — z-index 회피). 세분→계열 자동(`OB_CATEGORY_SERIES` shared.js). 권한 `outbound.view`(campaign_admin=write/campaign_manager=hidden). 이미지 업로드 검증 완료(마이그229 `has_permission` Storage 정책).
- **조건 추천 탭**(2단계, `runOutboundRecommend`·`outboundRecoScore`·`compareOutboundReco`): 조건 입력 → **DB 변경 없이** 전건 조회 + 클라 계산. **계열 필터 + `is_active=false` 제외** → 점수(`RECO_SCORE`: 등급 정확 +30/인접 +10[`sort_order`], 채널 +20, 예산 내 +20/초과 −20/미상 0). 정렬 ①가용 ②점수 ③팔로워 ④최신. 예산은 모집형식 단가(`price_feed/reels/story/tiktok`)로 판정. N번째 뒤 구분선 + 점수 근거 배지. 3~5단계 미착수. 사양서 `docs/specs/2026-07-08-influencer-recommendation.md` §구현 결과 + HANDOFF `2026-07-09-influencer-recommendation-stage1-handoff.md`

### 기준 데이터·번들·관리자 계정
- **기준 데이터 관리**(`/admin#lookups`): 채널/카테고리/콘텐츠 종류/NG 사항/반려사유/블랙리스트·위반 사유/주의사항/취소 사유/메일 종류 등을 한국어·일본어로 관리(campaign_admin 이상). 항목 활성/비활성 토글, 순서 변경 모드, 사용 중이면 hard delete 차단(soft delete 만). 채널은 모집 타입(monitor/gifting/visit) 다중 지정. code 자동 생성·비공개
- **자주 묻는 질문(FAQ) 관리**(`/admin#faq`, campaign_admin 이상): 응모건 메시지 자동응답 등록 페인. 좌우 2단(카테고리 | 질문 + 측정 배지[조회수·직접문의 전환수]) + 편집 모달(한/일 2열·화면이동 드롭다운·handoff·단계 다중선택·미리보기)
- **주의사항 번들**(`caution_sets`): 폼 콘텐츠 가이드 섹션 — 번들 드롭다운(recruit_type 필터) + "번들 다시 불러오기". 저장 시 스냅샷 복사
- **참여방법 번들**(`participation_sets`): 1~6단계, title/desc ko·ja, recruit_types[] 필터. 스냅샷 `participation_steps jsonb`
- **NG 번들**(`ng_sets`): caution_sets 미러. items `{html_ko, html_ja}` (DOMPurify, inline 서식만). `campaigns.ng_set_id` + `ng_items jsonb`. 인플은 jsonb 우선 + legacy `campaigns.ng` 폴백
- **민감 항목 변경 경고**: `caution_items`/`participation_steps`/`ng_items` 변경 시 `#sensitiveChangeModal`. closed 캠페인은 변경 차단 트리거. 이력 `campaign_caution_history` → 「변경 이력」(super_admin) + 인플 응모이력 「現在の文言と比較」 토글
- **변경 이력 = 전체 항목**(마이그레이션 265·266): 「변경 이력」 모달이 3영역 + **48개 항목**을 시각 역순 한 목록으로. **실제로 안 바뀐 기록은 접어 둠**. 변환 `CAMPAIGN_FIELD_LABELS`/`campaignFieldValueText`(shared.js), 렌더 `campaignChangeCardHtml`/`campaignChangeRowHtml`(admin.js). 열람은 super_admin 하드코딩
- **변경 이력 차이 표시**: **항목 단위 차이 목록**(`renderSensitiveDiffSection`/`renderSensitiveDiffRow`, admin.js) — 바뀐 글자만 강조, 한·일 둘 다. 엔진은 `dev/lib/shared.js`(`diffSensitiveItemLists`/`diffChars`/`richToPlainText`/`textSimilarity`/`sensitiveListsIdentical`) — **리치 HTML에 강조 태그를 직접 끼우지 않고** sanitize→텍스트→글자 비교→이스케이프 후 강조(태그 붕괴·저장형 XSS 차단). 상한 1200자·변경 비율 60% 초과 시 전문 비교 폴백. 저장 전 경고 모달(`#sensitiveChangeModal`)은 아직 옛 2단 표시
- **편집 모달 분리**: 참여방법/주의사항 편집을 별도 모달로, 注意事項 미리보기 한·일 토글
- **오픈 예정 기능 보드**(`/admin#upcoming`, 관리자 전원 읽기): 시행 예정 기능·D-day 카드(가까운 순). **DB 미사용** — `dev/lib/shared.js` 의 `UPCOMING_FEATURES` 상수(배포 시 1줄 등록). 시행 후 14일 뒤 숨김. 판정은 클라 `+09:00` 날짜 단위. ⚠️ **예고판일 뿐 기능 스위치 아님**(`effectiveDate`는 실제 시행일과 단일 소스). 렌더 `dev/js/admin-roadmap.js`, 헬퍼 `upcomingFeatureStatus`/`Dday`/`visibleUpcomingFeatures`. 사양서 `docs/specs/2026-06-15-admin-upcoming-features-board.md`
- **관리자 공지사항**(`/admin#admin-notices`): 사이드바 최상단 + 미읽음 배지. 카테고리 4종(system_update/release/warning/general), 고정(push_pin), Quill. **draft/published 분리** — 신규·draft는 `[초안 저장][게시하기]`, published는 `[게시 유지하며 저장][초안으로 되돌리고 저장]`. 작성자/super 한정 `[지금 게시]`/`[게시 회수]`. 노출은 published 만. 초안은 `/공지초안-관리자`
- **관리자 계정**: 3단계 권한(super_admin > campaign_admin > campaign_manager)
  - **추가**: super_admin 이 이메일+이름+역할 입력 → `invite_admin()` RPC(현재 원본 **417**, 베이스 245 — 이메일 `lower(btrim())` 정규화) → Edge Function `notify-admin-invite` 가 **서버에서** 링크 발급(`auth.admin.generateLink`) + **한국어** 메일 Brevo 발송 → 자립형 `/admin-setpw.html` 에서 설정. 재발송은 「재발송」(super_admin, 서버도 가드) 또는 `mode=reset`. `storage.js` `sendAdminInviteMail(email, mode)`
    - **발송 상태 표시**(마이그레이션 244): `invite_completed_at` 있으면 「설정 완료」 / `invite_mail_sent_at` 있으면 「발송 {날짜}」 / 없으면 「미발송」. 발송 기록은 Edge Function, 설정 완료는 자립형 페이지가 본인 행 UPDATE(`.is(null)` 최초 1회)
    - **기존 계정 승격 시 비밀번호 보존**(마이그레이션 245): 🔴 **기존 비밀번호를 덮어쓰지 않는다** — 덮어쓰면 인플루언서 로그인이 즉시 끊기고, 메일이 스팸함으로 가면 계정에서 잠긴다. `admins.promoted_at` 로 메일 문구가 갈린다(승격자=「권한이 추가되었습니다」 / 신규=「비밀번호를 설정해 주세요」)
    - ⚠️ 이메일로 `admins` 조회 시 **`ilike` + 와일드카드 이스케이프**(`escapeLikePattern`). `eq` 는 대소문자를 구분해 못 찾고, 이스케이프 없는 `ilike` 는 `_`·`%` 든 이메일이 다른 행에 매칭된다
    - ⚠️ **`resetPasswordForEmail` 을 안 쓰는 이유**: ①템플릿이 인플루언서 비밀번호 찾기와 공유 ②`flowType:'pkce'` 라 검증값이 **호출한 브라우저**(super_admin)에 저장돼 초대 대상 브라우저에선 교환 실패. 서버 발급은 이 문제가 없음
    - **랜딩이 `/admin/` 밖인 이유**: 관리자 앱은 세션 없으면 리다이렉트(`dev/admin/app.js`). `dev/admin-setpw.html` → `build.sh` 가 루트로 복사. 사양서 `docs/specs/2026-07-20-admin-invite-mail-and-setpw.md`
  - **관리자 전용 로그인 화면**(`/admin-setpw.html?mode=login`): `/admin/` 세션 없음·만료·로그아웃 시 이 화면(옛 `/#login` 대체). 인플루언서 앱에서 관리자 로그인 시 `/admin/` 으로 가는 경로(`auth.js`)는 보존. 관리자 아닌 계정은 안내 + 인플루언서 앱 버튼. ⚠️ **`persistSession` 이 모드마다 다름** — `login`=true / `setpw`=false(임시 세션이 저장소를 공유해 「비밀번호 바꾸기 전에 다른 탭에서 `/admin/` 이 열리는」 사고 방지) + 완료 후 `signOut()`
  - **관리자 비밀번호 찾기**(로그인 화면 → forgot): 익명 Edge Function `admin-password-reset-request` 가 관리자면 발송, 아니면 아무것도 안 함. **계정 존재 여부 비노출** — 모든 분기가 `{ok:true}` 200 + 최소 2500밀리초로 수렴. **요청 제한 3층**(이메일별 5분1회·24시간5회 / 전역 시간당 30건 / 형식·길이) — Brevo 직접 발송이라 Auth Rate Limits 보호가 없고, 한도 소진 시 다른 메일까지 죽기 때문. 제한에 걸려도 「요청이 많습니다」 비노출. 마이그레이션 243
  - **흔한 비밀번호 거부**(관리자 비밀번호를 정하는 세 곳 — 초대·재설정 화면·「내 계정」·슈퍼관리자 초기화): 브라우저가 SHA-1 앞 5글자만 서버 함수 `password-range-lookup` 에 보내 Have I Been Pwned 목록과 대조(`commonPasswordCheck` — `ui.js`·`admin-setpw.html` **두 곳**). 🔴 **Supabase 「유출 비밀번호 검사」는 일부러 꺼 둔다**(켜면 회원까지 거부 — 회원은 경고만이 결정). 🔴 **서버 함수를 먼저, 화면을 나중에** 배포 — 함수가 없으면 판정이 조용히 `'unknown'`(통과)이 되어 효과 0이고 오류도 안 난다. 함수는 git 병합으로 반영되지 않아 개발·운영에 따로 배포. 사양서 `docs/specs/2026-09-29-common-password-warning.md`
  - **삭제 2택**: `remove_admin_role`(권한만 해제) / `delete_admin_completely`(auth/influencers/applications/receipts cascade). 자기 삭제 불가
  - **「최근 접속」 열**(마이그레이션 436 → **437**): `get_admin_last_sign_in()` 이 `last_sign_in_at` 과 **`last_active_at` = GREATEST(로그인 시각, `auth.sessions.updated_at` 최댓값)** 을 주고 화면은 뒤쪽을 쓴다(auth 스키마라 브라우저가 못 읽음). 🔴 **로그인 시각만 쓰면 안 된다** — 토큰 연장만 일어나 오늘 쓴 사람이 「어제」로 보인다(436). 🔴 **슈퍼관리자 전용, 두 겹** — `is_super_admin()` 가드 + 실행 권한(PUBLIC·`anon`·`service_role` 회수, `authenticated` 만 부여). 🔴 반환 칸을 바꾸려면 `DROP` 후 `CREATE` 라 **회수를 다시 걸어야 한다**(437). **화면에서 열을 숨기는 것은 보안이 아니다**. ⚠️ 「관리자 화면에 들어온 날」과 다르다 — ①겸직 회원은 인플루언서 화면만 써도 오르고 ②**로그아웃하면 세션 행이 지워져 로그인 시각으로 돌아간다**(툴팁). ⚠️ 열 노출 판정은 **`showLastSignIn` 하나**이고 머리글·셀·빈 상태 `colspan` 이 그것만 본다 — 나누면 표가 밀린다. ⚠️ 조회 실패는 **`null`**(0건 `{}` 와 구분) → 열을 안 그린다. ⚠️ 권한 관리 화면에 이 열 열쇠말이 **없다**(슈퍼 고정) — 열려면 마이그레이션 필요
- **메일 수신 설정**(`/admin#admin-accounts`): 「메일받기」 셀 칩 + 「설정」 모달(종류별 체크박스). `admin_email_subscriptions` + `lookup_values(kind='admin_email_kind')`. super_admin 은 타인 편집 가능. 새 종류는 `lookup_values` 한 줄로
- **내 계정**: 이름/비밀번호
- **감사용 계정 메커니즘**(179·181): 운영팀 시뮬레이션용 공용 계정(`influencers.is_audit=true`). 응모수(`get_campaign_application_counts`)·슬롯(`check_monitor_slots`)·「N명 신청」(`recompute_campaign_applied_count`)·대시보드·운영현황(`get_brand_ops_overview`/`detail`)에서 **격리**. 「감사용」 배지 `auditBadgeHtml`. 엑셀 5개 export 에 포함되면 「포함/제외」 확인(`confirmAuditExport`, 0명이면 생략). 청소 함수 2종(`purge_audit_data_all`/`purge_audit_data_for_campaign`, super_admin — **저장소 파일 경로를 돌려주고 화면이 지운다**). ⚠️ `fetchInfluencers(opts)` 기본값이 `includeAudit:true` 라 **통계·엑셀에서만 false 를 명시**해야 한다. 사양서 `docs/specs/2026-05-28-audit-influencer-account.md`
- **오류 로그**(`/admin#errors`, 마이그레이션 165, `dev/js/admin-errors.js`): 인플 앱 오류 모음. 상세 모달에서 해결/무시/메모(`resolve_client_error`). 개인정보는 수집 단계 마스킹. 수집은 `error-report.js`
- **광고 추적**(`/admin#ad-tracking`, 마이그레이션 438·439, `dev/js/admin-ad-tracking.js` — ★**운영 배포 완료**. 🔴 **운영에서 켜져 있다**(켜짐·아이디 있음·시행일 `2026-09-18` — 사용자 결정으로 공고상 시행일 10-17 을 기다리지 않았고, 방침·앱 공지·메일의 10-17 은 그대로 둔다)): 메타 픽셀 켜기·아이디 입력 화면(「관리자 설정」 묶음). 권한 `menu.ad-tracking`(매니저 읽기) + `ad_tracking.manage`(매니저 숨김, **서버 강제**).
  - 🔴 **상태 배지 4종은 서버 `status` 를 그대로 그린다** — 화면이 시행일을 비교하지 않는다(갈리면 「켤 수 있어 보이는데 서버가 거부」). 순서 `policy_locked` → `no_pixel_id` → `disabled` → `active`
  - ⚠️ **스위치는 저장된 아이디로만** — 저장 안 한 입력이 있으면 멈추고 먼저 저장하라고 한다. 켤 때만 확인 창
  - ⚠️ 쓰기 권한이 아니면 **숨기지 않고 비활성** + 「변경 권한이 없습니다」. 거부 사유 넷(`forbidden`·`invalid_input`·`invalid_pixel_id`·`policy_not_in_effect`)과 통신 실패는 **각각 다른 문구**
  - ⚠️ 저장 뒤 안내는 셋 모두 같다 — 이미 열린 탭은 새로고침 전까지 옛 설정으로 보낸다
  - ⚠️ 개발서버에서는 「운영 아이디를 넣지 마세요」 경고(`IS_STAGING`). 🔴 **관리자 앱에는 픽셀을 심지 않는다**(운영자 행동이 전환으로 잡힌다)
- **에러 처리**: `friendlyError()` 한국어 메시지 + 에러 코드
- **상태 뱃지**: `getStatusBadgeKo()` 한국어 상태 표시

## Database Schema (Supabase)

### 캠페인·신청·결과물
- `campaigns` — 캠페인 정보. 핵심 컬럼:
  - 기본: `title`, `brand`, `brand_ko`, `product`, `product_ko`, `type`, `channel`, `channel_match`('or'|'and'), `category`, `reward`, `reward_note`, `slots`, `min_followers`, **`min_followers_by_channel`**(jsonb, 마이그레이션 385 — 「그리고」 갈래만 읽는다), `status`, `view_count`, `img1~img8`
  - 일정: `recruit_start date NULL`(NULL 이면 "오늘 ~ 마감" 폴백), `deadline`, `purchase_start/end`(monitor), `visit_start/end`(visit), `submission_end`
  - 번들 스냅샷: `participation_set_id`/`participation_steps jsonb`, `caution_set_id`/`caution_items jsonb`, `ng_set_id`/`ng_items jsonb`
  - 채번: `campaign_no`, `legacy_no`(콤마 누적), `brand_id` FK, `source_application_id` FK
  - `reward_note` 는 지급 조건·정산 시점 등 자유 텍스트
  - 홍보 메일: `first_active_at timestamptz NULL` — 처음 active 가 된 시각. `BEFORE UPDATE OF status` 트리거(`_record_first_active_at`) 자동 기록·불변 (마이그레이션 140)
  - 동시 저장 방어(마이그레이션 275): `version integer NOT NULL DEFAULT 1` — 나중 저장이 앞 저장을 조용히 덮는 것을 막는다. `campaigns_bump_version()` 트리거가 **제외 6개**(`version`·`updated_at`·`view_count`·`applied_count`·`order_index`·`first_active_at`) 외 변경 시에만 +1(새 컬럼은 자동 보호). 편집 저장은 `updateCampaign(id, updates, expectedVersion)` 의 `.eq('version', …)` → 0행이면 충돌 안내. ⚠️ **코드보다 마이그레이션을 먼저**(반대면 자동 마감 실패). ⚠️ 자동 전이(`autoOpen/Close/EndCampaigns`)도 version 을 올리므로 캐시를 `.select('version')` 으로 갱신 — 안 하면 **가짜 충돌**
  - 오리엔시트 발행 보조(마이그레이션 197): `proxy_purchase boolean NOT NULL DEFAULT false`(가구매 — 영수증만. 인증성공 판정·활동관리·엑셀이 분기) + `emergency_publish_reason`/`emergency_published_by`/`emergency_published_at`
- `campaigns_yearly_counter`, `brand_seq_counter`(싱글톤), `brand_application_counter`, `application_campaign_counter`, `brand_external_campaign_counter` — 채번 카운터. SECURITY DEFINER 트리거 전용 (직접 UPDATE 금지)
- `numbering_legacy_map` — 신구 채번 양방향 매핑
- `applications` — `user_id`, `campaign_id`, `message`, `address`, `status`(pending/approved/rejected/cancelled), `reviewed_by`, `reviewed_at`, `oriented_at`, `reviewed_version`(낙관적 락), `caution_agreed_at`, `caution_snapshot jsonb`. 취소 보조 5종: `cancelled_at`, `cancel_reason`, `cancel_reason_code`, `cancel_phase CHECK(recruit|purchase|visit|post|other)`, `previous_status`. `(user_id, campaign_id)` partial unique index(cancelled 제외) → 재응모 가능
- `deliverables` — `kind`('receipt'|'review_image'|'post'), `status`, `receipt_url`/`purchase_date`/`purchase_amount`/`order_number`, `post_url`/`post_channel`/`post_submissions`, `reject_reason`, `reviewed_by`/`reviewed_at`, `version`. **대리 등록 4종**: `submitted_by_admin`(NULL=본인) + `submitted_by_admin_reason_code`/`_reason`/`_at`. 부분 인덱스 `idx_deliverables_proxy WHERE submitted_by_admin IS NOT NULL`. **`admin_create_deliverable_proxy` 게시물 분기**(182): ①요구 채널 불일치 차단(⚠️ 채널이 빈값이면 우회된다) ②같은 채널 반려·검수대기 게시물은 **교체**(`status='approved'`, `post_submissions` 누적, `version`+1) — **승인 게시물은 교체 차단**(`insertDraftDeliverable` 과 같은 규칙). **잘못된 채널 잔존 행 정리**(183, `delete_mismatched_post_deliverable`): 「채널 불일치」 배지 + super_admin 수동 삭제. **반려·검수중·임시저장만**, `post_channel` 이 NULL 이거나 정상 채널이면 거부. `deliverable_events` 는 **328 이후 `SET NULL` 이라 감사 기록이 남는다**
- `deliverable_events` — `action`(submit/resubmit/approve/reject/revert/admin_proxy_submit/admin_proxy_revoke/channel_assign/channel_unassign), 트리거/RPC 만 INSERT. ⚠️ **마이그레이션 328로 `ON DELETE SET NULL`**(옛 `CASCADE` 는 이력도 지웠다) — 스냅샷 칸 4종(`kind`·`post_channel`·`status` 등)으로 **결과물이 지워져도 무엇의 이력인지 남는다**(`admin_proxy_revoke` 포함)
- `application_events` — 신청 status 변경 audit(운영자 액션). `action`(approve|reject|revert_to_pending|**restore_cancelled**). `trg_application_status_event` 트리거 INSERT(본인 취소·재응모 미경유). RLS SELECT `is_admin()` — **단 `restore_cancelled` 는 `restore_cancelled_application`(440)이 직접 넣는다**(「취소 되돌리기」 참조). ⚠️ **검사 제약 이름은 440 부터 `application_events_action_check`**(131 은 자동 생성 이름). 다음에 `action` 을 늘릴 땐 440 이 베이스
- `receipt_edit_history` — 영수증 수정 감사. `deliverable_id` FK **SET NULL**(마이그레이션 253) + 3종 prev/next 스냅샷. RLS SELECT `is_admin()`, INSERT 는 `update_receipt_admin` 만
- `campaign_caution_history` — 주의사항/참여방법/NG 변경 audit + `app_count_at_change`. RLS SELECT super_admin, INSERT 는 `record_caution_history()` 만(campaign_admin 이상)
- `campaign_change_history` — **캠페인 전체 항목 변경 audit**(마이그레이션 265·266). 「바뀐 항목 1개 = 1행」 + `change_group_id` + `changed_by`/`changed_by_name`/`changed_at` + `field_name`(CHECK 화이트리스트 **48개**) + `old_value`/`new_value` jsonb + `change_source`(admin / auto / system). RLS SELECT `is_super_admin()`, 쓰기는 트리거만(`record_campaign_change_history()` AFTER UPDATE — 구 `record_caution_history` 와 달리 같은 트랜잭션이라 감사 공백 없음). ⚠️ **화이트리스트는 세 곳(265 CHECK · 266 v_fields · 266 트리거 `AFTER UPDATE OF` 목록)이 항상 같은 집합** — 어긋나면 CHECK 위반으로 INSERT 실패. 조회수·신청 수·수정일·순서·채번 제외. 3영역은 기존 표와 병존. 사양서 `docs/specs/2026-07-27-campaign-full-change-history.md`

### 광고주 신청(브랜드 서베이)
- `brand_applications` — `form_type`(reviewer|seeding), `brand_name`, `contact_name`, `phone`, `email`, `billing_email`, `products jsonb`, `total_jpy/total_qty`, `estimated_krw`, `final_quote_krw`, `quote_sent_at`, `quote_sent_url`, `orient_sheet_sent_at`, `orient_sheet_sent_url`, `paid_at`, `payment_flags jsonb`, `status` 10단계, `request_note`, `version`, `legacy_no`. **익명 INSERT 는 `submit_brand_application()` RPC(SECURITY DEFINER, BYPASSRLS) 필수** — 직접 INSERT 는 42501
- `brand_application_memos` — `application_id` FK CASCADE, `product_idx integer NOT NULL DEFAULT 0`, `memo`, `created_by`/`created_by_name`/`created_at`
- `brand_application_memo_reads` — (memo_id FK CASCADE, auth_id) PRIMARY KEY
- `brand_application_history` — 광고주 신청 변경 audit
- `brand_app_daily_counter` — 일자별(JST) 채번 카운터. SECURITY DEFINER 트리거 전용
- `brand_survey_settings` — 공개 제출 차단 싱글톤(id=1). `submissions_open boolean DEFAULT false`. RLS SELECT `is_admin()` / UPDATE `is_super_admin()`. **`submit_brand_application` 0단계 가드가 차단 시 `RAISE 'submissions_closed'`(P0001)** — 폼은 `error.message==='submissions_closed'` 로 분기. anon 조회 `is_brand_survey_open()`(bool만). 관리자 예외 입력 `admin_create_brand_application`(091). 마이그레이션 206. 사양서 `docs/specs/2026-06-30-brand-survey-submit-lock.md`. ⚠️`submissions_open=true` 재개 시 `sales/index.html`(정적 차단 안내)도 함께 되돌려야 함(reviewer/seeding 은 동적)
- `companies` — 회사 마스터(회사 > 브랜드 > 신청 > 캠페인). `name_ko`(NOT NULL)/`name_ja`/`name_en` + `name_normalized` UNIQUE NOT NULL(자동 정규화) + `business_no` + `address` + `homepage_url` + `billing_email`/`billing_address`/`memo` + `status CHECK(active|archived)` + `total_brands`(`recalc_company_total_brands` 트리거, `brands.company_id` 변경 시). RLS SELECT `is_admin()`, CUD `is_campaign_admin()` 이상. ⚠️ `name_normalized` 는 마이그레이션 119에서 공백 압축 패턴(`lower(trim(regexp_replace(name_ko,'\s+',' ','g')))`)으로 교체(118 원본은 압축 없음)
- `brands` — `name`, `name_normalized`, `brand_seq` UNIQUE, `company_id` FK ON DELETE SET NULL
- `brand_memos`(466) — 브랜드 영업 메모 여러 건(옛 `brands.memo` 는 더 안 쓴다). 관리자 전원 읽기·쓰기, 브랜드 삭제 시 함께 삭제. `merge_brands`(**현재 원본 467**, 베이스 328)가 메모도 옮긴다
- `get_brand_ops_overview(p_company_id uuid)` — 22컬럼 집계 RPC(`SECURITY DEFINER + SET search_path='' + is_admin()`). 148 로 `alert_reasons text[]` + `soonest_deadline date` + `d1_count bigint` 추가. 임계값 120 기준, `flag_agg` CTE 로 1회 계산 후 재참조. 181 로 `app_agg`·`deliv_agg` 에 `JOIN influencers AND is_audit=false`(감사용 격리)
- `get_brand_ops_detail(p_brand_id uuid)` — 브랜드 상세 jsonb. 149 로 캠페인 항목에 `channel`/`channel_match`/`img1`/`recruit_start`/`submission_end` + `approved_app_count`·`deliv_submitted_inf`·`deliv_total`·`deliv_approved`, 150 으로 `purchase_start`/`purchase_end`·`visit_start`/`visit_end`. 미니카드 진행바 중 **인증 성공률**은 RPC에 없어 `hydrateCampCertBars`(admin-brand-ops.js)가 `fetchDeliverablesByCampaign`(🔴 **실패 `null`·0건 `[]`** — 실패를 「0%」로 그리지 않는다. 진행현황 요약 카드도 같다) 후 `countCertSuccess`(admin-deliverables.js — `buildDeliverableGroups`+`computeCertStatus` 단일 소스)로 비동기 채움
- `link_campaign_to_application` / `unlink_campaign_from_application` — 연결/해제 RPC (`is_campaign_admin()` 이상, advisory_xact_lock 2단)

### 브랜드 셀프 오리엔시트 (마이그레이션 186~195·200)
> 상세는 **`.claude/rules/orient-sheet.md`** — 오리엔시트 화면·작성 폼·오리엔시트 마이그레이션을 열면 자동으로 읽힌다.
> 🔴 **이 영역을 설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).
> 🔴 아래는 규칙 파일이 자동으로 안 읽히는 자리에서도 알아야 하는 것이라 여기 남겼다(다른 영역·현재 원본 번호·잠금 상태 등).
> 🔴 **이 영역 파일은 Read 도구로 연다** — 셸(`cat`·`sed`·`grep`)로 보거나 고치면 규칙 파일이 **안 실린다**.

**현재 원본 번호** (함수를 재정의할 때 베이스 — 옮긴 덩어리의 ③ 줄마다 한 줄)
- `create_orient_sheet` — **490**(5인자 `CREATE OR REPLACE` — 권한 `authenticated` 보존. 465 의 「`DROP` 후 재생성」 표기는 틀렸다)
- `get_orient_tier_fees` — **489**
- `_orient_apply_issued_rules` — **445**
- `submit_orient_sheet` — **461**
- `_orient_compute_quote` — **463**
- `link_orient_card_to_campaign` — **464**(베이스 237)

> - ⚠️ **개발서버 시딩 단가 25행은 아직 가짜 값(`99001~99025`)** — 그 환경에서는 작성 폼을 브랜드에게 내보내지 않는다(구간 단추에 단가가 뜬다). 새 환경도 「견적 기준값」에 실제 금액을 넣고 `99,0` 으로 시작하는 행이 없는지 본다

- 🔴 오리엔시트 표·카드 메모·구간 요금(계산은 서버가 인원으로 재판정 · 구간 인원은 형식별 · 이름 기본값 사본 세 곳)·모집비 직접 지정(캠페인 관리자 이상)·고정 안내 확인(445 가 446 보다 앞 · 🔴 446 적용 뒤 새 폼이 나가기 전에는 시트를 발급하지 않는다 · 운영 순서는 사양서 §7) — 상세 `.claude/rules/orient-sheet.md`
- 🔴 캠페인 발행(판매가는 캠페인 어느 칸에도 자동으로 안 들어간다 · 리뷰어형 제품 금액 0 확인창은 세 경로 모두)·기존 캠페인 연결(모집 형식은 `proxy_purchase` 로만 가른다)·구매 가이드 모드(NULL = 옛 판) — 상세 `.claude/rules/orient-publish.md`

### 오프라인 팝업 방문 예약(티켓팅)
> 상세는 **`.claude/rules/event-ticketing.md`** — 행사 화면(`admin-event.js`·`event-ticket.js`·`event-scan.html`)이나 행사 마이그레이션을 열면 자동으로 읽힌다.
> ⚠️ **기능은 전부 운영에 있으나 아무도 켠 적이 없다** — 데이터 0건. 다음에 쓸 캠페인이 생기면 캠페인 등록·타임 생성·묶음 지정이 필요하다.
> 🔴 **다른 영역을 고칠 때 알아야 하는 셋** (위 규칙 파일은 행사 파일을 열어야 뜬다):
> - **캠페인 변경 이력**(265·266)의 화이트리스트에 행사 칸 4종(`event_mode`·`is_invite_only`·`event_group_id`·`event_selection_mode`)을 **의도적으로 안 넣었다**(세 곳 동시 수정 위험) — 「빠졌다」고 넣지 말 것
> - **인플루언서 일일 다이제스트 메일이 행사 낙선 통지를 겸한다** — 낙선은 응모를 `rejected` 로 두어 그 메일과 「落選」 배지를 그대로 쓴다. 그 메일을 고칠 때 행사가 딸려 온다
> - **선정 기간(`selection_start`/`selection_end`) 표시 조건이 네 곳**(인플루언서 상세·관리자 미리보기·진행현황·엑셀)에서 **글자 그대로 같아야** 한다(폼에만 「이미 값이 저장돼 있으면 보여준다」 예외가 하나 더)
### 인플루언서·관리자
> 상세는 주제별 규칙 파일(아래 지도) — 그 화면 파일을 Read 로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).

> ⚠️ **아직 안 한 것**: 위반 기록 3년 파기는 **행만 지우고 증빙 파일 경로는 대기열에 쌓기만** 한다 — 대기열을 소비하는 화면이 아직 없다(방침 문구에 「집행 완료」로 적지 말 것)

- `influencers`(🔴 회원 본인 직접 UPDATE 로 이메일·동의 시각·가입 시각 변경과 수신 직접 켜기는 거부 — 492, 반드시 SECURITY INVOKER · 신규 가입자는 연령 게이트가 다시 안 뜬다)·`age_policy_settings`·`influencer_flags` — 상세 `.claude/rules/member-profile-tables.md`
- 동적 권한 관리(🔴 `has_permission` 미등록 시 판정이 등급별로 반대 · 슈퍼관리자 잠금 방지 3중 · 「설정 미적용」 12개는 모든 등급에서 무효 · 응급 복구는 직접 UPDATE · 정책을 바꾸는 마이그레이션은 `default_level` 도 함께 UPDATE) — 상세 `.claude/rules/admin-permissions.md`
- `admins`·`admin_password_reset_requests`(원문 이메일 미저장)·`admin_email_subscriptions`·`admin_notices`·`admin_notice_reads`(⚠️ 칸 이름은 `auth_id`) — 상세 `.claude/rules/admin-accounts-notices.md`
- `outbound_influencers`(⚠️ 정책은 `is_admin()` 금지 — `has_permission('outbound.view')`) — 상세 `.claude/rules/outbound.md`

### 응모건 메시지 (인플루언서 ↔ 관리자, 마이그레이션 144·145)
> 응모건 단위 양방향 메시지 — 받은편지함 3단 페인 `#adminPane-messages`·강제 숨김/복구·응대 완료·알림 `message_received`. **캠페인 단위 일괄 발송도 운영 가동 중** — 대상 필터 + 발송 이력·일괄 회수. 관리자 로직 `dev/js/admin-messaging.js`. 사양서 `docs/specs/2026-05-15-application-messaging.md`·`docs/specs/2026-06-02-bulk-message-target-redesign.md`
> 🔴 **약관 게이트가 언제·무엇을 근거로 풀렸는지 어디에도 없다** — 개인정보처리방침은 **「문의하기」(인플루언서 → 운영팀) 기준으로** 갱신됐고, **관리자 → 인플루언서 일괄 발송까지 덮는지는 확인되지 않았다.** 판단이 필요하면 `/약관확인`
> ⚠️ 첨부·임의 다중선택(3페인 체크박스)·메일 지연 큐(PR 4)는 **미구현**
  - **후속 발송 — 「같은 조건으로, 아직 안 받은 사람에게만」**(마이그레이션 388~391·393): 진입점은 **발송 이력 상세의 「아직 안 받은 대상에게 추가 발송」 버튼**. ⚠️ **못 누를 때도 감추지 않고 회색으로 두고 이유를 말한다**. 창은 **두 수를 같이** 말한다(N건 중 아직 안 받은 M건). 🔴 **「명」이 아니라 「건」이다**(한 사람이 여러 건). 한도 200건을 넘으면 **막지 않고** 남은 건수를 말한 뒤 200건을 보내고 **방금 만들어진 발송을 연다** — 🔴 「이 발송에서 다시 누르세요」는 **틀린 안내**(보내는 순간 사슬의 마지막이 아니게 되어 회색이 된다). ⚠️ 조건 스냅샷은 **그대로** 넘겨 부모의 판을 물려받는다(새로 찍으면 사슬의 판 표시가 깨진다). ⚠️ 발송 뒤 `refreshInboxData()` 도 부른다(미응대 배지). ⚠️ **「전체 회수」는 사슬을 안 따라간다** — `withdraw_broadcast`(167)는 발송 1건만, 추가 발송은 각각 회수(확인창이 말한다). 토대: `application_message_broadcasts.parent_broadcast_id` 로 사슬을 잇고 대상 고르기가 **사슬 전체가 이미 보낸 응모건을 뺀다**(`resolve_bulk_recipients` 의 `p_exclude_broadcast_id`). ⚠️ **응모건 단위로 뺀다**(사람 단위면 다른 캠페인 건까지 빠진다). ⚠️ **「이미 받은 사람」에 새 표를 안 만든다** — `application_messages` 의 `broadcast_id` 가 이미 그 기록이다. 🔴 **사슬은 줄이어야 하고 서버가 거부로 강제한다**(`send_application_message_bulk` — 현재 원본 **417**, 베이스 390. 417 이 부모 행에 `FOR UPDATE` 잠금 — 3종 — ①남의 발송 ②사슬의 마지막이 아님 ③부모가 회수됨). 🔴 **②는 자손 전체를 본다** — 한 겹만 보면 「1차 → 2차(회수) → 3차」에서 1차가 통과해 형제가 생기고 **겹쳐 받는다**. ⚠️ **「마지막 세기」와 「뺄 집합」은 기준이 다르다** — 마지막 세기는 회수된 것을 **건너뛰고**, 뺄 집합은 회수된 발송의 수신자도 **뺀다**(회수는 가리는 것). ⚠️ **「마지막」은 시각이 아니라 깊이로 센다**. ⚠️ 판 표시 `v`(`BULK_FILTER_VERSION`, admin-messaging.js) — **화면 열쇠말을 고치면 사람이 올려야 한다**(안 올리면 옛 이력 조건이 조용히 잘못 재현). 판 0 이력은 막지 않는다. 사양서 `docs/specs/2026-08-27-bulk-message-followup-send.md`
- **회원 배지 조회 시간 초과**(사양서 `docs/specs/2026-09-02-influencer-unread-badge-timeout.md`): ①`fetchInfluencerUnreadMessageThreads` 는 **실패 `null`, 0건 `[]`** 이고 실패 때 지난 값을 유지한다. ②세 표의 관리자 정책 `is_admin()` 이 **행마다** 평가돼 느렸다 → **415** 가 그 세 SELECT 정책을 `(SELECT public.is_admin())` 로 감쌌다(137 이 `auth.uid()` 에 한 방식). ⚠️ **감싸지 않은 `is_admin()` 정책이 운영에 84개 더 있다** — 같은 증상이면 이 방식으로. ⚠️ 회원 역할 실행 계획은 SQL 편집기에서 **`set local role authenticated`** 를 넣어야 정책이 평가된다
- `application_messages` — `application_id` FK CASCADE(**475 부터 비어 있을 수 있다** — 아래 일반 문의 행은 `influencer_id` 만 가진다. 검사 제약 `application_messages_owner_exactly_one` 이 둘 중 정확히 하나를 강제), `sender_kind`(influencer|admin), `body`, `attachments jsonb`, `read_by_influencer_at`, 강제숨김 4컬럼, 본인회수 2컬럼, 메일큐 3컬럼, `broadcast_id` FK. RLS SELECT 본인 응모건 또는 `is_admin()`, INSERT/UPDATE 는 RPC 만
- 부속 테이블: `application_message_admin_reads` / `application_message_resolutions` / `application_message_broadcasts` / `application_message_hide_history`(append-only super_admin)
- 뷰 `application_message_summary`(security_invoker) + RPC: `get_application_messages`(역할별 4종 마스킹. ⚠️ **326 으로 `sender_id` 추가** — **관리자가 부를 때만** 채운다. 없으면 **다른 관리자 메시지에도 「회수」 버튼이 떠 누르면 반드시 실패**. ⚠️ 개별 회수(`withdraw_own_message`)에는 **최고 관리자 예외가 없다** — 일괄 회수의 예외를 옮기면 버튼만 뜨고 실패한다)·`send_application_message`(rate limit 100/h + 자동응대 + 관리자 발신 시 `message_received`)·`mark_application_messages_read`·`withdraw_own_message`(25분)·`mark_application_resolved`·`hide_application_message`(campaign_admin)·`unhide_application_message`(super_admin). 모두 SECURITY DEFINER
- lookup `message_hide_reason` 7종 + Storage 버킷 `application-message-attachments`(비공개). 첨부는 클라 압축(`dev/lib/image-compress.js`, HEIC→JPEG/2048px) 후 업로드

### 일반 문의 창구 (응모와 무관한 회원 ↔ 운영팀, 마이그레이션 475~483 — 개발 완료 · 🔴**운영은 시행일 2026-10-06 에 한 번에**)
> 햄버거 「お問い合わせ」 → `#page-inquiry` 탭 둘(「キャンペーンのお問い合わせ」 = 대화가 시작된 응모만 + 「新しくお問い合わせ」 응모 고르기 / 「サービスのお問い合わせ」). 대화 화면은 `#page-messages` 를 **재사용**(`_msgMode` 로 갈림 — 나갈 때 정리 함수가 응모건 모드로 되돌려야 한다). 관리자 받은편지함은 탭 셋(캠페인 문의 / 서비스 문의 / 일괄발송 이력[캠페인관리자 이상]). 사양서 `docs/specs/2026-05-21-general-inquiry-desk.md`(「구현 결과」) · 작업표 `…-breakdown.md`
> 🔴 **공고 기간(9/29~10/5) 운영 배포는 골라 담기** — 개발 브랜치를 통째로 올리면 창구가 시행일 전에 열린다(방침 개정 공고 중). 앱 안 공지(`POLICY_NOTICE` `inquiryDesk2026`)만 먼저 나갈 수 있다
- **같은 표에 산다** — 일반 문의는 새 표가 아니라 `application_messages` 에 `application_id` NULL + `influencer_id` 로 들어간다. 🔴 **그래서 응모건을 세는 자리가 일반 문의 행을 딸려 올 수 있다** — 479(관리자 안 읽은 수)·480(감사용 청소)·482(탈퇴 파기 셋, `INNER` → `LEFT JOIN`)가 그 자리들을 고쳤다. 새로 메시지를 세는 조회를 만들면 **`application_id IS NOT NULL` 이 필요한지** 먼저 본다
- 회원 정책 넷 + 첨부 경로 판정 `_general_inquiry_path_is_own`(476, 경로 `general/{회원id}/{파일}`) · 응대 완료 `general_inquiry_resolutions`(477) · 함수 다섯(478 — 조회·발송·읽음·응대 완료·관리자 안 읽은 수) · 뷰 `general_inquiry_message_summary`(481). ⚠️ **뷰는 메시지 표 기준** — 회원 표 기준이면 관리자의 회원 표 읽기가 312 로 막혀 **관리자에게 빈 뷰**가 된다
- **483 은 이미 운영에 있다**(창구와 별개) — 본인이 보낸 첨부의 조회 정책. 저장소 삭제는 **조회 정책이 보이는 행만** 지우므로, 이게 없으면 「회수」가 성공해도 파일이 남는다(응모건 메시지도 같은 결함이었다). 폴더 소유까지 확인
- 사이드바 메시지 미응대 수는 **두 종류 합산이고 세는 자리가 둘**(`updateInboxSidebarBadge` · 30초 `refreshMsgBadgesLight`) — 한쪽만 고치면 30초 뒤 숫자가 되돌아간다
- 알림은 종류가 `message_received` 그대로이고 **`ref_table='general_inquiry'` 로만 갈린다** — 그 분기가 응모건 분기보다 **앞에** 있어야 한다(`notifications.js`, 뒤에 두면 응모건 화면으로 간다). 탈퇴 화면의 연락 안내는 이 창구로 간다. **로그인할 수 없는 자리**(로그아웃된 확정 회원 안내·가입 실패 안내)는 LINE 유지

### 자동응답(FAQ 가이드형, 마이그레이션 146)
> 응모건 메시지의 「문의 게이트」형 FAQ. 사양서 `docs/specs/2026-05-21-message-faq.md`. 빈 구멍 분석 `docs/specs/2026-05-29-message-faq-improvement.md`.
- `faq_nodes` — 자기참조 트리. `parent_id`/`kind`(category|item), `label_ko/ja`, `body_ko/ja`, `action_type`/`action_target`(앱 해시 경로 8종), `is_human_handoff`, `relevant_stages text[]`, `sort_order`, `active`. RLS SELECT authenticated / CUD `is_campaign_admin()`. 시드 31노드
- `faq_interactions` — `action`(viewed|resolved|handoff), `view_count`. `viewed` 부분 유니크. RLS INSERT 본인행 / SELECT `is_admin()`
- `record_faq_interaction(...)` RPC(SECURITY DEFINER, `influencer_id=auth.uid()` 강제, `viewed` 멱등 UPSERT)
- 화면: 관리자 `#adminPane-faq`(`dev/js/admin-faq.js`) / 인플 「문의 게이트」(`dev/js/messaging.js`) / 관리자 응대 보조(`dev/js/admin-messaging.js`). 판정 공용 `faqComputeStatus`/`faqComputeCancelPhase`(`dev/lib/shared.js`). 사양서 `docs/specs/2026-05-21-message-faq.md`

### 정산 (인플루언서 리워드 — 마이그레이션 217~223·299~303·337~342, ★운영 배포 완료 · 337~339·342 포함)
> 상세는 **`.claude/rules/settlement.md`** — 정산 화면·정산 마이그레이션을 열면 자동으로 읽힌다.
> 🔴 **이 영역을 설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).
> 🔴 아래는 규칙 파일이 자동으로 안 읽히는 자리에서도 알아야 하는 것이라 여기 남겼다(다른 영역·현재 원본 번호·잠금 상태 등).
> 🔴 **이 영역 파일은 Read 도구로 연다** — 셸(`cat`·`sed`·`grep`)로 보거나 고치면 규칙 파일이 **안 실린다**.
> 설계·질문이면 **`reverb-settlement` 스킬**이 길을 안내한다(파일을 안 여는 세션용 입구).

**현재 원본 번호** (함수를 재정의할 때 베이스 — 옮긴 덩어리의 ③ 줄마다 한 줄)
- `mark_settlements_paid_bulk` · `mark_settlement_revert` · `mark_settlement_paid` · `register_past_settlements` · `correct_settlement_payment` — **486**(베이스 416·416·343·339·341 아님)
- `_settlement_cert_candidates` — **455**(232 를 베이스로 재작성하면 알림 잠금이 사라진다 — 번호가 가장 큰 정의를 베이스로)

**송금 묶음·수수료**(마이그레이션 484~488 — ★**운영 반영 완료 2026-10-01**(문의 창구 475~482 보다 먼저, 골라 담기 #1831). 🔴 **운영 첫 기록 전**: 「미등록 응모를 묶음으로 기록」 경로를 시험 데이터로 한 번 — 첫 기록이 곧 도입일이다. 사양서 `docs/specs/2026-09-30-settlement-transfer-fee-record.md`)
- 🔴 **`source='app'` 묶음이 한 줄이라도 생기면 옛 송금완료 경로 셋이 거부된다**(`payout_bundle_required`) — **운영 SQL 편집기에서 `record_settlement_transfers` 를 시험 호출하지 말 것**(첫 기록이 곧 도입일, 되돌릴 함수 없음)

> ⚠️ **코드와 데이터베이스는 운영에 있지만 인플루언서에게는 잠겨 있다** — `settlement_settings.influencer_visible=false` + `cutoff_at=null`(자동 등록 0건). 지급은 관리자가 직접 처리. 🔴 **인플루언서 노출은 코드에서 제거됐다(343) — 두 값을 바꿔도 아무 일도 안 일어난다**. 되살리는 절차는 아래 343 항목. ⚠️ **두 값은 서로 다른 스위치다** — `cutoff_at` 을 켜도 화면·알림은 `influencer_visible` 이 막는다(지금 둘 다 꺼짐).
- 🔴 **인플루언서 노출은 완전히 제거됐다(마이그레이션 343).** 화면(`#mypage-sub-settlements`)·조회(`fetchMySettlements`)·햄버거 항목·알림 라우팅을 **지웠고**, 서버는 ①알림 발행 3곳(`mark_settlement_paid`·`mark_settlements_paid_bulk`·`backfill_settlements`)을 들어내고 ②본인 조회 정책 `settlements_select_own` 을 **삭제**했다. 정산 알림 2종은 `fetchMyNotifications` 가 **항상** 걸러낸다. ⚠️ **`influencer_visible` 칸과 `is_settlement_public()` 함수는 죽은 채 남겨 뒀다** — 지우면 배포 순서에 따라 앱이 없는 함수를 불러 오류가 쌓인다. ⚠️ 그래서 **그 스위치를 true 로 바꿔도 아무 일도 없다**. 되살리려면 343 의 「되돌리는 방법」부터 — **정책을 먼저 되돌리지 않으면 화면만 살고 목록은 0건**. ⚠️ 옛 잠금 구조(240·241·242)는 이것으로 대체됐다. 사양서 `docs/specs/2026-08-18-settlement-list-unification-and-payout-schedule.md` §9
- **실제 송금 기록 (3단계, 마이그레이션 338~342)**: 일괄 기록 + 실제 송금일·금액. 사양서 `docs/specs/2026-08-18-settlement-list-unification-and-payout-schedule.md` · 인수인계 `…-settlement-stage3-handoff.md`
  - **회차 송금 명단 엑셀**(`exportPayoutRoundExcel`) — 회차별 요약에서 회차 줄 체크박스로 골라 탭 줄 오른쪽 「다운로드(xlsx)」(**여러 회차면 한 파일** — 이전 회차 미지급은 고른 회차 중 가장 늦은 것보다 앞, **고르지 않은** 회차만) + 회차 상세 머리의 「다운로드(xlsx)」. 시트 둘(「회차 합계」 사람별 · 「건별」 — 캠페인·브랜드 포함. ⚠️ 미등록 건 브랜드는 조회가 안 줘 캠페인 목록에서 채운다(`_payoutBrandMap`, 못 받으면 「확인 실패」)). **대상은 회차 전체** — 사람별 화면의 검색·보기와 무관. 기본은 미지급만, 「송금완료 포함」 체크(`_payoutExportIncludePaid`, 두 화면 공유·진입 때 꺼짐). 🔴 **합계는 행의 `amount` 를 더한다** — 지급 행엔 `amount_jpy` 가 없어 `settlementEffectiveAmount` 를 다시 부르면 0원. ⚠️ 미확정은 빈칸·합계 제외. 페이팔은 **정산 행 스냅샷 우선**, 현재 값과 다르면 「(확인 필요)」. 회차가 `PAYOUT_LEDGER_WARN_UNTIL`(2026-09-30) 이하면 「지급대장 대조 전」 경고 줄. 「이전 회차 미지급 포함」(`_payoutExportIncludeEarlier`, 기본 켬·진입 때 켬)이면 밀린 이전 회차 미지급을 사람별 「미지급」 한 줄에 합친다 — 🔴 **범위 아래 끝 `PAYOUT_CARRYOVER_FROM`(2026-10-15) 을 앞당기지 말 것**(6~9월 미지급 약 486건은 시트로 이미 보낸 건이 섞여 이중 송금. 정산 3단계 뒤 「송금 기록 없는 건」 정리 전 금지 — 사양서 `2026-09-30-settlement-transfer-fee-record.md` D-6). 「지급일 기록 없음」 묶음엔 단추 없음. 미등록 조회 실패면 거부
  - 🔴 **화면 버튼과 그것이 부르는 서버 함수는 같은 배포에 묶이지 않는다** — 화면은 머지로, 함수는 SQL 편집기로 나간다. 실제로 **버튼은 열려 있고 함수는 없는** 구간이 생겼다(운 좋게 피해 0). **잠금을 푸는 변경은 함수 적용을 확인한 뒤 머지할 것**
  - **남은 일** — ①미등록 건을 지급대장과 맞춰 처리(4단계) ②그 뒤 `cutoff_at` 설정(5단계, **설정 화면이 없어 데이터베이스 직접 입력**). ⚠️ 「목록에 뜨는 건 = 실제로 등록되는 건 = 495」 일치

- 🔴 **인증 성공 판정은 사본이 여러 곳**(서버 후보 함수·검수 화면·엑셀·검수 결과 메일·인플루언서 일일 메일·일정 뷰·관리자 일일 메일 다섯째 절·브랜드 공유) — 판정을 고치면 전부 본다. 상세 `.claude/rules/cert-success.md`
- 🔴 **리뷰어형 정산 금액 = 영수증 실결제액(제품 가격 상한)**, 화면·메일 문구는 금액을 약속하지 않는다(다섯 자리가 같은 말) — 상세 `.claude/rules/receipt-amount.md`
- ⚠️ `settlement.view` 를 캠페인 매니저에게 열면 PayPal 이 노출된다 · 신청 반려·취소 → 정산 자동 보류 트리거·화면 가드 · 송금 묶음 표·확인 창·화면 배타 — 상세 `.claude/rules/settlement.md`

### 회원 탈퇴 (마이그레이션 345~367 — ★운영 배포 완료 · 회원이 실제로 탈퇴할 수 있다)
> 상세는 **`.claude/rules/member-withdrawal.md`** — 탈퇴 메일·파기 함수·탈퇴 마이그레이션·관리자 회원 화면을 열면 자동으로 읽힌다.
> 🔴 **이 영역을 설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).
> 🔴 아래는 규칙 파일이 자동으로 안 읽히는 자리에서도 알아야 하는 것이라 여기 남겼다(다른 영역·현재 원본 번호·잠금 상태 등).
> 🔴 **이 영역 파일은 Read 도구로 연다** — 셸(`cat`·`sed`·`grep`)로 보거나 고치면 규칙 파일이 **안 실린다**.

**현재 원본 번호** (함수를 재정의할 때 베이스 — 옮긴 덩어리의 ③ 줄마다 한 줄)
- `cancel_withdrawal` — **356**
- `request_withdrawal` · `request_withdrawal_for_member` · `advance_withdrawal_states` — **450**
- `purge_withdrawn_personal_data` — **396**(베이스 352)
- `_withdrawal_cancel_event_ticket` — **418**(베이스 350)
- `cancel_application` — **394**

> - ⚠️ **362(가입 차단)만 양쪽 다 안 넣었다** — `auth.users` 트리거라 실수하면 회원가입이 전면 중단된다. 별도 확인 후 적용
> - ⚠️ **시행 전 잠금이 살아 있다**(`withdrawal_settings.effective_date` 비어 있음). 승인된 결과물·행사 응모·정산 기록·받지 못한 보수 **넷 중 하나라도** 있으면 스스로 못 나가고 운영팀 연락(LINE)으로 간다 — 관리자 대행(작업 19)
> - ⚠️ **6개월 파기(작업 12)는 대상이 아직 0건** — 운영에서 실제로 지워진 파일은 없다
> - ⚠️ **아직 안 한 것(본문은 규칙 파일)**: 대행 확인 창의 「받지 못한 보수 건수·시행일 전 경고」(화면 몫) · 탈퇴 확정 계정의 **응모건 메시지 발송은 안 막는다**(구멍 — 작업 2에서 재판단) · **관리자 수동 행사 취소(288)는 송금완료만 본다**(같은 사고가 그 경로로 재현될 수 있다 — 후속 과제 C-2) · **메시지 첨부 파기(작업 12-B)도 운영에서 실제로 돈 적이 없다** · **페이팔 5년 파기는 효과 확인에 5년** — 시험 데이터로 확정일을 5년 전으로 돌려 한 번은 돌려 볼 것(아직 안 함) · **강제 탈퇴(자격 상실)는 값만 있고 화면이 안 보낸다** — 여는 날 예정일 메일의 대행 문단(`{{proxy_notice}}`) 분기를 볼 것

- 🔴 **탈퇴 확정 계정 차단 장치**(프로필 수정·응모 삽입·행사 예약·결과물 제출·두 번째 탈퇴 신청 — 통과 조항 둘·대기자 승격 예외, 거부 코드 `account_withdrawn` 은 `ui.js`·`shared.js` 두 곳) — 상세 `.claude/rules/withdrawn-account-guards.md`
- 탈퇴 신청·상태 전이·행사 예약 정리·개인정보 파기·페이팔 5년 파기·재가입 차단(361 운영 적용 · 362 미적용 — 설계는 규칙 파일)·홍보 메일 제외·영수증 파기·관리자 화면(사이드바 아이콘 자리 규칙 포함) — 상세 `.claude/rules/member-withdrawal.md`
- ⚠️ 관리자 사이드바 경고 아이콘은 **항목마다 장치 하나 · 자리 셋**(나중에 도는 쪽이 이긴다) — 상세 `.claude/rules/admin-sidebar-indicators.md`

### 일별 방문자수 (마이그레이션 332)
> 화면 = 관리자 대시보드 「일별 방문자수」 카드(회원가입 추이와 2열), 기간 7일/30일/전체. ⚠️ 세는 기준 문구는 **차트 아래 정적 줄**이다 — 헤더에 넣으면 옆 카드와 높이가 어긋나고 조회 실패 시에도 남아야 해서 `visitChartNote`(동적)와 분리.
- `site_daily_visits` — `(visit_date, app)` 유일. `visitor_count`(브라우저 단위 하루 1회) + `page_view_count`(보조, 화면 미사용). **개인 식별 값 없음**. 조회 `is_admin()`, **쓰기 정책 없음**(함수만 — `client_error_logs` 와 같은 형태)
- `record_site_visit(p_app, p_is_new_visitor)` — anon·authenticated 호출. 263(`increment_campaign_view`)을 본떠 관리자·감사용 계정을 서버가 제외. ⚠️ **날짜는 서버가 만든다**(과거 날짜 부풀리기 방지). 앱 구분이 화이트리스트 밖이면 **조용히 종료**
- ⚠️ **저장소를 못 쓰면 세지 않는다 — 조회수(263)와 정반대이고 의도한 것이다.** 하루 한 행이라 한 사람의 새로고침이 그대로 그날 수가 된다. 「일관성 없다」며 맞추지 말 것 (`_markSiteVisited`·`recordSiteVisit`)
- ⚠️ 호출은 **부팅 1회**, **세션 복원 뒤**(`dev/js/app.js` `init()` 의 `updateGnb()` 직후) — 아니면 **운영자 접속이 방문자로 세어진다**
- ⚠️ **관리자·감사용 제외는 SQL 편집기로 검증 못 한다**(서비스 키라 그 분기가 안 돈다 — 마이그레이션 272 와 같은 함정). 로그인 브라우저로만 확인
- 봇 방어는 `navigator.webdriver` + 미리 불러오기 제외뿐 — **헤드리스 봇은 못 거른다.** 「참고 지표」임을 밝힐 것
- 도입 이전 구간은 **백필 없음** — 0으로 그리지 말 것(「방문자 0명」으로 오독)
- **화면**(`dev/js/admin-dashboard.js` `_computeVisitSeries`/`renderVisitChart`/`loadVisitChart`/`switchVisitPeriod`, 조회 `fetchSiteDailyVisits`): ⚠️ **날짜 기준이 옆 회원가입 차트와 다르다** — 가입 차트는 `toISOString()`(세계시), 방문 집계는 **일본 표준시** 날짜라 세계시로 자르면 어제 숫자가 오늘 칸에 간다(`_visitDateTodayKst`·`_visitDateShift` — 문자열 연산이라 시간대 무관)
- ⚠️ **조회 실패(`null`)와 기록 0건(`[]`)을 구분**해 다른 안내를 띄운다 — 어느 쪽도 0을 그리지 않는다(마이그레이션 276 원칙). ⚠️ **도입 이전은 자르되 도입 이후의 빈 날은 0이 맞다**
- ⚠️ 차트 오른쪽 끝은 **`max(오늘, 마지막 기록일)`** — 자정 직후 PC 시계가 조금만 느려도 **그릴 칸이 0개가 된다**
- 열람 권한은 **관리자 전원**(`is_admin()`)

### 메타 픽셀 (마이그레이션 438·439 — ★**운영 적용 완료** · 🔴 **운영 전송 중**(설정 시행일 `2026-09-18` · 켜짐 · 아이디 입력))
> 방문·가입·신청을 Meta 로 보낸다. 관리 화면은 「광고 추적」, 전송은 `dev/js/meta-pixel.js`. 사양서 `docs/specs/2026-09-03-meta-pixel.md` · 작업표 `…-meta-pixel-breakdown.md`
> 🔴 **잠금 구조** — 설정 시행일이 비었거나 미래면 켜기 거부·앱용 조회 빈 값. **그 날짜 입력이 곧 잠금 해제**. ⚠️ 방침 문서·앱 공지·통지 메일의 시행일 `2026-10-17` 은 어긋남이 아니라 사용자 결정이다. 되돌리지 말 것.
- `meta_pixel_settings` — 한 줄(id=1). `meta_pixel_id`(숫자만) · `enabled` · `policy_effective_date` · `updated_at/by`. 조회 `is_admin()`, **쓰기 정책 없음**. 🔴 **시행일을 바꾸는 함수는 없다** — SQL 편집기로만
- `meta_pixel_settings_history` — 추가만. 🔴 **저장 함수가 아니라 설정 표의 트리거가 쓴다** — SQL 로 넣은 값도 남도록. 로그인 없으면 `actor NULL` →「시스템(직접 입력)」. ⚠️ `updated_by` 를 이력의 `actor` 로 옮겨 적지 않는다(직전 저장자가 찍힌다)
- 🔴 **시행일 판정식은 `_meta_pixel_policy_in_effect(date)` 한 곳**이고 저장 거부·앱용 조회·상태 배지가 그것을 부른다. 식 = `p_date IS NOT NULL AND p_date <= (now() AT TIME ZONE 'Asia/Tokyo')::date`. **다른 함수에 복사하지 말 것**
- `get_meta_pixel_admin()` — 관리자 전원. 설정 + `status` + 최근 이력 50건. `update_meta_pixel_settings(text, boolean)` — 가드는 `is_campaign_admin()` 이 아니라 **`has_permission('ad_tracking.manage','write')`**. ⚠️ **「꺼짐 → 켜짐」 요청만** 시행 전이면 거부 — 아이디 저장·끄기는 항상 허용
- `get_public_meta_pixel_id()` — 비로그인·로그인 모두. ①켜짐 ②아이디 있음 ③시행일 도래 ④관리자·감사용 아님(332 와 같은 판정) — 넷 다 참일 때만 아이디, 아니면 **빈 문자열**(NULL 아님 — 실패와 구분).
- ⚠️ **실행 권한은 회수 방향이 둘**(369·370·375) — 앱용 조회만 `anon`·`authenticated`, 관리 함수 둘은 `authenticated`, 헬퍼·트리거 함수는 셋 다 회수
- ⚠️ **관리자·권한·감사용 판정은 SQL 편집기로 재현 못 한다** — 실제 로그인 브라우저로 확인
- 🔴 **배포는 데이터베이스 먼저, 코드 나중** — 반대면 없는 함수를 불러 오류가 쌓인다. ⚠️ 개발에서 앱 코드가 438 보다 먼저 나간 적이 있다. 439 는 438 뒤, **관리 화면과 같은 배포**에(화면은 못 읽으면 열고 서버는 거부 — 방향이 반대)

### 메일·기준 데이터·알림
- `lookup_values` — 기준 데이터. `kind`(channel/category/content_type/ng_item/reject_reason/blacklist_reason/violation_reason/caution/admin_email_kind/cancel_reason/**admin_proxy_reason**), `code`, `name_ko`, `name_ja`, `sort_order`, `active`, `recruit_types[]`(channel 만 사용). `admin_proxy_reason`(마이그레이션 160) 시드 4건: shipping_delay/system_error/inflexible_deadline/other
- `participation_sets` — 참여방법 번들. `name_ko`/`ja`, `recruit_types[]`, `steps jsonb`, `sort_order`, `active`. `campaigns.participation_steps jsonb` 스냅샷 + `participation_set_id` FK ON DELETE SET NULL
- `caution_sets` — 주의사항. items `{text_ko, text_ja, link_url?, link_label_ko?, link_label_ja?, text_after_ko?, text_after_ja?}`. `campaigns.caution_items jsonb` + `caution_set_id` FK ON DELETE SET NULL. RLS SELECT 관리자
- `ng_sets` — NG. items `{html_ko, html_ja}`(DOMPurify, inline 서식만). `campaigns.ng_set_id` + `ng_items jsonb` 스냅샷. RLS SELECT `is_admin()`, CUD `is_campaign_admin()` 이상.
- `notifications` — 인플루언서 알림. `kind`(deliverable_rejected/deliverable_changed/deliverable_approved/application_cancelled/message_received/application_approved/**deliverable_proxy_submitted**/**settlement_paypal_required**/**settlement_paid**), `ref_table`/`ref_id`, `title`, `body`, `read_at`. deliverable_* 는 status 전이 트리거가 생성, 재제출 시 미읽음 자동 dismiss. `message_received`(145)=관리자 답장 시 send 함수 · `application_approved`(154)=→approved 전이 시 `record_application_status_event()`(「キャンペーンに当選しました」 — 당선 안내) · `deliverable_proxy_submitted`(160)=대리 등록 시 `admin_create_deliverable_proxy()`(「結果物が登録されました」 — 결과물 등록됨). 셋 다 **미읽음 중복 방지**. 클릭 시 `message_received` 는 메시지 모달, `application_approved`/`application_cancelled`/`application_restored`는 응모이력(ref_table='applications' 공유라 kind 한정 필수). 🔴 **종류 검사 제약의 현재 원본은 440**(13종) — 376 이 아니라 440 을 베이스로
- `admin_daily_digest_runs` — 관리자 통합 다이제스트 로그. `digest_date` UNIQUE(mutex) + `status CHECK(sent|skipped_no_data|failed)` + `sections_summary jsonb`(`{received, cancelled, submitted, reprocessed}`) + `recipients_count` + `error_message` + `run_at`. RLS SELECT `is_admin()`, INSERT 는 service_role 만
- `influencer_daily_digest_runs` / `application_received_admin_digest_runs` — 로그. `digest_date` UNIQUE
- `deadline_reminder_email_sent` — D-5·D-1 임박 메일 재발송 차단. UNIQUE `(influencer_id, campaign_id, kind, d_minus)`
- 캠페인 홍보 메일 4종(주 2회, 모두 RLS SELECT `is_admin()`·쓰기 정책 없음 → service_role만):
  - `campaign_promo_digest_runs` — run 로그. `digest_date` UNIQUE mutex + `status`/카운트/`included_campaign_ids`/`started_at`·`finished_at`
  - `campaign_promo_digest_sent` — `(influencer_id, digest_date)` UNIQUE(1통/cron) + `skip_reason`
  - `campaign_promo_exposure` — `(campaign_id, influencer_id, kind)` UNIQUE(캠페인당 최대 2회)
  - `campaign_promo_email_clicks` — CTA 클릭. `(campaign_id, influencer_id)` UNIQUE
  - 관련 RPC: `get_promo_digest_targets(date)`·`get_promo_digest_campaign_pool(date)`·`mark_promo_digest_sent`·`track_promo_click`(anon)·`unsubscribe_by_token`(anon 1-click 수신거부)·`resubscribe_marketing`(본인 재구독)
- 헬퍼 `_yesterday_kst_window()` STABLE — 어제·오늘 KST 날짜

### 사용자 앱 에러 수집 (마이그레이션 165)
> 인플루언서 앱 에러를 관리자가 모아 본다(실시간 아님). 개인정보 마스킹 필수.
- `client_error_logs` — fingerprint 묶음. `fingerprint`+`status`(open/resolved/ignored) UNIQUE, 같은 에러는 `occurrence_count` 누적. `source`(influencer/admin)·`kind`(unhandled/rejection/handled)·`message`/`stack`/`page_hash`(마스킹)·`error_code`·`user_id`(influencers FK, anon 은 NULL)·`first/last_seen_at`·`resolved_by/at/note`. RLS SELECT `is_admin()` 만, 쓰기는 RPC 경유
- `report_client_error(...)` RPC — SECURITY DEFINER, **anon+authenticated**. 빈값·범위·길이 가드 + **서버측 2차 마스킹**(이메일·전화·우편번호 `\d{3}-\d{4}`·Bearer 토큰·PostgreSQL `(col)=(val)`) + open fingerprint UPSERT
- `resolve_client_error(id, status, note)` RPC — `is_admin()` 가드(open 되돌리기 시 resolved_* 초기화)
- 클라: `dev/js/error-report.js`(`window.onerror`·`unhandledrejection` + `friendlyErrorJa` 훅 + 1차 마스킹·노이즈필터·60초 디바운스·throw 안 함), `storage.js` `reportClientError()`. 사양서 `docs/specs/2026-06-02-client-error-reporting.md`

### RLS·인증·세션
- 캠페인 SELECT 공개, 나머지는 본인 or 관리자만
- `is_admin()` / `is_super_admin()` / `is_campaign_admin()`: admins 에서 auth.uid() 조회(search_path 고정)
- 트리거: auth.users 생성 시 influencers 자동 생성
- 세션 만료: `retryWithRefresh()` 로 갱신 후 1회 재시도
- **함수 실행 권한 — 회수 방향이 둘이다**(마이그레이션 369·370): **Postgres 는 새 함수에 PUBLIC 실행 권한**을, **Supabase 는 거기 더해 `anon`·`authenticated` 에 개별로** 준다. `REVOKE ALL FROM PUBLIC` 은 개별 부여를, `REVOKE … FROM anon, authenticated` 는 PUBLIC 부여를 못 걷는다 — **서로를 대신하지 못한다.** ⚠️ **`has_function_privilege` 만 보면 방향을 모른다**(PUBLIC 이 남으면 둘 다 `true`) — `p.proacl::text` 의 **맨 앞 `=X/`** 유무를 함께 볼 것. ⚠️ **개발과 운영의 권한 상태가 다를 수 있고 저장소 문서로는 못 알아낸다** — 직접 조회할 것. ⚠️ `REVOKE` 는 **대상이 없어도 「Success」** — 돌린 뒤 다시 조회해 확인. ⚠️ 안쪽 호출은 감싸는 함수가 **`SECURITY DEFINER`** 라 산다 — **`SECURITY INVOKER` 로 부르면 끊긴다**(`recompute_campaign_applied_count` 를 잘못 건드리면 **응모가 통째로 막힌다**. 증명 절차는 370 주석). ⚠️ **순수 계산 함수 3종은 일부러 안 닫았다**(`_meets_min_followers`·`_withdrawal_email_hash`·`_accumulate_legacy_no` — 표를 안 읽는다)
- **함수 실행 권한 — 「안쪽에 호출자 검사가 없는 함수」는 별도로 훑는다**(마이그레이션 375): 본문에 `is_admin()`·`auth.uid()` 검사가 없으면 권한 부여가 **유일한 방어선**이다. 🔴 `get_subscribed_admin_emails` 는 **로그인 없이** 관리자 이메일을, `get_promo_digest_targets` 는 회원 이메일·이름·**수신거부 토큰**을 돌려줬다 — 그 토큰이면 `unsubscribe_by_token`(비로그인 수신거부)으로 **남의 수신 설정을 끈다**. `mark_promo_digest_sent` 는 가짜 기록으로 회원을 메일에서 뺄 수 있었다. ⚠️ **「비로그인만 막으면 된다」가 아니다** — `get_promo_digest_targets` 는 **`authenticated` 만 열려** 있었다. 두 역할을 **따로** 볼 것. ⚠️ **회수 전에 `service_role` 이 자기 권한을 따로 갖는지 확인** — PUBLIC 경유뿐이면 PUBLIC 회수가 **메일을 통째로 죽인다**(375 는 먼저 `GRANT … TO postgres, service_role`). ⚠️ 인자 많은 함수(기본값 포함)는 **별도 트랜잭션**으로 — 어긋나면 앞의 것까지 되돌아간다. 개발·운영 적용 완료
- ⏸️ **아직 안 닫은 것 — 판단 대기**: `is_email_withdrawal_blocked(text)` 는 **비로그인에 일부러 연 것**이다(362 미적용이라 **유일한 재가입 차단 수단**). 그런데 **임의 이메일의 탈퇴 여부를 알려 줘** 361·362 의 「실패 문구를 같게」 설계와 어긋난다. **지금은 시행일이 비어 항상 거짓.** **작업 18(약관 개정)·362(가입 차단)와 함께 판단할 것**

## Test Accounts
- 관리자: admin@kemo.jp / admin1234
- 테스트 인플루언서: sakura.test@reverb.jp, yui.test@reverb.jp, haruka.test@reverb.jp (비밀번호: test1234)

## Dev Workflow
- 개발: dev/ 에서 수정 → dev/index.html 로 확인
- 배포: `cd dev && bash build.sh` → 루트 index.html 자동 업데이트
- 파일명이 기능과 일치 (캠페인=campaign, 로그인=auth 등)
- DB API: `dev/lib/storage.js` 에 모든 DB 함수 집중 (fetchCampaigns, upsertInfluencer 등)
- 세션: onAuthStateChange 로 SIGNED_IN/TOKEN_REFRESHED/SIGNED_OUT/SESSION_EXPIRED 처리 (양쪽)
- URL 정제: `cleanUrl()` 로 마크다운 링크 형식 자동 변환 (product_url 등)
- 페이지 전환: 같은 탭에서 이동 (새 탭 금지). ⚠️ **예외 2종은 새 탭이 맞다** — ①앱 경계를 넘는 전환(인플루언서 앱 → `/admin/`, `dev/js/app.js`) ②**자립형 단독 화면**(`admin-setpw.html`·`event-scan.html` — 현장 확인은 부스 단말용). 되돌리지 말 것
- 깜빡임 방지: visibility:hidden cloak (양쪽)
- 마이페이지 서브해시: `#mypage-applications` 등으로 복원
- 약관/정책 수정: `docs/{TERMS,PRIVACY}_{kr,ja}.md` 가 source of truth. 앱 푸터 약관은 `dev/lib/legal.js` 가 이 4개 md 를 **런타임 fetch + 렌더링** — 빌드 무관. 한·일 동시 수정 + 부칙 갱신 (`.claude/rules/policy.md`)

## Conventions
- 인플루언서 페이지 UI 텍스트: 일본어
- 관리자 페이지 UI 텍스트: 한국어
- 코드 주석: 한국어 (일본어 금지)
- 날짜 포맷: ja-JP
- `lang="ja"`

## Rules
- 관리자 페이지는 반드시 PC 레이아웃 유지 (모바일 쉘 금지). ⚠️ **관리자 뷰포트는 `width=1280` 고정** — `width=device-width` 면 `#page-admin`(fixed·overflow:hidden) 안 900px 레이아웃이 잘려 **모바일에서 오른쪽이 안 보이고 스크롤·축소도 안 된다**. 자립형 화면(`admin-setpw`·`event-scan`·`report`)과 오리엔시트 인쇄 새창은 대상 아님
- 인플루언서 페이지만 모바일 전용 (480px)
- db 참조 시 항상 `db?.from()` 사용 (null-safe)
- `.single()` 대신 `.maybeSingle()` 사용
- localStorage 이미지 base64 는 별도 키로 분리 (용량 초과 방지)
- 캠페인 삭제는 **보관 삭제(soft delete)** — 🔴 **저장소 파일은 「신청을 지우기 직전에 경로를 모아 돌려주고」 화면(`softDeleteCampaign`)이 지운다**(325). 뒤집으면 **나중에 지울 방법이 없다**. 영수증 수정 이력(`receipt_edit_history`)도 함께 파기. ⚠️ **캠페인 이미지(img1~8)는 안 지운다**— 다만 **완전 삭제(`purge_campaign`·`purge_expired_deleted_campaigns`) 때도 안 지워** 공개 버킷에 영구 잔존(후속 과제). 캠페인 행은 `deleted_at` 으로 30일 보관(「삭제됨」 탭 복구) 후 pg_cron 자동 완전삭제, applications·deliverables(개인정보)는 즉시 파기. 정산 걸린 캠페인은 삭제 차단(251 트리거). 복구=campaign_admin·완전삭제=super_admin. 사양서 `docs/specs/2026-07-22-campaign-soft-delete-restore.md`
- 이미지 업로드는 Supabase Storage (`campaign-images` 버킷) 사용
- 비밀번호 재설정: Authentication → URL Configuration → Redirect URLs 에 양 도메인 등록 필수
- 아이콘은 Material Icons 사용 (이모지 금지), `translate="no"` 필수
- 하드코딩 DOM 인덱스 금지 (`:nth-child` 인덱스 직접 사용 금지)
- **이미지 썸네일 — 유료 변환을 쓰지 않는다**: `storageThumbUrl(url)`(ui.js) 로 **올릴 때 저장한 사본**(`{폴더}/thumb/{본체와 같은 파일 이름}`)을 가리킨다. 저장은 `uploadImage`·`uploadContentImage`·`uploadOutboundImage` 가 `_uploadThumbCopy` 로 하고 **데이터베이스 칸 없이 주소 규칙으로 찾는다**. `data-orig` + `onerror` 원본 폴백은 **여전히 필수**(썸네일 없는 옛 파일).
  - ⚠️ **설명 이미지 썸네일은 화면에 그릴 때만**(E-2) — `richHtml`·`miniRichHtml`·`renderCautionItemsHtml`·`renderNgItemsHtml` 이 `displayWidth` 를 줘서 `content/thumb/` 를 받고, **저장 경로는 인자 없이 불러 원본 주소가 저장된다.** 조건은 `typeof storageThumbUrl`(E-5)
  - 🔴 **`imgThumb`(유료 변환 `/render/image/`)은 아무도 안 부른다. 되살리지 말 것** — 포함량을 크게 넘겨 요금이 나갔다(캐시 `cacheControl:'86400'` 로도 못 막음). **죽은 코드인 줄 알고 지우지도 말 것**(되돌릴 여지)
  - **폭은 폴더마다 다르다** — `campaigns`·`content` **720** / `receipts`·`review-images`·아웃바운드 **480**. 🔴 720 은 캠페인 상세 첫 장 요구값(`application.js`), 480 은 영수증이 작게 뜨고 확대는 원본을 열며 **개인정보라 작을수록 낫기** 때문
  - ⚠️ **같은 목록이 세 곳 — 항상 같은 집합으로**: 화면 `THUMB_FOLDERS`(ui.js) · 저장 `THUMB_WIDTH_BY_PREFIX`(storage.js) · 소급 `FOLDERS`(`scripts/backfill-storage-thumbs.js`). **경로 규칙**(「{첫 칸}/thumb/{나머지}」)은 storage.js `_thumbPathOf`(E-4) + ui.js `storageThumbUrl` + Edge Function `purge-withdrawal-media` 의 `withThumbs` — 바꾸면 셋을 함께. 아웃바운드 폭은 `THUMB_WIDTH_OUTBOUND`. 어긋나면 **없는 썸네일을 요청**하거나 **안 쓰는 파일**이 쌓인다
  - ⚠️ **통마다 판정이 다르다** — `campaign-images` 는 첫 칸(용도 폴더)을 목록으로 거르고, `outbound-influencer-images` 는 첫 칸이 **회원 고유번호**라 **통 전체**(`THUMB_ALL_BUCKETS`)
  - 🔴 **원본은 절대 압축하지 않는다** — 「영수증에서 읽기」가 저장 파일 글자를 읽는데, 큰 영수증을 압축하자 주문번호 `1209389647` 이 **`120938964`** 로 빠졌다. 그래서 썸네일만 따로 둔다
  - 🔴 **개인정보 사본이라 파기하는 자리가 썸네일도 함께 지워야 한다** — 화면 4곳(`softDeleteCampaign`·`purgeAuditDataAll`·`purgeAuditDataForCampaign`·고아 정리 `deleteCampImages`[E-3])은 공용 `_withThumbPaths(paths)` 를, 예약 실행은 `purge-withdrawal-media` 안 `withThumbs` 를 거친다. **하나라도 빠지면 「지웠다」면서 남는다**(공개 통). 아웃바운드는 `deleteOutboundImage` 가 함께 지운다
  - ⚠️ **`remove()` 는 없는 파일에도 성공으로 답한다** — **응답만으로는 지워졌는지 모른다**
  - 🔴 **`campaign-images` 조회 정책은 「관리자 또는 본인이 올린 파일(`owner_id`)」**(474) — 회원 썸네일 저장이 `upsert: true` 라 **owner 조건을 빼면 회원 썸네일이 조용히 멈출 수 있다**. 아웃바운드 통 조회는 `outbound.view` 읽기 권한자만. 두 통 모두 공개 링크는 무관
  - ⚠️ **썸네일 실패는 삼킨다** — `onerror` 로 본체를 그린다. `keepIfSmall` 로 좁은 사진은 다시 굽지 않는다(**투명한 PNG 배경이 검게** 되는 함정)
  - 🔴 **기존 파일에 썸네일을 먼저 만든 뒤 표시를 바꾼다** — 뒤집으면 폴백이 **원본을 받아 더 나빠진다**. 도구 `scripts/backfill-storage-thumbs.js`(관리자 콘솔, 재실행 안전) — **개발·운영 각각**
  - 사양서 `docs/specs/2026-08-31-image-thumbnail-two-copies.md`
- 채널 비교는 항상 `split(',')` 후 `includes()` 사용 (단일 `===` 비교 금지 — 멀티채널 누락 위험)
- **채널 코드 이관은 3곳 동시가 한 세트**: 채널 `code`(`lookup_values`)를 바꾸거나 지울 때 **①기준 데이터 ②캠페인(`campaigns.channel`) ③결과물(`deliverables.post_channel`)** 을 **함께** 옮긴다. 아니면 채널 비교가 **인플루언서 활동관리 · 관리자 인증 상태(`computeCertStatus`) · 정산 후보(`_settlement_cert_candidates()`)** 3곳에서 함께 깨진다(@cosme 때 인증샷 55건 소실 — 패치 `supabase/patches/2026-07-30-fix-cosme-review-image-channel-code.sql`, 보고서 `docs/specs/2026-07-30-cosme-channel-affected-report.md`). 🔴 **기존 관리자 도구로 못 고친다** — 162 의 채널 지정·해제·삭제 3함수는 거부하고, 구제 장치(`hasLegacyReviewImage`)는 **빈 값일 때만** 작동해 **「값이 틀린」 경우가 사각지대**다. ⚠️ 교정 시 `status` 를 건드리면 알림이 몰리고, 옛·새 코드 **공존 행**은 중복 금지 제약(`deliverables_review_image_app_channel_uniq`)에 걸린다 — 미리 배제할 것. **공존 26건은 「그대로 유지」**(보고서 §4 「26건 유지 결정 근거」).
  - **재발 방지 — 캠페인 채널 변경 가드**: ①편집에서 **결과물이 제출된 채널을 빼면 확인창**(영향 건수 표시, 막지 않고 묻는다). 건수 `countDeliverablesByChannels` ②**모집 형식 라디오를 눌러도 저장된 채널이 증발하지 않는다** — `renderChannelCheckboxes` 의 보존 기준은 화면 체크값이 아니라 **`opts.savedCodes`(저장된 값)**. ⚠️ **비활성 처리도 같은 위험** — `fetchLookups` 가 `active=true` 만 반환한다. ⚠️ 확인창은 `_editCampOriginal.channel` **스냅샷에 의존**하므로 그 키가 비면 죽은 코드(브라우저 1회 발동 확인 필수)
  - **감지 장치**(마이그레이션 277·278·319, `detect_channel_code_drift()`): 조회 전용·`is_admin()` 가드. 3층 = **A**(결과물 채널이 요구 채널에 없음 — 실제 피해) · **B**(캠페인 채널이 기준 데이터에 없음 — 조기 경보) · **C**(결과물 채널이 기준 데이터에 없음, `other` 등). ★ **제외 규칙 = 「같은 응모·같은 종류에 캠페인 채널과 정확히 일치하는 행이 있으면 뺀다」(상태 불문)** — 공존 26건이 자동 통과. ⚠️ **`covered` 는 A층·C층 양쪽에 적용**(옛 코드는 C에도 걸린다). ⚠️ **승인 상태를 요구하지 않는다**: 판정 세 곳(`_finalizeMonitorReprs`·`count_pending_review_applications`·`_settlement_cert_candidates()`)이 행 존재만 본다. ⚠️ **반려된 결과물은 경보하지 않는다**(278). 단 그 조건은 **`mismatched`·C층에만**, `deliv` 에는 넣지 않는다 — `covered` 는 **상태 불문**이어야 해서, 빼면 반려 행만 있는 경우 A층에 잘못 뜬다.
  - **화면 3단**: ①사이드바 경고 아이콘(결과물 관리·기준 데이터 — **부팅 시 1회 조회**) ②페인 제목 옆 경고 버튼 ③모달(종류별 조치 + 「캠페인 편집 열기」). `refreshChannelDriftIndicators` 계열(admin-core.js). ⚠️ **조치 안내는 결과물 종류로 분기** — 「검수 창의 채널 불일치 표시에서 지운다」는 **게시물 전용**이고 **리뷰 인증샷에는 없다**. 🔴 **0건이면 아무것도 안 그린다**(조회 실패 때도) — 늘 떠 있으면 무시하게 된다. ⚠️ **비교 규칙이 층마다 다르다**(319): A층은 **실제 판정과 글자 그대로**(캠페인 토큰=`btrim` 만 / 결과물 채널=원본) — `lower` 면 **대소문자만 다른 값을 통과**시킨다. **B·C층은 일부러 `lower` 유지**. `covered` 는 `(응모, 결과물 종류)` 로만 결합
  - 운영 경보는 0에서 시작(C층의 `other` 2건은 반려 → 278 로 제외)
  - **아직 안 한 재발 방지 1종**: 채널이 빈 캠페인에서 게시물 채널로 **「その他」를 고를 수 있는 구멍**(원천은 시딩·방문형 채널 0개 저장 허용. ⚠️순서 = 편집 필수화 → 정리 → 「その他」 제거. 먼저 지우면 고를 값이 0개)
- **최소 팔로워수 정책 — 채널 묶음에 따라 갈래 셋**(마이그레이션 384·385): **채널 1개**=그 채널로 검사 / **「또는」**(`channel_match='or'`)=**모집 채널 중 하나라도** 넘으면 통과 / **「그리고」**(`='and'`)=**채널마다 따로** — `campaigns.min_followers_by_channel`(jsonb). `recruit_type='monitor'` 는 **건너뛴다**(저장 때 `min_followers`·`primary_channel` 이 0·`null`, 채널별 칸도 `{}`). ⚠️ **채널 1개를 별도 갈래로 둔 이유** — 하나인데 `and` 로 저장되면 빈 칸을 읽어 **검사가 통째로 사라진다**. ⚠️ **빈 채널별 칸은 「검사 안 함」이지 0이 아니다**(화면에 「제한 없음」). ⚠️ **입력칸은 팔로워 값을 가진 네 채널만**(Instagram·X·TikTok·YouTube) — **Qoo10 은 Instagram 값을 빌린다**(`campaignMinFollowersByChannel`. 🔴 저장 칸을 직접 읽으면 화면은 「제한 없음」인데 실제로는 막힌다). **LIPS·@cosme 는 값이 항상 0** 이라 칸을 만들면 아무도 통과 못 한다(지금은 리뷰어형 전용이라 건너뜀 — **그 안전판이 사라지면 문제**).
  - 🔴 **같은 판정이 두 곳에 산다** — 화면 `dev/lib/shared.js`(`campaignFollowerKind`·`meetsMinFollowers`·`minFollowersDisplay`)와 홍보 메일 SQL(`_meets_min_followers`, 현재 원본 **387**). **한쪽만 고치면 메일은 오는데 응모는 막히고 오류는 없다.** 🔴 **387 은 옛 8인자를 `DROP` 했는데 그때 141 의 회수(`FROM PUBLIC, anon`)도 사라진다** — 387 이 다시 건다. ⚠️ 「일부러 안 닫은 셋」은 **369·370 정리에서 뺐다**는 뜻이지 **회수가 없다는 뜻이 아니다** 🔴 `get_promo_digest_targets`(현재 원본 **471**, 베이스 417→387→360)는 **반드시 `CREATE OR REPLACE`** — `DROP` 후 `CREATE` 하면 375 의 회수가 풀려 회원 누구나 남의 이메일·수신거부 토큰을 받는다.
  - ⚠️ **화면 표시는 `minFollowersDisplay` 가 재료만 주고 문구는 각 화면이 만든다**(관리자 빌드엔 `t()` 없음) — **다섯 곳을 함께**: ①인플 캠페인 상세(`minFollowersDetailLines`) ②응모 차단 문구(`followerBlockMessage`) ③관리자 폼·미리보기(`admin.js`) ④**삭제된 캠페인 상세**(`deletedCampMinFollowersCell`) ⑤**FAQ 자동응답**(`_buildFaqCtx` + 본문, 마이그레이션 386). ⚠️ **메일에는 이 조건을 쓰는 곳이 없다**. ⚠️ 경위·팝업 3건 1,000 → 0 조치는 `docs/specs/2026-08-27-min-followers-channel-match.md`
- **Sales(광고주) 서브도메인 규칙**: `sales.globalreverb.com` / `sales-dev.globalreverb.com` UI 한국어, `<meta name="robots" content="noindex,nofollow">` 유지. `/reviewer`·`/seeding` 은 Vercel `cleanUrls`. 파일 업로드 없음
- **익명 폼 INSERT 패턴**: anon 이 쓰는 테이블은 `.insert().select()` 대신 **SECURITY DEFINER RPC** 로 (RETURNING SELECT 충돌로 42501)
- **관리자 리스트 IntersectionObserver lazy-load**: 8개 페인(campaigns/applications/deliverables/camp-applicants/influencers/lookups/admin-accounts/brand-applications) sentinel 점진 렌더(필터·검색·정렬 변경 시 리셋 필수). `renderAppCampList` 는 campaigns/applications/influencers 캐시 공유
- **PostgREST 1000-row cap 대응**: 집계용 fetch(`fetchInfluencers`/`fetchApplications`/`fetchDeliverables` 등)는 `range(from, from+999)` 루프로 전건 조회. 단일 `.from().select()` 는 1000건에서 잘림
  - **무거운 목록은 페이지를 동시에 받는다**(2026-09-30): `fetchAllPagedFast`(storage.js — 결과물·신청·인플루언서 목록). 🔴 **조건 둘** — ①일반 표 조회만(`db.rpc` 는 페이지마다 함수 전체가 다시 돌아 부하가 몰린다) ②정렬 끝에 **`.order('id')`**(고유 순서가 아니면 페이지 경계에서 한 건이 겹치거나 빠진다 — `fetchAllPaged` 도 같다). 번호 목록을 200개씩 끊는 조회도 `mapLimit`(최대 4개 동시) — ⚠️ 함수마다 실패 규약이 다르다(`{}`·`null`·「실패 조각만 건너뜀」), 옮길 때 그대로. ⚠️ 운영 데이터베이스가 가장 작은 사양이라 **결과물 조회는 동시 2개**
- **인플루언서 앱 캠페인 목록 보관**(2026-09-30, `campaign.js` `getCampaignsCached`): 받아 둔 목록으로 먼저 그리고 뒤에서 새로 받아 **바뀌었을 때만** 다시 그린다(10초 안이면 안 받음). ⚠️ 신청 인원을 바꾸는 동작(응모·취소·행사 예약·예약 취소) 뒤에는 **`invalidateCampaignsCache()`** — 새 경로를 만들면 함께. ⚠️ `fetchCampaigns` 자체는 관리자도 써서 **보관하지 않는다**(편집 직후 최신값 필요)

## Mobile Layout Rules
- `#appShell` 은 `position:fixed` + `top:0`/`bottom:0`
- html, body 에 `height:100%` + `overflow:hidden` 유지
- 페이지 콘텐츠 스크롤은 `.page.active` 내부에서만 (`flex:1` + `overflow-y:auto`)
- GNB 는 `flex-shrink:0` 고정 (바텀탭 없음 — 햄버거 메뉴)
- 모바일 키보드: visualViewport API 로 `appShell` 높이 동적 조절
- input/textarea/select 의 `font-size` 는 반드시 16px 이상 (자동 확대 방지)
- `100vh`/`100dvh` 대신 `position:fixed` + `top:0`/`bottom:0` 사용 (키보드 안정성)
- 캠페인 상세 URL 은 `#detail-{id}` (새로고침 복원)

---

## 변경 이력
이력성 메타데이터(마이그레이션 번호·PR 번호·deprecated 메모·과거 변경 사항)는 [`docs/CLAUDE-ARCHIVE.md`](docs/CLAUDE-ARCHIVE.md) 참조.
