# 코드맵: 데이터 계층 (storage.js + 마이그레이션)

> ⚠️ **작업 시작점 지도** — 줄 번호·마이그레이션 번호는 자동 생성 초안이라 오차 가능. 실제 수정 전 함수명으로 grep, 마이그레이션은 `ls supabase/migrations/` 재확인.
> 생성: 2026-05-20 (병렬 Explore). 갱신 규칙: [README](./README.md)

## 개요
데이터 계층은 Supabase PostgREST API + 원격 호출 함수(RPC) 약 135개(`dev/lib/storage.js`, 2,084줄)와 PostgreSQL 함수(마이그레이션 137개 파일)로 구성. 캠페인·신청·결과물·인플루언서·광고주 신청·메시지 등 도메인별 16개 핵심 테이블 관리. 환경 분기(운영/개발) 자동 처리, 세션 만료 재시도 내장.

## storage.js 함수 인덱스 (기능 그룹별)

### 유틸·세션
- `retryWithRefresh(fn)` — 세션 만료 시 토큰 갱신 후 재시도 (8~18)
- `fetchAllPaged(buildQuery, pageSize)` — PostgREST 1000행 제한 우회 pagination (22~34)

### 캠페인
- `fetchCampaigns()` — 전체 조회 + 자동 상태 전이 (37~53)
- `autoOpenCampaigns(camps)` / `autoCloseCampaigns(camps)` — scheduled→active / active→closed 자동 (58~99)
- `toggleCampaignVisibility(campId, visible)` — 노출 토글(expired 수동 설정) (105~124)
- `computeCampaignStatus(camp)` — 날짜 기준 상태 계산 (127~140)
- `insertCampaign(camp)` / `updateCampaign(campId, updates)` / `incrementViewCount(campId)` (142~166)

### 인플루언서
- `fetchInfluencers()` (169~178)
- `computePrefectureStats(users, limit)` — 도도부현 배송지 분포 (185~205)
- `setInfluencerVerified(...)` / `setInfluencerBlacklist(...)` — 인증/블랙리스트 RPC (208~227)
- `fetchInfluencerFlags(...)` / `recordInfluencerViolation(...)` / `updateInfluencerViolation(...)` — 마킹 이력·위반 (229~281)
- `uploadFlagEvidence(...)` / `getFlagEvidenceSignedUrl(...)` / `deleteFlagEvidenceFiles(...)` — 증빙 파일 (289~320)
- `upsertInfluencer(...)` / `updateInfluencer(...)` — 프로필 (346~360)

### 신청
- `fetchApplications(filters)` (363~376)
- `countActiveApplications(campaignId)` — 활성 신청 수(슬롯 판정용) (378~388)
- `insertApplication(app)` / `updateApplication(...)` / `checkDuplicateApplication(...)` (390~417)

### 결과물
- `fetchPendingDeliverableCount()` — 검수 대기 배지 (443~452)
- `fetchDeliverables(filters)` — 관리자 목록 + 캠페인/인플 조인 (455~481)
- `fetchDeliverableById(id)` / `fetchDeliverablesByCampaign(...)` / `fetchDeliverablesForUser(...)` (483~632)
- `insertDraftDeliverable(...)` / `deleteDraftDeliverable(...)` / `submitDrafts(...)` / `insertPostDeliverable(...)` / `appendPostSubmission(...)` (636~784)
- `updateReceiptAdmin(...)` / `fetchReceiptEditHistory(...)` — 관리자 영수증 수정·이력 RPC (669~699)
- `fetchDeliverableEvents(...)` / `updateDeliverableStatus(...)` — 이벤트·상태 변경 RPC(낙관적 락) (800~827)
- `updateApplicationOrientedAt(...)` — OT 발송 토글 (498~511)

### 알림
- `fetchMyNotifications(opts)` / `markNotificationRead(...)` / `deleteNotification(...)` / `markAllNotificationsRead()` (515~571)
- `insertApplicationCancelledNotification(...)` — 취소 알림 자동 생성 (576~604)

