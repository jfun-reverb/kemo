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
  "recruit": {                    // 모집 정보
    "slots": "",                  // 모집인원 → campaigns.slots (숫자 파싱)
    "recruit_start": "",          // 모집 시작(YYYY-MM-DD) → recruit_start
    "recruit_end": "",            // 모집 마감 → deadline
    "post_start": "",             // 게시 시작 → (구매/방문 기간 참고)
    "post_end": "",               // 게시 마감 → submission_end
    "result_date": ""             // 결과 발표일 → 캠페인 미대응, 관리자 참고만
  },
  "brand": {
    "name": "",                   // 브랜드명 → brand / brand_ko (일본어는 관리자 보완)
    "intro": ""                   // 브랜드 소개·어필 → 콘텐츠 가이드 리치텍스트
  },
  "product": {
    "name": "",                   // 제품명 → product / product_ko
    "category": "",               // 카테고리 → category (lookup 매칭, 실패 시 보정)
    "prices": [                   // 가격 복수(상시·세일·메가와리) → product_price 대표 1개 + 나머지 텍스트
      { "label": "", "value": "" }
    ],
    "urls": [                     // 판매 URL 복수(Qoo10·Amazon·한국) → product_url 대표 1개 + 나머지 텍스트
      { "label": "", "value": "" }
    ],
    "appeal": ""                  // 제품 소개·소구 포인트 → 콘텐츠 가이드 리치텍스트
  },
  "channels": [                   // 채널별 게시 가이드(반복 블록) → 콘텐츠 가이드 단일 리치텍스트로 합쳐 주입(§5 a안)
    { "channel": "", "guide": "" }  // channel = instagram|x|tiktok|youtube|qoo10|lips|atcosme 등, 집합은 campaigns.channel
  ],
  "hashtags": [],                 // 필수 해시태그(최대 5) → 콘텐츠 가이드 본문 텍스트
  "account_tags": "",             // 계정 태그 → 콘텐츠 가이드 본문 텍스트
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

### PR 2·3·4
- 미착수. PR2(브랜드 작성 폼 `dev/sales/orient.html` + 익명 업로드 보안) → PR3(관리자 발급·조회 페인) → PR4(자동 채움 매핑 + 일본어 발행 게이트). §8 분할대로 **시퀀셜**(PR3·4는 `dev/js/admin.js` 핫스팟이라 병렬 금지).
