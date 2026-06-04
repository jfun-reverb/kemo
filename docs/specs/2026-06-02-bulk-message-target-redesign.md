# 일괄발송 모달 — 대상선택 흐름 재설계

**작성일:** 2026-06-02

## 현재 상태 (재설계 전)
- 관리자 받은편지함 「일괄 발송」 모달(2스텝): 1스텝 캠페인 다중선택 + 응모상태·결과물상태·채널·팔로워 필터, 2스텝 본문(텍스트 전용)
- 대상 해결: `resolve_bulk_recipients`(마이그레이션 167, 5인자). 결과물 상태는 종류(receipt/post/review_image) 구분 없이 통합 필터
- 발송: `send_application_message_bulk`(167, 6인자). `application_message_broadcasts`에 제목 컬럼 없음
- 167은 개발서버만 적용·운영 보류(메시지 약관 30일 통지 게이트)

## 설계 (사용자 확정)
1. **단계 흐름**: 한 화면 누적 방식 — ① 캠페인 상태 칩(모집중/모집마감/종료) 먼저 → ② 해당 상태 캠페인 다중선택 → ③ 참여 조건 → ④ 인플루언서 상태. 2스텝(대상선택 / 제목+본문) 유지
2. **결과물 필터 2분할**: 영수증 상태(kind='receipt') / 결과물 상태(kind IN 'post','review_image'). 두 그룹 **AND**, 그룹 내 status OR. 영수증은 선택 캠페인에 리뷰어(monitor) 포함 시에만 노출
3. **인플루언서 상태 3토글**: 인증된 인플만(`is_verified`) / 위반 이력 제외(`influencer_flags.action='violation'` 1건이라도) / 블랙리스트 제외(`is_blacklisted`, 기본 켜짐)
4. **발송 제목**: `application_message_broadcasts.title`(NULL 허용, 선택). **관리자 전용** — `application_messages.body`에 미포함(인플 비노출). 발송 이력 목록·상세에 표시 + "관리자만 볼 수 있습니다" 안내

## DB 변경 (마이그레이션 168)
- `application_message_broadcasts ADD COLUMN title text NULL`
- `send_application_message_bulk` 6→7인자(`p_title`). 6·7인자 DROP 후 CREATE(오버로드 모호성 방지)
- `resolve_bulk_recipients` 5→9인자: `p_receipt_statuses`/`p_post_statuses`(결과물 2분할) + `p_require_verified`/`p_exclude_violation`/`p_exclude_blacklist`. 5·9인자 DROP 후 CREATE
- 운영 보류(167과 함께 약관 게이트 후 적용). 개발서버는 167 위에 168 적용

## 구현 결과

**구현일:** 2026-06-02
**관련 커밋:** feature/bulk-msg-target-redesign (dev PR 예정)

### 초안 대비 변경 사항
- 추가된 것: 발송 제목을 목록·상세 양쪽에 표시(상세는 `get_broadcast_detail` 미수정·목록 캐시 `_broadcastRows` 재사용으로 DB 추가 변경 없이 처리)
- 빠진 것: 없음
- 달라진 것: 없음 (설계 그대로)

### 구현 중 기술 결정 사항
- `send`/`resolve` 모두 인자 수 변경이라 `CREATE OR REPLACE` 불가 → 구·신 시그니처 양쪽 `DROP FUNCTION IF EXISTS` 후 `CREATE`로 멱등성·오버로드 모호성 동시 해결
- 영수증 필터는 클라이언트에서 `_bulkState.hasMonitor` 게이트 → monitor 없으면 `receiptStatuses=[]` → RPC에 NULL 전달(게시물형 캠페인 0명 사고 방지). RPC 내 recruit_type 분기 불필요
- 상태 칩 변경 시 캠페인 선택 리셋(`clearMultiFilter`) + 빈 상태 안내(`#bulkCampaignEmpty`)
- 약관 영향 없음: 인플 상태 필터는 관리자 내부 운영 선별 기준(새 개인정보 수집 아님, `influencer_flags`는 PRIVACY에 이미 반영)
