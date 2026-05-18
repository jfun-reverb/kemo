# HANDOFF — 메일 파이프라인 통합 (관리자 일일 다이제스트 4섹션화 + 양측 audit)

> **작성일**: 2026-05-18
> **작성 세션**: 기획/설계 (메인 폴더, 코드 미수정)
> **인수인계 대상**: 메일링 작업 개발 세션
> **관련 사양서**: `docs/specs/2026-05-18-mail-pipeline-consolidation.md` (§13~§16 확정)
> **선행 운영 상태**: 마이그레이션 130 운영 배포 완료. 인플루언서 다이제스트 코드·DB 운영 적용, **cron 미등록** 상태. 관리자 cron 2종 (`notify-application-cancelled-daily`, `notify-application-received-admin-daily`) 가동 중
> **우선순위**: 일반 (선행 PR 운영 안정화 직후 진행 가능)

---

## 0. 한 줄 요약

관리자 일일 메일 2종을 단일 `notify-admin-daily-digest` 로 통합 + 신청 status 변경 audit 테이블 (`application_events`) 신규 도입으로 2차 변경(결과물 재제출·결과물 되돌리기·신청 되돌리기) 까지 다이제스트에 포착. 인플루언서 측 발송 매트릭스는 변경 없음.

---

## 1. 산출물

| 종류 | 갯수 | 비고 |
|---|---|---|
| 마이그레이션 | 1개 | **131** — `application_events` 테이블 + 트리거 + RLS |
| Edge Function | 1개 신규 | `notify-admin-daily-digest` |
| Edge Function | 2개 deprecated | `notify-application-cancelled-daily`, `notify-application-received-admin-daily` (cron 만 해제, 코드 보존) |
| 메일 템플릿 (HTML) | 1개 신규 | `docs/email-templates/admin-daily-digest.html` (4섹션) |
| pg_cron job | 통합 후 1개 + 인플 1개 = 2개 등록, 2개 해제 | 양 DB (개발 + 운영) 각각 |
| 카탈로그 갱신 | 1개 | `docs/email-templates/index.html` 활성 메일 7종 → 6종 + deprecated 표기 |
| 클라이언트 코드 | **0개** | 변경 없음 |

---

## 2. 작업 전제 (이미 결정된 것)

### 2-1. 사양 확정 (§13~§14)

| 항목 | 결정 |
|---|---|
| 통합 방향 | 옵션 C — 관리자만 통합, 인플루언서 측 즉시 검수 메일 + 4섹션 다이제스트 유지 |
| 보완안 | 옵션 2 — 신청 + 결과물 양측 audit (`application_events` 신규 + 기존 `deliverable_events` 활용) |
| 다이제스트 섹션 구조 | 4섹션 (접수 / 취소 / 제출 / 재처리) |
| application_events 트래킹 범위 | 운영자 액션만 (approve / reject / revert_to_pending — 3종, supabase-expert 검증 반영 reapply 제외). 본인 취소는 cancelled_at 으로 §2 섹션이 이미 잡음. 본인 재응모는 새 INSERT 라 §1 「신청 접수」 가 잡음 |
| 결과물 제출 섹션 그룹화 | kind 별 (영수증 / 리뷰 이미지 / 게시 URL) |
| 기존 Edge Function 2종 | cron 해제 + 코드 보존 (2주 안정화 후 별도 PR 에서 삭제 검토) |
| 운영 적용 타이밍 | 인플 다이제스트 cron 미등록 상태에서 통합 함수 cron + 인플 cron 함께 등록 (1회 전환) |

### 2-2. 기존 인프라 점검

- `notify-application-cancelled-daily` 가 운영 중 — Brevo SMTP 호출 + `auth.admin.getUserById` 패턴이 검증된 베이스
- `auth.admin.getUserById` 이메일 조회 패턴은 마이그레이션 130 작업에서 안정화됨 (cancel-daily 버그 C 수정 후 패턴 확정)
- `lookup_values(kind='admin_email_kind')` 시드 3건 존재 (`brand_notify`, `application_cancel`, `application_received`)
- 다음 마이그레이션 번호: **131** (현재 마지막=130). 작업 시작 직전 `ls supabase/migrations/ | tail -5` 한 번 더 확인 권장
- `admin_email_subscriptions` 행 단위 보안 정책(RLS) + `get_subscribed_admin_emails()` 원격 호출 함수(RPC) 이미 운영 가동 (마이그레이션 103)

