# 캠페인 노출 토글 — 자동 마감일에서 수동 토글로 전환 사양서

- **작성일**: 2026-05-13
- **작성**: 기획 세션
- **상태**: 개발 착수 전 (미구현)
- **다음 마이그레이션 번호 후보**: 122 (이전 사양서에서 117~121 예약)

---

## 1. 배경 및 목표

### 현재 동작
- `campaigns.post_deadline` 날짜가 경과하면 인플루언서 화면에서 자동 비노출
- 운영자가 캠페인 등록 시 게재 마감일을 명시적으로 지정

### 변경 후 동작
- 자동 비노출 제거 — 날짜 기반 비노출 동작 없음
- **운영자가 「캠페인 노출」 토글을 명시적으로 OFF** 해야만 인플루언서 화면에서 사라짐
- 토글 OFF 시 캠페인 상태가 **「노출마감」(expired)** 으로 변경
- 토글 ON 으로 다시 켜면 날짜 기반으로 상태 재계산 (scheduled/active/closed)

### 도입 이유
- 결과물 게시 마감일이 지나도 운영자 판단에 따라 캠페인을 계속 노출하고 싶은 경우가 있음
- 운영자 수동 제어가 사업 상황에 더 부합

---

## 2. 최종 결정 사항

| 항목 | 결정 |
|---|---|
| `post_deadline` 필드 | **완전 제거** — DB 컬럼도 삭제 |
| 토글 위치 | 캠페인 생성/수정 폼 **최상단** |
| 토글 라벨 | 좌측 "캠페인 노출" + ON/OFF 토글 (참고 이미지 스타일) |
| 기본값 | **ON** (신규 캠페인은 노출 상태로 시작) |
| 캠페인 목록 빠른 토글 | **추가** — 한 번 클릭으로 ON/OFF |
| 토글 OFF 시 상태 | **`expired` (노출마감)** |
| 토글 ON 시 상태 | 날짜 기반 자동 재계산 (scheduled/active/closed) |
| 기존 운영 데이터 마이그레이션 | **모두 토글 ON으로 초기화** — 운영자가 일일이 OFF 처리 |
| migration 097 (expired 상태) | **이번 작업과 함께 운영 배포** |

---

## 3. 상태 모델 (변경 후)

캠페인 상태 5종 (migration 097 동일):
- `draft` — 등록 준비 중 (인플 화면 비노출)
- `scheduled` — 모집 예정 (recruit_start 미도래)
- `active` — 모집 중
- `closed` — 모집 마감, 결과물 진행 중
- `expired` — **노출마감 (수동 토글 OFF)**

### 자동 전이 (유지)
- `scheduled` → `active` : `recruit_start` 도래 시
- `active` → `closed` : `deadline` 경과 시
- 위 전이는 `expired` 가 아닐 때만 동작

### 수동 전이 (신규 토글로)
- 어디서든 → `expired` : 토글 OFF 시
- `expired` → 다른 상태 : 토글 ON 시, 날짜 기반 재계산

### 자동 전이 제거 (현재 dev에 있는 동작)
- `closed` → `expired` 자동 전이 **제거** (`post_deadline` 경과 시 자동 expired 처리하던 로직 삭제)

---

## 4. 인플루언서 화면 노출 규칙 (변경 후)

```
status 가 expired = 비노출
status 가 draft   = 비노출
그 외 (scheduled / active / closed) = 노출
```

- `closed` 캠페인은 모집 마감 오버레이(`募集締切`) 로 표시되지만 토글 OFF 전까지 계속 노출
- 운영자가 「이제 됐다」 판단 시 토글 OFF → 인플 화면에서 사라짐

---

## 5. DB 변경

### 5-1. migration 097 운영 배포
**파일**: `supabase/migrations/097_campaign_status_redesign.sql` (이미 dev 적용됨)
- `status` CHECK 제약 변경: `draft / scheduled / active / paused / closed` → `draft / scheduled / active / closed / expired`
- `paused` 상태 제거, `expired` 추가
- 운영 DB SQL Editor 에 적용 필요

### 5-2. 새 마이그레이션 122 — post_deadline 제거 + 자동 전이 제거
**파일**: `supabase/migrations/122_remove_post_deadline_and_autoexpire.sql`

```sql
-- 1. post_deadline 자동 전이 함수 (autoExpireCampaigns 등) 삭제 또는 수정
--    현재 클라이언트의 autoCloseCampaigns 호출 체인 안에 있을 가능성 — 코드도 함께 정리

-- 2. campaigns.post_deadline 컬럼 DROP
ALTER TABLE public.campaigns DROP COLUMN IF EXISTS post_deadline;

-- 3. 기존 expired 캠페인을 자동 재계산 → 토글 ON 상태로 초기화
--    사용자 결정: 모든 expired 캠페인을 다시 노출시킴
UPDATE public.campaigns
SET status = CASE
  WHEN recruit_start IS NULL OR recruit_start <= now() THEN
    CASE WHEN deadline IS NULL OR deadline > now() THEN 'active' ELSE 'closed' END
  ELSE 'scheduled'
END
WHERE status = 'expired';
```

