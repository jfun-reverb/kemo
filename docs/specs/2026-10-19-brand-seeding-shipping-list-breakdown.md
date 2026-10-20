# 📋 작업 분해표 — 시딩형 배송 리스트 + 개인정보 접속·제공 기록

**사양서:**
- ① `docs/specs/2026-10-19-brand-seeding-shipping-list.md` (배송 리스트 — 결정 13건, §4 설계)
- ② `docs/specs/2026-10-19-personal-data-access-records.md` (개인정보 접속·제공 기록 — 결정 6건)

**분해일:** 2026-10-19 (개발 세션 — `reverb-planner` 초안 + 코드 대조)
**피그마:** 「레버브시딩_브랜드」 Brand 「[1차] 05-1」 bw05-01b · 「[1차] 05-2 배송 리스트」(bw05-02·bm05-02·bw05-03·03a·90·91·94) · Admin 「[1차] a05-5 배송 리스트」(a05-09·09a·10·11·14·90a·메일 bw05-95) · Admin 「[1차] a13 개인정보 기록」(a13-00~03)
**양식:** `.claude/commands/작업분해.md` 「표준 작업표 양식」 · 선례 `docs/specs/2026-10-19-brand-campaign-results-breakdown.md`
**총 작업 조각:** 13개 · **병렬 가능:** 3개(○ S5·S6·S7) · **순차 필수:** 10개(✗ — 데이터베이스 조각 P1·P2·S1·S2·R1 은 한 세션이 차례대로 · 관리자 화면 S3·S4·R2·R3 은 `dev/admin/index.html`·`shared.js`·`storage.js` 핫스팟이 겹침 · 운영 반영 L1)

> **상태: 작업표만 — 코딩은 사용자가 이 문서를 본 뒤 시작한다**(2026-10-19 사용자 지시).
>
> **화면 문구:** 브랜드·관리자 화면과 메일 모두 한국어다. 이 작업표에는 일본어 문구가 없다(인플루언서 화면을 바꾸지 않는다 — 사양서 ① 결정 4).
>
> 🔴 **개발서버에서만 돈다.** 데이터베이스 조각은 개발서버 데이터베이스에만 넣는다. 브랜드 묶음(526~551)과 같은 줄에 서서 운영 반영을 보류한다.
> - 브랜드 화면은 `brandDb`(운영 주소에서는 `null`)로만 서버를 부른다.
> - 관리자 화면 코드는 `_brandAccountEnabled()`(배송 탭·택배사 탭·「개인정보 기록」 화면 전체와 브랜드 상세 「제공 기록」)나 `IS_STAGING`(관리자 엑셀·문의 첨부·민감정보 열람 기록 + 「사내용」 첫 줄 — R2) 아래에서만 돈다.
> - 출시 때 그 판정을 걷는다(L1).
>
> **모든 조각 공통:** 담당 파일 칸에 따로 적지 않아도 모든 조각은 병합 요청에서 `CLAUDE.md`(자기 산출물 줄 — 「개발서버만」 딱지)와 `docs/FEATURE_SPEC.md` 를 함께 고친다(`docs-tracking.md`). R1·S5·L1 은 고칠 줄이 정해져 있어 칸에 적었다.
>
> **번호 이름:** 조각은 P·S·R·L(예: 조각 S2), 착수 전 선결 조건은 **Q1~Q6**(예: 선결 Q2)이다 — 글자가 겹치지 않게 나눴다.
>
> **마이그레이션 번호:** 미리 정하지 않는다. 작성 시점 마지막 번호는 **551** 이다. 「새 마이그레이션 P1·P2·S1·S2·R1」은 순서 이름일 뿐이다. 만들기 직전에 `origin/dev` 와 열린 병합 요청까지 보고 그다음 번호로 확정한다.

---

## 현재 상태 (2026-10-19 코드로 확인)

| 항목 | 실제 (파일·위치) |
|---|---|
| 송장·배송 칸 | 없다. 사양서 ① §1 의 검색 결과와 같다 — 새로 만든다 |
| 브랜드 시딩형 진행 단계 | `dev/js/brand-campaigns.js` `brandCampaignStages(c, today)`. 시딩형은 「모집·선정·**배송**·결과물 게시·종료」이다. 「배송」 단계는 `{label:'배송', date:'', end:null}` 이라 **날짜가 없어 지금 단계로 뽑히지 않는다**. 선정 판정은 `_bcHasSelection` |
| 브랜드 상세 그리기 | `renderBrandCampaignDetail(host, id)` 가 `_bcStatsHtml` → `_bcStagesHtml` → `_bcScheduleHtml` → `brandResultSectionHtml(c)` 차례로 그린다. 배송 카드는 일정과 결과물 사이에 들어간다(사양서 ① §4-1). 상세 조회는 `loadBrandCampaignDetail` → `get_my_brand_campaign`, 그 뒤 `loadBrandCampaignResults(id)` |
| 브랜드 주소 규칙 | `splitBrandHash`(brand-shell.js)는 **첫 「/」 한 번만** 자른다. `#campaigns/<번호>/shipping` 이면 `page='campaigns'`, `arg='<번호>/shipping'` 이다. 🔴 캠페인 페이지 `render` 가 `BRAND_UUID_RE.test(arg)` 로 거르므로 **지금은 그 주소가 「캠페인을 찾을 수 없음」이 된다** — 캠페인 페이지 안에서 인자를 한 번 더 나눠야 한다. 틀 쪽 세 곳(`routeBrand`·`rerenderCurrentBrandPage`·`showBrandShellPage`)은 앞부분만 보므로 안 고쳐도 된다 |
| 로그인 전 메일 링크 | 오리엔시트 메일은 해시가 아니라 `?orient=<시트 번호>` 를 쓴다. 부팅 때 세션 저장소에 옮기고(`captureBrandOrientTarget`) 로그인 뒤 꺼낸다(`consumeBrandOrientTarget`). 해시 링크가 로그인을 거쳐도 남는지는 **확인하지 못했다** |
| 브랜드 빌드 | `dev/build.sh` 의 `BRAND_JS_FILES`(14개, `brand-app.js` 맨 끝). 같은 파일 203줄 주석: 「원본 태그 정규식은 일반식이라 이름을 넣지 않는다」 — 브랜드 쪽은 목록 한 곳만 고친다. 브랜드 빌드에는 `ui.js` 가 없다 → `formatPhoneDisplay` 를 못 쓴다. 엑셀 도구는 `_brLoadExcelJS`(`exceljs@4.4.0`)가 그때 불러온다 — 같은 도구로 읽기(`wb.xlsx.load`)가 된다(관리자 `report-parsers.js` 가 이미 그렇게 읽는다) |
| 브랜드 캠페인 함수 | `get_my_brand_campaigns`·`get_my_brand_campaign`·`get_my_brand_campaign_results` 현재 원본 **547**. 셋 다 `RETURNS jsonb` 라 칸을 더해도 `CREATE OR REPLACE` 로 된다(실행 권한 보존). 🔴 셋 다 **`STABLE`** 이다 — 안에서 기록 줄을 넣으려면 `VOLATILE` 로 바꿔야 한다(`STABLE` 함수 안의 `INSERT` 는 오류). → 이 작업표는 이 셋을 **재정의하지 않는다**(R1 은 서버 함수에서 기록) |
| 로그인 브랜드 판정 | `is_my_brand(brand_id)`(530) = `my_brand_role(...) IS NOT NULL`(활성 연결 + 활성 브랜드). 547 은 「캠페인의 `brand_id` 로 `is_my_brand` + 보일 상태 넷 + 보관 삭제 제외」로 판정하고, 거부는 `not_found` 하나다 |
| 감사용 계정 제외 | `_brand_campaign_counts`(543): `JOIN influencers i ON i.id = a.user_id AND i.is_audit = false` |
| 브랜드 결과물 서버 함수 | `supabase/functions/brand-campaign-results` — `view`·`excel`·`receipt` **세 갈래 모두** 브랜드 토큰으로 `get_my_brand_campaign_results` 를 부른다. 브랜드 화면(`brand-campaign-results.js`)은 결과물을 **이 서버 함수로만** 부른다(데이터베이스 함수를 직접 부르는 자리 없음). 547 안에서 「열람」을 기록하면 엑셀과 영수증 「열기」도 열람으로 쌓인다 → 기록은 서버 함수의 갈래별로 남긴다(R1) |
| 응모 주소 | 마이페이지가 `influencers.address = '〒{우편번호} {도도부현}{시군구} {건물}'` 로 저장한다(`mypage.js`). 응모 창이 그 값을 미리 채우고(`application.js`) 회원이 고친 값이 `applications.address` 에 들어간다 — 사양서 ① §4-2 의 「〒 뒤 우편번호 떼기」 전제와 맞다. 전화번호 = `influencers.phone` |
| 탈퇴와 응모 | `request_withdrawal`(450)이 응모를 `cancel_application`(394, 사유 `withdrawal`)으로 취소한다 → 탈퇴 신청자의 배송 줄은 「취소됨」이 된다. 확정 때 `purge_withdrawn_personal_data`(520)가 `applications.address`·`user_name` 과 회원 이름·전화를 비운다 → **「취소됨」 줄의 이름도 비게 된다**(D25) |
| 응모 상태 경로 | 관리자 승인·반려·대기로 되돌림 = 표 직접 수정(`updateApplication`, storage.js) · 본인 취소 = `cancel_application`(394) · 취소 되돌리기 = `restore_cancelled_application`(**525**, 베이스 440 — `previous_status` 로 **같은 응모 줄**이 돌아간다) · 재응모 = 새 응모 줄. 시딩형 응모는 늘 심사중으로 들어간다(537 가드) |
| 캠페인 보관 삭제 | `soft_delete_campaign` 이 신청·결과물을 **즉시** 지운다 → 새 배송 표가 응모를 「지우기 막음」으로 가리키면 캠페인 삭제가 깨진다 |
| 관리자 진행현황 탭 | `dev/js/admin-applications.js` `renderCampDetailTabs(appCount, delivCount, ticketCount)`. 일반 캠페인 = `applicants`·`deliverables`, 행사 = `tickets`·`applicants`. 표시 전환 `applyCampDetailTabVisibility`(카드 `campApplicantsCard`·`campDelivCard`·`campTicketsCard`·`campExtBox`). 탭 상태 `_campDetailTab` |
| 권한 | `ADMIN_PERMISSION_CATALOG`(shared.js) — **「신청 승인」 항목이 없다.** 승인은 `menu.applications`(최고·캠페인 관리자·매니저 **모두 쓰기**, `server_enforced:false`) + 표 직접 수정. 🔴 캠페인 매니저는 `influencer.sensitive_pii` 가 **숨김**(213 — 주소·전화를 서버가 비운다). `has_permission` 은 항목이 미등록이면 최고 관리자는 통과, 다른 두 등급은 거부다 |
| 기준 데이터 종류 | `lookup_values.kind` 검사 제약 현재 원본 **346**. 칸 = `code·name_ko·name_ja·sort_order·active·recruit_types` — **「송장 조회 주소」 칸이 없다**. 관리자 탭은 `switchLookupTab(kind, btn)`(admin-lookups.js) + `dev/admin/index.html` 탭 단추 |
| 오리엔시트 「브랜드 계정 전원」 메일 | `notify-orient-sheet` 의 `resolveBrandAccountRecipients` — 활성 브랜드 · 활성 연결 · `password_set_at` 있는 계정 · 대표 먼저 · 중복 제거. 두 겹 잠금 = 비밀값 `ORIENT_MAIL_TO_BRAND_ACCOUNTS=1` **그리고** `isStagingProject()`. 링크 주소는 비밀값 `PUBLIC_BRAND_URL`. `supabase/functions/_shared/` 폴더가 **없다**. 메일 양식은 `scripts/sync-email-templates.sh` 의 `SYNC_GROUPS` 에 한 줄 |
| 기존 브랜드 메일 꼬리 | `orient-sheet-invite-brand.html` 39줄 — 개인 카카오 아이디·휴대전화 번호가 문의처로 박혀 있다 — 같은 파일 18줄 주석이 「피그마 「확인 필요」 — 그대로 둘지 기획 확인」 |
| 관리자 엑셀 | 내보내기 함수 **14개**: admin-excel.js 6(`exportSelectedCampaignsApplicants`·`exportSelectedCampaignsDeliverables`·`exportCampaignApplicationsExcel`·`exportCampaignDeliverables`·`exportInfluencersExcel`·`exportEventTicketsExcel`) · admin-deliverables.js `exportDeliverablesViewExcel` · admin-settlements.js 4(`exportSettlementsExcel`·`exportPickedPayoutRounds`·`exportPayoutRoundExcel`·`exportTransferHistoryExcel`) · admin-reports.js `exportReportExcel` · admin-outbound.js `exportOutboundExcel` · admin-brand.js `exportBrandApplicationsExcel`. 관리자 엑셀을 **다시 읽는 코드는 없다** — `report-parsers.js` 는 포인테일 파일만 읽는다 |
| 민감정보 표시 | 「보기」 단추가 **없다** — `admin-influencers.js` 가 권한이 있으면 상세 창·목록 줄에 바로 그리고, 없으면 「열람 권한 없음」 |
| 문의 첨부 열기 | `getMessageAttachmentSignedUrl(path, expiresIn)`(storage.js) — 인플루언서·관리자 앱이 **같이 쓴다** |
| 남은 결과물 조각 | 4c(보류 — 547·요약 함수 재정의 예정) · 16(별도 작업표) · 17(admin-reports.js·admin-excel.js) · 18~21(출시 날) |

