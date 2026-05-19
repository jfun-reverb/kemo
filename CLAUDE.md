# REVERB JP — 인플루언서 체험단 플랫폼

> 이 문서는 **현재 가동 중인 동작·핵심 컨벤션** 위주. 마이그레이션 번호·PR 노트·deprecated 메모 등 이력성 메타데이터는 [`docs/CLAUDE-ARCHIVE.md`](docs/CLAUDE-ARCHIVE.md) 참조.

## Overview
일본 시장 대상 인플루언서 체험단(리뷰어/기프팅/방문형) 모집 플랫폼.
브랜드가 캠페인을 등록하고, 인플루언서가 신청하는 구조.

## Tech Stack
- Language: HTML/CSS/JavaScript (vanilla, 프레임워크 없음)
- Backend: Supabase (Auth + Database + Storage) + localStorage 폴백
- Deployment: Vercel Pro (Team 플랜)
- Package Manager: 없음 (CDN 기반)

## Key URLs
- 운영 (인플루언서): https://globalreverb.com
- 운영 (관리자): https://globalreverb.com/admin/
- 운영 (광고주 신청 폼): https://sales.globalreverb.com (별도 Vercel 프로젝트 `reverb-sales`, Root Directory=`sales/`)
- 스테이징 (인플루언서): https://dev.globalreverb.com
- 스테이징 (관리자): https://dev.globalreverb.com/admin/ (admin@kemo.jp / admin1234)
- GitHub: github.com/jfun-reverb/kemo
- Supabase (production): https://twofagomeizrtkwlhsuv.supabase.co (🇦🇺 Sydney `ap-southeast-2`, Pro/NANO)
- Supabase (staging): https://qysmxtipobomefudyixw.supabase.co (🇯🇵 Tokyo `ap-northeast-1`, Pro/MICRO)
- LINE: @reverb.jp

## Environments
- **도메인 기반 자동 분기**: `dev/lib/supabase.js`의 `resolveSupabaseEnv()`가 `location.hostname` 판별
  - `globalreverb.com`, `www.globalreverb.com` → 운영서버 Supabase
  - 그 외 (dev.globalreverb.com, localhost 등) → 개발서버 Supabase
- Supabase URL/Key는 `SUPABASE_ENVS` 객체에서만 관리 (다른 파일 하드코딩 금지)
- 관리자 페이지 헤더에 개발서버에서만 주황색 `STAGING` 배지 + `[DEV]` 탭 제목/파비콘 표시
- 운영 배포는 반드시 개발서버 검증 후 main merge
- Supabase Client 옵션: `flowType: 'pkce'`, `detectSessionInUrl: true` (비밀번호 재설정 안정성)

## Email / SMTP
- 양 서버 모두 **Brevo Custom SMTP** 사용 (`smtp-relay.brevo.com:587`)
- **Brevo 플랜: Starter 20,000 emails/월** (Monthly $29, 갱신일 매월 16일). Marketing+Transactional 공용 쿼터, 일일 한도 없음
- 발신: `noreply@globalreverb.com`, 발신명: 운영 `REVERB JP` / 개발 `REVERB JP [DEV]`
- 발신 도메인 DNS 인증 완료 (SPF/DKIM/DMARC, cafe24 DNS 관리)

### 가동 중인 메일 파이프라인
- **광고주 신청 접수 알림** (`notify-brand-application`): Supabase Edge Function — `brand_applications` INSERT 직후 호출. 수신자는 `get_subscribed_admin_emails('brand_notify')` RPC + env `NOTIFY_ADMIN_EMAILS` 합산 (중복 제거)
- **관리자 일일 통합 다이제스트** (`notify-admin-daily-digest`): pg_cron 매일 UTC 00:00 (=KST 09:00). 4섹션 1통 — ①신청 접수 ②응모 취소 ③결과물 제출 ④재처리 일감. 4섹션 모두 0건이면 미발송. 부분 0건은 발송 + 해당 섹션 본문 생략. `admin_daily_digest_runs.digest_date UNIQUE` 가 mutex (중복 호출 차단)
- **인플루언서 일일 다이제스트** (`notify-influencer-daily-digest`): pg_cron 매일 UTC 00:00. 인플루언서별 어제 신청·승인·반려 + 오늘 D-5/D-1 영수증·결과물 마감 4섹션 1통. 4섹션 모두 0건은 스킵. `deadline_reminder_email_sent` UNIQUE 4-tuple 로 임박 메일 재발송 차단. marketing_opt_in 무시 (트랜잭션 성격)
- **인플루언서 메일 푸터 통일 패턴** (2026-05-19 확정, 사용자 명시): 인플 대상 메일(`notify-influencer-daily-digest`, `notify-deliverable-decision` 6종, `notify-campaign-promo-digest`)은 **4줄 푸터 필수** — ①「REVERB JP のメンバーシップに紐づいて自動送信されています。」 ②「お問い合わせは LINE @reverb.jp までお願いいたします。」 ③「© JFUN Corp. · 株式会社ジェイファン」 ④`https://globalreverb.com`. 글자색 `#999`, 링크 underline. deliverable 메일은 placeholder(`{{help_line_url}}`/`{{site_url}}`) 유지, 그 외는 LINE/사이트 URL 하드코딩. 관리자/광고주 메일은 통일 대상 외. 신규 인플 메일 추가 시 본 패턴 그대로 적용 의무
- **캠페인 홍보 메일 다이제스트** (`notify-campaign-promo-digest`, 2026-05-19 PR 2): pg_cron 매주 월·목 UTC 00:00 (=KST 09:00, cron 등록은 PR 5 영역). `get_promo_digest_targets(date)` RPC 로 `marketing_opt_in=true` + 자격 매칭 인플 조회. 신규(`新着`) + D-1 임박(`締切間近`) 2섹션, 카드 최대 5건 + 「他 N件」 안내. 같은 캠페인 인플당 최대 2회 노출 (`campaign_promo_exposure` UNIQUE) + 클릭한 캠페인은 자동 제외 (`campaign_promo_email_clicks`). 200명/호출 배치 + chained 자기재호출(fire-and-forget). `campaign_promo_digest_runs.digest_date UNIQUE` mutex (중복 호출 차단) + `campaign_promo_digest_sent (influencer_id, digest_date) UNIQUE` 멱등 (재호출·chained 안전). 인플당 1통씩 분리 발송 (To 헤더 노출 차단). 마이그레이션 139·140·141·143 의존
- **메일 템플릿 소스**: `docs/email-templates/` 가 source of truth. Edge Function 은 `_templates/` 미러를 `Deno.readTextFile + render({{key}})` 로 읽음. 배포 전 항상 `scripts/sync-email-templates.sh` 로 동기화
- **카탈로그**: `docs/email-templates/index.html`
- **관리자 일괄 발송 메일 수신자 분리** (2026-05-19): 관리자 N명에게 보내는 메일은 모두 **관리자 한 명당 1통씩 분리 발송**. To 헤더에 다른 관리자 이메일이 노출되지 않음. 적용 함수: `notify-admin-daily-digest`, `notify-brand-application` (관리자 알림 부분), `notify-application-received-admin-daily` / `notify-application-cancelled-daily` (cron 해제 deprecated 2종도 회귀 방지 차원에서 동일 패턴). 부분 실패(N명 중 일부 실패) 시 `status='sent'` + `recipients_count`=성공 수 + `error_message`에 실패 명단 누적 (전원 실패만 `status='failed'`). 인플루언서 메일은 원래부터 1명씩 발송이라 영향 없음
- **관리자 일일 통합 다이제스트 인플루언서 표시 4종 통일 + 섹션 1 표 헤더** (2026-05-19): 4개 섹션 모두 인플루언서 정보를 「이름(한자)·이름(가나)·이메일·SNS 아이디(공식 URL 링크)」 4종으로 통일. 섹션 1 신청 접수 표는 5컬럼 헤더(이름·이메일·SNS·신청시각) + 행 하단 점선. SNS 링크는 `dev/js/admin.js` 엑셀 export 의 `_excelSnsUrl` 패턴과 통일 (Instagram `https://www.instagram.com/{h}/`, TikTok `https://www.tiktok.com/@{h}`, X `https://x.com/{h}`, YouTube `https://www.youtube.com/@{h}`). primary_sns 우선 + 없으면 첫 등록 채널 폴백. 기존 `influencerDisplayName` / `snsHandleDisplay` 헬퍼는 `influencerNameKanji` / `influencerNameKana` / `influencerNameFull` / `snsCellHtml` 4종으로 분리
- **관리자 일일 통합 다이제스트 섹션 2/3/4 캠페인 그룹화 + 표** (2026-05-19): 섹션 1과 동일 패턴으로 통일 — 캠페인별 그룹 카드 + 인플 N행 표(헤더 포함). 기존 phase(취소 시점)/kind(결과물 종류)/type(재처리 종류) 그룹 헤더는 폐기되고 표의 컬럼 안 컬러 칩으로 흡수. 같은 캠페인에 인플 N명이 동시에 사건을 일으킨 경우 한 카드 안 표로 묶여 운영자가 한눈에 식별 가능. 섹션 3 「제출 내역」 컬럼 신규: 영수증 → 이미지 링크 + 「주문 X · 구매일 · 금액 ¥N」 작은 글씨 (`order_number` / `purchase_date` / `purchase_amount` 3종, 마이그레이션 128 이후 노출 재허용), 게시 URL → 게시 링크, 리뷰 이미지 → 이미지 링크. URL 화이트리스트 `safeExternalUrl(url)` 로 http/https 만 허용 (`javascript:` / `data:` 등 차단). `DeliverableInfo` 쿼리에 `receipt_url, post_url, order_number, purchase_date, purchase_amount` 5개 컬럼 추가

