# 📋 작업 분해표 — 서비스 문의: 회원 한 명이 여러 대화를 갖는 구조

**사양서:** [`2026-10-06-service-inquiry-threads.md`](2026-10-06-service-inquiry-threads.md) — 그 문서의 「코드 대조 결과」 절이 「설계」 절보다 우선한다
**분해일:** 2026-10-06 (기획 에이전트 분해 + 개발 세션 점검)
**상태:** 📄 작업표 — 착수는 사용자 확인 뒤
**총 작업 조각:** 6개 · **병렬 가능:** 2개(조각 3 ∥ 조각 4) · **순차 필수:** 4개(조각 1·2·5·6) — 후속 정리 조각 F 는 이번 배포 제외라 수에서 뺐다

> **사양서와 다르게 나눈 점** — 사양서는 「데이터베이스 1 · 회원 화면 1 · 관리자 화면 1」로 적었지만, **공용 데이터 접근 층(조각 2)**을 따로 뗐다. 두 화면 모두 `dev/lib/storage.js` 일반 문의 함수 묶음과 `dev/lib/shared.js` 예상 거부 목록을 고쳐야 하는데 둘 다 핫스팟이다. 이것을 먼저 끝내 두어야 두 화면 조각이 겹치는 파일 없이 병렬로 갈 수 있다. 한 사람이 순차로 하면 조각 2 를 조각 3 앞머리에 합쳐도 된다.

---

## 🚦 착수 전 선결 조건

