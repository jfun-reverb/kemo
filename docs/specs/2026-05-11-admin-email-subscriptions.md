# 사양서: 관리자 메일 수신 설정 분리 (멀티 메일 종류)

> **작성일**: 2026-05-11
> **작성 세션**: 고문(메인 폴더)
> **상태**: ✅ **운영 배포 완료 (2026-05-11)** — 마이그레이션 103 양 DB 적용 + 관리자 페인 「메일 수신 설정」 모달 가동 중. 구현 결과 섹션 참조
> **연관 사양**: `docs/specs/2026-05-11-application-cancel.md` (§6-1 수신자 로직이 본 사양 결과를 사용)
> **예상 PR 분할**: 1개 (DB + UI + Edge Function 영향 통합) — 실제 단일 commit `7153b03` 으로 처리됨

---

## 1. 결정 요약

| 항목 | 결정 |
|---|---|
| 데이터 저장 | `admin_email_subscriptions` 신규 테이블 (admin_id + mail_kind) |
| 메일 종류 카탈로그 | `lookup_values(kind='admin_email_kind')` 시드 — 초기 2종 |
| UI 편집 동선 | 관리자 계정 행에 「설정」 버튼 → 모달에서 메일 종류 체크박스 리스트 + 저장 |
| 관리자 목록 표시 | 「메일받기」 열에 켜진 메일 종류 한글 라벨 칩 나열, 비어있으면 「—」 |
| 기존 컬럼 처리 | `admins.receive_brand_notify` 데이터 이관 후 deprecated (즉시 DROP 안 함) |
| 신청 취소 사양과의 관계 | 본 작업이 먼저 머지되면 신청 취소 §6-1 수신자 로직이 본 테이블 참조 |
| 작업 시작 | PR #152·#153과 영역이 안 겹치므로 **병렬 진행 가능** (대기 불필요) |

---

## 2. 데이터베이스 스키마 변경

### 2-1. 마이그레이션 파일

**파일명**: `supabase/migrations/{다음번호}_admin_email_subscriptions.sql`

> 작업 시작 시점에 `ls supabase/migrations/ | tail -5`로 다음 번호 확인.

### 2-2. `admin_email_subscriptions` 신규 테이블

```sql
CREATE TABLE public.admin_email_subscriptions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id     uuid NOT NULL REFERENCES public.admins(id) ON DELETE CASCADE,
  mail_kind    text NOT NULL,                              -- lookup_values(kind='admin_email_kind') code
  subscribed   boolean NOT NULL DEFAULT true,              -- false 행도 허용 (명시적 끄기 흔적)
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid REFERENCES auth.users(id) ON DELETE SET NULL,

  UNIQUE (admin_id, mail_kind)
);

CREATE INDEX admin_email_subscriptions_admin_idx
  ON public.admin_email_subscriptions (admin_id);

CREATE INDEX admin_email_subscriptions_kind_subscribed_idx
  ON public.admin_email_subscriptions (mail_kind, subscribed)
  WHERE subscribed = true;
```

**행 단위 보안 정책 (RLS)**
```sql
ALTER TABLE public.admin_email_subscriptions ENABLE ROW LEVEL SECURITY;

-- SELECT: 모든 관리자 (자기 설정 + 다른 관리자 설정 모두 볼 수 있어야 super_admin이 관리)
CREATE POLICY admin_email_sub_select_admin
  ON public.admin_email_subscriptions FOR SELECT
  USING (public.is_admin());

-- INSERT/UPDATE/DELETE: super_admin만 다른 관리자 설정 수정, 일반 관리자는 본인 것만
CREATE POLICY admin_email_sub_cud_self_or_super
  ON public.admin_email_subscriptions FOR ALL
  USING (
    public.is_super_admin()
    OR admin_id IN (SELECT id FROM public.admins WHERE auth_id = auth.uid())
  )
  WITH CHECK (
    public.is_super_admin()
    OR admin_id IN (SELECT id FROM public.admins WHERE auth_id = auth.uid())
  );
```

### 2-3. `lookup_values` 시드 — 메일 종류 카탈로그

