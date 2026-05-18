# 메일 통합 사양서 — 인플루언서 + 관리자 다이제스트 확장

- **작성일**: 2026-05-18
- **작성**: 메인 세션 (사용자 새 요청 기반 초안)
- **상태**: 사양 확정 완료 (2026-05-18 메인 세션) — 옵션 C + 보완 옵션 2 + 세부 결정 5종 모두 확정 (§13~§14 참조). HANDOFF 문서 별도 작성됨
- **선행**: `2026-05-18-application-email-pipeline.md` (운영 배포 완료, 마이그레이션 130)
- **선행 운영 상태**: 인플루언서 다이제스트 4섹션 + 관리자 접수 요약 1통 + cancel-daily 1통 + 결과물 검수 즉시 6종(`notify-deliverable-decision`) 모두 가동 중

---

## 1. 배경 및 동기

사용자 새 요청 (2026-05-18):
1. **관리자 일일요약 메일 3종 통합** — 응모 취소 + 캠페인 신청 접수 + 영수증·결과물 제출 내역을 한 통으로
2. **인플루언서 결과물 검수 메일도 일일 다이제스트로 통합 가능 의견** — 영수증/리뷰/게시 URL 승인·반려 6종을 인플 다이제스트로

### 우려 (사용자 직접 표명, 2026-05-18)
> "이게 정리가 안되면 메일 폭탄처럼 중복 메일이 발송될것 같아"

→ 즉시 메일과 다이제스트가 동시 가동되면 같은 사건이 두 번 발송되는 위험. 정리 원칙 필수.

---

## 2. 핵심 원칙 — 한 사건당 메일 1통

본 사양은 다음 원칙을 위반하면 안 됨:

> 같은 도메인 사건(예: 영수증 반려 1건)은 즉시 메일 또는 다이제스트 중 **정확히 하나의 채널**로만 발송된다.

원칙 위반 시 즉시 + 익일 이중 발송 = 메일 폭탄.

---

## 3. 현재 발송 메일 매트릭스 (2026-05-18 운영 적용 직후)

### 인플루언서 수신 메일
| 메일 | Edge Function | 발송 시점 | 중복 위험 |
|---|---|---|---|
| 응모 신청 접수 | (없음 — 인플 다이제스트 섹션 1) | 익일 09:00 | — |
| 응모 승인 | (없음 — 인플 다이제스트 섹션 2) | 익일 09:00 | — |
| 응모 반려 | (없음 — 인플 다이제스트 섹션 3) | 익일 09:00 | — |
| 마감 임박 (D-5/D-1) | (없음 — 인플 다이제스트 섹션 4) | 익일 09:00 | — |
| **영수증 승인** | `notify-deliverable-decision` | 검수 즉시 | 새 다이제스트로 옮기면 충돌 |
| **영수증 반려** | `notify-deliverable-decision` | 검수 즉시 | 새 다이제스트로 옮기면 충돌 |
| **리뷰 이미지 승인** | `notify-deliverable-decision` | 검수 즉시 | 새 다이제스트로 옮기면 충돌 |
| **리뷰 이미지 반려** | `notify-deliverable-decision` | 검수 즉시 | 새 다이제스트로 옮기면 충돌 |
| **게시 URL 승인** | `notify-deliverable-decision` | 검수 즉시 | 새 다이제스트로 옮기면 충돌 |
| **게시 URL 반려** | `notify-deliverable-decision` | 검수 즉시 | 새 다이제스트로 옮기면 충돌 |

### 관리자 수신 메일
| 메일 | Edge Function | 발송 시점 | 중복 위험 |
|---|---|---|---|
| 광고주 신청 접수 알림 | `notify-brand-application` | INSERT 즉시 | 다이제스트 통합 대상 아님 |
| 응모 취소 일일 요약 | `notify-application-cancelled-daily` | 매일 09:00 | 통합 시 흡수 |
| 캠페인 신청 접수 일일 요약 | `notify-application-received-admin-daily` | 매일 09:00 | 통합 시 흡수 |
| **결과물 제출 내역** | (없음 — 신규 요청) | (신규) | — |

---

