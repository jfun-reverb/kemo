# 📋 작업 분해표 — 오류 로그: 같은 오류는 한 줄로 묶고, 날짜·환경별 횟수를 따로 쌓는다

**사양서:** `docs/specs/2026-10-12-error-log-env-distribution.md` (origin/dev `2604c266` 시점)
**분해일:** 2026-10-13
**총 작업 조각:** 12개 · **병렬 가능:** 2개 · **순차 필수:** 10개

---

## 🚦 착수 전 선결 조건

| # | 선결 조건 | 근거 | 막는 조각 |
|---|---|---|---|
| 1 | **탈퇴 확정 판정을 무엇으로 할지 정한다** — 사양서가 말하는 「358 `login_blocked` 판정 함수」는 **함수가 아니다.** `get_my_withdrawal_state()` 반환값 안의 한 줄짜리 식(`status = 'done'`)이다(358 파일 190줄). 함수로 있는 것은 `_withdrawal_account_blocked()` 인데 이것은 **더 넓은 쓰기 차단 판정**(확정 **또는** 예정일 경과)이다 | 358 파일 111~133줄, 184~193줄 | D2 |
| 2 | **도입일 표의 조회 정책 여부를 정한다** — 사양서는 「행 단위 보안 정책만 켜고 정책 없음」인데, 그러면 같은 오류 로그 화면의 「막힌 표 감지」(335·336)가 그 표를 「확인 안 됨」으로 잡아 사이드바 아이콘이 회색 경고로 바뀐다. 점검 스크립트(`node scripts/check-table-readers.mjs --tables <표> --record`)를 개발·운영 각각 돌려 기록해야 사라진다 | 335 파일 20~45줄 | D2·O1 |
| 3 | **「직접 선택」 날짜 입력 모양을 정한다** — 사양서는 「날짜 칸 둘(시작·끝)」, 기존 관리자 기간 필터는 **달력 한 칸짜리 범위 선택**(`delivSubmittedRange`·`campDelivCertRange`, flatpickr). 범위 한 칸은 「시작만 비움 / 끝만 비움」(사양서 경우의 수 ⑦)을 표현 못 한다 | `.claude/rules/quality.md` 「먼저 기존 것을 보고 맞춘다」 · `dev/admin/index.html` 1445·1623줄 | C3·C4 |

→ 셋 다 결정됨(아래 「선결 결정」).

## 선결 결정 (2026-10-13 사용자)
| # | 결정 | 반영 |
|---|---|---|
| 1 | **「확정」부터** — 탈퇴 화면과 같은 기준(`withdrawal_requests.status = 'done'`, `get_my_withdrawal_state()` 의 `login_blocked` 와 같은 뜻). 예정일 경과 구간(새벽 확정 처리 전 몇 시간)은 포함하지 않는다 — 그 구간 회원은 탈퇴를 취소할 수 있다 | D2: 판정을 새로 퍼뜨리지 않도록 358 의 기준을 가리키는 주석 + 같은 식. 🔴 `_withdrawal_account_blocked()`(쓰기 차단, 더 넓음)를 쓰지 않는다 |
| 2 | **관리자 조회 허가 둠** — 도입일 표에 조회 정책 `(SELECT public.is_admin())` | D2. **O1(막힌 표 점검 기록)은 필요 없다** — 날짜별 표(D1)도 조회 정책이 있어 걸리지 않는다. 적용 뒤 「못 읽는 표」에 안 뜨는지만 V1 에서 본다 |
| 3 | **달력 한 칸 범위 선택**(결과물 관리 「최근 제출일」과 같은 flatpickr 범위 방식) | C3·C4. 사양서 경우의 수 ⑦(「시작만 비움 / 끝만 비움」)은 이 모양에서 성립하지 않으므로 규칙을 바꾼다: **두 날짜 선택 = 그 기간 · 한 날짜만 선택 = 그 하루 · 비움 = 「전체」와 같음**. 사양서 「구현 결과」에 이 변경을 적는다 |

---

## ⚠️ 사양서 stale 점검 (규칙 A·D — 코드 대조 결과)

