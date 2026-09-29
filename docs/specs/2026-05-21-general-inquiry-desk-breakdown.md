# 📋 작업 분해표 — 일반 문의 창구 (응모에 매이지 않는 회원↔운영팀 메시지)

**사양서:** `docs/specs/2026-05-21-general-inquiry-desk.md`
**분해일:** 2026-09-29 / **총 작업 조각:** 12개 · **다른 조각과 동시에 할 수 있는 것:** 7개(0·1·3·4·5·6·8) · **반드시 순서대로 해야 하는 것:** 5개(2·7·9·10·11)

> 번호 읽는 법: 이 표의 조각 번호(0~11)는 작업 순서 표시일 뿐이다. 사양서 §5-5 의 마이그레이션 ①~⑧ 과는 **다른 번호**다. 본문에서는 마이그레이션을 「마이그 ①」로 적는다. 실제 마이그레이션 파일 번호는 미리 정하지 않는다(개발 세션이 파일을 만들 때 정한다).
>
> **사용자 결정(2026-09-29, 분해 중)**: ①관리자 받은편지함은 **탭 둘(「캠페인 문의」 / 「일반 문의」)**로 나눈다 ②회원 햄버거 「문의하기」 항목에 **안 읽은 답장 배지를 단다** ③메시지 표에 **「응모 번호와 회원 번호 중 정확히 하나만」 검사 제약을 넣는다** ④방침 공고는 **방침 문서 + 앱 안 공지**(메일 없음), 공고 7일(9/29 → 시행 10/6)

---

## 🚦 착수 전 선결 조건

| 번호 | 조건 | 누가 | 막는 대상 |
|---|---|---|---|
| S0 | **개인정보처리방침 개정·공고**(사양서 §10, 단계 0) — 문안 완료(2026-09-29, `docs/PRIVACY_{kr,ja}.md`). 공고일 = **방침 문서가 운영에 반영되는 날**(부칙에 9/29 로 적었다 — 늦어지면 부칙 날짜를 고친다) | 기획(문안) + **사용자(운영 반영 확인)** | **운영 병합(조각 11)만** 막는다. 개발은 막지 않는다 |
| S1 | 시행일 = 공고일 + 7일(부칙 10/6) | — | 조각 11 날짜 |
| S2 | ✅ 받은편지함 배치 — **탭 둘**(사용자 결정) | — | — |
| S3 | 정산 자주 묻는 질문 행 수정(단계 5-B) 승인 | 사용자 | 조각 8만 |
| S4 | 공고 기간 동안 **이 기능 조각을 운영 병합에 섞지 않는다**는 합의(조각 0 만 예외 — 아래) | 개발 세션 전원 | 그 사이 다른 기능의 운영 배포는 골라 담기 |

---

## ⚠️ 사양서 stale 점검 (2026-09-29 코드 대조 결과)

**§13-1 「현재 원본」 표 — 전부 아직 최신이다**(최신 마이그레이션 472 까지 셈). 표의 번호를 그대로 베이스로 쓴다.

**사양서와 실제 코드가 어긋나는 곳 — 11건** (결론을 바꾸는 1·2·7 은 사양서 본문에 반영했다)

