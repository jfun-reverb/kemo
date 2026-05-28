# 방문자 통계 자체 집계 — 관리자 대시보드 직접 표시

> **상태**: 기획 초안 (2026-05-20 작성) — 구현은 개발 세션이 진행
> **요청자**: 사용자 (2026-05-20)
> **관련 메모리**: 없음 (신규 기능)

---

## 1. 배경 / 목표

인플루언서 앱(`globalreverb.com`)과 광고주 신청 폼(`sales.globalreverb.com`)의 방문자 통계를 **관리자 대시보드 안에 우리 차트로 직접** 표시한다.

현재 3개 앱 모두 Vercel Web Analytics 스크립트(`/_vercel/insights/script.js`)가 삽입되어 데이터를 수집 중이나, **Vercel Web Analytics 는 외부(우리 관리자 페이지)에서 데이터를 조회하는 공식 API 가 사실상 없다**. 따라서 방문 기록을 운영 Supabase 에 **자체 집계**하여 직접 렌더하는 방식으로 간다.

---

## 2. 사용자 확정 사항 (2026-05-20 AskUserQuestion)

| 분기 | 결정 |
|---|---|
| 표시 방식 | 관리자 페이지 안에 직접 표시 (Vercel 외부 링크 아님) |
| 통계 범위 | 중간 — ①일별 방문자 수·페이지뷰 ②7일/30일 추이 그래프 ③인기 페이지 순위 |
| 표시 위치 (분기 A) | **신규 「방문 통계」 페인** (`#adminPane-visits`), 사이드바 대시보드 아래 |
| 방문자 식별 (분기 B) | **순방문자(UV)까지 집계** — localStorage 익명 UUID. 개인정보 아님. 개인정보처리방침 자동수집 항목에 「로컬스토리지 익명 식별값」 한 줄 보강 |
| 관리자 앱 포함 (분기 C) | **제외** — 인플·광고주만 집계 |
| 데이터 보존 (분기 E) | **3개월 후 원본 자동 삭제** (단순. 일별 롤업 테이블 없음. 개인정보처리방침 「접속 로그 3개월」 정합) |
| 인기 페이지 개수 (분기 F) | 상위 10개 (기본값) |
| 마이그레이션 번호 (분기 G) | 144 (작업 시작 직전 `ls supabase/migrations/ | tail -5` 재확인) |

---

## 3. 데이터 모델

### 3-1. 테이블 `page_views`
```sql
CREATE TABLE public.page_views (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  app         text NOT NULL CHECK (app IN ('inf','sales')),  -- 관리자 앱 제외
  page        text NOT NULL,                                  -- 정규화된 페이지 경로/페인명
  visitor_id  uuid,                                           -- localStorage 익명 UUID
  created_at  timestamptz NOT NULL DEFAULT now()
);
```
- **IP·referrer·user agent 미저장** (요구사항 — 익명 집계).
- `page` 는 임의 문자열 그대로 받지 않고 **정규화**: 길이 64자 컷 + 화이트리스트 패턴(`^[a-z0-9_\-]+$`) 외는 `'other'`. 봇이 임의 URL 을 쏟아내 카디널리티(고유값 수) 폭증하는 것 방지.

### 3-2. 인덱스
- `(app, created_at)` — 일별/추이 집계
- `(app, page, created_at)` — 인기 페이지 순위
- `(created_at)` — 3개월 파기 정리용

### 3-3. RLS (행 단위 보안 정책)
- SELECT: `is_admin()` 만
- INSERT/UPDATE/DELETE: 정책 없음 → service_role + RPC 만 우회 (캠페인 홍보 메일 4종 테이블과 동일 패턴)

### 3-4. 보존 정책 (3개월 후 삭제)
- pg_cron 으로 매일 1회 `DELETE FROM page_views WHERE created_at < now() - interval '90 days'`
- 또는 별도 정리 함수 `purge_old_page_views()` + cron. 기존 다이제스트 cron 패턴 참고.

---

## 4. 수집 RPC `record_page_view`
```sql
record_page_view(p_app text, p_page text, p_visitor_id uuid DEFAULT NULL)
  RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
-- p_app CHECK ('inf'|'sales'), p_page 정규화(길이/패턴), INSERT
GRANT EXECUTE ON FUNCTION public.record_page_view(text, text, uuid) TO anon, authenticated;
```
- 익명 호출(anon)이므로 직접 INSERT 는 42501 → **RPC 필수** (프로젝트 규칙: 익명 폼은 SECURITY DEFINER RPC 로 감싸기).
- 클라이언트 호출은 **fire-and-forget** (await 안 함, 실패 무시) — 페이지 전환 지연 방지.
- (선택) 동일 visitor_id + 동일 page 5초 내 재호출 무시하는 가벼운 가드.

## 5. 집계 RPC `get_visit_stats`
```sql
get_visit_stats(p_app text, p_days int)   -- p_app: 'inf'|'sales'|'all'
  RETURNS jsonb
  SECURITY DEFINER SET search_path = '' + is_admin() 가드
-- 반환:
--   daily:     [{date, pv, uv}]   (KST 일자 기준, p_days 범위)
--   top_pages: [{page, pv, uv}]   (상위 10개)
--   totals:    {pv, uv, period}
```
- 서버 집계(`date_trunc` + `count(distinct visitor_id)`) → PostgREST 1000행 cap 무관, 클라 전건 fetch 불필요.
- KST 일자 경계는 기존 `_yesterday_kst_window()` 패턴 참고 (UTC+9).

