# 📋 작업 분해표 — 오리엔시트 단순화(발급 단위 재설계 · 항목 정리 · 견적서 · 큐텐 자동 채움)

**사양서:** `docs/specs/2026-09-08-orient-sheet-simplify-and-quote.md`
**분해일:** 2026-09-08
**총 작업 조각:** 23개 · **병렬 가능:** 4개(트랙 시작점) · **순차 필수:** 19개

> 검증 기준: 브랜치 `feature/기획-오리엔시트-재설계`(origin/dev 와 같음). 「사양서 stale 점검」은 사양서 「착수 전 알아야 할 것」 절에 **이미 적힌 4건을 뺀** 새 발견만 적었다. 이 표에서 나온 결정(선-3·선-4)은 사양서 본문에 이미 반영됐다.

---

## 🚦 착수 전 선결 조건 (작업표보다 먼저)

| # | 선결 조건 | 근거 | 막는 조각 |
|---|---|---|---|
| **선-1** | **시딩 채널별 1인 진행비 초기값 5종**(인스타그램-피드 / 인스타그램-릴스 / X / 틱톡 / 유튜브) — 원화 금액 | 사양서 §8-③ · §4-5 표. 값이 없으면 시딩 견적이 **0원짜리 문서**로 브랜드에게 나간다 | **작업 13**(견적 기준값 표) 운영 배포 · **작업 20**(2단계 배포). 개발·검증은 0원 시드로 진행 가능 |
| **선-2** | **큐텐 페이지 자동 읽기의 이용약관 위험** — 진행 / 조사 후 결정 / 보류 | 사양서 §8-⑫. 사양서가 「확인하지 않았다」고 명시 | **작업 21~23**(3단계 전부) |
| ~~선-3~~ | ~~「견적서 · PDF 저장」 단추 자리~~ → **결정(2026-09-08): 새 「제출 완료 화면」을 만든다** | 작성 폼에 완료 화면이 없었다(stale 점검 ①). 사양서 §4-6 에 반영 | (해소) |
| ~~선-4~~ | ~~견적 기준값 화면 자리~~ → **결정(2026-09-08): 기준 데이터 화면의 종류 탭 하나** | 목록형 레이아웃에 카드를 더 넣으면 높이 배분이 깨진다(stale 점검 ⑥). 사양서 §4-5 에 반영 | (해소) |
| 선-5 | 시딩의 **배송 안내·금지 표현·추가 안내** 유지 여부(사양서 §8-⑥, 잠정 ⓐ) | 「당분간 유지」로 착수 가능 — **막지 않는다.** 뒤집히면 §4-2 표 한 줄 + 작업 6 의 삭제 목록만 고친다 | (없음 — 참고) |
| 선-6 | 「예시 넣기」 예시 문안(리뷰 가이드·소구 키워드, 사양서 §8-⑬ 잠정 ⓛ) | 마케팅팀이 주면 작업 7 에 붙인다. **막지 않는다**(없으면 링크를 안 그린다) | (없음 — 참고) |

⚠️ **선-1 은 2단계 「배포」만 막고 「구현」은 안 막는다.** 0원으로 시드해 두고 화면·계산을 다 만든 뒤, 값이 오면 관리자 화면에서 그대로 입력하면 된다(그러라고 만드는 화면이다).

---

## ⚠️ 사양서 stale 점검

사양서 §1-1 이 인용한 파일·함수는 **거의 전부 실재하고 「현재 원본」 번호도 맞다**(`create_orient_sheet`=205 / `save_orient_draft`·`submit_orient_sheet`=329 / `get_orient_sheet`=187 / `orient_token_can_upload`=200). 아래는 사양서가 조건부로 남겨 둔 것을 실제로 확인한 결과와, 코드가 사양서와 어긋난 자리다.

### ① 🔴 작성 폼에 「제출 완료 화면」이 없었다 → 새로 만든다(선-3 결정)

`dev/sales/orient.html` 의 화면은 넷뿐 — `screenLoading`(497줄) · `screenError`(503) · `screenForm`(510) · `screenPreview`(584). 하단 고정바 `footbar`(593) 안에 `saveState`/`saveStateText`(595). 제출 성공 시 `submitSheet()`(1799줄)는 `closePreview()` → `enterFormScreen()` → `setSaveState('saved', '제출 완료')` → 토스트 뿐이다. → **작업 17 이 `screenDone` 을 새로 만든다**(재진입·새로고침·수정 복귀까지 — 사양서 §4-6 「완료 화면(신설)」).

### ② 발급 메일 양식에는 고칠 문구가 **없다**

`docs/email-templates/orient-sheet-invite.html` 과 미러 `supabase/functions/notify-orient-sheet/_templates/orient-sheet-invite.html` 둘 다 형식·카드 이야기를 하지 않는다(0건). → 「메일 문구 수정」은 **선택 조각**(작업 11)이고, 넣는다면 「이 링크는 {형식}·{채널} 용입니다」를 **새로 더하는 결정**이다.

### ③ 「카드마다 형식 선택」 문구는 화면에도 없다 — 전부 **코드 주석**

`dev/js/admin-orient.js` 6·337·374줄, 셋 다 주석. → 사양서 §4-1 의 「문구 제거」는 실제로는 **주석 정리**(작업 4 에 포함).

### ④ `dev/lib/storage.js` 에 **부르는 곳이 0곳인 감싸개 두 개**

`saveOrientDraft`(4973줄)·`submitOrientSheet`(5002줄) — 호출부 0곳(작성 폼은 `sb.rpc` 직접 호출). 빌드 산출물에는 실려 있다. → Ⓑ·Ⓓ 가 반환값·거부 코드를 바꿔도 **깨질 것은 없다.** 작업 3 에서 **「호출부 없음」 주석 한 줄**로 못 박는다(지우는 것은 범위 밖).

### ⑤ `sales/reviewer.html` 은 **빌드 산출물** — 원본은 `dev/sales/reviewer.html`

`EXCHANGE_RATE = 10`(1479줄) · `TRANSFER_FEE = 2500`(1480줄) · `calcQuote()`(1759줄). `dev/build.sh` 139~153줄이 `dev/sales/*.html` 을 `../sales/` 로 복사한다. 사양서 경로 표기를 원본으로 고쳤다.

### ⑥ 기준 데이터 페인은 「카드 한 장 추가」가 구조에 안 맞는다 → 탭(선-4 결정)

`#adminPane-lookups`(`dev/admin/index.html` 2699줄)는 `admin-pane-list`(머리글 고정 + 표 몸통만 스크롤, `admin-card` 정확히 하나 — 2724줄). 이미 **종류 탭 7개**(2714~2720줄, `switchLookupTab`)로 돌아간다. → **여덟 번째 탭**.

### ⑦ 시딩 채널 5종이 **세 곳**에 놓인다 — 지금은 한 곳에만

`SEEDING_CHANNELS`(5종)는 `dev/sales/orient.html` 640줄에만. 관리자 `OS_CH_LABEL`(admin-orient.js 53줄)은 **9종**(피드·릴스·instagram·X·틱톡·유튜브·Qoo10·LIPS·@cosme)이라 발급 드롭다운 재료로 쓰면 **서버가 거부할 값을 고를 수 있는 화면**이 된다. → 작업 4 에서 `OS_SEEDING_CHANNELS`(5종)를 따로 두고, Ⓐ 서버 검증까지 세 곳이 같은 집합임을 각 자리 주석에 적는다.

