# 응모 단계별 메일 파이프라인 사양서 (인플루언서 통합 다이제스트 + 관리자 다이제스트)

- **작성일**: 2026-05-18
- **작성**: 기획/설계 세션 (메인 폴더, 코드 미수정)
- **상태**: ✅ **운영 배포 완료 (2026-05-18)** — 마이그레이션 130 운영 DB 적용 완료. Edge Function 2종(`notify-influencer-daily-digest`, `notify-application-received-admin-daily`) 운영 배포. cron 2종 모두 가동 중 (관리자 접수 요약 + 인플루언서 다이제스트 — mail-pipeline-consolidation PR 2 에서 통합 전환 완료). **dev 잠재, main merge 보류 중**
- **우선순위**: 🟢 완료
- **선행**: 없음. 기존 인프라 재사용 (`notify-application-cancelled-daily` 패턴 미러)
- **마이그레이션**: 130 (`supabase/migrations/130_application_email_pipeline_infra.sql`) — 운영 DB 적용 완료
- **연관 별도 사양** (예정): `applications.reject_reason` 컬럼 + 운영자 입력 UI — 본 사양 도입 후 후속

---

## 1. 배경 및 목표

### 현재 상태
- 인플루언서가 응모해도 본인·관리자에게 **자동 메일 안내가 없다**
- 관리자가 응모를 승인·반려해도 인플루언서는 앱 안 알림만 받음 — 메일 안 옴
- 영수증·결과물 제출 마감일 임박 알림이 **없다** → 인플루언서가 잊고 제출 누락하는 사례 발생
- LINE @reverb.jp 로 개별 안내하는 비공식 흐름

### 목표
응모 단계별 5가지 이벤트(접수·접수확인·승인·반려·마감 임박)를 **인플루언서당 매일 09:00(KST) 1통 통합 메일** + **관리자에게 접수 요약 1통** 으로 발송.

기존 `notify-application-cancelled-daily` 인프라(pg_cron + Edge Function + Brevo SMTP) 그대로 재사용.

---

## 2. 메일 2종 구조 (재설계)

사용자 결정 「인플루언서당 하루 최대 1통, 모든 종류 묶음」 반영. Edge Function 5개 분리 안 → **2개 통합** 으로 단순화.

| 메일 | 수신자 | Edge Function | 발송 조건 | 묶음 단위 |
|---|---|---|---|---|
| **인플루언서 통합 다이제스트** | 인플루언서 | `notify-influencer-daily-digest` | 4개 섹션 중 1개라도 0건 초과 시 | 인플루언서당 1통/일 |
| **관리자 접수 다이제스트** | 관리자 | `notify-application-received-admin-daily` | 전일 응모 1건 이상 시 | digest 1통/일 |

### 인플루언서 통합 메일 본문 4섹션 구성

```
┌────────────────────────────────────────────────────────┐
│ 【REVERB】 본일の応募状況のお知らせ                       │
├────────────────────────────────────────────────────────┤
│ 1️⃣ 新規応募の受付完了 (어제 신청 N건)                    │
│    └ 캠페인 카드 N개                                     │
│                                                        │
│ 2️⃣ 応募が承認されました (어제 승인 N건)                  │
│    └ 캠페인 카드 N개 + 제출 마감일 + CTA「제출 시작」     │
│                                                        │
│ 3️⃣ 応募結果のお知らせ (어제 반려 N건)                    │
│    └ 캠페인 카드 N개 + 「다른 캠페인 보기」 CTA          │
│                                                        │
│ 4️⃣ 提出期限が近づいています (오늘 D-5/D-1 N건)            │
│    └ 캠페인 카드 N개 + 「제출하러 가기」 CTA             │
├────────────────────────────────────────────────────────┤
│ [응모이력 확인] [캠페인 더 보기]                        │
└────────────────────────────────────────────────────────┘
```

- **각 섹션 0건이면 그 섹션 자체 미노출** (조건부 렌더)
- 4섹션 모두 0건이면 메일 자체 미발송 (해당 인플루언서)
- 본문 상단에 「오늘의 알림 ({{total_sections}}건)」 인디케이터

---

## 3. 최종 결정 사항 (사용자 답변 반영, 2026-05-18)

| 항목 | 결정 |
|---|---|
| 묶음 정책 | **모두 1통으로 합쳐서 발송** (인플루언서당 하루 최대 1통) |
| 발송 시각 | 매일 한국시간 09:00 (UTC 00:00) |
| 마감일 기준 | 영수증 = `purchase_end` / 결과물 = `submission_end` (NULL이면 `post_deadline` 폴백) |
| 마감일 D-N | **D-5, D-1** (사용자 명시 그대로) |
| 재발송 방지 | `(인플루언서, 캠페인, 종류, D-N) UNIQUE` 로그 (마감 임박만) + 일별 다이제스트 `digest_date` UNIQUE |
| 수신 거부 | `marketing_opt_in` 무시. 무조건 발송 (트랜잭션 성격) |
| 관리자 「application_received」 수신 기본값 | **전체 관리자 기본 ON** |
| 반려 사유 표시 | **이번 범위 밖** — 일반 안내 「선정되지 않았습니다」 + 후속 별도 사양에서 `applications.reject_reason` 컬럼 도입 시 메일 템플릿이 자동으로 노출 |
| Edge Function 구조 | 인플루언서 통합 1개 + 관리자 1개 = **총 2개** |

---

## 4. 인플루언서 통합 메일의 4섹션 데이터 쿼리

### 4-1. 윈도우·기준 계산 (Edge Function 안)
- 어제 윈도우 (KST): `[어제 00:00, 오늘 00:00)` → `applications.created_at` / `applications.reviewed_at`
- 오늘 (KST) 날짜: `today_kst` → 마감일 D-N 계산 (`deadline - today_kst IN (5, 1)`)

### 4-2. 4섹션 통합 쿼리 (개념)

