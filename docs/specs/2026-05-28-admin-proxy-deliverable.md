# 관리자 결과물 대리 등록·자동 승인

**작성일:** 2026-05-28
**작성 세션:** 기획/설계
**배경:** 인플루언서가 제품 배송 지연 등으로 결과물 제출 마감일 후에 결과물을 등록하는 케이스가 발생. 관리자가 인플과 별도 소통 후 **결과물을 대신 등록하고 즉시 승인**할 수 있는 운영 도구가 필요. 등록 사유를 남기고, 「관리자 대리 등록」이 운영자에게 명확히 식별되어야 함.

---

## 1. 확정 사항 (사용자 결정 2026-05-28)

| 항목 | 결정 |
|---|---|
| 적용 결과물 종류 | **영수증(receipt) + 게시물(post)** 즉시 적용 / **리뷰 이미지(review_image)** 는 사양 2 운영 후 자동 확장 |
| 권한 | `is_campaign_admin()` 이상 — 운영 빈도 고려해 super_admin 한정 아님 |
| 마감 전후 제약 | **없음** — 마감 전이라도 운영 필요 시 사용 가능 (배송 지연 외 케이스 대응) |
| 등록·승인 흐름 | **단일 트랜잭션** — INSERT + 자동 승인 한 번에 |
| 사유 입력 | **사유 코드 드롭다운(필수) + 자유 메모(선택)** |
| 인플루언서 알림 | **발송** — 「관리자가 결과물을 대신 등록·승인했습니다」 |
| 표시 | 결과물 목록·검수 모달·진행 현황·엑셀에 「대리 등록」 배지·컬럼 |
| 마이그레이션 번호 | 작업 시점 `ls supabase/migrations/` 재확인 (본 사양 작성 시 156이 최신) |

## 2. 결과물 종류별 입력 폼 (대리 등록 모달)

종류 드롭다운 선택 시 폼이 분기:

| 종류 | 입력 항목 |
|---|---|
| **영수증** (`kind='receipt'`, monitor 캠페인) | 이미지 업로드 + 주문번호 + 구매일 + 구매금액 |
| **게시물 (URL)** (`kind='post'`, gifting/visit 캠페인) | 게시물 URL + 자동 채널 판별 (인플 폼과 동일 로직 재사용) + 실패 시 수동 채널 드롭다운 |
| **리뷰 이미지** (`kind='review_image'`, 사양 2 후) | 이미지 업로드 + 채널 선택 (캠페인 채널 중) |

종류 드롭다운은 선택된 신청의 캠페인 모집 유형(`recruit_type`)·채널 구성에 맞게 가능한 종류만 노출(잘못된 조합 차단).

## 3. 데이터 모델

### 3-1. `deliverables` 컬럼 4종 추가 (마이그레이션 1개)

```sql
ALTER TABLE public.deliverables
  ADD COLUMN IF NOT EXISTS submitted_by_admin uuid REFERENCES public.admins(id),
  ADD COLUMN IF NOT EXISTS submitted_by_admin_reason_code text,
  ADD COLUMN IF NOT EXISTS submitted_by_admin_reason text,
  ADD COLUMN IF NOT EXISTS submitted_by_admin_at timestamptz;

COMMENT ON COLUMN public.deliverables.submitted_by_admin IS
  '관리자 대리 등록 시 그 관리자 ID. NULL=인플 본인 제출.';
```

- 인플 본인 제출은 4개 컬럼 모두 NULL — 기존 행 영향 없음
- `submitted_by_admin IS NOT NULL` 인 행이 대리 등록 식별 기준

### 3-2. lookup_values 신설 (사유 코드)

```sql
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active) VALUES
  ('admin_proxy_reason', 'shipping_delay',     '배송 지연',           '配送遅延',         10, true),
  ('admin_proxy_reason', 'system_error',       '시스템 오류',         'システムエラー',   20, true),
  ('admin_proxy_reason', 'inflexible_deadline','기간 외 합의 처리',   '期間外協議',       30, true),
  ('admin_proxy_reason', 'other',              '기타',                'その他',           90, true)
ON CONFLICT (kind, code) DO NOTHING;
```

기준 데이터 페인(`#lookups`)에서 운영자가 추가·수정 가능.

### 3-3. 신규 RPC — `admin_create_deliverable_proxy`

