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
  - 🔴 **supabase-js 는 CDN 에서 `@2.116.0/dist/umd/supabase.js` 로 버전을 고정**(9개 HTML — 인플·관리자·`admin-setpw`·`event-scan`·`report`·**브랜드(`dev/brand/index.html`)**·sales 3종). `@2` 로 두면 배포 없이 라이브러리가 바뀐다. 올릴 때는 **아홉 줄을 같은 문자열로** 함께 올린다

## Key URLs
- 운영 (인플루언서): https://globalreverb.com
- 운영 (관리자): https://globalreverb.com/admin/
- 운영 (광고주 신청 폼): https://sales.globalreverb.com (별도 Vercel 프로젝트 `reverb-sales`, Root Directory=`sales/`)
- 스테이징 (인플루언서): https://dev.globalreverb.com
- 스테이징 (관리자): https://dev.globalreverb.com/admin/ (admin@kemo.jp / admin1234)
- GitHub: github.com/jfun-reverb/kemo
- Supabase (production): https://nrwtujmlbktxjgdwlpjj.supabase.co (🇯🇵 Tokyo `ap-northeast-1`, Pro/MICRO 1GB — 경위·메모리 현황은 `.claude/rules/supabase.md`)
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
- **Brevo 플랜: Starter 20,000 emails/월**(Marketing+Transactional 공용, 일일 한도 없음). 🔴 **금액·용량·갱신일은 이 문서가 아니라 Brevo 「Usage and plan」에서 볼 것**. 🔴 **구독이 만료되면 Brevo 는 오류 없이 조용히 큐에 쌓는다** — 모든 메일이 멈춰도 회원 문의로만 안다. 진단은 `.claude/rules/supabase.md` 「메일이 안 나갈 때 보는 순서」
- 발신: `noreply@globalreverb.com`, 발신명: 운영 `REVERB JP` / 개발 `REVERB JP [DEV]`
- 발신 도메인 DNS 인증 완료 (SPF/DKIM/DMARC, cafe24 DNS 관리)

### 가동 중인 메일 파이프라인 (세부 구현은 `supabase/functions/*` + 사양서가 source of truth)
> 상세는 주제별 규칙 파일(아래 지도) — 그 함수 폴더·마이그레이션을 Read 로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).

**현재 원본 번호**
- `get_promo_digest_targets` · `get_promo_digest_campaign_pool` — **471**(🔴 **`CREATE OR REPLACE` 로만** — `DROP` 후 `CREATE` 하면 375 의 실행 권한 회수가 풀려 회원 누구나 남의 이메일·수신거부 토큰을 받는다)
- `_campaign_cert_success_counts` — **456**(베이스 433)

- 일일 메일 3종(관리자 메일 다섯째 절은 시간 창 없음 · ⚠️ 사유 문구 표 두 벌)·🔴 수신자 단위 발송 기록(선점 조건과 바꾸는 값이 같은 칸 · 배포는 데이터베이스 먼저 · **「복사 목록」 9개가 세 함수에 같은 본문**)·1,000행 상한(🔴 인플루언서 메일은 조회 실패 시 마감 절을 통째로 건너뛴다) — 상세 `.claude/rules/mail-digests.md`
- 웹훅 메일(광고주 접수·오리엔시트 제출 과다 발송 게이트 2단·🔴 알림 1건 = 메일 1통은 「선점 먼저」·요청 본문을 믿지 않는다·같은 호출자 검사 본문 12개) — 상세 `.claude/rules/mail-webhooks.md`
- 캠페인 홍보 메일(🔴 채널 문지기는 네 채널만 — Qoo10·LIPS·@cosme 만 쓰는 캠페인은 대상 아님, 결정 · 실행 권한 회수 순서는 부여 먼저) — 상세 `.claude/rules/promo-mail.md`
- **약관·방침 개정 통지 메일**(`notify-policy-change`, **수동 1회 호출**. 전 회원 1인 1통, 수신 동의 무관): 🔴 **통지마다 갈아 끼울 자리가 넷** — ①`docs/email-templates/policy-change-notice.html`(→ 동기화 스크립트가 `_templates/` 와 **`templates.ts`** 생성, 함수는 `templates.ts` 를 읽는다) ②`CURRENT_NOTICE`(키·시행일) ③제목 ④텍스트 판 — **뒤 셋은 `index.ts` 에 박혀** 템플릿만 바꾸면 옛 제목으로 나간다. **탈퇴 확정 회원**(`@deleted.reverbjp.invalid`)은 `skipped`/`withdrawn`(진행 중 회원은 받는다). `noticeKey`·`effectiveDate` 가 `CURRENT_NOTICE` 와 다르면 **시험 발송까지 거부**(`notice_mismatch`) — 옛 키면 받은 회원이 「이미 받음」으로 빠진다. ⚠️ 짝인 **앱 안 공지**는 `POLICY_NOTICE`(shared.js) + `policyNotice.*`(ja·ko) — `id` 도 통지마다 새 값(옛 값이면 공지를 닫은 회원에게 안 뜬다). 메일 템플릿에 지금 든 것 = 개인정보처리방침 개정(메타 픽셀, 시행 2026-10-17). ⚠️ **앱 안 공지는 일반 문의 창구 공지(`inquiryDesk2026`, 시행 2026-10-06, 메일 통지 없음)로 바뀌어 메일과 짝이 아니다** — 공지 틀이 하나뿐이라 픽셀 공지를 대체했다(사용자 결정). 사양서 `docs/specs/2026-09-17-meta-pixel-policy-notice.md`
- **브랜드 메일 함수 넷**(설정 `notify-brand-account-setup` · 비밀번호 찾기 `brand-password-reset-request` · 초대 `notify-brand-invite` · 초대 수락 `brand-invite-accept`) — 개발서버만, 운영 보류 · 🔴 **개발서버 두 겹 잠금** `BRAND_SETUP_DEV_ECHO=1` **그리고** 개발 프로젝트 주소 — 하나라도 지우면 운영에서 링크가 응답에 실린다. 🔴 **운영에 `BRAND_SETUP_DEV_ECHO` 를 넣지 않는다** · 공개 함수(비밀번호 찾기·초대 수락)는 잠금이어도 응답·로그에 링크·본문을 싣지 않는다 — 상세 `.claude/rules/brand-account.md` 「브랜드 메일 함수」
- 🔴 **브랜드 메일 링크 「24시간」 문구**(설정·재설정 — 2026-10-15): 인증 설정 Email OTP Expiration 86400 이 전제다(개발서버는 바꿈). **운영은 설정을 먼저 바꾸고 그 뒤 함수 배포** — 반대면 메일이 거짓 안내. 같은 날 인플루언서 `reset-password.html` 「1時間後」도 고친다. 설정 메일 양식 `{{heading}}` 칸은 두 함수가 넘긴다(빠뜨리면 제목이 빈 채로 나간다)
- **공통 패턴**: ①인플 대상 메일은 **4줄 푸터 필수**(自動送信 안내·LINE @reverb.jp·© JFUN·사이트 URL, 글자색 #999) — 신규 인플 메일 추가 시 의무 ②관리자 일괄 발송은 **1명당 1통 분리**(To 헤더 노출 차단) ③부분 실패는 `status='sent'`+실패 명단 누적(전원 실패만 `failed`)
- **메일 템플릿**: `docs/email-templates/` 가 source of truth(카탈로그 `index.html`). Edge Function 은 `_templates/` 미러를 `render({{key}})` 로 읽음 — 배포 전 `scripts/sync-email-templates.sh` 동기화 필수

### Auth URL Configuration
- 운영: Site URL `https://globalreverb.com` + Redirect `https://globalreverb.com/**`, `https://www.globalreverb.com/**`
- 개발: Site URL `https://dev.globalreverb.com` + Redirect `https://dev.globalreverb.com/**`

### Auth Rate Limits
- 운영: `Rate limit for sending emails` = **100 emails/h** (가입+초대+재설정 메일 공용)
- 개발: 기본값 30/h (Confirm email OFF, 트래픽 적어 충분)
- 한도 소진 시 `429 email rate limit exceeded`. Logs & Analytics → Auth 에서 확인

## i18n
- 인플루언서 페이지 KO/JA 토글 (마이페이지 메뉴)
- 키-값: `dev/lib/i18n/{ja,ko}.js`, 런타임: `dev/lib/i18n/index.js`
- HTML: `data-i18n="key"` (textContent), `data-i18n-html="key"` (innerHTML, `<br>` 허용)
- JS 동적: `t('key')` 헬퍼
- 기본값 `ja`, navigator.language 자동 감지 사용 안 함
- ⚠️ **운영 빌드에도 실려 있다**(`main` 산출물에 `setLang('ja')`·`setLang('ko')`·번역 런타임). **화면에 토글이 보이는지**는 미확인 — 운영에서 켤지 판단하려면 먼저 눈으로 볼 것
- 적용 범위: 마이페이지, 인증, GNB/홈, 캠페인 목록·상세, 신청 모달, 활동관리, 알림, DB 에러 메시지 로케일 분기 (`friendlyErrorJa`)

## 내부 문서 (개발서버 한정)
- `docs/flowchart-i18n.html` — i18n 다국어 흐름도
- 접속: https://dev.globalreverb.com/docs/flowchart-i18n.html (전체 서비스 플로우차트 `service-flow.html` 은 더 쓰지 않아 2026-10-19 삭제)
- **운영서버(main)에 머지하지 않음** — 내부 직원용 참고 자료

## Architecture
- 인플루언서 앱: `dev/index.html` (모바일 480px, GNB + 우측 슬라이드 햄버거 메뉴)
- 관리자 앱: `dev/admin/index.html` (PC 전체폭, 별도 페이지, **2단 고정 레이아웃** — 사이드바/메인 독립 스크롤, 상단 GNB 없음)
- **광고주 신청 앱(sales)**: `sales/{index,reviewer,seeding}.html` — **별도 Vercel 프로젝트 `reverb-sales`**(Root Directory=`sales/`), `sales.globalreverb.com` / `sales-dev.globalreverb.com`. anon 이 `submit_brand_application` 을 거쳐 `brand_applications` 에 넣는다. `cleanUrls`+catch-all rewrite 로 `/reviewer` → `reviewer.html`. **파일 업로드 없음**. ⚠️ 배포 대상이 달라 **커밋 머지 ≠ 페이지 반영**
- 배포용 산출물: 루트 `index.html`·`admin/index.html`·`brand/index.html` (`dev/build.sh` 가 생성 — **직접 수정 금지**)
- **브랜드 페이지**(`dev/brand/index.html` → 루트 `brand/index.html`, 개발서버만 · 운영은 「준비 중」): **자립형 화면**(`storage.js`·`ui.js` 안 실음). 🔴 `window.REVERB_SKIP_GLOBAL_DB = true` 를 `lib/supabase.js` 보다 **앞**에 두어 전역 `db`·`dbAuthRequest` 를 만들지 않는다(기본 저장 칸·주소 인증 값 가로채기 방지) — **인플루언서·관리자 화면에 이 표시를 두면 그 화면의 `db` 가 `null` 이 된다**. 빌드는 `BRAND_*_FILES` + 원본 태그 정규식 **두 곳**. 틀 안 주소는 「페이지/인자」(`#campaigns/<캠페인 번호>`) — 🔴 `routeBrand`·`rerenderCurrentBrandPage`·`showBrandShellPage` 가 모두 `splitBrandHash`(brand-shell.js)로 앞부분만 본다(하나만 고치면 새로고침·브랜드 바꾸기에서 주소가 첫 페이지로 덮인다)
- **폴더 구조는 `ls dev/js/`·`dev/lib/`·`dev/css/` 로 본다**(목록을 베껴 적지 않는다). 빌드 목록 단일 소스는 **`dev/build.sh` 의 `CLIENT_JS_FILES`·`ADMIN_JS_FILES`**
- **회원 앱 공용 부품은 `dev/css/member-ui.css`**(회원 빌드 맨 끝 — 관리자 빌드엔 없다) + 상태 안내 헬퍼 `stateEmptyHtml`·`stateLoadingHtml`·`stateErrorHtml`(`ui.js`, 🔴 조회 실패 `null` 은 오류 · 0건 `[]` 은 빈 상태). 🔴 `base.css`·`components.css`·`ui.js` 는 관리자와 공유라 **기존 값을 고치지 않는다** — 회원 앱 값은 `member-ui.css` 에서 **전역으로** 덮어쓴다(2026-10-06 마무리에서 화면별 선택자를 합침 · ⚠️ 약관 창·정책 통지 창은 공유 파일이 창 아이디로 정의해 같은 아이디가 필요)(사양서 `docs/specs/2026-09-29-member-app-style-unification.md`)
- 🔴 **빌드는 ES 모듈이 아니라 단순 이어붙이기(concat)라 전역 스코프가 하나다** — `admin-core.js` 가 다른 `admin-*` 보다 **앞**, `admin.js` 가 페인 파일들보다 **뒤**, `admin/app.js` 가 **맨 마지막**(`dev/build.sh` 의 순서). 인플루언서 쪽은 `lib/*` 가 `js/*` 보다 앞, `js/app.js` 가 맨 마지막
- Supabase 미연결 시 localStorage 로 동작 (DEMO_MODE)
## Features — 인플루언서 (모바일)
> 상세는 주제별 규칙 파일(아래 지도) — 그 화면 파일을 Read 로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).

