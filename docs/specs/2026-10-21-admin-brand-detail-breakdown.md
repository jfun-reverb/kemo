# 📋 작업 분해표 — 관리자 「브랜드 상세」 재구성(탭 4개 + 영업 메모) · 묶음 ③ 관리자 화면

**사양서(정본):** `docs/specs/2026-07-15-brand-portal.md` §16-4 「관리자 브랜드 상세 페이지 구성 — 탭 4개 + 영업 메모」(705줄)·「관리자: 브랜드 상세의 담당자·계정 목록」(703)·「대표 담당자 계정 줄의 상태와 버튼」(704)·「화면 정책 넷」 ②③(698) · §16-5 6번(714)·11번·12번·14번 · §16-7 · §16-8 1번(연결 요청) · §4 「리포트 공유 링크」 ③(브랜드 공개 기본 열 세 층, 95줄) · 「운영 반영 전 남은 관문」(994~1004)
**옛 사양(지금 운영 페이지):** `docs/specs/2026-09-23-brand-detail-pane.md`
**Figma:** 파일 `XG4hXdgySeN45Ele3EnN8H` 구역 `659:523` 「[1차] a03-1 브랜드 상세 탭」(a03-13·00d·00·00a·00b·00c·00e·00f·09·93·90a·흐름도). 이 구역 밖 화면(a03-01~05·07·08·10·91·92)은 **다른 Figma 구역** — 조각마다 「Figma 다른 구역 확인 필요」로 표시했다.
**받아 쓰는 계약:** 마이그레이션 527·531·533(계정·멤버 함수) · 536(브랜드 쪽 저장·이력) · 544·559(브랜드 공개)
**분해일:** 2026-10-21
**범위:** 관리자 브랜드 상세 페이지(묶음 ③). 브랜드 화면(`dev/brand/`)·연결 요청 서버(16-8 1번)·이용 제한(a03-94)·머리 「…」 메뉴(16-8 「들어오는 곳 정리」)는 범위 밖 — 경계만 적는다.
**출시(2026-10-21 사용자 결정):** 전부 **브랜드 페이지 1차와 함께**. 운영에 먼저 따로 내지 않는다 → 새 화면은 개발서버 판정 아래에만, **운영은 지금 화면 그대로**.
**총 작업 조각:** 12개(데이터베이스 D1·D2 + 화면 1~10) · **병렬 가능:** 조각 1 뒤 두 줄기(「2→3→4→9」 ∥ 「5→6→7→8」, 조건은 「공유 지점 경고」) · **순차 필수:** 나머지

> **화면 문구 언어:** 한국어(관리자 화면). 이 작업에 일본어 문구는 없다.
> **마이그레이션 번호는 박지 않는다** — D1·D2 는 「새 마이그레이션(번호는 만들기 직전 `git pull origin dev` 뒤 확정)」. 개발자가 두 명이라(`.claude/rules/two-developers.md`) 만들기 직전에 상대에게 알린다.

---

## 현재 상태 (2026-10-21 코드 확인)

| 항목 | 실제 |
|---|---|
| 화면 자리 | 페이지 `#adminPane-brand-detail`(`dev/admin/index.html` 2670~2672 — 머리 `#brandDetailPaneHeader` · 본문 `#brandDetailPaneBody` 두 칸). 모달 `#brandDetailModal` 은 **신규 등록 전용**으로 남아 있다(09-23 결정 ㉣) |
| 들어오는 길(전수) | `openBrandDetail(id, from)` 호출 자리 다섯 — 브랜드 목록 행(`admin-brand.js` 1149) · 운영 현황 카드(`admin-brand-ops.js` 354, `'brand-ops'`) · 서베이 신청 목록(`admin-brand.js` 안) · 오리엔시트 발급 창(`admin-orient.js` 679) · 배송 리스트 탭(`admin-shipping.js` 231, `from` 없음) |
| 머리 | `renderBrandDetailPaneHeadHtml`(1276) — 돌아가기 단추가 들어온 곳별 세 갈래(`BRAND_DETAIL_BACK` 37~41) · **상태 선택칸 `#brandFormStatus` 가 머리 안**(1514) · 「삭제」(연결 0건 + 캠페인 관리자 이상) · 「병합」 · 「제공 기록」(최고 관리자 + 개발서버) · 「오리엔시트 발급」 · **「저장」이 머리에** |
| 본문 | `renderBrandDetailFormHtml`(1763) — 한 줄로 이어진 절: 기본 정보(회사 블록 + 이름 셋) · 담당자(줄마다 **인라인 편집**, 별 단추로 대표, 계정 줄 `#brandAccountStatusRow` 개발서버만) · 「브랜드 콘텐츠 (오리엔시트용)」(소개·어필·Qoo10·인스타·X) · 브랜드 공개 기본 열(개발서버만) · 탭 둘(오리엔시트·캠페인, `display` 토글) + 오른쪽 영업 메모 `#brandMemoPanel` |
| 같은 본문을 쓰는 다른 자리 | **신규 등록 모달**(`openNewBrandModal` 2343)이 같은 `renderBrandDetailFormHtml` 을 쓴다. 입력칸 아이디가 같아 페이지·모달 본문 중 하나를 비우는 장치 두 개(`clearBrandModalBody`·`clearBrandDetailPaneBody`)가 한 세트 |
| 저장 | `_collectBrandFormPatch`(2251)가 **통째로** 보낸다 — `contacts`·옛 대표 칸 셋(`primary_contact_name`·`primary_phone`·`primary_email`)·**세 칸(`description`·`appeal_points`·`official_qoo10_url`)** 포함 → `updateBrand`(storage.js 3473, 표 직접 갱신, 정책 `brands_update_admin` = `is_admin()`) |
| 저장 뒤 계정 처리(임시 구현) | `_brandAccountAfterBrandSave`(2624) — 개발서버에서 대표 이메일이 새로·바뀌면 **저장만으로 계정을 만들고 메일**. 신규 등록(`submitNewBrand` 2368)도 같은 호출 → **새 브랜드 등록만으로 계정·메일**. 16-5 14번에서 무효 판정된 동작 |
| 계정 줄(지금) | 상태 넷(`none`·`mail_pending`·`mail_sent`·`active`) + 「계정 만들고 메일 보내기」·「다시 보내기」. 캠페인 매니저에게 **회색 단추 + 「계정 메일은 캠페인 관리자 이상이 보냅니다」**(2488 — Figma a03-00f 가 「임시 구현이라 바뀐다」고 지목). 대표 바꾸기·해제·멤버 상한·연결 추가·멤버 줄 **화면 없음**. 권한 판정은 화면이 `isCampaignAdminOrAbove()`(2406) |
| 서버에 이미 있는 것(533, 개발서버) | 쓰기 다섯(`has_permission('brand.account_manage','write')`, 거부 `forbidden`): `admin_upsert_brand_owner_account` · `admin_change_brand_owner(brand, 새 대표, 기대한 옛 대표)` · `admin_set_brand_member_limit` · `admin_release_brand_account` · `admin_link_brand_owner_account`. 조회 둘(`is_admin()`): `admin_get_brand_account_status`(상태·`setup_mail_sent_by`·`owner_auth_id`·`members[]`(이름·이메일·연락처·마지막 접속·역할)·`pending_invite_count`·`release_cancel_count`·`seat_used`·`member_limit`·`can_manage`) · `admin_check_brand_account_email`(겹침 확인). 메일 `notify-brand-account-setup`(`mode` setup·resend, `mail_kind:'link'` = 연결 안내) |
| storage.js 감싸개 | 있는 것: `upsertBrandOwnerAccount`·`fetchBrandAccountStatus`·`sendBrandAccountSetupMail`(3507~3554, 전부 `_brandAccountEnabled()` 아래). **없는 것:** 대표 바꾸기·상한·해제·연결 추가·겹침 확인 다섯 |
| 서버에 없는 것 | ①담당자 **한 줄** 저장·삭제 함수(`brands.contacts` 는 배열 한 칸) ②계정이 있는 동안 대표 줄 잠금의 **서버 거부**(16-4 「화면 정책 넷」 ② — 「화면만이 아니라 서버도」) ③관리자 저장의 동시 저장 방어(`brands` 에 `version` 없음, 536 은 브랜드 쪽만 칸 비교) ④16-8 1번 **연결 요청**(533 은 즉시 연결 + 연결 안내 메일) ⑤옛 대표 칸 셋 맞추기 — 531 `_brand_contacts_mark_primary`(381~432)는 `contacts` 만 고쳐 **브랜드 목록의 「대표 담당자」 열이 옛 사람으로 남는다** |
| 회사 수정 모달 | `openCompanyModal(id, opts)`(`admin-company.js` 156)이 회사를 **회사 관리 화면 목록 보관값 `_companiesCache`** 에서 찾는다 → 그 화면을 안 열었으면 빈 폼이 「새 회사 추가」 제목으로 뜨는데 대상 아이디는 잡혀 있어 **저장하면 기존 회사를 빈 값으로 덮어쓴다**. 캠페인 매니저 「보기」도 같은 이유로 **빈 칸**. `saveCompany` 는 10칸 통째(207). 브랜드 상세에서는 지금 「신규 회사 등록」(`openCompanyModal(null, {onSaved})`)만 부른다 — 그래서 운영에서는 아직 안 터진다 |
| 떠날 때 확인 | 브랜드 상세에는 **없다**. 캠페인 폼용 `campLeaveGuard`(`admin-campaign-dirty.js` 238)는 판정이 캠페인 두 페인만 본다. 부르는 자리 셋 — 사이드바 `navAdminPaneReload`(`dev/admin/app.js` 77) · 정산(`admin-settlements.js` 536) · 캠페인 편집(`admin.js` 1094). **브라우저 뒤로가기(`admin-core.js` 392 popstate)는 안 지난다** |
| 페이지를 떠나는 다른 길 | 「← 돌아가기」(머리) · 캠페인 탭 배지(`brandDetailOpenCampProgress` 1371 — 브라우저 기본 `confirm` + `closeBrandDetailModal()` 이 `_brandsCurrentId` 를 비움) · 오리엔시트 상세의 「이 카드로 발행」(`admin-orient.js` 2247 `switchAdminPane('add-campaign')`) · 「제공 기록」(`openPrivacyLogs`) · 다른 브랜드 상세 열기(발급 창·배송 탭) · 신규 등록 모달(`openNewBrandModal` 이 페이지 본문을 비움) |
| 갱신 장치 | `PANE_REFRESHERS['brand-detail']`(shared.js 1486) → `refreshBrandDetailSheets`(1317 — 시트 구역·탭 숫자만, 숨어 있으면 `_brandDetailStale`) · 화면 진입 `loaders['brand-detail']`(admin-core.js 280) · 오리엔시트 쪽은 `osRefreshAfterSheetChange`(admin-orient.js 2070)가 부른다 |
| 권한 카탈로그 | `brand.account_manage` **없음**(530 시드만). 개발서버 전용 표시 깃발 `staging_only` 는 있다(`admin-permissions.js` 86, 선례 `shipping.manage`). 회사 수정 판정 `canEditCompanies` 는 등급 하드코딩(카탈로그 `company.cud` 와 별개) |
| 브랜드 공개 기본 열 | 이미 있다 — `renderBrandPublishDefaultBox`(`admin-brand-publish.js` 248) + **자기 「기본 열 저장」 단추**(544 `admin_set_brand_publish_default_brand`, `report.share` 쓰기). 규칙 파일·코드 주석이 「`saveBrandDetail` 에 넣지 않는다」고 적었다 — **사양서·Figma 「탭의 저장으로 함께」와 어긋남**(선결 S0-2) |
| 오리엔시트 탭·캠페인 탭 | 내용·조회·실패와 0건 구분·「브랜드 공개 중·꺼짐」 배지(544, 개발서버만)·발급 경고(계정 없는 브랜드, 16-5 8번)까지 **이미 있다** — 이 작업은 탭 자리만 옮긴다 |
| 개발서버 판정 | `_brandAccountEnabled()` = `IS_STAGING`(storage.js 3500) 한 곳 |
| 세 칸 데이터 | 읽는 곳은 `admin-brand.js`(1838~1842·2284~2286)와 `fetchBrands` 칸 목록(storage.js 3459)뿐. **운영에 값이 든 브랜드 수는 미확인**(조각 2 착수 때 센다) |
| 미해결 백로그 | 브랜드 화면(536)이 고친 값을 관리자 폼이 통째 저장으로 되돌림(CLAUDE.md 경고 — 막는 곳이 이 묶음) · 531 대표 이동을 열린 관리자 폼이 되돌림 · 3차 ⑥ 낮음(영업 메모 저장 경합 등 — 16-5 6번이 「이 사양에서 함께」로 넘김) |

