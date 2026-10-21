# 📋 작업 분해표 — 관리자 브랜드 상세 탭 4개 재구성 (브랜드 페이지 1차와 같은 날 출시)

**사양서:** `docs/specs/2026-10-21-admin-brand-detail-tabs.md` (결정 원문: `docs/specs/2026-07-15-brand-portal.md` §16-4 · §16-2 머리 「낱말」 · §16-7 · §16-8)
**정본 화면:** 피그마 「레버브시딩_브랜드」 Admin 페이지 — `[1차] a03-1 브랜드 상세 탭`(659:523) · `a03-2 브랜드 계정`(659:524) · `a03-3 회사·담당자 수정`(659:525). `a03-4 이용 제한`(686:584)은 범위 밖
**양식:** 직전 작업표 `docs/specs/2026-10-16-brand-info-page-breakdown.md` · `docs/specs/2026-10-16-brand-orient-tab-breakdown.md`
**분해일:** 2026-10-21
**총 작업 조각:** 18개 · **병렬 가능:** 6개(데이터베이스 흐름 1·2·3 과 화면 흐름 5·6·9 가 서로 동시에) · **순차 필수:** 12개

> **화면 문구:** 관리자 화면이라 한국어. 일본어 문구 없음.
> **마이그레이션 번호:** 미리 정하지 않는다(「새 마이그레이션(번호는 작성 시 확정)」). 지금 마지막 번호는 **572**. 572 이후 새 파일은 기록 표 양식(`BEGIN;` … 자기 기록 줄 … `COMMIT;`, `.claude/rules/supabase.md` 「새 파일 양식」)이어야 병합 요청 검사를 통과한다.
> 🔴 **데이터베이스 먼저, 화면 나중** — 화면이 없는 서버 함수를 부르면 브랜드 저장이 통째로 멈춘다.

---

## 현재 상태 (2026-10-21, 코드·마이그레이션 직접 확인)

### 사양서가 「착수 때 확인」으로 남긴 셋 — 지금 확인한 결과

**① `brands.contacts` 담당자 줄 아이디** — **있다. 칸 이름 `id`, 글자(text) 값.**
| 만드는 자리 | 값 |
|---|---|
| 084(파일 이름 086) 칸 신설 때 옛 `primary_*` 이전 | `gen_random_uuid()::text` |
| 087·397 공개 신청서 `submit_brand_application`(새 브랜드 삽입) | `gen_random_uuid()::text` |
| 091 `admin_create_brand_application`(대표 줄 갱신·추가) | `gen_random_uuid()::text` |
| 531 `_brand_contacts_mark_primary`(서버 대표 표시 이동 때 새 줄) | `gen_random_uuid()::text` |
| 관리자 화면 `_genContactId()`(admin-brand.js 1537) — `addBrandContact` 와 `renderBrandDetailFormHtml`(1765 `c.id \|\| _genContactId()`) | 보통 uuid, 브라우저가 못 만들면 **`c-<시각>-<난수>`**(uuid 아님) |
| `osSaveIssuedContact`(admin-orient.js 874) | `_genContactId()` 또는 `c<n>_<이메일>`(uuid 아님) |

- **아이디 없는 줄이 생길 수 있는 길**: 관리자 화면은 아이디 없는 줄을 그릴 때 **그 자리에서 새 아이디를 붙이고 저장하면 통째로 덮어** 남긴다 — 그래서 한 번이라도 상세 「저장」을 거친 브랜드는 아이디가 있다. 남을 수 있는 것은 **SQL(데이터베이스 조회문)로 직접 넣은 줄·저장을 한 번도 안 한 옛 브랜드**뿐. 533 시험 데이터처럼 `'k1'` 같은 짧은 글자 아이디도 있다.
- → **새 함수(5-2)의 줄 아이디 인자는 uuid 가 아니라 text 여야 한다.**
- **운영·개발 건수는 착수 때 SQL 편집기로 센다**(선결 S4 — 조회문은 그 줄에).

**② `brands` 직접 고치기(UPDATE) 정책** — **082 `brands_update_admin`: `is_admin()`(캠페인 매니저 포함 관리자 전원), 모든 칸.** 082 이후 `brands` 정책을 바꾼 마이그레이션 없음(526~572 포함 전수 — 이름 `brands_*_admin` 은 082 에만). 직접 고치는 화면 자리 **셋**:
| 자리 | 무엇을 보내나 |
|---|---|
| `updateBrand`(storage.js 3473) ← `saveBrandDetail`(admin-brand.js) | `contacts` 통째 + 소개·어필·Qoo10 + 이름·회사·상태 |
| `updateBrand` ← `osSaveIssuedContact`(admin-orient.js 865) | `contacts` 통째(대표 표시 이동 포함). ⚠️ 계정 모드(개발서버)에서는 응답이 `recipients[]` 라 이 갈래에 **도달하지 않는다** — 운영(계정 모드 꺼짐)에서만 산다 |
| `assignBrandsToCompany`(storage.js 3691, 회사 관리 일괄 할당) | `company_id` 만(⚠️ `company_name` 사본은 안 맞춘다 — 기존 틈) |

**③ 연결 요청(§16-8, 2026-10-19 「연결」 → 「연결 요청」) 서버 쪽** — 🔴 **없다.**
- `admin_link_brand_owner_account` 현재 원본 = **533**(신설). 526~572 전수에서 정의는 533 하나(527·533 외 파일은 주석·확인 조회뿐).
- 533 의 동작은 **즉시 연결**이다 — `brand_account_links` 에 활성 대표 행을 바로 넣고 대표 표시를 옮긴다. 메일은 화면이 `notify-brand-account-setup` 을 `mail_kind:'link'` 로 불러 **`brand-link-notice`(연결 안내) 양식**을 보낸다 — bw01-98 「브랜드 연결 요청」 양식이 아니다.
- **연결 요청 표 없음**(`link_request`·「연결 요청」 0건). `brand_invites`(530)는 대표가 보내는 멤버 초대 전용이다(`invited_by`·`inviter_name` NOT NULL, 역할 칸 없음).
- **「요청 취소」 함수 없음.** 브랜드 쪽 「받은 연결 요청」(bw07-00c)·메일 링크 착지·비밀번호 정하며 수락도 없다. **어느 작업표에도 없다**(`docs/specs` 에서 bw07-00c·bw01-98 이 나오는 문서는 사양서·약관 초안 넷뿐).
- 같은 문제가 하나 더: 533 `admin_upsert_brand_owner_account` 의 갈래 (1)에서 이메일이 **연결 없는 브랜드 계정**이면 그 계정을 **즉시** 이 브랜드 대표로 잇는다(533 489~499줄) — §16-8 「본인 수락」과 어긋난다.

### 그 밖에 확인한 것
| 항목 | 실제 |
|---|---|
| `admin_get_brand_account_status` | 현재 원본 **533**(527 → 533). 534~572 재정의 없음. 반환에 **연결 요청 상태 칸이 없고**, 링크 만료 시각 칸도 없다(`setup_mail_sent_at`·`setup_mail_sent_by` 만) |
| `admin_check_brand_account_email` | 533. 가드 `is_admin()`(매니저 포함) — `influencer` 면 한자 이름, `admin` 이면 관리자 이름을 그대로 준다(D6 위반) |
| 권한 `brand.account_manage` | 530 시드(최고·캠페인 관리자 `write`, 매니저 `hidden`) · 533 서버 가드 · `notify-brand-account-setup` 가드. **`ADMIN_PERMISSION_CATALOG`(shared.js 2023)에 없다** → `permLevel` 이 `'write'` 를 돌려줘 화면 판정이 아무도 안 막는다(그래서 지금 화면은 역할 하드코딩). 등록 방식 선례 = `shipping.manage`(2106줄: `server_enforced:true, staging_only:true` — 운영엔 시드가 없어 `renderPermGrid` 가 `_brandAccountEnabled()` 일 때만 그린다) + **열쇠말 네 곳**(시드 · 카탈로그 · `PERM_SUPER_SERVER_ENFORCED`(2131) · 서버 가드). 서버 상태 조회가 `can_manage` 를 이미 돌려준다 |
| 변경 이력 표 `brand_profile_history`(536) | 브랜드 **5칸만**(name·name_ja·name_en·official_instagram_url·official_x_url) + 회사 5칸. 🔴 **`company_id`·`status` 는 기록하지 않는다.** 공개 기본 열(544 `brand_publish_default_by_brand`)은 이력 표 없이 `updated_at`·`updated_by` 만. 세 곳 같은 집합(CHECK · 트리거 함수 VALUES · `AFTER UPDATE OF`) |
| 저장 충돌 선례 | 536 `update_my_brand_info(…, p_prev)` — 칸 비교 → 같으면 안 씀 → UPDATE, `stale` 은 값을 안 싣는다 |
| 담당자 줄 칸 | `id`·`name`·`phone`·`email`·`is_primary` **다섯뿐**. 사양서 5-2 의 「직함」 칸은 없다 |
| 떠날 때 확인 선례 | `campLeaveGuard`(admin-campaign-dirty.js) — 사이드바는 `navAdminPaneReload`(**`dev/admin/app.js` 77**)에서 건다. 그 자리 주석: 「`switchAdminPane` 에 두지 않는다 — 저장 성공 후 복귀·권한 리다이렉트·뒤로가기가 다 지나간다」. 뒤로가기는 `admin-core.js` 392 `popstate` 가 **주소가 이미 바뀐 뒤** `switchAdminPane` 을 직접 부른다 |
| 공개 기본 열 칸 | `renderBrandPublishDefaultBox`(admin-brand-publish.js 248) + 자기 「기본 열 저장」 `#bpBrandSaveBtn` → `saveBrandPublishDefaultFromDetail` → `admin_set_brand_publish_default_brand`(544, `report.share` 쓰기 가드) |
| 회사 모달 | `openCompanyModal`(admin-company.js 156)이 `_companiesCache` 에서 찾는다 · 권한 `canEditCompanies()` 역할 하드코딩(서버 `companies` 쓰기도 `is_campaign_admin()` 하드코딩 — 둘이 같다) · 중복은 토스트(모달 안 오류 아님) · 저장해도 `brands.company_name` 사본을 안 맞춘다(기존 틈) |
| 오리엔시트 발급 경고 | admin-orient.js 660 문구 「브랜드 상세의 「브랜드 로그인 계정」 줄에서…」 · 637 주석 「담당자·계정 탭(아직 없는 화면)을 지금 줄로 바꿔 적었다(기획 확인 필요)」 · `osGoBrandAccount` 679 → `openBrandDetail(brandId, 'brands')` |
| 운영 반영 경로 | 관리자 코드는 **다음 운영 배포(`dev` → `main`)에 함께 나간다.** 5-1·5-2 함수는 526·544 표에 기대 **운영에 미리 넣을 수 없다** → 아래 선결 S0 |

### 낱말 전파 점검 — 바뀌는 이름
찾은 방법: `메일 대기|설정 완료|계정 없음|링크 만료|메일 미발송` 을 `dev/js`·`dev/lib`·`dev/admin`·`supabase/functions/*/index.ts`·`docs/email-templates/brand-*.html` 에서 / `브랜드 로그인 계정|담당자·계정|브랜드 상세` 를 `admin-orient.js` 에서 / `BRAND_DETAIL_BACK` 사용처.

| 이름 | 쓰이는 자리 | 이번 처리 |
|---|---|---|
| 대표 계정 상태 넷(「계정 없음 · 메일 대기 · 메일 보냄 · 설정 완료」) → ⓐ~ⓔ(「계정 없음 · 메일 미발송 · 메일 보냄 · 링크 만료 · 사용 중」) | `admin-brand.js` `_brandAccountRowHtml` **한 곳**(2472~2481). 메일 양식·자주 묻는 질문·엑셀·브랜드 화면에는 없음(`admin-accounts.js` 135 「설정 완료」는 **관리자 초대** 배지 — 별개, 안 바꿈) | 조각 10 이 새 이름으로 |
| 「브랜드 로그인 계정」 줄 → 「담당자·계정」 탭 | `admin-orient.js` 660 문구 · 637·676 주석 | 조각 5 |
| 돌아가기 「브랜드 관리로 / 운영 현황으로 / 브랜드 서베이로」 → 「목록」 | `BRAND_DETAIL_BACK`(admin-brand.js 37) · `renderBrandDetailPaneHeadHtml` | 조각 5(새 페이지에서만 — 옛 경로는 조각 18 에서 삭제) |
| 「브랜드 상세 모달」(문서) | `CLAUDE.md` 브랜드 서베이 절 · `.claude/rules/brand-admin.md` | 조각 16 |
| `saveBrandDetail` 에 공개 기본 열을 넣지 않는다(규칙) | `.claude/rules/brand-account.md` · `admin-brand-publish.js` 181 주석 | 조각 7(주석) · 16(규칙) |

---

## 의심·경우의 수 (반대론자)