```sql
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES
  ('admin_email_kind', 'brand_notify',      '브랜드 서베이 접수', 'ブランドサーベイ受付',   10, true),
  ('admin_email_kind', 'application_cancel', '응모 취소 알림',     '応募取消通知',          20, true);
```

추가 메일 종류는 lookup 한 줄 추가만으로 카탈로그 확장 (마이그레이션 없이 SQL 한 줄).

### 2-4. 기존 `admins.receive_brand_notify` 데이터 이관

```sql
-- 기존 receive_brand_notify=true 관리자를 admin_email_subscriptions에 brand_notify 구독으로 이관
INSERT INTO public.admin_email_subscriptions (admin_id, mail_kind, subscribed)
SELECT id, 'brand_notify', true
FROM public.admins
WHERE receive_brand_notify = true
ON CONFLICT (admin_id, mail_kind) DO NOTHING;

-- 컬럼은 즉시 DROP 안 함. 한동안 유지 + COMMENT에 deprecated 표시
COMMENT ON COLUMN public.admins.receive_brand_notify IS
  'DEPRECATED (2026-05-11). 대체: admin_email_subscriptions(mail_kind=''brand_notify''). 다음 배포 사이클에서 DROP 예정.';
```

> **NOTE**: 다음 배포에서 안정성 확인 후 별도 마이그레이션으로 `ALTER TABLE admins DROP COLUMN receive_brand_notify`. 본 사양 범위 외.

### 2-5. 헬퍼 함수 (선택)

```sql
-- 특정 메일 종류 구독 중인 관리자 이메일 목록 반환 (Edge Function이 호출)
CREATE OR REPLACE FUNCTION public.get_subscribed_admin_emails(p_mail_kind text)
RETURNS TABLE (email text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT a.email
  FROM public.admins a
  JOIN public.admin_email_subscriptions s ON s.admin_id = a.id
  WHERE s.mail_kind = p_mail_kind
    AND s.subscribed = true;
$$;

GRANT EXECUTE ON FUNCTION public.get_subscribed_admin_emails(text) TO authenticated;
```

Edge Function이 직접 JOIN 쿼리해도 되지만, 한 곳에서 정의해두면 신청 취소 PR-D 등 후속 알림 함수가 재사용 가능.

---

## 3. 관리자 UI 사양 (`dev/js/admin.js` + `dev/index.html` admin 부분)

### 3-1. 관리자 계정 페인 (`/admin#admin-accounts`) — 「메일받기」 열 변경

**Before** (현재):
```
| 이름 | 이메일 | 권한 | 메일받기 | 생성일 | 액션 |
                          [토글]
```

**After**:
```
| 이름 | 이메일 | 권한 | 메일받기 (1)             | 생성일 | 액션 |
                          [브랜드 서베이] [응모 취소]  [설정]
```
- 「메일받기」 열에 켜진 메일 종류 라벨을 작은 회색 칩으로 나열
- 줄바꿈 허용 (메일 종류 3개 이상일 때)
- 아무것도 안 켜져 있으면 회색 「—」
- 마지막에 「설정」 작은 버튼 (ghost) — 클릭 시 모달 열림

### 3-2. 「메일 받기 설정」 모달

모달 구조:
```
┌──────────────────────────────────────┐
│ 메일 받기 설정                          │
│ {관리자 이름} ({관리자 이메일})           │
│                                      │
│ 받을 메일을 선택하세요.                  │
│                                      │
│ ☑ 브랜드 서베이 접수                    │
│    광고주(브랜드)가 sales 페이지에서      │
│    신청 폼을 제출했을 때 접수 알림         │
│                                      │
│ ☐ 응모 취소 알림                        │
│    인플루언서가 구매기간 이후에           │
│    응모를 취소했을 때 알림                │
│                                      │
│ ┌────────────────────────────────┐    │
│ │ 미래 추가 가능 메일 종류는          │    │
│ │ lookup_values에 한 줄 추가         │    │
│ │ (마이그레이션 없이)                │    │
│ └────────────────────────────────┘    │
│                                      │
│          [취소]    [저장]              │
└──────────────────────────────────────┘
```