**현재 원본 번호 확인** (정의 `CREATE` 가 있는 파일만 셈)

| 함수 | 이름이 나오는 파일 | 정의가 있는 파일 | 현재 원본 |
|---|---|---|---|
| `report_client_error` | 165·279·308·369 | 165·279·308 (369 는 주석만) | **308** ✅ |
| `resolve_client_error` | 165·518 | 165·518 | **518** ✅ |
| `purge_old_client_error_identity` | 519 | 519 | **519** ✅ |
| `purge_withdrawn_personal_data` | 352·396·520 (+361·369 주석·권한) | 352·396·520 | **520** ✅ (이 사양은 안 건드림) |

**어긋난 곳 6개**
1. 🔴 **「358 `login_blocked` 판정 함수」는 없다** — 선결 1. `get_my_withdrawal_state()` 의 반환 칸 이름일 뿐이다. 그대로 옮겨 적으면 판정 사본이 하나 더 생긴다.
2. 🔴 **저장소 문서 셋이 사양서와 다른 설계를 말한다** — `CLAUDE.md` 「보관 3개월」 줄 · `.claude/rules/admin-tools.md` 17줄 · 519 파일 머리말 19~21줄이 「`user_agent` 만 `last_seen_at` 기준」. 사양서(10-13 결정)는 **두 칸을 한 쌍으로 묶고 새 칸 `identity_at` 기준**. 519 머리말을 따르지 말고 `CLAUDE.md`·`admin-tools.md` 를 같은 커밋에서 고쳐 쓴다(519 파일은 이력이라 그대로, 새 마이그레이션 머리말에 「519 머리말의 제안은 폐기됨」).
3. **「`_visitDateTodayKst` 와 같은 방식」** — 그 함수는 `admin-dashboard.js` 전용. 공용 `jstTodayStr()`(`dev/lib/shared.js`, 관리자 빌드에도 실림)을 쓴다. 날짜 하루 빼기 공용 함수는 없다 → `admin-errors.js` 안 문자열 연산 도우미 또는 `jstTodayStr` 옆으로 공용화.
4. ⚠️ **회원 아이디 칸에 외래 키(FK)** — `client_error_logs.user_id REFERENCES influencers(id) ON DELETE SET NULL`(165). 지금(308)은 새 줄을 넣을 때만 `user_id` 를 쓰지만 재정의 뒤엔 **기존 줄 갱신에도** 쓴다. `influencers` 행이 없는 로그인 계정이 부르면 갱신 자체가 실패하고 화면은 삼킨다(`reportClientError` 무음). 방어 권장(D2 주의).
5. ⚠️ **`identity_at` 이 비면 파기에서 영원히 빠진다** — 기본값 `now()` + 채운 뒤 「비지 않음」 제약, 또는 파기 조건 `COALESCE(identity_at, first_seen_at)`.
6. **관리자 앱은 오류를 보내지 않는다** — `collectClientError` 는 회원 빌드에만. 지문 변경 영향은 **회원 앱만**(충돌 아님, 범위 확인).

**충돌 없음으로 확인(5영역)**: 자립형 단독 화면(`event-scan.html`·`admin-setpw.html`) 오류 수집 호출 0건 · 서버 함수(`supabase/functions/`) `client_error` 참조 0건 · 엑셀 내보내기에 오류 로그 없음 · `refreshPane('errors')` 등록됨 · 사이드바 미해결 배지(`fetchClientErrorOpenCount`)는 줄 수 기준이라 그대로.

---

## 한눈에 보는 의존 순서

