# 사용자(인플루언서) 앱 에러를 관리자가 볼 수 있게 하는 기능
**작성일:** 2026-06-02
**작성:** reverb-planner (기획 세션)
**상태:** 설계 — 사용자 결정 대기 (미착수)

> 사용자 요청 원문: "사용자들이 사용하면서 에러코드가 뜨는 걸 관리자에게 알릴 수 있나? 실시간이 아니더라도."

---

## 현재 상태 (작성일 2026-06-02 기준, planning.md 규칙 A)

### 관련 코드·DB·UI 진입점
- **에러 표시 변환기 2종** (관리자에게 전송하는 곳 아님, 사용자 화면 표시용):
  - `friendlyErrorJa(e)` — `dev/js/ui.js:111`. 인플루언서 일본어/한국어 i18n 분기. 정규식 12종 매칭 후 사전 문구 반환. **호출처는 단 8곳** (`mypage.js` 3 · `application.js` 4 · `ui.js` 1). 즉 인플 앱 에러의 극히 일부만 이 함수를 거침.
  - `friendlyError(msg)` — `dev/js/admin-core.js:99`. 관리자 한국어. `[ERR_XXX_NNNNN]` 코드 부착.
- **`console.error` 101곳** (`dev` 전체): `storage.js` 65 · `admin-messaging.js` 11 · `admin-deliverables.js` 7 · `messaging.js` 6 · `admin-excel.js` 4 · 기타. **현재 이 로그는 사용자 본인 브라우저 콘솔에만 출력 — 관리자는 절대 못 봄.**
- **전역 에러 핸들러 없음**: `window.onerror` / `unhandledrejection` / `addEventListener('error')` grep 0건. 미처리 예외·Promise reject는 어디에도 잡히지 않음.
- **외부 에러 추적 도구 없음**: Sentry·LogRocket 등 미연동. 에러 로그 테이블 없음.
- **앱 부트**: `dev/js/app.js:441` `DOMContentLoaded` 핸들러 — 여기가 전역 핸들러를 달 유일한 진입점.
- **DB 함수 집중**: `dev/lib/storage.js` (CLAUDE.md Rules — 다른 파일 직접 쿼리 금지). 세션 만료 재시도 `retryWithRefresh()` (storage.js:8).

### 활용 가능한 기존 인프라
- `notifications` (인플루언서 알림 — 관리자용 아님). 관리자 알림은 `admin_notices` 테이블 별도.
- `admin_email_subscriptions` (마이그레이션 103) + lookup `admin_email_kind` (시드 `brand_notify`/`application_cancel`/`application_received`). 신규 메일 종류는 lookup 한 줄 추가로 확장 가능. 헬퍼 `get_subscribed_admin_emails(p_mail_kind)`.
- **관리자 일일 통합 다이제스트** `notify-admin-daily-digest` (pg_cron 매일 KST 09:00, 4섹션 1통). **5번째 섹션 추가 가능.**
- 익명 INSERT 패턴: 반드시 SECURITY DEFINER RPC (RLS WITH CHECK + RETURNING 충돌 42501 사례 — `.claude/rules/supabase.md`).
- 관리자 목록 페인 패턴: IntersectionObserver lazy-load · `refreshPane` · sticky-header · `admin-pane-list` 클래스 · PostgREST 1000행 cap → `fetchAllPaged`.
- 약관 문서: `docs/PRIVACY_{ja,kr}.md`, `docs/TERMS_{ja,kr}.md` 존재.
- 마이그레이션 현재 최신 **164**(관리자 메일 항목 통합). 신규는 **165**.

### 이 제안과 충돌 가능성 있는 기존 동작
- **확인 완료 — 직접적 코드 충돌 없음** (에러 로그 인프라가 전무하므로 신규 추가).
- 단 **약관(PRIVACY) 충돌 위험 있음**: 에러 메시지·스택에 사용자 개인정보가 섞여 들어가면 「수집하는 개인정보」에 빠진 채 수집하는 셈이 됨 → §의심 2 참조. 이건 코드 충돌이 아니라 법적 충돌.
- `notify-admin-daily-digest` 다이제스트에 섹션을 추가하면 기존 4섹션 메일 레이아웃·`sections_summary jsonb`(`{received, cancelled, submitted, reprocessed}`) 구조를 건드림 → 5번째 키 추가 필요.

