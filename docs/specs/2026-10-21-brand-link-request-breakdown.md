# 📋 작업 분해표 — 브랜드 「연결 요청」(관리자가 기존 브랜드 계정을 대표로 이을 때 본인 24시간 수락)

**사양서:** `docs/specs/2026-10-21-brand-link-request.md` (인계 `docs/specs/2026-10-21-brand-link-request-handoff.md` · 짝 작업표 `docs/specs/2026-10-21-admin-brand-detail-tabs-breakdown.md` 조각 13·14)
**분해일:** 2026-10-21
**총 작업 조각:** 10개 · **병렬 가능:** 5개(메일·공개 서버 함수·브랜드 화면 쪽 연결 5~9 는 데이터베이스 흐름과 동시에 **작성**할 수 있다 — 반영은 짝 조각 뒤) · **순차 필수:** 5개(데이터베이스 연결 1→2→3→4 + 문서 연결 10)
**완료 기준:** 개발서버 데이터베이스 적용 / 개발서버 배포까지. 운영은 브랜드 페이지 묶음과 함께(사양서 7절) — 이 표 범위 밖.

> **화면 문구:** 브랜드 화면·메일·관리자 화면 모두 한국어다. 일본어 문구 없음.
> **마이그레이션 번호:** 미리 정하지 않는다(「새 마이그레이션」). 지금 마지막은 **575**. 572 뒤 새 파일은 기록 표 양식(`BEGIN;` … 자기 기록 줄 … `COMMIT;`)이어야 병합 요청 검사를 통과한다(`.claude/rules/supabase.md` 「새 파일 양식」).
> 🔴 **데이터베이스 먼저, 화면 나중** — 그리고 짝이 둘 있다: **연결 3 ↔ 연결 8 같은 날**, **연결 4 ↔ 연결 7 ↔ 연결 9 같은 날**(아래 의심 1·3).


## ✅ 사용자 결정 (2026-10-21)

| # | 결정 |
|---|---|
| Q1 | 수락 때 약관 동의는 **계정의 지금 칸에 덮어쓰기**(이력 표 없음) |
| Q2 | 비밀번호 정하며 수락 화면에 계정 이메일을 **읽기 전용으로 보인다** — 링크 판정 `existing_setpw` 에 `email` 을 싣는다 |
| Q3 | 데이터베이스 조각 연결 1~4 = **세션 A**(조각 15 는 그 사이에 끼운다) |
| Q4 | 메일·공개 함수·브랜드 화면 조각 연결 5~9(+문서 10) = **새 세션 C** |

> 아래 본문 끝의 「사용자 확인 필요」 Q1~Q4 는 이 표로 닫혔다(질문 원문은 기록으로 남긴다).

---

## 현재 상태 (2026-10-21, 코드·마이그레이션 직접 확인)

### 사양서가 「확인」으로 남긴 것 — 결과

| 확인 항목 | 결과 |
|---|---|
| `_brand_email_owner`(527:275, 이후 재정의 없음)가 비밀번호 안 정한 브랜드 계정에 `brand` 를 돌려주는가(L8 전제) | **그렇다.** 판정은 `brand_accounts` 행 유무뿐(`password_set_at` 을 안 본다). 우선순위 관리자 > 브랜드 > 인플루언서 |
| `_brand_invite_acceptable(p_invite_id, p_auth_id, p_via_link)`(530:367, 재정의 없음)가 비밀번호를 보는가 | **안 본다.** 대기·만료 전·`blocked` 아님·브랜드 활성·(계정 주면)계정 이메일 = 초대 이메일·지금 갈래 = 보낼 때 갈래(`brand` 면 `sent_owner_auth_id` 일치)만. → L8 마지막 단계가 통과한다. 자리 검사·대표 유무 없음(B2·B4 와 맞다) |
| 현재 원본 번호 | `admin_upsert_brand_owner_account` **573** · `_brand_contacts_locked` **574** · `_brand_contacts_mark_primary` **574**(531 아님 — `_brand_set_contacts` 로 옛 대표 칸 셋까지 맞춘다) · `admin_get_brand_account_status` **533** · `admin_link_brand_owner_account` **533**(화면 호출 0건 확인) · 530·531·532 함수는 재정의 없음 · `get_brand_invite_link_state` **534** |

### 그 밖에 확인한 것

| 항목 | 실제 |
|---|---|
| `respond_brand_invite` 인자 | **3개**(`p_invite_id, p_link_id, p_action`) — 사양서의 「옛 2인자」는 틀림(stale 1) |
| `_brand_acceptable_invites_for` 반환 | `SETOF public.brand_invites`(표 행 그대로) — jsonb 아님. 칸을 더하면 자동으로 실린다(stale 2). 이 함수를 로그인 판정(`get_my_brand_login_state`)·받은 초대·비밀번호 찾기 열림(`get_brand_link_state`·`service_issue_brand_account_link`) 넷이 쓴다 |
| 설정 완료 기록 | `complete_brand_account_setup`(532:1027)은 `password_set_at`·`password_changed_at`·약관 셋 + **`setup_link_id = NULL`** 을 쓰고, 약관 버전이 비면 **예외**(22023)를 던진다(결과 값이 아니다) |
| 다른 브랜드 설정 링크 | 비밀번호를 정한 계정의 설정 링크는 `get_brand_link_state('setup')` 이 `invalid`, 화면은 `already_set` 도 `showBrandLinkInvalid()`(brand-login.js:352) — **「이미 설정됨」 화면은 없다**(stale 6) |
| 메일 함수 `notify-brand-invite` | 조회 칸(175)에 `invite_kind` 없음 · 읽자마자 대표 확인(182-191) · 개발서버 두 겹 잠금 응답은 **`dev_mail{subject, text}`**(링크가 본문 안) — 설정 메일의 `dev_link` 와 모양이 다르다 |
| 메일 양식 동기화 | `scripts/sync-email-templates.sh` 46·47줄의 **함수 ↔ 양식 대응표**를 고쳐야 새 양식이 미러에 들어간다(사양서는 「동기화 실행」만 적음 — stale 5) |
| 공개 함수 `brand-invite-accept` | 실패 때 **반쪽 계정을 지우는 정리 경로**(`deleteUser`, 93~107줄)가 있다 — 원래 있던 계정을 다루는 갈래를 여기 끼우면 지우기 경로와 한 파일에 산다 |
| 관리자 화면 storage | `sendBrandAccountSetupMail`·`fetchBrandAccountStatus`·`_brandAccountRpc` 계열만 있다. **`notify-brand-invite` 를 부르는 storage 함수는 없다**(브랜드 화면이 `brand-members.js` 의 `brandCallFunction` 으로만 부름 — 관리자 빌드엔 없다). 사양서 4-6 「있으면 재사용」은 해당 없음(stale 7) |
| 브랜드 화면 | 링크 착지 `continueBrandInviteLanding`(brand-invite.js:206)은 `recipient==='new'` 만 설정 화면, 그 밖은 전부 「로그인 후 수락」 · `resumeBrandInviteLink` 는 `existing` 이 아니면 **링크를 지우고 false**(233·235) · 비밀번호 설정 폼 `#setpwForm` 은 이미 약관 동의 두 칸 + 「보기」(`data-legal`)를 갖는다 · `data-legal` 바인딩은 **부팅 때 한 번**(brand-login.js:566) — 마이페이지처럼 나중에 그리는 줄엔 안 붙는다 · `BRAND_TERMS_VERSION = 'dev-2026-10-14'`(brand-login.js:30) |
| 받은 초대 화면 bw01-03(`#invite`, index.html 253~270) · 마이페이지 줄(brand-mypage.js:138~149) | 약관 동의 칸 없음 · 문구 전부 「대표 담당자 ○○님이 멤버로 초대」 |
| 관리자 화면 대기 자리 | admin-brand-detail.js 598(칩 자리 주석) · 1134·1151(임시 토스트) · 1394·1403(`bdOwnerLocked`) — 관리자 작업표 조각 13 몫 |

### 낱말 전파 점검 — 새 낱말 「연결 요청」 · 걷는 낱말 「연결 안내」
찾은 방법: `초대|연결 안내|link-notice|brand-link` 를 `dev/js/brand-*.js`·`dev/brand/index.html`·`supabase/functions/notify-brand-*`·`docs/email-templates/brand-*`·`scripts/sync-email-templates.sh` 에서. 자주 묻는 질문·엑셀·인플루언서 화면에는 없다.

| 자리 | 지금 | 처리 조각 |
|---|---|---|
| `BRAND_INVITE_MSG`·`showInviteScreen` 설명·`_setInviteBusy` 「초대 수락」·`declineCurrentInvite` 확인 문구·착지 제목 「초대를 확인하시겠습니까?」(brand-invite.js) | 멤버 초대 전제 | 연결 8(연결 요청 줄이면 갈래) · 연결 9(설정 착지) |
| 마이페이지 줄 「초대한 사람 ○○(대표 담당자)」·거절 확인·수락 토스트(brand-mypage.js 25·141·277~279) | 멤버 초대 전제 | 연결 8 |
| `#invite` 제목 「브랜드 초대」·단추 「초대 수락」(index.html 256·267) | 정적 문구 | 연결 8(제목에 아이디를 붙여 갈래) |
| 받은 초대 묶음 머리 「받은 초대 N」 | 그대로(사양서 결정 L1 — 같은 묶음) | 안 바꿈 |
| `notify-brand-account-setup` 의 `mail_kind:'link'`·양식 `brand-link-notice`(원본·미리보기·미러·카탈로그 642~643줄·`brand-account-setup.html` 38줄 주석·동기화 대응표 46줄) | 걷을 것 | 연결 6 |
| 관리자 임시 토스트 「「연결 요청」 기능은 준비 중입니다」(admin-brand-detail.js 1134·1151) | 임시 | 관리자 작업표 조각 13 |
| `CLAUDE.md`·`.claude/rules/brand-account.md` 의 `mail_kind:'link'`·즉시 연결 서술 | 낡게 됨 | 연결 10 |

