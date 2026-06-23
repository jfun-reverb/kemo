# 브랜드 셀프 오리엔시트 작성·수집

**작성일:** 2026-06-18
**작성 주체:** 기획 세션
**성격:** 기획 초안. 사용자와 핵심 설계 9종 확정 완료. 개발 착수 전 PR 분할·매핑 세부 재확인 권장.
**관련 베타 계획:** 오리엔시트는 베타 서비스 계획 중 **우선 착수 1순위 항목**. 베타 전체 로드맵·기획 방향은 허브 `docs/specs/2026-06-18-beta-launch-plan.md` 참조.
**참고 양식:** 기존 구글 시트 오리엔시트(2026-06-18 내용 확인 — 시딩/리뷰어 진행 종류별 블록 구조).

---

## 0. 한 줄 요약

브랜드사(광고주)에게 **로그인 없는 토큰 링크**를 보내 웹에서 캠페인 콘텐츠 상세(오리엔시트)를 **한국어로** 작성·제출하게 하고, 관리자가 그 내용을 **자동 채움(prefill)**으로 모집 건(캠페인) 등록 폼에 옮겨 **일본어를 보완한 뒤 발행**한다.

---

## 1. 현재 상태 (planning.md 규칙 A — 검증 완료)

### 관련 코드·DB·UI 진입점
- **익명 폼 제출 함수 선례**: `submit_brand_application()` — `supabase/migrations/087_submit_brand_application_with_brand_id.sql:62-216`. `SECURITY DEFINER` + `SET search_path=''` + `GRANT ... TO anon`. 입력 검증·브랜드 정규화 후 INSERT·번호 반환. 클라 호출부 `dev/sales/reviewer.html:1664`. (REVERB 규칙: 익명 INSERT는 직접 INSERT 금지[42501], 반드시 보안 정의자 함수로 감쌈)
- **토큰 익명 함수 선례**: `unsubscribe_by_token(p_token uuid)` — `supabase/migrations/140_influencer_unsubscribe_token.sql:159-203`. UUID(범용 고유 식별자) 토큰, `REVOKE FROM PUBLIC` 후 `GRANT TO anon`, 미매칭 시 `{success:false}` 반환(계정/자원 열거 방지), 멱등 처리.
- **오리엔시트 현재 처리**: `brand_applications.orient_sheet_sent_at` / `orient_sheet_sent_url` — `supabase/migrations/112_brand_app_quote_orient_urls.sql:11-13`. **지금은 관리자가 외부(구글) 시트 URL을 손으로 붙여넣는 텍스트 칸일 뿐, 시트 내용을 시스템이 보유하지 않음.** 광고주 신청 상태 10단계 중 `orient_sheet_sent`(오리엔시트 전달) 단계가 이미 존재.
- **광고주 신청 익명 폼(sales)**: `dev/sales/*` 가 원본, `sales/*` 가 배포본(빌드 없이 정적 배포, 별도 Vercel 프로젝트 Root=`sales/`). `cleanUrls` + catch-all rewrite 로 `/reviewer` → `reviewer.html`. 검색 노출 차단(`noindex`), 한국어 단일 UI.
- **캠페인 등록 폼**: 진입 `switchAdminPane('add-campaign')`/`('edit-campaign')` — `dev/js/admin.js:690, 2186`. 신규 처리 `addCampaign()` `dev/js/admin.js:2464`. 필드 ID 패턴 `newCamp*`(`newCampTitle`/`newCampProduct`/`newCampSlots`/`newCampDeadline`/`newCampBrandId`/`newCampSourceAppId` 등). 채널 복수 체크박스, 콘텐츠 가이드 Quill 리치텍스트 3필드.
- **신청↔캠페인 연결**: `campaigns.source_application_id` 직접 set(`dev/js/admin.js:1751, 2505`) + 별도 `link_campaign_to_application` 함수(채번 재발급, `supabase/migrations/121_*`).

### 이 제안과 충돌 가능성 있는 기존 동작
- **`source_application_id`는 신청이 있을 때만 채워지는 구조** → 결정①(신청 없이 생성)에서는 오리엔시트→캠페인 연결 키가 부족. **별도 테이블의 `campaign_id` 역참조로 해소**(§4).
- **`brand_applications.products jsonb`는 견적용(가격·수량)** — 오리엔시트의 제품 정보(콘텐츠용)와 용도가 다름. 같은 행에 두 종류를 섞으면 혼동 → **별도 테이블로 분리**(§4).
- **그 외 충돌 없음 — 확인 완료**: 토큰 익명 함수 패턴, 캠페인 폼 자동 채움 진입점은 기존 구조에 그대로 얹힘.

### 미해결 백로그·관련 작업
- 브랜드 운영 페인 재설계(`docs/specs/2026-05-13-brand-ops-redesign.md`), 브랜드↔회사 연결(`docs/specs/2026-06-04-brand-company-linking.md`) — 같은 brand-applications/companies 영역. 신규 관리자 페인 추가 시 사이드바·라우팅 충돌 점검 필요.

---

## 2. 의심·경우의 수 (planning.md 규칙 B — 반대론자 모드)

1. **[데이터/공백] 신청 미연결 오리엔시트의 견적·제품 정보 공백** — 신청 없이 만들면 견적·수량 데이터가 없음. 발행 시 모집인원(`slots`)·리워드를 브랜드가 오리엔시트에 적은 값으로만 채워야 함. 값이 비거나 비현실적(모집인원 99999)이면 깨진 캠페인 생성 → **관리자 검토·발행 게이트 필수**.
2. **[기술/매핑] 채널별 게시 가이드 다중 vs 캠페인 단일** — 오리엔시트는 채널(X·인스타, 피드·릴스)마다 게시 가이드를 따로 받는데, 캠페인 콘텐츠 가이드는 단일 리치텍스트. 합쳐 주입 시 길이 폭주·서식 깨짐 위험 → **§5 매핑 (a)안**.
3. **[보안] 토큰 유출** — 링크가 메신저·메일로 전달되다 유출되면 제3자가 브랜드 명의로 작성·수정 가능. UUID라 추측은 불가하나 유출 자체는 못 막음 → 만료·발행 후 잠금·읽기전용이 방어선, 발행 책임은 관리자 검토에.
4. **[동시성] 한 토큰 다중 탭·다중인 동시 편집** — 담당자 2명이 같은 링크를 동시에 저장하면 마지막이 앞을 덮음 → 낙관적 락(`version`) 충돌 감지 + UX 안내.
5. **[UX·필수] 브랜드 입력 이탈** — 폼이 길다(모집·브랜드·제품·채널 가이드). 비로그인 브랜드 중간 이탈 시 전부 날아감 → **서버 임시저장 + 진행 피드백 필수**. 한국어 비즈 용어(결과발표·메가와리)를 일본 현지 담당이 작성하면 이해도 문제(작성자 통상 한국 영업 담당 전제).
6. **[권한/i18n] 발행 시 일본어 보완 누락** — 브랜드는 한국어만 입력 → 관리자가 일본어 보완을 빼먹고 발행하면 일본 인플루언서 화면에 한국어 노출(운영 사고) → **§7 일본어 필수 차단 게이트**.

### 의도 모호점 (확정)
- "오리엔시트" 단어가 ① 이번 신규 작성 폼 ② 기존 `orient_sheet_sent_url`(외부 시트) 둘을 가리킴 → **공존**으로 확정(결정⑨).
- "마케팅 동의 4종"이 브랜드 항목인지 인플 항목인지 모호 → **인플 신청 동의 항목으로 보고 오리엔시트에서 제외**(결정⑦).

---

## 3. 확정 설계 결정 (사용자 확인 완료)

| # | 항목 | 결정 |
|---|---|---|
| ① | 신청 연결 | 오리엔시트는 **브랜드(`brands.id`) 기준**. 기존 광고주 신청(`brand_applications.id`) 있으면 연결(선택), 없으면 신청 없이도 생성(둘 다 지원) |
| ② | 작성 언어 | **브랜드는 한국어만** 작성·제출. 일본어는 관리자가 캠페인 발행 단계에서 보완. 오리엔시트 폼은 한국어 단일 입력 |
| ③ | 모집 건 생성 | **자동 채움(prefill)** — 오리엔시트 내용이 캠페인 등록 폼 칸에 자동으로 들어가고, 관리자가 검토·수정·일본어 보완 후 발행 |
| ④ | 단위 | **오리엔시트 1장 = 제품 1개 = 모집 건 1개 (1:1)** |
| ⑤ | 데이터 구조 | **전용 테이블 신규**(별도 테이블). 결정①이 "기존 신청 테이블에 칸 추가"와 정면 충돌(빈 껍데기 신청 유령화)하므로 별도 테이블이 유일하게 깔끔 |
| ⑥ | 작성 폼 위치 | **`sales` 사이트(별도 프로젝트)에 토큰 링크 페이지** — 익명 제출·한국어 단일 UI·검색 차단을 이미 갖춤 |
| ⑦ | 마케팅 동의 4종 | **오리엔시트에서 제외** (인플 신청 동의 항목) |
| ⑧ | 일본어 게이트 | **필수 차단 + 권한자 긴급 발행 우회** — 일본어 필수 칸 미입력 시 발행 버튼 차단. 단 **campaign_admin(광고 관리 권한자) 이상**이 사유 입력 후 긴급 발행 가능 + 그 사실 기록. campaign_manager는 우회 불가 |
| ⑨ | 세부 추천값 | 링크 만료 **30일** / 제출 후 **발행 전까지 재편집 허용** / 기존 외부 시트 칸 **공존** / 채널 가이드 **단일 리치텍스트로 합쳐 주입** / "브랜드 소개·어필"은 **콘텐츠 가이드에** |

---

## 4. 데이터 모델 (전용 테이블)