### ⑧ §4-7 에 **교차 출처 허용 헤더(CORS)** 이야기가 없다

`qoo10-product-lookup` 은 작성 폼 브라우저가 직접 부르는 함수 → `.claude/rules/supabase.md` 「브라우저 직접 호출 Edge Function 은 교차 출처 허용 헤더 필수」. 같은 조건의 `notify-orient-sheet` 가 헤더 없이 배포돼 **리뷰·운영 배포를 다 통과하고도 한 번도 성공하지 못한** 전례 → 작업 22 완료 정의에 사전요청(OPTIONS) 확인.

### ⑨ 가이드 초안의 [NG]·[추가 안내] 블록은 **형식으로 안 갈린다**

`osBuildGuideDraft`(admin-orient.js 1638줄) 1653·1654줄 — `card.cautions`·`card.ng` 를 형식 구분 없이 넣는다. 사양서 §4-4 대로 **리뷰어만 생략**하려면 형식으로 갈라야 한다(그냥 지우면 시딩 값까지 사라진다). ⚠️ `sd.required_content`(1648)·`sd.gift`(1649) 줄은 **지우면 안 된다** — 옛 시트에 값이 남아 있고 발행 때 관리자가 본다.

### ⑩ 부가세 자릿수 규칙 — `floor`

트리거 111(104~106줄): `v_vat := floor(v_supply * 0.1)`. Ⓓ 도 **`floor`** 를 쓴다(사양서 §4-6 에 반영).

### ⑪ `create_orient_sheet` 의 실행 권한 대상은 **`authenticated`** (`anon` 아님)

205 의 343~344줄: `REVOKE ... FROM PUBLIC; GRANT ... TO authenticated;`. 익명 함수 3종(→ `anon`)과 **대상이 다르다.** Ⓐ 가 `DROP` 후 다시 만들 때 `anon` 으로 잘못 걸면 **누구나 오리엔시트를 발급**할 수 있게 된다.

### ⑫ 줄 번호 소소한 차이(기록용)

`collectCard` 실제 1475(사양서 1,478) · `renderPreviewCard` 1734(1,735) · `osBrandCard` 979(980). 사양서가 「이름으로 찾을 것」이라 적었다.

---

## 한눈에 보는 의존 순서

```
[선결] 선-1(시딩 단가) ─┐   [선결] 선-2(큐텐 약관)
                        │              │
━━ 1단계 ━━━━━━━━━━━━━  ━━ 2단계 ━━━━━━┷━━━━  ━━ 3단계 ━━┷━━━━━

 트랙 A (마이그레이션 — 한 세션만)
   1 Ⓐ create_orient_sheet ──▶ 2 Ⓑ save/submit ①차
                                      │
                                      └──────────────▶ 13 Ⓒ quote_settings ──▶ 16 Ⓓ submit ②차
                                                              │                       │
 트랙 B (dev/sales/orient.html — 병렬 금지)                    │                       │
   5 새/옛 분기 뼈대 ──▶ 6 항목 삭제 ──▶ 7 글자 수 ──▶ 8 시딩 일정 ──▶ 12 배포·눈확인   │
                                                                                       ▼
                                                                        17 완료 화면+견적서 진입점 ──▶ 18 인쇄용 화면 ──▶ 20 배포·인쇄실측
 트랙 C (dev/js/admin-orient.js + dev/lib/storage.js — 병렬 금지)                              │
   3 storage.js 인자·주석 ──▶ 4 발급 모달 ──▶ 9 상세 빈값생략·배지 ──▶ 10 발행 매핑           │
                                                                                              │
   14 storage.js 견적값 감싸개 ──▶ 15 기준데이터 탭(admin-lookups.js)                          │
                                                              19 상세 견적카드·열기 ◀─────────┘
 트랙 D (선택·독립)
   11 발급 메일 문구 (사용자 결정 필요)

 3단계 (순차 한 줄)
   21 개발서버 읽기 검증 ──▶ 22 Edge Function ──▶ 23 폼 연결
```

