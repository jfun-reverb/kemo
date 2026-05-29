# 감사용 인플 계정 메커니즘 (운영 모니터링용)

**작성일:** 2026-05-28
**상태:** 기획 초안 (개발 미진입)
**작성 세션:** 기획/설계 세션

---

## 1. 배경 / 문제

### 현재 상태
- 운영서버에 배포된 기능을 관리자가 검증하기 어려움
- 인플루언서 한 명이 거치는 단계(응모 → 승인 → 영수증 제출 → 검수 → 결과물 → 정산)에서 각 단계의 알림·메일·화면 분기가 제대로 동작하는지 인플 본인 입장에서 직접 확인할 방법 없음
- 개발서버에서는 검증 가능하지만 운영서버는 실 데이터·실 메일 발송 환경이라 같은 검증 불가능
- 테스트 인플 계정(`sakura.test@reverb.jp` 등)이 개발서버에는 있으나 운영서버에는 없고, 식별 메커니즘도 없음

### 문제
- 운영서버 배포 후 회귀·이상 동작을 발견하는 채널이 「인플 문의」 외 거의 없음
- 알림 발송이 누락된 경우 운영자가 인지하기 어려움
- 캠페인 진행 단계별 인플 화면이 의도대로 노출되는지 본인 입장에서 확인 불가

### 목표
- **운영서버에서도 관리자가 인플 동선을 본인 입장에서 시뮬레이션** 가능
- 단 **실 운영 데이터(통계·산출물·슬롯)에 흔적·영향 0**
- 시각적으로 「감사용」임을 강제 표시 → 운영 혼선 방지
- 캠페인별·전체 단위로 「흔적 청소」 메뉴 제공

---

## 2. 현재 상태 (planning.md 규칙 A — 2026-05-28 검증)

### 격리해야 할 6 영역 — 코드·DB 직접 확인 결과

| 영역 | 현재 구현 위치 | 격리 방향 |
|---|---|---|
| 응모수 카운팅 | `supabase/migrations/151_campaign_application_counts.sql` RPC `get_campaign_application_counts()` 매번 SELECT 집계 (트리거 카운터 아님) | RPC 본문에 `JOIN influencers + AND NOT is_audit` 한 줄 추가 |
| `influencers` 스키마 | `is_audit` 컬럼 없음. 002·019·140 등에 컬럼 누적 | 신규 마이그 — `ALTER TABLE` + 공용 1개 시드 |
| `fetchInfluencers()` | `dev/lib/storage.js:268` 전건 fetch, 엑셀 export 4곳 + 대시보드 + 다수 페인 공용 호출 | `fetchInfluencers({includeAudit})` 옵션 인자화 |
| 엑셀 export 4곳 | `dev/js/admin-excel.js:287/415/720/872` 모두 `fetchInfluencers()` 호출 | 다운로드 클릭 시 「감사용 포함·제외」 모달 1개 → 옵션 전달 |
| 다이제스트 메일 | `notify-influencer-daily-digest`·`notify-campaign-promo-digest` 가 `FROM public.influencers i` 직접 참조 | 수신은 유지 (사용자 결정 2/5) — RPC 미수정 |
| 대시보드 KPI·통계 | `dev/js/admin-dashboard.js` 인플·신청·승인 카운트 | `is_audit` 제외 SELECT 또는 클라이언트 필터 |

### 충돌 점검 — 없음

- 마이그 156 (closed→ended 자동 전이) — 응모건 status 와 무관, 영향 없음
- 마이그 154 (application_approved 알림) — 감사용도 알림 받음(검증 목적), 충돌 아님
- 마이그 144·145 (응모건 메시지 PR 1·2) — 감사용 응모건의 메시지도 자연 동작, 메시지 페인에 「감사용」 배지만 추가하면 됨
- 마이그 152 (관리자 홍보 메일 토글) — 감사용은 인플 측 메일만 수신, 관리자 메일 별도