### 낱말 전파 점검 — 화면에서 이름이 바뀌는 말

찾은 방법: `dev/`·`supabase/functions/`·`docs/email-templates/`·`docs/FEATURE_SPEC.md` 에서 글자 검색(빌드 산출물 제외).

| 바뀌는 이름 | 쓰이는 자리 | 처리 |
|---|---|---|
| 「브랜드 콘텐츠 (오리엔시트용)」 → 「SNS 정보」 | `admin-brand.js` 1836 한 곳(코드) · 사양서·마이그레이션 082 주석 | 화면만. 메일·번역 파일·자주 묻는 질문·엑셀 0건 |
| 「← 브랜드 관리로 / 운영 현황으로 / 브랜드 서베이로」 → 「목록」 | `admin-brand.js` `BRAND_DETAIL_BACK` | 새 화면에서 갈래 없음 |
| 「담당자」 절 → 「담당자·계정」 탭, 「기본 정보」 절 → 「브랜드 정보」 탭 | `admin-brand.js` 한 곳 | 화면만 |
| 계정 상태 이름(「메일 대기」 → 「미발송」 등 a03-91 다섯) | `admin-brand.js` 2471~2484 · `admin-orient.js` 발급 경고 문구(16-5 8번 두 갈래) | **발급 경고 문구가 같은 상태 이름을 쓰는지 조각 6에서 대조** |
| 노션 「관리자 가이드」 브랜드 관리 페이지 | 출시 뒤 | 조각 10 이 고칠 목록에 올린다(노션 규칙 — 운영 배포 뒤 갱신) |

---

## 의심·경우의 수 (반대론자)

1. **(사용 흐름) 떠날 때 확인이 새는 길이 일곱이다** — 사이드바만 막으면 「목록」·캠페인 탭 배지·오리엔시트 「이 카드로 발행」·「제공 기록」·다른 브랜드 열기·신규 등록 모달·브라우저 뒤로가기에서 고치던 값이 **조용히 사라진다**. 특히 오리엔시트 상세 창은 페이지 **위에** 떠서 「아직 페이지 안」으로 느끼는데 「발행」은 화면을 옮긴다. → 조각 4가 길을 전수로 막고, 뒤로가기는 선결 S0-6.
2. **(데이터) 관리자 「저장」이 남이 고친 값을 되돌린다** — 브랜드 담당자가 브랜드 화면(536)에서 이름·SNS·회사 정보를, 대표가 「대표 넘기기」(531)로 담당자 대표 표시를 바꾸는 사이 열려 있던 관리자 폼이 통째로 저장하면 경고 없이 되돌아간다. → 「담당자 칸을 보내지 않는다」(조각 2) + 칸 단위 비교 저장(D2) + 회사 모달도 같은 함수(조각 3).
3. **(기술) 두 벌 구현이 갈라진다** — 운영은 옛 화면, 개발서버는 새 화면이라 같은 기능(오리엔시트 구역 갱신·메모)이 두 화면에서 돌아야 한다. 갱신 장치(`PANE_REFRESHERS`·진입 로더·`osRefreshAfterSheetChange`)가 옛 화면 요소 아이디를 가정한다 → 새 화면이 같은 아이디를 쓰거나, 옛 진입 함수 **첫 줄에서 새 함수로 넘긴다**(선결 S0-1 권고).
4. **(기술) 입력칸 아이디 충돌** — 새 화면과 신규 등록 모달이 같은 아이디(`brandFormName` 등)를 쓰면 문서 순서상 앞의 것을 읽어 **엉뚱한 값이 저장**된다(09-23 사양서 2-2). 새 화면은 **다른 아이디 접두어**를 쓴다.
5. **(권한·환경) 매니저가 누를 수 있어 보이는 단추** — 담당자 「수정」은 매니저에게 남지만(a03-00f) 계정이 있으면 대표 줄은 잠긴다. 잠긴 칸이 열려 보이면 「저장 → 서버 거부」가 된다 → 모달이 잠금을 먼저 그린다. 권한이 열어 둔 사이 바뀌면 서버 거부 문구(a03-90a 초안 「권한이 바뀌어 저장할 수 없습니다…」).
6. **(사양 충돌) 「브랜드 연결 추가」·겹침 확인 창 「연결」은 이제 연결 요청이다(16-8 1번)** — 서버(533)는 즉시 연결한다. 그대로 화면을 붙이면 **약관 제5조 5항(본인 수락)을 어기는 동작이 개발서버에 생긴다** → 선결 S0-3.
7. **(사양 충돌) 브랜드 공개 기본 열 저장 경로** — 사양서·Figma 「탭의 저장으로 함께」 ↔ 구현·규칙 「자기 단추로만」. 합치면 저장이 서버 호출 둘(브랜드 정보 · 기본 열)이 되어 **한쪽만 성공**하는 경우를 화면이 말해야 한다 → 선결 S0-2.
8. **(데이터) 브랜드 목록의 「대표 담당자」 열이 옛 사람으로 남는다** — 대표 이동(531)이 옛 대표 칸 셋을 안 맞춘다. 담당자 한 줄 저장도 같은 일을 해야 한다 → D1 에서 「`contacts` 가 바뀌면 옛 대표 칸 셋을 서버가 맞춘다」로 한 곳에 둔다.
9. **(법률·약관) 「마지막 접속」을 관리자 화면에 처음 띄운다** — 이용 기록(운영 관문 10번 `/약관확인`·보관 기간). 개발서버만이라 막지 않지만 출시 판단에 포함.
10. **(데이터) 회사 모달 「브랜드 N개에 함께 바뀝니다」의 N** — 사양서는 `total_brands`(보관 포함), 브랜드 화면(작업표 D3)은 활성만. 같은 회사의 같은 안내가 화면마다 다른 숫자 → 선결 S0-9.

**현재 구현과 충돌하는 지점:** ①머리의 「저장」·상태 선택칸 ②돌아가기 세 갈래 ③담당자 인라인 편집 + 통째 저장 ④저장·신규 등록 때 자동 계정 생성(임시 구현) ⑤매니저 회색 단추 문구 ⑥회사 모달의 목록 보관값 조회 ⑦브랜드 공개 기본 열 자기 단추 ⑧533 즉시 연결.

**사용자 의도 모호점:** 「운영은 지금 그대로」가 **신규 등록 모달**까지 포함하는가(개발서버에서도 세 칸·자동 계정 생성을 그대로 둘지 — S0-8) · 「목록」이 운영 현황에서 들어온 사람에게도 브랜드 목록인가(사양서는 「어디서 들어왔든」이라 적었다 — 그대로 따른다).

**권고:** 새 화면은 **새 파일**에 따로 만들고 옛 진입 함수 첫 줄에서 개발서버일 때만 넘긴다(운영 경로는 한 글자도 안 바뀐다). 데이터베이스는 담당자 한 줄 저장(D1)·칸 단위 비교 저장(D2) 둘만 이 작업표에 넣고, 연결 요청(16-8 1번)은 별도 작업표로 뺀다.

---

## 🚦 착수 전 선결 조건

| # | 선결 조건 | 근거 | 막는 조각 |
|---|---|---|---|
| S0-1 | **운영·개발서버 가르는 방식** — 아래 「S0-1 경우의 수」 | 2026-10-21 「전부 1차와 함께」 | 1 (이후 전부) |
| S0-2 | 브랜드 공개 기본 열을 탭 「저장」으로 합칠지 | 의심 7 | 9 · 4(판정 범위) |
| S0-3 | 「브랜드 연결 추가」·겹침 확인 창 「연결」을 이번에 어떻게 둘지 | 의심 6 · 16-8 1번 | 7 · 8 |
| S0-4 | 「되돌리기」 범위 · 확인 모달 단추 · 탭 닫기 경고 · 다른 브랜드 바로 열기 · 탭 기억 | Figma 「아직 정하지 않은 것」 | 2 · 4 |
| S0-5 | 담당자 줄·계정 줄 묶는 기준 · 대표 줄 「해제」(멤버 있을 때) · 「계정 만들기」 숨김 조건 · 대표 없을 때 「멤버 0 / 5명」 셈 · 권한 항목 이름 | Figma a03-00·00a·00f 미정 | 5 · 6 · 7 · 8 |
| S0-6 | 브라우저 뒤로가기도 막을지 | 의심 1 · 09-23 사양서 1-10 | 4 |
| S0-7 | 머리 「삭제」 유지 · 매니저에게 「오리엔시트 발급」 | a03-00d·00e 미정 | 1 |
| S0-8 | 신규 등록 모달(개발서버)에서 세 칸 제거·자동 계정 생성 걷기 | 의심 모호점 | 7 |
| S0-9 | 회사 모달 브랜드 수 기준 | 의심 10 | 3 |
| S0-10 | Figma 다른 구역 원문 대조 — a03-01·01a·01b·01c(계정 만들기) · 02·02a·02b(대표 바꾸기) · 03·03a(상한) · 04·04a(연결 추가) · 05·05a·05b(해제) · 07·07a·07b(회사) · 08·08a·08b·08c(담당자) · 10(저장 충돌) · 90(계정 토스트) · 91·91a(대표 줄 상태) · 92(멤버 줄) | 이 작업표는 사양서 기준으로만 적었다 | 그 화면을 만드는 조각 착수 때(착수는 막지 않는다) |
| S0-11 | 개발서버 시험 데이터 — 대표 설정 완료 + 멤버 2명 브랜드 · 대표 없는 브랜드 · 대표 「메일 보냄」·「만료」 브랜드 · 세 칸 값이 든 브랜드 · 같은 회사 활성 브랜드 둘 + 보관 하나 · 매니저 계정(로그인은 사용자에게 부탁) | 묶음 ② 시험 계정 `zz-b2-*` 재사용 | 완료 확인 |
| S0-12 | 마이그레이션 동시 작성 확인 — 상대 개발자가 `brands`·`companies`·`_brand_contacts_mark_primary`(531)·533 함수를 다시 정의하는 작업이 있는지 | `two-developers.md` 1번 | D1 · D2 |

### S0-1 경우의 수 — 운영은 옛 화면, 개발서버는 새 화면

