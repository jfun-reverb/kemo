# 인계 — 브랜드 「연결 요청」 별도 사양서 착수용 (2026-10-21)

> **무엇:** 관리자가 기존 브랜드 계정을 브랜드에 잇는 길(a03-04 「브랜드 연결 추가」 · a03-01c 겹침 창 「연결」)을 **본인 24시간 안 수락**으로 바꾸는 기능(사양 `docs/specs/2026-07-15-brand-portal.md` §16-8 1번). 🔴 **서버·메일 양식(bw01-98)·브랜드 쪽 수락 화면(bw07-00c) 모두 없다** — 지금 533 `admin_link_brand_owner_account` 는 수락 없이 즉시 연결한다.
> **결정(2026-10-21 사용자):** 관리자 브랜드 상세 작업표와 **따로** 사양서·작업표를 만든다(기획 세션). 관리자 쪽 연결 요청 화면은 관리자 작업표 조각 13 이 이 서버가 개발서버에 들어간 뒤 붙인다 — 그쪽이 기대하는 서버 계약 초안은 `docs/specs/2026-10-21-admin-brand-detail-tabs-breakdown.md` 「작업 4」.
> **출처:** 같은 날 오전 다른 세션의 작업표(브랜치 `feature/관리자-브랜드상세-작업표`, 커밋 28d2591a — 병합 안 됨)의 인계 절. 그 작업표는 오후 작업표와 합쳐졌고 정본은 오후 것이다.
> **출시:** 브랜드 페이지 1차·관리자 브랜드 상세와 같은 날. 약관 초안 제5조 5항(본인 수락)이 이 기능을 전제한다 — 없으면 출시 관문 1(`/약관확인`)을 못 넘는다.

## 오전 세션이 남긴 인계 (원문 그대로 옮김)

> ⚠️ 원문은 「이 작업표에 추가」 결정을 전제로 썼으나 **2026-10-21 오후 사용자가 「별도 사양서·작업표」로 최종 결정**했다 — 아래의 조각 번호(D1·D3·7·8·11)와 S0-12 는 **오전 작업표의 번호**다 — 오후(정본) 작업표에서는 관리자 연결 요청 화면 = 조각 13, 서버 계약 초안 = 작업 4, 개발자 두 명 알림 = M8. 아래는 이번 세션에서 코드로 확인한 사실과 잠정 권고다. 권고는 검증 전이다.

### 확인한 사실(코드 기준)
1. **지금 서버는 수락 없이 바로 잇는다** — `admin_link_brand_owner_account`(533, 933~1011행): 대표 없는 브랜드에 기존 브랜드 계정을 대표로 즉시 넣는다(이미 멤버면 `_brand_transfer_owner` 로 올림) + `_brand_contacts_mark_primary`. 결과값 `ok|forbidden|owner_exists|not_brand_account|brand_archived|brand_not_found|invalid_email`. 잠금 순서 브랜드(`brand_account_upsert:`) → 이메일(`brand_account_email:`). 메일은 화면이 `notify-brand-account-setup` 을 `mail_kind:'link'` 로 따로 부른다(비밀번호 정한 계정이면 `link_notice`, 아니면 설정 메일). 운영에는 없다(533 개발서버만).
2. **기존 초대 장치는 「멤버 초대」 전용이다** — 표 `brand_invites`(530, 167~209행): `status`(pending·accepted·declined·cancelled — 만료는 「대기 + `expires_at` 지남」) · `recipient_kind`(new·brand·blocked) · `sent_owner_auth_id` · `link_id` · `invited_by`·`inviter_name`(NOT NULL). 같은 브랜드·이메일 대기 초대는 하나(`brand_invites_one_pending_per_email`). 읽는 함수: 530 `_brand_seat_usage`·`_brand_invite_acceptable` / 531 `_brand_invite_reissue`·`create_brand_invite`·`resend_brand_invite`·`cancel_brand_invite`·`hide_brand_invite`·`get_brand_members`(826행) / 532 `_brand_acceptable_invites_for`·`get_brand_invite_link_state`·`respond_brand_invite`·`get_my_brand_invites`·`service_brand_invite_create_account`·`service_brand_invite_finalize` / 533 `admin_get_brand_account_status`(704·706행 대기 숫자)·`admin_release_brand_account`(909행) / 534 링크 판정 현재 원본. 🔴 수락 `respond_brand_invite`(532, 614~688행)는 연결을 `'member'` 로 넣는다(680행), 비밀번호 미설정은 `setup_incomplete` 거부. 메일 `notify-brand-invite`(new·existing·blocked)·`brand-invite-accept` 는 멤버 전제.
3. **사양서 16-8 1번 요구** — 관리자가 잇는 길 셋(「브랜드 연결 추가」 a03-04 · 겹침 창 「연결」 a03-01c · 대표 이메일을 다른 브랜드 계정 이메일로 바꿔 저장)이 모두 「연결 요청」. 메일 bw01-98 하나. 본인이 메일 링크나 마이페이지 「받은 초대」(bw07-00c)에서 수락·거절, 기한 24시간. 비밀번호 미설정 계정은 링크에서 비밀번호를 정하며 바로 수락(bw01-02b 모양). 대표 표시는 수락한 때 바뀐다(bw01-96c 대체, 16-5 18번 닫음). Figma 흐름도: 「연결 요청 보냄(a03-91a)」 · 「이미 대표가 있음 → 토스트」 · 「브랜드 계정이 아닌 이메일 → a03-04a」.

