# 📋 작업 분해표 — 브랜드 페이지 「브랜드」 메뉴(03 브랜드 관리) + 마이페이지 잔여

**사양서:** `docs/specs/2026-07-15-brand-portal.md` §16-4 「브랜드 페이지 회사 정보」(692줄 부근) · 518줄(수정 이력은 누가·언제) · 543줄(평소 읽기 전용, 카드마다 「수정」) · 661줄(멤버도 브랜드 정보를 고친다)
**정본 화면:** 피그마 「[1차] 03 브랜드」(노드 57:951) bw03-00(대표 담당자 기본 보기) · 00a(브랜드 정보 수정 중) · 00b(회사 정보 수정 중, 대표 담당자만) · 00c(멤버가 볼 때). 모바일 그림 없음. 마이페이지는 「[1차] 07」(130:326)
**양식:** 앞 작업표 `docs/specs/2026-10-15-brand-member-screen-breakdown.md` 를 따른다
**분해일:** 2026-10-16
**범위:** 브랜드 화면(`dev/brand/`) + 그 화면용 데이터베이스 함수 + 결정 D2 때문에 고칠 관리자 회사 화면의 주소 칸 + 마이페이지 잔여 1건(코드) / 1건(피그마 — 기획에게 넘김)
**총 작업 조각:** 8개 · **동시에 할 수 있는 것:** 조각 1과 7, 조각 2와 3, 조각 7(언제든) · **나머지는 순서대로**

> **화면 문구:** 한국어(`dev/brand/index.html` 이 `lang="ko"`). 일본어 문구 없음.
> 🔴 **개발서버에서만 돈다:** 브랜드 화면 코드는 모두 `brandDb`(운영 주소에서는 `null`)로만 서버를 부른다. 데이터베이스 함수(조각 3)는 526~534와 같은 줄에 서서 운영 반영을 보류한다. ⚠️ **예외** — 조각 2(관리자 회사 화면)는 관리자 코드라 다음 운영 배포 때 함께 나간다. 그래서 그보다 먼저 **조각 1(상세 주소 칸)을 운영 데이터베이스에 따로 넣는다**(결정 Q3).
> **마이그레이션 번호:** 미리 정하지 않는다. 작성 시점 마지막 번호는 **534**.

---

## 현재 상태 (2026-10-16 코드로 확인)

| 항목 | 실제 |
|---|---|
| 「브랜드」 메뉴 | `brand-shell.js` `BRAND_MENU` 에 `brand`(라벨 「브랜드」, 아이콘 `business`)가 있다. `registerBrandPage('brand', _brandComingSoon('브랜드'))` 때문에 「준비 중입니다」가 뜬다. 등록부가 `_brandPages[hash] = def` 라 뒤에 실리는 파일이 다시 등록하면 바뀐다 |
| 브랜드 계정이 읽을 수 있는 표 | `brands` 읽기·쓰기 정책은 `is_admin()` 뿐(082). `companies` 도 읽기 `is_admin()`, 쓰기 `is_campaign_admin()`(118). 이후 두 표 정책을 바꾼 마이그레이션 없음 → **보안 정의자 함수가 필요하다** |
| 역할 판정 | `my_brand_role(p_brand_id)`(530, 보안 정의자, `authenticated` 만). 활성 연결 + 활성 브랜드일 때만 `owner`/`member`, 아니면 NULL(보관 브랜드도 NULL) |
| 브랜드명을 바꿀 때 딸려 가는 것 | ①173 트리거 `trg_brands_sync_campaigns`(`AFTER UPDATE OF name, name_ja, name_en`)가 연결 캠페인의 `brand`·`brand_ja`·`brand_en` 을 고친다 → **한글·영문을 바꿔도 캠페인으로 옮겨진다** ②그 쓰기가 266 캠페인 변경 이력 트리거를 부른다 — `changed_by` = 브랜드 계정 아이디, `changed_by_name` NULL(화면 「시스템 / 직접 수정」), `change_source='admin'` ③275 `campaigns.version` +1(제외 6칸에 브랜드명 칸 없음) |
| 인플루언서 화면 브랜드명 | `brandLabelInflu`(shared.js) = `brand_ja || brand_en || brand` — **일본어 이름이 빈 브랜드는 영문 → 한글명이 인플루언서 화면에 뜬다** |
| 이름 중복 막기 | `brands.name_normalized` 유일(082) · `companies.name_normalized` 유일(119). 회사명이 비면 118 트리거가 `23514` 로 거부 |
| 회사 표 칸 | `name_ko`(필수)·`name_ja`·`name_en`·`business_no`·**`address`(한 칸)**·`homepage_url`·`billing_email`·`billing_address`·`memo`·`status`·`total_brands`·`updated_at`·`updated_by`. **상세 주소 칸 없음** |
| `total_brands` | 118 트리거는 `company_id` 가 바뀔 때만 센다 — **보관 브랜드도 숫자에 든다**. D3(보관 제외)과 기준이 다르다 |
| 관리자 회사 모달 | `admin-company.js` `COMPANY_FIELDS` 9칸 · `saveCompany` 가 9칸을 **통째로** 보낸다 · `openCompanyModal` 은 목록 보관값 `_companiesCache` 에서 읽는다 · 회사 목록 표에 주소 열 없음 |
| 관리자 브랜드 상세 저장 | `_collectBrandFormPatch`(admin-brand.js)가 `name`·`name_ja`·`name_en`·SNS 둘·`contacts`·회사 연결 등을 **통째로** 보낸다 → 브랜드가 고친 값을 열려 있던 관리자 폼이 되돌린다 |
| 🔴 회사 조회가 실패하면 | `fetchCompanies`(storage.js)가 칸을 직접 지정하고 **실패하면 `[]`** — 없는 칸을 넣으면 회사 목록이 비고 브랜드 상세 회사 선택 칸도 빈다 → 그 상태로 브랜드를 저장하면 `company_id: null`, **브랜드가 회사에서 조용히 떨어진다** |
| `brands.company_name` | 회사명 사본. 관리자 브랜드 저장 때만 그 한 줄을 맞춘다(회사 모달은 안 맞춤). 읽는 곳: `admin-orient.js` · `admin.js` · `admin-brand.js` · 신청 조회(storage.js) |
| 수정 이력 표 | 브랜드·회사 변경 이력 표 **없음**. 선례 `campaign_change_history`(265·266, 칸마다 한 줄 + `change_source`) |
| 비교 기준 칸 | `updated_at` 은 있으나 `brands.updated_at` 은 관계없는 저장에도 오른다 — 시각 비교는 가짜 충돌. `version` 칸 없음 |
| 마이페이지 동그라미 | `dev/brand/index.html` `brand-me-avatar` 안 `data-brand-user-initial` · `brand-shell.js` `renderBrandShellChrome` 이 이름 첫 글자를 채운다. 새 초대 빨간 점이 같은 동그라미 안에 있다 |
| 다시 쓸 부품 | `brandRpc`·`brandToast`·`brandConfirm`·`brandEsc`·`brandTouchActivity`·`onBrandChanged`·`refreshBrandLoginState`·`handleBrandNotLinked`·`compareBrandNames` · 마이페이지 카드 클래스(`brand-my-head`·`brand-my-btn`·`brand-my-field`·`is-locked`) · 「떠나면 수정 상태 버림」(`brand-mypage.js` `hashchange`) |
| 빌드 | `dev/build.sh` `BRAND_JS_FILES` 한 곳 + `dev/brand/index.html` 원본 태그. 태그 제거 정규식은 일반식 |