---

## 의심·경우의 수 (반대론자)

1. **(기술 — 조용한 고장) 547 에 기록을 넣으면 세 갈래 모두 열람으로 기록된다.** 서버 함수의 엑셀·영수증 「열기」도 547 을 거친다. 또 함수를 `VOLATILE` 로 바꾸지 않으면 기록이 **첫 호출에서 오류**가 나고 결과물 화면 전체가 「불러오지 못함」이 된다 → R1: 547 은 건드리지 않고, 서버 함수가 갈래별로 기록한다 — `view` 는 `results_view`(D16 합치기), `excel` 은 `results_excel`, `receipt` 는 기록하지 않는다(그 사진을 담은 화면 열람이 이미 `view` 로 남는다).
2. **(운영 사고) 관리자 엑셀 「기록 실패면 못 내려받음」(사양서 ② 결정 5) + 운영에 기록 함수 없음 = 운영 관리자 엑셀 전부 막힘.** 관리자 엑셀은 이미 운영 화면이다 → R2 는 `IS_STAGING` 아래에서만 기록하고, 운영은 지금 동작 그대로. 잠금은 L1 에서 함수 적용을 확인한 뒤 걷는다.
3. **(데이터) 지우기 연쇄가 기록을 지운다.** 배송 줄은 응모가 지워지면 함께 지워져야 한다(보관 삭제가 응모를 즉시 지운다). 반대로 제공 기록은 캠페인·브랜드가 지워져도 **3년 남아야 한다**. 기록 표가 브랜드를 「지우기 막음」으로 가리키면 `delete_brand`(528)가 새로 막히고, 「함께 지움」이면 기록이 사라진다 → 기록 표는 외래 키 없이 번호 + 이름 스냅샷으로 둔다(P1).
4. **(권한) 캠페인 매니저에게 주소·전화가 열린다.** 결정 10 「처음 값 = 신청 승인 권한」을 `menu.applications` 로 읽으면 매니저도 쓰기다. 그러면 213 이 서버에서 감춘 주소·전화를 배송 탭이 보여 준다(선결 Q2).
5. **(UX) 메일 링크로 들어온 브랜드가 엉뚱한 곳에 닿는다.** `#campaigns/<번호>/shipping` 은 지금 「찾을 수 없음」이 되고, 로그인 전이면 해시가 남는지도 확인되지 않았다(D20).
6. **(UX) 엑셀 줄 번호 모양.** 배송 줄 고유 번호를 범용 고유 번호(36자)로 두면 엑셀에서 손으로 다루기 어렵다 → 캠페인 안 일련번호(D21).
7. **(데이터) 취소 뒤 다시 선정.** 같은 응모 줄이 승인으로 돌아오면 옛 배송 줄이 살아난다. 처음 들어간 날로 기한을 세면 **되살아나자마자 「기한 지남」**이다(D15).
8. **(데이터) 탈퇴 확정 뒤 「취소됨」 줄.** 520 이 이름까지 비운다 → 결정 7 「이름만 남김」이 확정 뒤에는 빈 줄이 된다(D25).
9. **(법률) 기록에 남는 이름 스냅샷은 탈퇴 뒤 3년 남는 개인정보다.** 방침이 그것을 말해야 한다 → 선결 Q6(`/약관확인`).
10. **(동시성) 두 관리자가 동시에 전달을 누르면** 기록이 두 줄, 메일이 두 번 나갈 수 있다 → 전달 함수 잠금 + 메일 「선점 먼저」(`.claude/rules/mail-webhooks.md`).

**의도가 모호한 점:** 「3일」을 어떻게 세는가(D14) · 자동 추가가 「제공」인가(선결 Q3) · 기록 대상 관리자 엑셀의 범위(선결 Q5) · 배송 탭의 기록 모달을 누가 보는가(D26).

**권고 — 두 기능의 순서:** **기록 표 → 배송 표**. 배송 전달 함수와 자동 추가 트리거가 같은 거래 안에서 기록 표에 쓰므로, 기록 표가 먼저면 나중에 「기록 붙이기」 재정의가 안 생긴다. 기존 기능에 기록을 붙이는 일(R1·R2)은 선행이 P1 뿐이라 배송 조각을 기다리지 않아도 된다. 배분상으로는 R1 을 데이터베이스 조각의 끝(그 세션은 이어서 S7), R2 를 관리자 묶음 끝에 둔다(핫스팟 순서 때문 — 「배분 제안」).

---

## 🚦 착수 전 선결 조건 (작업표보다 먼저)

| # | 선결 조건 | 근거 | 막는 조각 | 개발 기본값 후보 (결정 아님) |
|---|---|---|---|---|
| Q1 | 기록 장치(관리자 쪽)를 언제 운영에 내나 — 브랜드 묶음과 함께인가, 먼저인가 | 사양서 ② 결정 3(장치가 운영에 들어가는 날 방침 §9 3·6호 동시) · 의심 2 | R2 운영 · L1 | **브랜드 묶음과 함께.** R2 코드는 `IS_STAGING` 아래에서만 기록 |
| Q2 | 캠페인 매니저가 배송 탭에서 주소·전화를 보는가 | 사양서 ① 결정 10 · 213(매니저 민감정보 숨김) · 의심 4 | S2 · S3 | **민감정보 권한(`influencer.sensitive_pii`)을 따른다** — 숨김 등급에는 서버가 주소·전화를 비우고 「열람 권한 없음」. 송장 입력·전달은 그대로 |
| Q3 | 전달 뒤 자동으로 추가된 줄을 「제공」 기록으로 남기나 | 피그마 a05-11 예시 줄 「새로 승인된 1명 추가」 ↔ 사양서 ② §4-2 목록에 없음 | S1 | **남긴다** — 그 순간 새 사람의 주소가 브랜드에 열리는 것이 곧 제공이다(일본 법 제29조). 승인과 같은 거래 안에서 한 줄 |
| Q4 | 관리자 「민감정보 보기」 기록 자리 — 그런 단추가 없다 | 사양서 ② 결정 2 · 현재 상태 「민감정보 표시」 | R2 | **상세 창을 연 순간 기록**(열람 권한 등급만, 기록 실패해도 막지 않음) |
| Q5 | 기록 대상 관리자 엑셀 범위 | 사양서 ② §1 「6종」 ↔ 실제 14개 | R2 | **인플루언서 정보가 든 13개 전부**(아웃바운드 명단 포함). 브랜드 서베이 엑셀(브랜드 담당자 연락처)만 뺀다 |
| Q6 | `/약관확인` — ①기록에 남는 이름 스냅샷을 탈퇴 뒤 3년 보관 ②캠페인 종료 뒤 브랜드가 주소를 계속 보는 기간 | 의심 9 · D2 | L1(운영). 개발은 안 막음 | 운영 반영 전 ⓪에서 확인 |

---

## ⚠️ 사양서 stale 점검

> 사양서 본문은 **개발 세션이 착수 때 한 줄씩 보탠다**(사실 정정만 — 결정은 바꾸지 않는다). 피그마 설명 정정은 기획 몫.

1. **사양서 ① §7 에 한 줄 보탬:** 「bw05-94 상태 모음 — ⑤ 받는 사람 0명 · ⑥ 불러오는 중 · ⑦ 엑셀 읽는 중 · ⑧ 반영 중」(번호는 bw05-91 ①~④ 에 이어진다 — 넷이 전부). 피그마에는 있는데 §7 목록에 없다.
2. **사양서 ① §1·§4-6 「543」** → 지금 브랜드 캠페인 함수 셋의 현재 원본은 **547** 이다(요약 칸은 550).
3. **사양서 ② §1 「관리자 개인정보 엑셀 6종」** → 내보내기 함수가 14개다(범위는 선결 Q5).
4. **사양서 ② 결정 2 「민감정보 「보기」 누름」** → 그런 단추가 없다(선결 Q4).
5. **사양서 ② §1·§4-3 「547 을 베이스로 다시 정의 · 브랜드 조회 함수가 같은 거래 안에서 기록」** → 547 은 `STABLE` 이고 서버 함수 세 갈래가 모두 547 을 부른다(의심 1). 브랜드 화면이 결과물을 **서버 함수로만** 부르므로 기록 자리를 서버 함수로 옮긴다(R1). 같은 거래는 아니지만 **기록이 실패하면 응답을 돌려주지 않아**(「기록 없는 제공」 없음) 사양서의 목적은 같다. 배송 리스트 쪽은 새 데이터베이스 함수라 사양서대로 같은 거래에서 기록한다(S2).
6. **사양서 ② §4-2 제공 표 목록에 「자동 추가」가 없다** → 피그마 a05-11 에는 있다(선결 Q3).
7. **피그마 a05-11 미결 「결과물 표·엑셀 열람도 같은 기록 표에 둘지」** → 사양서 ② 가 이미 「브랜드 제공 표 하나」로 정했다(피그마가 뒤처짐 — 기획이 피그마 설명을 고친다).
8. **사양서 ① §4-4 「처음 값은 신청 승인 권한과 같게」** → 그런 권한 항목이 없다. `menu.applications`(세 등급 쓰기)로 읽으면 매니저 민감정보와 부딪힌다(선결 Q2).
9. **피그마 bw05-95 링크 `…/brand/#campaigns/…/shipping`** → 지금 구조에서는 「찾을 수 없음」이 된다(D20 — 기획이 피그마 주소 표기를 고친다).
10. **피그마 a05-14 「송장 조회 주소(선택)」 칸** → `lookup_values` 에 그런 칸이 없다(D13).
11. **CLAUDE.md 「브랜드 빌드는 목록 + 원본 태그 정규식 두 곳」** → `build.sh` 203줄 주석은 「브랜드 쪽 정규식은 일반식 — 목록만」이다. 조각 S5 에서 새 브랜드 파일을 넣을 때 실제로 확인하고 CLAUDE.md 를 고친다.
12. **사용자 지시 「조각 17 이 `brand-campaigns.js` 를 만진다」** → 조각 17 이 고치는 파일은 `admin-reports.js`·`admin-excel.js` 다. 이 작업과 실제로 겹치는 파일은 **`admin-excel.js`·`admin-reports.js`(둘 다 R2 — 리포트 엑셀 `exportReportExcel` 에 기록을 붙인다)** 다(공유 지점 경고).