### 미해결 백로그 관련 작업
- 메모리 `project_messaging_pr1.md`·`project_messaging_pr2.md` — 응모건 메시지 PR 1·2 운영 보류 중. 감사용 계정이 메시지 페인에 노출될 때 「감사용」 배지 강제 표시 필요
- 메모리 `project_admin_js_split.md` — admin.js 페인 분리 완료. 감사용 표식은 각 admin-*.js 파일에 분산 적용 필요

---

## 3. 의심·경우의 수 (planning.md 규칙 B — 2026-05-28 정리)

### 깨질 가능성

| # | 카테고리 | 시나리오 | 대응 방향 |
|---|---|---|---|
| ① | 기술 — 격리 누락 | 한 페인에서 `is_audit` 필터 빠지면 광고주 산출물·통계 오염. 신규 페인 추가 시 누락 위험 영구 누적 | DB 단계 격리(RPC 본문)를 default 로, 클라이언트 필터는 보조 |
| ② | 기술 — 다이제스트 메일 폭주 | 사용자 결정으로 메일 수신 유지. 운영자 인박스(감사용 계정 이메일)에 매일 다이제스트 누적 | 감사용 계정 이메일을 별도 라벨/필터 가능한 형태(예: `audit+date@reverb.jp` 또는 운영자 본인 메일 별칭)로 설정 |
| ③ | UX — 시각 표식 누락 | 일부 페인에 「감사용」 배지 안 떠 운영자가 일반 인플로 오인 → 잘못된 검수 처분 | 공용 헬퍼 `auditBadge(infOrApp)` 도입 + 모든 페인 행 렌더에 강제 호출 |
| ④ | UX — 흔적 제거 후 ghost 데이터 | 흔적 제거 시 application_message_hide_history 같은 audit 테이블도 cascade. 운영팀 내부 감사 정보 손실 위험 | 흔적 제거 단위로 「감사용 계정 데이터만 cascade, 운영 audit 보존」 결정 필요 — 본 사양서 §4-4 명시 |
| ⑤ | 권한 — 흔적 제거 권한 | 누구나 「흔적 제거」 누르면 광고주 산출물 보호 정책 우회 가능 | super_admin 한정 |
| ⑥ | 데이터 — 응모 슬롯 | monitor 캠페인은 `slots` 도달 시 hard 차단. 감사용이 슬롯 잡으면 진짜 인플 응모 불가 | 슬롯 검증 트리거에도 `AND NOT is_audit` 적용 |
| ⑦ | 데이터 — 캠페인 진행현황 「선정 N/M」 | 광고주에게 보고하는 진행 카운트 | `get_campaign_application_counts` 격리로 자동 해결 |
| ⑧ | 약관·법률 | 감사용 계정이 운영팀 본인이므로 PIPA·APPI 영향 없음. 단 감사용도 동의 기록(`terms_agreed_at` 등)이 필요한지 | 운영팀 본인 동의로 처리, 약관 명시 불필요 |
| ⑨ | UX — 엑셀 모달 부담 | 매 엑셀 다운로드마다 「감사용 포함·제외」 모달은 운영 부담 | 모달에 「다음부터 묻지 않음 (현재 세션)」 옵션. 단 새 페이지 로드 시 초기화 |

### 현재 구현 충돌점
- 없음 (응모수 카운팅이 트리거 기반이 아니라 RPC 1곳 수정만으로 격리 가능 — 큰 호재)

### 의도 모호점 (사용자 확인 후 본 사양서 §3-결정 사항으로 확정)
- 모호점 5개 → 2026-05-28 사용자 확정 완료 (본 §3-결정 사항 참조)

---

## 4. 결정 사항 (2026-05-28 사용자 확정)