## 4. 통합 방향 — 옵션 A/B/C 비교

### 옵션 A — 전부 다이제스트 (즉시 메일 0)

**인플루언서 측**:
- `notify-deliverable-decision` 6종 모두 **즉시 발송 중단**
- 인플 다이제스트에 신규 **섹션 5: 어제 결과물 검수 (승인 + 반려)** 추가
- 5섹션 1통/일

**관리자 측**:
- `notify-application-cancelled-daily` + `notify-application-received-admin-daily` + 결과물 제출 신규 → **단일 `notify-admin-daily-digest`** 로 통합
- 3섹션 1통/일

**장점**:
- 메일 수 최소화 (인플당 ~1통/일, 관리자 ~1통/일)
- 한 사건 = 한 메일 원칙 자명

**단점**:
- **결과물 반려도 익일 09:00 통보** → 인플루언서가 D-1 임박일에 반려 받으면 다음 날 안에 재제출 시간 부족 가능성
- 즉시성 손실이 가장 큼

---

### 옵션 B — 반려만 즉시, 나머지 다이제스트 (균형, 봇 추천)

**인플루언서 측**:
- `notify-deliverable-decision`: **반려 3종만 즉시 발송**, 승인 3종 즉시 발송 중단 (코드 한 줄 가드)
- 인플 다이제스트에 신규 **섹션 5: 어제 결과물 승인** 추가 (반려 제외 — 이미 즉시 발송됨)
- 평균 1~2통/일 (반려 발생 시만 즉시 + 다이제스트 1통)

**관리자 측**:
- 옵션 A 와 동일 — `notify-admin-daily-digest` 단일 통합 3섹션

**장점**:
- 결과물 반려는 즉시 통보 → 인플루언서 재제출 시간 확보 (특히 D-1 임박일 안전)
- 결과물 승인은 다이제스트로 묶임 (다음 단계 안내가 익일 09:00 이어도 영향 작음)
- 한 사건 = 한 메일 (반려는 즉시, 승인은 다이제스트)

**단점**:
- 코드 분기 1개 (`notify-deliverable-decision` 가 승인 vs 반려 분기)
- 인플 다이제스트 섹션 5 의 「반려 제외」 필터 추가

---

### 옵션 C — 관리자만 통합, 인플은 현재 유지

**인플루언서 측**: 변경 없음
- 인플 다이제스트 4섹션 + 결과물 검수 즉시 6종 그대로

**관리자 측**: 옵션 A 와 동일 — `notify-admin-daily-digest` 단일 통합 3섹션

**장점**:
- 변경 범위 최소
- 결과물 검수 즉시성 100% 보존
- 메일 폭탄 리스크 0 (인플 다이제스트가 결과물 섹션을 안 가짐)

**단점**:
- 인플루언서 메일 수 그대로 (검수 6종 + 다이제스트 1통)
- 사용자 새 요청 중 「인플 다이제스트에 결과물 통합」 부분 미수용

---

## 5. 옵션별 변경 파일·범위

### 옵션 A (가장 변경 큼)
- 마이그레이션: 신규 — `admin_daily_digest_runs` 로그 테이블 (또는 기존 2개 통합) — 결정 필요
- 신규 Edge Function: `notify-admin-daily-digest` (3섹션)
- 인플 다이제스트 수정: 섹션 5 (결과물 검수 승인 + 반려 통합) 추가
- `notify-deliverable-decision`: 6종 즉시 발송 완전 비활성화 (또는 Edge Function 폐기)
- 기존 2개 Edge Function (cancel-daily, received-admin-daily) 폐기 또는 호출 중단
- 기존 cron 2개 → 1개로 통합
- 메일 템플릿: 인플 다이제스트 row-deliverable 신규, 관리자 통합 다이제스트 신규
- 카탈로그 페이지 갱신

### 옵션 B (중간 변경)
- 옵션 A 와 동일하되 인플 다이제스트 섹션 5 가 **승인만** 포함
- `notify-deliverable-decision`: 승인 발송 분기 비활성화 (예: `if (action === 'approved') return;` 추가 또는 호출 측 webhook 필터)
- 메일 폭탄 방지 검증: 「어제 검수된 결과물 status='approved'」 만 다이제스트 섹션 5 에 포함

