# 인수인계 — 사양서 상태 점검 뒤 남은 일 (2026-10-02)

**작성일:** 2026-10-02 · **작성:** 기획 세션
**상태:** 📄 인수인계 — 아래 목록을 개발 세션·사용자가 처리

## 무엇을 했나

8월 이후 사양서 115개를 `origin/dev`·`origin/main` 의 코드·커밋·마이그레이션 파일과 대조했다. 결과는 각 문서 맨 위 **「상태:」 줄**에 적었다(98개 갱신, 「2026-10-02 상태 점검」 표시). 진행 상태는 그 줄과 「구현 결과」가 단일 소스이므로 **이 문서에는 다시 적지 않는다.**

- 대조 범위는 **저장소 기준**이다. 마이그레이션이 운영 데이터베이스에 실제로 적용됐는지는 사양서에 적용 기록이 있을 때만 확인된 것으로 봤다.
- 다른 브랜치가 지금 고치고 있는 세 문서는 충돌을 피하려고 손대지 않았다 — `2026-08-31-error-log-triage.md`(`feature/기획-오류로그-구현정정`) · `2026-10-01-signup-email-code-verification.md`(`feature/기획-찾기문구`) · `2026-09-11-ios-app-wide-layout.md`(`feature/ios-app`, 판정: 미착수)

## 1. 운영 확인 — 먼저 볼 것

| 순서 | 무엇 | 왜 | 누가 |
|---|---|---|---|
| 1 | 🔴 정산 화면의 「밀린 금액」 | 과거 미등록 495건 송금완료 등록(정산 목록 통합 4단계) 전에 한시 안내를 지웠다(`1b6ca42d`). 실무자가 실제 미지급으로 읽을 수 있다 | 사용자 결정 → 개발 |
| 2 | 캠페인 목록 탭 주소 — 완료 기준 8(메타 쪽 확인) | 「운영 배포 전 필수」였는데 확인 없이 운영(#1814)에 나갔다 | 사용자 |
| 3 | 마이그레이션 382·383(가입 동의 기록 설계 1) 운영 적용 여부 | 코드는 운영에 있는데 적용 기록이 없다. 빠졌으면 화면이 없는 함수를 부른다 | 개발(운영 조회) |
| 4 | 마이그레이션 388~391·393(일괄 메시지 추가 발송) 운영 적용 여부 | 위와 같다 | 개발(운영 조회) |
| 5 | 마이그레이션 470~474·493~499 가 `main` 에 없다 | 운영 데이터베이스엔 적용 기록이 있는데 운영 브랜치 저장소에 파일이 없다. 다음 운영 병합 때 함께 들어가는지 볼 것 | 개발 |

## 2. 「구현 결과」 본문의 낡은 서술 — 개발 세션 몫

상태 줄은 고쳤지만 **본문의 「운영 미적용」·「개발서버만」 같은 서술은 「구현 결과」라 개발 세션이 고친다**(규칙상 기획은 본문만). 앞의 서술을 고쳐 쓰고 아래에 덧붙이지 않는다.

| 문서 | 낡은 서술 |
|---|---|
| `2026-09-30-settlement-transfer-fee-record.md` | 「배포 상태: 개발서버만」 → 2026-10-01 운영 |
| `2026-09-29-common-password-warning.md` | 머리 줄 「단계 2 — 미착수」 |
| `2026-09-21-orient-tier-direct-input.md` | 7절 「운영 미반영」 · 빈 6절 |
| `2026-09-30-campaign-list-tab-url.md` · `2026-09-30-admin-entry-flash-handoff.md` | 운영 반영(#1814) 기록 없음 |
| `2026-09-22-campaign-brand-change-confirm.md` · `2026-09-22-brand-ops-and-cost-card-orient.md` | 운영 반영 일자 없음 |
| `2026-09-18-sns-account-url-unify.md` | 개발서버 검증까지만 — 운영 #1618 |
| `2026-09-18-orient-tier-slots-as-settings.md` · `2026-09-16-orient-sheet-tiered-pricing-and-fields.md` | 「운영 대기」 칸 |
| `2026-09-11-admin-digest-deadline-section.md` · `2026-09-07-digest-per-recipient-send-record.md` | 「운영 미적용」 |
| `2026-09-10-brand-detail-orient-sheets.md` · `2026-08-12-quill-image-upload.md` | 「운영 미배포」 |
| `2026-09-08-orient-sheet-simplify-and-quote.md` | 단계별 배포 표 「미적용」 |
| `2026-09-03-meta-pixel.md` | 「운영 픽셀은 아직 없다」 |
| `2026-09-03-campaign-report-builder.md` | 「구현 결과」 빈칸 — 작업표 링크로 채움 |
| `2026-09-02-influencer-unread-badge-timeout.md` | 조각 1 절 「운영 배포 대기」 |
| `2026-08-27-bulk-message-followup-send.md` · `2026-08-25-signup-consent-not-recorded.md` | 「운영 미적용」(위 1-3·1-4 확인 뒤) |
| `2026-08-11-selection-period-visibility.md` | 「개발서버 반영」 |
| `2026-08-04-settlement-receipt-basis.md` | 「미착수 — 결정 2건이 나면 채운다」 |
| `2026-08-05-event-group-and-scoped-checkin.md` | (정정됨 — 상태 줄의 낡은 경고만 이번에 지웠다) |
| 작업표의 빈 「개발 세션이 채울 것」 절 | `admin-digest-deadline-section-breakdown` · `orient-sheet-tiered-pricing-breakdown` · `payback-period-excel-breakdown` · `deliverable-draft-stall-breakdown` · `event-invite-only-selection-breakdown`·`campaign-list-full-slot-order`(빈 틀 중복) · `2026-09-02-audit-remediation-plan` · `period-wording-remaining-handoff` |

## 3. 사람이 직접 볼 것 (문서에 「미확인」으로 남은 검증)

- 캠페인 매니저 계정: 일정 뷰 시나리오 6 · 리포트 공유 거부 경로 · 광고 추적 화면이 비활성으로 보이는지
- 아이패드 사파리 실측(넓은 화면)
- 메타 픽셀 의무 6 — 두 픽셀이 같은 광고 계정인지
- 초대 링크 복귀 브라우저 실증 · 다이제스트 검증 3(Brevo 키 무효화 시험)
- 탈퇴 작업표 검증 2·4(다른 등급 로그인)

## 구현 결과

해당 없음 — 인수인계 문서