**단계 경계:** 1단계 전부가 **운영까지** 나간 뒤 2단계 착수(사양서 §7). 2단계 배포 뒤 3단계.

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약 | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| **1** | 마이그레이션 Ⓐ — 발급 함수 재정의 | `supabase/migrations/{새번호}_*.sql` | `create_orient_sheet(p_brand_id uuid, p_application_id uuid DEFAULT NULL, p_form_type text DEFAULT NULL, p_channel text DEFAULT NULL)` · `data.issued{form_type,channel,issued_at}` · 거부 `invalid_form_type`·`channel_required`·`invalid_channel` | — | ✅ 트랙 A 시작 | 개발(데이터베이스) |
| **2** | 마이그레이션 Ⓑ — 저장·제출 함수 ①차 | 같은 폴더 새 파일 | 서버 키 보존 4종(`issued`·`quote`·`quote_history`·`quote_error`) · 형식/채널 원본 덮어쓰기(`issued` 있을 때만) · 제출만 `cards_limit`·`guide_too_long`·`appeal_too_long` | 1 | ❌ 같은 세션 | 개발(데이터베이스) |
| **3** | 데이터 접근 함수 인자 확장·주석 정정 | `dev/lib/storage.js` | `createOrientSheet(brandId, applicationId, formType, channel)` · 초기값 주석 정정 · 죽은 감싸개 2개에 「호출부 없음」 명시 | 1(적용) | ✅ 트랙 C 시작 | 개발(관리자) |
| **4** | 발급 모달 — 형식 라디오 + 채널 드롭다운 | `dev/js/admin-orient.js` | `OS_SEEDING_CHANNELS`(5종) · `osOpenCreate` 초기화 · `osSubmitCreate` 4인자 · `osReasonText` 거부 3종 · 주석 정리 | 3 | ❌ 같은 파일 | 개발(관리자) |
| **5** | 작성 폼 — 새/옛 구조 분기 뼈대 | `dev/sales/orient.html` | `isNewLayout()`(= `!!data.issued`) · 새 구조는 카드 1개 고정 · 「제품 추가」 제거 · 형식/채널 읽기 전용 배지 | 1(적용) | ✅ 트랙 B 시작 | 개발(작성 폼) |
| **6** | 작성 폼 — 항목 삭제 | `dev/sales/orient.html` | 공통 6 · 리뷰어 2 · 시딩 3 삭제. 옛 구조 경로 **무변경** | 5 | ❌ 같은 파일 | 개발(작성 폼) |
| **7** | 작성 폼 — 글자 수 제한 | `dev/sales/orient.html` | 리뷰 가이드·소구 키워드 각 1,000자, **서식 뺀 본문 기준**, 그 자리에서 자르고 「{현재} / 1000」 표시 · 「예시 넣기」는 문안이 오면(잠정 ⓛ) | 6 | ❌ 같은 파일 | 개발(작성 폼) |
| **8** | 작성 폼 — 시딩 예상 일정 안내 | `dev/sales/orient.html` | 읽기 전용 계산 표시(모집 마감 +10~14 · 배송 5~7 · 최종 업로드 +25~35), **저장 안 함** | 7 | ❌ 같은 파일 | 개발(작성 폼) |
| **9** | 관리자 상세 — 빈 값 생략 + 형식·채널 배지 | `dev/js/admin-orient.js` | `osField`/`osFieldHtml`/`osFieldRow` 빈 값이면 줄 안 그림 · 카드 머리에 채널 · `osCardsSummary` 「시딩 · 인스타그램-피드」 | 4 | ❌ 같은 파일 | 개발(관리자) |
| **10** | 발행 자동 채움 매핑 변경 | `dev/js/admin-orient.js` | `applyOrientCardPrefill` 이 `issued` 유무로 **두 매핑을 나란히** · `osBuildGuideDraft` 블록을 형식으로 가름 | 9 | ❌ 같은 파일 | 개발(관리자) |
| **11** | (선택) 발급 메일 문구에 형식·채널 안내 | `docs/email-templates/orient-sheet-invite.html` + `_templates/` 미러 + `supabase/functions/notify-orient-sheet/index.ts` | 새 치환 열쇠말 `{{form_type_label}}`·`{{channel_label}}` | — | ✅ 독립 | 개발(메일) · **사용자 결정 필요** |
| **12** | 1단계 sales 빌드·배포·눈 확인 | `bash dev/build.sh` → `sales/orient.html` | 복사본 갱신 + `reverb-sales` 배포 + 브라우저 확인 | 5~8, 1~2(운영 적용) | ❌ | 개발 + 사용자 |
| **13** | 마이그레이션 Ⓒ — 견적 기준값 표 | 새 파일 | `quote_settings`·`quote_settings_history`·`get_quote_settings()`·`update_quote_setting(key, amount)` + 초기 행 9개 | 2(운영 적용) | ✅ 트랙 A | 개발(데이터베이스) |
| **14** | 견적 기준값 데이터 접근 함수 | `dev/lib/storage.js` | `fetchQuoteSettings()` · `updateQuoteSetting(key, amount)` | 13 | ✅ 트랙 C | 개발(관리자) |
| **15** | 기준 데이터 화면에 「견적 기준값」 탭 | `dev/js/admin-lookups.js` + `dev/admin/index.html` | 여덟 번째 종류 탭(`switchLookupTab('quote_settings', …)`) · 인라인 수정 · `refreshPane('lookups')` | 14 | ❌ | 개발(관리자) |
| **16** | 마이그레이션 Ⓓ — 제출 함수 ②차(견적 계산) | 새 파일 (**베이스 = 작업 2 파일**) | `data.quote` 스냅샷 · `quote`/`quote_error` 세트 규칙 · `quote_history` 누적 · 반환값에 `quote`/`quote_error` | 13 | ❌ 같은 세션 | 개발(데이터베이스) |
| **17** | 작성 폼 — 제출 완료 화면 + 견적서 진입점 | `dev/sales/orient.html` | `screenDone`(신설) · 「견적서 · PDF 저장」 단추(이름 고정) · 「내용 수정하기」 · `quote_error` 면 안내 · `submitted` 재진입 시 완료 화면 먼저 | 16 | ✅ 트랙 B | 개발(작성 폼) |
| **18** | 작성 폼 — 인쇄용 견적서 화면 | `dev/sales/orient.html` | `?token=…&view=quote` · `screenQuote` · `@media print` · `window.print()` · 견적 번호 `{orient_no}-Q` · 형식별 고정 문구 | 17 | ❌ 같은 파일 | 개발(작성 폼) |
| **19** | 관리자 상세 — 예상 견적 카드·「견적서 열기」 | `dev/js/admin-orient.js` | `quote` 있으면 금액 요약 + 「판 N」 + 지난 판 접기 · `quote_error` 면 한 줄 · 새창 `{sales}/orient?token=…&view=quote` | 16 | ✅ (15와 다른 파일) | 개발(관리자) |
| **20** | 2단계 배포 + 인쇄 실측 | 빌드·배포 | 실제 인쇄 대화상자로 PDF 저장까지 · 모바일 사파리 안내 | 15·17·18·19, **선-1** | ❌ | 개발 + 사용자 |
| **21** | 3단계 0) 개발서버 읽기 검증 | `supabase/functions/qoo10-product-lookup/`(임시) | 상품 3개에서 상품 정보 묶음이 오는지 · **실패면 여기서 멈추고 「보류」 기록** | 선-2 | ❌ | 개발 |
| **22** | Edge Function `qoo10-product-lookup` | 같은 폴더 + 배포 | 입력 `{token,url}` → `{goods_code, product_name, store_name, price_sale_jpy, price_list_jpy, image_url}` / 실패는 전부 `{ok:false}` · 교차 출처 헤더 · 토큰 관문 · 호스트 제한 · 분당 5회 | 21 | ❌ | 개발 |
| **23** | 작성 폼 — 판매 URL 자동 채움 연결 | `dev/sales/orient.html` | `onSaleUrlBlur` · **빈 칸만** 채움 · `sale.goods_code`·`sale.store_name`·`sale.image_url`·`sale.price_list` 저장 | 22 | ❌ | 개발(작성 폼) |

---

## 조각별 상세

### 작업 1 — 마이그레이션 Ⓐ: 발급 함수 재정의
- **하는 일:** `create_orient_sheet` 에 형식·채널 인자를 더하고, 값이 있으면 `data.issued` 를 심은 **카드 1개짜리 초기값**으로 발급. `orient_sheets.form_type` 칸에도 형식을 넣는다.
- **담당 파일:** `supabase/migrations/{새번호}_orient_issue_with_form_type.sql`(번호는 만드는 순간 확정 — 마지막 번호 확인)
- **산출 계약:** `public.create_orient_sheet(p_brand_id uuid, p_application_id uuid DEFAULT NULL, p_form_type text DEFAULT NULL, p_channel text DEFAULT NULL) RETURNS jsonb`. 반환 키 205 그대로(`success`·`id`·`token`·`token_expires_at`·`orient_no`). 거부 `reason`: `invalid_form_type`(reviewer·seeding 외 — **`proxy_purchase` 도 거부**) · `channel_required` · `invalid_channel`. 채널 5종 `instagram_feed`·`instagram_reels`·`x`·`tiktok`·`youtube`. `p_form_type` 이 **NULL 이면 205 와 똑같이**(옛 구조, `issued` 없음). 값이 있을 때 `data` 초기값은 사양서 §4-1 JSON 그대로(`brand` 에 `intro`·`official_accounts` 키 없음).
- **선행 의존:** 없음
- **완료 정의:** ①개발 적용 후 함수 조회에서 **4인자 함수 1개만** ②실행 권한: `authenticated` 있음 · `PUBLIC`·`anon` 없음(`proacl::text` 맨 앞 `=X/` 없음) ③관리자 로그인 브라우저에서 4인자 호출 → `success:true`, `data.issued` 값 일치, `cards` 길이 1 ④**2인자로도 호출** → 성공, `issued` 없음·`cards` 빈 배열 ⑤거부 3종 각 1회 사유 일치
- **필요 검문소:** `reverb-supabase-expert` → 개발 적용 → **실제 로그인 브라우저 호출**(관리자 가드는 SQL 편집기로 재현 안 됨) → `reverb-reviewer`
- **주의·롤백:** 🔴 인자 개수가 늘어 `CREATE OR REPLACE` 로는 안 된다 — `DROP FUNCTION public.create_orient_sheet(uuid, uuid);` 뒤 새로 만들고 **같은 파일에서** `REVOKE EXECUTE … FROM PUBLIC;` + **`GRANT EXECUTE … TO authenticated;`**(⚠️ `anon` 아님 — stale ⑪) ⚠️ 새 인자에 반드시 기본값 ⚠️ 205 끝의 스키마 캐시 재로드를 그대로 넣는다. **롤백:** 새 함수 `DROP` + 205 블록·권한 두 줄 재실행.

