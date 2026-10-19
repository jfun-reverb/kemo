# 📋 작업 분해표 — 브랜드 페이지 1차 「오리엔시트」 메뉴(04)

**사양서:** `docs/specs/2026-07-15-brand-portal.md` §4 「현재 단계 정의」(브랜드 페이지 1차 줄) · §9(단계 줄 — 1차는 운영팀이 발급한 시트만) · §13-1(현재 상태·결함 후보) · §13-4 ⑦(견적 1차 상태 이름) · §15 화면 코드 표 「1차 04 오리엔시트」 줄 · §16-4 「오리엔시트 작성 경로」(693줄) · 16-5 8번(계정 없는 브랜드 발급 경고) · 9번(발급 메일 받는 사람) · §17 표 3차 ①-5(견적 계산 예외 경로 — 1차에 포함)
**정본 화면:** 피그마 「[1차] 04 오리엔시트」 — bw04-00 · 00a · 00b · 00c · 00d · 00e · bm04-00 · bw04-01 · 01a · 01b · 01c · 01e · 01f · 01g · bm04-01 · bw04-02 · 03 · 04 · 04a · 05 · 05a · 05b · 13 · 90 · 91 · 92 · bw04-96(발급 메일) · a04-95(제출 알림 메일) + 흐름도. 옛 링크 안내는 「[1차] 01」의 bw01-09
**양식:** 직전 작업표 `docs/specs/2026-10-16-brand-info-page-breakdown.md` 를 따른다
**분해일:** 2026-10-16
**범위:** 브랜드 화면(`dev/brand/`) 오리엔시트 목록·작성 모달 + 그 화면용 데이터베이스 함수 + 큐텐(Qoo10) 불러오기·파일 업로드 관문 + 옛 작성 링크 폼 닫기 + (결정 17에 따라) 관리자 발급 쪽(받는 사람·경고·메일)
**총 작업 조각:** 11개 · **동시에 할 수 있는 것:** 조각 10(관리자 발급)은 조각 5~8 과 동시에 · **나머지는 순서대로**(데이터베이스 조각 1~4 는 한 세션·순서대로 — 그래프에서 4 와 5 가 갈라진 것은 「5 가 4 의 산출물을 안 쓴다」는 뜻일 뿐, 한 사람이면 4 → 5)

> **화면 문구:** 한국어(`dev/brand/index.html` 이 `lang="ko"`), 문체 「~습니다 / ~십시오」. 화면 문구·모양의 정본은 피그마. 일본어 문구 없음.
> 🔴 **개발서버에서만 돈다:** 브랜드 화면은 `brandDb`(운영 주소에서는 `null`)로만 서버를 부른다. 데이터베이스 조각은 526~536(535 는 2026-10-16 따로 먼저 적용됨 — 제외)과 같은 줄에 서서 운영 반영을 보류한다(운영 배포는 브랜드 페이지 전체가 끝난 뒤 한꺼번에 — 2026-10-16 사용자 결정). ⚠️ **예외 셋** — ①조각 1(기한 결함 수정)은 결정 14 에 따라 운영에 먼저 따로 간다 ②관리자 화면 코드(조각 10)는 다음 운영 배포에 함께 나가므로 `_brandAccountEnabled()` 판정 아래에 둔다 · 같은 이유로 조각 9 의 `orient.html` 이동 갈래도 운영 주소에서는 돌지 않게 막는다 ③서버 함수(Edge Function)는 프로젝트마다 손으로 배포한다 — 조각 10 은 운영에 먼저 배포되는 사고를 스위치로 막고, 조각 4 는 새 갈래만 더해 옛 갈래를 안 건드리므로 운영에 먼저 나가도 해가 없다. 조각 9 는 서버 함수를 고치지 않는다(토큰 갈래는 닫기 마이그레이션이 데이터베이스 관문에서 막는다).
> **마이그레이션 번호:** 미리 정하지 않는다. 작성 시점 마지막 번호는 **537**(다른 세션이 동시에 만든다 — 만들기 직전 `origin/dev`·열린 병합 요청까지 보고 확정).

---

## 현재 상태 (2026-10-16 코드로 확인)

| 항목 | 실제 |
|---|---|
| 「오리엔시트」 메뉴 | `brand-shell.js` `BRAND_MENU` 에 `orient`(아이콘 `assignment_turned_in`), `BRAND_FIRST_PAGE = 'orient'`(로그인 뒤 첫 페이지). 35줄 `registerBrandPage('orient', _brandComingSoon('오리엔시트'))` 로 「준비 중입니다」. 등록부는 `_brandPages[hash] = def` 라 뒤에 실리는 파일이 다시 등록하면 바뀐다 |
| 페이지 주소 | `routeBrand`(brand-app.js)는 `isBrandShellPage(hash)` **정확히 같은 해시만** 페이지로 본다. 시트 하나를 가리키는 주소(`#orient/…` 등)가 없다. `enterBrandApp` 은 로그인 직후 늘 첫 페이지로 간다 — **로그인 뒤 특정 시트로 가는 장치가 없다** |
| 브랜드 바꾸기 | `switchBrand`(brand-shell.js)에 **바꾸기 전 확인을 끼울 자리가 없다**(bw04-13 이 필요로 한다). 메뉴 이동·로그아웃도 같다 |
| 작성 폼 | `dev/sales/orient.html` 한 파일(함수 150개). 서버 호출 일곱(함수 다섯 + 큐텐 서버 함수 + 업로드)이 모두 링크 열쇠(토큰) — `get_orient_sheet`·`get_orient_tier_fees`·`save_orient_draft`·`preview_orient_quote`·`submit_orient_sheet`(1393·1072·2817·3030·3232줄) + 큐텐 서버 함수(2115줄) + 업로드(2336줄, `orient-images/{토큰}/…`). 이 기기 사본 열쇠 `reverb.orient.{토큰}`(894줄). 배포는 별도 Vercel 프로젝트(`reverb-sales`, `build.sh` 가 `dev/sales/*.html` 을 `sales/` 로 복사) — **병합 ≠ 페이지 반영** |
| 서버 함수 원본 | `get_orient_sheet`·`save_orient_draft`·`submit_orient_sheet` = **524** · `preview_orient_quote` = **430**(재정의 없음) · `get_orient_tier_fees` = **489** · `_orient_compute_quote` = **463** · `_orient_apply_issued_rules` = **445** |
| 실행 권한 | `get_orient_sheet` = 비로그인·로그인 둘 다 / `save_orient_draft`·`submit_orient_sheet` = **비로그인(`anon`)만** / `preview_orient_quote` = 둘 다. 그대로는 로그인 계정 기준이 아니다 |
| 🔴 기한 결함(실제) | 524 `save_orient_draft`(164~171줄)·`submit_orient_sheet`(316~323줄)가 기한을 **상태보다 먼저** 보고 `status NOT IN ('expired','consumed')` 면 `expired` 로 바꾼다 → **이미 제출된 시트도 `expired`** 가 되고, 196 `mark_orient_card_consumed`(125줄 `status <> 'submitted'` 거부)·464 `link_orient_card_to_campaign`(65줄)이 캠페인 등록을 거부한다. 사양서 13-1 은 「코드 추론, 재현 안 함」이라 적었지만 코드로 확정된다. 관리자 목록 `osIsExpired`(admin-orient.js 79줄)는 `submitted` 를 만료로 안 보지만, 서버가 상태를 바꾼 뒤에는 `expired` 로 보인다 |
| 3차 ①-5 | 524 제출 함수의 견적 계산 예외 갈래(433~440줄)가 `quote` 를 지우기만 하고 **직전 견적을 이력(`quote_history`)으로 옮기지 않는다** |
| 발행 표시 | 카드 단위(`data.cards[].campaign_id`·`linked_existing`), 전 카드 등록되면 `status='consumed'`. 196·464 둘 다 **`version` +1** — 브랜드가 쓰는 도중 관리자가 등록하면 브랜드 쪽 자동 저장이 「충돌」로 거부된다 |
| 조회 함수의 등록 시트 | `get_orient_sheet` 는 `consumed` 면 내용 없이 실패(66~72줄) → **bw04-01c(등록된 시트 읽기 전용 + 견적서)는 지금 함수로 못 그린다** |
| 기한 뒤 조회 | `get_orient_sheet` 는 기한이 지나면 상태와 무관하게 `expired`(77~85줄) — 견적 1차 「기한 뒤 견적서 못 봄」(13-4 ⑦)과 일치 |
| 누가 저장했나 | `orient_sheets` 에 **저장한 사람 칸이 없다**. 시각도 `draft_saved_at`(제출 뒤 작성본만)뿐 — 작성 중(draft) 시트의 마지막 저장 시각 칸이 없다. `updated_at` 은 관리자 동작·메일 기록(`mail_sent_at`)·알림 기록(`last_notified_at`)에도 오른다 → 「최근 수정」으로 못 쓴다 |
| 제출 시각 | `submitted_at`(처음·불변) · `last_submitted_at`(매 제출, 202) 따로 |
| 업로드 허가 | 200 의 넣기 정책 `orient_images_anon_insert` 가 **`TO anon` 만**(235~238줄) — 로그인한 브랜드 계정은 지금 정책으로 못 올린다. 허가 함수 `orient_token_can_upload(text)` 는 폴더 이름(=토큰)으로 판정. 472 가 통 목록 조회를 관리자만으로 좁힘 |
| 큐텐 관문 | `orient_lookup_gate(text)`(428, 서비스 키 전용)가 ①살아 있는 토큰 ③토큰당 분당 5회(`orient_lookup_hits.token uuid NOT NULL`). 서버 함수 `qoo10-product-lookup` 은 본문 `{token, url}` 을 받는다(교차 출처 허용 헤더에 `authorization` 이미 있음) |
| 브랜드 쪽 공용 부품 | `brandRpc`(토큰 만료면 한 번 갱신) · `brandCallFunction(name, payload, {auth:true})`(로그인 토큰 실음, 2xx 아니어도 본문 읽음) · `brandToast`·`brandConfirm`·`brandEsc`·`brandFormatDate(Time)` · `brandTouchActivity` · `onBrandChanged` · `handleBrandNotLinked` · `refreshBrandLoginState` · `getCurrentBrandId`·`switchBrand` |
| 역할 판정 | `my_brand_role`·`is_my_brand`(530, 보안 정의자, `authenticated` 만) — 활성 연결 + 활성 브랜드만. 대표·멤버 구분 없이 오리엔시트를 똑같이 쓴다(16-2) |
| 견적서 그리기 | `orient.html` 한 벌. 관리자는 `?embed=quote` 를 끼워 넣은 창(iframe)에 띄우고 postMessage 로 견적을 넘긴다(`bootEmbedQuote` 1362줄). 받는 출처 `embedAllowedOrigins`(1356줄) = 운영 `globalreverb.com`·`www`, 개발 `dev.globalreverb.com`(+로컬 같은 출처) — **브랜드 페이지 주소가 이미 들어 있다**. 인쇄는 새 탭(`window.open`, `noopener` 금지 — 관리자 `osPrintQuoteDoc` 선례) |
| 브랜드 페이지 빌드 | `dev/build.sh` 208줄 `BRAND_JS_FILES`(supabase → core → login → invite → shell → info → members → mypage → app) + `dev/brand/index.html` 원본 태그(458~465줄). **DOMPurify 를 싣지 않는다**(작성 폼의 서식 칸 셋이 필요 — `orient.html` 은 `dompurify@3.1.6`) |
| 발급 메일 | `notify-orient-sheet`: 받는 사람 = 화면이 넘긴 `to_email` 우선 → 서베이 연결이면 신청서 이메일 → 아니면 담당자 목록 대표 줄. 링크 = `PUBLIC_SALES_URL/orient?token=`. 기록 `mail_sent_at`·`mail_sent_to`(한 값). 화면 쪽 `osSendInviteAndShow`(admin-orient.js 711줄)·`sendOrientInviteMail(id, recipient)`(storage.js 6060줄) |
| 작성 링크를 만드는 자리 | `osBuildLink(token)` — `admin-orient.js` 352·365·579줄, `admin-brand.js` 1014·3167줄(다섯 곳) |
| 관리자 계정 상태 판정 | `_brandAccountEnabled()`(storage.js 3179줄, `IS_STAGING`) · `admin_get_brand_account_status`(533, storage.js 3229줄) |
| 개발서버 시딩 단가 | 아직 가짜 값(`99001~99025`) — 그 환경의 시딩 시트는 브랜드에게 내보내지 않는다 |

### 낱말·이름 전파 점검
찾은 방법: `get_orient_sheet|save_orient_draft|submit_orient_sheet|preview_orient_quote|get_orient_tier_fees|qoo10-product-lookup|orient-images` 를 `dev/`·`sales/`·`supabase/functions/` 에서 / `osBuildLink|osSalesBase` 를 `dev/js/` 에서 / 메일 양식 `orient-sheet-invite.html` 의 `{{…}}`·「링크」·「기한」 / 관리자 상태 이름 `OS_STATUS`.

**① 바뀌는 「이름」 — 브랜드 화면의 상태 이름(결정 1)**

| 자리 | 지금 | 이번 처리 |
|---|---|---|
| 브랜드 목록·카드·모바일 상태 표시 | 없음(새로 생김) | 서버가 준 판정 값 하나를 이름표 하나로(조각 5) |
| 관리자 목록 `OS_STATUS`·`OS_STATUS_TABS` | 작성 중·제출됨·**발행됨**·만료 + 「일부 발행 (n/m)」·「브랜드 수정 중 · 미제출」 | **바꾸지 않는다**(관리자 말은 「발행」, 브랜드 말은 「캠페인 등록」 — 사양서 13-3 5번이 일부러 가름). 두 말이 같은 상태를 가리킨다는 것만 문서에 적는다. ⚠️ 예외 — 피그마 브랜드 화면 문구 두 곳이 「발행」을 쓴다(bw04-01c 진행 단계 「캠페인 발행」 · bw04-05 토스트 「발행 전까지 수정할 수 있습니다.」). 문구 정본은 피그마라 그대로 옮기고 「기획에게 넘길 것」 10 으로 넘긴다 |
| 메일(발급·제출 알림·브랜드 일일 보고) | 상태 이름 안 씀 | 해당 없음 |
| 자주 묻는 질문·엑셀 | 브랜드 오리엔시트 상태 0 | 해당 없음 |

