# Qoo10 랭킹 모니터링 — 전체 구현 사양서

> ⛔ **보류 (2026-05-27 결정)** — 약관 게이트 **FAIL**. Qoo10 이용약관 금지행위 조항에 「로봇·스크래퍼·데이터 수집/추출 도구 등 모든 자동화 수단으로 서비스 접근 금지(목적 불문)」 + 「사전 서면 동의 없는 지식재산권 복제 금지」가 명시됨이 확인되어, 본 사양서의 **자체 크롤링(방식 C)은 약관 위반**. 우리는 Qoo10 셀러 캠페인 파트너라 발각 시 계정·캠페인 불이익 리스크. → **기능 자체를 보류**. 재개하려면 ①수동 캡처/입력 방식 또는 ②Qoo10 공식 데이터 문의(자사 제품 한정)로 **재설계 필요**. 아래 본문은 보류된 자체 크롤링 설계 기록.

**작성일:** 2026-05-27
**작성 세션:** 기획/설계 ([via planner] 경우의 수 탐색)
**선행 문서:** `docs/specs/2026-05-27-qoo10-ranking-poc.md` (PoC = GO 검증 완료)
**배경:** 챌린저스식 「랭킹 모니터링」(Qoo10 순위 추이 그래프 + 카테고리 순위 캡처). 벤치마크 분석은 `docs/research/2026-05-27-challengers-benchmark.md` 권고 G와 연계.

---

## 0. 확정 사항 (사용자 결정 2026-05-27)

| 항목 | 결정 |
|---|---|
| 수집 방식 | 자체 크롤링 (PoC GO — 접근·추출·단기 차단 없음 확인) |
| 인프라 | 깃허브 자동작업(GitHub Actions) + Playwright(가짜 브라우저), 결과는 service_role 키로 Supabase 저장 |
| 수집 범위 | **카테고리 1~200위 전체 스냅샷** (우리 제품 순위 + 카테고리 캡처 + 경쟁사 포착을 한 번에) |
| 추적 제품 등록 | **신규 추적 표** — 자사 + 경쟁사 모두 등록 |
| 광고주 노출 | **관리자만 보고 수동 전달**(이미지·엑셀). 광고주 로그인 신설 안 함 |
| 자동 실행 | **처음엔 수동 버튼**(workflow_dispatch), 안정성 + 약관 확인 통과 후 매일 자동(cron) |
| 진행 범위 | **랭킹 먼저 단독**. 광고주 성과 리포트(권고 G)는 이후 별도 |

## 0-1. ⚠️ 운영 배포 게이트 (필수)
- **Qoo10 이용약관의 자동 수집 금지 조항 여부를 사람이 직접 확인 + 법무 판단**한 뒤에만 **운영 자동 실행(매일 cron)을 켠다.** 우리는 Qoo10 셀러 캠페인 파트너라 더 민감.
- 개발·테스트 단계(수동 실행)는 진행 가능. 이 게이트는 자동 실행 활성 시점에 건다.

---

## 1. 데이터 모델 (마이그레이션 153~)

> 최신 마이그레이션 152(캠페인 홍보 메일 관리자 구독)가 이미 잡혀 있어 랭킹은 **153부터**. 멀티 세션 규칙상 신규 번호는 한 세션에서만.

### `qoo10_categories` — 추적 카테고리 마스터
- `code text PK`, `name_ko`, `name_ja`, `url text`(Qoo10 랭킹 페이지 주소), `active bool`, `sort_order`
- 행 단위 보안 정책(RLS): SELECT `is_admin()`, 변경 `is_campaign_admin()` 이상

### `tracked_products` — 추적 제품 등록 (자사 + 경쟁사)
- `id uuid PK`, `qoo10_item_no text`(상품번호), `qoo10_url text NOT NULL`, `label text`(표시명), `brand_id uuid NULL`(브랜드 연결), `campaign_id uuid NULL`(캠페인 연결), `is_competitor bool DEFAULT false`, `category_code text`(추적 카테고리), `active bool DEFAULT true`, 감사 4컬럼
- brand_id·campaign_id는 **다른 표의 행을 가리키는 느슨한 연결**(nullable) — 경쟁사 제품은 캠페인 없이도 등록 가능
- RLS: SELECT `is_admin()`, 변경 `is_campaign_admin()` 이상

### `ranking_snapshots` — 랭킹 스냅샷 시계열
- `id bigint PK`, `category_code text`, `captured_at timestamptz`, `rank int`, `item_no text`, `product_name text`, `brand_name text`, `review_count int`, `price_regular int`, `price_sale int`, `item_url text`
- 인덱스: `(category_code, captured_at)`, `(item_no, captured_at)`
- RLS: SELECT `is_admin()`, INSERT는 service_role만(정책 없음 → 우회)
- 보존 정책: 추적 제품과 무관한 행은 N일 후 정리하는 함수(선택, 저장량 관리)

### `ranking_captures` — 카테고리 캡처 이미지 메타
- `id uuid PK`, `category_code text`, `captured_at timestamptz`, `storage_path text`, `crawl_run_id uuid`
- 이미지는 **신규 비공개 버킷 `ranking-captures`** (기존 `campaign-images`는 공개·캠페인 전용이라 혼용 회피, 양 서버에 버킷+정책 복제)

### `crawl_runs` — 크롤 실행 로그 (멱등·차단 기록)
- `id uuid PK`, `started_at`, `finished_at`, `status CHECK(success|partial|blocked|failed)`, `categories_done int`, `error_message text`, `run_date date UNIQUE`(하루 1회 잠금장치 — 중복 실행 차단)
- RLS: SELECT `is_admin()`, 쓰기 service_role