| # | 사양서가 적은 것 | 실제 코드 | 영향 |
|---|---|---|---|
| 1 | §4: 받은편지함은 「합친 한 목록 + 「일반 문의」 칩」 | 받은편지함은 **캠페인부터 고르는 3단 화면**(`renderInboxCampaignList`·`renderInboxThreadList`, `admin-messaging.js:229·294`). 새 뷰 행을 그냥 합치면 캠페인 번호가 빈 행이 「(캠페인)」 가짜 그룹으로 묶인다 | ✅ **사용자 결정: 탭 둘** — 받은편지함 위에 「캠페인 문의 / 일반 문의」 탭. 일반 문의 탭은 왼쪽 열 없이 회원별 대화 목록 → 내용 2단. 미응대 수는 두 탭 합산 |
| 2 | (언급 없음) | 관리자 쪽은 대화 하나를 **응모 번호 하나로만** 구분한다(`_admMsgAppId`·`application_id` 36곳) | 대화 열쇠를 「응모 번호 / 회원 번호」 두 종류로 — 조각 6 의 가장 큰 일 |
| 3 | 5-4 ⑩: `loadMyApplications` 의 실패와 0건을 가른다 | `mypage.js:112` — 값을 돌려주지 않고 화면을 그리는 함수, 오류 무시 | 갈래 판정용 조회를 따로(조각 4 `fetchMyApplicationsForInquiry`) |
| 4 | §6 재사용 목록에 숨김 이력 조회 없음 | `fetchApplicationHideHistory(applicationId)`(`storage.js:4637`) 가 응모 번호로 거른다 | 짝 함수 하나 더(조각 4) |
| 5 | §13-2 에 `dev/js/app.js`(인플루언서 쪽) 없음 | 메시지 화면 주소 복원·뒤로가기·정리·당겨서 새로고침 목록을 `dev/js/app.js` 가 처리(62·95·269·325·633·678·717) | 조각 5 담당 파일에 넣는다(관리자 `dev/admin/app.js` 와 다른 파일) |
| 6 | §5-6 ①: 탈퇴 신청 목록을 화면이 조회 | `fetchWithdrawalStatesByInfluencer()`(`storage.js:4208`) 가 이미 있다 — 실패 `null` | 새로 만들지 않고 재사용 |
| 7 | 마이그 ①: 칸 `influencer_id` 추가(삭제 동작 미기재) | `delete_admin_completely`(현재 원본 **253**)가 `influencers` 행을 **직접 지운다** | 외래 키 **ON DELETE CASCADE** 필수(새 응대완료 표도). ✅ **사용자 결정: 검사 제약 `num_nonnulls(application_id, influencer_id) = 1` 넣는다** — 기존 행은 통과 |
| 8 | §13-2: 진입·정리 자리만 | `messaging.js` 에 `_msgCurrentAppId` 가드가 더 있다(보내기 370·새로고침 54·새 메시지 확인 40·회수 333·자주 묻는 질문 기록 804·830·846). `navigateBackFromMessages` 는 `_msgFrom` 을 저장만 하고 안 쓴다 | 조각 5 에서 전부 「일반 문의 모드」로 가른다 |
| 9 | (언급 없음) | 관리자 대화 위 자주 묻는 질문 열람 이력(`loadThreadFaqContext`)이 응모 번호로 조회 | 일반 문의 대화에서는 그 영역을 **안 그린다**(§11 「다음 판」 성격) |
| 10 | (언급 없음) | 회원 안 읽은 메시지 배지(`refreshMyMsgUnread`)는 응모 메시지만 센다 | ✅ **사용자 결정: 「문의하기」 항목에 배지를 단다** → 회원 쪽 안 읽음 조회 하나 추가(조각 4·5) |
| 11 | 5-6 ①: 「실패는 null, 0건은 빈 목록」 | 짝이 될 기존 함수 셋이 실패를 삼킨다(`fetchMessagePreviews`·`fetchAdminMessageUnreadCounts`·`fetchUnresolvedMessageCount`) | 새 짝 함수는 **실패 `null`**(조각 4 계약). 기존 함수는 안 건드린다 |

그 밖에 확인한 것: 번역 키 `messaging.navMenu`(「お問い合わせ」 — "문의하기") 미사용 상태로 남아 있어 재사용 가능 · `withdrawGuide` 사용처 0 · 30초 미응대 수 자리는 `admin-messaging.js:218` · `markNotificationsReadByRef(refTable, refId, kind)` 는 범용이라 그대로 씀 · 자동 번역 함수는 `application_id` 를 읽지 않음(추가 설정 0) · 「그 외」 갈래 카테고리는 시드 고유 번호 `00000001-0000-0000-0000-000000000005/6/7`(보수·정산 / 계정·프로필 / 그 외) 상수로 지목.

---

## 한눈에 보는 의존 순서

