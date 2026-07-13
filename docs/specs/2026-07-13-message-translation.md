# 응모건 메시지 자동 번역

**작성일:** 2026-07-13
**상태:** dev 구현 완료 (운영 미배포 — 약관 PR3 선행 필수)
**관련:** `docs/specs/2026-05-15-application-messaging.md`(메시지 원 기능), CLAUDE.md 「응모건 메시지」, 메모리 `project_message_faq`

> 인플루언서(일본어)와 관리자(한국어)가 응모건 메시지에서 서로 다른 언어로 대화하는데, 지금은 번역이 없어 관리자가 일본어 원문을 직접 읽고 답한다. **상대방 메시지를 내 언어로 자동 번역**해 병기/표시하는 기능.
> 사용량 검토(2026-07-13): 피크였던 6월 총 102,033자(양방향) — 무료 번역 한도(월 50만 자)의 20%. **무료 플랫폼으로 충분**, 트래픽 5배까지 여유.

---

## 현재 상태 (2026-07-13 기준, 코드 조사)

### 관련 코드·DB·UI 진입점
- **DB**: `application_messages(body text, sender_kind text[influencer|admin], attachments jsonb, created_at, mask_state 계열)` — 마이그레이션 144·145. INSERT/UPDATE/DELETE는 **SECURITY DEFINER RPC 경유만**(직접 변조 차단).
- **발송 RPC**: `send_application_message(p_application_id, p_body, p_attachments)` — sender_kind 자동 판별, rate limit 100/h, 관리자 발신 시 `message_received` 알림.
- **조회 RPC**: `get_application_messages(p_application_id)` RETURNS TABLE(... `body`, `mask_state`['visible'|'hidden_by_admin'|'self_withdrawn_*'] ...) — 역할별 비대칭 마스킹. **번역본을 실으려면 이 반환 스키마에 컬럼 추가 필요.**
- **렌더(인플)**: `renderMessageThread`(dev/js/messaging.js:172~) — 본문 `esc(msg.body).replace(/\n/g,'<br>')`(:201), 말풍선 `.msg-card`. `mask_state !== 'visible'`이면 placeholder 표시(:188~).
- **렌더(관리자)**: dev/js/admin-messaging.js — 받은편지함 3단 페인 + 스레드.
- **i18n**: 인플 화면만 ja/ko 토글(`dev/lib/i18n/*`). 관리자 화면은 한국어 고정.
- **Edge Function 패턴**: 대부분 웹훅·pg_cron·트리거 실행(CORS 불필요). **브라우저에서 `functions.invoke()` 직접 호출하는 함수는 CORS 헤더 + OPTIONS preflight 필수**(`.claude/rules/supabase.md`, 오리엔 발급 메일 전례).
- **처리위탁**: 개인정보처리방침(`docs/PRIVACY_{ja,kr}.md`) 처리위탁·국외이전 표에 Supabase·Vercel·Brevo만 등재. 「応募件運営お問い合わせ・添付」 데이터는 이미 Supabase(도쿄) 위탁 기재됨.

### 이 제안과 충돌 가능성 있는 기존 동작
- **마스킹과의 정합**: 강제숨김·본인 회수 메시지는 화면에서 placeholder로 가려짐. 번역도 **원문이 가려진 메시지는 번역/표시 안 함**으로 맞춰야 함(mask_state 존중).
- **FAQ 자동응답 봇**: 인플 문의 게이트의 FAQ 문안은 이미 ja/ko 양쪽 보유 → **번역 대상 아님**(원문 그대로).
- **XSS 방어**: 본문은 `esc()` 후 `\n`만 `<br>` 치환. 번역본도 **동일하게 esc() 적용** 필수(외부 API 반환값도 신뢰 금지).
- 그 외 **충돌 없음** — 기존 테이블·RPC에 컬럼/반환 필드 추가 확장 방식.

### 미해결 백로그·관련 작업
- 응모건 메시지 일괄발송(broadcast)은 운영 보류(약관 게이트). 번역과 독립.
- 정산·포인트 등 다른 진행 건과 무관(영역 분리).

---

## 의심·경우의 수 (규칙 B — 반대론자 검증)