| 항목 | 결정 |
|---|---|
| 시각 표식 | 「감사용」 명시 배지, 모든 페인 강제 노출 (강함) |
| 결과물 검수 | 일반 인플과 동일 검수 단계 진행 (검수 분기·메일·알림 검증 목적) |
| 메일 수신 | 일반 인플처럼 동일 자동 발송 메일 수신 (다이제스트·홍보·임박 등) |
| 신청 가능 범위 | 모든 모집중 캠페인 신청 가능 (격리 메커니즘으로 영향 차단) |
| 계정 수 | 공용 1개 (super_admin 대표 관리) |
| 흔적 제거 단위 | 캠페인별 부분 청소 + 전체 청소 **둘 다 제공** |
| 엑셀 산출물 보호 | 다운로드 클릭 시 매번 「감사용 N명 포함·제외」 확인 모달 |
| 흔적 제거 권한 | super_admin 한정 |

---

## 5. 제안 / 설계

### 5-1. DB 스키마

#### 신규 마이그레이션 (번호 TBD — `supabase/migrations/` 마지막 번호 확인 후 다음 번호 사용)

```sql
-- 1. influencers 테이블에 is_audit 컬럼 추가
ALTER TABLE public.influencers
  ADD COLUMN is_audit boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.influencers.is_audit IS
  '감사용 계정 여부. true 면 응모·결과물·통계·엑셀 산출물에서 격리됨. 운영팀 본인 시뮬레이션용';

CREATE INDEX idx_influencers_is_audit
  ON public.influencers (is_audit)
  WHERE is_audit = true;
-- 일반 인플이 압도적 다수이므로 partial index 로 비용 최소화

-- 2. get_campaign_application_counts RPC 본문 수정 (151 재정의)
CREATE OR REPLACE FUNCTION public.get_campaign_application_counts()
RETURNS TABLE(
  campaign_id uuid,
  total       bigint,
  approved    bigint,
  pending     bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    a.campaign_id,
    COUNT(*) FILTER (WHERE a.status <> 'cancelled') AS total,
    COUNT(*) FILTER (WHERE a.status = 'approved')   AS approved,
    COUNT(*) FILTER (WHERE a.status = 'pending')    AS pending
  FROM public.applications a
  JOIN public.influencers i ON i.id = a.user_id  -- 감사용 격리 위해 JOIN 추가
  WHERE i.is_audit = false                       -- 감사용 제외
  GROUP BY a.campaign_id;
END;
$$;

-- 3. monitor 캠페인 모집 슬롯 차단 — 감사용 응모는 slots 한도에 카운트 안 함
-- (현재 트리거 확인 후 적용 — application_inserts·application_approves 등에서 slots 검증)
-- 작업 분할 6c 단계에서 코드·트리거 상세 확인 후 결정

-- 4. 공용 감사용 인플 계정 1건 시드 (운영서버)
-- auth.users 생성은 Supabase Auth invite 또는 직접 SQL 로 분리. 사양서 §6 참조
```

#### auth 계정·influencer 행 시드 (운영 적용 시점)
- 이메일: 운영팀이 결정 (예: `audit@globalreverb.com` 또는 super_admin 본인 이메일 별칭 `audit+{date}@...`)
- 이름·SNS 핸들: 「감사용」 명시 (예: name_kanji `監査用`, 핸들 `audit_reverb`)
- `is_audit = true` 설정
- `terms_agreed_at`·`privacy_agreed_at`: 운영팀 본인 동의 시점으로 기록

### 5-2. 클라이언트 격리

#### `dev/lib/storage.js` — fetchInfluencers 옵션화

```javascript
// 현재
async function fetchInfluencers() {
  if (!db) return [];
  try {
    return await fetchAllPaged(() =>
      db.from('influencers').select('*').order('created_at', {ascending: true})
    );
  } catch(e) { return []; }
}

// 수정 — 옵션 추가
async function fetchInfluencers(opts = {}) {
  if (!db) return [];
  const { includeAudit = false } = opts;
  try {
    return await fetchAllPaged(() => {
      let q = db.from('influencers').select('*').order('created_at', {ascending: true});
      if (!includeAudit) q = q.eq('is_audit', false);
      return q;
    });
  } catch(e) { return []; }
}
```