**② 바뀌는 「이름」 — 「작성 링크」**(링크 폼을 닫으면 사라지는 말)

| 자리 | 지금 | 이번 처리 |
|---|---|---|
| 메일 양식 `docs/email-templates/orient-sheet-invite.html` | 「별도 로그인 없이 바로 작성」·「작성 링크」·`{{link}}`=토큰 주소·호칭 「{{brand_name}} 담당자님」 | 새 양식(bw04-96)으로 — 조각 10 |
| 관리자 「링크 복사」 토스트 「작성 링크가 복사되었습니다.」·발급 모달 링크 칸 | 토큰 주소 | 계정 판정이 켜진 환경에서 브랜드 페이지 주소로 — 조각 10 |
| `admin-brand.js` 1014·3167 의 링크 | 토큰 주소 | 같은 처리 — 조각 10 |

**③ 함수 이름 세 형태**(그대로 적힌 것 / 변수로 넘기는 것 / 조회문 안쪽)

| 이름 | 부르는 자리 | 이번 처리 |
|---|---|---|
| 토큰 함수 다섯(조회·저장·제출·미리보기·구간) | `dev/sales/orient.html`(원본) · `sales/orient.html`(사본) · **`dev/lib/storage.js` 5839·5869·5899줄**(`get/save/submit` 감싸개 — 화면에서 부르는 곳은 확인 필요, 0곳이면 죽은 코드) | 조각 1 이 둘(저장·제출) · 조각 2 가 넷(조회 제외 — 본체를 나누되 동작은 같게) · 조각 9 가 다섯 모두 닫는다. 🔴 닫기 전 storage.js 세 감싸개를 부르는 자리 0곳 확인 |
| `orient-images` 통 | `orient.html` 업로드 · 200·472 정책 · 관리자 파일 보기 | 로그인 업로드 정책을 **더한다**(조각 4), 옛 정책은 조각 9 에서 닫는다 |
| `qoo10-product-lookup` | `orient.html` | 같은 함수에 로그인 갈래를 더한다(조각 4) |
| 자립형 단독 화면(`event-scan.html`·`admin-setpw.html`) | 오리엔시트 이름 0 | 해당 없음 |

---

## 의심·경우의 수 (반대론자)

1. **(데이터·운영) 🔴 제출된 시트가 기한 뒤 저장 한 번으로 「만료」가 되어 캠페인 등록이 막힌다** — 위 결함. 지금 운영 링크 폼에서도 일어난다(브랜드가 기한 전에 열어 둔 창에서 기한 뒤 자동 저장이 한 번만 돌아도). → 조각 1. 운영에 이미 그렇게 바뀐 행이 있는지 S4 로 센다.
2. **(사용 흐름) 계정 없는 브랜드에 발급하면 메일이 안 나가고, 서베이 신청 상태 자동 전진(`orient_sheet_sent`)도 멈춘다** — 지금은 「메일 발송 성공 + 연결 신청」일 때만 전진한다. 받을 계정이 0명이면 운영팀이 신청 목록에서 상태를 손으로 옮겨야 한다. → 조각 10 의 경고 문구에 함께 적을지 기획 확인(「기획에게 넘길 것」 6).
3. **(사용 흐름) 링크 폼을 닫는 날 옛 링크로 쓰던 사람의 「이 기기 사본」(`reverb.orient.{토큰}`)은 브랜드 페이지로 못 옮긴다** — 다른 주소(sales 도메인)의 저장소라 읽을 수 없다. 서버에 저장된 내용은 그대로이므로 잃는 것은 「저장 실패 직후의 사본」뿐. 막지 않는다.
4. **(기술) 작성 폼 코드가 한동안 두 벌이 된다** — 브랜드 모달(조각 6)은 `orient.html` 새 구조 폼을 옮겨 온다(개발 기본값 1). 옛 폼 작성 코드를 출시 확인 뒤 별도로 정리할 때까지(조각 9 는 진입만 막고 코드는 지우지 않는다) **`orient.html` 작성 부분을 고치면 두 곳을 함께** 고쳐야 한다. 사본이 늘어나는 목록: 시딩 채널 5종(3곳 → 4곳) · 긴 글 칸 1,000자 검사(폼 `LONG_TEXT_FIELDS`·카운터·서버 = 「세 곳 한 세트」 → 넷) · 구간 기본 이름(서버·폼 `TIER_OPTIONS`·관리자 3곳 → 4곳) · 옵션 기본값(폼 1곳 → 2곳) · 이미지 압축(긴 변 2048).
5. **(권한) 로그인 업로드가 지금 정책으로는 막힌다** — 넣기 정책이 `anon` 만. 그리고 폴더 이름이 곧 토큰이던 구조를 그대로 쓰면 브랜드 화면이 토큰을 알아야 한다 → 폴더를 「시트 번호」 기준으로 새로 둔다(조각 4). 시트 번호는 비밀이 아니지만 허가 함수가 「그 계정이 그 시트 브랜드에 연결됐는가」를 다시 본다.
6. **(사용 흐름) 동시 작성 표시가 엉뚱한 사람을 가리킬 수 있다** — 운영팀이 캠페인을 등록하면(196·464) `version` 이 올라 브랜드 쪽 저장이 「다른 곳에서 먼저 수정되었습니다」로 거부되는데, 마지막 저장자는 브랜드 사람이라 「김멤버님이 수정했습니다」처럼 보인다. → 충돌 뒤 다시 불러오면 `consumed`/일부 등록이 드러나 bw04-01c 로 간다. 마지막 저장자 표시는 「저장한 사람」이지 「버전을 올린 사람」이 아니라고 문서에 적는다.
7. **(사용 흐름) 저장 안 된 입력이 브랜드 바꾸기·메뉴 이동·로그아웃·모달 닫기로 조용히 사라진다** — 공용 틀에 「떠나기 전 확인」 장치가 없다. → 조각 6 이 `brand-shell.js` 에 확인 장치를 하나 두고 넷이 모두 거친다(bw04-13·결정 10).
8. **(기술·보안) 큐텐 계정 단위 횟수는 서버 함수가 로그인 토큰을 직접 검증해야 한다** — 본문에 실린 계정 번호를 믿으면 남의 계정 횟수를 태울 수 있고, 공개 키로 부른 호출도 통과한다(`supabase.md` 「공개 키가 인증을 통과한다」). → 함수가 `Authorization` 의 로그인 토큰으로 사용자를 꺼내 관문에 넘긴다.
9. **(운영·배포) 관리자 화면 코드는 다음 운영 배포에 함께 나간다** — 「받는 사람 고르는 칸」을 출시 전에 운영에서 없애면 운영 발급 메일이 끊긴다(운영엔 계정이 없다). → `_brandAccountEnabled()` 아래(조각 10).
10. **(운영·배포) 🔴 새 받는 사람 규칙의 `notify-orient-sheet` 가 운영에 먼저 배포되면 운영 발급 메일이 전부 「받는 사람 없음」** — 서버 함수는 프로젝트마다 손으로 배포한다. 다른 이유로 운영에 배포하는 순간 새 규칙이 켜진다. → 개발서버에만 넣는 스위치(조각 10).
11. **(법률·약관) 「누가 저장·제출했나」를 남기는 것은 브랜드 담당자의 활동 기록이다** — 16-5 2번(해제된 멤버 개인정보 보관 기간)과 같은 판단 대상. → 이름 사본을 남기지 않는 쪽을 추천(결정 2) + 출시 관문 `/약관확인` 에 넣는다(S6).
12. **(사용 흐름) 견적 1차 시트는 기한 뒤 「만료」로 보인다 — 제출한 브랜드가 「제출이 무효가 됐나」로 읽을 수 있다** — 13-4 ⑦ 결정(기한 뒤 견적서 못 봄)은 그대로 두되, bw04-01b 안내 문구에 「이미 제출하신 내용은 담당자에게 전달되어 있습니다」를 넣을지(「기획에게 넘길 것」 5).
13. **(기술) 견적서는 sales 도메인 화면을 끼워 쓴다** — 링크 폼을 닫을 때 끼워 넣기 모드까지 지우면 관리자·브랜드 견적서가 함께 죽는다(16-4 ④). 조각 9 는 `?token=` 진입만 바꾼다.
14. **(사용 흐름) 메일 링크의 시트가 지금 고른 브랜드가 아닐 수 있다** — 한 계정이 브랜드 여럿에 연결된 경우. → 서버가 시트의 브랜드를 돌려주고 화면이 그 브랜드로 바꾼 뒤 연다(조각 5). 연결이 없으면 「볼 수 없는 오리엔시트」 토스트 + 목록.

**현재 구현과 충돌하는 지점:** ①`brand-shell.js` 35줄 「준비 중」 등록 ②`routeBrand`·`enterBrandApp` 이 시트 하나로 가는 길을 모른다 ③`switchBrand` 에 확인 장치가 없다 ④토큰 함수의 실행 권한(`anon` 만)·업로드 정책(`anon` 만)·큐텐 관문(토큰만) ⑤524 기한 결함 ⑥`get_orient_sheet` 가 등록 시트 내용을 안 준다(bw04-01c) ⑦`notify-orient-sheet` 의 「화면이 넘긴 주소 우선」 갈래·한 값 기록 ⑧사양서 13-1 「제출 함수 현재 원본 461」(→ 524).

**사용자 의도 모호점**(✅ 2026-10-16 결정 1·3·4 로 해결): 「캠페인 등록됨」이 일부 카드만 등록된 옛 구조 시트를 포함하는가(결정 4) · 「만료」 탭에 제출 뒤 기한 지난 시트가 드는가(결정 1·3) · 「신규」가 탭인가 배지인가(결정 1).

---

## ✅ 결정 표 (2026-10-16 사용자 결정 — 17개 모두 개발 추천값대로)