### 미해결 백로그·관련 작업
- 관련 백로그 없음 (신규 영역). 메모리·specs에 에러 수집 관련 항목 없음.
- 참고: 관리자 일일 다이제스트는 이미 운영 중 (`feedback_dev_no_mail_test.md` — 메일 발송 테스트는 운영에서만).

---

## 의심·경우의 수 (planning.md 규칙 B — 반대론자 모드)

### 1. 깨질 수 있는 경우의 수 (UX 포함 의무)

**[기술] 수집 자체 실패로 무한 루프**
에러 보고 INSERT(또는 RPC)가 또 실패하면(네트워크 끊김·RLS 오류) 그 실패가 다시 에러로 잡혀 또 보고를 시도 → 재귀·폭주. 특히 `window.onerror` 전역 훅에서 보고 로직이 던지는 예외는 다시 `window.onerror`로 들어옴. **반드시 보고 경로 자체는 try/catch로 완전히 삼키고(절대 throw 안 함), 보고 중 플래그(`_reporting`)로 재진입 차단.**

**[기술] 폭증 — 한 사용자 한 버그가 수천 건 INSERT**
무한 스크롤·렌더 루프 안에서 같은 에러가 나면 초당 수십 건 발생. 매 건 INSERT 하면 DB 폭증 + Brevo·다이제스트 노이즈. **fingerprint(메시지+위치 정규화 해시)로 묶어 `occurrence_count` 증가 + 클라이언트 측 동일 fingerprint 디바운스(예: 같은 fingerprint 60초 내 1회만 전송).**

**[데이터/법률] 개인정보가 에러 메시지·스택에 섞임 (가장 중요)**
DB 에러 메시지에 입력값이 그대로 나올 수 있음(예: `duplicate key value ... (email)=(user@x.com)`), 스택·URL 쿼리에 토큰·이메일·전화·PayPal·주소가 섞일 수 있음. 이걸 그대로 저장하면 PRIVACY에 없는 개인정보를 새로 수집·국외이전(Supabase 도쿄)하는 셈 → APPI·PIPA 위반 소지. **저장 전 마스킹 필수**(이메일·전화·우편번호·토큰·`(...)=(...)` PostgreSQL 상세값 정규식 치환) + PRIVACY 반영 검토.

**[권한/환경] anon·비로그인 사용자 에러**
회원가입 전·로그인 화면·캠페인 목록 열람은 비로그인(anon). 이 단계 에러도 받고 싶으면 `user_id` NULL 허용 + anon이 호출 가능한 SECURITY DEFINER RPC 필요. anon에게 INSERT 권한을 직접 주면 스팸 INSERT 벡터(누구나 임의 로그 주입) → **RPC 안에서 rate limit + 페이로드 크기 제한.**

**[UX — 관리자] 노이즈에 파묻혀 진짜 버그를 놓침**
사용자 네트워크 끊김·브라우저 확장 충돌·`ResizeObserver loop` 같은 무해 에러·취소된 요청(`AbortError`)이 대량 유입되면, 관리자 화면이 의미 없는 빨강으로 가득 차 정작 봐야 할 신규 버그를 못 봄. **수집 단계 노이즈 필터(블록리스트) + 관리자 화면에서 「해결됨/무시」 상태 + 「미해결만」 기본 필터** 필수. 빈 상태(에러 0건)일 때는 "최근 보고된 오류가 없습니다" 안내.

**[UX — 인플루언서] 보고 동작이 사용자 경험을 방해하면 안 됨**
에러 보고는 100% 백그라운드·무음이어야 함. 사용자에게 "오류를 보고하시겠습니까?" 팝업·로딩 스피너·토스트 절대 금지(인플은 일본어, 초등학생 눈높이 — 영문 에러코드 노출도 금지). 기존 `friendlyErrorJa` 일본어 표시는 그대로 두고, 보고는 그 뒤에서 조용히.

### 2. 현재 구현과 어긋나는 지점
- **확인 완료 — 코드 충돌 없음** (신규 인프라). 단 다음 2가지는 기존 구조에 "끼워 넣는" 작업이라 주의:
  - DB 함수는 `storage.js` 집중 규칙 → 보고 함수 `reportClientError()`도 `storage.js`에 추가.
  - 다이제스트 메일 섹션 추가 시 `sections_summary jsonb` 키 1개 추가 + `notify-admin-daily-digest/templates.ts` 레이아웃 수정.