### 옵션 C (최소 변경)
- 신규 Edge Function: `notify-admin-daily-digest` (3섹션 — 신청 접수 + 응모 취소 + 결과물 제출)
- 기존 2개 Edge Function (cancel-daily, received-admin-daily) 폐기 또는 호출 중단
- 기존 cron 2개 → 1개로 통합
- 인플 측 변경 없음

---

## 6. 신규 섹션 — 「어제 결과물 제출 내역」 (관리자) 상세

### 시점 기준
- 어제 한국시간 0~24시 동안 `deliverables.created_at` (인플루언서 제출 시점)
- 검수 시점(`reviewed_at`)이 아니라 **제출 시점** 기준 (관리자가 「어제 들어온 일감」 확인 의도)

### 그룹화
- kind 별 그룹 (receipt / review_image / post)
- 또는 캠페인별 그룹 (선택 가능)

### 본문 예시
```
[REVERB] 관리자 일일 요약 — 2026-05-18

▶ 캠페인 신청 접수 (23건)
  [캠페인 A] - 인플 5명
  [캠페인 B] - 인플 3명
  ...

▶ 응모 취소 (3건)
  구매기간 1건 · 결과물 제출기간 2건
  ...

▶ 결과물 제출 (8건)
  영수증 5건 · 리뷰 이미지 2건 · 게시 URL 1건
  [캠페인 A] 야마다 사쿠라 — 영수증 제출
  ...
```

---

## 7. 신규 섹션 — 「어제 결과물 검수」 (인플루언서) 상세

### 옵션 A 시 (승인 + 반려 통합)
- `deliverables.reviewed_at` 어제 윈도우
- status IN ('approved', 'rejected')
- 각 행에 색상 라벨 (승인 = 초록, 반려 = 회색)
- 반려 시 사유 표시 (별도 컬럼 필요? 현재 `reject_reason` 컬럼이 있다면 활용)

### 옵션 B 시 (승인만)
- `deliverables.reviewed_at` 어제 윈도우
- **status = 'approved' 만**
- 「다음 단계 안내」 CTA 포함 (영수증 승인 → 리뷰 이미지 제출 안내)
- 반려는 이미 즉시 메일로 받음 → 다이제스트에서 제외

---

## 8. 사용자 결정 필요 항목

1. **옵션 A/B/C 중 선택**
2. **기존 Edge Function 처리**:
   - 완전 삭제 (Supabase Dashboard 에서 함수 자체 제거)
   - 코드 보존 + cron 만 해제 (호출 안 됨, 코드는 archive)
   - 코드 수정해서 분기만 비활성화 (옵션 B 의 deliverable-decision 처리)
3. **결과물 제출 섹션 그룹화**:
   - kind 별 (receipt/review_image/post)
   - 캠페인별
4. **「반려 사유」 노출** (옵션 A 의 인플 다이제스트 결과물 반려 섹션):
   - 사양서 §15 「반려 사유 컬럼은 별도 사양」 — 이번 작업 범위에 포함할지 분리할지
5. **운영 적용 타이밍**:
   - 인플 다이제스트 cron 등록 (현재 미등록) 직전에 통합?
   - 또는 인플 다이제스트 운영 자연 실행 결과 안정성 확인 후 통합?

---

## 9. 리스크

| 리스크 | 옵션별 영향 |
|---|---|
| 메일 폭탄 (즉시 + 다이제스트 이중 발송) | A=0 / B=0(가드 추가 시) / C=0 |
| 결과물 반려 즉시성 손실 → 재제출 마감 압박 | A=높음 / B=0 / C=0 |
| 결과물 승인 즉시성 손실 → 다음 단계 안내 지연 | A=중간 / B=중간 / C=0 |
| 코드 변경 범위·회귀 | A=큼 / B=중간 / C=작음 |
| 관리자 메일 수 감소 | A·B·C 모두 동일 (3→1통) |
| 인플루언서 메일 수 감소 | A=최대 / B=중간 / C=0 |

---

## 10. 추천안

