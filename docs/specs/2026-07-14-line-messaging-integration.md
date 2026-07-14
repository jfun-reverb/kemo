# LINE 공식계정 메시지 플랫폼 통합 (아웃바운드 명단 영업 컨택)
**작성일:** 2026-07-14
**작성 세션:** 기획/설계
**상태:** 초안 (실현 가능성 검토 + 설계 방향)

> 아웃바운드 인플루언서 명단(`outbound_influencers`, 구글시트 917명 이관 예정)의 나노~메가 인플루언서와 LINE 공식계정 `@reverb.jp`로 주고받는 대화를, 관리자(영업) 화면에서 직접 주고받을 수 있게 통합한다. LINE Messaging API(공식계정) 기반.

---

## 현재 상태 (2026-07-14 기준, planning 규칙 A)

### 관련 코드·DB·UI 진입점
- **LINE 현재 사용처 = 발신 전용 링크뿐**: `@reverb.jp` 추가 유도 딥링크·QR(`index.html`, `sales/*`), 당선 통보 문구. 실제 대화는 전부 플랫폼 밖 LINE에서 수기로 진행 중. **양방향 대화·웹훅·userId 저장은 전무.**
- **인플루언서 LINE 필드 `influencers.line_id`** (마이그레이션 002): 인플이 프로필에 입력한 **사람이 읽는 아이디 문자열**. LINE 시스템 식별번호(userId, U로 시작 32자)가 아님. PII 마스킹 6종 중 하나(가림막 뷰 `influencers_admin_view`).
- **아웃바운드 명단 `outbound_influencers`** (마이그레이션 226): 이번 통합의 대상. 영업팀 직접 컨택 명단, `influencers`(auth 계정 1:1)와 물리 분리·**가입 계정 없는 외부 자산**. 소통 컬럼 `contact_channel`(자유텍스트)·`agency`·`nego_memo`. RLS 전부 `has_permission('outbound.view', ...)`(⚠️`is_admin()` 아님 — campaign_manager 차단). UI `/admin#outbound`, `dev/js/admin-outbound.js`.
- **재사용 가능한 기존 인프라**:
  - `application_messages` 풀스택(마이그레이션 144·145): 양방향 메시지 저장·서버측 역할별 마스킹·읽음/응대 추적·rate limit·첨부 Storage. 단 **응모건(application_id)에 종속** → 응모 없는 아웃바운드 명단과 키 구조 불일치.
  - `translate-message`(마이그레이션 235): **"메시지 INSERT → 데이터베이스 웹훅 → Edge Function → 외부 API(Google 번역) → 결과 UPDATE"** 파이프라인 확립. LINE 연동이 그대로 응용할 원형.
  - Edge Function 외부→서버 수신·서명검증 인프라 토대(`supabase/functions/*` 11개).
- **등급 체계**: `outbound_influencers.tier_code` → lookup `ob_tier` 3단계(micro/middle/mega). **"나노"는 이 명단 등급에 없음**(최저 마이크로 1만~). "나노 이상"을 명단 기준으로 보면 사실상 전 등급.

### 이 제안과 충돌 가능성 있는 기존 동작
- **충돌 없음 — 신규 영역** (LINE 양방향은 처음). 단 주의점 2개:
  - `influencers.line_id`(아이디 텍스트)와 신규 LINE userId는 **다른 개념** → 별도 저장 필요. `line_id`를 재활용 불가.
  - 발신 Edge Function은 **브라우저에서 직접 호출**하므로 CORS(교차 출처 허용 헤더)+OPTIONS 사전요청 필수(`.claude/rules/supabase.md`「브라우저 직접 호출 CORS」, `notify-orient-sheet` 사고 선례).

### 외부 조사 결과 (LINE 공식 문서·요금제, 2026-07-14 확인)
- **공식계정을 통해서만** 유저와 메시지 교환. **직원 개인 LINE 계정 대화방은 API로 접근 불가** → 우리는 공식계정 `@reverb.jp` 기반이라 통과.
- **userId는 유저가 먼저 친구추가/메시지할 때만** 웹훅(follow/message 이벤트)으로 획득. **명단만으로 우리가 먼저 발신 불가.** userId는 **채널(공식계정)별 발급** — 타 채널 재사용 불가.
- **과금**: 「먼저 보내는 메시지(push/broadcast)」만 통수 과금. **1:1 수동 채팅·응답 메시지(reply)는 통수 카운트 제외(무료)**. 무료 플랜 월 200통 / 스탠다드 월 15,000엔·30,000통(2026-10 요금 개편 예정). → **영업 1:1 대화 위주면 비용 부담 낮음.** (단 Messaging API의 push 호출이 「수동 채팅 무료」에 해당하는지는 개발/운영이 실측 필요 — reply token은 유효기간이 짧아 실무 대화엔 부적합.)