**호출처별 기본값:**
- 대시보드 KPI: `includeAudit: false` (통계 격리)
- 인플 관리 페인 행 목록: `includeAudit: true` (운영자가 감사용도 봐야 함, 배지로 구분)
- 신청 관리 페인: `includeAudit: true` (검수 단계 시각 검증)
- 결과물 관리 페인: `includeAudit: true`
- 엑셀 export 4곳: 모달 사용자 선택에 따라 동적 — 기본 `false`

#### 인플 시각 배지 공용 헬퍼

`dev/lib/shared.js` 에 추가:

```javascript
function auditBadgeHtml(inf) {
  if (!inf || !inf.is_audit) return '';
  return '<span class="audit-badge" title="감사용 계정 — 통계·산출물 격리됨">감사용</span>';
}
```

CSS (`dev/css/admin.css`):

```css
.audit-badge {
  display: inline-block;
  padding: 2px 8px;
  background: #ff9800;
  color: #fff;
  font-size: 11px;
  font-weight: 700;
  border-radius: 3px;
  margin-left: 4px;
}
.audit-row {
  background: #fff3e0;  /* 행 자체 배경도 옅게 강조 */
}
```

**적용 페인 (모든 인플·응모건·결과물 행 렌더):**
- 인플 관리 페인 (`admin-influencers.js`)
- 신청 관리 페인 (`admin-applications.js`)
- 결과물 관리 페인 (`admin-deliverables.js`)
- 캠페인별 신청자 페인 (camp-applicants)
- 메시지 받은편지함 (`admin-messaging.js`)
- 대시보드 최근 신청 (`admin-dashboard.js`)

### 5-3. 엑셀 산출물 보호 — 다운로드 확인 모달

#### 모달 패턴

엑셀 다운로드 버튼 4곳 (admin-excel.js 287·415·720·872) 클릭 시:

```
┌────────────────────────────────────────┐
│ 엑셀 다운로드 — 감사용 계정 처리       │
├────────────────────────────────────────┤
│ 현재 결과에 감사용 계정 N명이 포함되어 │
│ 있습니다. 광고주 산출물에 포함할까요?  │
│                                        │
│ ○ 감사용 제외 (광고주 전달용) (추천)   │
│ ○ 감사용 포함 (운영 내부 확인용)       │
│                                        │
│           [취소]  [엑셀 다운로드]      │
└────────────────────────────────────────┘
```

- 결과에 감사용 0명이면 모달 생략 (바로 다운로드)
- 「제외」 선택 시 `fetchInfluencers({includeAudit: false})` + 엑셀 생성
- 「포함」 선택 시 `fetchInfluencers({includeAudit: true})` + 시트1 「캠페인 정보」 상단에 「감사용 N행 포함」 경고 행 자동 추가

### 5-4. 흔적 제거 RPC

#### 5-4-1. 전체 청소 — `purge_audit_data_all()`

```sql
CREATE OR REPLACE FUNCTION public.purge_audit_data_all()
RETURNS jsonb  -- {deleted: {applications:N, deliverables:N, messages:N, ...}}
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_audit_ids uuid[];
  v_result jsonb;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '권한 없음 (super_admin 한정)';
  END IF;

  SELECT array_agg(id) INTO v_audit_ids
    FROM public.influencers WHERE is_audit = true;

  IF v_audit_ids IS NULL OR cardinality(v_audit_ids) = 0 THEN
    RETURN jsonb_build_object('status', 'no_audit_account');
  END IF;

  -- 1. application_messages 첨부 Storage 파일 path 회수 (cascade 전에)
  -- (Storage 파일 삭제는 클라이언트가 후속 수행 — 반환된 path 배열 사용)

  -- 2. cascade delete (FK ON DELETE CASCADE 의존)
  --    applications, deliverables, deliverable_events, application_events,
  --    application_messages, notifications, application_message_resolutions,
  --    application_message_admin_reads, broadcast_id NULL 처리
  DELETE FROM public.applications WHERE user_id = ANY(v_audit_ids);
  DELETE FROM public.notifications WHERE user_id = ANY(v_audit_ids);
  -- (deliverables 는 applications CASCADE 로 자동 정리)

  -- 3. 결과 집계 (대략적인 수치)
  v_result := jsonb_build_object(
    'status', 'ok',
    'audit_account_count', cardinality(v_audit_ids)
  );

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.purge_audit_data_all() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.purge_audit_data_all() TO authenticated;
```