1. **(배포·운영) 🔴 이 화면은 출시 날 전에 운영으로 새어 나간다** — 관리자 코드는 다른 작업의 운영 배포에 실려 나가는데, 새 저장 함수(5-1·5-2)는 526·544 가 없는 운영 데이터베이스에 넣을 수 없다. 그대로 두면 **운영 브랜드 저장이 통째로 실패**한다. → 선결 S0.
2. **(약관·데이터) 🔴 「연결 요청」이 서버에 없다** — 사양서 5-6 은 「취소 함수만 확인」으로 적었지만 요청·수락·메일·브랜드 쪽 화면이 통째로 없다. 533 을 그대로 쓰면 **본인 수락 없이 연결**(이용약관 초안 제5조 5항 위반). → 선결 S1.
3. **(사용 흐름) a03-10 「누가·언제」를 못 채우는 칸이 셋** — 회사·상태·공개 기본 열은 이력이 없다. → 선결 S2.
4. **(데이터) 서버 대표 이동과 화면 사본 어긋남** — 사양서 6절 ③ 그대로. 조각 10 이 담당자·계정 탭을 누를 때마다·계정 동작 뒤마다 `contacts` 를 새로 받는다.
5. **(데이터) 담당자 이름을 고치면 계정 이름도 바뀌나** — 533 `admin_upsert` 의 같은-이메일 갈래는 담당자 이름·연락처를 **`brand_accounts` 로 덮어** 맞춰 왔다. 그런데 브랜드 계정 본인은 마이페이지에서 자기 이름을 고친다. 새 담당자 함수(5-2)가 이어서 덮으면 본인이 고친 이름이 관리자 저장으로 되돌아간다. → 선결 S7. → **S7=B 로 결정(2026-10-21)** — 계정 관리 권한이 있는 관리자가 저장할 때만 함께 바뀐다.
6. **(권한) 직접 고치기 길이 셋** — 화면만 바꾸면 옛 캐시 화면·콘솔이 `contacts` 를 통째로 보낼 수 있다. 정책을 통째로 닫으면 회사 일괄 할당이 죽는다. → 선결 S5.
7. **(사용 흐름) 뒤로가기는 「가로채기」가 아니라 「되돌리기」다** — `popstate` 는 주소가 이미 바뀐 뒤 온다. 「머물기」면 주소를 `#brand-detail` 로 다시 밀어 넣어야 한다(회원 앱 `restoreActivityHash` 와 같은 방식). 사양서 4-9 「한 곳」은 실제로 **자리 넷**(사이드바 `navAdminPaneReload` · 뒤로가기 `popstate` · 브랜드 상세를 다시 여는 진입 · 캠페인 줄).
8. **(사용 흐름, UX) 탭으로 나눴는데 브랜드 정보 칸이 지워지는 길** — 머리 요약 줄·탭 숫자를 다시 그리는 함수가 브랜드 정보 영역에 손대면 고치던 값이 사라진다(사양서 6절 ②). 리뷰 의뢰 때 지목한다.
9. **(사용 흐름) 저장 충돌 시각 비교는 기기 시계에 기댄다** — 「연 뒤의 이력 줄」을 기기 시각으로 자르면 시계가 틀린 컴퓨터에서 줄이 빠진다. → 개발 기본값 4(값으로 비교).
10. **(권한) 회사 모달 권한 판정이 둘** — 사양서는 `company.cud` 쓰기로 적었지만 서버는 `is_campaign_admin()` 하드코딩이다. 권한 관리에서 바꾸면 「보이는데 저장 실패」. → 개발 기본값 5.
11. **(데이터) 운영의 옛 경로가 담당자를 고친다** — `osSaveIssuedContact`·091 `admin_create_brand_application`(대표 줄 덮기, 생성 단추는 비활성)이 D9 잠금을 모른다. 출시 뒤에는 둘 다 도달하지 않지만, 조각 15 의 서버 막기가 들어간 뒤 **계정 모드가 꺼진 환경에서는 그 길이 오류**가 된다.
12. **(운영) 하루에 바뀌는 화면이 크다** — 관리자 공지·Notion 관리자 가이드(조각 17).

**현재 구현과 충돌하는 지점:** ①533 즉시 연결(위 2) ②`BRAND_DETAIL_BACK`·「저장」이 머리에 있음 ③`_brandAccountAfterBrandSave` 자동 발송 ④공개 기본 열의 자기 저장 단추와 규칙 문구 ⑤`campLeaveGuard` 주석의 「`switchAdminPane` 에 두지 말 것」(위 7 — 같은 자리 원칙을 따른다) ⑥`openCompanyModal` 캐시 의존 ⑦082 정책(관리자 전원 모든 칸).

---

## ✅ 개발 기본값 (묻지 않고 알림 — 바꾸려면 말해 주세요)

| # | 기본값 | 근거 | 조각 |
|---|---|---|---|
| 기본값 1 | 담당자 줄 아이디가 빈 줄은 **담당자 함수 마이그레이션 안에서 한 번에 새 아이디를 붙인다**(멱등). 함수도 아이디 없는 줄을 만나면 `contact_not_found` 로 거부(조용히 넘기지 않음) | 화면이 아이디 없이 줄을 가리킬 방법이 없다 · `contacts` 는 이력 트리거·이름 동기화 트리거 대상 칸이 아니라 부작용 없음 | 2 |
| 기본값 2 | 계정이 없을 때 대표 줄을 지우면 **남은 첫 줄이 대표**(지금 `removeBrandContact` 규칙). 첫 담당자 추가는 자동 대표(지금 `addBrandContact` 규칙) | 「대표는 늘 한 명」 | 2·12 |
| 기본값 3 | 공개 기본 열 저장은 새 브랜드 정보 함수가 **544 `admin_set_brand_publish_default_brand` 를 안에서 부른다**(사본을 만들지 않는다) | 형식 검사·권한 가드가 그 함수에 있다 | 3 |
| 기본값 4 | a03-10 의 「바뀐 칸」은 **시각이 아니라 값으로** 정한다 — 다시 받은 서버 값과 연 순간 값(`p_prev`)이 다른 칸. 「누가·언제」는 그 칸의 **가장 최근 이력 줄** | 기기 시계에 기대지 않는다(의심 9) | 8 |
| 기본값 5 | 회사 모달 「수정 / 보기」 판정은 **`canEditCompanies()`**(서버 쓰기 기준과 같은 역할 판정). `company.cud` 로 바꾸는 것은 회사 관리 화면과 함께(후속) | 의심 10 | 9 |
| 기본값 6 | 계정 버튼 표시 판정은 **서버 상태 조회의 `can_manage`** 하나(카탈로그 등록은 권한 관리 화면용). 조회 실패면 버튼 없음 | 판정 사본을 만들지 않는다 · 실패를 「권한 있음」으로 그리지 않는다 | 10·11·13 |
| 기본값 7 | ⓒ「~까지 유효(예상)」·ⓓ「링크 만료」는 화면 상수 `BRAND_SETUP_LINK_HOURS = 24` **한 곳**에서 `setup_mail_sent_at` 으로 계산. 운영 인증 설정 24시간(관문 7)이 출시 날 서버 함수보다 먼저라 출시 뒤 바로 켜도 된다 | 표시 전용 · 인증 서비스 설정값이라 서버 칸이 없다 | 10 |
| 기본값 8 | 새 서버 함수 결과에 사양서 목록 밖 거부 하나를 더한다 — 브랜드 정보 함수 `invalid_input`(받지 않는 열쇠·빈 이름·없는 상태 값), 담당자 함수 `primary_email_required` 등(조각 2 표) | 「조용히 버리지 않는다」(사양서 5-1) | 2·3 |
| 기본값 9 | 담당자 모달 삭제 확인은 「확인만」(이름 재입력 없음) | 사양서 4-5 | 12 |

---

## ✅ 사용자 결정 (2026-10-21 — 아래 「사용자 확인 필요」 Q1~Q6 의 답)

| # | 결정 | 이 표에서 바뀌는 것 |
|---|---|---|
| S0 | **A — 개발서버만 새 화면**(새 파일 + `openBrandDetail` 맨 앞 한 줄 `_brandAccountEnabled()` 분기). 운영은 출시 날까지 지금 페이지 | 조각 5 그대로 · 조각 18(출시 뒤 옛 경로 정리) 살아 있음 |
| S1 | **A — 연결 요청은 별도 사양서·작업표**(기획). 이 표의 조각 4 는 「계약 확인」만, 조각 13 은 그 서버 조각이 개발서버에 들어간 뒤 착수. 조각 1 의 「브랜드 계정 즉시 재연결 갈래 닫기(`conflict_brand`)」는 한다 | 조각 4 = 별도 작업표 소관 · 13 보류 가능 |
| S2 | **A — 이력에 `company_id`·`status` 칸 더하기** + 공개 기본 열은 `updated_by`·`updated_at` | 조각 3 의 세 곳 수정 포함 |
| S3 | **직함 칸 만들지 않음**(지금 다섯 칸) | 사양서 5-2 문구만 |
| S4 | (셈 — 결정 아님) 착수 때 조각 2 세션이 개발·운영에서 센다 | — |
| S5 | **A — 담당자 칸만 서버가 거부하는 트리거**(SECURITY INVOKER) | 조각 15 |
| S7 | **B — 함께 바꾸기**(추천과 다름). 대표 줄 이름·연락처 저장이 활성 대표 계정의 이름·연락처도 맞춘다 — 계정 관리 권한이 있는 관리자가 저장할 때만(메인 기본값) | 조각 2 계약·완료 정의 |
| S6·S8 | 피그마 정리(기획 먼저) · 시험 데이터(조각 14 전) — 결정 아님 | — |

## 🔀 오전 작업표에서 옮겨 온 것 (2026-10-21 합치기 — 사용자 결정)

> 같은 날 오전 다른 세션이 같은 기능의 작업표(`feature/관리자-브랜드상세-작업표` 브랜치, 커밋 28d2591a, 병합 안 됨)를 만들었다. 사용자가 **이 작업표를 정본으로 두고 오전 것의 확인 사실만 옮기기**로 했다. 부딪힌 셋(연결 요청 · 뒤로가기 · 「삭제」 자리)은 다시 물어 **모두 이 작업표 쪽**(별도 작업표 · 확인 창 · 「…」 메뉴)으로 정해졌다. 오전 작업표의 연결 요청 인계는 `docs/specs/2026-10-21-brand-link-request-handoff.md` 로 옮겼다.

| # | 옮긴 사실·결정 | 반영 조각 |
|---|---|---|
| M1 | 🔴 **옛 대표 칸 셋(`primary_contact_name`·`primary_phone`·`primary_email`)이 안 맞춰지는 길이 이미 있다** — 531 `_brand_contacts_mark_primary` 는 `contacts` 만 고쳐 **브랜드 목록 「대표 담당자」 열이 옛 사람으로 남는다**. 담당자 함수뿐 아니라 이 도우미도 같은 마이그레이션에서 옛 칸 셋을 맞추게 재정의한다(베이스 531 — 현재 원본 확인 후) | 2 |
| M2 | **떠나는 길은 일곱**(코드가 가로채는 자리는 넷 — 조각 6 계약. 길 여럿이 같은 자리를 지난다) — 사이드바 · 「목록」 · 캠페인 탭 줄 · 오리엔시트 상세의 「이 카드로 발행」(`admin-orient.js` 2247 `switchAdminPane('add-campaign')` — 상세 창이 페이지 **위에** 떠서 「아직 페이지 안」으로 느낀다) · 「제공 기록」(`openPrivacyLogs`) · 다른 브랜드 상세 열기(발급 창·배송 탭) · 신규 등록 모달(`openNewBrandModal` 이 페이지 본문을 비운다) + 브라우저 뒤로가기. 전부 같은 확인을 거친다 | 6 |
| M3 | **새 페이지 입력칸은 다른 아이디 접두어** — 신규 등록 모달(`#brandDetailModal`)이 `brandFormName` 등 같은 아이디를 쓰면 문서 순서상 앞의 것을 읽어 엉뚱한 값이 저장된다(09-23 사양 2-2) | 5·7 |
| M4 | 캠페인 매니저에게도 머리 「오리엔시트 발급」을 보인다(지금과 같다 — 오전 결정 4~20 중) | 5 |
| M5 | 회사 모달 「이 회사에 속한 브랜드 N개에 함께 바뀝니다」의 N 은 **브랜드 화면(작업표 2026-10-16 D3)과 같은 기준(활성 브랜드만)** — 같은 회사 안내가 화면마다 다른 숫자가 되지 않게(메인 기본값, 사양서 4-4 의 `total_brands` 표기는 이것으로 읽는다) | 9 |
| M6 | a03-93 ⑤ 문구 「오리엔시트 없음 — 하단 「오리엔시트 발급」으로…」의 「하단」은 이미 틀렸다(머리 단추) → 「머리의 「오리엔시트 발급」으로 만듭니다」 | 5 |
| M7 | 「마지막 접속」을 관리자 화면에 처음 띄운다 — 이용 기록이라 운영 관문 10번(`/약관확인`·보관 기간) 판단에 넣는다. 개발서버만이라 착수는 막지 않는다 | 17 |
| M8 | 🔴 **개발자 두 명 규칙**(`.claude/rules/two-developers.md`) — 데이터베이스 세션은 533·531 함수·`brand_profile_history`·`brands` 트리거를 다시 정의하기 **전에** 사용자를 통해 상대 개발자에게 알린다(같은 함수를 따로 정의하면 나중 적용이 앞 변경을 조용히 지운다). 운영 병합은 병합 직전 상대 확인 | 1·2·3·15 · 17 |
| M9 | 09-23 사양서 머리에 「16-4·2026-10-21 사양서가 대체」 한 줄 · CLAUDE.md 「🔴 관리자 화면이 브랜드가 고친 값을 되돌린다 — 막는 것은 묶음 ③」을 「개발서버는 막힘 · 운영은 출시 때」로 | 16 |
| M10 | 피그마 a03-00 저장소 참고 「브랜드 계정·멤버 표와 서버 함수는 새로 만든다」·a03-00a 「가입 트리거 420 · `invite_admin` 417」은 낡음(530~533·526·528 이 있다) — 기획 몫(사양서 10절 목록에 더한다) | S6 |

## 🚦 착수 전 선결 조건 (작업표보다 먼저)