**현재 원본 번호**
- 가입 트리거(폼 값 저장) `handle_new_user` — **526**(382 → 420 → 526 — 526 는 맨 앞 브랜드 계정 분기만 더함. 🔴 420 을 베이스로 잡으면 브랜드 계정에 인플루언서 행이 생긴다) · 모집 마감 후 응모 차단 트리거 — **326**(272 → 326) · 응모 삽입 상태값 위조 차단 `guard_application_insert_status` — **537**(314 → 537, 안내 확인 시각도 비운다. 🔴 `CREATE OR REPLACE` 로만 — 트리거 이름이 049 자동 승인보다 알파벳순으로 앞서야 한다)

> ⚠️ **아직 안 한 것**: 「올려두고 제출 안 함」 재발 방지의 관리자 대신 제출 기록(작업 9)·일일 메일 안내(작업 11)는 범위 밖, 자주 묻는 질문 노드(작업 12)는 작업 2·5 운영 배포 뒤에만

- 🔴 **가입 폼 값은 화면이 아니라 가입 트리거가 저장한다**·지우는 일은 쓰기마다(383)·확인 링크 `?code=` 는 재설정 신호가 아니다·가입 이메일 도메인 점검·흔한 비밀번호 경고 — 상세 `.claude/rules/member-signup-auth.md`
- 캠페인 목록(탭별 주소 판정 두 함수)·상세 뒤로 단추·마이페이지(저장 단추는 바뀐 값이 있을 때만 · 떠날 때 확인 — 🔴 `navigate` 가드는 목적지가 마이페이지여도 건다)·메일 수신 설정(켜기는 서버 함수)·수신거부 라우트(🔴 템플릿 수신거부 줄 삭제 금지)·햄버거 메뉴·알림·응모이력·푸터 — 상세 `.claude/rules/member-app-screens.md`
- 신청 사전 체크·주의사항 동의 스냅샷·리뷰어형 정원 차단·🔴 **모집 마감 후 응모 차단은 서버 트리거가 유일한 최종 방어선**·본인 응모 취소(🔴 인플루언서 행은 `id` 로 찾는다 · 취소 알림은 서버가 만든다) — 상세 `.claude/rules/apply-and-cancel.md`
- 활동관리 결과물 제출·「올려두고 제출 안 함」 방지(채널 단위 버튼·떠날 때 확인 두 겹)·제출 마감 판정 `get_deliverable_gate`(⚠️ 조회 실패 `null` 과 0건 `[]` 구분) — 상세 `.claude/rules/deliverable-submit.md`
- 리뷰어형 기간·마감 문구 판정 헬퍼(회원 상세와 관리자 미리보기가 **같은 함수**) · 페이백 안내 문구 **두 벌**(i18n·`admin.js`) — 상세 `.claude/rules/campaign-period-wording.md`
- 응모건 메시지 회원 화면(🔴 취소 응모도 진입은 막지 않는다 · 페이지 재사용)·자동 번역 파이프라인 — 상세 `.claude/rules/member-messages.md`

## Features — 관리자 (PC)
- **사이드바**: Material Icons, 접기/펼치기 토글, `data-pane` 속성 기반 라우팅, pending 배지 항상 표시
- **페이지 새로고침**: `visibility:hidden` cloak 기법 (깜빡임 완전 방지), 서브패널 새로고침 시 부모 패널로 리다이렉트
- **대시보드**: KPI 카드(캠페인/인플/신청/승인), 상태별·채널별 캠페인 분포(복수 채널은 중복 집계), 가입 추이 차트(Chart.js, 7일/30일/전체), 오늘·이번주 가입 KPI, 프로필 완성률(SNS·배송지·PayPal), 도도부현 분포 도넛(Top 10 + 未登録/海外, 한국어 라벨), 최근 신청 테이블
- **로딩 UX**: 테이블·KPI·차트 영역 인라인 스피너

### 캠페인 관리
> 상세는 주제별 규칙 파일(아래 지도) — 그 화면 파일을 Read 로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).

- 캠페인 삭제 복구·번호 매기기(🔴 복제는 원본의 `brand_id`·`source_application_id` 를 둘 다 이어받는다)·등록/편집 폼·브랜드 변경 확인 창·가이드 칸 이름 판정(🔴 형식만 보고 바꾸면 기존 리뷰어형 제목이 한꺼번에 바뀐다)·미리보기·목록 「결과물 현황」 열(🔴 방문형 현장 사진도 `kind='receipt'`)·상태 6단계·노출 토글(신규 폼 안내 문구와 저장 상태를 같이 고친다)·상태 전이·마감일 연장 확인 — 상세 `.claude/rules/campaign-admin.md`
- 캠페인 리치 텍스트 편집기 이미지(⚠️ 정화·편집기 형식·CSS **세 곳이 한 세트** · `image-compress.js` 는 관리자 빌드에도 · 본문에서 빼도 저장소 파일은 남는다 — 복제본이 가리킨다) — 상세 `.claude/rules/rich-editor-images.md`

### 신청·결과물 관리
> 상세는 주제별 규칙 파일(아래 지도) — 그 화면 파일을 Read 로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).

**현재 원본 번호**
- `get_report_share_data` — **545**(414 → 449 → 457 → 469 → 491 → 545). 🔴 **`CREATE OR REPLACE` 로만** — `DROP` 하면 413 이 비로그인에 준 권한이 풀려 공유 링크가 전부 죽는다. 545 부터 본체는 내부 함수 `_results_payload_core`·`_results_ext_rows`(브랜드 결과물과 공유가 같이 쓴다 — 본문을 고칠 때는 이 둘을 545 베이스로) · 회원 응답에 `is_audit` 없음 · 「또는」 캠페인(채널 하나 캠페인 포함 — 기본값이 'or')은 게시한 채널 계정만(사양서 `2026-07-15-brand-portal.md` §17 — 개발서버만, 운영은 출시 날 ①)
- `touch_campaign_report_updated_at` — **491**
- `admin_create_deliverable_proxy` — **511**(184 → 511, 대리 등록 기간 거부 `proxy_window_closed` — 화면 판정 `isProxyWindowOpen` 과 같은 식). 🔴 **`CREATE OR REPLACE` 로만**(184 의 `DROP` 을 옮기지 말 것)

- 신청 관리·취소 되돌리기(🔴 `reviewed_at` 안 건드림 — 당선 메일 재발송 방지 · 탈퇴와 얽히면 항상 거부 · 정원은 이 함수가 유일한 방어선)·캠페인 진행현황 — 상세 `.claude/rules/application-admin.md`
- 결과물 검수·인증 상태/인증 성공일/구매금액 열(🔴 진행현황 표와 행 함수 공유 — 열을 늘리면 머리글·`colspan` 여러 곳)·검수대기 배지(배지 전용 재현)·영수증 수정(정산 재계산·「자동 보류」 연속 표현 금지)·엑셀 — 상세 `.claude/rules/deliverable-review.md`
- 캠페인 리포트·브랜드 공유(🔴 계정 열 채널 추가 시 고칠 자리 넷 · 공유 열 끄기 판정 사본 두 벌 · 끈 열 값은 서버가 비운다 · 반려·취소·탈퇴 줄은 공유 응답에 없다) — 상세 `.claude/rules/report-share.md`

### 브랜드 서베이 (광고주 신청 관리)
> 상세는 주제별 규칙 파일(아래 지도) — 그 화면 파일을 Read 로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).

**현재 원본 번호**
- `merge_brands` — **528**(175 → 328 → 467 → 528, 🔴 175 를 베이스로 잡으면 오리엔시트·메모 이동이, 467 을 잡으면 브랜드 계정 연결 거부가 사라진다) · `delete_brand` — **528**(174 → 191 → 325 → 528, 🔴 191 베이스 금지 — 325 의 보관 캠페인 제외가 사라진다). ⚠️ 528 은 **개발서버만** — 운영 원본은 아직 467·325(운영 반영은 526 → 527 → 528 한 묶음, 528 단독이면 없는 표를 불러 삭제·병합·초대가 전부 깨진다)

- 오리엔시트 발급·조회 페인(신규 발급 창의 신청 연결 칸은 잠김 · 발급 메일 수신자는 서버가 정함 · ⚠️ 재발송 버튼·발송 이력은 없다)·발급 목록 삭제 — 상세 `.claude/rules/orient-sheet.md`
- 브랜드 상세 모달(🔴 편집 폼이라 탭 전환은 `display` 토글만)·회사 관리·브랜드 삭제·병합(되돌리기 불가)·서베이 신청 목록·상태 10단계·제품별 메모·입금 칩·캠페인↔신청 연결 — 상세 `.claude/rules/brand-admin.md`
- 운영 현황 일정(간트)·브랜드 뷰(🔴 날짜→위치 변환은 `ganttDayOffset` 하나 · 선정 막대 조건은 다섯째 사본 · 경고 꼬리표는 브랜드 카드 경고의 화면 사본) — 상세 `.claude/rules/brand-ops.md`

### 인플루언서 관리
- **목록**: 채널/인증/위반 드롭다운 + 주소지(도도부현 다중, 「未登録」·「海外」) + 팔로워 범위(채널 기준, 전체=4채널 합계) + 통합 검색 + 인원수. 주소지·팔로워는 클라 필터(`getFilteredInfluencersForView` — 화면·엑셀 공용. `classifyPrefecture`/`followerValueByChannel`, admin-core.js). SNS 채널 선택 시 열은 항상 전체 10컬럼 고정
- **엑셀 내보내기**(`exportInfluencersExcel`, admin-excel.js): 현재 필터 결과(화면에 보이는 대상)를 .xlsx 로. 기본 16열(이름 한자/가나·이메일·대표SNS·4채널 핸들+팔로워·합계·도도부현·시군구·등록일). 민감정보 6열(전화·LINE·PayPal·우편번호·건물·상세주소)은 `canRead('influencer.excel_sensitive')` + 「민감정보 포함」 체크 시만. ⚠️ 그 열쇠말은 화면 열람용 `sensitive_pii` 와 **별개**다(엑셀 대량 유출을 따로 통제). **민감정보 서버 실차단(마이그레이션 212·213)**: `fetchInfluencers`/`fetchInfluencersByIds` 가 가림막 뷰 `influencers_admin_view`(security_invoker) 경유, `has_permission('influencer.sensitive_pii','read')` 가 false 인 등급(213으로 campaign_manager=hidden)에게 6종을 **서버에서 NULL 마스킹** + `has_phone`/`has_line`/`has_paypal` 불리언. 화면은 「열람 권한 없음」. **신청자·결과물 엑셀도 자동 마스킹**. `_excel*` 헬퍼 재사용
- **상태 관리**(인증/위반/블랙리스트): 상태 관리 카드 + 이력 카드(사유별 pill + 타임라인 + 위반 행 편집). 사유는 `blacklist_reason` ∪ `violation_reason`. 증빙은 `influencer-flag-evidence` 비공개 버킷(10MB, image/PDF). RPC: `setInfluencerVerified`/`setInfluencerBlacklist`/`recordInfluencerViolation`/`updateInfluencerViolation` (evidence_paths 미변경=null, 전체 삭제=[])
- **전화번호 표시**(`formatPhoneDisplay` in ui.js): KR/JP 정규화(11자리 3-4-4, 10자리 02/03/06 → 2-4-4 else 3-3-4, `+81`/`+82`). 실패 시 원문

### 아웃바운드 인플루언서 명단 (추천 도구 1·2단계 — ★**운영 반영 완료**)
> 상세는 **`.claude/rules/outbound.md`** — `admin-outbound.js`·아웃바운드 마이그레이션을 Read 도구로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).
- 입구 `/admin/?app=outbound`(영업팀 전용 모드 — **보안 경계 아님**, `outbound.view` 가 서버에서 강제) · 명단 페인 `/admin#outbound` · 조건 추천 탭은 **데이터베이스 변경 없이** 클라이언트 계산. 3~5단계 미착수

### 기준 데이터·번들·관리자 계정
> 상세는 주제별 규칙 파일(아래 지도) — 그 화면 파일을 Read 로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).

**현재 원본 번호**
- `invite_admin` — **528**(245 → 417 → 528 — 브랜드 계정 이메일 거부 `brand_account_email`. ⚠️ 528 은 개발서버만, 운영 원본은 417)
- `get_admin_last_sign_in` — **437**(🔴 반환 칸을 바꾸려면 `DROP` 후 `CREATE` 라 **실행 권한 회수를 다시 걸어야 한다**)

> 🔴 **광고 추적(메타 픽셀)은 운영에서 켜져 있다**(시행일 `2026-09-18` — 방침·앱 공지·메일의 10-17 은 사용자 결정으로 그대로). 관리자 앱에는 픽셀을 심지 않는다