```
[D1 마이그레이션①: 날짜별 표 + 환경 분류 함수]
        ↓
[D2 마이그레이션②: 도입일 표 + identity_at + 조회 함수 + 세 함수 재정의 — 한 묶음]
        ↓ (개발 데이터베이스 적용·시험 통과 뒤)
[C2 storage.js] → [C3 admin/index.html] → [C4 admin-errors.js]      ∥ [C1 error-report.js 지문]
        ↓
[C5 문서(CLAUDE.md·규칙·사양서 구현 결과)] — 코드와 같은 커밋
        ↓
[V1 개발서버 검증 14항목]
        ↓
[P1 운영: 데이터베이스 먼저 → 화면 코드] → [O1 막힌 표 점검 기록(선결 2 결과에 따라)]
        ↓
[N1 Notion 가이드]      [H1 운영 배포 1주 뒤 옛 줄 정리 — 사람]
```

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약 | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| D1 | 날짜별 표 + 환경 분류 함수 | `supabase/migrations/` 새 파일 ① | 표 `client_error_daily(error_log_id, day, env, count)` · 함수 `_client_error_env_label(text) → text` | 없음 | ✗ | 개발 |
| D2 | 도입일·쌍 기준·조회 함수·세 함수 재정의 | `supabase/migrations/` 새 파일 ② | 칸 `client_error_logs.identity_at` · 도입일 표 · `get_client_error_counts(date, date) → jsonb {introduced_on, rows}` · `report_client_error`(10인자 그대로)·`resolve_client_error`(3인자 그대로)·`purge_old_client_error_identity()` 재정의 | D1, 선결 1·2 | ✗ | 개발 |
| C1 | 지문 계산 변경 | `dev/js/error-report.js` | `_fingerprint(msg, stack, context)` 새 규칙 a/b/c · 우리 사이트 주소식 상수 1개를 `_isNoise` 와 공유 | 없음(코딩)/D2(배포) | ✓ | 개발 |
| C2 | 조회 함수 추가·기존 조회 정리 | `dev/lib/storage.js` 🔥 | `fetchClientErrorCounts(from, to)` — 실패 `null` / 성공 `{introduced_on, rows}` · `fetchClientErrors` 의 `since` 제거 | D2 | ✗ | 개발 |
| C3 | 기간 선택지·날짜 칸·횟수 머리글 | `dev/admin/index.html` 🔥 | `errFilterDays` 「직접 선택」 · 날짜 칸 아이디 2개 · `#errCountHeader` · `#errPeriodNotice` | 선결 3 | ✗ | 개발 |
| C4 | 목록·상세 모달 화면 | `dev/js/admin-errors.js` | `loadClientErrors` 재작성 · `openErrorsOpen` 초기화 보강 · `openClientErrorDetail` 환경 표·「최근 브라우저」 · `_clientErrorCounts` 보관 | C2, C3 | ✗ | 개발 |
| C5 | 레퍼런스 문서 갱신 | `CLAUDE.md` · `.claude/rules/admin-tools.md` · 사양서 「구현 결과」 | 낡은 설계 서술 고쳐 쓰기 | C1~C4 | ✓(같은 커밋) | 개발 |
| V1 | 개발서버 검증 | 화면·콘솔·SQL 편집기 | 사양서 검증 ①~⑪ + ⑫~⑭ | D2, C1~C4 | ✗ | 개발(+사용자) |
| P1 | 운영 반영 | 운영 SQL 편집기 → `dev→main` | 데이터베이스 먼저, 화면 나중 | V1 + 사용자 승인 | ✗ | 개발 → 사용자 확인 |
| O1 | 막힌 표 점검 기록 | `scripts/check-table-readers.mjs`(실행만) | 새 표가 「확인 안 됨」으로 안 뜸 | D2 적용(개발·운영 각각) | ✗ | 개발 |
| N1 | 실무자 가이드 | Notion 「관리자 가이드」 오류 로그 페이지 | 기간 「직접 선택」·횟수 뜻·환경 표 | P1 | — | 개발 |
| H1 | 옛 줄 정리 | 관리자 화면(손) | 갈라진 옛 미해결 줄 무시 + 메모 | P1 + 1주 | — | 사람 |

---

## 조각별 상세