---

## 3. 작업 순서 (PR 분해)

### 3-1. PR 구성

| PR | 범위 | 의존성 |
|---|---|---|
| **PR 1** — application_events audit | 마이그레이션 131 + 트리거 검증 | 없음 |
| **PR 2** — 통합 Edge Function + cron 전환 | `notify-admin-daily-digest` 신규 + 기존 2종 cron 해제 + 통합 cron 등록 + 인플 다이제스트 cron 등록 + 카탈로그 갱신 | PR 1 운영 배포 완료 후 시작 권장 |

원래 §15 표에서 PR 2 와 PR 3 (인플 cron 등록) 을 분리했으나, 「인플 다이제스트 cron 등록」 은 사실상 운영 cron 한 줄 추가라 PR 2 묶음에 함께 처리하는 게 안전 (운영 전환 시점 일원화).

### 3-2. 운영 안정화 후 별도 PR (작업 본 묶음 외)

| PR | 범위 | 시점 |
|---|---|---|
| 후속 — deprecated Edge Function 정리 | `notify-application-cancelled-daily` + `notify-application-received-admin-daily` Supabase Dashboard + repo 삭제 | 통합 함수 운영 2주 안정화 후 |

---

## 4. PR 1 — application_events audit 테이블 (마이그레이션 131)

### 4-1. 영향 파일

- [ ] `supabase/migrations/131_application_events.sql` (신규)
- [ ] `CLAUDE.md` Database Schema 섹션 신규 항목 추가
- [ ] `docs/specs/2026-05-18-mail-pipeline-consolidation.md` §12 「구현 결과」 채우기 (PR 1 단계 분량만)

### 4-2. 마이그레이션 구조

```sql
-- 131_application_events.sql
-- 신청 status 변경 audit (운영자 액션 한정). 본인 취소는 cancelled_at 으로 별도 추적
-- supabase-expert 검증 (2026-05-18) 반영:
--  - reapply 액션 제거 (cancelled→pending UI 없음, 본인 재응모는 §1 신청 접수가 잡음)
--  - approved↔rejected 직접 전이 매핑 추가 (UI 단계 생략·직접 SQL 대비)
--  - partial 인덱스 → 단순 created_at 인덱스로 통합
--  - from_status·to_status CHECK 제약 추가
--  - changed_by FK ON DELETE SET NULL (관리자 삭제 시 audit 보존)

CREATE TABLE application_events (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    application_id  uuid        NOT NULL REFERENCES applications(id) ON DELETE CASCADE,
    action          text        NOT NULL CHECK (action IN ('approve', 'reject', 'revert_to_pending')),
    from_status     text        CHECK (from_status IN ('pending','approved','rejected','cancelled')),
    to_status       text        CHECK (to_status   IN ('pending','approved','rejected','cancelled')),
    changed_by      uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
    changed_by_name text,
    memo            text,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_application_events_application_created
    ON application_events (application_id, created_at DESC);

CREATE INDEX idx_application_events_created_at
    ON application_events (created_at DESC);

ALTER TABLE application_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY application_events_select
    ON application_events FOR SELECT
    USING (is_admin());

-- INSERT/UPDATE/DELETE 정책 없음 → 트리거로만 INSERT
```

### 4-3. 트리거 설계

`applications.status` 변경 시 트리거가 자동 INSERT:

```sql
CREATE OR REPLACE FUNCTION public.record_application_status_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_action      text;
    v_admin_name  text;
BEGIN
    -- no-op (status 동일) 스킵
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;

    -- 운영자 액션 매핑.
    -- cancelled 전이는 cancel_application RPC 가 cancelled_at 으로 별도 추적 → ELSE NULL 로 미기록.
    -- cancelled → pending 은 현재 UI 없음 → ELSE NULL 로 미기록 (추후 필요 시 확장).
    v_action := CASE
        WHEN OLD.status = 'pending'                AND NEW.status = 'approved' THEN 'approve'
        WHEN OLD.status = 'pending'                AND NEW.status = 'rejected' THEN 'reject'
        WHEN OLD.status IN ('approved','rejected') AND NEW.status = 'pending'  THEN 'revert_to_pending'
        WHEN OLD.status = 'approved'               AND NEW.status = 'rejected' THEN 'reject'
        WHEN OLD.status = 'rejected'               AND NEW.status = 'approved' THEN 'approve'
        ELSE NULL
    END;

    IF v_action IS NULL THEN
        RETURN NEW;
    END IF;

    -- 관리자 이름 스냅샷
    SELECT a.name INTO v_admin_name
      FROM public.admins a
     WHERE a.auth_id = auth.uid();

    INSERT INTO public.application_events (
        application_id, action, from_status, to_status,
        changed_by, changed_by_name, memo
    ) VALUES (
        NEW.id, v_action, OLD.status, NEW.status,
        auth.uid(), v_admin_name, NULL
    );

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_application_status_event ON public.applications;
CREATE TRIGGER trg_application_status_event
    AFTER UPDATE OF status ON public.applications
    FOR EACH ROW
    EXECUTE FUNCTION public.record_application_status_event();
```

**참고 (reapply 제거)**: 본인 응모 취소 후 재응모는 마이그레이션 104 partial unique index 패턴으로 새 INSERT 행이 되므로 다이제스트 §1 「신청 접수」 섹션이 잡음. `cancelled → pending` UPDATE 는 현재 관리자 UI 에 없음 (반드시 「revert → pending」 후 재심사 2단계 또는 새 INSERT 경로). 따라서 `reapply` 액션은 트리거가 INSERT 안 함 (CHECK 제약에서도 제거).

### 4-4. PR 1 검증 SQL (개발 DB 에서 실행)

```sql
-- 1. 테이블 생성 확인
SELECT count(*) FROM application_events;  -- 0 기대

-- 2. 트리거 동작 확인 — 임의 신청 행 status 변경 후 application_events INSERT 여부
-- 개발 DB 에서 테스트 신청 1건의 status 를 approved 로 UPDATE
-- 그 후
SELECT action, from_status, to_status, changed_by_name, created_at
FROM application_events
ORDER BY created_at DESC
LIMIT 5;

-- 3. RLS 확인 — anon 으로 SELECT 시 0건
-- (Supabase SQL Editor 에서는 admin 권한이라 0건 안 나옴)
```

### 4-5. PR 1 검증 후 운영 배포 단계

- [ ] 개발 DB 마이그레이션 적용 → 검증 SQL 통과
- [ ] reverb-reviewer 호출
- [ ] dev push → 개발서버 배포 확인
- [ ] **개발서버에서 실제 신청 1건 승인 → application_events 행 1건 생기는지 육안 확인**
- [ ] AskUserQuestion 으로 운영 배포 여부 확인
- [ ] 운영 DB SQL Editor 에서 동일 마이그레이션 적용
- [ ] 운영 DB 검증 SQL 재확인 (0건이어야 함 — 트래픽 발생 전)
- [ ] main merge → 운영 배포

---

## 5. PR 2 — 통합 Edge Function + cron 전환

### 5-1. 영향 파일

- [ ] `supabase/functions/notify-admin-daily-digest/index.ts` (신규)
- [ ] `supabase/functions/notify-admin-daily-digest/_templates/admin-daily-digest.html` (sync 자동 생성)
- [ ] `docs/email-templates/admin-daily-digest.html` (신규 — source of truth)
- [ ] `docs/email-templates/index.html` 카탈로그 갱신 (활성 카드 추가 + 기존 2개 deprecated 표기)
- [ ] cron 등록 + 해제 SQL (양 DB 각각)
- [ ] `CLAUDE.md` Email / SMTP 섹션 — 「관리자 일일 통합 다이제스트」 항목 추가, 기존 2종은 (deprecated 2026-05-XX) 표기
- [ ] `docs/specs/2026-05-18-mail-pipeline-consolidation.md` §12 「구현 결과」 PR 2 단계 채우기

### 5-2. Edge Function 본문 구조