⚠ post_deadline 을 참조하는 다른 함수·트리거·뷰가 있는지 사전 grep 필수:
- `supabase/migrations/*.sql` 에서 `post_deadline` 검색
- 발견 시 모두 수정 또는 제거

### 5-3. 추가 검토 — submission_end 와의 관계
- `submission_end` (결과물 제출 마감일) 은 그대로 유지
- `post_deadline` 과 `submission_end` 는 별개 개념 — `post_deadline` 만 제거

---

## 6. UI 변경

### 6-1. 캠페인 생성/수정 폼 — 최상단 토글

화면 구조 (변경 후):
```
[← 목록으로] 캠페인 편집  [캠페인 번호 배지]

┌────────────────────────────────────────────────────────────┐
│ 캠페인 노출    [ON ●━━] / [━━● OFF]                        │  ← 신규
│                                                            │
│ 상태: 모집중 (자동 계산 — recruit_start 도래, deadline 미경과) │
└────────────────────────────────────────────────────────────┘

기본 정보
  캠페인명 *
  브랜드 *
  ...
```

- 토글 우측에 현재 상태 텍스트 표시 (이해 보조)
- 토글 OFF 시 상태 표시가 "노출마감 (수동)" 으로 변경
- 토글 ON 시 상태가 자동 계산 결과로 표시

### 6-2. 캠페인 목록 — 빠른 토글

기존 「상태」 컬럼에 작은 토글 추가:
- 토글 ON: 현재 상태 배지 + 작은 ON 표시
- 토글 OFF: "노출마감" 배지 + 작은 OFF 표시
- 클릭 시 즉시 변경 + 토스트 ("노출이 OFF로 변경되었습니다")

### 6-3. 모집기간 입력 영역 — post_deadline 부분 제거

기존 `dev/admin/index.html` 의 캠페인 등록/편집 폼:
- 「모집 기간」 range picker 유지 (`recruit_start ~ deadline`)
- 「게시 기간」 single picker (`post_deadline`) **제거**
- 「구매·방문 기간」 range picker 유지

### 6-4. 상태 도움말 모달 갱신
캠페인 관리 표 헤더 「상태」 옆 info 아이콘 → 도움말 모달:
- 5단계 상태 설명: draft / scheduled / active / closed / expired
- 자동 전이 규칙
- expired 상태는 **수동 토글 OFF로만 진입** 명시

---

## 7. 토글 동작 로직

### 7-1. 토글 OFF → 동작

```js
async function toggleCampaignVisibility(campaignId, newValue) {
  if (newValue === false) {
    // OFF: status를 expired로 변경
    await updateCampaign(campaignId, { status: 'expired' });
  } else {
    // ON: status를 날짜 기반 재계산
    const cur = await fetchCampaign(campaignId);
    const newStatus = computeCampaignStatus(cur);  // scheduled/active/closed 중 하나
    await updateCampaign(campaignId, { status: newStatus });
  }
}

function computeCampaignStatus(campaign) {
  const now = new Date();
  if (campaign.recruit_start && campaign.recruit_start > now) return 'scheduled';
  if (campaign.deadline && campaign.deadline <= now) return 'closed';
  return 'active';
}
```

### 7-2. 토글 변경 시 확인 모달 (선택)

운영자 실수 방지용 확인 모달:
- 토글 OFF 시: "캠페인을 비노출로 전환합니다. 인플루언서 화면에서 사라집니다. 계속할까요?" [취소] [확인]
- 토글 ON 시: 확인 모달 없이 즉시 적용

draft 상태에서의 토글:
- draft 캠페인은 토글 자체를 **비활성화 또는 숨김** (아직 발행 전이라 노출 개념 무관)
- 발행 액션은 별도 (현재 시스템에 발행 흐름이 어떻게 되어 있는지 확인 필요)

---

## 8. 변경 파일 목록

### DB
- `supabase/migrations/097_campaign_status_redesign.sql` 운영 배포 (이미 dev에 있음)
- `supabase/migrations/122_remove_post_deadline_and_autoexpire.sql` (신규)

### 클라이언트
- `dev/admin/index.html` — 토글 영역 추가, post_deadline picker 제거, 상태 도움말 모달 갱신
- `dev/js/admin.js` — 토글 렌더/핸들러, 폼 저장 시 토글 값 처리, post_deadline 입력 제거
- `dev/lib/storage.js` — `toggleCampaignVisibility` 함수 추가
- `dev/css/admin.css` — 토글 스타일 (참고 이미지의 ON/OFF 모양)
- `dev/js/campaign.js` (인플루언서측) — 노출 필터 조건이 status 기준 그대로 동작하는지 확인 (post_deadline 참조 제거)
- `dev/build.sh` — 신규 파일 없으면 변경 불필요

