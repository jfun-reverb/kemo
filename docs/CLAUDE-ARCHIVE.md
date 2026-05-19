# CLAUDE.md — 이력 아카이브

> 이 문서는 `CLAUDE.md` 가 비대해지는 것을 막기 위해 분리된 **이력·deprecated 메모** 보관소다.
> `CLAUDE.md` 본문은 "현재 가동 중인 동작" 위주로만 남기고, 마이그레이션 번호·PR 노트·과거 변경 이력은 이쪽에서 관리한다.
> 새 기능 추가 시 본문에는 동작 설명만 쓰고, 이력성 메타데이터(언제·어느 PR·어느 마이그레이션)는 이 파일에 누적.
>
> **최초 정리: 2026-05-19** (이전 CLAUDE.md 258줄·75KB → 슬림화 + 본 아카이브 분리)

---

## 1. 메일 파이프라인 이력

### 1-1. 광고주 신청 접수 알림 (notify-brand-application)
- Supabase Edge Function — `brand_applications` INSERT 직후 호출
- 수신자: `get_subscribed_admin_emails('brand_notify')` RPC(migration 103) ∪ env `NOTIFY_ADMIN_EMAILS` (중복 제거)
- DB 조회 실패 시 env 만 폴백
- 이전 `admins.receive_brand_notify` 단일 컬럼 방식은 2026-05-11 deprecated, `admin_email_subscriptions` 테이블로 분리

### 1-2. 응모 취소 일일 요약 메일 (notify-application-cancelled-daily) — **deprecated 2026-05-18**
- 2026-05-12 migration 113 도입 → 2026-05-18 PR 2 deprecated
- pg_cron 매일 UTC 00:00 (=KST 09:00), 전일 KST 0~24시 `cancel_phase != 'recruit'` 응모 취소 요약 1통
- 수신자: `get_subscribed_admin_emails('application_cancel')` ∪ env
- 0건이면 미발송 + `application_cancel_digest_runs.status='skipped_no_data'`
- 같은 날짜 중복 호출 UNIQUE 차단
- 2026-05-13 패치 (607f52b → 9ed247c): 주석 안 플레이스홀더 누출(버그 A) + 인플루언서 이메일 「-」 표시(버그 C) + 시점별 그룹화
- 2026-05-18: 「관리자 통합 다이제스트」 §2 응모 취소 섹션으로 흡수. cron 만 해제, Edge Function 코드는 롤백 대비 보존 — 운영 안정화 2주 후 별도 정리 PR 에서 삭제 예정

### 1-3. 인플루언서 일일 다이제스트 (notify-influencer-daily-digest)
- 2026-05-18 migration 130 도입, **운영 가동 중**
- pg_cron 매일 UTC 00:00, 인플루언서별 어제 신청·승인·반려 + 오늘 D-5/D-1 마감 4섹션 1통
- 4섹션 모두 0건이면 발송 스킵
- 발송 직후 `deadline_reminder_email_sent` 에 D-N 항목 벌크 INSERT (UNIQUE 4-tuple `influencer_id, campaign_id, kind, d_minus` 로 재발송 차단)
- 로그 `influencer_daily_digest_runs` (digest_date UNIQUE)
- `marketing_opt_in` 무시 (트랜잭션 성격), 일본어 본문
- 사양서 `docs/specs/2026-05-18-application-email-pipeline.md`

### 1-4. 캠페인 신청 접수 — 관리자 일일 요약 (notify-application-received-admin-daily) — **deprecated 2026-05-18**
- 2026-05-18 migration 130 도입 → 같은 날 PR 2 deprecated
- 전일 신청을 캠페인별 그룹화해 관리자에게 1통
- 0건 미발송. 수신자 `get_subscribed_admin_emails('application_received')` ∪ env
- 「관리자 통합 다이제스트」 §1 신청 접수 섹션으로 흡수. cron 만 해제, Edge Function 코드 보존

### 1-5. 관리자 일일 통합 다이제스트 (notify-admin-daily-digest)
- 2026-05-18 migration 132, PR 2, **운영 가동 중**
- 양 DB cron 등록 완료 2026-05-18 18시경, 첫 자동 발송 2026-05-19 09:00 KST
- 4섹션 1통:
  - ① 캠페인 신청 접수 (applications.created_at)
  - ② 응모 취소 (cancelled_at, cancel_phase != recruit)
  - ③ 결과물 제출 (`deliverable_events.action='submit'` — 재제출 자동 배제)
  - ④ 재처리 일감 (`deliverable_events` resubmit/revert + `application_events.action='revert_to_pending'`)
- 4섹션 모두 0건이면 미발송. 부분 0건은 발송 + 0건 섹션 본문 생략
- **동시성 패턴**: status='failed' 마커 INSERT 선행(digest_date UNIQUE = mutex) → 23505 발생 시 즉시 종료(메일 중복 차단) → 성공 시 데이터 조회·메일 발송 후 UPDATE 로 상태 갱신
- 수신자: `application_cancel` ∪ `application_received` ∪ env (Promise.all 개별 try-catch + env 폴백)
- 로그 `admin_daily_digest_runs`
- 메일 템플릿 6종 (`docs/email-templates/admin-daily-digest{.html,.section.html,.row-{received,cancelled,submitted,reprocessed}.html}`)
- 2026-05-18 사용자 인박스 8통 검수 통과 (관리자 + 인플 + 결과물 검수 6종)
- 사양서 `docs/specs/2026-05-18-mail-pipeline-consolidation.md` §12~§16 + HANDOFF 문서