```typescript
// supabase/functions/notify-admin-daily-digest/index.ts
// supabase-expert 검증 (2026-05-18) 반영:
//  - INSERT-선행 동시성 패턴 (digest_date UNIQUE 가 mutex 역할 — 메일 중복 발송 방지)
//  - 섹션 3 = deliverable_events.action='submit' 기준 (재제출 자동 배제, 사양 의도 명확화)
//  - 수신자 Promise.all 개별 try-catch + env 폴백 (한쪽 RPC 실패 시도 진행)

// 1. 어제 KST 윈도우 계산 (헬퍼 _yesterday_kst_window() 재사용)

// 2. ★ INSERT 선행 (mutex) — status='failed' 로 마커 INSERT
//    23505 (UNIQUE 위반) = 이미 처리됨 → 즉시 종료 (중복 메일 발송 차단)
//    성공 = 이 프로세스만 진행, 메일 발송 후 UPDATE 로 실제 상태 갱신

// 3. 4섹션 데이터 조회 (개별 쿼리 4종)
//    a. 신청 접수: applications WHERE created_at IN yesterday_kst_window
//       ※ 본인 재응모 케이스도 새 INSERT 라 여기서 함께 잡힘
//    b. 응모 취소: applications WHERE cancelled_at IN window AND cancel_phase != 'recruit'
//    c. 결과물 제출: deliverable_events WHERE created_at IN window AND action='submit'
//       ※ deliverable_events.action='submit' 기준 — 재제출(resubmit) 자동 배제
//       ※ 이후 deliverable_id 배치 조회로 campaign_id / user_id / kind 획득
//    d. 재처리: 클라이언트 측 머지
//       - deliverable_events WHERE created_at IN window AND action IN ('resubmit', 'revert')
//       - application_events WHERE created_at IN window AND action = 'revert_to_pending'
//         ※ application_events 액션 3종 중 재처리 1종만 사용 (approve/reject 는 §1·§3 흐름)

// 4. 4섹션 모두 0건이면 → UPDATE status='skipped_no_data' + 발송 스킵
//    부분 0건은 발송 (0건 섹션은 본문 생략)

// 5. 수신자 조회 — Promise.all + 개별 try-catch
//    get_subscribed_admin_emails('application_cancel')
//      ∪ get_subscribed_admin_emails('application_received')
//      ∪ env NOTIFY_ADMIN_EMAILS

// 6. 메일 템플릿 렌더 + Brevo SMTP 전송

// 7. UPDATE admin_daily_digest_runs SET status='sent' + sections_summary + recipients_count
//    (실패 시 status='failed' 유지 + error_message 채워서 UPDATE)
```

### 5-3. 다이제스트 로그 테이블

기존 2종은 각자 `application_cancel_digest_runs` / `application_received_admin_digest_runs` 두 개 테이블 사용. 통합 후에는 단일 테이블이 합리적이나, 기존 테이블 보존 + 신규 통합 테이블 추가의 트레이드오프 있음.

**권장**: 신규 테이블 `admin_daily_digest_runs` 추가, 기존 2종은 그대로 보존 (deprecated, 추후 정리 PR 에서 DROP 검토).

```sql
-- 마이그레이션 132 로 신설 (supabase-expert 검증 반영)
--   - status 'failed' (기존 cancel/received 패턴 승계, 'error' 아님)
--   - run_at (130 패턴, ran_at 아님)
--   - recipients_count NOT NULL DEFAULT 0
CREATE TABLE IF NOT EXISTS public.admin_daily_digest_runs (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    digest_date      date NOT NULL UNIQUE,
    status           text NOT NULL CHECK (status IN ('sent', 'skipped_no_data', 'failed')),
    sections_summary jsonb,  -- {received: N, cancelled: N, submitted: N, reprocessed: N}
    recipients_count integer NOT NULL DEFAULT 0,
    error_message    text,
    run_at           timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.admin_daily_digest_runs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS admin_daily_digest_runs_select ON public.admin_daily_digest_runs;
CREATE POLICY admin_daily_digest_runs_select
  ON public.admin_daily_digest_runs FOR SELECT
  USING (is_admin());
```

→ **메모**: 이전 세션에서 "recipients_count 컬럼 부재 SQL 오류" 가 있었다. 기존 130 테이블이 `recipient_count` (단수) 였던 컬럼명 미스매치 — 통합 테이블 신설 시 `recipients_count` (복수) 로 통일, 신규 cancel 테이블 (113) 패턴과 일치.