### 3. 사용자 의도와 다르게 해석될 수 있는 부분
- **"에러코드가 뜨는 걸"** = ① 사용자 화면에 토스트로 보인 에러만(`friendlyErrorJa` 통과분, 8곳뿐)인지 ② 콘솔에만 찍힌 `console.error` 101곳인지 ③ 코드에 아예 안 잡힌 미처리 예외(흰 화면·앱 멈춤)까지인지 — **세 범위가 완전히 다름.** 사용자가 말한 "에러코드"는 보통 ①(화면에 보이는 것)이지만, 운영상 정작 중요한 건 ③(앱이 멈추는 치명적 버그). → 결정 필요.
- **"관리자에게 알릴 수 있나"** = ① 관리자 화면에 쌓이는 목록(보러 가는 방식)인지 ② 메일로 밀어주는 방식(받는 방식)인지 ③ 둘 다인지. "실시간 아니어도 된다"는 단서는 ②(일일 다이제스트 메일) 또는 ①(목록)이면 충분하다는 뜻. → 결정 필요.
- **인플 앱만? 관리자 앱도?** 관리자 앱 에러는 운영자 본인이 보는 화면이라 보고 의미가 다름(스스로 콘솔 확인 가능). 우선 인플 앱만 권장. → 결정 필요.

### 권고 (한두 문장)
실시간 불필요·운영 부담 최소 전제에서, **수집 범위는 「전역 미처리 예외(window.onerror·unhandledrejection) + friendlyErrorJa를 거친 처리된 에러」 둘 다**, 저장은 **fingerprint 묶음 + 강한 마스킹**, 관리자 노출은 **(a) 관리자 「오류 로그」 페인 목록(상태 관리 가능) + (c) 사이드바 미해결 배지**를 기본으로 하고, 일일 다이제스트 메일 섹션(b)은 선택 옵션으로 둔다(메일 노이즈 우려). 인플 앱만 먼저, 관리자 앱은 후순위.

---

## 제안 / 설계

### 전체 흐름
```
인플 앱에서 에러 발생
  ├─ window.onerror / unhandledrejection (전역 미처리 예외)
  └─ friendlyErrorJa() 통과 (처리된 에러, 토스트로 표시된 것)
        ↓ (둘 다 collectClientError로 모임)
  noise 필터 통과? ── no ──▶ 버림
        │ yes
  fingerprint 계산 + 60초 디바운스 (같은 fp 중복 억제)
        ↓
  마스킹 (이메일/전화/우편번호/토큰/PG 상세값 제거)
        ↓
  reportClientError() → SECURITY DEFINER RPC `report_client_error()`
        ↓
  client_error_logs 테이블 (같은 fingerprint면 occurrence_count++ , 아니면 신규 INSERT)
        ↓
  [관리자] (a) #adminPane-errors 목록 페인 + (c) 사이드바 미해결 배지
           (b 옵션) 일일 다이제스트 메일 5번째 섹션
```

### DB 스키마 초안 (마이그레이션 165)

```sql
-- ── 테이블 ──────────────────────────────────────────────
CREATE TABLE public.client_error_logs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fingerprint   text NOT NULL,            -- 메시지+위치 정규화 해시 (묶음 키)
  source        text NOT NULL DEFAULT 'influencer'  -- influencer | admin (앱 구분)
                  CHECK (source IN ('influencer','admin')),
  kind          text NOT NULL             -- unhandled | rejection | handled (수집 경로)
                  CHECK (kind IN ('unhandled','rejection','handled')),
  message       text NOT NULL,            -- 마스킹된 에러 메시지
  error_code    text,                     -- friendlyError의 [ERR_XXX] 코드 (있으면)
  stack         text,                     -- 마스킹된 스택 (선택, 길이 제한)
  page_hash     text,                     -- location.hash (#detail-123 등, id는 마스킹)
  context       text,                     -- 발생 맥락 (어떤 동작 중 — 화이트리스트 라벨만)
  user_agent    text,                     -- 브라우저/OS (개인식별 아님)
  user_id       uuid REFERENCES public.influencers(id) ON DELETE SET NULL, -- 로그인 시만, NULL=anon
  occurrence_count integer NOT NULL DEFAULT 1,   -- 같은 fingerprint 누적 횟수
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at  timestamptz NOT NULL DEFAULT now(),
  -- 관리자 처리 상태
  status        text NOT NULL DEFAULT 'open'     -- open | resolved | ignored
                  CHECK (status IN ('open','resolved','ignored')),
  resolved_by   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  resolved_at   timestamptz,
  resolve_note  text,
  UNIQUE (fingerprint, status)   -- open 상태 같은 fp는 1행으로 묶임 (resolved 후 재발하면 새 open)
);

CREATE INDEX client_error_logs_status_lastseen_idx
  ON public.client_error_logs (status, last_seen_at DESC);
CREATE INDEX client_error_logs_fingerprint_idx
  ON public.client_error_logs (fingerprint);

-- ── RLS ─────────────────────────────────────────────────
ALTER TABLE public.client_error_logs ENABLE ROW LEVEL SECURITY;
-- SELECT: 관리자만 (사용자는 자기 에러 로그 볼 필요 없음)
CREATE POLICY cel_select_admin ON public.client_error_logs
  FOR SELECT USING (public.is_admin());
-- INSERT/UPDATE 직접 금지 — 전부 RPC 경유 (정책 미생성 = service_role/SECURITY DEFINER만)
-- 단 관리자 상태변경(resolve/ignore)은 별도 RPC 또는 UPDATE 정책:
CREATE POLICY cel_update_admin ON public.client_error_logs
  FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());
```

