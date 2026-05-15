# 영수증 제출 필수 입력 강화 + 관리자 검수 수정 + 변경 이력

**작성일:** 2026-05-14
**작성자:** 기획 세션
**구현 담당:** 개발 세션 (TBD)
**예상 마이그레이션:** 122
**관련 사양서:** 없음 (신규)

---

## 1. 배경 / 문제

- 리뷰어(monitor) 캠페인의 결과물 검수에서 영수증 이미지만으로는 마켓에서 주문 확인이 어려움. 인플루언서가 입력한 **주문번호**가 있으면 마켓 관리자 페이지에서 즉시 대조 가능
- 현재 구매일·구매금액은 `receipts` 테이블에 컬럼은 있으나, 인플루언서 제출 폼에서 필수 검증이 일관되지 않음 (개발 세션이 코드 확인 필요)
- 관리자가 검수 중 인플루언서 입력 오타·누락을 발견해도 직접 정정할 수단이 없어, 인플루언서에게 재제출을 요청해야 하는 비효율 존재

## 2. 요구사항

### 2-1. 인플루언서
- 리뷰어(monitor) 캠페인 영수증 제출 시 아래 3개 항목 **모두 필수 입력**
  - 주문번호 (신규)
  - 구매금액 (이미 컬럼 있음)
  - 구매일 (이미 컬럼 있음)
- 빈값 / 공백만 입력 차단 (자유 텍스트, 형식 검증은 빈값만)
- 활동관리 신규 제출 폼 + 재제출 폼 모두 적용

### 2-2. 관리자
- 결과물 검수 모달에서 위 3개 값을 **수정 가능**
- 수정 권한: `campaign_admin` 이상 (super_admin·campaign_admin) — `campaign_manager` 는 열람만
- 수정 시 자동으로 변경 이력에 기록
- 결과물 검수 모달 안에서 변경 이력 타임라인 열람 가능

### 2-3. 변경 이력 (audit)
- 누가 / 언제 / 어느 필드를 / 어떤 값에서 → 어떤 값으로 바꿨는지 모두 저장
- 별도 테이블 `receipt_edit_history` 신규 생성
- 인플루언서 본인의 재제출(=신규 행 생성에 가까움)은 이력 대상 외, **관리자가 기존 행을 수정한 경우만** 기록

## 3. 정책 충돌 — 마스킹 해제 검토 필요 ⚠️

### 현재 정책
2026-04-30 (0d2b599): 관리자 결과물 검수 모달에서 영수증 `purchase_date`/`purchase_amount` **마스킹**. 인플루언서 본인 화면에서만 표시 (개인정보 최소 노출 원칙).

### 이번 요청과의 충돌
관리자가 값을 수정하려면 화면에 표시되어야 함 → 마스킹 정책 해제 필요.

### 영향 검토
- 영수증 이미지 자체는 이미 관리자가 열람 가능 (이미지 위에 구매일·금액이 그대로 보임)
- 따라서 텍스트로 노출 추가가 「개인정보 신규 노출」 은 아니고 「이미 보이는 값을 수정 가능 폼에 다시 표시」 수준
- **개인정보 처리방침(PRIVACY) 영향: 미미** (수집 항목·처리 목적 변경 없음, 관리자 접근 권한도 기존 범위 내)
- 다만 운영 시작 후 `/약관확인` 명령으로 한번 더 점검 권장

### 결정 (사용자 확인 필요)
사양서 채택 시 **검수 모달의 영수증 마스킹 해제 + 수정 폼 표시** 로 진행. 반대 의견 있으면 사양서 §3 수정.

## 4. DB 변경 (마이그레이션 122)

### 4-1. 신규 컬럼
```sql
ALTER TABLE public.receipts
  ADD COLUMN order_number text NULL;

COMMENT ON COLUMN public.receipts.order_number IS
  '인플루언서 입력 주문번호 (자유 텍스트, 빈값 차단). 2026-05-14 추가, 기존 데이터는 NULL';
```

`deliverables` (kind='receipt') 의 스냅샷 jsonb 또는 컬럼에도 동일 키 추가 — 개발 세션이 현행 dual-write 구조 확인 후 결정.