### 5-4. 수신자 lookup_kind 결정 (재확인)

| 안 | 동작 |
|---|---|
| **A (추천)** | 기존 두 종류 (`application_cancel`, `application_received`) 합집합 — 둘 중 하나라도 ON 인 관리자에게 발송 |
| B | 신규 단일 종류 `admin_daily_digest` 추가 + 기존 2종 자동 비활성화 + 기존 구독자 마이그레이션 |

추천 근거: 기존 구독 설정 보존이 가장 안전. 합집합 한 줄로 처리 가능. 단점 — 통합 함수의 수신자 종류가 헷갈릴 수 있음 (운영 안정화 후 단일 lookup_kind 로 정리 검토).

### 5-5. 메일 템플릿 4섹션 구조

```html
[REVERB] 관리자 일일 요약 — YYYY-MM-DD

▶ 캠페인 신청 접수 (N건)
  ※ 0건이면 섹션 자체 생략
  - [캠페인 A] - 인플 5명
  - [캠페인 B] - 인플 3명

▶ 응모 취소 (N건)
  ※ 0건이면 섹션 생략
  - cancel_phase 별 그룹: 구매기간 1건 · 결과물 제출기간 2건
  - 행: [캠페인] / [인플] / [사유 코드] / [메모]

▶ 결과물 제출 (N건)
  ※ kind 별 그룹 — 영수증 / 리뷰 이미지 / 게시 URL
  - 행: [캠페인] / [인플] / [제출 시각]

▶ 재처리 일감 (N건)  ← 신규 섹션
  ※ 종류별 그룹 — 결과물 재제출 / 결과물 되돌리기 / 신청 되돌리기
  - 행: [캠페인] / [인플] / [action 라벨] / [운영자 이름]
  ※ 본인 응모 취소 후 재응모는 새 INSERT 라 §1 「신청 접수」 가 잡음 (재처리 아님)
```

4섹션 모두 0건이면 발송 스킵 (기존 cancel-daily 패턴 승계).

### 5-6. cron 전환 SQL (양 DB)

⚠ supabase-expert 검증 반영 — **등록 먼저, 해제 나중**. 반대로 하면 그날 관리자 메일이 0통 발송됨.

```sql
-- 1. 통합 cron 먼저 등록 (UTC 00:00 = KST 09:00)
SELECT cron.schedule(
    'notify-admin-daily-digest',
    '0 0 * * *',
    $$
    SELECT net.http_post(
        url := 'https://[프로젝트 URL]/functions/v1/notify-admin-daily-digest',
        headers := jsonb_build_object('Authorization', 'Bearer ' || (
            SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'service_role_key'
        ))
    );
    $$
);

-- 2. 인플 다이제스트 cron 등록 (옵션 C 결정으로 통합 시점에 등록)
SELECT cron.schedule(
    'notify-influencer-daily-digest',
    '0 0 * * *',
    $$
    SELECT net.http_post(
        url := 'https://[프로젝트 URL]/functions/v1/notify-influencer-daily-digest',
        headers := jsonb_build_object('Authorization', 'Bearer ' || (
            SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'service_role_key'
        ))
    );
    $$
);

-- 3. 신규 cron 2종 등록 확인
SELECT jobname, schedule, active FROM cron.job WHERE jobname LIKE '%-daily%';

-- 4. 신규 cron 등록 확인 후 기존 cron 2종 해제
--    (반드시 신규 cron 등록 + active 확인 후 진행)
SELECT cron.unschedule('notify-application-cancelled-daily');
SELECT cron.unschedule('notify-application-received-admin-daily');

-- 5. 최종 상태 확인 (기존 2종 사라지고 신규 2종 + 기타만 남아있어야 함)
SELECT jobname, schedule, active FROM cron.job ORDER BY jobname;
```

### 5-7. PR 2 검증 절차 (개발 DB)