---

## 의심·경우의 수 (반대론자)

1. **(데이터·순서) 🔴 관리자 요청 함수가 먼저 들어가면 옛 수락 함수가 연결 요청을 「멤버」로 받아 준다.** 532 `respond_brand_invite` 는 종류를 모르고 늘 `'member'` 로 넣는다(680줄). 관리자 쪽(연결 2)만 개발서버에 들어간 날 받는 사람이 링크를 열면 **대표가 아니라 멤버**가 되고 대표 없는 브랜드에 멤버가 생긴다(533 `owner_has_members` 전제 붕괴). → 연결 1 이 받는 쪽 셋(`respond_brand_invite`·`_brand_acceptable_invites_for`·`get_brand_invite_link_state`)에 **연결 요청 줄 임시 막음**을 넣고 연결 3 이 푼다(개발 기본값 1).
2. **(기술) 메일 함수를 표 확장보다 먼저 배포하면 멤버 초대 메일까지 죽는다.** 조회 칸에 `invite_kind` 를 넣는 순간, 그 칸이 없는 데이터베이스에서는 모든 호출이 조회 오류(500)다. → 연결 5 배포는 연결 1 적용 확인 뒤.
3. **(사용 흐름) 비밀번호 안 정한 계정이 로그인 화면에 갇힌다.** 링크 판정이 `existing_setpw` 를 돌려주기 시작했는데(연결 4) 화면이 옛것이면 — `continueBrandInviteLanding` 은 `new` 가 아니므로 로그인 쪽으로 보내고 `resumeBrandInviteLink` 는 링크를 지운다. 비밀번호가 없어 로그인할 수 없다. 반대로 연결 3 만 들어가고 연결 4 가 없으면 같은 계정이 `existing` 판정으로 같은 막다른 길에 간다(개발서버 한정·짧게). → 연결 4·7·9 같은 날, 연결 3 ↔ 4 사이를 길게 두지 않는다.
4. **(사용 흐름) 다른 브랜드 계정으로 로그인한 채 링크를 열면 「이 초대는 더 이상 쓸 수 없습니다」** 만 뜬다 — 원인(다른 계정)을 말하지 않는다. 지금 멤버 초대와 같은 동작이고 사양서 5-3 이 받아들였다. 문구 개선은 후속 후보로만 적는다.
5. **(사용 흐름) 마이페이지 「보기」가 안 열린다.** `data-legal` 은 부팅 때 한 번 바인딩된다 — 다시 그리는 받은 초대 줄에 그대로 붙이면 눌러도 아무 일이 없다. → 연결 8 은 `data-my-act` 갈래에서 `openLegalModal()` 을 직접 부른다.
6. **(법률·약관) 수락 때 약관 칸 셋을 덮어쓰면 첫 동의 기록이 사라진다.** `brand_accounts.terms_agreed_at`·`privacy_agreed_at`·`terms_version` 은 이력이 없다. 사양서 L3 는 「그때 버전·시각 기록」만 정했다 → 사용자 확인 Q1. 또 `BRAND_TERMS_VERSION` 은 아직 개발용 자리값이다 — 출시 관문 1(`/약관확인`)에서 실제 버전으로.
7. **(데이터·보안) 비밀번호를 정하며 수락한 뒤 옛 설정 링크 번호가 남는다.** 532 설정 완료는 `setup_link_id` 를 비우는데 사양서 4-2 의 마무리 함수에는 그 줄이 없다. 남기면 같은 번호가 「재설정」 종류로는 유효 판정(`get_brand_link_state('reset')` 은 번호 일치 + 비밀번호 있음만 본다)이 된다 → 개발 기본값 3.
8. **(운영) 개발자 두 명·세션 둘이 같은 함수를 만진다.** 이 표는 530·531·532·534 함수와 **세션 A 가 방금 만든 573·574 함수**를 다시 정의한다. 다른 세션이 같은 함수를 손대면 나중 적용이 앞 변경을 조용히 지운다(`two-developers.md` 1조) → 배분 제안에서 세션 A 에 몰아준다.
9. **(데이터) 관리자 작업표 조각 15(담당자 칸 직접 고치기 막는 트리거, `SECURITY INVOKER`·`current_user='authenticated'` 판정)와 수락 본체.** 수락 본체는 정의자 권한 함수 안에서 `_brand_set_contacts` 로 담당자 목록을 고치므로 그 트리거를 통과해야 맞다. 판정 갈래가 하나라도 어긋나면 **수락이 통째로 실패**한다 → 조각 15 적용 뒤 수락 1회를 다시 본다(관리자 작업표 14 2차 확인에 포함).
10. **(사용 흐름) 관리자 화면 개발서버 확인 모양이 다르다.** `notify-brand-invite` 의 개발서버 응답은 `dev_mail{subject, text}` 다(`dev_link` 아님). 관리자 조각 13 이 `dev_link` 를 찾으면 개발서버에서 「링크 없음」으로 보인다.

**현재 구현과 충돌하는 지점:** ①532 수락이 종류를 모르고 멤버로 넣음(의심 1) ②531 대표 쪽 함수 넷·`get_brand_members` 가 종류 구분 없이 대기 줄을 집음(사양서 3절 그대로) ③534 링크 판정에 종류 없음 ④`notify-brand-invite` 가 대표만 통과 ⑤`brand-invite-accept` 의 지우기 경로(개발 기본값 2) ⑥533 즉시 연결 함수가 서버에 살아 있음(로그인 사용자 실행 권한) ⑦`notify-brand-account-setup` 연결 안내 갈래(화면 호출 0건).

**의도 모호점:** ①약관 칸 덮어쓰기 vs 첫 동의 보존(Q1) ②비밀번호 정하며 수락 화면에 이메일을 보일지(Q2 — 피그마 bw01-02b 는 읽기 전용 이메일 칸이 있는데 534 는 `existing` 갈래에 이메일을 일부러 안 싣는다).

---

## ✅ 개발 기본값 (묻지 않고 알림 — 바꾸려면 말해 주세요)

| # | 기본값 | 근거 | 조각 |
|---|---|---|---|
| 기본값 1 | **중간 상태 보호** — 연결 1 이 받는 쪽 셋에 「연결 요청 줄이면 무효」를 임시로 넣고 연결 3 이 푼다. 연결 1·2 만 들어간 날 관리자는 요청을 보낼 수 있고, 받는 사람 링크는 「쓸 수 없는 링크」(개발서버만) | 의심 1. 관리자 조각 13 을 브랜드 화면보다 먼저 풀 수 있다 | 1·3 |
| 기본값 2 | 비밀번호 정하며 수락의 공개 서버 함수는 **새 함수 `brand-link-request-accept`**(사양서 4-5 가 개발에 맡긴 선택) | `brand-invite-accept` 에는 계정 지우기 경로가 있다 — 원래 있던 계정을 다루는 갈래를 같은 파일에 두면 실수 한 줄로 기존 계정이 지워진다. 새 함수에는 지우기 경로 자체가 없다 | 7 |
| 기본값 3 | 마무리 함수 `service_brand_link_request_finalize` 는 ①인증 계정 비밀번호가 실제로 있는지(`auth.users.encrypted_password` 비어 있지 않음 — 532 마무리와 같은 확인, 없으면 `password_not_set`) ②`password_set_at`·`password_changed_at` 기록 ③**`setup_link_id = NULL`** 까지 한다 | 의심 7 · 532 설정 완료와 같은 정리 | 4 |
| 기본값 4 | `respond_brand_invite` 의 `terms_version_required` 는 **결과 값**(예외 아님 — 사양서 그대로). 532 설정 완료(예외)와 다르다는 것을 파일 머리말에 적는다 | 화면 갈래가 결과 값 하나로 끝난다 | 3 |
| 기본값 5 | 대표 쪽 `resend_brand_invite`·`cancel_brand_invite`·`hide_brand_invite` 가 연결 요청 줄 번호를 받으면 **없는 줄과 같은 결과**(`not_found`/`not_owner`) | 531 머리말 [E] 「존재 비노출」 | 1 |
| 기본값 6 | 연결 6 이후 `notify-brand-account-setup` 에 `mail_kind:'link'` 가 오면 **400 `invalid_request`**(조용히 설정 메일로 새지 않게 — 그 함수의 지금 규칙) | 화면 호출 0건 확인 | 6 |
| 기본값 7 | 관리자 쪽 메일 storage 함수 이름 **`sendBrandOwnerLinkMail(requestId)`** → `{sent:true[, dev_mail]}` \| `{sent:false, reason[, error]}` — **관리자 작업표 조각 13 이 storage.js 에 만든다**(이 표는 storage.js 를 안 만진다) | 핫스팟을 한 세션에 · stale 7 | (13) |
| 기본값 8 | 공용 본체 서명 `_brand_accept_owner_link(p_invite_id uuid, p_auth_id uuid, p_terms_version text) RETURNS text`(`ok`·`invalid`·`owner_exists`·`already_member`·`setup_incomplete`) | 사양서 4-2 「(invite, auth_id, terms_version)」을 구체화 | 3 |
| 기본값 9 | 메일 제목·본문은 초안을 `reverb-ui-copy` 로 다듬고 피그마 bw01-98 과 글자 대조. 보낸 사람 「REVERB 운영팀」, 4줄 푸터는 인플루언서 메일 규칙이라 적용 대상 아님(브랜드 메일 양식 관례를 따른다) | 사양서 4-3 · L4 | 5 |

