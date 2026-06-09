# 캠페인 종료 시 심사중 신청 자동 낙첨 (무알림)
**작성일:** 2026-06-09

## 요약
캠페인 상태가 **종료(ended)** 또는 **노출마감(expired)** 으로 바뀌면, 그 캠페인의 **심사중(pending)** 신청을 자동으로 **낙첨(rejected)** 처리한다. 단 인플루언서에게 **알림이 가지 않게** 한다(앱 알림·메일 모두). 이번 누적분 일괄 정리(백필) + 향후 자동(데이터베이스 트리거).

- 관리자 화면: 이 건들은 "미승인"이 아니라 **"캠페인 종료"** 로 표시
- 인플루언서 화면: 「落選(낙첨)」 + 작은 「募集終了(모집종료)」 보조 라벨

## 현재 상태 (2026-06-09 기준)

### 관련 코드·DB·UI 진입점
- 캠페인 status 전환(클라): `dev/lib/storage.js` `autoEndCampaigns`(closed→ended), `toggleCampaignVisibility`(노출 OFF→expired). 둘 다 `campaigns.status` 를 DB UPDATE → AFTER UPDATE OF status 트리거로 후킹 가능.
- 신청 status 트리거 `trg_application_status_event`(마이그레이션 131·154): `NEW.status='approved'` 일 때만 notifications INSERT → **rejected 전이는 앱 알림 없음**. rejected 는 `application_events` 'reject' audit 만 남김.
- 인플 일일 다이제스트 메일(`notify-influencer-daily-digest`): `status IN ('approved','rejected') AND reviewed_at >= 어제KST AND < 오늘KST`. **reviewed_at = NULL 이면 메일 제외.**
- 인플 응모이력: `dev/js/mypage.js:269` → `getStatusBadge(a.status)` → `ui.js` rejected=「落選」.
- 관리자 상태 배지: `getStatusBadgeKo`(ui.js). 호출처 `admin-applications.js`(신청관리·신청자 2곳)·`admin-influencers.js`(인플 상세 응모이력)·`admin-dashboard.js`(최근 신청).
- applications 컬럼: status / reviewed_by(text) / reviewed_at(timestamptz NULL 가능) / reviewed_version(낙관적 락). reject_reason 없음.

### 이 제안과 충돌 가능성 있는 기존 동작
- 트리거 연쇄: 신규 트리거의 applications UPDATE 가 `trg_application_status_event` 를 발화 → application_events 'reject' audit(의도된 동작). 무한루프 없음(campaigns→applications 단방향).
- `reviewed_version` 낙관적 락: 트리거/백필이 미변경이라 충돌 없음.
- 마이그레이션 156 보호컬럼 락은 campaigns 만 대상, 신규 트리거는 applications 만 건드려 무관.

## 의심·경우의 수
1. **approved 보호(최중요)**: 트리거·백필 모두 `WHERE status='pending'` 만 → approved(당첨자) 절대 미변경.
2. **closed 제외**: ended/expired 만 대상. closed(모집마감, 결과물 진행 중)는 제외.
3. **운영자 노출 ON 복귀**: ended/expired→active 복귀 시 이미 낙첨된 건은 자동 복원 안 됨(DB 굳혀짐). 운영자가 신청관리에서 「되돌리기」로 수동 pending 복귀 가능(드문 케이스, 자동 복원은 과설계).
4. **되돌리기 후 잔존**: 「되돌리기」로 pending 복귀 시 `auto_reject_reason` 값이 남지만 pending 상태라 화면엔 "심사중" 정상 표시(무해). 재낙첨되면 트리거가 다시 덮어씀.
5. **메일 폭탄 방지**: 백필도 `reviewed_at=NULL` 이라 다음날 다이제스트 메일 제외.

## 설계

### DB (마이그레이션 2개)
- **176 `auto_reject_pending_on_campaign_end.sql`**
  - `applications.auto_reject_reason text` 컬럼 추가 (NULL=일반, 'campaign_ended'/'campaign_expired'=자동 낙첨 식별)
  - 함수 `reject_pending_on_campaign_end()` (SECURITY DEFINER, search_path=''): `NEW.status IN ('ended','expired') AND COALESCE(OLD.status,'') NOT IN ('ended','expired')` 일 때 그 캠페인 pending → rejected, auto_reject_reason 세팅, reviewed_by='시스템(캠페인 종료)', reviewed_at=NULL
  - 트리거 `trg_reject_pending_on_campaign_end` AFTER UPDATE OF status ON campaigns
- **177 `auto_reject_pending_backfill.sql`**: 기존 ended/expired 캠페인의 pending 일괄 정리(동일 규칙, reviewed_at=NULL). 사전 확인 SELECT 주석 포함. 멱등.

### 화면 (DB 변경 없이 식별 컬럼 기반 분기)
- `ui.js`:
  - `getStatusBadgeKo(s, autoReason)` — rejected+autoReason 이면 "캠페인 종료" 배지
  - `getStatusBadge(s, autoReason)` — rejected+autoReason 이면 「落選」 + 작은 「募集終了」 보조 배지
- 호출부에 `a.auto_reject_reason` 전달: `admin-applications.js`(2곳), `admin-influencers.js`, `admin-dashboard.js`, `mypage.js`
- i18n: `appHistory.recruitEnded` (ja '募集終了' / ko '모집종료')
- 관리자 처리 셀: 자동 낙첨 건은 status=rejected 라 기존 else 분기(reviewed_by 표시 + 되돌리기). reviewed_at=NULL 이라 날짜 미표시. reviewed_by='시스템(캠페인 종료)' 노출.

## 사이드바 배지
별도 작업 불필요 — 낙첨은 pending 이 아니므로 `fetchPendingApplicationCount`(status='pending' count)에서 자동 제외.

## PR/배포 순서
- DB(176·177) + 화면을 한 묶음으로 dev 배포 → 개발 DB 적용·스모크.
- 운영: 마이그레이션 운영 DB 적용(백필 전 대상 건수 SELECT 확인) 후 dev→main 머지. **운영 데이터 변경(백필) 포함이라 사용자 최종 확인 필수.**

## 구현 결과

**구현일:** 2026-06-09
**관련 커밋:** (dev 머지 후 기록)

### 초안 대비 변경 사항
- reviewed_at 회피값: 과거 고정값 대신 **NULL** 채택(화면에 이상한 날짜 미표시 + 메일 제외, 추적은 auto_reject_reason + reviewed_by 로 충분).
- 식별: `auto_reject_reason text` 단일 컬럼으로 boolean+사유 통합('campaign_ended'/'campaign_expired').
- 인플 화면: 「落選」 + 「募集終了」 보조 라벨(사용자 선택).

### 구현 중 기술 결정 사항
- 마이그레이션 번호 확정: 176(트리거+컬럼), 177(백필).
- 관리자 일관성을 위해 신청관리 2곳 외 대시보드·인플 상세 응모이력에도 동일 배지 분기 적용.