| 안 | 방법 | 좋은 점 | 나쁜 점 | 실패·되돌리기 |
|---|---|---|---|---|
| **A (권고)** 새 파일 + 진입 첫 줄 위임 | 새 파일(예 `dev/js/admin-brand-detail.js` — 틀·브랜드 정보 탭·떠날 때 확인, `dev/js/admin-brand-contacts.js` — 담당자·계정 탭·계정 모달)에 새 화면 전부. 옛 함수 넷의 **첫 줄**만 고친다: `openBrandDetail`·`refreshBrandDetailSheets`·`setBrandDetailTab`·`brandDetailOpenCampProgress` → `if (_brandDetailNewOn()) return 새함수(...)`. 판정 `_brandDetailNewOn()` = `_brandAccountEnabled()` 를 감싼 한 곳 | 운영 경로는 옛 코드 그대로(첫 줄 조건만) · 갱신 장치(`PANE_REFRESHERS`·진입 로더·`osRefreshAfterSheetChange`)를 안 고친다 → 핫스팟 `shared.js`·`admin-core.js` 손대지 않음 · 출시 때 「옛 본체 지우기 + 첫 줄 걷기」로 끝 · 두 파일로 나누면 개발자 둘이 병렬 가능 | 두 벌이 한동안 함께 산다(옛 본체를 고치는 버그 수정이 새 화면에 안 따라올 수 있다) · 전역 이름 충돌 위험(단순 이어붙이기 빌드) | 새 화면이 깨지면 판정 함수 한 줄을 `false` 로 → 개발서버도 옛 화면 |
| B 한 함수 안 조건 | 지금 `renderBrandDetailFormHtml` 등에 `if (개발서버)` 갈래를 곳곳에 | 파일이 안 늘어난다 | 갈래가 수십 곳 → **운영 화면 회귀 위험**(이 파일 저장·탭·갱신 경로가 전부 운영 경로) · 신규 등록 모달도 같은 함수라 갈래가 또 갈림 · 출시 청소가 어렵다 | 되돌리려면 병합 요청 통째 되돌림 |
| C 기능 브랜치로 보류 | `dev` 에 안 넣고 출시 때 병합 | 운영 코드에 잠든 코드가 없다(`release-timing.md` 1순위 기본값) | 개발자 둘이 `dev` → `main` 을 계속 내보내는 동안 몇 주짜리 브랜치가 `admin-brand.js`·`storage.js` 와 계속 충돌 · **개발서버 검증 불가**(개발서버 = `dev`) · 브랜드 페이지 다른 조각들이 이미 `_brandAccountEnabled()` 방식이라 혼자 다른 방식 | — |

권고 근거: 브랜드 페이지 묶음 전부가 이미 「개발서버 판정 + 출시 때 걷기」 방식이고(`release-timing.md` 「인코드 플래그는 예외」의 그 예외로 운영 중), A 는 그 판정을 진입 넷에만 두어 운영 경로를 건드리지 않는다.

### 출시 때 걷을 자리 (A 기준 — 조각 10이 최종 목록을 사양서 「운영 반영 전 남은 관문」에 넣는다)

1. 옛 함수 넷의 첫 줄 위임 → 새 함수가 유일한 구현. 옛 본체(`renderBrandDetailPaneHeadHtml`·`renderBrandDetailTabsHtml`·옛 `setBrandDetailTab`·`saveBrandDetail`·`_collectBrandFormPatch` 의 상세 몫·`renderBrandContactsRows`·`addBrandContact`·`removeBrandContact`·`setBrandPrimaryContact`·`updateBrandContactField`·`BRAND_DETAIL_BACK`·`_brandDetailFrom`) 지우기 — ⚠️ `renderBrandDetailFormHtml` 은 **신규 등록 모달이 쓰므로** S0-8 결과대로 남기거나 줄인다
2. 판정 함수 `_brandDetailNewOn()` 자체
3. 임시 계정 구현 — `_brandAccountAfterBrandSave`·`_brandAccountRunUpsert`·`brandAccountSendMail`·`_brandAccountRowHtml` 와 그 상태 변수들
4. 권한 카탈로그 `brand.account_manage` 의 `staging_only` 깃발
5. 회사 모달·`saveCompany` 의 개발서버 갈래(조각 3) → 새 저장 함수만
6. 브랜드 공개 기본 열 칸의 `_brandAccountEnabled()` 조건(이미 있는 것 — 1848)
7. 떠날 때 확인의 개발서버 조건(조각 4)
8. 운영 데이터베이스 — D1·D2 를 브랜드 묶음 적용 순서(526 → … → 536 → 544 …) **뒤**에. D1 의 대표 줄 잠금은 526(`brand_account_links`)에 기댄다

---

## ⚠️ 사양서·작업표 stale 점검

1. **브랜드 공개 기본 열 저장** — 사양서 705줄·Figma a03-00d 「탭의 저장으로 함께」 ↔ `admin-brand-publish.js` 181·263 주석 + `.claude/rules/brand-account.md` 「브랜드 칸은 자기 「기본 열 저장」 단추로만」(조각 11 구현). S0-2 결과대로 한쪽을 고친다(규칙 파일은 고문에게 넘김).
2. **연결 요청(16-8 1번)** — Figma a03-04·01c·흐름도 「연결 요청 보냄 · 본인이 24시간 안에 수락」 ↔ 533 `admin_link_brand_owner_account` 즉시 연결 + `notify-brand-account-setup` `mail_kind:'link'` 연결 안내 양식. 서버·메일·브랜드 화면(수락) 작업이 아무 작업표에도 없다 → S0-3.
3. **16-5 6번「출시 순서는 개발 담당자와 이야기한 뒤」·Figma 꼬리표「먼저 따로 출시 가능 / 일부만 먼저」** → 2026-10-21 「전부 1차와 함께」로 정해졌다. 사양서 문장·Figma 꼬리표 정리는 기획 몫.
4. **Figma a03-00 저장소 참고 「브랜드 계정·멤버 표와 서버 함수는 새로 만든다」** → 530~533 이 이미 있다. a03-00a 「가입 트리거 현재 원본 420 · `invite_admin` 417」 → 526 · 528. Figma 정정은 기획 몫.
5. **`.claude/rules/brand-account.md` 「관리자 브랜드 상세 「계정」 줄 — 「대표 이메일이 새로·바뀔 때만」은 화면이 지킨다」** → 16-5 14번에서 무효가 된 임시 구현. 조각 7이 걷고, 규칙 문장 정정은 고문에게.
6. **09-23 사양서 ㉡ 「돌아가기는 들어온 곳으로」** → 16-4 「목록 — 어디서 들어왔든 브랜드 목록」으로 뒤집혔다. 옛 사양서 머리에 「16-4 가 대체」 한 줄(조각 10).
7. **CLAUDE.md 「🔴 관리자 화면이 브랜드가 고친 값을 되돌린다 — 막는 것은 묶음 ③」·「🔴 묶음 ③ 전까지 `brands.contacts` 통째 저장」** → 이 작업표가 그 묶음 ③. 조각 10에서 「개발서버는 막힘 · 운영은 출시 때」로 고친다.
8. **브랜드 정보 작업표(2026-10-16) stale 3번** — 「관리자 회사 모달 브랜드 수 = `total_brands`(보관 포함) → 묶음 ③ 때 맞출지 기획이 정한다」 → S0-9.
9. **Figma a03-93 「지금 운영 화면 문구 그대로」** — 지금 문구는 「불러오지 못했습니다」·「오리엔시트 없음 — 하단 「오리엔시트 발급」으로 만듭니다」. 「하단」은 머리 단추라 이미 틀리다 → 조각 1에서 「머리의 「오리엔시트 발급」」로.
10. **사양서 16-4 704줄 선행 조건 「공용 설정 1시간 → 24시간을 두 서버 모두 바꾼 뒤 「~까지 유효(예상)」 표시」** — 개발서버는 2026-10-15 바꿨고 운영은 출시 때(관문 7번). 조각 6 완료 정의에 「출시 순서 관문 7번 뒤」를 적는다.

---

## 한눈에 보는 의존 순서

```
S0-1 · S0-12 → D1 담당자 한 줄 저장·대표 줄 잠금·옛 대표 칸 맞추기 (데이터베이스)
              D2 관리자 브랜드 정보·회사 정보 칸 단위 비교 저장 (데이터베이스)   ← D1 과 같은 개발자가 이어서
                 ↓ (둘 다 개발서버 적용 + 첫 호출 확인 뒤)
              1 새 파일·진입 분기·탭 4개 틀·머리·불러오기 상태·storage 감싸개·권한 카탈로그 (핫스팟 한 번에)
                 ├→ 2 브랜드 정보 탭 → 3 회사 모달 → 4 떠날 때 확인 → 9 브랜드 공개 기본 열 통합
                 └→ 5 담당자 목록·모달 → 6 계정 줄 표시 → 7 계정 만들기·다시 보내기·임시 구현 걷기 → 8 대표 바꾸기·해제·상한·(연결 추가)
                                                         ↓ (두 줄기 끝)
                                                10 문서·처음부터 끝까지 확인·출시 때 걷을 목록
```

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약(요지) | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| D1 | 담당자 한 줄 저장·삭제 + 대표 줄 서버 잠금 + 옛 대표 칸 맞추기 | 새 마이그레이션 | `admin_save_brand_contact(brand, contact, prev)` · `admin_delete_brand_contact(brand, contact_id, prev)` · `brands` 갱신 전 트리거(대표 줄 불변식 + 옛 대표 칸 셋) | S0-12 | ✗ | 개발 |
| D2 | 관리자 브랜드 정보·회사 정보 저장(칸 단위 비교) | 새 마이그레이션 | `admin_update_brand_info(brand, patch, prev)` · `admin_update_company(company, patch, prev)` → `ok`/`stale`(바뀐 칸)/거부 코드 | S0-12 | ✗(D1 다음 번호) | 개발 |
| 1 | 새 화면 틀 + 진입 분기 + 탭 4개 + 머리 + 불러오기 상태 + 감싸개·카탈로그 | 새 `admin-brand-detail.js` · 빈 껍데기 `admin-brand-contacts.js` · `admin-brand.js`(첫 줄 넷) · `storage.js` · `shared.js`(카탈로그 한 줄) · `dev/build.sh`(목록 + 원본 태그 정규식 두 곳) · `dev/admin/index.html`(원본 `<script>` 두 줄) | `_brandDetailNewOn()` · `openBrandDetailNew(id)` · `brandDtlSetTab(code)` · `brandDtlRedrawSection(name)` · 상태 객체 `_brandDtl` · storage 감싸개 아홉 | D1·D2·S0-1·S0-7 | ✗ | 개발 |
| 2 | 브랜드 정보 탭 — 칸 정리·저장·저장 안 한 변경 표시·되돌리기·매니저 보기 | `admin-brand-detail.js` | `brandDtlSaveInfo()` · `brandDtlIsDirty()` · `brandDtlRevert()` · 기준값 `_brandDtl.saved` | 1·S0-4 | ○(5~8과) | 개발 |
| 3 | 회사 정보 수정·보기 모달 연결 | `admin-company.js` · `admin-brand-detail.js` | `openCompanyModal(id, {company, onSaved, brandCount})` · 개발서버 `saveCompany` → `admin_update_company` | 2·D2·S0-9 | ○(5~8과) | 개발 |
| 4 | 떠날 때 확인 모달 + 이탈 경로 전수 | `admin-brand-detail.js` · `dev/admin/app.js`(한 줄) · `admin-brand.js`(이탈 자리 첫 줄) · `admin-orient.js`(발행 한 자리) · `admin-privacy-logs.js`(있으면 한 자리) | `brandDtlLeaveGuard(go)` · 동적 모달 | 2·S0-4·S0-6 | ○(5~8과) | 개발 |
| 5 | 담당자 목록 + 담당자 추가·수정 모달 + 삭제 | `admin-brand-contacts.js` | `brandDtlOpenContactModal(contactId?)` · `brandDtlRenderContacts()` | 1·D1·S0-5 | ○(2~4·9와) | 개발 |
| 6 | 계정 줄 표시 — 대표 상태 다섯·멤버 줄·머리 요약·마지막 접속·조회 실패 | `admin-brand-contacts.js` · `admin-brand-detail.js`(머리 요약 자리) | `brandDtlLoadAccount()` · `_brandDtl.account`(undefined/null/객체) | 5 | ○(2~4·9와) | 개발 |
| 7 | 계정 만들기·다시 보내기 + 임시 구현 걷기 | `admin-brand-contacts.js` · `admin-brand.js`(신규 등록 경로) | 확인 모달 a03-01 · 겹침 창 a03-01c · 「다시 보내기」 | 6·S0-3·S0-8 | ○(2~4·9와) | 개발 |
| 8 | 대표 바꾸기·해제·멤버 상한·(브랜드 연결 추가) | `admin-brand-contacts.js` | 모달 a03-02·03·05(·04) · 담당자 모달 대표 이동 연결 | 7·S0-3 | ○(2~4·9와) | 개발 |
| 9 | 브랜드 공개 기본 열 칸을 브랜드 정보 탭에 통합 | `admin-brand-detail.js` · `admin-brand-publish.js` | S0-2 결과대로 | 2·S0-2 | ○(5~8과) | 개발 |
| 10 | 문서 + 개발서버 처음부터 끝까지 확인 + 출시 목록 | 사양서 「구현 결과」 · `docs/FEATURE_SPEC.md` · `CLAUDE.md` · 옛 사양서 머리 | — | 1~9·D1·D2 | ✗ | 개발(규칙 파일은 고문에게) |