### 작업 2 — 마이그레이션 Ⓑ: 저장·제출 함수 ①차
- **하는 일:** `save_orient_draft`·`submit_orient_sheet` 를 **함께** 재정의 — ①서버 키 보존 ②형식·채널 원본 덮어쓰기 ③제출에만 카드 1개 제한·글자 수 재검증.
- **담당 파일:** `supabase/migrations/{새번호}_orient_save_submit_guard.sql`
- **산출 계약:** 시그니처 그대로(`CREATE OR REPLACE`). **두 함수 공통:** 저장돼 있던 `issued`·`quote`·`quote_history`·`quote_error` 네 키를 들어온 값과 무관하게 다시 얹는다. **두 함수 공통, `issued` 있을 때만:** `cards[0].form_type := issued.form_type`, 시딩이면 `cards[0].seeding.channels := [issued.channel]`. **제출만, `issued` 있을 때만:** 카드 2개 이상 `cards_limit` · 리뷰 가이드 1,000자 초과 `guide_too_long` · 소구 1,000자 초과 `appeal_too_long`. 반환 키 329 그대로. 파일 머리말에 **「Ⓓ 가 이 파일을 베이스로 삼는다」**.
- **선행 의존:** 작업 1(같은 세션)
- **완료 정의:** ①새 시트에 `issued` 뺀 `data` 임시저장 → 조회하면 `issued` 살아 있음 ②`cards[0].form_type` 딴 값 임시저장 → `issued` 값으로 되돌아옴 ③카드 2개: 임시저장 성공·제출 `cards_limit` ④1,001자: 임시저장 성공·제출 `guide_too_long` ⑤**옛 구조 시트**로 카드 2개·1,001자 제출 통과 ⑥`card_uids` 가 329 검증과 같은 값
- **필요 검문소:** `reverb-supabase-expert` → 개발 적용 + 6가지 실호출 → `reverb-reviewer`
- **주의·롤백:** 🔴 카드 고유 번호 부분(`_orient_apply_card_uids`·`_orient_sent_card_uids` 호출)은 329 에서 **글자 그대로** 🔴 **임시저장에 거부를 걸지 않는다** 🔴 키 보존을 빠뜨리면 사양 전체가 헛돈다 ⚠️ 파일 안에서 `REVOKE … FROM PUBLIC; GRANT … TO anon;` 을 다시 적는다. **롤백:** 329 두 블록 재실행.

### 작업 3 — 데이터 접근 함수 인자 확장·주석 정정
- **담당 파일:** `dev/lib/storage.js`
- **산출 계약:** `createOrientSheet(brandId, applicationId, formType, channel)` → `p_form_type`·`p_channel`(없으면 `null`). 5035줄 주석의 초기값을 두 갈래(형식 있음/없음)로 정정. `saveOrientDraft`(4973)·`submitOrientSheet`(5002) 위에 **「호출부 없음 — 작성 폼은 `sb.rpc` 직접 호출」** 한 줄.
- **선행 의존:** 작업 1(개발 적용)
- **완료 정의:** 빌드 통과 · `admin/index.html` 에 4인자 정의 · 발급이 여전히 됨(작업 4 전에는 `null` 로 나가 옛 경로)
- **필요 검문소:** `reverb-reviewer`
- **주의·롤백:** ⚠️ 핫스팟 파일 — 같은 시각에 다른 작업이 안 만지게 ⚠️ 죽은 감싸개를 지우지 않는다. **롤백:** 인자 두 개 제거.

### 작업 4 — 발급 모달: 형식 라디오 + 채널 드롭다운
- **담당 파일:** `dev/js/admin-orient.js`(모달은 `ensureOrientModals` 1773줄 안 동적 생성 — `dev/admin/index.html` 안 만짐)
- **산출 계약:** `OS_SEEDING_CHANNELS = ['instagram_feed','instagram_reels','x','tiktok','youtube']`(라벨은 `OS_CH_LABEL` 재사용). DOM 식별자(제안) `osCreateFormType`(라디오 이름)·`osCreateChannelRow`·`osCreateChannel`. `osOpenCreate(opts)` 열릴 때마다 초기화. `osSubmitCreate()` → 형식 미선택 「모집 형식을 선택해 주세요」 · 시딩 채널 미선택 「게시 채널을 선택해 주세요」 → `createOrientSheet(brandId, appId, formType, channel)`. 드롭다운 아래 **「채널이 여럿이면 링크를 따로 발급하세요」**. `osReasonText` 거부 3종 한국어. 6·337·374줄 주석 정리.
- **선행 의존:** 작업 3
- **완료 정의:** ①진입점 **3곳**(현황 「신규 발급」 / 서베이 더보기 「오리엔시트 링크생성」 / 브랜드 상세 「오리엔시트 발급」) 모두 열면 형식이 비어 있다 ②리뷰어면 채널 줄 안 보임·시딩이면 보임 ③시딩+채널 발급 → 링크·번호, 상세에 형식·채널 ④형식 없이 누르면 막힘 ⑤목록 「모집 형식」 열에 채널
- **필요 검문소:** `reverb-reviewer` · 브라우저 눈 확인
- **주의·롤백:** 🔴 `OS_CH_LABEL`(9종)을 드롭다운 재료로 쓰지 않는다(stale ⑦) ⚠️ 채널 5종 세 곳(폼 640줄·여기·Ⓐ)에 서로 위치 주석 ⚠️ 동적 생성 모달이라 초기 문자열과 `osOpenCreate` 초기화 두 곳. **롤백:** 라디오·드롭다운 감추고 `null, null`.

### 작업 5 — 작성 폼: 새/옛 구조 분기 뼈대
- **담당 파일:** `dev/sales/orient.html`
- **산출 계약:** `isNewLayout()` = `!!(loadedData && loadedData.issued)` — `boot()`(730줄)이 `data` 를 모듈 변수에 담는다. 새 구조: 「제품 추가」·카드 삭제 단추 안 그림 · `cardHtml`(1003) 머리에 형식 배지(+시딩 채널). 옛 구조: `cardHtml`·`collectCard`·`findInvalidField`·`renderPreviewCard` **기존 경로 무변경**. `collectData`(1561) 그대로.
- **선행 의존:** 작업 1(개발 적용)
- **완료 정의:** ①새 시딩 시트: 형식 탭 없음·카드 1·제품 추가 없음 ②배지 값 일치 ③**옛 구조 시트**(개발에 `issued` 없는 시트 하나 준비): 탭·카드 여러 개·제품 추가 그대로, 카드 2개 임시저장·제출 됨 ④새 구조 임시저장 → 새로고침 복원
- **필요 검문소:** `reverb-reviewer` · 브라우저 눈 확인(개발 sales 도메인)
- **주의·롤백:** 🔴 이 분기를 빠뜨리면 조용한 데이터 유실(운영 다중 카드 14건) ⚠️ 별도 배포 프로젝트 ⚠️ 「제품 추가」를 함수째 지우지 않는다. **롤백:** `isNewLayout()` 항상 `false`.