---

## 🚦 착수 전 선결 조건 (작업표보다 먼저)

| # | 선결 조건 | 근거 | 막는 조각 |
|---|---|---|---|
| **P1** | 🔴 **상대 개발자에게 알림** — 「530·531·532·534 함수와 573 `admin_upsert_brand_owner_account`·574 `_brand_contacts_locked`·533 `admin_get_brand_account_status` 를 다시 정의하고 533 `admin_link_brand_owner_account` 를 지운다. 같은 함수를 손대는 작업이 있나?」(사용자를 통해 전달 — Claude 는 상대에게 직접 못 보낸다) | `two-developers.md` 1조 · 의심 8 | 1·2·3·4 |
| **P2** | 착수 직전 `git pull origin dev` 뒤 위 함수들의 **마지막 `CREATE` 정의**를 다시 본다(특히 세션 A 가 조각 15 를 먼저 넣었으면 그 파일이 `brands` 에 무엇을 걸었는지) | `supabase.md` 「재정의 경고」 | 1~4 |
| **P3** | ✅ 결정됨(2026-10-21) — Q1=지금 칸에 덮어쓰기 · Q2=이메일 읽기 전용 표시 | 위 「사용자 결정」 표 | — |
| **P4** | 개발서버 시험 데이터 — ①대표 없는 활성 시험 브랜드 둘(요청·취소·만료용 / 거절용) ②비밀번호 정한 브랜드 계정(`zz-b2-second@example.com` 재사용 가능) ③비밀번호 안 정한 브랜드 계정 하나(다른 시험 브랜드에서 「계정 만들기」로 ⓒ 상태를 만든다) ④대표가 있는 브랜드(멤버 초대 회귀용 — 「가나다 시험」). 로그인이 필요한 확인은 **사용자에게 로그인을 부탁**(비밀번호 입력 금지) | 사양서 6절 | 1~9 |
| **P5** | 관리자 작업표 조각 14(세션 B)는 연결 요청을 **빼고** 먼저 돌린다(그 작업표 의존 순서 아래 주석) — 이 표의 서버 조각을 기다리지 않는다 | 관리자 작업표 「한눈에」 마지막 줄 | (14) |

---

## ⚠️ 사양서 stale 점검

1. **4-2 `respond_brand_invite` 「옛 2인자 판 DROP」·5절 9번 「옛 화면의 두 인자 호출」** — 지금 인자는 **셋**(`p_invite_id, p_link_id, p_action`)이다. 새 판은 넷째로 `p_terms_version text DEFAULT NULL` 을 더하고 **옛 3인자 판**을 지운다. 화면은 이름 붙인 인자로 부르므로 기본값 덕에 옛 화면 호출도 새 판을 찾는다(뜻은 사양서와 같다).
2. **4-2 표 「`_brand_acceptable_invites_for` … 셋 다 jsonb 반환이라 키 추가는 `CREATE OR REPLACE`」** — 이 함수는 `SETOF public.brand_invites` 다. 표에 칸을 더하면 결과에 저절로 실린다. 키를 직접 더할 것은 `get_my_brand_invites`·`get_brand_invite_link_state` 둘. 이 함수 자체는 연결 1(임시 막음)·연결 3(해제)에서만 다시 정의한다.
3. **4-2 `_brand_contacts_mark_primary`(본체 ⑤)** — 현재 원본은 **574**(옛 대표 칸 셋까지 맞춘다). 이름으로 부르므로 자동으로 574 판이 돈다. 「533 즉시 연결 999~1007 과 같은 처리」의 근거 줄 갱신은 그대로 옮긴다.
4. **4-2 `_brand_invite_acceptable`·L8 「개발이 착수 전 코드로 확인」** — 확인 완료: 비밀번호를 안 보고, `_brand_email_owner` 도 비밀번호와 무관하게 `brand` 를 준다. 사양서 설계 그대로 성립.
5. **4-3 「`scripts/sync-email-templates.sh` 실행」** — 실행 전에 **대응표 두 줄**을 고쳐야 한다: 47줄 `notify-brand-invite` 에 `brand-link-request.html` 추가, 46줄 `notify-brand-account-setup` 에서 `brand-link-notice.html` 제거. 안 고치면 새 양식이 미러·`templates.ts` 에 안 들어가 함수가 `TEMPLATES['brand-link-request']` 를 못 찾는다(발송 때 예외).
6. **6절 ④ 「그 계정의 다른 브랜드 설정 링크가 「이미 설정됨」으로」** — 그런 화면은 없다. 비밀번호를 정한 계정의 설정 링크는 「쓸 수 없는 링크」 화면(`showBrandLinkInvalid`)이다. 완료 정의를 그것으로 바꿔 적었다(연결 9).
7. **4-6 「메일은 멤버 초대 메일 함수를 부르는 storage 함수(있으면 재사용)」** — 없다. 관리자 조각 13 이 새로 만든다(기본값 7). 개발서버 응답은 `dev_mail{subject, text}`(의심 10).
8. **4-3 「걷는 것: … 533:930 주석」** — 마이그레이션 파일은 고치지 않는다(병합 요청 검사 ④ 경고 대상). 함수를 지우는 것(연결 2)으로 갈음하고 `CLAUDE.md`·`brand-account.md` 에서 서술을 걷는다(연결 10).
9. **4-5 공개 함수 결과** — 성공 응답 모양이 없다. 화면이 새 비밀번호로 로그인하려면 **이메일**이 필요하다(`brand-invite-accept` 도 `email` 을 돌려준다). 또 인증 서비스가 약한 비밀번호를 거부하는 결과(`password_rejected`)가 빠졌다 → 연결 7 계약에 둘 다 넣었다. 링크 판정의 이메일은 Q2.
10. **4-2 마무리 함수** — `setup_link_id` 비우기·`password_changed_at`·비밀번호 실재 확인이 없다(의심 7 · 기본값 3).
11. **5절 9번 「서버를 먼저 내면 옛 화면이 막힌다」** — 막히는 것이 하나 더 있다: `existing_setpw` 를 모르는 옛 화면은 비밀번호 없는 계정을 로그인 화면에 가둔다(의심 3). 같은 날 짝을 둘로 적었다.
12. **7절 「데이터베이스(4-1·4-2) → 메일 → 공개 함수 → 브랜드 화면 → 관리자 화면」** — 데이터베이스를 한 번에 내면 중간에 「관리자 요청은 되는데 옛 수락이 멤버로 받는」 상태가 생긴다(의심 1). 연결 1 의 임시 막음 + 네 조각 분할로 바꿨다.

---

## 한눈에 보는 의존 순서