### 4-2. 변경 이력 테이블 (신규)
```sql
CREATE TABLE public.receipt_edit_history (
  id              bigserial PRIMARY KEY,
  receipt_id      uuid NOT NULL REFERENCES public.receipts(id) ON DELETE CASCADE,
  changed_by      uuid NOT NULL,
  changed_by_name text NOT NULL,
  changed_at      timestamptz NOT NULL DEFAULT now(),
  -- prev / next 스냅샷 (3개 필드 일괄)
  order_number_prev    text,
  order_number_next    text,
  purchase_date_prev   date,
  purchase_date_next   date,
  purchase_amount_prev numeric,
  purchase_amount_next numeric,
  source           text NOT NULL DEFAULT 'admin_edit'
                   CHECK (source IN ('admin_edit', 'influencer_resubmit'))
);

CREATE INDEX idx_receipt_edit_history_receipt
  ON public.receipt_edit_history (receipt_id, changed_at DESC);

ALTER TABLE public.receipt_edit_history ENABLE ROW LEVEL SECURITY;

-- 관리자만 SELECT (super_admin + campaign_admin + campaign_manager 모두 열람 가능)
CREATE POLICY "admin_read_receipt_history"
  ON public.receipt_edit_history FOR SELECT
  USING (public.is_admin());

-- INSERT/UPDATE/DELETE 정책 미정의 → SECURITY DEFINER 함수만 INSERT 가능
```

### 4-3. 신규 원격 호출 함수 (RPC)
```sql
CREATE OR REPLACE FUNCTION public.update_receipt_admin(
  p_receipt_id     uuid,
  p_order_number   text,
  p_purchase_date  date,
  p_purchase_amount numeric
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_admin_name text;
  v_prev       record;
BEGIN
  -- 권한 가드: campaign_admin 이상
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)';
  END IF;

  -- 빈값 검증
  IF p_order_number IS NULL OR btrim(p_order_number) = '' THEN
    RAISE EXCEPTION '주문번호는 빈값일 수 없습니다';
  END IF;
  IF p_purchase_date IS NULL THEN
    RAISE EXCEPTION '구매일은 빈값일 수 없습니다';
  END IF;
  IF p_purchase_amount IS NULL OR p_purchase_amount <= 0 THEN
    RAISE EXCEPTION '구매금액은 0보다 커야 합니다';
  END IF;

  -- 기존 값 조회
  SELECT order_number, purchase_date, purchase_amount
    INTO v_prev
    FROM public.receipts
   WHERE id = p_receipt_id;

  IF v_prev IS NULL THEN
    RAISE EXCEPTION '영수증을 찾을 수 없습니다';
  END IF;

  -- 변경 사항 없으면 no-op
  IF v_prev.order_number    IS NOT DISTINCT FROM p_order_number
     AND v_prev.purchase_date   IS NOT DISTINCT FROM p_purchase_date
     AND v_prev.purchase_amount IS NOT DISTINCT FROM p_purchase_amount THEN
    RETURN;
  END IF;

  -- 관리자 이름 스냅샷
  SELECT name INTO v_admin_name
    FROM public.admins WHERE auth_id = auth.uid();

  -- UPDATE
  UPDATE public.receipts
     SET order_number    = p_order_number,
         purchase_date   = p_purchase_date,
         purchase_amount = p_purchase_amount
   WHERE id = p_receipt_id;

  -- 이력 INSERT
  INSERT INTO public.receipt_edit_history (
    receipt_id, changed_by, changed_by_name,
    order_number_prev, order_number_next,
    purchase_date_prev, purchase_date_next,
    purchase_amount_prev, purchase_amount_next,
    source
  ) VALUES (
    p_receipt_id, auth.uid(), COALESCE(v_admin_name, '(이름미상)'),
    v_prev.order_number, p_order_number,
    v_prev.purchase_date, p_purchase_date,
    v_prev.purchase_amount, p_purchase_amount,
    'admin_edit'
  );

  -- TODO: deliverables 테이블이 영수증 값을 별도 컬럼/jsonb로 가지고 있다면 동기화 필요
  -- 개발 세션이 dual-write 구조 확인 후 추가
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_receipt_admin TO authenticated;
```

### 4-4. 검토 대상 (개발 세션)
- `deliverables` 테이블의 영수증 스냅샷 구조 확인 후 동기화 처리 추가
- 인플루언서 신규 제출용 RPC가 별도로 있다면 거기에도 `order_number` 파라미터 추가
- `submit_deliverable` RPC 시그니처 변경 시 하위호환 (NULL DEFAULT) 고려

## 5. UI 변경

