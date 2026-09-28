# 사양서 목록

**만든 날:** 2026-09-28 (기획 세션 — 사양서 정리)

> 이 목록은 **어떤 문서가 있고, 무슨 종류이며, 무엇과 짝인지**만 적는다.
> 🔴 **진행 상태(구현됐나·배포됐나)는 여기 적지 않는다** — 각 문서 맨 위 「상태」 줄과 「구현 결과」 절이 단일 소스다. 같은 사실을 두 곳에 적으면 한쪽이 반드시 낡는다(기획 규칙 C 「진행 기록은 한 자리에만」).
> 상태를 한눈에 보려면: `grep -m1 -H "^\*\*상태" docs/specs/*.md`

## 새 문서를 만들 때

1. 파일 이름은 `YYYY-MM-DD-기능이름.md`. 작업표는 `…-breakdown.md`, 인수인계는 `…-handoff.md` 를 뒤에 붙여 **짝 사양서와 앞부분을 같게** 한다(아래 표의 「짝」 칸이 그 규칙으로 자동으로 이어진다)
2. 맨 위에 `**상태:**` 줄을 둔다. 구현·배포되면 **그 줄을 고쳐 쓴다**(아래에 덧붙이지 않는다)
3. 다른 문서가 결론을 뒤집으면 **뒤집힌 쪽 맨 위에** 「이 결론은 ○○에서 뒤집혔다 — 최신은 [링크]」를 적는다(모범: `2026-07-23-settlement-reviewer-receipt-amount.md`)
4. 이 목록에 한 줄 추가한다

## 결론이 뒤집히거나 대체된 문서

| 옛 문서 | 무엇으로 | 비고 |
|---|---|---|
| [2026-07-23-settlement-reviewer-receipt-amount.md](2026-07-23-settlement-reviewer-receipt-amount.md) | [2026-08-05-settlement-receipt-amount-switch.md](2026-08-05-settlement-receipt-amount-switch.md) | 정산 금액 「상시가」 → 「영수증 실결제액(상시가 상한)」 |
| [2026-08-04-settlement-receipt-basis.md](2026-08-04-settlement-receipt-basis.md) | [2026-08-05-settlement-receipt-amount-switch.md](2026-08-05-settlement-receipt-amount-switch.md) | 결정 문서 → 구현 사양서로 이어짐 |
| [2026-05-19-supabase-tokyo-region-migration.md](2026-05-19-supabase-tokyo-region-migration.md) | [2026-05-25-supabase-tokyo-migration.md](2026-05-25-supabase-tokyo-migration.md) | 결정 초안 → 실행 계획 |
| [2026-06-18-brand-self-orient-sheet.md](2026-06-18-brand-self-orient-sheet.md) | [2026-09-08-orient-sheet-simplify-and-quote.md](2026-09-08-orient-sheet-simplify-and-quote.md) | 새로 발급하는 시트의 형식만 대체. 옛 시트는 앞 문서 규칙 그대로 |
| [2026-05-19-campaign-promo-email.md](2026-05-19-campaign-promo-email.md) §17-5 창 정의 | [2026-09-28-promo-mail-new-and-deadline-window.md](2026-09-28-promo-mail-new-and-deadline-window.md) | 홍보 메일 「신규」·「마감 임박」 범위 |
| [2026-06-15-admin-permission-matrix.md](2026-06-15-admin-permission-matrix.md) | [2026-06-15-admin-permission-management.md](2026-06-15-admin-permission-management.md) | 감사 결과가 구현 사양서의 「현재 상태」·기본값이 됨 |
| [2026-08-12-reward-promise-by-recruit-type.md](2026-08-12-reward-promise-by-recruit-type.md) | [2026-09-02-unpaid-campaign-reward-mail.md](2026-09-02-unpaid-campaign-reward-mail.md) | 검수 결과 메일의 「보수 지급」 문구 — 뒤 문서가 다시 설계해 구현 |
| 관리자 머티리얼 3 디자인 사양(파일 없음) | 흑백 재설계 + 보라 강조색 | 관리자 화면 기준이 바뀌었다 — 옛 문서를 기준으로 삼지 말 것(`planning.md`) |

## 종류 안내

| 종류 | 뜻 | 「구현 결과」가 필요한가 |
|---|---|---|
| 사양서 | 무엇을 만들지 정한 문서 | ✅ 필요 |
| 작업표 | 사양서를 작업 조각으로 나눈 것 | 조각별로 |
| 인수인계 | 다음 세션에 넘기는 메모 | ✗ |
| 조사·보고 / 착수 전 대조 | 현재 상태를 조사한 결과 | ✗ |
| 조치 계획 | 조사 결과를 무엇부터 고칠지 | 조각별로 |
| 점검표 / 문안 초안 / 검증 지시서 | 배포 점검표·공지 문안 등 일회성 | ✗ |
| 허브 | 여러 사양서를 묶어 방향을 잡는 문서 | ✗ |

## 전체 목록 (날짜순)

### 2026-05