```sql
-- 어제 신청 (섹션 1)
WITH yesterday_kst AS (
  SELECT
    ((now() AT TIME ZONE 'Asia/Seoul')::date - 1)::timestamp AT TIME ZONE 'Asia/Seoul' AS w_start,
    ((now() AT TIME ZONE 'Asia/Seoul')::date)::timestamp     AT TIME ZONE 'Asia/Seoul' AS w_end,
    ((now() AT TIME ZONE 'Asia/Seoul')::date - 1)::date      AS digest_date,
    ((now() AT TIME ZONE 'Asia/Seoul')::date)::date          AS today
),
section_received AS (
  SELECT a.user_id AS influencer_id,
         json_build_object('kind','received', 'campaign_no', c.campaign_no,
                           'title', c.title, 'recruit_type', c.recruit_type,
                           'applied_at', a.created_at, 'deadline', c.deadline) AS item
  FROM applications a JOIN campaigns c ON c.id = a.campaign_id
  WHERE a.created_at >= (SELECT w_start FROM yesterday_kst)
    AND a.created_at <  (SELECT w_end   FROM yesterday_kst)
),
section_approved AS (
  SELECT a.user_id AS influencer_id,
         json_build_object('kind','approved', 'campaign_no', c.campaign_no,
                           'title', c.title, 'recruit_type', c.recruit_type,
                           'reviewed_at', a.reviewed_at, 'reward', c.reward,
                           'purchase_end', c.purchase_end,
                           'submission_end', COALESCE(c.submission_end, c.post_deadline)) AS item
  FROM applications a JOIN campaigns c ON c.id = a.campaign_id
  WHERE a.status = 'approved'
    AND a.reviewed_at >= (SELECT w_start FROM yesterday_kst)
    AND a.reviewed_at <  (SELECT w_end   FROM yesterday_kst)
),
section_rejected AS (
  SELECT a.user_id AS influencer_id,
         json_build_object('kind','rejected', 'campaign_no', c.campaign_no,
                           'title', c.title, 'reviewed_at', a.reviewed_at) AS item
  FROM applications a JOIN campaigns c ON c.id = a.campaign_id
  WHERE a.status = 'rejected'
    AND a.reviewed_at >= (SELECT w_start FROM yesterday_kst)
    AND a.reviewed_at <  (SELECT w_end   FROM yesterday_kst)
),
-- 오늘 D-5/D-1 임박 — 영수증
section_deadline_receipt AS (
  SELECT a.user_id AS influencer_id,
         json_build_object('kind','deadline_receipt', 'campaign_no', c.campaign_no,
                           'campaign_id', c.id, 'title', c.title,
                           'deadline', c.purchase_end,
                           'd_minus', (c.purchase_end - (SELECT today FROM yesterday_kst))) AS item
  FROM applications a JOIN campaigns c ON c.id = a.campaign_id
  WHERE a.status = 'approved'
    AND c.recruit_type = 'monitor'
    AND c.purchase_end IS NOT NULL
    AND (c.purchase_end - (SELECT today FROM yesterday_kst)) IN (5, 1)
    AND NOT EXISTS (
      SELECT 1 FROM deliverables d
       WHERE d.application_id = a.id AND d.kind = 'receipt'
         AND d.status IN ('pending','approved'))
    AND NOT EXISTS (
      SELECT 1 FROM deadline_reminder_email_sent s
       WHERE s.influencer_id = a.user_id AND s.campaign_id = c.id
         AND s.kind = 'receipt'
         AND s.d_minus = (c.purchase_end - (SELECT today FROM yesterday_kst)))
),
-- 오늘 D-5/D-1 임박 — 결과물
section_deadline_post AS (
  SELECT a.user_id AS influencer_id,
         json_build_object('kind','deadline_post', 'campaign_no', c.campaign_no,
                           'campaign_id', c.id, 'title', c.title,
                           'deadline', COALESCE(c.submission_end, c.post_deadline),
                           'd_minus', (COALESCE(c.submission_end, c.post_deadline) - (SELECT today FROM yesterday_kst))) AS item
  FROM applications a JOIN campaigns c ON c.id = a.campaign_id
  WHERE a.status = 'approved'
    AND COALESCE(c.submission_end, c.post_deadline) IS NOT NULL
    AND (COALESCE(c.submission_end, c.post_deadline) - (SELECT today FROM yesterday_kst)) IN (5, 1)
    AND NOT EXISTS (
      SELECT 1 FROM deliverables d
       WHERE d.application_id = a.id AND d.kind = 'post'
         AND d.status IN ('pending','approved'))
    AND NOT EXISTS (
      SELECT 1 FROM deadline_reminder_email_sent s
       WHERE s.influencer_id = a.user_id AND s.campaign_id = c.id
         AND s.kind = 'post'
         AND s.d_minus = (COALESCE(c.submission_end, c.post_deadline) - (SELECT today FROM yesterday_kst)))
),
all_items AS (
  SELECT * FROM section_received UNION ALL
  SELECT * FROM section_approved UNION ALL
  SELECT * FROM section_rejected UNION ALL
  SELECT * FROM section_deadline_receipt UNION ALL
  SELECT * FROM section_deadline_post
)
SELECT
  i.id AS influencer_id, i.email, i.name,
  array_agg(item) AS items
FROM all_items ai
JOIN influencers i ON i.id = ai.influencer_id
GROUP BY i.id, i.email, i.name;
```

Edge Function 은 위 결과를 받아 인플루언서별로 4섹션으로 분류·렌더링.

발송 직후 `deadline_reminder_email_sent` 에 `kind in ('receipt','post')` 항목만 일괄 INSERT (벌크) — D-N 재발송 방지.

---

## 5. 관리자 접수 다이제스트 메일 쿼리

```sql
WITH yesterday_kst AS (
  SELECT
    ((now() AT TIME ZONE 'Asia/Seoul')::date - 1)::timestamp AT TIME ZONE 'Asia/Seoul' AS w_start,
    ((now() AT TIME ZONE 'Asia/Seoul')::date)::timestamp     AT TIME ZONE 'Asia/Seoul' AS w_end
)
SELECT
  a.id, a.created_at,
  c.id AS campaign_id, c.title, c.campaign_no, c.recruit_type,
  i.id AS influencer_id, i.name, i.email, i.primary_sns
FROM applications a
JOIN campaigns c   ON c.id = a.campaign_id
JOIN influencers i ON i.id = a.user_id
WHERE a.created_at >= (SELECT w_start FROM yesterday_kst)
  AND a.created_at <  (SELECT w_end   FROM yesterday_kst)
ORDER BY c.title, a.created_at;
```