1. **번역 시점·아키텍처(가장 큰 분기)** — 발송 RPC는 DB 함수라 외부 HTTP를 직접 못 부른다(pg_net 확장 필요). 세 방식:
   - (A) **발송 직후 클라이언트가 Edge Function 호출** → 번역 결과를 UPDATE. ⚠️브라우저 직접 호출이라 **CORS 필수**(오리엔 메일 전례처럼 누락 시 조용히 실패).
   - (B) **INSERT 트리거 → pg_net으로 Edge Function 비동기 호출** → UPDATE. 프로젝트 웹훅 패턴과 일치, **CORS 불필요**, 발송 트랜잭션과 분리(best-effort). ⚠️pg_net 확장 활성 필요 + 번역 도착 전 과도기(원문만 보임).
   - (C) **조회 시점 번역 + 캐싱**. 첫 조회가 느리고 재조회 비용 위험 → 비권장.
   - → **(B) 트리거/웹훅 권장**(CORS 회피·패턴 일치). 과도기 UX는 "번역 중" 표시로 처리.
2. **재번역 비용 폭증** — 화면 열 때마다 다시 번역하면 API 글자수가 실제 저장량의 몇 배. **번역 결과를 DB에 1회 저장(캐싱)**해 재조회 시 재호출 0 — 사용량 검토(월 50만 자 여유)의 전제.
3. **번역 실패·지연** — 외부 API 장애·타임아웃·한도 초과 시. **원문 폴백**(번역 없으면 원문만 표시, 발송·조회는 절대 안 막음). 실패는 status='failed'로 남기고 재시도 대상.
4. **마스킹된 메시지 번역** — 숨김/회수 메시지를 번역해 두면 번역본으로 원문이 새어나갈 위험. **mask_state≠visible이면 번역 컬럼도 마스킹**(get_application_messages에서 body와 동일 규칙).
5. **개인정보·약관(법률)** — 메시지 본문을 외부 번역사(DeepL/Google 등)에 전송 = **신규 처리위탁 + 국외이전**. 개인정보처리방침 개정(처리위탁·국외이전 표에 번역 플랫폼 추가) + 시행일 이전 통지 필요(release-timing 규칙). 본문에 배송지·연락처가 섞일 수 있어 **민감정보의 국외 전송**이라는 점 고지.
6. **UX — 표시 방식** — ①번역만 보여주기 ②원문+번역 병기 ③토글. 관리자는 원문(일본어) 검증이 필요할 수 있어 **병기**가 안전, 인플은 관리자 한국어를 몰라 **번역 위주 + 원문 접기**가 나을 수 있음. 오역 시 원문 확인 경로가 없으면 분쟁 위험.
7. **UX — 자기 메시지** — "상대 메시지를 내 언어로"가 원칙. 내가 쓴 메시지는 원문 그대로(번역 불필요). 발신자==뷰어면 번역 표시 생략.
8. **언어 오판** — 인플이 한국어로, 관리자가 일본어로 쓰는 예외. sender_kind로 원본 언어를 가정(influencer=ja, admin=ko)하면 오판 가능 → 번역 API 자동 감지 사용 or 동일 언어면 skip.
9. **엣지케이스** — 빈 본문(첨부만)·이모지·URL만 있는 메시지는 번역 skip(글자수·비용 절약). 초장문은 길이 상한.

### 현재 구현 충돌점
**충돌 없음 — 확인 완료.** 기존 테이블·RPC 확장이며 마스킹·XSS·발송 흐름은 유지. 단 §의심 4·6은 설계에 반영 필수.

### 의도 모호점
- "번역 기능" = **양방향 전부** vs **인플 일본어→관리자 한국어만**(관리자 읽기 보조). 후자면 절반 비용·절반 구현. → 사용자 확인.
- 표시 = 병기 vs 번역만 vs 토글. → 사용자 확인.
- 번역 플랫폼(DeepL/Google/LibreTranslate). → 사용자 확인.

---

## 제안 / 설계

### 데이터 모델 (신규 마이그레이션 1개 — 컬럼 추가)
`application_messages`에 컬럼 추가(개수·번호는 개발 세션 확정):
- `body_translated text NULL` — 번역본(상대 언어)
- `translated_lang text NULL` — 번역 도착 언어('ko'|'ja')
- `translate_status text` — 'pending'|'done'|'failed'|'skipped'(빈본문·동일언어)
- (트리거 방식이면) `pg_net` 확장 활성

### 번역 파이프라인 (권장안 = §의심 1-B 트리거/웹훅)
1. 메시지 INSERT(`send_application_message`) → `translate_status='pending'`으로 저장(발송은 즉시 완료, 번역과 분리 best-effort).
2. INSERT 트리거가 pg_net으로 Edge Function `translate-message` 비동기 호출(service_role).
3. Edge Function: 원본 언어 판별(sender_kind 기반 + 자동 감지) → 외부 번역 API 호출 → `body_translated`·`translated_lang`·`translate_status='done'` UPDATE. 실패 시 'failed'.
4. 조회 `get_application_messages` 반환에 `body_translated`·`translated_lang`·`translate_status` 추가. **mask_state≠visible이면 번역본도 마스킹.**
5. 화면 렌더: 상대 메시지에 번역본 표시(+§의심 6 표시 방식). 번역 없으면 원문 폴백 + "번역 중"/"번역 실패" 안내. **번역본도 esc() 적용.**