### 기준 데이터 (lookup_values + 번들 3종)
- `invalidateLookupCache(kind)` / `fetchLookups(kind)` / `fetchLookupsAll(kind)` (912~939)
- `generateLookupCode(...)` / `insertLookup(...)` / `updateLookup(...)` / `deactivateLookup(...)` / `activateLookup(...)` / `isLookupInUse(...)` / `deleteLookup(...)` / `swapLookupOrder(...)` (942~1037)
- 참여방법 번들: `fetchParticipationSets*` / `insert/update/deactivate/activate/delete/swap` (1044~1118)
- 주의사항 번들: `fetchCautionSets*` / 동일 CRUD (1130~1207)
- NG 번들: `fetchNgSets*` / 동일 CRUD (1219~1318)
- `recordCautionHistory(...)` / `fetchCautionHistory(...)` — 변경 감사 RPC (1323~1371)

### 관리자 공지
- `fetchAdminNotices(...)` / `fetchUnreadAdminNotices()` / `insertAdminNotice(...)` / `updateAdminNotice(...)` / `publishAdminNotice(...)` / `unpublishAdminNotice(...)` / `deleteAdminNotice(...)` / `markAdminNoticeRead(...)` (1373~1481)

### 광고주 신청
- `fetchBrands(...)` / `fetchBrandById(...)` / `updateBrand(...)` / `insertBrand(...)` (1484~1530)
- `fetchBrandApplications(filters)` / `fetchBrandAppPendingCount()` / `fetchBrandApplicationById(...)` / `fetchBrandApplicationHistory(...)` (1654~1729)
- `adminCreateBrandApplication(...)` / `updateBrandApplication(..., expectedVersion)` — 생성·수정(낙관적 락) (1731~1805)
- 메모: `fetchBrandAppMemos(...)` / `insertBrandAppMemo(...)` / `updateBrandAppMemo(...)` / `deleteBrandAppMemo(...)` / `fetchBrandAppMemoSummaries()` / `markBrandAppMemosRead(...)` (1547~1639)
- `refreshBrandAppProductPaymentFlags(...)` — 입금 플래그 재계산 RPC (1807~1819)

### 이미지 업로드
- `uploadImage(...)` — campaign-images 버킷 (831~851)
- `uploadContentImage(file)` — 미니 에디터 이미지(5MB, jpeg/png/webp) (859~886)
- `uploadCampImages(imgList)` — 8슬롯 일괄 (889~903)

### 관리자 메일 구독
- `fetchAdminEmailSubscriptions(...)` / `fetchAdminEmailKinds()` / `saveAdminEmailSubscriptions(...)` (1828~1931)

### 신청 취소·마케팅 메일
- `fetchCancelReasons()` / `cancelApplication(applicationId, opts)` — 본인 취소 RPC (1863~1902)
- `unsubscribeByToken(token)` — 익명 1-click 수신거부 RPC (1939~1953)
- `resubscribeMarketing()` / `updateMarketingOptIn(value)` — 재구독·토글 (1959~1995)

### 응모건 메시지 (PR 1)
- `fetchApplicationMessages(applicationId)` — 역할별 마스킹 RPC (2006~2011)
- `sendApplicationMessage(applicationId, body, attachments)` — 발송 RPC (2015~2026)
- `markApplicationMessagesRead(applicationId)` (2029~2035)
- `withdrawOwnMessage(messageId, attachmentPaths)` — 회수 RPC + 첨부 삭제 (2039~2050)
- `uploadMessageAttachment(...)` / `getMessageAttachmentSignedUrl(...)` / `fetchInfluencerUnreadMessageThreads()` (2054~2083)