수신자: `get_subscribed_admin_emails('application_received')` ∪ env `NOTIFY_ADMIN_EMAILS`
- `lookup_values(kind='admin_email_kind')` 시드 1건 추가: `code='application_received'`, `name_ko='캠페인 신청 접수'`
- `admin_email_subscriptions` 자동 시드 (전체 관리자 기본 ON) — 마이그레이션 안에서 INSERT

본문: 캠페인별 그룹 → 인플루언서 리스트 (이름·이메일·SNS 핸들·신청 시각)
CTA: 「관리자 보기」 → `{{public_admin_url}}#applications?status=pending`

---

## 6. DB 변경 (마이그레이션 130)

**파일**: `supabase/migrations/130_application_email_pipeline_infra.sql`

### 6-1. 일별 다이제스트 발송 로그 2종 (`digest_date` UNIQUE)

```sql
CREATE TABLE public.influencer_daily_digest_runs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  digest_date     date NOT NULL UNIQUE,
  ran_at          timestamptz NOT NULL DEFAULT now(),
  status          text NOT NULL CHECK (status IN ('sent','skipped_no_data','failed')),
  total_influencers integer NOT NULL DEFAULT 0,  -- 발송 받은 인플루언서 수
  total_emails    integer NOT NULL DEFAULT 0,    -- 실제 발송 메일 수 (== total_influencers)
  error_message   text
);

CREATE TABLE public.application_received_admin_digest_runs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  digest_date     date NOT NULL UNIQUE,
  ran_at          timestamptz NOT NULL DEFAULT now(),
  status          text NOT NULL CHECK (status IN ('sent','skipped_no_data','failed')),
  total_applications integer NOT NULL DEFAULT 0,
  recipients_count integer NOT NULL DEFAULT 0,
  error_message   text
);
```

### 6-2. 마감일 임박 메일 발송 로그 (UNIQUE 키 재발송 방지)

```sql
CREATE TABLE public.deadline_reminder_email_sent (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id   uuid NOT NULL REFERENCES public.influencers(id) ON DELETE CASCADE,
  campaign_id     uuid NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,
  kind            text NOT NULL CHECK (kind IN ('receipt','post')),
  d_minus         integer NOT NULL CHECK (d_minus IN (5,1)),
  sent_at         timestamptz NOT NULL DEFAULT now(),
  deadline_date   date NOT NULL,  -- 발송 시점의 마감일 (변경 추적용)
  UNIQUE (influencer_id, campaign_id, kind, d_minus)
);

CREATE INDEX idx_deadline_reminder_email_lookup
  ON public.deadline_reminder_email_sent (campaign_id, kind);
```

> **참고**: 캠페인 마감일이 운영자에 의해 연장되면 같은 D-N 메일이 두 번 안 감. **추후 운영자 수동 reset 도구 필요할 수 있음** — 이번 범위 밖.

### 6-3. RLS 정책

- 3개 발송 로그 테이블 SELECT: `is_admin()`
- INSERT/UPDATE: Edge Function (service_role) — 정책 미정의
- `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` + admin SELECT 정책만

### 6-4. lookup_values 시드 추가

```sql
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES ('admin_email_kind', 'application_received', '캠페인 신청 접수', 'キャンペーン応募受付', 30, true)
ON CONFLICT (kind, code) DO NOTHING;
```

### 6-5. 관리자 메일 기본 구독 시드 (전체 ON)

```sql
INSERT INTO public.admin_email_subscriptions (admin_id, mail_kind)
SELECT a.auth_id, 'application_received'
FROM public.admins a
ON CONFLICT (admin_id, mail_kind) DO NOTHING;
```

### 6-6. 헬퍼 함수 (옵션)

```sql
-- 어제 한국시간 윈도우 반환
CREATE OR REPLACE FUNCTION public._yesterday_kst_window()
RETURNS TABLE (window_start timestamptz, window_end timestamptz, digest_date date, today_date date)
LANGUAGE sql STABLE AS $$
  SELECT
    ((now() AT TIME ZONE 'Asia/Seoul')::date - 1)::timestamp AT TIME ZONE 'Asia/Seoul',
    ((now() AT TIME ZONE 'Asia/Seoul')::date)::timestamp     AT TIME ZONE 'Asia/Seoul',
    ((now() AT TIME ZONE 'Asia/Seoul')::date - 1)::date,
    ((now() AT TIME ZONE 'Asia/Seoul')::date)::date;
$$;
```

---

## 7. Edge Function 2종

기존 `notify-application-cancelled-daily` 구조 그대로 미러링.

```
supabase/functions/
├── notify-influencer-daily-digest/
│   ├── index.ts
│   ├── templates.ts (sync 자동 생성)
│   └── _templates/
└── notify-application-received-admin-daily/
    ├── index.ts
    ├── templates.ts (sync 자동 생성)
    └── _templates/
```

### 7-1. 공통 환경 변수
- `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` (자동 주입)
- `BREVO_API_KEY` (양 서버 별도)
- `BREVO_SENDER_EMAIL` = `noreply@globalreverb.com`
- `BREVO_SENDER_NAME` = `REVERB JP` (개발은 `REVERB JP [DEV]`)
- `PUBLIC_APP_URL` = `https://globalreverb.com` (인플루언서 메일 딥링크용, 개발은 `https://dev.globalreverb.com`)
- `PUBLIC_ADMIN_URL` = `https://globalreverb.com/admin/` (관리자 메일 딥링크)
- `NOTIFY_ADMIN_EMAILS` (옵션, 외부 수신자 합산)

### 7-2. 공통 동작 흐름
1. 어제 윈도우 + 오늘 날짜 계산
2. 해당 함수의 `digest_runs` 테이블 `digest_date` UNIQUE 검사 → 이미 있으면 즉시 종료
3. 대상 row 조회 (§4 / §5 쿼리)
4. 0건이면 `INSERT ... status='skipped_no_data'` 후 종료
5. 인플루언서별 그룹핑 → 4섹션 분류 (인플루언서 메일 한정) → 템플릿 렌더 → Brevo SMTP 발송
6. 인플루언서 메일: 발송 직후 `deadline_reminder_email_sent` 에 D-N 항목만 벌크 INSERT
7. 전체 성공 시 `INSERT ... status='sent'` + 카운트 기록
8. 실패 시 `INSERT ... status='failed'` + `error_message`