### 작업 6 — 작성 폼: 항목 삭제
- **담당 파일:** `dev/sales/orient.html`
- **산출 계약(새 구조 한정):** 공통 6(`brand.intro`·`brand.official_accounts`·`product.category`·`recruit.recruit_end`·`recruit.upload_start`·`upload_end`·`reverb_request`) · 리뷰어 2(`ng`·`cautions`) · 시딩 3(`seeding.grade`·`required_content`·`gift`). 시딩 「게시물에 태그할 계정」 안내문에 「브랜드 공식 SNS 계정 포함」. 판매 URL·상시가는 시딩도 필수 그대로. **뺀 키는 새로 쓰지 않는다**(빈 문자열로도).
- **선행 의존:** 작업 5
- **완료 정의:** ①새 리뷰어 화면에 8칸 없음(화면 스크롤로 확인) ②새 시딩 화면에 등급·필수 내용·증정품 없음, 배송·NG·추가 안내 있음 ③저장한 `data` 에 뺀 키 없음 ④옛 구조 8칸 그대로 ⑤`findInvalidField` 가 없어진 칸을 요구하지 않음
- **필요 검문소:** `reverb-reviewer` · 브라우저 눈 확인
- **주의·롤백:** 🔴 `loadCategoryOptions()`(764줄) 지우지 않는다(옛 구조가 쓴다) ⚠️ 빈 문자열 키를 보내면 관리자 상세가 줄을 그린다 ⚠️ `findInvalidField`·`renderPreviewCard` 함께. **롤백:** 삭제 조건 제거.

### 작업 7 — 작성 폼: 글자 수 제한
- **담당 파일:** `dev/sales/orient.html`
- **산출 계약:** `LIMIT_REVIEW_GUIDE = 1000` · `LIMIT_SEEDING_APPEAL = 1000`. 세는 기준 = `richValue(node)`(918줄) 결과의 서식 뺀 본문(`osStripHtml` 방식). **「{현재} / 1000」** 표시(포인테일 표기 — 사양서 §1-6). 「예시 넣기」 링크는 마케팅팀 예시 문안이 온 뒤(잠정 ⓛ) — 없으면 안 그린다. 거부 코드 `guide_too_long`·`appeal_too_long` 를 `submitSheet`(1815줄 아래)에서 사람 말로.
- **선행 의존:** 작업 6
- **완료 정의:** ①1,000자 넘겨 붙여넣기 → 잘리고 0 남음 ②임시저장 안 막힘 ③개발자 도구 우회 1,001자 제출 → 서버가 막고 사람 말 안내 ④옛 구조 제한 없음
- **필요 검문소:** `reverb-reviewer` · 브라우저 눈 확인
- **주의·롤백:** ⚠️ 태그 포함해 세지 않는다 ⚠️ 붙여넣기·직접 입력 양쪽. **롤백:** 상수를 크게.

### 작업 8 — 작성 폼: 시딩 예상 일정 안내
- **담당 파일:** `dev/sales/orient.html`
- **산출 계약:** 「모집 마감 예상 {시작+10}~{시작+14} · 배송 5~7일 · 최종 업로드 {시작+25}~{시작+35}」 · 표시 자리 `cgScheduleHint`(모집 시작일 칸 아래) · **시딩 전용** · 시작일 비면 안 그림 · **저장 안 함**
- **선행 의존:** 작업 7
- **완료 정의:** ①시작일 고르면 즉시 계산·변경 추종 ②`data` 에 값 없음 ③리뷰어 화면에 없음 ④시작일 지우면 사라짐
- **필요 검문소:** `reverb-reviewer` · 브라우저 눈 확인
- **주의·롤백:** 🔴 저장하면 「희망일」이 되살아난다 ⚠️ 날짜 계산은 문자열 자르기(`new Date('…')` 금지) ⚠️ 「배송 5~7일」은 고정 문구. **롤백:** 표시 함수 안 부름.

### 작업 9 — 관리자 상세: 빈 값 생략 + 형식·채널 배지
- **담당 파일:** `dev/js/admin-orient.js`
- **산출 계약:** `osField`(967)·`osFieldHtml`(972)·`osFieldRow`(964) 빈 값이면 빈 문자열. `osCardTitle`(1154)/`osTypeChip`(113)에 채널 배지. `osCardsSummary`(120) 「시딩 · 인스타그램-피드」.
- **선행 의존:** 작업 4
- **완료 정의:** ①새 시트 상세에 「—」 없음 ②옛 시트 옛 값 전부 표시 ③카드 머리 형식(+채널) ④**새창 출력**(848줄)도 같음 ⑤목록 열에 채널
- **필요 검문소:** `reverb-reviewer` · 브라우저 눈 확인
- **주의·롤백:** ⚠️ 카드가 통째로 비면 「아직 작성 전입니다」 한 줄 ⚠️ `osField` 는 여러 곳이 쓴다 — 전부 눈으로 ⚠️ 새창 출력의 메모 안 그리는 분기 무변경. **롤백:** 세 함수 빈 값 처리 되돌림.

### 작업 10 — 발행 자동 채움 매핑 변경
- **담당 파일:** `dev/js/admin-orient.js`
- **산출 계약(새 구조 한정, 사양서 §4-4):** 카테고리 비움(`renderCategorySelect('new','')`) · 모집 마감 = 시작+14일(`newCampDeadline`) · 구매 기간·제출 마감 비움 · 캠페인 설명 비움(`newCampDesc`) · `osBuildGuideDraft` **리뷰어면 [NG]·[추가 안내] 생략, 시딩은 그대로** · `osPrefillChannels` 무변경 · **옛 구조 매핑 한 줄도 안 바꿈**
- **선행 의존:** 작업 9
- **완료 정의:** ①새 시딩 발행 → 카테고리·설명 비고 마감 시작+14, 채널 체크 ②새 리뷰어 발행 → 초안에 [NG]·[추가 안내] 없음 ③새 시딩 발행 → 있음 ④**옛 시트 발행** → 예전처럼 채워짐 ⑤캠페인 생성·발행 표시
- **필요 검문소:** `reverb-reviewer` · 브라우저 눈 확인(발행까지)
- **주의·롤백:** 🔴 1653·1654줄을 그냥 지우면 시딩 값까지 사라진다(stale ⑨) 🔴 1648·1649줄(`required_content`·`gift`) 지우지 않는다 🔴 옛 값 읽는 줄을 지우면 발행 23건의 재발행·연결이 깨진다 ⚠️ `osSetVal('newCampProductPrice', 0)`(1708) 무변경. **롤백:** `issued` 분기 제거.

### 작업 11 — (선택) 발급 메일 문구에 형식·채널 안내
- **담당 파일:** `docs/email-templates/orient-sheet-invite.html` + `supabase/functions/notify-orient-sheet/_templates/` 미러 + `index.ts`
- **산출 계약:** `{{form_type_label}}`·`{{channel_label}}`(값 없으면 줄 통째로 비움)
- **선행 의존:** 없음 · **사용자 결정 필요**(사양서에 없는 새 항목)
- **완료 정의:** 원본·미러 글자 단위 동일(`scripts/sync-email-templates.sh`) · 개발 함수 재배포 · 발송 시험은 운영에서만
- **주의·롤백:** ⚠️ 병합 ≠ 메일 반영(함수 별도 배포) ⚠️ 브랜드 한국어 메일이라 4줄 꼬리말 무관. **롤백:** 치환 줄 제거.

### 작업 12 — 1단계 sales 빌드·배포·눈 확인
- **선행 의존:** 작업 5~8 · 작업 1~2 **운영 적용**
- **완료 정의:** ①`sales/orient.html` = `dev/sales/orient.html` ②개발 sales 에서 새 시딩 시트 작성→임시저장→제출 ③옛 시트 카드 2개 제출 ④휴대폰 폭 줄바꿈 ⑤운영 반영 후 한 번 더
- **필요 검문소:** 브라우저 눈 확인 필수 · 사용자 확인(운영 배포)
- **주의·롤백:** 🔴 **배포 순서 데이터베이스 → 관리자 → 작성 폼** ⚠️ `reverb-sales` 는 다른 배포 프로젝트. **롤백:** 이전 커밋 재배포(데이터베이스는 그대로 둬도 옛 폼이 `issued` 를 무시).