| # | 선결 조건 | 근거 | 막는 조각 |
|---|---|---|---|
| S0 | ~~운영 데이터 실측~~ **끝남** — 서비스 문의 메시지 2건 · 회원 1명 · 응대 완료 줄 0건(2026-10-06 읽기 전용) | 사양서 「코드 대조 결과」 머리 | — |
| S1 | **운영 적용 직전에 다시 센다** — 메시지 수·회원 수·응대 완료 줄 수 + 옮길 서비스 문의 행 내려받기 | 창구가 10/6 운영에서 열려 건수가 는다. 「옮기기 전·후 건수 일치」(검증 5)의 기준값 | 6 |
| S2 | **운영 반영 방식** — 골라 담기로 충분하다(2026-10-06 개발 세션 확인) | 이 기능이 만지는 파일 중 운영(`main`)과 개발(`dev`)이 다른 것은 **가입 인증번호 코드뿐**(`app.js` 2줄 · `storage.js` 38줄 — 10/13 묶음 #1892). `messaging.js`·`admin-messaging.js`·`mypage.css`·`notifications.js` 는 같다(회원 앱 스타일 통일은 #1907 로 이미 운영 반영). ⚠️ 10/13 묶음과 **같은 파일 두 개**(`app.js`·`storage.js`)를 만지므로 순서만 정하면 된다 | 6 |
| S3 | **운영 반영 날짜·시간대** — 회원이 적은 시간대, 데이터베이스 → 코드를 바로 이어서. 10/13 가입 인증번호 시행일과 같은 날은 피한다 | 사양서 경우의 수 #8 · 「단계 분할」 | 6 |
| S4 | **개발서버 시험 데이터** — 회원 3명 이상(대화 여러 개 가질 회원 · 응모 0건 회원 · **관리자를 겸한 회원**) + 감사용 계정 1 | 검증 4·8·9·11·13-1. 관리자 겸직은 실제 로그인으로만 재현(SQL 편집기는 서비스 키라 호출자 분기가 안 돈다) | 1 의 완료 확인, 3·4·5 |

사양서 「사용자 확인」 Q-1~Q-4 와 코드 대조의 사용자 결정 셋(R-1·R-2·R-3)은 모두 확정 — 미결 결정 없음.

## ⚠️ 분해 중 발견 — 조각 1 이 정해 사양서 「구현 결과」에 적을 것

1. **발신 함수 반환 모양** — 지금 478 `send_general_inquiry_message` 는 `RETURNS uuid`. 사양서는 「반환에 `thread_id` 추가」만 적었다. **제안:** `RETURNS TABLE(message_id uuid, thread_id uuid)`(옛 화면은 반환값을 버리므로 무영향)
2. **관리자 목록 미리보기가 지금은 번역본** — `fetchGeneralInquiryPreviews`(storage.js) 가 `body_translated`·`translate_status` 를 받는다. 새 뷰 칸에 번역 미리보기가 없으면 **관리자 미리보기가 한국어 번역 → 일본어 원문으로 바뀐다.** 뷰에 번역 미리보기 칸을 함께 넣기를 권한다
3. **거부 코드 이름** — 확정은 `new_message_since_view`·`open_thread_exists` 둘뿐. 나머지 **이름 제안**: `no_open_thread`(운영팀이 열린 대화 없는 회원에게) · `thread_closed`(운영팀이 닫힌 대화에) · `thread_not_found`(남의 대화 id 또는 없는 대화 — 존재 여부를 드러내지 않게 하나로)
4. **탈퇴 개인정보 파기**(`purge_withdrawn_personal_data`, 현재 원본 396)가 서비스 문의 **메시지 행을 지우는지** 확인 안 함 — 지운다면 글 없는 대화 행이 열린 채 남아 관리자 목록에 「회원 답 대기」로 영영 뜬다. 착수 때 확인

## 한눈에 보는 의존 순서

```
[S1·S2·S3 → 조각 6 앞]   [S4 → 조각 1 완료 확인 앞]

조각 1 데이터베이스(마이그레이션 1→2→3, 개발 적용 + 옛 화면 상태 검증 13)
   ↓
조각 2 공용 데이터 접근 층(storage.js + shared.js — 옛 화면이 계속 돌게 호환 유지)
   ↓
조각 3 회원 화면  ∥  조각 4 관리자 화면
   ↓                 ↓
조각 5 개발서버 통합 검증 + 문서 + 안 쓰이게 된 옛 접근 함수 정리
   ↓
조각 6 운영 반영(사용자 확인 → 데이터베이스 → 코드 바로 이어서 → Notion 가이드)
   ⋮ (운영 안정 뒤, 다음 배포)
조각 F 후속 정리 마이그레이션 — 이번 배포 제외
```

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약(요약) | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| 1 | 데이터베이스: 대화 표 + 옮기기 + 함수 + 뷰 | `supabase/migrations/` 새 파일 3개 | 표 `general_inquiry_threads` · 칸 `application_messages.general_thread_id` · 함수 재정의 4 + 신설 2 + 감사용 청소 재정의 · 뷰 `general_inquiry_thread_summary` · 거부 코드 | 없음(S4 는 완료 확인용) | 단독(데이터베이스는 한 세션) | 개발 1 |
| 2 | 공용 데이터 접근 층 | `dev/lib/storage.js`, `dev/lib/shared.js` | storage 함수 이름·인자·반환 · 예상 거부 코드 등록 | 1 | 단독(핫스팟 두 파일) | 개발 1 |
| 3 | 회원 화면 | `dev/js/messaging.js`, `app.js`, `notifications.js`, `mypage.js`, `dev/lib/i18n/{ja,ko}.js`, `dev/css/mypage.css`(또는 `member-ui.css`), `dev/index.html`(필요 시), 빌드 산출물 | 주소 `#inquiry-general-{대화id}` · 현재 대화 id 변수 · 번역 키 | 2 | ∥ 4 | 개발 1 또는 2 |
| 4 | 관리자 화면 | `dev/js/admin-messaging.js`, `dev/css/admin.css`, `dev/admin/index.html`(필요 시), 빌드 산출물 | 대화 줄 목록 · 미응대 수 세 자리 · 닫기·다시 열기 | 2 | ∥ 3 | 개발 2 또는 1 |
| 5 | 개발서버 통합 검증 + 문서 + 옛 접근 함수 정리 | 사양서 「구현 결과」, `docs/FEATURE_SPEC.md`, `CLAUDE.md`, `dev/lib/storage.js`(호출부 0건이 된 옛 함수 지우기만), 빌드 산출물 | 검증 1~13-1 결과 · 실제 마이그레이션 번호 | 3, 4 | 순차 | 개발 1 |
| 6 | 운영 반영 | 운영 데이터베이스(SQL 편집기) · 개발 → 운영 병합 요청 · Notion 실무자 가이드 | 운영 반영 기록 | 5, S1·S2·S3 | 순차 | 개발 1 + **사용자 확인** |
| F | (이번 제외) 후속 정리 마이그레이션 1개 | `supabase/migrations/` 새 파일 1개 | 옛 응대 완료 함수·표(477)·옛 뷰(481) 삭제 + 감사용 청소 재정의(같은 파일) | 6 운영 안정 뒤 | — | 개발 |

## 조각별 상세

### 조각 1 — 데이터베이스

- **하는 일:** 마이그레이션 3개(번호는 만들 때 확정, 「1 → 2 → 3」). 개발 데이터베이스에 적용하고 새로 만든·다시 만든 함수를 전부 한 번씩 실제 호출. 그 뒤 **화면은 옛 판 그대로 둔 채** 검증 13(데이터베이스 → 코드 사이 구간)을 개발서버에서 확인 — **조각 2 병합 전에만** 할 수 있다
- **담당 파일:** `supabase/migrations/` 새 파일 3개만
- **산출 계약:**
  - **마이그레이션 1 — 표 `general_inquiry_threads`**: `id uuid` 기본 키 · `influencer_id uuid`(회원 표 외래 키, 회원 삭제 시 함께 삭제) · `status text`(`open`·`closed`) · `opened_at` · `closed_at` · `closed_by` · `closed_by_name` · `reopened_count int` 기본 0. 마지막 글 시각·발신 종류 칸 없음. **행 단위 보안 켜기**. 정책: 회원 본인 조회 · 관리자 조회 `(SELECT public.is_admin())` · 쓰기 정책 없음. 부분 유일 색인 `(influencer_id) WHERE status='open'`
  - **마이그레이션 1 — 칸 `application_messages.general_thread_id uuid NULL`**: 대화 표 외래 키, **대화 삭제 시 메시지도 함께 삭제**(코드 대조 기본값). 색인 `(general_thread_id, created_at)`
  - **마이그레이션 2 — 옮기기**(경우의 수 #5 · R-9): **메시지에서 출발**해 회원마다 대화 하나. 닫힘 = `resolution_method='manual'` 이고 `resolved_at` 뒤 회원 글 없음(`closed_at = resolved_at`, 닫은 사람 `resolved_by`·`resolved_by_name`), 나머지 열림. 실행 전·후 건수 출력(일반 문의 메시지 수 = 대화 칸이 채워진 수)
  - **마이그레이션 2 — 함수**(실행 권한 회수·부여를 **두 방향 모두** 다시 건다 — `FROM PUBLIC` + `FROM anon`, `TO authenticated`):
    - `send_general_inquiry_message(p_body text, p_attachments jsonb, p_influencer_id uuid, p_thread_id uuid DEFAULT NULL)` — `DROP` 후 `CREATE`. 반환에 `thread_id`(제안 `TABLE(message_id uuid, thread_id uuid)` — 확정 모양을 여기 고쳐 적는다). 응대 완료 표(477) 더는 안 건드림. 알림 `ref_id = 대화 id`, 중복 방지도 대화 단위
    - `get_general_inquiry_messages(p_influencer_id uuid, p_thread_id uuid DEFAULT NULL)` — `DROP` 후 `CREATE`. 숨긴 글 가리기를 **갈래 기준**으로(R-6)
    - `mark_general_inquiry_messages_read(p_influencer_id uuid, p_thread_id uuid DEFAULT NULL)` — `DROP` 후 `CREATE`
    - `general_inquiry_admin_unread_counts(p_admin_auth_id uuid)` — `DROP` 후 `CREATE`, 반환 **대화별**(제안 `TABLE(thread_id uuid, influencer_id uuid, unread_count bigint)`)
    - `close_general_inquiry_thread(p_thread_id uuid, p_seen_last_message_id uuid)` — 신설. 관리자 전원, 열린 대화만, 숨김·회수 뺀 기준
    - `reopen_general_inquiry_thread(p_thread_id uuid)` — 신설. 관리자 전원, 그 회원에게 열린 대화가 없을 때만
    - `purge_audit_data_all()` — 현재 원본 480 베이스 `CREATE OR REPLACE`(권한 보존). 대화 표도 지운다(메시지 → 대화 순). 477 지우는 줄은 남김
    - `mark_general_inquiry_resolved` 는 **손대지 않는다**
    - 「호출자 판정」 ⓪①②③과 **회원 단위 잠금**(`pg_advisory_xact_lock`, 열쇠 = 회원 id)은 사양서 「데이터」 절 정의 그대로. 발신·닫기·다시 열기가 같은 잠금
  - **마이그레이션 2 — 검사 제약**(맨 끝): 응모 칸이 빈 행이면 `general_thread_id` 필수(이름 제안 `application_messages_general_thread_required`)
  - **마이그레이션 3 — 뷰 `general_inquiry_thread_summary`**(`security_invoker`, **대화 표에서 출발**). 칸 이름은 `needs_reply` 만 확정, 나머지 **이름 제안**: `thread_id` · `influencer_id` · `status` · `opened_at` · `closed_at` · `message_count` · `last_message_at` · `last_sender_kind` · `first_message_preview` · `last_message_preview` · `last_message_preview_translated`·`last_translate_status`(발견 2 — 권고) · `unread_for_influencer` · `needs_reply` · `influencer_thread_count`(회원 단위, 닫힌 것 포함). **메시지에서 구하는 칸은 모두 숨김·회수 글 제외**
  - **거부 코드**(`RAISE EXCEPTION '<코드>'` → P0001, 메시지 본문 = 코드): 확정 `new_message_since_view`·`open_thread_exists` / 제안 `no_open_thread`·`thread_closed`·`thread_not_found`. 기존 「会員を指定してください」(회원을 지정해 주세요) 거부는 그대로
  - 옛 뷰(481)·표(477)는 그대로 둔다
- **완료 정의:** 개발 데이터베이스에 1→2→3 오류 없이 적용 · 옮기기 전·후 건수 일치 출력(검증 5) · 신설 2·재정의 5 를 **각각 한 번 이상 실제 호출**(관리자·호출자 분기는 **실제 로그인 브라우저 콘솔**) · 실행 권한 확인(`p.proacl::text` 맨 앞 `=X/` 없음, `anon` 실행 없음) · 서버 쪽 검증 1·2·3·4·9·10·12 · 13-1 「운영팀이 열린 대화 없는 회원에게 → 거부」 · **검증 13**(새 데이터베이스 + 옛 화면 — 조회·읽음 회원 전체 단위, 옛 배지 조회 그대로, 옛 응대 완료로 대화 안 닫힘)
- **검문소:** `reverb-supabase-expert`(마이그레이션 셋·권한 두 방향·정책·잠금) → `reverb-reviewer`
- **주의·롤백:** 🔴 마이그레이션 2 는 **한 파일·한 묶음**(틈이 있으면 대화 칸 없는 행이 들어온다). 실패하면 그 트랜잭션 전체가 되돌아간다. 마이그레이션 1 만 남았을 때의 되돌림 SQL 을 `supabase/patches/` 에 미리 써 둔다. ⚠️ 번역 저장(`translate-message`)은 검사 제약 위반으로 **조용히 실패**한다 — 건수 대조 필수. ⚠️ 함수 넷을 `DROP` 하면 권한 회수가 풀린다 — 다시 건다

### 조각 2 — 공용 데이터 접근 층

- **하는 일:** `storage.js` 일반 문의 함수 묶음을 새 함수·뷰에 맞춘다. **옛 화면이 계속 돌도록** 기존 함수는 **인자를 뒤에 덧붙이기만**, 뜻이 바뀌는 것은 **새 이름**으로. `shared.js` 예상 거부 목록에 새 코드 등록
- **담당 파일:** `dev/lib/storage.js`(일반 문의 구역), `dev/lib/shared.js`(`APP_ERROR_EXPECTED_PATTERNS`), 빌드 산출물
- **산출 계약**(새 이름은 전부 **이름 제안** — 확정 이름을 여기 고쳐 적는다):
  - 인자만 덧붙임(호환): `fetchGeneralInquiryMessages(influencerId = null, threadId = null)`(실패 `null`·0건 `[]`) · `sendGeneralInquiryMessage(body, attachments = [], influencerId = null, threadId = null)`(반환 `{ message_id, thread_id }`, 실패는 예외) · `markGeneralInquiryMessagesRead(influencerId = null, threadId = null)`
  - 속만 바뀜: `fetchMyGeneralInquiryUnread()` — 새 뷰 `unread_for_influencer` **여러 행 합산**. 🔴 `.maybeSingle()` 금지. 실패 `null`
  - 신설(회원): `fetchMyGeneralInquiryThreads()` — 본인 대화 전부(1,000행 반복, 정렬 끝 `thread_id`), 실패 `null`·0건 `[]`
  - 신설(관리자): `fetchAdminGeneralInquiryThreadRows(opts)`(기간 + `includeClosed`·`influencerId`, `.gt('message_count', 0)` **옮기지 않음**) · `fetchGeneralInquiryNeedsReplyCount()`(기간 창 없는 열린 대화의 `needs_reply` 수) · `fetchGeneralInquiryAdminUnreadByThread()`(`Map<thread_id, count>`) · `fetchAdminGeneralThreadSentAtMap()`(`Map<thread_id, iso>`) · `closeGeneralInquiryThread(threadId, seenLastMessageId)` · `reopenGeneralInquiryThread(threadId)`(실패는 예외)
  - 그대로: `uploadGeneralInquiryAttachment(file, influencerId)`(경로 회원 id) · `fetchGeneralInquiryHideHistory(influencerId)`(회원 단위) · 옛 관리자 함수 다섯과 `markGeneralInquiryResolved` — **이 조각에서는 안 지운다**(조각 5)
  - `shared.js`: 조회·닫기·다시 열기의 예상 코드 등록(발신은 `messaging.js` 가 이미 P0001 을 예상 거부로 넘긴다)
- **선행:** 조각 1(그리고 **검증 13 뒤에** 병합)
- **완료 정의:** 빌드 오류 없음 · 개발서버 **옛 회원·관리자 화면이 병합 뒤에도 그대로 돈다**(문의 열기·보내기·햄버거 배지) · 관리자 콘솔에서 신설 6개를 한 번씩 불러 `null`·`[]` 구분 확인
- **검문소:** `reverb-reviewer`(고유 정렬·`maybeSingle` 잔존·실패와 0건 구분) + `reverb-supabase-expert`(storage.js 수정)
- **주의:** 🔴 기존 함수의 **인자 순서를 바꾸지 않는다**(옛 화면이 위치로 넘긴다)

### 조각 3 — 회원 화면

- **하는 일:** 서비스 탭을 「지금의 문의」 한 칸 + 문의하기 버튼 + 지난 문의 목록(20개 + 「もっと見る」("더 보기"))으로 다시 그린다. 대화 화면에 현재 대화 id 를 들이고 주소·뒤로가기·알림·탈퇴 지름길·30초 새 글 감지를 대화 단위로. 응모 0건 회원도 서비스 문의 목록(R-3), 새 문의 화면은 빈 화면(R-2)
- **담당 파일:** `messaging.js`(상태·진입·탭·불러오기·읽음(알림 읽음 포함)·발신 반환·폴링·지난 문의 보내기 막기·정리·주소 비교 셋·뒤로가기·재시도·배지) · `app.js`(주소 다섯 곳) · `notifications.js`(알림 클릭) · `mypage.js`(탈퇴 지름길) · `dev/lib/i18n/{ja,ko}.js` · `dev/css/mypage.css`(또는 `member-ui.css` — 🔴 공유 `base.css`·`components.css`·`ui.js` 기존 값은 안 고친다) · `dev/index.html`(필요 시) · 빌드 산출물
- **산출 계약:** 주소 목록 `#inquiry`(서비스 탭) · 대화 `#inquiry-general-{대화id}` · 새 문의 `#inquiry-general`(조회·읽음 안 부름) / 진입 `openGeneralInquiryPage(from, pushHistory, threadId = null)`(이름 제안) / 현재 대화 id `_msgGeneralThreadId`(이름 제안) / 번역 키(이름 제안 — 같은 뜻 기존 키 있으면 그것):

  | 키 제안 | 한국어 뜻 | 일본어 |
  |---|---|---|
  | `inquiry.currentTitle` | 지금의 문의 | 現在のお問い合わせ |
  | `inquiry.pastTitle` | 지난 문의 | 過去のお問い合わせ |
  | `inquiry.startInquiry` | 문의하기 | お問い合わせする |
  | `inquiry.backToList` | 문의 목록으로 | お問い合わせ一覧に戻る |
  | `inquiry.more` | 더 보기 | もっと見る |
  | `inquiry.resolved` | 응대 완료 | 対応済み |
  | `inquiry.noVisibleMessage` | 표시할 메시지가 없습니다 | 表示できるメッセージはありません |
  | `inquiry.threadNotFound` | 이 문의를 열 수 없습니다(뜻) | 작성 시 `reverb-ui-copy` 스킬 |

- **선행:** 조각 2
- **완료 정의:** 빌드 오류 없음 · 검증 6(옛·새 알림 둘 다 읽음, R-7) · 7(배지 합계·지난 문의 줄 배지) · 11(일곱 항목, 시계 경계는 받은 `thread_id` 로 다시 그림) · 13-1 회원 쪽 셋(새 문의 빈 화면 · 응모 0건 → 목록 · 겸직 회원 숨긴 본문 안 보임·회원 글로 저장) · 1 회원 쪽(첫 글 → 주소가 그 대화로) · 남의 대화 id 주소 → 오류 안내만 · 상태 안내는 `stateEmptyHtml`·`stateLoadingHtml`·`stateErrorHtml`
- **검문소:** `reverb-reviewer` → `reverb-qa-tester` 가벼운 범위(단일 세션, 사용자 시작)
- **주의:** ⚠️ 일본어 문구는 `reverb-ui-copy` 스킬 + 한국어 뜻 병기. 화면 기준 Apple 지침 — 스타일 통일로 정한 `.inq-*` 글자 5단계·누르는 영역 44·`.back-link` 를 따르고, 목록 줄은 `inq-app-item` 모양

### 조각 4 — 관리자 화면

- **하는 일:** 서비스 문의 탭 목록을 **대화 한 줄**로(이름 · 상태 칩 셋 · 마지막 글 시각 · 미리보기 · 「이 회원 대화 N」), 기본 거름 열린 대화 + 「닫힘 포함」 토글, 「응대 완료」 = 닫기, 닫힌 대화는 입력란 대신 「다시 열기」, 미응대 수 **세 자리**를 함께
- **담당 파일:** `admin-messaging.js`(상태 변수·목록·대화 화면·답장·`markCurrentResolved`·`adminThreadViewHtml`·미응대 세 자리 `updateInboxSidebarBadge`·`refreshMsgBadgesLight`·`renderInboxKindTabs`·`unresolved_for_admin_team` 여섯 곳 → `needs_reply`·회원 id 짝짓기·첨부 올리기는 회원 id 그대로) · `dev/css/admin.css` · `dev/admin/index.html`(필요 시) · 빌드 산출물
- **산출 계약:** 대화 id 변수 `_admMsgGeneralThreadId`(이름 제안 — 회원 id 변수는 첨부 경로용으로 남김, R-5) · 「닫힘 포함」 `_genIncludeClosed` · 회원 거름 `_genFilterInfluencerId` · 다시 열기 `reopenCurrentGeneralThread()`(모두 이름 제안). 칩 문구 「미응대」/「회원 답 대기」/「닫힘」, 보이는 글 0건이면 「표시할 글 없음」
- **선행:** 조각 2
- **완료 정의:** 빌드 오류 없음 · 검증 8(세 자리 일치 — 새로고침 직후 / 30초 뒤 / **기간 거름을 바꾼 뒤** · 회수로 「회원 답 대기」 · 「이 회원 대화 3」) · 12 화면 쪽(거부 문구 「새 메시지가 도착했습니다. 확인 후 다시 눌러 주세요」 · 「다시 열기」 · 「이 회원에게 열린 대화가 이미 있습니다」) · 1 관리자 쪽(답장 뒤 「회원 답 대기」) · 13-1 운영팀 거부가 한국어 문구 · 닫기·다시 열기 뒤 목록·배지 즉시 갱신(`refreshPane` 의무) · 캠페인 매니저 권한으로도 의도대로
- **검문소:** `reverb-reviewer` → `reverb-qa-tester` 가벼운 범위
- **주의:** 🔴 세 자리 중 하나만 고치면 30초 뒤 또는 다시 그릴 때 숫자가 되돌아간다. 🔴 닫기에 넘기는 「본 마지막 메시지 id」는 **숨김·회수 뺀** 마지막 id(관리자 화면엔 숨긴 글도 보인다)

### 조각 5 — 개발서버 통합 검증 + 문서 + 옛 접근 함수 정리

- **하는 일:** 조각 3·4 가 모두 병합된 뒤 검증 1~13-1 을 **한 번에** 다시 돈다. 호출부 0건이 된 옛 storage 함수(`fetchAdminGeneralInquiryThreads`·`fetchGeneralInquiryUnresolvedCount`·`fetchGeneralInquiryAdminUnreadCounts`·`fetchAdminGeneralSentAtMap`·`fetchGeneralInquiryPreviews`·`markGeneralInquiryResolved`)를 지운다 — 호출부는 **세 형태**(그대로·인자·문자열 안)로 각각 찾는다. 사양서 「구현 결과」·`FEATURE_SPEC.md`·`CLAUDE.md` 「일반 문의 창구」 절 갱신(「회원당 1 대화」 서술은 고쳐 쓴다, 덧붙이지 않는다)
- **완료 정의:** 검증 1~13-1 전부 통과 기록 · 옛 함수 지운 뒤 빌드 통과 · 문서 세 곳 갱신
- **검문소:** `reverb-reviewer` + 운영 직전 **`reverb-qa-tester` 전체 범위**(단일 세션, 사용자 시작)
- **주의:** 옛 함수 삭제는 별도 커밋(문제 시 그것만 되돌림)

### 조각 6 — 운영 반영

- **하는 일:** ①S1·S2·S3 확인 ②회원이 적은 시간대에 운영 SQL 편집기에서 1→2→3 ③옮기기 전·후 건수 대조 ④**바로 이어** 운영 병합 요청 병합 ⑤운영 확인 ⑥Notion 실무자 가이드 갱신
- **완료 정의:** 운영 건수 전·후 일치(검증 5) · 산출물 반영(`curl -sL` + md5 를 `origin/main` 과 대조, 양성 대조 포함) · 실제 로그인 브라우저로 관리자 목록이 대화 줄 · 세 자리 일치 · 회원 시험 계정으로 서비스 탭 · Notion(「응대 완료 = 닫기, 답장만으로 안 닫힘」·「회원 답 대기」·「다시 열기」·「닫힘 포함」·「이 회원 대화 N」·24시간 안 다시 열림 — 정확성 게이트)
- **검문소:** 운영 적용 전 `reverb-supabase-expert` 로 실행 순서 재확인. **편집기 경고: 뜸 — 무해**(함수를 지웠다 다시 만들 뿐). 단 권한 회수를 다시 걸었는지 실행 뒤 조회로 확인
- **주의·롤백:** 데이터베이스와 코드 사이 몇 분은 옛 관리자 화면의 안 읽음 표시가 빠지고 미응대 수가 틀어진다(예상 — 경우의 수 #8). 되돌릴 때는 **코드 먼저, 데이터베이스 다음**(조각 1 의 되돌림 SQL + S1 에서 내려받은 행). 🔴 SQL 편집기 탭은 쓰고 나면 그 자리에서 닫는다(저장 안 된 편집이 있으면 `navigate` 에 `force: true` 뒤 닫기 — `.claude/rules/browser-qa.md`)

### 조각 F — 후속 정리 마이그레이션 (이번 배포 제외)

옛 응대 완료 함수 `mark_general_inquiry_resolved` · 응대 완료 표 `general_inquiry_resolutions`(477) · 옛 뷰 `general_inquiry_message_summary`(481) 삭제 + **같은 파일에서** `purge_audit_data_all` 재정의(477 지우는 줄 빼기). 조각 6 운영 안정 뒤, 세 형태로 호출부 0건 확인 뒤. 검문소 `reverb-supabase-expert` + `reverb-reviewer`

## ⚠️ 공유 지점 경고

- **`dev/lib/storage.js`·`dev/lib/shared.js`(핫스팟)** — 조각 2 와 조각 5(지우기)만. 🔴 **조각 3·4 는 이 두 파일을 고치지 않는다**(3·4 병렬의 전제). 고칠 일이 생기면 조각 2 를 다시 열어 순차로
- **응급 처치(10/6 운영 반영 #1918 — 서비스 탭 배지)를 조각 3 이 다시 그린다** — `openInquiryPage` 의 `Promise.all([fetchMyApplicationsForInquiry(), refreshNavInquiryBadge()])` · 「새 답장이면 서비스 탭 먼저」 · `.inq-tab-badge`·`.inq-new-reply`. **합계 변수 `_navInquiryUnread` 와 「서비스 탭 먼저」 규칙은 잇고**, 그 변수를 채우는 조회만 새 뷰 합산(조각 2)으로. 착수 때 `docs/specs/2026-10-06-inquiry-service-tab-badge-handoff.md` 를 읽는다
- **가입 인증번호 화면 묶음(#1892, 10/13 운영)** — `app.js`·`storage.js` 를 같이 만진다. 그 묶음이 먼저 운영에 들어가면 그 뒤 이 기능을 골라 담을 때 두 파일이 맞물린다(S2·S3)
- **`dev/admin/index.html`** 은 조각 4 만, **`dev/index.html`** 은 조각 3 만. **`dev/build.sh`** 는 새 파일이 없어 아무도 안 만진다
- **빌드 산출물** — 조각 3·4 가 각자 빌드하면 병합 때 반드시 충돌한다. 개발 브랜치 최신을 받아 **다시 빌드**해서 푼다(손으로 합치지 않는다)
- **데이터베이스** — 476·482·483·495·479 는 안 바뀐다(P-4). 다른 작업이 `application_messages` 를 세는 새 조회를 만들면 `general_thread_id` 와 새 검사 제약(응모 칸이 빈 행은 대화 칸 필수)을 알아야 한다

## 🧭 배분 제안

- **권장 — 개발 1명 순차**: 1 → 2 → 3 → 4 → 5 → 6. 병렬로 얻는 시간은 화면 조각 하나만큼이고, 대신 빌드 산출물 충돌을 한 번 풀어야 한다. 조각 2 를 조각 3 앞머리에 합쳐도 되나 **조각 1 의 검증 13 은 조각 2 병합 전에** 해야 한다
- 대안 — 개발 2명: 개발 1 이 1 → 2, 이어서 조각 3(개발 1) ∥ 조각 4(개발 2) 각자 작업 폴더·기능 브랜치, 개발 1 이 5 → 6
- 데이터베이스 조각(1·F)은 **반드시 한 세션**(마이그레이션 번호 충돌). 착수 전 다른 세션이 마이그레이션을 만들 일이 있는지 묻는다
- 운영 반영(6)은 사용자 확인 없이는 진행하지 않는다