봇 추천: **옵션 B (반려만 즉시, 나머지 다이제스트)** + **결과물 제출 섹션은 kind 별 그룹**.

근거:
- 결과물 반려는 인플루언서 재제출 시간이 중요 → 즉시 발송 유지 가치 큼
- 결과물 승인은 다음 단계 안내가 익일 09:00 이어도 영향 작음
- 메일 폭탄 방지 가드: `notify-deliverable-decision` 가 status='approved' 시 발송 안 함 (코드 한 줄)
- 관리자 통합으로 메일 산만함 ↓
- 변경 범위 옵션 A 보다 작고 옵션 C 보다 큼 (사용자 요청 「인플도 통합」 부분 반영)

다만 사용자가 「결과물 반려도 익일 통보 OK」 또는 「인플은 그대로 유지가 안전」 등 다른 의견이면 옵션 A 또는 C 로 변경.

---

## 11. 다음 단계

1. **사용자 사양 검토 + 옵션 결정**
2. 결정 후 마이그레이션·Edge Function·메일 템플릿 작업
3. 검증·배포는 인플 다이제스트 cron 등록 직전에 묶어서 진행 권장
4. 본 사양 결정 후 §12 「구현 결과」 채울 것

---

## 12. 구현 결과

**구현일:** 2026-05-18
**관련 마이그레이션:** 131 (application_events audit) + 132 (admin_daily_digest_runs)
**관련 PR:** PR 1 commit `45c891c` (dev) — application_events / PR 2 (본 세션, dev 잠재 + 운영 적용은 사용자 결정에 따라 진행)

### 최종 채택 옵션
- 메인 옵션: **C (관리자만 통합, 인플루언서 측 즉시 검수 메일 + 4섹션 다이제스트 유지)**
- 보완안: **옵션 2 (신청 + 결과물 양측 audit 도입 — 2차 변경 다이제스트 포착)**

### 초안 대비 변경 사항
- 추가된 것:
  - 신청 status 변경 audit 테이블 (마이그레이션 131, application_events) — 옵션 2 채택으로 신규
  - 관리자 통합 다이제스트 발송 로그 (마이그레이션 132, admin_daily_digest_runs) — PR 2 핵심
  - 신규 Edge Function `notify-admin-daily-digest` + 메일 템플릿 6종 (메인 + 섹션 wrapper + 4종 row)
  - 관리자 다이제스트 4섹션화 (재처리 섹션 신설)
- 빠진 것:
  - 인플루언서 다이제스트 결과물 섹션 추가 (옵션 C 채택으로 제외 — 즉시 검수 메일 유지)
  - application_events `reapply` 액션 (supabase-expert 검증으로 제거 — cancelled→pending UI 없음, 본인 재응모는 신청 접수 섹션이 잡음)
- 달라진 것:
  - 관리자 다이제스트 결과물 제출 섹션 데이터 소스가 `deliverables.created_at` 이 아닌 `deliverable_events.action='submit'` 기준 (재제출 자동 배제, supabase-expert 검증 반영)
  - application_events 액션 매핑에 approved↔rejected 직접 전이 추가 (단계 생략·직접 SQL 대비, 방어적 audit)
  - 마이그레이션 132 인덱스 단순화 (partial 인덱스 → 단순 created_at 인덱스)
  - 컬럼명 통일: `run_at`·`recipients_count`·status='failed' (130 의 단수 표기·113 의 'error' 표기 모두 130 패턴 + 113 패턴 일치 방향으로 정리)

### 구현 중 기술 결정 사항

**PR 1 — application_events (마이그레이션 131)**
- 트리거 SECURITY DEFINER + `SET search_path = ''` + `public.` 접두사 통일 (077·104·128 패턴 일치)
- `changed_by` FK `ON DELETE SET NULL` 추가 — 관리자 삭제 시 audit 데이터 보존 (`changed_by_name` 스냅샷으로 추적)
- 인덱스 2종: `(application_id, created_at DESC)` + `(created_at DESC)` (다이제스트 윈도우 조회용)
- 행 단위 보안 정책: SELECT 만 `is_admin()`, INSERT/UPDATE/DELETE 정책 없음 → 트리거만 INSERT (deliverable_events 패턴 일치)