---

## 조각별 상세

### 조각 D1 — 담당자 한 줄 저장·삭제 + 대표 줄 서버 잠금 + 옛 대표 칸 맞추기 (데이터베이스)
- **하는 일:** 담당자를 줄 단위로 저장·삭제하는 서버 함수 둘을 만든다. 대표 계정이 있는 동안 담당자 목록의 대표 줄은 **이메일·대표 표시·삭제를 거부**하고 이름·연락처만 받는다. 이 규칙을 함수 안에만 두지 않고 `brands.contacts` 를 바꾸는 **모든 길**(표 직접 갱신 포함 — 정책 `brands_update_admin` 이 관리자 전원에게 직접 갱신을 허용한다)에 걸리게 갱신 전 트리거로 둔다. 같은 트리거가 `contacts` 가 바뀌면 옛 대표 칸 셋을 대표 줄 값으로 맞춘다(531 대표 이동 뒤 목록 「대표 담당자」 열이 옛 사람으로 남는 문제를 함께 닫는다).
- **담당 파일:** 새 마이그레이션 1개(번호는 만들기 직전 확정)
- **산출 계약:**
  - `admin_save_brand_contact(p_brand_id uuid, p_contact jsonb, p_prev jsonb) → jsonb` — `p_contact` = `{id?, name, phone, email, is_primary}`(아이디 없으면 새 줄, 서버가 아이디 생성). `p_prev` = 화면이 연 시점의 그 줄(새 줄이면 NULL). 결과 `result`: `ok`(+ 저장된 `contacts` 전체·새 줄 아이디) · `stale`(그 줄이 그사이 바뀜/지워짐 — 지금 줄 동봉) · `primary_locked`(대표 계정이 있는데 대표 줄 이메일·대표 표시를 바꾸려 함) · `use_change_owner`(대표 계정이 있는데 다른 줄에 대표 표시를 켜려 함 — 화면은 이 경로를 쓰지 않고 조각 8 대표 바꾸기로 간다. 안전망) · `invalid_input`(셋 다 빈 줄 · 이메일 형식 · 길이) · `brand_not_found` · `forbidden`
  - `admin_delete_brand_contact(p_brand_id, p_contact_id text, p_prev jsonb) → jsonb` — `ok` · `stale` · `primary_locked`(대표 계정이 있을 때 대표 줄 삭제) · `not_found` · `forbidden`. 대표 계정이 **없을 때** 대표 줄을 지우면 지금 화면처럼 첫 줄에 대표 표시를 옮긴다(`removeBrandContact` 2230 과 같은 규칙)
  - 대표 계정 없을 때 `is_primary=true` 저장은 다른 줄의 표시를 떼고 그 줄에(지금 `setBrandPrimaryContact` 와 같은 규칙)
  - 권한: `is_admin()`(지금 브랜드 수정 정책과 같다 — 매니저도 담당자를 고친다, a03-00f)
  - 트리거(갱신 전, `contacts` 칸): 「바뀌기 전에 불변식이 지켜졌고 바뀐 뒤 깨지면 거부」 — 불변식 = **활성 대표 계정이 있으면 대표 표시 줄이 정확히 하나이고 그 줄 이메일(`lower(btrim())`)이 대표 계정 이메일과 같다**. 이미 어긋난 옛 데이터는 막지 않는다(「나빠지는 변경만 거부」). 거부 코드 `primary_locked`
  - 같은 트리거가 대표 줄로 `primary_contact_name`·`primary_phone`·`primary_email` 을 맞춘다(대표 줄이 없으면 셋 다 NULL)
  - 실행 권한: 부여 먼저(`postgres`·`authenticated`·`service_role`) → `PUBLIC` 회수 → `anon` 회수(533 [G] 와 같은 순서)
- **선행 의존:** S0-12. 526(`brand_account_links`)·530~533 이 있는 서버(개발서버)
- **완료 정의:**
  - 함수 둘을 **로그인한 관리자 브라우저 콘솔에서** 갈래마다 1회 이상 호출(관리자 가드는 SQL 편집기로 재현 안 됨 — `supabase.md`)
  - 🔴 **대표 이동 경로 셋이 트리거에 막히지 않는다** — 관리자 `admin_change_brand_owner`(533) · 브랜드 화면 「대표 담당자 넘기기」(531 `transfer_brand_owner` 계열) · `admin_link_brand_owner_account`(533). 셋 다 「연결을 먼저 바꾸고 표시를 옮기는」 순서인지 본문으로 확인하고 실제로 한 번씩 돌린다. 하나라도 막히면 트리거 판정을 고친다(대표 이동이 통째로 죽는다)
  - `merge_brands`(528)·광고주 신청 함수(397)·`delete_brand`(528)가 `contacts` 를 건드리는지 본문 확인 — 건드리면 그 경로도 한 번 돌린다
  - 표 직접 갱신(`db.from('brands').update({contacts: …})`)으로 계정 있는 브랜드의 대표 줄 이메일을 바꾸면 `primary_locked` 로 거부되는지(관리자 세션 콘솔)
  - 대표 이동 뒤 `brands.primary_email` 이 새 대표 이메일로 바뀌었는지(SQL 조회)
  - **신규 등록 모달**(개발서버에서도 옛 경로)이 이 트리거 아래서 정상 저장되는지(새 브랜드는 계정이 없어 통과해야 한다)
- **필요 검문소:** `reverb-supabase-expert`(트리거 순서 — 536 이력 트리거 `trg_brands_profile_history` 와 같은 표, 이름 알파벳순 실행 · 잠금 순서 — 533 [B] 브랜드 잠금 열쇠 `brand_account_upsert:`), `reverb-reviewer`
- **주의·롤백:** 🔴 트리거가 틀리면 **대표 바꾸기·넘기기·연결이 전부 막힌다**. 되돌리기 = 트리거부터 지우기(`DROP TRIGGER`) → 함수 둘. 데이터는 바뀐 줄이 남는다. 운영 적용은 브랜드 묶음과 함께(출시 목록 8).

### 조각 D2 — 관리자 브랜드 정보·회사 정보 저장(칸 단위 비교) (데이터베이스)
- **하는 일:** 관리자 「브랜드 정보」 저장과 회사 모달 저장을 서버 함수로 바꾼다. 화면이 연 시점 값(`p_prev`)과 지금 값을 **칸마다** 비교해(536 `update_my_brand_info` 와 같은 방식, 기본값 5) 그사이 브랜드 담당자·다른 관리자가 바꾼 칸이 있으면 덮지 않고 알린다(Figma a03-10 — 다른 구역). 담당자 칸·세 칸은 **받지 않는다**(정본 방어선이 화면만이 아니게).
- **담당 파일:** 새 마이그레이션 1개(D1 다음 번호)
- **산출 계약:**
  - `admin_update_brand_info(p_brand_id uuid, p_patch jsonb, p_prev jsonb) → jsonb` — 받는 칸 **여덟만**: `name`·`name_ja`·`name_en`·`company_id`·`status`·`official_instagram_url`·`official_x_url` + (서버가 계산하는) `company_name` 사본. `contacts`·옛 대표 칸 셋·`description`·`appeal_points`·`official_qoo10_url`·`memo` 는 패치에 있어도 **무시**(오류가 아니라 무시 — 옛 캐시 화면 보호). 결과 `ok`(+ 저장된 행) · `stale`(+ 어긋난 칸 이름 목록 + 지금 값) · `duplicate_name`(이름 중복 — 지금 화면 문구 그대로) · `invalid_input` · `brand_not_found` · `forbidden`(`is_admin()` 아님)
  - `admin_update_company(p_company_id uuid, p_patch jsonb, p_prev jsonb) → jsonb` — 회사 표 10칸(`COMPANY_FIELDS`) + `status`. 같은 결과 형태 + `duplicate_name`. 권한은 지금 회사 쓰기 정책과 같게(`is_campaign_admin()`) · 회사명(한국어)이 바뀌면 같은 회사 **모든** 브랜드의 `brands.company_name` 사본을 맞춘다(브랜드 정보 작업표 기본값 6과 같은 규칙 — 지금 관리자 회사 모달은 안 맞춘다)
  - 실행 권한: D1 과 같은 순서
- **선행 의존:** S0-12 · 536(이력 트리거가 이 저장도 기록 — `changed_by` = 관리자)
- **완료 정의:**
  - 두 함수 갈래마다 1회 이상 로그인 관리자 콘솔에서 호출
  - 🔴 **세 칸이 비워지지 않는다** — `description` 에 값이 든 시험 브랜드를 `admin_update_brand_info` 로 저장한 뒤 세 칸 값이 그대로인지 SQL 조회
  - 🔴 **담당자가 되돌려지지 않는다** — 시험 브랜드에서 브랜드 화면 「대표 담당자 넘기기」 → 그 전에 받은 `p_prev` 로 관리자 저장 → `contacts` 대표 표시가 새 대표 그대로
  - 브랜드 화면(536)에서 영문명을 바꾼 뒤 옛 `p_prev` 로 관리자 저장 → `stale` + 칸 이름 `name_en`
  - 브랜드명 변경이 173 캠페인 이름 동기화·266 캠페인 변경 이력을 지금처럼 일으키는지(관리자가 바꿀 때와 같다)
- **필요 검문소:** `reverb-supabase-expert`, `reverb-reviewer`
- **주의·롤백:** 화면이 이 함수를 쓰는 것은 개발서버뿐(조각 2·3) — 함수를 지워도 운영 영향 없음. 운영 적용은 브랜드 묶음과 함께.