> 아래 표의 선택지(A/B/C · 「추천」)는 **질문 당시 원문**이다. 고른 답은 바로 위 「✅ 사용자 결정」 표가 정본.

| # | 선결 조건 | 근거 | 막는 조각 |
|---|---|---|---|
| **S0** | 🔴 **이 요청은 현 배포 구조와 맞지 않는 점이 있다 — 의도 재확인 필요.** 「동시 출시」(D1)인데 관리자 코드는 출시 날 전 운영 배포에 실려 나가고, 새 저장 함수는 운영에 미리 못 넣는다. 고를 것: **A(추천)** 새 페이지를 새 파일(`dev/js/admin-brand-detail.js`)에 만들고 `openBrandDetail` 맨 앞 **한 줄**이 `_brandAccountEnabled()` 일 때만 새 페이지로 보낸다 — 운영은 출시 날까지 지금 페이지 그대로, 출시 날 판정을 걷는 순간 바뀐다(사양서 6절 ⑩ 「같은 판정 하나」와 같다). 대가: 출시 뒤 옛 경로 정리 조각(18) / **B** 이 작업 전부를 `dev` 가 아닌 통합 브랜치에 모으고 미리보기 배포 주소(개발 데이터베이스로 붙는다)로 확인, 출시 날 한꺼번에 병합 — `admin-brand.js` 를 다른 브랜드 작업이 계속 만져 충돌이 쌓인다 / **C** 출시 날까지 운영 배포를 골라 담기로만 — 모든 운영 배포가 무거워진다 | 의심 1 · `release-timing.md` §4 | 5 이후 전부 |
| **S1** | 🔴 **「연결 요청」을 어디서 만들까.** **A(추천)** 브랜드 쪽 수락 길(bw07-00c 받은 요청 · bw01-98 메일과 그 링크 착지 · 비밀번호 정하며 수락)까지 포함한 **별도 사양·작업표**(기획 → `/작업분해`)로 만들고, 이 표의 조각 4·13 은 그 서버 조각이 개발서버에 들어간 뒤 착수 — 이 표는 아래 조각 4 의 「계약」만 넘긴다 / **B** 이 작업표에 서버·브랜드 화면까지 넣는다(조각이 8개쯤 늘고 브랜드 앱 파일이 섞인다) / **C** 1차는 533 즉시 연결로 낸다 — 약관 초안 제5조 5항과 어긋나 **출시 관문 1(`/약관확인`)을 통과 못 한다**. 어느 쪽이든 조각 1 의 「브랜드 계정 즉시 재연결 갈래 닫기」는 필요(C 만 예외) | 현재 상태 ③ · 의심 2 | 1(갈래 하나) · 4 · 13 · 2(잠금 판정 확장) · 14 일부 |
| **S2** | **a03-10 에서 회사·상태·공개 기본 열은 「누가·언제」를 어떻게.** **A(추천)** 이력 표에 `company_id`·`status` 를 더한다(536 세 곳 같은 집합을 한 마이그레이션에서) + 공개 기본 열은 「누가·언제」 칸에 `updated_by`·`updated_at`(이력 없이 마지막 저장자만) / **B** 셋 다 「—」(바뀐 사실만) | 현재 상태 · 의심 3 | 3 · 8 |
| **S3** | 사양서 5-2 「직함 등」 — **칸을 새로 만들지 않는다**(지금 다섯 칸) 로 확인 | 현재 상태 「담당자 줄 칸」 | 2 · 12 |
| **S4** | **운영·개발 데이터 셈**(SQL 편집기, 한 줄씩 순차 — 사용자에게 안내): ① `SELECT count(DISTINCT b.id) AS brands, count(*) AS rows FROM public.brands b, jsonb_array_elements(CASE WHEN jsonb_typeof(b.contacts)='array' THEN b.contacts ELSE '[]'::jsonb END) e WHERE NULLIF(btrim(COALESCE(e->>'id','')),'') IS NULL;` ② 한 브랜드 안 아이디 겹침: `SELECT b.id, e->>'id' AS cid, count(*) FROM public.brands b, jsonb_array_elements(CASE WHEN jsonb_typeof(b.contacts)='array' THEN b.contacts ELSE '[]'::jsonb END) e GROUP BY 1,2 HAVING count(*)>1;` ③ 배열 아닌 칸: `SELECT count(*) FROM public.brands WHERE jsonb_typeof(contacts) <> 'array';` ④ 대표 표시 둘 이상: `SELECT b.id, count(*) FROM public.brands b, jsonb_array_elements(CASE WHEN jsonb_typeof(b.contacts)='array' THEN b.contacts ELSE '[]'::jsonb END) e WHERE e->>'is_primary'='true' GROUP BY 1 HAVING count(*)>1;` ⑤ uuid 아닌 아이디 수: `… WHERE NULLIF(btrim(e->>'id'),'') IS NOT NULL AND e->>'id' !~ '^[0-9a-f-]{36}$'` | 기본값 1 · 의심 4 | 2 |
| **S5** | **직접 고치기 길을 어떻게 막을까**(사양서 5-5). **A(추천)** `brands` 에 「`contacts`·`primary_contact_name`·`primary_phone`·`primary_email` 를 로그인 사용자 직접 UPDATE 로 바꾸면 거부」하는 트리거(492 `trg_guard_influencer_owner_locked_columns` 방식 — **반드시 SECURITY INVOKER**, 판정 `current_user = 'authenticated'`). 서버 함수(정의자 권한)는 저절로 통과, 회사 일괄 할당·이름 직접 저장은 그대로 / **B** UPDATE 정책을 지우고 세 자리를 모두 함수로 / **C** 화면만 끊는다(정책 그대로 — 우회 남음). `reverb-supabase-expert` 가 확정 | 현재 상태 ② · 의심 6·11 | 15 |
| **S6** | 피그마 대조 — 조각마다 그 조각 화면 코드(조각 표 「화면」)의 칸 순서·문구 글자. 사양서 10절의 피그마 정리 6건(a03-02 설명 · 출시 범례 · a03-00b 꼬리표 · 「…」에 「삭제」 · 공개 기본 열 칸 단추 없음·a03-00e 읽기 전용 칸 · 캠페인 탭 머리 순서)은 **기획이 먼저** | 정본 | 5·7·9·10·11·12·13 |
| **S7** | **관리자가 담당자 대표 줄의 이름·연락처를 고치면 계정(`brand_accounts`) 이름·연락처도 바꿀까.** **A(추천)** 바꾸지 않는다 — 계정 이름은 본인 것(브랜드 마이페이지가 고친다), 담당자 목록은 관리자 장부 / **B** 지금(533 같은-이메일 갈래)처럼 따라 바꾼다 | 의심 5 | 2 |
| **S8** | 개발서버 시험 데이터 — 계정 상태 ⓐ~ⓔ 각 1개 브랜드(ⓓ 는 `setup_mail_sent_at` 을 SQL 로 하루 전으로) + 멤버 둘 있는 브랜드 + 담당자 0명 브랜드 + 보관 회사에 붙은 브랜드 + (S1 뒤) 연결 요청 보냄·만료·거절·취소 | 화면 상태 전부 | 14 |

---

## ⚠️ 사양서 stale 점검

1. **3절 「서버 함수는 대부분 개발서버에 이미 있다(533)」 · 5-6 「있으면 그것을」 · D11** — 연결 요청은 서버에 없고 533 은 **즉시 연결**(+ `brand-link-notice` 메일). 533 `admin_upsert` 의 브랜드 계정 갈래도 즉시 연결. → S1.
2. **5-2 「직함 등」** — 그런 칸 없음. → S3.
3. **4-6 「바뀐 칸·누가·언제는 `brand_profile_history` 에서」** — 회사·상태·공개 기본 열은 이력 없음. → S2.
4. **4-9 「가로채는 곳 = 페이지 이동 한 곳」** — 실제 자리 넷이고, 기존 원칙(「`switchAdminPane` 에 두지 않는다」)을 따라야 한다. 뒤로가기는 「되돌리기」. → 조각 6 계약.
5. **5-5 「`updateBrand` 직접 UPDATE」** — 직접 고치는 자리가 셋(`saveBrandDetail`·`osSaveIssuedContact`·`assignBrandsToCompany`). → S5.
6. **4-1 「매니저(`company.cud` 쓰기 없음)」** — 회사 쓰기는 서버가 역할 하드코딩. → 기본값 5.
7. **3절 「`admin_get_brand_account_status` 의 533 확장 칸」** — 맞다. 다만 a03-91a(요청 보냄)·「만료·거절·취소」 칩을 그릴 칸이 없다 → 조각 4 계약에 확장 칸.
8. **8절 「이 작업이 끝나야 닫히는 관문 2·5」** — 관문 2 는 조각 11(해제 화면), 관문 5 는 조각 2(서버 거부) + 12(화면 잠금) + 15(직접 고치기 막기)가 함께 닫는다.
9. **`CLAUDE.md`·`brand-admin.md` 「브랜드 상세 모달」** — 사양서가 이미 짚음(조각 16).

---

## 한눈에 보는 의존 순서