| 날짜 | 문서 | 종류 | 짝 |
|---|---|---|---|
| 2026-05-11 | [관리자 메일 수신 설정 분리 (멀티 메일 종류)](2026-05-11-admin-email-subscriptions.md) | 사양서 |  |
| 2026-05-11 | [캠페인 신청 본인 취소 기능](2026-05-11-application-cancel.md) | 사양서 |  |
| 2026-05-12 | [HANDOFF — 응모 취소 + 관리자 메일 수신 분리](2026-05-12-HANDOFF-application-cancel-and-admin-email-subs.md) | 인수인계 |  |
| 2026-05-12 | [HANDOFF — 응모 취소 일일 요약 메일 운영 배포 절차](2026-05-12-HANDOFF-application-cancel-pr-d-cron-setup.md) | 인수인계 |  |
| 2026-05-12 | [운영 배포 체크리스트 — 응모 취소 + 관리자 메일 분리 + NG 사항 번들화 + 브랜드 서베이 묶음](2026-05-12-PROD-DEPLOY-checklist.md) | 점검표 |  |
| 2026-05-12 | [브랜드 서베이 「모집비」 행별 입력 추가](2026-05-12-brand-app-recruit-fee.md) | 사양서 |  |
| 2026-05-12 | [브랜드 서베이 신청 목록 상태별 탭 UI](2026-05-12-brand-app-status-tabs.md) | 사양서 |  |
| 2026-05-12 | [브랜드 서베이 — 예상 견적에 모집비 합산 추가](2026-05-12-brand-recruit-fee-in-quote.md) | 사양서 |  |
| 2026-05-12 | [NG 사항 번들화 (캠페인 NG 사항을 묶음 선택 방식으로 전환)](2026-05-12-ng-sets.md) | 사양서 |  |
| 2026-05-12 | [참여방법·주의사항·NG 미니 에디터 이미지 첨부 강화](2026-05-12-rich-editor-image-upload.md) | 사양서 |  |
| 2026-05-13 | [응모 취소 일일 요약 메일 버그 수정 + 시점별 그룹화 사양서](2026-05-13-application-cancel-daily-email-fix.md) | 사양서 |  |
| 2026-05-13 | [브랜드 서베이 — 가격체크 컬럼 추가 사양서](2026-05-13-brand-app-price-check.md) | 사양서 |  |
| 2026-05-13 | [브랜드 서베이 — 내부 메모 제품별 분리 사양서](2026-05-13-brand-app-product-admin-memo.md) | 사양서 |  |
| 2026-05-13 | [브랜드 서베이 입금여부 — 제품별 4플래그 재설계 사양서](2026-05-13-brand-app-product-payment-flags.md) | 사양서 |  |
| 2026-05-13 | [관리자 페이지 — 회사·브랜드·신청·캠페인 통합 관리(운영 현황) 재설계 사양서](2026-05-13-brand-ops-redesign.md) | 사양서 |  |
| 2026-05-13 | [캠페인 노출 토글 — 자동 마감일에서 수동 토글로 전환 사양서](2026-05-13-campaign-visibility-toggle.md) | 사양서 |  |
| 2026-05-14 | [영수증 제출 필수 입력 강화 + 관리자 검수 수정 + 변경 이력](2026-05-14-receipt-required-fields.md) | 사양서 |  |
| 2026-05-15 | [관리자 페이지 점진 성능 저하 — 엄밀 진단 사양서](2026-05-15-admin-perf-diagnosis.md) | 사양서 |  |
| 2026-05-15 | [인플루언서 ↔ 관리자 양방향 메시지 (응모건 단위)](2026-05-15-application-messaging.md) | 사양서 |  |
| 2026-05-18 | [HANDOFF — 응모 단계별 메일 파이프라인 (Edge Function 2개 + cron 2개) + cancel-daily 버그 수정 동반](2026-05-18-HANDOFF-application-email-pipeline.md) | 인수인계 |  |
| 2026-05-18 | [HANDOFF — 인플루언서 ↔ 관리자 양방향 메시지 (응모건 단위)](2026-05-18-HANDOFF-application-messaging.md) | 인수인계 |  |
| 2026-05-18 | [HANDOFF — 운영 현황 재설계 PR 2 (회사 관리 페인)](2026-05-18-HANDOFF-brand-ops-pr2-company-pane.md) | 인수인계 |  |
| 2026-05-18 | [HANDOFF — 메일 파이프라인 통합 (관리자 일일 다이제스트 4섹션화 + 양측 audit)](2026-05-18-HANDOFF-mail-pipeline-consolidation.md) | 인수인계 |  |
| 2026-05-18 | [응모 단계별 메일 파이프라인 사양서 (인플루언서 통합 다이제스트 + 관리자 다이제스트)](2026-05-18-application-email-pipeline.md) | 사양서 |  |
| 2026-05-18 | [메일 통합 사양서 — 인플루언서 + 관리자 다이제스트 확장](2026-05-18-mail-pipeline-consolidation.md) | 사양서 |  |
| 2026-05-19 | [신규 캠페인 홍보 메일 — 일일 다이제스트](2026-05-19-campaign-promo-email.md) | 사양서 |  |
| 2026-05-19 | [행 단위 보안 정책(RLS) InitPlan 최적화 + 외래 키 인덱스 추가](2026-05-19-rls-initplan-optimization.md) | 사양서 |  |
| 2026-05-19 | [Supabase 운영 프로젝트 도쿄 리전 이전 사양서](2026-05-19-supabase-tokyo-region-migration.md) | 사양서 |  |
| 2026-05-20 | [HANDOFF — 응모건 메시지 PR 2 (관리자 발신 + GNB + 알림)](2026-05-20-HANDOFF-messaging-pr2.md) | 인수인계 |  |
| 2026-05-20 | [방문자 통계 자체 집계 — 관리자 대시보드 직접 표시](2026-05-20-visitor-analytics.md) | 사양서 |  |
| 2026-05-21 | [인플루언서 피드백·소통 채널 역할 분담 사양](2026-05-21-feedback-channel-roles.md) | 사양서 |  |
| 2026-05-21 | [일반 문의 창구 (응모건 비종속 메시지) 사양](2026-05-21-general-inquiry-desk.md) | 사양서 |  |
| 2026-05-21 | [자동응답(FAQ) 시스템 — 개발 세션 인계서 (HANDOFF)](2026-05-21-message-faq-handoff.md) | 인수인계 | [2026-05-21-message-faq.md](2026-05-21-message-faq.md) |
| 2026-05-21 | [응모건 메시지 — 자동응답(FAQ 가이드형) 사양](2026-05-21-message-faq.md) | 사양서 | [2026-05-21-message-faq-handoff.md](2026-05-21-message-faq-handoff.md) |
| 2026-05-22 | [관리자 캠페인 관리 화면 속도 개선 (코드 최적화, 서버 이관 없이)](2026-05-22-admin-campaign-list-perf.md) | 사양서 |  |
| 2026-05-25 | [Supabase 운영 데이터베이스 호주(시드니) → 일본(도쿄) 이관 계획서](2026-05-25-supabase-tokyo-migration.md) | 사양서 |  |
| 2026-05-27 | [관리자 캠페인 홍보 메일 수신 + 관리자 메일 설정 목록 점검](2026-05-27-admin-promo-email-subscription.md) | 사양서 |  |
| 2026-05-27 | [연령 정책 (만 18세 이상 가입) + 성별 수집 — 전체 구현 사양서](2026-05-27-age-minor-policy.md) | 사양서 |  |
| 2026-05-27 | [캠페인 상태 라벨 명확화 (모집마감 / 종료 / 노출종료) — 사양서](2026-05-27-campaign-status-label.md) | 사양서 |  |
| 2026-05-27 | [관리자 일일 통합 다이제스트 — 모집 채널 기준 SNS + 팔로워 표시](2026-05-27-digest-recruit-sns.md) | 사양서 |  |
| 2026-05-27 | [자주 묻는 질문(FAQ) 정확성 검토 + 정정 — 사양서](2026-05-27-faq-accuracy-fix.md) | 사양서 |  |
| 2026-05-27 | [LIPS·@cosme 모집 채널 추가 — 전체 구현 사양서](2026-05-27-lips-cosme-channels.md) | 사양서 |  |
| 2026-05-27 | [Qoo10 랭킹 모니터링 — 전체 구현 사양서](2026-05-27-qoo10-ranking-monitoring.md) | 사양서 |  |
| 2026-05-27 | [Qoo10 랭킹 모니터링 — 기술 검증(PoC) 지시서](2026-05-27-qoo10-ranking-poc.md) | 검증 지시서 |  |
| 2026-05-27 | [약관·개인정보처리방침 문구 보강 (허위리뷰·정정요구권·부정수령 환수·위반기록 보관)](2026-05-27-terms-policy-reinforcement.md) | 사양서 |  |
| 2026-05-28 | [관리자 모달 드래그·리사이즈](2026-05-28-admin-modal-draggable.md) | 사양서 |  |
| 2026-05-28 | [관리자 결과물 대리 등록·자동 승인](2026-05-28-admin-proxy-deliverable.md) | 사양서 |  |
| 2026-05-28 | [감사용 인플 계정 메커니즘 (운영 모니터링용)](2026-05-28-audit-influencer-account.md) | 사양서 |  |
| 2026-05-28 | [리뷰어 캠페인 결과물 모델 확장 — 영수증 + 채널별 리뷰 이미지](2026-05-28-multichannel-deliverable-split.md) | 사양서 |  |
| 2026-05-28 | [약관·정책 버전 관리 + 변경 통지 시스템 + 운영 거버넌스 전환](2026-05-28-policy-versioning.md) | 사양서 |  |
| 2026-05-28 | [운영 일괄 배포 실행 체크리스트 (②경로 — 약관 통지 동시 출시)](2026-05-28-prod-batch-deploy-checklist.md) | 점검표 |  |
| 2026-05-29 | [관리자 페이지 모달 구조 통일](2026-05-29-admin-modal-structure-unify.md) | 사양서 |  |
| 2026-05-29 | [채널 미지정 리뷰 이미지 → 채널 지정 기능](2026-05-29-deliverable-channel-assign.md) | 사양서 |  |
| 2026-05-29 | [결과물 관리 — 상단 필터 재설계](2026-05-29-deliverables-filter-redesign.md) | 사양서 |  |
| 2026-05-29 | [응모건 메시지 실측 분석 → FAQ·정책 개선 입력 자료](2026-05-29-message-faq-improvement.md) | 조사·보고 |  |