#### 5-4-2. 캠페인별 부분 청소 — `purge_audit_data_for_campaign(uuid)`

```sql
CREATE OR REPLACE FUNCTION public.purge_audit_data_for_campaign(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_audit_ids uuid[];
  v_app_ids uuid[];
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '권한 없음 (super_admin 한정)';
  END IF;

  SELECT array_agg(id) INTO v_audit_ids
    FROM public.influencers WHERE is_audit = true;

  IF v_audit_ids IS NULL OR cardinality(v_audit_ids) = 0 THEN
    RETURN jsonb_build_object('status', 'no_audit_account');
  END IF;

  -- 해당 캠페인의 감사용 응모건만 cascade delete
  DELETE FROM public.applications
   WHERE campaign_id = p_campaign_id
     AND user_id = ANY(v_audit_ids);

  RETURN jsonb_build_object('status', 'ok', 'campaign_id', p_campaign_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.purge_audit_data_for_campaign(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.purge_audit_data_for_campaign(uuid) TO authenticated;
```

**Storage 첨부 파일 처리:**
- 응모건 CASCADE delete 후 Storage 의 결과물·메시지 첨부 파일은 path 가 응모건 ID 기반이라 별도 정리 RPC 또는 클라이언트 후속 삭제 호출 필요
- 작업 분할 단계에서 Storage cleanup 처리 패턴 확정

### 5-5. UI — 흔적 제거 메뉴 위치

#### 5-5-1. 캠페인별 부분 청소
- 위치: `#adminPane-campaigns` 캠페인 더보기 메뉴 (기존 「결과물 엑셀·신청자 엑셀·변경 이력」 옆)
- 메뉴 라벨: 「감사용 흔적 청소」 (super_admin 한정 노출)
- 클릭 시 확인 모달: 「캠페인 X 안에서 감사용 계정이 만든 응모·결과물·메시지를 모두 삭제합니다. 진행할까요?」 + 영향 카운트 미리보기

#### 5-5-2. 전체 청소
- 위치: `#adminPane-influencers` 인플 관리 페인 상단 (감사용 행 옆 「전체 흔적 청소」 작은 버튼) 또는 별도 「관리자 도구」 페인
- 권장: 인플 관리 페인 감사용 행을 클릭하면 상세 모달 안 「흔적 청소」 섹션 등장 (캠페인별 N개 + 「전체 청소」 한 번에)

---

## 6. 영향 범위

| 영역 | 변경 |
|---|---|
| DB | 마이그 (번호 TBD) — `is_audit` 컬럼 + 인덱스 + `get_campaign_application_counts` 재정의 + `purge_audit_data_all` + `purge_audit_data_for_campaign` 2종 + 공용 감사용 계정 시드 |
| storage.js | `fetchInfluencers(opts)` 옵션화 + `purgeAuditDataAll`/`purgeAuditDataForCampaign` 함수 추가 |
| admin-excel.js | 4개 export 함수에 「감사용 포함·제외」 모달 진입 |
| admin-influencers.js / admin-applications.js / admin-deliverables.js / admin-dashboard.js / admin-messaging.js | 행 렌더에 `auditBadgeHtml(inf)` 호출 추가 |
| admin-dashboard.js | KPI·통계 SELECT 에서 `is_audit` 제외 |
| admin.js (캠페인 더보기 메뉴) | 「감사용 흔적 청소」 메뉴 항목 추가 (super_admin 한정) |
| shared.js | `auditBadgeHtml` 헬퍼 추가 |
| admin.css | `.audit-badge`·`.audit-row` 스타일 |
| 문서 | `FEATURE_SPEC.md`, `CLAUDE.md` Features — 관리자 섹션에 감사용 메커니즘 추가 |
| 약관 | 영향 없음 (운영팀 본인 동의로 처리) |
| Storage 정책 | 미변경 (감사용은 일반 인플과 동일 path 사용) |