- 기준 데이터·자주 묻는 질문 관리·주의사항/참여방법/NG 번들(스냅샷)·민감 항목 변경 경고·캠페인 변경 이력(차이 표시는 정화 뒤 글자 비교) — 상세 `.claude/rules/lookups-bundles.md`
- 오픈 예정 보드(예고판일 뿐 스위치 아님)·관리자 공지·관리자 계정(🔴 승격 때 기존 비밀번호를 덮어쓰지 않는다 · `resetPasswordForEmail` 안 씀 · 비밀번호 찾기는 계정 존재 비노출 · 흔한 비밀번호 거부는 서버 함수 먼저 배포 · 「최근 접속」은 슈퍼관리자 전용 두 겹) — 상세 `.claude/rules/admin-accounts-notices.md`
- 🔴 **감사용 계정 격리**(응모수·정원·통계·운영현황·엑셀 — ⚠️ `fetchInfluencers` 기본값이 포함이라 통계·엑셀에서만 `includeAudit:false` 명시) — 상세 `.claude/rules/audit-account.md`
- 오류 로그·광고 추적 화면(상태 배지는 서버 값 그대로 · 스위치는 저장된 아이디로만) — 상세 `.claude/rules/admin-tools.md`
- **에러 처리**: `friendlyError()` 한국어 메시지 + 에러 코드
- **상태 뱃지**: `getStatusBadgeKo()` 한국어 상태 표시

## Database Schema (Supabase)

### 캠페인·신청·결과물
- `campaigns` — 캠페인 정보. 핵심 컬럼:
  - 기본: `title`, `brand`, `brand_ko`, `product`, `product_ko`, `type`, `channel`, `channel_match`('or'|'and'), `category`, `reward`, `reward_note`, `slots`, `min_followers`, **`min_followers_by_channel`**(jsonb, 마이그레이션 385 — 「그리고」 갈래만 읽는다), `status`, `view_count`, `img1~img8`
  - 일정: `recruit_start date NULL`(NULL 이면 "오늘 ~ 마감" 폴백), `deadline`, `purchase_start/end`(monitor), `visit_start/end`(visit), `submission_end`
  - 번들 스냅샷: `participation_set_id`/`participation_steps jsonb`, `caution_set_id`/`caution_items jsonb`, `ng_set_id`/`ng_items jsonb`
  - 채번: `campaign_no`, `legacy_no`(콤마 누적), `brand_id` FK, `source_application_id` FK
  - `reward_note` 는 지급 조건·정산 시점 등 자유 텍스트
  - 홍보 메일: `first_active_at timestamptz NULL` — 처음 active 가 된 시각. `BEFORE UPDATE OF status` 트리거(`_record_first_active_at`) 자동 기록·불변 (마이그레이션 140)
  - 동시 저장 방어(마이그레이션 275): `version integer NOT NULL DEFAULT 1` — 나중 저장이 앞 저장을 조용히 덮는 것을 막는다. `campaigns_bump_version()` 트리거가 **제외 6개**(`version`·`updated_at`·`view_count`·`applied_count`·`order_index`·`first_active_at`) 외 변경 시에만 +1(새 컬럼은 자동 보호). 편집 저장은 `updateCampaign(id, updates, expectedVersion)` 의 `.eq('version', …)` → 0행이면 충돌 안내. ⚠️ **코드보다 마이그레이션을 먼저**(반대면 자동 마감 실패). ⚠️ 자동 전이(`autoOpen/Close/EndCampaigns`)도 version 을 올리므로 캐시를 `.select('version')` 으로 갱신 — 안 하면 **가짜 충돌**
  - 오리엔시트 발행 보조(마이그레이션 197): `proxy_purchase boolean NOT NULL DEFAULT false`(가구매 — 영수증만. 인증성공 판정·활동관리·엑셀이 분기) + `emergency_publish_reason`/`emergency_published_by`/`emergency_published_at`
- `campaigns_yearly_counter`, `brand_seq_counter`(싱글톤), `brand_application_counter`, `application_campaign_counter`, `brand_external_campaign_counter` — 채번 카운터. SECURITY DEFINER 트리거 전용 (직접 UPDATE 금지)
- `numbering_legacy_map` — 신구 채번 양방향 매핑
- `applications` — `user_id`, `campaign_id`, `message`, `address`, `status`(pending/approved/rejected/cancelled), `reviewed_by`, `reviewed_at`, `oriented_at`, `reviewed_version`(낙관적 락), `caution_agreed_at`, `caution_snapshot jsonb`, `guide_acknowledged_at`(537 — 응모 직후 「응모 완료 모달」에서 「확인」을 누른 시각. 기록은 `acknowledge_application_guide(uuid)` 로만·덮지 않음, 응모 삽입 때 보낸 값은 314→537 가드가 지운다. 관리자 신청자 표 「안내 확인」 배지). 취소 보조 5종: `cancelled_at`, `cancel_reason`, `cancel_reason_code`, `cancel_phase CHECK(recruit|purchase|visit|post|other)`, `previous_status`. `(user_id, campaign_id)` partial unique index(cancelled 제외) → 재응모 가능
- `deliverables` — `kind`('receipt'|'review_image'|'post'), `status`, **`submitted_at` = 마지막으로 제출한 시각**(512 트리거가 **임시저장 → 검수 대기 순간에만** 찍는다 — 관리자 되돌리기·승인에는 안 바뀐다. 🔴 조건을 넓히지 말 것. 512 이전 행은 「처음 만든 날」), `receipt_url`/`purchase_date`/`purchase_amount`/`order_number`, `post_url`/`post_channel`/`post_submissions`, `reject_reason`, `reviewed_by`/`reviewed_at`, `version`. **대리 등록 4종**: `submitted_by_admin`(NULL=본인) + `submitted_by_admin_reason_code`/`_reason`/`_at`. 부분 인덱스 `idx_deliverables_proxy WHERE submitted_by_admin IS NOT NULL`. **`admin_create_deliverable_proxy` 게시물 분기**(182): ①요구 채널 불일치 차단(⚠️ 채널이 빈값이면 우회된다) ②같은 채널 반려·검수대기 게시물은 **교체**(`status='approved'`, `post_submissions` 누적, `version`+1) — **승인 게시물은 교체 차단**(`insertDraftDeliverable` 과 같은 규칙). **잘못된 채널 잔존 행 정리**(183, `delete_mismatched_post_deliverable`): 「채널 불일치」 배지 + super_admin 수동 삭제. **반려·검수중·임시저장만**, `post_channel` 이 NULL 이거나 정상 채널이면 거부. `deliverable_events` 는 **328 이후 `SET NULL` 이라 감사 기록이 남는다**
- `deliverable_events` — `action`(submit/resubmit/approve/reject/revert/admin_proxy_submit/admin_proxy_revoke/channel_assign/channel_unassign), 트리거/RPC 만 INSERT. ⚠️ **마이그레이션 328로 `ON DELETE SET NULL`**(옛 `CASCADE` 는 이력도 지웠다) — 스냅샷 칸 4종(`kind`·`post_channel`·`status` 등)으로 **결과물이 지워져도 무엇의 이력인지 남는다**(`admin_proxy_revoke` 포함)
- `application_events` — 신청 status 변경 audit(운영자 액션). `action`(approve|reject|revert_to_pending|**restore_cancelled**). `trg_application_status_event` 트리거 INSERT(본인 취소·재응모 미경유). RLS SELECT `is_admin()` — **단 `restore_cancelled` 는 `restore_cancelled_application`(440)이 직접 넣는다**(「취소 되돌리기」 참조). ⚠️ **검사 제약 이름은 440 부터 `application_events_action_check`**(131 은 자동 생성 이름). 다음에 `action` 을 늘릴 땐 440 이 베이스
- `receipt_edit_history` — 영수증 수정 감사. `deliverable_id` FK **SET NULL**(마이그레이션 253) + 3종 prev/next 스냅샷. RLS SELECT `is_admin()`, INSERT 는 `update_receipt_admin` 만
- `campaign_caution_history` — 주의사항/참여방법/NG 변경 audit + `app_count_at_change`. RLS SELECT super_admin, INSERT 는 `record_caution_history()` 만(campaign_admin 이상)
- `campaign_change_history` — **캠페인 전체 항목 변경 audit**(마이그레이션 265·266). 「바뀐 항목 1개 = 1행」 + `change_group_id` + `changed_by`/`changed_by_name`/`changed_at` + `field_name`(CHECK 화이트리스트 **48개**) + `old_value`/`new_value` jsonb + `change_source`(admin / auto / system). RLS SELECT `is_super_admin()`, 쓰기는 트리거만(`record_campaign_change_history()` AFTER UPDATE — 구 `record_caution_history` 와 달리 같은 트랜잭션이라 감사 공백 없음). ⚠️ **화이트리스트는 세 곳(265 CHECK · 266 v_fields · 266 트리거 `AFTER UPDATE OF` 목록)이 항상 같은 집합** — 어긋나면 CHECK 위반으로 INSERT 실패. 조회수·신청 수·수정일·순서·채번 제외. 3영역은 기존 표와 병존. 사양서 `docs/specs/2026-07-27-campaign-full-change-history.md`

### 브랜드 계정·로그인·멤버 관리 (마이그레이션 526~528 · 530~533 — 🔴 **개발서버만**, 운영 반영 보류)
> 상세는 **`.claude/rules/brand-account.md`** — 브랜드 화면(`dev/brand/**`·`dev/js/brand-*.js`)·관리자 브랜드 상세(`admin-brand.js`)·브랜드 메일 함수 둘·526~528을 Read 도구로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).
> 사양서 `docs/specs/2026-07-15-brand-portal.md` §16-6·§16-7 · 작업표 `docs/specs/2026-10-14-brand-login-breakdown.md`(조각 11개 · 결정 기록) · 멤버 관리 작업표 `docs/specs/2026-10-15-brand-member-breakdown.md`(묶음 ① 서버) · 화면 작업표 `docs/specs/2026-10-15-brand-member-screen-breakdown.md`(묶음 ② 브랜드 화면 완료 2026-10-16 — 관리자 화면 묶음 ③ 미착수) · 인수인계 `…-brand-login-handoff.md`