### 보고 RPC 초안 (SECURITY DEFINER — anon·authenticated 양쪽 호출)

```sql
CREATE OR REPLACE FUNCTION public.report_client_error(
  p_fingerprint text,
  p_source      text,
  p_kind        text,
  p_message     text,
  p_error_code  text DEFAULT NULL,
  p_stack       text DEFAULT NULL,
  p_page_hash   text DEFAULT NULL,
  p_context     text DEFAULT NULL,
  p_user_agent  text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();   -- 로그인 시 채워짐, anon이면 NULL
BEGIN
  -- 페이로드 길이 가드 (폭주·거대 스택 방지)
  p_message := left(coalesce(p_message,''), 1000);
  p_stack   := left(coalesce(p_stack,''), 4000);
  IF length(p_fingerprint) = 0 OR length(p_message) = 0 THEN RETURN; END IF;

  -- 같은 open fingerprint 있으면 카운트++ , 없으면 신규
  UPDATE public.client_error_logs
     SET occurrence_count = occurrence_count + 1, last_seen_at = now()
   WHERE fingerprint = p_fingerprint AND status = 'open';
  IF NOT FOUND THEN
    INSERT INTO public.client_error_logs
      (fingerprint, source, kind, message, error_code, stack, page_hash,
       context, user_agent, user_id)
    VALUES
      (p_fingerprint, coalesce(p_source,'influencer'), p_kind, p_message,
       p_error_code, p_stack, p_page_hash, p_context, p_user_agent, v_uid)
    ON CONFLICT (fingerprint, status) DO UPDATE
      SET occurrence_count = public.client_error_logs.occurrence_count + 1,
          last_seen_at = now();
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.report_client_error(...) TO anon, authenticated;
```

> **서버측 추가 마스킹**: 클라이언트 마스킹을 1차 방어로 두되, RPC 안에서 `(...)=(...)` PostgreSQL 상세값·이메일 정규식을 한 번 더 치환하는 2차 방어 권장(클라 우회·신규 누락 대비).

### 클라이언트 수집 로직 (신규 `dev/js/error-report.js` + storage.js 함수)

1. **전역 핸들러** (app.js 부트에 1회 등록):
   ```js
   window.addEventListener('error', (e) => collectClientError(e.error || e.message, 'unhandled'));
   window.addEventListener('unhandledrejection', (e) => collectClientError(e.reason, 'rejection'));
   ```
2. **처리된 에러 훅**: `friendlyErrorJa` 내부 끝에서 `collectClientError(e, 'handled')` 호출 (호출처 8곳 자동 커버). 추가로 `storage.js` 주요 catch에서 선택적 호출.
3. **`collectClientError(err, kind)`** (error-report.js):
   - 재진입 가드 `if (_reporting) return;`
   - 노이즈 블록리스트 매칭 시 return (`ResizeObserver loop`, `AbortError`, `Failed to fetch`(네트워크 끊김 — 옵션), 브라우저 확장 스택 등)
   - fingerprint = `hash(정규화된 메시지 + 파일:라인)` (숫자 id·UUID 제거 후)
   - 60초 디바운스 (메모리 Set, 같은 fp 최근 전송이면 skip)
   - 마스킹: 이메일·전화·우편번호·`Bearer xxx`·`(col)=(val)` 치환
   - `_reporting=true` → `reportClientError(payload)` → finally `_reporting=false`
   - **절대 throw 안 함** (catch로 전부 삼킴)