---

## 7. PR 분할 (작업 분할 권장안)

| 단계 | 범위 | 의존성 |
|---|---|---|
| A — 데이터베이스 | 신규 마이그 — `is_audit` 컬럼 + 인덱스 + `get_campaign_application_counts` 재정의 + 흔적 제거 RPC 2종 + 공용 감사용 계정 시드 | (독립) |
| B — storage.js | `fetchInfluencers(opts)` 옵션화 + `purgeAuditDataAll`/`purgeAuditDataForCampaign` 추가 | A |
| C — UI 시각 표식 | `auditBadgeHtml` 공용 헬퍼 + 6개 페인 행 렌더에 호출 추가 + CSS | B |
| D — 엑셀 보호 모달 | 4개 엑셀 export 함수에 「감사용 포함·제외」 모달 진입 | B |
| E — 흔적 청소 UI | 캠페인 더보기 메뉴 + 인플 상세 모달 「흔적 청소」 섹션 + 확인 모달 | B |
| F — 대시보드 KPI 격리 | 대시보드 SELECT 에서 `is_audit` 제외 | A·B |
| G — qa·문서 | qa full + `FEATURE_SPEC.md` + `CLAUDE.md` + 본 사양서 §구현 결과 작성 | A~F |

각 단계 commit 직전 `reverb-reviewer` 호출 + 머지 전 `reverb-qa-tester` light/full PASS.

---

## 8. qa 시나리오

- 감사용 계정으로 캠페인 응모 시 캠페인 카드 「N명 신청」 숫자에 안 잡힘
- 감사용 응모건이 결과물 관리 페인에 「감사용」 배지와 함께 노출
- 검수 단계 메일·알림 모두 감사용 계정으로 정상 도착
- 엑셀 다운로드 시 감사용 N명 포함된 결과는 모달 발동, 0명일 때는 모달 생략
- 「감사용 제외」 선택 시 엑셀에 행 없음, 「포함」 시 시트1 상단에 경고 행
- 대시보드 KPI (인플 수·신청 수·승인 수) 감사용 제외
- 인플 일일 다이제스트 메일 감사용 계정도 수신 (사용자 결정 2/5)
- 캠페인별 흔적 청소 후 해당 캠페인 응모건·결과물·메시지 cascade delete 확인
- 전체 흔적 청소 후 감사용 계정 행은 유지되지만 응모·결과물·알림 모두 0건
- super_admin 외 (campaign_admin·campaign_manager) 흔적 청소 버튼 비노출
- 응모 슬롯 monitor 캠페인 슬롯 한도에 감사용 제외 (작업 분할 A 단계 슬롯 검증 트리거 확인 후 확정)

---

## 9. 약관·개인정보 영향

- 영향 없음 — 감사용 계정 본인이 운영팀이므로 PIPA·APPI 「제3자 처리」 아님
- `/약관확인` 슬래시 커맨드 실행 불필요
- 단 약관 문서에 「운영팀 감사용 계정 운영 가능」 명시는 선택 사항 (감사용 인플의 존재를 광고주에게 사전 안내하는 차원). 본 사양서 범위 외

---

## 10. 미해결 / 추후 검토 (v2)

- 감사용 계정 추가 생성 (현재 공용 1개) — 운영 규모 확대 시 검토
- 감사용 행 상세 모달에 「실시간 응모 단계 시각화」 다이어그램 (응모→승인→영수증→검수→완료 진행바)
- 다른 인플 화면 미리보기 (impersonate 패턴) — 본 사양서 범위 외, 보안·약관 검토 별건
- Sentry / LogRocket 같은 외부 모니터링 도구 도입 — 본 사양서 범위 외

---

## 구현 결과 (개발 세션이 채울 것)

(개발 세션이 PR A~G 진행 후 작성)