| # | 무엇 | 개발 추천값 | 근거 | 사용자 결정 | 영향 조각 |
|---|---|---|---|---|---|
| 1 | 목록 상태 이름·탭과 판정식 | 탭 = 전체 · 작성 중 · 제출됨 · 캠페인 등록됨 · 만료(피그마 bw04-00). 「신규」는 탭이 아니라 **「작성 중」 탭 안의 배지**(아직 아무도 저장 안 한 시트). 판정은 **서버 한 곳**(`_orient_brand_view_status`)이 `new / editing / submitted / registered / expired` 하나를 정하고 리스트·카드·모바일·상세가 그 값만 쓴다. 우선순위 = 등록된 카드가 있으면(새 구조는 전 카드, 옛 구조는 일부 포함 — 결정 4) → 캠페인 등록됨 · 기한 지남 → 만료(제출된 시트도 — 13-4 ⑦) · 제출됨 · 작성 중(저장 기록 없으면 신규) | 기한 비교를 서버 시각으로(bw04-01b) · 사본 금지(bw04-00a) · 13-4 ⑦ 견적 1차 이름 | 추천값대로(2026-10-16 사용자) | 2·3·5 |
| 2 | 「최근 수정」에 사람 이름 | **보인다.** 새 칸 둘 — `last_edited_at`(브랜드가 저장·제출한 시각) · `last_edited_by`(계정 번호). **이름은 사본으로 남기지 않고** 읽을 때 계정 표에서 찾는다(못 찾으면 시각만) | 「○○님이 3분 전에」(bw04-01e, 2026-10-14 결정)가 같은 칸을 쓴다 · 이름 사본은 16-5 2번 보관 기간 문제를 만든다 | 추천값대로(2026-10-16 사용자) | 2·3·5·6 |
| 3 | 기한 지난 시트를 목록에 둘까 | **둔다**(「만료」 탭, 회색 줄). 누르면 bw04-01b. 단 **캠페인이 등록된 시트는 기한 뒤에도 「캠페인 등록됨」**으로 두고, 열면 bw04-01c 를 **견적서 없이**(진행 단계·「캠페인 보기」만) | 피그마 그림 그대로 · 등록된 시트를 「만료」로 보이면 진행 중 캠페인이 죽은 것처럼 읽힌다 · 견적서 비노출은 13-4 ⑦ 유지 | 추천값대로(2026-10-16 사용자) | 2·3·5·7 |
| 4 | 옛 구조 시트(제품 여러 개) | **목록에 보인다. 형식 칸 「이전 양식」, 작성 모달을 열지 않는다** — 기한 지난 옛 구조는 01b, 등록된 옛 구조는 01c 로 가고(등록이 `layout` 보다 앞), 그 밖(기한 안·미등록)만 읽기 전용 안내. 옛 구조는 2026-09-08(424) 전 발급이라 출시 때는 전부 기한이 지나 「만료」·「캠페인 등록됨」으로만 남는다 — 일부만 등록된 시트도 「캠페인 등록됨 (n/m)」 | 새 모달에 옛 양식을 옮기면 일이 두 배 · 숨기면 브랜드가 「시트가 사라졌다」고 묻는다 · S4 로 살아 있는 옛 구조가 0건인지 확인 | 추천값대로(2026-10-16 사용자) | 2·3·5 |
| 5 | 고쳐 두고 다시 제출 안 한 시트의 목록 표시 | 상태는 「제출됨」 그대로 + 작은 표시 「수정 중」(탭은 제출됨) | 관리자 「브랜드 수정 중 · 미제출」과 같은 사실을 같은 자리에서 · 운영팀이 보는 것은 여전히 제출본 | 추천값대로(2026-10-16 사용자) | 3·5 |
| 6 | 「제출일시」 열 | **마지막 제출 시각**(`last_submitted_at`) | 운영팀이 보는 내용이 마지막 제출본 · 처음 제출 시각은 브랜드 판단에 쓰이지 않는다 | 추천값대로(2026-10-16 사용자) | 3·5 |
| 7 | 동시 작성 표시와 「새로고침」 | 마지막 저장자 줄은 **다른 사람이 저장했을 때만** 늘 보이고, 충돌 때는 누구든 보인다. 「3분 전」은 모달을 열 때·충돌 때만 계산(저절로 안 바뀜). 「새로고침」은 **모달만** 다시 불러오고 이 기기 사본 되살리기를 묻는다 | 내가 방금 저장한 걸 「○○님이」로 보이면 잡음 · 페이지 전체 새로고침은 목록·브랜드 상태까지 흔든다 · 같은 사람의 다른 기기는 가를 수 없다(같은 이름으로 보임) | 추천값대로(2026-10-16 사용자) | 3·6 |
| 8 | bw04-03 「브랜드 정보」(브랜드명·담당자·연락처·이메일) 입력 위치 | **모달 맨 아래에 지금 폼과 같은 네 칸을 둔다. 비어 있으면 처음 열 때 로그인 계정 이름·연락처·이메일과 지금 브랜드명으로 미리 채운다**(고칠 수 있다) | 관리자 상세·견적서 「수신」(결정 13)이 `data.brand` 를 읽는다 — 칸을 없애면 견적서 수신이 빈다 · 계정 정보와 자동 동기화는 안 한다(bw04-03 주의) | 추천값대로(2026-10-16 사용자) | 6·7 |
| 9 | 「담당자에게 문의」 단추의 목적지 | **단추를 빼고 안내 문장만**(「기한을 늘리거나 새 시트가 필요하면 담당자에게 문의해 주십시오.」) | 브랜드 쪽에 정해진 문의 창구가 없다(LINE 은 인플루언서용, 광고주 입구는 reverb.kr 「문의하기」 — 16-5 4번 — 이미 계정이 있는 브랜드의 운영 문의 창구는 아님) | 추천값대로(2026-10-16 사용자) | 7 |
| 10 | 작성 모달 닫기 확인 | **저장 대기·충돌 상태일 때만** bw04-13 과 같은 확인(제목·단추 이름만 「닫기」로). 저장이 끝난 상태면 바로 닫는다 | 자동 저장이 대부분을 지킨다 · 늘 물으면 무시하게 된다 | 추천값대로(2026-10-16 사용자) | 6 |
| 11 | 로그인이 풀렸을 때 | 지금 틀의 처리(로그인 화면 + 「로그인 시간이 만료」 안내)를 그대로 쓰고, **그 직전에 입력을 이 기기 사본에 남긴다.** 다시 로그인하면 **그 시트 작성 모달로 바로**(옛 링크·메일 링크와 같은 「가려던 시트」 장치) → 사본 되살리기를 묻는다 | 새 문구·새 화면 없이 지금 장치를 재사용 · 쓰던 내용을 잃지 않는다 | 추천값대로(2026-10-16 사용자) | 5·6 |
| 12 | 발급 메일 호칭 | **「{계정 이름}님」**(이름이 비면 「{브랜드명} 담당자님」) | 1명당 1통이라 받는 사람이 정해져 있다 | 추천값대로(2026-10-16 사용자) | 10 |
| 13 | 견적서 「수신」 | **지금 그대로 — 시트의 브랜드 정보 칸**(`data.brand`) | 견적서 그리는 코드는 한 벌(관리자와 공유) — 바꾸면 관리자 견적서도 함께 바뀐다 · 결정 8 이 그 칸을 계정 값으로 미리 채운다 | 추천값대로(2026-10-16 사용자) | 7 |
| 14 | 기한 결함을 고칠 시기·방식 | **지금 고치고 운영에도 먼저 따로 넣는다**(526 묶음과 별개 — 535 선례). 고치는 내용: 기한이 지나도 `draft` 만 `expired` 로 바꾸고 제출된 시트는 상태를 두고 거부만. 운영에 이미 바뀐 행이 있으면 되돌리는 조회를 함께(S4) | 운영 링크 폼에서 지금 일어나는 결함 · 1차 출시를 기다릴 이유가 없다 | 추천값대로(2026-10-16 사용자) | 1·2 |
| 15 | 큐텐 분당 횟수·업로드 허가 기준 | 큐텐 = **계정 단위 분당 5회**(시트를 바꿔도 합산). 업로드 = **그 시트 브랜드에 연결된 계정 + 시트가 작성 가능(작성 중·제출됨, 기한 안, `consumed` 아님 — 새 구조는 카드 1장이라 곧 「미등록」)**, 폴더 `s/{시트 번호}/…` | 사양서 14-4 2번 「계정 단위」 · 토큰 폴더를 쓰면 화면이 토큰을 알아야 한다 | 추천값대로(2026-10-16 사용자) | 4·6 |
| 16 | 링크 폼을 닫는 시점 | 운영 = **출시 때**(순서: 브랜드 페이지 운영 반영 + `orient.html` 운영 막음 걷기 반영 → 그 뒤 토큰 함수 닫기. `orient.html` 이동 코드 자체는 운영 주소에서 막힌 채 먼저 나가 있다 — 조각 9). 개발서버 = **조각 8 까지 끝나 브랜드 모달로 처음부터 끝까지 확인한 직후**(그 전에는 옛 폼을 대조용으로 둔다) | 개발서버에서 옛 폼과 새 모달의 결과를 나란히 비교할 수 있다 · 데이터베이스를 먼저 닫으면 옛 폼이 오류 화면이 된다 | 추천값대로(2026-10-16 사용자) | 9 |
| 17 | 관리자 발급 쪽(16-5 8·9번)을 이 작업표에 넣을까 | **넣는다**(조각 10, 브랜드 화면 조각과 동시 진행 가능). 단 관리자 브랜드 상세 재구성(16-5 6번·묶음 ③)과는 섞지 않는다 | 16-5 6번이 「발급 경고·계정 전원 수신은 브랜드 페이지 1차와 함께」로 정했다 · 메일 링크가 브랜드 페이지를 가리켜야 이 메뉴가 쓰인다 | 추천값대로(2026-10-16 사용자) | 10 |

### 개발 기본값 (묻지 않고 알림)

| # | 기본값 | 근거 | 조각 |
|---|---|---|---|
| 기본값 1 | 작성 모달은 `orient.html` **새 구조 폼 코드를 브랜드 파일로 옮겨 온다**(옛 구조 경로는 안 옮긴다). 끼워 넣기(iframe)로 폼 전체를 띄우는 방식은 쓰지 않는다 — 다른 도메인에 로그인 세션을 넘겨야 해서 위험. 견적서만 지금처럼 끼워 넣는다 | 의심 4·13 | 6·7 |
| 기본값 2 | 데이터베이스는 **본체를 한 벌로**: 저장·제출·미리보기·구간 조회의 본문을 내부 함수 넷으로 빼고, 토큰 함수와 로그인 함수가 같은 본체를 부른다(토큰 함수 동작·결과 키는 524·430·489 와 같게) | 사본이 두 벌이면 결함 수정·3차 ①-5 를 두 번 해야 한다 | 2·3 |
| 기본값 3 | 로그인 함수 결과 모양은 **기존 오리엔시트 함수와 같은 `{success, reason, …}`** 에 `reason:'not_found'` 하나를 더한다(536 의 `result` 모양이 아니다) | 옮겨 오는 폼 코드가 거의 그대로 돈다 | 3·6·7 |
| 기본값 4 | 남의 브랜드 시트·없는 시트·연결이 풀린 계정은 모두 `not_found` 하나(구분하지 않는다). 화면은 `not_found` 면 `refreshBrandLoginState()` 후 목록으로 | 시트 번호로 다른 브랜드 시트의 존재를 알 수 없게 | 3·5 |
| 기본값 5 | 브랜드에게 주는 값에 **토큰·`created_by`·`mail_sent_to`·내부 메모를 싣지 않는다** | 토큰은 옛 링크 열쇠 · 나머지는 운영 내부 | 3 |
| 기본값 6 | 이 기기 사본 열쇠 `reverb.brandOrient.{계정 번호}.{시트 번호}` · 값 `{data, at, version, conflict}`(옛 폼과 같은 모양) | 같은 기기 다른 계정이 남의 사본을 보지 않게 | 6 |
| 기본값 7 | 「가려던 시트」 장치 — 주소 `?orient=<시트 번호>`(메일 링크) · `?orient_token=<토큰>`(옛 링크 이동) → 부팅 때 세션 저장소 `reverb.brandOrientTarget` 에 옮기고 **주소에서 곧바로 지운다**. 오리엔시트 페이지가 그릴 때 한 번 꺼내 쓴다 | 첫 페이지가 오리엔시트라 로그인 직후 자연히 소비된다 · 토큰을 주소에 남기지 않는다(초대 번호와 같은 처리) | 5·9 |
| 기본값 8 | 활동 기록(`brandTouchActivity`)은 「작성 시작」·제출 성공 때. **자동 저장은 모달 한 번 열 때 첫 성공 한 번만** | 16-4 ③ 「사람이 누른 저장」 · 자동 저장마다 부르면 호출이 쏟아진다 | 6·7 |
| 기본값 9 | 리스트/카드 보기는 이 기기에 기억(`reverb.brandOrient.view`, 기본 리스트). 모바일은 카드만 | bw04-00a 「기억할지」 질문 — 되돌리기 쉬운 쪽 | 5 |
| 기본값 10 | `notify-orient-submitted`(a04-95)는 이번에 고치지 않는다(「누가 제출했는지」 줄 추가는 기획 확인 뒤) | 웹훅 함수라 바꾸면 운영 배포가 필요 | — |

---

## 🚦 착수 전 선결 조건

| # | 선결 조건 | 근거 | 막는 조각 |
|---|---|---|---|
| S1 | 결정 1~17 사용자 답 — ✅ **충족**(2026-10-16, 모두 추천값대로) | 위 표 | 1(결정 14) · 2(1·2·3·4·14) · 3(1·2·3·4·5·6·7) · 4(15) · 5~7 · 9(16) · 10(12·17) |
| S2 | 개발서버 시딩 단가 25행을 실제 금액으로(또는 시딩 확인은 가짜 값임을 알고만 진행) | `orient-sheet.md` — 가짜 값이 단추·견적서에 뜬다 | 8(조각 6·7 의 시딩 확인 포함 — 착수는 안 막음) |
| S3 | 개발서버 시험 데이터 — 시험 브랜드(`zz-b2-owner` 대표 · `zz-b2-second` 멤버가 붙은 브랜드)에 리뷰어·시딩 시트 각각 + 상태별(신규·작성 중·제출됨·제출 뒤 수정 중·일부 등록·전부 등록·기한 지남·제출 뒤 기한 지남·견적 계산 실패) + 옛 구조 시트 1건. 기한 지남은 `token_expires_at` 을 SQL 로 과거로 | 화면 상태 전부 확인 | 5~8 완료 확인 |
| S4 | **운영 조회 둘**(사용자에게 순차 안내): ①결함 피해 — `status='expired' AND submitted_at IS NOT NULL` 건수와 목록 ②살아 있는 옛 구조 시트 — `data->'issued' IS NULL AND status IN ('draft','submitted') AND token_expires_at > now()` 건수 | 결정 4·14 의 근거 | 1(피해 복구 범위) · 결정 4 전제 확인(살아 있는 옛 구조 0건) |
| S5 | 피그마 대조 — 그 화면을 만드는 조각 착수 때 칸 순서·문구 글자(00·00a~e·bm04-00 → 5, 01·02·bm04-01·01e·13·91·92 → 6, 03·04·04a·05·05a·05b·01a·01b·01c·01f·01g·90 → 7, bw01-09 → 9, bw04-96 → 10) | 정본 | 5·6·7·9·10 |
| S6 | 출시 관문 `/약관확인`에 「저장·제출한 계정 기록」(결정 2)을 넣는다 | 의심 11 · 16-5 2번 | 운영 반영(개발 착수는 안 막음) |
| S7 | 개발서버 비밀값 `PUBLIC_BRAND_URL` 확인(있음 — 브랜드 메일 함수가 씀) · 새 스위치 `ORIENT_MAIL_TO_BRAND_ACCOUNTS` 를 **개발서버에만** | 조각 10 · 의심 10 | 10 |

---

## ⚠️ 사양서·규칙 stale 점검

1. **사양서 13-1 「현재 상태」 제출 줄** 「제출 `submit_orient_sheet`(현재 원본 461)」 → **524**. 「결함 후보 — 재현하지 않았다」 → 코드로 확정(위 「현재 상태」). 기획 몫.
2. **사양서 13-1 「현재 상태」 수정 막힘 줄** 「캠페인 발행(`consumed`)된 시트와 기한이 지난 시트는 수정이 막힌다」 — 맞다. 다만 결함 때문에 「제출된 시트가 기한 뒤 저장 시도로 등록 불가가 된다」가 빠져 있다(13-1 충돌 줄에만 있음).
3. **피그마 bw04-00e** 탭 목록에 「완료」, 안내 문구가 「~요」체 → bw04-00 은 「만료」, 문체는 「~습니다」. 기획 몫(「기획에게 넘길 것」 1).
4. **피그마 bw04-05b·05a** 문구가 「~요」체 → 같은 처리.
5. **`orient-sheet.md`** 「익명 함수 3종 (GRANT anon)」 — 조회는 로그인에도 열려 있고 저장·제출만 `anon` 이다. 조각 11 에서 「로그인 함수 계열」과 함께 고친다(고문에게 넘김).
6. **`brand-shell.js` 머리 주석** 「페이지 파일(brand-info.js·brand-members.js·brand-mypage.js)」 → 조각 5 에서 오리엔시트 파일을 더한다.
7. **`CLAUDE.md` 「브랜드 셀프 오리엔시트」 절** 「현재 원본 번호」 줄 — 조각 1~4 뒤 새 번호로(조각 11).
8. bw04-01c 「캠페인 보기 ›」 → bw05-01(캠페인 페이지)은 아직 「준비 중」이다. 조각 7 은 단추를 그리되 `#campaigns` 로 보낸다(05 가 생기면 그 캠페인으로).