**현재 원본 번호**
- 브랜드 관리 화면 함수 셋 `get_my_brand_profile`·`update_my_brand_info`·`update_my_brand_company` + 이력 표 `brand_profile_history`(트리거 `trg_brands_profile_history`·`trg_companies_profile_history` — 관리자·브랜드 구분 없이 바뀐 칸마다 한 줄) — **536**(신설, 개발서버만 · 운영 묶음은 … → 534 → 536). 🔴 브랜드 계정이 처음으로 173(캠페인 브랜드명 동기화)·266(캠페인 변경 이력)을 부른다 — 이력은 `change_source='admin'`·`changed_by`=브랜드 계정·`changed_by_name` 빈 값(266 은 이름을 `admins` 에서만 찾는다, Q4 로 그대로 둠)
- 🔴 **관리자 화면이 브랜드가 고친 값을 되돌린다** — 관리자 브랜드 편집(`saveBrandDetail`)·회사 편집(`saveCompany`)은 폼을 연 순간 값으로 **통째** 저장한다. 브랜드 담당자가 그사이 고친 이름·SNS·회사 정보가 경고 없이 덮인다. 막는 것은 묶음 ③(관리자 화면)
- 외부 결과 파일 캠페인 첨부(`attach_campaign_ext_source`·`detach_campaign_ext_source`·`get_campaign_ext_sources`) + 410 의 `replace_report_source_rows`·`remove_report_source` — **546**(410 베이스 금지 · 개발서버만, 운영은 「사전」 단계) · 🔴 공유 판정(545)·리포트 화면(410)은 `report_id` 로만 찾는다 — 캠페인 첨부는 공유 링크로 새지 않는다 · ⚠️ 캠페인 **보관 삭제 때 첨부·줄이 30일 남는다**(신청·결과물은 즉시 파기 — 후속 과제) · 화면 `admin-camp-ext.js`
- 캠페인 「브랜드 공개」 표 셋·관리자 함수 일곱 — **544**(개발서버만, 운영은 「사전」 단계) · 🔴 화면(`admin-brand-publish.js`·목록 배지·기준 데이터 탭)은 `_brandAccountEnabled()`(개발서버)일 때만 — 운영엔 544 가 없다. 출시 때 그 판정을 걷는다 · 🔴 쓰기 함수 `admin_set_campaign_brand_publish` 현재 원본 **559**(켜기·끄기·열 바꾸기를 같은 거래에서 제공 기록 — 544 베이스 금지, 개발서버만) · 결과물 열람·내려받기 기록은 서버 함수 `brand-campaign-results` 가 남긴다(547 은 그대로)
- 결과물 사진 값 두 형식(조각 6 — 옛 공개 주소 / 비공개 통 경로 `receipts/…`, 「://」 유무로 가름): 판별 `deliverableMediaRef`(ui.js) · 서명·보관 `signDeliverableMedia`·`prefetchDeliverableMedia`·그리기 `deliverableImgAttrs` + 그린 뒤 `hydrateDeliverableMedia`(목록은 `mountLazyList` 묶음마다)·누를 때 서명 `openDeliverableMediaLightbox`(storage.js) · 엑셀 링크 7일 `_excelMediaLink`(admin-excel.js) · 지우기 `_deleteDeliverableMediaFiles`(가리키는 통마다 — 🔴 통을 고정하면 비공개 통 파일을 「없는 파일 삭제 성공」으로 넘긴다) · 탈퇴 파기 목록 `list_pending_withdrawal_media_purge` 현재 원본 **549**(364 베이스, 두 형식을 같은 파일로 셈 — 내부 `_deliverable_media_key`) + 서버 함수 `purge-withdrawal-media` 통 둘 · 관리자 일일 메일은 경로 영수증이면 관리자 화면 링크. 🔴 새로 사진을 그리는 자리는 `receipt_url` 을 `<img src>` 에 바로 넣지 말 것(경로면 안 열린다) · ⚠️ 공유 리포트 `report.html` 은 서명 못 한다(비로그인) · 업로드(조각 7): 영수증(회원 제출·관리자 대리 등록)은 `uploadImage(…, {bucket: receiptUploadBucket()})` 로 비공개 통에 올리고 **경로**를 저장 — 🔴 `receiptUploadBucket()` 이 **운영 주소에서는 아직 공개 통**(공유 화면이 비공개 사진을 못 열어서). 출시 날 공유를 닫은 뒤 그 조건을 걷는다 · 리뷰 인증샷은 공개 통 그대로(D1) · 옛 영수증 옮기기(조각 8, 출시 날 ⑥): 복사 도구 `scripts/copy-receipts-to-private.js` → 변환 패치 `supabase/patches/2026-10-19-receipt-url-to-private-path.sql`(복사본 있는 줄만, 백업 표 `_receipt_url_backup_20261019` — 🔴 조각 20·21 끝나기 전에 지우지 말 것) · 개발서버는 이미 변환됨
- 영수증 비공개 통 `deliverable-media` 정책 넷 + `_deliverable_media_owner_ok` — **548**(개발서버만, 운영은 「사전」 단계) · 서명 전 「올린 사람 대조」 `service_brand_receipt_signable` — **551**(개발서버만 · 서버 함수 `brand-campaign-results` 는 개발 프로젝트에만 배포)
- 개인정보 기록 표 둘 `brand_provision_logs`·`personal_data_access_logs` + 쓰기 함수 — **552** · 보관 기간 정리 + 예약 — **553**(둘 다 개발서버만 · 운영은 L1 — 552 바로 뒤 553, 운영에도 예약을 건다) · 부르는 자리: 554 트리거·557 배송 함수·559 공개 설정·서버 함수 `brand-campaign-results` · 탈퇴 파기(520)는 이 표를 안 지운다(의도)
- 시딩형 배송 기반(표 둘·승인 트리거·권한 `shipping.manage`) — **554**(개발서버만 · 운영은 L1) · 🔴 기준 데이터 종류 검사 제약 현재 원본도 **554**(종류를 늘릴 때 베이스) · 상세 `.claude/rules/shipping-list.md`
- 배송 리스트 함수(관리자 조회·전달·송장 저장 / 브랜드 요약·목록·내려받기·저장 / 메일 선점) — **557**(개발서버만 · 운영은 L1) · 🔴 트리거 함수 `_application_shipping_sync` 현재 원본도 **557** · 🔴 `_brand_mailable_accounts` 는 `notify-orient-sheet` 받는 사람 규칙의 사본 · 상세 `.claude/rules/shipping-list.md`
- 브랜드 결과물 `get_my_brand_campaign_results` + 목록·상세 `get_my_brand_campaigns`·`get_my_brand_campaign` — **547**(543 베이스 금지) · 🔴 요약 `_brand_campaign_summary` — **550**(547 베이스 금지) · 둘 다 개발서버만, 운영은 출시 날 ①
- 캠페인 탭 함수 `get_my_brand_campaigns`·`get_my_brand_campaign` + 내부 셋(`_brand_campaign_counts`·`_brand_campaign_channel_names`·`_brand_campaign_view_status`) — **543**(신설, 개발서버만 · 반환 칸을 바꾸면 `DROP` 후 `CREATE` 라 실행 권한 회수를 다시 건다). 🔴 상태는 저장값이 아니라 `_brand_campaign_view_status` 가 일본 날짜로 다시 판정한 값 — **관리자 자동 전환(`storage.js` `autoOpen/Close/EndCampaigns`)의 사본**이라 그 식을 바꾸면 함께. 결과물 영역(2단계)은 547 — ⚠️ 목록·상세 두 함수의 현재 원본은 이제 **547**(위 줄)
- `get_brand_invite_link_state` — **534**(베이스 532 — 새 이메일 초대만 `email`, 두 갈래 `issued_at` 추가. 🔴 `CREATE OR REPLACE` 로만 — 비로그인 실행 권한 유지) · ⚠️ 534 도 개발서버만, 운영 묶음은 526 → … → 533 → 534
- 527 함수 여섯(`get_my_brand_login_state`·`get_brand_link_state`·`service_issue_brand_account_link`·`complete_brand_account_setup`·`complete_brand_password_reset`·`service_mark_brand_setup_mail_sent`) — **532**(마지막은 4인자 — 옛 3인자 지움) · `admin_upsert_brand_owner_account`·`admin_get_brand_account_status` — **533**. 🔴 527 을 베이스로 잡으면 532·533 의 새 칸·`can_manage`·권한 가드가 사라진다
- 표 `brand_invites`·`brand_member_limits`·권한 항목 `brand.account_manage`(시드 3행) — **530** · 대표 함수 — **531** · 관리자 쓰기 — **533**. ⚠️ 운영 적용은 526 → 527 → 528 → 530 → 531 → 532 → 533 한 묶음(순서는 사양서 「운영 반영 전 남은 관문」)
> 🔴 **운영 관문**: 브랜드용 이용약관·개인정보처리방침 + `/약관확인` 전에는 운영 데이터베이스에 넣지 않는다. 화면 코드는 `IS_STAGING` 일 때만 계정 생성·판정을 부른다(작업표 P-1) — 출시 때 그 조건을 걷는다
- 🔴 **인플루언서 표 삽입 거부 트리거**(526)가 인플루언서 앱 `handleLogin` 의 프로필 자동 생성을 막는다 — 인플루언서 앱 차단(`auth.js`·`app.js`)은 **판정 실패(`null`)를 「차단」으로 처리하지 않는다**(함수 없는 서버에서 전원 로그인 불가)
- 🔴 **브랜드 비밀번호를 바꾸면 서버가 같은 계정의 다른 로그인을 모두 끊는다**(2026-10-16 실측) — 마이페이지 변경은 일회 연결로 바꾼 세션을 로그인 연결에 옮겨 담는다(`brandChangePasswordWithCurrent`, 일회 연결을 로그아웃하면 옮긴 세션까지 끊긴다)
- 🔴 **브랜드 계정 표시는 앱 메타데이터 `raw_app_meta_data.account_kind='brand'`**(사용자 메타데이터는 누구나 채운다) · 계정 생성에 `auth.admin.createUser` 를 쓰지 않는다(497 가입 관문에 걸린다)
- ⚠️ 528 이 기존 함수 셋(`merge_brands`·`delete_brand`·`invite_admin`)에 브랜드 계정 거부를 넣었다 — 현재 원본 번호는 「브랜드 서베이」·「기준 데이터」 절. ⚠️ **연결 해제는 함수만 있다**(대표 `release_brand_member` 531 · 관리자 `admin_release_brand_account` 533 — 화면 없음). 해제 이력이 있는 브랜드는 해제 뒤에도 삭제가 막힌다(528 — 병합으로)
- 🔴 묶음 ③ 전까지 관리자 브랜드 편집 폼이 `brands.contacts` 를 **통째로** 저장한다 — 서버가 옮긴 대표 표시(531 `_brand_contacts_mark_primary`)가 폼을 연 채 저장하면 되돌아간다
- ⚠️ 권한 「브랜드 계정 관리」(`brand.account_manage`)는 데이터베이스 시드만 있고 관리자 권한 카탈로그(`shared.js`)에는 아직 없다(묶음 ③). 등급을 바꾸면 계정 함수·설정 메일 함수가 함께 따른다
- ⚠️ 알려진 틈(기록만, 다음 작업): 인플루언서 「비밀번호 찾기」·가입 인증번호(499)가 브랜드 이메일에도 동작

### 광고주 신청(브랜드 서베이)
- `brand_applications` — `form_type`(reviewer|seeding), `brand_name`, `contact_name`, `phone`, `email`, `billing_email`, `products jsonb`, `total_jpy/total_qty`, `estimated_krw`, `final_quote_krw`, `quote_sent_at`, `quote_sent_url`, `orient_sheet_sent_at`, `orient_sheet_sent_url`, `paid_at`, `payment_flags jsonb`, `status` 10단계, `request_note`, `version`, `legacy_no`. **익명 INSERT 는 `submit_brand_application()` RPC(SECURITY DEFINER, BYPASSRLS) 필수** — 직접 INSERT 는 42501
- `brand_application_memos` — `application_id` FK CASCADE, `product_idx integer NOT NULL DEFAULT 0`, `memo`, `created_by`/`created_by_name`/`created_at`
- `brand_application_memo_reads` — (memo_id FK CASCADE, auth_id) PRIMARY KEY
- `brand_application_history` — 광고주 신청 변경 audit
- `brand_app_daily_counter` — 일자별(JST) 채번 카운터. SECURITY DEFINER 트리거 전용
- `brand_survey_settings` — 공개 제출 차단 싱글톤(id=1). `submissions_open boolean DEFAULT false`. RLS SELECT `is_admin()` / UPDATE `is_super_admin()`. **`submit_brand_application` 0단계 가드가 차단 시 `RAISE 'submissions_closed'`(P0001)** — 폼은 `error.message==='submissions_closed'` 로 분기. anon 조회 `is_brand_survey_open()`(bool만). 관리자 예외 입력 `admin_create_brand_application`(091). 마이그레이션 206. 사양서 `docs/specs/2026-06-30-brand-survey-submit-lock.md`. ⚠️`submissions_open=true` 재개 시 `sales/index.html`(정적 차단 안내)도 함께 되돌려야 함(reviewer/seeding 은 동적)
- `companies` — 회사 마스터(회사 > 브랜드 > 신청 > 캠페인). `name_ko`(NOT NULL)/`name_ja`/`name_en` + `name_normalized` UNIQUE NOT NULL(자동 정규화) + `business_no` + `address` + `address_detail`(상세 주소, 535 — 개발·운영 모두 적용(운영 2026-10-16 선적용). 🔴 칸을 지우려면 관리자 회사 화면(`fetchCompanies` 칸 목록) 코드를 **먼저** 되돌린다 — 없으면 회사 목록 조회가 실패해 빈 목록이 되고(실패도 `[]`) 브랜드 편집 폼에서 회사가 떨어진다) + `homepage_url` + `billing_email`/`billing_address`/`memo` + `status CHECK(active|archived)` + `total_brands`(`recalc_company_total_brands` 트리거, `brands.company_id` 변경 시). RLS SELECT `is_admin()`, CUD `is_campaign_admin()` 이상. ⚠️ `name_normalized` 는 마이그레이션 119에서 공백 압축 패턴(`lower(trim(regexp_replace(name_ko,'\s+',' ','g')))`)으로 교체(118 원본은 압축 없음)
- `brands` — `name`, `name_normalized`, `brand_seq` UNIQUE, `company_id` FK ON DELETE SET NULL
- `brand_memos`(466) — 브랜드 영업 메모 여러 건(옛 `brands.memo` 는 더 안 쓴다). 관리자 전원 읽기·쓰기, 브랜드 삭제 시 함께 삭제. `merge_brands`(**현재 원본 467**, 베이스 328)가 메모도 옮긴다
- `get_brand_ops_overview(p_company_id uuid)` — 22컬럼 집계 RPC(`SECURITY DEFINER + SET search_path='' + is_admin()`). 148 로 `alert_reasons text[]` + `soonest_deadline date` + `d1_count bigint` 추가. 임계값 120 기준, `flag_agg` CTE 로 1회 계산 후 재참조. 181 로 `app_agg`·`deliv_agg` 에 `JOIN influencers AND is_audit=false`(감사용 격리)
- `get_brand_ops_detail(p_brand_id uuid)` — 브랜드 상세 jsonb. 149 로 캠페인 항목에 `channel`/`channel_match`/`img1`/`recruit_start`/`submission_end` + `approved_app_count`·`deliv_submitted_inf`·`deliv_total`·`deliv_approved`, 150 으로 `purchase_start`/`purchase_end`·`visit_start`/`visit_end`. 미니카드 진행바 중 **인증 성공률**은 RPC에 없어 `hydrateCampCertBars`(admin-brand-ops.js)가 `fetchDeliverablesByCampaign`(🔴 **실패 `null`·0건 `[]`** — 실패를 「0%」로 그리지 않는다. 진행현황 요약 카드도 같다) 후 `countCertSuccess`(admin-deliverables.js — `buildDeliverableGroups`+`computeCertStatus` 단일 소스)로 비동기 채움
- `link_campaign_to_application` / `unlink_campaign_from_application` — 연결/해제 RPC (`is_campaign_admin()` 이상, advisory_xact_lock 2단)

### 브랜드 셀프 오리엔시트 (마이그레이션 186~195·200)
> 상세는 **`.claude/rules/orient-sheet.md`** — 오리엔시트 화면·작성 폼·오리엔시트 마이그레이션을 열면 자동으로 읽힌다.
> 🔴 **이 영역을 설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).
> 🔴 아래는 규칙 파일이 자동으로 안 읽히는 자리에서도 알아야 하는 것이라 여기 남겼다(다른 영역·현재 원본 번호·잠금 상태 등).
> 🔴 **이 영역 파일은 Read 도구로 연다** — 셸(`cat`·`sed`·`grep`)로 보거나 고치면 규칙 파일이 **안 실린다**.