```
조각0 앱 안 공지 배너 ── 방침 문서와 같이 **즉시 운영**(S0) ── 7일 ──┐
                                                                     ▼
[세션 A] 조각1 마이그 ①~⑥ ─→ 조각2 마이그 ⑧ 뷰 ─→ 조각3 마이그 ⑦ 파기 셋 ─→ 조각6 관리자 탭 ─┐
                 │                                                                     │
[세션 B] 조각4 storage.js 계약(조각1과 같은 날) ─→ 조각5 회원 화면 ─→ 조각7 탈퇴 연결 ─────┤
                                                                                       ▼
                                                조각10 통합 검증(§9 1~10) ─→ 조각11 시행일 운영 적용
조각8 (5-B 운영 행 — 코드 아님, S3 뒤 아무 때나)                              └→ 조각9 (Q6-7 운영 행 — 조각11 직후)
```

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약(요약) | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| 0 | **앱 안 공지 배너**(방침 개정 공고) | `dev/lib/shared.js`(`POLICY_NOTICE`) · `dev/lib/i18n/{ja,ko}.js`(`policyNotice.*`) | `POLICY_NOTICE.id` 새 값 · 문구 「문의 창구 확대·보관 기간 표기 정정, 시행 2026-10-06」 · 「끄는 방법」 줄 없음(픽셀과 달리 회원이 끌 것이 없다) | 없음 | ✅ | 개발(아무 세션) — **골라 담아 즉시 운영** |
| 1 | 데이터 모델 — 마이그 ①~⑥ (단계 1) | `supabase/migrations/` 새 파일 6개 | 칸 `influencer_id` + 검사 제약 · 정책 4개 · 표 `general_inquiry_resolutions` · 함수 5개 · 기존 안 읽음 집계 조건 한 줄 · 감사용 청소 정리 | 없음 | ✅ 조각 4와 동시 | 세션 A |
| 2 | 관리자 목록용 새 뷰 — 마이그 ⑧ (단계 2) | 새 파일 1개 | 뷰 `general_inquiry_message_summary` | 1 | ❌ | 세션 A |
| 3 | 탈퇴 첨부 파기 함수 셋 — 마이그 ⑦ (단계 6) | 새 파일 1개 | 368 목록·건수 + 451 경고를 `LEFT JOIN`+`COALESCE` 로 | 1 | ✅ 조각 5와 동시 | 세션 A |
| 4 | storage.js 새 함수 묶음(계약 먼저) | `dev/lib/storage.js` **만** | 새 함수 13개(아래) | 없음(시험은 1·2 뒤) | ✅ 조각 1과 동시 | 세션 B |
| 5 | 회원 화면 (단계 3) + 문의 배지 | `dev/js/messaging.js` · `dev/js/notifications.js` · `dev/js/app.js` · `dev/index.html` · `dev/css/mypage.css` · `dev/lib/i18n/{ja,ko}.js`(`inquiry.*`) | `openGeneralInquiryPage(from)` · `#page-inquiry` · 알림 분기 · 햄버거 배지 | 4 | ✅ 조각 6과 동시 | 세션 B |
| 6 | 관리자 받은편지함 **탭 둘** (단계 4 + 단계 5 ②) | `dev/js/admin-messaging.js` · (필요하면) `dev/css/admin.css` | 탭 「캠페인 문의 / 일반 문의」 · 대화 열쇠 두 종류 · 미응대 수 두 경로 합산 · 탈퇴 날수/대기 | 2·4 | ✅ 조각 5와 동시 | 세션 A |
| 7 | 탈퇴 연결 (단계 5 ①③) | `dev/js/mypage.js`(탈퇴 화면만) · `dev/lib/i18n/{ja,ko}.js`(`withdrawView.*` 5키 · `withdrawGuide` 삭제) · `docs/specs/2026-08-19-member-withdrawal-breakdown.md` | 문의 버튼 → `openGeneralInquiryPage('withdraw')` | 5 | ❌ | 세션 B |
| 8 | 정산 자주 묻는 질문 행 수정 (단계 5-B) | 코드 없음 — 운영 관리자 화면 | 노드 `…0005-000000000003`: `action_type='none'` · `is_human_handoff=true` | S3 | ✅ | 사용자(개발이 안내) |
| 9 | 탈퇴 Q6-7 운영 행 수정 (§12 ① 표 8) | 코드 없음 — 운영 행 | LINE 문구 삭제 + 「바로 직접 문의」 모드 | 11 | ❌ 시행일 병합 **직후** | 사용자(개발이 안내) |
| 10 | 통합 검증 + 검문소 + 문서 | 사양서 「구현 결과」 · `CLAUDE.md` · `docs/FEATURE_SPEC.md` | §9 검증 1~10 통과 기록 | 1~7 | ❌ | 두 세션 |
| 11 | 시행일 운영 적용 | 운영 데이터베이스 + 운영 병합 **한 번** | 데이터베이스 → 코드 순서 | 10·S0·S1 | ❌ | 개발 + 사용자 확인 |