```
[데이터베이스 흐름 — 한 세션·순서대로]                 [화면 흐름 — 한 세션·순서대로(핫스팟)]
1 533 함수 둘 손보기                                    5 페이지 틀·탭 4개·「…」·들어오는 곳 (S0)
 └→ 2 담당자 한 줄 저장·삭제 + 아이디 부여                └→ 6 떠날 때 확인
      └→ 3 관리자 브랜드 정보 저장 (+S2 이력 칸)               └→ 9 회사 정보 수정 모달
           └→ 4 연결 요청 서버 계약 (S1 — 별도 작업표 권고)          │
                                                                    ▼
   (3 완료) ──────────────────────────────→ 7 브랜드 정보 탭 + 새 저장 + 공개 기본 열 합치기
                                              └→ 8 저장 충돌 확인 a03-10
   (1 완료) ──────────────────────────────→ 10 담당자·계정 탭 표 + 권한 카탈로그 + 자동 발송 제거
                                              └→ 11 계정 동작 다섯(만들기·다시 보내기·대표 바꾸기·해제·상한)
   (2 완료) ──────────────────────────────→      └→ 12 담당자 모달(대표 이동 → 11 의 a03-02)
   (4 완료) ──────────────────────────────→           └→ 13 연결 요청 화면(01c·04·04a·91a)
                                                            └→ 14 개발서버 처음부터 끝까지 확인
                                                                 └→ 15 직접 고치기 막기(S5 — 데이터베이스 흐름 세션)
                                                                      └→ 16 문서
                                                                           └→ 17 출시 날 운영 반영(관문 4번 안)
                                                                                └→ 18 출시 뒤 옛 경로 정리(S0=A 일 때만)
```
- 병렬: 데이터베이스 흐름(1→2→3)과 화면 흐름(5→6→9)은 파일이 안 겹쳐 **두 세션이 동시에** 갈 수 있다. 그 밖은 순서대로.
- 13 이 S1 때문에 늦으면 14 는 「연결 요청 빼고」 먼저 돌리고, 13 뒤 그 부분만 다시 본다.

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약(요지) | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| 1 | 533 함수 둘 손보기(5-3·5-4) | 새 마이그레이션 | `admin_upsert_brand_owner_account(uuid,text,text)` 갈래 ④ → `email_change_locked` · 브랜드 계정 즉시 재연결 갈래 → `conflict_brand`(S1) · `admin_check_brand_account_email(uuid,text)` 의 `name` = NULL(influencer·admin) | S1 | ○(5·6·9 와) | 개발(데이터베이스) |
| 2 | 담당자 한 줄 저장·삭제(5-2) | 새 마이그레이션 | `_brand_contacts_locked(uuid)` · `admin_save_brand_contact(uuid,text,text,text,text,boolean)` · `admin_delete_brand_contact(uuid,text)` · 아이디 일괄 부여 | 1 · S3·S4·S7 | ○(5·6·9 와) | 개발(데이터베이스) |
| 3 | 관리자 브랜드 정보 저장(5-1) | 새 마이그레이션 | `admin_update_brand_info(uuid,jsonb,jsonb)` → `ok\|stale\|forbidden\|duplicate_name\|not_found\|invalid_input` · (S2=A) 이력 칸 `company_id`·`status` | 2 · S2 | ○(5·6·9 와) | 개발(데이터베이스) |
| 4 | 연결 요청 서버 계약(5-6 확장) | (S1=A) 별도 작업표의 마이그레이션·서버 함수 · (S1=B) 새 마이그레이션 + 서버 함수 + 메일 양식 | `admin_request_brand_owner_link` · `admin_cancel_brand_owner_link` · `admin_get_brand_account_status` 칸 `owner_link_request` · `_brand_contacts_locked` 재정의 | 2 · S1 | ✗ | 개발(데이터베이스) / 별도 작업표 |
| 5 | 페이지 틀·탭 4개·「…」·들어오는 곳 | 새 `dev/js/admin-brand-detail.js` · `dev/js/admin-brand.js`(`openBrandDetail` 분기·`setBrandDetailTab`) · `dev/js/admin-orient.js`(두 줄) · `dev/build.sh` · `dev/admin/index.html`(원본 태그) · `dev/css/admin.css` | `openBrandDetailTabs(id, opts)` · 탭 `brandDetailTab_{info,people,sheets,camps}` · 영역 `brandDetailPane_{…}` · `#brandDetailSummaryLine` · `#brandDetailMoreBtn`·`#brandDetailMoreMenu` | S0 · S6 | ○(1·2·3 과) | 개발(화면) |
| 6 | 떠날 때 확인(a03-09) | `dev/js/admin-brand-detail.js` · `dev/admin/app.js`(`navAdminPaneReload`) · `dev/js/admin-core.js`(`popstate`) · `dev/js/admin-brand.js`(`brandDetailOpenCampProgress`) | `brandDetailDirty()` · `brandDetailLeaveGuard(go)` · `#brandDetailLeaveModal` | 5 | ○(1·2·3 과) | 개발(화면) |
| 7 | 브랜드 정보 탭 + 새 저장 + 공개 기본 열 합치기 | `dev/js/admin-brand-detail.js` · `dev/js/admin-brand.js`(새 브랜드 모달 D14) · `dev/js/admin-brand-publish.js` · `dev/lib/storage.js` | `saveBrandInfoAdmin(brandId, fields, prev)` · `saveBrandInfoTab()` · `revertBrandInfoTab()` · `#brandInfoSaveBar` | 3 · 5·6 · S6 | ✗ | 개발(화면) |
| 8 | 저장 충돌 확인(a03-10) | `dev/js/admin-brand-detail.js` · `dev/lib/storage.js` | `fetchBrandProfileHistory(brandId, fields)` · `#brandInfoConflictModal` | 7 · S2 | ✗ | 개발(화면) |
| 9 | 회사 정보 수정 모달(a03-07·07a·07b) | `dev/js/admin-company.js` · `dev/js/admin-brand-detail.js` · `dev/lib/storage.js` | `fetchCompanyById(id)` · `openCompanyModal(id, {company, notice, onSaved})` · `openBrandCompanyEdit()` · `#companyModalError` | 5 · S6 | ○(1·2·3 과) | 개발(화면) |
| 10 | 담당자·계정 탭 표 + 권한 카탈로그 + 자동 발송 제거 | `dev/js/admin-brand-detail.js` · `dev/lib/shared.js` · `dev/js/admin-brand.js`(자동 발송 호출 제거) | `renderBrandPeopleTab()` · `bdReloadPeopleTab()` · `bdMergePeopleRows(contacts, status)` · `BRAND_SETUP_LINK_HOURS` · 카탈로그 `brand.account_manage` | 1 · 5 · S6 | ✗ | 개발(화면) |
| 11 | 계정 동작 다섯 | `dev/js/admin-brand-detail.js` · `dev/lib/storage.js` | `openBrandAccountCreateModal()` · `brandAccountResend()` · `openBrandOwnerChangeModal(preAuthId)` · `openBrandAccountReleaseModal(authId)` · `openBrandMemberLimitModal()` + 저장 함수 넷 | 10 · S6 | ✗ | 개발(화면) |
| 12 | 담당자 추가·수정 모달(a03-08·08a~e) | `dev/js/admin-brand-detail.js` · `dev/lib/storage.js` | `openBrandContactModal(contactId)` · `saveBrandContact(...)` · `deleteBrandContact(...)` · `#brandContactModal` | 2 · 11 · S6 | ✗ | 개발(화면) |
| 13 | 연결 요청 화면(a03-01c·04·04a·91a) | `dev/js/admin-brand-detail.js` · `dev/lib/storage.js` | `openBrandLinkRequestModal(email)` · `cancelBrandLinkRequest()` · `requestBrandOwnerLink`·`cancelBrandOwnerLink` | 4 · 12 · S6 | ✗ | 개발(화면) |
| 14 | 개발서버 처음부터 끝까지 확인 | (코드 없음 — 고친 것은 해당 조각에) | 확인 기록 | 7·8·9·11·12·13 · S8 | ✗ | 개발(+확인 담당) |
| 15 | 직접 고치기 막기(5-5) | 새 마이그레이션 | (S5=A) 트리거 `trg_brands_guard_direct_contacts` + 함수 `_guard_brands_direct_contacts()` SECURITY INVOKER · 거부 코드 `brand_contacts_direct_write` | 14 · S5 | ✗ | 개발(데이터베이스) |
| 16 | 문서 | 사양서 「구현 결과」 · `docs/FEATURE_SPEC.md` · `CLAUDE.md` · `.claude/rules/brand-admin.md` · `.claude/rules/brand-account.md` | — | 1~15 | ✗ | 개발 |
| 17 | 출시 날 운영 반영 | (운영 데이터베이스·설정·병합) | 관문 4번 순서 안에 끼우기 | 16 · 브랜드 페이지 관문 1~10 | ✗ | 개발 + 사용자 |
| 18 | 출시 뒤 옛 경로 정리 | `dev/js/admin-brand.js` · `dev/js/admin-brand-publish.js` · `dev/js/admin-orient.js` · `dev/lib/storage.js` · `dev/lib/shared.js`(`staging_only` 걷기 — 17 에서 했으면 생략) | 옛 페이지·옛 계정 줄·`BRAND_DETAIL_BACK`·`_brandAccountAfterBrandSave`·`saveBrandPublishDefaultFromDetail`·`osSaveIssuedContact`·`updateBrand` 정리 | 17 + 운영 확인 | ✗ | 개발 |

**화면 코드(피그마) 대응:** 5 = a03-00d(틀·머리·탭) · a03-00b · a03-00c · a03-13 · a03-93 ⑤⑥⑦⑧⑨ · 6 = a03-09 · 7 = a03-00d · a03-00e · 8 = a03-10 · 9 = a03-07 · 07a · 07b · 10 = a03-00 · 00a · 00f · 91 · 92 · 93 ③④ · 11 = a03-01 · 01a · 01b · 02 · 02a · 02b · 03 · 03a · 05 · 05a · 05b · 90 · 90a · 12 = a03-08 · 08a · 08b · 08c · 08d · 08e · 13 = a03-01c · 04 · 04a · 91a

---

## 조각별 상세

### 작업 1 — 533 함수 둘 손보기 (사양서 5-3·5-4)
- **하는 일:** ①`admin_upsert_brand_owner_account` — 활성 대표가 있는 갈래 ④(설정 전 이메일 교체)를 **아무것도 안 바꾸고 거부**. 활성 대표가 없는 갈래 (1)에서 이메일이 브랜드 계정이면 **연결을 만들지 않고** `conflict_brand`(S1 이 C 면 이 줄만 뺀다). ②`admin_check_brand_account_email` — `email_kind` 가 `influencer`·`admin` 이면 `name` NULL. 나머지 본문은 533 글자 그대로.
- **담당 파일:** 새 마이그레이션 1개(572 이후 양식).
- **산출 계약:** 두 함수 모두 `CREATE OR REPLACE`(🔴 **베이스 533** — 527 을 베이스로 잡으면 532·533 의 권한 가드·칸이 사라진다). 이름·인자·반환형·실행 권한 그대로. 새 결과 값 `email_change_locked`(`needs_mail:false`, 다른 칸은 지금 값). `COMMENT` 의 결과 목록 갱신. 머리말에 「다음 재정의 베이스는 이 파일」.
- **선행 의존:** S1.
- **완료 정의:** 🔴 SQL 편집기로는 재현 안 됨(`has_permission`·`is_admin` 이 로그인 사용자 기준). 개발서버 **로그인한 관리자 화면 콘솔**에서 ①설정 전 대표가 있는 시험 브랜드의 대표 줄 이메일을 SQL 로 바꾼 뒤 `db.rpc('admin_upsert_brand_owner_account', …)` → `email_change_locked`, `brand_accounts.email` 그대로 ②연결 없는 브랜드 계정 이메일을 대표로 둔 브랜드 → `conflict_brand`, `brand_account_links` 새 행 없음 ③인플루언서 이메일로 겹침 확인 → `email_kind:'influencer'`, `name:null` / 브랜드 계정 이메일 → 이름 있음. 기록 표에 방금 시각의 줄.
- **필요 검문소:** `reverb-supabase-expert`(쓰기 전 — 533 과 줄 단위 대조) · `reverb-reviewer`.
- **주의·롤백:** 롤백 = 533 의 두 함수 블록 재실행. 다른 세션이 533 함수를 재정의 중이면 병합 요청 검사 ②가 경고한다(그때는 상대의 마지막 정의를 베이스로).

### 작업 2 — 담당자 한 줄 저장·삭제 (사양서 5-2)
- **하는 일:** 담당자 한 줄만 바꾸는 서버 함수 둘 + 「계정이 있는 동안」 판정 한 곳 + 아이디 없는 줄 일괄 부여.
- **담당 파일:** 새 마이그레이션 1개.
- **산출 계약** (함수 이름은 제안 — 작성 때 바꾸면 이 표와 조각 12 를 함께):
  - **`_brand_contacts_locked(p_brand_id uuid) RETURNS boolean`** — 내부 전용(`postgres`·`service_role` 부여 → `PUBLIC` 회수 → `anon`·`authenticated` 회수). 지금은 「활성 대표 연결 있음」. 🔴 조각 4 가 「살아 있는 연결 요청」을 OR 로 더해 **재정의**한다(판정은 이 함수 한 곳).
  - **`admin_save_brand_contact(p_brand_id uuid, p_contact_id text, p_name text, p_phone text, p_email text, p_is_primary boolean) RETURNS jsonb`** → `{result, contact_id, contacts}`(정상일 때 저장 뒤 배열 전체 — 화면 사본 갱신용). `result` = `ok` · `forbidden`(`is_admin()` 아님) · `brand_not_found` · `contact_not_found` · `name_required` · `invalid_email` · `primary_email_required`(대표 표시 켠 줄인데 이메일 빔) · `primary_locked`(잠김인데 대표 줄 이메일 변경·대표 해제) · `primary_move_needs_owner_change`(잠김인데 다른 줄로 대표 이동 — 화면이 a03-02 로). `p_contact_id` NULL = 새 줄(아이디 `gen_random_uuid()::text`, 첫 줄이면 자동 대표 — 기본값 2). 잠김 아닐 때 대표를 이 줄로 옮기면 **같은 호출에서 옛 대표 표시를 끈다**. `primary_*` 옛 칸 셋을 대표 줄로 맞춘다. 브랜드 잠금은 527·531·533 과 **같은 열쇠** `pg_advisory_xact_lock(hashtext('brand_account_upsert:' || brand))`. 🔴 **S7=B(2026-10-21 사용자 결정 — 함께 바꾸기)**: 저장한 줄이 대표 줄이고 그 브랜드에 활성 대표 계정이 있으며 이메일이 그 계정과 같으면(대소문자·공백 무시), 같은 호출 안에서 `brand_accounts` 의 이름·연락처도 그 값으로 맞춘다 — 🔴 **단 호출자가 `has_permission('brand.account_manage','write')` 일 때만**(매니저 등 권한 없는 관리자가 저장하면 담당자 목록만 바뀌고 계정은 그대로 — 계정 쪽 권한 경계를 넘지 않게. 메인 기본값, `reverb-supabase-expert` 확인 항목) — 533 `admin_upsert` 의 같은-이메일 갈래가 해 오던 동작을 이 함수로 옮긴 것. 본인이 마이페이지에서 고친 이름이 관리자 저장으로 덮일 수 있다(사용자가 알고 고름). 멤버 줄은 계정을 건드리지 않는다.
  - **`admin_delete_brand_contact(p_brand_id uuid, p_contact_id text) RETURNS jsonb`** → `{result, contacts}` · `ok` · `forbidden` · `brand_not_found` · `contact_not_found` · `primary_locked`. 잠김 아닌 대표 줄 삭제면 남은 첫 줄이 대표(기본값 2).
  - 둘 다 `SECURITY DEFINER SET search_path=''`, 실행 권한 `postgres`·`authenticated`·`service_role` 부여 → `PUBLIC` 회수 → `anon` 회수.
  - 아이디 일괄 부여(기본값 1): 빈 아이디 줄에만 `gen_random_uuid()::text`. 파일 하단 주석에 S4 셈 결과(개발·운영)를 적는다.
- **선행 의존:** 1 · S3 · S4 · S7.
- **완료 정의:** 로그인한 관리자 콘솔에서 ①새 줄 추가 → `contacts` 에 줄 하나 늘고 다른 줄 값 그대로 ②계정 없는 브랜드에서 대표 이동 → 대표 표시 정확히 1 ③계정 있는 브랜드(ⓑ~ⓔ)에서 대표 줄 이메일 변경 → `primary_locked`, 이름만 변경 → `ok` ④다른 줄로 대표 이동 → `primary_move_needs_owner_change` ⑤매니저 계정으로 이름 저장 → `ok`(사양서 4-2 「수정」은 남는다) ⑥S4 ① 조회가 0 ⑦(S7=B) 설정 완료 대표가 있는 브랜드에서 캠페인 관리자가 대표 줄 이름 변경 → `brand_accounts.name` 도 새 값 / 매니저가 같은 변경 → `ok`, 계정 이름 그대로 / 멤버 줄 이름 변경 → 계정 그대로. 함수마다 1회 실제 호출(`supabase.md` 「신규 함수는 적용 성공이 동작 확인이 아니다」).
- **필요 검문소:** `reverb-supabase-expert` · `reverb-reviewer`.
- **주의·롤백:** 롤백 = 함수 셋 `DROP`(화면 12 를 먼저 되돌린다). 아이디 부여는 되돌리지 않는다(무해). ⚠️ 091 `admin_create_brand_application` 의 대표 줄 덮기(정의자 권한)는 이 잠금을 모른다 — 생성 단추가 비활성이라 지금은 도달하지 않음을 파일 머리말에 기록만.