### Auth URL Configuration
- 운영: Site URL `https://globalreverb.com` + Redirect `https://globalreverb.com/**`, `https://www.globalreverb.com/**`
- 개발: Site URL `https://dev.globalreverb.com` + Redirect `https://dev.globalreverb.com/**`

### Auth Rate Limits
- 운영: `Rate limit for sending emails` = **100 emails/h** (가입+초대+재설정 메일 공용)
- 개발: 기본값 30/h (Confirm email OFF, 트래픽 적어 충분)
- 한도 소진 시 `429 email rate limit exceeded`. Logs & Analytics → Auth 에서 확인

## i18n (개발서버 한정)
- 인플루언서 페이지 KO/JA 토글 (마이페이지 메뉴)
- 키-값: `dev/lib/i18n/{ja,ko}.js`, 런타임: `dev/lib/i18n/index.js`
- HTML: `data-i18n="key"` (textContent), `data-i18n-html="key"` (innerHTML, `<br>` 허용)
- JS 동적: `t('key')` 헬퍼
- 기본값 `ja`, navigator.language 자동 감지 사용 안 함
- 운영서버 배포 전 (테스터 검증 완료 후 결정)
- 적용 범위: 마이페이지, 인증, GNB/홈, 캠페인 목록·상세, 신청 모달, 활동관리, 알림, DB 에러 메시지 로케일 분기 (`friendlyErrorJa`)

## 내부 문서 (개발서버 한정)
- `docs/service-flow.html` — 전체 서비스 플로우차트
- `docs/flowchart-i18n.html` — i18n 다국어 흐름도
- 접속: https://dev.globalreverb.com/docs/service-flow.html, https://dev.globalreverb.com/docs/flowchart-i18n.html
- **운영서버(main)에 머지하지 않음** — 내부 직원용 참고 자료

## Architecture
- 인플루언서 앱: `dev/index.html` (모바일 480px, GNB + 우측 슬라이드 햄버거 메뉴)
- 관리자 앱: `dev/admin/index.html` (PC 전체폭, 별도 페이지, **2단 고정 레이아웃** — 사이드바/메인 독립 스크롤, 상단 GNB 없음)
- **광고주 신청 앱(sales)**: `sales/{index,reviewer,seeding}.html` — 별도 Vercel 프로젝트 `reverb-sales`(Root Directory=`sales/`), `sales.globalreverb.com` / `sales-dev.globalreverb.com` 서브도메인. anon 으로 `submit_brand_application` RPC 경유 `brand_applications` INSERT. Vercel `cleanUrls`+catch-all rewrite 로 `/reviewer` → `reviewer.html`. 파일 업로드 기능 없음 (텍스트 입력만)
- 배포용: 루트 `index.html` (build.sh 로 생성)
- 개발 폴더 구조:
  - `dev/js/` — app, ui, campaign, application, auth, mypage, admin, admin-brand
  - `dev/css/` — base, components, campaign, auth, mypage, admin
  - `dev/lib/` — supabase(설정), shared(전역변수), storage(DB/Storage API)
  - `dev/build.sh` — dev/ → 루트 index.html 빌드
  - `sales/` — 광고주 신청 폼 (빌드 없이 정적 파일 그대로 배포)
  - `supabase/functions/notify-brand-application/` — 광고주 신청 알림 Edge Function
- Supabase 미연결 시 localStorage 로 동작 (DEMO_MODE)

