# 사양서: 캠페인 신청 본인 취소 기능

> **작성일**: 2026-05-11
> **작성 세션**: 고문(메인 폴더) + reverb-planner
> **상태**: ✅ **운영 배포 완료 (마이그레이션 104, 2026-05-11)** — DB·인플루언서 UI·관리자 UI 구현 완료. 코드(admin.js·app.js)는 dev 잠재, main merge 보류 중. 알림 메일(PR-D)은 2026-05-18 관리자 통합 다이제스트(마이그레이션 132)로 흡수. 구현 결과 섹션 참조
> **실제 PR 분할**: DB + UI(인플루언서·관리자 통합) 1개 — 별도 알림 PR 은 메일 파이프라인 통합으로 대체

---

## 1. 결정 요약

| 항목 | 결정 |
|---|---|
| 데이터 모델 | `applications.status='cancelled'` 신규 값 + 보조 컬럼 5개 |
| 사유 형식 | `lookup_values(kind='cancel_reason')` 카테고리 select + 자유 텍스트 보충 |
| 취소 가능 시점 | 결과물 제출 마감까지 — 구매기간 이후는 사유·경고·동의 필수 |
| 결과물 승인 후 | 본인 취소 차단 — 관리자 수동 처리만 |
| 재신청 | 허용 — `(user_id, campaign_id)` UNIQUE를 partial로 변경 |
| 관리자 알림 | 구매기간 이후 취소 시 메일 + admin_notices 둘 다 |
| 관리자 화면 | 「신청 관리」 페인 상태 필터에 「취소」 추가, 인플루언서 상세 모달에 「취소 사유」 카드 |
| 활동관리 페이지 | 취소된 신청은 진입 자체 차단 + 안내 메시지 + 응모이력 복귀 버튼 |
| 캠페인 상세 재방문 | 「再応募する」 버튼 활성 + 회색 안내 박스. 재응모는 신규 row INSERT |
| 본인 취소 알림 | `notifications` 테이블 신규 `kind='application_cancelled'` 1건 — 단순 완료 알림 |
| 사유 카테고리 6종 | 참여 가능 일정 부족 / 개인 사정 변경 / 제품 정보 불일치 / 배송 문제 / SNS 계정 변경·제한 / 기타 |
| 작업 시작 | PR #152(admin-split Phase 0) · PR #153(제출마감-19일) dev 머지 후 |

---

## 2. 데이터베이스 스키마 변경

### 2-1. 마이그레이션 파일

**파일명**: `supabase/migrations/{다음번호}_application_cancellation.sql`

> 다음 마이그레이션 번호는 **작업 시작 직전** `ls supabase/migrations/ | tail -5`로 확인할 것. 084까지는 알려져 있음. 097 이상 운영 미배포분이 있을 수 있어 dev 기준 마지막 번호 +1.

### 2-2. `applications` 테이블 컬럼 추가

```sql
ALTER TABLE public.applications
  ADD COLUMN cancelled_at        timestamptz NULL,
  ADD COLUMN cancel_reason       text        NULL,           -- 자유 텍스트 보충
  ADD COLUMN cancel_reason_code  text        NULL,           -- lookup_values code
  ADD COLUMN cancel_phase        text        NULL CHECK (cancel_phase IS NULL OR cancel_phase IN ('recruit','purchase','visit','post','other')),
  ADD COLUMN previous_status     text        NULL;           -- 취소 직전 상태 백업
```

- `applied_count` 트리거(058)는 `status IN ('pending','approved')` 기준이라 `cancelled`는 자연 제외 — 슬롯 자동 복원
- `status` 컬럼에 CHECK 제약은 현재 없음(자유 텍스트). 신규 값 `'cancelled'` 추가에 DDL 부담 없음

### 2-3. UNIQUE 제약 partial로 변경 (재신청 허용)

```sql
-- 기존 제약 제거
ALTER TABLE public.applications
  DROP CONSTRAINT IF EXISTS applications_user_id_campaign_id_key;

-- partial unique index 재생성
CREATE UNIQUE INDEX applications_user_camp_active_uidx
  ON public.applications (user_id, campaign_id)
  WHERE status != 'cancelled';
```

**부작용 점검 필요**:
- migration 049 (monitor 자동 승인 트리거): 재신청 시 INSERT BEFORE 트리거가 다시 작동 → 슬롯 한계 안이면 즉시 approved
- migration 048 (정원 가드): 슬롯 도달 시 INSERT 차단 — 정상 동작
- migration 058 (applied_count 재계산): cancelled 제외라 빈자리 정확히 반영

### 2-4. `cancel_application` 원격 호출 함수(RPC)