### 사전 grep 필요
- `grep -rn "post_deadline" dev/ supabase/migrations/` — 영향 범위 전수 조사
  - 자동 종료 함수 (`autoCloseCampaigns` 등)
  - 인플루언서 화면 노출 필터
  - 캠페인 목록 D-day 표시
  - 엑셀 내보내기
  - 미리보기 모달
  - 상태 도움말 모달 텍스트

---

## 9. 토글 UI 스타일 (참고 이미지 기반)

사용자가 첨부한 토글 이미지의 스타일을 따름:
- 배경: 회색 (OFF) / 초록 (ON)
- 손잡이: 흰색 원
- 둥근 모서리 알약 모양
- 좌측에 "캠페인 노출" 라벨

CSS 예시(클래스명 가안):
```css
.campaign-visibility-toggle { ... }
.campaign-visibility-toggle.is-on { background: #22C55E; }
.campaign-visibility-toggle.is-off { background: #9CA3AF; }
.campaign-visibility-toggle .knob { ... }
```

---

## 10. 회귀 체크 목록

- [ ] 캠페인 등록 시 토글 기본값이 ON
- [ ] 토글 OFF → 인플루언서 화면에서 즉시 사라짐 + 관리자 화면에서 status="노출마감"
- [ ] 토글 ON → 인플루언서 화면에 다시 노출 + status가 날짜 기반으로 재계산
- [ ] 캠페인 목록의 빠른 토글 클릭 → 즉시 반영 + 토스트
- [ ] post_deadline 입력 칸이 폼에서 사라짐
- [ ] post_deadline 경과 시 자동 expired 동작 없음
- [ ] draft 캠페인은 토글 동작 비활성/숨김
- [ ] 인플루언서 응모 차단 — expired 캠페인은 응모 불가
- [ ] migration 097의 status CHECK 제약이 운영에 정상 반영
- [ ] 기존 운영 데이터의 expired 캠페인이 마이그레이션 후 자연 상태(active/closed/scheduled)로 복귀
- [ ] 캠페인 검색·필터·정렬에 expired 옵션 표시
- [ ] 엑셀 내보내기에서 post_deadline 컬럼 제거 + status 컬럼에 expired 표시

---

## 11. 작업 시작 절차 (개발 세션용)

1. `git pull origin dev` — 최신 동기화
2. `ls supabase/migrations/ | tail -5` — 다음 가용 마이그레이션 번호 확인 (예상 122)
3. **사전 grep 영향 조사**: `grep -rn "post_deadline" dev/ supabase/migrations/ docs/`
4. 발견된 모든 참조 정리 계획 수립 (reverb-planner 추가 호출 권장)
5. migration 122 작성 → 개발 DB 적용
6. 097 운영 배포 (기존 dev 검증 결과 활용)
7. 122 운영 배포 + 캠페인 목록 검증 (자연 상태로 복귀했는지)
8. 클라이언트 코드 수정 — 폼·목록·인플 화면 모두
9. `cd dev && bash build.sh`
10. 개발서버 검증
11. reverb-reviewer + reverb-supabase-expert + reverb-qa-tester 호출
12. 사용자 개발서버 확인 → 운영 배포

---

## 12. 다른 사양서와의 의존성

| 사양서 | 관계 |
|---|---|
| `2026-05-13-brand-ops-redesign.md` | 운영 현황 화면에 「캠페인 노출 OFF」 캠페인을 어떻게 표시할지 결정 필요 — 별도 그룹으로 보이거나 필터에 포함 |
| `2026-05-13-brand-app-price-check.md` | 무관 |
| `2026-05-13-brand-app-product-payment-flags.md` | 무관 |
| `2026-05-13-application-cancel-daily-email-fix.md` | 무관 |

---

## 13. 제외 항목 (이번 작업 범위 밖)

- 토글 변경 audit 이력 (누가 언제 ON/OFF 했는지) — 필요해지면 별도 사양
- 일정 시간 후 자동 OFF 예약 기능 (예: 30일 뒤 자동 expired) — 명시 요구 없음
- 인플루언서에게 캠페인 종료 알림 발송 — 명시 요구 없음
- 모집기간 연장 빠른 액션 (이전 사양서에서 제외)

---

## 14. 리스크 / 애매한 부분