### 잠정 권고(검증 전)
- 저장은 새 표보다 **`brand_invites` 확장**(종류 칸: 멤버 초대 / 대표 연결 요청) — 로그인 판정·빨간 점·받은 초대·비밀번호 찾기 넓히기·링크 판정이 이 표 하나를 본다. 대신 위 함수를 **종류별로 하나씩 대조**: ①수락 때 `owner` 로·수락 순간 대표가 있으면 거부·담당자 대표 표시 이동 ②대표의 멤버 목록·관리자 「초대 대기 N」에서 뺄지 ③자리 계산 포함 여부 ④`invited_by`·`inviter_name` 에 관리자를 어떻게(「REVERB 운영팀」?) ⑤비밀번호 미설정 수락 경로 ⑥관리자 취소 함수 필요 여부(16-5 11번 「관리자는 초대를 대신 취소하지 않는다」 — 사용자 확인)
- 533 즉시 연결 함수는 운영에 없으니 지우거나 요청 생성 함수로 바꾼다 → 관리자 연결 요청 화면(오후 작업표 조각 13 — a03-01c 겹침 창 「연결」·a03-04 「브랜드 연결 추가」) 산출 계약도 바뀐다
- 메일은 `notify-brand-invite` 에 연결 요청 양식(bw01-98)을 더하는 쪽 먼저 검토(두 겹 잠금 공유). `notify-brand-account-setup` 의 `mail_kind:'link'` 갈래는 걷는 대상

### 아직 확인 못 한 것
- 사양서 16-8 1번 주변 전부 · 16-3 1번·5번·11번 · 약관 초안 `docs/specs/2026-10-19-brand-terms-draft.md` 제5조
- `supabase/functions/brand-invite-accept/index.ts`·`notify-brand-invite/index.ts` 본문
- 532 `service_brand_invite_create_account`·`service_brand_invite_finalize`·`get_my_brand_login_state` 대기 초대 판정 · 531 `get_brand_members`
- 브랜드 화면 초대 착지(`dev/js/brand-invite.js`·`brand-app.js`)
- 「대표 이메일을 바꿔 저장」 길과 D1(대표 줄 잠금)의 맞물림 — 계정이 없는 동안에만 생기는 길인지

### 다음 세션 순서
1. 위 「아직 확인 못 한 것」을 읽고 **새 사양서(별도 파일)를 쓰고** `/작업분해` 로 작업표를 만든다(조각 표·의존 순서·공유 지점·출시 때 걷을 자리도 함께)
2. 새 「사용자 확인 필요」가 생기면 하나씩 묻는다
3. 설계에 관여하지 않은 서브에이전트로 문서 자기 정합성 점검(`.claude/rules/planning.md` 「규칙 C — 사양서 자기 정합성 점검」) — 지적 0건까지
4. 그 뒤 서버 조각부터 착수(오후 작업표 M8 — 상대 개발자에게 `brands`·`brand_invites`·531·533 재정의 작업 여부 먼저 확인). 관리자 브랜드 상세 데이터베이스 세션이 533 을 손대는 중일 수 있다
- Figma 구역 설명 글 추출본은 세션 임시 폴더라 사라진다 — 필요하면 Figma 파일 `XG4hXdgySeN45Ele3EnN8H` 구역 `659:523` 에서 다시 뽑는다