### 2026-06

| 날짜 | 문서 | 종류 | 짝 |
|---|---|---|---|
| 2026-06-02 | [관리자 메일 수신 항목 통합 (application_cancel + application_received → daily_digest)](2026-06-02-admin-email-consolidation.md) | 사양서 |  |
| 2026-06-02 | [일괄발송 모달 — 대상선택 흐름 재설계](2026-06-02-bulk-message-target-redesign.md) | 사양서 |  |
| 2026-06-02 | [사용자(인플루언서) 앱 에러를 관리자가 볼 수 있게 하는 기능](2026-06-02-client-error-reporting.md) | 사양서 |  |
| 2026-06-02 | [[P0·최우선] 게시물 URL 재제출 시 유니크 제약 위반 버그 수정](2026-06-02-deliverable-post-url-duplicate-fix.md) | 사양서 |  |
| 2026-06-02 | [시행일 운영 규칙 — 배포 타이밍 거버넌스 (코드는 미리, 효력은 시행일)](2026-06-02-release-timing-governance.md) | 사양서 |  |
| 2026-06-02 | [서비스 전체 점검·유지보수 체계 (Service Health Audit)](2026-06-02-service-health-audit.md) | 사양서 |  |
| 2026-06-04 | [관리자 응모건 메시지 — 「내가 보낸 순」 정렬 + 달력 기간 필터](2026-06-04-admin-message-sent-filter.md) | 사양서 |  |
| 2026-06-04 | [인플루언서 응모이력 — 상태 필터 드롭다운화 + 「진행중」 기본 표시](2026-06-04-application-history-status-dropdown.md) | 사양서 |  |
| 2026-06-04 | [브랜드 관리 ↔ 회사 관리 연동 (회사 정보 일원화)](2026-06-04-brand-company-linking.md) | 사양서 |  |
| 2026-06-04 | [캠페인 상태 안내 개선 + 관리자 오류 메시지 한글화 (+ 종료 캠페인 편집 버그)](2026-06-04-campaign-status-help-and-error-ko.md) | 사양서 |  |
| 2026-06-04 | [인플루언서 관리 — 주소지 + 채널 + 팔로워 조합 필터](2026-06-04-influencer-combo-filter.md) | 사양서 |  |
| 2026-06-05 | [일괄발송 대상 조건 정교화](2026-06-05-bulk-message-filter-refinement.md) | 사양서 |  |
| 2026-06-08 | [브랜드명 다국어 표시 정합화](2026-06-08-brand-name-i18n.md) | 사양서 |  |
| 2026-06-09 | [관리자 결과물 대리 등록 — 이미 제출된 결과물 사전 안내](2026-06-09-admin-proxy-duplicate-guidance.md) | 사양서 |  |
| 2026-06-09 | [브랜드 삭제 + 병합 기능](2026-06-09-brand-delete-merge.md) | 사양서 |  |
| 2026-06-09 | [캠페인 종료 시 심사중 신청 자동 낙첨 (무알림)](2026-06-09-campaign-end-auto-reject.md) | 사양서 |  |
| 2026-06-09 | [QA 자동 테스트 — Playwright 연결을 「확장 방식」 → 「원격 디버깅(CDP)」 전환](2026-06-09-qa-cdp-remote-debugging.md) | 사양서 |  |
| 2026-06-10 | [영수증 이미지 글자인식(OCR) 자동입력](2026-06-10-receipt-ocr-autofill.md) | 사양서 |  |
| 2026-06-11 | [공통 거버넌스 글로벌 단일화 (작업방식·소통·문서관리)](2026-06-11-global-governance-extraction.md) | 사양서 |  |
| 2026-06-12 | [캠페인 운영 상세 — 진행현황 화면 확장 + 운영현황 연결](2026-06-12-campaign-ops-detail.md) | 사양서 |  |
| 2026-06-15 | [관리자 권한 설정 화면 (동적 역할 기반 권한 제어) — 기획 사양서](2026-06-15-admin-permission-management.md) | 사양서 |  |
| 2026-06-15 | [관리자 등급별 권한 매트릭스 + 화면↔서버 불일치 점검](2026-06-15-admin-permission-matrix.md) | 조사·보고 |  |
| 2026-06-15 | [관리자 「오픈 예정 기능」 보드 (D-day) — 기획 사양서](2026-06-15-admin-upcoming-features-board.md) | 사양서 |  |
| 2026-06-16 | [게시물(post) 채널 일치 검증 + 대리 등록 교체 (3건 묶음)](2026-06-16-post-channel-validation-and-proxy-replace.md) | 사양서 |  |
| 2026-06-17 | [관리자 목록 표 — 열 너비 드래그 조정 기능](2026-06-17-admin-column-resize.md) | 사양서 |  |
| 2026-06-17 | [연령 정책 PR5 — 약관 개정 문구 + 통지 문안 초안](2026-06-17-age-policy-pr5-draft.md) | 문안 초안 |  |
| 2026-06-17 | [베타 출시 로드맵 — 3단계 출시 계획 (추정)](2026-06-17-beta-rollout-roadmap.md) | 허브 |  |
| 2026-06-17 | [시드니 옛 운영 서버 폐기 전 — Storage 주소 이전 (이관 잔여 작업)](2026-06-17-sydney-storage-url-migration.md) | 사양서 |  |
| 2026-06-18 | [베타 오픈 계획 — 허브 (기능 로드맵·기획 방향)](2026-06-18-beta-launch-plan.md) | 허브 |  |
| 2026-06-18 | [브랜드 셀프 오리엔시트 작성·수집](2026-06-18-brand-self-orient-sheet.md) | 사양서 |  |
| 2026-06-18 | [노션 실무자 가이드 — 스크린샷 자동 캡처 파이프라인 (트랙 B 핸드오프)](2026-06-18-notion-guide-screenshot-pipeline.md) | 사양서 |  |
| 2026-06-22 | [관리자 인플루언서 연령·성별 분포 대시보드](2026-06-22-age-gender-dashboard.md) | 사양서 |  |
| 2026-06-22 | [인플루언서 정산 관리 (베타 1차)](2026-06-22-influencer-settlement.md) | 사양서 |  |
| 2026-06-23 | [관리자 광고주 여정 재설계 — 메뉴 개편 + 오리엔시트 발행·취합 워크플로](2026-06-23-admin-brand-journey-redesign.md) | 사양서 |  |
| 2026-06-30 | [브랜드 서베이 공개 제출 차단 (영업 2단계 토큰 잠금 — 1단계)](2026-06-30-brand-survey-submit-lock.md) | 사양서 |  |
| 2026-06-30 | [오리엔시트 자체 식별번호 (B0001-O001) — 신청 번호 의존 분리](2026-06-30-orient-self-numbering.md) | 사양서 |  |
| 2026-06-30 | [오리엔시트 제출 알림 — 개별 즉시 메일 + 브랜드 일일 보고](2026-06-30-orient-submit-notification.md) | 사양서 |  |