### 1-6. 메일 템플릿 분리 (2026-04-27, PR #125)
- 광고주 메일 3종(`brand-admin-notify`, `brand-ack-reviewer`, `brand-ack-seeding`) HTML 이 Edge Function 인라인 문자열 → `docs/email-templates/`(source of truth) 로 분리
- Edge Function 은 `_templates/` 미러 디렉토리를 `Deno.readTextFile` + `render({{key}})` 헬퍼로 읽음
- 배포 전 항상 `scripts/sync-email-templates.sh` 실행 (`docs/` → `_templates/` 동기화, `cmp -s` diff 검증)
- 카탈로그 페이지: `docs/email-templates/index.html` (활성 5종 + 미구현 7종)
- 기존 `docs/email-preview.html` 은 카탈로그로 리다이렉트

---

## 2. 캠페인 관리 이력

### 2-1. 캠페인 카드 배지 레이아웃 (2026-04-21 재배치)
- 커밋 9364b07/82b377b/32bc19d
- 이미지 좌상단 `募集中` pill(active), 우상단 NEW(7일 이내), 제목 위 `締切間近`(deadline<5일 또는 잔여slots≤30%), 슬롯 카운트는 콘텐츠 종류 아래, 첫 채널+`+N` 좌하단

### 2-2. 캠페인 상태 5단계 진화
- migration 097 까지: draft → scheduled → active → closed → expired (자동 비노출)
- **migration 129 (2026-05-18)**: post_deadline 컬럼 폐기 + 자동 비노출 제거. expired 는 운영자 수동 토글 OFF 로만 진입. closed 는 운영자가 OFF 할 때까지 인플 화면에 노출(募集締切 오버레이)
- 운영 DB expired 35건은 그대로 보존 (자연 복귀 안 함)
- `storage.js`: `toggleCampaignVisibility(campId, visible)` + `computeCampaignStatus(camp)`

### 2-3. 캠페인 자동 시작 (2026-04-27 migration 072)
- scheduled 캠페인의 `recruit_start` 도래 시 active 자동 전환
- `fetchCampaigns` → `autoOpenCampaigns()` → `autoCloseCampaigns()` 순서
- `autoExpireCampaigns` 는 migration 129 에서 제거 (수동 토글로 대체)

### 2-4. 캠페인 등록·편집 폼 날짜 입력 개편 (2026-04-27 PR #129 + migration 129)
- 단일 `<input type="date">` → flatpickr range picker 2개 + single picker 1개
- 모집 기간(`recruit_start ~ deadline`) / 구매·방문 기간 range + 결과물 제출 마감일(`submission_end`) single
- 모집 종료일 선택 시 `submission_end` +14일 자동 제안
- 구매·방문 기간은 모집 시작 ~ 결과물 제출 마감 윈도우로 자동 clamp
- 게시 기간(post_deadline) picker 는 migration 129 에서 제거
- 모집 타입·인원·카테고리는 "모집 조건" → **"기본 정보"** 섹션 이동
- monitor 때 콘텐츠 종류 옵션이 영상/이미지 lookup 만으로 자동 필터링

### 2-5. 캠페인 번호 채번 진화
- v1: `CAMP-YYYY-NNNN` (JST 연도별 4자리, `campaigns_yearly_counter` 카운터)
- v2 광고주 신청: `JFUN-{Q|N}-YYYYMMDD-NNN` (reviewer=Q, seeding=N, 연도 4자리)
- v2 시도 (migration 078, 2026-05-04 deprecated): `JFUN-{R|S}-YYMMDD-NNN` 단축안 — 088~090 으로 흡수됨
- **현행 계층 채번 (migration 088~090, 2026-05-04, 운영 가동 중)**: `B{brand_seq}-A{app_seq}-C{camp_seq}` (외부 캠페인은 `B{brand_seq}-C{ext_seq}`)
- 자릿수: brand 4자리 / 신청 3자리 / 캠 3자리
- 기존 채번은 `legacy_no` 컬럼 보존, `numbering_legacy_map` 테이블에서 양방향 매핑
- 신규 카운터: `brand_seq_counter`(싱글톤), `brand_application_counter`, `application_campaign_counter`, `brand_external_campaign_counter` — 모두 SECURITY DEFINER 트리거 전용
- 트리거 `generate_brand_application_no`/`generate_campaign_no` advisory lock 으로 동시 INSERT 직렬화
- 2026-05-18 양 DB 적용 확인 — 개발 `B0017-C002` (외부) / 운영 `B0018-A002-C002` (신청 연결) 정상

### 2-6. 캠페인·신청·결과물 표 brand_ko/product_ko 컬럼 분리 (2026-04-30)
- 커밋 02c432f / 56dcfd4 / 231a638
- 단일 "브랜드/상품" → `brand_ko`·`product_ko` 분리 (migration 074)
- 캠페인 관리·신청 관리·캠페인별 신청자 페인 3개 적용
- 검색창은 두 컬럼 모두 매칭