**현재 원본 번호** (함수를 재정의할 때 베이스 — 옮긴 덩어리의 ③ 줄마다 한 줄)
- `create_orient_sheet` — **490**(5인자 `CREATE OR REPLACE` — 권한 `authenticated` 보존. 465 의 「`DROP` 후 재생성」 표기는 틀렸다)
- `get_orient_tier_fees` — **489** · ⚠️ **개발서버는 539**(토큰 함수 자체는 542 가 닫았다 — 아래 542 줄) — 토큰 함수 넷(저장·제출·미리보기·구간)은 「토큰 → 시트 번호」만 하고 본문은 내부 함수 `_orient_save_core`·`_orient_submit_core`·`_orient_preview_core`·`_orient_tier_fees_core`(539 신설 — 로그인 브랜드 함수와 한 벌)에 있다. 🔴 본문을 고칠 때는 `*_core` 를 539 베이스로(운영은 아직 538·430·489 — 539 는 브랜드 묶음과 함께, 적용 순간 운영 링크 폼이 새 본체로 돈다). 칸 `last_edited_at`·`last_edited_by`(539 — 브랜드 저장·제출 성공 때만, 토큰 폼은 계정 NULL) · 브랜드 화면 상태 판정 `_orient_brand_view_status`(539 — 발급 직후 `version` 은 **0**) · 브랜드 로그인 계정 함수 일곱 `get_my_orient_sheets`·`get_my_orient_sheet`·`save_my_orient_draft`·`submit_my_orient_sheet`·`preview_my_orient_quote`·`get_my_orient_tier_fees`·`resolve_my_orient_link` — **540**(개발서버만, 시트의 `brand_id` 로 `is_my_brand` 판정 · 거부는 `not_found` 하나 · 반환 칸을 바꾸면 `DROP` 후 `CREATE` 라 실행 권한 회수를 다시 건다)
- 큐텐 불러오기 계정 관문 `orient_lookup_gate_account`(서비스 키 전용 — 활성 연결·활성 브랜드 식은 530 `my_brand_role` 의 **사본**이라 그 식을 바꾸면 함께) · 업로드 허가 `orient_account_can_upload` + 정책 `orient_images_account_insert`(`s/{시트 번호}/…`, `upsert:false`) · `orient_lookup_hits.auth_id` — **541**(개발서버만). 서버 함수 `qoo10-product-lookup` 은 본문에 `sheet_id` 가 있으면 로그인 토큰을 `auth.getUser` 로 검증하는 계정 갈래(개발 프로젝트에만 배포 — 옛 `token` 갈래는 그대로라 운영에 먼저 나가도 해는 없으나 운영 DB 에 541 이 없으면 새 갈래는 늘 `ok:false`)
- `_orient_apply_issued_rules` — **445**
- `submit_orient_sheet` · `save_orient_draft` — **538**(⚠️ 개발서버는 542 — 아래) (베이스 524 — 기한이 지나면 작성 중(`draft`)만 만료로 바꾸고 제출된 시트는 상태를 그대로 둔 채 거부만. 🔴 524 로 되돌리면 제출 시트가 기한 뒤 저장 시도 한 번으로 만료가 되어 캠페인 등록이 막힌다 · 개발·운영 모두 적용(운영 2026-10-16 — 브랜드 묶음과 별개로 먼저 넣음)) · `get_orient_sheet` — **524**(세 함수 공통 — 524 의 베이스 461·425·187 — 🔴 제출된 시트의 임시저장은 `data` 가 아니라 작성본 `draft_data` 에 간다. 관리자 화면은 작성본 내용을 안 받는다(화면 기준 — 서버 정책은 칸 단위로 안 막는다) — `fetchOrientSheetById` 에 `select('*')` 금지)
- `_orient_compute_quote` — **463**
- `link_orient_card_to_campaign` — **464**(베이스 237)
- 🔴 **링크 폼 닫기 542 — 개발서버만**(2026-10-19): 토큰 함수 다섯(`get_orient_sheet`·`save_orient_draft`·`submit_orient_sheet`·`preview_orient_quote`·`get_orient_tier_fees`)이 `{success:false, reason:'moved'}`, `orient_token_can_upload`·`orient_lookup_gate` 는 거짓 고정(전부 `CREATE OR REPLACE` — 권한 보존). 개발서버에서는 이 다섯·둘의 현재 원본이 **542**(다시 열려면 524·539[7]·200·428 판 재실행 — 542 머리말). 견적서 끼워 넣기(`?embed=quote`)는 서버를 안 써서 그대로. 🔴 **운영 순서**: 브랜드 페이지 운영 반영 → `dev/sales/orient.html` `boot()` 의 `token && SUPABASE_ENV !== 'production'` 막음을 걷어 `reverb-sales` 운영 배포 → 운영 옛 링크가 `/brand/?orient_token=` 으로 넘어가는 것을 눈으로 확인 → 그 뒤 542(반대면 운영 브랜드가 옛 링크에서 오류 화면만 본다)
- 🔴 **발급 메일 = 브랜드 계정 전원(조각 10 — 개발서버만)**: `notify-orient-sheet` 는 비밀값 `ORIENT_MAIL_TO_BRAND_ACCOUNTS=1` **그리고** 개발 프로젝트일 때만 받는 사람 = 시트 브랜드의 비밀번호를 정한 연결 계정 전원(1명당 1통, 링크 `PUBLIC_BRAND_URL/brand/?orient=<시트 번호>`, 화면 주소 무시, 0명이면 `no_account` — 나중에 다시 보내지 않는다), 양식 `orient-sheet-invite-brand`. 관리자 발급 창(받는 사람 칸 숨김·계정 없는 브랜드 경고·브랜드 페이지 링크)은 `_brandAccountEnabled()` 아래. 🔴 **출시 때 걷을 것 셋**: ①운영 비밀값 `ORIENT_MAIL_TO_BRAND_ACCOUNTS=1` ②함수의 `isStagingProject()` 조건을 걷어 운영 배포(남기면 운영에서 스위치를 넣어도 안 켜진다) ③화면의 `_brandAccountEnabled()` 판정(브랜드 페이지 공통 출시 단계). 옛 양식 `orient-sheet-invite.html` 은 출시 확인 뒤 정리

> - ⚠️ **개발서버 시딩 단가 25행은 아직 가짜 값(`99001~99025`)** — 그 환경에서는 작성 폼을 브랜드에게 내보내지 않는다(구간 단추에 단가가 뜬다). 새 환경도 「견적 기준값」에 실제 금액을 넣고 `99,0` 으로 시작하는 행이 없는지 본다

- 🔴 오리엔시트 표·카드 메모·구간 요금(계산은 서버가 인원으로 재판정 · 구간 인원은 형식별 · 이름 기본값 사본 세 곳)·모집비 직접 지정(캠페인 관리자 이상)·고정 안내 확인(445 가 446 보다 앞 · 🔴 446 적용 뒤 새 폼이 나가기 전에는 시트를 발급하지 않는다 · 운영 순서는 사양서 §7) — 상세 `.claude/rules/orient-sheet.md`
- 🔴 캠페인 발행(판매가는 캠페인 어느 칸에도 자동으로 안 들어간다 · 리뷰어형 제품 금액 0 확인창은 세 경로 모두)·기존 캠페인 연결(모집 형식은 `proxy_purchase` 로만 가른다)·구매 가이드 모드(NULL = 옛 판) — 상세 `.claude/rules/orient-publish.md`

### 오프라인 팝업 방문 예약(티켓팅)
> 상세는 **`.claude/rules/event-ticketing.md`** — 행사 화면(`admin-event.js`·`event-ticket.js`·`event-scan.html`)이나 행사 마이그레이션을 열면 자동으로 읽힌다.
> ⚠️ **기능은 전부 운영에 있으나 아무도 켠 적이 없다** — 데이터 0건. 다음에 쓸 캠페인이 생기면 캠페인 등록·타임 생성·묶음 지정이 필요하다.
> 🔴 **다른 영역을 고칠 때 알아야 하는 셋** (위 규칙 파일은 행사 파일을 열어야 뜬다):
> - **캠페인 변경 이력**(265·266)의 화이트리스트에 행사 칸 4종(`event_mode`·`is_invite_only`·`event_group_id`·`event_selection_mode`)을 **의도적으로 안 넣었다**(세 곳 동시 수정 위험) — 「빠졌다」고 넣지 말 것
> - **인플루언서 일일 다이제스트 메일이 행사 낙선 통지를 겸한다** — 낙선은 응모를 `rejected` 로 두어 그 메일과 「落選」 배지를 그대로 쓴다. 그 메일을 고칠 때 행사가 딸려 온다
> - **선정 기간(`selection_start`/`selection_end`) 표시 조건이 여섯 곳**(인플루언서 상세·관리자 미리보기·진행현황·엑셀·운영현황 일정 뷰·브랜드 페이지 캠페인 상세 — 목록은 `application.js` 그 줄 주석)에서 **글자 그대로 같아야** 한다(폼에만 「이미 값이 저장돼 있으면 보여준다」 예외가 하나 더)
### 인플루언서·관리자
> 상세는 주제별 규칙 파일(아래 지도) — 그 화면 파일을 Read 로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).

> ⚠️ **아직 안 한 것**: 위반 기록 3년 파기는 **행만 지우고 증빙 파일 경로는 대기열에 쌓기만** 한다 — 대기열을 소비하는 화면이 아직 없다(방침 문구에 「집행 완료」로 적지 말 것)

- `influencers`(🔴 회원 본인 직접 UPDATE 로 이메일·동의 시각·가입 시각 변경과 수신 직접 켜기는 거부 — 492, 반드시 SECURITY INVOKER · 신규 가입자는 연령 게이트가 다시 안 뜬다)·`age_policy_settings`·`influencer_flags` — 상세 `.claude/rules/member-profile-tables.md`
- 동적 권한 관리(🔴 `has_permission` 미등록 시 판정이 등급별로 반대 · 슈퍼관리자 잠금 방지 3중 · 「설정 미적용」 12개는 모든 등급에서 무효 · 응급 복구는 직접 UPDATE · 정책을 바꾸는 마이그레이션은 `default_level` 도 함께 UPDATE) — 상세 `.claude/rules/admin-permissions.md`
- `admins`·`admin_password_reset_requests`(원문 이메일 미저장)·`admin_email_subscriptions`·`admin_notices`·`admin_notice_reads`(⚠️ 칸 이름은 `auth_id`) — 상세 `.claude/rules/admin-accounts-notices.md`
- `outbound_influencers`(⚠️ 정책은 `is_admin()` 금지 — `has_permission('outbound.view')`) — 상세 `.claude/rules/outbound.md`

### 응모건 메시지 (인플루언서 ↔ 관리자, 마이그레이션 144·145)
> 상세는 **`.claude/rules/messages-admin.md`** — 메시지 화면(`admin-messaging.js`·`messaging.js`)·메시지 마이그레이션을 Read 도구로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(회원 쪽 화면은 `member-messages.md` · 기획·고문 세션에서는 자동으로 안 읽힌다).
**현재 원본 번호**
- `send_application_message` — **509**(베이스 323. `CREATE OR REPLACE` 로만) · 「응모 끝나고 90일이면 회원은 못 씀」 판정은 **`_application_message_writable`(509) 한 곳**(종료 시각은 `_application_message_ended_at`) — 회원 화면은 `get_my_application_message_status()`(509, 본인 응모 전부 jsonb)로 「지난 문의」를 가른다. 🔴 90일을 화면에서 계산하지 않는다. 배포는 509 먼저

> 🔴 **약관 게이트가 언제·무엇을 근거로 풀렸는지 어디에도 없다** — 개인정보처리방침은 **「문의하기」(인플루언서 → 운영팀) 기준으로** 갱신됐고, **관리자 → 인플루언서 일괄 발송까지 덮는지는 확인되지 않았다.** 판단이 필요하면 `/약관확인`
- `application_messages` — **475 부터 `application_id` 가 비어 있을 수 있다**(일반 문의 행 — 아래 「일반 문의 창구」). 🔴 일괄 발송 `send_application_message_bulk` 현재 원본 **417**(베이스 390)
- ⚠️ **감싸지 않은 `is_admin()` 정책이 운영에 84개 더 있다** — 행마다 평가돼 조회가 느려지면 415 처럼 `(SELECT public.is_admin())` 로 감싼다. 회원 역할 실행 계획은 SQL 편집기에서 `set local role authenticated` 를 넣어야 정책이 평가된다