> 마이그레이션 번호는 개발 세션이 생성 시점에 확정(플레이스홀더). 아래는 구조와 상대 순서만.

### 신규 테이블 `orient_sheets`
```
orient_sheets(
  id              uuid PK DEFAULT gen_random_uuid(),
  brand_id        uuid NOT NULL REFERENCES brands(id),       -- 결정①: 브랜드 기준
  application_id  uuid NULL REFERENCES brand_applications(id),-- 결정①: 신청 있으면 연결, 없으면 NULL
  token           uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(), -- 로그인 없는 작성 링크 식별자
  form_type       text NULL,                                  -- reviewer | seeding (참고용, 신청에서 승계 가능)
  data            jsonb NOT NULL DEFAULT '{}',                -- 오리엔시트 전체 내용(§6 구조)
  status          text NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft','submitted','consumed','expired')),
  campaign_id     uuid NULL REFERENCES campaigns(id),         -- 결정④: 1:1 발행된 캠페인 역참조
  token_expires_at timestamptz NULL,                          -- 결정⑨: 발급 +30일
  submitted_at    timestamptz NULL,
  consumed_at     timestamptz NULL,
  version         integer NOT NULL DEFAULT 0,                 -- 낙관적 락(동시 편집 충돌 감지)
  created_by      uuid NULL REFERENCES auth.users(id),        -- 발급한 관리자
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
)
```
- 인덱스: `token` UNIQUE, `brand_id`, `application_id`, `status`, (선택) `campaign_id`.
- 행 단위 보안 정책(RLS): SELECT/CUD 는 관리자만(`is_admin()` / 발급·발행은 `is_campaign_admin()` 이상). **익명(anon)은 테이블 직접 접근 0** — 토큰 함수로만 접근.
- 상태 전이: `draft`(작성 중) → `submitted`(브랜드 제출) → `consumed`(캠페인 발행됨, 잠금) / `expired`(만료). 발행 전(`draft`/`submitted`)까지 브랜드 재편집 허용(결정⑨).

### 기존 `brand_applications.orient_sheet_sent_url` 와의 관계
- **공존**(결정⑨). 외부 구글 시트 링크 칸은 그대로 두고, 내부 오리엔시트는 `orient_sheets` 별도 관리. (향후 발행 시 내부 링크로 채우는 보조 연결은 선택 — 이번 범위 밖.)

---

## 5. 오리엔시트 필드 ↔ 캠페인 필드 자동 채움(prefill) 매핑

| 오리엔시트 필드 | campaigns 대상 | 비고 |
|---|---|---|
| 모집인원 | `slots` | 숫자 파싱. 비거나 비현실값이면 관리자 보정 |
| 신청기간(모집) | `recruit_start`/`deadline` | 날짜 파싱. 자유텍스트면 검토 단계 보정 |
| 게시기간 | `submission_end`(+구매/방문) | recruit_type 분기 |
| 결과발표일 | (캠페인 미대응) | `data`에 보관, 관리자 참고만 |
| 브랜드명 | `brand`/`brand_ko` | 일본어 `brand_ja`는 관리자 보완(결정②) |
| 브랜드 소개·어필 | **콘텐츠 가이드 리치텍스트**(결정⑨) | 캠페인에 전용 칸 없음 |
| 카테고리 | `category` | lookup 매칭, 실패 시 드롭다운 보정 |
| 제품명 | `product`/`product_ko` | 일본어는 관리자 보완 |
| 제품가격(상시/세일/메가와리 3종) | `product_price`(단일) | **3종 → 1칸.** 대표 1개 + 나머지 텍스트 보존 |
| 판매 URL(Qoo10/Amazon/한국 3종) | `product_url`(단일) | **복수 → 1칸.** 대표 1개 + 나머지 텍스트 |
| 제품 소개·소구 포인트 | 콘텐츠 가이드 리치텍스트 | Quill |
| **게시 가이드(채널별 다중)** | 콘텐츠 가이드 리치텍스트(단일) | **(a)안: 채널별 섹션을 한 리치텍스트로 합쳐 주입** ("■ Instagram 피드 … ■ X …") |
| 필수 해시태그(최대 5) / 계정 태그 | 콘텐츠 가이드 본문 텍스트 | 캠페인에 해시태그 전용 구조 없음 |
| 금지 표현(NG) | `ng_items jsonb` | 채널 무관 단일 → 비교적 깔끔 |
| 첨부 이미지 예시 | `img1~8` 또는 콘텐츠 첨부 | **이미지 링크(URL) + 파일 직접 업로드 둘 다 지원**(§6 익명 업로드 보안) |
| 추가 안내 / 필독 안내사항 | `caution_items jsonb` | |
| 채널(X·인스타) | `campaigns.channel`(콤마 멀티) + `channel_match` | 1제품 다채널이라도 캠페인 1건 |

- **핵심 불일치 해소**: 채널 다중 가이드 → 단일 리치텍스트 (a)안. 3종 가격·복수 URL → 대표 1개 + 나머지 텍스트.
- **prefill 누락 필드(결과발표 등)는 `data`에 보존**해 관리자가 상세에서 열람.

---

## 6. 토큰 작성 폼 (sales 사이트)

- 라우트: `sales.globalreverb.com/orient?token=...` (또는 `/orient/<token>`). Vercel `cleanUrls`+rewrite 재사용.
- 동작:
  1. 진입 시 `get_orient_sheet(token)` 익명 함수로 현재 내용·상태 조회. 미매칭/만료/`consumed`면 안내 화면(작성 불가).
  2. 한국어 단일 폼(모집 정보·브랜드 정보·제품 정보·채널별 게시 가이드). 인플 동의 4종 없음(결정⑦).
  3. **임시저장**: `save_orient_draft(token, data, version)` — 부분 저장(`status='draft'`), 같은 링크 재방문 시 복원. 보조로 브라우저 localStorage 캐시(토큰별 키). 동시 편집은 낙관적 락으로 마지막 저장 우선 + 충돌 안내.
  4. **제출**: `submit_orient_sheet(token, data, version)` — `draft`→`submitted`, 입력 검증. 발행 전까지 재편집 가능(결정⑨).
- **모집 정보 초기값(잔여①·②)**: 진입 시 연결된 신청(`application_id`)이 있으면 `get_orient_sheet`가 신청서의 모집인원·기간 희망값을 **초기값으로 함께 반환**해 폼에 미리 채움(브랜드 수정 가능 — 견적값≠실제 모집). 미연결 건은 빈 칸 직접 입력.
- **이미지 입력(잔여①)**: 제품 이미지는 **링크(URL) 입력 + 파일 직접 업로드** 둘 다 지원. 직접 업로드는 로그인 없는 토큰 폼이므로 보안 설계 필수 — ⓐ 토큰 유효성 검증 후에만 업로드 허용(서명 URL 또는 토큰 기반 업로드 함수) ⓑ 용량·확장자(jpg/png/webp) 제한 ⓒ 전용 비공개 버킷. PR 2 범위.
- 작성자 안내 문구는 한국 영업 담당 기준(비즈 용어 OK). 진행률·"저장됨" 피드백 필수(이탈 방지).

---

## 7. 관리자 흐름

- **조회 위치**: **신규 페인 `#orient-sheets`**(또는 캠페인 영역 하위). brand-applications(신청 전용) 목록에 섞지 않음 — 신청 없는 오리엔시트가 깔때기·통계를 왜곡하지 않게(결정①). 단 신청 연결 건은 brand-applications 상세에서 "연결된 오리엔시트" 링크 노출.
- **발급**: 관리자가 브랜드(+선택적 신청) 골라 "오리엔시트 링크 생성" → `create_orient_sheet(brand_id, application_id)` → `orient_sheets` 행 + 토큰 생성 → 링크 복사/전달.
- **자동 채움 연결**: 오리엔시트 상세에서 "이 내용으로 모집 건 생성" → `switchAdminPane('add-campaign')` 진입 직전 전역 prefill 객체에 매핑 결과 주입 → 신규 함수 `applyOrientPrefill(data)` 가 `newCamp*` 필드 채움. 발행 성공(`addCampaign`) 후 `mark_orient_consumed(orient_id, campaign_id)` → `status='consumed'` + `campaign_id` set.
- **일본어 발행 게이트(결정⑧·잔여③)**: `addCampaign` 또는 발행 직전 검증 — 일본어 필수 칸(`brand_ja`/`product_ko`/일본어 콘텐츠 가이드 등) 미입력 시 발행 차단 + 안내. **campaign_admin(광고 관리 권한자) 이상**이 **사유 입력 후 긴급 발행** 가능 → 우회 사실·사유 기록(컬럼 또는 audit). campaign_manager는 우회 불가.

### 신규 함수 목록 (이름·인자·권한·가드)
| 이름 | 인자 | 권한(GRANT) | 가드 | 보안 정의자 |
|---|---|---|---|---|
| `get_orient_sheet` | `p_token uuid` | anon, authenticated | 미매칭 `{success:false}`, 만료/consumed 분기 | ✅ (`search_path=''`) |
| `save_orient_draft` | `p_token uuid, p_data jsonb, p_version int` | anon | 만료·consumed 차단, 낙관적 락, jsonb 크기 제한 | ✅ |
| `submit_orient_sheet` | `p_token uuid, p_data jsonb, p_version int` | anon | draft→submitted 전이, 입력 검증 | ✅ |
| `create_orient_sheet` | `p_brand_id uuid, p_application_id uuid` | authenticated | `is_campaign_admin()` 이상, brand 존재 검증 | ✅ |
| `mark_orient_consumed` | `p_orient_id uuid, p_campaign_id uuid` | authenticated | `is_campaign_admin()`, 상태 전이 | ✅ |