---

## 한눈에 보는 의존 순서

```
1 기한 결함 수정(데이터베이스 — 운영에도 먼저 따로, 결정 14)
 └→ 2 본체 한 벌로 + 저장자 칸 + 3차 ①-5(데이터베이스, 개발서버만)
      └→ 3 로그인 계정 함수 일곱(데이터베이스, 개발서버만)
           ├→ 4 큐텐 계정 관문 + 로그인 업로드 허가(데이터베이스 + 서버 함수)
           ├→ 5 목록 페이지 + 「가려던 시트」 장치(4 와 별개 — 4 의 산출물을 안 쓴다)
           │    └→ 6 작성 모달(리뷰어·시딩·모바일) + 자동 저장·충돌·떠나기 전 확인  ← 4·5 둘 다 필요
           │         └→ 7 확인·견적서·제출·완료·만료·등록 시트
           │              └→ 8 브랜드 화면 처음부터 끝까지 확인(개발서버)
           │                   └→ 9 옛 링크 안내 bw01-09 + 링크 폼 닫기(코드 → 개발서버 닫기는 8 직후 / 운영 닫기는 출시 때)
           └→ 10 관리자 발급 쪽(받는 사람·경고·메일)  ∥ 5~8 과 동시(링크 형식은 5 의 계약)
(1~10) → 11 문서
```

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약(요지) | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| 1 | 기한 결함 수정 | 새 마이그레이션 | `save_orient_draft`·`submit_orient_sheet` 재정의(베이스 524, 기한 갈래만) | S1(결정 14)·S4① | ✗ | 개발 |
| 2 | 본체 한 벌로 + 저장자 칸 + ①-5 | 새 마이그레이션 | 칸 `last_edited_at`·`last_edited_by` · 내부 함수 `_orient_save_core`·`_orient_submit_core`·`_orient_preview_core`·`_orient_tier_fees_core` · 판정 `_orient_brand_view_status` · 토큰 함수 넷이 본체를 부름(`get_orient_sheet` 는 그대로) | 1 · S1 | ✗ | 개발 |
| 3 | 로그인 계정 함수 일곱 | 새 마이그레이션 | `get_my_orient_sheets` · `get_my_orient_sheet` · `save_my_orient_draft` · `submit_my_orient_sheet` · `preview_my_orient_quote` · `get_my_orient_tier_fees` · `resolve_my_orient_link` | 2 · S1(충족) | ✗ | 개발 |
| 4 | 큐텐 계정 관문 + 로그인 업로드 허가 | 새 마이그레이션 · `supabase/functions/qoo10-product-lookup/index.ts` | `orient_lookup_gate_account(uuid, uuid)` · `orient_lookup_hits.auth_id` · 함수 본문 `{sheet_id,url}` 갈래 · `orient_account_can_upload(text)` · 정책 `orient_images_account_insert` | 3 · S1(결정 15) | ✗ | 개발 |
| 5 | 목록 페이지 + 「가려던 시트」 장치 | 새 `dev/js/brand-orient.js` · `dev/js/brand-shell.js` · `dev/js/brand-app.js` · `dev/build.sh` · `dev/brand/index.html` · `dev/css/brand.css` | `registerBrandPage('orient', …)` · `#brandOrientPage` · `BRAND_ORIENT_STATUS` · `reverb.brandOrientTarget` · `openBrandOrientSheet(sheetId)`(자리만) | 3 · S5 · S1(충족) | ✗ | 개발 |
| 6 | 작성 모달 + 자동 저장·충돌·떠나기 전 확인 | 새 `dev/js/brand-orient-form.js` · `dev/js/brand-shell.js` · `dev/brand/index.html`(DOMPurify) · `dev/build.sh` · `dev/css/brand.css` | `openBrandOrientSheet` 구현 · `#brandOrientModal` · `registerBrandLeaveGuard(fn)` · 저장 상태 여덟 | 4·5 · S5 · S1(충족) | ✗ | 개발 |
| 7 | 확인·견적서·제출·완료·만료·등록 시트 | `dev/js/brand-orient-form.js` · `dev/css/brand.css` | `#boConfirm`·`#boQuote`(끼워 넣은 견적서)·`#boDone` · 거부 이유 → 칸·토스트 | 6 · S5 · S1(충족) | ✗ | 개발 |
| 8 | 브랜드 화면 처음부터 끝까지 확인 | (코드 없음 — 고친 것은 6·7 에) | 확인 기록 | 7 · S2·S3 | ✗ | 개발(+확인 담당) |
| 9 | 옛 링크 안내 + 링크 폼 닫기 | `dev/sales/orient.html` · `dev/brand/index.html` · `dev/js/brand-app.js` · `dev/js/brand-core.js` · `dev/js/brand-orient.js` · 새 마이그레이션(마지막에) | bw01-09 카드 `data-screen="orient-moved"` · `orient.html` `?token=` → 브랜드 페이지 이동 · 토큰 함수 결과 `reason:'moved'` | 8 · S1(결정 16) · S5 | ✗ | 개발 |
| 10 | 관리자 발급 쪽 | `dev/js/admin-orient.js` · `dev/js/admin-brand.js`(링크 두 곳) · `dev/lib/storage.js`(`sendOrientInviteMail` 한 곳) · `supabase/functions/notify-orient-sheet/index.ts` · 새 `docs/email-templates/orient-sheet-invite-brand.html`(+동기화) | 받는 사람 = 설정 마친 연결 계정 전원 · 경고 ⓐ/ⓑ~ⓓ · 링크 `?orient=` · 스위치 `ORIENT_MAIL_TO_BRAND_ACCOUNTS` | 3(링크 형식은 5 계약) · S1(12·17) · S5 · S7 | ○(5~8 과) | 개발 |
| 11 | 문서 | 사양서 「구현 결과」 · `docs/FEATURE_SPEC.md` · `CLAUDE.md`(규칙 파일은 고문에게) | — | 1~10 | ✗ | 개발 |

---

## 조각별 상세

### 작업 1 — 기한 결함 수정
- **하는 일:** 524 의 저장·제출 두 함수에서 기한 갈래만 고친다 — 기한이 지났을 때 `status='draft'` 면 지금처럼 `expired` 로 바꾸고 `{success:false, reason:'expired'}`, **`submitted` 면 상태를 그대로 두고** 같은 거부만. 나머지 본문은 524 글자 그대로.
- **담당 파일:** 새 마이그레이션 1개.
- **산출 계약:** 함수 이름·인자·권한(`anon` 만)·결과 키 **변경 없음**(`CREATE OR REPLACE`). 머리말에 「다음 재정의의 베이스는 이 파일」. 파일 하단에 **운영 피해 확인 조회**(S4①)와 **되돌리는 패치 초안**(결정 14 — S4① 결과가 0건이 아니면 사용자 확인 뒤 한 단계씩 실행)(`status='expired' AND submitted_at IS NOT NULL` → `submitted`, 단 `data.cards` 에 등록 표시가 전부 있으면 `consumed`)을 주석으로. 패치 실행은 사용자 확인 뒤 한 단계씩.
- **선행 의존:** S1(결정 14) · S4①.
- **완료 정의:** 개발서버에서 ①제출된 시트의 기한을 SQL 로 과거로 → 옛 폼으로 저장 시도 → 결과 `expired` 이고 **`status` 는 `submitted` 그대로** → 관리자 「이 카드로 발행」이 성공 ②작성 중 시트는 종전대로 `expired` 로 바뀜. 524 의 검증 V3~V7 이 그대로 통과.
- **필요 검문소:** `reverb-supabase-expert`(쓰기 전) · `reverb-reviewer`.
- **주의·롤백:** 롤백 = 524 의 [B]·[C] 블록 재실행. 운영 반영은 1차 묶음과 별개(결정 14 「운영 먼저」) — 이 함수는 운영 링크 폼이 지금 쓰므로 **적용 직후 운영 링크 폼에서 저장 한 번**을 확인.

### 작업 2 — 본체 한 벌로 + 저장자 칸 + 3차 ①-5
- **하는 일:** ①`orient_sheets` 에 칸 둘 ②저장·제출·미리보기·구간 조회의 본문을 내부 함수 넷으로 옮기고 그 토큰 함수 넷은 「토큰 → 시트 번호」만 하고 본체를 부른다(조회 `get_orient_sheet` 는 본체로 빼지 않고 손대지 않는다 — 로그인 조회는 조각 3 이 따로 쓴다) ③제출 본체의 견적 계산 예외 갈래가 지우기 전에 직전 `quote` 를 `quote_history` 로 옮긴다(정상 경로의 `_orient_compute_quote` 와 같은 방식) ④브랜드 화면 상태 판정 한 곳.
- **담당 파일:** 새 마이그레이션 1개.
- **산출 계약:**
  - 칸: `last_edited_at timestamptz NULL` · `last_edited_by uuid NULL`(외래 키 없음 — 계정이 지워져도 행 보존). 브랜드(토큰 포함) 저장·제출이 성공할 때만 쓴다. 관리자 동작·메일 기록은 안 건드린다. 기존 행은 NULL(소급 안 함).
  - 내부 함수(전부 `SECURITY DEFINER SET search_path=''`, 실행 권한은 `postgres`·`service_role` 부여 → `PUBLIC` 회수 → `anon`·`authenticated` 회수):
    - `_orient_save_core(p_sheet_id uuid, p_data jsonb, p_version int, p_editor uuid) RETURNS jsonb` — 524 `save_orient_draft` 본문(결함 수정 포함) + 성공 때 `last_edited_at=now()`, `last_edited_by=p_editor`
    - `_orient_submit_core(p_sheet_id uuid, p_data jsonb, p_version int, p_editor uuid) RETURNS jsonb` — 524 `submit_orient_sheet` 본문 + ①-5 + 저장자 칸
    - `_orient_preview_core(p_sheet_id uuid, p_data jsonb) RETURNS jsonb` — 430 본문
    - `_orient_tier_fees_core(p_sheet_id uuid) RETURNS jsonb` — 489 본문
  - 판정 `_orient_brand_view_status(p_status text, p_deadline timestamptz, p_data jsonb, p_last_edited_at timestamptz, p_version int) RETURNS text` → `'new'|'editing'|'submitted'|'registered'|'expired'` — 결정 1·3·4 의 우선순위 그대로. 「신규」 = `draft` + `last_edited_at IS NULL` + `version = 0`(발급 직후 판 — 186 표 기본값·490 발급 함수 모두 0, 539 작성 때 확인. 기존 행은 `version` 으로 판정이 갈린다). 일부 등록(옛 구조)은 결정 4 에 따라 `'registered'` + 개수는 목록 함수가 따로 준다. `IMMUTABLE` 아님(시각 비교) — `STABLE`.
  - 토큰 함수 넷(`save_orient_draft`·`submit_orient_sheet`·`preview_orient_quote`·`get_orient_tier_fees`)이 본체를 부른다: 인자·권한·결과 키 **그대로**, `invalid_token` 도 그대로. 저장·제출은 `p_editor` 에 NULL. `get_orient_sheet`(524)는 이 조각에서 바꾸지 않는다.
- **선행 의존:** 1(결함 수정이 본체로 들어간다) · S1(결정 1·2·3·4·14).
- **완료 정의:** 개발서버에서 옛 폼(`sales-dev.globalreverb.com/orient?token=…`)으로 작성 → 견적 보기 → 제출 → 「내용 수정하기」 → 다시 제출이 **이전과 똑같이** 동작(524 V3~V7 · 430 검증 ①). 견적 계산을 일부러 실패시키는 시트(판매가에 글자)로 재제출 → `quote_history` 에 직전 견적이 남는다. `SELECT proname, proacl::text …` 로 내부 함수 넷에 `anon`·`authenticated` 없음, 맨 앞 `=X/` 없음. 내부 함수마다 1회 실제 호출(빈 결과라도).
- **필요 검문소:** `reverb-supabase-expert`(쓰기 전 — 본문을 옮기며 빠지는 줄이 없는지 524·430·489 와 줄 단위 대조) · `reverb-reviewer`.
- **주의·롤백:** 🔴 토큰 함수는 운영 링크 폼이 쓰는 함수다 — 이 파일은 1차 묶음과 함께 운영에 가지만, **그 순간부터 운영 폼이 새 본체로 돈다.** 그래서 「동작 같음」 확인이 이 조각의 핵심. 롤백 = 토큰 함수 넷을 저장·제출은 **조각 1 판**(524 로 되돌리면 운영에 먼저 넣은 기한 결함 수정이 사라진다)·미리보기 430·구간 489 로 재실행 → 내부 함수·판정 함수 `DROP` → 칸 `DROP`(작업 3 이후면 3 을 먼저 되돌린다).