### 일반 문의 창구 (응모와 무관한 회원 ↔ 운영팀, 마이그레이션 475~483 — ★운영 반영 2026-10-06 · 서비스 문의 여러 대화 504~508 은 **개발서버만**)
> 상세는 **`.claude/rules/general-inquiry.md`** — 문의 화면(`messaging.js`·`admin-messaging.js`)·일반 문의 마이그레이션을 Read 도구로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).

**현재 원본 번호**
- `send_general_inquiry_message`(6인자) · `reopen_general_inquiry_thread` · 뷰 `general_inquiry_thread_summary` — **508**(베이스 505·505·506. 🔴 발신은 `DROP` 후 `CREATE` 라 실행 권한 회수를 다시 건다) · `update_general_inquiry_thread_title` · `_general_inquiry_open_limit`(상한 5 — 숫자는 여기 한 곳) — **508** 신설
- `get_general_inquiry_messages` · `mark_general_inquiry_messages_read` · `general_inquiry_admin_unread_counts` · `purge_audit_data_all` — **505**(베이스 478·478·478·480. 🔴 앞 셋은 `DROP` 후 `CREATE`) · `close_general_inquiry_thread` · `_general_inquiry_resolve_caller` — **505** 신설. ⚠️ 504~508 은 **개발서버에만** 있다 — 운영은 아직 478~480 이 원본이다

- **같은 표에 산다** — 일반 문의는 새 표가 아니라 `application_messages` 에 `application_id` NULL + `influencer_id` 로 들어간다. 🔴 **그래서 응모건을 세는 자리가 일반 문의 행을 딸려 올 수 있다** — 479(관리자 안 읽은 수)·480(감사용 청소)·482(탈퇴 파기 셋, `INNER` → `LEFT JOIN`)가 그 자리들을 고쳤다. 새로 메시지를 세는 조회를 만들면 **`application_id IS NOT NULL` 이 필요한지** 먼저 본다
- 사이드바 메시지 미응대 수는 **두 종류 합산이고 세는 자리가 둘**(`updateInboxSidebarBadge` · 30초 `refreshMsgBadgesLight`) — 한쪽만 고치면 30초 뒤 숫자가 되돌아간다
- 알림은 종류가 `message_received` 그대로이고 **`ref_table='general_inquiry'` 로만 갈린다** — 그 분기가 응모건 분기보다 **앞에** 있어야 한다(`notifications.js`, 뒤에 두면 응모건 화면으로 간다). 탈퇴 화면의 연락 안내는 이 창구로 간다. **로그인할 수 없는 자리**(로그아웃된 확정 회원 안내·가입 실패 안내)는 LINE 유지

### CS 이력 관리 (마이그레이션 555~ — 🔴 개발서버만, 화면 없음)
> 사양서 `docs/specs/2026-10-16-cs-history-management.md` · 작업표 `…-breakdown.md`(조각 21 · 진행은 사양서 「구현 결과」)
- 표 `cs_cases`·`cs_case_messages`(기본 키 = 메시지 id)·`cs_case_comments`·`cs_case_comment_reads` + 비공개 통 `cs-case-attachments` — **556**. 🔴 접근은 **읽기만** `has_permission('menu.messages','read')`(메시지 표의 `is_admin()` 보다 좁다) — 쓰기는 정의자 권한 함수만(표 권한도 SELECT 만). 🔴 응모·대화·메시지·회원·캠페인 외래 키는 전부 **비우기** — 원본이 지워져도 건은 통계로 남는다(앱 건 원본 칸 둘이 다 비면 「원본 대화 삭제됨」). ⚠️ 그래서 **원본을 지우는 경로(캠페인 보관 삭제·탈퇴 파기 등)가 CS 건의 개인정보 사본을 따로 비워야 한다** — 아직 연결 안 됨(4-1)
- 자동 생성 트리거 `trg_cs_case_on_member_message`(메시지 표의 **첫 마이그레이션 트리거**, 회원 글만) + 3개월 백필 — **558**. 🔴 트리거는 **예외를 삼킨다**(회원 문의 발신을 절대 막지 않게 — 대화 잠금 대기 2초) · 실패한 글은 건에 안 붙는다. 🔴 같은 대화 잠금(`hashtext('cs_case_conv:'||…)`)을 잡는 새 함수는 잠금을 **먼저** 잡는다(발신과 교착)
- 조회 함수 넷 `get_cs_cases`·`get_cs_summary`·`get_cs_cases_for_conversation`·`get_cs_comment_summaries` + 내부 `_cs_case_rows`(첫 답장·감사용 제외 한 곳) — **560**. 전부 jsonb 한 값 · 메시지 메뉴 권한 없으면 42501(대화별은 인자가 둘 다 있거나 둘 다 없으면 22023)

### 자동응답(FAQ 가이드형, 마이그레이션 146)
> 🔄 **2026-10-07 회원 화면 진입로가 바뀌었다**: 대화 맨 위 봇 카드는 없앴고, 입력란 왼쪽 「＋」 → 「よくある質問」이 아래 서랍(`#msgFaqSheet`)에 같은 카드를 띄운다. 문의 목록 「対応中」 옆 단추는 따로 떨어진 질문 페이지 `#faq-campaign` / `#faq-service`(`#page-faq`) — 그리는 함수는 오버레이와 같고 **그릴 자리(`_faqHostId`)만 바꾼다**(떠날 때 `cleanupFaqPage` 가 되돌림). 어느 문의에 보일지는 **노출 위치 칸 둘**(마이그레이션 510 — 개발서버만)을 `faqNodeVisibleIn`(shared.js)이 본다 — 자기 칸 + 위 분류 칸이 모두 켜져야 보인다. 🔴 칸이 없는 서버(510 전)는 옛 규칙(`FAQ_GENERAL_CATEGORY_IDS` 카테고리 셋)으로 폴백하지만 **관리자 편집 저장은 새 칸을 보내 실패한다** — 운영은 510 먼저. 질문 문안은 데이터라 패치로 고친다(2026-10-07 운영 대조 정정 `supabase/patches/2026-10-07-faq-accuracy-fix.sql` + 되돌리기, 사양서 `docs/specs/2026-10-07-faq-accuracy-review-2.md`)
> 응모건 메시지의 「문의 게이트」형 FAQ. 사양서 `docs/specs/2026-05-21-message-faq.md`. 빈 구멍 분석 `docs/specs/2026-05-29-message-faq-improvement.md`.
- `faq_nodes` — 자기참조 트리. `parent_id`/`kind`(category|item), `label_ko/ja`, `body_ko/ja`, `action_type`/`action_target`(앱 해시 경로 8종), `is_human_handoff`, `relevant_stages text[]`, `sort_order`, `active`, `show_in_campaign`(기본 true)·`show_in_service`(기본 false — 510). RLS SELECT authenticated / CUD `is_campaign_admin()`
- `faq_interactions` — `action`(viewed|resolved|handoff), `view_count`. `viewed` 부분 유니크. RLS INSERT 본인행 / SELECT `is_admin()`
- `record_faq_interaction(...)` RPC(SECURITY DEFINER, `influencer_id=auth.uid()` 강제, `viewed` 멱등 UPSERT)
- 화면: 관리자 `#adminPane-faq`(`dev/js/admin-faq.js`) / 인플 「문의 게이트」(`dev/js/messaging.js`) / 관리자 응대 보조(`dev/js/admin-messaging.js`). 판정 공용 `faqComputeStatus`/`faqComputeCancelPhase`(`dev/lib/shared.js`). 사양서 `docs/specs/2026-05-21-message-faq.md`

### 정산 (인플루언서 리워드 — 마이그레이션 217~223·299~303·337~342, ★운영 배포 완료 · 337~339·342 포함)
> 상세는 **`.claude/rules/settlement.md`** — 정산 화면·정산 마이그레이션을 열면 자동으로 읽힌다.
> 🔴 **이 영역을 설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).
> 🔴 아래는 규칙 파일이 자동으로 안 읽히는 자리에서도 알아야 하는 것이라 여기 남겼다(다른 영역·현재 원본 번호·잠금 상태 등).
> 🔴 **이 영역 파일은 Read 도구로 연다** — 셸(`cat`·`sed`·`grep`)로 보거나 고치면 규칙 파일이 **안 실린다**.
> 설계·질문이면 **`reverb-settlement` 스킬**이 길을 안내한다(파일을 안 여는 세션용 입구).

**현재 원본 번호** (함수를 재정의할 때 베이스 — 옮긴 덩어리의 ③ 줄마다 한 줄)
- `mark_settlements_paid_bulk` · `mark_settlement_revert` · `mark_settlement_paid` · `register_past_settlements` · `correct_settlement_payment` — **486**(베이스 416·416·343·339·341 아님)
- `_settlement_cert_candidates` — **455**(232 를 베이스로 재작성하면 알림 잠금이 사라진다 — 번호가 가장 큰 정의를 베이스로)
- `get_settlement_transfer_monthly` · `get_settlement_transfer_by_round` — **502**(베이스 487 아님. 🔴 반환 칸을 바꾸면 `DROP` 후 `CREATE` 라 실행 권한 회수를 다시 건다)
- 송금별 요율(513~517, 사양서 `docs/specs/2026-10-02-settlement-per-transfer-fee-rule.md`): `record_settlement_transfers` — **514**(베이스 486) · `preview_settlement_fees` — **515**(베이스 488, 4인자) · `get_settlement_transfers` — **516**(베이스 502) · `correct_settlement_transfer` — **517**(베이스 502, 8인자 — 🔴 옛 6인자는 지웠다. 두 벌이면 화면 호출이 모호 오류). 칸 `settlement_transfers.fee_rule_custom`(513) = 「이 송금만」 — 저장 순간 설정과 요율·고정액이 다름(끝수 비교 안 함), 화면은 이 저장값만 본다
- `backfill_settlement_transfers_from_sheet` — **501**(과거 지급 시트 소급 전용. 🔴 시트 소급은 이것으로만 — `record_settlement_transfers` 로 넣으면 출처가 `app` 이 되어 그 순간 도입일이 생긴다)

