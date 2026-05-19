# 행 단위 보안 정책(RLS) InitPlan 최적화 + 외래 키 인덱스 추가

**상태:** 개발서버 적용 대기 (마이그레이션 137 v2 재작성 완료 — 2026-05-19)  
**작성일:** 2026-05-19  
**마이그레이션:** 137 (행 단위 보안 정책 최적화), 138 (외래 키 인덱스)

---

## 배경

Supabase Performance Advisor 진단 결과:

- 「Auth RLS Initialization Plan」 경고 88건
- 「Unindexed foreign keys」 권고 30건

운영 페이지 응답 지연의 원인으로 지목됨. 인플루언서 데이터가 1,000건 이상 누적된 상황에서 행 단위 보안 정책(RLS) 정책이 행마다 `auth.uid()` 를 반복 호출하는 구조가 주요 병목.

---

## §1. 문제 원인

### 1-1. auth.uid() 직접 호출 안티패턴

```sql
-- 안티패턴 (현행)
USING (auth.uid() = user_id)

-- 권장 패턴
USING ((SELECT auth.uid()) = user_id)
```

PostgreSQL 의 쿼리 계획기는 `auth.uid()` 를 `STABLE` 함수로 인식하더라도, 행 단위 보안 정책(RLS) 내에서 직접 호출하면 행마다 재평가(Re-Evaluate) 한다. `(SELECT auth.uid())` 로 서브쿼리로 감싸면 쿼리 계획 단계에서 1회 평가 후 InitPlan(상수) 으로 캐시되어 전체 행을 순회하지 않는다.

- `applications` 3,000건 × `auth.uid()` 재호출 = 함수 3,000회 실행
- `(SELECT auth.uid())` 패턴 = 함수 1회 실행

### 1-2. 외래 키(FK) 컬럼 인덱스 미존재

외래 키 컬럼에 인덱스가 없으면:
- JOIN 시 참조 테이블 전체 순회 (Seq Scan)
- `ON DELETE CASCADE / SET NULL` 시 참조 테이블 전체 탐색

---

## §2. 영향 분석

### 마이그레이션 137 대상 정책 (운영 DB 기준 26개 전수)

운영 DB `pg_policies` 추출 결과(2026-05-19)를 기준으로 `auth.uid()` 직접 호출이 포함된 26개 정책 전수 대상.

| # | 테이블 | 정책명 | 명령 | 변경 내용 |
|---|---|---|---|---|
| 1 | admin_email_subscriptions | admin_email_sub_cud_self_or_super | ALL | USING + WITH CHECK (IN 서브쿼리 안) |
| 2 | admin_notice_reads | admin_notice_reads_insert | INSERT | WITH CHECK |
| 3 | admin_notices | admin_notices_delete | DELETE | USING (created_by 비교) |
| 4 | admin_notices | admin_notices_select | SELECT | USING (created_by 비교) |
| 5 | admin_notices | admin_notices_update | UPDATE | USING + WITH CHECK (created_by 비교) |
| 6 | admins | admins_delete | DELETE | USING (EXISTS 서브쿼리 안) |
| 7 | admins | admins_insert | INSERT | WITH CHECK (EXISTS 서브쿼리 안) |
| 8 | admins | admins_update | UPDATE | USING (EXISTS 서브쿼리 안 + 직접 비교) |
| 9 | applications | applications_select_own | SELECT | USING |
| 10 | applications | applications_insert_own | INSERT | WITH CHECK |
| 11 | brand_application_memo_reads | brand_app_memo_reads_insert | INSERT | WITH CHECK |
| 12 | deliverable_events | deliverable_events_select_own | SELECT | USING (actor_id 비교 + EXISTS 서브쿼리 안) |
| 13 | deliverables | deliverables_select_own | SELECT | USING |
| 14 | deliverables | deliverables_insert_own | INSERT | WITH CHECK |
| 15 | deliverables | deliverables_update_own_draft_or_pending | UPDATE | USING + WITH CHECK |
| 16 | deliverables | deliverables_update_own_rejected | UPDATE | USING + WITH CHECK |
| 17 | deliverables | deliverables_delete_own_draft | DELETE | USING |
| 18 | influencers | influencers_select_own | SELECT | USING |
| 19 | influencers | influencers_insert_allow | INSERT | WITH CHECK |
| 20 | influencers | influencers_update_allow | UPDATE | USING + WITH CHECK |
| 21 | notifications | notifications_select_own | SELECT | USING |
| 22 | notifications | notifications_update_own | UPDATE | USING + WITH CHECK |
| 23 | notifications | notifications_delete_own | DELETE | USING |
| 24 | receipts | receipts_select_own | SELECT | USING |
| 25 | receipts | receipts_insert_own | INSERT | WITH CHECK |
| 26 | receipts | receipts_update_own | UPDATE | USING + WITH CHECK |