### 작업 3 — 로그인 계정 함수 일곱
- **하는 일:** 브랜드 페이지가 부르는 함수 일곱. 권한은 시트의 `brand_id` 로 `public.is_my_brand()` — 화면이 보낸 브랜드 번호를 믿지 않는다(목록 함수만 인자로 받고 그 브랜드를 다시 판정).
- **담당 파일:** 새 마이그레이션 1개.
- **산출 계약(공통):** 전부 `SECURITY DEFINER SET search_path=''`, 실행 권한 `postgres`·`authenticated`·`service_role` 부여 → `PUBLIC` 회수 → `anon` 회수. 결과 `{success:true, …}` / `{success:false, reason}`. 공통 거부 `not_found`(시트 없음·남의 브랜드·연결 해제·보관 브랜드 — 기본값 4). 토큰·`created_by`·`mail_sent_to`·메모는 싣지 않는다.
  - **`get_my_orient_sheets(p_brand_id uuid) RETURNS jsonb`** (`STABLE`) — `is_my_brand(p_brand_id)` 거짓이면 `not_found`. 정상 `{success:true, server_now, sheets:[{id, orient_no, layout:'new'|'old', form_type, channel, extra_markets, goods_code, product_name, status, view_status, registered_count, card_count, issued_at, deadline_at, submitted_at, last_submitted_at, last_edited_at, last_edited_by_name, last_edited_by_me, has_unsubmitted_draft}]}` — 발급 최신순. `view_status` 는 `_orient_brand_view_status` 만. `last_edited_by_name` 은 읽을 때 `brand_accounts.name`(결정 2 — 없으면 NULL). `has_unsubmitted_draft` = `submitted` + `draft_saved_at IS NOT NULL`(관리자 `osHasUnsubmittedDraft` 와 같은 식). 상품 번호·제품명은 `data.cards[0].sale.goods_code`·`product.name`, 추가 옵션 `sale.extra_markets`(리뷰어만), 시딩 채널 `data.issued.channel`.
  - **`get_my_orient_sheet(p_sheet_id uuid) RETURNS jsonb`** (`STABLE`) — 정상 `{success:true, id, brand_id, orient_no, layout, form_type, data, status, view_status, version, submitted_at, last_submitted_at, deadline_at, initial_values, last_edited_at, last_edited_by_name, last_edited_by_me, read_only, campaigns:[{card_idx, campaign_id, linked_existing}], draft_data?}`. `draft_data` 는 524 와 같은 조건일 때만 키. `read_only` = `view_status='registered'` 이거나 옛 구조. 🔴 새 구조 시트는 카드 1장 고정이라(제출 함수가 2장 이상을 `cards_limit` 로 거부) 「일부 등록」은 옛 구조에만 있다 — 새 구조는 등록되면 곧 전 카드 등록. 거부: `expired`(만료 — 단 결정 3 에 따라 등록 시트는 기한 뒤에도 `success:true` + `read_only:true` + `data` 에서 `quote`·`quote_history`·`quote_error` 를 뺀 판을 준다), `not_found`. 🔴 `consumed` 를 거부하지 않는다(bw04-01c).
  - **`save_my_orient_draft(p_sheet_id uuid, p_data jsonb, p_version int)`** → `_orient_save_core(…, auth.uid())`. 결과 키·거부 이유 = 524(`expired`·`consumed`·`conflict`·`data_too_large`) + `not_found`. 🔴 일부만 등록된 **옛 구조** 시트의 저장은 지금 규칙(발행 카드 복구 328)대로 — 거부를 새로 걸지 않는다(화면은 옛 구조를 작성 모달로 열지 않으므로 실제로는 옛 링크 폼만 해당). 새 구조는 등록되면 곧 `consumed` 라 524 대로 거부.
  - **`submit_my_orient_sheet(p_sheet_id uuid, p_data jsonb, p_version int)`** → `_orient_submit_core`. 거부 이유 = 524(`cards_limit`·`guide_too_long`·`appeal_too_long`·`text_too_long`+`field`·`notice_not_acknowledged`·`slots_below_min`+`min_slots`·`data_required`·`data_too_large`·`conflict`·`expired`·`consumed`) + `not_found`. 성공 결과 = 524 와 같은 키(`quote`·`quote_error` 포함).
  - **`preview_my_orient_quote(p_sheet_id uuid, p_data jsonb)`** → `_orient_preview_core`. 결과 = 430 + `not_found`.
  - **`get_my_orient_tier_fees(p_sheet_id uuid)`** → `_orient_tier_fees_core`. 결과 = 489 + `not_found`.
  - **`resolve_my_orient_link(p_token uuid) RETURNS jsonb`** — 토큰의 시트가 내 브랜드면 `{success:true, sheet_id, brand_id}`, 아니면 `not_found`(토큰이 틀린 경우와 구분 안 함). 시트 내용은 싣지 않는다(16-4 「링크 속 열쇠만으로는 시트 내용을 보여 주지 않고」).
- **선행 의존:** 2 · S1(충족).
- **완료 정의:** 🔴 SQL 편집기로는 재현 안 됨(`auth.uid()` 없음 — 늘 `not_found`). **로그인한 브랜드 계정**(`zz-b2-owner` 대표 / `zz-b2-second` 멤버)의 화면 콘솔에서 `brandRpc` 로:
  - 대표·멤버 모두: 목록 `success` · 상세 `success` · 저장 → `version` +1 · `last_edited_by_me:true` · 제출 → `quote` 또는 `quote_error`
  - 다른 브랜드 시트 번호 · 인플루언서 계정 · 연결 해제된 계정: 일곱 모두 `not_found` / 비로그인(공개 키): 실행 권한 오류
  - 제출 뒤 수정 → `data` 그대로, `draft_data` 생김(524 와 같음) · 등록 시트 상세 → `read_only:true` + 견적 · 기한 뒤 등록 시트 → 견적 키 없음 · 기한 뒤 제출 시트 → `expired` 이고 **상태 그대로**(작업 1)
  - 옛 링크 토큰 → `resolve_my_orient_link` 가 시트 번호
  - 권한 조회: 맨 앞 `=X/` 없음, `anon` 없음
- **필요 검문소:** `reverb-supabase-expert`(쓰기 전) · `reverb-reviewer`.
- **주의·롤백:** 반환 칸을 나중에 바꾸려면 `DROP` 후 `CREATE` 라 회수를 다시 건다. 롤백 = `DROP FUNCTION` 일곱(화면 5~7 을 먼저 되돌린다). 운영 순서 = 526~536 묶음(535 는 이미 따로 적용) 뒤.

### 작업 4 — 큐텐 계정 관문 + 로그인 업로드 허가
- **하는 일:** ①큐텐 불러오기에 「로그인 계정 + 시트」 관문 ②`orient-images` 통에 로그인 계정 넣기 정책. 옛 토큰 갈래는 그대로(조각 9 에서 닫음).
- **담당 파일:** 새 마이그레이션 1개 · `supabase/functions/qoo10-product-lookup/index.ts`.
- **산출 계약:**
  - `orient_lookup_hits`: `auth_id uuid NULL` 추가, `token` 을 NULL 허용으로, 검사 `CHECK (token IS NOT NULL OR auth_id IS NOT NULL)`, 색인 `(auth_id, hit_at DESC)`.
  - **`orient_lookup_gate_account(p_auth_id uuid, p_sheet_id uuid) RETURNS boolean`** — 서비스 키 전용(428 과 같은 부여 → 회수). ①그 계정이 시트 브랜드에 활성 연결(`brand_account_links` 활성 + 브랜드 활성 — `my_brand_role` 과 같은 식을 계정 번호로) ②시트가 작성 가능(`draft`·`submitted`, 기한 안 — `consumed`(전 카드 등록)만 막고 일부 등록 시트는 지금 저장 규칙(328)대로 통과. 결정 15 「미등록」은 이 뜻) ③계정 단위 최근 60초 5회 미만(결정 15) — 계정 단위 잠금(`pg_advisory_xact_lock`) 뒤 셈·기록.
  - 서버 함수: 본문에 `sheet_id` 가 있으면 새 갈래 — `Authorization` 의 **로그인 토큰을 서비스 연결의 `auth.getUser(토큰)` 으로 검증**해 계정 번호를 얻고(공개 키·서비스 키·검증 실패는 `{ok:false}`) 관문을 부른다. 본문의 계정 번호는 받지 않는다. 응답 모양은 지금과 같다(`{ok:true, goods_code, product_name, store_name, price_sale_jpy, price_list_jpy, price_event_jpy, image_url, brand_name}` / `{ok:false}`). `token` 갈래 그대로.
  - **`orient_account_can_upload(p_sheet text) RETURNS boolean`** (`STABLE`, 보안 정의자, `authenticated` 실행 — 정책 평가가 호출자 권한으로 돈다) — 형식이 uuid 아니면 거짓, 그 시트가 `is_my_brand(brand_id)` + 작성 가능이면 참.
  - 정책 **`orient_images_account_insert`** `ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id='orient-images' AND (storage.foldername(name))[1]='s' AND public.orient_account_can_upload((storage.foldername(name))[2]))`. 경로 = `s/{시트 번호}/{난수}.{확장자}`. 🔴 화면 업로드는 `upsert:false`(472 — `true` 면 조회 권한이 필요해 막힌다).
- **선행 의존:** 3 · S1(결정 15).
- **완료 정의:** 로그인 브랜드 콘솔에서 `brandCallFunction('qoo10-product-lookup', {sheet_id, url}, {auth:true})` → `ok:true`, 61초 안 6번째 `ok:false` · 다른 브랜드 시트 번호 `ok:false` · 공개 키로 `{sheet_id,url}` 호출 `ok:false` · 옛 폼 큐텐 불러오기 그대로 동작 · `OPTIONS` 200. 업로드: 로그인 계정이 `s/{내 시트}/x.jpg` 성공 · `s/{남의 시트}/x.jpg` 거부 · 비로그인 거부 · 옛 폼 업로드 그대로.
- **필요 검문소:** `reverb-supabase-expert` · `reverb-reviewer`(서버 함수 교차 출처 허용 헤더 점검).
- **주의·롤백:** 🔴 서버 함수는 **개발 프로젝트에만** 배포(`--project-ref qysmxtipobomefudyixw`) — 운영 배포는 출시 묶음. 새 갈래는 옛 갈래를 안 건드리므로 운영에 먼저 나가도 해가 없지만, 운영 데이터베이스에 관문 함수가 없으면 새 갈래는 늘 `ok:false`. 롤백 = 정책 `DROP` → 함수 둘 `DROP` → 색인·검사·칸 되돌림(서버 함수를 먼저 되돌린다).

### 작업 5 — 목록 페이지 + 「가려던 시트」 장치
- **하는 일:** 「준비 중」을 목록으로. bw04-00 리스트 · 00a 카드 · 00b 실패 · 00c 0건 · 00d(가로 스크롤) · 00e 고른 탭 0건 · bm04-00 모바일. 메일 링크·옛 링크·로그인 풀림 뒤 「가려던 시트」를 여는 장치.
- **담당 파일:** 새 `dev/js/brand-orient.js` · `dev/js/brand-shell.js`(35줄 「준비 중」 등록 삭제 · 머리 주석) · `dev/js/brand-app.js`(부팅 때 주소 값 옮기기) · `dev/build.sh`(`BRAND_JS_FILES` 에서 `js/brand-info.js` 뒤에 `js/brand-orient.js`) · `dev/brand/index.html`(같은 자리 원본 태그) · `dev/css/brand.css`.
- **산출 계약:**
  - `registerBrandPage('orient', { title: '오리엔시트', render(host) { … } })`
  - 상태 `_brandOrientList`(`undefined` 불러오는 중 / `null` 실패 / 배열) · `_brandOrientTab`(`'all'|'editing'|'submitted'|'registered'|'expired'`) · `_brandOrientView`(`'list'|'card'`, 기본값 9) · `_brandOrientLoadSeq`
  - `loadBrandOrientList()` → `brandRpc('get_my_orient_sheets', { p_brand_id: getCurrentBrandId() })`. 호출 실패 → `null`(00b), `not_found` → `refreshBrandLoginState()` 뒤 다시 그림(기본값 4 와 같은 처리 — 연결이 풀렸으면 로그인 판정이 알아서 다른 브랜드·안내로 보낸다)
  - 이름표 한 곳 `BRAND_ORIENT_STATUS = { new, editing, submitted, registered, expired }` → `{label, cls}`(결정 1 — 「신규」는 배지). 탭 소속 한 곳 `brandOrientInTab(row, tab)`(`new` 는 `editing` 탭). 탭 숫자와 목록은 같은 배열에서(00e 주의)
  - DOM `#brandOrientPage` · `#brandOrientTabs` · `#brandOrientList` · 단추 `data-bo-act="open|start|retry|view-list|view-card"` + `data-sheet-id`
  - 표 열: 번호 · 모집 형식 · 게시 채널 · 추가 옵션 · 상품 번호 · 상태 · 발급일 · 작성 기한(남은 날) · 제출일시(`last_submitted_at`, 결정 6) · 최근 수정(이름·시각, 결정 2) · 관리(「상세」 — 신규 줄은 비움). 날짜는 `brandFormatDate`·`brandFormatDateTime`
  - 「가려던 시트」(기본값 7): `BRAND_ORIENT_TARGET_KEY = 'reverb.brandOrientTarget'`(세션 저장소, 값 `{kind:'sheet'|'token', value}`). `bootBrand` 가 `?orient=`·`?orient_token=` 를 읽어 옮기고 `history.replaceState` 로 주소에서 지운다(설정·재설정·초대 링크 착지 갈래들 **뒤**, 해시 라우팅 **앞** — 「공유 지점 경고」 `brand-app.js` 줄과 같은 자리). `consumeBrandOrientTarget()` — 오리엔시트 페이지가 그릴 때 한 번: `token` 이면 `resolve_my_orient_link` → 시트 번호·브랜드 / 시트 브랜드가 지금 브랜드와 다르면 `switchBrand(brand_id)` 뒤 / `openBrandOrientSheet(sheetId)`. `not_found` → 토스트 「이 오리엔시트를 볼 수 없습니다.」(문구 기획 확인) + 목록
  - `openBrandOrientSheet(sheetId)` — 이 조각은 자리만(조각 6 이 채운다). 줄 누르기 = 상태별 갈래(작성 중·신규 → 작성 모달 / 제출됨 → 완료 화면 / 만료 → bw04-01b / 등록 → bw04-01c / 옛 구조 → 읽기 전용 안내 — 단 기한 지난 **미등록** 옛 구조 시트는 서버가 `expired` 를 돌려주므로 01b 로 간다. 출시 때 옛 구조는 전부 기한이 지나 있어 실제로는 만료 01b·등록 01c 만 보인다(결정 4))는 조각 6·7 이 그 함수 안에서
  - `onBrandChanged` → 목록 다시 받기 · 0건이면 00c
