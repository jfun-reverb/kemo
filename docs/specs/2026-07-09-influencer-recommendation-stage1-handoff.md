# HANDOFF — 인플루언서 추천 도구 1단계 (데이터 이관 + 명단 관리)

**작성일:** 2026-07-09 (기획/고문 세션 → 개발 세션 인계)
**사양서:** `docs/specs/2026-07-08-influencer-recommendation.md`
**범위:** 1단계만 (추천 알고리즘은 2단계, 성과는 3단계 — 본 인계 대상 아님)
**참고 마이그레이션:** `217_settlements_schema.sql`(테이블+RLS 패턴)·`220_settlement_role_permissions_seed.sql`(권한 시드)·`200_orient_upload_bucket_and_policy.sql`(Storage 버킷)

> 영업팀 인플 명단(구글시트 **917명**, globalreverb 미가입·별도 자산)을 시스템으로 이관 + 관리자 CRUD 페인 신설.
> ⚠️ 2026-07-14 정정: 최초 이관은 시트를 "약 50명"으로 잘못 파악해 앞 50명만 넣었으나, 실제 917명. 전량 재이관으로 정정(seed 교체 + 마이그레이션 236 카테고리 health·tech 추가).
> 기존 `influencers`와 **분리한 신규 테이블**(그건 auth 계정 1:1·정산/마스킹 결합이라 섞으면 오염).

---

## 확정된 결정 (planner 추천안 채택)

| # | 항목 | 결정 |
|---|---|---|
| 1 | 이관 방법 | **1회 import SQL** (사용자가 CSV export 제공 → 개발이 정제·INSERT). 이후 유지는 화면 CRUD |
| 2 | 마스터 쓰기 권한 | **직접 정책**(RLS로 관리자 쓰기 허용, 기준데이터 페인류). 비금전이라 원격 함수 강제 불필요 |
| 3 | 등급 티어 출처 | **시트값 우선 + 수동 수정**. 팔로워 자동계산 안 함(시트값과 충돌 방지) |
| 4 | 계열 매핑 | ✅ 확정: 라이프=브이로그·키즈맘 / 푸드 독립 / 기타 미분류 (아래 표) |
| 5 | 콘텐츠 정책 | 대표 게시물 링크 **최대 5개** + `content_consent` 동의 컬럼 **선탑재**(5단계 브랜드 노출 대비) |

---

## PR 서브분할 (3개 순차 — worktree 병렬 금지, `admin-core.js`·`index.html` 공유 파일 수정 때문)

### PR 1단계-a : DB 기반 (마이그레이션 226~, 번호는 생성 시 확정)
1. **`outbound_influencers` 테이블** (표준 패턴: `CREATE TABLE IF NOT EXISTS` + `COMMENT` + RLS + `touch_updated_at` 트리거)

| 그룹 | 컬럼 |
|---|---|
| 기본 | `id uuid PK`, `name_ko`, `account_id` |
| 분류 | `series_code`, `category_code`, `tier_code` (셋 다 lookup code 문자열 스냅샷, 계열은 세분에서 자동채움) |
| 채널 | `ig_handle/ig_followers`, `tiktok_*`, `youtube_*`, `x_*` (핸들 `normalizeSnsFields` 정규화, 팔로워 `bigint NULL`) |
| 가격 | `price_feed/reels/story/tiktok/secondary bigint NULL` (빈값=NULL, 0과 구분) |
| 운영(내부전용) | `contact_channel text`, `agency text`, `nego_memo text`, `availability CHECK(available/unavailable/adjusting)` |
| 콘텐츠 | `rep_image_path`, `rep_posts jsonb`(링크+썸네일 경로 배열), `content_consent boolean DEFAULT false` |
| 메타 | `is_active bool`, `created_at`, `updated_at` |

- **RLS**: SELECT `has_permission('outbound.view','read')` (⚠️ `is_admin()` 금지 — 매니저 뚫림). INSERT/UPDATE/DELETE 직접 정책 `has_permission('outbound.view','write')`. 인플·anon 정책 0개.

2. **신규 lookup 3종** (`lookup_values`에 `kind` 추가 — 기존 grep 0건 확인됨)
   - `ob_series`(계열) / `ob_category`(세분) / `ob_tier`(등급, name에 팔로워 구간 병기)
   - **세분→계열 매핑은 lookup에 부모 컬럼이 없으므로 `shared.js` 코드 상수 `OB_CATEGORY_SERIES`**로 두고 저장 시 `series_code` 자동 채움

3. **권한 시드 마이그레이션** (220 패턴): `role_permissions`에 `menu.outbound`·`outbound.view` — campaign_admin=write / campaign_manager=hidden, **`default_level`도 동일값**(NOT NULL)

4. **Storage 버킷** `outbound-influencer-images` — public 읽기(imgThumb 재사용), 경로 `{id}/{random}.{ext}`, MIME image/jpeg·png·webp 5MB. SELECT public / 쓰기 관리자. 정책식 `has_permission` 호출이 storage.objects에서 안 되면 `is_campaign_admin()`로 대체(검증 필요)