### 작업 3 — 관리자 브랜드 정보 저장 (사양서 5-1)
- **하는 일:** 브랜드 정보 탭 「저장」이 부를 함수. 536 브랜드 쪽 함수와 같은 3단계.
- **담당 파일:** 새 마이그레이션 1개.
- **산출 계약:**
  - **`admin_update_brand_info(p_brand_id uuid, p_fields jsonb, p_prev jsonb) RETURNS jsonb`** → `{result}`. 받는 열쇠 **여덟**: `name`·`name_ja`·`name_en`·`company_id`·`status`·`official_instagram_url`·`official_x_url`·`publish_default`(544 형식, NULL = 「전체 기본값 따르기」). 열쇠가 없으면 그 칸은 안 바꿈. 🔴 `contacts`·`description`·`appeal_points`·`official_qoo10_url`·`primary_*` 또는 그 밖 열쇠가 오면 **`invalid_input`**(조용히 버리지 않는다, 기본값 8). `publish_default` 가 왔는데 `has_permission('report.share','write')` 가 아니면 `forbidden`. 단계: ①`p_prev` 와 칸 비교(`IS DISTINCT FROM`, 빈 문자열·열쇠 없음 = NULL — 536 과 같은 규칙) → 다르면 `stale`(값 안 실음) ②같으면 쓰지 않고 `ok` ③UPDATE. `company_id` 가 바뀌면 `company_name` 사본 = 그 회사 `name_ko`(지금 화면이 하던 일). 이름 중복(`name_normalized` 23505) → `duplicate_name`. 공개 기본 열은 544 `admin_set_brand_publish_default_brand` 를 안에서 부른다(기본값 3). 가드 `is_admin()`(지금 `brands` 쓰기 정책과 같은 기준). 실행 권한은 조각 2 와 같다.
  - (S2=A) `brand_profile_history` CHECK · `record_brand_profile_history()` VALUES · 트리거 `AFTER UPDATE OF` **세 곳에 `company_id`·`status` 를 함께** 더한다(🔴 세 곳이 어긋나면 브랜드 저장이 통째로 실패 — 266 교훈). 베이스 536.
- **선행 의존:** 2(같은 세션 순서) · S2.
- **완료 정의:** 로그인 관리자 콘솔: ①이름만 보냄 → `ok`, 이력 한 줄 ②`p_prev` 를 일부러 틀리게 → `stale`, 칸 그대로 ③`contacts` 열쇠를 섞어 보냄 → `invalid_input` ④매니저가 `publish_default` 를 보냄 → `forbidden`, 이름도 안 바뀜 / 매니저가 빼고 보냄 → `ok` ⑤회사 변경 → `company_name` 사본이 새 회사명 ⑥(S2=A) 회사·상태 변경이 이력에 남는다.
- **필요 검문소:** `reverb-supabase-expert` · `reverb-reviewer`.
- **주의·롤백:** 롤백 = 함수 `DROP` + (S2=A) 세 곳을 536 판으로. ⚠️ 173 트리거(브랜드명 → 연결 캠페인 이름)·275 캠페인 판 번호 상승은 이 함수의 UPDATE 에서도 돈다(지금과 같다).

### 작업 4 — 연결 요청 서버 계약 (사양서 5-6 확장)
> 🔄 **2026-10-21 이 조각은 별도 사양서 `docs/specs/2026-10-21-brand-link-request.md` 로 대체된다** — 함수 이름·반환 값·상태 칸은 그 문서 4-2·4-6 이 정본(아래는 초안 기록으로 남긴다). 조각 13 은 그 문서의 서버 조각이 개발서버에 들어간 뒤 착수.
- **하는 일:** (S1=A) 별도 작업표의 서버 조각이 끝났는지 확인하고 아래 계약을 고정한다. (S1=B) 이 조각에서 만든다.
- **담당 파일:** (A) 별도 작업표 소관 · (B) 새 마이그레이션 + 서버 함수 + `docs/email-templates/`(bw01-98) + 동기화.
- **산출 계약** (조각 2·10·13 이 쓰는 최소 — 이름은 제안):
  - **`admin_request_brand_owner_link(p_brand_id uuid, p_email text) RETURNS jsonb`** → `{result, request_id, email_kind}` · `ok` · `forbidden`(`brand.account_manage` 쓰기 아님) · `owner_exists` · `request_exists` · `not_brand_account`(+`email_kind` — a03-04a) · `brand_archived` · `brand_not_found` · `invalid_email`. 메일은 bw01-98 한 양식, 기한 24시간.
  - **`admin_cancel_brand_owner_link(p_brand_id uuid, p_request_id uuid) RETURNS jsonb`** → `ok` · `forbidden` · `not_pending`. 보낸 관리자가 아니어도 권한만 있으면.
  - **`admin_get_brand_account_status`** 재정의(베이스 533, 반환형 jsonb 같아 `CREATE OR REPLACE`) — 기존 칸 전부 유지 + **`owner_link_request`** `{status:'pending'|'expired'|'declined'|'cancelled', email, sent_at, expires_at}` 또는 NULL(가장 최근 한 건).
  - **`_brand_contacts_locked`** 재정의 — 활성 대표 **또는** 살아 있는 요청(`pending` + 기한 안).
  - 533 `admin_link_brand_owner_account` 는 화면이 더 부르지 않는다(남길지·거부로 바꿀지는 그 작업표에서).
- **선행 의존:** 2 · S1.
- **완료 정의:** 요청 → 상태 조회에 `pending` → 취소 → `cancelled` / 24시간 지난 요청 → `expired`(SQL 로 기한을 과거로) · 요청 중 대표 줄 이메일 변경(조각 2 함수) → `primary_locked`.
- **필요 검문소:** `reverb-supabase-expert` · `reverb-reviewer` · (메일) 개발서버는 발송 시험 금지 — 두 겹 잠금 확인만(`brand-account.md`).
- **주의·롤백:** 브랜드 쪽 수락이 없으면 요청은 영원히 만료로 끝난다 — 13 을 이것 없이 내지 않는다.

### 작업 5 — 페이지 틀·탭 4개·「…」·들어오는 곳 (사양서 4-0·4-7·4-8)
- **하는 일:** (S0=A) 새 파일에 새 페이지를 만들고 `openBrandDetail` 이 개발서버에서만 그쪽으로 보낸다. 머리(「← 목록」·브랜드명·번호 칩·상태 배지·요약 한 줄·「병합」·「오리엔시트 발급」·「…」) · 탭 줄 · 오른쪽 영업 메모(지금 것). 오리엔시트·캠페인 탭은 지금 내용 그대로 옮긴다. 이 조각에서는 브랜드 정보 탭에 **지금 폼 절(기본 정보·회사·브랜드 콘텐츠·SNS·공개 기본 열)과 지금 「저장」을 임시로** 두고, 담당자·계정 탭에 **지금 담당자 줄·계정 줄을 임시로** 둔다(7·10 이 바꾼다 — 개발서버에서만 보이는 중간 상태).
- **담당 파일:** 새 `dev/js/admin-brand-detail.js` · `dev/js/admin-brand.js` · `dev/js/admin-orient.js` · `dev/build.sh`(🔴 `ADMIN_JS_FILES` 에서 `admin-brand.js` 뒤 **그리고** 원본 태그 제거 정규식 — 두 곳, `build.md`) · `dev/admin/index.html`(원본 `<script>` 태그) · `dev/css/admin.css`.
- **산출 계약:**
  - `openBrandDetail(id, from, opts)` 맨 앞: `if (_brandAccountEnabled()) return openBrandDetailTabs(id, opts || {});` — `from` 은 새 페이지에서 안 쓴다(D12).
  - `openBrandDetailTabs(id, opts)` — `opts.tab` 이 `'people'` 이면 그 탭, 아니면 `'info'`(D7 · A5). 지금 `openBrandDetail` 의 순서·대조(`_brandsCurrentId !== id` 두 번, 메모 상태 먼저 비우기, 삭제 판정 `countsKnown`)를 **그대로** 따른다.
  - 화면 요소 아이디(DOM): 탭 `#brandDetailTab_info` · `_people` · `_sheets` · `_camps`, 영역 `#brandDetailPane_info` · `_people` · `_sheets` · `_camps`(🔴 `sheets`·`camps` 는 지금 아이디 그대로 — `refreshBrandDetailSheets` 가 그 아이디로 다시 그린다), 요약 `#brandDetailSummaryLine`, 「…」 `#brandDetailMoreBtn`·`#brandDetailMoreMenu`(「삭제」 항목 아이디는 `brandDetailDeleteBtn` 그대로 — `refreshBrandDetailSheets` 의 `.remove()` 가 산다. 항목이 0개가 되면 「…」 를 지운다), 저장 안 한 표시 점 `.brand-detail-dirty-dot`.
  - `setBrandDetailTab(code)` 가 네 코드를 받는다 — 🔴 **`info` 는 표시만 바꾸고 다시 그리지 않는다**, `people` 은 누를 때마다 다시 받기(조각 10 이 채움), `camps` 는 처음 한 번(지금 그대로). `_brandDetailTab` 기본값 `'info'`.
  - `renderBrandDetailSummaryLine()` — 회사·대표 담당자·멤버 숫자(`seat_used`/`member_limit`, 「초대 대기 k 포함」은 `pending_invite_count>0` 일 때만). 상태 조회 실패·계정 기능 꺼짐이면 멤버 구절 통째 생략. 🔴 브랜드 정보 영역을 건드리지 않는다.
  - 상태 조회 보관 `_brandDetailAccountStatus`(`undefined` 아직 / `null` 실패 / 객체).
  - admin-orient.js: `osGoBrandAccount` → `openBrandDetail(brandId, 'brands', { tab: 'people' })` · 660 문구 「… 브랜드 상세의 「담당자·계정」 탭에서 대표 담당자 계정을 먼저 만들어 주십시오.」 · 637·676 주석 정리.
- **선행 의존:** S0 · S6.
- **완료 정의:** 개발서버: 들어오는 곳 다섯(브랜드 목록·서베이·운영 현황·오리엔시트 발급 경고·배송 탭)이 모두 이 페이지를 열고 첫 탭이 브랜드 정보(발급 경고만 담당자·계정) · 「← 목록」은 어디서 왔든 브랜드 목록 · 탭 전환 뒤 브랜드 정보 칸에 친 값이 그대로 · 오리엔시트 발급 → 그 탭·숫자·「…」 의 「삭제」만 바뀐다 · 오리엔시트·캠페인 조회 실패와 0건이 다르게 보인다 · 「…」 는 최고 관리자에게 「제공 기록」, 삭제 조건 맞으면 「삭제」, 둘 다 없으면 안 보임 · **운영 주소로 열면 지금 페이지 그대로**(분기 확인).
- **필요 검문소:** `reverb-reviewer`(전역 이름 충돌 — 빌드가 이어붙이기라 같은 이름이면 뒤 파일이 이긴다 · `PANE_REFRESHERS['brand-detail']` 이 새 페이지에서도 맞게 도는지).
- **주의·롤백:** 롤백 = 분기 한 줄 삭제(옛 페이지로 즉시 복귀) + 파일·빌드 목록 되돌림. `admin-brand.js`·`dev/admin/index.html`·`build.sh` 는 핫스팟 — 화면 흐름 한 세션만.

### 작업 6 — 떠날 때 확인 (사양서 4-9 · A1·A2·A3)
- **하는 일:** 브랜드 정보 탭에 저장 안 한 변경이 있으면 떠나기 전에 묻는다.
- **담당 파일:** `dev/js/admin-brand-detail.js` · `dev/admin/app.js` · `dev/js/admin-core.js` · `dev/js/admin-brand.js`.
- **산출 계약:**
  - `brandDetailDirty()` → boolean — 판정은 브랜드 정보 영역 칸의 **연 순간 기준값과 지금 값 비교**(`campDirty` 의 스냅샷 방식). 조각 7 이 칸을 바꿔도 이 이름·뜻은 유지. 새 페이지가 아니거나 화면이 `brand-detail` 이 아니면 false.
  - `brandDetailLeaveGuard(go)` — 깨끗하면 `go()`, 아니면 a03-09 창 `#brandDetailLeaveModal`(동적 생성) — 단추 「머물기」 / 「저장하지 않고 나가기」.
  - 거는 자리 넷: ①`navAdminPaneReload`(admin/app.js — `campLeaveGuard` 다음 고리로) ②`popstate`(admin-core.js — 🔴 떠나는 쪽이 `brand-detail` 이고 더러우면 먼저 `history.pushState({pane:'brand-detail'}, '', '#brand-detail')` 로 주소를 되돌린 뒤 창, 「나가기」면 원래 목적지로 `switchAdminPane`) ③`openBrandDetail` 진입(새 페이지가 떠 있고 더러운데 다른 브랜드를 열 때) ④「← 목록」·캠페인 줄(`brandDetailOpenCampProgress` 의 `confirm` 을 이것으로 — 「머물기」면 아무것도 비우지 않는다).
  - `beforeunload` 는 새 페이지가 떠 있고 더러울 때만(브라우저 기본 문구 — A2).
  - 🔴 `switchAdminPane` 안에는 걸지 않는다(저장 뒤 복귀·권한 리다이렉트가 지나간다 — 기존 원칙).
- **선행 의존:** 5.
- **완료 정의:** 브랜드명을 고친 채 ①사이드바 ②「← 목록」 ③브라우저 뒤로가기(주소가 `#brand-detail` 로 남는다) ④캠페인 줄 ⑤운영 현황에서 다른 브랜드 열기 → 다섯 모두 창 · 「머물기」면 값 그대로 · 탭 전환은 묻지 않음 · 새로고침은 브라우저 경고 · 고치지 않았으면 어디로든 바로 · 캠페인 폼의 떠날 때 확인이 그대로 동작.
- **필요 검문소:** `reverb-reviewer`(`popstate` 되돌림이 기록을 두 번 쌓지 않는지).
- **주의·롤백:** `admin-core.js`·`admin/app.js` 핫스팟 — 이 조각만 만진다.

