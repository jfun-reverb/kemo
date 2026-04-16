# Deliverables E2E 테스트 시나리오

> **Target**: `reverb-qa-tester` 에이전트가 Playwright로 개발서버(`dev.globalreverb.com`)에서 실행
> **Date**: 2026-04-15 뼈대 작성
> **Precondition**: Stage 0~7 적용 + `test_campaigns_deliverables.sql` + `test_users_deliverables.sql` 실행 완료

---

## 0. 실행 준비

### 0-1. 환경
- URL: `https://dev.globalreverb.com`, `https://dev.globalreverb.com/admin/`
- 관리자: `admin@kemo.jp` / `admin1234`
- 테스트 유저: `deliv.*@reverb.jp` / `test1234` (6명)
- 테스트 캠페인: `[TEST]` prefix 3종 (monitor/gifting/visit)

### 0-2. 초기 상태 (seed 기준)
| 유저 | app_status | receipt | post |
|---|---|---|---|
| deliv.pending | pending | — | — |
| deliv.approved | approved | — | — |
| deliv.receipt | approved | pending | — |
| deliv.receipt-ok | approved | approved | — |
| deliv.post | approved | approved | pending |
| deliv.rejected | rejected | — | — |

### 0-3. 실행 방법
```
reverb-qa-tester 에이전트를 호출해서 docs/tests/deliverables_e2e.md 전체 시나리오 실행해줘
```
실패 시 스크린샷·콘솔 로그 포함 리포트.

---

## 1. 인플루언서 플로우

### 1-1. 응모이력 탭 필터 `[Stage 4]`
- [ ] `deliv.pending` 로그인 → 마이페이지 > 応募履歴 → "심사중" 탭에 1건 노출
- [ ] `deliv.approved` → "승인" 탭에 1건
- [ ] `deliv.rejected` → "비승인" 탭에 1건
- [ ] "전체" 탭에 모든 건수 노출

### 1-2. 승인 건 클릭 → 활동관리 진입 `[Stage 3]`
- [ ] `deliv.approved` 로그인 → 응모이력 > 승인 건 클릭 → 활동관리 화면 오픈
- [ ] 영수증 제출 폼 노출 (monitor 타입 기준)
- [ ] gifting 타입은 영수증 제출 폼 없음 (post URL 바로)
- [ ] visit 타입은 방문기간 표시 + 영수증 제출 폼 표시

### 1-3. 영수증 제출 `[Stage 3]`
- [ ] `deliv.approved` 로그인 → 영수증 이미지 + 구매일 + 금액 입력 → 제출
- [ ] 제출 후 "검수중" 상태 표시
- [ ] DB: `deliverables` 테이블에 kind='receipt', status='pending' 행 생성

### 1-4. post URL 제출 `[Stage 3]`
- [ ] `deliv.receipt-ok` 로그인 → 활동관리 → post URL 입력란 활성화
- [ ] Instagram URL 입력 → 제출 → "검수중" 상태
- [ ] 동일 URL 재제출 시 `post_submissions` 배열에 날짜만 추가, 별도 행 생성 안 됨
- [ ] 다른 URL 재제출 시 `post_url` 갱신 + 이력 누적

### 1-5. 반려 후 재제출 `[Stage 7 — SKIP, 후속 고도화]`
- [ ] ~~관리자로 `deliv.receipt` 영수증 반려 → 인플루언서 재로그인~~
- [ ] ~~활동관리에 반려 사유 노출~~
- [ ] ~~재제출 가능, 이전 이력 보존~~

---

## 2. 관리자 플로우

### 2-1. 신청관리 pending 기본필터 `[Stage 5]`
- [ ] 관리자 로그인 → 신청관리 진입 시 기본적으로 pending 필터 적용
- [ ] `deliv.pending` 건이 상단 노출