---

## 조각별 상세

### 조각 0 — 앱 안 공지 배너 (방침 개정 공고)
**하는 일** — 픽셀 공고(2026-09-17)가 만든 `POLICY_NOTICE`(shared.js) + `policyNotice.*`(ja·ko) 틀을 **재사용**해 새 공지로 갈아 끼운다. `id` 는 새 값(옛 값이면 지난 공지를 닫은 회원에게 안 뜬다 — CLAUDE.md). 문구(한국어 뜻 병기): 「プライバシーポリシーを改定します — お問い合わせ窓口を広げ、保管期間の表記を実際の取り扱いに合わせて訂正しました。施行日：2026年10月6日」(개인정보처리방침을 개정합니다 — 문의 창구를 넓히고 보관 기간 표기를 실제 처리에 맞게 정정했습니다. 시행일 2026-10-06). 「끄는 방법」 줄은 넣지 않는다.
**산출 계약**: `POLICY_NOTICE.id`·`effectiveDate='2026-10-06'`, 키 `policyNotice.*` 교체.
**완료 정의**: 개발서버 회원 로그인 시 공지가 뜨고 닫으면 다시 안 뜬다. 관리자 앱에는 안 뜬다. 픽셀 공지의 옛 `id` 를 닫았던 계정에도 새 공지가 뜬다.
**검문소**: `reverb-reviewer`.
**주의**: 🔴 **이 조각만 방침 문서와 함께 즉시 운영에 나간다**(골라 담기 — 창구 코드는 섞지 않는다). `shared.js` 는 핫스팟이라 이 조각을 먼저 끝내고 병합한 뒤 조각 4 를 시작한다(같은 파일은 아니지만 같은 세션이 하면 안전). 픽셀 공지가 아직 떠 있는 회원(10/17 시행)이 있다 — 공지 하나만 보이는 구조이므로 **새 공지가 픽셀 공지를 대체**한다. 픽셀 공지는 이미 9/17 부터 12일 떠 있었고 메일 통지도 끝났으므로 대체해도 된다(사용자 확인 권장 — S0 와 함께).

