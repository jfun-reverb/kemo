---
description: 감사용 계정(is_audit) — 응모수·정원·통계·운영현황·엑셀에서 격리, 청소 함수(묶음 규칙)
paths:
  - "dev/lib/storage.js"
  - "dev/lib/shared.js"
  - "dev/js/admin-influencers.js"
  - "dev/js/admin-applications.js"
  - "dev/js/admin-settlements.js"
  - "dev/js/admin-event.js"
  - "dev/js/admin-deliverables.js"
  - "dev/js/admin-messaging.js"
  - "dev/js/admin-reports.js"
  - "dev/js/admin-excel.js"
  - "dev/js/admin-dashboard.js"
  - "dev/js/admin-brand-ops.js"
  - "supabase/migrations/*audit*"
---

# 감사용 계정 (CLAUDE.md 기준 데이터·번들·관리자 계정 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **감사용 계정 메커니즘**(179·181): 운영팀 시뮬레이션용 공용 계정(`influencers.is_audit=true`). 응모수(`get_campaign_application_counts`)·슬롯(`check_monitor_slots`)·「N명 신청」(`recompute_campaign_applied_count`)·대시보드·운영현황(`get_brand_ops_overview`/`detail`)에서 **격리**. 「감사용」 배지 `auditBadgeHtml`. 엑셀 5개 export 에 포함되면 「포함/제외」 확인(`confirmAuditExport`, 0명이면 생략). 청소 함수 2종(`purge_audit_data_all`/`purge_audit_data_for_campaign`, super_admin — **저장소 파일 경로를 돌려주고 화면이 지운다**). ⚠️ `fetchInfluencers(opts)` 기본값이 `includeAudit:true` 라 **통계·엑셀에서만 false 를 명시**해야 한다. 사양서 `docs/specs/2026-05-28-audit-influencer-account.md`