**PR 2 — admin_daily_digest (마이그레이션 132 + Edge Function)**
- **INSERT 선행 mutex 패턴** (supabase-expert 검증 반영) — 기존 cancel-daily/received-admin-daily 의 「precheck 후 INSERT」 패턴은 동시 호출 시 메일 중복 발송 가능성. 신규 함수는 INSERT 먼저 (status='failed' 마커, digest_date UNIQUE = mutex) → 23505 시 중복 호출 차단 → 성공 시 데이터 처리 → 메일 발송 후 UPDATE 로 실제 상태 갱신
- **섹션 3 데이터 소스 변경** — 초안의 `deliverables.created_at` 대신 `deliverable_events.action='submit'` 사용 (재제출 자동 배제, 사양 의도 명확화)
- **수신자 합집합 + 개별 try-catch** — `get_subscribed_admin_emails('application_cancel')` ∪ `get_subscribed_admin_emails('application_received')` ∪ env. Promise.all 안 한쪽 RPC 실패 시도 다른 쪽 + env 폴백 (cancel-daily 패턴 강화)
- **cron 전환 순서** — 신규 cron 먼저 등록 후 기존 2종 해제 (반대 순서면 그날 관리자 메일 0통 발송)
- **기존 Edge Function 2종 보존** — cron 만 해제, Edge Function 코드는 운영 안정화 2주 후 별도 정리 PR 에서 삭제. 카탈로그 ⑫·⑭ 카드에 「DEPRECATED 2026-05-18」 표기 + 신규 ⑮ 카드 추가

### 검증·배포 절차 (HANDOFF §5-7, §5-8)

PR 1 — 개발·운영 양 DB 적용·검증 완료 (2026-05-18).

PR 2 — 본 세션에서 코드 작성 완료. 다음 단계:
- 개발서버 배포 + 시드 데이터로 curl 수동 호출 + 관리자 메일 직접 확인 (HANDOFF §5-7)
- 운영 배포 결정 후 마이그레이션 132 적용 + Edge Function 배포 + cron 전환 (HANDOFF §5-8)
- 다음 날 09:00 KST 첫 자동 발송 확인

### 후속 별도 PR

운영 2주 안정화 후 별도 정리 PR (HANDOFF §6-1):
- `notify-application-cancelled-daily` + `notify-application-received-admin-daily` Supabase Dashboard·repo 삭제
- `application_cancel_digest_runs` / `application_received_admin_digest_runs` 테이블 DROP 검토 (감사 보존 시 보존)
- 카탈로그 deprecated 카드 제거

---

## 13. 1차 결정 사항 (2026-05-18 확정 — 메인 세션)

### 13-1. 통합 방향 — 옵션 C 채택
- 인플루언서 측 발송 매트릭스 **변경 없음** (즉시 검수 메일 6종 + 인플 다이제스트 4섹션 유지)
- 관리자 측 일일 메일 2종 (`notify-application-cancelled-daily`, `notify-application-received-admin-daily`) 을 신규 단일 Edge Function `notify-admin-daily-digest` 로 통합
- 광고주 신청 접수 즉시 메일 (`notify-brand-application`) 은 도메인 사건이 다르므로 통합 대상 아님 — 그대로 유지

### 13-2. 보완 — 옵션 2 채택 (양측 audit 도입)
- `deliverable_events` (기존 테이블) 활용 — 결과물 측 재제출·되돌리기 다이제스트 자동 포착
- **신규 마이그레이션 — `application_events` 테이블** — 신청 status 변경 audit. 트리거로 자동 기록
- 관리자 다이제스트 본문에 **「어제 재처리된 일감」 신규 섹션** 추가 (결과물 + 신청 통합)

### 13-3. 관리자 다이제스트 최종 본문 구조 (4섹션 + 푸터)