### 낱말 전파 점검 — 회사 「주소」가 쓰이는 자리 (D2 영향)
찾은 방법: `address|business_no|homepage_url` 를 `dev/` 에서, `companies|company` 를 `supabase/functions` 에서, `from('companies')`·`companies:`·`company:companies` 끼워 넣기 조회를 `dev/`·`sales/` 에서, `compan` 을 `supabase/migrations/4xx~5xx` 에서.

| 자리 | 지금 | 이번 처리 |
|---|---|---|
| `admin-company.js` `COMPANY_FIELDS`(라벨 「주소」) | 한 칸 | **두 칸**(「주소」 + 「상세 주소」) — 조각 2 |
| `storage.js` `fetchCompanies` 칸 지정 | `address` | `address_detail` 추가 — 조각 2(🔴 칸이 생긴 뒤에만) |
| `storage.js` `upsertCompany` | `COMPANY_FIELDS` 를 그대로 보냄 | 저절로 따라온다 |
| 회사 목록 표 · 관리자 브랜드 상세 회사 요약 · `get_brand_ops_*` | 주소 안 씀 | 바꾸지 않는다 |
| 메일 함수·메일 양식·자주 묻는 질문·엑셀·광고주 신청 폼·오리엔시트 폼 | 회사 주소 0 | 해당 없음 |
| `billing_address`(청구 주소) | 한 칸 | 바꾸지 않는다(브랜드 화면에 없음, D2 대상 아님) |

---

## 의심·경우의 수 (반대론자)

1. **(사용 흐름) 멤버가 바꾼 영문·한글명이 인플루언서 화면에 뜰 수 있다** — 일본어 이름이 빈 브랜드는 `brandLabelInflu` 가 영문 → 한글로 고른다. → 조각 3 검문소에서 `name_ja` 빈 브랜드 수를 센다. 화면은 막지 않는다.
2. **(기술) 브랜드명 저장이 캠페인 세 군데를 건드린다** — 173 이름 갱신 · `version` 상승 · 266 이력 「시스템 / 직접 수정」. 관리자가 그 캠페인을 편집하던 중이면 **가짜 충돌 안내**. 관리자가 이름을 바꿀 때도 같았지만, 이제는 관리자가 모르는 사이에 일어난다.
3. **(데이터) 관리자 화면이 브랜드가 고친 값을 되돌린다** — 관리자 브랜드 상세 폼과 회사 모달이 연 시점 값을 통째로 저장한다(Q2 — 묶음 ③에서 막는다).
4. **(기술·운영) 🔴 상세 주소 칸이 없는 서버에 관리자 코드가 나가면 브랜드가 회사에서 떨어진다** — `fetchCompanies` 실패 = `[]` → 빈 회사 선택 칸으로 저장 → `company_id` NULL. 운영 데이터베이스에 칸이 먼저 있어야 한다(Q3).
5. **(정보 노출) 이름 중복 거부가 다른 브랜드의 존재를 알려 준다** — 이름만 드러나고 내용은 안 드러나 받아들일 만하다. 문구는 중립으로.
6. **(사용 흐름) 두 사람이 동시에 고친다 · 고치는 중에 역할이 바뀐다** — 서버가 「연 시점 값」과 지금 값을 칸 단위로 비교해 `stale`, 역할은 서버가 다시 판정해 `not_owner`.
7. **(사용 흐름) 저장하지 않은 입력이 조용히 사라진다** — 「떠나면 버림」(개발 기본값 4, 마이페이지와 같다).
8. **(데이터) 브랜드 개수가 화면마다 다르다** — 브랜드 화면은 D3(보관 제외), 관리자 쪽은 `total_brands`(보관 포함).
9. **(데이터) 회사명을 바꾸면 사본 칸이 어긋난다** — 회사 저장 함수가 같은 회사 브랜드 전부의 `brands.company_name` 을 맞춘다(개발 기본값 6).
10. **(법률·약관) 개인정보 판단** — 개인사업자의 사업자등록번호, 이력의 담당자 이름 스냅샷. 개발서버라 막지 않지만 운영 관문(`/약관확인`)에 넣는다.

**현재 구현과 충돌하는 지점:** ①`brand-shell.js` 「준비 중」 등록 ②관리자 두 저장 함수의 통째 저장 ③`fetchCompanies` 의 실패 = `[]` ④사양서 692줄 「브랜드명 한글·일본어·영문 모두 고친다」 ↔ D1 ⑤사양서 543줄 「주소 검색은 이 카드」 ↔ 개발 기본값 1.