---

## 의심·경우의 수 (planning 규칙 B)

### 깨질 수 있는 경우의 수
1. **[데이터·핵심] 우리가 먼저 말 걸 수 없음** — 명단 917명 중 실제 대상은 **@reverb.jp를 이미 추가한 사람만**. 첫 컨택은 여전히 LINE 밖(인스타 DM 등)에서 공식계정 추가를 유도해야 함. "명단에서 플랫폼이 먼저 LINE 발신"은 LINE 구조상 영구 불가.
2. **[데이터·매핑] userId ↔ 명단 자동 연결 불가** — 유저가 친구추가해도 우리가 받는 건 익명 userId뿐. "이 userId = 명단의 누구"를 자동으로 못 붙임. 매핑 수단 필요(수동 연결 or 초대링크 파라미터). 한 명단 인플이 여러 LINE 계정이거나, 동명이인이면 오연결 위험.
3. **[동시성] 미연결 수신 폭주** — 매핑 전 들어온 메시지가 "미연결 수신함"에 쌓임. 영업이 방치하면 미읽음 누적. 여러 영업이 같은 대화를 동시에 매핑·응대하면 충돌.
4. **[외부 장애] LINE 웹훅 유실·서명검증** — LINE→서버 웹훅이 재전송·순서 뒤바뀜·중복 도착 가능. `X-Line-Signature` 검증 실패 시 위조 메시지 유입 차단 필요. Edge Function 다운 시 수신 유실(LINE은 재시도 제한).
5. **[권한·환경] 개발/운영 채널 분리** — LINE 공식계정 채널(access token·secret)이 환경별로 필요. 개발서버에서 실발송 테스트 시 실제 인플에게 발송될 위험(`.claude/rules/supabase.md`「개발서버 메일 발송 테스트 금지」와 동일 정신).
6. **[법률] 개인정보·약관** — LINE userId + 대화 내용 저장 = 개인정보. 아웃바운드 명단 인플은 **globalreverb 가입자가 아니라 우리 개인정보처리방침 동의 주체가 아님** → 외부 개인정보를 저장·처리하는 근거·고지 별도 검토 필요(일본 개인정보보호법 APPI, 국외이전). LINE 공식계정/Messaging API 이용약관(스팸·대량발송 제한) 준수.
7. **[UX] 영업 화면 인지 부하** — 명단 관리 + 대화 + 미연결 수신함이 한 화면에 섞이면 복잡. 대화 진입/이탈 경로, 미읽음 표시, 누가 응대 중인지 표시 필요.

### 현재 구현 충돌점
- 확인 완료, **충돌 없음**. 단 ①`line_id` 재활용 불가 ②발신 Edge Function CORS 필수 — 2개 주의점만 설계에 반영.

### 의도 모호점 (사용자 확인 필요)
- **매핑 방식** — 익명 userId를 명단과 어떻게 연결? (수동 연결 vs 초대링크 자동)
- **발신 범위** — 답장(reply) 중심인지, 먼저 보내는 안내(push)도 포함인지(과금·약관 영향).
- **"나노 이상"** — 명단 tier엔 나노가 없음. 전 등급 대상으로 보면 되는지, 나노 구간을 새로 만들지.

---

## 제안 / 설계

### A. 실현 형태 (한 줄)
> **"명단에서 우리가 먼저 발신"은 불가. "@reverb.jp를 추가한 인플의 대화를 명단 화면에서 주고받고 저장"만 가능.** 첫 컨택은 LINE 밖에서 공식계정 추가 유도 → 추가한 시점부터 플랫폼이 대화를 흡수.

### B. 데이터 (신규, DB 변경 — 마이그레이션 개수·상대순서만. 번호는 개발 세션이 확정)
1. **매핑 저장** — `outbound_influencers`에 LINE 연결 컬럼 추가 (`line_user_id text UNIQUE NULL` + 연결 시각·연결자). 1:1 가정. (한 인플 다계정 필요 시 별도 매핑 테이블로 확장.)
2. **대화 저장 테이블** `outbound_line_messages` 신규 — `outbound_influencer_id`(NULL 허용 = 미연결 수신), `direction`(inbound|outbound), `line_message_id`(멱등·중복 차단 UNIQUE), `message_type`(text|image|sticker…), `body`, `sent_by`(발신 관리자 auth_id, inbound는 NULL), `line_timestamp`, `raw jsonb`, `created_at`.
3. **미연결 수신 처리** — 매핑 안 된 userId의 inbound는 `outbound_influencer_id=NULL`로 저장 → "미연결 수신함"에서 영업이 명단과 연결.
- **마이그레이션 상대순서**: ①대화 테이블·매핑 컬럼 생성 → ②RLS(전부 `has_permission('outbound.view', …)` 일관, service_role만 INSERT 우회) → ③멱등·인덱스. ①이 가장 먼저.
- **RLS 원칙**: SELECT/UPDATE = `has_permission('outbound.view','read'/'write')`(명단과 동일 등급 경계, campaign_manager 차단). INSERT는 웹훅 Edge Function(service_role)만.

