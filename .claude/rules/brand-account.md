---
description: 브랜드 계정·로그인 — 표 셋·계정 함수·링크 번호·인플루언서 앱 차단·기존 함수 보호(개발서버만)
paths:
  - "dev/brand/**"
  - "dev/js/brand-*.js"
  - "dev/js/admin-brand.js"
  - "supabase/functions/notify-brand-account-setup/**"
  - "supabase/functions/brand-password-reset-request/**"
  - "supabase/functions/notify-brand-invite/**"
  - "supabase/functions/brand-invite-accept/**"
  - "supabase/migrations/526_brand_accounts_base.sql"
  - "supabase/migrations/527_brand_account_functions.sql"
  - "supabase/migrations/528_brand_account_guards.sql"
  - "dev/js/admin-camp-ext.js"
  - "dev/js/admin-brand-publish.js"
  - "dev/js/report-rows.js"
  - "supabase/functions/brand-campaign-results/**"
  - "supabase/migrations/543_brand_campaign_functions.sql"
  - "supabase/migrations/544_brand_publish_settings.sql"
  - "supabase/migrations/546_campaign_ext_sources.sql"
  - "supabase/migrations/547_brand_campaign_results.sql"
  - "supabase/migrations/548_deliverable_media_bucket.sql"
  - "supabase/migrations/550_brand_campaign_summary_split.sql"
  - "supabase/migrations/551_brand_receipt_sign_guard.sql"
  - "supabase/migrations/552_personal_data_logs.sql"
  - "supabase/migrations/553_personal_data_logs_retention.sql"
  - "supabase/migrations/559_brand_publish_provision_log.sql"
---

# 브랜드 계정·로그인 (CLAUDE.md 에서 옮겨 옴 — 2026-10-15)