### 7-3. 인플루언서 메일 — 일부 섹션 실패 시 정책
- 전체 4섹션 쿼리 중 하나가 실패하면 **그 인플루언서만 전체 발송 스킵** + 그 인플루언서 전체를 다음 cron 에 재시도하려면 `deadline_reminder_email_sent` INSERT 가 트랜잭션 안에 있어야 함
- 권장: 인플루언서별 발송 + 인플루언서별 트랜잭션 (한 인플루언서 실패 가 다른 인플루언서 발송 안 막음)

---

## 8. 메일 템플릿 (HTML)

`docs/email-templates/` 신규 2종 + preview 2종:

```
docs/email-templates/
├── influencer-daily-digest.html               + .preview.html
│   └── (옵션) 섹션별 row 헬퍼 4종
├── application-received-admin-daily.html      + .preview.html + .row.html
└── index.html (카탈로그 갱신 — §8-3 추가 사양 적용)
```

### 8-3. 카탈로그 카드 「발송 조건」 행 추가 (2026-05-18 추가 요구사항)

**배경**: 운영자·CS 직원이 카탈로그 페이지(`https://www.globalreverb.com/docs/email-templates/index.html`)를 열었을 때 「이 메일이 언제·왜 보내지는지」 한 줄에 이해할 수 있어야 함. 기존 `.card-desc` 는 기술적 표현이 섞여 있어 비개발자에게 친절하지 않음.

#### 카드 마크업 변경 (모든 카드 공통)

기존 `.card-desc` 다음에 **`.card-condition` 행** 신규 추가. 강조용 박스 디자인:

```html
<div class="card">
  <div class="card-tag tag-...">...</div>
  <div class="card-title">...</div>
  <div class="card-desc">기존 기술 설명 (그대로 유지)</div>

  <!-- ★ 신규 행 -->
  <div class="card-condition">
    <div class="cc-label">언제 보내요?</div>
    <div class="cc-text">초등학생도 알 수 있는 한 줄 설명</div>
    <div class="cc-timing"><strong>발송 시점:</strong> 예) 영수증 비승인 처리 즉시 / 매일 한국시간 오전 9시</div>
  </div>

  <div class="card-meta">...</div>
  <div class="card-actions">...</div>
</div>
```

#### 스타일 (신규 클래스)

```css
.card-condition {
  background: #FFF8E1;          /* 옅은 노란색 — 눈에 띄는 안내 박스 */
  border-left: 3px solid #F5C147;
  padding: 8px 12px;
  border-radius: 6px;
  margin-bottom: 14px;
}
.cc-label {
  font-size: 10px;
  font-weight: 700;
  color: #8A5A0A;
  letter-spacing: 0.05em;
  margin-bottom: 4px;
}
.cc-text {
  font-size: 12.5px;
  color: #333;
  line-height: 1.55;
}
/* 발송 시점 — cc-text 아래 굵은 라벨 + 시점 텍스트 */
.cc-timing {
  font-size: 11.5px;
  color: #7A4E0A;
  line-height: 1.5;
  margin-top: 6px;
  padding-top: 6px;
  border-top: 1px dashed #F5C147;
}
.cc-timing strong { font-weight: 700; color: #5B3A06; }
```

#### 카드별 「발송 조건」 한 줄 — 기획 초안 (개발 세션 다듬기 허용)

아래 표는 **기획 세션이 작성한 초안**입니다. 개발 세션이 실제 카드에 적용하면서 어색한 부분을 발견하면 자유롭게 다듬을 수 있습니다. 단 **수정한 내용은 §8-3-1 「문구 다듬기 이력」에 한 행씩 기록** 해 주세요 (변경 추적 + 다음 세션이 의도 파악 가능).

| # | 카드 제목 | 발송 조건 (평이한 한국어) | 발송 시점 |
|---|---|---|---|
| 1 | 회원가입 확인 메일 | 인플루언서가 회원가입을 하면 보냅니다. 이메일 주소가 진짜인지 확인하는 메일입니다. | 가입 폼 제출 즉시 |
| 2 | 비밀번호 재설정 메일 | 비밀번호를 잊었을 때 다시 만들 수 있는 링크를 보내거나, 새 관리자에게 처음 비밀번호 만드는 링크를 보낼 때 보냅니다. | 비밀번호 찾기 요청 / 관리자 초대 즉시 |
| 3 | 광고주 신청 — 관리자 알림 | 광고주가 캠페인 신청서를 보내면 관리자에게 「새 신청이 들어왔어요」 알림을 보냅니다. | 광고주 신청서 접수 즉시 |
| 4 | 광고주 접수 확인 — Qoo10 리뷰어 | Qoo10 리뷰어 신청서를 받은 광고주에게 「접수했습니다, 다음 절차는 이렇습니다」 안내를 보냅니다. | 리뷰어 신청서 접수 즉시 |
| 5 | 광고주 접수 확인 — 나노 시딩 | 나노 시딩 신청서를 받은 광고주에게 「접수했습니다, 다음 절차는 이렇습니다」 안내를 보냅니다. | 시딩 신청서 접수 즉시 |
| 6 | 결과물 — 영수증 승인 | 인플루언서가 보낸 영수증을 관리자가 승인하면 「다음 단계로 리뷰 이미지를 보내주세요」 안내를 보냅니다. | 영수증 승인 처리 즉시 |
| 7 | 결과물 — 영수증 비승인 | 인플루언서가 보낸 영수증에 문제가 있어서 다시 보내야 할 때, 어디를 고쳐야 하는지 알려주는 메일을 보냅니다. | 영수증 비승인 처리 즉시 |
| 8 | 결과물 — 리뷰 이미지 승인 | 인플루언서가 보낸 리뷰 화면 캡처를 관리자가 승인하면 「확인 완료, 보상 지급을 기다려 주세요」 안내를 보냅니다. | 리뷰 이미지 승인 처리 즉시 |
| 9 | 결과물 — 리뷰 이미지 비승인 | 인플루언서가 보낸 리뷰 화면 캡처에 문제가 있어서 다시 보내야 할 때, 어디를 고쳐야 하는지 알려주는 메일을 보냅니다. | 리뷰 이미지 비승인 처리 즉시 |
| 10 | 결과물 — 게시 URL 승인 | 인플루언서가 SNS에 올린 게시물 주소를 관리자가 승인하면 「확인 완료, 보상 지급을 기다려 주세요」 안내를 보냅니다. | 게시 URL 승인 처리 즉시 |
| 11 | 결과물 — 게시 URL 비승인 | 인플루언서가 SNS에 올린 게시물에 문제가 있어서 다시 올려야 할 때, 어디를 고쳐야 하는지 알려주는 메일을 보냅니다. | 게시 URL 비승인 처리 즉시 |
| 12 | 응모 취소 — 일일 요약 (관리자) | 인플루언서가 어제 캠페인 응모를 취소한 게 있으면, 그 목록을 모아서 다음 날 아침 9시에 관리자에게 한 통으로 보냅니다. | 매일 한국시간 오전 9시 (전일 0~24시 분 모아서 1통, 0건이면 미발송) |
| **13 (신규)** | **인플루언서 일일 다이제스트** | 인플루언서에게 매일 아침 9시에 한 통으로 보냅니다. 어제 신청·승인·반려된 캠페인 + 오늘부터 5일 안에 영수증/결과물 마감되는 캠페인을 한 메일에 모아 안내합니다. | 매일 한국시간 오전 9시 (인플루언서당 1통, 4섹션 모두 0건이면 미발송) |
| **14 (신규)** | **캠페인 신청 접수 — 관리자 일일 요약** | 인플루언서가 어제 응모한 캠페인 목록을 모아서 다음 날 아침 9시에 관리자에게 한 통으로 보냅니다. | 매일 한국시간 오전 9시 (전일 신청 1통, 0건이면 미발송) |
| 15 (미구현 유지) | OT 발송 안내 | 관리자가 인플루언서에게 「OT(오리엔테이션) 자료를 보냈어요」 알림을 보낼 때 보냅니다. *현재 미구현.* | 관리자가 OT 발송 체크박스 토글 시 즉시 (미구현) |