### 작업 13 — 마이그레이션 Ⓒ: 견적 기준값 표
- **담당 파일:** `supabase/migrations/{새번호}_quote_settings.sql`
- **산출 계약:** `quote_settings(key text PK, amount numeric NOT NULL, unit text, label_ko text, updated_at, updated_by)` · `quote_settings_history(key, prev_amount, next_amount, actor, at)` · `get_quote_settings()`(`is_admin()`) · `update_quote_setting(p_key, p_amount)`(**`is_campaign_admin()` 이상**) · 접근 정책 조회 `is_admin()`·쓰기 없음 · 초기 9행(`exchange_rate_krw_per_jpy`=10 · `reviewer_transfer_fee_krw`=2500 · `reviewer_recruit_fee_krw`=0 · `seeding_fee_krw_{5채널}`=선-1 값 또는 0 · `vat_rate`=0.10)
- **선행 의존:** 작업 2 **운영 적용**(1단계 완료 뒤)
- **완료 정의:** ①로그인 브라우저에서 `get_quote_settings()` → 9행 ②캠페인 관리자로 `update_quote_setting('vat_rate', 0.1)` 성공 + 이력 1행 ③캠페인 매니저로 거부 ④공개 키 직접 조회 막힘
- **필요 검문소:** `reverb-supabase-expert` → 로그인 브라우저 실호출 → `reverb-reviewer`
- **주의·롤백:** 🔴 신규 함수는 1회 실호출 ⚠️ `numeric`(부가세율) ⚠️ `updated_by` 는 트리거. **롤백:** 두 표·두 함수 `DROP`.

### 작업 14 — 견적 기준값 데이터 접근 함수
- **담당 파일:** `dev/lib/storage.js`
- **산출 계약:** `fetchQuoteSettings()` → **실패 `null`, 0건 `[]`** · `updateQuoteSetting(key, amount)`(`retryWithRefresh`)
- **완료 정의:** 빌드 통과 · 각 1회 호출 · 실패 흉내 시 `null`
- **주의·롤백:** ⚠️ 핫스팟 🔴 `null`/`[]` 구분(합치면 「환율 0」 화면). **롤백:** 함수 제거.

### 작업 15 — 기준 데이터 화면에 「견적 기준값」 탭
- **담당 파일:** `dev/js/admin-lookups.js` + `dev/admin/index.html`
- **산출 계약:** 여덟 번째 종류 탭 `switchLookupTab('quote_settings', …)` · 열: 항목 이름·값·단위·마지막 수정 · 권한 없으면 **읽기 전용**(단추 안 그림) · 저장 후 `refreshPane('lookups')`
- **선행 의존:** 작업 14
- **완료 정의:** ①캠페인 관리자 수정 → 즉시 갱신·새로고침 유지 ②캠페인 매니저에게 수정 단추 안 보임 ③표가 화면을 밀지 않음 ④조회 실패 시 실패 안내
- **필요 검문소:** `reverb-reviewer` · 브라우저 눈 확인(매니저 로그인은 사용자에게 부탁)
- **주의·롤백:** 🔴 카드 추가가 아니라 탭(stale ⑥) ⚠️ 필터 줄은 전용 클래스만 ⚠️ 새 사이드바 항목·권한 열쇠말 없음. **롤백:** 탭 감춤.

### 작업 16 — 마이그레이션 Ⓓ: 제출 함수 ②차(견적 계산)
- **담당 파일:** `supabase/migrations/{새번호}_orient_submit_quote.sql` — 🔴 **베이스 = 작업 2 파일**
- **산출 계약:** `submit_orient_sheet` `CREATE OR REPLACE`. `data.quote` = `{quote_no, revision, issued_at, form_type, channel, basis{…}, lines[{label,qty,unit_krw,amount_krw}], subtotal_krw, vat_krw, total_krw, price_regular_jpy, slots, note}`. 리뷰어 = `상시가×인원×환율 + 인원×송금수수료 + 인원×모집비`, 부가세 **`floor(공급가×vat_rate)`**. 시딩 = `인원×채널 단가`(+제품 제공 0원 줄, 상시가 미사용). 리뷰어 상시가 못 읽으면 제출 통과 + `quote_error='price_unreadable'`. 🔴 세트 규칙: 성공 → 이전 `quote` 를 `quote_history[]` 로, 새 판(`revision`=지난 판 수+1, `quote_no`=`{orient_no}-Q` 고정), `quote_error` 삭제 / 실패 → 이전 `quote` 를 이력으로, `quote` 없애고 `quote_error`. 반환값에 `quote`/`quote_error`.
- **선행 의존:** 작업 13
- **완료 정의:** ①리뷰어 제출 → `quote` 있고 `total_krw` 손계산과 1원까지 같음 ②재제출 → `revision` 2·이력 1·`quote_no` 그대로 ③「3,429엔 (가격소구금지)」 → 숫자만 뽑아 계산 ④「미정」 → 제출 성공·`quote` 없음·`quote_error`·이전 판 이력 ⑤다시 제대로 → `quote` 생기고 `quote_error` 사라짐 ⑥시딩 → 상시가 무관, `price_unreadable` 안 뜸 ⑦옛 시트 → 둘 다 안 생김 ⑧작업 2 검사 4종 여전히 동작
- **필요 검문소:** `reverb-supabase-expert` → 8가지 실호출 → `reverb-reviewer`
- **주의·롤백:** 🔴 베이스를 329 로 잡으면 작업 2 검사가 통째로 사라진다 🔴 보존 먼저, 그 뒤 세트 다시 쓰기 ⚠️ `floor` ⚠️ `basis` 에 읽은 기준값 전부. **롤백:** 작업 2 파일 제출 함수 블록 재실행.

### 작업 17 — 작성 폼: 제출 완료 화면 + 견적서 진입점
- **담당 파일:** `dev/sales/orient.html`
- **산출 계약:** 새 화면 `screenDone`(기존 4화면과 서로 배타) — 제출 성공 직후 진입 · 큰 **「견적서 · PDF 저장」** 단추(`quote` 일 때) / `quote_error` 면 「가격을 숫자로 적으면 견적서를 받을 수 있어요」 · 「내용 수정하기」(→ `screenForm`) · 「제출된 내용은 발행 전까지 수정할 수 있어요」 · 단추 아래 「휴대폰은 「공유 → PDF」로 저장할 수 있어요」 · 「제출 후 흐름: 담당자 확인 → 견적 확정 → 캠페인 발행 → 모집」 한 줄(사양서 §1-6·§4-6). **`submitted` 상태로 재진입(새로고침 포함)하면 완료 화면 먼저**, 작성 화면은 「내용 수정하기」로만. 판별은 `submitSheet()` 반환값 → 새로고침 뒤에는 `boot()` 의 `data.quote`/`quote_error`. **옛 구조 시트는 완료 화면 없이 지금 흐름 그대로.**
- **선행 의존:** 작업 16
- **완료 정의:** ①리뷰어 제출 → 완료 화면·단추 ②새로고침 → 완료 화면 그대로 ③「내용 수정하기」 → 작성 화면, 수정 후 재제출 → 완료 화면 ④`price_unreadable` → 안내, 고쳐 재제출 → 단추 ⑤옛 시트 → 작성 화면 복귀(지금과 같음) ⑥시딩도 단추 ⑦뒤로가기로 작성 화면↔완료 화면이 꼬이지 않음
- **필요 검문소:** `reverb-reviewer` · 브라우저 눈 확인
- **주의·롤백:** 🔴 `quote`·`quote_error` 둘 다 없으면(옛 시트·계산 전) 완료 화면을 그리지 않는다 ⚠️ 화면 5개가 서로 배타로 켜고 꺼지는지(기존 `enterFormScreen` 류 함수에 맞춰) ⚠️ 자동저장 타이머·`dirty` 는 작성 화면에서만 돌게. **롤백:** 제출 후 `enterFormScreen()` 으로 되돌림.