```sql
CREATE OR REPLACE FUNCTION public.cancel_application(
  p_application_id  uuid,
  p_reason_code     text DEFAULT NULL,
  p_reason_note     text DEFAULT NULL,
  p_acknowledged    boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_app           public.applications%ROWTYPE;
  v_campaign      public.campaigns%ROWTYPE;
  v_phase         text;
  v_deliv_approved boolean;
BEGIN
  -- 1. 신청 행 잠금 + 본인 검증
  SELECT * INTO v_app
  FROM public.applications
  WHERE id = p_application_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'application_not_found' USING ERRCODE = '22023';
  END IF;

  IF v_app.user_id != auth.uid() THEN
    RAISE EXCEPTION 'not_owner' USING ERRCODE = '42501';
  END IF;

  -- 2. 상태 검증 (pending/approved만 취소 가능)
  IF v_app.status NOT IN ('pending','approved') THEN
    RAISE EXCEPTION 'invalid_status' USING ERRCODE = '22023';
  END IF;

  -- 3. 결과물 승인 차단
  SELECT EXISTS (
    SELECT 1 FROM public.deliverables
    WHERE application_id = p_application_id AND status = 'approved'
  ) INTO v_deliv_approved;

  IF v_deliv_approved THEN
    RAISE EXCEPTION 'deliverable_already_approved' USING ERRCODE = '22023';
  END IF;

  -- 4. 캠페인 일자 + now() 비교 → cancel_phase 도출
  SELECT * INTO v_campaign
  FROM public.campaigns
  WHERE id = v_app.campaign_id;

  v_phase := CASE
    WHEN v_campaign.submission_end IS NOT NULL AND now() > v_campaign.submission_end::timestamptz THEN 'post'
    WHEN v_campaign.purchase_end   IS NOT NULL AND now() > v_campaign.purchase_end::timestamptz   THEN 'post'
    WHEN v_campaign.visit_end      IS NOT NULL AND now() > v_campaign.visit_end::timestamptz      THEN 'post'
    WHEN v_campaign.purchase_start IS NOT NULL AND now() >= v_campaign.purchase_start::timestamptz THEN 'purchase'
    WHEN v_campaign.visit_start    IS NOT NULL AND now() >= v_campaign.visit_start::timestamptz    THEN 'visit'
    WHEN v_campaign.deadline       IS NOT NULL AND now() <= v_campaign.deadline::timestamptz       THEN 'recruit'
    ELSE 'other'
  END;

  -- 5. recruit 외 단계는 사유·동의 필수
  IF v_phase != 'recruit' THEN
    IF NOT COALESCE(p_acknowledged, false) THEN
      RAISE EXCEPTION 'acknowledgement_required' USING ERRCODE = '22023';
    END IF;
    IF p_reason_code IS NULL OR length(trim(p_reason_code)) = 0 THEN
      RAISE EXCEPTION 'reason_required' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- 6. UPDATE
  UPDATE public.applications
  SET status            = 'cancelled',
      previous_status   = v_app.status,
      cancelled_at      = now(),
      cancel_reason_code = p_reason_code,
      cancel_reason     = NULLIF(trim(p_reason_note), ''),
      cancel_phase      = v_phase
  WHERE id = p_application_id;

  RETURN jsonb_build_object(
    'cancel_phase',    v_phase,
    'cancelled_at',    now(),
    'previous_status', v_app.status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_application(uuid, text, text, boolean) TO authenticated;
```

### 2-5. `lookup_values` 시드 — 취소 사유 카테고리 (사용자 확정 완료)

| code | name_ko | name_ja | sort |
|---|---|---|---|
| `schedule_unavailable` | 참여 가능 일정 부족 | 期間内に参加が難しい | 10 |
| `personal_reason` | 개인 사정 변경 | 個人的な事情 | 20 |
| `product_mismatch` | 제품 정보 불일치 | 商品情報が想定と違う | 30 |
| `delivery_issue` | 배송 문제 | 配送に問題があった | 40 |
| `account_change` | SNS 계정 변경/제한 | SNSアカウントの変更・制限 | 50 |
| `other` | 기타 | その他 | 90 |

### 2-6. `violation_reason` lookup 추가 (위반 등록용)

```sql
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES (
  'violation_reason',
  'cancel_after_purchase_start',
  '구매기간 이후 캠페인 신청 취소',
  '購入期間後の応募取消',
  60, true
);
```

### 2-7. 행 단위 보안 정책(RLS)

- 본인 취소는 RPC SECURITY DEFINER로 우회. SELECT/UPDATE 정책 추가 없음
- 관리자 SELECT/UPDATE는 기존 `is_admin()` 정책으로 충분 (cancelled 상태도 자동 조회 가능)

---

## 3. 비즈니스 룰 매트릭스

### 3-1. 취소 허용 조건

| status \ cancel_phase | recruit | purchase | visit | post |
|---|---|---|---|---|
| `pending` | ✅ 자유 | ✅ 사유+동의 | ✅ 사유+동의 | ✅ 사유+동의 |
| `approved` (결과물 미승인) | ✅ 자유 | ✅ 사유+동의 | ✅ 사유+동의 | ✅ 사유+동의 |
| `approved` (결과물 1건이라도 approved) | ❌ 차단 | ❌ 차단 | ❌ 차단 | ❌ 차단 |
| `rejected` | ❌ 의미 없음 | ❌ | ❌ | ❌ |
| `cancelled` | ❌ 중복 | ❌ | ❌ | ❌ |

### 3-2. 사유 필수 / 동의 필수 매트릭스