---

## ✅ 결정 표 (2026-10-16 사용자 결정 + 개발 기본값)

| # | 결정 | 출처 | 반영 |
|---|---|---|---|
| D1 | 브랜드명(일본어, `name_ja`)은 브랜드 화면에서 **잠금(보기만)**. 브랜드가 고치는 칸은 한글(`name`)·영문(`name_en`)·SNS 둘뿐. 서버 함수도 일본어 칸을 **받지 않는다** | 사용자 | 3·4·5 |
| D2 | 주소 **두 칸(기본·상세)**. `companies` 에 상세 주소 칸, 관리자 회사 화면도 두 칸. 기존 `address` 는 기본 주소로 그대로(옮기지 않음) | 사용자 | 1·2·3·4·6 |
| D3 | 대표 화면의 회사 안내에 같은 회사의 **다른 브랜드 이름까지** 보인다(멤버 화면은 피그마 00c 대로 목록 없이 안내만). **보관 브랜드 제외** — 기준 `brands.status='active'`(`total_brands` 안 씀). 지금 브랜드도 목록에 든다 | 사용자 | 3·4·6 |
| D4 | 사업자등록번호는 브랜드 화면 저장 때 **필수**(공백 제거 뒤 빈 값 거부). 관리자 회사 모달은 지금처럼 선택 | 사용자 | 3·6 |
| Q1 | 수정 이력 = **새 이력 표** — 브랜드 5칸·회사 5칸이 바뀔 때마다 관리자·브랜드 담당자 구분 없이 한 줄씩. 보는 화면은 묶음 ③ | 사용자 | 3 |
| Q2 | 관리자 화면 덮어쓰기는 **묶음 ③(관리자 화면)에서 막는다** — 그 전까지 문서에 경고만 | 사용자 | 8 |
| Q3 | 상세 주소 칸은 **운영 데이터베이스에 먼저 따로 넣는다**(조각 2가 `main` 으로 가기 전) | 사용자 | 1·2 |
| Q4 | 캠페인 변경 이력의 「시스템 / 직접 수정」 표시는 **그대로 둔다**(266 재정의 안 함 — 누가 바꿨는지는 Q1 이력 표에) | 사용자 | 3 |
| 기본값 1 | 주소 「검색」 단추는 **뺀다**(외부 서비스 미정·약관 처리 위탁 확인 필요). 두 칸 모두 직접 입력 | 사용자에게 알림 | 6 |
| 기본값 2 | **두 카드를 동시에 고칠 수 없다** — 한 카드를 열면 다른 카드의 「수정」을 숨긴다(양방향) | 알림 | 5·6 |
| 기본값 3 | 저장 완료 토스트 「브랜드 정보를 저장했습니다.」 / 「회사 정보를 저장했습니다.」 | 알림 | 5·6 |
| 기본값 4 | 메뉴를 옮기거나 브랜드를 바꾸면 수정 상태를 **확인 없이 버린다**(마이페이지와 같다) | 알림 | 4 |
| 기본값 5 | 동시 수정은 **칸 단위 비교**(`p_prev` vs 지금 값) → `stale`, 화면은 토스트 뒤 `loadBrandInfo()` 로 다시 불러온다(회사 안내 목록까지 새로) | 의심 6 | 3·5·6 |
| 기본값 6 | 회사명을 바꾸면 같은 회사 **모든** 브랜드의 `brands.company_name` 사본을 함께 맞춘다 | 의심 9 | 3 |
| 기본값 7 | 같은 회사 **활성** 브랜드가 지금 브랜드 하나뿐이면 「함께 바뀝니다」 문장을 **둘 다** 그리지 않는다 — 보기 화면 안내의 뒷문장(작업 4)과 수정 화면 주황 안내(작업 6). 「이 회사의 브랜드: ○○」는 남긴다. 이름은 두 자리 모두 6개까지, 넘으면 「이름 · 이름 · … · 외 {남은 수}개」 — 두 자리 모두 같은 함수로 만든다. 필수 칸 빈 값(브랜드명·회사명·사업자등록번호)은 화면이 저장 전에 먼저 막고(같은 칸 아래 같은 문구), 서버 거부는 안전망 | 피그마에 없음 | 4·6 |
| 기본값 8 | 보관(archived) 회사에 연결된 브랜드도 회사 정보를 보여 주고, 대표 담당자는 고칠 수 있다 | 피그마에 없음 | 3·4 |
| 기본값 9 | 사업자등록번호 형식 검사 안 함. 길이 상한: 이름 100 · 사업자등록번호 30 · 주소 각 200 · 주소(URL) 500 | 피그마에 없음 | 3·5·6 |
| 기본값 10 | 주소(URL) 칸은 칸을 벗어날 때와 **저장 직전에** 화면이 빈 값이 아니고 `http://`·`https://` 로 시작하지 않으면 앞에 `https://` 를 붙인다(대소문자 무시 — 서버도 대소문자 무시로 판정). 서버는 빈 값이거나 `http://`·`https://` 로 시작할 때만 받는다(`url_invalid` 는 화면을 거치지 않은 호출을 막는 안전망) | 보안 | 3·5·6 |

---

## 🚦 착수 전 선결 조건

| # | 선결 조건 | 막는 조각 |
|---|---|---|
| S1~S4 | (결정됨 — 위 Q1~Q4) | — |
| S5 | 개발서버 시험 데이터 — 같은 회사에 활성 브랜드 둘 이상 + 보관 브랜드 하나, 회사 미연결 브랜드 하나, 한 계정이 A에서 대표·B에서 멤버, 일본어 이름이 빈 브랜드 하나. 기존 시험 계정 `zz-b2-owner`·`zz-b2-second` 의 브랜드를 회사에 연결해 쓴다 | 3·4·5·6 완료 확인(착수는 막지 않는다) |
| S6 | 피그마 원문 대조 — 칸 순서·안내 문구 글자를 그 화면을 만드는 조각 착수 때(00·00c → 4, 00a → 5, 00b → 6) | 4·5·6 |