### D1 — 날짜별 표 + 환경 분류 함수 (마이그레이션 2개 중 ①)
- **하는 일**: 날짜별 표를 만들고, 브라우저 문자열을 「OS · 브라우저」 이름으로 바꾸는 순수 계산 함수를 만든다. **아직 아무도 안 쓴다**(수집 함수 연결은 D2) — 비로그인 수집 경로에 끼우기 전에 분류 함수만 따로 시험.
- **담당 파일**: `supabase/migrations/{번호는 개발이 확정}_client_error_daily.sql`
- **산출 계약**:
  - 표 `client_error_daily` — `error_log_id uuid REFERENCES client_error_logs(id) ON DELETE CASCADE` · `day date`(일본 표준시) · `env text` · `count integer` · 기본 키 `(error_log_id, day, env)`. 행 단위 보안 켜고 조회 `(SELECT public.is_admin())`, 쓰기 정책 없음.
  - 함수 `public._client_error_env_label(p_user_agent text) RETURNS text` — `IMMUTABLE`, 표를 안 읽음. 판별 순서: 앱 안 브라우저(LINE·Instagram·Facebook·우리 아이폰 앱) → 아이폰 크롬 → Safari·Chrome·Samsung·Edge·Firefox → 봇 → 기타. 빈 값은 고정 이름.
- **완료 정의**: 개발 SQL 편집기에서 운영 오류 로그 표본 브라우저 문자열 7개 이상(아이폰 사파리·아이폰 크롬·안드로이드 크롬·LINE·인스타그램·윈도우 엣지·빈 값)이 기대 이름으로 나온다. 표 `relrowsecurity = true`.
- **필요 검문소**: `reverb-supabase-expert`
- **주의·롤백**:
  - 🔴 분류 이름은 한 번 정하면 고정 — 이름 목록을 파일 머리말에 표로.
  - 아이패드는 「Macintosh」를 자칭 — 「대략값」 안내로 감수(사양서 ④).
  - 실행 권한 두 방향 모두 회수(`FROM PUBLIC` + `FROM anon, authenticated`). 회수 뒤 `p.proacl::text` 맨 앞 `=X/` 없음 확인.
  - 롤백: `DROP TABLE client_error_daily; DROP FUNCTION _client_error_env_label(text);`. 편집기 경고: 안 뜸.

### D2 — 도입일·쌍 기준·조회 함수·세 함수 재정의 (마이그레이션 2개 중 ②, 한 파일·한 트랜잭션)
- **하는 일**: 사양서 단계 1 묶음 전부 + 도입일 기록 + 조회 함수. 도입일을 여기 두는 이유 — **날짜별 행이 실제로 쌓이기 시작하는 순간이 곧 도입일**이어야 「도입 이전 N회」가 맞는다.
- **담당 파일**: `supabase/migrations/{번호는 개발이 확정}_client_error_identity_pair_and_counts.sql`
- **산출 계약**:
  1. 한 줄짜리 도입일 표(예 `client_error_daily_settings(id=1, introduced_on date)`) — 값 `(now() AT TIME ZONE 'Asia/Tokyo')::date`. 🔴 날짜 상수 금지. 조회 정책은 선결 2.
  2. `ALTER TABLE client_error_logs ADD COLUMN identity_at timestamptz` + 기존 줄 `first_seen_at` 으로 채움 + (권장) 기본값 `now()`·「비지 않음」.
  3. `get_client_error_counts(p_from date DEFAULT NULL, p_to date DEFAULT NULL) RETURNS jsonb` — `SECURITY DEFINER`·`SET search_path=''`·`is_admin()` 가드. 반환 `{introduced_on, rows:[{id, period_count, envs:{이름:횟수}}]}`. 0건이어도 `introduced_on`. `p_to` 비면 오늘(일본), `p_from` 비면 하한 없음. 실행 권한 `authenticated` 만.
  4. `report_client_error` — **308 본문 베이스 `CREATE OR REPLACE`, 인자 10개·자료형·기본값 그대로.** 세 갈래(기존 줄 갱신·새 줄·동시 삽입 충돌 갱신) 모두 `RETURNING id` → 날짜별 행 +1(`ON CONFLICT (error_log_id, day, env) DO UPDATE SET count = client_error_daily.count + 1`). 세 갈래 모두 `user_agent`·`user_id`·`identity_at = now()` 를 **한 문장에서 함께**. 탈퇴 확정이면 쌍 NULL(선결 1).
  5. `resolve_client_error` — **518 본문 베이스.** 합치기 갈래에서 `DELETE` **앞에** 지울 줄의 날짜별 행을 남길 줄로 옮겨 더한다. `identity_at = v_newer.identity_at` 추가.
  6. `purge_old_client_error_identity()` — **519 베이스.** 조건 `identity_at`(또는 `COALESCE(identity_at, first_seen_at)`) 3개월. 예약은 다시 등록하지 않는다.