| cancel_phase | 사유 카테고리 | 자유 텍스트 | 동의 체크 |
|---|---|---|---|
| `recruit` | 선택 | 선택 | 불필요 |
| `purchase` | **필수** | 선택 | **필수** |
| `visit` | **필수** | 선택 | **필수** |
| `post` | **필수** | 선택 | **필수** |
| `other` | **필수** | 선택 | **필수** |

---

## 4. 인플루언서 UI 사양 (`dev/index.html` + `dev/js/mypage.js` + `dev/css/mypage.css`)

### 4-1. 응모이력 화면 진입점

- 응모이력 카드 우상단에 ⋮ (more_vert) 아이콘 추가
- 클릭 시 드롭다운: `[詳細を見る] [取消]`
- 활동관리 페이지(approved 진입) 상단에도 동일한 「取消」 액션 1개 추가
- 표시 조건: status ∈ {pending, approved} & 결과물 승인 0건 & 캠페인 status ≠ draft

### 4-2. 취소 모달 — 단순형 (cancel_phase = 'recruit')

```
┌────────────────────────────────┐
│ この応募を取り消しますか？           │
│                                │
│ キャンペーン: {제목}                │
│ 状態: {pending|approved}          │
│                                │
│         [戻る]  [取り消す]         │
└────────────────────────────────┘
```

### 4-3. 취소 모달 — 사유 입력형 (cancel_phase ≠ 'recruit')

```
┌────────────────────────────────────────────────┐
│ 応募を取り消しますか？                                 │
│                                                │
│ ┌──────────────────────────────────────────┐   │
│ │ ⚠ 注意                                    │   │
│ │ {phase 라벨} が開始しているため、取消すと違反記録 │   │
│ │ など不利益を受ける可能性があります。               │   │
│ └──────────────────────────────────────────┘   │
│                                                │
│ 取消理由 (必須)                                    │
│ [▼ カテゴリを選択]                                  │
│  - 期間内に参加が難しい                              │
│  - 個人的な事情                                   │
│  - 商品情報が想定と違う                             │
│  - 配送に問題があった                              │
│  - SNSアカウントの変更・制限                         │
│  - その他                                       │
│                                                │
│ 補足説明 (任意)                                    │
│ [텍스트 영역, 최대 500자]                            │
│                                                │
│ ☐ 上記の不利益の可能性を理解しました                    │
│                                                │
│              [戻る]  [取り消す]                    │
└────────────────────────────────────────────────┘
```

- 「取り消す」 버튼은 동의 체크 + 카테고리 선택 후에만 활성
- phase 라벨: `purchase` → 「購入期間」, `visit` → 「訪問期間」, `post` → 「結果物提出期間/期限経過」, `other` → 「現在のキャンペーン状態」

### 4-4. 응모이력 「取消」 탭 신규 추가

- 기존 4탭(`all / pending / approved / rejected`) + 신규 1탭(`cancelled`)
- 탭 라벨: 「取消」
- `all` 탭에도 cancelled 카드 포함
- 카드에 회색 배지 「取消済」 + 우측에 취소일 `YYYY-MM-DD` + 클릭 시 사유 모달

### 4-5. 사유 확인 모달 (취소된 카드 클릭 시)

```
┌─────────────────────────────────┐
│ 取消の詳細                          │
│                                 │
│ 取消日時: 2026-05-11 14:30          │
│ カテゴリ: 期間内に参加が難しい            │
│ 補足: {p_reason_note 텍스트, 없으면 생략} │
│ 取消時の段階: 購入期間                  │
│                                 │
│               [閉じる]              │
└─────────────────────────────────┘
```

### 4-6. i18n 키 신규 추가 (`dev/lib/i18n/{ja,ko}.js`)

```
appHistory.tab.cancelled            「取消」/「취소」
appHistory.badge.cancelled          「取消済」/「취소됨」
appHistory.menu.cancel              「取消」/「취소」
appHistory.cancel.title             「応募を取り消しますか？」/...
appHistory.cancel.warning.purchase  「購入期間が開始しているため...」
appHistory.cancel.warning.visit     「訪問期間が開始しているため...」
appHistory.cancel.warning.post      「結果物提出期間/期限経過のため...」
appHistory.cancel.warning.other     「現在のキャンペーン状態では...」
appHistory.cancel.reason.label      「取消理由」
appHistory.cancel.reason.select     「カテゴリを選択」
appHistory.cancel.note.label        「補足説明 (任意)」
appHistory.cancel.acknowledge       「上記の不利益の可能性を理解しました」
appHistory.cancel.confirmBtn        「取り消す」
appHistory.cancel.cancelBtn         「戻る」
appHistory.cancel.detail.title      「取消の詳細」
appHistory.cancel.detail.datetime   「取消日時」
appHistory.cancel.detail.category   「カテゴリ」
appHistory.cancel.detail.note       「補足」
appHistory.cancel.detail.phase      「取消時の段階」
appHistory.cancel.phase.purchase    「購入期間」
appHistory.cancel.phase.visit       「訪問期間」
appHistory.cancel.phase.post        「結果物提出期間後」
appHistory.cancel.phase.recruit     「募集期間中」
appHistory.cancel.phase.other       「その他」
appHistory.cancel.blocked.title     「この応募はキャンセルされました」
appHistory.cancel.blocked.body      「応募履歴に戻る場合は下のボタンをタップ」
appHistory.cancel.blocked.backBtn   「応募履歴に戻る」
campaign.reapply.notice             「以前キャンセルされた応募があります。再度応募しますか？」
campaign.reapply.btn                「再応募する」
notif.applicationCancelled.title    「応募を取り消しました」
notif.applicationCancelled.body     「{campaignTitle}」
```