---

## ⚠️ 사양서·작업표 stale 점검

1. **사양서 692줄** 「브랜드명 한글·일본어·영문 모두 고친다」 → D1(일본어 잠금). 사양서 본문은 기획이 고친다.
2. **사양서 543줄** 「주소 검색은 이 카드」 → 기본값 1(검색 뺌). 「1차는 직접 입력」으로(기획 몫).
3. **사양서 701줄** 관리자 회사 모달 브랜드 수 = `total_brands`(보관 포함) → D3과 기준이 갈린다. 묶음 ③ 때 맞출지 기획이 정한다.
4. **사양서 692줄** 「미정: 변경 기록을 어디서 볼지」 → Q1: 기록은 남기되 보는 화면은 묶음 ③.
5. **`brand-shell.js` 머리 주석** 「페이지 파일(brand-members.js·brand-mypage.js)」 → 조각 4에서 고친다.
6. **피그마 bw07-01b** 비밀번호 규칙 문구 → **코드가 정본**(`brandPasswordIssue`). 피그마를 코드에 맞추는 일은 기획에게 넘긴다.

---

## 한눈에 보는 의존 순서

```
1 회사 상세 주소 칸(데이터베이스, 운영에도 먼저 따로)
 ├→ 2 관리자 회사 화면 두 칸            ← 1이 그 코드를 받을 서버 전부에 있어야 머지
 └→ 3 브랜드 화면용 함수 셋 + 이력 표(데이터베이스, 개발서버만)
        └→ 4 브랜드 페이지 틀 + 보기(00·00c·회사 없음·불러오는 중·실패)
               └→ 5 브랜드 정보 수정(00a)
                      └→ 6 회사 정보 수정(00b, 대표 담당자만)
7 마이페이지 동그라미 글자 비우기(언제든 — 4보다 먼저 권장, brand-shell.js 가 겹침)
(1~7) → 8 문서 + 처음부터 끝까지 확인
```

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약(요지) | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| 1 | 회사 상세 주소 칸 | 새 마이그레이션 | `companies.address_detail text NULL` | 없음 | ○(7과) | 개발 |
| 2 | 관리자 회사 화면 주소 두 칸 | `dev/js/admin-company.js` · `dev/lib/storage.js`(`fetchCompanies` 한 줄) | `COMPANY_FIELDS` 에 `address_detail` · 라벨 「주소」/「상세 주소」 | 1(받을 서버 전부) | ○(3과) | 개발 |
| 3 | 브랜드 화면용 서버 함수 셋 + 이력 표 | 새 마이그레이션 | `get_my_brand_profile` · `update_my_brand_info` · `update_my_brand_company` · 이력 표·트리거 둘 | 1 | ○(2와) | 개발 |
| 4 | 브랜드 페이지 틀 + 보기 | 새 `dev/js/brand-info.js` · `dev/build.sh` · `dev/brand/index.html` · `dev/css/brand.css` · `dev/js/brand-shell.js` | `registerBrandPage('brand', …)` · `#brandInfoPage`·`#brandCompanyCard`·`#brandInfoCard` | 3 · S6 (S5 는 완료 확인 때) | ✗ | 개발 |
| 5 | 브랜드 정보 수정(00a) | `brand-info.js` · `brand.css` | `update_my_brand_info` 호출 · 결과 코드별 문구 | 4 · S6 | ✗ | 개발 |
| 6 | 회사 정보 수정(00b) | `brand-info.js` · `brand.css` | `update_my_brand_company` 호출 · 주황 안내 | 5 · S6 | ✗ | 개발 |
| 7 | 마이페이지 동그라미 글자 비우기 | `dev/brand/index.html` · `dev/js/brand-shell.js` | `data-brand-user-initial` 0건 | 없음 | ○ | 개발 |
| 8 | 문서 + 처음부터 끝까지 확인 | 사양서 「구현 결과」 · `docs/FEATURE_SPEC.md` · `CLAUDE.md`(규칙 파일은 고문에게) | — | 1~7 | ✗ | 개발 |

---

## 조각별 상세

### 작업 1 — 회사 상세 주소 칸
- **하는 일:** `companies` 에 상세 주소 칸 하나를 더한다. 기존 `address` 는 건드리지 않는다(= 기본 주소).
- **산출 계약:** `ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS address_detail text NULL;` + `COMMENT`(「상세 주소 — 기본 주소는 address」). 정책·트리거·함수는 바꾸지 않는다.
- **완료 정의:** 개발서버 SQL 편집기에서 `SELECT address, address_detail FROM public.companies LIMIT 1;` 가 오류 없이 돈다. 관리자 「회사 관리」가 이전과 똑같이 열린다.
- **검문소:** 브랜드 계정 표와 관계없어 **526~534 운영 묶음과 따로 운영에 먼저** 넣는다(Q3). 🔴 운영에 넣는 시점은 조각 2가 `main` 으로 가기 **전**.
- **주의:** 칸 이름 `address_detail` 은 조각 2·3·6 계약이 쓴다.
- **롤백:** `ALTER TABLE public.companies DROP COLUMN IF EXISTS address_detail;` — 🔴 조각 2 코드가 나간 서버에서는 지우기 **전에** 조각 2를 되돌린다.