- 체크박스 + 굵은 한국어 라벨 + 회색 작은 설명문
- 메일 종류는 `lookup_values(kind='admin_email_kind', active=true)`에서 `sort_order` 순으로 동적 렌더
- 저장 클릭 시 모달 안의 모든 메일 종류에 대해 `admin_email_subscriptions` UPSERT (subscribed=true/false)
- 저장 후 `refreshPane('admin-accounts')`

### 3-3. 권한 분기

| 시나리오 | 동작 |
|---|---|
| super_admin이 본인 행 설정 모달 열기 | 정상 — 본인 설정 편집 |
| super_admin이 다른 관리자 행 설정 모달 열기 | 정상 — 다른 관리자 설정 편집 (RLS도 허용) |
| campaign_admin / campaign_manager가 본인 행 설정 모달 열기 | 정상 — 본인 설정만 편집 |
| campaign_admin / campaign_manager가 다른 관리자 행 「설정」 버튼 | 버튼 자체 비활성 또는 비표시 (UI 가드) + RLS 이중 방어 |

### 3-4. storage.js 함수 추가 (`dev/lib/storage.js`)

```js
// 관리자별 메일 구독 상태 fetch — admin_id를 키로 mail_kind 배열 반환
async function fetchAdminEmailSubscriptions(adminIds) {
  if (!db) return {};
  const {data, error} = await db.from('admin_email_subscriptions')
    .select('admin_id, mail_kind')
    .in('admin_id', adminIds)
    .eq('subscribed', true);
  if (error) throw error;
  // { adminId: ['brand_notify', 'application_cancel'] }
  const map = {};
  for (const row of data || []) {
    if (!map[row.admin_id]) map[row.admin_id] = [];
    map[row.admin_id].push(row.mail_kind);
  }
  return map;
}

// 메일 종류 카탈로그 fetch (lookup_values)
async function fetchAdminEmailKinds() {
  if (!db) return [];
  const {data, error} = await db.from('lookup_values')
    .select('code, name_ko, sort_order')
    .eq('kind', 'admin_email_kind')
    .eq('active', true)
    .order('sort_order');
  if (error) throw error;
  return data || [];
}

// 한 관리자의 메일 구독 일괄 저장 (UPSERT)
async function saveAdminEmailSubscriptions(adminId, subscribedKinds /* Set<string> */, allKinds /* Array<{code}> */) {
  if (!db) return;
  const rows = allKinds.map(k => ({
    admin_id: adminId,
    mail_kind: k.code,
    subscribed: subscribedKinds.has(k.code),
    updated_at: new Date().toISOString()
  }));
  const {error} = await db.from('admin_email_subscriptions')
    .upsert(rows, {onConflict: 'admin_id,mail_kind'});
  if (error) throw error;
}
```

### 3-5. 기존 `toggleAdminBrandNotify` 처리

- 기존 단일 토글 함수는 제거 (admin.js 4012~4024줄)
- HTML 인라인 onclick `toggleAdminBrandNotify(...)` 호출 라인도 제거
- 기존 `admins.receive_brand_notify` 컬럼은 RPC/Edge Function이 더 이상 참조하지 않도록 변경

---

## 4. Edge Function 영향

### 4-1. `notify-brand-application` (기존)

- 현재: `SELECT email FROM admins WHERE receive_brand_notify = true`
- 변경: `SELECT email FROM get_subscribed_admin_emails('brand_notify')` 또는 직접 JOIN 쿼리
- env `NOTIFY_ADMIN_EMAILS` 합산 로직은 그대로 유지

### 4-2. `notify-application-cancelled` (신청 취소 사양 PR-D)

- 신청 취소 사양에서 「수신자: admins.receive_brand_notify=true」 라고 잡았었음 → **본 작업 결과 반영**
- 변경 후: `SELECT email FROM get_subscribed_admin_emails('application_cancel')`
- 신청 취소 사양 §6-1 수신자 줄은 본 작업 머지 후 업데이트 필요 (사양서 §6 갱신)

---

## 5. 신청 취소 사양과의 의존성