#### 브랜드 계정·로그인 (마이그레이션 526~ — 🔴 **개발서버만**, 운영 반영 보류)
> 사양서 `docs/specs/2026-07-15-brand-portal.md` §16-6 · 작업표 `docs/specs/2026-10-14-brand-login-breakdown.md`(조각 11개 · 결정 기록) · 인수인계 `…-brand-login-handoff.md`
> 🔴 **운영 관문**: 브랜드용 이용약관·개인정보처리방침 + `/약관확인` 전에는 운영 데이터베이스에 넣지 않는다. 화면 코드는 `IS_STAGING` 일 때만 계정 생성·판정을 부른다(작업표 P-1) — 출시 때 그 조건을 걷는다
- 표 셋(526): `brand_accounts`(`auth_id` = `auth.users` 1:1, 이메일 `lower(btrim())` 강제·유일) · `brand_account_links`(브랜드 참조 `ON DELETE RESTRICT`, 브랜드당 활성 대표 1명) · `brand_password_reset_requests`(243 복제, 해시만). 셋 다 쓰기 정책 없음 — 읽기는 본인 또는 `is_admin()`(요청 기록은 최고 관리자)
- 🔴 **브랜드 계정 표시는 앱 메타데이터 `raw_app_meta_data.account_kind='brand'`** — 사용자 메타데이터는 공개 키 가입으로 누구나 채우고 383 이 지운다. 계정은 `invite_admin`(417) 방식 직접 삽입 + `email_confirmed_at=now()` 로 만든다(🔴 `auth.admin.createUser` 는 497 가입 관문에 걸린다)
- 🔴 **인플루언서 표 삽입 거부 트리거 `trg_block_influencer_row_for_brand`**(526, DEFINER) — `NEW.id` 가 브랜드 계정이면 `brand_account_not_influencer`. 판정은 `auth.uid()` 가 아니라 `NEW.id`(137 삽입 정책이 로그인만 보면 통과). 인플루언서 앱 `handleLogin` 의 프로필 자동 생성이 이 거부에 걸린다 — 인플루언서 앱 차단(작업표 조각 9)은 **판정 실패(`null`)를 「차단」으로 처리하지 않는다**(함수 없는 서버에서 전원 로그인 불가)
- `get_my_account_kind()`(526) → `'brand'|'other'`, `authenticated` 만(로그아웃 호출은 권한 오류)
- 함수(527, 전부 DEFINER): 관리자 `admin_upsert_brand_owner_account(brand, 이전 대표 줄 id, 이전 이메일)`(캠페인 관리자 이상 — 판정 표는 527 머리말 B. 🔴 화면은 상세를 연 시점의 대표 줄 id·이메일을 **반드시** 넘긴다 — 안 넘기면 이메일 변경으로 본다) · `admin_get_brand_account_status`(관리자 아니면 42501 — 🔴 실패를 「계정 없음」으로 그리지 않는다) · 비로그인 `get_brand_link_state(링크, 'setup'|'reset')` · 임시 세션 `complete_brand_account_setup`(🔴 `updateUser` 먼저 — 비밀번호가 비면 `password_not_set`)·`complete_brand_password_reset` · 로그인 판정 `get_my_brand_login_state`(보관 브랜드 제외) · 서비스 키 전용 `service_issue_brand_account_link`·`service_mark_brand_setup_mail_sent`·`check_brand_password_reset_rate_limit` · 정기 정리 `brand-password-reset-requests-retention-daily`(UTC 21:00, 30일)
- 🔴 **링크 번호 칸 `brand_accounts.setup_link_id` 하나를 계정 만들기·재설정 링크가 같이 쓴다**(피그마 「링크는 보낸 때의 계정 상태에 묶인다」) — 새로 보내면 옛 링크 무효, 설정·재설정을 마치면 비운다
- ⚠️ 알려진 틈(기록만, 다음 작업): 인플루언서 「비밀번호 찾기」·가입 인증번호(499)가 브랜드 이메일에도 동작
- 화면(개발서버만 — 판정 `_brandAccountEnabled()` 한 곳): 인플루언서 앱 차단(`auth.js` `handleLogin`·`app.js` 부팅·로그인 이벤트 — 🔴 판정 실패 `null` 은 차단 아님) · 관리자 브랜드 상세 「계정」 줄(`admin-brand.js` — 🔴 「대표 이메일이 새로·바뀔 때만」은 **화면이** 지킨다: 527 은 계정 없는 브랜드면 이전 값을 안 본다) · 브랜드 화면 `/brand/`
- 기존 함수 보호(528): 계정 연결(활성)이 있는 브랜드는 삭제·병합(원본) 거부, 해제 이력만 있어도 삭제 거부(이력 보존 — 병합으로 안내), 관리자 초대는 브랜드 계정 이메일 거부. ⚠️ **연결 해제 기능이 아직 없다** — 운영 전 어느 조각에서 만들지 정할 것. ⚠️ 병합·초대 거부 문구는 화면 매핑 전이라 영문 코드·일반 오류로 보인다(조각 10)