---

## 한눈에 보는 의존 순서

```
[데이터베이스 — 한 세션이 이 차례대로]
 P1 기록 표 둘·기록 함수·읽기 함수
  ├─ P2 보관 기간 지난 줄 매일 삭제 예약
  ├─ S1 배송 기반(택배사 종류·권한 항목·배송 표·자동 추가 트리거) ← 선결 Q3
  │    └─ S2 배송 함수(관리자 조회·전달·저장 / 브랜드 요약·조회·내려받기·저장) ← 선결 Q2
  └─ R1 결과물 열람·내려받기·공개 설정 기록(544 재정의 + 서버 함수 `view`·`excel` 갈래 기록 — 547 은 그대로)

[관리자 화면 — 핫스팟이라 한 세션 순서대로]
 S3 진행현황 「배송 리스트」 탭·전달 확인·기록 모달 ← S2 · P1 · 선결 Q2
 S4 기준 데이터 「택배사」 탭 ← S1 · S2
 R3 「개인정보 기록」 화면·브랜드 상세 「제공 기록」 ← P1 · S3(기록 읽기 storage 함수 둘 + 「더 보기」 한 줄)
 R2 관리자 엑셀·문의 첨부·민감정보 열람 기록 + 「사내용」 첫 줄 ← P1 · 선결 Q4·Q5   ⚠️ admin-excel.js·admin-reports.js = 결과물 조각 17 과 겹침

[브랜드 화면 — 관리자 묶음과 동시]
 S5 배송 카드·배송 리스트 ← S2
 S6 엑셀 내려받기·올리기 ← S5

[메일 — 관리자·브랜드 묶음과 동시]
 S7 전달 알림 메일 ← S2 · S3   (세션 가가 R1 뒤에 — 관리자 화면에서 부르는 한 줄도 S7 이 넣으므로 S3 병합을 확인한 뒤)

[운영 반영 — 브랜드 묶음 출시 날에]
 L1 ⓪ 선결 Q6 확인 → 데이터베이스(P1·P2·S1·S2·R1) → 서버 함수 → 화면 잠금 걷기 → 방침 §9 3·6호 → 공지·가이드
```

∥ 표기: (S3 → S4 → R3 → R2) ∥ (S5 → S6) ∥ S7 — 세 묶음 모두 **S2 가 개발서버에 들어간 뒤** 시작한다(R1·P2 는 기다리지 않는다). R2 는 선행이 P1 뿐이지만 관리자 핫스팟이라 S3 뒤, R3 은 S3 의 기록 읽기 storage 함수 둘과 「더 보기」 한 줄 때문에 S3 뒤. S7 의 관리자 화면 호출 한 줄은 S3 뒤.

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약 | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| P1 | 기록 표 둘·기록 함수·읽기 함수 | 새 마이그레이션 P1 | 표 `brand_provision_logs`·`personal_data_access_logs` / 내부 `_record_brand_provision(...)` / 서비스 전용 `service_record_brand_provision(...)` / 관리자 `record_admin_data_access(...)` / 읽기 `admin_get_brand_provision_logs(jsonb)`·`admin_get_brand_provision_persons(uuid)`·`admin_get_data_access_logs(jsonb)` | — | ✗(데이터베이스 한 세션) | 개발 |
| P2 | 보관 기간 지난 줄 매일 삭제 | 새 마이그레이션 P2 | `purge_expired_personal_data_logs()` + 예약 `personal-data-logs-retention-daily` | P1 | ✗ | 개발 |
| S1 | 배송 기반 | 새 마이그레이션 S1 | 종류 `shipping_carrier` + 처음 값 7 · 권한 항목 `shipping.manage` · 표 `campaign_shipping_lists`·`campaign_shipments` · 트리거 `trg_application_shipping_sync` | P1 · 선결 Q3 | ✗ | 개발 |
| S2 | 배송 함수 | 새 마이그레이션 S2 | 관리자 `admin_get_campaign_shipping`·`admin_deliver_shipping_list`·`admin_save_shipping_rows` / 브랜드 `get_my_brand_shipping_summary`·`get_my_brand_shipping_list`·`get_my_brand_shipping_export`·`save_my_brand_shipping_rows` / 내부 `_shipping_rows_payload`·`_shipping_list_open_for_brand`·`_brand_mailable_accounts` / 서비스 전용 `service_claim_shipping_mail`·`service_mark_shipping_mail_sent` | S1 · 선결 Q2 | ✗ | 개발 |
| R1 | 결과물·공개 설정 기록 | 새 마이그레이션 R1 · `supabase/functions/brand-campaign-results/` · `CLAUDE.md`(공개 설정 원본 번호 한 줄) | `admin_set_campaign_brand_publish` 재정의(같은 거래 기록) · 서버 함수 `view`·`excel` 갈래가 `service_record_brand_provision`(547 은 재정의하지 않음) | P1 | ✗ | 개발 |
| S3 | 관리자 「배송 리스트」 탭 | 새 `dev/js/admin-shipping.js` · admin-applications.js · `dev/admin/index.html`(핫스팟) · `dev/lib/shared.js`(핫스팟) · `dev/lib/storage.js`(핫스팟) · `dev/build.sh`(핫스팟) | 탭 코드 `shipping` · 카드 `campShippingCard` · `openShippingDeliverModal`·`openShippingLogModal` · storage `fetchCampaignShipping`·`deliverShippingList`·`saveShippingRowsAdmin(campaignId, rows)`(줄마다 `{application_id, …, expected_version|null}` — S2 와 같은 모양) · 기록 읽기 `fetchBrandProvisionLogs(filters)`·`fetchBrandProvisionPersons(logId)`(P1 읽기 함수를 감싼다 — R3 이 그대로 쓴다) | S2 · P1 · 선결 Q2 | ✗(핫스팟) | 개발 |
| S4 | 기준 데이터 「택배사」 탭 | admin-lookups.js · `dev/admin/index.html`(핫스팟) | 탭 `shipping_carrier`(이름 한·일 + 켜기·끄기·순서) | S1 · S2 | ✗(S3 뒤) | 개발 |
| S5 | 브랜드 배송 카드·배송 리스트 | `dev/js/brand-campaigns.js` · `CLAUDE.md`(브랜드 빌드 문구 — stale 11) · 새 `dev/js/brand-shipping.js` · `dev/css/brand.css` · `dev/brand/index.html` · `dev/build.sh`(핫스팟 — `BRAND_JS_FILES` 한 줄) | 주소 `#campaigns/<번호>/shipping` · `brandShippingCardHtml(summary)` · `renderBrandShippingPage(host, campId)` · 메일 링크 `?shipping=<캠페인 번호>` 받기(D20) | S2 | ○(관리자 묶음과 동시 — `build.sh` 한 줄과 `CLAUDE.md` 자기 줄만 겹치므로 먼저 병합한 쪽 뒤에 맞춘다) | 개발 |
| S6 | 브랜드 엑셀 내려받기·올리기 | brand-shipping.js · brand.css | `brandShippingExcelDownload()` · `brandShippingExcelUpload(file)` → 미리 보기 → `save_my_brand_shipping_rows` | S5 | ○(관리자 묶음과만 동시 — S5 와는 같은 파일이라 S5 병합 뒤) | 개발 |
| S7 | 전달 알림 메일 | 새 `supabase/functions/notify-brand-shipping-list/` · 새 `docs/email-templates/brand-shipping-delivered.html` · `scripts/sync-email-templates.sh` · `dev/js/admin-shipping.js`(호출 한 줄, S3 뒤) | 함수 입력 `{campaign_id}` → `{sent, recipients, failed, reason?}` · 비밀값 `SHIPPING_MAIL_TO_BRAND_ACCOUNTS` · 관리자 화면(`admin-shipping.js`) 호출 한 줄 | S2 · S3(호출 한 줄) | ○ | 개발 |
| R2 | 관리자 엑셀·첨부·민감정보 기록 | admin-excel.js · admin-deliverables.js · admin-settlements.js · admin-reports.js · admin-outbound.js · admin-influencers.js · admin-messaging.js · `dev/lib/storage.js`(핫스팟) | 공용 `recordAdminExportOrBlock(source, columns, personCount)` · 첫 줄 「사내용」 헬퍼 `_excelInternalBanner(ws, colCount)` | P1 · 선결 Q4·Q5 | ✗(핫스팟 · 조각 17 과 admin-excel.js·admin-reports.js 겹침) | 개발 |
| R3 | 「개인정보 기록」 화면 + 브랜드 상세 「제공 기록」 | 새 `dev/js/admin-privacy-logs.js` · admin-brand.js · `admin-shipping.js`(「더 보기」 링크 한 줄 — S3 뒤) · `dev/admin/index.html`(핫스팟) · `dev/lib/shared.js`(핫스팟) · `dev/lib/storage.js`(핫스팟) · `dev/build.sh`(핫스팟) | 페인 `privacy-logs` · `openPrivacyLogs({brandId})` · 기록 읽기는 S3 의 `fetchBrandProvisionLogs`·`fetchBrandProvisionPersons` 를 그대로 쓴다(접속 탭용 `fetchDataAccessLogs(filters)` 만 새로) | P1 · S3(기록 읽기 storage 함수 둘 + 「더 보기」 한 줄) | ✗(핫스팟) | 개발 |
| L1 | 운영 반영 묶음 | 운영 데이터베이스 · 서버 함수 · `docs/PRIVACY_{kr,ja}.md` · 관리자 공지 · Notion · `CLAUDE.md`·`docs/FEATURE_SPEC.md` | 잠금 걷기 목록(아래) | 모두 · 선결 Q1·Q6 | ✗ | 개발 + **사람** |

---

## 조각별 상세