### 작업 2 — 관리자 회사 화면 주소 두 칸
- **하는 일:** 관리자 회사 모달 주소를 두 칸으로. 회사 목록 조회가 새 칸도 받게.
- **산출 계약:** `COMPANY_FIELDS` 순서 … `homepage_url` → `{ key: 'address', label: '주소' }` → `{ key: 'address_detail', label: '상세 주소' }` → `billing_email` … · 입력 아이디 `companyF_address_detail` · `saveCompany`·`upsertCompany` 는 그대로(목록을 따라온다)
- **선행:** 조각 1이 **이 코드를 받을 서버 전부**에(개발서버는 `dev` 머지 전, 운영은 `main` 머지 전).
- **완료 정의:** 개발서버 관리자 「회사 관리」 → 회사 하나 → 「주소」·「상세 주소」 두 칸 → 상세 주소 입력·저장 → 다시 열면 남아 있다. 기존 주소는 「주소」 칸에 그대로. 브랜드 상세의 회사 선택 칸에 회사 목록이 그대로 뜬다(의심 4 양성 대조).
- **검문소:** 🔴 머지 직전 그 서버에서 `SELECT address_detail FROM public.companies LIMIT 1` 확인. 캠페인 매니저 계정에서 두 칸이 비활성으로 보이는지.
- **주의:** `storage.js` 는 핫스팟 — 다른 `storage.js` 작업과 병렬 금지. 묶음 ③이 `openCompanyModal` 을 다시 쓸 예정(같은 함수).

### 작업 3 — 브랜드 화면용 서버 함수 셋 + 이력 표
- **하는 일:** 보안 정의자 함수 셋(조회 · 브랜드 정보 저장 · 회사 정보 저장(대표만)) + 이력 표와 트리거 둘(Q1).
- **산출 계약(공통):** 셋 다 `LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''`. 결과의 `field` 값 = **저장 칸 이름**(인자에서 `p_` 를 뺀 것 — `name`·`name_en`·`official_instagram_url`·`official_x_url`·`name_ko`·`business_no`·`homepage_url`·`address`·`address_detail`). 실행 권한 **부여 먼저, 회수 나중**(375) — `GRANT EXECUTE … TO postgres, authenticated, service_role;` → `REVOKE … FROM PUBLIC;` → `REVOKE … FROM anon;`(369·370). 역할은 `public.my_brand_role(p_brand_id)` 로만, **회사 id 는 화면에서 받지 않고 서버가 브랜드 행에서 읽는다**. 반환 `jsonb`, 열쇠 `result`.
  - **`get_my_brand_profile(p_brand_id uuid) RETURNS jsonb`** (`STABLE`)
    - 역할 NULL → `{"result":"not_linked"}`
    - 정상 → `{"result":"ok","role":"owner"|"member","can_edit_company":boolean,"brand":{"id","name","name_ja","name_en","official_instagram_url","official_x_url"},"company":null|{"id","name_ko","business_no","homepage_url","address","address_detail"},"company_brands":[{"id","name"}]}`
    - `company_brands` = 같은 `company_id` 이고 `status='active'` 인 브랜드 전부(지금 브랜드 포함 · D3). 회사 없으면 `[]`. 🔴 **멤버(`role='member'`)에게는 `[]`** — 목록은 대표 화면만(D3, 서버가 뺀다). 순서는 화면(`compareBrandNames`)
    - `can_edit_company` = `role='owner' AND company IS NOT NULL`
    - 🔴 청구 이메일·청구 주소·메모·회사명(일본어·영문)·상태는 **싣지 않는다**
  - **`update_my_brand_info(p_brand_id uuid, p_name text, p_name_en text, p_official_instagram_url text, p_official_x_url text, p_prev jsonb) RETURNS jsonb`**
    - 일본어 칸 인자 **없음**(D1)
    - 순서: 역할 확인 → 브랜드 행 `FOR UPDATE` → 입력 정리(`btrim`, 빈 문자열 → NULL, `name` 빈 값 거부) → 검사 → ①`p_prev`(열쇠 `name`·`name_en`·`official_instagram_url`·`official_x_url`, 빈 문자열·열쇠 없음 = NULL) vs 지금 값 `IS DISTINCT FROM` → 다르면 `stale` ②입력값 vs 지금 값 → 모두 같으면 쓰지 않고 `ok` ③UPDATE(네 칸만)
    - 결과: `ok`(+`brand`) · `not_linked` · `name_required` · `too_long`(+`field`) · `url_invalid`(+`field`) · `name_taken`(`brands_name_normalized` 제약만 — 다른 유일 위반은 다시 던진다) · `stale`(화면이 다시 불러오므로 값은 싣지 않는다)
  - **`update_my_brand_company(p_brand_id uuid, p_name_ko text, p_business_no text, p_homepage_url text, p_address text, p_address_detail text, p_prev jsonb) RETURNS jsonb`**
    - 순서: 역할(NULL → `not_linked`, `member` → `not_owner`) → 브랜드 `company_id`(NULL → `no_company`) → 회사 행 `FOR UPDATE` → 입력 정리(`btrim`, 빈 문자열 → NULL, `name_ko`·`business_no` 빈 값 거부) → 검사 → ①`p_prev`(열쇠 `name_ko`·`business_no`·`homepage_url`·`address`·`address_detail`, 빈 문자열·열쇠 없음 = NULL) vs 지금 값 → 다르면 `stale` ②입력값 vs 지금 값 → 모두 같으면 쓰지 않고 `ok` ③UPDATE 다섯 칸 + `updated_by = auth.uid()` → 회사명이 바뀌었으면 `UPDATE public.brands SET company_name = 새 이름 WHERE company_id = 그 회사 AND company_name IS DISTINCT FROM 새 이름`(기본값 6)
    - 결과: `ok`(+`company`) · `not_linked` · `not_owner` · `no_company` · `name_required` · `business_no_required` · `too_long`(+`field`) · `url_invalid`(+`field`) · `name_taken`(`companies_name_normalized` 제약만) · `stale`(화면이 다시 불러오므로 값은 싣지 않는다)
  - **이력 표(Q1):** 새 표(이름은 작성 때, 예 `brand_profile_history`) — `id`·`target_kind CHECK(brand|company)`·`target_id`·`field_name`(CHECK — 브랜드 5칸 `name`·`name_ja`·`name_en`·`official_instagram_url`·`official_x_url` + 회사 5칸 `name_ko`·`business_no`·`homepage_url`·`address`·`address_detail`)·`old_value`·`new_value`·`changed_by`·`changed_by_name`·`change_source CHECK(admin|brand|system)`·`changed_at`. 판정 순서(트리거 안): `auth.uid()` 가 NULL → `system`(SQL 편집기·자동 처리, 이름 NULL) / `admins` 에 있으면 → `admin`(이름 `admins.name`) / `brand_accounts` 에 있으면 → `brand`(이름 `brand_accounts.name`) / 그 밖 → `system`. 쓰기는 `brands`·`companies` 의 `AFTER UPDATE OF <위 칸>` 트리거 둘만(관리자 저장도 남는다). 읽기 정책 `is_admin()` 하나. 🔴 트리거 칸 목록 · 트리거 안 비교 목록 · CHECK 는 **세 곳이 같은 집합**(266 교훈) — 마이그레이션 주석에 적는다
  - **캠페인 변경 이력(Q4):** 266 재정의 안 함.
