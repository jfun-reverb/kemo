---
description: 응모·취소 — 신청 사전 체크·주의사항 동의·정원·모집 마감 후 응모 차단(서버 트리거)·본인 취소(묶음 규칙)
paths:
  - "dev/js/application.js"
  - "dev/js/mypage.js"
  - "dev/js/campaign.js"
  - "dev/lib/storage.js"
  - "dev/lib/shared.js"
  - "dev/js/ui.js"
  - "dev/js/error-report.js"
  - "supabase/migrations/*deadline*"
  - "supabase/migrations/*cancel_application*"
  - "supabase/migrations/*caution*"
  - "supabase/migrations/*client_error*"
  - "supabase/migrations/*notifications*"
  - "supabase/migrations/326_*"
---

# 응모·취소 (CLAUDE.md 인플루언서 기능 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **캠페인 신청**: 이메일 인증 필수, 필수정보 사전체크(채널별 SNS / zip+prefecture+city+phone / PayPal) → 동기메시지 + 배송지 + PR태그 동의, 중복 방지, 최소 팔로워 미달 차단
- **주의사항 동의**: `caution_items` 가 있으면 ①상세 "주의 사항" 섹션 + ②신청 모달 상단 빨간 박스. 하단 "全ての注意事項を確認しました" 체크 필수. 동의 시 `applications.caution_agreed_at` + `caution_snapshot`(jsonb) — 신청 시점 스냅샷이라 번들 수정 무영향. 응모이력에 동의 시각 배지
- **응모 차단**: 리뷰어(monitor)는 `applied_count >= slots` 면 신규 응모 차단(기프팅·방문형은 초과 허용)
- **모집 마감 후 응모 차단**(마이그레이션 272 → **현행 원본은 326**): `applications` BEFORE INSERT 트리거 `trg_application_deadline_guard`. **삭제된 캠페인은 관리자도 거부**, 그 외 **active 가 아니면 거부**(화면 응모 버튼과 같은 기준). 마감 판정 `(now() AT TIME ZONE 'Asia/Tokyo')::date <= campaigns.deadline`, NULL 은 무기한. 거부 코드 `recruit_deadline_passed`·`campaign_deleted`·`recruit_not_open`(`friendlyErrorJa` 등록). 통과 `auth.uid() IS NULL`(배치·서비스 키) · `is_admin()`(대비). **감사용 계정도 차단**. ⚠️ 이름 `a…` 로 정원 가드(`trg_monitor_*`)보다 **먼저** 실행. ⚠️ **SQL Editor 는 서비스 키라 재현 못 한다**(검증법은 파일 하단 주석). ⚠️ **삽입 전용** — 행사 대기자 승격(UPDATE)엔 안 걸린다. 자동 마감이 브라우저 조회 시 돌아 **서버 트리거가 유일한 최종 방어선**이다.
- **본인 응모 취소**: `cancel_application(uuid, reason_code, reason_note, acknowledged)` RPC — 본인 검증·결과물 승인 차단·구매기간 이후 사유·동의 강제. 🔴 **인플루언서 행은 `id` 로 찾는다**(`auth_id` 칸 없음) — 틀리면 흔적 없이 죽는다(`storage.js` 가 오류를 삼키고 `mypage.js` 가 `friendlyErrorJa()` 없이 덮었다). **오류를 일반 문구로 덮는 자리는 같은 실패를 또 숨긴다** → 308 오류 기록 68곳(`docs/specs/2026-08-07-app-error-visibility.md`). 🔴 **취소 알림은 서버가 만든다**(309) — `notifications` 는 **쓰기 정책이 없어**(037 「INSERT 는 SECURITY DEFINER 트리거에서만」) **브라우저에서 알림을 만드는 코드를 되살리지 말 것**