**송금 묶음·수수료**(마이그레이션 484~488 — ★**운영 반영 완료 2026-10-01**(문의 창구 475~482 보다 먼저, 골라 담기 #1831). 🔴 **운영 첫 기록 전**: 「미등록 응모를 묶음으로 기록」 경로를 시험 데이터로 한 번 — 첫 기록이 곧 도입일이다. 사양서 `docs/specs/2026-09-30-settlement-transfer-fee-record.md`)
- 🔴 **`source='app'` 묶음이 한 줄이라도 생기면 옛 송금완료 경로 셋이 거부된다**(`payout_bundle_required`) — **운영 SQL 편집기에서 `record_settlement_transfers` 를 시험 호출하지 말 것**(첫 기록이 곧 도입일, 되돌릴 함수 없음)

> ⚠️ **코드와 데이터베이스는 운영에 있지만 인플루언서에게는 잠겨 있다** — 🔴 **인플루언서 노출은 코드에서 제거됐다(343)** — 노출 스위치 `influencer_visible` 은 바꿔도 아무 일도 안 일어난다(`cutoff_at` 은 노출이 아니라 자동 등록 스위치 — 지금 꺼짐). 되살리는 절차·실제 송금 기록(회차 송금 명단 엑셀 포함)·남은 일은 `settlement.md`
- 🔴 **화면 버튼과 그것이 부르는 서버 함수는 같은 배포에 묶이지 않는다** — 화면은 머지로, 함수는 SQL 편집기로 나간다. **잠금을 푸는 변경은 함수 적용을 확인한 뒤 머지할 것**
- 🔴 회차 송금 명단의 「이전 회차 미지급」 범위 아래 끝 `PAYOUT_CARRYOVER_FROM`(2026-10-15) 을 앞당기지 말 것(시트로 이미 보낸 건이 섞여 이중 송금)

- 🔴 **인증 성공 판정은 사본이 여러 곳**(서버 후보 함수·검수 화면·엑셀·검수 결과 메일·인플루언서 일일 메일·일정 뷰·관리자 일일 메일 다섯째 절·브랜드 공유) — 판정을 고치면 전부 본다. 상세 `.claude/rules/cert-success.md`
- 🔴 **리뷰어형 정산 금액 = 영수증 실결제액(제품 가격 상한)**, 화면·메일 문구는 금액을 약속하지 않는다(다섯 자리가 같은 말) — 상세 `.claude/rules/receipt-amount.md`
- ⚠️ `settlement.view` 를 캠페인 매니저에게 열면 PayPal 이 노출된다 · 신청 반려·취소 → 정산 자동 보류 트리거·화면 가드 · 송금 묶음 표·확인 창·화면 배타 — 상세 `.claude/rules/settlement.md`

### 회원 탈퇴 (마이그레이션 345~367 — ★운영 배포 완료 · 회원이 실제로 탈퇴할 수 있다)
> 상세는 **`.claude/rules/member-withdrawal.md`** — 탈퇴 메일·파기 함수·탈퇴 마이그레이션·관리자 회원 화면을 열면 자동으로 읽힌다.
> 🔴 **이 영역을 설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).
> 🔴 아래는 규칙 파일이 자동으로 안 읽히는 자리에서도 알아야 하는 것이라 여기 남겼다(다른 영역·현재 원본 번호·잠금 상태 등).
> 🔴 **이 영역 파일은 Read 도구로 연다** — 셸(`cat`·`sed`·`grep`)로 보거나 고치면 규칙 파일이 **안 실린다**.

**현재 원본 번호** (함수를 재정의할 때 베이스 — 옮긴 덩어리의 ③ 줄마다 한 줄)
- `cancel_withdrawal` — **356**
- `request_withdrawal` · `request_withdrawal_for_member` · `advance_withdrawal_states` — **450**
- `purge_withdrawn_personal_data` — **520**(352 → 396 → 520)
- `_withdrawal_cancel_event_ticket` — **418**(베이스 350)
- `cancel_application` — **394**

> - ⚠️ **362(가입 차단)만 양쪽 다 안 넣었다** — `auth.users` 트리거라 실수하면 회원가입이 전면 중단된다. 별도 확인 후 적용
> - ⚠️ **시행 전 잠금이 살아 있다**(`withdrawal_settings.effective_date` 비어 있음). 승인된 결과물·행사 응모·정산 기록·받지 못한 보수 **넷 중 하나라도** 있으면 스스로 못 나가고 운영팀 연락(LINE)으로 간다 — 관리자 대행(작업 19)
> - ⚠️ **6개월 파기(작업 12)는 대상이 아직 0건** — 운영에서 실제로 지워진 파일은 없다
> - ⚠️ **아직 안 한 것(본문은 규칙 파일)**: 대행 확인 창의 「받지 못한 보수 건수·시행일 전 경고」(화면 몫) · 탈퇴 확정 계정의 **응모건 메시지 발송은 안 막는다**(구멍 — 작업 2에서 재판단) · **관리자 수동 행사 취소(288)는 송금완료만 본다**(같은 사고가 그 경로로 재현될 수 있다 — 후속 과제 C-2) · **메시지 첨부 파기(작업 12-B)도 운영에서 실제로 돈 적이 없다** · **페이팔 5년 파기는 효과 확인에 5년** — 시험 데이터로 확정일을 5년 전으로 돌려 한 번은 돌려 볼 것(아직 안 함) · **강제 탈퇴(자격 상실)는 값만 있고 화면이 안 보낸다** — 여는 날 예정일 메일의 대행 문단(`{{proxy_notice}}`) 분기를 볼 것

- 🔴 **탈퇴 확정 계정 차단 장치**(프로필 수정·응모 삽입·행사 예약·결과물 제출·두 번째 탈퇴 신청 — 통과 조항 둘·대기자 승격 예외, 거부 코드 `account_withdrawn` 은 `ui.js`·`shared.js` 두 곳) — 상세 `.claude/rules/withdrawn-account-guards.md`
- 탈퇴 신청·상태 전이·행사 예약 정리·개인정보 파기·페이팔 5년 파기·재가입 차단(361 운영 적용 · 362 미적용 — 설계는 규칙 파일)·홍보 메일 제외·영수증 파기·관리자 화면(사이드바 아이콘 자리 규칙 포함) — 상세 `.claude/rules/member-withdrawal.md`
- ⚠️ 관리자 사이드바 경고 아이콘은 **항목마다 장치 하나 · 자리 셋**(나중에 도는 쪽이 이긴다) — 상세 `.claude/rules/admin-sidebar-indicators.md`

### 일별 방문자수 (마이그레이션 332)
> 상세는 **`.claude/rules/site-visits.md`** — 관리자 대시보드(`admin-dashboard.js`)·마이그레이션 332를 Read 도구로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).
- `site_daily_visits` + `record_site_visit(p_app, p_is_new_visitor)`(관리자·감사용 계정은 서버가 제외, 날짜는 서버가 만든다)
- ⚠️ 호출은 **부팅 1회**, **세션 복원 뒤**(`dev/js/app.js` `init()` 의 `updateGnb()` 직후) — 아니면 **운영자 접속이 방문자로 세어진다**
- ⚠️ **관리자·감사용 제외는 SQL 편집기로 검증 못 한다**(서비스 키라 그 분기가 안 돈다 — 마이그레이션 272 와 같은 함정). 로그인 브라우저로만 확인
- ⚠️ **저장소를 못 쓰면 세지 않는다 — 조회수(263)와 정반대이고 의도한 것이다.** 하루 한 행이라 한 사람의 새로고침이 그대로 그날 수가 된다. 「일관성 없다」며 맞추지 말 것 (`_markSiteVisited`·`recordSiteVisit`)

### 메타 픽셀 (마이그레이션 438·439 — ★**운영 적용 완료** · 🔴 **운영 전송 중**(설정 시행일 `2026-09-18` · 켜짐 · 아이디 입력))
> 상세는 **`.claude/rules/admin-tools.md`** — 광고 추적 화면·`meta-pixel.js`·픽셀 마이그레이션을 Read 도구로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).
> 방문·가입·신청을 Meta 로 보낸다. 관리 화면은 「광고 추적」, 전송은 `dev/js/meta-pixel.js`. 사양서 `docs/specs/2026-09-03-meta-pixel.md` · 작업표 `…-meta-pixel-breakdown.md`
> 🔴 **잠금 구조** — 설정 시행일이 비었거나 미래면 켜기 거부·앱용 조회 빈 값. **그 날짜 입력이 곧 잠금 해제**. ⚠️ 방침 문서·앱 공지·통지 메일의 시행일 `2026-10-17` 은 어긋남이 아니라 사용자 결정이다. 되돌리지 말 것.
- 🔴 **시행일 판정식은 `_meta_pixel_policy_in_effect(date)` 한 곳**이고 저장 거부·앱용 조회·상태 배지가 그것을 부른다. 식 = `p_date IS NOT NULL AND p_date <= (now() AT TIME ZONE 'Asia/Tokyo')::date`. **다른 함수에 복사하지 말 것**
- 🔴 **민감 주소 판정은 부팅 때 한 번뿐**(`metaPixelUrlHasSensitiveValue`) — 이미 켜진 탭에서 주소에 붙는 값은 못 막는다. 그래서 **초대 번호는 주소에 남기지 않는다** — 저장소(`reverb.inviteCtx`)가 기억하고 `captureInviteFromHash` 가 주소에서 걷어낸다(`stripInviteFromUrl`, 저장소를 못 쓰면 남김). 주소에 값을 싣는 새 링크를 만들면 같은 처리를. ⚠️ 초대 링크로 처음 들어온 방문은 픽셀이 꺼진 채 시작한다(의도). **iOS 앱(Capacitor 웹뷰)에서는 꺼짐**(앱 추적 투명성 동의 없음)
- 🔴 **배포는 데이터베이스 먼저, 코드 나중** — 반대면 없는 함수를 불러 오류가 쌓인다. ⚠️ 개발에서 앱 코드가 438 보다 먼저 나간 적이 있다. 439 는 438 뒤, **관리 화면과 같은 배포**에(화면은 못 읽으면 열고 서버는 거부 — 방향이 반대)