#### 캠페인 결과물·브랜드 공개·외부 결과 파일·영수증 비공개 통·개인정보 기록 (CLAUDE.md 에서 옮겨 옴 — 2026-10-20, 🔴 개발서버만)
> 현재 원본 번호 요약과 영역 밖 경고(사진 값 두 형식·관리자 편집 덮어쓰기·자동 전환 사본)는 `CLAUDE.md` 「브랜드 계정·로그인·멤버 관리」 절에 남아 있다.
- 외부 결과 파일 화면(조각 12, `admin-camp-ext.js`): 진행현황 결과물 탭 「외부 결과 파일」 카드(붙이기·업데이트·떼기 — 파일 읽기는 리포트와 같은 `REPORT_PARSERS.pointail`) + 제출한 외부 줄 표 + 모집 현황 「외부 N명」 + 결과물 엑셀 「외부 참가자」 시트. 외부 줄은 `_reportExtToRow(…, {rules:'campaign'})`·`reportExtRowSubmitted` 로만 · 🔴 546 이 없는 서버(`PGRST202`)는 카드를 조용히 숨긴다 — 운영은 546 과 같은 「사전」 단계
- 외부 결과 파일 캠페인 첨부 — `campaign_report_sources.campaign_id`(리포트 또는 캠페인 정확히 하나) + `attach_campaign_ext_source`·`detach_campaign_ext_source`·`get_campaign_ext_sources`·내부 `_campaign_ext_participant_count` — **546**(개발서버만 · 운영은 「사전」 단계). 410 의 `replace_report_source_rows`·`remove_report_source` 현재 원본도 **546**(리포트 첨부만 받는다). 🔴 공유 판정(545)·리포트 화면(410)은 `report_id` 로만 찾는다 — 캠페인 첨부는 공유 링크로 새지 않는다. ⚠️ 캠페인 **보관 삭제 때 첨부·줄이 30일 남는다**(신청·결과물은 즉시 파기 — 후속 과제)
- 캠페인 「브랜드 공개」 설정 창(조각 9, `admin-brand-publish.js`): 진행현황 결과물 카드 「브랜드 공개 설정」 단추 + 머리 줄 「브랜드 공개 중 / 꺼짐」(누르면 같은 창). 열 = `reportColumnsFor`(그 캠페인 결과물 줄 + 요구 채널) · 처음 켤 때 체크 = `reportDefaultCheckedKeys` · 저장 = `reportPublishColsToSave`(S19) · 「계정 ID」 고를 수 없음 · 🔴 `report.share` 숨김 등급(매니저)은 단추 숨김·상태 표시만 · 상태 조회 실패면 표시 숨김(「꺼짐」으로 그리지 않음) · 「비공개」 낱말 금지 · 목록 배지·필터(조각 10): `brandPublishBadgeHtml` 한 곳(캠페인 관리 목록 캠페인명 아래 + 「브랜드 공개」 필터 · 관리자 브랜드 상세 캠페인 탭) · 상태는 `fetchBrandPublishStates` 한 번(실패면 배지·필터 안 그림) · 브랜드 변경 확인 창에 「공개 중이면 새 브랜드가 바로 봅니다」 · 🔴 세 조회·저장(`fetchCampaignBrandPublish`·`fetchBrandPublishStates`·`saveCampaignBrandPublish`)과 단추는 `_brandAccountEnabled()`(개발서버)일 때만 — 운영엔 544 가 없다. 출시 때 그 판정을 걷는다 · 기본 열(조각 11): 기준 데이터 「브랜드 공개 기본 열」 탭(전체) + 관리자 브랜드 상세 「브랜드 공개 기본 열」 칸(「전체 기본값 따르기 / 이 브랜드만 따로 정하기」) — 고르기 칸 `brandPublishDefaultPickerHtml` 한 곳 · 🔴 브랜드 칸은 자기 「기본 열 저장」 단추로만(`saveBrandDetail` 에 안 넣는다) · `report.share` 쓰기가 아니면 읽기 전용(숨김 등급도 — 의도된 예외)
- 캠페인 「브랜드 공개」 설정·기본 열 — 표 `campaign_brand_publish`·`brand_publish_default_global`·`brand_publish_default_by_brand` + 관리자 함수 일곱(`admin_get/set_campaign_brand_publish`·`admin_get_brand_publish_states`·`admin_get_brand_publish_defaults`·`admin_get_publish_default_for_campaigns`·`admin_set_brand_publish_default_global/brand`) — **544**(개발서버만 · 작업표 `docs/specs/2026-10-19-brand-campaign-results-breakdown.md` 조각 1 · 운영은 「사전」 단계). 🔴 캠페인 표에 칸을 두지 않았다(`version` 가짜 충돌·변경 이력 세 곳) · 쓰기 `has_permission('report.share','write')`, 읽기 `is_admin()` · 표 셋은 정책 없음(함수로만) · 🔄 쓰기 함수 `admin_set_campaign_brand_publish` 현재 원본 **559**(544 베이스 — 저장이 성공한 같은 거래에서 제공 기록: 꺼짐→켜짐 `publish_on` · 켜짐→꺼짐 `publish_off` · 켜진 채 열이 바뀌면 `publish_columns`, 칸 = `[{enabled_before, enabled_after, before, after}]`, 사람 목록 없음 · 꺼진 채 열 저장·같은 값·충돌은 기록 없음 · 개발서버만)
- 영수증 비공개 저장소(통) `deliverable-media` + 정책 넷 + 내부 `_deliverable_media_owner_ok` — **548**(개발서버만 · 운영은 「사전」 단계 · 아직 아무도 안 올린다 — 올리는 쪽 전환은 조각 7). 🔴 회원 조회는 「자기 영수증 줄이 가리키는 경로」 **그리고** 「올린 사람이 그 회원 또는 그 줄을 대리 등록한 관리자」 — `receipt_url` 은 회원이 직접 쓰는 칸이라 경로만 보면 남의 파일이 열린다 · 브랜드 계정은 넣기·조회 모두 거부, 서명 주소로만 · 서버 함수 `brand-campaign-results`(브라우저 직접 호출 — CORS 있음·공개 키 거부 없음, 판정은 브랜드 토큰으로 547 을 부름, 응답 안 `receipts/` 경로만 서비스 키로 서명 · 🔄 조각 5b(S26): `view` 는 서명하지 않고 저장값 그대로 · 영수증은 「열기」 때 `purpose:'receipt'` + `deliverable_id` 로 **하나씩** 1시간 서명(판정 응답 안에서 번호로만 찾는다 — 화면이 보낸 경로는 받지 않는다, 옛 공개 주소는 그대로 `expires_in:null`) · `excel` 은 7일 일괄 서명 그대로 · 🔄 제공 기록(배송 리스트 작업표 R1): `view` 는 돌려주기 전 `results_view`(30분 합치기)·`excel` 은 서명 전 `results_excel` 을 `service_record_brand_provision`(「누가」 = 토큰의 계정 · 칸 = 응답 columns · 사람 = 응답 users 의 회원 번호 + 가린 이름) — 실패면 `{success:false, reason:'record_failed'}`(화면은 기존 실패 문구) · `receipt`·공개 꺼짐은 기록 없음 · 🔴 서명 전 「올린 사람 대조」 `service_brand_receipt_signable(uuid[])`(551 — 548 조회 정책과 같은 판정, 서비스 키 전용) — `receipt_url` 은 회원이 쓰는 칸이라 남의 파일 경로를 적으면 경로 검사만으로는 남의 영수증이 서명된다. 🔴 서명은 대조 함수가 돌려준 경로·썸네일 경로로만(판정 응답 값을 다듬어 서명하면 대조한 파일과 어긋난다), 대조 실패도 「서명 안 함」, 개발 프로젝트에만 배포)
- 개인정보 기록 표 둘 `brand_provision_logs`(브랜드 제공 3년)·`personal_data_access_logs`(관리자 접속 1년) + 쓰기 `_record_brand_provision`(내부 — 열람 30분 합치기 한 곳)·`service_record_brand_provision`(서비스 키 전용, 브랜드 연결 계정 검사 = 530 `my_brand_role` 사본)·`record_admin_data_access` + 최고 관리자 읽기 셋 — **552**(개발서버만 · 배송 리스트 작업표 조각 P1 · 운영은 L1). 🔴 외래 키 없음(보관 삭제·브랜드 삭제·병합과 무관하게 남는다) · 탈퇴 파기(520)는 이 표를 안 지운다(의도) · 부르는 자리: 554 트리거·557 배송 함수·559 공개 설정·서버 함수 `brand-campaign-results` · 보관 기간 정리 `purge_expired_personal_data_logs()`(postgres 전용 → `{provision_deleted, access_deleted}`) + 예약 `personal-data-logs-retention-daily` 매일 UTC 18:00(도쿄 03:00) — **553**(개발서버 적용·예약 등록 · 운영은 L1 에서 552 바로 뒤, 메일 없는 정리라 운영에도 예약을 건다)
- 🔴 `_brand_campaign_summary` 현재 원본 **550**(547 베이스 — 「결과물 게시」 `result_posted` = 세 숫자의 **검수 완료**(옛 547 은 제출) + 나눈 칸 `applied_reverb`·`approved_reverb`·`ext_participants`, 합계 칸은 그대로 · 개발서버만 · 운영은 출시 날 ①)
- 브랜드 결과물 화면(조각 14, `brand-campaign-results.js` — 브랜드 빌드에 `report-rows.js` 를 함께 싣는다): 줄·열은 `buildReportRows`·`_reportExtToRow(rules:'campaign')`·`reportColumnsFor`·`reportShareColDraw` 그대로(사본 없음) · 🔴 `view` 응답의 `receipt_url` 은 저장값이라 `<img>`·링크에 바로 넣지 않는다 — 영수증 「열기」는 `purpose:'receipt'` 로 그 한 장만 · 게시물 링크는 `reportIsLinkable` · 「결과물 게시」 칸은 `brandResultPostedText`(목록·카드·상세 한 곳) · 엑셀(조각 15 `brandCampaignResultsExcel`)은 누를 때 `purpose:'excel'` 로 새로 받고 줄·열은 화면과 같은 `_brBuildRowsCols` — 🔴 화면보다 많이 싣지 않는다
- 브랜드 결과물 조회 `get_my_brand_campaign_results` + 내부 `_brand_campaign_result_counts`(세 숫자 — 최신 건만)·`_brand_campaign_summary`(목록·상세의 공개 여부·결과물 게시·외부 참가자 합산 — 현재 원본 550)·`_results_ext_rows` 4인자(증빙 있는 줄만) — **547**(개발서버만 · 운영은 출시 날 ①). 🔴 목록·상세 `get_my_brand_campaigns`·`get_my_brand_campaign` 의 현재 원본도 **547**(543 베이스 — 요약 함수 한 줄만 다르다) · 공개 꺼짐이면 세 숫자도 안 싣는다 · 쓰기 없음(열람 기록 없음)