- **선행 의존:** 3(목록 함수) · S1(충족) · S5. 조각 4 와는 별개.
- **완료 정의:** 시험 브랜드로 다섯 탭 숫자가 목록과 같다 · 신규 줄에 배지·「상세」 없음 · 만료 줄 회색 · 카드 보기 전환 뒤 새로고침해도 유지 · 브랜드를 바꾸면 그 브랜드 목록(0건이면 00c) · 서버를 끊고(개발자 도구 오프라인) 다시 시도 → 00b → 「다시 시도」로 복구, **실패를 0건으로 그리지 않음** · `?orient=<내 시트>` 로 열면 주소창에서 값이 사라지고 그 시트 자리 호출이 한 번 · 로그인 안 한 채 `?orient=` → 로그인 뒤 같은 동작 · 좁은 폭(모바일)은 카드만·탭 가로 넘김 · Tab 으로 탭·줄에 닿음. 개발서버 「오리엔시트」 메뉴에 「준비 중입니다」가 더는 안 뜸.
- **필요 검문소:** `reverb-reviewer`.
- **주의·롤백:** `brand-shell.js`·`brand-app.js` 는 조각 6·9 도 만진다 — 한 사람이 순서대로.

### 작업 6 — 작성 모달 + 자동 저장·충돌·떠나기 전 확인
- **하는 일:** bw04-01(리뷰어) · 02(시딩) · bm04-01(모바일 전체 화면) · 01e(충돌) · 13(브랜드 바꿀 때 확인) · 91(저장 상태 여덟) · 92(칸 안내 넷). `orient.html` 새 구조 폼 코드를 옮겨 오되 서버 호출을 로그인 함수로 바꾼다(기본값 1).
- **담당 파일:** 새 `dev/js/brand-orient-form.js` · `dev/js/brand-shell.js`(떠나기 전 확인 장치) · `dev/brand/index.html`(`<script src="https://cdn.jsdelivr.net/npm/dompurify@3.1.6/dist/purify.min.js">` — `orient.html` 과 같은 판, 원본 태그) · `dev/build.sh`(`js/brand-orient.js` 뒤에 `js/brand-orient-form.js`) · `dev/css/brand.css`.
- **산출 계약:**
  - `openBrandOrientSheet(sheetId, opts)` — `brandRpc('get_my_orient_sheet', { p_sheet_id })` → `view_status`·`read_only`·`layout` 로 갈래 — 우선순위: 거부 `expired` → 01b · 등록(`view_status='registered'`) → 01c(`layout` 과 무관) · 옛 구조(`layout='old'`) → 읽기 전용 안내 · 제출됨 → 완료 화면 · 그 밖 → 작성 모달(결정 4)
  - 모달 `#brandOrientModal`(동적 생성 — `brandConfirm` 과 같은 방식) · 본문 `#boForm` · 아래 바 `#boSaveBar`(속성 `data-save-state` = `idle|saving|saved|failed|restored|conflict|locked|too_large`, bw04-91 ①~⑧) · 충돌 안내 `#boConflictNote` · 마지막 저장자 `#boLastEditor`(결정 7) · 이미 제출한 시트 수정 안내 `#boResubmitNote`(05b 「내용 수정하기」로 들어왔을 때)
  - 서버: 저장 `save_my_orient_draft`(한 번에 하나, 대기 1개 — 옛 폼 `saveInFlight`·`saveQueued` 그대로) · 구간 단가 `get_my_orient_tier_fees`(단가 넷을 다 받았을 때만 단추 줄 — `loadTierFees` 규칙) · 큐텐 `brandCallFunction('qoo10-product-lookup', { sheet_id, url }, { auth:true })`(빈 칸만 채움, 결과가 늦게 오면 그사이 주소가 바뀌었는지 보고 버림) · 업로드 `brandDb.storage.from('orient-images').upload('s/' + sheetId + '/' + 난수 + 확장자, blob, { upsert:false })`
  - 이 기기 사본 = 기본값 6. 충돌이면 사본에 `conflict:true`, 다시 열 때 「불러오시겠습니까?」
  - 거부 → 화면: `conflict` → 01e(자동 저장 멈춤, 「작성 완료」·「제출하기」·「파일 업로드」 누르면 토스트 「새로고침 후 다시 시도해 주십시오.」) · `expired`·`consumed` → `locked`(결정 없음 — bw04-91 「⑦ 그 자리에서 안내 화면으로 바꿀지」는 「기획에게 넘길 것」 3, 기본은 지금 폼처럼 아래 바 글자만) · `data_too_large` → `too_large` · `not_found` → 모달 닫고 `refreshBrandLoginState()` + 목록
  - **떠나기 전 확인 장치**(brand-shell.js): `registerBrandLeaveGuard(fn)` — `fn()` 이 `Promise<boolean>`(진행해도 되면 참). `switchBrand`·메뉴 이동(`hashchange` 전)·`brandLogout`·모달 닫기가 모두 이것을 거친다. 모달이 닫혀 있으면 등록을 풀어 다른 페이지에 영향 없음. 저장되지 않은 입력 = 자동 저장 대기 상태 또는 충돌 상태(결정 10 과 같은 말 — 충돌만 나고 새 입력이 없어도 묻는다). 「바꾸기」면 사본을 남기고 진행(bw04-13 — 모달을 그냥 닫을 때도 같은 확인은 결정 10)
  - 로그인 풀림(결정 11): 틀의 `SIGNED_OUT` 처리 **전에** 사본 저장 + `reverb.brandOrientTarget` 에 지금 시트(`kind:'sheet'`)
  - 브랜드 정보 네 칸(결정 8): 비어 있으면 열 때 `brandSession.name`·계정 연락처·`brandSession.email`·지금 브랜드명으로 채움(연락처는 로그인 판정에 없으면 마이페이지와 같은 조회 — 착수 때 확인)
  - 칸 이름·클래스는 옮겨 오는 폼 것을 유지(`.f-slots` 등 — 지우면 저장·검사·요약이 다 빈다). 입력 글자 16픽셀 이상
- **선행 의존:** 4(큐텐·업로드) · 5(목록·장치) · S1(충족) · S5.
- **완료 정의:** 대표·멤버 각각 리뷰어·시딩 시트를 열어 입력 → 아래 바 「저장 중…」→「저장됨 시각」 · 관리자 오리엔시트 상세에 같은 값 · 큐텐 주소 입력 뒤 칸을 벗어나면 빈 칸만 채움(분당 5회 넘기면 「자동으로 못 불러왔습니다」) · 사진 업로드 성공·5개 초과·10MB 초과 안내 · 두 탭(대표·멤버)에서 같은 시트 → 늦게 저장한 쪽 01e, 「새로고침」 뒤 사본 되살리기 · 저장 대기 중 좌측 위 브랜드 바꾸기 → bw04-13, 「계속 작성」이면 그대로 · 저장 대기 중 모달 닫기 → 같은 확인, 저장 끝난 뒤엔 바로 닫힘 · 모바일 폭에서 전체 화면·키보드가 아래 바에 안 가림 · 시딩 채널은 칩(못 바꿈) · 개발서버 시딩 단가가 가짜면 그 값이 단추에 뜬다는 것을 기록.
- **필요 검문소:** `reverb-reviewer`(서식 칸 정화가 저장·미리보기 두 곳에 있는지 · 사본 목록 의심 4) · 확인 담당 `reverb-qa-tester` 권장(다른 세션이 크롬을 안 쓸 때).
- **주의·롤백:** 🔴 이 조각 착수부터 출시 확인 뒤 옛 폼 코드를 별도로 정리할 때까지 `dev/sales/orient.html` **작성 부분을 고치는 다른 작업이 있으면 두 곳을 함께** — 착수 때 다른 세션에 알린다. 롤백 = 파일 삭제 + 빌드 목록·태그 되돌림(조각 5 의 자리 함수로 복귀).

### 작업 7 — 확인·견적서·제출·완료·만료·등록 시트
- **하는 일:** bw04-03(확인) · 04(견적서) · 04a(계산 실패) · 05·05a·05b(완료 셋) · 01a·01f·01g(입력 오류·제출 거부) · 01b(기한 지남) · 01c(등록된 시트 읽기 전용) · 90(토스트 19개).
- **담당 파일:** `dev/js/brand-orient-form.js` · `dev/css/brand.css`.
- **산출 계약:**
  - 확인 `#boConfirm`(작성 내용 읽기 전용, 서식 칸 정화 뒤 그림) → 「견적 보기」 → `brandRpc('preview_my_orient_quote', { p_sheet_id, p_data })`
  - 견적서 `#boQuote` — 🔴 **그리지 않고 끼워 넣는다**: 창 `#boQuoteFrame` 주소 = 로컬이면 `location.origin + '/sales/orient.html?embed=quote'`, 개발 `https://sales-dev.globalreverb.com/orient?embed=quote`, 운영 `https://sales.globalreverb.com/orient?embed=quote`(판정 함수 `brandSalesBase()` — 관리자 `osSalesBase` 의 브랜드 사본, 출처 판정 사본이 하나 는다는 것을 주석에). 준비 신호 `reverb-orient-quote-ready` 를 받으면 그 창 출처로 고정해 `{type:'reverb-orient-quote', quote, data, note}` 를 보낸다(관리자 `osOpenQuoteDoc` 과 같은 순서). 6초 안에 신호가 없으면 「견적서를 불러오지 못했습니다」. 인쇄는 같은 주소를 `window.open`(새 탭, `noopener` 금지)
  - 제출 `brandRpc('submit_my_orient_sheet', …)` — 직전 자동 저장이 끝나기를 기다림(늦으면 「저장이 늦어지고 있습니다」) · 단추 잠금 · 거부 이유 → `cards_limit`·`guide_too_long`·`appeal_too_long`·`text_too_long`+`field`(그 칸 빨간 테두리 + 토스트, 칸을 모르면 「내용이(가) 1,000자를 넘었습니다…」) · `slots_below_min`+`min_slots`(숫자 있으면 넣고, 없으면 일반 문구) · `notice_not_acknowledged` · `expired` → 01b · `consumed` → 01c · `conflict` → 01e
  - 완료 `#boDone` — 저장된 `data.quote`/`quote_error` 를 그린다(다시 계산 안 함). `quote_error` 넷의 문구는 옮겨 온 `QUOTE_ERROR_TEXT`. 작성본 있으면 05b 안내. 「내용 수정하기」 → 작성 모달(작성본)
  - 01b 모달: 「작성 기한이 지났습니다」 + 「닫기」 + 안내 문장 「기한을 늘리거나 새 시트가 필요하면 담당자에게 문의해 주십시오.」(결정 9 — 문의 단추 없음)
  - 01c: 초록 띠 + 진행 단계(제출 › 담당자 확인 › 캠페인 발행 › 모집) + 견적서(기한 안일 때만 — 결정 3) + 흐린 「내용 수정하기」 + 「캠페인 보기 ›」(05 가 생기기 전엔 `#campaigns`)
  - 견적서 「수신」은 손대지 않는다(결정 13)
- **선행 의존:** 6 · S1(충족) · S5.
- **완료 정의:** 대표로 리뷰어 시트 끝까지 제출 → 05 + 토스트 「제출되었습니다. 발행 전까지 수정할 수 있습니다.」 → 관리자 목록 「제출됨」 + 제출 알림 메일 경로(웹훅) 동작 기록 → 「내용 수정하기」로 고치고 닫음 → 다시 열면 05b, 목록에 「수정 중」 → 다시 제출하면 견적 차수 +1 · 판매가에 글자 → 04a → 그래도 제출 → 05a · 리뷰 가이드 1,000자 넘김(화면 검사를 우회한 값) → 01f · 단가를 못 받은 채 인원 미달 → 01g · 관리자가 등록 → 01c, 「내용 수정하기」 흐림 · 기한 지난 시트 → 01b · 「인쇄 · PDF」 → 새 탭, 파일 이름 `REVERB_…`. 견적서 금액이 관리자 「견적서 열기」와 같다(같은 그리기).
- **필요 검문소:** `reverb-reviewer` · 확인 담당 권장.

### 작업 8 — 브랜드 화면 처음부터 끝까지 확인
- **하는 일:** 조각 5~7 을 시험 데이터(S3)로 한 바퀴 — `browser-qa.md` 방식(마우스를 실제로 옮기고 스크린샷). 고칠 것은 조각 6·7 파일에서.
- **완료 정의:** 조각 5·6·7 이 만든 화면 코드 26개(S5 배정분 — 00·00a~e·bm04-00 / 01·02·bm04-01·01e·13·91·92 / 03·04·04a·05·05a·05b·01a·01b·01c·01f·01g·90. bw04-96 은 조각 10, bw01-09 는 조각 9, a04-95 는 고치지 않음) + **조각 10 이 끝나 있으면** 관리자 발급 링크 `/brand/?orient=<시트 번호>` 로 그 시트가 열리는 것(조각 10 이 늦게 끝나면 조각 10 완료 때 이 한 줄을 확인) 각각 스크린샷 한 장 이상 · 대표·멤버·두 브랜드 연결 계정 · 모바일 폭 · 옛 폼과 같은 시트를 번갈아 저장해도 충돌 판정이 맞음. 결과를 「구현 결과」에.
- **필요 검문소:** `reverb-qa-tester`(단일 세션).