## Features — 인플루언서 (모바일)
- **회원가입**: 1단계 폼 (이름 한자/가나 + 이메일 + 비밀번호), 추가정보는 마이페이지에서 입력
- **로그인/로그아웃**: 이메일+비밀번호, 세션 복원, 관리자 로그인 시 admin 페이지 자동 오픈
- **비밀번호 재설정**: 이메일 입력 → Supabase 재설정 메일 발송 → 앱 내 새 비밀번호 설정 (`#page-forgot`, `#page-reset-pw`)
- **GNB**: 비로그인 시 Log In/Sign Up 버튼, 로그인 시 우측 햄버거 메뉴 (홈/캠페인/마이페이지/알림/로그아웃), 관리자는 Admin 버튼
- **회원가입 이메일 확인**: 운영서버 한정 Supabase Confirm sign-up 활성, 가입 후 확인 메일 안내 화면 표시, 미확인 시 로그인/신청 차단. 개발서버는 Confirm email OFF. auth.js 는 `data.session` 유무로 자동 분기
- **캠페인 목록**: 채널필터(동적 생성), 모집유형 필터(리뷰어/기프팅/방문형). 노출 대상은 active + scheduled + closed(노출 ON)
- **캠페인 카드 배지**: 좌상단 `募集中`(active), 우상단 `NEW`(7일 이내), 제목 위 `締切間近`(deadline<5일 또는 잔여 slots≤30%), 콘텐츠 종류 아래 모집타입 pill + `{applied}/{slots}名` 슬롯 카운트, 이미지 좌하단 첫 채널+`+N`
- **캠페인 상세**: 이미지 캐러셀(최대9장), 상품정보, 모집조건, 참가방법, 가이드라인, NG사항, LINE/Instagram CTA, 조회수 자동 카운트, closed 시 신청버튼 비활성(募集締切). 채널 pill 사이에 `or` 또는 `&` 구분자 (`channel_match`)
- **캠페인 신청**: 이메일 인증 필수, 필수정보 사전체크(채널별 SNS / zip+prefecture+city+phone / PayPal 이메일) → 동기메시지 + 배송지 + PR태그 동의, 중복신청 방지, 최소 팔로워수 미달 시 알럿 차단
- **주의사항 동의**: 캠페인의 `caution_items` 가 있으면 ①상세 "주의 사항" 섹션 + ②신청 모달 상단 빨간 박스 양쪽 렌더. 모달 하단 "全ての注意事項を確認しました" 단일 체크박스 + 미체크 시 차단. 동의 시 `applications.caution_agreed_at` + `caution_snapshot`(jsonb) 저장. 캠페인 items 스냅샷을 신청 시점 그대로 보존 → 번들 수정 후에도 기존 신청 데이터 영향 없음. 응모이력에 동의 시각 작은 배지 노출
- **응모 차단**: 리뷰어(monitor) 캠페인은 `applied_count >= slots` 일 때 신규 응모 차단 (기프팅·방문형은 초과 응모 허용)
- **마이페이지**: 리스트 → 상세 페이지 네비게이션, 메뉴 応募履歴/基本情報/SNSアカウント/配送先/PayPal/パスワード変更/ログアウト, 대표SNS 선택 가능, 필수 미입력 항목 "未登録" 배지 + 붉은 테두리
- **GNB 햄버거 메뉴**: 상단 우측 ☰ 버튼에 미읽음 알림 배지(9+), 클릭 시 우측 슬라이드 패널. 비로그인은 로그인/회원가입, 인증 페이지에선 햄버거 숨김, 관리자는 알림 항목 없음
- **알림 모달**: deliverables.status 트리거로 생성된 rejected/changed/approved 3종. 항목 클릭 시 읽음 처리 + 활동관리로 이동. "모두 읽음" 버튼
- **활동관리**: 승인된 캠페인에서 결과물 제출. recruit_type 분기 — monitor=영수증(이미지 + 주문번호·구매일·구매금액 3종 필수), gifting/visit=SNS 게시물 URL(자동 채널 판별 + 실패 시 수동 드롭다운). 모두 `deliverables` 직접 INSERT + `submit_deliverable` RPC. 반려된 결과물은 상단 빨간 배너에 사유 표시, 재제출 시 pending 복귀 (동일 URL 은 `post_submissions` 배열에 날짜 누적). `submission_end` 경과 시 폼 비활성
- **응모이력**: 상태별 탭 필터(전체/심사중/승인/비승인), 캠페인상태/정렬 필터. 승인 캠페인 클릭→활동관리, 기타→캠페인 상세
- **본인 응모 취소**: `cancel_application(uuid, reason_code, reason_note, acknowledged)` RPC — 본인 검증·결과물 승인 차단·구매기간 이후 사유·동의 강제
- **홈 하단 푸터**: 株式会社ジェイファン 회사 정보 + 会社紹介/利用規約/個人情報処理方針 링크 (슬라이드업 모달), Instagram·X SNS 아이콘
- **성능 최적화**: preconnect(Supabase/Fonts/jsDelivr), 캠페인 카드/마이페이지 썸네일 lazy loading + decoding=async, Supabase Storage 이미지 transform(`/render/image/public/?width=&quality=`)으로 썸네일 용량 축소, 이미지 로드 실패 시 원본 URL 자동 폴백

## Features — 관리자 (PC)
- **사이드바**: Material Icons, 접기/펼치기 토글, `data-pane` 속성 기반 라우팅, pending 배지 항상 표시
- **페이지 새로고침**: `visibility:hidden` cloak 기법 (깜빡임 완전 방지), 서브패널 새로고침 시 부모 패널로 리다이렉트
- **대시보드**: KPI 카드(캠페인/인플/신청/승인), 상태별·채널별 캠페인 분포(채널 복수 선택 캠페인은 중복 집계), 회원가입 추이 차트(Chart.js, 7일/30일/전체), 오늘·이번주 가입 KPI, 프로필 완성률(SNS·배송지·PayPal), 배송지 도도부현 분포 도넛(Top 10 + 未登録/海外, 47개 현 한국어 라벨), 최근 신청 테이블
- **로딩 UX**: 테이블/대시보드 KPI/차트 영역에 인라인 스피너 (전체화면 오버레이 제거)