### 5-1. 인플루언서 — 활동관리 영수증 제출 폼
- **추가 입력칸**: "주문번호" (한 줄 텍스트). 라벨 일본어 (예: 「注文番号」)
- 기존 입력칸: 영수증 이미지 / 구매일 / 구매금액 → 모두 필수 표시 (`*` 마크 등)
- 제출 시 클라이언트 측 빈값 검증 + DB 측 RPC 가드 이중 방어
- 에러 메시지 일본어
- 재제출 폼도 동일 (반려된 영수증 다시 올릴 때)

### 5-2. 관리자 — 결과물 검수 모달
- 영수증 섹션 표시 항목 (마스킹 해제):
  - 영수증 이미지 (기존)
  - **주문번호** (신규, 한국어 라벨)
  - 구매일 (마스킹 해제)
  - 구매금액 (마스킹 해제)
- 우측 또는 하단에 「수정」 버튼 (campaign_admin 이상만 노출)
- 수정 모드 전환 시:
  - 3개 항목이 입력 가능한 폼으로 전환
  - 「저장」 클릭 → `update_receipt_admin` RPC 호출 → 성공 토스트 + 모달 데이터 새로고침
  - 「취소」 → 원본 표시로 복귀
- 「변경 이력」 토글:
  - 관리자 전체 열람 가능 (campaign_manager 포함)
  - 타임라인 형식 (날짜 / 관리자 / 어떤 필드 어떻게 바뀜)
  - `campaign_caution_history` 모달 패턴 참고
- 검수 결정 버튼(승인/반려)은 별도 — 영수증 정보 수정과 검수 결정은 분리된 동작

### 5-3. 결과물 엑셀 내보내기
- 캠페인 단위 결과물 엑셀에 「주문번호」 컬럼 추가
- 위치: 구매일·구매금액 옆

## 6. 영향 범위

| 영역 | 변경 |
|---|---|
| DB | 마이그레이션 122 — 컬럼 1개 + 테이블 1개 + RPC 1개 |
| 인플루언서 코드 | `dev/js/application.js` 또는 결과물 제출 영역 + i18n 키 추가 |
| 관리자 코드 | `dev/js/admin.js` 결과물 검수 모달 — 마스킹 해제, 주문번호 표시, 수정 폼, 변경 이력 모달 |
| 엑셀 | `dev/js/admin.js` 결과물 엑셀 내보내기 헤더·셀 |
| 문서 | `FEATURE_SPEC.md`, `CLAUDE.md` (스키마 + 마스킹 정책 변경 반영) |
| 약관 | 영향 미미 — `/약관확인` 한 번 호출 권장 |

## 7. 의존성·실행 순서

- 마이그레이션 121 운영 적용 완료 후 122 진행
- 다른 동시 작업과 충돌 없음 (영수증 영역 단독)
- 단계:
  1. 개발 세션이 `dev/js/admin.js` 영수증 검수 모달 코드 확인 + `deliverables` 영수증 스냅샷 구조 확인
  2. `reverb-planner` 호출로 구현 계획 정리
  3. `reverb-supabase-expert` 호출로 마이그레이션 122 작성·검증
  4. 인플루언서 폼 + 관리자 모달 코드 수정
  5. 개발서버 적용 → 검증 → 운영 SQL 적용 → 운영 코드 머지

## 8. 약관·개인정보 영향

- **수집 항목 신규 추가**: 주문번호 — 개인 식별 정보는 아니나 PRIVACY 「수집하는 개인정보」 항목 점검 필요
- **관리자 접근 범위 확장 (마스킹 해제)**: 기존에 마스킹된 값이 다시 노출됨 — 다만 영수증 이미지에 이미 보이는 정보라 실질 영향 미미
- 운영 배포 전 `/약관확인` 호출 권장. PRIVACY 변경이 사소하면 알림 없이 반영, 「수집 항목」 추가는 차회 약관 개정 시 함께 반영

## 9. 미해결 / 추후 검토

- (없음 — 모든 분기점 사용자 확정)

---

## 구현 결과

**구현일:** 2026-05-15
**관련 커밋:** (dev 머지 후 채움)
**마이그레이션 번호:** 128 (사양서 원안 122 → 127까지 소진되어 128로 부여)

### 초안 대비 변경 사항