### 작업 7 — 브랜드 정보 탭 + 새 저장 + 공개 기본 열 합치기 (사양서 4-1 · D3·D8·D13·D14)
- **하는 일:** 칸 정리(기본 정보 → SNS 정보 → 공개 기본 열) · 소개·어필·Qoo10 제거 · 「저장」을 새 함수로 · 공개 기본 열 칸 안 단추 제거 · 아래 띠·되돌리기·탭 점 · 「새 브랜드」 모달에서도 세 칸 제거(그 밖 동작 그대로).
- **담당 파일:** `dev/js/admin-brand-detail.js` · `dev/js/admin-brand.js`(`renderBrandDetailFormHtml`·`submitNewBrand` 의 세 칸 — `_brandAccountEnabled()` 일 때만) · `dev/js/admin-brand-publish.js` · `dev/lib/storage.js`.
- **산출 계약:**
  - storage.js **`saveBrandInfoAdmin(brandId, fields, prev)`** → `{ok:true, result}` | `{ok:false, error}` — `admin_update_brand_info` 호출, `retryWithRefresh`, 계정 기능이 꺼져 있으면 `{ok:false, error:'brand_account_disabled'}`.
  - `_brandInfoPrev`(연 순간 값 여덟 열쇠) · `collectBrandInfoChanges()` → 바뀐 열쇠만. 🔴 `canWrite('report.share')` 가 아니면 `publish_default` 를 **아예 안 넣는다**(의심 6절 ①).
  - `saveBrandInfoTab()` — `ok` → 띠·점 사라짐 + 토스트 「브랜드 정보를 저장했습니다.」 + 머리 배지·제목·요약 줄 + `refreshPane('brands')` + 기준값 다시 잡기 / `stale` → 조각 8 / `duplicate_name` → 지금 문구 / `forbidden` → 「권한이 바뀌어 저장할 수 없습니다. 페이지를 새로고침해 주십시오.」 / 그 밖 → 「브랜드 정보를 저장하지 못했습니다. 잠시 후 다시 시도해 주십시오.」(값 그대로).
  - `revertBrandInfoTab()` — 확인 없이 기준값으로(A4).
  - 아래 띠 `#brandInfoSaveBar`(변경 있을 때만).
  - `renderBrandPublishDefaultBox(brandId, { embedded: true })` — `#bpBrandSaveBtn` 을 안 그린다. 값은 기존 `brandPublishDefaultPickerValue('bpBrand')`.
  - 상태 선택칸은 이 탭 안(머리는 배지만 — D13).
  - 🔴 이 탭 저장은 `contacts` 를 보내지 않는다(D8) — `_collectBrandFormPatch` 를 쓰지 않는다.
- **선행 의존:** 3 · 5 · 6 · S6.
- **완료 정의:** 이름 고침 → 띠·점 → 저장 → 사라짐·목록 갱신 · 「되돌리기」 → 값 복귀·띠 사라짐 · 매니저가 이름만 고쳐 저장 → 성공(공개 기본 열 읽기 전용) · 공개 기본 열만 바꾸고 저장 → 그 값이 다음 캠페인 처음 켜기에 반영 · 저장 요청에 `contacts`·소개·Qoo10 가 없음(개발자 도구 네트워크 탭) · 「새 브랜드」 등록이 담당자 여러 줄과 함께 그대로 됨(세 칸 없음) · 같은 아이디 입력칸이 화면에 둘 안 생김(`clearBrandModalBody`·`clearBrandDetailPaneBody` 한 세트).
- **필요 검문소:** `reverb-reviewer`(공개 기본 열 인자 생략 분기 · `refreshPane` · 요약 줄 함수가 이 탭 칸을 안 건드리는지).
- **주의·롤백:** 옛 `saveBrandDetail`·`saveBrandPublishDefaultFromDetail` 은 **운영 경로라 지우지 않는다**(조각 18). `admin-brand-publish.js` 181 주석을 「새 페이지는 탭 저장으로 함께 — 옛 페이지만 자기 단추」로.

### 작업 8 — 저장 충돌 확인 a03-10 (사양서 4-6 · D5)
- **하는 일:** `stale` 을 받으면 바뀐 칸 표와 두 단추.
- **담당 파일:** `dev/js/admin-brand-detail.js` · `dev/lib/storage.js`.
- **산출 계약:**
  - storage.js **`fetchBrandProfileHistory(brandId, fieldNames)`** → 칸마다 최근 줄 배열 | `null`(실패) — `brand_profile_history` 직접 조회(관리자 읽기 정책 있음), `target_kind='brand'`.
  - 창 `#brandInfoConflictModal`(동적) — 표: 칸 이름 · 지금 값 · 내가 넣은 값 · 누가(`changed_by_name`, 없으면 「시스템」) · 언제. 바뀐 칸은 **값으로** 정한다(기본값 4). S2 에 따라 회사·상태·공개 기본 열의 누가·언제.
  - 「다시 불러와서 확인」 → `reloadBrandInfoFromServer()`(이 탭만 서버 값으로 다시 채움 · 내 변경은 버린다고 창 문구에) / 「내 값으로 저장」 → 다시 받은 서버 값을 새 `p_prev` 로 `saveBrandInfoTab()` 재시도.
  - 이력 조회 실패 → 「다른 사람이 그사이 이 브랜드 정보를 고쳤습니다」 한 줄 + 같은 두 단추.
- **선행 의존:** 7 · S2.
- **완료 정의:** 두 창(관리자 둘 또는 관리자 + 브랜드 계정의 「브랜드」 메뉴)에서 같은 브랜드 이름을 고쳐 늦게 저장 → 창에 그 칸·고친 사람·시각 · 「다시 불러와서 확인」 → 서버 값, 띠 사라짐 · 「내 값으로 저장」 → 내 값 저장 · 이력 조회를 막아 두면 한 줄 안내.
- **필요 검문소:** `reverb-reviewer`.
- **주의·롤백:** 창 z-index 는 모달 규칙(동적 모달 선례)대로.

### 작업 9 — 회사 정보 수정 모달 (사양서 4-4 · A9)
- **하는 일:** 브랜드 정보 탭 회사 요약 아래 「수정」/「보기」 → 회사 모달.
- **담당 파일:** `dev/js/admin-company.js` · `dev/js/admin-brand-detail.js` · `dev/lib/storage.js`.
- **산출 계약:**
  - storage.js **`fetchCompanyById(id)`** → 객체 | `null`.
  - `openCompanyModal(id, opts)` 확장 — `opts.company` 가 있으면 캐시 대신 그 값 · `opts.notice` 맨 위 문구 · `opts.onSaved` 를 **수정에도** 부른다(지금은 새 등록 전용). 권한은 `canEditCompanies()`(기본값 5), 보관 회사는 읽기 전용.
  - 중복 이름은 모달 안 `#companyModalError` 에(값 그대로) — 회사 관리 화면에서 열어도 같다.
  - `openBrandCompanyEdit()`(새 페이지) — 고른 회사 아이디(저장 전 바꾼 값이면 새로 고른 회사 — 4-1)로 받아 열기, 받기 실패면 열지 않고 토스트. 문구 「이 회사에 속한 브랜드 N개에 함께 바뀝니다」(N = 활성 브랜드 수 — M5).
  - 저장 뒤: 회사 요약 상자(`renderBrandCompanyInfoCardInner`) · 회사 선택칸 이름(`_rebuildBrandCompanySelect`) · 요약 줄만 · `_brandFormCompanies` 의 그 회사 갱신 · 회사 관리 목록이 보관값을 가지면 `refreshPane('companies')`. 🔴 고치던 브랜드 값은 그대로.
- **선행 의존:** 5 · S6.
- **완료 정의:** 「회사 관리」를 한 번도 안 연 새 탭에서 「수정」 → 실제 회사 값이 채워진다(빈 폼 아님) · 저장 → 요약·선택칸 바뀜, 브랜드명에 친 값 그대로 · 같은 이름 회사 → 모달 안 오류 · 매니저·보관 회사 → 「보기」만.
- **필요 검문소:** `reverb-reviewer`(회사 관리 화면 동작 회귀 — 콜백 모드 z-index).
- **주의·롤백:** ⚠️ 관리자 회사 이름 변경은 `brands.company_name` 사본을 안 맞춘다(기존 틈 — 536 브랜드 쪽은 맞춘다). 이번 범위 밖, 「구현 결과」에 후속으로 적는다.

### 작업 10 — 담당자·계정 탭 표 + 권한 카탈로그 + 자동 발송 제거 (사양서 4-2 · D6·D9·D15 · A7·A8)
- **하는 일:** 표(이름·이메일·역할·브랜드 페이지 계정·관리) — 담당자 줄 ∪ 계정 줄(대표·멤버), 같은 사람은 이메일로 묶음 · 대표 상태 ⓐ~ⓔ · 멤버 「사용 중」+「마지막 접속」 · 실패·0건 · 권한 숨김. 권한 항목 카탈로그 등록. 임시 자동 발송 제거.
- **담당 파일:** `dev/js/admin-brand-detail.js` · `dev/lib/shared.js` · `dev/js/admin-brand.js`.
- **산출 계약:**
  - shared.js `ADMIN_PERMISSION_CATALOG` 에 `{ key: 'brand.account_manage', label_ko: '브랜드 페이지 계정 관리', category: '브랜드', server_enforced: true, staging_only: true }` + `PERM_SUPER_SERVER_ENFORCED` 에 추가(🔴 열쇠말 네 곳 — 530 시드 · 카탈로그 · 이 목록 · 533·`notify-brand-account-setup` 가드. 철자 하나 다르면 조용히 거부). 주석은 `shipping.manage` 형식.
  - `renderBrandPeopleTab()` → `#brandDetailPane_people` · `bdReloadPeopleTab()`(브랜드 `contacts` + `fetchBrandAccountStatus` 다시 받기 → `_brandFormContacts` · `_brandDetailAccountStatus` · 탭 숫자 · 요약 줄 갱신 — 11·12·13 이 동작 뒤 부른다) · `bdMergePeopleRows(contacts, status)` → `[{kind:'owner'|'member'|'contact', contact, member}]`(묶는 열쇠 `_brandAccountNormEmail` — 지금 함수).
  - 대표 상태 판정 `bdOwnerState(status)` → `'none'|'mail_pending'|'mail_sent'|'link_expired'|'active'` 한 곳 · `BRAND_SETUP_LINK_HOURS = 24`(기본값 7). 「(본인 요청)」 = `setup_mail_sent_by==='self'`.
  - 버튼 표시 = `status.can_manage === true`(기본값 6). 조각 11·13 이 버튼을 채우고 이 조각은 자리와 숨김 규칙만.
  - 실패(a03-93④): 「확인 불가 / 계정 상태를 불러오지 못했습니다 / 다시 불러오기」 — 계정 버튼 전부 숨김. 🔴 실패를 「계정 없음」으로 그리지 않는다. 0명(a03-93③) 안내. 대표 줄이 없으면 카드 머리 아래 안내 줄(권한 있을 때만).
  - 「+ 담당자 추가」·「수정」 단추 자리(조각 12 가 연다), 「멤버 상한 바꾸기」 자리(11).
  - 🔴 `_brandAccountAfterBrandSave` 호출을 지운다(옛 `saveBrandDetail` 안 — 운영은 계정 기능이 꺼져 원래 아무 일도 안 했다). 회색 버튼 + 「계정 메일은 캠페인 관리자 이상이 보냅니다」 안내는 새 페이지에 만들지 않는다.
  - 🔴 이 탭의 모든 다시 그리기는 이 영역·탭 숫자·요약 줄만.
- **선행 의존:** 1 · 5 · S6.
- **완료 정의:** 시험 브랜드 ⓐ~ⓔ 각각 계정 칸이 그림과 같다(ⓓ 는 SQL 로 하루 전) · 멤버가 담당자 목록에 없어도 계정 줄로 보인다 · 같은 이메일(대소문자 달라도) 한 줄 · 초대 대기 줄 없음(숫자만) · 매니저는 버튼이 안 보이고 상태는 보인다 · 상태 조회를 막으면 「확인 불가」 · 권한 관리 화면에 「브랜드 페이지 계정 관리」(개발서버만) · 탭을 누를 때마다 다른 창에서 바꾼 대표 표시가 반영 · 탭 전환 뒤 브랜드 정보 칸 값 그대로.
- **필요 검문소:** `reverb-reviewer`(열쇠말 네 곳 철자 · 브랜드 정보 영역 미접촉).
- **주의·롤백:** `shared.js` 핫스팟. 롤백 = 카탈로그 두 줄 + 탭 내용(조각 5 임시 내용으로).

