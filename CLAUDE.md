# REVERB JP — 인플루언서 체험단 플랫폼

## Overview
일본 시장 대상 인플루언서 체험단(리뷰어/기프팅/방문형) 모집 플랫폼.
브랜드가 캠페인을 등록하고, 인플루언서가 신청하는 구조.

## Tech Stack
- Language: HTML/CSS/JavaScript (vanilla, 프레임워크 없음)
- Backend: Supabase (Auth + Database + Storage) + localStorage 폴백
- Deployment: Vercel (이전: Netlify)
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
- **도메인 기반 자동 분기**: `dev/lib/supabase.js`의 `resolveSupabaseEnv()`가 `location.hostname` 을 판별
  - `globalreverb.com`, `www.globalreverb.com` → 운영서버 Supabase
  - 그 외 (dev.globalreverb.com, localhost 등) → 개발서버 Supabase
- Supabase URL/Key는 `SUPABASE_ENVS` 객체에서만 관리 (다른 파일 하드코딩 금지)
- 관리자 페이지 헤더에 개발서버에서만 주황색 `STAGING` 배지 + `[DEV]` 탭 제목/파비콘 표시
- 운영 배포는 반드시 개발서버 검증 후 main merge
- Supabase Client 옵션: `flowType: 'pkce'`, `detectSessionInUrl: true` (비밀번호 재설정 안정성)

## Email / SMTP
- 양 서버 모두 **Brevo Custom SMTP** 사용 (`smtp-relay.brevo.com:587`)
- **Brevo 플랜: Starter 20,000 emails/월** (2026-04-16 Free 300/일→Starter로 업그레이드, 갱신일 매월 16일, Monthly $29). Marketing+Transactional 공용 쿼터, 일일 한도 없음
- 발신: `noreply@globalreverb.com`, 발신명: 운영 `REVERB JP` / 개발 `REVERB JP [DEV]`
- 발신 도메인 DNS 인증 완료 (SPF/DKIM/DMARC, cafe24 DNS 관리)
- **광고주 신청 접수 알림**: Supabase Edge Function `notify-brand-application` 이 `brand_applications` INSERT 직후 호출 → `admins.receive_brand_notify=true` 계정 + env `NOTIFY_ADMIN_EMAILS` 외부 이메일 합산(중복 제거) 대상에게 Brevo SMTP 경유로 접수 알림 발송. DB 조회 실패 시 env 만 폴백
- Auth URL Configuration:
  - 운영: Site URL `https://globalreverb.com` + Redirect `https://globalreverb.com/**`, `https://www.globalreverb.com/**`
  - 개발: Site URL `https://dev.globalreverb.com` + Redirect `https://dev.globalreverb.com/**`
- Auth Rate Limits (대시보드 → Authentication → Rate Limits):
  - 운영: `Rate limit for sending emails` = **100 emails/h** (2026-04-16 30→100 상향, 가입+초대+재설정 메일 공용 한도)
  - 개발: 기본값 30/h 유지 (Confirm email OFF라 가입 메일 없음. 초대/재설정만 사용, 트래픽 적어 충분)
  - 한도 소진 시 `429 email rate limit exceeded` 응답. Logs & Analytics → Auth에서 확인

## i18n (개발서버 한정)
- 인플루언서 페이지 KO/JA 토글 (마이페이지 메뉴)
- 키-값: `dev/lib/i18n/{ja,ko}.js`, 런타임: `dev/lib/i18n/index.js`
- HTML: `data-i18n="key"` (textContent), `data-i18n-html="key"` (innerHTML, `<br>` 허용)
- JS 동적: `t('key')` 헬퍼
- 기본값 `ja`, navigator.language 자동 감지 사용 안 함
- 운영서버 배포 전 (테스터 검증 완료 후 결정)
- Phase 1 완료 범위: 마이페이지, 인증(로그인/가입/재설정), GNB/홈, 캠페인 목록 탭
- Phase 2 완료 범위: 캠페인 상세 라벨(모집타입/기간/인원/마감일), 신청 모달(로그인유도/사유/주소/PR동의), 활동관리(영수증/게시URL/마감일/상태배지/재제출/비승인배너), 알림(헤더/전체읽음), DB 에러 메시지 로케일 대응(`friendlyErrorJa` → ko/ja 분기)