### 조각 1 — 새 화면 틀 + 진입 분기 + 탭 4개 + 머리 + 불러오기 상태 + 감싸개·카탈로그
- **하는 일:** S0-1 권고 A 의 뼈대. 새 파일 둘을 빌드에 등록하고, 옛 진입 함수 넷의 첫 줄에서 개발서버일 때 새 함수로 넘긴다. 새 화면은 머리(「목록」 · 번호 · 이름 · **상태 배지(보여 주기만)** · 요약 줄 「회사 · 대표 담당자 · 멤버」 자리 · 「삭제」(S0-7) · 「병합」(캠페인 관리자 이상) · 「제공 기록」 · 「오리엔시트 발급」) + 탭 줄(브랜드 정보 · 담당자·계정 · 오리엔시트 · 캠페인 — 이 순서, 처음은 브랜드 정보) + 오른쪽 영업 메모. 오리엔시트·캠페인 탭은 지금 부품(`renderBrandOrientSheetsView`·`renderBrandSurveyNoteHtml`·`renderBrandCampaignsView`·`renderBrandCampaignRow`·브랜드 공개 배지)을 **그대로 불러** 자리만 옮긴다. 영업 메모도 지금 함수(`renderBrandMemoPanelHtml`·`loadBrandMemos` 등)를 그대로. 브랜드 정보·담당자·계정 탭 본문은 「준비 중」 자리(조각 2·5가 채움). 다음 조각들이 `storage.js`·`shared.js`·`build.sh` 를 다시 만지지 않도록 **감싸개·카탈로그를 여기서 한 번에** 넣는다.
- **담당 파일:** 새 `dev/js/admin-brand-detail.js` · 빈 껍데기 `dev/js/admin-brand-contacts.js` · `dev/js/admin-brand.js`(첫 줄 넷만) · `dev/lib/storage.js` · `dev/lib/shared.js`(카탈로그 한 줄) · `dev/build.sh`(`ADMIN_JS_FILES` + **원본 `<script>` 태그를 지우는 정규식** — 관리자 빌드는 두 곳, `build.md` 「두 곳」) · `dev/admin/index.html`(개발용 원본 `<script>` 두 줄)
- **산출 계약:**
  - 판정 `_brandDetailNewOn()` — `_brandAccountEnabled()` 를 감싼 한 곳(출시 목록 2)
  - 옛 함수 첫 줄: `openBrandDetail` → `openBrandDetailNew(id)`(`from` 무시 — 「목록」은 늘 브랜드 목록) · `refreshBrandDetailSheets` → `brandDtlRefreshSheets()` · `setBrandDetailTab` → `brandDtlSetTab()` · `brandDetailOpenCampProgress` → 조각 4 의 떠날 때 확인을 거친 이동
  - 상태 객체 `_brandDtl` = `{ id, brand, saved(조각 2), account(조각 6 — undefined 아직 / null 실패 / 객체), tab, req(요청 번호) }`. 🔴 받는 사이 다른 브랜드를 열었으면 늦은 응답을 버린다(지금 `_brandsCurrentId` 대조 두 번 — 1235·1250 — 을 그대로). `_brandsCurrentId` 는 계속 같은 뜻으로 채운다(`admin-brand-publish.js`·진입 로더가 읽는다)
  - 탭 전환 `brandDtlSetTab(code)` — code `info`·`contacts`·`sheets`·`camps`. **본문을 다시 그리지 않고 `display` 만**. 캠페인 탭은 처음 누를 때 조회(지금과 같다)
  - 부분 다시 그리기 `brandDtlRedrawSection(name)` — `head`·`contacts`·`sheets`·`camps`·`memo` 중 하나만. 🔴 「바로 처리」 동작 뒤 **페이지 전체를 다시 그리지 않는다**(브랜드 정보 탭의 고치던 값이 사라진다)
  - 🔴 새 화면 입력칸 아이디는 **신규 등록 모달과 다른 접두어**(예 `brandDtlF_…`) — 같은 아이디 둘 문제(의심 4) 차단. 그래도 새 화면을 열 때 `clearBrandModalBody()` 는 지금처럼 부른다
  - 불러오기 상태(a03-93 ①②): 페이지 받는 중(머리 비움) · 실패 「데이터를 불러올 수 없습니다」. 오리엔시트 0건 문구의 「하단」 → 「머리의 「오리엔시트 발급」」(stale 9)
  - storage 감싸개(전부 `_brandAccountEnabled()` 아래, 실패 규약은 기존 둘과 같게 — 조회는 실패 `null`, 쓰기는 `{ok, data|error}`): `saveBrandContact`·`deleteBrandContact`(D1) · `updateBrandInfoAdmin`·`updateCompanyAdmin`(D2) · `changeBrandOwnerAdmin`·`setBrandMemberLimitAdmin`·`releaseBrandAccountAdmin`·`linkBrandOwnerAccountAdmin`·`checkBrandAccountEmailAdmin`(533). 🔴 쓰기 함수는 서버가 `ok:true` 여도 `data.result` 로 갈린다(527·533 계약) — 감싸개는 결과 칸을 그대로 넘긴다
  - 권한 카탈로그 한 줄: `{ key: 'brand.account_manage', label_ko: S0-5 결과, category: '브랜드', server_enforced: true, staging_only: true }` — 화면 단추 판정은 **서버 응답 `can_manage`** 를 쓴다(카탈로그는 권한 관리 화면 표시용)
- **선행 의존:** D1·D2(감싸개가 부를 함수) · S0-1 · S0-7
- **완료 정의:**
  - 빌드 오류 없음 + 루트 `admin/index.html` 에 원본 `<script src="../js/admin-brand-detail.js">` 태그 0개(정규식 누락 확인)
  - 개발서버: 목록·운영 현황·서베이·발급 창·배송 탭 다섯 진입 모두 새 화면이 열리고 「목록」은 늘 브랜드 목록
  - 탭 넷 전환에서 본문이 다시 그려지지 않음(입력칸에 글자를 넣고 탭을 오가도 남음 — 조각 2 전에는 영업 메모 쓰다 만 글로 확인)
  - 오리엔시트 발급 → 그 탭 숫자만 갱신(`osRefreshAfterSheetChange` 경로) · 페이지가 숨어 있을 때 발급하면 돌아올 때 갱신
  - **운영 흉내**(`IS_STAGING=false` 로 바꿔 띄움): 옛 화면이 지금과 같다(머리 「저장」·돌아가기 세 갈래·한 줄 본문) — 운영 경로 무변경 확인
  - 전역 이름 충돌 검사 — 새 함수 접두어가 관리자 빌드 전체에서 0건(단순 이어붙이기라 같은 이름은 뒤의 것이 오류 없이 이긴다)
  - 권한 관리 화면: 개발서버에서만 「브랜드 페이지 계정 관리」 줄이 보인다
- **필요 검문소:** `reverb-reviewer`(전역 이름 · 빌드 두 곳 · 운영 경로 무변경), `reverb-supabase-expert`(storage.js 감싸개)
- **주의·롤백:** 🔴 핫스팟 `storage.js`·`shared.js` 를 만지는 유일한 조각 — 다른 작업의 `storage.js` 병합 요청과 같은 시기에 열지 않는다. 되돌리기 = 판정 함수를 `false` 로(개발서버도 옛 화면) 또는 병합 요청 되돌림.

### 조각 2 — 브랜드 정보 탭
- **하는 일:** 브랜드 정보 탭 본문 — 회사 선택 + 회사 요약(사업자등록번호·청구 이메일) + 「이 정보는 「회사 관리」에 있습니다. 수정」(매니저는 「보기」 — 조각 3이 연결) · **상태(활성/비활성) 칸** · 브랜드명 셋 · 「SNS 정보」(공식 인스타그램·X) · 브랜드 공개 기본 열 자리(조각 9). 세 칸은 그리지 않는다. 값을 고치면 아래에 「저장하지 않은 변경이 있습니다」 줄 + 「되돌리기」·「저장」, 「브랜드 정보」 탭 이름 옆 점. 저장은 D2 함수. 고친 값이 없을 때의 저장 줄 모양은 S0-4.
- **담당 파일:** `dev/js/admin-brand-detail.js`
- **산출 계약:**
  - 기준값 `_brandDtl.saved` — 그린 **직후** 칸 값을 읽어 잡는다(서버 값이 아니라 화면이 채운 값 기준 — 회원 마이페이지 `snapshotMypageForms` 와 같은 방식)
  - `brandDtlIsDirty()` — 「저장한 값 ≠ 지금 칸 값」. 🔴 담당자 줄 저장·계정 동작·영업 메모는 **세지 않는다**(바로 저장되므로 — a03-09). 이 함수 하나를 탭 점·저장 줄·떠날 때 확인(조각 4)이 함께 쓴다(따로 세면 「점은 없는데 묻는」 어긋남)
  - `brandDtlSaveInfo()` — 🔴 보내는 칸은 D2 계약 여덟뿐. **`contacts`·옛 대표 칸·세 칸을 보내지 않는다.** `p_prev` = `_brandDtl.saved`. 결과: `ok` → 기준값 갱신·줄·점 사라짐·머리 이름·상태 배지 새 값·`refreshPane('brands')` · `stale` → a03-10 충돌 확인(Figma 다른 구역 — 「다시 불러오기」·「그대로 두기」 기본) · 실패 → 줄·값 그대로 + 토스트(a03-90a 「브랜드 정보를 저장하지 못했습니다. 잠시 후 다시 시도해 주십시오.」) · `forbidden` → 「권한이 바뀌어 저장할 수 없습니다. 페이지를 새로고침해 주십시오.」(초안)
  - `brandDtlRevert()` — S0-4 결과대로
  - 매니저 보기(a03-00e): 브랜드 정보 칸은 매니저도 고치고 저장(지금과 같다) · 「병합」·「삭제」 없음
- **선행 의존:** 1 · D2 · S0-4
- **완료 정의:**
  - 🔴 **세 칸 덮어쓰기 함정** — 운영 데이터 건수 측정(읽기만, 운영 SQL 편집기 — 끝나면 탭을 닫는다 `browser-qa.md`): `SELECT count(*) FILTER (WHERE description IS NOT NULL OR appeal_points IS NOT NULL OR official_qoo10_url IS NOT NULL) FROM public.brands;` 결과를 사양서 「구현 결과」에. 개발서버에서 세 칸 값이 든 시험 브랜드를 새 화면으로 저장한 뒤 세 칸 값이 그대로인지 SQL 조회
  - 🔴 **담당자 되돌림 함정** — 새 화면을 연 채 다른 탭에서 대표 바꾸기(조각 8 전이면 콘솔로 `admin_change_brand_owner` 호출) → 새 화면 「저장」 → `contacts` 대표 표시가 새 대표 그대로
  - 저장 성공 토스트 「브랜드 정보를 저장했습니다.」 · 실패 시 고치던 값이 남음(연결을 끊어 확인)
  - 다른 탭으로 옮겨도 고치던 값·점 유지 · 되돌리기 뒤 점 사라짐
  - 매니저 계정으로(사용자에게 로그인 부탁) 「병합」·「삭제」 없음, 저장은 됨
- **필요 검문소:** `reverb-reviewer`(보내는 칸 목록 · `refreshPane` 의무 · 같은 아이디 둘 아님)
- **주의·롤백:** 화면 파일만(개발서버 판정 아래).

### 조각 3 — 회사 정보 수정·보기 모달 연결 (a03-07·07a·07b — Figma 다른 구역 확인 필요)
- **하는 일:** 「수정」/「보기」가 지금 「회사 관리」 화면의 회사 모달을 브랜드 상세 위에 띄운다. 🔴 모달이 **목록 보관값이 아니라 넘겨받은 회사 정보로** 열리게 고친다. 맨 위 「이 회사에 속한 브랜드 N개에 함께 바뀝니다」(S0-9 기준). 회사 선택 칸에서 회사를 바꾸고 아직 저장하지 않았으면 **새로 고른 회사**를 연다. 저장하면 모달이 닫히고 회사 요약·회사 선택 칸 이름만 새 값 — **탭의 고치던 브랜드 값은 그대로**.
- **담당 파일:** `dev/js/admin-company.js` · `dev/js/admin-brand-detail.js`
- **산출 계약:**
  - `openCompanyModal(id, {company, onSaved, brandCount})` — `opts.company` 가 있으면 그 값으로 칸을 채운다(없으면 지금처럼 `_companiesCache`). 제목은 `id` 유무로 정하고 `company` 를 못 찾으면 **열지 않고** 「회사 정보를 불러올 수 없습니다」(빈 폼 + 대상 아이디 조합 자체를 없앤다). 이 고침은 회사 관리 화면에도 무해하다(인자 없으면 지금과 같다)
  - 개발서버 `saveCompany` → D2 `admin_update_company`(`p_prev` = 모달을 연 시점 값) · 운영은 지금 `upsertCompany` 그대로. `stale`·`duplicate_name`(a03-07a)·실패는 모달·값 유지 + 토스트
  - 저장 뒤 브랜드 상세: `_brandFormCompanies` 의 그 회사 갱신 → 회사 선택 칸 다시 만들기(🔴 지금 `_rebuildBrandCompanySelect` 는 보관 회사를 빼고 다시 그려 **보관 회사에 연결된 브랜드의 선택이 빠진다** — 새 화면은 보관 회사를 「(보관됨)」으로 남기는 지금 첫 그리기 규칙(1686~1689)을 따른다) → 요약 카드만 다시 그리기. 「회사 정보를 저장했습니다.」
  - 콜백 모드 모달 겹침 순서는 지금 규칙(z-index 620)