- 익명 함수는 `REVOKE FROM PUBLIC` 후 명시 GRANT(140 패턴). 모두 `SECURITY DEFINER` + `SET search_path=''`(security.md 규칙).
- 긴급 발행 우회 기록용 보조 함수/컬럼은 개발 세션이 §7 게이트 구현 시 결정.

---

## 8. PR 분할 (개발서버 먼저, 시퀀셜)

> ⚠️ **병렬 금지**: PR 3·4 는 `dev/js/admin.js`(캠페인 폼 잔류 파일·핫스팟)를 건드림 → worktree 병렬 시 충돌 100%. **시퀀셜 PR**만.

- **PR 1 — 데이터 모델 + 익명 작성/제출 함수**: `orient_sheets` 테이블(마이그레이션 ①) + 토큰 익명 함수 3종(`get`/`save_draft`/`submit`, 마이그레이션 ②) + `storage.js` 함수. 화면 없음. **마이그레이션 2개, ①이 ②보다 먼저.**
- **PR 2 — 브랜드 작성 폼**: `dev/sales/orient.html` + Vercel rewrite. 폼·임시저장·제출·만료/잠금 안내.
- **PR 3 — 관리자 발급·조회**: 신규 페인 `#orient-sheets`, 발급·발행 함수(마이그레이션 ③), 목록/상세, brand-applications 상세에 연결 링크.
- **PR 4 — 자동 채움 매핑 + 발행 게이트**: `applyOrientPrefill`, add-campaign 진입 연결, `mark_orient_consumed`, 일본어 발행 게이트(결정⑧). **가장 깨지기 쉬운 매핑은 마지막.**

마이그레이션 총 3개(①테이블 → ②익명 함수 → ③관리자 함수). 번호는 개발 세션이 생성 시점 확정 후 「구현 결과」에 기록.

---

## 9. 약관·정책 영향 (policy.md 체크)

- **새 개인정보 수집 아님**: 오리엔시트는 브랜드(법인 담당자)가 작성하는 **캠페인 콘텐츠 정보**라 인플루언서 개인정보 수집과 무관. 담당자 연락처는 기존 `brand_applications`/`brands`에 이미 있음.
- **단 작성 폼이 외부(브랜드)에게 노출되는 신규 접점**이므로, 개발 단계에서 `/약관확인` 1회 실행 권장(브랜드 담당자 입력 정보 처리 고지 필요 여부 확인). 현재 판단으로는 약관 본문 개정 불요.

---

## 10. 잔여 3종 — 확정 (2026-06-18 사용자 결정)

| # | 항목 | 확정 | 영향 |
|---|---|---|---|
| ① | 이미지 입력 | **링크(URL) + 파일 직접 업로드 둘 다 지원** | PR 2에 익명 업로드 보안(토큰 검증·용량/확장자 제한·전용 비공개 버킷) 추가. §5·§6 반영 |
| ② | 모집인원·기간 | **신청 연결 건은 신청서 값 자동 표시(미리 채움·수정 가능), 미연결만 직접 입력** | `get_orient_sheet`가 연결 신청의 모집 희망값을 초기값으로 함께 반환. §6 반영 |
| ③ | 긴급 발행 우회 권한 | **campaign_admin(광고 관리 권한자) 이상**. campaign_manager는 불가 | §7 발행 게이트 가드 = `is_campaign_admin()`. 결정⑧·§3·§7 반영 |

→ 추가 미결정 없음. 개발 PR 1부터 착수 가능.

---

## 11. 부록 A — `data` jsonb 스키마 (PR2 ↔ PR4 공유 단일 소스)

> PR2 작성 폼의 입력칸 ↔ `orient_sheets.data` 키 ↔ PR4 자동 채움(prefill) 매핑이 **같은 키 이름**을 쓰도록 여기서 고정한다. PR4는 이 부록을 읽어 `applyOrientPrefill(data)`를 작성한다. 키를 바꾸면 양쪽을 함께 고친다.

```jsonc
{
  "recruit": {                    // 모집 정보 — 브랜드는 희망 모집 기간만 입력(2026-06-22 개선)
    "slots": "",                  // 모집인원 → campaigns.slots (숫자 파싱)
    "recruit_start": "",          // 희망 모집 시작(YYYY-MM-DD) → recruit_start
    "recruit_end": ""             // 희망 모집 마감 → deadline
    // post_start/end·result_date·purchase_start/end 는 브랜드 입력에서 제거(2026-06-22):
    //   게시·구매·결과 발표 일정은 관리자가 캠페인 등록 시 직접 채움. PR4 prefill 도 recruit_start/end 만 매핑.
  },
  "brand": {
    "name": "",                   // 브랜드명 → brand / brand_ko (일본어는 관리자 보완)
    "intro": ""                   // 브랜드 소개·어필 → 콘텐츠 가이드 리치텍스트
  },
  "product": {
    "name": "",                   // 제품명 → product / product_ko
    "category": "",               // 카테고리 → campaigns.category. lookup_values(kind=category) code 저장(예: beauty), 드롭다운 선택·라벨 아님(2026-06-22). PR4 무손실 매칭
    "appeal": "",                 // 제품 소개·소구 포인트 → 콘텐츠 가이드 리치텍스트
    "prices": [                   // [리뷰어 전용] 가격 복수(상시·세일·메가와리) → product_price 대표 1개 + 나머지 텍스트
      { "label": "", "value": "" }
    ],
    "urls": [                     // [리뷰어 전용] 판매 URL 복수(Qoo10·Amazon·한국) → product_url 대표 1개 + 나머지 텍스트
      { "label": "", "value": "" }
    ],
    "provide_note": "",           // [시딩 전용] 제품 제공 방식·수량 안내
    "shipping_note": ""           // [시딩 전용] 배송 관련 안내
  },
  "channels": [                   // 채널별 게시 가이드(반복 블록) → 콘텐츠 가이드 단일 리치텍스트로 합쳐 주입(§5 a안)
    { "channel": "", "guide": "" }  // channel = instagram|x|tiktok|youtube|qoo10|lips|atcosme 등, 집합은 campaigns.channel
  ],
  "hashtags": [],                 // 필수 해시태그(최대 5) → 콘텐츠 가이드 본문 텍스트
  "account_tags": "",             // 게시물에 태그(멘션)할 브랜드 자사 공식 계정 → 콘텐츠 가이드 본문 텍스트(2026-06-22 의도 명확화)
  "ng": "",                       // 금지 표현(NG) → ng_items jsonb
  "cautions": "",                 // 추가 안내·필독 → caution_items jsonb
  "images": [                     // 첨부 이미지 예시 → img1~8 / 콘텐츠 첨부
    { "type": "url", "value": "" }  // PR2: type='url' 만(링크). 'file'(직접 업로드)은 분리 PR에서 추가
  ]
}
```

- 빈 폼(첫 진입) 기본값: 위 구조에서 `prices`/`urls`/`channels`/`images`는 빈 블록 1개씩, 나머지는 빈 문자열.
- `get_orient_sheet`의 `initial_values`(연결 신청 모집 희망값)는 `data.recruit`가 비었을 때만 미리 채움(브랜드 수정 가능).

---

## 12. PR 분할 변경 (2026-06-18 개발 세션, 사용자 확정)

§8 PR2를 **이미지 입력 범위로 2분할**한다.

- **PR 2 (이 PR)** — 브랜드 작성 폼 + **이미지 링크(URL) 입력까지**: `dev/sales/orient.html` + `sales/orient.html` 복제. 4분기 진입·폼·채널 반복 블록·자동저장·낙관적 락·제출·반응형. 이미지는 `data.images[].type='url'`만. **서버 함수 추가 없음**(PR1 함수 3종 그대로 사용). vercel.json 수정 불필요(cleanUrls 자동).
- **PR 2-이미지 (분리, 후속)** — **파일 직접 업로드**: 전용 비공개 버킷(Storage 마이그레이션 1개) + 토큰 검증 함수 `validate_orient_token_for_upload` + Edge Function `upload-orient-image`(service_role 경유) + orient.html 파일 선택 UI. **이유**: PostgreSQL 함수는 Storage에 파일을 직접 쓸 수 없어(메타데이터만 생성·고아 레코드) 방식 B는 Edge Function이 필수 → 개발·운영 양쪽 배포·동기화 부담이 커 폼 골격과 분리. supabase-expert 설계 초안(버킷 정책·검증 함수·Edge Function 골격·sales 인라인 호출) 확보 완료.
- **PR 3 / PR 4** — §8 그대로(관리자 발급·조회 / 자동 채움 매핑 + 일본어 발행 게이트). 핫스팟 `dev/js/admin.js` 시퀀셜.

---

## 13. PR2 재설계 — 타입별 분기 + 4단계 위저드 (2026-06-18 사용자 확정)

PR2 작성 폼(이미 dev 배포)에 대해 사용자 요청 2건(타입별 조건 입력 / 단계별 작성)을 검토(reverb-planner)해 아래로 확정. **기존 폼 위에 얹는 점진 확장**(자동저장·낙관적 락·진입 분기 유지).