### 4-7. 차단 분기 메시지

- 결과물 1건이라도 approved → 「取消」 메뉴 비활성 + tooltip 「承認済みの結果物があるため、ご自身で取消できません。管理者にお問い合わせください。」
- 이미 cancelled 상태 → 「取消」 메뉴 비활성 (중복 차단)

### 4-8. 활동관리 페이지(결과물 제출 화면) 진입 차단 (취소된 신청)

- approved 상태였다가 cancelled 된 신청의 활동관리 페이지 직접 URL 진입 시 차단
- 빈 회색 안내 화면만 노출:
  ```
  ┌───────────────────────────────────────────┐
  │  この応募はキャンセルされました                  │
  │                                           │
  │  応募履歴に戻る場合は下のボタンをタップ           │
  │                                           │
  │         [応募履歴に戻る]                     │
  └───────────────────────────────────────────┘
  ```
- 영수증 업로드 / URL 입력 폼 자체를 DOM 비공개
- 헤더 알림에서 과거 이력으로 진입할 때도 동일 분기

### 4-9. 캠페인 상세 페이지 — 취소 후 재방문 시 「재응모」 동선

- 본인이 이미 취소한 캠페인의 상세 페이지를 다시 열면:
  - 일반 「応募する」 버튼 라벨이 **「再応募する」** 로 변경
  - 버튼 위에 회색 안내 박스 1줄: 「以前キャンセルされた応募があります。再度応募しますか？」
  - 클릭 시 신규 응모와 동일한 모달 흐름 (사유·동의 등 추가 단계 없음)
- 재응모는 partial unique index 덕에 신규 row 로 INSERT (cancelled row 와 별도 row 공존)
- monitor 캠페인의 경우 049 자동 승인 트리거 즉시 작동 — 슬롯 여유 있으면 즉시 approved

### 4-10. 본인 취소 완료 알림 (`notifications`)

- 본인이 응모를 취소한 직후 알림 1건 자동 생성
- `notifications` 테이블 신규 `kind='application_cancelled'` 추가
- 라벨: 「応募を取り消しました — {キャンペーン名}」
- 헤더 햄버거 아이콘 미읽음 배지에 즉시 반영
- 알림 모달에서 클릭 시 응모이력 「取消」 탭으로 이동 + 읽음 처리
- 다른 디바이스에서 동시 로그인 중일 때 동기 확인 용도 (대부분 본인이 방금 한 행동 — 노이즈 낮음)

---

## 5. 관리자 UI 사양 (`dev/js/admin.js` + `dev/admin/app.js` + `dev/index.html` admin 부분)

### 5-1. 「신청 관리」 페인 (`/admin#applications`)

- 상태 필터 드롭다운에 「취소」 항목 1개 추가
- 정렬 옵션은 기존대로 유지
- 행에 「취소」 배지(회색) + cancel_phase 라벨(작은 글씨, 「취소(구매기간)」 등) 추가
- 검색창에 cancel_reason / cancel_reason_code도 매칭 (이름·이메일·캠페인명 검색 확장)

### 5-2. 인플루언서 상세 모달 「취소 사유」 카드

신청 행 클릭 시 열리는 상세 모달에 카드 1개 추가 (취소된 신청에만 노출):

```
┌──────────────────────────────────┐
│ 취소 사유                            │
│                                  │
│ 카테고리: 참여 가능 일정 부족          │
│ 보충: {cancel_reason 텍스트}           │
│ 시점:   구매기간                       │
│ 일시:   2026-05-11 14:30             │
│                                  │
│         [위반 등록]                  │
└──────────────────────────────────┘
```

- 「위반 등록」 버튼 → 기존 인플루언서 위반 등록 모달 reuse
  - `lookup_values(kind='violation_reason')` 신규 코드 `cancel_after_purchase_start` 기본 선택
  - 메모란에 cancel_reason 자동 prefill
  - 관리자가 검토 후 등록 또는 취소

### 5-3. 「캠페인별 신청자」 페인 (`/admin#camp-applicants`)

- 행 상태 셀에 「취소」 배지 + cancel_phase 라벨 표시
- 슬롯 카운트는 058 트리거에 의해 자동 갱신 (cancelled 제외)

### 5-4. 엑셀 내보내기 영향

- 「신청자 엑셀」(캠페인 더보기 메뉴) 17컬럼에 「취소일/취소 사유/취소 카테고리/취소 시점」 4컬럼 추가 → 21컬럼

---

## 6. 알림 (`supabase/functions/notify-application-cancelled/` + `admin_notices` 자동 등록)