### 2-7. 캠페인 상태 도움말 모달 (2026-04-30, cdaa146 + migration 129)
- 「상태」 헤더 옆 `info` 아이콘 → 5단계 의미 + 자동 전이 규칙 모달

### 2-8. 민감 항목 변경 경고 모달 (d79ad39) + migration 075 잠금
- 캠페인 편집에서 `caution_items`/`participation_steps` 변경 시 `#sensitiveChangeModal` 경고
- migration 075: closed 캠페인의 caution/participation 변경 차단 트리거
- migration 108: ng_items 까지 확장 (caution/participation/ng 모두 차단)

### 2-9. 캠페인 변경 이력 audit (migration 077, 2026-04-30, 운영 가동 중)
- `campaign_caution_history` 테이블 — 누가/언제/어느 필드/이전·이후 값
- SELECT super_admin RLS, INSERT 는 `record_caution_history()` RPC 경유
- 캠페인 더보기 메뉴 「변경 이력」 + 인플루언서 응모이력 「現在の文言と比較」
- migration 109 (2026-05-12): NG 컬럼 4종 추가 (`ng_set_id_prev/next`, `ng_items_prev/next`). RPC 시그니처 11→15 파라미터

### 2-10. 캠페인 다중 선택 + 통합 엑셀 (2026-05-15, PR #206/#207)
- 캠페인 관리 목록에 체크박스 컬럼 + 카드 헤더에 「선택 N개 신청자/결과물 엑셀」 버튼 2종
- `_selectedCampIds = new Set()` 전역 + 필터/정렬/lazy-load remount 무관 절대 선택
- 다운로드 가드: 5초 쿨다운 + 동시 진행 lock (4종 export 함수 모두)
- 50개+ 선택 시 confirm() 다이얼로그
- 엑셀: 시트1 캠페인 정보(12컬럼) + 시트2 결과물/신청자 (단일 함수와 동일 형식)
- 단일 캠페인 export A:S 19→A:V 22컬럼, 다중 캠페인 A:U 21→A:X 24컬럼 (영수증 그룹 확장 동반)
- 엑셀 형식 통일 (2026-05-15): 이름 「한자」+「가나」 분리, SNS 핸들 → 공식 전체 URL, 우편번호 별도 컬럼
- 공용 헬퍼: `_excelInfluencerNameParts(u)` / `_excelSnsUrl(channel, raw)` / `_excelZip(u)` / `_excelAddressOnly(u, fallback)`

### 2-11. multi-filter 드롭다운 초기 비체크 (2026-05-15, PR #206)
- 캠페인/신청/결과물/광고주 신청 페인 모든 「전체 X」 드롭다운이 처음 열렸을 때 비체크 상태
- 데이터 모델은 동일 (비체크 = 모두 체크 = 필터 없음 → 빈 배열)

### 2-12. admin list 정렬 인덱스 5종 (2026-05-15, migration 127, PR #208)
- `applications.created_at DESC` / `influencers.created_at ASC` / `deliverables.updated_at DESC` / `brand_applications.created_at DESC` / `campaigns.order_index NULLS LAST`
- applications EXPLAIN ANALYZE Seq Scan 19.3ms → Index Scan 1.9ms (~10배 ↑)
- 진단 사양서 `docs/specs/2026-05-15-admin-perf-diagnosis.md` §6-3

### 2-13. 콘텐츠 가이드 Quill 리치 텍스트 (2026-05-12 NG-PR-B 직전까지)
- 콘텐츠 가이드 3개 필드(설명/어필 포인트/촬영 가이드) Quill v2 에디터
- DOMPurify 저장+렌더 이중 sanitize, 헬퍼 `sanitizeRich/richHtml/renderRich` (`dev/lib/shared.js`)
- 기존 4번째 「NG사항」 Quill 에디터는 제거되고 별도 NG 번들 카드(`ng_sets`/`ng_items`)로 분리됨

### 2-14. 참여방법·주의사항·NG 미니 에디터 이미지 첨부 (2026-05-12)
- `miniEditorHtml` 툴바에 「이미지」 버튼 추가
- `uploadContentImage(file)` (5MB / jpg·png·webp) → `campaign-images/content/` → `<img class="rich-img">` 삽입
- 참여방법 desc 입력이 textarea → 미니 에디터로 전환
- XSS 방어: `sanitizeCautionHtml` 의 src 화이트리스트 `_isAllowedContentImageSrc` (https + `*.supabase.co` 만)
- 이미지 크기 사전설정 (ee2a500): Small(25%)/Medium(50%)/Large(75%)/Original — `style="width:X%"` 인라인 스타일

### 2-15. 참여방법/주의사항 편집 모달 분리 (2026-04-26, eb78c98 / c5e2cef / 6be9c19)
- 캠페인 폼 inline 편집 → 별도 편집 모달
- 카드 헤더 「편집」 버튼 1개로 정리, bundle summary 한·일 양언어 풀 노출

---

## 3. 광고주 신청 / 브랜드 서베이 이력