- **완료 정의:** 🔴 SQL 편집기는 `auth.uid()` 가 없어 재현 안 됨 — **로그인한 브랜드 계정으로 실제 호출**(curl 비밀번호 로그인 → rpc 또는 화면 콘솔 `brandRpc`).
  - 대표: 조회 `ok`·`owner`·`can_edit_company:true` · 브랜드명 변경 `ok` → 관리자 목록·연결 캠페인 이름 바뀜 · 회사 저장 `ok` → 관리자 회사 모달에 반영
  - 멤버: 조회 `can_edit_company:false` · 회사 저장 `not_owner` · 브랜드 저장 `ok`
  - 연결 안 된 브랜드 · 인플루언서 계정: 셋 다 `not_linked` · 비로그인(공개 키): 실행 권한 오류
  - 다른 브랜드 이름: `name_taken` · `p_prev` 일부러 틀림: `stale`
  - 이력 표에 바뀐 칸 수만큼 줄, `change_source='brand'`, `changed_by_name` = 계정 이름 · 관리자 저장도 `admin` 으로 남음
  - 권한: `SELECT proname, proacl::text FROM pg_proc WHERE proname IN (…);` 맨 앞 `=X/` 없고 `anon` 없음
- **검문소:** `reverb-supabase-expert`(코드 쓰기 전) · ①`name_ja` 빈 브랜드 수(개발·운영)를 「구현 결과」에 ②브랜드명 변경 뒤 `campaign_change_history` 최근 행 확인·기록 ③`brands.company_name` 이 같은 회사 전부에서 바뀌었는지.
- **주의:** 173 트리거는 이 함수의 UPDATE에서도 돈다(의심 2 — 막지 않음). 반환 칸을 나중에 바꾸려면 `DROP` 후 `CREATE` 라 회수를 다시 건다. 운영 순서는 526~534 묶음 **뒤**.
- **롤백:** `DROP FUNCTION` 셋 + 트리거 둘·이력 표 `DROP`. 화면(4~6)을 먼저 되돌린다.

### 작업 4 — 브랜드 페이지 틀 + 보기
- **하는 일:** 「준비 중」을 실제 페이지로. 머리 「브랜드 관리」/「브랜드 정보를 관리합니다.」 아래 카드 둘(회사 정보 → 브랜드 정보, 브랜드 정보 안에 「SNS 정보」 절)을 읽기 전용으로. 상태는 두 축이다 — ①불러오기: 불러오는 중 · 실패(「다시 시도」) · 정상 ②정상일 때 역할: 대표(00) · 멤버(00c). 회사 미연결은 **회사 카드만** 미연결 안내로 바뀌고 브랜드 카드는 역할대로(대표·멤버 모두 「수정」).
- **담당 파일:** 새 `dev/js/brand-info.js` · `dev/build.sh`(`BRAND_JS_FILES` 에서 `js/brand-shell.js` 뒤, `js/brand-app.js` 앞) · `dev/brand/index.html`(같은 자리 원본 태그) · `dev/css/brand.css` · `dev/js/brand-shell.js`(「준비 중」 등록 삭제 · 머리 주석).
- **산출 계약:**
  - `registerBrandPage('brand', { title: '브랜드 관리', render(host) { … } })`
  - 상태 `_brandInfoData`(`undefined` 불러오는 중 / `null` 실패 / 응답) · `_brandInfoEditing`(`null`|`'brand'`|`'company'`) · `_brandInfoBusy` · `_brandInfoLoadSeq`
  - `loadBrandInfo()` → `brandRpc('get_my_brand_profile', { p_brand_id: getCurrentBrandId() })`, `not_linked` 면 `handleBrandNotLinked()`
  - DOM `#brandInfoPage` · `#brandCompanyCard` · `#brandInfoCard` · 단추 `data-bi-act="edit-company|edit-brand|cancel|save-company|save-brand|reload"`
  - 회사 카드 보기 칸: 회사명 · 사업자등록번호 · 홈페이지 URL · 주소 · 상세 주소(D2) / 브랜드 카드: 브랜드명(한글) · 브랜드명(일본어, 잠김) · 브랜드명(영문) + 「SNS 정보」 절(공식 Instagram URL · 공식 X URL)
  - 회사 안내(대표): 「이 회사의 브랜드: {이름 · 이름} — 회사 정보는 대표 담당자만 고칠 수 있습니다.」 + 같은 회사 활성 브랜드가 2개 이상일 때만 「 고치면 이 회사의 브랜드 모두에 함께 바뀝니다.」를 잇는다(기본값 7) / (멤버, 「수정」 없음): 「회사 정보는 대표 담당자만 고칠 수 있습니다. 바꿔야 하면 대표 담당자에게 요청해 주십시오.」
  - 회사 미연결: 「등록된 회사 정보가 없습니다 — 운영팀에 등록을 요청해 주십시오」(「수정」 없음)
  - 빈 값 「미입력」 · 이름 목록 `compareBrandNames` 정렬, 6개 넘으면 「외 {남은 수}개」 · 일본어 브랜드명은 늘 잠긴 칸 모양(`is-locked`)
  - `onBrandChanged` → `_brandInfoEditing = null` + 다시 불러오기 · `hashchange` 로 `#brand` 를 떠나면 수정 상태 버림
  - 주소(URL)는 글자로만(링크로 만들지 않음)