### C. 수신 (LINE → 서버, 신규 Edge Function `line-webhook`)
- 공개 엔드포인트. **`X-Line-Signature` HMAC 검증**(secret `LINE_CHANNEL_SECRET`) — 위조 차단, 실패 시 거부. (외부→서버라 CORS 불필요, 서명검증이 방어선.)
- follow/message/unfollow 이벤트 처리. message inbound → `outbound_line_messages` 저장(`line_message_id` UNIQUE로 재전송 멱등). userId가 기존 매핑에 있으면 해당 명단 대화에, 없으면 미연결 수신.
- best-effort(저장 트랜잭션과 분리), service_role INSERT. `translate-message`의 웹훅 수신 패턴 재사용.

### D. 발신 (서버 → LINE, 신규 Edge Function `line-send`)
- **브라우저(관리자 화면)에서 직접 호출** → **CORS 헤더 + OPTIONS 분기 필수**(`notify-orient-sheet` 선례). secret `LINE_CHANNEL_ACCESS_TOKEN`으로 LINE push/reply API 호출.
- 발신 성공 시 `outbound_line_messages`에 outbound 행 저장. 발신 권한 `has_permission('outbound.view','write')`.
- **과금 주의**: 답장(reply)은 무료지만 유효기간 짧음 → 실무는 push. push의 「수동 채팅 무료」 해당 여부를 개발/운영이 실측 후 플랜 확정.

### E. 관리자(영업) 화면 (`/admin#outbound` 확장, `dev/js/admin-outbound.js`)
- 명단 행/상세에 **대화 패널**(`admin-messaging.js` 패턴 응용) — 미읽음 배지, 스레드, 텍스트·이미지 발신.
- **미연결 수신함** 별도 뷰 — 매핑 안 된 수신 메시지 목록 → "이 대화 = 명단의 ○○" 연결 액션.
- 도착 감지는 기존 30초 폴링 패턴 or 알림. 누가 응대 중인지(동시성) 표시 고려.

### F. 인플루언서 앱 — **변경 없음**
- 아웃바운드 명단은 가입 계정 없는 외부 자산 → 인플 앱(globalreverb) UI 무관.

---

## PR 분할 (권장)
- **PR 1 — 수신 파이프라인**: 데이터 모델(대화 테이블·매핑 컬럼·행 단위 보안 정책) + `line-webhook` Edge Function(서명검증·inbound 저장·미연결 수신) + 미연결 수신함 조회. *운영엔 LINE 채널 발급·secret 필요.*
- **PR 2 — 명단 연결**: 미연결 userId ↔ 명단 수동 연결 UI + 매핑 저장.
- **PR 3 — 발신·대화 패널**: `line-send` Edge Function(CORS) + 명단 화면 대화 패널·미읽음.
- **PR 4 — 운영 보강**: 알림·동시 응대 표시·과금 플랜 실측·개인정보 고지 반영.
- **의존성**: PR 1 → PR 2 → PR 3 순. PR 4는 PR 3 이후.

---

## 사용자 확인 필요 (다음 세션 결정)
1. **매핑 방식** — ⓐ영업이 대화 열고 수동 연결(권장·현실적) / ⓑ초대링크에 명단 식별값 심어 자동 연결(LINE 제약으로 제한적).
2. **발신 범위** — 답장 중심(비용·약관 안전) / 먼저 보내는 안내도 포함(push 과금·대량발송 약관 검토).
3. **"나노 이상" 정의** — 전 등급 대상 / 나노 구간 신설.
4. **개인정보·약관** — 외부 명단(비가입자) LINE userId·대화 저장의 법적 근거 → `/약관확인` 또는 법무 확인 선행 여부.
5. **개발/운영 LINE 채널** — 채널 2개(개발·운영) 분리 발급 여부. 실발송 테스트는 운영 한정 원칙 적용 여부.

---

## 구현 결과 (개발 세션이 채울 것)
_(미착수)_