---

## 6. 수집 코드 삽입 위치

| 앱 | 파일 | 위치 |
|---|---|---|
| 인플루언서 | `dev/js/app.js` | `window.va('event', {name:'pv_inf', page:pageName})` 자리(약 45행)에서 `recordPageView('inf', pageName)` 동시 호출 |
| 광고주 폼 | `sales/index.html`, `sales/reviewer.html`, `sales/seeding.html` + **`dev/sales/` 미러본** | 페이지 로드 시 1회 `sb.rpc('record_page_view', {p_app:'sales', p_page:..., p_visitor_id:...})`. (커스텀 이벤트 없이 자동 페이지뷰만 있던 곳) |

- **광고주 폼 도메인 분기**: `sales/reviewer.html:1467` 의 인라인 `SUPABASE_ENV` 가 `sales.globalreverb.com` → 운영 DB(`twofagomeizrtkwlhsuv`) 로 분기됨 (확인 완료). 추가 인프라 불필요.
- **⚠️ `sales/` vs `dev/sales/` 양쪽 존재** — 어느 쪽이 배포 source 인지 개발 세션이 확인 후 양쪽 동기화. Vercel `reverb-sales` 프로젝트 Root Directory=`sales/` 이므로 `sales/` 가 운영 배포 source.
- localStorage 익명 UUID 헬퍼: 첫 방문 시 `crypto.randomUUID()` 생성·저장, 이후 재사용. 인플 앱과 sales 양쪽에 동일 로직 필요(공용 함수 분리 권장).

## 7. 관리자 대시보드 UI

- **신규 페인 `#adminPane-visits`** ("방문 통계") + 사이드바 항목(대시보드 아래).
- 인플/광고주 **탭 분리** + 기간 토글(7일/30일).
- **추이 그래프**: Chart.js (기존 `_signupChart` 패턴 재사용 — line chart, pv·uv 2개 시리즈).
- **인기 페이지 테이블**: 상위 10개 (page, pv, uv).
- 페이지명 한글 라벨 매핑(예: `home` → 「홈」, `detail` → 「캠페인 상세」)이 있으면 운영자 가독성 ↑.
- `dev/js/admin.js` 핫스팟 — worktree 병렬 금지, 시퀀셜 PR (멀티 세션 규칙).

---

## 8. 영향 파일 목록 (dev/ 기준)
- 신규: `supabase/migrations/144_page_views.sql` (테이블 + RLS + record_page_view + get_visit_stats + 파기 cron)
- `dev/lib/storage.js` — `recordPageView()` + `fetchVisitStats()` + localStorage UUID 헬퍼
- `dev/js/app.js` — 인플 페이지뷰 기록 호출
- `dev/js/admin.js` — 신규 페인 렌더·차트·인기 페이지 테이블
- `dev/admin/index.html` — 신규 페인 마크업 + 사이드바 항목
- `sales/{index,reviewer,seeding}.html` (+ `dev/sales/` 미러) — 로드 시 record_page_view 호출
- `docs/PRIVACY_{kr,ja}.md` — 자동수집 항목에 「로컬스토리지 익명 식별값(순방문자 집계용)」 한 줄 보강
- build.sh: 새 JS/CSS 파일 추가 없으면 변경 불필요

## 9. PR 분할
- **PR 1 — 방문 기록 인프라(DB)**: 마이그레이션 144 + storage.js 함수. 의존성 없음.
- **PR 2 — 수집 코드 삽입**: app.js + sales 3종(+미러). PR 1 운영 적용 후 데이터 적재 시작.
- **PR 3 — 관리자 대시보드 UI**: 신규 페인 + Chart.js + 인기 페이지 테이블. PR 1 의존. admin.js 핫스팟이라 PR 2 와 시퀀셜.
- **PR 4 — 약관 보강**: 개인정보처리방침 자동수집 한 줄 (PR 2 운영 적용 시점에 맞춰).

의존성: PR 1 → PR 2 → PR 3 (admin.js 시퀀셜) → PR 4

---

## 10. 약관·개인정보처리방침 영향
- `docs/PRIVACY_kr.md:35` 에 이미 「자동 수집 — 접속 IP, 접속 일시, 브라우저 정보, 쿠키, 세션 토큰 / 서비스 이용 분석 / 3개월」 항목 존재.
- 우리 수집(페이지 경로 + 시각 + 앱 구분, IP·UA 미수집)은 기존 「자동수집·서비스 이용 분석」 범위 안 → 신규 항목 추가 불필요.
- 단 **localStorage 익명 UUID 로 순방문자 식별** → 「쿠키·로컬스토리지 자동수집」 명시에 한 줄 보강 권장 (PR 4). 한·일 동시 수정.

## 11. 리스크 / 운영 메모
- 봇 트래픽 완전 차단 불가 → 「근사 지표」 전제. Vercel Web Analytics 수치와 차이 가능(우리는 SPA 라우팅 기준).
- NANO compute(운영) — 3개월 파기 cron 으로 무한 적재 방지.
- 롤백: 마이그레이션 144 revert + 수집 호출 코드 제거. 독립 테이블이라 사이드이펙트 없음.

---

## 구현 결과
(개발 세션이 채울 것)

### 초안 대비 변경 사항
-

### 구현 중 기술 결정 사항
-