| # | 항목 | 결정 |
|---|---|---|
| A | 타입 범위 | **리뷰어·시딩 2종 먼저.** 방문형(visit)은 `orient_sheets.form_type` CHECK이 reviewer/seeding 2종이라 DB 변경·매핑 증식 동반 → **후속 분리**(베타 빠른 출시 우선). |
| B | 타입 선택 주체 | **관리자가 발급 시 지정**(PR3 `create_orient_sheet` 인자). PR2 폼은 `get_orient_sheet`가 반환한 `form_type`을 **읽어** 타입별 칸만 표시. `form_type` NULL이면 리뷰어로 폴백. |
| C | 단계 구성 | **4단계 위저드**: ①모집·브랜드 ②제품 ③콘텐츠(채널·해시태그·NG) ④이미지·안내. reviewer.html `showPage` 패턴 차용하되 **구역 `display` 토글**(별도 페이지 아님)이라 `collectData`/자동저장/낙관적 락 무변경. |
| D | 타입별 필드 | 공통=모집·브랜드·제품명/카테고리/소개·채널·해시태그·NG·이미지·안내. **리뷰어 전용**=구매 기간(`recruit.purchase_start/end`)·판매 가격(`product.prices`)·판매 URL(`product.urls`). **시딩 전용**=제품 제공 안내(`product.provide_note`)·배송 안내(`product.shipping_note`). 숨김 필드는 `collectData`의 빈값 `.filter`로 자동 제외. |
| E | 타입 선택 0단계 (조건부) | **타입 결정 주체가 조건부로 갈림.** 신청(브랜드서베이) 연결 건은 발급 시 신청서 타입 승계(`form_type` 채움) → **0단계 생략·바로 본문**. 미연결 건은 `form_type` NULL → **작성 전 0단계 타입 선택 화면**(리뷰어/시딩 카드)에서 브랜드가 선택. **판정은 `get_orient_sheet`의 `form_type` NULL 여부 하나로** — 연결 여부를 따로 보지 않음(연결인데 타입 비면 동일하게 0단계 노출, 사고 방지). 선택 시 `set_orient_form_type(token, form_type)`로 컬럼 확정. **작성 중(draft)이면 본문 「타입 다시 선택」 링크로 자유 변경**(잘못 클릭 대비 — 변경 시 이전 타입 전용 입력[가격·구매기간·제공/배송]을 비우고 `confirm` 경고), **제출(submitted) 후 잠금**(다른 값 재호출=`type_locked`). `applyType`의 NULL→reviewer 폴백은 본문 진입 방어선으로만 잔류. 0단계는 위저드 밖 별도 화면이라 단계 수(N/4) 불변. |

- **DB 변경: 익명 함수 2개** — `set_orient_form_type(p_token, p_form_type)` (마이그레이션 188 신규 + **189 잠금 완화**, GRANT anon, SECURITY DEFINER+search_path='', 토큰·만료·consumed 차단, CHECK reviewer/seeding, version 미변경). 189에서 "NULL일 때만 set"(188) → "draft면 자유 변경, submitted면 type_locked"로 `CREATE OR REPLACE`. 테이블·기존 함수 3종 무변경.
- 방문형(visit) 추가 시에만 별도 마이그레이션(`form_type` CHECK에 `'visit'` 추가) — 후속.
- §11 스키마 부록에 `recruit.purchase_start/end`·`product.provide_note/shipping_note` 추가 반영. §3 결정① "미연결=NULL"은 본 0단계 선택으로 채워짐.

---

## 구현 결과

### PR 1 — 데이터 모델 + 익명 작성/제출 함수 (2026-06-18)

**구현일:** 2026-06-18
**관련 브랜치:** `feature/orient-sheet` (PR·커밋 해시는 세션종료 시 기록)
**마이그레이션 (실제 번호 확정):**
- **186** `186_orient_sheets_table.sql` — `orient_sheets` 테이블 + 인덱스 5종 + 행 단위 보안 정책(RLS) + `updated_at` 자동 갱신 트리거(`trg_orient_sheets_updated_at`)
- **187** `187_orient_sheets_functions.sql` — 익명 토큰 함수 3종

**함수 시그니처 (확정):**
- `get_orient_sheet(p_token uuid) → jsonb` (GRANT anon, authenticated)
- `save_orient_draft(p_token uuid, p_data jsonb, p_version int) → jsonb` (GRANT anon)
- `submit_orient_sheet(p_token uuid, p_data jsonb, p_version int) → jsonb` (GRANT anon)
- `storage.js`: `getOrientSheet(token)` / `saveOrientDraft(token, data, version)` / `submitOrientSheet(token, data, version)`

### 초안 대비 변경 사항
- **추가된 것**:
  - `updated_at` 자동 갱신 트리거(`touch_orient_sheets_updated_at` + `trg_orient_sheets_updated_at`) — 기존 테이블(admin_notices·deliverables 등) 패턴과 일관성 확보(초안 §4엔 명시 없었음).
  - 외래 키 `ON DELETE` 옵션 명시: `brand_id` RESTRICT(발행된 오리엔시트 이력 보호), `application_id`·`campaign_id`·`created_by` SET NULL.
  - 186 마이그레이션에도 `NOTIFY pgrst` 추가(186 단독 적용 시 PostgREST 인식 보장).
- **빠진 것**: 없음(PR1 범위 그대로).
- **달라진 것**:
  - `save_orient_draft`가 **status를 변경하지 않음**으로 확정(초안 §6.3은 "status='draft' 유지"였으나, submitted 상태에서 임시저장 시 draft로 역전환하면 §4 상태전이도와 모순 → data·version만 갱신). reverb-reviewer P0 지적 반영.
  - `get_orient_sheet`(조회)는 **읽기 전용**으로 확정 — 만료 시 status 전환 부작용을 제거하고 반환값으로만 만료를 알림(상태 전환은 save/submit 쓰기 함수의 FOR UPDATE 잠금 하에서만). reverb-reviewer P1 지적 반영.

### 구현 중 기술 결정 사항
- 익명 함수 검증: SECURITY DEFINER + `SET search_path=''` + `REVOKE ... FROM PUBLIC` 후 명시 GRANT(140 선례). 미매칭은 `{success:false, reason:'invalid_token'}` HTTP 200(자원 열거 방지).
- 낙관적 락 3단: `FOR UPDATE` 행 잠금 + `WHERE version = p_version` + `GET DIAGNOSTICS ROW_COUNT` 0행이면 충돌 반환.
- jsonb 크기 상한 100KB(`octet_length`). 이미지는 PR2에서 링크 URL + 파일 업로드(전용 버킷)로 받으므로 `data`에는 URL 텍스트만.
- **PR3·4 인계 메모**: ① `delete_brand` RPC(마이그레이션 174)에 `orient_sheets` 카운트 체크 추가 필요(brand_id RESTRICT와 정합). ② 관리자 대리 저장이 필요하면 `save/submit_orient_sheet`에 `authenticated` GRANT 추가. ③ `create_orient_sheet`/`mark_orient_consumed`는 PR3·4에서 구현(PR1 의도적 제외).

### PR 2 — 브랜드 작성 폼 (이미지 링크까지) (2026-06-18)

**구현일:** 2026-06-18
**관련 브랜치/PR:** `feature/orient-sheet-form` → dev PR #536 (커밋 `0b6ec82`)
**신규 파일:** `dev/sales/orient.html`(원본) + `sales/orient.html`(빌드 복사본, `dev/build.sh` 3단계가 `dev/sales/*.html` → `sales/`로 복사)

**구현 내용:**
- 토큰 링크(`/orient?token=...`) 진입 → `get_orient_sheet` 익명 호출 → 4분기(정상 draft/submitted · 무효 · 만료 · 소비) 화면.
- 폼 8섹션: 모집 정보 / 브랜드 정보 / 제품 정보(가격·판매URL 반복) / 채널별 게시 가이드(추가·삭제 반복 블록) / 해시태그·계정 태그 / NG / 예시 이미지 링크(반복) / 추가 안내.
- 자동저장(debounce 1.5초) + 낙관적 락(응답 `version` 항상 흡수, `conflict` 시 자동저장 중단 + 새로고침 배너) + 「저장됨 HH:MM」 피드백 + localStorage 백업 + `beforeunload` 미저장 경고.
- 제출(`submit_orient_sheet`) → 제출됨 배너 전환, 발행 전 재편집 가능.
- 한국어 단일 UI · `noindex` · 반응형(PC/모바일, `max-width:720px`).

### 초안 대비 변경 사항
- **달라진 것**: 이미지 입력을 **링크(URL)만** PR2에 포함. 파일 직접 업로드는 **별도 PR로 분리**(§12). 이유 = PostgreSQL 함수는 Storage에 파일을 직접 쓸 수 없어(메타데이터만·고아 레코드) 토큰 검증 방식(방식 B)에 Edge Function이 필수 → 개발·운영 배포·동기화 부담 분리(`reverb-supabase-expert` 검증).
- **추가된 것**: §11 `data` jsonb 스키마 부록(PR4 prefill과 공유할 단일 소스), §12 PR 분할 변경, 채널 입력 = 추가/삭제 반복 블록(사용자 확정), `data.images[].type='url'` 구조.
- **빠진 것**: 익명 업로드 보안(버킷·검증 함수·Edge Function)은 PR2에서 제외 → 분리 PR. supabase-expert 설계 초안(버킷 정책 `orient-images` 비공개 + `validate_orient_token_for_upload` + `upload-orient-image` Edge Function + sales 인라인 호출) 확보 완료.

### 구현 중 기술 결정 사항
- sales는 `storage.js`를 빌드로 안 씀 → `orient.html`이 `SUPABASE_ENVS`·`createClient`·`rpc`를 인라인 호출(reviewer.html 패턴). `normalizeUrl`(위험 스킴 차단·https 보정)·`escAttr`(XSS 방어)도 인라인 이식.
- vercel.json 수정 불필요(`cleanUrls`가 `/orient` → `orient.html` 자동 매핑).
- reverb-reviewer GO(Critical 0). `notranslate` 클래스 20개 보강. qa skip(토큰 발급은 PR3라 실 E2E는 SQL Editor 테스트 행 후).

### PR 3 — 관리자 발급·조회 (2026-06-19)

**구현일:** 2026-06-19
**관련 브랜치:** `feature/orient-sheet-form` → dev PR (커밋은 세션종료 시 기록)
**마이그레이션:** 190 `create_orient_sheet`(발급, is_admin 가드·신청 연결 시 form_type 승계) · 191 `delete_brand` 갱신(orient_sheets 카운트 추가, 174 CREATE OR REPLACE)