#### 미구현 섹션 정리

기존 미구현 6장 중 **4장이 신규 13번(인플루언서 일일 다이제스트)으로 흡수** 됨. 카탈로그에서 제거 대상:
- 「캠페인 신청 접수 확인 (본인)」 → 신규 13번 섹션 1로 흡수
- 「신청 승인 알림」 → 신규 13번 섹션 2로 흡수
- 「신청 반려 알림」 → 신규 13번 섹션 3로 흡수
- 「마감일 임박 리마인더」 → 신규 13번 섹션 4로 흡수

미구현으로 남는 것: **「OT 발송 안내」 1장** 만. 「캠페인 신청 접수 알림 (관리자)」 도 신규 14번으로 활성화.

#### 운영자 안내 (footer 추가)

카탈로그 푸터에 한 줄 추가:

> **🟡 노란 박스 안 「언제 보내요?」** — 메일이 자동으로 발송되는 시점을 평이한 한국어로 설명합니다. 새로 들어온 운영자·CS 담당자가 이 페이지 하나로 메일 흐름을 이해할 수 있도록 의도된 것입니다.

### 8-3-1. 문구 다듬기 이력 (개발 세션 기록 영역)

> 카드 「언제 보내요?」 문구를 §8-3 표의 기획 초안에서 다듬은 경우 한 행씩 추가하세요. 빈 상태로 두면 「초안 그대로 사용」으로 간주.

| 날짜 | 카드 # / 제목 | 변경 전 (초안) | 변경 후 (최종 적용) | 이유 |
|---|---|---|---|---|
| 2026-05-18 | 카드 #1~#15 전체 | (§8-3 표 그대로) | (동일) | **초안 그대로 사용** — 14장 활성 카드 모두 §8-3 표 문구 그대로 적용. 별도 다듬기 없음 |

운영 규칙:
- 한 카드의 문구를 여러 번 고치면 행을 여러 줄로 누적 (기획 초안 → 1차 → 2차 ... 추적 가능)
- 사용자가 직접 「이 문장 이렇게 고쳐줘」 라고 요청해서 바꾼 경우도 포함
- 사양서 §17 「구현 결과」 의 「달라진 것」 에는 **변경 행 수만 짧게 요약** (예: "§8-3 카드 문구 3건 다듬음 — 상세는 §8-3-1 표 참조")

### 8-1. 인플루언서 메일 본문 구조 (일본어)

```html
<!-- 상단 헤더 -->
<h2>本日の応募状況のお知らせ ({{today_jp}})</h2>
<p>{{total_sections}}件のお知らせがあります。</p>

<!-- 섹션 1: 어제 신청 -->
{{#if received_count > 0}}
<h3>📝 新規応募の受付 ({{received_count}}件)</h3>
{{received_rows_html}}
{{/if}}

<!-- 섹션 2: 어제 승인 -->
{{#if approved_count > 0}}
<h3>✅ 応募が承認されました ({{approved_count}}件)</h3>
{{approved_rows_html}}
<p><a href="{{public_app_url}}/#mypage-applications">活動管理で提出を始める →</a></p>
{{/if}}

<!-- 섹션 3: 어제 반려 -->
{{#if rejected_count > 0}}
<h3>📋 応募結果のお知らせ ({{rejected_count}}件)</h3>
{{rejected_rows_html}}
<p><a href="{{public_app_url}}/#campaigns">他のキャンペーンを見る →</a></p>
{{/if}}

<!-- 섹션 4: 마감 임박 -->
{{#if deadline_count > 0}}
<h3>⏰ 提出期限が近づいています ({{deadline_count}}件)</h3>
{{deadline_rows_html}}
<p><a href="{{public_app_url}}/#mypage-applications">活動管理で提出する →</a></p>
{{/if}}

<!-- 푸터 -->
<hr>
<p>このメールは応募活動に関する重要なお知らせです。</p>
```

Edge Function 의 render() 가 `{{#if ...}}` 같은 조건 분기 직접 처리하거나, JavaScript 안에서 섹션별로 미리 빈 문자열/렌더된 HTML 을 결정한 후 `{{section_X_html}}` 통째로 치환.

기존 `application-cancelled-daily.html` 의 row 패턴 + 단순 placeholder 치환 패턴 미러링 권장 (조건 분기 없이 빈 문자열로 비노출).

### 8-2. 관리자 메일 본문 구조 (한국어, cancel-daily 패턴 미러)