### 3-1. 상태 파이프라인 진화
- migration 064: 8단계 (schedule_sent, campaign_registered 추가)
- migration 065: 9단계 (orient_sheet_sent 추가)
- 2026-04-30 migration 076 (d860685): 10단계 — `kakao_room_created` 추가
- **현행**: `new → reviewing → quoted → paid → kakao_room_created → orient_sheet_sent → schedule_sent → campaign_registered → done` / `rejected`
- 2026-04-27 표시 순서 재정렬: 깔때기·드롭다운·통계 표시 순서가 실제 영업 워크플로에 맞게 변경 (이전: reviewing → schedule_sent → quoted → orient → register → paid → done — 입금이 거의 마지막에 위치). DB 데이터·status 값 자체는 그대로, 표시 순서만 변경

### 3-2. brand_applications 컬럼 진화
- migration 056: `submit_brand_application` RPC 도입 (anon INSERT 42501 회피)
- migration 057: 사업자등록증 수집 제거 (`brand-docs` 버킷 + `business_license_path` 컬럼 삭제)
- migration 068: `request_note text NULL` 추가 (신청자 자유 입력 기타/요청사항). RPC 에 `p_request_note` 파라미터 추가
- migration 078 (2026-05-04, **deprecated 088~090 으로 흡수**): 원안은 채번을 v2 `JFUN-{R|S}-YYMMDD-NNN` (연도 2자리 숫자) 으로 단축할 계획이었으나 계층 채번 (`B{brand_seq}-A{app_seq}` 형식) 도입으로 흡수
- 2026-05-18 점검 결과 양 DB 모두 v1·v2 JFUN 채번 0건, 모두 계층 채번 (B-A) 패턴