### 조각 P1. 기록 표 둘·기록 함수·읽기 함수 (새 마이그레이션 P1)
- **하는 일:** 사양서 ② §4-2·§4-4 ① 을 만든다. 적용만으로 바뀌는 기존 동작은 없다.
- **산출 계약**
  - **표 `brand_provision_logs`**(브랜드 제공, 3년): `id`, `at timestamptz`, `brand_id uuid`·`brand_name text`, `campaign_id uuid`·`campaign_no text`, `actor_auth_id uuid`·`actor_kind CHECK(brand|admin|system)`·`actor_name text`, `action text CHECK(...)`, `columns jsonb`, `persons jsonb`(`[{influencer_id, name}]`), `person_count int`.
    - 🔴 **외래 키를 두지 않는다**(의심 3 — 보관 삭제·`delete_brand`·`merge_brands` 와 무관하게 3년).
    - `action` 처음 값: `shipping_deliver` · `shipping_auto_add`(선결 Q3 와 상관없이 목록에는 넣어 둔다 — 「남기지 않음」이면 쓰이지 않는 값일 뿐) · `shipping_view` · `shipping_excel` · `results_view` · `results_excel` · `publish_on` · `publish_off` · `publish_columns`.
  - **표 `personal_data_access_logs`**(접속, 1년): `id`, `at`, `actor_auth_id`·`actor_name`·`actor_role`, `source text`(화면·엑셀 종류 열쇠말), `columns jsonb`, `person_count int`, `meta jsonb`. 🔴 인플루언서 목록을 담지 않는다(사양서 ② §4-2).
  - 두 표 모두 정책은 「읽기 = `is_super_admin()`」 하나뿐이고 쓰기 정책은 없다(함수로만 — 캠페인 변경 이력 265 와 같은 규칙).
  - **함수**(모두 정의자 권한 + `search_path=''`)
    - `_record_brand_provision(p_brand_id, p_campaign_id, p_action, p_columns, p_persons, p_actor_auth_id uuid DEFAULT NULL, p_actor_kind text DEFAULT NULL) RETURNS void` — 내부 전용. 「누가」를 비워 넘기면 로그인 계정(`auth.uid()`)을 쓰고, 자동 추가 트리거는 `system` 으로 넘긴다(서비스 키 호출은 로그인 계정이 비므로 `service_record_brand_provision` 이 받은 계정을 넘긴다). PUBLIC·`anon`·`authenticated` 셋 다 회수. 브랜드 이름·캠페인 번호 스냅샷은 이 함수가 읽어 채우고, **사람 이름은 부르는 쪽이 넘긴 값 그대로** 남긴다(결과물은 가린 이름, 배송은 전체 이름 — 브랜드가 실제로 받은 모양). D16 합치기는 `_record_brand_provision` 한 곳에서 한다 — `service_record_brand_provision` 은 그것을 부른다.
    - `service_record_brand_provision(p_actor_auth_id, p_campaign_id, p_action, p_columns, p_persons)` — `service_role` 전용(R1 의 서버 함수 `view`·`excel` 갈래). 부여 먼저, 회수 나중(375 순서).
    - `record_admin_data_access(p_source text, p_columns jsonb, p_person_count int, p_meta jsonb) RETURNS uuid` — `authenticated`, 안에서 `is_admin()` 가드. 실패면 예외(화면이 「기록 실패」로 읽는다).
    - 읽기 `admin_get_brand_provision_logs(p_filters jsonb)`(기간·브랜드·누가·인플루언서 이름·캠페인) · `admin_get_brand_provision_persons(p_log_id)` · `admin_get_data_access_logs(p_filters jsonb)`(기간·누가·어디서) — `is_super_admin()`. 배송 탭 머리 줄의 요약(마지막 전달·열람 횟수 등)은 이 읽기 함수가 아니라 S2 `admin_get_campaign_shipping` 이 정의자 권한으로 기록 표에서 모아 담는다(D26).
  - 감사용 계정의 기록도 빼지 않는다(사양서 ② §1).
- **선행:** 없음
- **완료 정의**
  - 개발 데이터베이스에서 함수마다 1회 실제 호출이 성공한다(빈 결과라도 — `.claude/rules/supabase.md` 「적용 성공이 동작 확인이 아니다」).
  - 로그인한 최고 관리자 브라우저 콘솔에서 읽기 셋이 성공하고, 캠페인 관리자는 `42501` 이다.
  - 권한 조회에서 내부 함수는 `authenticated` 실행 불가, 서비스 전용 함수는 `service_role` 만 실행 가능이다(`p.proacl::text` 맨 앞 `=X/` 없음까지).
  - `purge_withdrawn_personal_data`(520) 본문에 두 표 이름이 없다(사양서 ② §4-4).
- **필요 검문소:** `reverb-supabase-expert`(권한 회수 두 방향) · `reverb-reviewer`
- **주의·롤백:** 표·함수를 지우면 된다. 다른 조각이 이 함수를 부르기 시작한 뒤에는 그 조각부터 되돌린다.

### 조각 P2. 보관 기간 지난 줄 매일 삭제 (새 마이그레이션 P2)
- **하는 일:** 제공 3년·접속 1년이 지난 줄을 매일 지운다(사양서 ② 결정 3).
- **산출 계약:** `purge_expired_personal_data_logs()` → `{provision_deleted, access_deleted}` · 예약 `personal-data-logs-retention-daily` — 시각은 04:30~05:30 에 이미 여섯이 돌므로(`member-withdrawal.md`) 그 밖으로 잡는다(예: 03:45 한국·일본 시각). 메일을 보내지 않으니 **개발에도 등록한다**(365 선례).
- **선행:** P1
- **완료 정의:** 시험 줄의 시각을 기간 밖으로 돌려 넣고 함수를 한 번 부르면 그 줄만 사라진다. 예약 목록에 이름이 있다.
- **필요 검문소:** `reverb-supabase-expert`

### 조각 S1. 배송 기반 (새 마이그레이션 S1)
- **하는 일:** 택배사 종류, 권한 항목, 배송 표 둘, 응모 상태 변화 트리거를 만든다.
- **산출 계약**
  - **`lookup_values.kind` 검사 제약** — 346 목록 + `shipping_carrier`. 처음 값 7개는 사양서 ① 결정 8 순서대로(우체국 EMS · K-Packet · CJ대한통운 국제 · 롯데 국제 · 일본우편 · 야마토 · 사가와). 「기타」는 목록 행이 아니라 저장 규칙이다(`carrier_code` 비움 + `carrier_other`). 🔴 작성 전 같은 종류·비슷한 이름 행이 있는지 조회한다(`supabase.md` 「기준 데이터 추가 시 기존 중복 확인」).
  - **권한 항목 `shipping.manage`**(「배송 리스트 보기·전달·송장 수정」 — 읽기 = 보기, 쓰기 = 전달·송장 수정). 시드 = 최고·캠페인 관리자·매니저 모두 쓰기(`menu.applications` 와 같게), `default_level` 도 같게. 🔴 시드는 함수(S2)보다 먼저다 — 미등록이면 다른 두 등급은 거부된다.
  - **표 `campaign_shipping_lists`**(캠페인당 1줄): `campaign_id` 기본 키(→ campaigns, 함께 지움) · `delivered_at`·`delivered_by` · `next_row_no int` · `mail_claimed_at`·`mail_sent_at` · `version`.
  - **표 `campaign_shipments`**(응모 1건 = 1줄): `id` · `campaign_id`(함께 지움) · `application_id UNIQUE`(🔴 **함께 지움** — 보관 삭제가 응모를 즉시 지운다) · `row_no int`(캠페인 안 일련번호, `(campaign_id,row_no)` 유일 — D21) · `added_on date`(일본 날짜)·`added_at` · `carrier_code text NULL` · `carrier_other text NULL` · `tracking_no text NULL` · `shipped_on date NULL` · `updated_by uuid`·`updated_by_kind CHECK(brand|admin)`·`updated_at` · `version int`.
    - 🔴 **주소·전화번호를 복사해 두지 않는다** — 읽을 때 `applications.address`·`influencers.phone` 에서 가져온다(복사하면 520 탈퇴 파기에 새 절이 필요해진다).
    - 두 표 모두 정책 없음(함수로만).
  - **트리거 `trg_application_shipping_sync`**(`applications` 삽입·상태 변경 뒤): 전달된 시딩형 캠페인 + 감사용 아님 + 새 상태 `approved` 이면 줄을 넣는다(이미 있으면 D15 규칙). 선결 Q3 이 「남김」이면 같은 거래에서 `_record_brand_provision(…, 'shipping_auto_add', …)`. 캠페인 단위 잠금으로 전달 함수와 겹치지 않게 한다. 취소·반려·대기로 되돌림은 **줄을 건드리지 않는다**(상태는 읽을 때 응모에서 판정).
- **선행:** P1 · 선결 Q3
- **완료 정의**
  - 시험 시딩 캠페인에서 아래 넷이 모두 확인된다: 전달 전 승인이면 트리거로는 줄이 안 생긴다(전달 전 줄은 관리자 송장 저장 때만 — S2) · (S2 의 전달 함수를 거래 안에서 흉내 낸 뒤) 승인이면 줄이 하나 생기고 `row_no` 가 다음 번호다 · 반려 → 다시 승인이면 같은 줄이다 · 감사용 계정이면 줄이 안 생긴다.
  - 캠페인을 보관 삭제하면 줄이 함께 사라지고 오류가 없다.
  - 🔴 **본인 응모 취소를 시험 계정으로 실제로 눌러 본다**(트리거가 응모 표에 붙으므로).
- **필요 검문소:** `reverb-supabase-expert` · `reverb-reviewer`
- **주의·롤백:** 트리거부터 지운다(응모 승인 경로를 막지 않게). 그다음 표 → 권한 시드 → 종류 순서로 되돌린다.