### 캠페인 관리
- CRUD + 복제 + 삭제(확인모달) + 순서변경 모드 + 더보기 메뉴(결과물 엑셀·신청자 엑셀·변경 이력)
- **캠페인 번호 채번**: `B{brand_seq}-A{app_seq}-C{camp_seq}` (외부 캠페인은 `B{brand_seq}-C{ext_seq}`). 자릿수 brand 4/신청 3/캠 3. 신규 INSERT 시 트리거 자동 채번. 캠페인 등록 폼은 brands 드롭다운 + 신청 cascade + 신규 brand 인라인 모달 패턴. 기존 v1 `CAMP-YYYY-NNNN`/`JFUN-{Q|N}-YYYYMMDD-NNN` 은 `legacy_no` 컬럼·`numbering_legacy_map` 에 보존
- **캠페인 등록/편집 폼**: 4개 섹션 그룹핑 (기본정보/제품정보/모집조건/콘텐츠가이드). 모집타입 라디오버튼 UI, 채널은 복수 선택 체크박스(Instagram/X/Qoo10/TikTok/YouTube, 콤마 구분 저장 `"instagram,x"`). 채널 2개+ 선택 시 `or`/`&` 라디오 노출 → `campaigns.channel_match`. 자격 검증은 `primary_channel` 단일 기준
- **콘텐츠 가이드 리치 텍스트** (Quill v2, 3개 필드): Notion 복사·붙여넣기 서식 유지. 이미지 태그는 저장 시 제거. XSS 방어 DOMPurify 저장+렌더 이중 sanitize. 헬퍼는 `dev/lib/shared.js`
- **참여방법·주의사항·NG 미니 에디터**: 굵게/기울이기/링크/이미지 첨부 가능. 이미지는 `campaign-images/content/` 업로드 (5MB / jpg·png·webp) → `<img class="rich-img">` 삽입. 클릭 팝오버로 Small/Medium/Large/Original 크기 조정. XSS 방어는 src 화이트리스트 (https + `*.supabase.co`)
- **캠페인 목록**: 썸네일+이미지수, 상태/타입 드롭다운 필터, 검색(캠페인명+브랜드+제품+campaign_no), 헤더 정렬(조회/신청/등록일/수정일 ▲▼), D-day 라벨, 승인수/모집수 표시 + 대기 배지
- **캠페인 미리보기**: 캠페인 제목 클릭 시 모바일 크기 프리뷰 모달 (편집 버튼 포함)
- **캠페인 상태 5단계**: `draft` → `scheduled` → `active` → `closed`, `expired`(노출마감). 자동 전이 2종: `scheduled→active`(recruit_start 도래), `active→closed`(deadline 경과). `expired` 는 운영자 「캠페인 노출」 토글 OFF 로만 진입. `closed` 는 운영자 OFF 까지 인플 화면에 노출(募集締切 오버레이). 노출 그룹(scheduled/active/closed) 컬러 배지, 비노출 그룹(draft/expired) 회색·점선
- **캠페인 노출 토글**: 등록/편집 폼 최상단 + 목록 「상태」 컬럼 빠른 토글. OFF 시 확인 모달 후 status=expired, ON 시 자연 상태 재계산. draft 는 비활성. `toggleCampaignVisibility` + `computeCampaignStatus`
- **자동 시작·종료**: `fetchCampaigns` 호출 시 `autoOpenCampaigns()` → `autoCloseCampaigns()`. deadline 지난 캠페인은 active/scheduled 저장 불가
- **날짜 입력**: flatpickr range picker 2개(모집·구매/방문) + single picker 1개(`submission_end`). 모집 종료일 선택 시 `submission_end` +14일 자동 제안. 구매·방문 기간은 모집 시작~결과물 제출 마감 윈도우로 자동 clamp. monitor 일 때 콘텐츠 종류 옵션 영상/이미지만 자동 필터링
- **모집인원 초과 승인 차단**: 승인 수가 slots 에 도달하면 알럿 모달 차단
- **조회수**: `campaigns.view_count`, 캠페인 상세 열 때 +1, 관리자 목록에 표시
- **이미지 관리**: 드래그앤드롭 업로드, 크롭, 미리보기, Supabase Storage 저장

### 신청·결과물 관리
- **신청 관리**: 테이블 UI (캠페인 썸네일, 타입/상태/검색 필터, 상태 정렬), 인플루언서 상세 모달, 모집인원/빈자리 표시. `reviewed_by`/`reviewed_at` 기록, 되돌리기(pending 복귀). 빈자리 없으면 승인버튼 비활성. 빨간 배너로 결과물 반려 사유 표시
- **결과물 관리** (`/admin#deliverables`): 영수증/게시물 URL 통합 검수 페인. 필터(상태 기본 pending·캠페인·타입·인플루언서 검색) + 오래된 순 정렬. 상세 모달에 이력 타임라인 + 승인/반려/되돌리기. 반려 사유 템플릿(6종) + 자유입력. 낙관적 락(`version`) 기반 동시 처리 충돌 차단 — 후순위는 "이미 처리됨" 토스트
- **캠페인 진행현황**(캠페인 → 신청자 보기): 신청자 테이블에 OT 발송 체크박스(gifting/visit 승인 건만 활성) + 결과물 상태 요약(승인/검수대기/반려 건수 + 최신 상세 모달 링크)
- **영수증 필수 필드**(리뷰어 monitor): 인플 폼에 `order_number` + `purchase_date` + `purchase_amount` 3종 필수. 관리자 검수 모달은 `renderReceiptInfoBlock(d)` 공통 헬퍼 + campaign_admin 이상 인플레이스 수정 + 「변경 이력 보기」 토글. `update_receipt_admin` RPC (SECURITY DEFINER, campaign_admin 가드, FOR UPDATE 행 잠금). 변경 시 `receipt_edit_history` 자동 INSERT
- **엑셀 내보내기**: 단일 캠페인은 더보기 메뉴 `결과물 엑셀`/`신청자 엑셀`, 다중 캠페인은 목록 체크박스 + 「선택 N개 …엑셀」. ExcelJS CDN lazy-load, 영수증 이미지 셀 임베드. 50개+ confirm() + 5초 쿨다운 + 동시 진행 lock. 시트1 「캠페인 정보」 + 시트2 「결과물/신청자」. 이름 한자/가나 분리, SNS 핸들 → 공식 전체 URL, 우편번호 별도 컬럼. 공용 헬퍼는 `_excel*` 시리즈