**구현 내용:**
- 신규 관리자 페인 `#orient-sheets`(사이드바 **브랜드 서베이 하위**, `dev/js/admin-orient.js`). 목록(브랜드·타입·상태·발급일·작성기한·링크복사/상세) + 검색.
- 발급 모달: 브랜드 드롭다운 + 선택적 신청 연결(타입 자동 승계) + 타입 선택(비우면 브랜드 0단계 선택) → `create_orient_sheet` → 결과 모달에 작성 링크 + 복사 + 작성기한.
- 상세 모달: `data` jsonb를 §11 스키마대로 한국어 섹션 렌더(타입별 분기, draft=작성 전 안내, 이미지 링크 http/https만 허용).
- `storage.js`: `createOrientSheet`/`fetchOrientSheets`(fetchAllPaged)/`fetchOrientSheetById`/`fetchOrientSheetsByApplication`.

### 초안 대비 변경 사항
- **달라진 것**: 발급 권한 = **`is_admin()`(campaign_manager 포함 전체)** — 사용자 확정(§7 초안은 is_campaign_admin). 타입 결정 = 신청 연결 자동 승계 / 미연결 브랜드 0단계 선택.
- **빠진 것**: brand-applications 상세 "연결된 오리엔시트 링크"(§7)는 **후속 분리** — `dev/js/admin.js`/`admin-brand.js` 핫스팟 정밀 작업이라 PR3에서 제외(`fetchOrientSheetsByApplication`은 미리 추가해 둠).
- **추가된 것**: 발급 결과 링크 복사 모달, 만료 클라 판정(조회 함수가 status 미전환이라), 이미지 링크 위험 스킴 차단.

### 구현 중 기술 결정 사항
- 발급 함수 SECURITY DEFINER라 테이블 INSERT 정책(is_campaign_admin) 우회 — is_admin 가드만으로 manager 발급 허용(RLS 정책 변경 불요).
- 모달은 `ensureOrientModals`로 동적 생성(index.html 수정 최소 — 사이드바+페인만). 기존 `.modal-overlay`/`.modal-body` 클래스 재사용.
- reverb-supabase-expert 190·191 작성. reverb-reviewer GO(이미지 href 위험 스킴 차단·CLAUDE.md 동기화·fetchAllPaged 반영).

### dev 시연 개선 — 버그 2건 + 수집 항목·문구 (2026-06-22)

**구현일:** 2026-06-22
**관련 PR:** dev #549(관리자 모달 표준 구조 + 작성 폼 하단바 safe-area) · #550(발급 모달 결과 영역 표시 토글) · (카테고리 드롭다운 + 수집 항목·문구는 후속 PR)
**마이그레이션:** 없음 (전부 UI·클라이언트, `lookup_values` anon SELECT 기존 권한 의존)

개발서버에서 발급→작성→제출 전체 플로우를 브라우저로 시연하며 발견·개선:

- **개선 1 — 관리자 모달 레이아웃**: `ensureOrientModals()`가 `.modal-overlay > .modal-body`(`.modal` 래퍼 없음, 본문 `.modal-content`) 구조라 발급·상세 모달이 화면 우측에 좁게 치우쳐 표시되던 버그. 표준 관리자 모달 구조(`.modal[margin:auto;display:flex;column]` + `.modal-body[overflow-y:auto;flex:1]`, `clientErrorDetailModal` 패턴)로 교체. 발급·상세 모달 둘 다.
- **개선 2 — 작성 폼 하단 고정바 가림**: `body` 하단 여백 96px→`calc(120px + safe-area-inset-bottom)`, `.footbar` 에도 `safe-area-inset-bottom` 반영(모바일 홈 인디케이터 기기).
- **(추가 발견) 발급 모달 결과 영역 상시 노출**: `admin-orient.js`가 `classList('hidden')`으로 form/result/발급버튼을 토글했으나 **관리자 빌드에 `.hidden` 단독 규칙 없음**(복합 셀렉터만) → 토글 무효였던 기존 버그. `style.display` 직접 토글로 전환(공통 `.hidden` 규칙은 전역 영향 회피 위해 미추가).
- **개선 3 — 카테고리 드롭다운**: 작성 폼 카테고리 자유 텍스트 → `lookup_values(kind=category)` 드롭다운(`loadCategoryOptions`, anon SELECT 직접 조회·함수 0). `data.product.category`에 **code 저장**(캠페인 폼과 동일 → PR4 무손실 매칭). 관리자 상세 모달은 `fetchLookups('category')`로 code→`name_ko` 라벨 변환 표시. 현행 5종, 조회 실패 시 빈 드롭다운(자유입력 폴백 없음 — 사용자 확정).
- **개선 4 — 수집 항목·문구**: ① Step1 날짜 9개 → **희망 모집 시작·마감 2개만**(구매·게시·결과발표는 관리자가 캠페인에서 입력, §11 부록·`fillForm`/`collectData`/`clearTypeFields`/상세모달 `osSecRecruit` 동시 반영). ② 「필수 계정 태그」 → 「게시물에 태그할 계정」(placeholder·hint로 **브랜드 자사 공식 계정** 의도 명확화, `account_tags` 키 유지).

**사용자 결정(2026-06-22):** 카테고리=코드 저장·현행 5종 / 날짜=희망 모집 기간만 / 계정 태그=브랜드 자사 공식 계정.

### PR 5 — 발급 진입점·서베이 prefill·신청목록 열 (2026-06-22)

**구현일:** 2026-06-22
**관련 PR:** dev #552(단계1~4) + 후속 커밋(단계5)
**마이그레이션:** 192 — `create_orient_sheet` 3인자 DROP → 4인자(`p_product_idx` + 서버 prefill + 반려 제품 차단)

**구현 내용:**
- **발급 함수 확장(192)**: `p_product_idx` 추가. 신청+제품 인덱스 있으면 서버가 `brand_applications` 직접 읽어 `data` prefill(brand_name→`data.brand.name`, products[idx].name→`data.product.name`, reviewer면 url→`urls`/price→`prices`). 반려(`products[idx].status='rejected'`) 제품은 `reason:'product_rejected'` 차단. 기존 3인자 호출은 `p_product_idx` NULL → prefill 없음(동작 보존).
- **발급 진입점 3개**: ①`#orient-sheets` 「신규 발급」(유지·자유 선택) ②서베이 신청 목록 더보기 「오리엔시트 링크생성」(`osIssueFromApplication` → `_brandApps` 캐시에서 신청·브랜드·제품·타입 컨텍스트 주입 + 제품 선택 행) ③브랜드 상세 모달 「오리엔시트 발급」(`osOpenCreate({brandId,lockBrand})`, 비-서베이 빈 폼). `osOpenCreate(opts)` 파라미터화로 한 모달 재사용·진입 시 컨텍스트 초기화.
- **신청 목록 「셀프 오리엔시트」 열**: `renderSelfOrientCell`(신청 단위 요약 — 최근 상태 + 추가 건수, 만료 클라 판정). 목록 로드 시 `fetchOrientSheets` 1회 조회 후 `_orientByApp` 그룹(N+1 회피).
- **(후속 통합, 2026-06-22)**: 위 「셀프 오리엔시트」 + 기존 「오리엔트 전달」(구글시트 외부 URL `orient_sheet_sent_url`) **2열을 1열 「오리엔시트」로 통합**(`renderOrientCombinedCell` — 한 셀 2줄: 「시스템」 상태+건수+작성링크 복사/열기 / 「구글시트」 URL 열기·✎수정). 구글시트 줄만 `.brand-app-orient-cell` 로 감싸 인라인 ✎ 편집이 시스템 줄 보존. **데이터 무변경(마이그 0)**. 사용자 결정(2026-06-22): 한 곳 통합·시스템도 링크 관리·발급은 더보기 유지·신청목록만(페인 제외)·별도 PR. 시스템 N건은 셀에 최근 1건만(전체는 `#orient-sheets`).

### 초안(§14) 대비 변경 사항
- **카테고리 prefill 제외**(§14-1 결정 B 정정): 서베이 `products` jsonb에 category 키가 **없음** → prefill 대상 = 브랜드명·제품명·판매URL·가격(리뷰어)만. 카테고리는 브랜드가 작성 폼 드롭다운에서 직접 선택(§13 lookup code). §14-2 "카테고리 중복" 항목도 무효.
- **반려 제품 발급 차단**(사용자 확정 2026-06-22): planner 초안은 "허용 권고"였으나 사용자가 차단 선택. 제품 단위 `status='rejected'`만 차단(NULL은 통과 — 과잉 차단 방지).
- **prefill = 서버 방식**(사용자 확정): 발급 함수가 직접 조회(클라 위조·stale 캐시 차단).
- **brands 담당자 이메일 = `primary_email`** 확정(§14-5 잔여 해소, PR6 메일용).

### 구현 중 기술 결정 사항
- `create_orient_sheet` 4인자 확장 시 기존 3인자 함수를 `DROP FUNCTION` 후 재생성(오버로드 공존 → PostgREST rpc 모호성 회피). REVOKE/GRANT/COMMENT/NOTIFY 재선언.
- `_brandApps`(admin-brand.js 전역)를 admin-orient.js의 `osIssueFromApplication`이 런타임 참조(빌드 concat 순서상 admin-brand 먼저 + `typeof` 가드).
- **E2E 검증(개발서버)**: 서베이 더보기→제품 선택("테스트제품")→발급→작성 폼 prefill(브랜드명·제품명·가격 10000) 정상, 카테고리 빈값(제외 확정대로) 확인.

### PR 5-잔여 / PR 6 (메일)
- **PR 6 — 메일 발송**: `notify-orient-sheet-link` Edge Function + 발급 시 자동 발송 + 재발송. 수신자 = 서베이 `brand_applications.email` / 비-서베이 `brands.primary_email`. `orient_sheet_sent` 상태 자동 전이는 수동 확인 여지 두기(미착수).