- 본 작업이 신청 취소 PR-D보다 먼저 머지되어야 신청 취소 알림이 올바른 수신자에게 발송됨
- 만약 신청 취소 PR-D가 먼저 머지되면 임시로 `receive_brand_notify=true` 관리자에게 응모 취소 메일까지 가게 됨 (오발송 위험)
- **권장 머지 순서**: PR #152·#153 → **본 사양 PR** → 신청 취소 PR-A → 신청 취소 PR-B/C/D/E
- 신청 취소 사양 §1·§6-1에 의존성 메모 추가 필요 (별도 Edit)

---

## 6. PR 분할

본 작업은 단일 PR로 진행:

| 단계 | 범위 | 파일 |
|---|---|---|
| 1 | 마이그레이션 (테이블 + lookup seed + 데이터 이관 + 헬퍼 함수) | `supabase/migrations/{N}_admin_email_subscriptions.sql` |
| 2 | storage.js 함수 3개 | `dev/lib/storage.js` |
| 3 | 관리자 계정 페인 row 렌더 + 칩 표시 + 「설정」 버튼 | `dev/js/admin.js` (관리자 계정 영역 ~30줄) |
| 4 | 메일 받기 설정 모달 HTML + open/save 함수 | `dev/admin/app.js` 또는 `dev/js/admin.js`, `dev/index.html` admin 부분 |
| 5 | 기존 토글 코드 제거 (`toggleAdminBrandNotify`) | `dev/js/admin.js` |
| 6 | `notify-brand-application` Edge Function 수신자 쿼리 변경 | `supabase/functions/notify-brand-application/index.ts` |

---

## 7. QA 시나리오 (개발서버 → reverb-qa-tester)

1. 마이그레이션 적용 → 기존 `receive_brand_notify=true` 관리자의 `admin_email_subscriptions(mail_kind='brand_notify', subscribed=true)` 행이 자동 생성됐는지 확인
2. 관리자 계정 페인 → 「메일받기」 열에 「브랜드 서베이」 칩이 기존 수신자에게 표시
3. 일반 관리자 계정의 「설정」 버튼 클릭 → 모달 열림 → 「응모 취소 알림」 체크 → 저장 → 칩 추가 확인
4. super_admin이 다른 관리자의 「설정」 버튼 클릭 → 모달 열려서 편집 가능
5. campaign_manager 권한으로 다른 관리자 행의 「설정」 버튼 비활성 또는 비표시 확인
6. 콘솔에서 RPC 직접 호출로 다른 관리자 행 변경 시도 (campaign_manager 권한) → RLS에서 차단
7. 브랜드 서베이 폼 제출 → 새 메일 인프라로 발송되는지 확인 (`notify-brand-application` Edge Function 로그)
8. 신청 취소 PR-D 머지 후: 구매기간 이후 응모 취소 발생 → 「응모 취소 알림」 구독 관리자에게만 메일 발송
9. 메일 종류 신규 추가 시뮬레이션: `lookup_values`에 새 행 INSERT → 모달에서 즉시 노출되는지 확인

---

## 8. 약관·개인정보처리방침 영향

- 관리자 내부 시스템 설정. 인플루언서·광고주 데이터 처리 아님 → 약관/정책 변경 **없음**
- `/약관확인` 호출 불필요

---

## 9. 롤백 절차

1. `notify-brand-application` Edge Function 수신자 쿼리를 원복 (`receive_brand_notify=true` 직접 참조)
2. `dev/js/admin.js`에서 새 모달 코드 제거 + 기존 토글 코드 복원
3. SQL: `DROP TABLE admin_email_subscriptions CASCADE;` (lookup_values seed 2건도 비활성화)
4. `admins.receive_brand_notify` 컬럼 COMMENT 원복

**주의**: 본 사양 머지 후 운영 데이터(구독 행)가 쌓이면 롤백 시 데이터 손실. 머지 전 dev 검증 필수.

---

## 10. 충돌 점검 (PR #152·#153 / 신청 취소 사양과의 관계)