- [ ] 마이그레이션 132 (admin_daily_digest_runs) 적용
- [ ] Edge Function 배포 (`supabase functions deploy notify-admin-daily-digest`)
- [ ] 어제 윈도우에 테스트 데이터 시드 (신청 접수 1건 / 취소 1건 / 결과물 제출 1건 / 재처리 1건)
- [ ] curl 수동 호출 → Brevo Activity 로그에서 발송 확인 + 메일 본문 4섹션 모두 렌더 확인
- [ ] `admin_daily_digest_runs` 행 1건 INSERT 확인 (status='sent', sections_summary 4종 모두 1)
- [ ] 어제 윈도우 0건 시드 → 재호출 → status='skipped_no_data' 확인
- [ ] 같은 날짜 중복 호출 → UNIQUE 제약 차단 확인 (기존 cancel-daily 패턴 승계)
- [ ] 기존 cron 2종 해제 → cron.job 테이블에서 사라짐 확인
- [ ] 통합 cron + 인플 cron 등록 확인
- [ ] reverb-reviewer 호출
- [ ] reverb-qa-tester Light 모드 (관리자 페인 영향 — admin_daily_digest_runs 페인 추가 없으면 스킵 OK)

### 5-8. 운영 배포 단계

PR 1 운영 배포 + 안정성 확인 (최소 1일 이상) 후:

- [ ] 개발서버 검증 통과 확인 (위 5-7)
- [ ] AskUserQuestion 으로 운영 배포 여부 확인 (사용자 명시 지시 받음)
- [ ] 운영 DB SQL Editor 에서 마이그레이션 132 적용
- [ ] 운영 Edge Function 배포
- [ ] 운영 cron 전환 SQL 실행 (기존 2종 해제 + 통합 1종 등록 + 인플 1종 등록)
- [ ] cron.job 테이블 등록 확인
- [ ] main merge → 운영 배포
- [ ] **다음 날 09:00 KST 발송 확인** — Brevo Activity 로그 + admin_daily_digest_runs 조회

---

## 6. 운영 안정화 후 별도 PR (참고만 — 본 묶음 외)

### 6-1. deprecated Edge Function 정리

운영 2주 안정화 + 발송 누락 0회 확인 후:

- [ ] Supabase Dashboard 에서 `notify-application-cancelled-daily` Function 삭제
- [ ] `notify-application-received-admin-daily` Function 삭제
- [ ] `supabase/functions/` 디렉토리에서 두 폴더 제거
- [ ] `docs/email-templates/index.html` 카탈로그에서 deprecated 카드 제거
- [ ] CLAUDE.md 해당 항목 (deprecated 표기 줄) 삭제
- [ ] `application_cancel_digest_runs` / `application_received_admin_digest_runs` 테이블 DROP 검토 (감사 보존 필요하면 보존, 정리 시 마이그레이션 별도)

---

## 7. 의존성 / 충돌 점검

### 7-1. 다른 작업과의 충돌 가능성

- **마이그레이션 번호**: 작업 시작 직전 `ls supabase/migrations/ | tail -5` 로 확인. 다른 세션이 131 을 가져갔으면 132 사용
- **applications 테이블 트리거**: 기존 트리거 (cancel_application RPC 안에서 동작) 와 충돌 없음 확인 — 본 트리거는 `AFTER UPDATE OF status` 이고 cancelled 전이는 본 트리거 본문에서 early return
- **admin_email_subscriptions**: 마이그레이션 103 이후 안정 가동. 본 작업은 신규 lookup_kind 추가 안 함 (기존 2종 합집합 — 5-4 안 A)
- **인플 다이제스트 cron 미등록 상태**: 통합 시점에 함께 등록. PR 2 SQL 5-6 §3 참고

### 7-2. 동시 진행 불가 작업

- `applications.status` 컬럼 추가/변경 작업 (트리거 의존성)
- `notify-application-cancelled-daily` 코드 수정 (deprecated 예정이라 무의미)
- `lookup_values(kind='admin_email_kind')` 시드 변경 작업 (수신자 조회 동작에 영향)

---

## 8. 롤백 절차

### 8-1. PR 1 롤백 (audit 테이블만)

```sql
-- 1. 트리거 제거
DROP TRIGGER IF EXISTS trg_application_status_event ON public.applications;
DROP FUNCTION IF EXISTS public.record_application_status_event();

-- 2. 테이블 DROP (audit 데이터 소실 주의)
DROP TABLE IF EXISTS public.application_events;
```