- **선행 의존:** 2 · D2 · S0-9
- **완료 정의:**
  - 🔴 **빈 값 덮어쓰기 함정** — 새로고침 직후(회사 관리 화면을 한 번도 안 연 상태) 브랜드 상세 → 「수정」 → 칸이 그 회사 값으로 차 있고 제목 「회사 수정」 · 아무것도 안 고치고 저장 → 회사 표 값 무변화(SQL 조회)
  - 매니저 「보기」도 값이 차 있음(지금은 빈 칸 — 같은 원인)
  - 회사 선택을 바꾼 뒤 「수정」 → 새로 고른 회사가 열림
  - 회사 관리 화면에서 행을 눌러 여는 기존 동작 무변경(운영 경로)
  - 회사명 변경 뒤 같은 회사 다른 브랜드의 `company_name` 사본이 맞춰짐
- **필요 검문소:** `reverb-reviewer`(회사 관리 화면 회귀 · `refreshPane('companies')` 는 콜백 모드에서도 부를지)
- **주의·롤백:** `admin-company.js` 는 회사 관리 화면(운영)도 쓰는 파일 — 바꾸는 것은 인자 하나 추가 + 「못 찾으면 안 연다」뿐인지 리뷰에서 본다.

### 조각 4 — 떠날 때 확인 모달 + 이탈 경로 전수 (a03-09)
- **하는 일:** 저장 안 한 변경(`brandDtlIsDirty()`)이 있을 때 페이지를 떠나는 **모든 길**에서 확인 모달을 띄운다. 다른 탭으로 옮기는 것은 떠나는 것이 아니다. 모달은 **동적 생성**(`quality.md` — 핫스팟 `admin/index.html` 을 안 만진다), 단추는 S0-4 결과대로. ESC = 머물기.
- **담당 파일:** `dev/js/admin-brand-detail.js` · `dev/admin/app.js`(`navAdminPaneReload` 한 줄) · `dev/js/admin-brand.js`(옛 이탈 함수 첫 줄 — 조각 1이 깐 자리) · `dev/js/admin-orient.js`(「이 카드로 발행」 한 자리) · `dev/js/admin-privacy-logs.js`(`openPrivacyLogs` 진입 — 필요하면)
- **산출 계약:**
  - `brandDtlLeaveGuard(go)` — 새 화면이 보이고 변경이 있으면 모달, 아니면 `go()`. 🔴 게이트를 `switchAdminPane` 에 두지 않는다(저장 뒤 복귀·권한 되돌림이 그 함수를 지난다 — `admin/app.js` 72~76 주석의 이유 그대로)
  - 걸 자리(전수 — 의심 1): ①사이드바 — `navAdminPaneReload` 에서 `campLeaveGuard(go)` 를 `campLeaveGuard(() => brandDtlLeaveGuard(go))` 로(동시에 보이는 편집 폼은 하나뿐) ②「목록」 ③캠페인 탭 배지(옛 `confirm` + `closeBrandDetailModal()` 대신 — 🔴 `_brandsCurrentId` 를 비우지 않는다) ④오리엔시트 상세 「이 카드로 발행」(브랜드 상세에서 열렸을 때 — 발행 창은 오리엔시트 상세를 먼저 닫고 묻는다, 창 겹침 순서) ⑤「제공 기록」 ⑥다른 브랜드 상세 열기(S0-4) ⑦신규 등록 모달(`openNewBrandModal` 이 페이지 본문을 비운다 — 브랜드 상세에서 그 모달을 여는 길이 있는지 먼저 세고, 있으면 게이트)
  - 탭 닫기·새로고침(S0-4) — 쓰기로 하면 변경이 있을 때만 브라우저 기본 경고(`beforeunload`), 새 화면을 떠나면 해제
  - 브라우저 뒤로가기(S0-6)
- **선행 의존:** 2 · S0-4 · S0-6
- **완료 정의:** 걸 자리 일곱을 하나씩 실제로 눌러(마우스로 — `browser-qa.md`) 모달이 뜨고, 「머물기」면 값·탭 유지, 「저장하지 않고 나가기」면 누른 곳으로 · 변경이 없으면 묻지 않음 · 저장 성공 뒤 사이드바 → 묻지 않음 · 캠페인 폼의 기존 확인(`campLeaveModal`)이 그대로 동작(회귀) · 운영 흉내에서 옛 화면은 묻지 않음(지금과 같다)
- **필요 검문소:** `reverb-reviewer`(이탈 자리 전수를 **지목해서** 확인시킨다 — 글자 검색 `switchAdminPane(`·`openBrandDetail(`·`openPrivacyLogs(`·`openCampApplicants(` 로 브랜드 상세에서 닿는 자리)
- **주의·롤백:** 🔴 `dev/admin/app.js` 는 핫스팟 — 한 줄만 바꾸고, 다른 작업과 같은 시기에 열지 않는다. 판정이 틀리면 「저장했는데 묻는」 모습 — 저장 성공에서 기준값 갱신이 먼저인지 본다.

### 조각 5 — 담당자 목록 + 담당자 추가·수정 모달 + 삭제 (a03-08·08a·08b·08c — Figma 다른 구역 확인 필요)
- **하는 일:** 담당자·계정 탭의 담당자 줄(이름·연락처·이메일·대표 표시) 표와 「+ 담당자 추가」·줄의 「수정」·「삭제」. 모달의 「저장」이 **그 줄만 바로** 저장(D1). 모달에 「여기서 이메일을 고쳐도 브랜드 페이지 로그인 이메일은 바뀌지 않습니다」 안내. 대표 계정이 있으면 대표 줄은 이메일 칸·대표 표시 잠금, 삭제 단추 없음(이름·연락처만). 대표 계정이 있는데 다른 줄에 「대표 담당자로 표시」를 켜면 저장 대신 조각 8의 대표 바꾸기 확인(a03-02)으로 넘기고, 그 줄이 멤버 계정이 아니면 막는 안내 하나(16-4 「화면 정책 넷」 ② 두 문구 — 대표 계정 상태로 고른다). 담당자 0명 상태(a03-93 ③).
- **담당 파일:** `dev/js/admin-brand-contacts.js`
- **산출 계약:**
  - `brandDtlRenderContacts()` — 표만 다시 그린다 · `brandDtlOpenContactModal(contactId?)` — 동적 모달 · 저장 `p_prev` = 모달을 연 시점 그 줄
  - 결과 처리: `ok` → 표 갱신 + 「담당자를 저장했습니다.」/「담당자를 삭제했습니다.」 + **브랜드 정보 탭 기준값은 건드리지 않는다**(담당자는 그 탭 판정 밖) · `stale` → 「다른 곳에서 바뀌었습니다」 + 표 다시 받기 · `primary_locked`·`use_change_owner` → 안내(안전망 — 화면이 미리 막아야 한다) · 입력 오류(a03-08b) · 실패(a03-08c) 모달·값 유지
  - 대표 계정 유무는 조각 6 전에는 `admin_get_brand_account_status` 를 한 번 받아 판단(조각 6이 같은 값을 공유하게 `_brandDtl.account` 에 둔다)
  - 「수정」은 담당자 정보가 있는 줄에만(계정만 있는 멤버 줄에는 없음 — 조각 6)
- **선행 의존:** 1 · D1 · S0-5
- **완료 정의:** 추가·수정·삭제가 그 줄만 저장(다른 줄·브랜드 정보 탭 고치던 값 무변화) · 계정 있는 브랜드의 대표 줄 이메일 칸 잠김(매니저·관리자 모두) · 관리자 두 창에서 같은 줄을 고치면 늦은 쪽 `stale` · 대표 없는 브랜드는 대표 표시를 자유롭게 옮김 · 목록 「대표 담당자」 열이 갱신(`refreshPane('brands')`)
- **필요 검문소:** `reverb-reviewer`(입력값 `esc()` · 모달 저장 뒤 갱신)
- **주의·롤백:** 화면 파일만.

### 조각 6 — 계정 줄 표시 (a03-91 다섯 · a03-92 멤버 줄 · 머리 요약 — Figma 다른 구역 확인 필요)
- **하는 일:** 담당자 표에 계정 줄을 함께 그린다(묶는 기준은 S0-5) — 대표 담당자 줄 상태 다섯(ⓐ계정 없음 · ⓑ미발송 · ⓒ설정 메일 보냄 + 보낸 시각 + 「~까지 유효(예상)」 · ⓓ링크 만료·설정 안 함(주황) · ⓔ설정 완료(초록) + 설정 시각), 「(본인 요청)」(`setup_mail_sent_by='self'`), 사용 중 멤버 줄, 계정 줄 「마지막 접속」(대표 줄은 설정 완료일 때만). 카드 머리·페이지 머리 요약 「멤버 n / m명 · 초대 대기 k 포함」(초대 줄은 그리지 않는다 — 16-5 11번). 이 조각은 **표시만**, 단추 자리만 잡는다. 조회 실패는 「확인 불가」 + 「다시 불러오기」, 「계정 만들기」를 그리지 않는다(a03-93 ④).
- **담당 파일:** `dev/js/admin-brand-contacts.js` · `dev/js/admin-brand-detail.js`(머리 요약 자리)
- **산출 계약:**
  - `brandDtlLoadAccount()` → `_brandDtl.account` — 🔴 실패 `null` 과 계정 없음 `{status:'none'}` 을 가른다(527 계약)
  - 만료 추정 = 마지막 발송 시각 + 24시간 지남 + 설정 완료 시각 없음 — 화면 계산은 이 한 곳(시각 비교는 서버 응답 값으로)
  - n·m·k 는 서버 값 그대로(`seat_used`·`member_limit`·`pending_invite_count` — 뜻이 다르다, §16 머리 정의). 화면이 세지 않는다
  - 상태 이름 다섯을 상수 한 곳에 두고, 발급 창 경고(`admin-orient.js`, 16-5 8번)가 같은 이름을 쓰는지 대조
- **선행 의존:** 5
- **완료 정의:** 시험 브랜드 다섯 상태(S0-11) 각각 화면 확인 · 매니저에게도 상태 표시는 보이고 단추 자리는 없음 · 상태 조회를 일부러 실패시키면(연결 끊기) 「확인 불가」 · 대표 해제 뒤 ⓐ로 · 「~까지 유효(예상)」 문구는 개발서버만이고 운영은 출시 관문 7번(인증 설정 24시간) 뒤라는 것을 사양서 「구현 결과」에 적음
- **필요 검문소:** `reverb-reviewer`
- **주의·롤백:** 「마지막 접속」은 이용 기록(의심 9) — 운영 관문 10번 판단 목록에 이미 있음을 확인.

### 조각 7 — 계정 만들기·다시 보내기 + 임시 구현 걷기 (a03-01·01a·01b·01c · a03-90 — Figma 다른 구역 확인 필요)
- **하는 일:** ⓐ계정 없음 줄의 「계정 만들기」 → 받을 이메일을 크게 보이는 확인 모달(a03-01) → 겹침 확인(`admin_check_brand_account_email`): 인플루언서·관리자 이메일이면 「이미 다른 용도로 쓰는 이메일입니다」(a03-01a, 안 만듦) · 다른 브랜드 계정이면 겹침 확인 창(a03-01c — S0-3 결과대로 「연결」 처리) · 없으면 `admin_upsert_brand_owner_account` → 메일(`sendBrandAccountSetupMail(…,'setup')`) → ⓑ/ⓒ. 서버 오류면 모달 유지 + 「다시 보내기」(a03-01b). ⓑ~ⓓ 줄 「다시 보내기」 → 바로 발송 + 토스트. 그리고 **임시 구현을 걷는다**: 저장·신규 등록 뒤 자동 계정 생성(`_brandAccountAfterBrandSave`)을 개발서버에서도 부르지 않게(새 화면은 이미 안 부른다 — 남은 것은 신규 등록 모달, S0-8), 「계정 메일은 캠페인 관리자 이상이 보냅니다」 회색 단추 없앰(권한 없으면 단추가 안 보인다 — `can_manage`).
- **담당 파일:** `dev/js/admin-brand-contacts.js` · `dev/js/admin-brand.js`(`submitNewBrand` 의 자동 계정 호출 한 줄 · S0-8 결과대로 신규 등록 모달 세 칸)
- **산출 계약:**
  - 「계정 만들기」는 **저장된** 대표 줄 기준(지금 `brandAccountSendMail` 2660 의 「고친 뒤 저장 안 함」 검사는 담당자가 줄마다 바로 저장되므로 필요 없다 — 대표 줄 이메일이 없거나 대표 표시 줄이 없을 때의 처리는 S0-5)
  - 동시에 두 관리자가 누르면 늦은 쪽은 서버가 막는다(533 브랜드 잠금) → 「이 브랜드에는 이미 대표 담당자가 있습니다」
  - 개발서버 「메일 대신 링크」 표시(지금 `_brandAccountDevLinks`)는 새 화면에도 둔다(두 겹 잠금은 서버 몫 — `brand-account.md`)
  - 결과 문구 표(지금 `_brandAccountMailOutcome`·`_brandAccountRunUpsert` 2526~2618)를 새 파일로 옮기되 「저장」 맥락 문구(「브랜드는 저장됐지만…」)는 뺀다