#### 브랜드 메일 함수 (CLAUDE.md 에서 옮겨 옴 — 2026-10-20, 🔴 개발서버만)
- **브랜드 계정 설정 메일**(`notify-brand-account-setup`, 관리자 화면이 브라우저에서 직접 부름 — CORS 있음·공개 키 거부 없음, 판정은 호출자 토큰으로 `has_permission('brand.account_manage','write')`(533 관리자 함수와 같은 판정), `mail_kind:'link'` 면 양식을 서버가 고름(비밀번호 정한 계정 = 연결 안내 `brand-link-notice`), 받는 사람은 서버가 `brand_id` 로 다시 읽음 · 🔴 **개발서버 두 겹 잠금** `BRAND_SETUP_DEV_ECHO=1` **그리고** 개발 프로젝트 주소일 때만 메일 대신 응답에 `dev_link` — 하나라도 지우면 운영에서 링크가 응답에 실린다. 🔴 **운영에 `BRAND_SETUP_DEV_ECHO` 를 넣지 않는다** · 비밀값 `PUBLIC_BRAND_URL` 기본값 없음 · 링크 번호를 발송 **전에** 교체하므로 발송 실패면 옛 링크도 무효 — 「다시 보내기」로 복구) — 개발서버만, 운영 보류
- **브랜드 비밀번호 찾기**(`brand-password-reset-request`, 비로그인 공개 — 늘 `200 {ok:true}`·최소 2.5초) · 🔴 **실제 처리는 `EdgeRuntime.waitUntil` 로 응답 뒤에** — 기다렸다 응답하면 걸린 시간으로 브랜드 계정 여부가 드러난다 · 🔴 개발서버 잠금이어도 **응답·로그에 링크를 싣지 않는다**(공개 함수라 누구나 남의 재설정 링크를 받게 된다) · 설정 메일 「다시 보냄」 문구 사본이 `notify-brand-account-setup` 과 두 벌 · 재발송 기록은 `p_sent_by='self'` — 개발서버만, 운영 보류
- **브랜드 초대 메일**(`notify-brand-invite`, 대표 브랜드 계정이 브라우저에서 부름 — CORS·공개 키 거부 없음 · 갈래(새 이메일·브랜드 계정·만들 수 없는 이메일)를 응답에 싣지 않는다 · 위 두 겹 잠금 스위치를 공유) · **새 이메일 초대 수락**(`brand-invite-accept`, 비로그인 공개 — CORS·공개 키 거부 없음·새 비밀값 없음 · 비밀번호 원문이 지나가므로 로그에 본문을 남기지 않는다) — 개발서버만, 운영 보류