### 6-1. Edge Function — 메일 알림

- 트리거: `applications.status` `pending|approved → cancelled` AND `cancel_phase != 'recruit'`
- DB 트리거(트리거 함수)에서 `pg_net.http_post`로 Edge Function 호출 또는 client-side에서 RPC 응답 후 호출
- 권장: `notify-brand-application` 패턴 따라 DB 트리거 → pg_net 비동기 호출
- **수신자**: `SELECT email FROM public.get_subscribed_admin_emails('application_cancel')` + `env NOTIFY_ADMIN_EMAILS` 외부 메일 합산
  - `get_subscribed_admin_emails` 헬퍼 함수는 **관리자 메일 수신 설정 분리 사양** 결과로 도입됨
  - 의존 사양: `docs/specs/2026-05-11-admin-email-subscriptions.md`
  - 본 PR-D는 그 사양 머지 후에 진행
- **발송 언어**: 한국어 (운영팀이 한국 운영진이므로)
- **제목 패턴 (확정)**: `[REVERB] 응모 취소 — {취소 시점 한국어} ({캠페인 번호} {캠페인 제목})`
  - 예시: `[REVERB] 응모 취소 — 구매기간 (【CAMP-2026-0042】 립프롬 신상 리뷰)`
  - 취소 시점 한국어: `모집기간 / 구매기간 / 방문기간 / 결과물 제출기간 / 기타`
  - 단 모집기간(`cancel_phase='recruit'`)은 발송 트리거 자체가 아님 (필터 단계에서 제외)
- 본문 구성 (한국어):
  - 캠페인 정보: 캠페인 번호, 제목, 모집 타입
  - 인플루언서: 이름(한자/가나), 이메일, 등록일
  - 취소 정보: 취소 일시, 취소 시점, 사유 카테고리(한국어 라벨), 보충 텍스트
  - 액션 링크: 「관리자 신청 관리 페인에서 확인」 → `{HOST}/admin#applications?id={app_id}`