### 조각 1 — 데이터 모델 마이그 ①~⑥ (한 세션, 순서대로)
- **마이그 ①** `application_messages` 에 `influencer_id uuid NULL REFERENCES public.influencers(id) ON DELETE CASCADE` 추가, `application_id` 의 NOT NULL 을 푼다. 기존 행 백필 없음. 색인 `(influencer_id, created_at) WHERE application_id IS NULL`. ✅ 검사 제약 `CHECK (num_nonnulls(application_id, influencer_id) = 1)`(사용자 결정 — 기존 행은 응모 번호만 차 있어 통과. `NOT VALID` 없이 걸되 적용 전 위반 0건 조회로 확인).
- **마이그 ②** 새 정책 4개(전부 회원용, 기존 정책 문장 무편집). 이름 제안: 표 조회 `influencer_read_own_general_inquiry_messages`(`application_id IS NULL AND influencer_id = auth.uid() AND` 숨김·회수 안 됨) · 첨부 내려받기 `msg_attachments_general_influencer_select`(첫 조각 `general` **그리고** 둘째 조각 = `auth.uid()::text` **그리고** 본인의 숨김·회수 안 된 일반 문의 메시지에 실려 있을 것) · 올리기 `msg_attachments_general_influencer_insert`(첫·둘째 조각만) · 삭제 `msg_attachments_general_influencer_delete`(첫·둘째 조각 + 본인 메시지에 실려 있을 것, 숨김·회수 조건 없음).
- **마이그 ③** 표 `general_inquiry_resolutions`(`influencer_id uuid PRIMARY KEY REFERENCES influencers(id) ON DELETE CASCADE` · `resolved_at` · `resolved_by` · `resolved_by_name` · `resolved_after_message_at` · `resolution_method CHECK(auto_replied|manual)`). 조회 정책 `(SELECT public.is_admin())`(415 방식), 쓰기 정책 없음.
- **마이그 ④** 함수 5개(`SECURITY DEFINER` + `SET search_path=''`, `REVOKE FROM PUBLIC` 과 `REVOKE FROM anon` **둘 다**, `GRANT TO authenticated`): `get_general_inquiry_messages(p_influencer_id uuid DEFAULT NULL)`(반환 열은 326 과 같은 모양 — 번역 칸 셋 포함, `sender_id` 는 관리자만) · `send_general_inquiry_message(p_influencer_id, p_body, p_attachments)`(발신 제한은 323 과 같은 계산, 관리자 답장 시 응대완료 행 + 알림 `message_received`/`ref_table='general_inquiry'`/`ref_id=회원 번호` 중복 방지, 회원 새 글이면 응대완료 행 삭제, 첨부 경로 `general/{회원번호}/` 서버 검사, 거부는 `P0001` + 일본어) · `mark_general_inquiry_messages_read(p_influencer_id DEFAULT NULL)` · `mark_general_inquiry_resolved(p_influencer_id)` · `general_inquiry_admin_unread_counts(p_admin_auth_id DEFAULT NULL)`.
- **마이그 ⑤** `application_message_admin_unread_counts`(베이스 144)에 `AND m.application_id IS NOT NULL` 한 줄. `CREATE OR REPLACE`.
- **마이그 ⑥** `purge_audit_data_all`(베이스 179)에 ⓐ일반 문의 첨부 경로 수집(기존 반환 `message_attachments` 에 합침) ⓑ`application_messages WHERE application_id IS NULL AND influencer_id = ANY(감사용)` 삭제 ⓒ`general_inquiry_resolutions` 정리. 반환 모양 불변.

**완료 정의** — 개발 데이터베이스 적용 후 **새 함수 5개 + 고친 함수 2개를 각각 한 번 이상 실제 호출**(§9 검증 1, 관리자 검사 함수는 로그인 브라우저 콘솔). 권한은 `proacl` 맨 앞 `=X/` 없음 확인. 검사 제약 적용 전 `SELECT count(*) FROM application_messages WHERE num_nonnulls(application_id, influencer_id) <> 1` 이 0.
**검문소** — `reverb-supabase-expert`(설계·작성 뒤) → `reverb-reviewer`.
**주의** — ⑤는 ①과 **같은 배포**. 기존 정책·뷰 문장 무편집(5-4 ②). 되돌리기는 파일마다 하단에.

### 조각 2 — 새 뷰 마이그 ⑧
`general_inquiry_message_summary`, `security_invoker = true`, 기준 표 `influencers`. 열은 144 뷰와 **같게**(`NULL::uuid AS application_id`, `i.id AS influencer_id`, `NULL::uuid AS campaign_id`, `message_count`, `unread_for_influencer`, `unresolved_for_admin_team`, `last_message_at`). 미응대 CASE 는 144 복사 + 기준 표 `general_inquiry_resolutions`. 감사용·탈퇴 칸 없음.
**완료 정의** — 관리자 콘솔에서 행 반환, 회원 세션에서 **본인 행만**.

### 조각 3 — 파기 함수 셋 마이그 ⑦
368 의 목록·건수 함수 + 451 의 `get_withdrawal_ops_alert` 를 `LEFT JOIN applications` + `COALESCE(m.influencer_id, a.user_id)` 로. 셋 글자 그대로 같은 판정. `mark_withdrawal_message_attachments_purged` 는 메시지 번호 기준이라 무변경.
**완료 정의** — §9 검증 10(적용 전후 응모 있는 행 건수·목록 불변 + 시험용 일반 문의 첨부 행이 새로 잡힘). 베이스는 451.