### PR 2-이미지 / PR 4
- 미착수. **PR 2-이미지**(파일 직접 업로드 — 버킷 + 토큰 검증 함수 + Edge Function) → **PR 4**(자동 채움 매핑 + 일본어 발행 게이트 + `mark_orient_consumed`). §8·§12 분할대로 **시퀀셜**(PR4는 `dev/js/admin.js` 핫스팟). brand-app 상세 연결 링크도 후속.

---

## 14. 발급 진입점·메일 발송·서베이 연동 보강 (2026-06-22 사용자 확정)

> PR3(발급·조회) 위에 얹는 보강. 사용자 추가 요구의 핵심: 브랜드는 **자체 시작 진입점이 없고 관리자 발급 링크로만** 작성(기존 설계와 일치 — "셀프"는 토큰 작성의 뜻), 발급을 **맥락별 진입점으로 분산** + **메일 전달** + **서베이 중복 입력 제거**.

### 14-1. 확정 결정
| # | 항목 | 결정 |
|---|---|---|
| A | 발급·조회 화면 | `#orient-sheets` 페인 = **전체 조회 허브 유지**(특히 신청 없는 비-서베이 건 조회처). 발급은 **2진입점**: ① **brand-applications(브랜드 서베이) 목록 행 더보기 "오리엔시트 링크생성"**(서베이 경로) ② **브랜드 관리(brands) 발급**(비-서베이 경로). 기존 #orient-sheets 발급 모달의 유지/흡수는 구현 시 정리 |
| B | 서베이 정보 미리채움(prefill) | 폼은 **분리 유지**(시점·목적 다름 — 서베이=견적·계약 전 / 오리엔시트=콘텐츠·계약 후). 단 서베이 연결 발급 시 `brand_applications.brand_name` + 선택 제품의 `products[i]`(name·url·price·category)를 `orient_sheets.data` **초기값으로 미리채움**(브랜드 작성 폼에서 수정 가능). 기존 모집인원·기간 prefill(§6)과 함께 |
| C | 제품 선택(1:N 해소) | 서베이 `products` 배열에서 **발급할 제품 1개를 관리자가 선택**(1장=1제품, 결정④). 제품 N개면 N번 발급. 비-서베이는 제품 정보 빈 폼 |
| D | 메일 발송 | **발급과 동시 자동 발송 + 재발송 버튼.** 수신자 = 서베이 `brand_applications.email` / 비-서베이 brands 담당자 이메일(`primary_email` 또는 `contacts` jsonb — 구현 시 확인). 발송 실패 표시·재발송. 신규 Edge Function |
| E | 신청 목록 오리엔시트 열 | brand-applications 목록에 **"오리엔시트" 열** — 연결된 `orient_sheets` 링크·상태·작성 내역(기존 PR3에서 "후속"이던 연결을 구체화). ⚠️ 기존 `brand_applications.orient_sheet_sent_url`(수동 OT URL, 마이그레이션 112)과 **별개 컬럼으로 공존**(결정⑨) — 같은 행에 두 개념이 보이지 않게 라벨 구분 |

### 14-2. 서베이 ↔ 오리엔시트 중복 분석 (결정 B 근거)
브랜드 서베이(`brand_applications`)와 오리엔시트(`orient_sheets.data`)는 **기초 항목이 중복**: 브랜드명 · 제품명 · 카테고리 · 판매 URL · 가격 · 타입(reviewer/seeding). 단 **목적·시점이 다름** — 서베이는 신청·견적(여러 제품·수량·가격), 오리엔시트는 캠페인 콘텐츠(1제품 + 소구점·채널 가이드·해시태그·NG·이미지). → 폼 통합이 아니라 **prefill로 중복 입력만 제거**(결정 B). 미리채움 항목은 §11 `data` 스키마 키와 동일 매핑.

### 14-3. 신규/변경 사항
- **메일 Edge Function** `notify-orient-sheet-link`(기존 `notify-brand-application` 패턴 차용) — 수신자 분기·작성 링크 본문·재발송. 양 서버 배포·동기화(supabase.md 메일 정책: dev는 환경만, 발송 테스트는 운영).
- **`create_orient_sheet` 확장** — 발급 시 서베이 데이터 미리채움(서버 prefill 또는 클라 수집), 선택 제품 인덱스 인자(`product_idx`). 메일 발송 트리거(발급 직후).
- **brand-applications 목록**(admin-brand.js) — 더보기 메뉴 "오리엔시트 링크생성" + "오리엔시트" 열(연결 orient_sheets 링크·상태). `fetchOrientSheetsByApplication`(PR3에서 이미 추가) 재사용.
- **브랜드 관리**(admin-company.js/admin-brand.js) — 비-서베이 발급 버튼.
- (검토) 메일 발송 시 `brand_applications.status='orient_sheet_sent'`(파이프라인 단계) 자동 전이 옵션.

### 14-4. PR 분할 (PR3 이후, 시퀀셜 — admin.js·admin-brand.js 핫스팟)
- **PR 5 — 발급 진입점·서베이 prefill·신청목록 열**: 더보기 "링크생성"(제품 선택) + brands 발급 + prefill + 오리엔시트 열. `create_orient_sheet` 확장(마이그레이션 1개).
- **PR 6 — 메일 발송**: `notify-orient-sheet-link` Edge Function + 발급 시 자동 발송 + 재발송 버튼.
- 기존 PR4(자동 채움 발행)·PR2-이미지와의 순서는 사용자 우선순위로 조정(병렬 금지).

### 14-5. 사용자 확인 잔여
- brands 담당자 이메일 컬럼 확정(`primary_email` vs `contacts` jsonb) — 구현 착수 시 supabase-expert 확인.
- 메일 발송 시 `orient_sheet_sent` 상태 자동 전이 여부.
- 비-서베이 발급 시 제품 정보가 없으므로 prefill은 브랜드명만 — 제품은 빈 폼(확인).

---

## 15. 형식 전면 재설계 — 3형식·제품 복수·가격 3칸 (2026-06-23 사용자 확정, 사내 양식 기반)

> 사내 실제 오리엔시트 양식(구글시트 2건 — Dr.deep·MEDIFORCELL, 동일 템플릿)을 확인한 결과, 기존 기획(reviewer/seeding 2종·1장=1제품·prices 자유배열)을 **게시처 기준 3형식·제품 복수·가격 3칸**으로 재설계한다. **§3 결정④(1:1)·§11(data 스키마)·§13(타입 2종)·§14-C(제품 1개=1장)를 본 절로 갱신.**
> ⚠️ **재작업 규모 큼**: 이미 dev 머지된 PR1~5가 2종·1제품·prices배열 기준이라, 데이터 모델·폼·발급·발행이 대폭 수정됨. 개발 착수 전 reverb-planner로 마이그레이션·기존 코드 영향 정밀 계획 권장.

### 15-1. 사내 양식 구조 (확인 근거)
1 브랜드 시트 = **공통 정보(브랜드·담당자 1회)** + **서비스 4탭**(Qoo10 리뷰어 / 나노 시딩 / 미들·메가 인플루언서 / X) + 각 탭 **제품 블록 N개**(복사 추가). 진행 종류 = 상시/세일/메가와리/메가포 복수 선택. 리뷰어·미들메가는 가격 3칸(상시/세일/메가와리·메가포 특가), 시딩은 가격 없음.

### 15-2. 형식 3종 (게시처 기준 — 사용자 통찰)
사용자 통찰: 4탭은 독립 4종이 아니라 **"상품 획득 × 게시처"** 조합. X·미들·메가는 별도 종류가 아니라 채널/등급값. 게시처 성격이 형식을 결정.

| 형식 | 게시처(채널) | 상품 획득 | 결과물(검수) |
|---|---|---|---|
| **가구매**(proxy_purchase) | 없음 | 샵에서 구매(영수증) | **영수증만** (게시·리뷰 없음) |
| **리뷰어**(reviewer) | 리뷰 플랫폼 — Qoo10·Amazon·@cosme·LIPS | 샵에서 구매(영수증) | 영수증 + 리뷰 |
| **시딩**(seeding) | SNS — Instagram·TikTok·YouTube·X | 브랜드 배송(제공) | 게시물 |

- **게시처 = 리뷰 플랫폼 → 리뷰어 / SNS → 시딩 / 게시 없음 → 가구매.** @cosme·LIPS도 **구매(영수증)** 형(사용자 확정 2026-06-23).
- 기존 시스템 정합: CLAUDE.md "LIPS·@cosme = monitor(리뷰어) 전용 채널". 채널 `recruit_types` 태그와 일치 → 채널이 형식 결정.
- **방문형(visit)은 오리엔시트에서 제외**(우선, 사용자 확정).

### 15-3. 단위 — 1 오리엔시트 = 1 형식 + 제품 N개
- **결정④(1장=1제품 1:1)·§14-C 대체.** 1 오리엔시트 = 한 형식 + 제품 블록 N개(사내 양식대로).
- 브랜드 정보·담당자 = **공통 1회**(brands에서 prefill, data엔 작성 시점 값 보존).
- 발행 시 **제품마다 캠페인 N개** 생성(PR4 매핑이 products 배열 순회).
- 형식이 여러 개(브랜드가 리뷰어+시딩 둘 다)면 **형식별로 오리엔시트 발급**(형식별 1장).

### 15-4. 가격 3칸 (리뷰어·가구매 / 시딩 제외)
- prices 자유 배열 → **상시가 / 세일가 / 메가와리·메가포 특가 3칸 고정**.
- **상시가 필수**, 세일가·메가와리·메가포 특가 = 선택(빈칸 허용).
- 진행 종류(상시/세일/메가와리/메가포) 복수 선택 — 가격 칸과 연동. 시딩은 가격 없음(제공).

