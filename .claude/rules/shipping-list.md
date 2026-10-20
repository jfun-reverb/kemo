---
description: 시딩형 배송 리스트 — 표 둘·승인 트리거·잠금 순서(개발서버만)
paths:
  - "supabase/migrations/554_shipping_base.sql"
  - "dev/js/admin-shipping*.js"
  - "dev/js/brand-shipping*.js"
---

# 시딩형 배송 리스트 (CLAUDE.md 에서 옮겨 옴 — 2026-10-20)

> 사양서·작업표는 `docs/specs/` 의 배송 리스트 문서. 현재 원본 번호 요약은 `CLAUDE.md` 「브랜드 계정·로그인·멤버 관리」 절.
- 시딩형 배송 기반 — 기준 데이터 종류 `shipping_carrier`(제약 현재 원본 **554**, 346 + 1 = 17종 · 처음 값 7) · 권한 항목 `shipping.manage`(세 등급 쓰기) · 표 `campaign_shipping_lists`(캠페인당 1줄 — `delivered_at`·`next_row_no`)·`campaign_shipments`(응모당 1줄, 응모·캠페인 함께 지움 · 주소·전화 복사 없음) · 트리거 `trg_application_shipping_sync`(승인 순간 — 전달된 시딩형·감사용 아님이면 줄 넣기/되살리기 + 제공 기록 `shipping_auto_add`) · 내부 `_shipping_campaign_lock`·`_shipping_provision_columns` — **554**(개발서버만 · 배송 리스트 조각 S1 · 운영은 L1). 🔴 트리거·전달·저장 함수는 `_shipping_campaign_lock` 을 **먼저** 잡고 그 뒤에 「전달됐나」·「지금 승인인가」를 읽는다(반대면 경쟁 중 승인 한 건이 리스트에서 빠진다) · 기준 데이터 종류를 늘릴 때 베이스는 554