```
[데이터베이스 흐름 — 세션 A · 순서대로]          [메일·공개 함수·브랜드 화면 — 세션 C · 작성은 지금부터]
연결 1 표 확장 + 멤버 초대 한정 + 받는 쪽 임시 막음
 │                                                연결 5 연결 요청 메일 갈래 + 양식 ──(배포는 연결 1 뒤)
 └→ 연결 2 관리자 쪽(요청·취소·상태·계정 만들기·잠김·즉시 연결 삭제)
     │        └──────────→ [관리자 작업표 조각 13 착수 가능 — 연결 2 적용 + 연결 5 배포 뒤]
     └→ 연결 3 받는 쪽 수락(공용 본체·수락 4인자·약관 기록·목록·링크 종류) ══ 같은 날 ══ 연결 8 브랜드 화면 ①
         └→ 연결 4 비밀번호 정하며 수락 서버 함수 둘 + 링크 판정 existing_setpw
                     ══ 같은 날 ══ 연결 7 공개 함수 brand-link-request-accept → 연결 9 브랜드 화면 ②
                                                  연결 6 설정 메일 「연결 안내」 걷기(언제든 — 연결 5 뒤 같은 세션)
[관리자 작업표] 조각 13 → 조각 14 2차(연결 요청 부분만 다시) — 연결 9 뒤
연결 10 문서 — 연결 1~9 + 조각 13 뒤
```
- 병렬: 세션 A(연결 1→4)와 세션 C(연결 5·6·7·8·9 작성)는 파일이 안 겹친다. 세션 B 는 조각 14 → 13.
- 같은 날 짝: **연결 3 개발 데이터베이스 적용 → 바로 연결 8 병합** · **연결 4 적용 → 연결 7 배포 → 연결 9 병합**. 세션 A 는 마이그레이션 파일을 미리 써 두되 **적용은 짝 화면 병합 요청이 리뷰 통과한 날** 한다.

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약(요지) | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| 연결 1 | 표 확장 + 멤버 초대 한정 + 받는 쪽 임시 막음(4-1) | 새 마이그레이션 | 칸 `invite_kind`(`member`\|`owner_link`, 기본 `member`) · 검사 제약 둘 · 대기 하나 색인 둘 · 530 `_brand_seat_usage` · 531 여섯 · 532 `service_brand_invite_finalize`·`respond_brand_invite`(3인자, 임시 막음)·`_brand_acceptable_invites_for`(임시 막음) · 534 `get_brand_invite_link_state`(임시 막음) | P1·P2 | ✗ | 세션 A |
| 연결 2 | 관리자 쪽 서버 함수(4-2 관리자) | 새 마이그레이션 | `admin_request_brand_owner_link(uuid,text)` · `admin_cancel_brand_owner_link(uuid,uuid)` · `admin_get_brand_account_status` 칸 `owner_link_request` · `admin_upsert_brand_owner_account` `request_exists` · `_brand_contacts_locked` OR · `DROP admin_link_brand_owner_account(uuid,text)` | 1 | ✗ | 세션 A |
| 연결 3 | 받는 쪽 수락 + 약관 기록(4-2 받는 쪽 · L3) | 새 마이그레이션 | `_brand_accept_owner_link(uuid,uuid,text)` · `respond_brand_invite(uuid,uuid,text,text DEFAULT NULL)`(옛 3인자 삭제) · 임시 막음 해제 · `get_my_brand_invites`·`get_brand_invite_link_state` 에 `invite_kind` | 2 · Q1 · **연결 8 과 같은 날** | ✗ | 세션 A |
| 연결 4 | 비밀번호 정하며 수락 서버 함수(L8) | 새 마이그레이션 | `service_brand_link_request_setpw(uuid,text)` · `service_brand_link_request_finalize(uuid,text)` · 링크 판정 `recipient:'existing_setpw'`(+Q2 `email`) | 3 · Q2 · **연결 7·9 와 같은 날** | ✗ | 세션 A |
| 연결 5 | 연결 요청 메일 갈래 + 양식(4-3) | `supabase/functions/notify-brand-invite/index.ts` · `docs/email-templates/brand-link-request.html`·`.preview.html`·`index.html` · `scripts/sync-email-templates.sh` · 생성 미러 | 종류로 먼저 가르고 연결 요청 줄은 호출자 `has_permission('brand.account_manage','write')` 두 번 · 양식 `brand-link-request` · 응답 모양 그대로 | (작성) 없음 · (배포) 1 | ○ | 세션 C |
| 연결 6 | 설정 메일 「연결 안내」 갈래·양식 걷기(4-3 걷기) | `supabase/functions/notify-brand-account-setup/index.ts` · `docs/email-templates/brand-link-notice*.html`(삭제) · `index.html` · `brand-account-setup.html`(주석) · `scripts/sync-email-templates.sh` · 미러 | `mail_kind:'link'` → 400 `invalid_request` · 양식·미러·카탈로그 줄 삭제 | 5(같은 세션·같은 스크립트) | ○ | 세션 C |
| 연결 7 | 공개 함수 `brand-link-request-accept`(4-5) | 새 `supabase/functions/brand-link-request-accept/index.ts` | `{link_id, password, terms_version}` → `{ok:true, email, brand_id}` \| `{ok:false, reason}` · 지우기 경로 없음 | (작성) 없음 · (배포) 4 | ○ | 세션 C |
| 연결 8 | 브랜드 화면 ① 수락 문구·약관 동의(4-4) | `dev/js/brand-invite.js` · `dev/js/brand-mypage.js` · `dev/brand/index.html` · 브랜드 화면 스타일 파일 | `respondBrandInvite({…, termsVersion})` · 연결 요청 갈래 문구 · 동의 칸 `#inviteAgree`·`#inviteAgreeError` · 결과 `owner_exists` 안내 | (작성) 없음 · (병합) **3 적용 직후** | ○ | 세션 C |
| 연결 9 | 브랜드 화면 ② 비밀번호 정하며 수락(L8 · B7) | `dev/js/brand-invite.js` · `dev/js/brand-login.js` · `dev/js/brand-app.js` | `showOwnerLinkSetpw(linkId, st)` · `submitOwnerLinkSetpw(pw)` · `_brandOwnerLinkSetpwCtx` · 폼 셋째 갈래 | 8 · (병합) **4 적용 + 7 배포 뒤** | ○ | 세션 C |
| 연결 10 | 문서 | 사양서 「구현 결과」 · `docs/FEATURE_SPEC.md` · `CLAUDE.md` · `.claude/rules/brand-account.md` | 현재 원본 번호 · 메일 함수 서술 · 즉시 연결 삭제 | 1~9 · 관리자 13 | ✗ | 개발(세션 C 또는 A) |

**다른 작업표와의 연결:** 관리자 작업표 **조각 13**(연결 요청 화면 a03-01c·04·04a·91a + storage `requestBrandOwnerLink`·`cancelBrandOwnerLink`·`sendBrandOwnerLinkMail`)은 **연결 2 개발서버 적용 + 연결 5 개발서버 배포** 뒤 착수. 관리자 작업표 **조각 14 2차**(연결 요청 부분 다시 보기)는 조각 13 + **연결 9** 뒤.

---

## 조각별 상세

### 연결 1 — 표 확장 + 멤버 초대 한정 + 받는 쪽 임시 막음 (사양서 4-1 · 기본값 1·5)
- **하는 일:** 표 `brand_invites` 에 종류 칸을 더하고, 지금 함수들이 연결 요청 줄을 집거나 세지 않게 한다. 받는 쪽 셋은 연결 3 전까지 연결 요청 줄을 「무효」로 본다. **지금 있는 줄·동작은 하나도 안 바뀐다**(모두 `member`).
- **담당 파일:** 새 마이그레이션 1개(572 이후 양식).
- **산출 계약:**
  - `ALTER TABLE public.brand_invites ADD COLUMN invite_kind text NOT NULL DEFAULT 'member'` + 제약 `brand_invites_invite_kind_check CHECK (invite_kind IN ('member','owner_link'))` + `brand_invites_owner_link_recipient_check CHECK (invite_kind <> 'owner_link' OR (recipient_kind = 'brand' AND sent_owner_auth_id IS NOT NULL))`.
  - 색인: 옛 `brand_invites_one_pending_per_email` 을 지우고 같은 이름으로 `(brand_id, email) WHERE status='pending' AND invite_kind='member'` · 새 `brand_invites_one_pending_owner_link` `(brand_id) WHERE status='pending' AND invite_kind='owner_link'`.
  - `CREATE OR REPLACE`(이름·인자·반환형·권한 그대로, 베이스는 괄호): `_brand_seat_usage`(530 — 대기 줄 셈에 `invite_kind='member'`) · `_brand_invite_reissue`(531 — 연결 요청 줄이면 `inviter_name` 을 다시 읽지 않고 그대로) · `create_brand_invite`(531 — 543~546 대기 줄 조회에 `invite_kind='member'`) · `resend_brand_invite`·`cancel_brand_invite`·`hide_brand_invite`(531 — 연결 요청 줄이면 없는 줄과 같은 결과, 기본값 5) · `get_brand_members`(531 — 초대 행에 `invite_kind='member'`) · `service_brand_invite_finalize`(532 — 연결 요청 줄이면 `invalid_link`) · **임시 막음 셋**: `respond_brand_invite`(532, 3인자 그대로 — 잠금 안 재독 뒤 연결 요청 줄이면 `invalid`) · `_brand_acceptable_invites_for`(532 — `AND i.invite_kind = 'member'`) · `get_brand_invite_link_state`(534 — 연결 요청 줄이면 `{state:'invalid'}`).
  - 머리말: 「임시 막음 셋은 연결 3 이 푼다 — 다음 재정의 베이스는 이 파일」 · 롤백 절차.
- **선행 의존:** P1·P2.
- **완료 정의:** 개발서버 적용 + 기록 표 방금 시각 줄 · `SELECT invite_kind, count(*) FROM public.brand_invites GROUP BY 1;` → `member` 만 · `SELECT indexname, indexdef FROM pg_indexes WHERE tablename='brand_invites';` 에 부분 색인 둘 · `BEGIN; INSERT … invite_kind='owner_link', recipient_kind='new' …; ROLLBACK;` → 23514 · 같은 거래 안에서 올바른 연결 요청 줄을 넣고 `get_brand_invite_link_state(그 link_id)` → `{"state":"invalid"}` 뒤 `ROLLBACK` · 회귀(사용자가 대표 계정 `zz-b2-owner` 로 로그인한 브라우저 콘솔): 멤버 초대 만들기·다시 보내기·취소·목록이 지금과 같다 · 바꾼 함수마다 1회 실제 호출(`supabase.md` 「신규 함수는 적용 성공이 동작 확인이 아니다」).
- **필요 검문소:** `reverb-supabase-expert`(쓰기 전 — 530·531·532·534 줄 단위 대조) · `reverb-reviewer`.
- **주의·롤백:** 롤백 = 바꾼 함수를 베이스 블록으로 재실행 → 새 색인 삭제·옛 색인 원래 정의로 → 제약 둘·칸 삭제(연결 요청 줄이 0건일 때만). 색인을 지웠다 만드는 동안 표가 잠깐 잠긴다(개발서버 줄 수 적음 — 운영은 브랜드 묶음 첫 적용이라 무관).