### 15-5. 시딩 채널·등급
- 시딩 게시 채널 선택: **나노 = Instagram 한정 / 미들·메가 = IG·TikTok·YouTube·X 다채널**.
- 채널별 조건 분기: X = 140자·#PR·투고형식 / 영상(릴스·YT) = 촬영가이드.
- 등급별 가이드 깊이(나노 = 방향성 키워드만 / 미들·메가 = 상세 촬영가이드·필수내용①②③·증정품) — 등급 처리 방식은 폼 설계 시 확정(잔여).

### 15-6. 데이터 모델 변경
- `orient_sheets.form_type` CHECK: (reviewer/seeding) → **(reviewer/seeding/proxy_purchase) 3종**. 마이그레이션(CHECK 변경 + `set_orient_form_type`·발급·폼 분기 확장).
- `data` 구조: 제품 단수 → **`products` 배열**(제품 블록 N개). §11 부록 전면 개정.
- 공통 정보(브랜드명·소개·어필·공식계정 Qoo10/IG)는 brands prefill.
- **가구매 결과물(영수증만·게시 없음)** → 캠페인 `recruit_type`·결과물 흐름은 캠페인/발행(PR4) 설계에서 확정(monitor에서 리뷰 검수 뺀 변형 또는 신규 타입).

### 15-7. 영향·PR 재계획
- 본 절이 §3 결정④·§11·§13·§14-C를 갱신. 기존 구현(PR1~5)은 2종·1제품 기준이라 **상당 부분 재작업**.
- PR 재분할(개발 착수 시 planner 정밀화): ① 데이터모델(form_type 3종·products 배열·CHECK 마이그레이션) → ② 폼(형식 3종 분기·가격 3칸·시딩 채널·제품 복수 블록) → ③ 발급(형식 선택·서베이 제품 복수 prefill) → ④ 발행(N제품 매핑·가구매 결과물 흐름).

### 15-8. 사용자 확정 (2026-06-23)
형식 3종(가구매/리뷰어/시딩, 게시처 기준) / @cosme·LIPS = 구매(영수증) / 방문형 제외 / 1장 = 1형식 + 제품 N개 / 가격 3칸(상시 필수·세일·메가와리메가포 선택) / 시딩 채널(나노 IG 한정·미들메가 다채널).

### 15-9. 잔여 (사양 확정 전 추가 확인)
- 등급(나노/미들·메가) 폼 처리 방식(채널 흡수 vs 등급 필드 vs 가이드 깊이 분기).
- 가구매 캠페인의 `recruit_type`·결과물 검수 흐름(캠페인 설계 연동).
- 진행 종류 복수 선택과 가격 3칸의 연동 UI.

### 15-10. 세부 확정 — 가격·등급·가구매·진행종류 (2026-06-23, §15-9 잔여 해소)

- **가격 = 진행 종류 통합**(진행 종류 체크칸 제거): 사내 양식의 "진행 종류(상시/세일/메가와리/메가포 복수 체크)"는 **별도 칸으로 두지 않는다.** 가격 칸만 — **상시가(필수) / 세일가(선택·비우면 세일 안 함) / 대형할인(선택)**. 적은 가격이 곧 진행 종류(중복 입력·불일치 제거). **§15-4 "진행 종류 복수 선택 연동" 대체.**
- **대형할인 = 마켓 선택 → 행사 드롭다운 분기**(§15-4 "메가와리·메가포 고정" 대체): 판매처(마켓) 선택 **Qoo10·Amazon·@cosme·LIPS** + 판매 URL **1개** → 마켓별 **행사 드롭다운**(Qoo10=메가와리/메가포, Amazon=프라임데이/블랙프라이데이/사이버먼데이/타임세일축제, @cosme·LIPS=자체 세일 또는 없음) + 특가. 메가와리·메가포는 Qoo10 전용이라 마켓 종속 폐기. **행사 목록 = `lookup_values`(마켓 태그) 권장** — 마켓·행사 추가가 기준 데이터로 가능.
- **시딩 등급 = 선택 필드 → 채널·가이드 자동 분기**(§15-5 잔여 해소): 시딩 1형식 유지, 등급(나노/미들·메가) 속성. **나노 = Instagram 한정 · 방향성 키워드만(간단)** / **미들·메가 = IG·TikTok·YouTube·X 다채널 · 상세 촬영가이드·필수내용①②③·증정품**. 등급 고르면 채널 선택지·가이드 입력 깊이가 그에 맞게.
- **가구매 결과물 = monitor 재사용 + "리뷰/게시 불필요" 플래그**(§15-6·15-9 잔여 해소): 새 `recruit_type` 안 만들고 **monitor형에 플래그**(인증샷/리뷰 검수 생략). 영수증만 제출·승인=인증성공. 캠페인 카드·필터·통계·인증성공 판정은 플래그 분기로 영향 최소. (구체 플래그 컬럼·인증성공 판정 분기는 캠페인/결과물 설계 시.)
- → **§15-9 잔여 전부 해소.** 사양 골격 완결(폼 와이어프레임·발행 매핑 상세는 구현 착수 시 reverb-planner).

### 15-11. 발급 단위 재구조 — 1 링크 다형식 · 신청 카드 (2026-06-23, §15-3 갱신)

사내 양식(한 브랜드 = 한 시트에 형식 여러 탭 + 제품 블록) 재확인 → 발급 단위를 **형식별 따로**(§15-3)에서 **1 링크 다형식**으로 변경.

- **1 링크(토큰) = 브랜드 1개 + 공통 정보(brands prefill) + 신청 카드 N개.** §15-3 "형식이 여러 개면 형식별 발급" 폐기 → 한 브랜드는 **1 링크**에서 모든 모집 건을 작성.
- **카드 = 모집 건 = 형식(가구매/리뷰어/시딩) + 제품 1개 + 그 형식 항목·가이드 = 캠페인 1개.** (결정④ 1:1로 회귀하되, **1 링크에 카드 N개**.) 카드마다 형식이 다를 수 있음(리뷰어 카드 + 시딩 카드 혼재 가능).
- 브랜드가 카드를 **필요에 따라 추가/삭제**, **제출 전까지 수정**(기존 자동저장·낙관적 락 재사용).
- **데이터 구조**: `data` = `{ (공통은 brands prefill), cards: [ { form_type, product{...}, 가격/판매처(리뷰어·가구매), 채널/등급/가이드(시딩) } ] }`. §15-3·§15-6의 "products 배열" → **"cards 배열"**(카드 = 형식 + 제품 1).
- ⚠️ **`form_type` 단일 컬럼·0단계 타입 선택·`set_orient_form_type`(PR2 구현) 재설계**: 모두 "1 링크 = 1 형식" 전제였으나, 이제 **카드마다 형식 선택**(data 안). `orient_sheets.form_type` 컬럼은 의미 상실(폐기 또는 대표값).
- **발행**: 1 링크 → **카드별 캠페인 N개**(카드 = 형식 + 제품 1 → 캠페인 1). prefill 매핑이 cards 배열 순회.
- → 이 재구조로 **PR1~5(1 링크 1형식·products 배열·form_type 컬럼·0단계 타입선택)가 거의 전면 재작성** 수준. 착수 시 reverb-planner로 폐기·재사용 범위 정밀 계산 필수.

### 15-12. 형식별 입력 항목 (폼 설계 기준)
| 입력 항목 | 가구매 | 리뷰어 | 시딩 |
|---|---|---|---|
| 공통(브랜드·담당자, 1회 prefill) | ✓ | ✓ | ✓ |
| 모집 희망 기간 | ✓ | ✓ | ✓ |
| 판매처 + URL | ✓ | ✓ | — |
| 가격(상시 필수/세일/대형할인=마켓 행사) | ✓ | ✓ | — (제공) |
| 제품명·카테고리·모집인원 | ✓ | ✓ | ✓ |
| 등급(나노/미들·메가) | — | — | ✓ |
| 게시 채널 | — | (=판매처 리뷰 플랫폼) | ✓ (등급 따라) |
| 게시 가이드 | — | 리뷰 가이드 | 채널별 가이드 |
| 소구 키워드·해시태그·계정태그 | — | — | ✓ |
| 촬영가이드·필수내용·증정품 | — | — | 미들·메가만 |
| 배송 정보 | — | — | ✓ |
| NG·추가 안내 | (선택) | ✓ | ✓ |

카드에서 형식을 고르면 위 표대로 입력 항목이 분기된다.

### 15-13. 제출 전 미리보기 (2026-06-23 사용자 요구)
- 제출 시 **"작성 내용을 미리 확인하시겠어요?"** 를 물어, 원하면 **미리보기(검토) 화면**을 띄운다 — 공통 정보 + **카드별 입력 내용**(형식·제품·가격·가이드)을 **읽기 전용**으로 한눈에 정리. 검토 후 **「이대로 제출」 / 「수정으로 돌아가기」**. 원치 않으면 바로 제출.
- 카드 N개 전체를 제출 직전 검토 → 입력 누락·오타 방지(작성자=브랜드 담당자).
- 기존 "제출 후 발행 전까지 재편집"(§6·결정⑨)과 **별개의 사전 검토** 장치.
- ⚠️ 권고(반대론자): 실수 방지가 목적이면 **묻지 않고 항상 미리보기 → 확정** 방식이 더 안전할 수 있음(특히 카드 여러 개일 때). "물어보기" vs "항상 거치기"는 사용자 확인 — 본 절은 사용자 요구대로 "물어보기"로 기재.

---

## 구현 결과 — §15 재설계 (cards 배열)

### PR §15-A — 데이터 구조 재설계 (2026-06-23)
**구현일:** 2026-06-23 / **브랜치:** `feature/orient-redesign`
**착수 순서(사용자 확정):** 데이터구조 먼저 + 메뉴 2분할 병행 / 가구매 결과물 검수까지 포함 / dev 행 전부 삭제 / 폼 카드형 새로 작성.