- **선행 의존:** 6 · S0-3 · S0-8
- **완료 정의:** 대표 없는 시험 브랜드에서 「계정 만들기」 → 확인 모달에 받을 이메일 → 만들기 → 개발서버 링크 표시 → ⓑ 또는 ⓒ · 인플루언서 이메일로 시도 → 안 만듦 · **신규 브랜드를 대표 담당자와 함께 등록해도 계정이 생기지 않음**(`brand_accounts` 조회 0건) · 새 화면 「저장」으로 대표 줄 이메일을 바꿔도(계정 없을 때) 메일이 안 나감 · 매니저에게 단추가 안 보임
- **필요 검문소:** `reverb-reviewer`, (메일 함수 응답 처리 변경이 있으면) `reverb-supabase-expert`
- **주의·롤백:** 실제 메일 발송 시험은 하지 않는다(개발서버 두 겹 잠금으로 링크만 — `supabase.md` 「메일 발송 테스트 환경 정책」).

### 조각 8 — 대표 바꾸기·해제·멤버 상한·(브랜드 연결 추가) (a03-02·02a·02b · 03·03a · 05·05a·05b · 04·04a — Figma 다른 구역 확인 필요)
- **하는 일:** ⓔ설정 완료 대표 줄의 「대표 담당자 바꾸기」 → 멤버 중 한 명을 고르는 모달(a03-02, 멤버 0명이면 「먼저 해제」 a03-02a, 다른 관리자가 먼저 바꿨으면 a03-02b) → `admin_change_brand_owner(brand, 새 대표, 연 시점 대표)`. 조각 5 담당자 모달의 「대표 표시를 다른 줄로」도 여기로 이어진다. 「해제」(대표·멤버 줄, ⓑ~ⓔ) → 확인 모달(a03-05 — 대표 해제면 함께 취소될 초대 건수 `release_cancel_count` 를 보인다) → `admin_release_brand_account` · 멤버가 있는 대표면 a03-05b 「먼저 대표 담당자 바꾸기」(S0-5). 「멤버 상한 바꾸기」 → 1~50 정수 모달(a03-03, 지금 인원보다 작아도 받음, 입력 오류 a03-03a). ⓐ줄의 「브랜드 연결 추가」(a03-04) — S0-3 결과대로.
- **담당 파일:** `dev/js/admin-brand-contacts.js`
- **산출 계약:** 동작이 끝나면 `brandDtlLoadAccount()` + 표 + 머리 요약만 다시 그린다(🔴 페이지 전체 아님). 대표 바꾸기·연결 뒤 서버가 담당자 대표 표시를 옮기므로 **담당자 표도 다시 받는다**(16-4 「화면 표시를 맞추는 일」) — 브랜드 정보 탭 기준값은 안 건드린다. 해제는 「이 브랜드만 끊김」 안내
- **선행 의존:** 7 · S0-3 · S0-5
- **완료 정의:** 시험 브랜드(멤버 2명)에서 대표 바꾸기 → 옛 대표 멤버로 · 담당자 대표 표시·목록 「대표 담당자」 열이 새 사람 · 두 창에서 동시에 바꾸면 늦은 쪽 a03-02b · 멤버 있는 대표 해제 → 막힘 · 멤버 해제 → 그 줄 사라짐 · 대표 해제(멤버 0) → ⓐ + 대기 초대 취소 건수 일치(SQL) · 상한 0·51 거부, 3 저장 · 매니저 계정에서 단추 없음(서버도 `forbidden` — 콘솔 호출로 확인)
- **필요 검문소:** `reverb-reviewer`
- **주의·롤백:** 해제는 되돌릴 수 없다(연결 이력은 남는다 · 해제 이력이 있으면 브랜드 삭제가 막힌다 — 528) → 확인 모달에 「이 브랜드에서만 끊깁니다 · 다시 이으려면 계정 만들기(겹침 확인)」를 적는다.

### 조각 9 — 브랜드 공개 기본 열 칸 통합
- **하는 일:** 브랜드 정보 탭 SNS 정보 아래에 「브랜드 공개 기본 열」 칸(「전체 기본값 따르기」 / 「이 브랜드만 따로 정하기」 + 열 고르기 — 지금 `brandPublishDefaultPickerHtml` 그대로). S0-2 가 「합친다」면: 탭 「저장」이 브랜드 정보(D2)와 기본 열(544)을 **차례로** 부르고, 기본 열 칸 변경도 `brandDtlIsDirty()` 에 넣는다. `report.share` 쓰기가 아닌 관리자에게는 읽기 전용이고 **그 관리자의 저장은 이 칸을 보내지 않는다**. 한쪽만 성공하면 성공한 쪽은 기준값 갱신, 실패한 쪽은 줄·값 유지 + 「기본 열은 저장하지 못했습니다」. S0-2 가 「지금처럼」이면: 자리만 탭 안으로 옮기고 자기 단추 유지, 판정에서 뺀다.
- **담당 파일:** `dev/js/admin-brand-detail.js` · `dev/js/admin-brand-publish.js`(`renderBrandPublishDefaultBox` 에 「단추 없이 그리기」 인자 · 값 읽기 함수)
- **선행 의존:** 2 · S0-2
- **완료 정의:** 권한 있는 관리자 — 칸만 바꿔도 점·저장 줄 · 저장 뒤 `admin_get_brand_publish_defaults` 값 일치 · 그 브랜드 캠페인에서 공개를 처음 켤 때 미리 체크됨 · 권한 없는 매니저 — 칸 회색, 브랜드명만 고쳐 저장해도 기본 열 무변화 · 기본 열 저장만 일부러 실패시키면 안내 문구
- **필요 검문소:** `reverb-reviewer`
- **주의·롤백:** S0-2 결과에 따라 `brand-account.md` 「자기 단추로만」 문장 정정을 고문에게 넘긴다.

### 조각 10 — 문서 + 개발서버 처음부터 끝까지 확인 + 출시 목록
- **하는 일:** 사양서 `2026-07-15-brand-portal.md` 맨 아래 「구현 결과」(실제 마이그레이션 번호 · 바뀐 판단 · 세 칸 운영 건수) · 「운영 반영 전 남은 관문」에 D1·D2 적용 자리(536 뒤)와 「출시 때 걷을 자리」 목록 · `docs/FEATURE_SPEC.md` · `CLAUDE.md`(「관리자 화면이 브랜드가 고친 값을 되돌린다」·「`brands.contacts` 통째 저장」 경고를 「개발서버는 막힘 · 운영은 출시 때」로 · 새 원본 번호) · 옛 사양서 `2026-09-23-brand-detail-pane.md` 머리에 「16-4 가 대체」 한 줄 · 개발서버 처음부터 끝까지(진입 다섯 → 탭 넷 → 브랜드 정보 저장 → 회사 수정 → 담당자 추가 → 계정 만들기 → 대표 바꾸기 → 해제 → 떠날 때 확인 일곱 자리)
- **넘길 것:** 규칙 파일(`brand-account.md`·`brand-admin.md` 「브랜드 상세 모달 — 오리엔시트 / 캠페인 탭」 절)은 고문에게 · Figma 꼬리표·저장소 참고 정정·사양서 16-5 6번 문장은 기획에게 · 노션 「관리자 가이드」 브랜드 관리 페이지는 출시(운영 배포) 뒤
- **선행 의존:** 1~9 · D1 · D2
- **완료 정의:** `reverb-reviewer` 전체 · 사용자 승인 뒤에만 `reverb-qa-tester`(다른 세션이 크롬을 안 쓸 때 단일 세션)

---

## ⚠️ 공유 지점 경고 (충돌 주의)

- **`brands.contacts` 를 쓰는 길(전수)** — 옛 관리자 저장(`saveBrandDetail`, 운영 화면 · 개발서버 신규 등록 모달) · 새 담당자 한 줄 저장(D1) · 531 `_brand_contacts_mark_primary`(대표 넘기기·바꾸기·연결) · `merge_brands`(528) · 광고주 신청 함수(397, 처음 보는 브랜드 생성 때). D1 트리거는 **이 모두**에 걸린다 — D1 완료 정의에서 하나씩 돌린다.
- **`renderBrandDetailFormHtml`·`_collectBrandFormPatch`** — 신규 등록 모달과 공유. 새 화면은 쓰지 않는다. 출시 청소 때 지우면 신규 등록 모달이 죽는다(출시 목록 1).
- **`openCompanyModal`** — 회사 관리 화면(운영)과 공유. 조각 3의 인자 추가가 회사 관리 화면을 바꾸지 않는지 리뷰.
- **`campLeaveGuard`·`navAdminPaneReload`** — 캠페인 폼·정산과 공유. 조각 4는 감싸기만.
- **갱신 장치 셋**(`PANE_REFRESHERS['brand-detail']` · 진입 로더 · `osRefreshAfterSheetChange`) — 옛 함수 이름을 부른다. 조각 1의 첫 줄 위임이 있어 새 화면에 닿는다 — 옛 함수 이름을 바꾸면 끊긴다.
- **`_brandsCurrentId`** — `admin-brand-publish.js`·진입 로더·오리엔시트가 읽는다. 새 화면도 같은 뜻으로 채운다.
- **계정 상태 이름** — 관리자 상세(조각 6)와 오리엔시트 발급 경고(16-5 8번, `admin-orient.js`)가 같은 상태를 말한다.
- **숫자 정의** — 브랜드 화면 「n / m명」(`seat_used`) · 관리자 「초대 대기 k 포함」(`pending_invite_count`) · 해제 취소 건수(`release_cancel_count`)는 뜻이 다르다(§16 머리 정의). 서버 값을 그대로 그린다.

### 개발자 두 명 겹침 (`two-developers.md`)

| 파일 | 이 작업에서 만지는 조각 | 겹침 위험 |
|---|---|---|
| `dev/js/admin-brand.js` | 1(첫 줄 넷) · 4(이탈 첫 줄) · 7(신규 등록 한 줄) | 브랜드 서베이·운영 현황 연결 작업과 같은 파일 — 착수 전 상대에게 알린다 |
| `dev/lib/storage.js`(핫스팟) | **1만** | 다른 `storage.js` 작업과 같은 시기 병합 금지 · 짧게 끊어 빨리 병합 |
| `dev/lib/shared.js`(핫스팟) | **1만**(카탈로그 한 줄) | 권한 카탈로그를 고치는 다른 작업과 알림 |
| `dev/admin/app.js`(핫스팟) | **4만**(한 줄) | 부팅·라우팅 작업과 겹치지 않게 |
| `dev/admin/index.html` | 1(원본 `<script>` 두 줄) | 모달은 동적 생성이라 그 밖은 안 만진다 |
| `dev/build.sh` | 1 | 새 파일 등록 두 곳 |
| `dev/js/admin-company.js` | 3 | 회사 관리 화면 작업과 알림 |
| `dev/js/admin-orient.js` | 4(한 자리) | 오리엔시트 작업과 알림 |
| `dev/js/admin-brand-publish.js` | 9 | 브랜드 공개 작업과 알림 |
| 새 마이그레이션 둘 | D1·D2 | 번호는 만들기 직전 · `brands`·531·533 재정의 작업이 상대에게 있는지 먼저(S0-12) |