#### 추가된 것
- 영수증 데이터 원본 저장소 결정: **`deliverables` 단일 사용** (사양서 §4 원안의 `receipts` 가정 변경)
- review_image kind는 영수증 정보 블록 대상에서 제외 (영수증과 별개 단계라 주문번호 무관)
- 관리자 모달 수정 후 `refreshPane('deliverables')` 호출로 페인 목록도 함께 새로고침
- 「변경 이력 보기」 토글이 같은 패널에서 다시 누르면 닫히도록 toggle 동작 추가
- 엑셀 영수증 그룹 헬퍼 `renderReceiptCells9(d)` — 기존 `renderDeliverableCells` 호출 후 주문번호·구매일·구매금액 3개를 끼워 넣는 어댑터 (DRY)

#### 빠진 것
- `receipts` 테이블 컬럼 추가는 진행하지 않음 (현행 코드가 receipts 미경유 → 컬럼 추가해도 데이터가 안 들어가 무의미)
- 035 dual-write 트리거 변경 없음 (영수증 흐름이 receipts 안 거치므로 트리거 발화 자체가 거의 없음 — dead code 상태 보존)
- `submit_deliverable` RPC 시그니처 변경 없음 (draft→pending 전환만 담당)

#### 달라진 것
- 사양서 §3 마스킹 해제: **사용자 확정**(2026-05-15) → 진행
- 사양서 §4-3 RPC 대상: `receipts` → `deliverables` 로 변경
- 사양서 §4-3 금액 검증: `> 0` → `>= 0` 완화 (0엔 무료 시연 허용 — 사용자 결정)
- 사양서 §5-3 엑셀 컬럼: 「주문번호 1개만 추가」 → **3개 모두 추가** (사용자 결정, 마스킹 해제 정책 정합)

### 구현 중 기술 결정 사항

1. **영수증 저장소 결정**: 활동관리 현행 코드(`addDraftImage` → `insertDraftDeliverable`)가 `receipts` 테이블을 거치지 않고 `deliverables`에 직접 INSERT 중. 사양서가 가정한 receipts INSERT 흐름과 불일치 발견 → 사용자 확인 후 `deliverables` 단일 사용으로 확정. receipts 테이블·035 dual-write 트리거는 dead code로 보존(향후 별도 PR로 정리).
2. **0엔 허용**: 무료 시연·샘플 케이스 대응. 사양서 §4-3의 `> 0`을 `>= 0`로 완화.
3. **kind='receipt' 가드**: `update_receipt_admin` 안에서 대상이 receipt가 아니면 즉시 에러. review_image나 post에 주문번호 잘못 적용 방지.
4. **`FOR UPDATE` 행 잠금**: 두 관리자가 동시에 같은 영수증을 수정해도 직렬화. 두 번째 시도는 첫 번째 결과를 본 후 처리.
5. **no-op 체크**: 3종 값이 모두 기존값과 같으면 RETURN(이력 미기록). 「수정」 클릭 후 변경 없이 「저장」 눌러도 빈 이력이 쌓이지 않음.
6. **관리자 이름 스냅샷 보존**: `changed_by_name`을 admins 변경 시점에 캡처해 둠. admins 행 삭제 후에도 이력에서 누가 수정했는지 라벨로 식별 가능. FK 미설정.
7. **권한 가드 이중**: 클라이언트 `isCampaignAdminOrAbove()` + RPC 안 `is_campaign_admin()` 두 곳에서 확인.
8. **변경 이력 SELECT 범위**: 전체 관리자(campaign_manager 포함)에게 열람 허용 — 검수 결정에 참고 정보가 필요할 수 있음.
9. **i18n 키 분리**: 라벨(label) 3종 + 에러 메시지(error) 5종 = 총 8개. 양언어 ja/ko 모두 추가.
10. **마이그레이션 번호**: 사양서 원안 122를 무시하고 **128**로 재부여. 사양서 작성 후 122~127까지 다른 작업에 사용됨.

### 약관 영향
- PRIVACY 「수집하는 개인정보」에 "주문번호" 추가 검토 필요 — 운영 배포 전 `/약관확인` 슬래시 명령 호출 권장. 다만 주문번호는 인플루언서가 임의로 입력하는 거래 식별자라 PIPA/APPI 의미의 「개인 식별 정보」는 아님. 정책 영향 미미.

### 후속 작업
- `receipts` 테이블·035 dual-write 트리거 정리 PR (별도 분리, 향후 운영 데이터 정리 후)
- PRIVACY 다국어 파일 업데이트 검토