### 조각 S2. 배송 함수 (새 마이그레이션 S2)
- **하는 일:** 사양서 ① §4-2~§4-6 의 판정과 저장을 서버에 둔다. 🔴 목록 단위·줄 단위 판정과 「취소됨」 줄 비우기는 **전부 서버**에서 한다.
- **산출 계약**
  - **내부**
    - `_shipping_list_open_for_brand(p_campaign_id) RETURNS boolean` — **목록 단위 판정 한 곳**. 547 과 같은 「캠페인의 `brand_id` 로 `is_my_brand` + 보일 상태 넷 + 보관 삭제 제외」 + `recruit_type='gifting'` + 전달됨. 결과물 열람 정지(결과물 작업표 4c)가 생기면 이 한 곳에 한 줄을 더한다(D9).
    - `_shipping_rows_payload(p_campaign_id, p_mask_pii boolean) RETURNS jsonb` — **줄 단위 판정 한 곳**. 갈래 둘 — **전달 뒤**: 줄 = 줄이 있고 지금 승인 + 줄이 있고 지금 승인 아님(반려·대기·본인 취소 = 「취소됨」 하나 — 전달 함수 ③이 전달 순간 비승인 줄을 지우므로 남은 비승인 줄은 곧 「전달 뒤 취소」다). **전달 전**(관리자 조회만 — 브랜드 함수는 목록 단위 판정에서 막힌다): 지금 승인인 응모만, 줄이 없어도 포함(그때 `row_no` 는 빈 값), 승인 아닌 줄은 숨기고 「취소됨」에 넣지 않으며, 상태는 기한 없이 「발송 전」/「발송함」만, 「새로 추가」 표시 없음. 감사용 제외. 「취소됨」·`p_mask_pii` 면 주소·전화·우편번호 `null`. 탈퇴 확정으로 이름이 빈 줄은 `withdrawn:true`(D25). 우편번호는 `^〒\s*([0-9０-９\-－]{7,8})\s+` 모양일 때만 떼고, 아니면 주소 한 줄 그대로. 상태 값 넷(`pending`·`overdue`·`shipped`·`cancelled`)은 전달 뒤 갈래에서 서버가 일본 날짜로 계산한다(D14). 「새로 추가」 표시 칸(D4 — `added_at` 이 `delivered_at` 보다 뒤이고 `added_at` 의 일본 날짜부터 7일 안인 줄)도 서버가 준다.
    - `_brand_mailable_accounts(p_brand_id) RETURNS jsonb` — 활성 브랜드 · 활성 연결 · `password_set_at` 있음 · 대표 먼저 · 중복 제거. 🔴 `notify-orient-sheet` 의 `resolveBrandAccountRecipients`(타입스크립트)와 **같은 규칙의 사본**이다 — 머리말에 적는다.
  - **관리자**(가드 `has_permission('shipping.manage', …)`)
    - `admin_get_campaign_shipping(p_campaign_id)` 읽기 → `{delivered_at, delivered_by_name, account_count, provision_summary:{view_count, last_viewed_at, excel_count, last_excel_at, last_excel_by}, counts:{total, shipped, pending, overdue, cancelled}, rows:[… + SNS 계정 · 취소 사유 · 입력한 사람]}`. 주소·전화 가림은 선결 Q2 — 기본값이면 `has_permission('influencer.sensitive_pii','read')` 가 거짓일 때 가린다.
    - `admin_deliver_shipping_list(p_campaign_id)` 쓰기 → `{ok, delivered_now, row_count, account_count}`. 이미 전달된 캠페인이면 오류가 아니라 `{ok:true, delivered_now:false}`(기록·메일 없음 — 두 관리자가 동시에 눌러도 `true` 는 한 번). 거부 `not_gifting`·`no_account`·`campaign_deleted`. 캠페인 단위 잠금 → 줄 넣기 → 같은 거래에서 `_record_brand_provision(…, 'shipping_deliver', 칸 목록, 사람 목록)`. 🔴 되돌리는 함수는 만들지 않는다(결정 9).
    - `admin_save_shipping_rows(p_campaign_id, p_rows jsonb)` 쓰기 — 줄마다 `{application_id, carrier_code|null, carrier_other|null, tracking_no|null, shipped_on|null, expected_version|null}`(줄이 없을 수 있어 열쇠는 응모 번호). `tracking_no` 를 비워 보내면 브랜드 저장과 같은 「송장 지우기」다(택배사·발송일도 비우고 「발송 전」 — D1). 송장 형식 검사(D6)·택배사 이름 검사·「송장이 있는데 발송일이 비면 일본 날짜 오늘」도 브랜드 저장과 같다. 전달 전에도 된다(사양서 ① §4-4 · 피그마 a05-09). 트리거·전달 함수와 **같은 캠페인 단위 잠금**을 잡고, `campaign_shipping_lists` 줄이 없으면 만들고(`delivered_at` 비움), 전달 전에는 줄이 아직 없으므로 **지금 승인인 응모에 한해 그 자리에서 줄을 만들고 `row_no` 를 매긴다**(전달 전 관리자 조회 `admin_get_campaign_shipping` 은 지금 승인인 응모를 줄이 없어도 보여 준다). 전달 함수는 ①그 순간 승인인데 줄이 없는 응모에 줄을 넣고 ②이미 있는 줄의 `added_on` 을 전달한 날로 맞추고(D14 기한은 전달한 날부터) ③그 순간 승인이 아닌 응모의 줄은 지운다(전달 전에 빠진 분은 리스트에 넣지 않는다 — 사양서 ① §4-2).
  - **브랜드**(요약을 뺀 셋은 첫 줄에서 `_shipping_list_open_for_brand`, 거부는 `not_found` 하나. 요약 함수는 브랜드 판정(547 과 같은 `is_my_brand` + 보일 상태 넷 + 보관 삭제 제외 — 실패면 `not_found`)만 먼저 하고, 시딩형·전달 여부는 `ready` 로 돌려준다)
    - `get_my_brand_shipping_summary(p_campaign_id)` → `{ready, delivered_at, counts}`. **개인정보 없음 · 기록 없음** — 상세의 배송 카드용. 전달 전·시딩형 아님이면 `{ready:false}`.
    - `get_my_brand_shipping_list(p_campaign_id)` → 줄 + 택배사 목록. 기록 `shipping_view`(D16 합치기).
    - `get_my_brand_shipping_export(p_campaign_id)` → 같은 줄. 기록 `shipping_excel`.
    - `save_my_brand_shipping_rows(p_campaign_id, p_rows jsonb)`
      - 줄마다 `{row_no, carrier_code|null, carrier_other|null, tracking_no|null, shipped_on|null, expected_version}`. 🔴 **지금 승인인 줄만** 받는다(§4-2 「저장 사이 응모가 취소되면 거부」).
      - 송장 형식 검사(D6)·택배사 이름 검사는 서버가 다시 한다. 송장번호가 있는데 발송일이 비면 일본 날짜 오늘이다. 송장번호를 비워 보내면(D1 「송장 지우기」) 택배사·발송일도 비우고 「발송 전」으로 돌린다 — 엑셀 올리기는 송장 빈칸을 보내지 않는다(D1).
      - 캠페인이 종료(보일 상태 「종료」)면 전체 거부 `campaign_ended`(D2 — 운영팀 저장은 막지 않는다).
      - 한 거래로 처리하고 줄마다 결과를 돌려준다 `{saved:[…], skipped:[{row_no, reason}]}`(D22).
      - 🔴 브랜드가 보낸 엑셀 원문·파일은 받지 않는다(결정 3).
  - **서비스 전용**(S7 메일) `service_claim_shipping_mail(p_campaign_id)` → 선점 성공이면 받는 사람 목록, 이미 선점이면 `null` · `service_mark_shipping_mail_sent(p_campaign_id, p_ok boolean)` — 실패면 선점을 되돌린다(`mail-webhooks.md` 「선점 먼저」).
  - 실행 권한: 공개 함수는 `authenticated` 만(PUBLIC·`anon` 회수), 내부는 셋 다 회수, 서비스 전용은 `service_role` 만.
- **선행:** S1 · 선결 Q2
- **완료 정의**(🔴 브랜드·관리자 판정은 SQL 편집기로 재현되지 않는다 — 로그인 브라우저 콘솔)
  - 시험 대표 계정(`zz-b2-owner@example.com`)으로: 자기 브랜드 시딩 캠페인은 전달 전 `summary.ready=false`, 전달 뒤 줄이 나온다 · 다른 브랜드 캠페인 번호는 `not_found` · 「취소됨」 줄의 주소·전화는 `null` · 취소된 줄 저장은 `skipped` · 버전 충돌은 `skipped`(이유 `version_conflict`).
  - 관리자 쪽: 캠페인 매니저 로그인 콘솔에서 `admin_get_campaign_shipping` 의 주소·전화가 `null` 이다(선결 Q2 기본값일 때) · 브랜드 계정 0명 브랜드면 `no_account` · 같은 캠페인에 두 번 전달하면 둘째가 `delivered_now:false` 이고 기록이 한 줄.
  - 제공 기록 표에 전달·열람·내려받기 줄이 남는다.
- **필요 검문소:** `reverb-supabase-expert` · `reverb-reviewer`(🔴 이름 전파 세 형태 — `applications`·`influencers` 를 읽는 새 조회가 자립형 화면과 겹치지 않는지)
- **주의·롤백:** 함수만 지우면 된다(표는 S1). 화면 조각(S3·S5·S6·S7)부터 되돌린다.

### 조각 R1. 결과물·공개 설정 기록 (새 마이그레이션 R1 + 서버 함수)
- **하는 일:** 사양서 ② §4-3 「브랜드 쪽」·「브랜드 공개 설정 변경」을 붙인다.
- **산출 계약**
  - `get_my_brand_campaign_results`(547)는 **재정의하지 않는다**(`STABLE` 그대로).
  - 서버 함수 `brand-campaign-results` 의 `view` 갈래: 547 응답이 `ready:true` 이면 화면에 돌려주기 **전에** `service_record_brand_provision(브랜드 토큰에서 확인한 계정, 캠페인, 'results_view', 그 응답의 열 목록, 사람 목록)`. 사람 목록 = 응답 `users` 의 회원 번호 + 응답에 실린 이름(결과물 표는 가린 이름 — P1 은 넘긴 이름을 그대로 남긴다). 같은 계정(열어 본 브랜드 계정)·캠페인·종류는 D16 시간 안이면 새 줄을 만들지 않는다(합치기는 `_record_brand_provision` 한 곳 — `service_record_brand_provision` 은 그것을 부른다). 꺼짐(`ready:false`)이면 기록 없음. 기록이 실패하면 `{success:false, reason:'record_failed'}`(화면은 기존 「불러오지 못했습니다」).
  - `receipt` 갈래는 기록하지 않는다(의심 1).
  - `admin_set_campaign_brand_publish(...)` — 544 베이스 `CREATE OR REPLACE`. 저장이 성공한 같은 거래에서 `publish_on`·`publish_off`·`publish_columns` 를 쓴다(「무엇에서 무엇으로」는 `columns` 에 `{before, after}`).
  - 서버 함수 `brand-campaign-results` 의 `excel` 갈래: 서명하기 **전에** `service_record_brand_provision(브랜드 토큰에서 확인한 계정, 캠페인, 'results_excel', …)`. 실패면 `{success:false, reason:'record_failed'}`(화면은 기존 실패 문구 「엑셀을 만들지 못했습니다」).
  - ⚠️ 이 재정의 뒤 공개 설정 저장 함수의 **현재 원본은 R1** 이다 — `CLAUDE.md` 의 그 줄(「캠페인 「브랜드 공개」 설정·기본 열 … 544」)을 R1 병합 요청에서 함께 고친다. 결과물 조회(547)의 원본 번호는 바뀌지 않는다.
- **선행:** P1
- **완료 정의:** 시험 브랜드 계정으로 결과물 화면을 두 번 열면 열람 기록이 한 줄이다(D16 안) · 엑셀을 받으면 `results_excel` 한 줄(열람 줄은 늘지 않는다) · 영수증 「열기」는 기록이 늘지 않는다 · 관리자가 공개를 켜면 `publish_on` 한 줄 · 결과물 화면이 전과 같은 표를 그린다(공개 꺼짐 캠페인은 기록 0줄) · `CLAUDE.md` 공개 설정 원본 번호가 R1 이다.
- **필요 검문소:** `reverb-supabase-expert` · `reverb-reviewer`(🔴 `DROP` 이 없는지)
- **주의·롤백:** 544 파일의 해당 함수 부분을 다시 실행하고, 서버 함수를 이전 판으로 다시 배포한다.