- **선행**: D1, 선결 1·2
- **완료 정의**(개발 SQL 편집기 — 비로그인 갈래만 돈다):
  - ① 새 지문으로 1회 → 새 줄 1개 + 오늘 날짜별 `count=1` + `identity_at` 채워짐
  - ② 같은 지문 다시 → 횟수 2, 날짜별 `count=2`
  - ③ 권한 `p.proacl::text` — `report_client_error` 에 `anon`·`authenticated` **그대로**(가장 중요), 파기 함수 `postgres` 만, 조회 함수 `authenticated` 만
  - ④ `SELECT oid::regprocedure FROM pg_proc WHERE proname='report_client_error'` → 10인자 1행
  - ⑤ 시험 줄 지우기
  - 로그인 갈래·관리자 가드는 SQL 편집기로 재현 안 됨 → V1 콘솔.
- **필요 검문소**: `reverb-supabase-expert`(필수) · `reverb-reviewer`
- **주의·롤백**:
  - 🔴 비로그인 수집 경로라 실패하면 **오류 수집 전체가 조용히 멈춘다** — 확인은 V1·P1 「멈춤 감시」.
  - 🔴 `DROP FUNCTION` 금지 — `CREATE OR REPLACE` 로만.
  - ⚠️ 외래 키 방어(stale 4): `influencers` 에 없으면 NULL — 또는 감수하고 머리말에 결정 기록.
  - ⚠️ 탈퇴 판정이 예외를 내면 수집 전체 실패 → `BEGIN … EXCEPTION WHEN others` 로 감싸고 실패 시 쌍 NULL.
  - ⚠️ 잠금 순서: 날짜별 삽입은 부모 줄 갱신 **뒤**에(518 의 `FOR UPDATE` 와 교착 방지).
  - 편집기 경고: **뜸 — 무해**(518 본문 안 `DELETE` 단어).
  - 롤백: 308·518·519 의 `CREATE OR REPLACE` 블록 재적용. 칸·표는 남겨도 무해.

### C1 — 지문 계산 변경 (`error-report.js`)
- **하는 일**: 사양서 설계 ① 표 a/b/c 그대로.
- **산출 계약**: `_fingerprint(msg, stack, context)` 시그니처 유지 · 우리 사이트 주소식 상수 1개를 `_isNoise` 와 공유(사본 금지).
- **선행**: 없음(코딩). **배포는 D2 뒤.**
- **완료 정의**: 콘솔에서 크롬식(`at updateStats (https://dev.globalreverb.com/:1:2)`)·사파리식(`updateStats@https://dev.globalreverb.com/:1:2`)이 **같은 지문**, 익명 함수는 종전 지문과 같다.
- **필요 검문소**: `reverb-reviewer`
- **주의**: `async ` 접두어·소유자 접두어·사파리 `global code` 처리. 기존 `split('\n')[1]` 동작(c 갈래)은 그대로. 「빌드를 압축하면 전제가 깨진다」 주석.

### C2 — 조회 함수 (`storage.js`) 🔥
- **산출 계약**: `fetchClientErrorCounts(from, to)` — `db.rpc('get_client_error_counts', …)`, 실패 `null` · 성공 `{introduced_on, rows}`. `retryWithRefresh` 권장. `fetchClientErrors` 의 `since` 제거(호출부 `admin-errors.js` 한 곳).
- **완료 정의**: 관리자 콘솔 `await fetchClientErrorCounts(null, null)` → `introduced_on` 오늘 · `('2000-01-01','2000-01-02')` → `rows: []` + `introduced_on`.
- **필요 검문소**: `reverb-supabase-expert` · `reverb-reviewer`