### 작업 18 — 작성 폼: 인쇄용 견적서 화면
- **담당 파일:** `dev/sales/orient.html`
- **산출 계약:** `?token=…&view=quote` — `boot()` 이 `params.get('view')` 로 갈라 바로 띄움 · `screenQuote`(배타) · 내용(사양서 §4-6): 발행처 株式会社ジェイファン 고정 정보 · 수신(브랜드명·담당자) · 견적 번호·판·일자 · 제품명·판매 URL·형식·채널 · 인원 · 줄별 금액 · 공급가·부가세·합계(원) · 엔화 참고 · **형식별 고정 문구**(리뷰어 「…상시가·인원 기준…」 / 시딩 「…모집 인원 기준…」) · 유효기간(작성 기한) · `@media print` · `window.print()` · 외부 라이브러리 없음
- **선행 의존:** 작업 17
- **완료 정의:** ①단추 → 인쇄 대화상자 → PDF 저장 파일에 항목 전부 ②`?view=quote` 직접 진입 동일 ③인쇄 결과에 폼·고정바·토스트 안 섞임 ④원화 자릿수·엔화 참고 ⑤발행된 시트 주소 → 「이미 발행」 안내(기존 오류 화면) ⑥한 페이지·표 안 잘림
- **필요 검문소:** `reverb-reviewer` · 브라우저 + 실제 인쇄 대화상자
- **주의·롤백:** 🔴 견적서 그리는 코드는 여기 한 벌만 🔴 고정 문구 빼지 않는다 ⚠️ 발행되면 `get_orient_sheet` 가 막아 **열리는 구간은 제출 후~발행 전** — 항구적 열람은 작업 19 의 숫자 요약 ⚠️ 크롬·사파리 둘 다. **롤백:** `view=quote` 분기 제거.

### 작업 19 — 관리자 상세: 예상 견적 카드·「견적서 열기」
- **담당 파일:** `dev/js/admin-orient.js`
- **산출 계약:** `data.quote` 있으면 「예상 견적」 카드(금액 요약 + 「판 N」 + `quote_history` 접힘) · `quote_error` 면 「상시가를 숫자로 못 읽어 견적이 없습니다」 + 이력 접힘 · 「견적서 열기」 → `{sales}/orient?token=…&view=quote` 새창(`osSalesBase()`·`osBuildLink()` 규칙) · **토큰 만료·발행이면 단추 안 그림** · 금액 표기 정산·검수 화면 방식
- **선행 의존:** 작업 16
- **완료 정의:** ①요약 카드 숫자 = `data.quote` ②두 번 제출 시트 「판 2」·이력 접힘/펼침 ③새창 인쇄용 화면 ④발행된 시트 단추 없음·카드만 ⑤`quote_error` 한 줄 ⑥새창 출력(`readonly`)에서도 안 깨짐
- **필요 검문소:** `reverb-reviewer` · 브라우저 눈 확인
- **주의·롤백:** ⚠️ 관리자 앱에 견적서 사본 금지 ⚠️ `osCloseModal` 한 자리 분기 무변경 ⚠️ 새 탭이 맞다(다른 앱·다른 도메인). **롤백:** 카드 안 그림.

### 작업 20 — 2단계 배포 + 인쇄 실측
- **선행 의존:** 작업 15·17·18·19, **선-1**
- **완료 정의:** ①운영에 Ⓒ·Ⓓ 적용(순서) ②기준 데이터 탭에서 시딩 단가 5종 실제 값 입력 ③운영 시딩 시트 제출 → PDF 저장, 금액 손계산과 일치 ④리뷰어도 ⑤관리자 상세 같은 금액
- **필요 검문소:** 사용자 확인(운영 배포) · 브라우저 · `reverb-qa-tester`(선택, 브라우저 비어 있을 때)
- **주의·롤백:** 🔴 단가 0인 채 나가면 0원 견적서가 브랜드에게 간다 🔴 함수 적용 확인 뒤 화면 배포(정산 3단계의 15시간 사고). **롤백:** 화면만 되돌림(견적은 쌓이되 안 보임).

### 작업 21 — 3단계 0) 개발서버 읽기 검증
- **담당 파일:** `supabase/functions/qoo10-product-lookup/index.ts`(검증용 최소판, 개발만)
- **선행 의존:** **선-2**
- **완료 정의:** ①개발 Edge Function 에서 큐텐 상품 3개의 `schema.org/Product` 수신 ②3개 모두 상품명·상품번호·스토어명·**판매가**(정가·행사가와 구분) 추출 ③**실패면 22·23 「보류」 기록 후 3단계 종료** — 결과를 사양서 「구현 결과」에
- **주의·롤백:** 🔴 실패도 정상 결과 — 봇 판별 우회를 늘리지 않는다 🔴 `offers.price` 는 **행사가** ⚠️ 크롬과 같은 요청 모양(HTTP/2 + 머리말)이 Deno 에서 되는지가 전부. **롤백:** 개발 함수 삭제.

### 작업 22 — Edge Function `qoo10-product-lookup`
- **산출 계약:** 입력 `{token, url}` → 성공 `{ok:true, goods_code, product_name, store_name, price_sale_jpy, price_list_jpy, image_url}` / 실패 전부 `{ok:false}`(이유는 로그만). 관문 ①`orient_token_can_upload(token)` ②호스트 `qoo10.jp` 계열 + `/g/{n}`·`goodscode={n}` ③토큰당 분당 5회. **교차 출처 헤더 + OPTIONS 분기**(stale ⑧).
- **선행 의존:** 작업 21 성공
- **완료 정의:** ①**작성 폼 도메인 브라우저 콘솔에서** 호출 성공 ②OPTIONS 허용 헤더 ③죽은 토큰 `{ok:false}` ④비큐텐 주소 `{ok:false}` ⑤6번째 연속 호출 `{ok:false}` ⑥큐텐 불통 시 `{ok:false}`·오류 안 던짐
- **필요 검문소:** `reverb-supabase-expert` · `reverb-reviewer` · 브라우저 실호출
- **주의·롤백:** 🔴 교차 출처 헤더 없으면 한 번도 성공 못 한다(`notify-orient-sheet` 전례) 🔴 토큰·호스트·횟수 셋이 한 세트 ⚠️ 실패 사유를 응답에 담지 않는다. **롤백:** 함수 삭제(폼은 조용히 넘어감).