| 리스크 | 영향 | 대응 |
|---|---|---|
| 기존 데이터 모두 ON으로 복귀 시 갑자기 옛 캠페인이 인플 화면에 다시 보임 | 일시적 혼란 가능 | 운영 적용 전 운영자에게 "각자 OFF 처리 필요" 안내 + 일괄 OFF 도구 제공 검토 |
| post_deadline 을 참조하는 코드 누락 | 빌드 실패 또는 stale 동작 | 사전 grep 전수 조사 + reviewer 점검 |
| migration 097 운영 배포가 다른 작업과 시간 충돌 | 배포 순서 의존성 | `2026-05-13-brand-ops-redesign.md` 의 088~090 운영 배포와 같은 시점에 같이 적용 검토 |
| 운영자가 토글 의미를 헷갈림 | "OFF 했는데 화면에 안 보임" 등 문의 | 상태 도움말 모달 + 폼 안 안내 텍스트 명확화 |
| 결과물 마감 안내 (옛 post_deadline 용도) 가 사라짐 | 인플루언서가 결과물 마감 일정 알기 어려움 | submission_end 와 deadline 으로 충분한지 사용자 확인 필요 |

---

## 구현 결과

**구현일:** 2026-05-18
**관련 마이그레이션:** `supabase/migrations/129_remove_post_deadline.sql`

### 사전 진단 결과 (운영 DB)
- `paused_count` = 0 (paused 데이터 없음)
- `expired_count` = 35 (097이 이미 운영 DB 에 적용된 상태로 확인됨)
- `submission_null_count` = 35 (모두 expired 와 동일 캠페인)
- `closed_with_pd_count` = 47
- CHECK 제약: `('draft','scheduled','active','closed','expired')` — 097 운영 적용 완료

### 초안 대비 변경 사항

#### 빠진 것 (사용자 결정으로 의도적 제외)
- **§2 결정사항: 「모든 expired 캠페인을 자연 상태로 복귀」** → 사용자 결정으로 **expired 35건 그대로 보존**. 운영자가 명시적으로 OFF 한 적 없이 자동 비노출됐던 옛 캠페인이라 갑자기 다시 노출하지 않음
- **§5-2 step 3: 자연 복귀 UPDATE** 미실행
- **submission_end 백필 (Q2-C)** → 폴백 제거(Q2-A) 채택. expired 35건은 인플 화면 비노출이라 결과물 마감 표시 영향 없음

#### 추가된 것 (초안에 없었음)
- **`get_brand_ops_detail(uuid)` 함수 재정의** — 120 마이그레이션의 함수가 `post_deadline` 을 SELECT 함을 supabase-expert 검토에서 발견. 129 단계 1로 함수 재정의 후 단계 2 컬럼 DROP 순서로 처리
- **캠페인 목록 빠른 토글 mini 클래스** (`.visibility-toggle.is-mini`) — 상태 컬럼 통합 시 폼 토글보다 작은 크기 필요해 신규 추가
- **post_days 컬럼 클라이언트 참조 정리** — admin.js:4344 에서 post_deadline 의존이라 같이 제거

#### 달라진 것
- **§6-2 캠페인 목록 빠른 토글** — 상태 배지 + 미니 토글 버튼 (실제 구현 형태)
- **§7-1 코드 예시** — `fetchCampaign(campId)` 직접 호출 대신 `db.from('campaigns').select(...).eq('id', campId).maybeSingle()` 인라인

#### 동일하게 구현된 것
- post_deadline 컬럼 DROP
- 토글 위치 (캠페인 등록·편집 폼 최상단)
- 기본값 ON
- OFF 시 status = expired, ON 시 자연 상태 재계산
- draft 상태 토글 비활성
- 자동 전이 제거 (autoExpireCampaigns 함수 제거)

### 구현 중 기술 결정 사항

#### DB
- **마이그레이션 129 — 단일 트랜잭션**: 함수 재정의(단계 1) + 컬럼 DROP(단계 2) BEGIN/COMMIT 묶음
- **097은 운영에 이미 적용된 상태** — 129 만 운영 DB 에 적용

#### 코드
- **클라이언트 코드 수정 먼저 → DB 적용 순서** — supabase-expert 가이드. payload 에 post_deadline 잔존 시 컬럼 DROP 후 캠페인 저장 PostgREST 오류 발생 위험 회피
- **토글 UI**: native `<button role="switch" aria-checked>` + CSS 알약 모양. 외부 라이브러리 의존 없음
- **목록 빠른 토글 위임**: tr 의 `data-camp-id` 를 `closest('tr')?.dataset.campId` 로 받음
- **refreshPane('campaigns')**: 토글 후 목록 자동 재렌더

### 잔존 작업 (다음 사이클)
- 사양서 §14 「일괄 OFF 도구」 — 본 사이클 제외
- 사양서 §13 「토글 변경 audit 이력」 — 본 사이클 제외
- 사양서 §13 「일정 시간 후 자동 OFF 예약」 — 본 사이클 제외