- **완료 정의:** 대표는 회사 카드에 「수정」, 멤버는 「수정」 없이 멤버 안내, 회사 미연결은 미연결 안내. 같은 회사 보관 브랜드 이름은 안 보임. 브랜드를 바꾸면 그 값으로 바뀜. 운영 주소(`globalreverb.com/brand/`)는 브랜드 화면 전체를 덮는 기존 「준비 중」 안내 그대로(이번 변경과 무관). 「브랜드」 메뉴의 「준비 중입니다」 등록은 개발·운영 구분 없이 지운다 — 개발서버 「브랜드」 메뉴에 「준비 중입니다」가 더는 안 뜸.
- **검문소:** 좁은 폭에서 카드가 세로로 쌓이는지 · Tab 으로 「수정」에 닿는지 · `reverb-reviewer`.

### 작업 5 — 브랜드 정보 수정(00a)
- **하는 일:** 브랜드 정보 「수정」 → 한글명·영문명·Instagram·X 칸이 열리고 일본어명은 잠긴 채 → 「취소」·「저장」. 수정 중 회사 카드 「수정」 숨김.
- **산출 계약:**
  - `field` ↔ 화면 칸: `name`→`brandInfoName` · `name_en`→`brandInfoNameEn` · `official_instagram_url`→`brandInfoInstagram` · `official_x_url`→`brandInfoX`
  - 입력 `brandInfoName`(필수 *, 100) · `brandInfoNameEn`(100) · `brandInfoInstagram` · `brandInfoX`(둘 다 500자, 둘 다 칸을 벗어날 때·저장 직전에 빈 값이 아니고 `http://`·`https://` 로 시작하지 않으면 앞에 `https://` 를 붙인다 — 기본값 10) · 잠긴 표시 `brandInfoNameJa`
  - `brandRpc('update_my_brand_info', { p_brand_id, p_name, p_name_en, p_official_instagram_url, p_official_x_url, p_prev })`
  - 결과 → 화면: `ok` → 「브랜드 정보를 저장했습니다.」 + `brandTouchActivity()` + `refreshBrandLoginState()` + 보기로 + `loadBrandInfo()`(회사 안내 목록의 지금 브랜드 이름까지 새로) · `name_required` → 칸 아래 「브랜드명(한글)을 입력해 주십시오.」 · `name_taken` → 「이 이름은 쓸 수 없습니다. 다른 이름을 입력하거나 운영팀에 문의해 주십시오.」 · `too_long` → 「글자 수가 너무 많습니다.」 · `url_invalid` → 「주소는 http:// 또는 https:// 로 시작해야 합니다.」(둘 다 `field` 가 가리키는 칸 아래) · `stale` → 토스트 「다른 담당자가 먼저 고쳤습니다. 최신 내용을 불러왔습니다. 다시 고쳐 주십시오.」 + 보기로 + `loadBrandInfo()` · `not_linked` → `handleBrandNotLinked()` · 오류 → 「저장하지 못했습니다. 잠시 후 다시 시도해 주십시오.」(입력 유지)
  - 입력 글자 16픽셀 이상(모바일)
- **완료 정의:** 멤버로 한글명 저장 → 토스트 → 좌측 위 브랜드명이 바로 바뀜 → 관리자 화면에서 연결 캠페인 이름도 바뀜. 일본어 칸은 어느 계정도 입력 불가. 두 탭에서 한쪽이 먼저 저장하면 다른 쪽이 `stale` 안내. 「저장」 연타 → 요청 한 번. 「취소」 → 원래 값.

### 작업 6 — 회사 정보 수정(00b, 대표 담당자만)
- **하는 일:** 회사 「수정」 → 회사명 *·사업자등록번호 *·홈페이지 URL·주소·상세 주소 → 주황 안내 → 「취소」·「저장」. 수정 중 브랜드 카드 「수정」 숨김(기본값 2).
- **산출 계약:**
  - `field` ↔ 화면 칸: `name_ko`→`brandCoName` · `business_no`→`brandCoBizNo` · `homepage_url`→`brandCoHomepage` · `address`→`brandCoAddress` · `address_detail`→`brandCoAddressDetail`
  - 입력 `brandCoName`(필수, 100) · `brandCoBizNo`(필수 D4, 30) · `brandCoHomepage`(500, 칸을 벗어날 때·저장 직전에 빈 값이 아니고 `http://`·`https://` 로 시작하지 않으면 앞에 `https://` 를 붙인다 — 기본값 10) · `brandCoAddress`(200) · `brandCoAddressDetail`(200). 「검색」 단추 없음
  - 주황 안내(같은 회사 활성 브랜드 2개 이상일 때만): 「저장하면 이 회사의 브랜드 {전체 수}개({이름 · 이름})에 함께 바뀝니다.」 — 이름은 6개까지, 넘으면 「외 {남은 수}개」(기본값 7) · `role="note"`
  - `brandRpc('update_my_brand_company', { p_brand_id, p_name_ko, p_business_no, p_homepage_url, p_address, p_address_detail, p_prev })`
  - 결과: `ok` → 「회사 정보를 저장했습니다.」 + `brandTouchActivity()` + 보기로 + `loadBrandInfo()` · `not_owner` → 토스트 「회사 정보는 대표 담당자만 고칠 수 있습니다.」 + `refreshBrandLoginState()` + 보기로 + `loadBrandInfo()` · `no_company` → 토스트 「등록된 회사 정보가 없습니다 — 운영팀에 등록을 요청해 주십시오」 + 보기로 + `loadBrandInfo()` · `name_required` 「회사명을 입력해 주십시오.」(`brandCoName` 칸 아래) · `business_no_required` 「사업자등록번호를 입력해 주십시오.」(`brandCoBizNo` 칸 아래) · `name_taken` 「이 회사명은 쓸 수 없습니다. 운영팀에 문의해 주십시오.」 · `too_long`·`url_invalid` 는 `field` 칸 아래 · 나머지는 조각 5와 같게
  - 화면은 `company.id` 를 보내지 않는다
