---
description: 운영 현황 페인 — 일정(간트) 뷰·브랜드 뷰, 인증 성공·기간 판정을 다른 화면과 공유(묶음 규칙)
paths:
  - "dev/js/admin-brand-ops.js"
  - "dev/js/admin.js"
  - "dev/js/admin-excel.js"
  - "dev/js/admin-orient.js"
  - "dev/js/admin-applications.js"
  - "dev/js/admin-deliverables.js"
  - "dev/js/application.js"
  - "dev/lib/shared.js"
  - "dev/lib/storage.js"
  - "dev/css/admin.css"
  - "supabase/migrations/*brand_ops*"
---

# 운영 현황 페인 (CLAUDE.md 브랜드 서베이 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **운영 현황 페인**: 뷰 2종 — **「일정」(기본, 간트차트)** / **「브랜드」**(카드 그리드). 뷰는 `localStorage` `reverb.brandOps.view`. 회사 필터·검색 공용, 정렬은 브랜드 뷰 전용, 「종료 포함」·‹ 오늘 › 는 일정 뷰 전용. 필터 핸들러는 전부 `renderBrandOpsCurrentView()` 로(직접 `renderBrandOpsCards()` 를 부르면 일정 뷰에서 필터가 안 먹는다).
  - **일정 뷰**(`admin-brand-ops.js`, DB 변경 0): 대상 `scheduled·active·closed`(「종료 포함」이면 `ended·expired`, `draft`·삭제분 제외). **트리형** — 캠페인 행(**모집률**·**결과물 승인률**)을 펼치면 **모집 → 구매·방문 → 선정 → 제출** 순(`ganttSegsInFlowOrder`) 자식 행이 나오고 단계 진척이 붙는다(해당 없음 = `num: undefined`). **접힌 행 막대는 전체 일정 하나**(`ganttMergedSegment`), 구간 막대·D-day 는 자식 행에만. **막대 옆 경고 꼬리표**(`ganttCampaignAlert`·`ganttAlertTagHtml`, 부모 행만, 오른쪽 끝이면 `right` — 모집중: 마감 하루 전/3일 이내·모집 저조(30% 미만+마감 7일 이내 / 50% 미만) / 모집마감: **제출 마감 3일 이내+미인증 1명 이상**(하루 전·오늘 긴급) · 제출 마감 7일 이내+결과물 승인률 50% 미만(주의)). ⚠️ **브랜드 카드 경고(148)의 화면 사본**이라 임계값은 같되 취소 5건 조건은 뺐고 브랜드 합산과 단계가 다를 수 있다 — 툴팁이 말한다. 정상이면 안 그림. **시간축 가로 스크롤** — 끝에 닿으면 더 그린다(`_ganttExt`, 한쪽 최대 2년, 왼쪽 확장 시 scrollLeft 보정). ‹ › 는 이동폭만큼 스크롤(`ganttAnimateScroll` — `scrollBy({behavior:'smooth'})` 가 안 움직이는 브라우저가 있어 직접 굴린다. 🔴 숨은 탭에선 프레임이 안 돌아 바로 옮긴다). 조작 단추 `.gantt-nav`, 범례 `renderGanttLegend`, 왼쪽 열 접기 `ganttLeftToggleHtml`(⚠️ 머리글 안에서는 `--ink`·`--surface` 가 뒤집혀 색을 직접 적었다). 뷰 전환 `#brandOpsViewSelect`(함수는 `renderBrandOpsViewTabs`). 🔴 **날짜→위치 변환은 `ganttDayOffset` 하나**(`연-월-일` 문자열을 정수로 잘라 `Date.UTC` 차이 — `new Date('2026-09-07')` 파싱 금지). 막대는 `campaignPeriodRowKind` 갈래를 **이름으로** 지목(구매=`split`, 방문=`visit`). **선정 막대 조건은 선정 기간 표시 조건의 다섯째 자리**(`ganttSegmentsFor`) — 네 곳과 글자 그대로 같아야 한다. ⚠️ `.gantt-row .gantt-cell.c-dur > span` 은 **본문 행 한정** — 머리글까지 걸면 정렬 화살표가 커진다. 인증 성공은 **화면에서** `countCertSuccess` 로 센다(서버 사본을 안 만든다 — 판정 사본이 이미 5곳). 결과물은 `fetchDeliverablesByCampaignIds`(200개 조각, **하나라도 실패하면 통째 `null`**)로 받아 `_brandOpsDelivCache` 에 두고 **`loadBrandOps()` 재진입 때 비운다**. ⚠️ 캠페인은 반드시 `fetchCampaigns()`(`fetchCampaignsForAdminList` 는 `proxy_purchase`·`first_active_at`·`brand_id` 가 없어 조용히 틀린다). ⚠️ 조회 실패(`null`)는 「—」, 0건은 「0/N」. ⚠️ 가로 스크롤바는 **일부러 항상 보이게**(`.gantt-scroll`) — 다른 스크롤바 규칙과 반대. 사양서 `docs/specs/2026-09-07-brand-ops-schedule-gantt-view.md`
  - **브랜드 뷰**(사양서 `docs/specs/2026-09-22-brand-ops-and-cost-card-orient.md`): 카드 「진행 오리엔시트」·상세 「오리엔시트 (N)」·「연결 / 직접 등록 캠페인」 분류는 **화면이** `fetchOrientSheets()` 를 진입마다 한 번 받아 만든다(`_brandOpsOrientSheets` — `undefined` 안 받음 / `null` 실패 / 배열). 🔴 진행·전체 수는 오리엔시트 탭 판정(`osMatchesTab`)을 그대로 쓴다. 🔴 시트 목록·숫자는 **시트 브랜드** 기준, 캠페인 분류는 **전체 시트** 기준. 실패면 숫자 「—」·분류 안 함·「신청에 연결」 숨김. 진행현황 비용 카드도 서베이 미연결이면 오리엔시트 견적(`appendCampOpsOrientCostCard`). 서버 집계 `get_brand_ops_overview(p_company_id)`(alert_level 4단계). **사유 배너**(정상 외) — `alert_reasons text[]` + `soonest_deadline`/`d1_count` 를 `brandOpsAlertReasonLines` 가 문구로 조립. 상세 `get_brand_ops_detail(p_brand_id)`. 사양서 `docs/specs/2026-05-13-brand-ops-redesign.md`