- **메일 템플릿 파일 (2026-05-11 작성 완료)**:
  - `docs/email-templates/application-cancelled.html` — 실제 템플릿 (placeholder 포함)
  - `docs/email-templates/application-cancelled.preview.html` — 카탈로그 미리보기 (샘플값 채움)
  - PR-D 시 `supabase/functions/notify-application-cancelled/_templates/` 미러 동기화 (PR #125 `scripts/sync-email-templates.sh` 패턴 따름)
  - `docs/email-templates/index.html` 카탈로그 페이지에도 항목 1개 추가 (활성 메일 카탈로그 업데이트)
- **메일 템플릿 placeholder 키** (10개):
  - `{{campaign_no}}`, `{{campaign_title}}`, `{{recruit_type}}`, `{{influencer_name}}`, `{{influencer_email}}`, `{{cancelled_at}}`, `{{cancel_phase_ko}}`, `{{cancel_reason_ko}}`, `{{cancel_reason_note_row}}` (행 단위 HTML, 보충 텍스트 없을 시 빈 문자열), `{{admin_pane_url}}`

### 6-2. `admin_notices` 자동 등록

- 동일 DB 트리거에서 `admin_notices` row 추가
- category: `warning`, pin: false
- title: `응모 취소 — {캠페인 제목} / {인플루언서 이름}`
- body_html: 메일 본문과 동일한 정보를 Quill 호환 HTML로
- status: `published` (즉시 노출)
- created_by: NULL (시스템 생성), created_by_name: `system`
- 사이드바 미읽음 배지에 즉시 반영

---

## 7. 약관·개인정보처리방침 변경 (`docs/TERMS_{ja,kr}.md`)

### 7-1. TERMS 신규 섹션 추가

「§N 캠페인 신청 취소 정책」

내용 골자:
1. 인플루언서는 모집 기간 중에는 자유롭게 신청을 취소할 수 있음
2. 구매·방문·결과물 제출 기간이 시작된 후의 취소는 사유 입력과 함께 신청 시점에 동의한 약관·주의사항 위반으로 간주될 수 있음
3. 위반 등록 시 영향:
   - 향후 캠페인 신청 제한 가능성 (관리자 재량)
   - 누적 시 블랙리스트 등록 검토 대상
   - 정산금이 발생한 단계라면 환수 청구 대상
4. 결과물이 승인된 신청은 본인 취소 불가. 부득이 사정 시 관리자 문의

### 7-2. PRIVACY 영향

- 신규 수집 항목: `cancel_reason`, `cancel_reason_code`, `cancel_phase`, `cancelled_at`, `previous_status`
- 처리 목적: 「캠페인 운영 관리 — 신청 취소 및 위반 검토」
- 보유 기간: 기존 신청 이력과 동일 (탈퇴 시 파기)
- 별도 동의 항목 신규 추가는 불필요 (기존 「캠페인 운영 관리」 목적에 포섭)
- 변경 후 `/약관확인` 슬래시 명령 실행하여 점검

---

## 8. 단계별 PR 분할

| PR | 범위 | 파일 | 의존 |
|---|---|---|---|
| **PR-A. DB + RPC** | 마이그레이션 1개 (컬럼 5종 + UNIQUE 변경 + RPC + lookup seed 2건) + `dev/lib/storage.js`에 `cancelApplication()` / `fetchCancelReasons()` 추가 | `supabase/migrations/{N}_application_cancellation.sql`, `dev/lib/storage.js` | PR #152·#153 머지 후 |
| **PR-B. 인플루언서 UI** | 응모이력 ⋮ 메뉴 + 모달 2종 + 「取消」 탭 + i18n 키 + 활동관리 액션 + 차단 분기 | `dev/js/mypage.js`, `dev/js/ui.js` (getStatusBadge), `dev/index.html`, `dev/css/mypage.css`, `dev/lib/i18n/ja.js`, `dev/lib/i18n/ko.js` | PR-A |
| **PR-C. 관리자 UI** | 신청 관리 필터 + 상세 모달 카드 + 캠페인별 신청자 배지 + 엑셀 컬럼 4개 + 위반 등록 동선 | `dev/js/admin.js`, `dev/admin/app.js`, `dev/index.html` 관리자 부분 | PR-A |
| **PR-D. 알림** | DB 트리거 + Edge Function + admin_notices 자동 등록 + 메일 템플릿 | `supabase/migrations/{N+1}_application_cancel_notify.sql`, `supabase/functions/notify-application-cancelled/`, `docs/email-templates/application-cancelled.html`, `_templates/` 미러 | PR-A |
| **PR-E. 약관** | TERMS 신규 섹션 + PRIVACY 마이너 추가 + `/약관확인` 점검 | `docs/TERMS_ja.md`, `docs/TERMS_kr.md`, `docs/PRIVACY_*.md` | PR-B + PR-C |

**머지 순서**: PR-A → (PR-B + PR-C 병렬) → PR-D → PR-E

---

## 9. QA 시나리오 (개발서버 → reverb-qa-tester)

1. pending 상태, 모집 기간 중 취소 → 사유 없이 한 번에 → applied_count 감소 + 「取消」 탭 노출
2. approved 상태, 모집 기간 중 취소 → 슬롯 빈자리 복원 → 다른 응모자 승인 가능
3. approved 상태, 구매기간 시작 후 취소 → 경고 박스 + 카테고리 + 동의 체크 강제 → 미입력 시 차단
4. 동의 체크 없이 콘솔에서 RPC 직접 호출 → 서버 예외 `acknowledgement_required`
5. 결과물 1건이라도 approved → 「取消」 메뉴 비활성 + tooltip
6. 취소된 캠페인 재신청 → 신규 row INSERT (partial unique) → 049 트리거가 monitor 자동 승인
7. 관리자 「신청 관리」 → 「취소」 필터 → 상세 모달 사유 카드 확인 → 위반 등록 버튼 → lookup `cancel_after_purchase_start` 기본 선택
8. 구매기간 이후 취소 발생 → `receive_brand_notify=true` 관리자에게 메일 + admin_notices 자동 등록 + 사이드바 배지 갱신
9. 다중 탭 동시 취소 시도 → 두 번째는 `invalid_status` 예외
10. 인플루언서 상세 모달에서 「취소 사유」 카드의 cancel_phase 라벨이 한국어로 정확히 표시

---

## 10. 롤백 절차

PR-A 롤백이 필요한 경우:
1. 운영 SQL Editor에서 `cancel_application` 함수 DROP
2. `applications` 테이블 컬럼 5종 ALTER DROP (cancelled 행 데이터 손실 — 사전 백업 필수)
3. UNIQUE 제약 복원: `ALTER TABLE applications ADD CONSTRAINT applications_user_id_campaign_id_key UNIQUE (user_id, campaign_id);` (단 cancelled 행이 있으면 충돌 — 사전 정리)
4. lookup_values 신규 2건 비활성화 (`active=false`)
5. `git revert` PR-A 커밋

배포 전 운영 DB `applications` 테이블 백업 권장 (특히 partial unique 변경).

---

## 11. 충돌 점검 (선행 PR / 의존 사양과의 관계)

- PR #152(admin-split Phase 0): admin.js 주석 + SECTION 마커 추가. 본 작업의 PR-C가 admin.js 광역 수정 — **PR #152 머지 후 시작 권장**. SECTION 마커가 페인 식별을 도와 충돌 영향 최소화
- PR #153(제출마감-19일): admin.js의 `suggestSubmissionEnd()` 함수 8군데. 본 작업의 PR-C가 손대는 영역(신청 관리 페인)과 다르지만 동일 파일이라 머지 후 시작이 안전
- PR-B는 mypage.js 위주 — 두 PR과 영역 다름. PR-A 머지 후 별도로 진행 가능
- **관리자 메일 수신 설정 분리** (`docs/specs/2026-05-11-admin-email-subscriptions.md`): 본 작업 PR-D의 메일 발송 수신자 로직이 그 사양 결과(`get_subscribed_admin_emails` 함수, `admin_email_subscriptions` 테이블)를 사용. **그 사양 PR 머지 후 PR-D 진행** 필수. 그 사양이 먼저 머지되지 않으면 PR-D 메일이 잘못된 수신자에게 발송됨

---

## 12. 시작 절차 (PR #152·#153 머지 후)

```bash
# 메인 폴더에서
cd ~/Documents/projects/reverb-jp
git checkout dev
git pull origin dev

# 마이그레이션 번호 확인
ls supabase/migrations/ | tail -5

# /새세션 application-cancel 실행하여 worktree 생성
# 새 worktree에서 PR-A부터 순차 진행
```

---

## 13. 미해결 / 확정 필요

본 사양(캠페인 신청 본인 취소 기능)에서 결정해야 할 항목은 모두 확정 완료.

### 13-1. 확정 (2026-05-11)
- ~~사유 카테고리 6종 시드 항목 (§2-5 표)~~
- ~~활동관리 진입 차단 / 캠페인 상세 재응모 버튼 / 본인 취소 알림~~ (§4-8, §4-9, §4-10)
- ~~PR-D 알림 메일 제목 카피·발송 언어·본문 구조·placeholder~~ (§6-1)

### 13-2. 별도 후속 사양으로 분리 (본 사양 범위 외)
아래 항목은 본 사양과 직접 의존 없음. 본 기능 dev/main 배포 후 운영 데이터 축적 → 별도 사양으로 설계.

- **위반 등록 자동화 정책** (사용자 결정 2026-05-11)
  - 본 사양에서는 관리자 수동 등록만 구현
  - 자동화 정책 예시 (후속 사양 설계 시 검토): 누적 N회 이상 / 특정 cancel_phase / 결과물 단계까지 진행 후 취소 등에 따라 자동 위반 row INSERT
  - 후속 사양 작성 시점: 본 기능 dev 배포 후 최소 2주 운영 데이터 축적
- **결과물 승인 후 관리자 수동 취소 동선** (사용자 결정 2026-05-11)
  - 본 사양에서는 결과물 승인 후 본인 취소만 차단. 관리자 강제 취소 UI 미포함
  - 발생 시 운영팀이 DB 직접 UPDATE로 처리 (수동 SQL 패치)
  - 후속 사양 작성 시점: 실제 케이스 발생 후 또는 운영팀 요청 시

---

## 14. 구현 결과

**구현일:** 2026-05-11 (마이그레이션 104) — 개발 세션이 상세 채워야 함
**관련 마이그레이션:** `supabase/migrations/104_application_cancel.sql`

### 초안 대비 변경 사항

#### 달라진 것
- **PR 분할 구조 변경**: 사양서에서 5개 PR(DB·인플루언서 UI·관리자 UI·알림·약관) 예상 → 실제는 DB+UI 통합 1개 PR 로 단순화
- **PR-D 알림 메일**: 별도 PR 이 아닌 **2026-05-18 관리자 통합 다이제스트** (`notify-admin-daily-digest`, 마이그레이션 132)의 §2 응모 취소 섹션으로 흡수. `notify-application-cancelled-daily` Edge Function 의 cron 은 2026-05-18 해제됨

#### 구현된 것 (CLAUDE.md 기준)
- `applications` 테이블 취소 보조 컬럼 5종: `cancelled_at·cancel_reason·cancel_reason_code·cancel_phase CHECK(recruit|purchase|visit|post|other)·previous_status`
- `cancel_application(uuid, reason_code, reason_note, acknowledged)` 원격 호출 함수(행 단위 보안 정책(RLS) + 결과물 승인 차단 + 구매기간 이후 사유 + 동의 강제)
- `(user_id, campaign_id)` 중복 방지 제약을 부분 고유 인덱스로 변경 → 취소 후 재응모 가능
- `lookup_values` 취소 사유 6종 시드 + `cancel_after_purchase_start` 위반 사유 추가

### 잔존 작업 (다음 배포 사이클)
- main merge (현재 dev 잠재)
- 위반 등록 자동화 정책 (§13-2 — 데이터 축적 후)

---

## 15. 데드락 버그 수정 (2026-05-21)

**증상:** 인플루언서가 응모를 취소하려 해도 계속 에러만 나고 취소가 안 됨. (실사용자 Tomoko 사례 — "실수로 신청 → 취소하려는데 에러", 스크린샷 3장)

**원인 (코드로 확정):**
- 취소 화면은 단계(phase)에 따라 갈린다 — `recruit`이면 사유 입력란을 숨긴 **간단 취소**, 그 외엔 사유+동의 필수.
- 클라이언트 `_computeCancelPhase`(`dev/js/mypage.js`)와 서버 `cancel_application` RPC(마이그레이션 104)가 단계를 **각자 독립 계산**한다. 클라이언트는 `Date.parse`(UTC 자정 해석), 서버는 `now()` + `::timestamptz`(DB 타임존 기준). 경계 날짜에서 두 판정이 갈릴 수 있음.
- 클라이언트가 `recruit`으로 판정해 사유란을 숨겼는데(`isSimple=true`, 사유·동의를 `null/false`로 전송) 서버가 비-recruit로 판정하면 `reason_required`/`acknowledgement_required`로 거부 → 화면엔 사유란이 없는데 서버는 사유를 요구 → 무한 데드락.
- 부차: 클라이언트 에러 매핑에 `application_not_found`가 빠져 일반 오류(errorGeneric)로 표시됨.

**수정 (A안 — 자동 복구, 마이그레이션 없음):**
- `submitCancelApplicationFromPage`: 간단(recruit) 모드에서 서버가 `reason_required`/`acknowledgement_required`로 거부하면 → hidden phase를 `other`로 보정 + 사유 입력란을 자동으로 펼침(`_revealCancelReasonFields('other')`) + 안내문 표시 후 재입력 대기. 두 번째 제출(사유란 펼쳐진 상태)부터는 정상 검증 경로. phase 계산이 어떻게 엇갈리든 데드락이 풀린다.
- 박스 표시/사유 카탈로그 로드 로직을 헬퍼 2종(`_showCancelSimpleMode` / `_revealCancelReasonFields`)으로 추출해 진입 시·자동 복구에서 공통 사용.
- 에러 매핑에 `application_not_found` → `appHistory.cancel.errorNotFound` 추가.
- i18n 신규 키 2종: `appHistory.cancel.errorNotFound`, `appHistory.cancel.reasonNowRequired` (ja/ko 양쪽).
- 부수 수정: 기존 경고 카피 키 생성이 `warning${phase}`를 그대로 써서 i18n에 없는 `warningRecruit` 키를 시도하던 문제 → `['purchase','visit','post']` 화이트리스트 + 그 외 `warningOther` 폴백으로 정리.

**근본 해결(C안 — 서버 단일 판정)은 후속 백로그:** 서버에 단계 판정 함수를 두고 클라이언트가 그대로 따르게 하면 불일치 자체가 사라지나, 신규 마이그레이션·운영 DB 적용·진입 시 통신 1회 추가가 필요해 별도 검증 사이클로 분리. A안으로 출혈을 먼저 멈춤.

**관련 파일:** `dev/js/mypage.js`, `dev/lib/i18n/{ja,ko}.js`. **DB/RPC 변경 없음.**

**검증:** reverb-reviewer GO(헬퍼 추출 동작 동일성·무한 루프 차단·키 정합 확인). reverb-qa-tester light(응모 취소 정상 경로 + 에러 메시지 PASS).

### 원인 재평가 (2026-05-21) — 중요

수정 후 실제 데이터로 원인을 검증한 결과, **앞 문단의 "시간대 9시간 차이" 진단은 이 환경(운영)에서는 성립하지 않음**을 확인했다:
- 운영 DB `current_setting('TimeZone')` = **UTC**. date 컬럼을 `::timestamptz` 캐스팅하면 UTC 자정이고, 클라이언트 `Date.parse('YYYY-MM-DD')`도 UTC 자정 → **클라이언트와 서버의 단계 판정이 동일**. 따라서 시간대 차이로 인한 데드락은 평상시 발생하지 않는다.
- 데드락이 이론상 가능한 경우는 ① 마감 자정(UTC 0시 = KST 09:00) 경계를 "취소 화면 연 시각 ~ 제출 시각" 사이에 넘나들 때(드묾), ② 사용자 기기 시계 오차 — 둘 다 희귀.
- Tomoko(동명이인 다수, 安里智子 등) 신청 데이터 분석: gifting 캠페인은 구매·방문 기간이 없어 `deadline`만 지나면 곧장 `other` 단계가 되고 `other`는 사유·동의 필수. 즉 "모집 마감 후라 간단 취소가 안 되고 사유를 요구"하는 것은 **의도된 정책**이며 클라/서버 둘 다 `other`로 보므로 데드락 아님. 화면에 사유란이 정상 표시됐을 것.
- **결론:** Tomoko가 본 "에러"의 진짜 원인은 미확정. 가장 가능성 높은 것은 (가) 마감 후 신청이라 사유·동의를 요구받았으나 미입력으로 반복 실패 → 사용자가 "취소 불가"로 인지, (나) 이미 취소/오래된 신청 재시도 → `application_not_found`(기존엔 errorGeneric로 두루뭉술). 정확한 에러 화면/캠페인 미확보로 더 좁히지 못함(사용자 결정: 재현 안 되면 보류).

**이번 수정의 성격:** 근본 원인 직격은 아닐 수 있으나 **무해한 안전망 + 표시 개선**으로 유지 가치 있음 — ① 자정 경계/시계 오차 데드락(희귀)의 복구 경로, ② `application_not_found` 명확한 메시지, ③ `warningRecruit` 키 누락 버그 수정. 향후 DB 타임존이 비-UTC로 바뀌어도 안전.

**향후 과제(백로그):** Tomoko류 실제 에러 화면 확보 시 (가)/(나) 확정. gifting "모집 마감 후 ~ 제출 마감 전" 구간이 `other`로 떨어져 사유를 요구하는 UX가 사용자에게 혼란스러운지 별도 검토(정책 vs UX).

**배포:** dev 푸시 `d26caaa`. 운영 반영은 (개발서버 확인 후 결정 — 사용자 판단 대기).