```sql
CREATE OR REPLACE FUNCTION public.admin_create_deliverable_proxy(
  p_application_id uuid,
  p_kind text,                  -- 'receipt' | 'post' | 'review_image'
  p_post_channel text,          -- post/review_image 일 때만
  p_image_url text,             -- receipt/review_image 일 때만 (Storage URL)
  p_post_url text,              -- post 일 때만
  p_order_number text,          -- receipt 일 때만
  p_purchase_date date,         -- receipt 일 때만
  p_purchase_amount numeric,    -- receipt 일 때만
  p_reason_code text,           -- 사유 코드 (필수)
  p_reason text                 -- 사유 자유 메모 (선택)
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_admin_id uuid;
  v_deliverable_id uuid;
BEGIN
  -- 권한 가드
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;

  -- 관리자 ID 조회
  SELECT id INTO v_admin_id FROM public.admins WHERE auth_id = auth.uid();

  -- kind별 필수 필드 검증 + UNIQUE 위반 사전 체크
  -- (post+post_channel UNIQUE, review_image+post_channel UNIQUE)

  -- INSERT + 자동 승인
  INSERT INTO public.deliverables (
    application_id, kind, post_channel,
    receipt_url, post_url,
    order_number, purchase_date, purchase_amount,
    status, reviewed_by, reviewed_at, submitted_at,
    submitted_by_admin, submitted_by_admin_reason_code,
    submitted_by_admin_reason, submitted_by_admin_at,
    user_id
  )
  VALUES (
    p_application_id, p_kind, p_post_channel,
    CASE WHEN p_kind IN ('receipt','review_image') THEN p_image_url ELSE NULL END,
    CASE WHEN p_kind='post' THEN p_post_url ELSE NULL END,
    p_order_number, p_purchase_date, p_purchase_amount,
    'approved', auth.uid(), now(), now(),
    v_admin_id, p_reason_code, p_reason, now(),
    (SELECT user_id FROM public.applications WHERE id = p_application_id)
  )
  RETURNING id INTO v_deliverable_id;

  -- audit + 알림
  INSERT INTO public.deliverable_events (deliverable_id, action, from_status, to_status, changed_by)
    VALUES (v_deliverable_id, 'admin_proxy_submit', NULL, 'approved', auth.uid());

  INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
  SELECT
    a.user_id,
    'deliverable_proxy_submitted',
    'deliverables',
    v_deliverable_id,
    '結果物が登録されました',
    '運営側で結果物を登録・承認しました。理由: ' || COALESCE(p_reason, p_reason_code)
  FROM public.applications a WHERE a.id = p_application_id;

  RETURN v_deliverable_id;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_create_deliverable_proxy(uuid, text, text, text, text, text, date, numeric, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_deliverable_proxy(uuid, text, text, text, text, text, date, numeric, text, text) TO authenticated;
```

### 3-4. `deliverable_events.action` 신규 코드
- `'admin_proxy_submit'` — 관리자 대리 등록·승인

### 3-5. `notifications.kind` 신규 코드
- `'deliverable_proxy_submitted'` — 인플 알림. `ref_table='deliverables'`, 클릭 시 활동관리로 이동(기존 deliverable_* 알림 패턴 재사용)

## 4. UI — 결과물 관리 페인 (`dev/js/admin-deliverables.js`)

### 4-1. 페인 헤더에 「관리자 대리 등록」 버튼
- 클릭 시 모달 오픈

### 4-2. 대리 등록 모달
- **신청 선택** — 캠페인 + 인플루언서 검색·드롭다운(approved 상태만, 본 캠페인의 신청자)
- **결과물 종류 선택** — 캠페인 `recruit_type`·`channel` 구성에 맞게 가능한 종류만 노출
- **종류별 폼 분기** (§2 참조)
- **사유 코드** 드롭다운(필수) + **사유 메모** 텍스트(선택)
- **「대리 등록 및 자동 승인」** 버튼 → RPC 호출
- 확인 모달: 「인플루언서에게 「관리자가 결과물을 대신 등록·승인했습니다」 알림이 발송됩니다. 진행할까요?」

### 4-3. 목록 행 표시
- 대리 등록된 행에 **「대리 등록」 배지** (노랑/주황 톤)
- 배지 툴팁: 「{관리자 이름} · {사유 라벨} · {시점}」
- 「대리 등록만 보기」 필터 추가 (기본 OFF)

### 4-4. 검수 모달
- 대리 등록 행 진입 시 상단에 안내 박스 (노랑 배경):
  「관리자 대리 등록 — {관리자 이름} · {사유 라벨}{메모 있으면 메모}{시점}」
- 인플레이스 수정·되돌리기는 기존 패턴 유지 (단 대리 등록 행의 「되돌리기」는 의미상 모호 → 비활성 권장)

### 4-5. 캠페인 진행 현황 (`#camp-applicants`)
- 결과물 상태 칩 옆에 작은 마커 (예: 「영수증 ✓⊕」 — ⊕ 가 대리 등록 마커)
- 호버 툴팁: 「관리자 대리 등록」

## 5. 엑셀 다운로드 (`dev/js/admin-excel.js`)

결과물 엑셀에 **「대리 등록」 컬럼 1개 추가**:
- 인플 본인 제출: 공란
- 관리자 대리 등록: 「{관리자 이름} · {사유 라벨}」 (메모는 공간 효율상 생략)
- 단일 캠페인 결과물 엑셀 + 다중 캠페인 결과물 엑셀 양쪽 적용

신청자 엑셀은 결과물 컬럼 없음 → 영향 없음.

