---
description: 관리자 결과물 검수 — 인증 상태·인증 성공일·구매금액 열, 검수대기 배지, 영수증 수정(정산 재계산), 엑셀(묶음 규칙)
paths:
  - "dev/js/admin-deliverables.js"
  - "dev/js/admin-applications.js"
  - "dev/js/admin-excel.js"
  - "dev/js/admin-settlements.js"
  - "dev/js/report-rows.js"
  - "dev/js/admin-core.js"
  - "dev/admin/index.html"
  - "dev/lib/storage.js"
  - "dev/lib/shared.js"
  - "dev/lib/ocr-receipt.js"
  - "supabase/migrations/*deliverable*"
  - "supabase/migrations/*pending_review*"
  - "supabase/migrations/*receipt*"
  - "supabase/migrations/*settle*"
---

# 관리자 결과물 검수 (CLAUDE.md 신청·결과물 관리 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **결과물 관리** (`/admin#deliverables`): 영수증/게시물 URL 통합 검수. 필터(캠페인·타입·채널·영수증상태·결과물상태·인플루언서 검색·최근 제출일·**인증 성공일 기간**) + **인증 상태 탭**(전체/미제출/인증샷 제출중/인증성공/검수 불필요 — `status-tab-bar`, `DELIV_CERT_STATUS_TABS`/`_delivCertTab`/`renderDelivCertStatusTabs`, admin-deliverables.js. `computeCertStatus` 가 상호 배타라 탭. 배지 클릭 `_delivPendingOnly` 도 탭 건수에 반영) + 오래된 순. 상세 모달 이력 타임라인 + 승인/반려/되돌리기, 반려 사유 템플릿(6종) + 자유입력. 낙관적 락(`version`) — 후순위는 "이미 처리됨" 토스트
- **인증 상태 컬럼**(목록 + 엑셀, 신청 단위 4종, 인플루언서 다음·영수증 앞): `검수 불필요`(승인 후 반려·취소) · `인증성공`(리뷰어=영수증+채널별 인증샷 모두 승인 / 시딩·방문=게시물 승인) · `인증샷 제출중` · `미제출`. `computeCertStatus`/`certStatusBadge`(admin-deliverables.js), 엑셀 `_excelCertStatus*`(admin-excel.js). 단일 캠페인 엑셀도 전체 상태(`fetchDeliverables` status 필터 없음 + `fetchApplications({status:'approved'})` 조인으로 결과물 0건 승인 신청도 빈 행)
- **인증 성공일 컬럼**(인증 상태 오른쪽 · 정렬): **인증 성공 조건을 처음 만족한 시각**(`settlements.cert_at` 과 같은 정의) — 「그리고」·채널 1개는 승인 시각 중 가장 늦은 것, 🔴 **「또는」은 가장 먼저 승인된 채널 시각**(리뷰어형은 영수증 시각과 그중 늦은 쪽). 화면 `certSuccessAt(g)` / 서버 원본 `_settlement_cert_candidates()`(현재 원본 **455**). ⚠️ 승인됐지만 시각이 빈 채널은 서버처럼 건너뛴다. ⚠️ 형식·채널 갈래(가구매=영수증 / 리뷰어형=영수증+채널별 인증샷 / 시딩·방문형=채널별 게시물, 갈래 판정은 `_certChannelKind`)와 **채널 목록 출처**가 서버와 같아야 한다. ⚠️ **대상은 다르다** — 무보수 시딩·방문형(264 제외)은 날짜가 떠도 정산 목록엔 없다. 🔴 **승인 시각이 비면 빈 칸** — **등록일 등으로 채우지 않는다**. ⚠️ **빈 값은 방향 무관 뒤로**. ⚠️ **진행현황 표와 `renderDelivAppRow` 공유** — 열을 늘리면 머리글 2곳 + `colspan` **3곳**(`admin/index.html`·`admin-deliverables.js` 2곳·`admin-applications.js`). 엑셀엔 **없다**(셀 좌표 고정).
- **구매금액 열**(영수증 열 오른쪽): 최신 영수증 `purchase_amount`, `receiptAmountCell(g)`, `¥`+자릿수, **두 표 모두**(`renderDelivAppRow`). ⚠️ **「해당 없음」(시딩·방문형)과 「—」(리뷰어형 미기재)를 구분**. 🔴 **`Number(null)` 이 0 이라 「¥0」이 되기 쉽다** — 빈 값 검사 먼저. ⚠️ `product_price` 초과면 **「상한 ¥N」** 병기(정산은 상한으로 자른다). ⚠️ `fetchDeliverables`·`fetchDeliverablesByCampaign` 에 **`purchase_amount`·`product_price` 둘 다** 필요 — 빠지면 그 화면만 조용히 빈칸. ⚠️ 엑셀엔 원래 있다.
- **인증 성공일 기간 필터**: **두 화면**(결과물 관리 · 진행현황 결과물 탭). `certSuccessAt(g)` → `delivLocalDate()`(최근 제출일 필터와 같은 규칙). ⚠️ **인증 성공 전 건은 빠진다** — 「미제출」·「인증샷 제출중」 탭이 0(빈 상태 문구가 이유를 말한다). ⚠️ 결과물 관리는 판정이 **두 곳**(`passesFilters` · 표시용 `.filter()`) — **한쪽만 고치면 탭 숫자와 목록이 갈린다**. ⚠️ **진행현황엔 「보기 초기화」가 없다** — `btnCampDelivCertClear` 가 유일한 해제 수단(없으면 「0건」에 갇힌다). ⚠️ flatpickr `clear()` 는 변경 이벤트를 일으킨다 — 초기화는 **`clear(false)`**. ⚠️ **캠페인 결과물 엑셀 둘은 이 필터를 안 따라간다** — 필터를 따라가는 것은 결과물 관리 툴바 **「현재 목록 다운로드」**(`exportDeliverablesViewExcel`)뿐. 그 함수는 화면이 마지막에 그린 배열 `_delivVisibleGroups`(그리는 중엔 `null`)를 그대로 내보낸다 — 🔴 `passesFilters` 로 다시 거르지 말 것(「대리 등록만」이 거기 없다). 감사용은 묻지 않고 「감사용」 열로 표시, 회차 열 없음
- **반려·취소된 신청의 결과물 자동 제외**(DB 변경 없음): "검수 불필요". **결과물 status 는 그대로, 신청 status 참조**(임베드 `applications:application_id (status)`) → 재승인 시 복원. `isCertExcluded(g)` → `computeCertStatus` 앞단 `'excluded'`. 적용: 검수 목록·인증 상태 열·상태/캠페인/채널 카운트·진행바·엑셀·**사이드바 배지**. **검수 모달**은 검수 액션 전부 차단 + 안내. gifting/visit 은 「영수증(해당 없음)」 패널 없음 + 폭 620px. 사양서 `docs/specs/2026-07-21-rejected-application-deliverable-and-settlement.md`
- **사이드바 검수대기 배지 정합**(마이그레이션 248·249·250): **신청 단위** `count_pending_review_applications()`(SECURITY DEFINER·`search_path=''`·`is_admin()`) — 최신 결과물 pending + 반려·취소 아닌 신청 수(행 단위면 옛 pending 까지 **부풀어난다**). 최신 기준(`buildDeliverableGroups` 정합): **`review_image` 만 채널별** · **`post`·`receipt` 는 신청당 1건** · **채널 미지정 `review_image`(legacy) 제외**. `fetchPendingDeliverableCount` 호출, 화면 `groupHasPendingReview(g)`. **배지 클릭 → 「검수대기만」**(`_delivPendingOnly` + `openDelivPendingReview`). ⚠️ RPC는 배지 전용 재현(단일 소스 아님) — `buildDeliverableGroups` 변경 시 함께 검토. gifting/visit 다채널 근소 차이 감수.
- **영수증 필수 필드**(리뷰어 monitor): 인플 제출은 `order_number` + `purchase_date` + `purchase_amount` 필수, **관리자 인플레이스 수정은 최소 1개**(178). `renderReceiptInfoBlock(d)` + campaign_admin 이상 + 「변경 이력 보기」. 수정·**대리등록** 모달의 「영수증에서 읽기」(`runReceiptOcrAdmin`/`runProxyReceiptOcr` — **빈 칸만 채운다**). `update_receipt_admin`(SECURITY DEFINER, campaign_admin, FOR UPDATE — 빈 항목 NULL, **3종 모두 빈값이면 거부**), `receipt_edit_history` 자동 INSERT. **정산 정합 가드(302)**: **송금완료·보류·취소는 수정 차단**, **정산대기는 재계산**(`campaigns.product_price` 를 **다시 읽고** 감사 칸 2개도). 「금액 미확정」이면 **보류로 자동 전환**(`amount_jpy CHECK(>0)`). ⚠️ 그 사유 문구에 **「자동 보류」 연속 표현 금지** — 화면이 그 문자열로 「신청 반려로 자동 보류」 배지를 그린다. `settlement_events.action` 에 **`recalc`**. 검수 화면 「이 금액이 정산 지급액이 됩니다(상한 ¥N 초과 시 상한까지만)」(`receiptPayoutHint`, **리뷰어형 한정**) — ⚠️ 조회에 `campaigns.product_price` 필요 — **검수 모달은 `storage.js` 를 안 거치고 자체 조회를 쓴다**
- **엑셀 내보내기**: 단일 캠페인은 더보기 `결과물 엑셀`/`신청자 엑셀`, 다중은 체크박스 + 「선택 N개 …엑셀」. ExcelJS CDN lazy-load, 영수증 이미지 임베드. 50개+ confirm() + 5초 쿨다운 + 동시 진행 lock. 시트1 「캠페인 정보」 + 시트2 「결과물/신청자」. 이름 한자/가나 분리, SNS 핸들 → 전체 URL, 우편번호 별도. 헬퍼 `_excel*`