### 조각 S3. 관리자 진행현황 「배송 리스트」 탭
- **하는 일:** 사양서 ① §4-4 · 피그마 a05-09·09a·10·11.
- **담당 파일:** 새 `admin-shipping.js` · `admin-applications.js`(`renderCampDetailTabs`·`applyCampDetailTabVisibility` 에 시딩형만 `shipping` 탭 — 순서 신청자 목록 → 배송 리스트 → 결과물 목록) · `dev/admin/index.html`(카드 `campShippingCard`) · `shared.js`(카탈로그에 `shipping.manage` — 🔴 열쇠말이 시드·카탈로그·서버 가드 세 곳에서 철자가 같아야 한다) · `storage.js`(조회·저장 함수 셋 + 기록 읽기 둘 `fetchBrandProvisionLogs`·`fetchBrandProvisionPersons`) · `build.sh`(`ADMIN_JS_FILES` + 원본 태그 정규식이 새 이름을 지우는지 확인)
- **산출 계약**
  - 탭: 상태 칸에 「발송 전 · 기한 지남」(서버 값 그대로), 줄마다 「입력한 사람」(브랜드·운영팀), SNS 계정, 취소 사유. 송장 줄 입력·수정·「송장 지우기」(확인 뒤 `tracking_no:null` 로 저장 — D1)(쓰기 등급만 — 읽기 등급은 단추 없음). 저장 때 D6 형식을 화면에서도 검사한다. `withdrawn:true` 줄은 이름 칸에 「탈퇴한 회원」(D25).
  - 요약 카드에 「배송(발송함)」 막대 = 발송함 ÷ 받는 사람(피그마 a05-09 — 사양서에 없는 것을 그림대로. 받는 사람 0이면 막대 대신 「—」).
  - 「배송 리스트 전달」 → 확인 창(계정 수 · 사람 수 · 「이후 승인된 분은 자동 추가」 · 「기록이 남습니다」). 성공 토스트 뒤 메일 호출 한 줄은 S7 이 이 화면에 넣는다(`delivered_now:true` 일 때만 — 두 관리자가 동시에 눌러도 서버가 한 번만 `true`). 계정 0명이면 D11.
  - 「전달·열람 기록」 모달(a05-11 — D5·D26). D5 의 「개인정보 기록 화면에서 더 보기」 링크는 R3 병합 뒤 R3 이 이 파일에 한 줄로 넣는다(S3 시점엔 그 화면이 없다).
  - 저장 뒤 `refreshPane('camp-applicants')`.
  - 🔴 탭·단추·조회는 `_brandAccountEnabled()` 일 때만(운영에 S1·S2 가 없다).
- **선행:** S2 · P1 · 선결 Q2
- **완료 정의:** 개발서버에서 시험 시딩 캠페인을 열어 확인 — 탭이 보이고 리뷰어형·방문형에는 안 보인다 · 전달하면 머리 줄이 「전달함 · 시각」으로 바뀐다 · 줄 하나에 송장을 넣으면 목록·숫자·막대가 바로 바뀐다 · 매니저 계정 화면은 사용자에게 로그인을 부탁해 확인한다(비밀번호 입력 금지).
- **필요 검문소:** `reverb-reviewer`

### 조각 S4. 기준 데이터 「택배사」 탭
- **하는 일:** 피그마 a05-14 — 이름(한·일)·켜기·끄기·순서. 끄면 새로 고를 때만 안 보이고 저장된 줄은 그대로다(사양서 ① 결정 8). 「송장 조회 주소」 칸은 D13. 🔴 탭 단추는 `_brandAccountEnabled()` 일 때만(운영에 `shipping_carrier` 종류가 없다).
- **선행:** S1 · S2
- **완료 정의:** 탭에서 항목을 끄면 `get_my_brand_shipping_list`(S2)가 돌려주는 택배사 목록에서 빠지고, 이미 그 택배사로 저장된 줄의 이름은 응답에 그대로 있다(브랜드 고르기 칸 확인은 S5 완료 정의가 맡는다 — S4 는 S5 를 기다리지 않는다).
- **필요 검문소:** `reverb-reviewer`

### 조각 S5. 브랜드 배송 카드·배송 리스트
- **하는 일:** 피그마 bw05-01b(배송 카드) · bw05-02(PC) · bm05-02(모바일 — 보기 + 한 줄 입력, 결정 12) · bw05-90·91·94(토스트·상태).
- **담당 파일:** `brand-campaigns.js`(`render` 의 인자를 「캠페인 번호」와 「하위 페이지」로 나눈다 — `_bcCurrentArg`·`_bcRerenderIfShown` 도 같은 분리 · 시딩형 상세에 배송 카드, 일정과 결과물 사이) · 새 `brand-shipping.js`(`brand-campaigns.js` 뒤, `brand-app.js` 앞) · `brand.css` · `dev/brand/index.html` · `build.sh` · `CLAUDE.md`(브랜드 빌드 문구 — stale 11)
- **산출 계약**
  - 배송 카드는 `get_my_brand_shipping_summary` 만 쓴다(개인정보·기록 없음). 전달 전 「준비 중」(bw05-91 ①), 전달 뒤 전달 시각 · 받는 사람 · 발송함 · 발송 전(「기한 지남 N」) · 취소됨 · 「배송 리스트 열기」.
  - 리스트 화면은 `get_my_brand_shipping_list`. 🔴 조회 실패 `null` 은 오류 화면, 0줄은 「지금 보낼 분이 없습니다」(bw05-94 ⑤)다.
  - 한 줄 저장은 `save_my_brand_shipping_rows`(줄 하나). 송장이 있는 줄에는 「송장 지우기」(확인 뒤 `tracking_no:null` 로 저장 — D1). 저장 때 D6 형식을 화면에서도 검사한다(빈 송장은 검사 대상이 아니라 「송장 지우기」 — D1). 충돌·취소면 토스트를 띄우고 다시 불러온다.
  - 진행 단계 「배송」 판정은 바꾸지 않는다(사양서에 변경 없음).
  - 전화번호는 회원이 적은 그대로 보인다(D24). 「취소됨」 줄은 이름만, 탈퇴로 이름이 비면 D25.
  - 브랜드를 바꾸면 리스트를 다시 받는다(`onBrandChanged`).
  - 캠페인이 종료면 「입력」·「수정」·「송장 지우기」 단추를 그리지 않는다(D2).
  - 메일 링크 `?shipping=<캠페인 번호>`(D20)는 부팅 때 세션 저장소에 옮기고 로그인 뒤 `#campaigns/<번호>/shipping` 으로 연다(`captureBrandOrientTarget`·`consumeBrandOrientTarget` 과 같은 방식).
- **선행:** S2
- **완료 정의:** 시험 대표 계정으로 — 상세 → 배송 카드 → 「배송 리스트 열기」 → 주소창 `#campaigns/<번호>/shipping` → 새로고침해도 같은 화면 · 다른 브랜드 캠페인 번호를 주소에 넣으면 「찾을 수 없음」 · 로그아웃 상태에서 `?shipping=` 링크로 들어와 로그인하면 그 배송 리스트가 열린다 · 모바일 폭에서 한 줄 입력이 된다 · 키보드로 입력·저장이 된다 · `CLAUDE.md` 의 브랜드 빌드 문구가 `build.sh` 실제와 같다 · 데이터베이스에서 택배사 한 줄의 `active` 를 직접 끄면 고르기 칸에서 빠지고, 그 택배사로 이미 저장된 줄은 이름이 그대로 보인다(S4 탭을 기다리지 않는다).
- **필요 검문소:** `reverb-reviewer` · 화면 확인(`browser-qa.md` — 마우스·스크롤로)

### 조각 S6. 브랜드 엑셀 내려받기·올리기
- **하는 일:** 피그마 bw05-03·03a. PC 만.
- **산출 계약**
  - 내려받기는 `get_my_brand_shipping_export` 를 누를 때 새로 받는다. `withdrawn:true` 줄의 이름 칸은 「탈퇴한 회원」(D25). 첫 줄은 안내 문구(캠페인 번호 + 이용약관 파기 의무 — D3), 둘째 줄이 머리글이다. 파일 이름 `배송리스트_{제품명}_{YYYYMMDD}.xlsx`(결과물 엑셀 `결과물_{제품명}_{YYYYMMDD}` 과 같은 모양).
  - 올리기는 같은 `exceljs` 로 **브라우저 안에서만** 읽는다. 서버로 보내는 것은 줄 번호·택배사(「기타」면 이름)·송장번호·발송일뿐이다(결정 3). 여기에 줄마다 `expected_version` 을 붙이는데, 파일이 아니라 올리기 직전에 새로 받은 리스트에서 가져온다. 🔴 파일 내용을 오류 기록(`client_error_logs`)에 남기지 않는다.
  - 머리글은 이름으로 찾는다(열 순서가 바뀌어도 되게). 첫 줄의 캠페인 번호가 다르면 거부한다(D21).
  - 미리 보기 분류 = 새로 등록 · 바뀜(이전 번호) · 그대로 · 반영 안 됨(취소된 분 · 송장 빈칸 · 없는 줄 · 택배사 이름 확인 · 형식 오류). 반영은 「새로 등록」·「바뀜」만 한 번에 보낸다. 결과의 `skipped` 를 「반영되지 않은 줄」로 보인다(D8·D22). 읽는 중·반영 중 상태는 bw05-94 ⑦⑧.
  - 상한은 D7. 캠페인이 종료면 「엑셀로 송장 올리기」 단추를 그리지 않는다(내려받기는 된다 — D2).
- **선행:** S5
- **완료 정의:** 받은 파일을 손대지 않고 다시 올리면 「그대로 N」만 나온다 · 송장 셋을 바꿔 올리면 「바뀜 3」으로 반영된다 · 정렬·행 삭제한 파일도 줄 번호로 맞는다 · 다른 캠페인 파일은 거부된다 · 모바일 폭에서 엑셀 단추가 없다(결정 12) · 「기타」 + 이름 줄이 다시 올려도 그대로다(결정 8).
- **필요 검문소:** `reverb-reviewer`

### 조각 S7. 전달 알림 메일
- **하는 일:** 피그마 bw05-95 「배송 리스트가 전달되었습니다」. 브랜드 계정 전원에게 1명당 1통(결정 5). 회원 정보는 넣지 않는다.
- **산출 계약**
  - 서버 함수 `notify-brand-shipping-list`: 브라우저(관리자 화면)가 직접 부른다 → CORS·사전요청 처리 필수, 공개 키 거부는 걸지 않는다.
  - 호출자 판정은 `has_permission('shipping.manage','write')`. 받는 사람은 서버가 `service_claim_shipping_mail` 로 정한다(화면이 넘긴 주소는 받지 않는다).
  - 두 겹 잠금 = 비밀값 `SHIPPING_MAIL_TO_BRAND_ACCOUNTS=1` **그리고** 개발 프로젝트(`notify-orient-sheet` 과 같은 방식 — 출시 때 함께 걷는다).
  - 링크 = `PUBLIC_BRAND_URL` + D20 모양.
  - 관리자 화면(`admin-shipping.js`, S3)의 전달 성공 뒤 `delivered_now:true` 일 때 이 함수를 부르는 한 줄도 이 조각이 넣는다(S3 뒤).
  - 양식 `brand-shipping-delivered.html` + `SYNC_GROUPS` 한 줄. 문의처 줄은 D23.
  - 받는 사람 규칙은 **복사하지 않고** S2 의 `_brand_mailable_accounts` 를 쓴다(`_shared/` 폴더 선례가 없어 새로 만들지 않는다).
- **선행:** S2 · S3(호출 한 줄)
- **완료 정의:** 개발서버에서 사전요청 1회로 허용 헤더를 확인한다(실제 발송 시험은 시험 계정 `@example.com` 만) · 같은 캠페인으로 두 번 부르면 둘째는 보내지 않는다 · 받는 사람 0명이면 `no_account`.
- **필요 검문소:** `reverb-supabase-expert`(CORS·선점) · `reverb-reviewer`