**마이그레이션:**
- **194** `194_orient_redesign_form_type_and_drop_set_type.sql` — `orient_sheets.form_type` CHECK 2종→3종(`reviewer`/`seeding`/`proxy_purchase`, NULL 허용) + `set_orient_form_type`(188/189) DROP(카드별 form_type 구조라 "1링크=1형식" 함수 폐기).
- **195** `195_create_orient_sheet_cards_redesign.sql` — `create_orient_sheet` 4인자(192) DROP → **2인자**(`p_brand_id`, `p_application_id DEFAULT NULL`) 재정의. `form_type`=NULL, `data` 초기값=brand prefill(신청 연결 시 `brand_applications.brand_name` 우선, 없으면 `brands.name`) + **빈 `cards` 배열**. `is_admin()` 가드·SECURITY DEFINER·`search_path=''`.

**storage.js:** `createOrientSheet` 4인자→2인자(`brandId`, `applicationId`).

**data 카드 스키마 확정 (PR③·④·⑦ 공유 단일 소스 — §11 부록 A[구버전·제품 단수] 대체):**
```jsonc
{ "brand": {"name":"","intro":"","official_accounts":""},
  "cards": [{ "form_type":"",                         // proxy_purchase|reviewer|seeding
    "product":{"name":"","category":"","slots":""},   // category=lookup code
    "recruit":{"recruit_start":"","recruit_end":""},  // 희망 모집 기간만
    "sale":{"market":"","url":"","price_regular":"","price_sale":"","event":"","price_event":""}, // 가구매·리뷰어
    "review_guide":"",                                 // 리뷰어 전용
    "seeding":{"grade":"","channels":[],"appeal":"","hashtags":[],"account_tags":"","shooting_guide":"","required_content":"","gift":"","shipping_note":"","guides":[{"channel":"","guide":""}]},
    "ng":"","cautions":"","images":[{"type":"url","value":""}] }] }
```

**과도기 처리(중요):** 개발 DB의 194·195 적용은 **PR③(폼 카드형 재작성) 머지와 함께** 한다. PR② 코드만 머지하고 DB를 먼저 적용하면, 구버전 작성 폼(`orient.html` `selectType`→`set_orient_form_type`)이 DROP된 함수를 호출해 깨지기 때문. DB 미적용 동안은 구 함수가 살아 있어 구 폼이 정상 동작.

**미정리(다음 PR):** `admin-orient.js` 발급 호출부 4인자(JS가 여분 무시라 무해)·구버전 `orient.html` `selectType` — 폼·관리자 전면 재작성 PR에서 정리. reverb-reviewer Warning 3건이 이 항목(전부 곧 재작성될 파일).

**검토:** 187(get/save/submit) 무변경(`data` jsonb 투명 전달). reverb-supabase-expert 194·195 작성, reverb-reviewer GO(Critical 0), qa skip.

### PR §15-B — 작성 폼 카드형 전면 재작성 (2026-06-23)
**구현일:** 2026-06-23 / **브랜치:** `feature/orient-form-cards`

**무엇:** `dev/sales/orient.html` 을 4단계 위저드(1 링크 = 1 형식 + 제품 1) → **카드형**(1 링크 = 공통 브랜드 + 카드 N개, 카드마다 형식)으로 전면 재작성. §15-11 발급 단위 재구조 반영.

**화면 골격:** 헤더(상태 pill) → 공통 브랜드 섹션 1회(name·intro·official_accounts) → 카드 리스트(아코디언, 한 번에 1개 펼침) → 「제품(카드) 추가」 → 하단 고정 바(자동저장 상태 + 「제출」). 빈 카드(발급 직후 빈 cards 배열)는 빈 상태 안내 + 추가 버튼.

**카드 내부:** 형식 세그먼트(가구매/리뷰어/시딩) → 선택 시 §15-12 표대로 입력 항목 분기(카드 스코프 CSS `data-ctype`). 공통(제품명·카테고리[lookup code]·모집인원·희망 모집기간) + `.only-rp`(판매처·판매URL·상시가[필수]·세일가·대형할인[마켓→행사 드롭다운+특가]) + `.only-reviewer`(리뷰 가이드) + `.only-seeding`(등급→채널·가이드, 미들·메가만 `.only-mega` 촬영가이드·필수내용·증정품) + 공통 NG·추가안내·이미지링크.

**확정 사항(사용자, 2026-06-23):**
- 카드 펼침 = 아코디언(1개씩) / 빈 카드 = 빈 상태+추가 버튼 / 형식 전환 = 경고 후 그 카드 전용칸만 비움(`clearCardTypeFields`, 공통·다른 카드 보존) / 카드 순서변경 없음.
- **미리보기 = 제출 시 항상 1회**(§15-13 "물어보기" → "항상 거치기"로 확정). 제출 버튼 → 읽기전용 미리보기(공통+카드별) → 「이대로 제출」/「수정으로 돌아가기」.
- 가구매 = `proxy_purchase`(마이그194 CHECK).
- **대형할인 행사 목록 = 코드 하드코딩**(`MARKET_EVENTS`, 마켓 4종 Qoo10/Amazon/@cosme/LIPS). §15-10 "lookup_values 권장"은 작업 범위(공용 표 마켓 칸 없음 + 관리자 페인 신설 동반) 고려해 **하드코딩 채택, 기준데이터 관리는 후속**으로 사용자 확정.

**재사용:** boot·진입 4분기·Supabase env 인라인·RPC 인라인(get/save/submit)·자동저장(debounce 1.5s)·낙관적 락(version)·localStorage 백업·beforeunload·escAttr·normalizeUrl·loadCategoryOptions·CSS 토큰. 익명 함수 3종(187) 무변경(data jsonb 투명 전달).

**폐기:** 4단계 위저드(showStep/nextStep/prevStep/진행률바)·0단계 타입선택(selectType/changeType/clearTypeFields)·`set_orient_form_type` 호출(마이그194 DROP)·body[data-otype] 전역 CSS·단수 product collectData/fillForm.

**검증:** `collectData`→`{brand, cards[]}`(카드별 `collectCard`, data-card-id 스코프·DOM 인덱스 없음). `validateBeforeSubmit`(카드 0개·형식 미선택·제품명·상시가[리뷰어/가구매] 누락). reverb-reviewer GO(Critical 0, Warning=cardHtml 107줄·boot 62줄 템플릿 길이 — 다음 정리). qa skip(인증/응모 무관). dev/sales↔sales/ cmp IDENTICAL.

**개발 DB 적용:** 마이그194·195를 **이 PR 머지와 함께** 개발 DB(qysmxtipobomefudyixw)에 적용(SQL Editor). 운영 보류.

**미착수(다음 PR):** PR④ 관리자 발급·조회 재작성(`admin-orient.js` cards 렌더)·PR⑤~⑧(신청 파이프라인·발행·메일).

### PR §15-C — 관리자 발급·조회 화면 카드화 (2026-06-23)
**구현일:** 2026-06-23 / **브랜치:** `feature/orient-form-cards`

**무엇:** `dev/js/admin-orient.js` 발급·조회 화면을 cards 배열 구조(§15-A)에 맞게 재작성. PR③(작성 폼) 이후 관리자가 발급한 카드 내용을 형식별로 확인 가능.

**발급 모달 간소화:** 모집 타입 select·제품 선택 UI 제거(형식·제품은 브랜드가 작성 폼에서 카드마다 선택). 브랜드 + 선택적 신청 연결만. `osSubmitCreate`→`createOrientSheet(brandId, appId)` 2인자. `osIssueFromApplication`→`osOpenCreate({appId,brandId})`(products/formType 컨텍스트 제거). 안내 문구: 신청 연결=모집 희망값 첫 카드 prefill / 형식·제품은 브랜드가 폼에서 선택.

**상세 모달 cards 렌더:** `osDetailHtml`→공통 브랜드 카드(`osBrandCard`) + `data.cards` 순회(`osCardDetail`). 카드별 형식 칩(`osTypeChip`, 색상 분기) + §15-12 형식별 항목: 가구매·리뷰어=판매처·판매URL·가격 3칸·대형할인 / 리뷰어=리뷰 가이드 / 시딩=등급·채널별 가이드·소구·해시태그·계정태그, 미들·메가면 촬영가이드·필수내용·증정품·배송 / 공통 NG·추가안내·이미지(http/https 화이트리스트). 빈 cards=「아직 작성 전」, 형식 미선택 카드=폴백 안내. 카테고리 code→한국어(catMap).

**목록 「모집 형식」 컬럼:** form_type 컬럼이 NULL(카드별 형식)이라 `osCardsSummary(s.data)`로 형식별 개수 표시(「리뷰어 2 · 시딩 1」, 미작성=「미작성」). `fetchOrientSheets` select에 `data` 추가(오리엔시트 행 소수라 페이로드 영향 미미). 헤더 「모집 타입」→「모집 형식」(width 140).

**제거:** `osTypeLabel`·`osRenderProductSelect`·`osPairs`·`osSecRecruit/Brand/Product/Channels/Etc/Images`(단일 product용). **추가:** `OS_TYPE_CHIP`·`OS_GRADE_LABEL`·`osCardsSummary`·`osTypeChip`·`osBrandCard`·`osCardDetail`·`osLinkOrText`·`osImagesInline`.

**검증:** stale 참조 0(내부+admin-brand.js 호출부 호환)·XSS(esc+osImgSafe)·null 안전·DOM 인덱스 0. reverb-reviewer GO(Warning=osLinkOrText href esc 비이슈). DB 변경 없음. qa light.

**미착수(다음 PR):** 서베이 products→cards prefill·PR⑤~⑦(신청 파이프라인·자동 채움 발행)·PR⑧(메일).