### 메일·기준 데이터·알림
- `lookup_values` — 기준 데이터. `kind`(channel/category/content_type/ng_item/reject_reason/blacklist_reason/violation_reason/caution/admin_email_kind/cancel_reason/**admin_proxy_reason**), `code`, `name_ko`, `name_ja`, `sort_order`, `active`, `recruit_types[]`(channel 만 사용). `admin_proxy_reason`(마이그레이션 160) 시드 4건: shipping_delay/system_error/inflexible_deadline/other. 🔴 **종류 검사 제약의 현재 원본은 555**(18종 — 554 의 17종[346 + `shipping_carrier`]에 `cs_category` 추가. 위 목록은 일부 — 전체는 555 파일). 🔴 **이 제약을 고칠 땐 병합 직전 origin/dev 의 마지막 정의를 다시 본다**(같은 날 554·555 가 따로 만들어졌다). `cs_category`(CS 항목 8행, 개발서버만) 중 `legacy_unclassified`(미분류(과거) — 백필 전용)는 트리거 `trg_lookup_cs_legacy_lock` 이 로그인 역할의 이름·활성·코드 변경과 삭제를 거부(`cs_legacy_locked`) — **정렬 번호만은 통과**(순서 변경 `swapLookupOrder` 가 두 행을 따로 고쳐서)
- `participation_sets` — 참여방법 번들. `name_ko`/`ja`, `recruit_types[]`, `steps jsonb`, `sort_order`, `active`. `campaigns.participation_steps jsonb` 스냅샷 + `participation_set_id` FK ON DELETE SET NULL
- `caution_sets` — 주의사항. items `{text_ko, text_ja, link_url?, link_label_ko?, link_label_ja?, text_after_ko?, text_after_ja?}`. `campaigns.caution_items jsonb` + `caution_set_id` FK ON DELETE SET NULL. RLS SELECT 관리자
- `ng_sets` — NG. items `{html_ko, html_ja}`(DOMPurify, inline 서식만). `campaigns.ng_set_id` + `ng_items jsonb` 스냅샷. RLS SELECT `is_admin()`, CUD `is_campaign_admin()` 이상.
- `notifications` — 인플루언서 알림. `kind`(deliverable_rejected/deliverable_changed/deliverable_approved/application_cancelled/message_received/application_approved/**deliverable_proxy_submitted**/**settlement_paypal_required**/**settlement_paid**), `ref_table`/`ref_id`, `title`, `body`, `read_at`. deliverable_* 는 status 전이 트리거가 생성, 재제출 시 미읽음 자동 dismiss. `message_received`(145)=관리자 답장 시 send 함수 · `application_approved`(154)=→approved 전이 시 `record_application_status_event()`(「キャンペーンに当選しました」 — 당선 안내) · `deliverable_proxy_submitted`(160)=대리 등록 시 `admin_create_deliverable_proxy()`(「結果物が登録されました」 — 결과물 등록됨). 셋 다 **미읽음 중복 방지**. 클릭 시 `message_received` 는 메시지 모달, `application_approved`/`application_cancelled`/`application_restored`는 응모이력(ref_table='applications' 공유라 kind 한정 필수). 🔴 **종류 검사 제약의 현재 원본은 440**(13종) — 376 이 아니라 440 을 베이스로
- `admin_daily_digest_runs` — 관리자 통합 다이제스트 로그. `digest_date` UNIQUE(mutex) + `status CHECK(sent|skipped_no_data|failed)` + `sections_summary jsonb`(`{received, cancelled, submitted, reprocessed}`) + `recipients_count` + `error_message` + `run_at`. RLS SELECT `is_admin()`, INSERT 는 service_role 만
- `influencer_daily_digest_runs` / `application_received_admin_digest_runs` — 로그. `digest_date` UNIQUE
- `deadline_reminder_email_sent` — D-5·D-1 임박 메일 재발송 차단. UNIQUE `(influencer_id, campaign_id, kind, d_minus)`
- 캠페인 홍보 메일 4종(주 2회, 모두 RLS SELECT `is_admin()`·쓰기 정책 없음 → service_role만):
  - `campaign_promo_digest_runs` — run 로그. `digest_date` UNIQUE mutex + `status`/카운트/`included_campaign_ids`/`started_at`·`finished_at`
  - `campaign_promo_digest_sent` — `(influencer_id, digest_date)` UNIQUE(1통/cron) + `skip_reason`
  - `campaign_promo_exposure` — `(campaign_id, influencer_id, kind)` UNIQUE(캠페인당 최대 2회)
  - `campaign_promo_email_clicks` — CTA 클릭. `(campaign_id, influencer_id)` UNIQUE
  - 관련 RPC: `get_promo_digest_targets(date)`·`get_promo_digest_campaign_pool(date)`·`mark_promo_digest_sent`·`track_promo_click`(anon)·`unsubscribe_by_token`(anon 1-click 수신거부)·`resubscribe_marketing`(본인 재구독)
- 헬퍼 `_yesterday_kst_window()` STABLE — 어제·오늘 KST 날짜

### 사용자 앱 에러 수집 (마이그레이션 165)
> 상세는 **`.claude/rules/admin-tools.md`** — 오류 로그 화면·`error-report.js`·오류 로그 마이그레이션을 Read 도구로 열면 자동으로 실린다. 🔴 **설계·수정하면 그 파일부터 연다**(기획·고문 세션에서는 자동으로 안 읽힌다).
- `report_client_error`(비로그인 수집) 현재 원본 **522**(베이스 308) — 🔴 인자 10개 그대로 `CREATE OR REPLACE` 로만(틀리면 수집 전체가 조용히 멈춘다). 🔴 브라우저 문자열·회원 아이디·받은 시각(`identity_at`)은 **한 쌍으로** 함께 갱신 · `resolve_client_error` 현재 원본 **522**(베이스 518)
- **보관 3개월**(522 · 개인정보처리방침 「자동 수집 3개월」 근거) — 매일 `identity_at` 기준으로 쌍을 비운다. 탈퇴 확정 회원은 520 이 즉시

### RLS·인증·세션
- 캠페인 SELECT 공개, 나머지는 본인 or 관리자만
- `is_admin()` / `is_super_admin()` / `is_campaign_admin()`: admins 에서 auth.uid() 조회(search_path 고정)
- 트리거: auth.users 생성 시 influencers 자동 생성
- 세션 만료: `retryWithRefresh()` 로 갱신 후 1회 재시도
- **함수 실행 권한 — 회수 방향이 둘이다**(마이그레이션 369·370): **Postgres 는 새 함수에 PUBLIC 실행 권한**을, **Supabase 는 거기 더해 `anon`·`authenticated` 에 개별로** 준다. `REVOKE ALL FROM PUBLIC` 은 개별 부여를, `REVOKE … FROM anon, authenticated` 는 PUBLIC 부여를 못 걷는다 — **서로를 대신하지 못한다.** ⚠️ **`has_function_privilege` 만 보면 방향을 모른다**(PUBLIC 이 남으면 둘 다 `true`) — `p.proacl::text` 의 **맨 앞 `=X/`** 유무를 함께 볼 것. ⚠️ **개발과 운영의 권한 상태가 다를 수 있고 저장소 문서로는 못 알아낸다** — 직접 조회할 것. ⚠️ `REVOKE` 는 **대상이 없어도 「Success」** — 돌린 뒤 다시 조회해 확인. ⚠️ 안쪽 호출은 감싸는 함수가 **`SECURITY DEFINER`** 라 산다 — **`SECURITY INVOKER` 로 부르면 끊긴다**(`recompute_campaign_applied_count` 를 잘못 건드리면 **응모가 통째로 막힌다**. 증명 절차는 370 주석). ⚠️ **순수 계산 함수 3종은 일부러 안 닫았다**(`_meets_min_followers`·`_withdrawal_email_hash`·`_accumulate_legacy_no` — 표를 안 읽는다)
- **함수 실행 권한 — 「안쪽에 호출자 검사가 없는 함수」는 별도로 훑는다**(마이그레이션 375): 본문에 `is_admin()`·`auth.uid()` 검사가 없으면 권한 부여가 **유일한 방어선**이다. `anon`·`authenticated` 를 **따로** 보고, 회수 전에 `service_role` 이 자기 권한을 따로 갖는지 확인(PUBLIC 경유뿐이면 메일이 통째로 죽는다) — 실제 사례·절차는 `.claude/rules/supabase.md` 「호출자 검사 없는 함수」
- ⏸️ **아직 안 닫은 것 — 판단 대기**: `is_email_withdrawal_blocked(text)` 는 **비로그인에 일부러 연 것**이다(362 미적용이라 **유일한 재가입 차단 수단**). 그런데 **임의 이메일의 탈퇴 여부를 알려 줘** 361·362 의 「실패 문구를 같게」 설계와 어긋난다. **지금은 시행일이 비어 항상 거짓.** **작업 18(약관 개정)·362(가입 차단)와 함께 판단할 것**

- 🔴 **`auth.users` 가입 인증번호 관문 둘**(마이그레이션 493~499 · 미인증 계정 정기 삭제 503 — 상세 `.claude/rules/member-signup-auth.md` 「가입 인증번호 관문」): 🔴 **고쳐 쓰기 관문은 로그인·토큰 갱신마다 돈다**(브랜드·관리자 계정 포함) — 첫 줄 `OLD.email_confirmed_at IS NOT NULL → 통과` 를 옮기지 말 것 · 끄기 = 트리거 지우기(`DISABLE TRIGGER` 는 안 된다) · 트리거 함수 둘은 **반드시 `SECURITY INVOKER`** · `_strip_signup_meta` 현재 원본 **497** · 🔴 개발서버 「메일 대신 화면」 두 겹 잠금(`SIGNUP_CODE_DEV_ECHO=1` + 개발 프로젝트 주소)을 하나라도 지우면 운영에서 번호가 응답에 실려 인증이 무력해진다

## Test Accounts
- 관리자: admin@kemo.jp / admin1234
- 테스트 인플루언서: sakura.test@reverb.jp, yui.test@reverb.jp, haruka.test@reverb.jp (비밀번호: test1234)
- 브랜드 페이지(개발서버만, 비밀번호 둘 다 zzBrand-test1!): zz-b2-owner@example.com — 시험 브랜드 셋(「zz-묶음2 시험 하루담」·「가나다 시험」·「Aroma Farm 시험」)의 대표 / zz-b2-second@example.com — 「가나다 시험」·「Aroma Farm 시험」 멤버 / zz-b2-new@example.com — 초대로 가입한 「가나다 시험」 멤버(2026-10-15 묶음 ② 시험용)

## Dev Workflow
- 개발: dev/ 에서 수정 → dev/index.html 로 확인
- 배포: `cd dev && bash build.sh` → 루트 index.html 자동 업데이트
- 파일명이 기능과 일치 (캠페인=campaign, 로그인=auth 등)
- DB API: `dev/lib/storage.js` 에 모든 DB 함수 집중 (fetchCampaigns, upsertInfluencer 등)
- 세션: onAuthStateChange 로 SIGNED_IN/TOKEN_REFRESHED/SIGNED_OUT/SESSION_EXPIRED 처리 (양쪽)
- URL 정제: `cleanUrl()` 로 마크다운 링크 형식 자동 변환 (product_url 등)
- 페이지 전환: 같은 탭에서 이동 (새 탭 금지). ⚠️ **예외 2종은 새 탭이 맞다** — ①앱 경계를 넘는 전환(인플루언서 앱 → `/admin/`, `dev/js/app.js`) ②**자립형 단독 화면**(`admin-setpw.html`·`event-scan.html` — 현장 확인은 부스 단말용). 되돌리지 말 것
- 깜빡임 방지: visibility:hidden cloak (양쪽)
- 마이페이지 서브해시: `#mypage-applications` 등으로 복원
- 약관/정책 수정: `docs/{TERMS,PRIVACY}_{kr,ja}.md` 가 source of truth. 앱 푸터 약관은 `dev/lib/legal.js` 가 이 4개 md 를 **런타임 fetch + 렌더링** — 빌드 무관. 한·일 동시 수정 + 부칙 갱신 (`.claude/rules/policy.md`)

## Conventions
- 인플루언서 페이지 UI 텍스트: 일본어
- 관리자 페이지 UI 텍스트: 한국어
- 코드 주석: 한국어 (일본어 금지)
- 날짜 포맷: ja-JP
- `lang="ja"`

## Rules
- 관리자 페이지는 반드시 PC 레이아웃 유지 (모바일 쉘 금지). ⚠️ **관리자 뷰포트는 `width=1280` 고정** — `width=device-width` 면 `#page-admin`(fixed·overflow:hidden) 안 900px 레이아웃이 잘려 **모바일에서 오른쪽이 안 보이고 스크롤·축소도 안 된다**. 자립형 화면(`admin-setpw`·`event-scan`·`report`)과 오리엔시트 인쇄 새창은 대상 아님
- 인플루언서 페이지만 모바일 전용 (480px)
- db 참조 시 항상 `db?.from()` 사용 (null-safe)
- `.single()` 대신 `.maybeSingle()` 사용
- localStorage 이미지 base64 는 별도 키로 분리 (용량 초과 방지)
- 캠페인 삭제는 **보관 삭제(soft delete)** — 🔴 저장소 파일은 신청을 지우기 **직전에** 경로를 모아 화면이 지운다(뒤집으면 지울 방법이 없다) · 정산 걸린 캠페인은 삭제 차단 — 상세 `.claude/rules/campaign-admin.md`
- 이미지 업로드는 Supabase Storage (`campaign-images` 버킷) 사용
- 비밀번호 재설정: Authentication → URL Configuration → Redirect URLs 에 양 도메인 등록 필수
- 아이콘은 Material Icons 사용 (이모지 금지), `translate="no"` 필수
- 하드코딩 DOM 인덱스 금지 (`:nth-child` 인덱스 직접 사용 금지)
- **이미지 썸네일은 올릴 때 저장한 사본**(`storageThumbUrl`) — 🔴 유료 변환(`imgThumb`)을 되살리지 않는다 · `onerror` 원본 폴백 필수 · 🔴 원본은 압축하지 않는다 · 파기하는 자리는 썸네일도 함께 — 상세 `.claude/rules/image-thumbnails.md`
- 채널 비교는 항상 `split(',')` 후 `includes()` 사용 (단일 `===` 비교 금지 — 멀티채널 누락 위험)
- **채널 코드 이관은 기준 데이터·캠페인·결과물 3곳 동시가 한 세트**(관리자 도구로 못 고친다) · 채널 변경 가드·감지 장치 — 상세 `.claude/rules/channel-code.md`
- **최소 팔로워수 정책**은 채널 묶음별 갈래 셋 · 🔴 판정이 화면(`shared.js`)과 홍보 메일 SQL 두 곳 · 표시 다섯 곳 — 상세 `.claude/rules/min-followers.md`
- **Sales(광고주) 서브도메인 규칙**: `sales.globalreverb.com` / `sales-dev.globalreverb.com` UI 한국어, `<meta name="robots" content="noindex,nofollow">` 유지. `/reviewer`·`/seeding` 은 Vercel `cleanUrls`. 파일 업로드 없음
- **익명 폼 INSERT 패턴**: anon 이 쓰는 테이블은 `.insert().select()` 대신 **SECURITY DEFINER RPC** 로 (RETURNING SELECT 충돌로 42501)
- **관리자 리스트 IntersectionObserver lazy-load**: 8개 페인(campaigns/applications/deliverables/camp-applicants/influencers/lookups/admin-accounts/brand-applications) sentinel 점진 렌더(필터·검색·정렬 변경 시 리셋 필수). `renderAppCampList` 는 campaigns/applications/influencers 캐시 공유
- **PostgREST 1000-row cap 대응**: 집계용 fetch(`fetchInfluencers`/`fetchApplications`/`fetchDeliverables` 등)는 `range(from, from+999)` 루프로 전건 조회. 단일 `.from().select()` 는 1000건에서 잘림
  - **무거운 목록은 페이지를 동시에 받는다**(2026-09-30): `fetchAllPagedFast`(storage.js — 결과물·신청·인플루언서 목록). 🔴 **조건 둘** — ①일반 표 조회만(`db.rpc` 는 페이지마다 함수 전체가 다시 돌아 부하가 몰린다) ②정렬 끝에 **`.order('id')`**(고유 순서가 아니면 페이지 경계에서 한 건이 겹치거나 빠진다 — `fetchAllPaged` 도 같다). 번호 목록을 200개씩 끊는 조회도 `mapLimit`(최대 4개 동시) — ⚠️ 함수마다 실패 규약이 다르다(`{}`·`null`·「실패 조각만 건너뜀」), 옮길 때 그대로. ⚠️ 운영 데이터베이스가 가장 작은 사양이라 **결과물 조회는 동시 2개**
- **인플루언서 앱 캠페인 목록 보관**(`getCampaignsCached`) — 신청 인원을 바꾸는 동작 뒤에는 `invalidateCampaignsCache()` — 상세 `.claude/rules/member-app-screens.md`

## Mobile Layout Rules
- `#appShell` 은 `position:fixed` + `top:0`/`bottom:0`
  - 🔴 **회원 빌드는 `overflow:clip`**(`member-ui.css`) — `hidden` 은 코드 스크롤을 못 막아, 닫힌 햄버거·알림 창 안에 초점이 들어가거나 `scrollIntoView` 가 불리면 **껍데기 자체가 밀려** 닫힌 창이 반쯤 보이고 클릭을 가린다(2026-10-06, 운영에도 있던 결함). `hidden` 으로 되돌리지 말 것. 닫힌 두 창은 미끄러져 나간 뒤 `visibility:hidden`
- html, body 에 `height:100%` + `overflow:hidden` 유지
- 페이지 콘텐츠 스크롤은 `.page.active` 내부에서만 (`flex:1` + `overflow-y:auto`)
- GNB 는 `flex-shrink:0` 고정 (바텀탭 없음 — 햄버거 메뉴)
- 모바일 키보드: visualViewport API 로 `appShell` 높이 동적 조절
- input/textarea/select 의 `font-size` 는 반드시 16px 이상 (자동 확대 방지)
- `100vh`/`100dvh` 대신 `position:fixed` + `top:0`/`bottom:0` 사용 (키보드 안정성)
- 캠페인 상세 URL 은 `#detail-{id}` (새로고침 복원)

---

## 변경 이력
이력성 메타데이터(마이그레이션 번호·PR 번호·deprecated 메모·과거 변경 사항)는 [`docs/CLAUDE-ARCHIVE.md`](docs/CLAUDE-ARCHIVE.md) 참조.