### 2-2. 결과물 관리 페인 `[Stage 2]`
- [ ] 사이드바에 "결과물 관리" 메뉴 노출
- [ ] receipt pending 리스트에 `deliv.receipt` 노출
- [ ] 행 클릭 → 상세 모달 오픈 (영수증 이미지 + 구매일/금액)
- [ ] 승인 버튼 → status='approved', reviewed_at 기록
- [ ] 반려 버튼 → 사유 입력 모달 → status='rejected' + reason 기록

### 2-3. 되돌리기 `[Stage 2]`
- [ ] approved 건 "되돌리기" → status='pending' 복귀
- [ ] `deliverable_events`에 action='revert' 이력 기록

### 2-4. post URL 검수 `[Stage 2]`
- [ ] `deliv.post` post URL pending 리스트 노출
- [ ] URL 클릭 → 새 창에서 실제 게시물 열림
- [ ] 승인/반려 플로우 동일

### 2-5. OT 체크박스 `[Stage 4]`
- [ ] gifting/visit 타입 신청에 OT 체크박스 노출
- [ ] 체크 시 `applications.oriented_at` 기록
- [ ] monitor 타입은 체크박스 없음

### 2-6. AND 완료 판정 `[Stage 5]`
- [ ] `deliv.post` receipt+post 모두 approved 시 신청 "완료" 상태 전환
- [ ] post만 approved, receipt 없는 gifting 캠페인은 post approved만으로 완료

---

## 3. 캠페인 기한 필드 `[Stage 1]`

### 3-1. 관리자 — 타입별 기한 입력
- [ ] monitor: purchase_start/end + submission_end 입력란 노출
- [ ] gifting: submission_end만
- [ ] visit: visit_start/end + submission_end
- [ ] 저장 후 재오픈 시 값 유지

### 3-2. 인플루언서 — 기한 표시
- [ ] monitor 상세: 구매기간 표시
- [ ] visit 상세: 방문기간 표시
- [ ] 활동관리: 제출마감까지 D-day 표시

---

## 4. 알림 `[Stage 6]`

### 4-1. 3중 알림 (배너 + 배지 + 알림섹션)
- [ ] 관리자 반려 직후 → 인플루언서 홈 배너 + 바텀탭 뱃지 + 알림섹션 3곳 모두 노출
- [ ] 알림 클릭 → 해당 화면으로 이동 + 자동 읽음 처리
- [ ] 읽음 처리 후 배지 사라짐

---

## 5. 회귀 (Regression)

### 5-1. receipts 테이블 dual-write `[Stage 0]`
- [ ] 인플루언서가 receipts INSERT → 트리거로 deliverables에도 자동 생성
- [ ] 양쪽 행의 application_id/user_id/campaign_id 일치

### 5-2. 기존 receipts 백필
- [ ] seed 실행 전부터 존재하던 receipts 전량이 deliverables에도 복사됨

### 5-3. 낙관적 락
- [ ] 두 관리자 탭에서 동시에 같은 deliverable 승인 시도 → 하나만 성공, 다른 하나는 버전 불일치 에러

---

## 6. 리포트 포맷

테스트 완료 후 다음 형식으로 제출:

```
## 실행 결과 (2026-MM-DD)
- 총 시나리오: NN
- 통과: NN
- 실패: NN (목록 + 스크린샷 경로)
- 차단 (선행 실패로 실행 불가): NN

## 실패 상세
### [항목 번호] 제목
- 기대: ...
- 실제: ...
- 콘솔 에러: ...
- 스크린샷: dev/test-artifacts/...
```

---

## 7. TODO (Stage 구현 진행에 따라 보강)

- [ ] Stage 2 완료 후: §2-2 ~ §2-4 세부 셀렉터/버튼명 확정
- [ ] Stage 3 완료 후: §1-3 ~ §1-4 제출 폼 필드명 확정
- [ ] Stage 6 완료 후: §4 알림 테이블 스키마 확정 시 DB 검증 항목 추가
- [ ] Stage 7 완료 후: §1-5 반려 템플릿 코드 리스트 확정