```
[REVERB] 관리자 일일 요약 — YYYY-MM-DD

▶ 캠페인 신청 접수 (N건)
  (어제 0~24시 신규 INSERT)

▶ 응모 취소 (N건)
  (어제 cancel_phase != recruit 인 취소)

▶ 결과물 제출 (N건)
  (어제 deliverable_events action='submit' — 최초 제출 한정)

▶ 재처리 일감 (N건)  ← 신규 섹션
  - 결과물 재제출 (deliverable_events action='resubmit', 어제 윈도우)
  - 결과물 되돌리기 (deliverable_events action='revert', 어제 윈도우)
  - 신청 되돌리기 (application_events action='revert_to_pending', 어제 윈도우)
```

각 섹션 0건이면 생략 (4섹션 모두 0건이면 메일 미발송 + skipped_no_data 로그).

> **본인 응모 취소 후 재응모는 §1 「신청 접수」 섹션이 잡음** — 마이그레이션 104 의 partial unique index 패턴으로 본인 재응모는 새 INSERT 행이 되므로 §4 재처리 섹션이 아닌 §1 신청 접수 섹션 안에서 집계됨. 따라서 `application_events` 에는 `reapply` 액션 없음. supabase-expert 검증 (2026-05-18) 결과 반영.

---

## 14. 세부 결정 사항 (2026-05-18 확정 — 메인 세션 5종 일괄 승인)

옵션 C + 보완 옵션 2 채택 후 세부 결정 5종 모두 봇 추천안 그대로 확정.

### 14-1. application_events 트래킹 범위 (마이그레이션 설계)

| 안 | 트래킹 대상 | 비고 |
|---|---|---|
| **A (확정)** | 운영자 액션만 — 승인/반려/되돌리기 | reviewed_by 가 있을 때만 INSERT. 본인 취소(cancel_application RPC) 는 제외 — 이미 cancelled_at 으로 추적됨 |
| B | 모든 status 변경 | 본인 취소 + 운영자 액션 + 시스템 자동 (없음) 모두 |

**확정 근거**: 본인 취소는 이미 `cancelled_at` 으로 다이제스트 §2 응모 취소 섹션이 잡음. 중복 트래킹 피하기 위해 audit 은 운영자 액션만.

### 14-2. application_events 컬럼 구조

| 컬럼 | 타입 | 설명 |
|---|---|---|
| id | uuid | 기본 키 |
| application_id | uuid FK CASCADE | 신청 |
| action | text CHECK | `approve` / `reject` / `revert_to_pending` (3종, supabase-expert 검증 반영 — `reapply` 제외) |
| from_status | text CHECK | pending / approved / rejected / cancelled |
| to_status | text CHECK | pending / approved / rejected / cancelled |
| changed_by | uuid FK ON DELETE SET NULL | auth.uid() — 관리자 (삭제 시 SET NULL) |
| changed_by_name | text | 관리자 이름 스냅샷 (auth 삭제 후에도 audit 보존) |
| created_at | timestamptz NOT NULL DEFAULT now() | 이벤트 발생 시점 |
| memo | text NULL | 반려 사유 / 되돌리기 사유 등 (현재 트리거는 NULL 만 INSERT, 추후 확장) |

행 단위 보안 정책(RLS): SELECT 는 `is_admin()`, INSERT/UPDATE/DELETE 정책 없음 → 트리거로만 INSERT.

인덱스 2종:
- `(application_id, created_at DESC)` — 신청별 audit 타임라인 조회용
- `(created_at DESC)` — 다이제스트 어제 윈도우 조회용 (supabase-expert 검증 — partial 인덱스 대신 단순 인덱스로 변경. 일일 트래픽이 적어 partial 분리 비용이 더 큼)

트리거 매핑 (마이그레이션 131 본문 참조):
- `pending → approved` = approve
- `pending → rejected` = reject
- `approved/rejected → pending` = revert_to_pending
- `approved → rejected` = reject (단계 생략·직접 SQL 대비)
- `rejected → approved` = approve (단계 생략·직접 SQL 대비)
- `* → cancelled` 및 `cancelled → pending` = 무시 (각각 cancel_application 별도 추적 / UI 없음)

### 14-3. 기존 Edge Function 2종 처리 — 확정: **cron 해제 + 코드 보존**