### 작업 9 — 옛 링크 안내 + 링크 폼 닫기
- **하는 일:** ①`orient.html` 에 `?token=` 이 오면 브랜드 페이지로 보낸다 ②브랜드 페이지에 bw01-09 카드 ③토큰 경로를 서버에서 닫는다 — **개발서버 = 조각 8 직후, 운영 = 출시 때 코드 반영 확인 뒤**(결정 16). 견적서 끼워 넣기 모드는 **그대로**.
- **담당 파일:** `dev/sales/orient.html`(부팅 갈래 한 곳) · `dev/brand/index.html`(카드 마크업) · `dev/js/brand-app.js`(새 카드 착지) · `dev/js/brand-core.js`(`BRAND_SCREENS` 13줄 목록에 `'orient-moved'`) · `dev/js/brand-orient.js`(로그인 뒤 소비 — 이미 조각 5) · **마지막에** 새 마이그레이션. 서버 함수 `qoo10-product-lookup` 은 고치지 않는다 — 토큰 갈래는 닫기 마이그레이션의 `orient_lookup_gate` 거짓으로 막힌다(서버 함수를 따로 바꾸면 운영에 먼저 배포될 때 운영 옛 폼의 큐텐 불러오기가 죽는다).
- **산출 계약:**
  - `orient.html`: `boot()` 의 `embed=quote` 갈래 **다음**에 `token` 이 있으면 `location.replace(브랜드 주소 + '/brand/?orient_token=' + encodeURIComponent(token))` — 브랜드 주소 = 운영 `https://globalreverb.com` · 개발 `https://dev.globalreverb.com` · 로컬 같은 출처. 서버를 부르지 않는다. 🔴 **이 이동 갈래는 운영 주소(`sales.globalreverb.com`)에서는 돌지 않게 막아 둔다**(주소 판정 — 운영이면 지금 폼 그대로). `dev/sales/orient.html` 은 다음 `dev → main` 배포 때 운영 sales 에 함께 나가므로, 막지 않으면 출시 전에 운영 링크 폼 사용자가 「준비 중」 브랜드 페이지로 튕긴다(결정 16 「운영 = 출시 때」). 출시 때 이 막음을 걷는다. 그 밖의 작성 코드는 **이 조각에서 지우지 않는다**(되돌리기 쉽게 — 정리는 출시 확인 뒤 별도)
  - 브랜드 페이지: 로그인 안 한 채 `orient_token` 이 오면 카드 `data-screen="orient-moved"`(「오리엔시트는 브랜드 페이지에서 작성합니다」 + 「브랜드 페이지 로그인」 + 「계정이 없으면 브랜드 대표 담당자나 운영팀에 문의」 — 문구 피그마) → 로그인 → 조각 5 의 장치가 그 시트로. 로그인돼 있으면 카드 없이 바로
  - 닫기 마이그레이션(개발서버는 조각 8 직후 · 운영은 출시 때 — 둘 다 **코드 반영 뒤** 적용): 토큰 함수 다섯이 `{success:false, reason:'moved'}`(인자·권한 그대로 — 지우지 않는다), `orient_token_can_upload` 거짓 고정(또는 `orient_images_anon_insert` 삭제 — 작성 때 정함), `orient_lookup_gate` 토큰 갈래 거짓. 🔴 그 전에 `storage.js` 5839·5869·5899 감싸개를 부르는 자리 0곳 확인
- **선행 의존:** 8 · S1(결정 16) · S5.
- **완료 정의:** 개발서버 옛 링크(`sales-dev…/orient?token=…`) → `dev.globalreverb.com/brand/` 의 bw01-09 → 로그인 → 그 시트 작성 모달 · 다른 브랜드 계정으로 로그인 → 「볼 수 없는 오리엔시트」 + 목록 · 관리자 「견적서 열기」가 그대로 동작(양성 대조) · 닫기 마이그레이션 뒤 콘솔에서 토큰 함수 호출 → `moved`.
- **필요 검문소:** `reverb-supabase-expert`(닫기 마이그레이션) · `reverb-reviewer`.
- **주의·롤백:** 🔴 `orient.html` 은 다른 Vercel 프로젝트 — 병합으로 반영되지 않을 수 있어 **브라우저로 눈 확인**. 🔴 운영 순서 = 브랜드 페이지·`orient.html` 운영 반영 확인 → 닫기 마이그레이션(반대면 옛 폼이 오류 화면). 롤백 = 토큰 함수 넷은 조각 2 판, `get_orient_sheet` 는 524 판으로 재실행 · 업로드 허가는 200 판(`orient_token_can_upload`·`orient_images_anon_insert`) 재실행 · `orient_lookup_gate` 는 428 판 재실행 · `orient.html` 갈래 되돌림.

### 작업 10 — 관리자 발급 쪽 (결정 17 — 이 작업표에 넣음)
- **하는 일:** 16-5 8번(계정 없는 브랜드 발급 경고) · 9번(받는 사람 = 설정 마친 연결 계정 전원, 1명당 1통) · 발급 메일 링크를 브랜드 페이지로 · 새 메일 양식(bw04-96).
- **담당 파일:** `dev/js/admin-orient.js`(발급 모달 받는 사람 칸·발송 결과 표시·링크 칸) · `dev/js/admin-brand.js`(1014·3167 링크) · `dev/lib/storage.js`(`sendOrientInviteMail` — 받는 사람 인자를 판정 켜진 환경에서 안 보냄) · `supabase/functions/notify-orient-sheet/index.ts` · 새 `docs/email-templates/orient-sheet-invite-brand.html` + `scripts/sync-email-templates.sh` 실행 · 양식 목록 `docs/email-templates/index.html`.
- **산출 계약:**
  - 화면: `_brandAccountEnabled()` 가 참일 때만 ①받는 사람 고르기·직접 입력·「새 담당자를 목록에 저장」 처리(`_osPendingContact`)를 숨김 ②발급 모달에 경고 — `admin_get_brand_account_status`(533) 결과로 ⓐ계정 없음 / ⓑ~ⓓ 미발송·메일 보냄·링크 만료 — 문구는 ⓐ 하나 · ⓑ~ⓓ 셋이 공용 하나, 모두 두 문구(16-5 8번 원문) — 막지 않음 · 조회 실패면 경고 대신 「계정 상태를 확인하지 못했습니다」(실패를 「계정 없음」으로 그리지 않음) ③링크 = `location.origin + '/brand/?orient=' + 시트 번호`(관리자와 브랜드 페이지가 같은 도메인). 거짓이면 지금 그대로
  - 서버 함수: 비밀값 스위치 `ORIENT_MAIL_TO_BRAND_ACCOUNTS=1` **그리고** 개발 프로젝트 주소일 때만 새 규칙(브랜드 설정 메일의 두 겹 잠금과 같은 방식) — 받는 사람 = `brand_account_links` 활성 + 브랜드 활성 + `brand_accounts.password_set_at IS NOT NULL`(서비스 키로 서버가 읽음, 화면의 `to_email` 무시), 1명당 1통, 링크 `PUBLIC_BRAND_URL + '/?orient=' + 시트 번호`, 양식 새 파일, 호칭(결정 12). 결과 `{sent:boolean, recipients:[이메일], failed:[이메일], reason?:'no_account'}` · 기록 `mail_sent_at` + `mail_sent_to` = 성공한 주소를 「, 」로 이은 값(일부 실패면 성공분만, 전원 실패면 기록 안 함) · 1명 이상 성공이면 서베이 상태 자동 전진(지금 규칙). 스위치가 없으면 **지금 동작 그대로**
  - 새 양식: `{{recipient_name}}`·`{{brand_name}}`·`{{link}}`·`{{deadline}}` · 「브랜드 페이지에 로그인해 작성」 문장 · 옛 양식은 출시 때까지 둔다
- **선행 의존:** 3(목록에 나타나는 기준과 받는 사람 기준이 사실상 같다 — 받는 사람은 비밀번호를 정한 계정만이고, 정하지 않은 계정은 로그인을 못 해 목록도 못 본다) · 조각 5 의 `?orient=` 계약 · S1(결정 12·17) · S5(bw04-96) · S7.
- **완료 정의:** 개발서버 관리자로 ①계정 없는 브랜드 발급 → 경고 ⓐ, 발급 성공, 메일 결과 「받을 계정이 없어 보내지 않았습니다」 ②설정 전 계정 브랜드 → 경고 ⓑ~ⓓ ③시험 브랜드(대표+멤버) 발급 → 결과의 발송 대상에 두 주소(개발서버는 실제 발송을 안 하므로 `recipients`·`failed` 목록과 서버 로그의 링크가 `/brand/?orient=<시트 번호>` 형식인지까지만 — **상세 기록 `mail_sent_to`·서베이 상태 자동 전진은 성공 발송이 있어야 생기므로 운영 출시 때 첫 발급으로 확인**) · 운영 주소에서는 화면이 지금과 같다(받는 사람 칸 보임). 🔴 실제 메일 발송 시험은 개발서버에서 하지 않는다(`supabase.md` 메일 시험 정책) — `dev_link` 같은 응답 노출 장치는 만들지 않는다(발급 메일은 링크가 비밀이 아니므로 결과 주소 목록만 확인).
- **필요 검문소:** `reverb-reviewer`(교차 출처 허용 헤더 — 이 함수는 브라우저가 직접 부른다) · `reverb-supabase-expert`(서비스 키 조회 범위).
- **주의·롤백:** 🔴 서버 함수는 개발 프로젝트에만 배포하고 스위치도 개발서버에만. 운영에 함수가 먼저 배포돼도 스위치가 없으면 지금 동작(의심 10). `storage.js` 는 핫스팟 — 다른 `storage.js` 작업과 동시에 하지 않는다. 묶음 ③(관리자 브랜드 상세 재구성)이 같은 파일(`admin-brand.js`)을 다시 쓸 예정. 🔴 **출시 때 걷을 것 셋**(결정 16 의 출시 순서와 함께): ①운영 비밀값 `ORIENT_MAIL_TO_BRAND_ACCOUNTS=1` 넣기 ②서버 함수의 「개발 프로젝트 주소일 때만」 조건을 걷는 코드 수정 → 운영 배포(조건이 남으면 운영에서 스위치를 넣어도 새 규칙이 안 켜진다) ③화면의 `_brandAccountEnabled()` 판정 걷기(브랜드 페이지 공통 출시 단계 — 사양서 「운영 반영 전 남은 관문」 4번) · 옛 양식 `orient-sheet-invite.html` 은 출시 확인 뒤 정리. 조각 11 문서에 이 순서를 적는다.

### 작업 11 — 문서
- **하는 일:** 사양서 「구현 결과」(실제 마이그레이션 번호 · 함수 일곱과 결과 이유 · S4 운영 조회 결과 · 결함 복구 여부 · 확인 기록) · `docs/FEATURE_SPEC.md` · `CLAUDE.md`(「브랜드 셀프 오리엔시트」 현재 원본 번호 — 저장·제출·조회의 베이스가 바뀜 · 토큰 함수가 본체를 부른다는 것 · 🔴 링크 폼 닫기 순서 · 운영 묶음 순서 · 조각 10 의 출시 때 걷을 것 셋 · 조각 9 `orient.html` 운영 주소 막음 걷기). 규칙 파일(`orient-sheet.md`·`brand-account.md`)은 고문에게. Notion 「오리엔시트」 가이드는 운영 배포 뒤.
- **완료 정의:** 위 문서 갱신이 같은 병합 요청에.

---

## ⚠️ 공유 지점 경고

- 🔴 **토큰 함수 다섯** — 운영 링크 폼이 지금 쓰는 함수다. 조각 1 이 둘(저장·제출), 조각 2 가 넷(조회 제외), 조각 9 가 다섯을 재정의한다. 각 조각 뒤 **옛 폼으로 저장·제출 한 번**을 양성 대조로.
- 🔴 **`dev/sales/orient.html` 작성 코드** — 조각 6 이 옮겨 온 뒤부터 두 벌. 그 기간에 다른 작업이 작성 부분을 고치면 두 곳을 함께(의심 4 의 사본 목록). 끼워 넣기 모드(`bootEmbedQuote`·`embedAllowedOrigins`)는 관리자·브랜드 공용 — 지우지 않는다.
- **`brand-shell.js`** — 조각 5(준비 중 등록 삭제)·6(떠나기 전 확인 장치)이 만진다. 확인 장치는 브랜드 정보·멤버·마이페이지 페이지의 이동에도 걸리므로 그 페이지들이 열려 있을 때 확인이 안 뜨는지(장치가 비어 있으면 통과) 확인.
- **`brand-app.js`** — 조각 5(주소 값 옮기기)·9(새 카드 화면). 설정·재설정·초대 링크 착지 순서를 건드리지 않게 「착지 갈래들 뒤, 해시 라우팅 앞」.
- **`dev/build.sh`·`dev/brand/index.html` 원본 태그** — 조각 5·6(빌드 목록·태그) · 9(bw01-09 카드 마크업). 태그 지우는 정규식이 일반식인지 착수 때 확인(브랜드 빌드는 `BRAND_*_FILES` + 원본 태그 정규식 두 곳 — `CLAUDE.md`).
- **`dev/lib/storage.js`** — 조각 10 만(핫스팟). 브랜드 화면은 이 파일을 안 쓴다.
- **196·464 캠페인 등록 함수** — 바꾸지 않지만 `version` +1 이 브랜드 저장 충돌을 만든다(의심 6).
- **`notify-orient-submitted` 웹훅** — 바꾸지 않지만 브랜드 저장이 새 칸(`last_edited_at`)을 바꿀 때마다 제출된 시트면 웹훅이 한 번 불린다. 게이트 ①(`last_submitted_at` 그대로면 건너뜀)이 거른다 — 524 머리말과 같은 이유로 새 비용 없음.
- **`my_brand_role`·`is_my_brand`(530)** — 판정을 바꾸면 일곱 함수·업로드 허가가 함께 바뀐다.
- **`get_my_brand_login_state`·`refreshBrandLoginState`** — `not_found` 뒤 판정을 다시 받는다.