```html
<h2>キャンペーン応募 一日요약 — {{digest_date}} ({{total_count}}건)</h2>
{{rows_html}}
<p><a href="{{public_admin_url}}#applications?status=pending">관리자에서 보기 →</a></p>
```

배포 직전 `scripts/sync-email-templates.sh` 실행 필수 (`docs/email-templates/` → 각 Edge Function `_templates/` + `templates.ts` 갱신).

---

## 9. pg_cron 등록 (운영 적용 절차)

기존 `notify-application-cancelled-daily` cron 등록 패턴 미러. 2개 job 등록:

```sql
SELECT cron.schedule(
  'influencer-daily-digest',
  '0 0 * * *',  -- UTC 00:00 = KST 09:00
  $$ SELECT net.http_post(
       url:='<EDGE_FUNCTION_BASE>/notify-influencer-daily-digest',
       headers:=jsonb_build_object('Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='edge_function_jwt'))
     ); $$
);

SELECT cron.schedule(
  'application-received-admin-daily',
  '0 0 * * *',
  $$ SELECT net.http_post(
       url:='<EDGE_FUNCTION_BASE>/notify-application-received-admin-daily',
       headers:=jsonb_build_object('Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='edge_function_jwt'))
     ); $$
);
```

기존 `application-cancel-daily-digest` 와 동시 실행 → 09:00 KST 동시 3개 cron job.

상세 절차는 `docs/specs/2026-05-12-HANDOFF-application-cancel-pr-d-cron-setup.md` 참조 (양 서버 동일 패턴).

---

## 10. 영향 파일 목록

### DB
- `supabase/migrations/130_application_email_pipeline_infra.sql` (신규)
  - 다이제스트 로그 2종 + `deadline_reminder_email_sent` UNIQUE 로그 + `lookup_values` 시드 1건 + `admin_email_subscriptions` 시드 + 헬퍼 함수 (옵션)

### Edge Functions (Supabase)
- `supabase/functions/notify-influencer-daily-digest/` (신규)
- `supabase/functions/notify-application-received-admin-daily/` (신규)
- 각각 `index.ts` + `templates.ts` + `_templates/`

### 메일 템플릿
- `docs/email-templates/influencer-daily-digest.html` (+ preview + 섹션 row 헬퍼 4종 옵션)
- `docs/email-templates/application-received-admin-daily.html` (+ preview + row)
- `docs/email-templates/index.html` (카탈로그 갱신: 활성 5종 → 7종)

### pg_cron
- 운영 DB SQL Editor 에 2개 cron job 수동 등록 (개발 DB 동일)

### 클라이언트
- 변경 없음 (메일 발송 트리거는 전적으로 서버 cron + Edge Function)

### 관리자 페이지 (자동 반영)
- 「관리자 메일 수신 설정」 모달(`/admin#admin-accounts`)에 「캠페인 신청 접수」 항목 자동 노출 (`lookup_values` 기반이라 코드 변경 없음 — 확인 필요)

### 동기화 스크립트
- `scripts/sync-email-templates.sh` 가 신규 2종 템플릿을 자동 인식하는지 점검 (기존 패턴이 `find` 기반이면 자동 동작)

---

## 11. 검증 시나리오 (개발 세션용)

### 데이터 시드 (개발 DB)
1. 어제(KST) 캠페인 A·B 신청 2건 INSERT (인플루언서 X)
2. 어제 캠페인 C 승인 1건 (인플루언서 Y)
3. 어제 캠페인 D 반려 1건 (인플루언서 Y)
4. 오늘 기준 D-5 인 monitor 캠페인 E + 인플루언서 Z 승인 + 영수증 미제출
5. 오늘 기준 D-1 인 결과물 마감 캠페인 F + 인플루언서 Z 승인 + 결과물 미제출
6. 인플루언서 W 가 어제 신청 1건 + D-5 영수증 1건 + D-1 결과물 1건 동시 (4섹션 합쳐서 1통 검증)

### 회귀 시나리오
1. Edge Function 2개 각각 `curl` 로 호출 → 정상 발송 + 로그 status='sent'
2. 같은 날 두 번 호출 → `digest_date` UNIQUE 차단 → 즉시 종료
3. 윈도우 안 데이터 0건 → status='skipped_no_data', 메일 미발송
4. 인플루언서 Y (어제 승인 1 + 반려 1) → **1통**에 섹션 2·3 노출
5. 인플루언서 Z (D-5 영수증 1 + D-1 결과물 1) → 1통에 섹션 4 안 2건 묶음
6. 인플루언서 W (신청 1 + D-5 영수증 1 + D-1 결과물 1) → 1통에 섹션 1·4 노출
7. 4섹션 모두 0건인 인플루언서 → 해당 인플루언서만 발송 스킵 (전체 cron 은 정상)
8. 같은 D-N 메일 두 번 시도 → `deadline_reminder_email_sent` UNIQUE 차단
9. D-5 메일 받고 D-3 시점에 영수증 제출 → D-1 메일에 임박 섹션 없음 (NOT EXISTS 동작)
10. 관리자 「application_received」 수신 OFF 인 관리자에게는 #2 메일 미발송
11. Brevo API 키 잘못 설정 → status='failed' + `error_message`
12. 일본어 인코딩 (마감일·캠페인명 한자 포함) 정상 표시

---

## 12. 운영 배포 절차 (개발 → 운영)

### 12-1. 개발서버
1. 마이그레이션 130 개발 DB 적용
2. `scripts/sync-email-templates.sh` 실행 → `_templates/`·`templates.ts` 갱신
3. Edge Function 2개 배포 (`supabase functions deploy notify-influencer-daily-digest` + `notify-application-received-admin-daily`)
4. 환경변수 확인 (기존 cancel-daily 와 공유)
5. pg_cron 2개 job 등록 (개발 DB SQL Editor)
6. 수동 호출 검증 (`curl` + service_role JWT)
7. 검증 시나리오 1~12 통과
8. dev 머지 → 다음 날 09:00 자연 실행 결과 확인

### 12-2. 운영서버
1. 운영 DB 백업
2. 운영 DB 에 마이그레이션 130 적용 (SQL Editor)
3. Edge Function 2개 운영 프로젝트에 배포
4. 운영 환경변수 설정 (Brevo 키는 양 서버 분리)
5. 운영 DB pg_cron 2개 job 등록
6. 수동 호출 검증 (소량 데이터 시점)
7. 다음 날 09:00 자연 실행 결과 확인

