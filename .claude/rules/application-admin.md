---
description: 관리자 신청 관리·취소 되돌리기·캠페인 진행현황 — 정산·탈퇴·일일 메일과 얽힌 판정(묶음 규칙)
paths:
  - "dev/js/admin-applications.js"
  - "dev/js/admin-deliverables.js"
  - "dev/js/admin-brand-ops.js"
  - "dev/js/admin-orient.js"
  - "dev/js/admin-event.js"
  - "dev/js/admin.js"
  - "dev/admin/index.html"
  - "dev/lib/storage.js"
  - "supabase/functions/notify-influencer-daily-digest/**"
  - "supabase/migrations/*restore_cancel*"
  - "supabase/migrations/*audit_influencer*"
  - "supabase/migrations/*auto_reject*"
  - "supabase/migrations/*settle*"
---

# 관리자 신청 관리·취소 되돌리기·진행현황 (CLAUDE.md 신청·결과물 관리 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **신청 관리**: 테이블 UI(캠페인 썸네일, 타입/캠페인상태/검색 필터 + **신청 상태 탭**, 상태 정렬), 인플루언서 상세 모달, 모집인원/빈자리. `reviewed_by`/`reviewed_at` 기록, 되돌리기(pending 복귀). 빈자리 없으면 승인버튼 비활성. 결과물 반려 사유 빨간 배너. 상태는 **단일 선택 탭**(전체/심사중/승인/미승인/취소 — `status-tab-bar`. `APP_STATUS_TABS`/`_appStatusTab`/`renderAppStatusTabs`, admin-applications.js)
- **취소 되돌리기**(마이그레이션 440·441): **본인 취소** 신청을 **직전 상태**(`previous_status` — 승인/심사중)로. 진입점은 **「상태」 칸 「취소됨」 배지 옆 더보기**, **두 목록 모두**(신청 관리·진행현황 — `restoreCancelledMenuHtml`, `camp-more-menu` 패턴). ⚠️ **「처리」 칸이 아니다**. `restore_cancelled_application(신청id, 사유)` 가 **거부 10종**(`forbidden`·`memo_required`·`not_found`·`not_cancelled`·`withdrawal_related`·`previous_status_not_restorable`·`campaign_deleted`·`event_campaign`·`active_application_exists`·`slots_full`)을 사양서 순서로 판정해 **처음 걸린 하나**를 `{ok:false, error_code}` 로. 권한 `application.restore_cancelled`(441).
  - 🔴 **`reviewed_at`·`reviewed_by` 를 건드리지 않는다** — 일일 메일이 「어제 `reviewed_at` + 승인」으로 당선 절을 뽑아 **당선 메일이 다시 나간다**(결정 4 「메일 없음」 위반)
  - 🔴 **탈퇴와 얽히면 항상 거부** — 사유 코드 `withdrawal`(탈퇴를 취소해도 그대로) 또는 `pending_payout`·`scheduled`·`done` 탈퇴 신청. **버튼은 사유 코드만 보고 숨긴다** — 진행 중 탈퇴 회원 행에는 버튼이 보이고 서버가 거부한다
  - ⚠️ **정원은 리뷰어형만**, 기준은 `check_monitor_slots`(179)와 같다(감사용 제외·행 잠근 뒤 셈·`slots<=0` 통과). 상태 UPDATE 는 그 삽입 전용 트리거에 안 걸려 이 함수가 유일한 방어선
  - ⚠️ **원래 취소 기록은 비우기 전에 `application_events.memo` 로 옮긴다** — 안 옮기면 **언제·왜 취소했는지가 안 남는다**
  - ⚠️ **보류된 정산은 자동으로 풀지 않는다**(보류 사유가 여럿 — 416 원칙). 건수만 돌려주고 화면이 「정산 화면에서 확인하세요」
  - ⚠️ **되돌린 것을 다시 취소로 만드는 버튼은 없다** — 확인 창이 사유를 강제하고 후속 처리를 안내한다. 종료·노출종료 캠페인에 심사중으로 되돌리면 **자동 낙첨(176)이 안 돌아** 심사중으로 남음을 알린다(막지는 않는다)
  - 사양서 `docs/specs/2026-09-15-restore-cancelled-application.md` · 작업표 `…-breakdown.md`
- **캠페인 진행현황**(캠페인 → 신청자 보기): 요약 카드 3종(개요 / 모집·결과물 현황[진행바: 모집·제출·**인증 성공**(인증성공 인플/모집인원)] / 비용[**조건부** — `isCampaignAdminOrAbove()` + `source_application_id`]) + OT 발송 체크박스(gifting/visit 승인) + 결과물 상태 요약. 진입 ①캠페인 목록 `○/○명` ②운영현황 미니카드 「상세」(`openCampApplicants(id, null, 'brand-ops')`). `renderCampOpsSummary` 계열(admin-applications.js). ⚠️ 운영현황에서 들어오면 `allCampaigns` 가 비어 `fetchCampaigns()` 폴백 필요. 사양서 `docs/specs/2026-06-12-campaign-ops-detail.md`