### 조각 4 — storage.js 계약 (이 파일은 이 조각만 고친다)
새 함수(이름 제안, 실패 `null`/0건 `[]` 규약): `fetchGeneralInquiryMessages(influencerId=null)` · `sendGeneralInquiryMessage(body, attachments=[], influencerId=null)` · `markGeneralInquiryMessagesRead(influencerId=null)` · `markGeneralInquiryResolved(influencerId)` · `uploadGeneralInquiryAttachment(file, influencerId)`(`{path:'general/{id}/{난수}.jpg', …}`) · `fetchMyApplicationsForInquiry()`(`[{id,campaign_id,status}]` / 실패 `null`) · **`fetchMyGeneralInquiryUnread()`**(회원 안 읽음 수 — 배지용, 실패 `null`) · `fetchAdminGeneralInquiryThreads(opts)`(실패 `null`) · `fetchGeneralInquiryUnresolvedCount()` · `fetchGeneralInquiryAdminUnreadCounts()` · `fetchAdminGeneralSentAtMap()` · `fetchGeneralInquiryPreviews(influencerIds)` · `fetchGeneralInquiryHideHistory(influencerId)`. 재사용: `withdrawOwnMessage`·`hideApplicationMessage`·`unhideApplicationMessage`·`getMessageAttachmentSignedUrl`·`markNotificationsReadByRef('general_inquiry', uid, 'message_received')`·`fetchWithdrawalStatesByInfluencer()`.
**완료 정의** — 조각 1·2 적용 뒤 콘솔에서 각 함수 한 번씩. **개발 브랜치에 먼저 병합**한 뒤 조각 5·6 이 그 위에서 시작.

### 조각 5 — 회원 화면 (단계 3) + 문의 배지
1. 햄버거 「お問い合わせ」(문의하기) 항목(`renderNavMenu`, 키 `messaging.navMenu` 재사용) — 마이페이지 묶음 아래·로그아웃 위. ✅ **안 읽은 답장 배지**: 메뉴를 열 때 `fetchMyGeneralInquiryUnread()` 한 번(실패면 배지 없음).
2. `openGeneralInquiryPage(from)` — `from ∈ {'nav','branch','withdraw','notif'}`. `fetchMyApplicationsForInquiry()`: `null` → 갈래 화면 + 다시 시도 / `[]` → 바로 「그 외」(뒤로가기 홈) / 1건 이상(취소 포함) → 갈래 화면.
3. 갈래 화면 `#page-inquiry`(주소 `#inquiry`) — 「応募したキャンペーンについて」("응모한 캠페인에 대해") → 응모 목록(취소는 「閲覧のみ」 "읽기만") → `openMessagesPage(appId,'inquiry')` / 「その他のお問い合わせ」("그 외 문의") → 일반 문의 대화.
4. 「그 외」 대화는 `#page-messages` 재사용, 주소 `#inquiry-general`, 모드 값 `_msgMode='general'`, 헤더 「運営チームへのお問い合わせ」("운영팀 문의"), 상태 한 줄 숨김. stale 8 의 가드 7곳 전부 분기. **정리 함수에서 모드·헤더 복원.**
5. 자주 묻는 질문 「응모 없는 모드」 — `setupFaqGate(null, {}, {general:true})`, 카테고리 5·6·7 의 `relevant_stages` 빈 항목만.
6. 뒤로가기 넷(§3) — `_msgFrom` 을 실제로 쓰되 응모 메시지 기존 동작 유지.
7. 알림 — `onNotifItemClick` 에서 `refTable==='general_inquiry'` 를 `message_received` 분기 **앞**에. 진입 후 `markNotificationsReadByRef('general_inquiry', uid, 'message_received')`.
8. `dev/js/app.js` — 새 주소 둘의 복원·뒤로가기·정리 훅·당겨서 새로고침 목록.
9. 번역 키 `inquiry.*`: `title`「お問い合わせ」("문의하기") · `branchApp` · `branchOther` · `readOnly`「閲覧のみ」("읽기만") · `loadError`「応募履歴を読み込めませんでした」("응모 이력을 불러오지 못했습니다") · `retry`「もう一度読み込む」("다시 불러오기") · `generalTitle`「運営チームへのお問い合わせ」("운영팀 문의").
**완료 정의** — §9 검증 2·3·4·4-B·4-C·5·6·7(회원 쪽)·9 + 배지가 답장 후 뜨고 읽으면 꺼짐.
**주의** — Apple 지침(누름 영역 44픽셀), 입력 16픽셀, `translate="no"`, 초등학생 눈높이. `mypage.js` 는 안 고친다(조각 7 과 충돌 방지).