### C3 — 기간 선택지·날짜 칸 (`admin/index.html`) 🔥
- **하는 일**: `#errFilterDays` 에 「직접 선택」, 날짜 칸(선결 3 모양, 높이 32px `admin-filter`), 횟수 머리글 아이디, 안내 줄 자리.
- **산출 계약**: 날짜 칸 아이디 2개(예 `errFilterFrom`·`errFilterTo`) · `#errCountHeader` · `#errPeriodNotice`
- **완료 정의**: 「직접 선택」 외엔 날짜 칸이 안 보이고, 보일 때 옆 필터와 높이가 같다.

### C4 — 목록·상세 모달 (`admin-errors.js`)
- **하는 일**:
  - `loadClientErrors`: 기간을 일본 날짜 문자열로(「오늘」 = 오늘~오늘). 기존 `Date` 계산 삭제. 테이블 조회와 `fetchClientErrorCounts` 를 함께 —
    - 「전체」: 모든 줄 + 누적 횟수(조회 함수 실패면 환경 줄만 안 그림)
    - 그 밖: `rows` 와 겹치는 줄만, 횟수 = `period_count`. 실패면 목록 대신 「기간별 횟수를 불러오지 못했습니다」
    - 시작 > 끝이면 조회하지 않고 안내
    - 시작 ≤ 도입일이면 `#errPeriodNotice`
    - 머리글 「횟수(오늘)」, 메시지 아래 가장 많은 환경 하나, 기간 맞춤 빈 상태 문구
  - `openErrorsOpen`: 「전체」로 되돌릴 때 날짜 칸 비우고 숨김
  - `openClientErrorDetail`: 「발생 환경」 표 + 「전체」에서만 「도입 이전 N회」 · 「최근 브라우저」 + 받은 시각(`identity_at`, `formatDateTime`) · 쌍이 비면 「브라우저 정보 없음」 · 「분류는 대략값」
- **주의**: 🔴 「도입 이전 N회」 = `occurrence_count − 날짜별 합`, 조회 실패를 0 으로 그리지 않는다. 비율 분모는 날짜별 합. 달력을 쓰면 `formatDate` 로 문자열화·`clear(false)`.

### C5 — 레퍼런스 문서 (코드와 같은 커밋)
- `CLAUDE.md` 「보관 3개월」 줄 고쳐 쓰기(`identity_at` 기준, 「`user_agent` 만 `last_seen_at`」 삭제) + 새 표·조회 함수·현재 원본 번호.
- `.claude/rules/admin-tools.md` — 「처음 발생 3개월 뒤」 → 「받은 지 3개월 뒤」, 「「브라우저」 줄」 → 「「최근 브라우저」 줄」.
- 사양서 「구현 결과」 — 실제 마이그레이션 번호·분류 이름 목록·선결 결정.
- **완료 정의**: `grep -n "처음 발생 3개월\|last_seen_at 기준으로 갈라" CLAUDE.md .claude/rules/` 0건 + 같은 파일에서 `identity_at` 1건 이상.

### V1 — 개발서버 검증
- 사양서 검증 ①~⑪ + 아래 셋:
  - ⑫ **멈춤 감시(양성 대조)**: 회원 앱 로그인 비밀번호 틀린 직후 관리자 오류 로그에서 해당 줄 횟수 +1 **그리고** 「오늘」 횟수 +1
  - ⑬ 로그인 갈래: 시험 회원 콘솔 `await db.rpc('report_client_error', {p_fingerprint:'fp-v1-test', p_source:'influencer', p_kind:'handled', p_message:'v1 test', p_user_agent: navigator.userAgent})` → `user_id` 그 회원, `identity_at` 방금
  - ⑭ 관리자 콘솔 `await fetchClientErrorCounts(jstTodayStr(), jstTodayStr())` 의 `rows` 에 ⑬ 줄