### 2026-07

| 날짜 | 문서 | 종류 | 짝 |
|---|---|---|---|
| 2026-07-08 | [아웃바운드 시딩·타이업 인플루언서 추천 도구](2026-07-08-influencer-recommendation.md) | 사양서 |  |
| 2026-07-08 | [포인트 리워드 제도 — 리워드 원장 밑그림](2026-07-08-point-reward-system.md) | 사양서 |  |
| 2026-07-08 | [정산(Settlement) 개선 로드맵](2026-07-08-settlement-improvements.md) | 사양서 |  |
| 2026-07-09 | [HANDOFF — 인플루언서 추천 도구 1단계 (데이터 이관 + 명단 관리)](2026-07-09-influencer-recommendation-stage1-handoff.md) | 인수인계 |  |
| 2026-07-09 | [정산 과거분 컷오프 + 관리자 수동 처리](2026-07-09-settlement-cutoff-past-handling.md) | 사양서 |  |
| 2026-07-13 | [응모건 메시지 자동 번역](2026-07-13-message-translation.md) | 사양서 |  |
| 2026-07-14 | [인플루언서 화면 → iOS 앱 전환 인수인계 (HANDOFF)](2026-07-14-influencer-app-transition-handoff.md) | 인수인계 |  |
| 2026-07-14 | [LINE 공식계정 메시지 플랫폼 통합 (아웃바운드 명단 영업 컨택)](2026-07-14-line-messaging-integration.md) | 사양서 |  |
| 2026-07-15 | [브랜드 페이지 포털 — 조기 기획 골격 (살아있는 문서)](2026-07-15-brand-portal.md) | 사양서 |  |
| 2026-07-15 | [캠페인 생성 폼 — 서베이 신청 연동 자리 정리 (안전 숨김)](2026-07-15-campaign-form-hide-survey-link.md) | 사양서 |  |
| 2026-07-15 | [오리엔시트 — 시딩 채널 개편 + 레버브 요구사항 필드 + 리뷰어 엣코스메 제거](2026-07-15-orient-seeding-channel-redesign.md) | 사양서 |  |
| 2026-07-20 | [관리자 전용 초대 메일 + 관리자 전용 비밀번호 설정 화면](2026-07-20-admin-invite-mail-and-setpw.md) | 사양서 |  |
| 2026-07-20 | [인플루언서 비밀번호 찾기 정상화](2026-07-20-influencer-password-reset-fix.md) | 사양서 |  |
| 2026-07-21 | [반려·취소된 신청의 결과물 검수 자동 제외 + 정산 자동 보류](2026-07-21-rejected-application-deliverable-and-settlement.md) | 사양서 |  |
| 2026-07-22 | [전체 일관성 감사 후속 — 정합성 수정 6종](2026-07-22-audit-followup-consistency-fixes.md) | 사양서 |  |
| 2026-07-22 | [캠페인 삭제 복구 (soft delete) — 30일 보관 후 자동 완전삭제](2026-07-22-campaign-soft-delete-restore.md) | 사양서 |  |
| 2026-07-23 | [인플루언서 정산 — 리뷰어형(monitor) 대응 설계](2026-07-23-settlement-reviewer-receipt-amount.md) | 사양서 |  |
| 2026-07-27 | [캠페인 전체 항목 변경 이력](2026-07-27-campaign-full-change-history.md) | 사양서 |  |
| 2026-07-29 | [모집 마감·결과물 제출 마감 서버(데이터베이스) 강제](2026-07-29-deadline-server-enforcement.md) | 사양서 |  |
| 2026-07-29 | [슈퍼관리자 권한 자기 제한](2026-07-29-super-admin-self-restriction.md) | 사양서 |  |
| 2026-07-30 | [인수인계 — @cosme 리뷰 인증샷 채널 코드 교정 (기획 → 개발)](2026-07-30-HANDOFF-review-image-channel-drift.md) | 인수인계 |  |
| 2026-07-30 | [@cosme 리뷰 인증샷 누락 — 영향 범위 정리 및 공지 초안](2026-07-30-cosme-channel-affected-report.md) | 조사·보고 |  |
| 2026-07-30 | [작업 분해표 — 오프라인 팝업 방문 예약(티켓팅) + 입장 QR 확인](2026-07-30-offline-popup-ticketing-breakdown.md) | 작업표 | [2026-07-30-offline-popup-ticketing.md](2026-07-30-offline-popup-ticketing.md) |
| 2026-07-30 | [오프라인 팝업 방문 예약(티켓팅) + 입장 QR 확인](2026-07-30-offline-popup-ticketing.md) | 사양서 | [2026-07-30-offline-popup-ticketing-breakdown.md](2026-07-30-offline-popup-ticketing-breakdown.md) |
| 2026-07-30 | [@cosme 리뷰 인증샷이 화면에서 사라진 문제 — 채널 코드 어긋남 복구](2026-07-30-review-image-channel-code-drift.md) | 사양서 |  |
| 2026-07-31 | [제출 연타 방지 + 오류 로그 잡음 정리](2026-07-31-duplicate-submit-guard-and-error-log-noise.md) | 사양서 |  |