### 조각 6 — 관리자 받은편지함 탭 둘 (단계 4 + 단계 5 ②)
1. ✅ **받은편지함 위에 탭 「캠페인 문의 / 일반 문의」**(`status-tab-bar` 패턴). 캠페인 문의 탭 = 지금 3단 화면 그대로. 일반 문의 탭 = 왼쪽 캠페인 열 없이 **회원별 대화 목록 → 내용** 2단. 탭 라벨에 각 미응대 수.
2. 대화 열쇠 둘 — `_admMsgThread = {kind:'app'|'general', id}`. 응모 행에서 여는 창(`openAdminMessageModal`)은 응모 전용 그대로.
3. `refreshInboxData` — 새 조회 4종(목록·안 읽음·미리보기·보낸 시각) 따로. 일반 문의 쪽 `null` 이면 그 탭에 「불러오지 못했습니다」, 캠페인 탭은 그대로.
4. 미응대 수 합산 — `updateInboxSidebarBadge` + 30초 경로(218행) **둘 다**. 새 짝 `null` 이면 기존 숫자만.
5. 대화 화면 — 답장(`sendGeneralInquiryMessage`, 첨부 `general/{회원번호}/`), 응대완료, 숨김·복구, 숨김 이력. 상태 한 줄·자주 묻는 질문 이력은 안 그림.
6. 탈퇴 표시 — `fetchWithdrawalStatesByInfluencer()` 한 번으로 **두 탭 모두**: `scheduled` 「탈퇴 D-N」 / `pending_payout` 「탈퇴 대기 중」 / `null` 이면 표시 안 함.
**완료 정의** — §9 검증 8 전부 + 3 + 9.
**주의** — `dev/admin/index.html` 은 **가능하면 안 고친다**(탭도 자바스크립트로 그린다). 상세 설계 문구 「합친 한 목록 + 칩」은 사양서 §4 를 **탭으로 고쳐 두었다**(2026-09-29).

### 조각 7 — 탈퇴 연결 (단계 5 ①③)
§12 ① 표 1~6: `withdrawView.bContact`·`dCancelAdminOnly`·`eAdmin`·`rContact`·`errLocked` 의 LINE 부분을 「お問い合わせ」("문의하기") 안내로, `mypage.js`(785·800·810·844·883·933 일대)에 `openGeneralInquiryPage('withdraw')` 버튼. `withdrawGuide` 삭제. 표 7·9 는 LINE 유지. ③ 판단을 탈퇴 작업표에 기록.
**완료 정의** — 잠금 걸린 시험 계정에서 「문의하기」 → 「그 외」 대화 → 뒤로가기로 탈퇴 화면 복귀. 한·일 둘 다.
**주의** — 창구 본체보다 먼저 운영에 나가면 안 된다(조각 11 과 같은 병합).

### 조각 8 — 5-B 정산 자주 묻는 질문 행 (코드 없음)
운영 관리자 자주 묻는 질문 화면에서 노드 `…0005-000000000003` 을 `action_type='none'`·`is_human_handoff=true` 로. S3 뒤 아무 때나.

### 조각 9 — 탈퇴 Q6-7 운영 행 (코드 없음)
시행일 운영 병합 **직후** LINE 문구 삭제 + 「바로 직접 문의」 모드.