---

## 13. 리스크 / 애매한 부분

| 리스크 | 영향 | 대응 |
|---|---|---|
| Brevo 한도 (Starter 20,000/월) 압박 | 인플루언서 수 ↑ 시 한도 초과 | 인플루언서당 1통 통합으로 절약. 사용량 모니터링 |
| 캠페인 마감일 연장 시 D-1 메일 미발송 | 인플루언서가 임박 알림 못 받음 | `deadline_reminder_email_sent` 운영자 수동 reset 도구 (이번 범위 밖) |
| `applications.reviewed_at` UPDATE 시 매번 갱신 가정 | 검증 필요 | 개발 세션에서 storage.js / RPC 점검 |
| 일본어 날짜 표기 (YYYY年MM月DD日 vs YYYY-MM-DD) | 디자인 일관성 | 기존 cancel-daily 패턴 미러 |
| 4섹션 통합 본문이 길어짐 | 인플루언서가 본문 스크롤 부담 | 섹션 헤더 + 카드 컴팩트 디자인. 본문 평균 300~500단어 목표 |
| 한 인플루언서가 어제 신청 30건 (브랜드 운영자가 일괄 등록) | 메일 본문 폭주 | 각 섹션 「상위 10건 + 나머지 N건 더보기」 처리 검토 (이번 범위 밖, 데이터 모니터링 후 결정) |
| Edge Function 인플루언서별 트랜잭션 | 한 인플루언서 실패가 다른 인플루언서 발송 안 막아야 함 | 개별 try/catch 패턴 |

---

## 14. 사용자 검토 필요 항목

본 사양은 사용자 답변 4건 반영해서 확정 상태. 추가 검토 필요 항목:

1. ✅ 묶음 정책 — **모두 1통** 확정
2. ✅ 마감일 기준 — **purchase_end / submission_end (post_deadline 폴백)** 확정
3. ✅ D-N — **D-5, D-1** 확정
4. ✅ 관리자 기본값 — **전체 ON** 확정
5. ⏳ 반려 사유 컬럼 — 별도 사양 (이번 범위 밖, 후속 PR)
6. 🆕 인플루언서가 어제 30건 신청한 경우 본문 잘림 처리 (이번 범위 밖, 데이터 누적 후 결정)
7. 🆕 메일 본문 「섹션별 이모지」 (📝 ✅ 📋 ⏰) 사용 여부 — 사용자 메모리 「이모지 사용 금지」 적용 시 Material Icons 대체 어려움. 단순 텍스트 헤더로 변경 권장

---

## 15. 제외 항목 (이번 범위 밖)

- 운영자 수동 reset 도구 (마감일 연장 시 메일 재발송)
- 인플루언서 메일 수신 설정 UI (마이페이지 옵트아웃)
- 반려 사유 입력 필드·UI (별도 사양 — `applications.reject_reason` 컬럼 + 운영자 입력 흐름)
- 결과물 검수 알림(`notify-deliverable-decision`)과의 통합
- 인플루언서 LINE 알림 통합 (앱 내 알림 + 메일 + LINE 3채널 통합 흐름)
- 본문 30건 초과 시 페이징/잘림 처리

---

## 16. PR 분할 (개발 세션 권장)

규모가 커서 1개 PR 보다 분할 권장:

- **PR A**: 마이그레이션 130 + 메일 템플릿 2종 + 카탈로그 갱신 (DB ↔ 코드 정합)
- **PR B**: Edge Function 2종 배포 + 개발 DB pg_cron 등록 + 검증 시나리오 1~12
- **PR C**: 운영 배포 (마이그레이션 + Edge Function + pg_cron) — 사용자 명시 승인 후

또는 한 PR 로 묶어도 무방. 개발 세션 판단.

---

## 17. 구현 결과

**구현일:** 2026-05-18
**관련 마이그레이션:** `supabase/migrations/130_application_email_pipeline_infra.sql`
**관련 Edge Function:** `notify-influencer-daily-digest`, `notify-application-received-admin-daily` (신규 2개)
**같은 PR 묶음:** `docs/specs/2026-05-13-application-cancel-daily-email-fix.md` 사양서 §10 회고 + cancel-daily 운영 Edge Function 재배포 안내

### 사전 점검 결과 (메인 세션 검증)
- cancel-daily 인프라(cron + 윈도우 + 발송 로그)는 운영에서 정상 동작 확인 (2026-05-13~17 5일 연속 09:00 KST 정시 호출, 2026-05-12 sent 1건, 5일은 0건이라 skipped_no_data)
- cancel-daily 사양서 §10 「구현 결과」 가 비어있어 미구현처럼 보였으나 실제 코드(607f52b → release 9ed247c) 는 2026-05-13 에 dev+main 모두 머지 완료된 상태로 확인됨

### 초안 대비 변경 사항

#### 동일하게 구현된 것
- 인플루언서 통합 다이제스트 4섹션 (received / approved / rejected / deadline) + 인플루언서당 1통/일
- 관리자 application_received 일일 요약 (캠페인별 그룹)
- D-N = D-5, D-1 만 (사양서 §3)
- 마감 기준 = `purchase_end` (영수증) / `submission_end` (결과물 — post_deadline 폴백 없음, 마이그레이션 129 이후)
- `marketing_opt_in` 무시 (트랜잭션 성격)
- 관리자 application_received 기본 ON 시드
- 매일 KST 09:00 (UTC 00:00) cron
- 재발송 방지: `deadline_reminder_email_sent` UNIQUE 4-tuple + 일별 다이제스트 `digest_date` UNIQUE
- 인플루언서별 try/catch (한 명 실패가 다른 명 차단 안 함)

#### 추가된 것 (초안에 없었음)
- **마이그레이션 번호 130** (사양서엔 129 였으나 같은 날 129 가 `post_deadline 제거` 마이그레이션으로 사용되어 130 발급)
- **인플루언서 row 헬퍼 4종 분리** (`influencer-daily-digest.row-{received,approved,rejected,deadline}.html`) — 사양서 §8 의 옵션 「섹션별 row 헬퍼 4종」 채택
- **`_yesterday_kst_window()` SQL 헬퍼 함수** 추가 — SQL Editor 디버깅·테스트 편의용 (Edge Function 은 JS 로 직접 계산)
- **sync 스크립트 분기 확장**: `templates.ts` 자동 생성 대상 함수에 `notify-influencer-daily-digest` + `notify-application-received-admin-daily` 추가