| 안 | 절차 | 롤백 |
|---|---|---|
| **A (확정)** | Supabase Dashboard 에서 cron 스케줄 2개 해제. Edge Function 코드는 그대로 둠. 사양서·CLAUDE.md 에 "deprecated, archived" 표기 | 통합 함수 문제 발생 시 cron 재등록만으로 즉시 복귀 |
| B | Edge Function 자체 삭제 (Supabase Dashboard + repo) | 롤백 시 코드 재배포 필요 |

**확정 근거**: 신규 통합 함수가 운영 안정화될 때까지 (2주 권장) 기존 함수 보존. 안정화 후 별도 정리 PR 에서 삭제.

### 14-4. 「결과물 제출」 섹션 그룹화 — 확정: **kind 별 그룹**

| 안 | 본문 구조 | 비고 |
|---|---|---|
| **A (확정)** | kind 별 — 영수증 N건 / 리뷰 이미지 N건 / 게시 URL N건 (각 행에 캠페인+인플) | 검수 워크플로가 kind 별로 나뉘어 있어 일감 우선순위 판단 용이 |
| B | 캠페인별 하위 kind 별 | 캠페인 단위 운영 시 적합. 단 일일 8건이 캠페인 8개에 흩어지면 8줄 파편화 |

**확정 근거**: 검수자 입장에서 "오늘 들어온 영수증 N건부터" 처리하는 흐름이 자연스러움.

### 14-5. 운영 적용 타이밍 — 확정: **인플 다이제스트 cron 등록 직전 통합**

| 안 | 절차 |
|---|---|
| **A (확정)** | 인플 다이제스트 cron 미등록 상태 → 통합 함수 개발·검증 완료 후 인플 다이제스트 cron + 통합 함수 cron 함께 등록 (1회 전환) |
| B | 인플 다이제스트 cron 먼저 등록 + 2~3일 안정화 → 그 후 통합 함수 별도 배포 |

**확정 근거**: 인플 다이제스트는 이미 마이그레이션 130 으로 코드 + DB 가 운영에 올라가 있으나 cron 만 미등록. 통합 함수와 cron 등록을 한 번에 묶으면 운영 전환 시점이 명확.

---

## 15. 작업 분해 (참고용 — 사양 확정 후 HANDOFF 별도 작성)

PR 단위 예상:

| PR | 범위 | 의존성 |
|---|---|---|
| PR 1 — 신청 status 변경 audit 테이블 | 마이그레이션 신규 (`application_events` 테이블 + 트리거) | 없음 |
| PR 2 — 관리자 통합 다이제스트 Edge Function | `notify-admin-daily-digest` 신규 (4섹션) + cron 등록 + 기존 2종 cron 해제 + 카탈로그 갱신 | PR 1 운영 배포 완료 |
| PR 3 — 인플 다이제스트 cron 등록 | 운영 cron 1줄 추가 (코드 변경 없음) | PR 2 와 동시 또는 직후 |

PR 1·2 는 한 묶음 (동일 세션에서 처리 가능), PR 3 은 운영 전환 시점 결정에 따라 분리 또는 동시.

---

## 16. 리스크 (옵션 C + 보완 2 기준 갱신)

| 리스크 | 옵션 C+2 영향 | 완화 |
|---|---|---|
| 메일 폭탄 (즉시 + 다이제스트 이중 발송) | 0 — 결과물 도메인은 즉시 메일만, 신청 도메인은 다이제스트만 | 도메인 사건 분리로 자동 |
| 결과물 반려 즉시성 손실 | 0 — 즉시 검수 메일 유지 | — |
| 2차 변경 다이제스트 누락 | 0 — application_events + deliverable_events 양측 audit 으로 포착 | 옵션 2 보완 |
| application_events 트리거가 본인 취소까지 잡으면 cancel 섹션과 중복 | 14-1 추천안 A 채택 시 0 | 운영자 액션만 트래킹 |
| audit 테이블 무한 누적 | 시간당 수 행 수준이라 1~2년 영향 미미 | 추후 archive 정책 별도 |
| 통합 함수 첫 가동일 0건 발송 부담 | 4섹션 모두 0건이면 미발송 + skipped_no_data 로그 | 기존 동작 그대로 승계 |