### 비용·안전장치
- 번역 결과 **DB 캐싱**(재번역 0). 빈본문·동일언어·초장문 skip. 실패는 원문 폴백(발송·조회 무중단). API 키는 Edge Function env(클라 노출 금지).

### 약관·개인정보 (필수)
- 개인정보처리방침 한·일 동시 개정: 처리위탁 표 + 국외이전 표에 번역 플랫폼(법인·국가·항목·목적·보관) 추가.
- 시행일 이전 통지(release-timing 규칙 — 신규 처리위탁은 사전 고지). 앱 공지 + 필요 시 재동의 판단은 `/약관확인`으로.

### 번역 플랫폼 후보
| 플랫폼 | 무료 한도 | 특징 |
|---|---|---|
| DeepL API Free | 월 50만 자 | 일↔한 품질 우수, 신용카드 등록 필요(과금X) |
| Google Cloud Translation | 첫 50만 자/월 | 등록·결제수단 필요, 이후 유료 |
| LibreTranslate(셀프호스팅) | 무제한(자체 서버) | 무등록·데이터 미외부전송(개인정보 유리), 품질·운영부담 |
> 개인정보 관점에선 LibreTranslate(외부 미전송)가 유리하나 운영 부담. 품질·간편은 DeepL. → 사용자 확인.

---

## PR 분할 (안)

| 단계 | 내용 | 의존 |
|---|---|---|
| PR1 — 번역 파이프라인 | 컬럼 추가 + 트리거 + Edge Function + get RPC 반환 확장 | 없음 |
| PR2 — 화면 표시 | 인플·관리자 스레드에 번역 병기/토글, "번역 중/실패" 상태 | PR1 |
| PR3 — 약관·통지 | 개인정보처리방침 개정 + 사전 통지 + 운영 배포 | PR1·2 검증 후 |

---

## 결정 사항 (2026-07-13 사용자 확정)
1. **번역 범위** — ✅ **양방향 전부**(인플 일본어↔관리자 한국어 모두 번역). 피크 월 기준 무료 한도의 20%라 여유.
2. **표시 방식** — ✅ **원문+번역 병기**(말풍선에 상대 원문 + 번역 함께). 오역 시 원문 확인 경로 확보(관리자 검증·분쟁 대비).
3. **번역 플랫폼** — ~~DeepL API 무료~~ → **❌ 기각 (2026-07-13 딥리서치 검증, 공식 문서 원문 대조 3표 교차검증)**. DeepL API 무료 티어는:
   - 약관(pro-license §3.3.2)이 전송 콘텐츠의 **영구 저장 권리를 명시적으로 유보** (유료는 임시 저장+번역 후 삭제, 예외 디버그 72h)
   - 프라이버시 정책 §12→§3 준용으로 **신경망 학습에 사용될 수 있음** (유료는 학습 미사용 명시)
   - **개인정보 처리는 유료 구독에서만 허용** — 개인정보(배송지·연락처 가능성) 섞인 메시지를 무료로 보내면 약관 위반 소지
   - **데이터 처리 계약(DPA) 체결·리전 고정 모두 유료 전용** — GDPR/일본 APPI 준수 수단이 무료엔 없음
   - 참고: API Free/Pro는 신규 가입 불가 레거시, 현행 라인업 Developer(무료)/Growth/Enterprise. "학습에 안 쓴다"는 DeepL 보안 페이지 문구는 유료 맥락 서술이라 무료에 적용 불가
   - **재결정 (2026-07-13 같은 날 확정)** → ✅ **Google Cloud Translation** 채택. 경위:
     - **LibreTranslate 자체 서버 — ❌ 실측 기각**: 로컬 도커로 띄워 실제 인플 메시지 유형 6문장 스모크 테스트. 일→한이 영어 피벗(일→영→한)이라 치명 오역 3건 — ①「まだ発送されてない」(아직 발송 안 됨)→"아직 보낼 필요가 없습니다"(**의미 반전**) ②배송지 주소 「東京都渋谷区神南1-2-3」→"1-2-3 진난"(**주소 유실**) ③한→일 마감 안내 "7월 20일까지"→"wmu on Wed, 02/13/2013…"(**날짜 붕괴·깨진 문자열이 인플에게 노출**). 배송·마감·주소가 핵심인 용도에 부적합.
     - **3사 비교(피크 월 10.2만 자 기준)**: Google=첫 50만 자/월 무료 구간이라 **사실상 $0** + **"고객 데이터·번역문을 모델 학습에 사용하지 않음" 공식 명시**(무료 구간도 유료 상품의 데이터 보호 동일 — DeepL 무료와 구조가 다름) / Papago=한↔일 품질 최강·한국 서버(국외이전 부담 최소)이나 100만 자 단위 올림 과금으로 월 2만 원 고정 / DeepL Growth=$26 고정, 확실한 우위 없음.
     - PR3(약관) 반영: 개인정보처리방침 처리위탁·국외이전에 **Google LLC(미국)** 추가. 착수 시 Google Cloud 데이터 처리 조항(학습 미사용·보존) 최신 원문 재확인.