### 브랜드 서베이 (광고주 신청 관리)
- **현황 대시보드**(`/admin#brand-dashboard`): KPI 8개 + 견적 합계(예상·확정) + **전환 깔때기 10단계** + 폼·상태 도넛 2개 + 일별 추이 바차트(7/30/90일) + 최근 신청 5건 + 장기 대기(new 3일+) + Vercel Web Analytics 외부 링크
- **신청 관리**(`/admin#brand-applications`, **UI 라벨: "브랜드 서베이"**): 내부 용어·DB(`brand_applications`)·라우트·함수명은 `광고주 신청` 그대로. 영업팀이 비공개 URL(`sales.globalreverb.com/reviewer`, `/seeding`)로 받은 신청을 검수·견적 확정·상태 관리. 모든 관리자 접근(`is_admin()`)
- **리스트**: 필터(폼타입/상태/기간/검색) + pending(new) 배지 + 상세 모달(제품 테이블·견적·견적서 URL·OT 시트 URL·입금 날짜 `paid_at` 인라인 편집·제품별 multi-entry 메모·낙관적 락 version)
- **상태 전이 10단계**: `new → reviewing → quoted → paid → kakao_room_created → orient_sheet_sent → schedule_sent → campaign_registered → done` / `rejected`. "되돌리기"(any → new). 깔때기·드롭다운·통계 표시 순서는 실제 영업 워크플로에 맞게 정렬. `kakao_room_created`(카톡방 생성)는 입금 확인 후 카카오 단톡방 개설 가시화
- **제품별 메모**: 셀 ✎ 클릭으로 모달 진입. 분홍 배지 = 본인 미확인 메모 수 (`brand_application_memo_reads`). 모달 진입 시 자동 read. RPC `mark_brand_app_memos_read` 일괄 읽음 + `get_brand_app_memo_summaries()` 페어 단위 집계
- **입금여부 4종 칩**(`payment_flags jsonb`): {recruit, product, transfer, free}. products 변경 시 recruit/product/transfer 자동 재계산 트리거. free 키는 OLD 값 보존(관리자 명시 토글 보호). 무료모집 칩만 초록 톤(#E8F5E9/#16A34A)
- **가격체크**: `products[i].price_check` (`'higher'|'lower'|'equal'`, optional) — 마켓 등록 가격 vs 신청 금액 비교. 신청 목록 표 「가격체크」 드롭다운 컬럼 토글. 미선택이면 키 자체 없음
- **URL 입력 자동 prefix**: `normalizeBrandUrlInput(raw)` — 스킴 없는 입력(`example.com`) 에 `https://` 자동 prefix, 위험 스킴(javascript:, data:) 차단. 견적서/오리엔시트 셀 적용
- **엑셀 내보내기**: 페인 헤더에 엑셀 다운로드 버튼 — 신청일·신청번호·폼타입·업체/브랜드명·담당자·이메일·연락처·세금계산서 주소·예상견적·상태
- **운영 현황 페인**: 회사(`companies`) 기반 브랜드 카드 그리드. `get_brand_ops_overview(p_company_id)` 19컬럼 + alert_level 4단계(`danger`/`warning`/`caution`/`normal`). 브랜드 상세 진입 시 `get_brand_ops_detail(p_brand_id)` jsonb 통합 반환(brand/company/applications/external_campaigns). 사양서 `docs/specs/2026-05-13-brand-ops-redesign.md`
- **캠페인 ↔ 신청 연결/해제**: `link_campaign_to_application` / `unlink_campaign_from_application` RPC. 같은 brand_id 검증 후 채번 재발급 + `legacy_no` 콤마 누적 + `numbering_legacy_map` UPSERT. 동시성 `pg_advisory_xact_lock` 2단 잠금. 멱등성 `unchanged:true` 반환. 가드 `is_campaign_admin()` 이상

### 인플루언서 관리
- **목록**: 채널/인증/위반 드롭다운 3종 sticky-header + 통합 검색
- **상태 관리**(인증/위반/블랙리스트): 상세 모달에 상태 관리 카드 + 관리자 이력 카드 (사유별 누적 pill + 타임라인 + 위반 행 편집). 인증/위반 배지는 이름 옆 노출 (블랙일 땐 블랙 단독). 사유는 `blacklist_reason` ∪ `violation_reason` lookup 통합. 증빙 파일 업로드 (`influencer-flag-evidence` 비공개 버킷, 10MB, image/PDF). RPC: `setInfluencerVerified`/`setInfluencerBlacklist`/`recordInfluencerViolation`/`updateInfluencerViolation` (evidence_paths 미변경=null, 전체 삭제=[])
- **전화번호 표시 포맷**(`formatPhoneDisplay` in ui.js): KR/JP 번호 정규화 (11자리 3-4-4, 10자리 02/03/06 → 2-4-4 else 3-3-4, `+81`/`+82` 지원). 매칭 실패 시 원문 폴백

### 기준 데이터·번들·관리자 계정
- **기준 데이터 관리**(`/admin#lookups`): 채널/카테고리/콘텐츠 종류/NG 사항/반려사유/블랙리스트·위반 사유/주의사항/취소 사유/메일 종류 등을 한국어·일본어로 관리(campaign_admin 이상). 항목 활성/비활성 토글, 순서 변경 모드, 사용 중이면 hard delete 차단(soft delete 만). 채널은 모집 타입(monitor/gifting/visit) 다중 지정. code 는 자동 생성·UI 비공개
- **주의사항 번들**(`caution_sets`): 캠페인 등록/편집 폼 콘텐츠 가이드 섹션에 "주의사항" 영역 — 번들 드롭다운(recruit_type 필터) + "번들 다시 불러오기" + 인라인 items 편집(본문 한/일, 선택적 링크). 캠페인 저장 시 스냅샷 복사. 신청 행 메시지 셀에 "주의사항 동의 ✓ {시각}" 작은 배지 (msgCell 헬퍼)
- **참여방법 번들**(`participation_sets`): 1~6단계 묶음, 각 단계 title/desc ko·ja, recruit_types[] 태깅으로 필터링. 캠페인 저장 시 스냅샷 복사(`participation_steps jsonb`). 인라인 개별 수정 + "번들 다시 불러오기" 지원
- **NG 번들**(`ng_sets`): caution_sets 패턴 미러링. items 구조 `{html_ko, html_ja}` 2필드 (DOMPurify sanitize, inline 서식만). `campaigns.ng_set_id` + `ng_items jsonb` 스냅샷. 인플루언서는 jsonb 우선 + legacy `campaigns.ng` 폴백
- **민감 항목 변경 경고**: 캠페인 편집에서 `caution_items`/`participation_steps`/`ng_items` 변경 시 `#sensitiveChangeModal` 경고. closed 캠페인은 변경 차단 트리거. 변경 이력은 `campaign_caution_history` audit 자동 기록 → 더보기 메뉴 「변경 이력」(super_admin) 타임라인 + 인플 응모이력 「現在の文言と比較」 토글
- **편집 모달 분리**: 참여방법/주의사항 편집을 별도 모달로. 카드 헤더 「편집」 버튼 1개로 정리, bundle summary 카드 한·일 양언어 풀 노출, 注意事項 미리보기 한·일 토글
- **관리자 공지사항**(`/admin#admin-notices`): 사이드바 최상단 + 미읽음 건수 배지. 카테고리 4종(system_update/release/warning/general), 상단 고정(push_pin), Quill 리치텍스트 + HTML source 토글. **draft/published 분리** — 신규·draft 편집은 `[초안 저장][게시하기]`, published 편집은 `[게시 유지하며 저장][초안으로 되돌리고 저장]`. 보기 모달에 작성자/super 한정 `[지금 게시]`/`[게시 회수]`. 노출 채널 4개(사이드바 배지·로그인 팝업·대시보드 카드·목록 default)는 published 만. 로그인 시 미읽음 팝업 자동. 공지 초안 생성은 `/공지초안-관리자` 슬래시 커맨드
- **관리자 계정**: 3단계 권한(super_admin > campaign_admin > campaign_manager)
  - **추가**: super_admin 이 이메일+이름+역할 입력 → `invite_admin()` RPC → 클라이언트가 `resetPasswordForEmail()` 호출. 받은 사람이 메일 링크로 직접 비밀번호 설정 (이메일 유효성 자동 검증). 기존 인플루언서 계정도 같은 이메일로 호출 시 자동 관리자 승격
  - **삭제 2택**: `remove_admin_role` (권한만 해제, 인플루언서 계정 유지) / `delete_admin_completely` (auth/influencers/applications/receipts cascade). 자기 자신 삭제 불가
- **메일 수신 설정**(`/admin#admin-accounts`): 각 행 「메일받기」 셀에 켜진 메일 종류 회색 칩 + 「설정」 버튼. 모달에서 메일 종류별 체크박스 일괄 on/off. `admin_email_subscriptions` 테이블 + `lookup_values(kind='admin_email_kind')` 카탈로그. super_admin 은 다른 관리자 설정도 편집, 그 외는 본인만. 신규 메일 종류 추가는 `lookup_values` 한 줄 추가만으로 가능
- **내 계정**: 이름/비밀번호 변경
- **에러 처리**: `friendlyError()` 한국어 메시지 + 에러 코드
- **상태 뱃지**: `getStatusBadgeKo()` 한국어 상태 표시

## Database Schema (Supabase)

### 캠페인·신청·결과물
- `campaigns` — 캠페인 정보. 핵심 컬럼:
  - 기본: `title`, `brand`, `brand_ko`, `product`, `product_ko`, `type`, `channel`, `channel_match`('or'|'and'), `category`, `reward`, `reward_note`, `slots`, `min_followers`, `status`, `view_count`, `img1~img8`
  - 일정: `recruit_start date NULL`(NULL 이면 인플 화면 "오늘 ~ 마감" 폴백), `deadline`, `purchase_start/end`(monitor), `visit_start/end`(visit), `submission_end`
  - 번들 스냅샷: `participation_set_id`/`participation_steps jsonb`, `caution_set_id`/`caution_items jsonb`, `ng_set_id`/`ng_items jsonb`
  - 채번: `campaign_no`(현행 계층 채번), `legacy_no`(콤마 누적), `brand_id` FK, `source_application_id` FK
  - `reward_note` 는 리워드 금액 외 추가 안내(지급 조건·정산 시점) 자유 텍스트
  - 홍보 메일 트리거: `first_active_at timestamptz NULL` — 캠페인이 처음 active 상태로 전환된 시각. `BEFORE UPDATE OF status` 트리거(`_record_first_active_at`)가 자동 기록(이후 불변). 캠페인 홍보 메일이 「어제 KST 신규 캠페인」 판별에 사용 (마이그레이션 140)
- `campaigns_yearly_counter`, `brand_seq_counter`(싱글톤), `brand_application_counter`, `application_campaign_counter`, `brand_external_campaign_counter` — 채번 카운터. SECURITY DEFINER 트리거 전용 (직접 UPDATE 금지)
- `numbering_legacy_map` — 신구 채번 양방향 매핑
- `applications` — 캠페인 신청. `user_id`, `campaign_id`, `message`, `address`, `status`(pending/approved/rejected/cancelled), `reviewed_by`, `reviewed_at`, `oriented_at`(OT 발송 체크 수동 토글), `reviewed_version`(낙관적 락), `caution_agreed_at`, `caution_snapshot jsonb`. 취소 보조 5종: `cancelled_at`, `cancel_reason`, `cancel_reason_code`, `cancel_phase CHECK(recruit|purchase|visit|post|other)`, `previous_status`. `(user_id, campaign_id)` partial unique index (cancelled 행 제외) → 같은 캠페인 재응모 가능
- `deliverables` — 결과물 통합. `kind`('receipt'|'review_image'|'post'), `status`, `receipt_url`/`purchase_date`/`purchase_amount`/`order_number`(receipt), `post_url`/`post_channel`/`post_submissions`(post), `reject_reason`, `reviewed_by`/`reviewed_at`, `version` 낙관적 락
- `deliverable_events` — 결과물 상태 변경 이력. `action`(submit/resubmit/approve/reject/revert), `from_status`, `to_status`. 트리거/RPC 만 INSERT
- `application_events` — 신청 status 변경 audit (운영자 액션 한정). `action`(approve|reject|revert_to_pending), `from_status`/`to_status`, `changed_by`/`changed_by_name`/`memo`. `trg_application_status_event AFTER UPDATE OF status` 트리거가 `record_application_status_event()` SECURITY DEFINER 함수 경유 자동 INSERT. 본인 취소(cancel_application RPC)와 재응모는 트리거 미경유. RLS SELECT `is_admin()` 만, INSERT 트리거만
- `receipt_edit_history` — 관리자 영수증 수정 이력 감사. `deliverable_id` FK CASCADE + `changed_by`/`changed_by_name` + 3종 prev/next 스냅샷(`order_number_prev/next`, `purchase_date_prev/next`, `purchase_amount_prev/next`) + `source CHECK('admin_edit')`. RLS SELECT `is_admin()`, INSERT 는 `update_receipt_admin` RPC 만
- `campaign_caution_history` — 캠페인 주의사항/참여방법/NG 변경 audit. `campaign_id` FK CASCADE + `changed_by`/`changed_by_name`/`changed_at` + caution/participation/ng 각 prev·next + `app_count_at_change` + `bypass_warning_ack`. RLS SELECT super_admin, INSERT 는 `record_caution_history()` RPC 만(campaign_admin 이상, `SET search_path=''`). 인덱스 `(campaign_id, changed_at DESC)`

### 광고주 신청(브랜드 서베이)
- `brand_applications` — `form_type`(reviewer|seeding), `brand_name`, `contact_name`, `phone`, `email`, `billing_email`, `products jsonb`, `total_jpy/total_qty`, `estimated_krw`, `final_quote_krw`, `quote_sent_at`, `quote_sent_url`, `orient_sheet_sent_at`(timestamptz), `orient_sheet_sent_url`, `paid_at`, `payment_flags jsonb`, `status` 10단계 파이프라인, `request_note`, `version` 낙관적 락, `legacy_no`. **익명 INSERT 는 `submit_brand_application()` RPC(SECURITY DEFINER, BYPASSRLS) 경유 필수** — 직접 INSERT 는 42501
- `brand_application_memos` — 신청 메모 (multi-entry). `application_id` FK CASCADE, `product_idx integer NOT NULL DEFAULT 0`, `memo`, `created_by`/`created_by_name`/`created_at`
- `brand_application_memo_reads` — 메모 본인 읽음 기록. (memo_id FK CASCADE, auth_id) PRIMARY KEY
- `brand_application_history` — 광고주 신청 변경 audit
- `brand_app_daily_counter` — 일자별(JST) 채번 카운터. SECURITY DEFINER 트리거 전용
- `companies` — 회사 마스터 (1개 회사 = N 개 brands, 4단 계층: 회사 > 브랜드 > 신청 > 캠페인). `name_ko`(NOT NULL)/`name_ja`/`name_en` + `name_normalized` UNIQUE NOT NULL(자동 정규화 트리거) + `business_no` + `address` + `homepage_url` + `contact_*` 3종 + `billing_email`/`billing_address`/`memo` + `status CHECK(active|archived)` + `total_brands` 자동 재계산. RLS SELECT `is_admin()`, CUD `is_campaign_admin()` 이상
- `brands` — 브랜드 마스터. `name`, `name_normalized`(자동 정규화), `brand_seq` UNIQUE, `company_id` FK ON DELETE SET NULL
- `get_brand_ops_overview(p_company_id uuid)` — 운영 현황 19컬럼 집계 RPC (`SECURITY DEFINER + SET search_path='' + is_admin()`)
- `get_brand_ops_detail(p_brand_id uuid)` — 브랜드 상세 jsonb 통합 RPC
- `link_campaign_to_application` / `unlink_campaign_from_application` — 캠페인↔신청 연결/해제 RPC (`is_campaign_admin()` 이상, advisory_xact_lock 2단)

### 인플루언서·관리자
- `influencers` — 인플루언서 프로필. `name`, SNS 계정+팔로워, 주소, `paypal_email`, `primary_sns`, `terms_agreed_at`, `privacy_agreed_at`, `marketing_opt_in` 등. 홍보 메일 PR 1 추가 컬럼: `unsubscribe_token uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE`(영구 1개 토큰, 메일 수신거부·클릭 추적 익명 호출 식별자), `marketing_unsubscribed_at timestamptz NULL`(수신거부 시각 감사 — 재구독 시 NULL 초기화). 기존 인플 1,398행 백필 완료 (마이그레이션 140)
- `admins` — 관리자 계정. `auth_id`, `email`, `name`, `role`(super_admin/campaign_admin/campaign_manager)
- `admin_email_subscriptions` — 관리자별 메일 수신 구독. `(admin_id, mail_kind)` UNIQUE. `mail_kind` 는 `lookup_values(kind='admin_email_kind')` code 참조 (시드 `brand_notify`/`application_cancel`/`application_received`). RLS SELECT 관리자 전체, CUD 본인 또는 super_admin. 헬퍼 `get_subscribed_admin_emails(p_mail_kind)`
- `admin_notices` — 관리자 공지. `category`(system_update/release/warning/general), `pin`(bool), `title`, `body_html`(Quill rich), `created_by`/`created_at`/`updated_at`, `status CHECK(draft|published)`, `published_at`/`published_by`/`published_by_name`. SELECT RLS 는 published OR `is_super_admin()` OR `created_by=auth.uid()` (draft 는 작성자/super 한정). XSS 방어는 저장+렌더 이중 sanitize
- `admin_notice_reads` — 관리자별 읽음 기록. `(admin_id, notice_id, read_at)` UNIQUE. `upsert_admin_notice_read` RPC. 미읽음 카운트 = published - reads(by admin)
- `influencer_flags` — 인플루언서 관리자 마킹 이력. `influencer_id`, `action`(verify/violation/blacklist/clear), `reasons text[]` (blacklist_reason ∪ violation_reason lookup), `memo`, `evidence_paths text[]`, `updated_at/by/by_name`. 위반 행만 UPDATE RLS

### 메일·기준 데이터·알림
- `lookup_values` — 캠페인 기준 데이터. `kind`(channel/category/content_type/ng_item/reject_reason/blacklist_reason/violation_reason/caution/admin_email_kind/cancel_reason), `code`, `name_ko`, `name_ja`, `sort_order`, `active`, `recruit_types[]`. channel 만 recruit_types 사용
- `participation_sets` — 참여방법 번들. `name_ko`/`ja`, `recruit_types[]`, `steps jsonb`, `sort_order`, `active`. `campaigns.participation_steps jsonb` + `participation_set_id` FK ON DELETE SET NULL 로 스냅샷·원본 참조
- `caution_sets` — 주의사항 번들. items 구조 `{text_ko, text_ja, link_url?, link_label_ko?, link_label_ja?, text_after_ko?, text_after_ja?}`. `campaigns.caution_items jsonb` + `caution_set_id` FK ON DELETE SET NULL. RLS SELECT 관리자 (인플은 campaigns 스냅샷 경유)
- `ng_sets` — NG 사항 번들. items 구조 `{html_ko, html_ja}` (DOMPurify, inline 서식만). `campaigns.ng_set_id` + `ng_items jsonb` 스냅샷. RLS SELECT `is_admin()`, CUD `is_campaign_admin()` 이상. 신청자 동의 시점 스냅샷 없음 (NG는 표시용 가이드라인)
- `notifications` — 인플루언서 알림. `kind`(deliverable_rejected/deliverable_changed/deliverable_approved), `ref_table`/`ref_id`, `read_at`. deliverables.status 전이 트리거로 자동 생성, 재제출 시 미읽음 알림 자동 dismiss
- `admin_daily_digest_runs` — 관리자 통합 다이제스트 발송 로그. `digest_date` UNIQUE(중복 호출 차단 + INSERT 선행 mutex) + `status CHECK(sent|skipped_no_data|failed)` + `sections_summary jsonb`(`{received, cancelled, submitted, reprocessed}`) + `recipients_count` + `error_message` + `run_at`. RLS SELECT `is_admin()`, INSERT 는 service_role 만 우회
- `influencer_daily_digest_runs` / `application_received_admin_digest_runs` — 메일 파이프라인 운영 로그. `digest_date` UNIQUE
- `deadline_reminder_email_sent` — 영수증/결과물 D-5·D-1 임박 메일 재발송 차단. UNIQUE 4-tuple `(influencer_id, campaign_id, kind, d_minus)`
- 캠페인 홍보 메일 4종(주 2회 다이제스트, 마이그레이션 139 — PR 1 인프라, Edge Function·cron은 PR 2~5):
  - `campaign_promo_digest_runs` — 다이제스트 run 로그. `digest_date` UNIQUE(중복 호출 차단 mutex) + `status CHECK(sent|partial|skipped_no_data|failed)` + `included_campaign_ids uuid[]` + `target_influencer_count`/`sent_count`/`skipped_count`/`failed_count` + `error_message` + `started_at timestamptz DEFAULT now()` + `finished_at timestamptz NULL`(마지막 배치 또는 즉시 종료 시점에만 기록 — chained 중간은 NULL 유지) + `triggered_by`(향후 운영자 수동 트리거 대비)
  - `campaign_promo_digest_sent` — 인플별 발송 결과. `(influencer_id, digest_date)` UNIQUE 로 1통/cron 보장. `status CHECK(sent|skipped|failed)` + `skip_reason`(opt_out/no_email/no_matched_campaign/already_sent) + `included_campaign_ids uuid[]`
  - `campaign_promo_exposure` — 캠페인×인플×종류별 노출 기록. `(campaign_id, influencer_id, kind)` UNIQUE 로 인플당 캠페인당 최대 2회 보장(`kind CHECK(new|deadline_d1)`). 「관심 없는 캠페인 매일 노출」 방지
  - `campaign_promo_email_clicks` — CTA 클릭 추적. `(campaign_id, influencer_id)` UNIQUE + `click_count`/`first_clicked_at`/`last_clicked_at`. 클릭된 페어는 다음 다이제스트 매칭에서 자동 제외
  - 4종 모두 RLS SELECT `is_admin()` 한정, INSERT/UPDATE/DELETE 정책 없음 → service_role만 우회
  - 헬퍼 함수 4종(마이그레이션 141): `_meets_min_followers`(internal, PUBLIC+anon REVOKE), `get_promo_digest_targets(date)`(authenticated 한정), `mark_promo_digest_sent(...)`(authenticated 한정), `track_promo_click(uuid, uuid)`(익명 anon GRANT)
  - `influencers.unsubscribe_by_token(uuid)` RPC(익명 anon GRANT, 메일 1-click 수신거부) + `resubscribe_marketing()`(authenticated 본인만, 마이페이지 재구독, 마이그레이션 140)
- 헬퍼 함수 `_yesterday_kst_window()` STABLE — 어제 KST 윈도우 + 오늘 KST 날짜 반환 (SQL Editor 디버깅용)

### RLS·인증·세션
- 정책 요약: 캠페인 SELECT 공개, 나머지는 본인 데이터 or 관리자만 접근
- `is_admin()` / `is_super_admin()` / `is_campaign_admin()` 함수: admins 테이블에서 auth.uid() 조회 (search_path 고정)
- 트리거: auth.users 생성 시 influencers 레코드 자동 생성
- 세션 만료 대응: `retryWithRefresh()` 로 RLS/JWT 에러 시 세션 갱신 후 1회 재시도

## Test Accounts
- 관리자: admin@kemo.jp / admin1234
- 테스트 인플루언서: sakura.test@reverb.jp, yui.test@reverb.jp, haruka.test@reverb.jp (비밀번호: test1234)

## Dev Workflow
- 개발: dev/ 폴더에서 수정 → 브라우저에서 dev/index.html 열어서 확인
- 배포: `cd dev && bash build.sh` → 루트 index.html 자동 업데이트
- 수정할 파일 찾기: 파일명이 기능과 일치 (캠페인=campaign, 로그인=auth 등)
- DB API: `dev/lib/storage.js` 에 모든 DB 함수 집중 (fetchCampaigns, upsertInfluencer 등)
- 세션 관리: onAuthStateChange 로 SIGNED_IN/TOKEN_REFRESHED/SIGNED_OUT/SESSION_EXPIRED 처리 (인플루언서+관리자 양쪽)
- URL 정제: `cleanUrl()` 로 마크다운 링크 형식 자동 변환 (product_url 등)
- 페이지 전환: 관리자/인플루언서 화면 같은 탭에서 이동 (새 탭 열기 금지)
- 깜빡임 방지: visibility:hidden cloak 기법 (인플루언서+관리자 양쪽)
- 마이페이지 서브해시: `#mypage-applications` 등 URL 해시로 서브페이지 복원

## Conventions
- 인플루언서 페이지 UI 텍스트: 일본어
- 관리자 페이지 UI 텍스트: 한국어
- 코드 주석: 한국어 (일본어 금지)
- 날짜 포맷: ja-JP
- `lang="ja"`

## Rules
- 관리자 페이지는 반드시 PC 레이아웃 유지 (모바일 쉘 적용 금지)
- 인플루언서 페이지만 모바일 전용 (480px)
- db 참조 시 항상 `db?.from()` 사용 (null-safe)
- `.single()` 대신 `.maybeSingle()` 사용
- localStorage 저장 시 이미지 base64 는 별도 키로 분리 (용량 초과 방지)
- 캠페인 삭제 시 관련 applications 도 함께 삭제 (cascading)
- 이미지 업로드는 Supabase Storage (`campaign-images` 버킷) 사용
- 비밀번호 재설정 시 Supabase Redirect URL 설정 필수: Authentication → URL Configuration → Redirect URLs 에 양 도메인 등록
- 아이콘은 Material Icons 사용 (이모지 사용 금지), `translate="no"` 속성 필수
- 하드코딩 DOM 인덱스 금지 (querySelector 등에서 `:nth-child` 인덱스 직접 사용 금지)
- 이미지 썸네일 표시는 `imgThumb(url, width, quality)` 헬퍼 사용 (Supabase Pro 플랜 transform), `data-orig` + `onerror` 로 원본 URL 폴백 필수
- 채널 비교는 항상 `split(',')` 후 `includes()` 사용 (단일 `===` 비교 금지 — 멀티채널 캠페인 누락 위험)
- 최소 팔로워수 정책: **primary_channel 단일 검증** (캠페인의 `primary_channel` 팔로워수만 `min_followers` 와 비교, 없으면 채널 리스트 첫 번째로 폴백. `recruit_type='monitor'` 는 팔로워 체크 건너뜀) — 상세 `docs/FEATURE_SPEC.md` §10, 구현 `dev/js/application.js`
- **Sales(광고주) 서브도메인 규칙**: `sales.globalreverb.com` / `sales-dev.globalreverb.com` 페이지 UI 는 한국어, `<meta name="robots" content="noindex,nofollow">` 유지(검색 노출 차단). 루트에 choice landing + `/reviewer`·`/seeding` 경로는 Vercel `cleanUrls` 로 HTML 확장자 제거. 파일 업로드 기능 없음 — 텍스트 입력만
- **익명 폼 INSERT 패턴**: anon 이 쓰는 Supabase 테이블은 `.insert().select()` 대신 **SECURITY DEFINER RPC** 로 감쌀 것 (RLS WITH CHECK + RETURNING SELECT 권한 충돌로 42501 발생 사례)
- **관리자 리스트 IntersectionObserver lazy-load**: 8개 목록 페인(campaigns/applications/deliverables/camp-applicants/influencers/lookups/admin-accounts/brand-applications) 모두 sentinel 기반 점진 렌더. 필터·검색·정렬 변경 시 sentinel 리셋 필수. `renderAppCampList` 는 campaigns/applications/influencers 결과 in-memory 캐시 공유
- **PostgREST 1000-row cap 대응**: 대시보드 집계용 fetch(`fetchInfluencers`/`fetchApplications`/`fetchDeliverables` 등)는 반드시 `range(from, from+999)` pagination loop 로 전건 조회. 단일 `.from().select()` 호출은 1000건에서 잘림

## Mobile Layout Rules
- `#appShell` 은 `position:fixed` + `top:0`/`bottom:0` (body 스크롤 차단, 뷰포트 고정)
- html, body 에 `height:100%` + `overflow:hidden` 유지
- 페이지 콘텐츠 스크롤은 `.page.active` 내부에서만 (`flex:1` + `overflow-y:auto`)
- GNB 는 `flex-shrink:0` 으로 고정, 페이지가 나머지 공간 차지 (바텀탭 제거됨 — 햄버거 메뉴로 대체)
- 모바일 키보드 대응: visualViewport API 로 `appShell` 높이 동적 조절
- input/textarea/select 의 `font-size` 는 반드시 16px 이상 (모바일 자동 확대 방지)
- `100vh`/`100dvh` 대신 `position:fixed` + `top:0`/`bottom:0` 사용 (키보드 열림/닫힘 안정성)
- 캠페인 상세 URL 은 `#detail-{id}` 형식 (새로고침 시 복원 가능)

---

## 변경 이력
이력성 메타데이터(마이그레이션 번호·PR 번호·deprecated 메모·과거 변경 사항)는 [`docs/CLAUDE-ARCHIVE.md`](docs/CLAUDE-ARCHIVE.md) 참조.