## 6. 인플루언서 활동관리 화면 (`dev/js/application.js`)

- 대리 등록된 결과물 행에 **작은 안내 배지**: 「運営登録」
- 클릭 시 사유 라벨 툴팁 (메모는 노출 안 함 — 운영 내부 정보)
- 인플 본인이 다시 「제출」 시도 시: 「이미 운영진이 등록한 결과물이 있어 추가 제출은 불가합니다」 토스트 (현행 UNIQUE 위반 처리와 일관)

## 7. 약관·개인정보 영향

- 새 수집 항목 없음
- 처리 흐름 변경 없음
- **약관·개인정보처리방침 개정 불필요** (보강 안 함 — 사용자 결정)

## 8. 의존·후속

| 관계 | 사양/메모 | 비고 |
|---|---|---|
| 후속 통합 | `docs/specs/2026-05-28-multichannel-deliverable-split.md` (리뷰어 결과물 모델 확장) | 사양 2 운영 적용 후 `kind='review_image'` 대리 등록 자동 활성 (본 RPC가 이미 review_image 분기 포함) |
| 참고 | `dev/js/admin-deliverables.js` `update_receipt_admin` RPC (기존 영수증 인플레이스 수정) | 권한 가드·SECURITY DEFINER 패턴 재사용 |

## 9. PR 분할

- **PR 1 — DB + RPC**:
  - 마이그레이션 (컬럼 4종 + lookup_values + RPC + audit 액션 코드 + 알림 kind)
  - reverb-supabase-expert 호출 필수
- **PR 2 — 결과물 관리 UI**:
  - 대리 등록 모달 + 종류별 폼 분기
  - 목록 행 배지 + 검수 모달 안내 박스 + 「대리 등록만」 필터
- **PR 3 — 진행 현황 칩 + 엑셀 + 인플 화면 배지**:
  - 캠페인 진행 현황 마커
  - 엑셀 컬럼 추가
  - 인플 활동관리 배지

## 10. 게이트·QA

- **에이전트 호출 의무**:
  - `reverb-planner` — PR 1 착수 직전
  - `reverb-supabase-expert` — 마이그레이션·RPC 작성 시
  - `reverb-reviewer` — 모든 commit 직전
  - `reverb-qa-tester` Full — 인플 알림 발송 영향 + 권한 영역 변경 → 운영 배포 전 필수

- **회귀 시나리오**:
  - 영수증 대리 등록 → 인플 활동관리에 「운영등록」 배지 + 승인 상태로 보임 + 알림 1건
  - 게시물 URL 대리 등록 → 자동 채널 판별 + 같은 신청 본인 재제출 차단
  - 같은 신청에 이미 인플이 제출한 결과물이 있을 때 대리 등록 시도 → UNIQUE 친절 에러
  - campaign_manager 권한으로 RPC 호출 시도 → 42501 차단
  - 본인 제출 결과물은 기존 동작 무영향(컬럼 4종 NULL)

- **운영 적용 직전 점검 SQL**:
  ```sql
  -- 사유 lookup 4건이 잘 들어갔는지
  SELECT code, name_ko FROM lookup_values WHERE kind='admin_proxy_reason' ORDER BY sort_order;
  -- 컬럼 4종 추가 확인
  SELECT column_name FROM information_schema.columns
  WHERE table_schema='public' AND table_name='deliverables'
    AND column_name LIKE 'submitted_by_admin%';
  ```

## 11. 운영 시나리오 (예시)

1. 인플 A — 「Qoo10 화장품 리뷰」 캠페인 신청·승인. 제품 배송이 12일 늦어져 결과물 마감일 경과.
2. 인플 A가 LINE으로 운영팀에 「영수증·리뷰 등록이 안 됩니다」 문의.
3. 운영자가 LINE에서 영수증 사진·주문번호·구매일·금액·리뷰 캡쳐 수령.
4. 관리자 페이지 「결과물 관리」 → 「관리자 대리 등록」 → 신청 A 선택 → 영수증 종류 선택 → 이미지 업로드 + 주문번호·구매일·금액 입력 → 사유 「배송 지연」 + 메모 「6/12 도착 확인, 인플 LINE 협의 완료」 → 등록.
5. 동일 패턴으로 리뷰 이미지 채널별 대리 등록(사양 2 적용 후).
6. 인플 A에게 「結果物が登録されました — 배송 지연으로 운영 측에서 등록」 알림 발송.
7. 인플 A 활동관리 화면에 결과물 「승인됨 · 運営登録」 표시.
8. 운영자 검수 모달 진입 시 사유·시점·관리자 이름 안내 박스 노출.
9. 엑셀 다운로드 시 「대리 등록」 컬럼에 「{관리자} · 배송 지연」 표기.

---

## 구현 결과

(개발 세션이 채울 것)

**구현일:**
**관련 커밋:**

### 초안 대비 변경 사항
-

### 구현 중 기술 결정 사항
-