### 연결 2 — 관리자 쪽 서버 함수 (사양서 4-2 「새 함수(관리자)」·「고치는 함수」 관리자 줄 · B1·B3·L2·L7)
- **하는 일:** 요청 만들기·취소, 계정 상태에 요청 상태, 「계정 만들기」의 요청 중 거부, 담당자 잠김 판정 확장, 즉시 연결 함수 삭제.
- **담당 파일:** 새 마이그레이션 1개.
- **산출 계약:**
  - **`admin_request_brand_owner_link(p_brand_id uuid, p_email text) RETURNS jsonb`** → `{result, request_id, email_kind, expires_at}`. `result` = `ok`·`forbidden`·`owner_exists`·`request_exists`·`already_linked`·`not_brand_account`(+`email_kind` none\|influencer\|admin)·`brand_archived`·`brand_not_found`·`invalid_email`. 가드 `has_permission('brand.account_manage','write')` → 잠금 `brand_account_upsert:` → `brand_account_email:` → 사양서 4-2 검사 순서 그대로 → B1(같은 이메일 = `_brand_invite_reissue` 로 다시 발급 / 다른 이메일 = 만료 전 `request_exists`, 만료 뒤 옛 줄 `cancelled` + 새 줄). 새 줄 `invite_kind='owner_link'`·`recipient_kind='brand'`·`sent_owner_auth_id`=그 계정·`invited_by`=호출 관리자·`inviter_name='REVERB 운영팀'`·`expires_at=_brand_invite_expires_at(now())`. 🔴 B1 다시 발급 전에 그 이메일이 여전히 브랜드 계정인지 이미 확인됐다(검사 순서상 `not_brand_account` 가 앞) — 다시 발급이 갈래를 다시 판정해도 제약에 안 걸린다.
  - **`admin_cancel_brand_owner_link(p_brand_id uuid, p_request_id uuid) RETURNS jsonb`** → `{result: ok|forbidden|not_pending}` — 이 브랜드의 연결 요청 줄이고 대기(만료 포함)일 때만 `cancelled`.
  - **`admin_get_brand_account_status`**(베이스 533, `CREATE OR REPLACE`) — 기존 칸 전부 + `owner_link_request` `{request_id, status: pending|expired|declined|cancelled, email, sent_at(=issued_at), expires_at}` 또는 `null`(활성 대표가 있거나, 그 요청 `issued_at` 뒤에 생긴 대표 연결이 있으면 `null` — `brand_account_links.created_at` 비교). 대기 숫자 둘은 `invite_kind='member'` 만.
  - **`admin_upsert_brand_owner_account`**(베이스 **573**) — 활성 대표 없는 갈래 (1)에서 만료 전 대기 연결 요청이 있으면 `request_exists`(계정·연결 안 만듦), 만료된 대기 줄만 있으면 계정을 만드는 같은 거래에서 `cancelled`. 나머지 본문 573 글자 그대로.
  - **`_brand_contacts_locked`**(베이스 **574**) — 「활성 대표 **또는** 만료 전 대기 연결 요청」.
  - `DROP FUNCTION public.admin_link_brand_owner_account(uuid, text);`
  - 새 함수 둘 실행 권한: `postgres`·`authenticated`·`service_role` 부여 → `PUBLIC` 회수 → `anon` 회수.
- **선행 의존:** 1.
- **완료 정의:** 🔴 SQL 편집기로는 재현 안 됨(권한 판정이 로그인 사용자 기준) — 사용자가 로그인한 개발서버 관리자 콘솔에서: ①대표 없는 시험 브랜드 + 비밀번호 정한 브랜드 계정 이메일 → `ok`, 표에 `owner_link`·`REVERB 운영팀` 줄 ②같은 브랜드에 다른 브랜드 계정 이메일 → `request_exists` ③같은 이메일 다시 → `ok`, 같은 `request_id`, `link_id` 바뀜 ④상태 조회 `owner_link_request.status = 'pending'` ⑤`admin_save_brand_contact` 로 대표 줄 이메일 변경 → `primary_locked` ⑥`admin_upsert_brand_owner_account` → `request_exists` ⑦취소 → `ok`, 다시 취소 → `not_pending`, 상태 `cancelled` ⑧(새 요청 뒤) SQL 로 `issued_at`·`expires_at` 을 하루 전으로 → 상태 `expired`, 그 뒤 새 이메일 대표 줄로 「계정 만들기」 → `created` + 요청 줄 `cancelled` + 상태 조회 `owner_link_request: null` ⑨대표 있는 브랜드 → `owner_exists` · 인플루언서 이메일 → `not_brand_account`, `email_kind:'influencer'` ⑩`SELECT to_regprocedure('public.admin_link_brand_owner_account(uuid,text)');` → NULL ⑪새 함수 둘 `proacl` 맨 앞 `=X/` 없음·`anon` 없음. `already_linked` 는 정상 경로로 안 생겨(사양서 L2) 코드 대조로 갈음.
- **필요 검문소:** `reverb-supabase-expert`(573·574·533 줄 단위 대조) · `reverb-reviewer`.
- **주의·롤백:** 롤백 = 새 함수 둘 `DROP` → 533·573·574 블록 재실행(즉시 연결 함수도 533 블록으로 되살아난다). 🔴 이 조각이 들어간 뒤 받는 사람 링크는 연결 3 전까지 「쓸 수 없는 링크」(기본값 1 — 개발서버만).

### 연결 3 — 받는 쪽 수락 + 약관 기록 (사양서 4-2 받는 쪽 · L3·B4·B5·B6)
- **하는 일:** 연결 요청 수락의 공용 본체, 수락 함수에 약관 버전, 멤버 초대 수락에도 약관 기록, 임시 막음 해제, 목록·링크 판정에 종류.
- **담당 파일:** 새 마이그레이션 1개.
- **산출 계약:**
  - **`_brand_accept_owner_link(p_invite_id uuid, p_auth_id uuid, p_terms_version text) RETURNS text`**(기본값 8) — 사양서 4-2 본체 ①~⑤ 순서 그대로(①줄 재독·`pending`·`owner_link`·`sent_owner_auth_id = p_auth_id` 아니면 `invalid` ②`_brand_invite_acceptable(p_invite_id, p_auth_id, false)` ③활성 대표 → `owner_exists` · 이미 활성 연결 → `already_member` ④`password_set_at` 비었으면 `setup_incomplete` ⑤대표 연결 삽입 → `_brand_contacts_mark_primary` → 대표 줄 아이디를 `source_contact_id` 로 → 약관 셋 갱신 → 줄 `accepted`·`accepted_at`·`accepted_auth_id`). 잠금은 부르는 쪽이 이미 잡았어도 같은 열쇠로 다시 잡는다(재진입 안전). 🔴 실행 권한 `postgres`·`service_role` 만 — `PUBLIC`·`anon`·`authenticated` 모두 회수(호출자 검사 없는 함수 — `supabase.md` 「호출자 검사 없는 함수」).
  - **`respond_brand_invite(p_invite_id uuid, p_link_id uuid, p_action text, p_terms_version text DEFAULT NULL)`** — 옛 3인자 판 `DROP` 뒤 생성, 실행 권한 다시(`postgres`·`authenticated`·`service_role` 부여 → `PUBLIC` 회수 → `anon` 회수). 수락이고 약관 버전이 비면 맨 앞에서 `terms_version_required`(기본값 4). 줄 재독 직후 연결 요청 줄이면 곧바로 `_brand_accept_owner_link` 결과를 `{result, brand_id}` 로. 멤버 초대 수락은 지금 순서 그대로 + 성공 때 같은 거래에서 약관 셋 갱신. 거절은 종류 무관 지금처럼 상태만. 반환 결과에 `owner_exists`·`terms_version_required` 추가.
  - `_brand_acceptable_invites_for`(베이스 = 연결 1 판) — 종류 조건 삭제(532 본문으로 복귀).
  - `get_my_brand_invites`(베이스 532) — 줄마다 `invite_kind` 키.
  - `get_brand_invite_link_state`(베이스 = 연결 1 판, `CREATE OR REPLACE` 로만 — 비로그인 권한 유지) — 임시 막음 삭제 + `invite_kind` 키(두 갈래 모두). `existing_setpw` 는 연결 4.
  - Q1 = B 이면 약관 이력 표(이름은 작성 때)와 쓰기를 같은 파일에.
- **선행 의존:** 2 · Q1. 🔴 **개발서버 적용은 연결 8 병합 요청이 리뷰 통과한 날, 적용 직후 연결 8 병합.**
- **완료 정의:** 개발서버: ①연결 2 로 만든 요청을 받은 비밀번호 정한 계정(사용자 로그인)이 브랜드 화면 마이페이지에서 수락(연결 8 화면) → 그 브랜드 대표, 담당자 목록 대표 표시 이동(옛 대표 칸 셋도), `brand_accounts.terms_version` = 보낸 값·`terms_agreed_at` 방금 시각, 요청 줄 `accepted`, 관리자 상태 조회 `owner_link_request: null` ②같은 호출 다시 → `invalid` ③다른 시험 브랜드 요청을 거절 → `declined`, 관리자 상태 `declined` ④멤버 초대(「가나다 시험」) 수락에 약관 없이 콘솔 호출 → `terms_version_required`, 화면 수락 → `ok` + 약관 셋 갱신 ⑤`SELECT oid::regprocedure FROM pg_proc WHERE proname='respond_brand_invite';` → 4인자 한 줄 ⑥`_brand_accept_owner_link` 의 `proacl` 에 `authenticated` 없음·맨 앞 `=X/` 없음 ⑦`get_my_brand_login_state` 의 `new_invite_dot` 이 연결 요청에도 켜진다.
- **필요 검문소:** `reverb-supabase-expert`(잠금 순서 — 요청·취소·수락·계정 만들기가 같은 열쇠 짝인지) · `reverb-reviewer`.
- **주의·롤백:** 롤백 = 연결 1 판 셋 재실행 + `respond_brand_invite` 4인자 `DROP` 후 연결 1 판 3인자 재생성(권한 다시) + 본체 `DROP`. 연결 8 을 먼저 되돌려야 화면이 없는 인자를 안 보낸다. 🔴 이 조각과 연결 4 사이에는 비밀번호 없는 계정이 링크에서 막힌다(의심 3) — 짧게.

