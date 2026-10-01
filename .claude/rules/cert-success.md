---
description: 인증 성공 판정 — 같은 판정이 서버·화면·엑셀·메일 여러 곳에 있다(묶음 규칙)
paths:
  - "dev/js/admin-deliverables.js"
  - "dev/js/admin-excel.js"
  - "dev/js/report-rows.js"
  - "dev/js/admin-brand-ops.js"
  - "dev/js/admin-applications.js"
  - "dev/report.html"
  - "dev/lib/storage.js"
  - "supabase/functions/notify-deliverable-decision/**"
  - "supabase/functions/notify-influencer-daily-digest/**"
  - "supabase/functions/notify-admin-daily-digest/**"
  - "supabase/migrations/*settle*"
  - "supabase/migrations/*cert*"
  - "supabase/migrations/*report_share*"
---

# 인증 성공 판정 (CLAUDE.md 정산 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- `backfill_settlements()` RPC (마이그레이션 218, SECURITY DEFINER `search_path=''`) — 정산 화면 열 때 호출(트리거 아님). 판정은 `computeCertStatus`(admin-deliverables.js)의 SQL 재현. `is_audit=false` AND 정산행 미존재 → UPSERT(멱등). ⚠️ **`reward>0` 조건은 262에서 없어졌다**(리뷰어형은 `reward` 0이라 후보가 0건이 된다). 현재 후보 조건은 264 를 거쳐 **300**. PayPal 미등록이면 `settlement_paypal_required` 알림 멱등 발행. 가드 `has_permission('settlement.view','read')`. **컷오프(231): 인증 성공일(마지막 결과물 `reviewed_at` 최댓값) ≥ `settlement_settings.cutoff_at` 인 것만 자동 생성**. `cutoff_at` NULL이면 0건, `reviewed_at` 누락도 제외. 반환 `(created_count, paypal_missing_count)`
- **정산 후보에서 임시저장 제외(마이그레이션 318)**: `_settlement_cert_candidates()` 의 `receipt_latest`·`post_latest`·`review_channel_latest` 세 CTE 가 상태 필터 없이 최신 1건을 골라, `draft` 가 최신이면 **화면엔 승인인데 후보에서 조용히 빠졌다**. ⚠️ 「임시저장이 최신」과 「승인이 가려졌다」는 다른 조건이다. 화면은 원래 제외(`fetchDeliverables()` 의 `.neq('status','draft')`). 세 CTE 에 `AND d.status <> 'draft'` 만 추가 — 나머지는 300과 동일.
  ⚠️ **이 함수의 현재 원본은 455다.** 232→262→264→300→318→331→455(455 = 「또는」 채널 매칭). 232 를 베이스로 재작성해 알림 잠금이 소실될 뻔한 전례가 있다([[feedback_function_redefine_latest_base]]). **번호가 가장 큰 정의를 베이스로.**
  ⚠️ 후보가 늘면 **「과거 미등록」 화면에 즉시 나타난다**(컷오프 무관). 되돌릴 수 없는 「송금완료 기록」 버튼이 있어 적용 후 눈으로 확인할 것. ⚠️ 그 화면에는 **과거분 수백 건**이 함께 있다 — 섞지 말 것.
- **인증 성공의 채널 요구는 캠페인이 정한다(마이그레이션 331 → 455)** — 🔴 **지금 규칙(455)**: 채널 1개 = 그 채널 / 「그리고」(`channel_match='and'`) = 요구 채널 **전부** 승인 / 「또는」(`'or'`) = **하나라도** 승인(리뷰어형은 영수증 승인 필수). 331 이 시딩·방문형의 「승인 게시물 1건」(`post_latest`)을 리뷰어형(`channel_cert`) 방식의 `post_channel_latest`·`post_channel_cert` 로 교체했다(`post_latest` 제거). ⚠️ **채널이 빈 시딩·방문형 캠페인은 인증 성공이 되지 않는다**. 적용 전 331 파일의 사전 확인 조회로 **뒤집히는 응모가 0건인지** 볼 것.
  ⚠️ **같은 판정이 여러 곳에 있다** — 서버(`_settlement_cert_candidates`, 현재 원본 455) · 검수 화면(`computeCertStatus`·`_finalizePostReprs`) · 엑셀(`_excelCertStatusKo`) · 검수 결과 메일(`notify-deliverable-decision`) · 인플루언서 일일 다이제스트(`notify-influencer-daily-digest`) · **`_campaign_cert_success_counts`(456 — 일정 뷰·관리자 일일 메일 다섯째 절)** · 브랜드 공유(`get_report_share_data` 491 이 `channel_match` 를 주고 `report-rows.js` 가 판정). **판정을 고치면 함께 봐야 한다.** 메일 두 곳이 「게시물 1건이면 완료」 전제라, 안 고치면 **서버는 지급 대상이 아닌데 메일은 지급을 예고**하고 **남은 채널 마감 안내가 안 나간다**.
  ⚠️ 소급 피해 없음 — 앞으로 만들 캠페인부터 적용.