- ⑪(탈퇴 확정) 재현: 시험 회원 탭을 새로고침하지 않은 채 개발 SQL 편집기로 `withdrawal_requests` 에 `status='done'` 행 → 그 탭 콘솔에서 ⑬ 호출 → 쌍 빔 → 행 삭제. ⚠️ 운영 금지.
- **필요 검문소**: `reverb-qa-tester` 권장(단일 세션) · 브라우저 확인은 `.claude/rules/browser-qa.md`
- 사파리 항목은 아이폰 실기기나 맥 사파리 — 없으면 사용자에게.

### P1 — 운영 반영 (사용자 승인 후)
- ① 운영 SQL 편집기에 D1 → D2(절대경로 먼저, D2 경고 「뜸 — 무해」) → ② 권한·시그니처 조회 → ③ `dev→main` 병합 → ④ 멈춤 감시.
- **멈춤 감시(운영)**: 적용 직후와 몇 시간 뒤 `SELECT max(last_seen_at) FROM client_error_logs;` · `SELECT max(day), sum(count) FROM client_error_daily;` — 반나절 넘게 안 움직이면 308 블록으로 즉시 되돌린다. 「Success」 말고 결과 값으로 판단.
- **순서 이유**: 화면이 먼저면 없는 조회 함수를 불러 기간 필터가 실패. 수집 함수는 인자가 같아 옛 회원 화면과도 맞물린다.

### O1 — 막힌 표 점검 기록
- 선결 2 에서 「정책 없음」이면 개발·운영 각각 `node scripts/check-table-readers.mjs --tables <도입일 표> --record`.
- **완료 정의**: 오류 로그 화면 「못 읽는 표」에 새 표가 없다.

### N1 — Notion 실무자 가이드
- 운영 반영 뒤 오류 로그 페이지에 기간 「직접 선택」·횟수 뜻·발생 환경(대략값)·「도입 이전」. `notion-sync.md` 정확성 게이트.

### H1 — 옛 줄 정리 (운영 화면 배포 1주 뒤, 사람)
- 사양서 설계 ④ — 짝이 되는 새 줄이 생긴 옛 미해결 줄만 「무시」 + 메모 「지문 변경 전 줄 — 새 줄로 이어짐」.

---

## ⚠️ 공유 지점 경고

1. **핫스팟 두 개** — `dev/lib/storage.js`(C2), `dev/admin/index.html`(C3). 다른 세션이 같은 시기에 만지면 순차로. 이 사양 안에서도 C2·C3·C4 는 한 세션 차례로.
2. **수집 함수 하나를 모든 회원이 부른다** — 착수 전 `ls supabase/migrations | tail -3` 으로 번호 확인 + 「다른 세션도 마이그레이션 만들 일이 있나」 한 번 묻기.
3. **판정 사본이 늘지 않게** — 우리 사이트 주소식(한 상수) · 일본 날짜(`jstTodayStr`) · 환경 분류(서버 한 곳) · 탈퇴 확정 판정(선결 1).
4. **파기 두 개가 같은 칸을 비운다** — 519(매일 03:30)와 520(탈퇴 확정 순간). D2 는 519 만 고친다. 쌍이 한 문장에서 함께 바뀌어야 520 이 탈퇴 회원의 브라우저를 놓치지 않는다.
5. **막힌 표 감지와 같은 화면** — 새 표를 정책 없이 만들면 이 화면 자신이 경고를 띄운다(선결 2·O1).

---

## 🧭 배분 제안

- **개발 세션 1개로 충분.** 데이터베이스 조각은 한 세션·순차, C2·C3 는 핫스팟이라 병렬 이득 없음.
- 병렬을 원하면 **C1(지문)만** 떼어낼 수 있다(배포는 D2 뒤).
- **병합 요청 2개 권장**: ①마이그레이션 2개 — 개발 데이터베이스 적용·D2 완료 정의까지 ②화면·지문·문서(C1~C5) — V1 통과까지. 운영은 ①의 SQL 먼저, ②의 병합 나중.
- 약관: 사양서가 「집계라 개인과 이어지지 않음」으로 방침 개정 없음 판단. 리뷰 단계에서 `/약관확인` 한 번 권장.
