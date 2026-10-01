---
description: 브랜드·회사·광고주 신청(브랜드 서베이) 관리 화면 — 브랜드 상세 모달·삭제·병합·신청 상태·메모·입금 칩(묶음 규칙)
paths:
  - "dev/js/admin-brand.js"
  - "dev/js/admin-excel.js"
  - "dev/js/admin-company.js"
  - "dev/js/admin-orient.js"
  - "dev/js/admin-core.js"
  - "dev/js/admin-brand-ops.js"
  - "dev/lib/shared.js"
  - "dev/lib/storage.js"
  - "dev/admin/index.html"
  - "supabase/migrations/*brand*"
  - "supabase/migrations/*compan*"
  - "supabase/migrations/*link_unlink*"
  - "supabase/migrations/*merge*"
  - "supabase/migrations/328_*"
---

# 브랜드·회사·광고주 신청 관리 (CLAUDE.md 브랜드 서베이 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **현황 대시보드**(`/admin#brand-dashboard`): KPI·**전환 깔때기 10단계**·추이·장기 대기 등. ⚠️ 「Vercel Web Analytics 외부 링크」는 **화면에 없다**(코드에 `vercel.com` 0건) — 새로고침 버튼과 「설문 페이지」 링크뿐
- **회사 관리 페인**(`/admin#companies`): 회사(`companies`) CRUD + 브랜드 일괄 할당(회사>브랜드>신청>캠페인). `name_ko` 필수, 보관/복귀, 소속 0건 시 완전 삭제. SELECT 모든 관리자·CUD `is_campaign_admin()` 이상. **브랜드 관리 폼은 회사 드롭다운으로 `company_id` 연결**(자유텍스트 `company_name` 입력 폐지·회사명 동기화 보존). `dev/js/admin-company.js`. 사양서 `docs/specs/2026-05-13-brand-ops-redesign.md` PR 2 + `2026-06-04-brand-company-linking.md`
- **브랜드 상세 모달 — 「오리엔시트 / 캠페인」 탭**(DB 변경 없음): 캠페인 탭은 **「오리엔시트 연결 / 직접 등록」 두 묶음**(기준 = **그 브랜드 시트**가 발행했나 — 운영현황은 전체 시트를 봐 브랜드를 옮긴 캠페인에서 갈릴 수 있다), **보관 삭제분 제외**. 🔴 **탭 전환은 형제 div 의 `display` 토글만** — 이 모달은 **편집 폼**이라 본문을 다시 그리면 고치던 값이 경고 없이 사라진다(값을 DOM 에서 읽는다). 같은 이유로 오리엔시트 발급·삭제·연결·해제·발행 뒤에는 `refreshPane('brand-detail')` → `refreshBrandDetailSheets` 가 **시트 구역·탭 숫자만** 다시 그린다(숨어 있으면 `_brandDetailStale` 표시만 → 화면 전환 때). 운영현황 상세(`brand-ops-detail`)는 같은 호출로 오리엔시트 캐시를 비운다 — 둘 다 `osRefreshAfterSheetChange`(admin-orient.js)가 부른다. 병합 창은 **열 때마다 목록·건수를 새로 받고 창이 이미 있으면 무시**(두 번 눌러 창이 둘이면 엉뚱한 대상으로 병합된다). ⚠️ 목록은 **캠페인 탭 첫 클릭 때** `fetchCampaignsByBrand`(실패 `null`·0건 `[]`, 기준은 `countCampaignsByBrand` 와 글자 그대로 같다)로 받고, 그사이 다른 브랜드를 열었으면 `_brandsCurrentId` 대조로 버린다. ⚠️ 탭 라벨 건수는 이미 받은 `countCampaignsByBrand` 값(실패는 「…」). ⚠️ 「새 브랜드」 등록은 같은 본문 함수라 `b.id` 가 없으면 탭을 안 그린다. ⚠️ 운영현황 미니카드를 **통째로 쓰지 않는다** — 그 단추들은 운영현황 전역값에 기대 모달에선 아무 일이 없다. 표시 부품(`brandOpsCampThumb`·`brandOpsCampTypeChannel`·`brandOpsDateRange`·`brandOpsSubmitDateText`·`BRAND_OPS_CAMP_STATUS_*`)만 빌린다
- **브랜드 삭제·병합·목록 보강**: 「삭제」(연결 0건만 — `delete_brand` RPC, brands DELETE RLS 없음, 카운터 CASCADE) + 「병합」(`merge_brands` RPC — 현재 원본 **467**(175 → 328 오리엔시트 이동 → 467 메모 이동, 🔴 175 를 베이스로 잡으면 둘 다 사라진다) — **회사 무관**, 신청·캠페인을 대상 브랜드로 이동 + 채번 재발급[`legacy_no` 보존·`numbering_legacy_map` UPSERT, 121 패턴] + `brand/brand_ja/brand_en` 동기화 + 원본 `archived`, advisory_xact_lock 2단, `is_campaign_admin()`). 병합은 되돌리기 불가 확인. 목록에 「캠페인 수」 열(`fetchCampaignCountsByBrand`) + 회사명 `company_id` 기준(`company_name` 미동기화 대비). 마이그레이션 174·175. 사양서 `docs/specs/2026-06-09-brand-delete-merge.md`
- **신청 관리**(`/admin#brand-applications`, **UI 라벨: "브랜드 서베이"**): 내부 용어·DB(`brand_applications`)·라우트·함수명은 `광고주 신청`. 비공개 URL(`sales.globalreverb.com/reviewer`, `/seeding`) 신청 관리. 모든 관리자(`is_admin()`)
- **리스트**: 필터 + pending(new) 배지 + 상세 모달(제품 표·견적·견적서/OT 시트 URL·`paid_at` 인라인 편집·제품별 메모·낙관적 락 version)
- **상태 전이 10단계**: `new → reviewing → quoted → paid → kakao_room_created → orient_sheet_sent → schedule_sent → campaign_registered → done` / `rejected`. "되돌리기"(any → new). `kakao_room_created` 는 입금 확인 후 카톡방 개설
- **제품별 메모**: 셀 ✎ 로 모달. 분홍 배지 = 본인 미확인 수(`brand_application_memo_reads`). 진입 시 자동 read. RPC `mark_brand_app_memos_read` + `get_brand_app_memo_summaries()` 페어 집계
- **입금여부 4종 칩**(`payment_flags jsonb`): {recruit, product, transfer, free}. products 변경 시 앞 3종 자동 재계산 트리거, free 는 OLD 값 보존.
- **가격체크**: `products[i].price_check` (`'higher'|'lower'|'equal'`, optional) — 미선택이면 키 없음
- **URL 입력 자동 prefix**: `normalizeBrandUrlInput(raw)` — `example.com` 에 `https://` 부착, 위험 스킴(javascript:, data:) 차단
- **엑셀 내보내기**: 신청 목록 주요 열(견적·상태 포함)
- **캠페인 ↔ 신청 연결/해제**: `link_campaign_to_application` / `unlink_campaign_from_application` RPC. 같은 brand_id 검증 후 채번 재발급 + `legacy_no` 콤마 누적 + `numbering_legacy_map` UPSERT. `pg_advisory_xact_lock` 2단. 멱등 `unchanged:true`. `is_campaign_admin()` 이상