### 3-3. 견적·입금·오리엔시트 컬럼 (migration 111~116, 126)
- **migration 111 (2026-05-12)**: `recalc_brand_application_totals()` 재정의 — reviewer 공식에 `products[i].recruit_fee_krw`(모집비) + `transfer_fee_krw`(이체수수료) 합산 추가, 이전 고정값 1인당 2500원 공식 교체. 트리거 BEFORE INSERT → `BEFORE INSERT OR UPDATE OF products, form_type` 확장 (UPDATE 시 estimated_krw 미갱신 버그 수정)
- **migration 112 (2026-05-12)**: `quote_sent_url text NULL`(견적서 URL) · `orient_sheet_sent_at timestamptz NULL` · `orient_sheet_sent_url text NULL` 3개 컬럼 추가. http/https 스킴만 허용 (CHECK)
- **migration 114 (2026-05-12)**: `payment_flags jsonb NOT NULL DEFAULT '{}'` — 입금여부 4종 체크 ({recruit, product, transfer, free} boolean). 헬퍼 `calc_brand_app_payment_flags(products)` + RPC `recalc_brand_app_payment_flags(application_id)`
- **migration 115 (2026-05-12)**: 새로고침 RPC 동작 변경 — free 보존 → false 리셋 (4종 모두 products 합계로 완전 초기화)
- **migration 116 (2026-05-12)**: `trg_brand_app_auto_recalc_payment_flags BEFORE INSERT OR UPDATE OF products` 트리거 — products 변경 시 recruit/product/transfer 자동 재계산, free 키는 OLD 값 보존(관리자 명시 토글 보호). 입금여부 칩 토글 UI. 무료모집 칩만 초록 톤(#E8F5E9/#16A34A)
- **migration 126 (2026-05-15)**: 「오리엔시트 전달」 컬럼이 실제로는 입금일 의미로 쓰이고 있어 분리 — `paid_at timestamptz NULL` 신규 + `orient_sheet_sent_at` 데이터 백필 후 DROP. `orient_sheet_sent_url` 보존. 신청 목록 표 「입금 정보」 뒤로 「입금 날짜」 컬럼 추가 + 인라인 편집 (체크박스 + date picker)
- **URL 입력 자동 prefix (2026-05-15)**: `safeBrandUrl` 옆 `normalizeBrandUrlInput(raw)` — 스킴 없는 입력(`example.com`) 에 `https://` 자동 prefix, 위험 스킴(javascript:, data:) 차단 유지
- 컬럼 헤더 라벨 「입금여부」 → 「입금 정보」 (2026-05-15)
- legacy 작성자 표기 「(legacy)」 → 「(자동 이전)」 (2026-05-15)

### 3-4. 제품별 메모 진화 (migration 122~125)
- **migration 122 (2026-05-14)**: 신청 단위 `admin_memo text` 컬럼 DROP — `products[i].admin_memo` (jsonb 내부) 로 1차 이전. `record_brand_application_history` 트리거에서 admin_memo 추적 블록 제거 (products 추적으로 자동 포함). `admin_create_brand_application` RPC 14파라미터로 재정의 (p_admin_memo 제거). 기존 `brand_application_history.field_name='admin_memo'` 이력 행은 감사 목적 보존
- **migration 123 (2026-05-14)**: 운영서버 multi-entry 패턴 제품별 확장 — `brand_application_memos.product_idx integer NOT NULL DEFAULT 0` 컬럼 + 인덱스. `record_brand_application_memo_history` 트리거 history 페이로드에 product_idx 포함. 122 의 `products[i].admin_memo` → `brand_application_memos` (product_idx 포함) 백필 후 products 배열에서 admin_memo 키 제거. 셀 인라인 편집 제거 → 모달 통일 (운영서버 패턴 + 제품 표시 헤더)
- **migration 124 (2026-05-14)**: 080 백필분과 123 백필분의 중복 legacy 메모 정리 — 081 트리거 임시 비활성화 후 history 미기록(080 백필) 행만 정확히 식별해 삭제
- **migration 125 (2026-05-14)**: `brand_application_memo_reads` 테이블 신규 (memo_id FK CASCADE, auth_id, read_at, PRIMARY KEY) — 메모 셀 분홍 카운트 배지를 "총 메모 개수" → "본인이 안 읽은 메모 수" 로 전환. `admin_notice_reads(063)` 패턴 미러. RPC `mark_brand_app_memos_read(application_id, product_idx)` 일괄 읽음 + `get_brand_app_memo_summaries()` 페어 단위 total/unread/latest 집계. 모달 진입 시 자동 read 처리

### 3-5. 가격체크 키 (2026-05-13, DB 마이그레이션 없음)
- `products[i].price_check` (optional, `'higher'|'lower'|'equal'`) — 마켓 등록 가격 vs 신청 금액 비교
- 신청 목록 표 「가격체크」 드롭다운 컬럼 토글, 엑셀 내보내기 포함
- 미선택이면 키 자체 없음

### 3-6. companies 마스터 + 운영 현황 페인 (migration 118~121, 2026-05-13)
- **migration 118**: `companies` 테이블 — 1개 회사 = N개 brands (4단 계층: 회사 > 브랜드 > 신청 > 캠페인). name_ko(NOT NULL)·name_ja·name_en + `name_normalized text UNIQUE NOT NULL` (자동 정규화 트리거) + business_no·address·homepage_url·contact_* 3종·billing_email·billing_address·memo + `status text NOT NULL DEFAULT 'active' CHECK(active|archived)` + `total_brands integer NOT NULL DEFAULT 0` (`trg_brands_company_total_brands` 트리거 자동 재계산). RLS SELECT `is_admin()`, CUD `is_campaign_admin()` 이상. 트리거 함수 3종 모두 `SECURITY DEFINER + SET search_path=''`. `brands.company_id uuid FK ON DELETE SET NULL` 외래 키 추가
- **migration 119**: brands.name_normalized 동일 그룹(2개 이상)만 자동 회사 생성, 단일 brand 는 NULL 유지 (운영자 수동 정리). 개발 DB 결과 회사 0건 자동 생성 (brand 25건 모두 unique)
- **migration 120**:
  - `get_brand_ops_overview(p_company_id uuid DEFAULT NULL)` RETURNS TABLE 19컬럼 — brand 7종 + open_applications + active_campaigns + slots_total/approved_total/recruit_rate + deliverable 3종 + d3_count + cancel_7d + last_activity_at + alert_level. alert_level 4단계: `danger`(D-1 임박 / 7일 취소 ≥5 / 모집률 <30% AND deadline 7일내) > `warning`(D-3 임박 1개+) > `caution`(모집률 <50% AND deadline ≥7일) > `normal`
  - `get_brand_ops_detail(p_brand_id uuid)` jsonb 통합 반환 — `{brand, company, applications:[{...,campaigns:[...]}], external_campaigns:[]}`. 외부 캠페인(`source_application_id IS NULL`) 별도 섹션
  - 양쪽 모두 `SECURITY DEFINER + SET search_path='' + is_admin()` 가드. authenticated 에만 GRANT EXECUTE
- **migration 121 (2026-05-14)**: 캠페인 ↔ 신청 연결/해제 RPC
  - `link_campaign_to_application(p_campaign_id, p_application_id)`: 같은 brand_id 검증 후 `source_application_id` 채우고 새 채번 `B{brand_seq}-A{app_seq}-C{new_camp_seq}` 발급 (`application_campaign_counter` UPSERT)
  - `unlink_campaign_from_application(p_campaign_id)`: `source_application_id`=NULL + 외부 캠페인 채번 `B{brand_seq}-C{new_ext_seq}` 발급 (`brand_external_campaign_counter` UPSERT)
  - 양쪽 모두 이전 `campaign_no` 를 `campaigns.legacy_no` 에 콤마 누적 (`_accumulate_legacy_no` 헬퍼) + `numbering_legacy_map` UPSERT (new_no 만 최신 덮어쓰기, legacy_no 최초 이주값 고정)
  - 동시성: `pg_advisory_xact_lock(campaign_id) → pg_advisory_xact_lock(application_id 또는 brand_id)` 2단 잠금
  - 멱등성: 동일 application 으로 link 재호출 또는 이미 NULL 상태 unlink 시 `unchanged:true` 반환
  - 가드: `is_campaign_admin()` 이상. `GRANT EXECUTE TO authenticated`
  - 사양 `docs/specs/2026-05-13-brand-ops-redesign.md` §4-5 / §15

---

## 4. 결과물 / 영수증 이력

### 4-1. 결과물 통합 테이블 (deliverables)
- migration 035: dual-write 트리거 (receipts → deliverables) — 현재 dead code 상태 보존 (활동관리는 deliverables 직접 INSERT)
- receipts 테이블도 dead code 보존

### 4-2. 결과물 검수 모달 영수증 구매정보 마스킹 → 해제
- **2026-04-30 (0d2b599)**: 관리자 결과물 검수 모달에서 `purchase_date`/`purchase_amount` 노출 제거 (개인정보 최소 노출)
- **2026-05-15 (migration 128)**: 정책 해제 — 마켓 주문 대조 위해 다시 노출 + `order_number` 신규 추가

### 4-3. 영수증 필수 필드 강화 (2026-05-15, migration 128)
- 리뷰어(monitor) 영수증 제출 시 `order_number` + `purchase_date` + `purchase_amount` 3종 필수
- 인플루언서 폼 `#monitorReceiptFields` + i18n 키 8종(ja/ko)
- 관리자 검수 모달 2종(`openDelivDetail` + `renderDelivPanelContent`) 공통 헬퍼 `renderReceiptInfoBlock(d)` — campaign_admin 이상 인플레이스 수정 폼 + 「변경 이력 보기」 토글
- `update_receipt_admin(uuid, text, date, numeric)` RPC: SECURITY DEFINER, campaign_admin 가드, 0엔 허용, 200자 상한, `FOR UPDATE` 행 잠금, no-op 체크
- 변경 시 `receipt_edit_history` 자동 INSERT (prev/next 스냅샷)
- 결과물 엑셀 영수증 그룹 6→9 컬럼 확장 (주문번호/구매일/구매금액 추가)
- 사양서 `docs/specs/2026-05-14-receipt-required-fields.md`

### 4-4. 결정 이벤트 트리거 양방향 허용 (2026-04-26, aea3d7f)
- `record_deliverable_status_event` 트리거 `draft↔pending` 양방향 전이 허용
- 이전엔 단방향 차단으로 결과물 임시저장 후 재제출 흐름 막힘

### 4-5. 캠페인별 엑셀 내보내기 확장 (2026-04-22)
- 캠페인 더보기 메뉴 `결과물 엑셀` 옆 `신청자 엑셀` 추가
- 전 상태(pending/approved/rejected) 17컬럼
- 파일명 `applicants-{campaign_no|title}-YYYYMMDD.xlsx`

---

## 5. 인플루언서 관리 이력

### 5-1. verify/violation/블랙리스트 (migration 059~062, 2026-04-22)
- 인플루언서 상세 모달에 상태 관리 카드 (인증 토글, 위반 등록, 블랙리스트 등록/해제)
- 인증/위반 배지 이름 옆 노출 (블랙일 땐 블랙 단독)
- 사유는 `blacklist_reason` ∪ `violation_reason` lookup 통합
- 증빙 파일 업로드 (`influencer-flag-evidence` 비공개 버킷, 10MB, image/PDF) — 40×40 썸네일 + 라이트박스
- 인플루언서 목록 sticky-header 재구성 (채널/인증/위반 드롭다운 3종 + 통합 검색)
- storage.js RPC: `setInfluencerVerified`/`setInfluencerBlacklist`/`recordInfluencerViolation`/`updateInfluencerViolation` (evidence_paths 미변경=null, 전체 삭제=[])

### 5-2. 응모 취소 (migration 104, 2026-05-11)
- `applications.status` 에 `cancelled` 추가
- 보조 컬럼 5종: `cancelled_at`/`cancel_reason`/`cancel_reason_code`/`cancel_phase CHECK(recruit|purchase|visit|post|other)`/`previous_status`
- `cancel_application(uuid, reason_code, reason_note, acknowledged)` RPC — 본인 검증·결과물 승인 차단·구매기간 이후 사유·동의 강제
- `(user_id, campaign_id)` UNIQUE 제약을 partial unique index 로 변경 (cancelled 행 제외) → 같은 캠페인 재응모 가능
- `cancel_reason` lookup 시드 6건, `violation_reason` 에 `cancel_after_purchase_start` 1건 추가

### 5-3. 전화번호 표시 포맷 정규화 (`formatPhoneDisplay`, 2026-04-22)
- KR/JP 번호 정규화 (11자리 3-4-4, 10자리 02/03/06 → 2-4-4 else 3-3-4, `+81`/`+82` 지원)
- 적용처: 인플루언서 상세 모달·브랜드 앱 리스트·상세
- 매칭 실패 시 원문 폴백

---

## 6. 주의사항·참여방법·NG 번들 이력

### 6-1. 주의사항 번들 (migration 067 → 069)
- **migration 067 (v1)**: `applications.caution_agreed_at` + `caution_snapshot jsonb` 도입 (`{lookup_codes, labels, custom_html}` 구조). 캠페인의 `caution_lookup_codes`·`caution_custom_html` 컬럼 + lookup `kind='caution'` 5건 시드
- **migration 069 (v2)**: 번들 패턴으로 재설계 — `caution_sets` 테이블 + `campaigns.caution_set_id uuid FK ON DELETE SET NULL`·`caution_items jsonb NOT NULL DEFAULT '[]'`. items 구조: `{text_ko, text_ja, link_url?, link_label_ko?, link_label_ja?, text_after_ko?, text_after_ja?}`. 캠페인 저장 시 **스냅샷 복사**. snapshot v2 구조: `{version:2, campaign_id, set_id, items, agreed_lang, snapshot_at}`. v1 스냅샷은 관리자 뷰어 하위호환 유지
- 067 legacy 컬럼(`caution_lookup_codes`, `caution_custom_html`)·lookup `kind='caution'` 5건은 남아있으나 추후 마이그레이션에서 DROP 예정 (070은 결번)
- RLS SELECT 관리자 전용 (인플루언서는 campaigns 스냅샷 경유)

### 6-2. 참여방법 번들 (`participation_sets`)
- 캠페인 참여 단계 묶음 (1~6단계, 각 단계 title/desc ko·ja). recruit_types[] 태깅으로 필터링
- 캠페인 저장 시 스냅샷 복사 (`campaigns.participation_steps jsonb` + `participation_set_id` FK ON DELETE SET NULL)
- hard delete 는 FK SET NULL 로 스냅샷 격리

### 6-3. NG 번들 (migration 107~109, 2026-05-12, 운영 가동 중)
- **NG-PR-B**: 캠페인 등록·편집 폼에 NG 번들 카드 + 편집 모달 + 미리보기 + 변경 경고 모달 NG 트리거 + closed/expired 잠금 + 인플루언서 캠페인 상세 NG 렌더 (jsonb 우선 + legacy ng 폴백) 연결
- `ng_sets` 테이블 — caution_sets 패턴 완전 미러링. items 구조 `{html_ko, html_ja}` 2필드만 (DOMPurify sanitize, inline 서식만 허용). `campaigns.ng_set_id` + `ng_items jsonb` 스냅샷
- RLS SELECT `is_admin()`, CUD `is_campaign_admin()` 이상
- 기존 `campaigns.ng` (Quill rich text) 컬럼은 DEPRECATED — 1주 관찰 후 NG-PR-F에서 DROP 검토
- 기존 `lookup_values(kind='ng_item')` 6건은 `active=false` 비활성 (시드 6건을 「기본 NG 묶음」 번들 1건으로 흡수)
- 신청자 동의 시점 스냅샷 없음 — NG는 표시용 가이드라인
- 캠페인 백필 안 함 (모든 캠페인 `ng_items='[]'`로 시작, 인플루언서 화면은 legacy `ng` 폴백)
- 기준 데이터 페인 NG 탭의 번들 CRUD 전환은 PR-C 진행 예정

---

## 7. 관리자 공지·계정 이력

### 7-1. 관리자 공지사항 (migration 063, 2026-04-22 → migration 071, 2026-04-27)
- 카테고리 4종 (system_update/release/warning/general), pin (push_pin Material Icon), Quill rich + HTML source 토글
- `admin_notice_reads` 테이블로 관리자별 읽음 기록 (`upsert_admin_notice_read` RPC)
- **migration 071: draft/published 게시 상태 분리** — 작성 즉시 노출 → "초안 → 게시" 흐름. 목록 게시 상태 필터, 편집 모달 모드별 푸터 버튼 (신규·draft: `[초안 저장][게시하기]`, published: `[게시 유지하며 저장][초안으로 되돌리고 저장]` — 메인은 안전 우선 draft 회귀). 보기 모달 푸터에 작성자/super 한정 `[지금 게시]`/`[게시 회수]`. 노출 채널 4개(사이드바 배지·로그인 팝업·대시보드 카드·목록 default)는 published 만. RLS SELECT 는 published OR is_super_admin() OR created_by=auth.uid(). 재게시 시 `admin_notice_reads` 자동 리셋 안 함

### 7-2. 메일 수신 설정 (migration 103, 2026-05-11)
- 관리자 계정 리스트 「메일받기」 셀에 켜진 메일 종류 회색 칩 + 「설정」 버튼
- 모달에서 메일 종류별 체크박스 일괄 on/off (`admin_email_subscriptions` 테이블)
- `lookup_values(kind='admin_email_kind')` 카탈로그 — 시드 `brand_notify`·`application_cancel`·**`application_received`** (130 추가)
- super_admin 은 다른 관리자 설정 편집, 그 외는 본인만
- Edge Function `get_subscribed_admin_emails(메일종류코드)` RPC 수신자 조회 + env `NOTIFY_ADMIN_EMAILS` 합산
- 이전 `admins.receive_brand_notify` 단일 컬럼 deprecated — 다음 배포 사이클 안정성 확인 후 별도 마이그레이션에서 DROP 예정
- 신규 메일 종류 추가는 `lookup_values` 한 줄 추가만으로 가능 (마이그레이션 없이)

### 7-3. 관리자 추가/삭제 RPC
- 초대 방식 `invite_admin(email, name, role)` + 클라이언트가 `resetPasswordForEmail()` 호출 → 이메일 유효성 자동 검증
- 기존 인플루언서 계정도 같은 이메일로 호출 시 자동 관리자 승격
- 삭제 2택: `remove_admin_role(auth_id)` (권한만, 인플루언서 계정 유지) / `delete_admin_completely(auth_id)` (auth/influencers/applications/receipts cascade)
- 자기 자신 삭제 차단
- `create_admin()` 함수는 deprecated — migration 032 (호출 시 예외 발생)

---

## 8. 광고주(sales) 폼 이력

### 8-1. 사업자등록증 수집 제거 (migration 057)
- `brand-docs` 버킷·`business_license_path` 컬럼 모두 삭제
- `submit_brand_application` RPC 의 `p_business_license_path` 파라미터는 057 이후 무시됨 (하위호환 위해 시그니처 유지)

### 8-2. 익명 INSERT 패턴 (migration 056)
- 익명 폼은 `.insert().select()` 대신 SECURITY DEFINER RPC 필수
- RLS `WITH CHECK` + RETURNING SELECT 권한 충돌로 42501 발생 사례 — `brand_applications` → `submit_brand_application()` 로 우회

### 8-3. 리뷰어 신청 완료 화면 입금 계좌 교체 (2026-04-27)
- placeholder `우리은행 1005-XXX-XXXXXX` → 실 계좌 **기업은행 077-156976-01-055** (예금주: (주)제이펀)
- 은행/계좌번호/예금주 라벨 한·일 양언어 유지, 값은 KO-only (`<span class="ko-only">`)
- 시딩 폼은 종전대로 계좌 표시 없음 (별도 정산 흐름)

### 8-4. sales 페이지 리디자인 (2026-04-21)
- 루트에 choice landing + `/reviewer`·`/seeding` 경로
- Vercel `cleanUrls` 로 HTML 확장자 제거, catch-all rewrite
- 브랜드 로고 홈 클릭 가능, reviewer/seeding 페이지 샘플 이미지 + 통계 칩 인트로

---

## 9. 일반 UI / 성능 / 라이브러리 이력

### 9-1. 관리자 리스트 IntersectionObserver lazy-load (2026-04-21)
- 8개 목록 페인 모두 sentinel 기반 점진 렌더 — 커밋 79a98c6/8520430/cbb4396/4e34f3c
- 필터·검색·정렬 변경 시 sentinel 리셋 필수
- `renderAppCampList` 는 campaigns/applications/influencers 결과 in-memory 캐시 공유

### 9-2. PostgREST 1000-row cap 대응 (2026-04-21, 커밋 245e3f5)
- 대시보드 집계용 fetch 는 `range(from, from+999)` pagination loop 로 전건 조회
- 단일 `.from().select()` 호출은 1000건에서 잘림
- 이전 KPI 가 정확히 1000에 고정됐던 회귀 사례

### 9-3. 관리자 리스트 캠페인 필터 multi-select + cascade (2026-04-22)
- 신청 관리·결과물 관리·캠페인별 신청자 페인에 캠페인 다중선택 드롭다운
- 타입/kind 필터 cascade (캠페인 선택 시 타입 옵션 좁힘)
- `[CAMP-YYYY-NNNN] 제목` 라벨

### 9-4. 캠페인 신청자 목록 SNS 전체 표시 (2026-04-22)
- `renderAppCampList` 행에 IG/TT/X/YT 4개 채널 핸들+팔로워 모두 표시
- 이전: primary_channel 만

### 9-5. 브랜드 서베이 엑셀 내보내기 (2026-04-22)
- 페인 헤더에 엑셀 다운로드 버튼
- 컬럼: 신청일·신청번호·폼타입·업체/브랜드명·담당자·이메일·연락처·세금계산서 주소·예상견적·상태

### 9-6. 광고주 신청 페인 중복 fetch 회귀 수정 (2026-05-15, PR #205)
- `loadBrandApplications` 가 페인 진입 시 race condition 으로 두 번 호출되어 4종이 각각 2회 fetch
- promise 캐싱 guard 로 동시 호출 차단 (진행 중인 promise 있으면 그것 반환, 새 호출 시 fresh fetch)
- 14 requests → 8 requests (절반 감소)

---

## 10. 기타 deprecated / 정리 예정

- `admins.receive_brand_notify` — 2026-05-11 deprecated (admin_email_subscriptions 로 대체). 다음 배포 사이클 안정성 확인 후 별도 마이그레이션에서 DROP 예정
- `campaigns.ng` (Quill rich text) — 2026-05-12 deprecated (ng_sets/ng_items 로 대체). 1주 관찰 후 NG-PR-F 에서 DROP 검토
- `lookup_values(kind='ng_item')` 6건 — 2026-05-12 active=false 비활성 처리 (「기본 NG 묶음」 번들 1건으로 흡수)
- `lookup_values(kind='caution')` 5건 — 2026-04-23 부터 미참조 (caution_sets 번들로 대체). 추후 마이그레이션에서 DROP 예정 — 070은 결번
- `campaigns.caution_lookup_codes`, `caution_custom_html` (067 legacy) — 069 이후 미사용. 추후 마이그레이션에서 DROP 예정
- `notify-application-cancelled-daily` (113) — 2026-05-18 deprecated. cron 만 해제, Edge Function 코드 보존. 운영 안정화 2주 후 별도 정리 PR 에서 삭제 예정
- `notify-application-received-admin-daily` (130) — 2026-05-18 deprecated. cron 만 해제, Edge Function 코드 보존
- receipts 테이블·035 dual-write 트리거 — dead code 상태 보존 (활동관리는 deliverables 직접 INSERT). 추후 정리 예정
- `influencers.bank_*` 컬럼 — deprecated, 유지 미사용
- `applications.reviewed_version` — 낙관적 락용, 사용 미확인 (현행 동시 처리 충돌은 deliverables.version 으로)

---

## 메모

- 본 아카이브는 **검색용**이다. 새 변경 이력을 추가할 때 영역(1~10)에 맞춰 항목 누적
- "왜 그렇게 되었는가" 의 근거 자료가 되므로 마이그레이션 번호·PR 번호·커밋 해시는 가급적 보존
- `CLAUDE.md` 본문에서 "이력성 메타데이터" 가 보이면 본 파일로 이주