### 2026-08

| 날짜 | 문서 | 종류 | 짝 |
|---|---|---|---|
| 2026-08-04 | [마감 안내 모집 형식 분기 수정 + 리뷰어형 인증샷 안내 신설](2026-08-04-deadline-reminder-recruit-type-fix.md) | 사양서 |  |
| 2026-08-04 | [정산 금액 기준 — 상시가 vs 영수증 실결제액 (논의 기록)](2026-08-04-settlement-receipt-basis.md) | 사양서 |  |
| 2026-08-05 | [인수인계 — 오리엔시트 내부 메모 (기획 → 개발)](2026-08-05-HANDOFF-orient-sheet-internal-memo.md) | 인수인계 |  |
| 2026-08-05 | [인수인계 — 정산 마이그레이션 번호가 바뀌었습니다 (오리엔 세션 → 정산 세션)](2026-08-05-HANDOFF-settlement-migration-renumber.md) | 인수인계 |  |
| 2026-08-05 | [캠페인 폼 — 저장 안 한 변경을 두고 나가려 할 때 묻기](2026-08-05-campaign-unsaved-changes-guard.md) | 사양서 |  |
| 2026-08-05 | [현장 확인 화면을 행사 단위로 + 「행사 묶음」 도입](2026-08-05-event-group-and-scoped-checkin.md) | 사양서 |  |
| 2026-08-05 | [📋 작업 분해표 — 오리엔시트 내부 메모](2026-08-05-orient-sheet-internal-memo-breakdown.md) | 작업표 | [2026-08-05-orient-sheet-internal-memo.md](2026-08-05-orient-sheet-internal-memo.md) |
| 2026-08-05 | [오리엔시트 내부 메모 (관리자 전용)](2026-08-05-orient-sheet-internal-memo.md) | 사양서 | [2026-08-05-orient-sheet-internal-memo-breakdown.md](2026-08-05-orient-sheet-internal-memo-breakdown.md) |
| 2026-08-05 | [리뷰어형 정산 금액을 영수증 실결제액으로 전환 + 화면 문구 정정](2026-08-05-settlement-receipt-amount-switch.md) | 사양서 |  |
| 2026-08-06 | [📋 작업 분해표 — 캠페인 기간 문구 정리 + 리뷰어형 페이백 안내 공지](2026-08-06-campaign-period-wording-and-payback-notice-breakdown.md) | 작업표 | [2026-08-06-campaign-period-wording-and-payback-notice.md](2026-08-06-campaign-period-wording-and-payback-notice.md) |
| 2026-08-06 | [캠페인 기간 문구 정리 + 리뷰어형 페이백 안내 공지](2026-08-06-campaign-period-wording-and-payback-notice.md) | 사양서 | [2026-08-06-campaign-period-wording-and-payback-notice-breakdown.md](2026-08-06-campaign-period-wording-and-payback-notice-breakdown.md) |
| 2026-08-07 | [인플루언서 앱 오류가 관리자 오류 로그에 남게 하기](2026-08-07-app-error-visibility.md) | 사양서 |  |
| 2026-08-07 | [전수조사 후속 조치 계획 — 94건을 개발서버에 하나씩 반영하기](2026-08-07-audit-remediation-plan.md) | 조치 계획 |  |
| 2026-08-11 | [인수인계 — 기간 문구 정리 (2026-08-11 세션)](2026-08-11-HANDOFF-period-wording.md) | 인수인계 |  |
| 2026-08-11 | [기간 문구·선정 기간 잔여분 인수인계](2026-08-11-period-wording-remaining-handoff.md) | 인수인계 |  |
| 2026-08-11 | [기간 문구·선정 기간이 나머지 화면에 안 퍼진 것 바로잡기](2026-08-11-period-wording-rollout-gaps.md) | 사양서 |  |
| 2026-08-11 | [메일·자동응답이 영수증 마감을 잘못된 날짜로 안내하는 것 바로잡기](2026-08-11-receipt-deadline-mail-fix.md) | 사양서 |  |
| 2026-08-11 | [선정 기간이 관리자 화면에 안 보이는 것 바로잡기](2026-08-11-selection-period-visibility.md) | 사양서 |  |
| 2026-08-12 | [📋 작업 분해표 — 캠페인 「중단」 상태](2026-08-12-campaign-suspend-breakdown.md) | 작업표 | [2026-08-12-campaign-suspend.md](2026-08-12-campaign-suspend.md) |
| 2026-08-12 | [캠페인 「중단」 — 데이터를 남긴 채 운영을 동결하는 상태](2026-08-12-campaign-suspend.md) | 사양서 | [2026-08-12-campaign-suspend-breakdown.md](2026-08-12-campaign-suspend-breakdown.md) |
| 2026-08-12 | [안내 문구 ↔ 실제 동작 전수 대조 (문구 감사)](2026-08-12-copy-vs-behavior-audit.md) | 조사·보고 |  |
| 2026-08-12 | [캠페인 리치 텍스트 세 칸에 이미지 넣기](2026-08-12-quill-image-upload.md) | 사양서 |  |
| 2026-08-12 | [검수 결과 메일이 약속하는 「보수 지급」을 모집 형식에 맞게 가르기](2026-08-12-reward-promise-by-recruit-type.md) | 사양서 |  |
| 2026-08-18 | [📋 작업 분해표 — 조용히 죽는 관리자 화면 감지 장치](2026-08-18-blocked-admin-screen-detection-breakdown.md) | 작업표 | [2026-08-18-blocked-admin-screen-detection.md](2026-08-18-blocked-admin-screen-detection.md) |
| 2026-08-18 | [조용히 죽는 관리자 화면 — 감지 장치](2026-08-18-blocked-admin-screen-detection.md) | 사양서 | [2026-08-18-blocked-admin-screen-detection-breakdown.md](2026-08-18-blocked-admin-screen-detection-breakdown.md) |
| 2026-08-18 | [일별 방문자수 집계](2026-08-18-daily-site-visits.md) | 사양서 |  |
| 2026-08-18 | [회원 탈퇴 — 기능·문구·약관 정합](2026-08-18-member-withdrawal.md) | 사양서 |  |
| 2026-08-18 | [정산 관리 — 목록 통합 · 지급 예정일 표시 · 실제 송금 기록](2026-08-18-settlement-list-unification-and-payout-schedule.md) | 사양서 |  |
| 2026-08-18 | [운영팀 안내 초안 — 정산 관리 화면이 바뀝니다](2026-08-18-settlement-ops-notice.md) | 문안 초안 |  |
| 2026-08-18 | [📋 작업 분해표 — 정산 관리 1단계 (지급 준비 화면)](2026-08-18-settlement-stage1-breakdown.md) | 작업표 |  |
| 2026-08-18 | [📋 작업 분해표 — 정산 관리 2단계 (목록 통합)](2026-08-18-settlement-stage2-breakdown.md) | 작업표 |  |
| 2026-08-18 | [📋 작업 분해표 — 정산 관리 3단계 (실제 송금 기록)](2026-08-18-settlement-stage3-breakdown.md) | 작업표 |  |
| 2026-08-18 | [인수인계 — 정산 3단계 (실제 송금 기록)](2026-08-18-settlement-stage3-handoff.md) | 인수인계 |  |
| 2026-08-19 | [응모 취소 기록을 공지사항에서 신청 관리로](2026-08-19-cancel-record-move-out-of-notices.md) | 사양서 |  |
| 2026-08-19 | [📋 작업 분해표 — 회원 탈퇴](2026-08-19-member-withdrawal-breakdown.md) | 작업표 |  |
| 2026-08-19 | [PayPal 비즈니스 계정 안내 — 자주 묻는 질문 추가 + 어긋난 문구 정리](2026-08-19-paypal-business-account-faq.md) | 사양서 |  |
| 2026-08-20 | [여러 세션의 진행 상황이 안 보이는 문제 — 기획 인수인계](2026-08-20-session-status-visibility-handoff.md) | 인수인계 | [2026-08-20-session-status-visibility.md](2026-08-20-session-status-visibility.md) |
| 2026-08-20 | [여러 세션의 진행 상황 보이게 하기](2026-08-20-session-status-visibility.md) | 사양서 | [2026-08-20-session-status-visibility-handoff.md](2026-08-20-session-status-visibility-handoff.md) |
| 2026-08-21 | [작업 분해표 — 작업 12-B · 파기 ㄴ-2 · 응모건 메시지 첨부](2026-08-21-message-attachment-purge-breakdown.md) | 작업표 |  |
| 2026-08-24 | [작업 분해표 — 비공개 행사, 선착순형과 선정형 중 고르기](2026-08-24-event-invite-only-selection-breakdown.md) | 작업표 | [2026-08-24-event-invite-only-selection.md](2026-08-24-event-invite-only-selection.md) |
| 2026-08-24 | [비공개 행사 — 선착순형과 선정형 중 고르기](2026-08-24-event-invite-only-selection.md) | 사양서 | [2026-08-24-event-invite-only-selection-breakdown.md](2026-08-24-event-invite-only-selection-breakdown.md) |
| 2026-08-24 | [방문형에도 선정 기간 · 신청자를 관리자가 고르는지 확인](2026-08-24-visit-selection-period.md) | 사양서 |  |
| 2026-08-25 | [📋 작업 분해표 — 결과물이 「임시저장」으로 멈춰 관리자에게 안 보이는 결함](2026-08-25-deliverable-draft-stall-breakdown.md) | 작업표 |  |
| 2026-08-25 | [고문과 기획이 동시에 뜰 때 기획은 어디서 커밋하나](2026-08-25-planner-commit-location.md) | 사양서 |  |
| 2026-08-25 | [가입 시 받은 동의·정보가 저장되지 않는다](2026-08-25-signup-consent-not-recorded.md) | 사양서 |  |
| 2026-08-26 | [iOS 브랜치의 웹 공용 수정 — 인수인계](2026-08-26-ios-shared-fixes-handoff.md) | 인수인계 |  |
| 2026-08-27 | [일괄 발송 — 「같은 조건으로, 아직 안 받은 사람에게만 추가 발송」](2026-08-27-bulk-message-followup-send.md) | 사양서 |  |
| 2026-08-27 | [인플루언서 캠페인 목록 — 정원이 찬 캠페인을 아래로 내린다](2026-08-27-campaign-list-full-slot-order.md) | 사양서 |  |
| 2026-08-27 | [최소 팔로워수 채널 묶음 판정 — 작업표 (1~3단계)](2026-08-27-min-followers-channel-match-breakdown.md) | 작업표 | [2026-08-27-min-followers-channel-match.md](2026-08-27-min-followers-channel-match.md) |
| 2026-08-27 | [최소 팔로워수 — 채널 묶음 방식(또는/그리고)에 맞춰 판정하기](2026-08-27-min-followers-channel-match.md) | 사양서 | [2026-08-27-min-followers-channel-match-breakdown.md](2026-08-27-min-followers-channel-match-breakdown.md) |
| 2026-08-27 | [운영사 변경 — 회원 통지와 회사 정보 교체](2026-08-27-operator-change-notice.md) | 사양서 |  |
| 2026-08-31 | [운영 오류 로그 18건 — 원인 조사와 처리 방침](2026-08-31-error-log-triage.md) | 사양서 |  |
| 2026-08-31 | [이미지 축소 — 유료 변환 기능 끊기](2026-08-31-image-thumbnail-two-copies.md) | 사양서 |  |