### 연결 4 — 비밀번호 정하며 수락 서버 함수 (사양서 4-2 「새 함수(L8)」 · 기본값 3 · Q2)
- **하는 일:** 비밀번호 저장 전 검사 함수, 저장 뒤 마무리 함수, 링크 판정에 새 갈래.
- **담당 파일:** 새 마이그레이션 1개.
- **산출 계약:**
  - **`service_brand_link_request_setpw(p_link_id uuid, p_terms_version text) RETURNS jsonb`** → `{result: ok|terms_version_required|invalid_link|owner_exists|already_member|password_already_set, auth_id}` — 쓰지 않는다. 약관 버전 → 본체 ①~③과 같은 판정 → ④반대 판정(비밀번호 정했으면 `password_already_set`).
  - **`service_brand_link_request_finalize(p_link_id uuid, p_terms_version text) RETURNS jsonb`** → `{result: ok|terms_version_required|invalid_link|owner_exists|already_member|password_already_set|password_not_set, brand_id, email}` — 잠금(브랜드 → 이메일) → 받는 계정 행 잠금 → `password_set_at` 이미 있으면 `password_already_set` → `auth.users.encrypted_password` 비면 `password_not_set` → `password_set_at = now()`·`password_changed_at = now()`·`setup_link_id = NULL` → `_brand_accept_owner_link`(본체 `invalid` 는 `invalid_link` 로 바꿔 돌려줌). 본체가 거부하면 비밀번호 기록은 **같은 거래라 함께 되돌아간다**(사양서 4-5 「비밀번호는 저장된 채 남을 수 있다」는 인증 서비스 쪽 비밀번호 이야기 — 그때 링크 판정은 `existing_setpw` 로 남아 처음부터 다시 된다).
  - 둘 다 실행 권한 `postgres`·`service_role` 만.
  - `get_brand_invite_link_state`(베이스 = 연결 3 판, `CREATE OR REPLACE` 로만) — 연결 요청 줄이고 받는 계정 `password_set_at` 이 비었으면 `recipient:'existing_setpw'` + (Q2=A) `email`.
- **선행 의존:** 3 · Q2. 🔴 **개발서버 적용 → 연결 7 배포 → 연결 9 병합을 같은 날.**
- **완료 정의:** 개발서버 SQL 편집기(서비스 함수라 재현된다)에서, 비밀번호 안 정한 시험 계정 앞 연결 요청 줄의 `link_id` 로: `setpw(link,'')` → `terms_version_required` · `setpw(link,'v')` → `ok` + `auth_id` · `get_brand_invite_link_state(link)` → `existing_setpw`(+`email`) · 비밀번호 정한 계정 줄이면 `setpw` → `password_already_set` · `finalize` 를 비밀번호 저장 없이 → `password_not_set`(아무것도 안 바뀜) · 실제 끝까지는 연결 9 완료 정의에서.
- **필요 검문소:** `reverb-supabase-expert` · `reverb-reviewer`.
- **주의·롤백:** 롤백 = 두 함수 `DROP` + 링크 판정 연결 3 판 재실행(연결 9·7 을 먼저 되돌린다). 사전 검사와 비밀번호 저장 사이 틈은 사양서 5-7 대로 감수.

### 연결 5 — 연결 요청 메일 갈래 + 양식 (사양서 4-3 · B8 · 기본값 9)
- **하는 일:** 멤버 초대 메일 함수에 연결 요청 갈래와 새 양식.
- **담당 파일:** `supabase/functions/notify-brand-invite/index.ts` · `docs/email-templates/brand-link-request.html`·`brand-link-request.preview.html`·`index.html`(카탈로그 줄) · `scripts/sync-email-templates.sh` 47줄 · 생성물 `_templates/brand-link-request.html`·`templates.ts`.
- **산출 계약:**
  - 조회 칸에 `invite_kind` 추가. **종류로 먼저 가른다**: `member` = 지금 대표 확인 그대로 / `owner_link` = 호출자 토큰으로 `rpc('has_permission', {p_feature:'brand.account_manage', p_min:'write'})` 가 참이 아니면 403 — 선점 전 한 번·선점 뒤 한 번(브랜드 활성 재확인과 함께). 갈래끼리 판정을 섞지 않는다.
  - 양식 키 `brand-link-request`, 자리 `{{brand_name}}`·`{{link}}` — 비밀번호 유무와 상관없이 같은 메일·같은 링크 `${PUBLIC_BRAND_URL}/brand/?link=<link_id>&kind=invite`. 제목·본문 보낸 사람 「REVERB 운영팀」, 기한 「24시간」(브랜드 메일 24시간 전제 — `CLAUDE.md`), 끝에 보낸 시각(`kstStamp`). 텍스트 판은 양식의 사본(함께 고칠 것 — 머리말).
  - 응답 모양 그대로(`sent:true` · 개발서버 `dev_mail{subject,text}` · `not_pending`·`already_sent`·`send_failed`·400·401·403·500). 갈래를 응답에 싣지 않는다. 두 겹 잠금·선점·기록 그대로.
- **선행 의존:** (작성) 없음 · 🔴 (배포) 연결 1 개발서버 적용 확인 뒤(의심 2).
- **완료 정의:** `bash scripts/sync-email-templates.sh` 뒤 미러에 새 양식 · 개발 프로젝트 배포 · 사전 요청(교차 출처 허용 헤더 — CORS) 200 · 관리자 콘솔에서 연결 2 요청 아이디로 호출 → `dev_mail` 제목에 「REVERB 운영팀」·본문에 `kind=invite` 링크 · 브랜드 대표 토큰으로 같은 아이디 → 403 · 관리자 토큰으로 멤버 초대 아이디 → 403 · 대표가 멤버 초대 메일 → 지금처럼 `dev_mail`(회귀) · 같은 링크 두 번째 → `already_sent`. 🔴 실제 발송 시험 없음(`supabase.md`).
- **필요 검문소:** `reverb-reviewer`(교차 출처 허용 헤더·두 겹 잠금·로그에 링크·본문 없음).
- **주의·롤백:** 롤백 = 이전 커밋 함수 재배포. 운영 배포 금지(브랜드 묶음과 함께).

### 연결 6 — 설정 메일 「연결 안내」 갈래·양식 걷기 (사양서 4-3 「걷는 것」 · 기본값 6)
- **하는 일:** 즉시 연결 뒤 쓰던 메일 갈래와 양식을 지운다.
- **담당 파일:** `supabase/functions/notify-brand-account-setup/index.ts`(17~27 머리말·156~168·230~269·316~329의 연결 갈래) · `docs/email-templates/brand-link-notice.html`·`.preview.html`(삭제) · `docs/email-templates/index.html`(642~643줄 묶음) · `docs/email-templates/brand-account-setup.html` 38줄 주석 · `scripts/sync-email-templates.sh` 46줄 · 미러 `_templates/brand-link-notice.html`(삭제)·`templates.ts`.
- **산출 계약:** `mail_kind` 는 없음/`'setup'` 만 받고 `'link'` 는 400 `invalid_request`. 응답 `template` 은 `'setup'` 하나.
- **선행 의존:** 연결 5(같은 세션 — 동기화 스크립트를 둘 다 만진다).
- **완료 정의:** `grep -rn "brand-link-notice\|mail_kind.*link\|link_notice" dev supabase docs/email-templates scripts` → 0건(사양서·마이그레이션 주석 제외) · 개발 배포 · `mail_kind:'link'` 호출 → 400 · 설정 메일 → 지금처럼 `dev_link`.
- **필요 검문소:** `reverb-reviewer`.
- **주의·롤백:** 롤백 = 커밋 되돌림 + 재배포. 관리자 화면 호출 0건(확인됨).

### 연결 7 — 공개 함수 `brand-link-request-accept` (사양서 4-5 · 기본값 2)
- **하는 일:** 로그인 없이 링크·비밀번호·약관 버전을 받아 비밀번호를 정하고 수락.
- **담당 파일:** 새 `supabase/functions/brand-link-request-accept/index.ts`(교차 출처 허용·요청 길이 검사·배포 명령은 `brand-invite-accept` 머리말을 본뜸 — `--use-api`).
- **산출 계약:** `POST {link_id, password, terms_version}` · 사전 요청 처리 · 공개 키 거부 없음 · 순서 `service_brand_link_request_setpw` → `auth.admin.updateUserById(auth_id, {password})` → `service_brand_link_request_finalize`. 응답 `200 {ok:true, email, brand_id}` \| `200 {ok:false, reason: invalid_link|owner_exists|already_member|password_already_set|terms_version_required|password_rejected|failed}` \| `400 {ok:false, reason:'invalid_request'}` \| `500 {ok:false, reason:'server_error'}`. 비밀번호 길이 검사는 `brand-invite-accept` 와 같은 값. 🔴 계정 지우기 호출 없음 · 응답·로그에 링크·본문·비밀번호·이메일 없음(결과 코드만).
- **선행 의존:** (작성) 없음 · (배포) 연결 4.
- **완료 정의:** 개발 배포 · 사전 요청 200 · 형식 틀린 링크 → 400 · 없는 링크 → `invalid_link` · 끝까지 경로는 연결 9.
- **필요 검문소:** `reverb-reviewer`(교차 출처 허용 · 로그 · 지우기 경로 없음) · `reverb-supabase-expert`(인증 서비스 비밀번호 저장 뒤 세션 동작).
- **주의·롤백:** 롤백 = 함수 삭제(대시보드) 또는 이전 판 재배포. 운영 배포 금지.