- **완료 정의:** 대표로 상세 주소 저장 → 관리자 회사 모달 「상세 주소」에 값(조각 2 대조). 같은 회사 다른 브랜드 화면에도 반영. 사업자등록번호를 비우면 칸 아래 안내·저장 안 됨. 회사명 변경 → 관리자 오리엔시트 발급 목록의 회사명도 새 이름. A 대표·B 멤버 계정은 A에서만 「수정」.

### 작업 7 — 마이페이지 동그라미 글자 비우기
- **하는 일:** 좌측 아래 동그라미 안 이름 첫 글자를 없앤다(피그마). 빨간 점은 그대로.
- **담당 파일:** `dev/brand/index.html`(`<span data-brand-user-initial></span>` 삭제) · `dev/js/brand-shell.js`(`[data-brand-user-initial]` 채우기 한 줄 삭제).
- **완료 정의:** 동그라미가 비어 있다 · 새 초대가 있는 계정은 그 동그라미에 빨간 점 · 모바일 서랍 마이페이지 줄은 그대로. `data-brand-user-initial` 0건.
- **주의:** 비밀번호 규칙 문구는 코드를 바꾸지 않는다(기획에게 넘김).

### 작업 8 — 문서 + 처음부터 끝까지 확인
- **하는 일:** 사양서 「구현 결과」(실제 마이그레이션 번호 · 결과 코드 · `name_ja` 빈 브랜드 수 · 캠페인 변경 이력 실측) · `FEATURE_SPEC.md` · `CLAUDE.md`(현재 원본 번호에 새 함수 셋 · 운영 묶음 순서 · 조각 1 운영 반영 상태 · 🔴 관리자 화면 덮어쓰기 경고(Q2)). 규칙 파일(`brand-account.md`·`brand-admin.md`)은 고문에게. Notion 「회사 관리」는 운영 배포 뒤.
- **완료 정의:** 시험 계정으로 00·00a·00b·00c·회사 미연결 화면 확인(`browser-qa.md` 방식).

---

## ⚠️ 공유 지점 경고

- 🔴 **`fetchCompanies` 칸 목록(storage.js)** — 조각 1이 없는 서버에 조각 2가 나가면 브랜드가 회사에서 떨어진다. 운영 배포 전 운영 데이터베이스에 칸이 있는지 **SQL로** 확인.
- **관리자 저장 두 곳(`saveBrandDetail`·`saveCompany`)** — 브랜드가 고친 값을 통째 저장으로 되돌린다(Q2 — 묶음 ③). 묶음 ③이 `openCompanyModal`·`_collectBrandFormPatch` 를 다시 쓰므로 조각 2와 같은 파일 — 같은 시기 병렬 금지.
- **`brand-shell.js`** — 조각 4와 7이 함께 건드린다. 한 사람이 하거나 7을 먼저 머지.
- **`dev/build.sh`·`dev/brand/index.html` 원본 태그** — 조각 4만.
- **173·266·275 트리거** — 바꾸지 않지만 **브랜드 계정이 처음으로 부른다**.
- **로그인 판정 `brands[].name`** — 브랜드명 저장 뒤 `refreshBrandLoginState()` 를 빼면 좌측 위 이름이 옛 이름으로 남는다.
- **`my_brand_role`(530)** — 판정을 바꾸면 세 함수 권한도 함께 바뀐다.

---

## 🧭 배분 제안

- **개발 1명, 순서대로:** 7 → 1 → 2 → 3 → 4 → 5 → 6 → 8. 마이그레이션 둘(1·3)은 한 세션에서만.

---

## 기획에게 넘길 것 (질문 아님)

1. 피그마 bw07-01b 비밀번호 규칙 문구를 코드(`brandPasswordIssue`)에 맞추기
2. 사양서 692줄(일본어 잠금 D1)·543줄(주소 검색 뺌)·701줄(브랜드 수 기준) 고치기
3. 주황 안내가 브랜드 1개일 때 숨는 것(기본값 7)과 「외 N개」 표시를 피그마에 반영할지

---

## 구현 결과

2026-10-16 개발서버 완료 — 상세는 사양서 `docs/specs/2026-07-15-brand-portal.md` 「구현 결과 — 브랜드 관리 화면」(번호·결과 코드·실측·달라진 것·넘기는 것을 한 자리에 적었다).

| 조각 | PR | 실제 결과 |
|---|---|---|
| 7 동그라미 글자 | #2095 | `data-brand-user-initial` 0건(작업표 커밋 동반) |
| 1 상세 주소 칸 | #2096 | 마이그레이션 **535** — 개발서버 적용 · **운영 적용 2026-10-16**(조각 2 운영 배포 전 선적용 — 결정 Q3) |
| 2 관리자 회사 화면 | #2097 | 「상세 주소」 칸(주소 뒤) · `fetchCompanies` 칸 목록 |
| 3 함수 셋 + 이력 표 | #2098 | 마이그레이션 **536** — 개발서버 적용, 운영 미적용 |
| 4 틀 + 보기 | #2100 | `dev/js/brand-info.js` |
| 5 브랜드 정보 수정 | #2101 | 대표·멤버 확인 |
| 6 회사 정보 수정 | #2106 | 대표 확인 — 회사명 사본 3개·이력 표 반영 |
| 8 문서 | (이 커밋) | 사양서 · `FEATURE_SPEC.md` §67 · `CLAUDE.md` |

작업표와 다른 점: 보기 화면 빈 칸 「미입력」 · 상세 주소 자리표시 「상세 주소」 · 이력 표에 묶음 번호·인덱스 추가 · 캠페인 변경 이력은 이름 없는 `admin` 으로 남는다(실측, Q4 로 그대로).