### 작업 23 — 작성 폼: 판매 URL 자동 채움 연결
- **담당 파일:** `dev/sales/orient.html`
- **산출 계약:** `onSaleUrlBlur()` → 호출 → **빈 칸만**(제품명·상시가=판매가) 채움, 값 있으면 「불러온 값으로 바꾸기」 링크 · 「큐텐에서 불러왔어요 · 확인해 주세요」 · 저장 `sale.goods_code`·`sale.store_name`·`sale.image_url`·`sale.price_list` · 실패 「자동으로 못 불러왔어요. 직접 입력해 주세요」
- **선행 의존:** 작업 22
- **완료 정의:** ①큐텐 주소 → 채움·안내 ②값 있으면 안 덮고 링크 ③비큐텐 주소 → 아무 일 없음 ④함수 꺼도 폼 완전 동작 ⑤`data` 에 4키 저장
- **필요 검문소:** `reverb-reviewer` · 브라우저 · 사용자 확인(운영)
- **주의·롤백:** 🔴 「자동 입력」 약속 문구 금지 ⚠️ 사람이 고친 값을 덮으면 가장 나쁜 실패 ⚠️ 기다리는 표시 + 시간 지나면 조용히 포기. **롤백:** `onSaleUrlBlur` 안 부름.

---

## ⚠️ 공유 지점 경고 (충돌 주의)

### 🔴 한 파일을 여러 조각이 만진다 — 병렬 금지

| 파일 | 만지는 조각 | 판단 |
|---|---|---|
| **`dev/sales/orient.html`** | 5·6·7·8 · 17·18 · 23 — 7개 | 🔴 병렬 금지. 한 세션이 순서대로(자립형 단독 화면이라 함수가 전부 한 파일) |
| **`dev/js/admin-orient.js`** | 4·9·10 · 19 — 4개 | 🔴 이 사양 안에서는 병렬 금지. 저장소 핫스팟 목록은 아니라 **다른 페인 작업과는 병렬 가능** |
| **`dev/lib/storage.js`** | 3 · 14 | 🔴 저장소 공식 핫스팟. 같은 시각 금지 + 사양 밖 작업이 만지는 중이면 대기 |
| **`supabase/migrations/`** | 1·2 · 13·16 | 🔴 한 세션만. 다른 세션 마이그레이션 병합 뒤 다음 번호 |

### 🔴 같은 사실이 여러 곳에 — 함께 고칠 자리

| 사실 | 사는 곳 | 어긋나면 |
|---|---|---|
| 시딩 채널 5종 | ①`orient.html:640` `SEEDING_CHANNELS` ②`admin-orient.js` `OS_SEEDING_CHANNELS`(작업 4) ③Ⓐ 서버 검증 | 관리자가 서버가 거부할 값을 고르거나, 폼이 지정값을 못 그림 |
| 형식(리뷰어/시딩) | ①`data.issued.form_type`(원본) ②`cards[0].form_type` ③`orient_sheets.form_type` | 사본이 갈리면 화면·발행·목록이 다른 형식. **작업 2 의 덮어쓰기가 유일한 보증** |
| 글자 수 1,000 | ①폼(작업 7) ②제출 함수(작업 2) | 폼만이면 우회, 서버만이면 다 쓴 뒤 거부 |
| 부가세·환율 | ①`quote_settings` ②`dev/sales/reviewer.html` 상수 ③트리거 111 | 알고 남긴 어긋남(§8-⑩). 반올림(`floor`)만은 맞춘다 |
| 「견적서 · PDF 저장」 이름 | ①폼 단추(17) ②관리자 「견적서 열기」(19) ③문서 제목(18) | 화면마다 다른 이름 |
| 가이드 초안 블록 | `osBuildGuideDraft` 1640~1654 — 공통 2블록(`cautions`·`ng`) | 형식으로 안 가르면 시딩 값 소실(stale ⑨) |
| 메일 양식 | `docs/email-templates/` 원본 + `_templates/` 미러 | 한쪽만 고치면 옛 문구 발송. `scripts/sync-email-templates.sh` |

### ⚠️ 손대지 않기로 한 것

- `dev/sales/reviewer.html`·`seeding.html` 과 트리거 111(§5·§8-⑩)
- `osSetVal('newCampProductPrice', 0)`(admin-orient.js 1708) — 2026-08-11 결정
- 카드 고유 번호 규칙(293·329) — 작업 2·16 이 재정의하되 그 부분은 글자 그대로
- 메모(297·298)·연결/해제(237·238)·삭제(199·239·328)·제출 알림(202·234)·업로드 정책(200)·`get_orient_sheet`(187)
- `storage.js` 의 죽은 감싸개 두 개 — 주석만

---

## 🧭 배분 제안

### 1단계 — 세 트랙 동시, 검증은 순서대로

| 트랙 | 조각 | 세션 |
|---|---|---|
| **A · 데이터베이스** | 1 → 2 | 개발 1(마이그레이션 전담 — 다른 마이그레이션 작업과 안 겹칠 때만) |
| **B · 작성 폼** | 5 → 6 → 7 → 8 → 12 | 개발 2(`dev/sales/orient.html` 전담) |
| **C · 관리자** | 3 → 4 → 9 → 10 | 개발 3(`admin-orient.js` + `storage.js` 전담) |
| **D · 선택** | 11 | 아무 세션 또는 보류 |

- 트랙 B·C 는 파일이 안 겹쳐 병렬 가능. 다만 **둘 다 트랙 A 가 개발 데이터베이스에 적용된 뒤에야 검증**할 수 있다.
- 🔴 **배포는 반드시 A → C → B 순.**
- 세션이 하나뿐이면 **1 → 2 → 3 → 4 → 9 → 10 → 5 → 6 → 7 → 8 → 12** 한 줄로(관리자 쪽이 먼저여야 새 구조 시트를 만들어 폼을 시험할 수 있다).

### 2단계 — 트랙 두 개

| 트랙 | 조각 |
|---|---|
| **A · 데이터베이스 + 관리자** | 13 → 14 → 15, 그리고 16 → 19 |
| **B · 작성 폼** | 17 → 18 |

- 15(`admin-lookups.js`)와 19(`admin-orient.js`)는 다른 파일이라 병렬 가능. 17·18 은 16 개발 적용 뒤 검증. 20 은 **선-1 값을 받은 뒤**.

### 3단계 — 한 줄, 멈출 수 있게

21 → 22 → 23 을 한 세션이 순서대로. **21 실패 = 「보류」 기록으로 종료가 정상 결과.**

### 지금 필요한 것

**1단계는 바로 착수 가능**(선결 조건 없음). 2단계 배포 전 **선-1(시딩 채널별 1인 단가 5종)**, 3단계 전 **선-2(큐텐 약관 위험)**, 그리고 작업 11(메일 문구)을 할지 말지.

---

## 관련 파일 (절대경로)

- 사양서: `/Users/younggeunkim/Documents/projects/reverb-jp/docs/specs/2026-09-08-orient-sheet-simplify-and-quote.md`
- 작성 폼: `dev/sales/orient.html` · 관리자 오리엔 화면: `dev/js/admin-orient.js` · 기준 데이터 화면: `dev/js/admin-lookups.js` + `dev/admin/index.html`(2699줄~) · 데이터 접근 함수: `dev/lib/storage.js`(4973·5002·5037줄)
- 베이스 마이그레이션: `supabase/migrations/205_orient_self_numbering.sql`(192·343줄) · `supabase/migrations/329_orient_sheet_return_card_uids.sql`(220·344줄)
- 견적 계산 선례: `dev/sales/reviewer.html`(1479·1480·1759줄) · `supabase/migrations/111_recalc_with_recruit_fee.sql`(104~106줄)
- 발급 메일 양식: `docs/email-templates/orient-sheet-invite.html` + `supabase/functions/notify-orient-sheet/_templates/orient-sheet-invite.html`
- 빌드: `dev/build.sh`(139~153줄 — sales 복사)