**v1(초안) 대비 v2 차이:** `admin_email_subscriptions`, `admin_notices`(3개), `admins`(3개) 총 7개 누락 → v2에서 추가. 중복 DROP 정리.

정책 의미 변경: **없음**. `(SELECT auth.uid())` 은 `auth.uid()` 와 완전히 동일한 값을 반환한다.

### 마이그레이션 138 대상 인덱스 (11건)

| 테이블 | 컬럼 | 이유 |
|---|---|---|
| brand_application_history | changed_by | ON DELETE SET NULL |
| brand_application_memos | author_id | ON DELETE SET NULL |
| brands | created_by | ON DELETE SET NULL |
| campaign_caution_history | changed_by | ON DELETE SET NULL |
| companies | created_by | ON DELETE SET NULL |
| companies | updated_by | ON DELETE SET NULL |
| application_events | changed_by | ON DELETE SET NULL |
| brand_applications | intake_admin_id | ON DELETE SET NULL |
| admin_notice_reads | notice_id | PK 역방향 단독 조회 |
| brand_application_memo_reads | memo_id | PK 역방향 + CASCADE |
| deliverable_events | actor_id | ON DELETE SET NULL |

---

## §3. 적용 계획

### 순서

1. 개발서버 마이그레이션 137 적용 + 기능 검증
2. 개발서버 마이그레이션 138 적용
3. Supabase Performance Advisor 재확인 (88건 → 0건 목표)
4. 운영서버 동일 순서 적용 (한국시간 새벽 2~4시 권장)

### 적용 시간 권고

- 각 정책 DROP + CREATE 는 해당 테이블에 짧은 잠금 발생 (~10ms 이내)
- 인덱스 추가는 현재 데이터 크기 기준 < 1초
- 운영 트래픽이 거의 없는 새벽 적용 권장

### 운영 적용 전 개발서버 검증 체크리스트

1. `sakura.test@reverb.jp` 로그인 → 본인 applications 조회 성공, 타인 데이터 차단 확인
2. `admin@kemo.jp` 로그인 → influencers 전체 조회 성공
3. anon → campaigns SELECT 성공 (공개 정책 영향 없음)
4. 인플루언서 deliverable INSERT → pending 상태로 저장 성공
5. 관리자 deliverable UPDATE → 상태 변경 성공
6. 인플루언서 notification 읽음 처리 (UPDATE) 성공
7. 관리자 초대 → admin_notice_reads INSERT 성공

---

## §4. 검증 SQL

### 행 단위 보안 정책 최적화 확인

**1단계: 안티패턴 잔존 여부 확인 (결과 0건이어야 함)**

```sql
SELECT tablename, policyname, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND (
    qual    ~ 'auth\.uid\(\)'
    OR with_check ~ 'auth\.uid\(\)'
  )
  AND NOT (
    (qual ~ '\(SELECT auth\.uid\(\)' OR qual IS NULL)
    AND (with_check ~ '\(SELECT auth\.uid\(\)' OR with_check IS NULL)
  )
ORDER BY tablename, policyname;
```

**2단계: 운영 DB 정책 26개 전수 확인 (26행이어야 함)**

```sql
SELECT tablename, policyname, cmd
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, policyname;
```

### 외래 키 인덱스 확인