4. **`reportClientError(payload)`** (storage.js): `db?.rpc('report_client_error', {...})`. `if(!db) return` (DEMO 폴백).

### 관리자 화면 와이어 (텍스트)

신규 페인 `#adminPane-errors` (사이드바 「관리자설정」 그룹 아래 또는 「대시보드」 하단). `admin-pane-list` 패턴.

```
┌─ 오류 로그 ───────────────────────────────────────────────┐
│ [상태 ▾ 미해결] [앱 ▾ 인플/관리자] [기간 ▾ 7일] [검색 메시지/코드] │
├──────────────────────────────────────────────────────────┤
│ 상태 │ 메시지(마스킹)        │ 코드        │ 횟수 │ 최근발생   │ │
│ ●open│ 네트워크 오류…         │ ERR_NETWORK│ 142 │ 2분 전     │⋯│
│ ●open│ 결과물 제출 실패…      │ ERR_NULL   │  7  │ 1시간 전   │⋯│
│ ✓done│ JWT 만료…             │ ERR_AUTH   │  3  │ 어제       │⋯│
└──────────────────────────────────────────────────────────┘
  (행 클릭 → 상세 모달: 전체 메시지·스택·page_hash·user_agent·
   발생 사용자 수·타임라인 + [해결됨 표시][무시][메모])
  빈 상태: "최근 보고된 오류가 없습니다"
```
- **사이드바 배지**: 미해결(open) 건수 빨강 배지 (pending 배지 패턴 재사용).
- **모달 저장 후** `refreshPane('errors')` 의무 (`.claude/rules/quality.md`). → `PANE_REFRESHERS`에 `errors` 등록.

### 약관(PRIVACY) 영향 판단
- **마스킹이 완전하면**: 개인정보를 수집하지 않으므로 PRIVACY 개정 불필요 가능. 단 `user_id`(로그인 사용자 식별)·`user_agent`를 저장하면 「자동 수집 정보」에 해당할 수 있음.
- **보수적 권장**: PRIVACY `_ja`/`_kr` 「자동으로 수집되는 정보」 항목에 "서비스 오류 진단을 위한 오류 메시지·발생 화면·브라우저 정보(개인 식별 정보는 마스킹 처리)"를 1줄 추가. 중대 변경(수집항목 신설)이지만 개인 식별 없는 진단 정보라 사전 통지로 충분(재동의 불요)한지 `/약관확인`으로 별도 판정. → **결정 필요**.

---

## PR 분할

- **PR 1 — DB·RPC**: 마이그레이션 165 (테이블 + RLS + `report_client_error` RPC + 서버측 2차 마스킹). 스모크 호출 1회(`feedback_db_function_smoke_test.md`).
- **PR 2 — 클라이언트 수집**: `dev/js/error-report.js` 신규(전역 핸들러·노이즈 필터·fingerprint·마스킹·디바운스) + `friendlyErrorJa` 훅 + `storage.js` `reportClientError()` + build.sh 등록 + app.js 부트 1줄. 인플 앱만.
- **PR 3 — 관리자 화면**: `#adminPane-errors` 페인 + 목록(lazy-load·필터·검색) + 상세 모달(해결/무시/메모) + 사이드바 미해결 배지 + `PANE_REFRESHERS` 등록. `dev/js/admin-errors.js` 신규.
- **PR 4 (선택) — 다이제스트 메일 섹션**: `notify-admin-daily-digest` 5번째 섹션(어제 신규 미해결 오류 Top N) + `sections_summary` 키 추가. 메일 노이즈 우려로 사용자 확인 후.
- **PR 5 (선택) — 관리자 앱 에러 수집**: source='admin' 으로 관리자 앱에도 동일 수집 적용.
- **PR 6 (선택) — 보관 정리**: pg_cron 으로 90일·resolved/ignored 오래된 행 자동 삭제.

의존성: PR 1 → PR 2 → PR 3. PR 4·5·6은 독립(1·2·3 운영 안정화 후).

## 사용자 확인 필요
(아래 4개 결정 — AskUserQuestion으로 변환: 수집 범위 / 알림 방식 / 대상 앱 / 개인정보·약관)

## 구현 결과
(개발 세션이 채울 것)