### 작업 11 — 계정 동작 다섯 (사양서 4-3 · D10·D15)
- **하는 일:** 계정 만들기 · 다시 보내기 · 대표 담당자 바꾸기 · 해제 · 멤버 상한 바꾸기 + 결과 토스트.
- **담당 파일:** `dev/js/admin-brand-detail.js` · `dev/lib/storage.js`.
- **산출 계약:**
  - storage.js(전부 계정 기능 꺼지면 `{ok:false, error:'brand_account_disabled'}`, 실패는 `null`/`{ok:false}` — 0건과 구분): `checkBrandAccountEmail(brandId, email)` · `releaseBrandAccount(brandId, authId)` · `setBrandMemberLimit(brandId, limit)` · `changeBrandOwner(brandId, newAuthId, expectedAuthId)` + 기존 `upsertBrandOwnerAccount`·`sendBrandAccountSetupMail`.
  - **`openBrandAccountCreateModal()`**(a03-01, 받을 이메일 크게) — 🔴 담당자 목록 대표 줄로만(없거나 이메일 빔 → 「먼저 「+ 담당자 추가」로 대표 담당자를 등록하십시오」, 권한 있을 때만). 순서 = 겹침 확인 → `none` 이면 `upsertBrandOwnerAccount(brandId, 대표 줄 id, 대표 줄 이메일)` → 성공 시 `sendBrandAccountSetupMail(brandId, 'setup')`. `influencer`·`admin` → a03-01a(어느 계정인지 말하지 않음) / `brand` → a03-01c(조각 13 — 그 전에는 「연결 요청은 준비 중」 임시 토스트) / 서버 오류 → a03-01b / 계정은 생겼는데 메일 실패 → ⓑ로 그림.
  - **`brandAccountResend()`** — 확인 없이 `sendBrandAccountSetupMail(brandId, 'resend')`.
  - **`openBrandOwnerChangeModal(preselectAuthId)`**(a03-02) — 후보 = `members` 중 `role='member'` + `password_set_at` 있음(담당자 목록과 무관). 0명 → a03-02a. `owner_changed` → a03-02b.
  - **`openBrandAccountReleaseModal(authId)`**(a03-05 대표 · 05a 멤버) — 대표 창 본문에 `release_cancel_count`(0이면 그 줄 뺌). `owner_has_members` 또는 멤버 있는 대표의 「해제」 → a03-05b(A7). 창에 「해제 → 담당자 이메일 고치기 → 계정 만들기」 안내.
  - **`openBrandMemberLimitModal()`**(a03-03) — 1~50 정수, 범위 밖 → a03-03a.
  - 토스트 문구 = 피그마 a03-90 · 90a. 모든 동작 뒤 `bdReloadPeopleTab()`.
- **선행 의존:** 10 · S6.
- **완료 정의:** ⓐ 브랜드에서 「계정 만들기」 → 창 → 개발서버는 메일 대신 `dev_link`(두 겹 잠금) → ⓒ · 인플루언서 이메일 → a03-01a(이름 안 보임) · 「다시 보내기」 → 옛 링크 무효 · 멤버 하나 있는 브랜드에서 대표 바꾸기 → 대표 표시가 그 멤버 줄로(담당자 목록에 없으면 줄이 생김) · 두 창에서 차례로 바꾸기 → 늦은 쪽 a03-02b · 멤버 있는 대표 「해제」 → a03-05b · 대표 해제 → 대기 초대 건수 줄 · 상한 0·51 → a03-03a · 매니저는 어떤 버튼도 안 보임. **개발서버 실제 메일 발송 시험은 하지 않는다**(`supabase.md`).
- **필요 검문소:** `reverb-reviewer` · `reverb-qa-tester` 권장(다른 세션이 크롬을 안 쓸 때 단일 세션).
- **주의·롤백:** 옛 `renderBrandAccountRow`·`brandAccountSendMail` 은 운영 경로라 남긴다(조각 18).

### 작업 12 — 담당자 추가·수정 모달 (사양서 4-5 · D9·A10)
- **하는 일:** 줄 단위 바로 저장 모달.
- **담당 파일:** `dev/js/admin-brand-detail.js` · `dev/lib/storage.js`.
- **산출 계약:**
  - storage.js **`saveBrandContact(brandId, contactId, row)`**(`row = {name, phone, email, is_primary}`) · **`deleteBrandContact(brandId, contactId)`** → `{ok:true, data:{result, contact_id?, contacts}}` | `{ok:false, error}`.
  - **`openBrandContactModal(contactId)`** — `null` = 추가(08a). 창 `#brandContactModal`(동적). 필수는 이름(08b), 이메일은 형식만(대표 표시 켠 줄은 필수). 「이메일을 고쳐도 로그인 이메일은 바뀌지 않습니다」 안내.
  - 잠김 판정 `bdOwnerLocked()` = 대표 계정 ⓑ~ⓔ **또는** 연결 요청 `pending`(조각 4 칸 — 그 전에는 앞쪽만). 잠김이면 대표 줄은 체크 해제·삭제·이메일 칸 잠금(08e), 이름·연락처만.
  - 대표 표시: 잠김 아니면 자유 이동(🔴 메일·연결 요청 없음) / 잠김이면 멤버 계정이 있는 줄로만 — 체크하면 `openBrandOwnerChangeModal(그 멤버 auth_id)`(조각 11)가 위에 뜨고 다른 칸은 모달 「저장」으로 따로 / 막힐 때 08d 안내 둘 중 하나 / 계정 관리 권한이 없으면 잠김 동안 체크칸 숨김 / 연결 요청 중이면 「연결 요청 중에는 대표 담당자를 바꿀 수 없습니다」(권한 있을 때만).
  - 결과 → 화면: `name_required` → 08b · `primary_locked`·`primary_move_needs_owner_change` → 08d·08e 안내(화면이 이미 막지만 서버 거부도 같은 문구) · 그 밖 실패 → 08c(값 그대로, 모달 안 오류). 성공 → 응답의 `contacts` 로 `_brandFormContacts` 갱신 + `bdReloadPeopleTab()`.
  - 삭제: 모달 안 「삭제」 → 확인만(기본값 9).
- **선행 의존:** 2 · 11 · S6.
- **완료 정의:** 추가·수정·삭제가 다른 줄을 건드리지 않는다(다른 창에서 동시에 다른 줄을 고쳐도 둘 다 남는다) · 계정 있는 브랜드의 대표 줄은 이메일 잠김 · 콘솔로 잠긴 이메일 변경 요청 → 서버 거부 · 계정 없는 브랜드 대표 이동 → 메일 없음 · 대표 이동(계정 있음) → a03-02 가 그 멤버를 고른 채 · 브랜드 정보 탭에 쳐 둔 값 그대로.
- **필요 검문소:** `reverb-reviewer`.
- **주의·롤백:** 이 조각이 사양서 관문 5(매니저 대표 줄 이메일 변경 틈)를 화면에서 닫는다 — 서버 쪽은 조각 2, 직접 고치기는 조각 15.

### 작업 13 — 연결 요청 화면 (a03-01c · 04 · 04a · 91a · D11)
- **하는 일:** 「계정 만들기」의 브랜드 계정 갈래(01c)와 「브랜드 연결 추가」(04)를 연결 요청으로 · 보낸 요청 표시와 「요청 취소」(91a) · 만료·거절·취소 칩.
- **담당 파일:** `dev/js/admin-brand-detail.js` · `dev/lib/storage.js`.
- **산출 계약:**
  - storage.js **`requestBrandOwnerLink(brandId, email)`** · **`cancelBrandOwnerLink(brandId, requestId)`**(조각 4 함수 호출).
  - **`openBrandLinkRequestModal(email, from)`** — `from` = `'create'`(01c, 이름·연결된 브랜드 수 표시 — 겹침 확인의 `brand` 갈래 이름) | `'add'`(04, 이메일 입력). `not_brand_account` → 04a · `owner_exists` → 토스트 「이 브랜드에는 이미 대표 담당자가 있습니다」 · `request_exists` → 지금 요청 표시로.
  - **`cancelBrandLinkRequest()`** — 권한 있으면 누구나.
  - 대표 줄 계정 칸: `owner_link_request.status==='pending'` → 「연결 요청 보냄 · ~까지」 + 「요청 취소」 / `expired·declined·cancelled` → 「계정 없음 · 연결 요청 만료됨/거절됨/취소됨」 한 칩 + ⓐ 단추(따로 「다시 요청」 없음).
  - 조각 11 의 01c 임시 토스트를 이것으로 바꾼다.
- **선행 의존:** 4 · 12 · S6.
- **완료 정의:** 요청 → 칩 「보냄」, 요청 중 대표 줄 잠김(조각 12) · 취소 → 「취소됨」 칩 + ⓐ 단추 · 기한을 SQL 로 과거로 → 「만료됨」 · (별도 작업표 쪽) 브랜드 계정이 수락 → 탭을 다시 누르면 ⓔ 또는 ⓒ, 대표 표시가 그 사람 줄로.
- **필요 검문소:** `reverb-reviewer`.
- **주의·롤백:** 4 없이 내지 않는다. 늦어지면 01c·04 진입 단추를 숨긴 채로 14 를 먼저.

### 작업 14 — 개발서버 처음부터 끝까지 확인
- **하는 일:** 사양서 1절 「넣는 것」 화면 전부를 S8 시험 데이터로 확인. 매니저·캠페인 관리자·최고 관리자 세 등급(로그인은 사용자에게 부탁 — 비밀번호 입력 금지).
- **담당 파일:** 없음(고친 것은 해당 조각에).
- **산출 계약:** 확인 기록(사양서 「구현 결과」에 붙일 표 — 화면 코드별 결과).
- **선행 의존:** 7·8·9·11·12·13 · S8.
- **완료 정의:** 사양서 6절 ①~⑩ 각각 한 번 이상 재현해 기대대로 · 운영 주소에서는 지금 페이지 그대로(S0=A) · 오류 로그 화면에 새 오류 없음.
- **필요 검문소:** `reverb-qa-tester`(단일 세션 · `browser-qa.md` — 마우스로).
- **주의·롤백:** —

### 작업 15 — 직접 고치기 막기 (사양서 5-5)
- **하는 일:** (S5=A) `contacts`·`primary_*` 를 로그인 사용자의 직접 UPDATE 로 못 바꾸게.
- **담당 파일:** 새 마이그레이션 1개.
- **산출 계약:** (S5=A) 트리거 `trg_brands_guard_direct_contacts` `BEFORE UPDATE OF contacts, primary_contact_name, primary_phone, primary_email ON public.brands` + 함수 `_guard_brands_direct_contacts()` — 🔴 **반드시 SECURITY INVOKER**(정의자 권한이면 `current_user` 판정이 무력해진다 — 492·497 교훈), `current_user = 'authenticated'` 이고 값이 바뀌면 `RAISE` 코드 `brand_contacts_direct_write`. `friendlyError` 에 문구 한 줄(관리자 「새로고침해 주십시오」). 실행 권한은 셋 다 회수.
- **선행 의존:** 14 · S5.
- **완료 정의:** 로그인 관리자 콘솔에서 `db.from('brands').update({contacts: []}).eq('id', …)` → 거부 · 이름만 직접 UPDATE → 성공 · 회사 일괄 할당(회사 관리) → 성공 · 담당자 함수(조각 2)·대표 바꾸기(533) → 성공 · 「새 브랜드」 등록(삽입) → 성공.
- **필요 검문소:** `reverb-supabase-expert` · `reverb-reviewer`.
- **주의·롤백:** 🔴 운영 순서 = **화면 병합 뒤**(옛 운영 화면은 `contacts` 를 통째로 보낸다). 계정 모드가 꺼진 환경의 `osSaveIssuedContact` 는 이 뒤로 실패한다(의심 11) — 출시 뒤에는 도달하지 않는다. 롤백 = 트리거 `DROP`.

### 작업 16 — 문서
- **하는 일:** 사양서 「구현 결과」(실제 마이그레이션 번호·함수 이름·조각 14 기록·후속: 회사 이름 사본 틈·`osSaveIssuedContact` 정리) · `docs/FEATURE_SPEC.md` · `CLAUDE.md`(「브랜드 상세 모달」 → 페이지 · 현재 원본 번호: `admin_upsert_brand_owner_account`·`admin_check_brand_account_email`(조각 1) · `admin_get_brand_account_status`(조각 4) · 새 함수 셋) · `.claude/rules/brand-admin.md`(탭 넷·떠날 때 확인·「모달」 표현) · `.claude/rules/brand-account.md`(공개 기본 열 「`saveBrandDetail` 에 넣지 않는다」 → 「브랜드 정보 탭 저장으로 함께」 · 「대표 이메일이 새로·바뀔 때만은 화면이 지킨다」 → 서버 거부 · 권한 카탈로그 등록).
- **담당 파일:** 위 다섯.
- **산출 계약:** —
- **선행 의존:** 1~15.
- **완료 정의:** `grep -rn "브랜드 상세 모달\|saveBrandDetail 에 안 넣는다" CLAUDE.md .claude/rules/` 가 의도한 자리만 · 「구현 결과」에 사양서 stale 1~9 처리 결과.
- **필요 검문소:** `reverb-reviewer`.
- **주의·롤백:** 규칙 파일(`.claude/rules/*`)은 거버넌스 문서 — 개발 세션 커밋이 막히면 고문에게 넘긴다.

### 작업 17 — 출시 날 운영 반영
- **하는 일:** 브랜드 페이지 1차 운영 반영 순서(`docs/specs/2026-07-15-brand-portal.md` 「운영 반영 전 남은 관문」 4번 — 그 순서가 정본)에 끼운다.
- **담당 파일:** 없음(운영 데이터베이스·대시보드·병합).
- **산출 계약 — 순서:**
  1. 1차 데이터베이스 묶음(526 → … → 536, 535 제외 · 544 등 1차에 드는 것 전부)
  2. **이 작업 데이터베이스**: 조각 1 → 2 → 3 → (4 — S1=A 면 그 작업표의 서버 조각)
  3. 인증 설정 Email OTP Expiration 86400(관문 7 — 🔴 서버 함수보다 먼저)
  4. 서버 함수 넷 + (연결 요청 메일 함수) + 비밀값 `PUBLIC_BRAND_URL`(🔴 `BRAND_SETUP_DEV_ECHO` 는 넣지 않는다)
  5. 화면 병합(`dev` → `main`) + `_brandAccountEnabled()` 걷기(S0=A 면 이 순간 새 페이지로 바뀐다) + `brand.account_manage` 의 `staging_only` 걷기
  6. **조각 15**(🔴 화면 병합 확인 뒤)
  7. 관리자 공지(`/공지초안-관리자` — 「새로고침해 주세요」 포함) + Notion 「관리자 가이드」 브랜드 관리 페이지(`notion-sync.md` 정확성 게이트)