```sql
-- 11개 인덱스 등록 확인 (11행 반환)
SELECT indexname
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname IN (
    'idx_brand_app_history_changed_by',
    'idx_brand_app_memos_author_id',
    'idx_brands_created_by',
    'idx_campaign_caution_history_changed_by',
    'idx_companies_created_by',
    'idx_companies_updated_by',
    'idx_application_events_changed_by',
    'idx_brand_applications_intake_admin_id',
    'idx_admin_notice_reads_notice_id',
    'idx_brand_app_memo_reads_memo_id',
    'idx_deliverable_events_actor_id'
  )
ORDER BY indexname;
```

---

## §5. 회귀 위험 평가

| 항목 | 위험도 | 근거 |
|---|---|---|
| 정책 의미 변경 | 없음 | `(SELECT auth.uid())` = `auth.uid()` 동일 값 반환 |
| 락 시간 | 극소 | DROP + CREATE 각 ~10ms, 테이블 크기 작음 |
| 인덱스 빌드 시간 | 극소 | 각 테이블 < 1초 예상 |
| 정책 이름 충돌 | 없음 | DROP IF EXISTS 선행, 동일 이름으로 재생성 |

---

## §6. 롤백

각 마이그레이션 파일 하단 주석 블록에 롤백 SQL 포함됨.

- 마이그레이션 137 롤백: 각 정책을 `auth.uid()` 직접 호출 형태로 재생성
- 마이그레이션 138 롤백: `DROP INDEX IF EXISTS ...` 11건

---

## 구현 결과

**구현일:** 2026-05-19
**관련 파일:**
- `supabase/migrations/137_rls_initplan_optimization.sql`
- `supabase/migrations/138_fk_indexes.sql`

### 초안 대비 변경 사항

- 추가된 것: 없음 (초안 그대로)
- 빠진 것: 없음
- 달라진 것: 138 마이그레이션은 `CONCURRENTLY` 미사용 (11건 전부 일반 `CREATE INDEX IF NOT EXISTS`) — 운영 적용 시점에 대상 테이블이 작아 쓰기 잠금 위험 없음으로 판단

### 적용 결과 (운영 + 개발 DB)

- **운영 Performance Advisor**: 88 warnings → **62 warnings** (Auth RLS Initialization Plan 26개 100% 해소)
- **검증 SQL**: `antipattern_count = 0` 확인 (운영 + 개발 양쪽)
- **회귀 테스트**: 인플 로그인 / 캠페인 응모 / 결과물 제출 / 관리자 대시보드 / 인플 목록 모두 정상 동작
- **운영 사용자 체감 변화**: 작음 — Slow Queries 분석 결과 진짜 병목은 「Supabase 호주 시드니 리전 ↔ 일본 사용자 RTT × N개 API 호출」 로 판명. 137·138 은 DB 측 InitPlan/인덱스 효과 (DB 쿼리 자체) 한정이라 페이지 진입 총 시간 단축에는 한계
- **다음 PR**: Supabase 도쿄 리전 이전 사양서 별도 작성 예정 — 가장 큰 효과 추정 (-50~70%)

### 구현 중 기술 결정 사항

- `ALTER POLICY` 대신 `DROP + CREATE` 채택: PostgreSQL 15+ 에서 `ALTER POLICY` 는 `USING`/`WITH CHECK` 절 변경을 지원하지 않아 재생성 방식이 안전
- 마이그레이션 파일 기반 분석 결과, 그룹 A(이미 인덱스 있는 FK 22건)와 그룹 B(미존재 11건)로 분류
- `deliverable_events.actor_id` 추가: `ON DELETE SET NULL` 대상이나 기존 마이그레이션에서 인덱스 누락 확인
- 운영 DB 정확한 26개 정책 `pg_policies` 추출 결과로 137 의 1:1 대응 보장
- 적용 직후 검증 SQL의 LIKE 패턴은 PostgreSQL 의 공백 정규화(`(SELECT` → `( SELECT`) 영향으로 `LIKE '%SELECT auth.uid()%'` 형태로 조정 필요 (운영 사용자 추가 안내용)