#### 달라진 것
- **§8-3 카드 문구 다듬기**: 초안 그대로 사용 (§8-3-1 참조 — 14장 전체 변경 없음)
- **`recruitTypeJp` 일본어 표기**: 초안에 명시 없었으나 reviewer 가 `dev/js/ui.js` 패턴과 일관성 지적 — `レビュアー / ギフティング / 訪問型` 채택
- **인플루언서 SNS 컬럼명**: 사양서엔 `instagram` 으로 적혔으나 실제 컬럼은 `ig`. supabase-expert 가 차단급 버그 지적 후 수정

#### 빠진 것 (사용자 결정으로 의도적 제외)
- 반려 사유 표시 (사양서 §3, §15 — 별도 사양 후속)
- 본문 30건 초과 페이징/잘림 (사양서 §13, §15)
- 운영자 수동 reset 도구 (마감일 연장 시 메일 재발송)
- 인플루언서 메일 수신 옵트아웃 UI

### 구현 중 기술 결정 사항

#### 마이그레이션 130 (DB)
- **buy 1 (차단급) 수정** — supabase-expert 가 지적: `admin_email_subscriptions.admin_id` 는 `admins.id` (PK) 외래 키이므로 시드에서 `a.auth_id` → `a.id` 로 변경 (cancel-daily 시드 패턴 미러)
- **버그 2 (차단급) 수정** — `influencers.instagram` 컬럼 부재. 실제 컬럼명 `ig` 로 SELECT/InflRow/snsHandleDisplay 3곳 수정
- BEGIN/COMMIT 단일 트랜잭션 + ENABLE RLS + 멱등 정책 (`DROP POLICY IF EXISTS` → `CREATE POLICY`)
- 검증 NOTICE + 롤백 가이드 주석 포함

#### Edge Function — 인플루언서 다이제스트
- 어제 윈도우 한 번에 3 쿼리로 분리 (`created_at` / `reviewed_at` IN(approved,rejected) / `status=approved` 전체) — PostgREST 제약상 단일 OR 쿼리보다 가독성 ↑
- 마감 임박 후보의 `deliverables` 일괄 SELECT (`status IN (pending, approved)`) → `delivByApp: Map<app_id, Set<kind>>` 캐시
- 인플루언서 이메일은 `sb.auth.admin.getUserById` 배치 호출 (cancel-daily 검증된 패턴 재활용)
- 발송 직후 `deadline_reminder_email_sent` 벌크 INSERT 전 `sentDuringRun` Set 으로 동일 인플 같은 (kind, d_minus) 중복 INSERT 차단 + 23505 무시 처리

#### Edge Function — 관리자 접수 요약
- cancel-daily 패턴 완전 미러 (`computeWindow` / `resolveAdminEmails` / `logRun` / `sendBrevoEmail` / `escapeHtml`)
- SNS 핸들 표시: `primary_sns` 1순위 → 폴백 (`ig` → `tiktok` → `x` → `youtube`) 첫 채워진 채널
- 캠페인 정렬: title 알파벳 순 (`localeCompare`)

#### 메일 템플릿
- 인플루언서 본문은 일본어 (인플 UI 언어 일치)
- 관리자 본문은 한국어
- 4섹션 헤더는 Edge Function 인라인 (사양서 §8-1 의 `{{#if ...}}` 조건 분기 대신 사전 렌더 + 빈 문자열 치환 패턴 — 기존 cancel-daily 와 동일)
- 인플루언서 메일에 이모지 미사용 (사용자 메모리 「이모지 사용 금지」 + 사양서 §14-7 권장 따름) — 단순 텍스트 + 컬러 라벨

#### 카탈로그 페이지
- `.card-condition` / `.cc-label` / `.cc-text` / `.cc-timing` 신규 CSS 추가 (cc-timing 은 2026-05-18 사용자 추가 요구사항 — 카드별 발송 시점 명시)
- 활성 카드 14장 모두 「언제 보내요?」 박스 삽입 (사양서 §8-3 표 그대로)
- 미구현 섹션 5장 → 1장 (OT 발송 안내만 유지). 4장 흡수 + 1장 활성화
- 푸터에 노란 박스 안내 한 줄 추가
- legend 의 「Influencer · 미구현」 → 「Influencer · Edge Function」 로 갱신

### 운영 배포 절차 (HANDOFF §3-7 + cancel-daily 묶음)

1. 마이그레이션 129 운영 적용 여부 사전 확인 (`SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='campaigns' AND column_name='post_deadline'` → 0 row)
2. 운영 DB SQL Editor 에 마이그레이션 130 적용
3. 검증 SQL 4종 실행 (테이블 3개 / lookup 시드 / 구독 시드 / 헬퍼 함수)
4. Supabase 운영 프로젝트에 Edge Function 3개 배포 (cancel-daily 재배포 + 신규 2개):
   ```
   supabase functions deploy notify-application-cancelled-daily   --project-ref twofagomeizrtkwlhsuv
   supabase functions deploy notify-influencer-daily-digest        --project-ref twofagomeizrtkwlhsuv
   supabase functions deploy notify-application-received-admin-daily --project-ref twofagomeizrtkwlhsuv
   ```
5. 운영 DB pg_cron 2개 job 등록 (`cron.schedule` — HANDOFF §3-7 SQL 참조)
6. 수동 호출 검증 (curl + service_role JWT) — 소량 시점에 발송 확인
7. 다음 날 09:00 자연 실행 결과 확인 (`influencer_daily_digest_runs` + `application_received_admin_digest_runs` 의 status 컬럼)

### 잔존 작업 (다음 사이클)
- 반려 사유 표시 — `applications.reject_reason` 컬럼 + 입력 UI 별도 사양
- 본문 30건 초과 페이징 처리 — 데이터 누적 후 결정
- 운영자 수동 reset 도구 (`deadline_reminder_email_sent`)
- 인플루언서 메일 수신 설정 UI (마이페이지 옵트아웃)
- 메일 발송량 모니터링 (Brevo Starter 20,000/월 한도)