### 조각 R2. 관리자 엑셀·문의 첨부·민감정보 열람 기록 + 「사내용」 첫 줄
- **하는 일:** 사양서 ② 결정 1·2·5·6 · 피그마 a13-03.
- **산출 계약**
  - 공용 `recordAdminExportOrBlock(source, columns, personCount)`(storage.js) — `record_admin_data_access` 를 부르고 실패면 `false` + 토스트 「기록을 남기지 못해 내려받을 수 없습니다. 잠시 후 다시 시도해 주십시오.」(결정 5 그대로). 첫 줄 「사내용」은 공용 `_excelInternalBanner(ws, colCount)`(admin-excel.js)로 그린다.
  - 🔴 엑셀·문의 첨부·민감정보 기록 **셋 모두**, 그리고 **「사내용」 첫 줄도** `IS_STAGING` 일 때만이다 — 운영 파일은 지금 모양 그대로(기록이 없는데 「기록이 남습니다」가 찍히거나 머리글 줄이 밀리지 않게).
  - 엑셀 함수(선결 Q5 범위)마다 파일을 만들기 **직전**에 부른다. 🔴 `IS_STAGING` 이 아니면 부르지 않고 지금처럼 내려받는다(의심 2 · 선결 Q1).
  - 첫 줄 「사내용 — 회사 밖으로 보내지 마십시오 · 내려받은 기록이 남습니다(시각 · 이름)」(주황) — 머리글은 둘째 줄로 내려간다. 관리자 엑셀을 다시 읽는 코드는 없다(현재 상태). 운영팀이 구글 시트로 다시 읽는 습관은 L1 공지에 넣는다.
  - 문의 첨부: `getMessageAttachmentSignedUrl` 은 인플루언서 앱(`messaging.js`)과 같이 쓰므로 함수 안이 아니라 **관리자 쪽 호출 자리(`admin-messaging.js`)**에서 기록한다.
  - 민감정보 열람: 선결 Q4 자리(기본값 = 인플루언서 상세 창을 연 순간, 열람 권한 등급만, 실패해도 막지 않음).
- **선행:** P1 · 선결 Q4·Q5
- **완료 정의:** 개발서버에서 엑셀(선결 Q5 범위)을 하나씩 받으면 접속 기록이 한 줄씩 생기고 파일 첫 줄이 「사내용」이다 · 기록 함수를 일부러 실패시키면 파일이 안 받아진다 · 운영 주소 빌드에는 기록 호출이 돌지 않는다(`IS_STAGING` 갈래 확인).
- **필요 검문소:** `reverb-reviewer`(🔴 엑셀 전수 — 빠진 함수가 없는지)
- **주의:** `admin-excel.js` 는 결과물 조각 17 이 함께 고친다 — 아래 공유 지점.

### 조각 R3. 「개인정보 기록」 화면 + 브랜드 상세 「제공 기록」
- **하는 일:** 피그마 a13-00·01·02. 사이드바 「관리자 설정」 맨 아래(「광고 추적」 아래), 최고 관리자만. 탭 둘(「브랜드 제공 (3년)」·「접속 — 열람·내려받기 (1년)」). 브랜드 상세 머리 「…」 → 「제공 기록」(최고 관리자 아니면 그 줄 숨김).
- **산출 계약**
  - 페인 `privacy-logs`. `PANE_REFRESHERS` 등록.
  - 🔴 메뉴·화면 전체(두 탭 모두)·브랜드 상세 「…」 줄은 `_brandAccountEnabled()` 일 때만(운영에 P1 이 없다).
  - 🔴 이 페인은 권한 카탈로그 항목이 아니라 `is_super_admin()` 고정이다(캠페인 변경 이력과 같다). 카탈로그에 없는 페인은 기본으로 보일 수 있으니 최고 관리자 판정으로 직접 숨긴다.
  - 「사람 보기」 = `admin_get_brand_provision_persons`. 브랜드 상세에서 열면 `openPrivacyLogs({brandId})` 로 걸러 연다.
  - 「결과물 열람 정지」(a03-12)는 보류(결과물 작업표 4c).
- **선행:** P1 · S3(기록 읽기 storage 함수 둘 + 「더 보기」 한 줄)
- **완료 정의:** 개발 데이터베이스에 시험 기록 줄을 직접 넣어(S2·R1 이 들어갔으면 그 줄로) 최고 관리자 화면에서 보이고 거르기가 먹는다 · 배송 탭 기록 모달의 「더 보기」가 이 화면을 그 브랜드로 걸러 연다. 캠페인 관리자 화면에는 메뉴·「…」 줄이 없다(사용자 로그인 부탁).
- **필요 검문소:** `reverb-reviewer`

### 조각 L1. 운영 반영 묶음 (브랜드 묶음 출시 날)
- **차례**
  - ⓪ 선결 Q6 `/약관확인`
  - ① 운영 데이터베이스 P1 → P2 → S1 → S2 → R1(브랜드 묶음 526~551 뒤)
  - ② 서버 함수 `brand-campaign-results`·`notify-brand-shipping-list` 운영 배포
  - ③ 운영 비밀값 `SHIPPING_MAIL_TO_BRAND_ACCOUNTS=1`
  - ④ 화면 잠금 걷기: S3·S4·R3 의 `_brandAccountEnabled()`, R2 의 `IS_STAGING`(기록 셋 + 「사내용」 첫 줄), 메일 함수 `isStagingProject()`
  - ⑤ 같은 날 방침 §9 3호 「6개월 → 1년」·6호 「문의 첨부 열람·다운로드」(한·일 동시, `policy.md`)
  - ⑥ 관리자 공지(엑셀 「사내용」·브랜드에 엑셀을 보내지 않는다·시트 삭제 관문과 같은 공지 — 사양서 ② 의심 2)
  - ⑦ Notion 「관리자 가이드」(진행현황 배송 탭·택배사 탭·개인정보 기록)
  - ⑧ `CLAUDE.md`(현재 원본 번호는 각 조각 병합 때 이미 고쳤다 — 여기서는 「개발서버만」 딱지를 운영 반영으로)·`docs/FEATURE_SPEC.md`·사양서 「구현 결과」
- 🔴 ④ 는 ①·② 를 확인한 **뒤**에 병합한다(함수 없는 서버에서 기록 실패 = 운영 엑셀 전부 막힘).
- **필요 검문소:** `reverb-supabase-expert` · 사용자 확인(1단계씩)

---

## ⚠️ 공유 지점 경고 (충돌 주의)

- **`dev/js/brand-campaigns.js`** — S5 가 고친다(인자 나누기·배송 카드). 결과물 작업표의 남은 조각은 이 파일을 **고치지 않는다**(조각 17 은 `admin-reports.js`·`admin-excel.js`, 4c 는 서버). 그래도 다른 세션이 이 파일을 고치고 있으면 **순서대로**만 한다.
- **`dev/js/admin-excel.js`·`dev/js/admin-reports.js`** — 🔴 R2(기록·「사내용」 첫 줄)와 **결과물 조각 17**(리포트 엑셀 — 출시 날 배포)이 함께 고친다. 둘이 동시에 돌면 순서대로 하고, 「사내용」 첫 줄 때문에 머리글 행 번호가 바뀌는 것을 17 쪽에 알린다.
- **서버 함수 `brand-campaign-results`** — R1 이 `view`·`excel` 갈래에 기록을 붙인다. 결과물 작업표 4c(보류 — 열람 정지)가 547 이나 이 서버 함수를 다시 고치면 순서대로. 547 은 이 작업에서 건드리지 않는다.
- **`admin_set_campaign_brand_publish`(544)** — R1 재정의. 결과물 조각 19(출시 날 공유 열 옮기기 도구)가 이 함수가 아니라 표에 직접 쓰는지 확인한다 — 표에 직접 쓰면 그 공개 켜기가 제공 기록에 안 남는다.
- **받는 사람 규칙 사본** — `notify-orient-sheet` 타입스크립트 ↔ S2 `_brand_mailable_accounts`(SQL). 규칙을 바꾸면 둘 다 고친다.
- **브랜드 판정 사본** — S2 `_shipping_list_open_for_brand` 은 547 의 판정(보일 상태 넷·보관 삭제 제외·`is_my_brand`)을 따른다. 547 을 바꾸면 함께 고친다.
- **`dev/js/brand-shipping.js`·`dev/css/brand.css`** — S5 가 만들고 S6 이 더한다. S5 병합 뒤 S6.
- **`dev/js/admin-shipping.js`** — S3 이 만들고, S7(메일 호출 한 줄)·R3(「더 보기」 한 줄)이 각각 한 줄씩 더한다. 세션이 다르면(가·나) 먼저 병합한 쪽 뒤에 맞춘다.
- **`CLAUDE.md`** — **모든 조각**이 병합 요청에서 자기 산출물(새 표·함수·트리거·예약·화면)의 줄을 「개발서버만」 딱지와 함께 쓴다(`docs-tracking.md` — 코드·`FEATURE_SPEC.md`·`CLAUDE.md` 한 세트). 특히 R1(공개 설정 원본 번호)·S5(브랜드 빌드 문구). L1 은 딱지만 운영 반영으로 바꾼다. 세션이 다르면 먼저 병합한 쪽 뒤에 맞춘다.
- **핫스팟**: `dev/lib/shared.js`(S3 카탈로그·R3 새로고침 등록) · `dev/lib/storage.js`(S3·R2·R3) · `dev/admin/index.html`(S3·S4·R3) · `dev/build.sh`(S3·S5·R3 — 새 파일 셋). 먼저 병합한 쪽 뒤에 나머지가 다시 맞춘다.
- **`applications` 트리거** — S1 이 하나 더한다. 응모 승인·취소·되돌리기·탈퇴 철회가 모두 이 표 갱신이다. 오류가 나면 **승인 자체가 막힌다**.

---

## 🧭 배분 제안

- **세션 가(데이터베이스·서버):** P1 → P2 → S1 → S2 → R1(서버 함수 포함) → S7. 마이그레이션 번호는 이 세션 하나가 정한다.
- **세션 나(관리자 화면):** S2 가 개발서버에 들어간 뒤 S3 → S4 → R3 → R2. R2 는 결과물 조각 17 과 `admin-excel.js`·`admin-reports.js` 가 겹치므로 그 작업이 없을 때.
- **세션 다(브랜드 화면):** S2 뒤 S5 → S6.
- 세션이 하나뿐이면 **한 줄로**: P1 → P2 → S1 → S2 → S3 → S5 → S6 → S7 → S4 → R1 → R3 → R2.
- **출시 날(L1):** 한 세션이 사용자와 1단계씩.

---

## 확정할 기본값 (추천으로 시작 — 바꾸려면 사용자 결정)

> 사양서 ① §6 「아직 정하지 않은 것」 다섯 = **D1~D5**. 그 밖은 피그마 미결·코드 대조에서 나온 것.