### 2026-09

| 날짜 | 문서 | 종류 | 짝 |
|---|---|---|---|
| 2026-09-01 | [착수 전 알아야 할 것 — 응모 취소의 공지사항 자동 등록 중단](2026-09-01-cancel-notice-stop-handoff.md) | 인수인계 |  |
| 2026-09-02 | [전수조사(2차) 조치 계획 — 무엇을 어떤 순서로 처리하나](2026-09-02-audit-remediation-plan.md) | 조치 계획 |  |
| 2026-09-02 | [회원 「안 읽은 메시지」 배지가 조용히 0으로 뜬다](2026-09-02-influencer-unread-badge-timeout.md) | 사양서 |  |
| 2026-09-02 | [소셜 로그인과 리워드 포인트 — 경쟁사 대응 설계](2026-09-02-social-login-and-reward-points.md) | 사양서 |  |
| 2026-09-02 | [착수 전에 볼 곳 — 소셜 로그인·리워드 포인트](2026-09-02-social-login-points-before-starting.md) | 착수 전 대조 |  |
| 2026-09-02 | [무보수 캠페인에 「보수를 지급하겠다」고 말하는 메일](2026-09-02-unpaid-campaign-reward-mail.md) | 사양서 |  |
| 2026-09-03 | [캠페인 목록에 「결과물 현황」 열 추가](2026-09-03-campaign-list-deliverable-column.md) | 사양서 |  |
| 2026-09-03 | [📋 작업 분해표 — 캠페인 리포트 만들기](2026-09-03-campaign-report-builder-breakdown.md) | 작업표 | [2026-09-03-campaign-report-builder.md](2026-09-03-campaign-report-builder.md) |
| 2026-09-03 | [캠페인 리포트 만들기 — 외부 서비스 결과물 취합 + 브랜드 공유 링크](2026-09-03-campaign-report-builder.md) | 사양서 | [2026-09-03-campaign-report-builder-breakdown.md](2026-09-03-campaign-report-builder-breakdown.md) |
| 2026-09-03 | [메타 픽셀 도입 — 전환 추적·깔때기 모니터링·관리 화면](2026-09-03-meta-pixel.md) | 사양서 |  |
| 2026-09-07 | [📋 작업 분해표 — 운영현황 「일정」 뷰 (캠페인 간트차트)](2026-09-07-brand-ops-schedule-gantt-view-breakdown.md) | 작업표 | [2026-09-07-brand-ops-schedule-gantt-view.md](2026-09-07-brand-ops-schedule-gantt-view.md) |
| 2026-09-07 | [운영현황 「일정」 뷰 — 캠페인 간트차트](2026-09-07-brand-ops-schedule-gantt-view.md) | 사양서 | [2026-09-07-brand-ops-schedule-gantt-view-breakdown.md](2026-09-07-brand-ops-schedule-gantt-view-breakdown.md) |
| 2026-09-07 | [다이제스트 3종 — 수신자 단위 발송 기록 (전수조사 D-8)](2026-09-07-digest-per-recipient-send-record.md) | 사양서 |  |
| 2026-09-08 | [📋 작업 분해표 — 오리엔시트 단순화(발급 단위 재설계 · 항목 정리 · 견적서 · 큐텐 자동 채움)](2026-09-08-orient-sheet-simplify-and-quote-breakdown.md) | 작업표 | [2026-09-08-orient-sheet-simplify-and-quote.md](2026-09-08-orient-sheet-simplify-and-quote.md) |
| 2026-09-08 | [오리엔시트 단순화 — 발급 단위 재설계 · 항목 정리 · 견적서 PDF · 큐텐 자동 채움](2026-09-08-orient-sheet-simplify-and-quote.md) | 사양서 | [2026-09-08-orient-sheet-simplify-and-quote-breakdown.md](2026-09-08-orient-sheet-simplify-and-quote-breakdown.md) |
| 2026-09-10 | [브랜드 상세 「신청 내역」 → 오리엔시트 기준으로 교체](2026-09-10-brand-detail-orient-sheets.md) | 사양서 |  |
| 2026-09-10 | [가입 확인 링크가 비밀번호 재설정 화면으로 빠지는 결함 — 착지 경로 정정](2026-09-10-signup-confirm-link-routing-fix.md) | 사양서 |  |
| 2026-09-11 | [📋 작업 분해표 — 관리자 일일 메일 「조치가 필요한 캠페인」 절](2026-09-11-admin-digest-deadline-section-breakdown.md) | 작업표 | [2026-09-11-admin-digest-deadline-section.md](2026-09-11-admin-digest-deadline-section.md) |
| 2026-09-11 | [착수 전 알아야 할 것 — 관리자 일일 메일 다섯째 절](2026-09-11-admin-digest-deadline-section-precheck.md) | 착수 전 대조 |  |
| 2026-09-11 | [관리자 일일 메일에 「조치가 필요한 캠페인」 안내 추가 — 사양서](2026-09-11-admin-digest-deadline-section.md) | 사양서 | [2026-09-11-admin-digest-deadline-section-breakdown.md](2026-09-11-admin-digest-deadline-section-breakdown.md) |
| 2026-09-11 | [iOS 앱 넓은 화면 배치 — 여백 없이 채우기 + iPad 2단·3단 — 사양서](2026-09-11-ios-app-wide-layout.md) | 사양서 |  |
| 2026-09-11 | [넓은 화면(아이폰 폴드·아이패드) 대응 — 현재 상태 조사](2026-09-11-wide-screen-current-state-survey.md) | 조사·보고 |  |
| 2026-09-11 | [📋 작업 분해표 — 넓은 화면(아이폰 폴드 「iPhone Duo」·아이패드) 대응](2026-09-11-wide-screen-layout-breakdown.md) | 작업표 | [2026-09-11-wide-screen-layout.md](2026-09-11-wide-screen-layout.md) |
| 2026-09-11 | [넓은 화면(아이폰 폴드 「iPhone Duo」·아이패드) 대응 — 사양서](2026-09-11-wide-screen-layout.md) | 사양서 | [2026-09-11-wide-screen-layout-breakdown.md](2026-09-11-wide-screen-layout-breakdown.md) |
| 2026-09-15 | [📋 작업 분해표 — 메타 픽셀 도입 + 관리자 「광고 추적」 화면](2026-09-15-meta-pixel-breakdown.md) | 작업표 |  |
| 2026-09-15 | [📋 작업 분해표 — 관리자 「취소 되돌리기」](2026-09-15-restore-cancelled-application-breakdown.md) | 작업표 | [2026-09-15-restore-cancelled-application.md](2026-09-15-restore-cancelled-application.md) |
| 2026-09-15 | [관리자 「취소 되돌리기」 — 회원이 본인 취소한 신청을 원래 상태로](2026-09-15-restore-cancelled-application.md) | 사양서 | [2026-09-15-restore-cancelled-application-breakdown.md](2026-09-15-restore-cancelled-application-breakdown.md) |
| 2026-09-16 | [오리엔시트 — 가이드·제품명을 한국어·일본어 두 칸으로 받기](2026-09-16-orient-sheet-bilingual-fields.md) | 사양서 |  |
| 2026-09-16 | [오리엔시트 — 모집 인원 구간 요금 · 구매 가이드 · 항목 정리 · 브랜드 고정 안내](2026-09-16-orient-sheet-tiered-pricing-and-fields.md) | 사양서 |  |
| 2026-09-16 | [📋 작업 분해표 — 오리엔시트 구간 요금 · 구매 가이드 · 항목 정리 · 브랜드 고정 안내](2026-09-16-orient-sheet-tiered-pricing-breakdown.md) | 작업표 |  |
| 2026-09-17 | [메타 픽셀 — 개인정보처리방침 개정 공고와 회원 통지(메일 · 앱 안 공지)](2026-09-17-meta-pixel-policy-notice.md) | 사양서 |  |
| 2026-09-17 | [📋 작업 분해표 — 리포트에 SNS 게시물 링크·계정 넣기 (기프팅·방문형, LIPS)](2026-09-17-report-sns-channel-columns-breakdown.md) | 작업표 | [2026-09-17-report-sns-channel-columns.md](2026-09-17-report-sns-channel-columns.md) |
| 2026-09-17 | [리포트에 SNS 게시물 링크·계정 넣기 — 기프팅·방문형, 그리고 LIPS](2026-09-17-report-sns-channel-columns.md) | 사양서 | [2026-09-17-report-sns-channel-columns-breakdown.md](2026-09-17-report-sns-channel-columns-breakdown.md) |
| 2026-09-18 | [오리엔시트 — 구간별 모집 인원(건수)을 기준 데이터에서 고칠 수 있게](2026-09-18-orient-tier-slots-as-settings.md) | 사양서 |  |
| 2026-09-18 | [📋 작업 분해표 — SNS 계정 주소 판정 한 벌로 합치기](2026-09-18-sns-account-url-unify-breakdown.md) | 작업표 | [2026-09-18-sns-account-url-unify.md](2026-09-18-sns-account-url-unify.md) |
| 2026-09-18 | [SNS 계정 주소 판정을 한 벌로 — 화면 네 자리가 리포트와 같은 함수를 쓴다](2026-09-18-sns-account-url-unify.md) | 사양서 | [2026-09-18-sns-account-url-unify-breakdown.md](2026-09-18-sns-account-url-unify-breakdown.md) |
| 2026-09-18 | [탈퇴 「예정일 안내 메일이 아직 안 나간 N건」 경고의 오탐 — 판정 기준 정정](2026-09-18-withdrawal-mail-alert-false-positive.md) | 사양서 |  |
| 2026-09-21 | [작업표 — 「또는」 캠페인 인증 성공 판정 (2단계)](2026-09-21-or-channel-deliverable-judgement-breakdown.md) | 작업표 | [2026-09-21-or-channel-deliverable-judgement.md](2026-09-21-or-channel-deliverable-judgement.md) |
| 2026-09-21 | [「또는」 캠페인인데 채널을 전부 요구하고 있다 — 마감 메일 오발송 · 인증 성공 차단](2026-09-21-or-channel-deliverable-judgement.md) | 사양서 | [2026-09-21-or-channel-deliverable-judgement-breakdown.md](2026-09-21-or-channel-deliverable-judgement-breakdown.md) |
| 2026-09-21 | [오리엔시트 — 모집 인원 직접입력 + 구간 다섯으로](2026-09-21-orient-tier-direct-input.md) | 사양서 |  |
| 2026-09-21 | [오리엔시트 견적 — 구간 이름·옵션 문구를 관리자가 고친다](2026-09-21-orient-tier-names-editable.md) | 사양서 |  |
| 2026-09-21 | [오리엔시트 견적 — 구간 인원을 리뷰어·시딩 따로](2026-09-21-orient-tier-slots-per-form.md) | 사양서 |  |
| 2026-09-22 | [운영현황 브랜드 뷰·캠페인 비용 카드를 오리엔시트 기준으로](2026-09-22-brand-ops-and-cost-card-orient.md) | 사양서 |  |
| 2026-09-22 | [캠페인 브랜드를 바꿀 때 확인 창](2026-09-22-campaign-brand-change-confirm.md) | 사양서 |  |
| 2026-09-22 | [오리엔시트 「기존 캠페인 연결」 — 모집 형식 일치 검사](2026-09-22-orient-link-existing-recruit-type-check.md) | 사양서 |  |
| 2026-09-23 | [브랜드 상세 — 모달에서 페이지로](2026-09-23-brand-detail-pane.md) | 사양서 |  |
| 2026-09-23 | [브랜드 영업 메모 — 오리엔시트 메모처럼 여러 건으로](2026-09-23-brand-memo-entries.md) | 사양서 |  |
| 2026-09-28 | [캠페인 홍보 메일 — 「신규」 절이 한 번도 안 나간 문제와 「마감 임박」 범위](2026-09-28-promo-mail-new-and-deadline-window.md) | 사양서 | |
| 2026-09-28 | [인수인계 — 사양서 「구현 결과」 채우기](2026-09-28-spec-results-handoff.md) | 인수인계 | |

그 밖: `2026-07-30-cosme-channel-notice.html` — @cosme 채널 코드 사고 공지문(HTML)