---

## 🧭 배분 제안

- **개발 1명이 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 11** 순서대로. 데이터베이스 조각(1~4, 9 의 닫기)은 이 세션에서만.
- **조각 10 은 두 번째 세션이 조각 3 이 개발서버에 들어간 뒤 동시에** 해도 된다(파일이 안 겹친다 — 단 `storage.js` 를 만지는 다른 작업이 없을 때). 혼자면 7 과 8 사이에.
- 조각 1 은 결정 14(「운영 먼저」)에 따라 **가장 먼저 단독 병합 요청 + 운영 적용**까지 끝내고 2 로 간다.

---

## 기획에게 넘길 것 (질문 아님)

1. 피그마 bw04-00e 탭 목록의 「완료」를 「만료」로, 00e·05a·05b 의 「~요」체 문구를 「~습니다」체로.
2. 모바일 그림이 없는 화면(실패·빈 상태·만료 안내·읽기 전용·확인·견적서·완료·시딩 작성·입력 오류)은 **웹 그림을 세로로 쌓은 것**으로 개발이 만든다 — 피그마에 「웹을 따름」 한 줄을 적어 달라.
3. bw04-91 ⑦(저장 거부 때 그 자리에서 01b·01c 로 바꿀지) — 개발 기본은 지금 폼처럼 아래 바 글자만. 바꿀 거면 피그마에.
4. 결정 8(「모달 맨 아래 네 칸」)에 따라 bw04-01·02 그림에 그 칸을 더해 달라.
5. bw04-01b 문구에 「이미 제출하신 내용은 담당자에게 전달되어 있습니다」를 넣을지(의심 12).
6. 관리자 발급 경고 ⓐ 문구에 「서베이 신청 상태가 자동으로 넘어가지 않습니다」를 붙일지(의심 2).
7. a04-95 제출 알림 메일에 「제출한 사람」 줄을 넣을지(기본값 10 — 넣으면 웹훅 함수 배포가 필요).
8. 사양서 13-1 「현재 상태」의 제출 원본 번호·「재현 안 함」 고치기(위 stale 점검 1·2), 16-4 「오리엔시트 작성 경로」에 「가려던 시트」 장치(주소 값 두 가지) 반영.
9. 「볼 수 없는 오리엔시트」 토스트 문구와 bw01-09 「브랜드 페이지 로그인」 뒤의 흐름을 bw04-90 모음에.
10. 브랜드 화면 문구의 「발행」 두 곳(bw04-01c 진행 단계 「캠페인 발행」 · bw04-05 토스트 「발행 전까지」)을 브랜드 말 「캠페인 등록」으로 바꿀지(사양서 13-3 5번은 브랜드 쪽을 「캠페인 등록」으로 가름).

---

## 구현 결과

(개발 세션이 채운다 — 조각별 병합 요청 번호 · 실제 마이그레이션 번호 · S4 조회 결과 · 작업표와 달라진 점)

| 조각 | 병합 요청 | 실제 결과 |
|---|---|---|
| 1 | #2110 | 마이그레이션 **538** `538_orient_deadline_keep_submitted.sql` — 개발·**운영 적용 2026-10-16**(운영: 적용 전 523 칸 확인 → 적용 → 두 함수에 새 갈래·538 표시 true, 권한 맨 앞 `=X/` 없음·`anon` 유지). ⚠️ 작업 1 주의의 「적용 직후 운영 링크 폼에서 저장 한 번」은 **하지 않았다** — 운영 시트의 작성 링크는 실제 브랜드 것이라 시험 저장을 하지 않기로 했고, 함수 본문은 524 와 IF 조건만 달라 개발서버 시험으로 갈음. 운영 브랜드가 다음에 저장할 때 오류 로그로 본다. 개발 시험: 제출 시트 기한 뒤 저장·제출 모두 `expired` 거부 + 상태 `submitted` 유지 / 작성 중 시트만 `expired`. 524 대비 바뀐 줄은 IF 조건 두 곳·주석뿐. S4 운영 조회(2026-10-16): ①기한 결함 피해 **0건**(되돌리는 패치 불필요) ②기한 안 옛 구조 시트 **3건 — 모두 「제출됨」**(마이블루데이즈 2건 기한 10/16·10/22, epii 1건 10/17 — 한국 시각 +9시간. 10/16 시트는 운영팀 확인 결과 지난달 진행 끝난 건). 출시 전에 모두 기한이 지나므로 결정 4 전제(출시 때 옛 구조는 만료·등록만) 유지. 단 이 셋은 제출 뒤 기한이 지나는 시트라 **조각 1 이 운영에 들어가기 전에 기한 뒤 저장 시도가 오면 「만료」로 바뀌어 캠페인 등록이 막힌다** — 조각 1 을 서둘러 운영에 넣는 근거 |
| 2 | | |
| 3 | | |
| 4 | | |
| 5 | | |
| 6 | (이번 병합 요청) | 새 `dev/js/brand-orient-form.js`(orient.html 새 구조 폼 사본 — `orient.html` `cardHtmlNew` 위에 「두 곳을 함께」 주석) + `brand-shell.js` 떠나기 전 확인 장치(`registerBrandLeaveGuard(fn, {needsAsk})`·`brandGuardHashChange`·`onBrandSessionLost`·`onBrandShellHidden`) + `brand-app.js` 주소 이동·`SIGNED_OUT` 연결 + `brand/index.html` DOMPurify 3.1.6. 로컬 확인(개발 DB): 리뷰어 O001·시딩 O006(이번에 심음 — 정리 대상 `aaaaaaaa-…06` 추가) 열기 · 큐텐 불러오기(상품번호 칸·「불러온 값으로 바꾸기」·판매가 확인) · 자동 저장 · 두 탭 충돌(bw04-01e) · 충돌 중 브랜드 바꾸기·메뉴 이동 확인(bw04-13) · 「새로고침」 뒤 사본 되살리기 · 필수 칸 안내 · 신규 시트는 열어도 「신규」 유지 · 모바일 폭(393 끼움 창) 전체 화면. **작업표와 다른 점**: ①웹 어두운 막은 본문만 덮는다(좌측 메뉴를 덮으면 bw04-13 으로 갈 길이 없다 — 기획 확인) ②제출됨·만료·등록·옛 구조 갈래는 조각 7 전까지 「준비 중」 토스트(제출됨은 작성 모달 + 「이미 제출」 안내로 연다) ③「작성 완료」는 필수 칸 검사까지만(확인 화면은 조각 7) ④주소 칸은 값이 바뀌었을 때만 큐텐을 부른다(원본 폼은 칸을 지나가기만 해도 다시 불러 판매가 확인 창이 또 뜬다 — 원본 폼 결함, 그대로 둠) ⑤저장 중 「바꾸기」는 진행 중 저장을 끝낸 뒤 사본·마지막 저장(리뷰 지적), 탭 닫기 때 저장 중이면 사본에 `inflight` 표시 ⑥업로드 시험(파일 고르기 창)은 브라우저 도구로 못 해 조각 8 로. 피그마와 다르게 둔 문구는 병합 요청 본문 「기획 확인 필요」 |
| 7 | (이번 병합 요청) | `brand-orient-form.js` 안에 화면 넷(작성·확인 `#boConfirm`·견적 `#boQuote`·완료/등록 `#boDone`)과 화면별 아래 바(`_bofShowScreen`) + 작은 안내 모달(`_bofNoticeModal` — 01b·옛 구조). 견적서는 `orient.html ?embed=quote` 를 끼워 넣는다(`_bofMountQuote` — 관리자 `osOpenQuoteDoc` 와 같은 순서·출처 판정 사본 `_bofQuoteUrl`), 인쇄는 새 탭. 제출 `submit_my_orient_sheet` — orient.html `submitSheet` 규칙 그대로(자동 저장 대기·서버 키 보존·견적 세트·거부 12종). 로컬 확인(개발 DB): 시딩 O006 작성 → 확인 → 견적서(끼워 넣기) → 확인 체크 없이 제출 시 작성 칸으로 돌아가 빨간 표시 → 제출 → 05 + 토스트 → 「내용 수정하기」로 고치고 닫음 → 다시 열면 05b·목록 「수정 중」 · O002 만료 → 01b · O003 등록 → 01c(「캠페인 보기 ›」 → 캠페인 메뉴) · O004 옛 구조 → 안내 · O001 판매가에 글자 → 04a 이유별 문구. **O006 은 이제 제출됨(작성본 있음)** — 정리 대상. **작업표·피그마와 다른 점**: ①「꼭 확인해 주십시오」는 「작성 완료」가 아니라 「제출하기」에서 막는다(orient.html 규칙 — 금액부터 보게. 피그마 bw04-01a 그림은 「작성 완료」) ②01b 에 「담당자에게 문의」 단추 없음(결정 9) ③옛 구조 안내 모달은 피그마 그림 없음 ④04a 는 두 갈래 — 연결 오류(피그마 문구 + 「다시 불러오기」 + 토스트) / 계산은 됐으나 견적 없음(`quote_error` 이유별 문구) ⑤토스트 앞 기호(✓·!)는 공용 토스트라 이번에 안 넣음 ⑥01f(서버 글자 수 거부)는 화면이 1,000자에서 자르므로 화면으로 재현 못 함 — 코드만 ⑦진행 단계는 01c 도 「제출」만 강조(피그마 그대로) ⑧견적서 창 높이 고정(웹 820·모바일 640, 안쪽 스크롤) |
| 8 | (이번 병합 요청) | 로컬 화면(개발 DB)으로 처음부터 끝까지 확인 — **대표**(zz-b2-owner): 리뷰어 O001 구매 가이드·@cosme·모집 시작일·리뷰 가이드·**파일 업로드**(`orient-images/s/{시트 번호}/난수.jpg` 저장 확인) → 확인 → 견적서(상품 결제비·송금 수수료·모집비·옵션 줄) → 제출 → 완료 · 「인쇄 · PDF」 새 탭에 같은 견적서 · 시딩 O006 제출 · 05b · 01b · 01c · 옛 구조 · 04a(조각 7 기록) · 모바일 폭(작성·완료). **옛 링크 폼(로컬 `sales/orient.html?token=`) ↔ 새 모달 번갈아 저장**: 양쪽 모두 충돌 안내, 「새로고침」 뒤 사본 되살리기 · 토큰 폼 저장은 저장자 계정이 없어 마지막 저장자가 「다른 사람이」로 보인다. **멤버**(zz-b2-second): 대표가 저장한 시트에 「시험대표님이 2분 전에 수정했습니다」 · 멤버 재제출 → 2차 견적 · 목록 최근 수정 「시험멤버」·「수정 중」 사라짐 · 연결된 다른 브랜드(Aroma Farm 시험) 목록 0건 화면 · 연결 안 된 브랜드(하루담) 시트 주소 → 「이 오리엔시트를 볼 수 없습니다.」 · 다른 연결 브랜드의 시트 주소 → 브랜드가 바뀌고 그 시트가 열림. **고친 것**: 제출 직후 머리의 마지막 저장자 줄이 옛 사람으로 남던 것(`_bofSubmit` 성공 갈래에 `_bofPaintLastEditor(st, false)`). **확인 못 한 것**: 서버의 1,000자 거부(01f — 화면이 먼저 잘라 재현 불가) · 업로드 10MB 초과·5개 초과(조각 6 코드 그대로) · 실제 iOS 키보드. **정리(2026-10-19)**: 시험 시트 6개(`aaaaaaaa-…01~06`) 삭제(남은 0 확인, 딸린 표는 메모 하나 — 연쇄 삭제) · 업로드 파일 3개(`orient-images/s/aaaaaaaa-…01/` — 오늘 1 + 조각 4 의 2) 대시보드에서 폴더째 삭제. 조각 9 시험은 새 시험 시트를 심어야 한다 |
| 9 | | |
| 10 | | |
| 11 | | |

---

## 참고한 파일 (절대 경로)

- /Users/choiwooyoung/kemo-브랜드포털/docs/specs/2026-07-15-brand-portal.md
- /Users/choiwooyoung/kemo-브랜드포털/docs/specs/2026-10-16-brand-info-page-breakdown.md
- /Users/choiwooyoung/kemo-브랜드포털/supabase/migrations/524_orient_sheet_draft_functions.sql (결함: 164~171줄·316~323줄 / ①-5: 433~440줄)
- /Users/choiwooyoung/kemo-브랜드포털/supabase/migrations/430_orient_quote_preview.sql · 489_orient_tier_fees_option_fees.sql · 428_orient_lookup_gate.sql · 200_orient_upload_bucket_and_policy.sql(235~238줄 `TO anon`) · 196_mark_orient_card_consumed.sql(125줄) · 464_orient_link_existing_recruit_type_check.sql · 530_brand_member_base.sql(282~322줄) · 536_brand_profile_functions.sql · 526_brand_accounts_base.sql(`password_set_at`)
- /Users/choiwooyoung/kemo-브랜드포털/supabase/functions/qoo10-product-lookup/index.ts · notify-orient-sheet/index.ts · notify-orient-submitted/index.ts
- /Users/choiwooyoung/kemo-브랜드포털/dev/sales/orient.html · dev/js/admin-orient.js · dev/js/admin-brand.js · dev/lib/storage.js · dev/js/brand-core.js · dev/js/brand-shell.js · dev/js/brand-app.js · dev/brand/index.html · dev/build.sh
- /Users/choiwooyoung/kemo-브랜드포털/docs/email-templates/orient-sheet-invite.html
- 피그마 설명 원문: /private/tmp/claude-501/-Users-choiwooyoung-kemo------/75794094-12eb-4601-b663-82035aa40dc0/scratchpad/figma-57-3631/desc.txt (bw04-96·a04-95·bw01-09 설명은 이 파일에 없다 — 착수 때 피그마에서 직접 확인)