### 조각 10 — 통합 검증
§9 검증 1~10 을 개발서버 실제 로그인 브라우저로(회원 둘 + 관리자). 검문소: `reverb-supabase-expert` → `reverb-reviewer`(이름 세 형태 검색 지목) → `reverb-qa-tester`(한 세션만). 사양서 「구현 결과」에 마이그레이션 번호 기록, `CLAUDE.md`(응모건 메시지 절 옆 짧은 절 — 15만 자 한도라 낡은 서술을 빼면서), `FEATURE_SPEC.md`.

### 조각 11 — 시행일 운영 적용 (한 번)
①운영 데이터베이스에 마이그 ①→②→③→④→⑤→⑥→⑧→⑦, 새 함수 한 번씩 호출 ②적용 전 개발↔운영 데이터베이스 기계 대조 ③이 기능 조각만 모아 **운영 병합 한 번** ④조각 9 ⑤운영에서 §9 검증 2·8·9 재실행. 되돌리기: 코드는 되돌림 커밋, 데이터베이스는 정책·함수 먼저, 칸은 마지막(행이 쌓였으면 칸은 두고 창구만 닫는다).

---

## ⚠️ 공유 지점 경고
1. 🔴 **운영 병합은 한 번**(조각 0 만 예외) — 공고 기간 7일 동안 다른 기능을 운영에 올릴 때 **개발 브랜치를 통째로 올리면 창구가 시행 전에 열린다.** 그 기간 운영 배포는 골라 담기.
2. `dev/lib/storage.js` — 조각 4 만. 추가는 조각 4 의 후속 병합 요청으로 한 세션이.
3. `dev/lib/shared.js` — **조각 0 만**(공지 상수). 창구 조각은 안 건드린다(거부 문구를 `P0001`+일본어로 두면 「정상 거부 목록」도 무편집).
4. 번역 파일 — 조각 0(`policyNotice.*`)·5(`inquiry.*`)·7(`withdrawView.*`) 셋이 다른 자리. 순서 0 → 5 → 7 로 고정.
5. 마이그레이션 번호 — 조각 1·2·3 은 세션 A 한 곳.
6. `dev/admin/index.html`·`dev/admin/app.js`·`dev/js/admin.js`·`dev/js/admin-core.js`·`dev/build.sh` — 고칠 필요 없게 설계. 필요해지면 멈추고 조율.
7. `#page-messages` 재사용 — 정리 함수 복원을 §9 검증 9 로 확인.
8. 접근 정책은 SQL 편집기로 검증 안 됨 — 검증 2·3·7 은 실제 로그인 브라우저.
9. `CLAUDE.md` — 조각 10 에서 한 번에.

---

## 🧭 배분 제안 (개발 세션 2개 동시 진행)

| 날 | 세션 A (데이터베이스 → 관리자) | 세션 B (공지 → storage.js → 회원) |
|---|---|---|
| **1일차(9/29)** | 조각 1: 마이그 ①~⑥ → 데이터베이스 전문 에이전트 → 개발 적용 → 함수마다 호출 | **조각 0 앱 안 공지**(즉시 운영 골라 담기 — 방침 문서와 함께) → 조각 4 계약 함수 → 오후 콘솔 시험 → 병합 |
| **2일차** | 조각 2(뷰) + 조각 3(파기 셋) → 조각 6 시작(탭) | 조각 5 시작(햄버거+배지·갈래·일반 모드·주소) |
| **3일차** | 조각 6 계속(열쇠 이원화·합산·탈퇴 표시) | 조각 5 마무리(게이트 모드·알림·뒤로가기 넷) → 병합 → 조각 7 |
| **4일차** | 조각 10 관리자 쪽 검증 8·9·10 | 조각 10 회원 쪽 검증 2~7·9(브라우저 도구 한 세션씩) |
| **5일차 여유** | 지적 반영·리뷰·문서 | 같은 일 |
| **시행일 10/6** | 조각 11 → 조각 9 | — |

→ 개발 4~5일이면 **공고 7일 안에 들어온다.** 병목은 S0(방침 문서 운영 반영 = 공고 시작) — **오늘 반영해야 10/6 에 열 수 있다.** 조각 8 은 S3 확인만 받으면 1일차에 따로.

---

## 구현 결과 (개발 세션이 채울 것 — 조각 번호별로 기록)