### PR 1단계-b : 관리자 CRUD 페인 (신규 `dev/js/admin-outbound.js`, 가칭 `#outbound`)
- **반영 6곳**: ①`admin-core.js:175` loaders `outbound: loadOutbound` ②`dev/admin/index.html` 사이드바(회원 관리 그룹 근처)+페인 본문 ③`build.sh:78` ADMIN_JS_FILES(`js/admin-outbound.js`, admin.js 앞) ④`shared.js:523` PANE_REFRESHERS ⑤`shared.js:833` ADMIN_PERMISSION_CATALOG(`menu.outbound`+`outbound.view`) ⑥권한 시드(위 PR-a에 포함)
- **목록**: 대표이미지 썸네일·한글명·계정ID·계열·세분·등급·주채널 팔로워·가용상태 배지·소속사. IntersectionObserver lazy-load
- **필터**: 계열/세분(다중)·등급·가용상태·채널·검색(이름/계정/소속사)
- **상세·편집 모달**: 전체 필드 + 채널4 + 가격5 + 대표게시물 링크(최대5) + 협상메모 + 이미지 업로드. 저장 끝 `await refreshPane('outbound')` 필수
- `storage.js`에 `fetchOutboundInfluencers`/`upsertOutboundInfluencer` 등 추가

### PR 1단계-c : 시트 1회 이관
- 사용자 CSV export → 정제 → import SQL → 개발DB 적용 → 페인에서 눈으로 확인 → 운영
- **정제 규칙**: 빈 가격/팔로워=NULL / "기타"=`other` / 소속사 trim·표기 통일 / 깨진 글자는 import 전 사람이 교정(개발이 의심 행 목록 뽑아 사용자 확인) / 컨텍 창구 text

---

## 계열 매핑 (✅ 결정 4 — 확정 2026-07-09)

| 계열(series) | 세분(category) |
|---|---|
| 뷰티 | 색조(color) · 기초(base) |
| 패션 | 패션(fashion) |
| 라이프 | 브이로그(vlog) · 키즈맘(kidsmom) |
| 푸드 | 푸드(food) — 독립 |
| 미분류 | 기타(other) |

→ `shared.js` 코드 상수 `OB_CATEGORY_SERIES`에 이 매핑을 그대로 반영.

---

## 개발 세션 착수 방법
1. 메인 폴더에서 `/새세션 인플추천도구` → worktree(`reverb-jp-인플추천도구`) + `feature/인플추천도구` 브랜치 생성
2. 그 폴더에서 개발 세션 시작 → PR 1단계-a부터 순차
3. 마이그레이션 파일은 **worktree에 생기므로 메인 폴더 트리엔 안 보임** — 사용자에게 SQL Editor 실행 안내 시 **절대경로 먼저 제시**
4. 각 PR: `reverb-supabase-expert`(테이블·RLS·마이그레이션) → 빌드 → `reverb-reviewer` → dev 배포
5. 이관용 CSV는 **사용자에게 요청** 필요(개발이 시트 직접 접근 불가)

## 주의 (planner가 짚은 함정)
- **매니저 차단**: RLS SELECT를 반드시 `has_permission('outbound.view','read')`로 (is_admin() 금지)
- **내부 전용 필드**(실단가·협상 메모): 5단계 브랜드 뷰에서 같은 컴포넌트 재사용 시 유출 위험 — 데이터·렌더 양쪽에서 구획
- **빈 상태 화면**: 이관 전 0건이면 "먼저 이관하세요" 안내 필요
- **NULL vs 0**: 가격/팔로워 빈값은 NULL로 저장(2단계 예산 필터가 "가격 미상"을 구분)

---

## 구현 진행 (개발 세션 기록)

### PR 1단계-a — DB 기반 (2026-07-09, feature/outbound-recommendation)
- **마이그레이션 번호 확정**: 226(테이블+RLS+트리거) · 227(lookup 3종 시드) · 228(권한 시드) · 229(Storage 버킷). 순차·멱등.
- **가격 단위 = 엔화(¥) 확정**(사용자 2026-07-09) — 시트 원본이 엔화(정산과 동일 통화). 컬럼은 bigint NULL 저장, 화면에서 ¥ 표시.
- **등급 티어**: 사양서 원본 시트 3단계 그대로 — 마이크로(1만~5만)/미들(5만~30만)/메가(30만~). REVERB 기존 5단계 체계 신설 안 함.
- **229 Storage 정책**: `has_permission('outbound.view','write')` 채택(정적 검증만). ⚠️ PR-b 화면 완성 후 campaign_admin 계정 실제 업로드 1회 스모크 필수 — 실패 시 파일 하단 `is_campaign_admin()` 폴백.
- **dev 반영은 정산 운영 배포 후**(정산 배포 델타에 섞이지 않게 — 사용자 결정 2026-07-09).
- 검토: [via supabase-expert] 작성 / [via reviewer] GO(Critical·Warning 0).