- PR #152 (admin-split Phase 0): admin.js 주석 + SECTION 마커 추가. 본 작업과 영역 다름 → 충돌 없음
- PR #153 (제출마감-19일): admin.js의 캠페인 폼 부분(line 1430~1692). 본 작업은 관리자 계정 페인(line ~3990) → 영역 다름, 충돌 없음
- 신청 취소 사양: §6-1 수신자 로직만 본 작업 결과로 업데이트 필요

→ **본 작업은 PR #152·#153 머지 대기 불필요**. 지금 바로 별도 worktree에서 진행 가능

---

## 11. 시작 절차

```bash
cd ~/Documents/projects/reverb-jp
git checkout dev
git pull origin dev

# 마이그레이션 번호 확인
ls supabase/migrations/ | tail -5

# /새세션 admin-email-subs 실행하여 worktree 생성
# 새 worktree에서 §6 PR 단계 순차 진행
```

---

## 12. 미해결

- 메일 종류 카탈로그에 미래 추가 후보가 있는지: 본 사양 범위 외. 운영팀 요청 시 lookup 한 줄 추가
- `admins.receive_brand_notify` 컬럼 정식 DROP 시점: 본 사양 머지 후 1~2 배포 사이클 안정성 확인 후 별도 마이그레이션 → **2026-05-18 기준 아직 DROP 안 됨 (deprecated 유지)**

---

## 13. 구현 결과

**구현일**: 2026-05-11
**운영 적용일**: 2026-05-11 (양 DB)
**관련 커밋**: `7153b03 feat(admin): split admin email subscriptions into per-kind table`
**관련 마이그레이션**: 103 (`admin_email_subscriptions` 테이블 + `get_subscribed_admin_emails()` 원격 호출 함수(RPC) + `lookup_values(kind='admin_email_kind')` 시드)

### 초안 대비 변경 사항
- **추가된 것**:
  - `admin_email_kind` lookup 시드 2건 (`brand_notify`, `application_cancel`) — 초안의 「초기 2종」 결정대로
  - 2026-05-18 마이그레이션 130 시점에 `application_received` 추가 (3종) — 본 사양과 별개 신청 접수 일일 요약 메일 도입에 따른 추가
  - 2026-05-18 마이그레이션 130 안에서 「전체 관리자 기본 ON」 시드 자동화 — 신규 lookup 추가 시 모든 관리자에게 자동 구독 ON
- **빠진 것**: 없음
- **달라진 것**:
  - `admins.receive_brand_notify` 컬럼은 즉시 DROP 안 함 (deprecated 유지) — 안정성 보강 후 별도 마이그레이션 예정
  - 본 사양에서 메일 종류 추가는 「lookup 한 줄 추가」 라고 명시했는데, 실제 운영에서 마이그레이션 130 추가 시 lookup_values + admin_email_subscriptions 시드 두 곳 모두 갱신 필요했음 — UX 충실히 유지하려면 「신규 lookup 추가 → 기본 ON 시드 추가」 2단계로 정착

### 구현 중 기술 결정 사항
- 행 단위 보안 정책(RLS): SELECT 는 관리자 전체 (`is_admin()`), INSERT/UPDATE/DELETE 는 본인 또는 super_admin (분리 정책)
- `get_subscribed_admin_emails(p_mail_kind text) RETURNS TABLE(email text)` — Edge Function 들의 표준 수신자 조회 헬퍼. 매번 admin_email_subscriptions JOIN admins 패턴 반복 제거
- 관리자 페인 「설정」 모달은 본인은 항상 편집 가능, super_admin 은 타 관리자도 편집 가능. 클라이언트 + 행 단위 보안 정책 양쪽 가드

### 후속 작업
- **마이그레이션 130 (2026-05-18)**: `application_received` 메일 종류 추가 (PR 「캠페인 신청 접수 일일 요약」)
- **마이그레이션 132 (2026-05-18, PR 2)**: 관리자 통합 다이제스트(`notify-admin-daily-digest`) 에서 합집합 수신자 패턴 사용 — `get_subscribed_admin_emails('application_cancel') ∪ get_subscribed_admin_emails('application_received')` ∪ env. 본 사양의 헬퍼 함수가 핵심 인프라로 동작