- **선행 의존:** 16 · 브랜드 페이지 관문 1~10(특히 1 `/약관확인` — 멤버 계정 줄의 이름·이메일·마지막 접속 열람이 브랜드 방침 「운영 관리」 범위인지 함께, 사양서 9절).
- **완료 정의:** 여러 번호를 넣는 날 체크리스트(`supabase.md`) — 시작 시각 이후 기록 표 줄 = 넣은 번호·파일 이름 짝 · 운영 로그인 관리자 화면에서 조각 14 의 핵심 셋(브랜드명 저장 · 담당자 추가 · 계정 상태 표시) · 콘솔 직접 `contacts` UPDATE 거부.
- **필요 검문소:** `reverb-qa-tester`(운영 배포 전 권장) · 사용자 확인(운영 병합은 사용자).
- **주의·롤백:** 화면 문제면 `_brandAccountEnabled()` 분기 한 줄을 되돌려 옛 페이지로(S0=A 의 이점) — 단 데이터베이스는 되돌리지 않는다(새 함수는 남아도 무해, 조각 15 만 `DROP` 가능). 출시 날 관리자 공지가 없으면 실무자가 「저장 단추가 사라졌다」고 묻는다.

### 작업 18 — 출시 뒤 옛 경로 정리 (S0=A 일 때만)
- **하는 일:** 운영에서 며칠 확인한 뒤 옛 페이지 코드 삭제 — `openBrandDetail` 분기 · 옛 머리 함수·`BRAND_DETAIL_BACK` · 옛 `saveBrandDetail`·`_collectBrandFormPatch`(새 브랜드 모달이 쓰는 부분은 남김) · `renderBrandAccountRow` 계열·`_brandAccountAfterBrandSave`·`brandAccountSendMail` · `saveBrandPublishDefaultFromDetail` · `osSaveIssuedContact`·발급 창 담당자 고르기 옛 갈래 · `updateBrand`(호출 0 확인 뒤).
- **담당 파일:** `dev/js/admin-brand.js` · `dev/js/admin-brand-publish.js` · `dev/js/admin-orient.js` · `dev/lib/storage.js`.
- **산출 계약:** 지운 함수마다 `grep` 호출 0(세 형태 — 그대로·인자로 넘김·문자열 `onclick`).
- **선행 의존:** 17 + 운영 확인.
- **완료 정의:** 빌드 성공 · 위 grep 0 · 브랜드 상세·새 브랜드·오리엔시트 발급·회사 일괄 할당 동작 그대로.
- **필요 검문소:** `reverb-reviewer`(남은 참조).
- **주의·롤백:** `git revert` 한 번으로 되돌릴 수 있게 한 병합 요청으로.

---

## ⚠️ 공유 지점 경고 (충돌 주의)

| 파일·대상 | 만지는 조각 | 주의 |
|---|---|---|
| `dev/js/admin-brand.js`(핫스팟) | 5 · 6 · 7 · 10 · 18 | S0=A 면 새 코드는 새 파일로 가서 이 파일은 분기·임시 갈래만. 다른 브랜드 작업(캠페인 탭 배지·배송)이 같은 파일을 계속 만진다 — 착수 때 `origin/dev` 를 받아 합친다 |
| `dev/lib/storage.js`(핫스팟) | 7 · 8 · 9 · 11 · 12 · 13 | 새 함수만 더한다(기존 함수 시그니처 불변). 화면 흐름 한 세션 |
| `dev/lib/shared.js`(핫스팟) | 10 | 카탈로그·`PERM_SUPER_SERVER_ENFORCED` 두 자리 |
| `dev/admin/index.html` · `dev/build.sh`(핫스팟) | 5 | 원본 태그 + 빌드 목록 + 태그 제거 정규식 **세 자리** |
| `dev/admin/app.js` · `dev/js/admin-core.js`(핫스팟) | 6 | `navAdminPaneReload` 고리 · `popstate` 되돌림 — 캠페인 떠날 때 확인과 순서 |
| `dev/js/admin-orient.js` | 5 · 18 | 발급 경고 문구·`osGoBrandAccount` |
| `dev/js/admin-company.js` | 9 | 회사 관리 화면도 같은 모달 — 회귀 확인 |
| `dev/js/admin-brand-publish.js` | 7 · 18 | 옛 단추는 운영 경로라 18 까지 둔다 |
| 533 함수 재정의 | 1 · 4 | `admin_upsert_brand_owner_account`·`admin_check_brand_account_email`(1), `admin_get_brand_account_status`(4). 다른 세션이 같은 함수를 만지면 병합 요청 검사 ②가 경고 — 마지막 정의를 베이스로 |
| `brand_profile_history` 세 곳 같은 집합 | 3(S2=A) | CHECK · 트리거 함수 VALUES · `AFTER UPDATE OF` |
| `brands.contacts` 쓰는 자리 | 2 · 15 | 서버 쓰기: 087·397(신청서 삽입) · 091(대표 줄 덮기 — 생성 단추 비활성) · 531 `_brand_contacts_mark_primary` · 새 담당자 함수. 화면 쓰기: `saveBrandDetail`·`osSaveIssuedContact`(18 에서 정리) |
| 판정 한 곳 | 2 · 4 | 「계정이 있는 동안」 = `_brand_contacts_locked` 하나(화면 `bdOwnerLocked` 는 상태 조회 값을 읽기만) |
| 데이터베이스 흐름 | 1 · 2 · 3 · (4) · 15 | **한 세션·순서대로.** 번호는 push 직전 `origin/dev`·열린 병합 요청까지 보고 확정 |

---

## 🧭 배분 제안

> ✅ **2026-10-21 사용자 결정: 두 세션 동시**(아래 세션 A 데이터베이스 · 세션 B 화면). 착수는 이 작업표 병합 요청(#2239)이 `dev` 에 병합된 뒤.

- **세션 A — 데이터베이스(메인 또는 별도 작업 폴더 `feature/브랜드상세-db`)**: 1 → 2 → 3 → (4) → … → 15. 마이그레이션은 이 세션만. 매 조각 개발 데이터베이스 적용 + 로그인 콘솔 실제 호출 + 기록 표 확인.
- **세션 B — 화면(작업 폴더 `feature/브랜드상세-화면`)**: 5 → 6 → 9 를 세션 A 와 **동시에**, 그 뒤 7(3 완료 뒤) → 8 → 10(1 완료 뒤) → 11 → 12(2 완료 뒤) → 13(4 완료 뒤). 핫스팟 파일이 몰려 있어 **화면은 한 세션만**.
- **연결 요청(S1=A)**: 기획 세션이 별도 사양서·작업표를 먼저 — 그 서버 조각이 이 표의 조각 4 를 채운다. 늦어지면 13 만 보류하고 14 를 먼저.
- **확인 담당**: 14(크롬 단일 자원 — 다른 세션이 안 쓸 때).
- **마무리**: 16 은 세션 B, 17 은 브랜드 페이지 출시 날 묶음과 함께(사용자 확인), 18 은 출시 뒤.
- 🔴 **세션 B 는 세션 A 의 함수 적용을 확인한 뒤에 그 함수를 부르는 조각을 `dev` 에 병합한다**(화면 버튼과 서버 함수는 같은 배포에 묶이지 않는다).

---

## 사용자 확인 필요 (메인이 `AskUserQuestion` 으로 하나씩)

> ✅ **2026-10-21 모두 답을 받았다** — 아래는 질문 당시 원문(「추천」 표시 포함)이고, 결정은 위 「✅ 사용자 결정」 표가 정본이다(Q5 는 추천과 다르게 「함께 바꾸기」).

**Q1 (S0)** — 질문: 관리자 브랜드 상세 새 화면이 출시 날 전에 운영으로 새지 않게 어떻게 막을까요? · 헤더: 출시 전 보호
- 「개발서버만 새 화면 (추천)」 — 새 화면을 새 파일에 만들고 개발서버에서만 열리게 한 줄로 가릅니다. 운영은 출시 날까지 지금 화면 그대로이고, 문제가 생기면 그 한 줄로 되돌립니다. 출시 뒤 옛 코드 정리가 한 번 더 필요합니다.
- 「통합 브랜치에 모으기」 — 개발서버에 올리지 않고 따로 모아 미리보기 주소로 확인한 뒤 출시 날 한꺼번에 올립니다. 다른 브랜드 작업과 같은 파일을 만져 충돌이 쌓입니다.
- 「운영 배포를 골라 담기」 — 출시 날까지 운영 배포마다 이 작업만 빼고 올립니다. 매 배포가 무거워집니다.

**Q2 (S1)** — 질문: 서버에 아직 없는 「연결 요청」(본인이 24시간 안에 수락해야 연결)은 어디서 만들까요? · 헤더: 연결 요청
- 「별도 작업표로 (추천)」 — 브랜드 쪽 수락 화면·요청 메일까지 따로 기획해 만들고, 이 작업은 관리자 화면만 그 뒤에 붙입니다. 관리자 화면 대부분은 먼저 진행할 수 있습니다.
- 「이 작업표에 넣기」 — 서버·메일·브랜드 화면까지 이번에 함께 만듭니다. 작업이 8개쯤 늘고 브랜드 앱 파일이 섞입니다.
- 「지금처럼 즉시 연결」 — 이미 있는 즉시 연결로 냅니다. 브랜드 약관 초안(본인 수락)과 어긋나 약관 확인 관문을 통과하지 못합니다.

**Q3 (S2)** — 질문: 저장 충돌 창에서 회사·상태·공개 기본 열은 「누가·언제」를 보여 줄까요? · 헤더: 충돌 이력
- 「이력에 칸 더하기 (추천)」 — 회사·상태 변경도 이력에 남기고, 공개 기본 열은 마지막 저장자·시각을 보여 줍니다. 이력 표 세 곳을 함께 고칩니다.
- 「바뀐 사실만」 — 세 칸은 「누가·언제」를 비워 둡니다. 서버 변경이 적습니다.

**Q4 (S5)** — 질문: 담당자 목록을 서버 함수 말고 직접 고치는 길을 어떻게 막을까요? · 헤더: 직접 쓰기
- 「담당자 칸만 서버가 거부 (추천)」 — 담당자 목록과 대표 연락처 칸만 직접 고치기를 거부합니다. 회사 일괄 할당 같은 다른 저장은 그대로 됩니다.
- 「직접 고치기 전부 닫기」 — 브랜드 표 직접 수정을 모두 막고 남은 세 자리를 서버 함수로 옮깁니다. 확실하지만 일이 늘어납니다.
- 「화면만 바꾸기」 — 서버는 그대로 둡니다. 옛 화면이나 콘솔로 우회할 수 있습니다.

**Q5 (S7)** — 질문: 관리자가 대표 담당자 줄의 이름·연락처를 고치면 그 사람의 브랜드 페이지 계정 이름도 바꿀까요? · 헤더: 계정 이름
- 「바꾸지 않기 (추천)」 — 계정 이름은 본인이 마이페이지에서 정한 값으로 둡니다. 담당자 목록은 관리자 장부로만 씁니다.
- 「함께 바꾸기」 — 지금처럼 관리자 저장이 계정 이름·연락처를 덮어 맞춥니다. 본인이 고친 이름이 되돌아갈 수 있습니다.

**Q6 (S3)** — 질문: 사양서에 적힌 담당자 「직함」 칸은 지금 없는데, 새로 만들까요? · 헤더: 직함 칸
- 「만들지 않기 (추천)」 — 지금 칸 다섯(이름·연락처·이메일·대표 표시·아이디)만 씁니다. 사양서 문구만 고칩니다.
- 「새로 만들기」 — 담당자 모달·표·서버 함수에 칸을 하나 더합니다.

---

**참고 파일(절대경로)**
- 사양서: `/Users/choiwooyoung/kemo/docs/specs/2026-10-21-admin-brand-detail-tabs.md`
- 상위 사양서: `/Users/choiwooyoung/kemo/docs/specs/2026-07-15-brand-portal.md`(§16-8 818줄 · 운영 관문 994줄)
- 확인한 코드: `/Users/choiwooyoung/kemo/dev/js/admin-brand.js`(1198~1382 · 1533~1540 · 1763~1782 · 2203~2330 · 2402~2650) · `/Users/choiwooyoung/kemo/dev/lib/storage.js`(3465~3554 · 3691) · `/Users/choiwooyoung/kemo/dev/lib/shared.js`(2023~2137) · `/Users/choiwooyoung/kemo/dev/js/admin-orient.js`(637~680 · 863~898) · `/Users/choiwooyoung/kemo/dev/js/admin-company.js`(21 · 156~239) · `/Users/choiwooyoung/kemo/dev/js/admin-core.js`(180~208 · 392) · `/Users/choiwooyoung/kemo/dev/admin/app.js`(63~79) · `/Users/choiwooyoung/kemo/dev/js/admin-brand-publish.js`(181~272)
- 확인한 마이그레이션: `/Users/choiwooyoung/kemo/supabase/migrations/082_brands_master_phase1.sql`(224) · `086_brands_contacts_jsonb.sql` · `087_…` · `091_…` · `397_…` · `530_brand_member_base.sql`(167~191 · 270~276) · `531_brand_owner_functions.sql`(381~436) · `533_brand_admin_member_functions.sql`(388~1018) · `536_brand_profile_functions.sql`(66~207 · 282~369) · `544_brand_publish_settings.sql`(90~94 · 325)