## 내부 문서 (개발서버 한정)
- `docs/service-flow.html` — 전체 서비스 플로우차트
- `docs/flowchart-i18n.html` — i18n 다국어 흐름도
- 접속: https://dev.globalreverb.com/docs/service-flow.html, https://dev.globalreverb.com/docs/flowchart-i18n.html
- **운영서버(main)에 머지하지 않음** — 내부 직원용 참고 자료이므로 개발서버에서만 유지
- 내용 변경 시 dev 브랜치에만 커밋·푸시

## Architecture
- 인플루언서 앱: dev/index.html (모바일 480px, GNB + 우측 슬라이드 햄버거 메뉴)
- 관리자 앱: dev/admin/index.html (PC 전체폭, 별도 페이지, **2단 고정 레이아웃** — 사이드바/메인 독립 스크롤, 상단 GNB 없음)
- **광고주 신청 앱(sales)**: `sales/{index,reviewer,seeding}.html` — 별도 Vercel 프로젝트 `reverb-sales`(Root Directory=`sales/`), `sales.globalreverb.com` / `sales-dev.globalreverb.com` 서브도메인, 루트 랜딩에서 `/reviewer`(Qoo10 리뷰어 모집) 또는 `/seeding`(나노 인플루언서 시딩) 폼 선택. anon으로 `brand_applications` INSERT + `brand-docs` 비공개 버킷에 사업자등록증 업로드(reviewer 전용). Vercel `cleanUrls`+catch-all rewrite로 `/reviewer` → `reviewer.html` 라우팅
- 배포용: 루트 index.html (build.sh로 생성)
- 개발 폴더 구조:
  - dev/js/ — app, ui, campaign, application, auth, mypage, admin
  - dev/css/ — base, components, campaign, auth, mypage, admin
  - dev/lib/ — supabase(설정), shared(전역변수), storage(DB/Storage API)
  - dev/build.sh — dev/ → 루트 index.html 빌드
  - sales/ — 광고주 신청 폼 (빌드 없이 정적 파일 그대로 배포)
  - supabase/functions/notify-brand-application/ — 광고주 신청 알림 Edge Function
- Supabase 미연결 시 localStorage로 동작 (DEMO_MODE)