### 연결 8 — 브랜드 화면 ① 수락 문구·약관 동의 (사양서 4-4 · L3·B9)
- **하는 일:** 수락할 때 약관 동의 한 줄을 받고 버전을 보낸다(멤버 초대·연결 요청 둘 다). 연결 요청 줄이면 문구를 바꾼다.
- **담당 파일:** `dev/js/brand-invite.js` · `dev/js/brand-mypage.js` · `dev/brand/index.html`(`#invite` 화면) · 브랜드 화면 스타일 파일(동의 줄). 새 파일 없음 → `dev/build.sh` 변경 없음(빌드만).
- **산출 계약:**
  - `respondBrandInvite({inviteId, linkId, action, termsVersion})` — 수락이면 `p_terms_version: BRAND_TERMS_VERSION`.
  - `showInviteScreen(ctx, email)` — `ctx.invite.invite_kind === 'owner_link'` 면 제목(`#inviteTitle` 새 아이디) 「브랜드 연결 요청」, 설명 「REVERB 운영팀이 회원님을 「{브랜드}」의 대표 담당자로 연결하려 합니다」, 단추 「수락」 / 멤버 초대는 지금 문구. 동의 줄 `#inviteAgree`(체크) + 「보기」 둘 + 오류 `#inviteAgreeError` — 체크 없이 수락하면 오류 문구, 서버 안 부름. 링크 착지 갈래도 `st.invite_kind` 를 넘긴다.
  - 마이페이지 줄 — 연결 요청 줄은 「보낸 곳 REVERB 운영팀 · 대표 담당자로 연결」, 수락 = 줄 안 동의 칸 + 「보기」는 `data-my-act` 갈래에서 `openLegalModal('terms'|'privacy')` 직접 호출(의심 5), 거절 확인 「다시 연결하려면 운영팀에 문의해 주십시오」.
  - 결과 → 화면: `owner_exists` → 「이미 다른 대표 담당자가 정해졌습니다. 운영팀에 문의해 주십시오」 · `terms_version_required` → 지금 실패 문구 · 그 밖은 지금 갈래 그대로. 버튼·입력 높이 44px 이상. 문구는 `reverb-ui-copy`.
- **선행 의존:** (작성) 없음 · 🔴 (병합) 연결 3 개발서버 적용 직후, 같은 날.
- **완료 정의:** 개발서버: 마이페이지에서 동의 없이 수락 → 오류 문구·호출 없음 / 동의 후 수락 → 성공 토스트 + `brand_accounts.terms_version` 갱신(멤버 초대) · 연결 요청 메일 링크(로그인 상태) → 「브랜드 연결 요청」 화면 → 수락 → 그 브랜드가 대표로 열림 · 마이페이지 줄·거절 확인 문구가 위 계약대로 · 「보기」가 약관 창을 연다(마이페이지·초대 화면 둘 다) · 크롬 확인은 마우스로(`browser-qa.md`).
- **필요 검문소:** `reverb-reviewer` · `reverb-qa-tester` 권장(다른 세션이 크롬을 안 쓸 때 단일 세션).
- **주의·롤백:** 롤백 = 커밋 되돌림(연결 3 을 함께 되돌리면 순서는 화면 먼저). 브랜드 빌드 산출물 `brand/index.html` 은 빌드로만.

### 연결 9 — 브랜드 화면 ② 비밀번호 정하며 수락 (사양서 L8 · B7 · 4-4 첫 줄)
- **하는 일:** 비밀번호 안 정한 계정이 메일 링크에서 비밀번호를 정하며 바로 수락하고 로그인된 채 그 브랜드로.
- **담당 파일:** `dev/js/brand-invite.js` · `dev/js/brand-login.js`(`#setpwForm` 제출 셋째 갈래) · `dev/js/brand-app.js`(59·261줄의 링크 흐름 정리 조건에 새 맥락).
- **산출 계약:**
  - 착지: `handleBrandInviteLanding` 은 `existing_setpw` 면 「비밀번호를 설정하시겠습니까?」 · `continueBrandInviteLanding` 은 `existing_setpw` → `showOwnerLinkSetpw(linkId, st)`.
  - `showOwnerLinkSetpw` — `_brandOwnerLinkSetpwCtx = {linkId, email}`, `[data-member-only]` 숨김(이름·연락처 없음 — B7), 이메일 칸은 Q2=A 면 읽기 전용 표시·아니면 숨김, 설명 「REVERB 운영팀이 「{브랜드}」의 대표 담당자로 연결하려 합니다. 비밀번호를 정하면 바로 시작할 수 있습니다」.
  - `submitOwnerLinkSetpw(pw)` — `brandCallFunction('brand-link-request-accept', {link_id, password, terms_version: BRAND_TERMS_VERSION})` → 성공이면 `brandSignOutLocal()` → `signInWithPassword({email: body.email, password})` → `set_my_brand_last_viewed(brand_id)` → `fetchBrandLoginState` → `enterBrandApp`. 실패 → `invalid_link` = 쓸 수 없는 링크 화면 · `password_rejected` = 비밀번호 칸 오류 · `password_already_set` = 「이미 비밀번호가 정해진 계정입니다 — 로그인해 주십시오」 · `owner_exists`·`already_member` = 연결 8 과 같은 문구 · 그 밖 = 「처리하지 못했습니다. 메일의 링크를 다시 열어 주십시오」. 비밀번호 원문은 성공·실패 뒤 칸에서 지운다.
  - 폼 제출(`brand-login.js`): 갈래 판정에 `_brandOwnerLinkSetpwCtx` 추가(멤버 이름 검사 안 함).
- **선행 의존:** 8 · 🔴 (병합) 연결 4 적용 + 연결 7 배포 뒤 같은 날.
- **완료 정의:** 개발서버 처음부터 끝까지: 시험 브랜드 가에서 「계정 만들기」로 만든 비밀번호 없는 계정 → 관리자가 시험 브랜드 나에 연결 요청 → `dev_mail` 링크를 연다 → 「계속하기」 → 이름·연락처 없는 비밀번호 화면 → 정한다 → **로그인된 채 브랜드 나 대표** · 브랜드 가의 옛 설정 링크 → 쓸 수 없는 링크 화면(stale 6) · `brand_accounts.password_set_at`·약관 셋 기록, `setup_link_id` 빔 · 관리자 상태 조회 브랜드 가 = `active`(설정 완료) · 같은 링크 다시 → 쓸 수 없는 링크.
- **필요 검문소:** `reverb-reviewer` · `reverb-qa-tester` 권장(단일 세션).
- **주의·롤백:** 롤백 = 커밋 되돌림(연결 4 를 되돌리기 전에).

### 연결 10 — 문서
- **하는 일:** 사양서 「구현 결과」(실제 마이그레이션 번호·함수 이름·이 표 stale 1~12 처리·연결 9 확인 기록·후속: 다른 계정 로그인 때 문구) · `docs/FEATURE_SPEC.md` · `CLAUDE.md` 「브랜드 계정·로그인·멤버 관리」 현재 원본 번호(530·531·532·534 바뀐 함수 · `admin_upsert_brand_owner_account` · `_brand_contacts_locked` · `admin_get_brand_account_status` · 새 함수 다섯 · `respond_brand_invite` 4인자) + 「연결 해제는 함수만 있다」 옆 즉시 연결 삭제 + 메일 파이프라인 「브랜드 메일 함수 넷」에 연결 요청 갈래·`brand-link-request-accept` · `.claude/rules/brand-account.md`(`mail_kind:'link'`·`brand-link-notice` 서술 걷기, 연결 요청 절).
- **담당 파일:** 위 넷(+사양서).
- **산출 계약:** —
- **선행 의존:** 1~9 · 관리자 조각 13.
- **완료 정의:** `grep -rn "admin_link_brand_owner_account\|brand-link-notice\|mail_kind:'link'" CLAUDE.md .claude/rules/ docs/FEATURE_SPEC.md` → 「삭제됨」 서술만 · 「구현 결과」에 stale 처리.
- **필요 검문소:** `reverb-reviewer`.
- **주의·롤백:** 규칙 파일은 거버넌스 문서 — 개발 세션 커밋이 막히면 고문에게 넘긴다. 사양서 8절의 기획 몫 둘(관리자 작업표 「작업 4」 대체 한 줄 · 포털 사양 §16-8 1번 경로)은 기획이 한다.

---

## ⚠️ 공유 지점 경고 (충돌 주의)

