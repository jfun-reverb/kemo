---
description: 시딩형 배송 리스트 — 표 둘·승인 트리거·잠금 순서·배송 함수(개발서버만)
paths:
  - "supabase/migrations/554_shipping_base.sql"
  - "supabase/migrations/557_shipping_functions.sql"
  - "dev/js/admin-shipping*.js"
  - "dev/js/brand-shipping*.js"
---

# 시딩형 배송 리스트 (CLAUDE.md 에서 옮겨 옴 — 2026-10-20)

> 사양서·작업표는 `docs/specs/` 의 배송 리스트 문서. 현재 원본 번호 요약은 `CLAUDE.md` 「브랜드 계정·로그인·멤버 관리」 절.
- 시딩형 배송 기반 — 기준 데이터 종류 `shipping_carrier`(제약 현재 원본 **554**, 346 + 1 = 17종 · 처음 값 7) · 권한 항목 `shipping.manage`(세 등급 쓰기) · 표 `campaign_shipping_lists`(캠페인당 1줄 — `delivered_at`·`next_row_no`)·`campaign_shipments`(응모당 1줄, 응모·캠페인 함께 지움 · 주소·전화 복사 없음) · 트리거 `trg_application_shipping_sync`(승인 순간 — 전달된 시딩형·감사용 아님이면 줄 넣기/되살리기 + 제공 기록 `shipping_auto_add`) · 내부 `_shipping_campaign_lock`·`_shipping_provision_columns` — **554**(개발서버만 · 배송 리스트 조각 S1 · 운영은 L1). 🔴 트리거·전달·저장 함수는 `_shipping_campaign_lock` 을 **먼저** 잡고 그 뒤에 「전달됐나」·「지금 승인인가」를 읽는다(반대면 경쟁 중 승인 한 건이 리스트에서 빠진다) · 기준 데이터 종류를 늘릴 때 베이스는 554
- 배송 리스트 함수 — 관리자 `admin_get_campaign_shipping`·`admin_deliver_shipping_list`(되돌리지 않음)·`admin_save_shipping_rows`(가드 `shipping.manage`, 응답 `{ok…}` · 주소·전화는 `influencer.sensitive_pii` 가 없으면 서버가 비움) · 브랜드 `get_my_brand_shipping_summary`(기록 없음)·`get_my_brand_shipping_list`(기록 `shipping_view`)·`get_my_brand_shipping_export`(기록 `shipping_excel`)·`save_my_brand_shipping_rows`(지금 승인인 줄만 · 종료면 `campaign_ended`, 응답 `{success…}`) · 서비스 전용 메일 선점 `service_claim_shipping_mail`·`service_mark_shipping_mail_sent` — **557**(개발서버만 · 조각 S2 · 운영은 L1). 🔴 판정 한 곳씩: 목록 단위 `_shipping_list_open_for_brand`(결과물 열람 정지가 생기면 여기) · 줄 단위 `_shipping_rows_payload(캠페인, 가림, 관리자칸)`(상태·기한·「새로 추가」·우편번호 떼기·「취소됨」 가림·탈퇴 표시 — 회원 번호·SNS 는 관리자칸일 때만) · 저장 검사 `_shipping_check_row`(빈 송장 = 지우기 · 4~40자) · 🔴 `_brand_mailable_accounts` 는 `notify-orient-sheet` `resolveBrandAccountRecipients` 의 **사본**(한쪽을 바꾸면 함께) · 트리거 함수 `_application_shipping_sync` 현재 원본 **557**(554 베이스, 이름 칸 name_kanji → name → user_name 만 다름) · ⚠️ 알려진 작은 틈: 메일 실패 보고가 15분 뒤 다시 잡힌 남의 선점을 풀 수 있다(S7 에서 다룬다)