## 주요 테이블 (16개 핵심)
- **캠페인·신청·결과물**: campaigns, applications, deliverables, deliverable_events, application_events, receipt_edit_history, campaign_caution_history
- **광고주**: brand_applications, brand_application_memos, brand_application_memo_reads, brand_application_history, companies, brands
- **인플·관리자**: influencers, admins, admin_email_subscriptions, admin_notices, admin_notice_reads, influencer_flags
- **메시지**: application_messages, application_message_admin_reads, application_message_resolutions, application_message_broadcasts, application_message_hide_history
- **기준·알림·홍보**: lookup_values, participation_sets, caution_sets, ng_sets, notifications, campaign_promo_digest_runs, campaign_promo_digest_sent, campaign_promo_exposure, campaign_promo_email_clicks
> 컬럼 세부는 `CLAUDE.md` 의 「Database Schema」 섹션이 정본.

## 원격 호출 함수(RPC) 목록 (정의 마이그레이션 — 재확인 필요)
- 인플 관리: `set_influencer_verified` / `set_influencer_blacklist` / `record_influencer_violation` / `update_influencer_violation` (≈059~062)
- 결과물: `submit_deliverable`(≈073) / `update_deliverable_status`(≈082) + 트리거 `record_deliverable_status_event` / `notify_deliverable_status`
- 영수증: `update_receipt_admin`(≈128)
- 주의사항 감사: `record_caution_history`(≈109)
- 신청: `cancel_application`(≈104) + 트리거 `record_application_status_event`(≈131)
- 광고주: `submit_brand_application`(≈056) / `admin_create_brand_application`(≈091) / `refresh_brand_app_product_payment_flags`(≈117) / `link_campaign_to_application`·`unlink_campaign_from_application`(≈121)
- 메모: `get_brand_app_memo_summaries`(≈123) / `mark_brand_app_memos_read`(≈125)
- 메시지(PR 1): `get_application_messages` / `send_application_message` / `mark_application_messages_read` / `withdraw_own_message` / `application_message_admin_unread_counts` (모두 144)
- 공지: `upsert_admin_notice_read`(≈071)
- 마케팅 메일: `unsubscribe_by_token` / `resubscribe_marketing`(140)
- 운영 현황: `get_brand_ops_overview` / `get_brand_ops_detail`(≈120)
- 홍보 메일 헬퍼: `get_promo_digest_targets` / `mark_promo_digest_sent` / `track_promo_click`(141)

## 마이그레이션 최근 흐름 (125~144)
```
128 receipt_required_fields        영수증 필수 필드(order_number/purchase_date/purchase_amount)
129 remove_post_deadline           campaigns.post_deadline 제거(노출 토글로 교체)
130 application_email_pipeline      응모건 메일 파이프라인 인프라
131 application_events              신청 상태 변경 감사 테이블/트리거
132 admin_daily_digest_runs         관리자 다이제스트 발송 로그
137 rls_initplan_optimization       RLS 초기화 계획 최적화
138 fk_indexes                      외래키 컬럼 인덱스
139 campaign_promo_digest_tables    캠페인 홍보 메일 4종 테이블
140 influencer_unsubscribe_token    unsubscribe_token + 수신거부/재구독 RPC
141 promo_digest_helpers            홍보 메일 헬퍼 함수 3종
142 promo_digest_cron               캠페인 홍보 메일 cron 스케줄
143 promo_targets_total_counts      홍보 메일 대상 건수 집계
144 application_messages            응모건 메시지 PR 1 (테이블/뷰/RPC/트리거)
```
> 정확한 번호·파일명은 항상 `ls supabase/migrations/` 로 확인.

## 환경 분기 (supabase.js)
- `SUPABASE_ENVS` — production / staging 2개
  - production: `twofagomeizrtkwlhsuv.supabase.co` (globalreverb.com, www.globalreverb.com)
  - staging: `qysmxtipobomefudyixw.supabase.co` (dev.globalreverb.com, localhost, 그 외 전부)
- `resolveSupabaseEnv(hostname)` — 운영 도메인만 엄격 매칭, 나머지는 staging
- 전역 플래그: `IS_STAGING`, `window.__REVERB_ENV__`