application_events 가 다른 코드에서 참조되지 않으므로 단순 DROP 안전.

### 8-2. PR 2 롤백 (통합 함수 + cron 전환)

```sql
-- 1. 통합 cron 해제
SELECT cron.unschedule('notify-admin-daily-digest');
SELECT cron.unschedule('notify-influencer-daily-digest');  -- 인플 cron 도 동시 해제

-- 2. 기존 cron 2종 재등록 (cron.schedule 호출 — 5-6 의 이전 schedule 구문 복원)
-- (deprecated Edge Function 코드는 남아있으므로 호출 가능)
SELECT cron.schedule('notify-application-cancelled-daily', '0 0 * * *', $$ ... $$);
SELECT cron.schedule('notify-application-received-admin-daily', '0 0 * * *', $$ ... $$);

-- 3. admin_daily_digest_runs 테이블 보존 또는 DROP (감사 데이터)
```

통합 함수 자체는 Supabase Dashboard 에서 비활성화만 해도 충분 (cron 이 안 부르므로 호출 0건).

---

## 9. 에이전트 호출 의무 (배포 전 필수)

PR 1, PR 2 각각 commit 직전 모두 적용:

- [ ] **reverb-supabase-expert** — 마이그레이션 신규 (PR 1) / 마이그레이션 + cron + Edge Function (PR 2)
- [ ] **reverb-reviewer** — 모든 commit 직전 예외 없이
- [ ] **reverb-qa-tester** — 관리자 페인 변경 없으므로 Light 모드 스킵 OK. 단 다이제스트 발송 검증은 위 5-7 검증 절차에서 수동 처리

---

## 10. 관련 사양서 / 참고

- 본 HANDOFF: `docs/specs/2026-05-18-HANDOFF-mail-pipeline-consolidation.md`
- 사양서 (확정): `docs/specs/2026-05-18-mail-pipeline-consolidation.md` §13~§16
- 선행 작업 사양서: `docs/specs/2026-05-18-application-email-pipeline.md`
- 선행 작업 HANDOFF: `docs/specs/2026-05-18-HANDOFF-application-email-pipeline.md` (cancel-daily 버그 수정 패턴 참고용)
- 선행 작업 cancel-daily 버그 수정: `docs/specs/2026-05-13-application-cancel-daily-email-fix.md`

---

## 11. PR description 권장 형식

### PR 1
```
## 변경 요약
- 마이그레이션 131 — application_events audit 테이블 + 트리거 + RLS
- 운영자 액션(approve/reject/revert_to_pending — 3종) 자동 INSERT. approved↔rejected 직접 전이도 매핑 (단계 생략 대비)

## 요청 외 추가 변경
- 없음

## 관련 사양서
- docs/specs/2026-05-18-mail-pipeline-consolidation.md §13~§14
- docs/specs/2026-05-18-HANDOFF-mail-pipeline-consolidation.md §4
```

### PR 2
```
## 변경 요약
- notify-admin-daily-digest Edge Function 신규 (4섹션 = 신청 접수 / 응모 취소 / 결과물 제출 / 재처리)
- 마이그레이션 132 — admin_daily_digest_runs 로그 테이블
- 기존 cron 2종 (cancel-daily / received-admin-daily) 해제, 통합 cron + 인플 다이제스트 cron 등록
- 메일 템플릿 + 카탈로그 갱신

## 요청 외 추가 변경
- 없음

## 관련 사양서
- docs/specs/2026-05-18-mail-pipeline-consolidation.md §13~§16
- docs/specs/2026-05-18-HANDOFF-mail-pipeline-consolidation.md §5
```

---

## 12. 메인 세션 (고문/검증) 후속 처리

- 본 HANDOFF 작성 완료 후 사용자에게 「개발 세션 작업 시작 시점」 의견 확인
- 개발 세션이 PR 1 운영 배포 완료하면 본 사양서 §12 「구현 결과」 PR 1 단계 채우기 (개발 세션 의무)
- PR 2 운영 배포 완료 후 본 사양서 §12 전체 마무리 + Notion 동기화 필요 여부 점검 (`.claude/rules/notion-sync.md`)