4. **파이프라인 아키텍처** — §의심 1 권고 **(B) INSERT 트리거 → pg_net → Edge Function**로 진행(CORS 회피·패턴 일치). 개발 세션이 최종 확정.

---

## 구현 결과

**구현일:** 2026-07-13
**관련 커밋:** feature/message-translation 브랜치 (PR은 머지 후 기입)

### 초안 대비 변경 사항
- **PR1(파이프라인)+PR2(화면)를 한 PR로 통합** — 파이프라인만 머지하면 화면에서 검증 불가, 규모가 크지 않아 실용적 판단. PR3(약관)은 예정대로 별도(운영 배포 전 필수 게이트).
- **트리거는 pg_net 직접 호출 대신 데이터베이스 웹훅(Dashboard 수동 설정)** — 오리엔 제출 알림(notify-orient-submitted)과 같은 프로젝트 표준 패턴. 환경(개발/운영)별 URL 분리가 자연스럽고 마이그레이션에 프로젝트 URL 하드코딩 회피.
- **send_application_message RPC 무수정** — 상태 기록은 Edge Function 전담. 웹훅 유실 시 3컬럼 NULL 유지 → 화면 원문 폴백이라 안전.
- **"번역 중" 표시 생략** — 번역이 1~2초 내 완료되고 스레드는 열 때마다 재조회라 과도기 노출이 드묾. `translate_status='done'`일 때만 병기, 그 외 전부 원문만(상태 배지 없음).
- **표시 순서 구체화** — "병기"를 번역문=본문 위치 / 원문=아래 작은 글씨(라벨 原文/원문) + 「自動翻訳/자동 번역」 캡션으로 확정(읽는 사람 언어 우선).
- **추가된 것**: 관리자 받은편지함 미리보기·대화 내 검색이 한국어 번역본도 활용(`fetchMessagePreviews` select 확장 + `searchAdminMsg` 필터 확장).
- **빠진 것**: 과거 메시지 백필(운영 6월 피크 1,701건) — 새 메시지만 번역. 필요해지면 일회성 스크립트로 후속(사용량 여유 충분).

### 구현 중 기술 결정 사항
- **마이그레이션 235** (`235_message_translation.sql`): 컬럼 3개(`body_translated`/`translated_lang`/`translate_status`, 전부 NULL·DEFAULT 없음) + `get_application_messages` DROP 후 재정의(반환 3컬럼 추가, 144 로직 100% 보존, GRANT 재적용). 마스킹 행은 번역 3컬럼 모두 NULL(번역 존재 힌트 차단 — §의심 4).
- **Edge Function `translate-message`**: 웹훅 전용(브라우저 직접 호출 0건 grep 확인 → CORS 불필요). Google v2 REST(자동 감지, 타임아웃 8초, 5000자 상한). 감지 언어=대상 언어면 skipped. 모든 실패는 `failed` 기록 후 200 반환(재시도 폭주 방지). 로그에 본문 미기록(개인정보).
- 클라이언트: `messaging.js`/`admin-messaging.js` 렌더 병기(번역본도 `esc()` — XSS), i18n 키 2종(`messaging.translatedLabel`/`originalLabel`), CSS `.msg-trans-*`(mypage.css·admin.css).

### 수동 설정 (개발/운영 각각 — 미완, 배포 단계에서 진행)
1. Google Cloud 계정 + Translation API 키 발급 (사용자)
2. `supabase secrets set GOOGLE_TRANSLATE_API_KEY=xxx --project-ref {ref}`
3. `supabase functions deploy translate-message --project-ref {ref}`
4. Dashboard → Database → Webhooks: `application_messages` INSERT → translate-message
5. SQL Editor에서 마이그레이션 235 실행