| # | 항목 | 추천 | 근거 | 영향 조각 |
|---|---|---|---|---|
| D1 | 잘못 넣은 송장 지우기 | 한 줄 「송장 지우기」로 「발송 전」으로 돌린다(브랜드·운영팀 모두). 엑셀 빈칸은 지우기가 아니라 「반영 안 됨」 | 엑셀 빈칸을 지우기로 읽으면 열을 비운 파일 하나로 전부 지워진다 | S2·S3·S5·S6 |
| D2 | 캠페인 종료 뒤 수정 | 종료 뒤 브랜드는 보기·내려받기만, 운영팀은 수정 가능. 종료 뒤 주소를 얼마나 보일지는 선결 Q6 | 배송은 종료 전에 끝난다. 종료 뒤 주소 노출은 약관 제8조(목적 외)와 닿는다 | S2·S5·S6 |
| D3 | 엑셀 열 순서·머리글 | 1행 안내(캠페인 번호 + 파기 의무) / 2행 머리글: 줄 번호 · 이름(한자) · 이름(가나) · 우편번호 · 주소 · 전화번호 · 상태 · 택배사 · 택배사 이름(기타일 때) · 송장번호 · 발송일 | 결과물 엑셀(A1 안내 + 2행 머리글)과 같은 모양. 올리기는 머리글 이름으로 찾는다 | S6 |
| D4 | 「새로 추가」 표시 기간 | **전달 뒤** 리스트에 들어간 줄(`added_at` 이 `delivered_at` 보다 뒤 — 다시 선정된 줄 D15 포함)에, `added_at` 의 일본 날짜부터 7일. 처음 전달 때 들어간 줄에는 붙이지 않는다. `added_on` 은 D14 기한에만 쓴다 | 피그마 bw05-91 ② 그대로 | S2·S5 |
| D5 | 전달·열람 기록 모달 모양 | 표 = 일시 · 누가 · 무엇(전달·자동 추가·열람·내려받기) · 사람 수 + 「사람 보기」. 최근 50줄 + 「개인정보 기록 화면에서 더 보기」 | 피그마 a05-11 · R3 화면과 같은 읽기 함수 | S3·R3 |
| D6 | 송장번호 형식 | 택배사 무관 하나의 규칙: 영문·숫자·하이픈·띄어쓰기, 4~40자, 「저장」 때 검사(화면 + 서버 — 브랜드·운영팀 저장 모두). 빈 송장(`null`)은 형식 검사 대상이 아니라 「송장 지우기」다(D1) | 피그마 bw05-91 ④. 택배사마다 다르게 하면 목록을 늘릴 때마다 규칙을 고쳐야 한다 | S2·S3·S5·S6 |
| D7 | 올릴 파일 상한 | `.xlsx` 만, 5MB · 2,000줄. CSV 는 받지 않음 | 받으면 글자 깨짐(일본어 인코딩) 대응이 따로 필요하다 | S6 |
| D8 | 「바뀜」 줄 한 번 더 확인 · 반영 안 된 줄 목록 | 추가 확인 창 없음 — 미리 보기 창이 확인이다(「바뀜 N」을 굵게). 반영 안 된 줄은 화면 목록으로만, 파일로 받지 않음 | 확인 창이 두 겹이면 습관적으로 누른다. 파일로 주면 주소 든 파일이 하나 더 생긴다 | S6 |
| D9 | 결과물 열람 정지(bw05-01d) 때 배송 리스트도 막나 | 정지 사양서에서 정한다. 이번에는 막는 자리를 서버 판정 한 곳(`_shipping_list_open_for_brand`)으로만 둔다 | 정지가 배송을 막으면 회원이 제품을 못 받는다 — 제재 설계의 몫 | S2 |
| D10 | 운영팀(관리자) 배송 리스트 엑셀 | 1차에 두지 않는다 | 운영팀은 화면에서 보고 고친다. 주소 든 관리자 파일을 늘리지 않는다(사양서 ② 결정 1). 두게 되면 R2 기록 대상 + 「사내용」 첫 줄 | S3·R2 |
| D11 | 브랜드 계정 0명일 때 「전달」 | 단추를 흐리게 하고 바로 옆에 「이 브랜드에 비밀번호를 정한 계정이 없어 전달할 수 없습니다」 + 브랜드 상세 바로가기 | 피그마는 토스트만이다. 누르고 나서야 알면 원인을 찾으러 다른 화면을 헤맨다 | S3 |
| D12 | 자동 추가를 제공 기록으로 | 선결 Q3 | 선결 Q3 | S1 |
| D13 | 택배사 「송장 조회 주소」 칸 | 1차에 두지 않는다 | `lookup_values` 에 칸이 없어 표 변경이 필요하다. 지금 그 주소를 쓰는 화면이 없다 | S1·S4 |
| D14 | 기한 「3일」 세는 법 | 기한일 = 들어간 날 + 3일(일본 날짜). 그날까지는 「발송 전」, 다음 날부터 「기한 지남」. 예: 10/1 전달 → 10/4 까지 | 들어간 날 포함으로 읽으면 하루 짧아진다. 오리엔시트 안내 「전달 후 3일 이내」와 같은 뜻 | S2·S3·S5 |
| D15 | 취소 뒤 다시 선정된 줄 | 같은 줄을 살린다. 다시 선정되면 `added_at` 은 늘 다시 찍고(「새로 추가」 표시 — D4), `added_on`(기한 기준)은 송장이 없을 때만 다시 선정된 날로 바꾼다 | 의심 7 — 되살아나자마자 「기한 지남」 방지 | S1 |
| D16 | 열람 기록 합치기 | 같은 계정·캠페인·종류(열람)는 30분 안이면 새 줄을 만들지 않는다(합치기는 `_record_brand_provision` 한 곳 — `service_record_brand_provision` 은 그것을 부른다). 내려받기·전달은 매번 | 의심 1 · 운영 데이터베이스가 가장 작은 사양. 법 기록에는 「언제 처음 봤나」가 남는다 | P1·R1·S2 |
| D17 | 관리자 민감정보 열람 기록 자리 | 선결 Q4 | 선결 Q4 | R2 |
| D18 | 기록 대상 관리자 엑셀 | 선결 Q5 | 선결 Q5 | R2 |
| D19 | 캠페인 매니저의 주소·전화 | 선결 Q2 | 선결 Q2 | S2·S3 |
| D20 | 메일 링크 모양 | `PUBLIC_BRAND_URL/brand/?shipping=<캠페인 번호>` — 오리엔시트 메일(`?orient=`)과 같은 방식(세션 저장소에 옮기고 로그인 뒤 연다). 들어오면 `#campaigns/<번호>/shipping` 으로 바꾼다 | 해시가 로그인을 거쳐 남는지 확인되지 않았다. 이미 검증된 방식을 쓴다 | S5·S7 |
| D21 | 줄 번호 모양 · 다른 캠페인 파일 판별 | 줄 번호 = 캠페인 안 일련번호(1, 2, 3…, 다시 쓰지 않음). 다른 캠페인 판별 = 1행 안내 줄의 캠페인 번호 | 36자 고유 번호는 엑셀에서 다루기 어렵다. 화면 「No」와는 다르다(피그마 bw05-03a) | S1·S6 |
| D22 | 여러 줄 반영 중 충돌 | 한 거래로 처리하고 충돌·취소 줄만 건너뛴 뒤 그 목록을 돌려준다 | 사양서 ① §4-3 「반영 안 됨은 건너뛴다」·「다시 검사」. 전부 실패로 돌리면 한 줄 때문에 나머지를 다시 해야 한다 | S2·S6 |
| D23 | 메일 문의처 줄(KakaoTalk·TEL) | 새 메일에는 넣지 않고 「브랜드 페이지 문의」 한 줄로 둔다 | 기존 양식의 개인 카카오 아이디·휴대전화 하드코딩은 「확인 필요」 상태다. 사본을 늘리지 않는다 | S7 |
| D24 | 브랜드 화면 전화번호 표시 | 회원이 적은 그대로 | 브랜드 빌드에 `formatPhoneDisplay` 가 없다. 사본을 만들면 판정이 한 벌 더 생긴다 | S5·S6 |
| D25 | 탈퇴 확정으로 이름이 빈 「취소됨」 줄 | 「탈퇴한 회원」으로 보인다(줄은 남긴다). 서버(`_shipping_rows_payload`)는 이름 `null` + `withdrawn:true` 칸을 주고, 화면(S3·S5)과 엑셀(S6)이 그 문구로 바꾼다 | 520 이 이름을 비운다. 빈 줄이면 「어디 갔지?」가 된다 | S2·S3·S5·S6 |
| D26 | 배송 탭 기록을 누가 보나 | 초록 요약 줄(마지막 전달·마지막 열람 시각)은 배송 권한이 있는 모두. 모달(사람 목록)은 최고 관리자만 — 다른 등급은 「기록 보기는 최고 관리자만」 | 사양서 ② 「읽기는 최고 관리자만」과 피그마 a05-11(배송 탭 안 모달)이 부딪힌다 | P1·S2·S3 |

---

## 사용자 확인 결과 (2026-10-20 — 모두 추천대로)

| # | 결정 |
|---|---|
| Q1 | 관리자 기록 장치는 **브랜드 묶음과 함께** 운영에 낸다(R2 는 `IS_STAGING` 아래) |
| Q2 | 캠페인 매니저의 배송 탭 주소·전화는 **민감정보 권한을 따른다**(숨김 등급은 서버가 비움 · 송장 입력·전달은 됨) |
| Q3 | 전달 뒤 자동 추가도 **제공 기록에 남긴다**(`shipping_auto_add`) |
| Q4 | 관리자 민감정보 열람 기록은 **인플루언서 상세 창을 연 순간**(실패해도 창은 열림) |
| Q5 | 기록 대상 관리자 엑셀은 **인플루언서 정보가 든 13개**(내보내기 함수 14개 중 브랜드 서베이 엑셀만 뺌) |
| Q6 | (운영 반영 전 `/약관확인` — L1 ⓪에서) |
| D23 | 배송 메일 문의처는 **「문의는 브랜드 페이지에서」 한 줄**(개인 카카오 아이디·휴대전화 넣지 않음) |
| D1~D26 | 나머지 기본값은 **추천값으로 시작**(화면을 본 뒤 고칠 것은 그때) |

> 마이그레이션 번호: 2026-10-20 사용자 — 다른 세션도 마이그레이션을 만들 예정이라 그쪽이 `dev` 에 들어간 뒤 P1 번호를 정한다.

---

## 구현 결과 (개발 세션이 채울 것)

| 조각 | 실제 마이그레이션 번호 | 병합 요청 | 개발서버 | 운영 | 비고(계획과 달라진 것) |
|---|---|---|---|---|---|
| P1 | 552 | #2177 | 2026-10-20 적용 · 확인 1~6단계(권한·표 보안·서버 전용 기록 — 중복 제거·30분 합치기·엑셀 새 줄·다른 브랜드 거부·최고 관리자 콘솔 쓰기·읽기·잘못된 값 거부·520 무관) — 시험 줄 지움. 캠페인 관리자·매니저 거부는 미확인(다른 계정 로그인 필요) | 보류(L1) | 판단 J1~J8(파일 머리말) — 합치기 때 새 사람·열은 기존 줄에 덧붙임, 서비스 전용 함수가 계정 연결 검사, 사람 목록 중복 제거 |
| P2 | 553 | (병합 요청 번호) | 2026-10-20 적용 · 예약 1건(UTC 18:00 켜짐)·실행 권한 postgres 만 · 시험 줄 넷(기간 안·밖 × 두 표) → `{provision_deleted:1, access_deleted:1}`, 기간 안 둘만 남음 — 시험 줄 지움 | 보류(L1) | 예약 시각: UTC 18:00(도쿄 03:00) — 작업표 예시 03:45(UTC 18:45)는 423 이 쓰고 있어 바꿈. 반환은 jsonb |
| S1 | | | | 보류(L1) | |
| S2 | | | | 보류(L1) | |
| R1 | | | | 보류(L1) | |
| S3 | (없음) | | | 보류(L1 — `_brandAccountEnabled()`) | |
| S4 | (없음) | | | 보류(L1) | |
| S5 | (없음) | | | 보류(L1) | |
| S6 | (없음) | | | 보류(L1) | |
| S7 | (없음) | | | 보류(L1) | |
| R2 | (없음) | | | 보류(L1 — `IS_STAGING`) | 기록 대상 엑셀 수: |
| R3 | (없음) | | | 보류(L1) | |
| L1 | | | | | 방침 개정일: · 공지 게시일: |