| 파일·대상 | 만지는 조각 | 주의 |
|---|---|---|
| 표 `brand_invites` | 1 (칸·제약·색인) · 2·3·4 (쓰기) | 데이터베이스 흐름 한 세션·순서대로 |
| `get_brand_invite_link_state` | 1 → 3 → 4 | 🔴 세 번 다시 정의 — 베이스는 늘 **바로 앞 조각 파일**. `CREATE OR REPLACE` 로만(비로그인 권한) |
| `respond_brand_invite` | 1(3인자 임시 막음) → 3(4인자, 옛 판 삭제) | 연결 3 이 실행 권한을 다시 건다 |
| `_brand_acceptable_invites_for` | 1(막음) → 3(해제) | 로그인 판정·받은 초대·비밀번호 찾기 열림 넷이 쓴다 — 해제를 빠뜨리면 연결 요청이 영영 안 보인다 |
| 573 `admin_upsert_brand_owner_account` · 574 `_brand_contacts_locked` · 533 `admin_get_brand_account_status` | 2 | 세션 A 가 만든 함수 — 세션 A 에서 이어 쓴다. 다른 세션이 손대면 병합 요청 검사 ②가 경고 |
| 관리자 작업표 조각 15(`brands` 담당자 칸 직접 고치기 막는 트리거) | (세션 A) | 함수가 아니라 트리거라 겹치지 않는다. 수락 본체는 정의자 권한 경로라 통과해야 한다 — 15 적용 뒤 수락 1회 재확인(의심 9) |
| `scripts/sync-email-templates.sh` | 5 · 6 | 같은 세션 순서대로 |
| `notify-brand-invite` | 5 | 브랜드 대표 화면(`brand-members.js`)도 같은 함수를 부른다 — 멤버 초대 회귀 확인 필수 |
| `dev/js/brand-invite.js` | 8 · 9 | 같은 세션 순서대로 |
| `dev/js/brand-login.js` | 9 | 설정 메일 화면과 같은 폼 — 설정 메일 회귀(`fillSetpwReal`) 확인 |
| `dev/lib/storage.js`(핫스팟) | **이 표에서 안 만짐** | 관리자 조각 13(세션 B)만 — 기본값 7 |
| `CLAUDE.md`(핫스팟) | 10 | 관리자 작업표 조각 16 과 같은 절 — 나중에 들어가는 쪽이 `origin/dev` 를 받아 합친다 |
| 마이그레이션 번호 | 1~4 (+ 세션 A 의 조각 15) | 한 세션이 번호를 정한다. push 직전 `origin/dev`·열린 병합 요청까지 보고 확정 |

---

## 🧭 배분 제안

- **세션 A — 데이터베이스(작업 폴더 `feature/브랜드상세-db`, 지금 조각 15 대기 중)**: 연결 1 → 2 → 3 → 4. 지금 조각 14(세션 B) 결과를 기다리는 빈 시간이고, 573·574 를 만든 세션이라 베이스를 가장 잘 안다. 조각 14 가 끝나면 **진행 중인 연결 조각을 마무리한 뒤** 조각 15 를 끼운다(15 는 이 표와 의존이 없다). 마이그레이션 번호를 한 세션이 정하므로 겹침이 없다. 연결 3·4 는 **파일만 먼저 쓰고, 개발서버 적용은 세션 C 의 짝 화면이 리뷰 통과한 날**.
- **세션 C — 새 세션(메일·공개 함수·브랜드 화면, 작업 폴더 예: `feature/연결요청-화면`)**: 연결 5 → 6 → 7 → 8 → 9 → 10. 관리자 핫스팟을 하나도 안 만지므로 세션 B 와 병렬로 안전하다. 연결 5 를 가장 먼저 — 관리자 조각 13 이 그 메일 함수를 기다린다.
- **세션 B — 관리자 화면(진행 중)**: 조각 14(연결 요청 빼고) → 조각 13(연결 2 적용 + 연결 5 배포 확인 뒤) → 조각 14 2차(연결 9 뒤, 연결 요청 부분 + 조각 15 적용 뒤 수락 재확인).
- **대안**: 세션 C 를 열지 않고 세션 B 가 조각 13 뒤 연결 5~9 를 이어 받는다 — 세션이 하나 줄지만 연결 5 가 늦어져 조각 13 이 메일 없이 시작하게 된다. 데이터베이스를 새 세션에 맡기는 것은 권하지 않는다(세션 A 의 조각 15 와 번호·같은 날 재정의 경고가 겹친다).
- 🔴 **화면 버튼과 서버 함수는 같은 배포에 묶이지 않는다** — 각 화면 조각은 짝 데이터베이스 조각의 개발서버 적용(기록 표 줄)을 확인한 뒤 `dev` 에 병합한다.
- 크롬 확인(연결 8·9·조각 14 2차)은 단일 자원 — 한 번에 한 세션.

---

## 사용자 확인 필요 (메인이 `AskUserQuestion` 으로 하나씩)

**Q1 (약관 기록)** — 질문: 브랜드 계정이 초대나 연결 요청을 수락할 때 약관 동의 시각·버전을 지금 칸에 덮어쓸까요? · 헤더: 약관 기록
- 「지금 칸에 덮어쓰기 (추천)」 — 사양서대로 계정의 약관 동의 시각·버전 칸을 수락한 순간 값으로 바꿉니다. 「지금 시행 중인 약관에 동의했다」는 증거는 남고, 처음 계정 설정 때의 동의 시각은 사라집니다.
- 「이력 표로 따로 남기기」 — 수락할 때마다 한 줄씩 쌓는 표를 새로 만듭니다. 동의 기록이 전부 남지만 데이터베이스 변경이 늘고, 출시 전 약관 확인 때 보관 기간도 정해야 합니다.

**Q2 (이메일 표시)** — 질문: 비밀번호를 아직 안 정한 계정이 연결 요청 링크를 열었을 때 비밀번호 설정 화면에 그 계정의 이메일을 보여 줄까요? · 헤더: 이메일 표시
- 「읽기 전용으로 보이기 (추천)」 — 피그마 비밀번호 설정 화면처럼 이메일 칸을 보입니다. 링크를 가진 사람(메일함 주인)에게만 보이고, 어느 계정에 비밀번호를 정하는지 본인이 확인할 수 있습니다.
- 「숨기기」 — 이메일 칸을 숨기고 로그인용 이메일은 처리 결과로만 받습니다. 메일이 전달됐을 때 이메일이 덜 드러나지만, 본인이 어느 계정인지 화면에서 확인할 수 없습니다.

**Q3 (배분)** — 질문: 연결 요청의 데이터베이스 조각 넷을 어느 세션이 맡을까요? · 헤더: 데이터베이스
- 「세션 A 가 지금 (추천)」 — 조각 15 를 기다리는 세션 A 가 바로 시작하고 조각 15 는 그 사이에 끼웁니다. 같은 함수를 만든 세션이라 베이스 착오가 적고 번호도 한 곳에서 정합니다.
- 「새 세션」 — 별도 세션을 엽니다. 세션 A 의 조각 15 와 번호가 겹치지 않게 서로 확인해야 하고, 같은 함수를 두 곳에서 다시 정의하는 경고가 날 수 있습니다.

**Q4 (배분)** — 질문: 메일·공개 서버 함수·브랜드 화면 조각(연결 5~9)은 어느 세션이 맡을까요? · 헤더: 메일·화면
- 「새 세션 C (추천)」 — 관리자 화면 파일을 안 만지므로 세션 B 와 동시에 갈 수 있고, 관리자 조각 13 이 기다리는 메일 함수를 가장 먼저 낼 수 있습니다.
- 「세션 B 가 조각 13 뒤에」 — 세션 수는 줄지만 메일 함수가 늦어져 조각 13 이 메일 없이 시작하거나 기다려야 합니다.

---

**참고 파일(절대경로)**
- 사양서: `/Users/choiwooyoung/kemo/docs/specs/2026-10-21-brand-link-request.md` · 인계 `/Users/choiwooyoung/kemo/docs/specs/2026-10-21-brand-link-request-handoff.md` · 짝 작업표 `/Users/choiwooyoung/kemo/docs/specs/2026-10-21-admin-brand-detail-tabs-breakdown.md`
- 확인한 마이그레이션: `/Users/choiwooyoung/kemo/supabase/migrations/527_brand_account_functions.sql`(275~313 `_brand_email_owner`) · `530_brand_member_base.sql`(167~209 · 342~449) · `531_brand_owner_functions.sql`(265~859) · `532_brand_recipient_self_functions.sql`(526~727 · 864~1084 · 1176~1350) · `533_brand_admin_member_functions.sql`(647~720 · 874~1018) · `534_brand_invite_link_state_email.sql` · `573_brand_owner_account_lock_and_check_name.sql`(36~230) · `574_brand_contact_row_functions.sql`(1~118)
- 확인한 서버 함수: `/Users/choiwooyoung/kemo/supabase/functions/notify-brand-invite/index.ts` · `/Users/choiwooyoung/kemo/supabase/functions/brand-invite-accept/index.ts` · `/Users/choiwooyoung/kemo/supabase/functions/notify-brand-account-setup/index.ts` · `/Users/choiwooyoung/kemo/scripts/sync-email-templates.sh`(46·47)
- 확인한 화면: `/Users/choiwooyoung/kemo/dev/js/brand-invite.js` · `/Users/choiwooyoung/kemo/dev/js/brand-mypage.js`(25 · 58~291) · `/Users/choiwooyoung/kemo/dev/js/brand-login.js`(30 · 255~442 · 566) · `/Users/choiwooyoung/kemo/dev/brand/index.html`(105~270) · `/Users/choiwooyoung/kemo/dev/js/admin-brand-detail.js`(598 · 987 · 1134 · 1151 · 1394~1406) · `/Users/choiwooyoung/kemo/dev/lib/storage.js`(3496~3602)