## 2. 크롤링 워커 (깃허브 자동작업)

- 위치: `scripts/qoo10-crawler/`(크롤러 스크립트 + **격리된 package.json** — 메인은 패키지 매니저 없는 CDN 기반이라 분리) + `.github/workflows/qoo10-ranking.yml`(기존 배포 워크플로와 별도)
- 도구: Playwright. 실제 User-Agent, 접속자 위장 안 함, 요청 간 충분한 지연
- service_role 키: GitHub Secret(`SUPABASE_SERVICE_ROLE_KEY` / 개발용 `*_DEV`), **env 블록으로만 전달**(명령어 인자 금지 — 로그 노출 방지). 이 키는 행 단위 보안 정책을 우회하므로 **ranking_* 테이블 쓰기에만** 쓰도록 코드 가드
- 실행: 처음엔 **수동 버튼(workflow_dispatch)만**. 안정화 + 약관 게이트 통과 후 매일 cron 추가(메일 자동발송 검증 패턴 차용)
- graceful 처리(필수):
  - `crawl_runs.run_date UNIQUE` INSERT 선행 → 같은 날 재실행 차단
  - 차단 감지(차단 페이지·403·빈 결과) → `status='blocked'` 기록 후 즉시 중단, **우회 시도 금지**
  - 카테고리별 try/catch → 1개 실패해도 나머지 진행(`partial`)
  - 0건 추출 = Qoo10 구조 변경 신호 → 경보

## 3. 가격 파싱 규칙
- 추출 문자열에서 `[\d,]+円` 전부 추출 → 콤마·전각숫자 정규화 후 정수 배열
- 2개: 큰 값=정가(`price_regular`), 작은 값=할인가(`price_sale`)
- 1개: 정가=할인가(할인 없음)
- 0개: NULL + `crawl_runs` 경고(셀렉터 변경 신호)
- 정규화 함수는 크롤러 스크립트 내부(클라이언트 코드 `dev/lib`와 무관)

## 4. 표시 — 관리자 페인 (광고주는 수동 전달)
- 신규 `dev/js/admin-ranking.js`(페인). build.sh `ADMIN_JS_FILES`의 페인 그룹에 등록(admin.js 앞). 사이드바 메뉴 + `PANE_REFRESHERS` 등록
- 구성(챌린저스 화면 차용):
  - **집행 제품 카드** — 추적 제품별 현재 순위 + 추이 그래프(Chart.js — 이미 보유). 경쟁사 제품은 별도 표시(`is_competitor`)
  - **카테고리 캡처 갤러리** — `ranking_captures`의 캡처 이미지를 카테고리·날짜별로 나열(챌린저스 "카테고리별 최고 순위" 대응)
- 광고주 전달: 관리자가 화면에서 확인 후 이미지/엑셀로 직원이 전달(권고 G 전달 방식에 합류)

## 5. 단계별 PR 분할

> 모든 PR: dev 먼저 → reverb-reviewer GO → 빌드(해당 시) → dev 머지(Claude 진행). 운영(main)·약관 게이트는 사용자 확인.

- **PR 1 — 크롤러 스크립트**: `scripts/qoo10-crawler/` Playwright 스크립트(DB 미연결, 콘솔 출력 검증). 약관 무관(개발/테스트)
- **PR 2 — 데이터 모델**(마이그레이션 153~): 5개 표 + RLS + `ranking-captures` 버킷. 개발 DB 적용 + 신규 함수 스모크 호출. **reverb-supabase-expert 필수**
- **PR 3 — 깃허브 워커**: `.github/workflows/qoo10-ranking.yml` + service_role 저장 로직. Secret 등록(양 서버). **cron 아닌 수동 버튼만**으로 시작
- **PR 4 — 관리자 표시 페인**(`admin-ranking.js`): 집행제품 카드 + 추이 그래프 + 캡처 갤러리
- **PR 5 — 추적 제품 등록 UI**: `tracked_products` 추가/수정/삭제(자사·경쟁사 토글), 추적 카테고리 관리
- **(운영 게이트)** 약관 사람 확인 통과 + 안정성 검증 후 → PR 3 워크플로에 매일 cron 활성

admin.js 핫스팟: PR 4·5가 `dev/js/admin.js`(캠페인 폼) 건드리면 worktree 병렬 금지, 시퀀셜만.

## 6. 리스크
- **장기 차단**: 저빈도라도 누적 차단 가능 → graceful 중단 + 차단 경보 + 수동 재개. PoC 단기 안전이 장기 보장 아님
- **페이지 구조 변경**: 셀렉터를 크롤러 상단 상수로 모아 유지보수 1곳. 0건 추출 시 자동 경보
- **service_role 키**: GitHub Secret 유출 시 전체 우회 → 스코프 최소·정기 교체·env 전달
- **제3자 데이터 적법성**: 내부 참고(현 결정)는 부담 적으나, 향후 광고주 외부 노출(토큰 링크) 전환 시 Qoo10 데이터 재배포 적법성 재검토 필요
- **저장량**: 카테고리 5개 × 200위 × 365일 ≈ 36만 행/년 — 부담 없으나 보존 정책 사전 설계

## 7. 약관/개인정보 영향
- 외부 제품·가격·순위(공개정보)라 우리 개인정보처리방침 수집 항목과 무관 → 현재 결정(내부 참고)에선 약관·개인정보 문서 변경 불필요
- 향후 광고주 외부 노출(토큰 링크) 채택 시 `/약관확인` 검토 대상

---

## 구현 결과

(개발 세션이 채울 것)

**구현일:**
**관련 커밋:**

### 초안 대비 변경 사항
-

### 구현 중 기술 결정 사항
-