## Features — 인플루언서 (모바일)
- 회원가입: 1단계 폼 (이름 한자/가나 + 이메일 + 비밀번호), 추가정보는 마이페이지에서 입력
- 로그인/로그아웃: 이메일+비밀번호, 세션 복원, 관리자 로그인 시 admin 페이지 자동 오픈
- 비밀번호 재설정: 이메일 입력 → Supabase 재설정 메일 발송 → 앱 내 새 비밀번호 설정 (#page-forgot, #page-reset-pw)
- GNB: 비로그인 시 Log In/Sign Up 버튼, 로그인 시 버튼 없음 (Admin만 관리자용), 홈/캠페인/마이페이지/알림/로그아웃은 우측 햄버거 메뉴에서 접근
- 캠페인 목록: 채널필터(동적 생성), 모집유형 필터(리뷰어/기프팅/방문형)
- 캠페인 카드 배지 레이아웃:
  - 이미지 위 좌상단: `NEW` (7일 이내 등록)
  - 제목 위: `締切間近`(deadline < 5일 OR 잔여 slots ≤ 30%) + `{applied}/{slots}名` (진행중 항상 표시)
  - 콘텐츠 종류 아래: 모집타입 + `募集中` pill
  - 이미지 좌하단: 첫 채널 + `+N` (여러 채널 보유 시)
- 캠페인 상세 채널 렌더링: 채널 pill 사이에 `or` 또는 `&` 구분자 (캠페인별 `channel_match` 기준). 자격 검증은 `primary_channel` 단일 기준 — 표시만 다름
- 캠페인 목록 노출: active + scheduled + closed(게시기한 남은 경우, 募集締切 오버레이)
- 캠페인 상세: 이미지 캐러셀(최대9장), 상품정보, 모집조건, 참가방법(3단계), 가이드라인, NG사항, LINE/Instagram CTA, 조회수 자동 카운트, closed 시 신청버튼 비활성(募集締切)
- 캠페인 신청: 이메일 인증 필수, 필수정보 사전체크(채널별 SNS/zip+prefecture+city+phone/PayPal 이메일) → 동기메시지 + 배송지 + PR태그 동의, 중복신청 방지, 최소 팔로워수 미달 시 알럿 차단
- 회원가입 이메일 확인: **운영서버 한정** Supabase Confirm sign-up 활성, 가입 후 확인 메일 안내 화면 표시, 미확인 시 로그인/신청 차단. **개발서버는 Confirm email OFF** (테스트 계정 즉시 로그인 가능). auth.js는 `data.session` 유무로 자동 분기
- 마이페이지: 리스트 → 상세 페이지 네비게이션 (탭 방식 아님), 메뉴: 応募履歴/基本情報/SNSアカウント/配送先/PayPal/パスワード変更/ログアウト, 대표SNS 선택 가능, 필수 미입력 항목 "未登録" 배지 + 붉은 테두리 경고
- GNB 햄버거 메뉴: 상단 우측 ☰ 버튼에 미읽음 알림 배지(9+), 클릭 시 우측 슬라이드 패널(홈/캠페인/마이페이지/알림/로그아웃). 비로그인은 로그인/회원가입, 인증 페이지에선 햄버거 숨김, 관리자는 알림 항목 없음 (이전 바텀탭 대체, 키보드 간섭 제거)
- 알림 모달: 햄버거 메뉴 → 알림 클릭 시 슬라이드업 풀스크린 모달. deliverables status 트리거로 생성된 rejected/changed/approved 알림 3종. 항목 클릭 시 읽음 처리 + 해당 활동관리로 이동. "모두 읽음" 버튼 제공
- 활동관리: 승인된 캠페인에서 결과물 제출. recruit_type 분기 — monitor=영수증(이미지+구매일+금액, receipts 테이블, dual-write 트리거로 deliverables 동기화), gifting/visit=SNS 게시물 URL(자동 채널 판별 + 실패 시 수동 드롭다운, deliverables 직접 INSERT + submit_deliverable RPC). 반려된 결과물은 상단 빨간 배너에 사유 표시, 재제출 시 pending 복귀(동일 URL은 post_submissions 배열에 날짜 누적). submission_end(폴백: post_deadline) 경과 시 폼 비활성
- 응모 차단: 리뷰어(monitor) 캠페인은 applied_count >= slots일 때 신규 응모 차단 (기프팅·방문형은 초과 응모 허용)
- 응모이력: 상태별 탭 필터(전체/심사중/승인/비승인), 캠페인상태/정렬 필터, 승인 캠페인 클릭→활동관리, 기타→캠페인 상세
- 홈 하단 푸터: 株式会社ジェイファン 회사 정보 + 会社紹介/利用規約/個人情報処理方針 링크 (슬라이드업 모달), Instagram·X SNS 아이콘
- 성능 최적화: preconnect(Supabase/Fonts/jsDelivr), 캠페인 카드/마이페이지 썸네일 lazy loading + decoding=async, Supabase Storage 이미지 transform(`/render/image/public/?width=&quality=`)으로 썸네일 용량 축소, 이미지 로드 실패 시 원본 URL 자동 폴백

## Features — 관리자 (PC)
- 사이드바: Material Icons, 접기/펼치기 토글 (햄버거 버튼), data-pane 속성 기반 라우팅, 신규등록 메뉴 제거, pending 배지 항상 표시
- 페이지 새로고침: visibility:hidden cloak 기법 (깜빡임 완전 방지), 서브패널 새로고침 시 부모 패널로 리다이렉트
- 대시보드: KPI 카드(캠페인수/인플루언서수/신청수/승인수), 상태별/채널별 캠페인 분포 카드(채널 복수 선택 캠페인은 각 채널에 중복 집계), 회원가입 추이 차트(Chart.js, 7일/30일/전체 필터), 오늘/이번주 가입 KPI, 프로필 완성률(SNS별/배송지/PayPal), 최근 신청 테이블
- 로딩 UX: 테이블/대시보드 KPI/차트 영역에 인라인 스피너 (전체화면 오버레이 제거)
- 캠페인 관리: CRUD + 복제 + 삭제(확인모달) + 순서변경 모드(버튼 토글)
- 캠페인 등록/편집 폼: 4개 섹션 그룹핑 (기본정보/제품정보/모집조건/콘텐츠가이드), 제품정보 2열(이미지+상세), 모집타입 라디오버튼 UI, **채널은 복수 선택 체크박스**(Instagram/X/Qoo10/TikTok/YouTube · 콤마 구분 저장 `"instagram,x"`)
- **채널 매칭 표시 (channel_match)**: 채널 2개 이상 선택 시 `or`/`&` 라디오 노출 → `campaigns.channel_match` (text, default 'or', CHECK(or|and))에 저장. 인플루언서 상세 pill 구분자로 사용. 자격 검증 로직: primary_channel 단일 기준(Rules 최소 팔로워수 정책 참조)
- **콘텐츠 가이드 4개 필드(설명/어필 포인트/촬영 가이드/NG사항) 리치 텍스트 에디터** (Quill v2) — 볼드/이탤릭/리스트/링크/헤더/인용 지원. Notion 복사·붙여넣기로 서식 유지. 이미지 태그는 저장 시 제거(base64 폭증 방지). 저장 포맷은 sanitize된 HTML 문자열, 기존 `text` 컬럼 그대로 사용. 평문(legacy) 데이터는 렌더 시 자동 `<br>` 변환으로 하위호환. XSS 방어: DOMPurify 저장+렌더 이중 sanitize. 공통 헬퍼는 `dev/lib/shared.js`의 `sanitizeRich/richHtml/renderRich`
- 캠페인 목록: 썸네일+이미지수 표시, 상태/타입 드롭다운 필터, 검색(캠페인명+브랜드), 헤더 정렬(조회/신청/등록일/수정일 ▲▼), D-day 라벨(게시마감/모집마감), 타입 라벨 통일([타입] 제목 형식), 승인수/모집수 표시 + 대기 배지
- 캠페인 미리보기: 캠페인 제목 클릭 시 모바일 크기 프리뷰 모달 (편집 버튼 포함)
- 캠페인 상태: draft(준비) → scheduled(모집예정) → active(모집중) → paused(일시정지) → closed(종료), 드롭다운으로 변경
- 캠페인 자동 종료: deadline 경과 시 active → closed 자동 변경 (클라이언트 체크)
- 마감일 검증: post_deadline >= deadline 필수, 인라인 경고 + 저장 차단
- 마감일 경과 active/scheduled 차단: deadline 지난 캠페인은 모집중/모집예정 상태로 저장/변경 불가 (편집, 드롭다운 모두)
- 모집인원 초과 승인 차단: 승인 수가 slots에 도달하면 알럿 모달로 차단
- 조회수: campaigns.view_count 컬럼, 캠페인 상세 열 때 +1, 관리자 목록에 표시
- 이미지 관리: 드래그앤드롭 업로드, 크롭, 미리보기, Supabase Storage 저장
- 신청 관리: 테이블 UI (캠페인 썸네일, 타입/상태/검색 필터, 상태 정렬), 인플루언서 상세 모달, 모집인원/빈자리 표시
- 신청 처리: reviewed_by, reviewed_at 기록, 되돌리기(pending 복귀) 기능, 빈자리 없으면 승인버튼 비활성(회색)
- 결과물 관리(`/admin#deliverables`): 영수증/게시물 URL 통합 검수 페인. 필터(상태 기본 pending·캠페인·타입·인플루언서 검색) + 오래된 순 정렬. 상세 모달에 이력 타임라인 + 승인/반려/되돌리기. 반려 사유 템플릿(PR태그 누락 등 6종) + 자유입력 혼합. 낙관적 락(`version`) 기반 동시 처리 충돌 엄격 차단 — 후순위는 "이미 처리됨" 토스트
- 캠페인 진행현황(캠페인 → 신청자 보기): 기본 신청자 테이블에 OT 발송 체크박스(gifting/visit 승인 건만 활성, 해제 시 확인 모달) + 결과물 상태 요약(승인/검수대기/반려 건수 + 최신 상세 모달 링크) 컬럼 추가. 심사·OT·검수를 한 화면에서 처리
- 해시태그/멘션: 태그 입력 UI (콤마 구분, 라벨+삭제, #/@ 입력 차단)
- 에러 처리: friendlyError() 한국어 에러 메시지 + 에러 코드 표시
- 상태 뱃지: getStatusBadgeKo() 한국어 상태 표시
- 인플루언서 관리: 채널별 필터, 상세 프로필 조회
- 관리자 계정: 3단계 권한 (super_admin > campaign_admin > campaign_manager)
- 관리자 추가: **초대 방식** — super_admin이 이메일+이름+역할 입력 → `invite_admin()` RPC가 auth.users + identities 생성 → 클라이언트가 즉시 `resetPasswordForEmail()` 호출 → 받은 사람이 메일 링크로 직접 비밀번호 설정. 이메일 유효성 자동 검증됨.
- 기존 인플루언서 계정도 같은 이메일로 `invite_admin` 호출 시 자동으로 관리자 승격 (기존 프로필 유지)
- 관리자 삭제 2택: **권한만 해제**(`remove_admin_role`) — 인플루언서 계정 유지 / **완전 삭제**(`delete_admin_completely`) — auth/influencers/applications/receipts 모두 cascade 삭제. 자기 자신 삭제 불가.
- `create_admin()` 함수는 **deprecated** (migration 032). `invite_admin()` 사용.
- 내 계정: 이름/비밀번호 변경
- 기준 데이터 관리(`/admin#lookups`): 채널/카테고리/콘텐츠 종류/NG 사항/참여방법을 한국어·일본어 두 언어로 관리 (campaign_admin 이상). 각 항목 활성/비활성 토글, 순서 변경 모드, 사용 중이면 hard delete 차단(soft delete만). 채널은 모집 타입(monitor/gifting/visit) 다중 지정. code는 자동 생성·UI 비공개
- **참여방법 번들**(`participation_sets`): 캠페인 참여 단계 묶음(1~6단계, 각 단계 title/desc ko·ja) 관리. 모집 타입(recruit_types[]) 태깅으로 캠페인 폼에서 필터링. 캠페인 저장 시 **스냅샷 복사**(`campaigns.participation_steps` jsonb) — 번들 수정해도 기존 캠페인 영향 없음. 캠페인 폼에서 인라인 개별 수정 + "번들 다시 불러오기" 지원. hard delete는 FK `ON DELETE SET NULL`로 스냅샷 격리
- **광고주 신청 관리**(`/admin#brand-applications`): 영업팀이 비공개 URL(`sales.globalreverb.com/reviewer`, `/seeding`)로 받은 광고주 신청을 검수·견적 확정·상태 관리. 모든 관리자 접근 가능(`is_admin()`). 리스트 필터(폼타입/상태/기간/검색, multi-filter 스타일로 타 페인과 동일) + pending(new) 배지 + 상세 모달(제품 테이블·사업자등록증 signed URL 다운로드·final_quote_krw 수동 입력·quote_sent_at 체크·admin_memo·낙관적 락 version). 상태 전이 new→reviewing→quoted→paid→done/rejected + "되돌리기"(new 복귀). 클라이언트 URL 스킴은 http/https 화이트리스트만 href로 렌더
- **설문 메일받기 토글**(`/admin#admin-accounts`): 관리자 계정 리스트 각 행의 토글로 `admins.receive_brand_notify` on/off. 광고주 신청 접수 시 Edge Function `notify-brand-application` 이 참조해 알림 메일 발송 대상을 결정. env `NOTIFY_ADMIN_EMAILS` 에 지정된 외부 이메일과 합산(중복 제거). DB 조회 실패 시 env만 폴백 사용

## Database Schema (Supabase)
- `campaigns` — 캠페인 정보 (title, brand, product, type, channel, channel_match('or'|'and'), category, reward, reward_note, slots, min_followers, status, view_count, img1~img8, participation_set_id, participation_steps, deadline, post_deadline, purchase_start/end (monitor), visit_start/end (visit), submission_end 등). `reward_note`는 리워드 금액 외 추가 안내(지급 조건·정산 시점) 자유 텍스트, 인플루언서 상세 리워드 영역에 노출
- `deliverables` — 결과물 통합 테이블 (kind: 'receipt'|'post', status, receipt_url/purchase_date/purchase_amount(receipt), post_url/post_channel/post_submissions(post), reject_reason, reviewed_by/at, version). receipts와 dual-write 동기화 중 (Stage 7에서 receipts DROP 예정)
- `deliverable_events` — 결과물 상태 변경 이력 (action: submit/resubmit/approve/reject/revert, from_status, to_status). 트리거/RPC만 INSERT
- `notifications` — 인플루언서 알림 (kind: deliverable_rejected/deliverable_changed/deliverable_approved, ref_table/ref_id, read_at). deliverables.status 전이 트리거로 자동 생성, 재제출 시 미읽음 알림 자동 dismiss
- `influencers` — 인플루언서 프로필 (name, SNS계정+팔로워, 주소, paypal_email, primary_sns, terms_agreed_at, privacy_agreed_at, marketing_opt_in 등) — bank_* 컬럼은 deprecated (유지, 미사용)
- `applications` — 캠페인 신청 (user_id, campaign_id, message, address, status, reviewed_by, reviewed_at, oriented_at (OT 발송 체크 수동 토글), reviewed_version (낙관적 락))
- `admins` — 관리자 계정 (auth_id, email, name, role: super_admin/campaign_admin/campaign_manager, receive_brand_notify: 광고주 신청 접수 알림 메일 수신 여부)
- `receipts` — 구매 영수증 (application_id, user_id, campaign_id, receipt_url, purchase_date, purchase_amount)
- `lookup_values` — 캠페인 기준 데이터 (kind: channel/category/content_type/ng_item, code, name_ko, name_ja, sort_order, active, recruit_types[]) — channel만 recruit_types 사용
- `participation_sets` — 참여방법 번들 (name_ko/ja, recruit_types[], steps jsonb, sort_order, active). `campaigns.participation_steps jsonb` + `campaigns.participation_set_id uuid FK ON DELETE SET NULL` 로 스냅샷 저장·원본 참조
- `brand_applications` — 광고주(브랜드) 신청 폼 제출 데이터 (form_type: reviewer|seeding, brand_name, contact_name, phone, email, billing_email, products jsonb, total_jpy/total_qty, estimated_krw, final_quote_krw, quote_sent_at, business_license_path, status: new→reviewing→quoted→paid→done/rejected, admin_memo, version 낙관적 락). 서버 트리거가 `JFUN-Q|N-YYYYMMDD-NNN` 채번 + products 재계산. anon INSERT 허용, 관리자만 SELECT/UPDATE/DELETE
- `brand_app_daily_counter` — 일자별(JST) 채번 카운터. SECURITY DEFINER 트리거 전용 (직접 접근 차단)
- RLS 정책: 캠페인 SELECT 공개, 나머지는 본인 데이터 or 관리자만 접근
- `is_admin()` / `is_super_admin()` / `is_campaign_admin()` 함수: admins 테이블에서 auth.uid() 조회 (search_path 고정)
- 트리거: auth.users 생성 시 influencers 레코드 자동 생성
- 세션 만료 대응: retryWithRefresh()로 RLS/JWT 에러 시 세션 갱신 후 1회 재시도

## Test Accounts
- 관리자: admin@kemo.jp / admin1234
- 테스트 인플루언서: sakura.test@reverb.jp, yui.test@reverb.jp, haruka.test@reverb.jp (비밀번호: test1234)

## Dev Workflow
- 개발: dev/ 폴더에서 수정 → 브라우저에서 dev/index.html 열어서 확인
- 배포: `cd dev && bash build.sh` → 루트 index.html 자동 업데이트
- 수정할 파일 찾기: 파일명이 기능과 일치 (캠페인=campaign, 로그인=auth 등)
- DB API: dev/lib/storage.js에 모든 DB 함수 집중 (fetchCampaigns, upsertInfluencer 등)
- 세션 관리: onAuthStateChange로 SIGNED_IN/TOKEN_REFRESHED/SIGNED_OUT/SESSION_EXPIRED 처리 (인플루언서+관리자 양쪽)
- URL 정제: cleanUrl()로 마크다운 링크 형식 자동 변환 (product_url 등)
- 페이지 전환: 관리자/인플루언서 화면 같은 탭에서 이동 (새 탭 열기 금지)
- 깜빡임 방지: visibility:hidden cloak 기법 (인플루언서+관리자 양쪽)
- 마이페이지 서브해시: #mypage-applications 등 URL 해시로 서브페이지 복원

## Conventions
- 인플루언서 페이지 UI 텍스트: 일본어
- 관리자 페이지 UI 텍스트: 한국어
- 코드 주석: 한국어 (일본어 금지)
- 날짜 포맷: ja-JP
- lang="ja"

## Rules
- 관리자 페이지는 반드시 PC 레이아웃 유지 (모바일 쉘 적용 금지)
- 인플루언서 페이지만 모바일 전용 (480px)
- db 참조 시 항상 db?.from() 사용 (null-safe)
- .single() 대신 .maybeSingle() 사용
- localStorage 저장 시 이미지 base64는 별도 키로 분리 (용량 초과 방지)
- 캠페인 삭제 시 관련 applications도 함께 삭제 (cascading)
- 이미지 업로드는 Supabase Storage (campaign-images 버킷) 사용
- 비밀번호 재설정 시 Supabase Redirect URL 설정 필수: Authentication → URL Configuration → Redirect URLs에 https://globalreverb.com, https://globalreverb.com/**, https://www.globalreverb.com 등록 (Site URL도 https://globalreverb.com)
- 아이콘은 Material Icons 사용 (이모지 사용 금지), translate="no" 속성 필수
- 하드코딩 DOM 인덱스 금지 (querySelector 등에서 :nth-child 인덱스 직접 사용 금지)
- 이미지 썸네일 표시는 `imgThumb(url, width, quality)` 헬퍼 사용 (Supabase Pro 플랜 transform), `data-orig` + `onerror`로 원본 URL 폴백 필수
- 채널 비교는 항상 `split(',')` 후 `includes()` 사용 (단일 `===` 비교 금지 — 멀티채널 캠페인 누락 위험)
- 최소 팔로워수 정책: **primary_channel 단일 검증** (캠페인의 `primary_channel` 팔로워수만 `min_followers`와 비교, 없으면 채널 리스트 첫 번째로 폴백. `recruit_type='monitor'`는 팔로워 체크 건너뜀) — 상세는 `docs/FEATURE_SPEC.md` §10, 구현은 `dev/js/application.js`
- **Sales(광고주) 서브도메인 규칙**: `sales.globalreverb.com` / `sales-dev.globalreverb.com` 페이지 UI는 한국어, `<meta name="robots" content="noindex,nofollow">` 유지(검색 노출 차단). 사업자등록증 업로드는 `brand-docs` **비공개 버킷**(관리자만 signed URL로 열람). 루트에 choice landing + `/reviewer`·`/seeding` 경로는 Vercel `cleanUrls`로 HTML 확장자 제거

## Mobile Layout Rules
- #appShell은 position:fixed + top:0/bottom:0 (body 스크롤 차단, 뷰포트 고정)
- html,body에 height:100% + overflow:hidden 유지
- 페이지 콘텐츠 스크롤은 .page.active 내부에서만 (flex:1 + overflow-y:auto)
- GNB는 flex-shrink:0으로 고정, 페이지가 나머지 공간 차지 (바텀탭 제거됨 — 햄버거 메뉴로 대체)
- 모바일 키보드 대응: visualViewport API로 appShell 높이 동적 조절
- input/textarea/select의 font-size는 반드시 16px 이상 (모바일 자동 확대 방지)
- 100vh/100dvh 대신 position:fixed + top:0/bottom:0 사용 (키보드 열림/닫힘 안정성)
- 캠페인 상세 URL은 #detail-{id} 형식 (새로고침 시 복원 가능)