---

## 🧭 배분 제안

- **한 명 순차가 기본** — D1 → D2 → 1 → 2 → 3 → 4 → 9 → 5 → 6 → 7 → 8 → 10.
- **두 명이면** 조각 1 병합 뒤: 개발자 갑 = 「2 → 3 → 4 → 9」(`admin-brand-detail.js`·`admin-company.js`·`admin/app.js`) · 개발자 을 = 「5 → 6 → 7 → 8」(`admin-brand-contacts.js`). 두 줄기는 파일이 갈린다. 겹치는 곳은 `_brandDtl` 상태 객체 계약과 `brandDtlRedrawSection` 하나 — 조각 1에서 고정하고 바꿀 때는 상대에게 알린다. `admin-brand.js` 는 조각 4(갑)·7(을)이 한 줄씩 — 같은 날 병합하지 않는다.
- 데이터베이스 D1·D2 는 같은 개발자가 이어서(번호 충돌 방지).

---

## 사용자 확인 필요

> 결정 결과는 아래 「결정 기록」에 날짜와 함께 적는다.

1. 운영과 개발서버 화면을 가르는 방식(S0-1) — 추천: 새 파일로 분리
2. 브랜드 공개 기본 열을 탭 「저장」으로 합칠지(S0-2) — 추천: 합침
3. 「브랜드 연결 추가」·겹침 확인 창 「연결」(S0-3) — 추천: 이번엔 숨기고 별도 작업표
4. 「되돌리기」 범위(S0-4) — 추천: 탭 칸 전부를 저장값으로
5. 떠날 때 확인 모달 단추(S0-4) — 추천: 머물기·저장하지 않고 나가기 둘
6. 탭 닫기·새로고침 경고(S0-4) — 추천: 변경 있을 때만
7. 브라우저 뒤로가기(S0-6) — 추천: 이번 범위 밖(한계로 기록)
8. 고치던 중 다른 브랜드 상세 열기(S0-4) — 추천: 같은 확인 모달
9. 마지막 탭 기억(S0-4) — 추천: 기억 안 함
10. 담당자 줄·계정 줄 묶기(S0-5) — 추천: 이메일 같으면 한 줄
11. 멤버 있는 대표 줄 「해제」(S0-5) — 추천: 보이고 누르면 안내
12. 대표 이메일 없을 때 「계정 만들기」(S0-5) — 추천: 단추 대신 안내
13. 대표 없는 브랜드 멤버 수(S0-5) — 추천: 서버 값 그대로
14. 권한 항목 이름(S0-5) — 추천: 「브랜드 페이지 계정 관리」
15. 머리 「삭제」(S0-7) — 추천: 유지
16. 매니저에게 「오리엔시트 발급」(S0-7) — 추천: 보임
17. 개발서버 신규 등록 창(S0-8) — 추천: 세 칸 빼고 자동 계정 걷기
18. 회사 모달 브랜드 수 기준(S0-9) — 추천: 활성 브랜드만
19. 관리자 저장 충돌(D2) — 추천: 충돌 확인 창
20. 고친 값 없을 때 저장 줄(조각 2) — 추천: 숨김

### 결정 기록
- 2026-10-21 (사용자) **S0-1 — 새 파일로 분리.** 새 화면은 `dev` 에 넣되 새 파일 둘에 두고, 옛 진입 함수 첫 줄에서 개발서버일 때만 넘긴다. 「dev 브랜치에서만 개발하면 되지 않나」는 질문에 — `dev → main` 병합이 dev 전체를 싣기 때문에 코드 안 판정이 필요하다고 설명한 뒤 결정
- 2026-10-21 (사용자) **S0-2 — 탭 저장으로 합침.** 브랜드 공개 기본 열을 브랜드 정보 탭 「저장」 하나로 함께 저장(조각 9 「합침」 갈래)
- 2026-10-21 (사용자) **S0-3 — 연결 요청을 이 작업표에 추가.** 사양서 16-8 1번(본인 24시간 안 수락)의 서버·메일·브랜드 화면 수락까지 이번 작업에서 만든다 → 아래 「추가 조각 — 연결 요청」을 설계해 넣는다(미작성 — 다음 단계)
- 2026-10-21 (사용자) **4~20번 — 추천안 일괄 적용.** 되돌리기 = 탭 칸 전부를 저장값으로 · 떠날 때 확인 단추 둘(「머물기」·「저장하지 않고 나가기」) · 탭 닫기·새로고침은 변경 있을 때만 브라우저 경고 · 뒤로가기는 이번 범위 밖(한계로 기록) · 다른 브랜드 열기도 같은 확인 모달 · 탭 기억 안 함 · 담당자·계정 줄은 이메일(공백·대소문자 무시)이 같으면 한 줄 · 멤버 있는 대표 「해제」는 보이고 누르면 「먼저 대표 바꾸기」 안내 · 대표 이메일 없으면 「계정 만들기」 대신 안내 · 멤버 수는 서버 값 그대로 · 권한 이름 「브랜드 페이지 계정 관리」(분류 「브랜드」) · 머리 「삭제」 유지 · 매니저에게 「오리엔시트 발급」 보임 · 개발서버 신규 등록 창은 세 칸 빼고 자동 계정 걷기 · 회사 창 브랜드 수는 활성 브랜드만 · 저장 충돌은 충돌 확인 창(a03-10) · 고친 값 없으면 저장 줄 숨김

---

## 🔁 인계 — 연결 요청 조각 설계 (2026-10-21, 미완)

> S0-3 「이 작업표에 추가」 결정에 따라 붙일 「연결 요청」 조각(D3·D4…/11·12…)을 **다음 세션이 설계**한다. 아래는 이번 세션에서 코드로 확인한 사실과 잠정 권고다. 권고는 검증 전이다.

### 확인한 사실(코드 기준)
1. **지금 서버는 수락 없이 바로 잇는다** — `admin_link_brand_owner_account`(533, 933~1011행): 대표 없는 브랜드에 기존 브랜드 계정을 대표로 즉시 넣는다(이미 멤버면 `_brand_transfer_owner` 로 올림) + `_brand_contacts_mark_primary`. 결과값 `ok|forbidden|owner_exists|not_brand_account|brand_archived|brand_not_found|invalid_email`. 잠금 순서 브랜드(`brand_account_upsert:`) → 이메일(`brand_account_email:`). 메일은 화면이 `notify-brand-account-setup` 을 `mail_kind:'link'` 로 따로 부른다(비밀번호 정한 계정이면 `link_notice`, 아니면 설정 메일). 운영에는 없다(533 개발서버만).
2. **기존 초대 장치는 「멤버 초대」 전용이다** — 표 `brand_invites`(530, 167~209행): `status`(pending·accepted·declined·cancelled — 만료는 「대기 + `expires_at` 지남」) · `recipient_kind`(new·brand·blocked) · `sent_owner_auth_id` · `link_id` · `invited_by`·`inviter_name`(NOT NULL). 같은 브랜드·이메일 대기 초대는 하나(`brand_invites_one_pending_per_email`). 읽는 함수: 530 `_brand_seat_usage`·`_brand_invite_acceptable` / 531 `_brand_invite_reissue`·`create_brand_invite`·`resend_brand_invite`·`cancel_brand_invite`·`hide_brand_invite`·`get_brand_members`(826행) / 532 `_brand_acceptable_invites_for`·`get_brand_invite_link_state`·`respond_brand_invite`·`get_my_brand_invites`·`service_brand_invite_create_account`·`service_brand_invite_finalize` / 533 `admin_get_brand_account_status`(704·706행 대기 숫자)·`admin_release_brand_account`(909행) / 534 링크 판정 현재 원본. 🔴 수락 `respond_brand_invite`(532, 614~688행)는 연결을 `'member'` 로 넣는다(680행), 비밀번호 미설정은 `setup_incomplete` 거부. 메일 `notify-brand-invite`(new·existing·blocked)·`brand-invite-accept` 는 멤버 전제.
3. **사양서 16-8 1번 요구** — 관리자가 잇는 길 셋(「브랜드 연결 추가」 a03-04 · 겹침 창 「연결」 a03-01c · 대표 이메일을 다른 브랜드 계정 이메일로 바꿔 저장)이 모두 「연결 요청」. 메일 bw01-98 하나. 본인이 메일 링크나 마이페이지 「받은 초대」(bw07-00c)에서 수락·거절, 기한 24시간. 비밀번호 미설정 계정은 링크에서 비밀번호를 정하며 바로 수락(bw01-02b 모양). 대표 표시는 수락한 때 바뀐다(bw01-96c 대체, 16-5 18번 닫음). Figma 흐름도: 「연결 요청 보냄(a03-91a)」 · 「이미 대표가 있음 → 토스트」 · 「브랜드 계정이 아닌 이메일 → a03-04a」.

### 잠정 권고(검증 전)
- 저장은 새 표보다 **`brand_invites` 확장**(종류 칸: 멤버 초대 / 대표 연결 요청) — 로그인 판정·빨간 점·받은 초대·비밀번호 찾기 넓히기·링크 판정이 이 표 하나를 본다. 대신 위 함수를 **종류별로 하나씩 대조**: ①수락 때 `owner` 로·수락 순간 대표가 있으면 거부·담당자 대표 표시 이동 ②대표의 멤버 목록·관리자 「초대 대기 N」에서 뺄지 ③자리 계산 포함 여부 ④`invited_by`·`inviter_name` 에 관리자를 어떻게(「REVERB 운영팀」?) ⑤비밀번호 미설정 수락 경로 ⑥관리자 취소 함수 필요 여부(16-5 11번 「관리자는 초대를 대신 취소하지 않는다」 — 사용자 확인)
- 533 즉시 연결 함수는 운영에 없으니 지우거나 요청 생성 함수로 바꾼다 → 조각 7(겹침 창 「연결」)·8(「브랜드 연결 추가」) 산출 계약도 바뀐다
- 메일은 `notify-brand-invite` 에 연결 요청 양식(bw01-98)을 더하는 쪽 먼저 검토(두 겹 잠금 공유). `notify-brand-account-setup` 의 `mail_kind:'link'` 갈래는 걷는 대상

### 아직 확인 못 한 것
- 사양서 16-8 1번 주변 전부 · 16-3 1번·5번·11번 · 약관 초안 `docs/specs/2026-10-19-brand-terms-draft.md` 제5조
- `supabase/functions/brand-invite-accept/index.ts`·`notify-brand-invite/index.ts` 본문
- 532 `service_brand_invite_create_account`·`service_brand_invite_finalize`·`get_my_brand_login_state` 대기 초대 판정 · 531 `get_brand_members`
- 브랜드 화면 초대 착지(`dev/js/brand-invite.js`·`brand-app.js`)
- 「대표 이메일을 바꿔 저장」 길과 D1(대표 줄 잠금)의 맞물림 — 계정이 없는 동안에만 생기는 길인지

### 다음 세션 순서
1. 위 「아직 확인 못 한 것」을 읽고 연결 요청 조각 절을 설계해 이 파일에 붙인다(조각 표·의존 순서·공유 지점·출시 때 걷을 자리도 함께)
2. 새 「사용자 확인 필요」가 생기면 하나씩 묻는다
3. 설계에 관여하지 않은 서브에이전트로 문서 자기 정합성 점검(규칙 C) — 지적 0건까지
4. 그 뒤 D1 부터 착수(S0-12 — 상대 개발자에게 `brands`·531·533 재정의 작업 여부 먼저 확인)
- Figma 구역 설명 글 추출본은 세션 임시 폴더라 사라진다 — 필요하면 Figma 파일 `XG4hXdgySeN45Ele3EnN8H` 구역 `659:523` 에서 다시 뽑는다
