-- ============================================================
-- 361_withdrawal_email_blocks.sql
--
-- 회원 탈퇴 — 작업 11 「재가입 차단(6개월)」 1/2 (기록·판정·정리)
--   362 = 실제 가입 차단 (이 파일 뒤에)
--
-- 작업표 : docs/specs/2026-08-19-member-withdrawal-breakdown.md 「작업 11」
-- 사양서 : docs/specs/2026-08-18-member-withdrawal.md §5 ④ · §4-5(방침 개정 표)
--
-- ============================================================
-- ① 이 파일만 적용하면 — 해시가 쌓이기 시작하고, 가입은 아직 안 막힌다
-- ============================================================
--   확정되는 회원의 이메일 해시가 담기기 시작한다. **서버가 막는 것은 362 부터**다.
--   → 이 파일을 넣고 **실제로 담기는지 눈으로 본 다음** 362 로 차단을 켠다.
--     회원가입은 서비스의 입구라, 한 번에 켜면 잘못됐을 때 **신규 가입이 통째로 죽는다**.
--
--   ⚠️ **다만 화면은 이미 막는다.** 같은 묶음으로 나가는 가입 전 대조가 이 파일의
--     대조 함수 하나만 있으면 동작한다. 즉 361 만 적용해도 **화면에서는 막힌 것처럼
--     보인다**(개발자 도구로 우회하면 여전히 가입은 된다). 「데이터베이스만 보면
--     아무 일도 안 일어난다」가 「사용자에게 아무 일도 안 일어난다」는 뜻이 아니다.
--
-- ============================================================
-- ② ★ 담는 자리를 「이메일이 바뀌는 순간」으로 잡은 이유
-- ============================================================
--   확정되면 파기 함수(352)가 회원 이메일을 자리표시 주소로 바꾼다. 그러므로
--   **해시는 그 교체보다 먼저** 담겨야 한다 — 뒤에 담으면
--   `withdrawn+…@deleted.reverbjp.invalid` 의 해시가 저장돼 **아무도 안 막히고,
--   아무 오류도 안 난다.**
--
--   후보를 넷 놓고 비교한 결과 **「`influencers` 의 이메일이 실제로 바뀌는 그 순간」**
--   에 붙였다:
--
--   | 안 | 352 재정의 | 순서 위험 |
--   |---|---|---|
--   | 파기 함수 재정의 | **필요**(120줄짜리 파기 함수를 통째로 옮겨 적어야 한다) | 없음 |
--   | 확정 표에 트리거 | 불필요 | 🔴 **있다** — 나중에 누가 처리 순서를 바꾸면 조용히 무효가 된다 |
--   | **이메일 교체 시점(채택)** | **불필요** | **없다** — 발동 지점이 곧 그 순간이다 |
--
--   ⚠️ 그래도 **자리표시 주소를 해시하려는 시도는 예외로 막는다**(아래 [C] ③).
--     그러면 어떤 이유로든 순서가 어긋났을 때 **조용한 무효가 아니라 시끄러운 실패**가
--     된다 — 파기가 실패하고, 확정 전이가 롤백되고, 매일 로그에 남는다.
--
-- ============================================================
-- ③ ★ 만료 판정을 「행이 있나」가 아니라 「만료일이 지났나」로 한다
-- ============================================================
--   작업표는 「6개월 경과분을 안 지우면 **6개월 뒤 허용이 영영 안 온다**」고 적었다.
--   그건 판정을 「행이 있나」로 할 때만 참이다. **여기서는 다르게 간다.**
--
--   | | 판정 = 행 존재 | 판정 = 만료일(채택) |
--   |---|---|---|
--   | 정리 예약이 멈추면 | 🔴 재가입이 **영영 안 열린다** | ✅ 기능은 정상, 보관기간만 초과 |
--   | 정리 예약의 역할 | **기능의 일부** | 개인정보 보관기간 지키기만 |
--
--   → 기능을 삭제 작업에 의존시키지 않는다. 사양서 §4-7 의 「하나가 실패해도 다른
--     하나는 진행되게」를 가장 확실하게 지키는 방법이다.
--   ⚠️ 대신 **보관기간 초과는 눈에 보여야 한다** — 작업 14 의 「밀린 파기 경고」와
--     같은 자리에 붙일 것(이번 범위 밖).
--
-- ============================================================
-- ④ ★ 시행일 전에는 담지 않는다
-- ============================================================
--   시행 전 잠금(353·354)은 **「얽힌 것이 있는 회원」만** 막는다. 즉 깨끗한 회원은
--   **시행일 전에도 확정된다.** 그대로 두면 개인정보처리방침 개정 **전에** 이메일
--   해시가 쌓인다 — 방침에 없는 항목을 수집·보관하는 것이 된다(사양서 §4-5 가 이
--   항목을 「탈퇴 시 파기의 **예외**라 반드시 명시」로 분류한 바로 그것).
--
--   → **담는 자리에만** `is_withdrawal_open()` 을 건다.
--   ⚠️ **가입 차단(362)에는 걸지 않는다** — 담긴 해시가 없으면 아무것도 안 막는다.
--     조건이 두 곳이면 어긋날 자리만 는다. 실패 방향도 안전하다(기록 안 함 = 안 막음).
--
-- ============================================================
-- ⑤ 같은 이메일이 두 번 탈퇴하면 — 반드시 「갱신」이어야 한다
-- ============================================================
--   🔴 그냥 넣기만 하면 두 번째 확정에서 중복 오류 → 파기 실패 → **확정 전이가
--     롤백**(352 의 설계) → 매일 재시도하며 **영원히 대기**한다.
--   → 있으면 **만료일을 늦은 쪽으로** 갱신한다.
--
-- ============================================================
-- ⑥ 원문 이메일은 어디에도 저장하지 않는다
-- ============================================================
--   243(관리자 비밀번호 찾기 기록)과 같은 이유다 — 이 표가 유출되면 **탈퇴한 회원의
--   이메일 명단**이 된다. 소문자·앞뒤 공백 제거 후 sha256 16진수 64자만 담는다.
--   ⚠️ 담을 때와 대조할 때 **같은 정규화**를 써야 한다. 한쪽에만 넣으면 대소문자만
--     바꿔 그대로 우회된다.
--   ⚠️ `a+1@gmail.com` 같은 **더하기 주소는 정규화하지 않는다** — 제공자마다 뜻이 달라
--     정규화하면 서로 다른 사람을 잘못 막는다. 사양서 §5 ④ 가 「우회를 늦추는 것이지
--     영구 차단이 아니다」로 이미 정한 수준이고, 이 한계를 감수한다.
--
-- ============================================================
-- ⑦ 되돌리기
-- ============================================================
--   SELECT cron.unschedule('withdrawal-email-blocks-retention-daily');
--   DROP TRIGGER IF EXISTS trg_withdrawal_email_block_capture ON public.influencers;
--   DROP FUNCTION IF EXISTS public.capture_withdrawal_email_block();
--   DROP FUNCTION IF EXISTS public.purge_expired_withdrawal_email_blocks();
--   DROP FUNCTION IF EXISTS public.is_email_withdrawal_blocked(text);
--   DROP FUNCTION IF EXISTS public._withdrawal_email_hash(text);
--   DROP TABLE IF EXISTS public.withdrawal_email_blocks;
--   ⚠️ 362 를 먼저 되돌린 뒤에 할 것.
--   기존 함수를 하나도 재정의하지 않으므로 이것으로 완전히 되돌아간다.
-- ============================================================

BEGIN;

-- ============================================================
-- [A] withdrawal_email_blocks — 탈퇴한 이메일의 해시
-- ============================================================
CREATE TABLE IF NOT EXISTS public.withdrawal_email_blocks (
  email_hash    text        PRIMARY KEY
                            CHECK (email_hash ~ '^[0-9a-f]{64}$'),
  blocked_until timestamptz NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.withdrawal_email_blocks IS
  '[361] 탈퇴가 확정된 회원의 이메일 해시. 같은 주소로 6개월간 다시 가입하지 못하게 '
  '막는 데 쓴다. ⚠️ **원문 이메일은 저장하지 않는다**(243 과 같은 이유 — 유출되면 '
  '탈퇴 회원 이메일 명단이 된다). ⚠️ 판정은 「행이 있나」가 아니라 「blocked_until 이 '
  '지났나」다 — 정리 예약이 멈춰도 6개월 지난 사람은 가입된다(위 헤더 ③).';

COMMENT ON COLUMN public.withdrawal_email_blocks.blocked_until IS
  '[361] 이 시각까지 가입을 막는다. 탈퇴가 **확정된 날**부터 6개월(신청일이 아니다 — '
  '지급 대기가 길면 몇 달 어긋난다). 같은 이메일이 다시 탈퇴하면 **늦은 쪽으로 갱신**된다.';

ALTER TABLE public.withdrawal_email_blocks ENABLE ROW LEVEL SECURITY;

-- 조회는 최고 관리자만. 쓰기 정책은 두지 않는다(함수 전용 — 243·217 과 같은 형태).
DROP POLICY IF EXISTS "withdrawal_email_blocks_select" ON public.withdrawal_email_blocks;
CREATE POLICY "withdrawal_email_blocks_select"
  ON public.withdrawal_email_blocks FOR SELECT
  TO authenticated
  USING (public.is_super_admin());

-- ============================================================
-- [B] 정규화 + 해시 — 담을 때와 대조할 때가 **같은 함수**를 쓴다
--
--   ⚠️ 이 함수가 하나여야 한다. 정규화를 두 곳에 각각 적으면 한쪽만 고쳐질 때
--     차단이 조용히 반쪽이 된다.
-- ============================================================
CREATE OR REPLACE FUNCTION public._withdrawal_email_hash(p_email text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $fn$
  SELECT encode(
    extensions.digest(lower(btrim(coalesce(p_email, ''))), 'sha256'),
    'hex'
  );
$fn$;

COMMENT ON FUNCTION public._withdrawal_email_hash(text) IS
  '[361] 이메일 → 정규화(소문자·앞뒤 공백 제거) → sha256 16진수 64자. 담는 쪽과 '
  '대조하는 쪽이 **반드시 이 함수 하나**를 쓴다 — 정규화가 두 곳에 각각 있으면 '
  '한쪽만 고쳐질 때 대소문자만 바꿔 우회된다. ⚠️ 더하기 주소(a+1@…)는 정규화하지 '
  '않는다(제공자마다 뜻이 달라 서로 다른 사람을 잘못 막는다).';

REVOKE ALL ON FUNCTION public._withdrawal_email_hash(text) FROM PUBLIC;

-- ============================================================
-- [C] 담기 — 이메일이 실제로 바뀌는 그 순간
--
--   ⚠️ `OF email` 을 붙여 이메일이 걸린 수정에서만 돈다(다른 칸을 고칠 때는 아예
--     호출되지 않는다).
-- ============================================================
CREATE OR REPLACE FUNCTION public.capture_withdrawal_email_block()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_placeholder CONSTANT text := 'withdrawn+' || OLD.id::text || '@deleted.reverbjp.invalid';
  v_hash        text;
BEGIN
  -- ① 이메일이 실제로 바뀌는 경우만
  IF NEW.email IS NOT DISTINCT FROM OLD.email THEN
    RETURN NEW;
  END IF;

  -- ② 탈퇴 종착 구간인 회원인가 — 358 의 판정을 그대로 쓴다(새 판단을 만들지 않는다).
  --    ⚠️ **미래 위험** — 관리자가 회원 이메일을 직접 고치는 화면이 생기면, 그 회원이
  --      탈퇴 종착 구간이면 옛 이메일이 **조용히 차단 목록에 담긴다**. 지금은 그런
  --      화면이 없어(코드로 확인) 영향이 없지만, 그런 화면을 만들 때 이 트리거를
  --      함께 볼 것.
  IF NOT public._withdrawal_account_blocked(OLD.id) THEN
    RETURN NEW;
  END IF;

  -- ③ 🔴 자리표시 주소를 해시하려는 시도는 **소리 내며 멈춘다**(위 헤더 ②).
  --    여기 걸리면 파기가 실패하고 확정 전이가 롤백돼 매일 로그에 남는다 —
  --    「아무도 안 막히는데 아무 오류도 없는」 조용한 무효보다 훨씬 낫다.
  IF OLD.email = v_placeholder THEN
    RAISE EXCEPTION
      'withdrawal_email_block_order: 이미 파기된 이메일을 해시하려 했습니다(회원 %). 담는 시점이 파기보다 뒤로 밀렸습니다.',
      OLD.id
      USING ERRCODE = 'P0001';
  END IF;

  -- ④ 시행일 전에는 담지 않는다(위 헤더 ④)
  IF NOT public.is_withdrawal_open() THEN
    RETURN NEW;
  END IF;

  v_hash := public._withdrawal_email_hash(OLD.email);

  -- ⑤ 있으면 **늦은 쪽으로 갱신**(위 헤더 ⑤ — 그냥 넣으면 확정이 영원히 롤백된다)
  INSERT INTO public.withdrawal_email_blocks (email_hash, blocked_until)
  VALUES (v_hash, now() + interval '6 months')
  ON CONFLICT (email_hash) DO UPDATE
    SET blocked_until = GREATEST(public.withdrawal_email_blocks.blocked_until,
                                 EXCLUDED.blocked_until),
        updated_at    = now();

  RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION public.capture_withdrawal_email_block() IS
  '[361] 탈퇴 확정으로 회원 이메일이 자리표시 주소로 바뀌는 **그 순간** 옛 이메일의 '
  '해시를 담는다. 파기 함수(352)를 한 글자도 안 건드리려고 이 자리를 골랐다. '
  '⚠️ 이미 파기된 주소를 해시하려 하면 예외를 던져 확정을 롤백시킨다 — 순서가 '
  '어긋났을 때 조용히 무효가 되지 않게. ⚠️ 시행일 전에는 담지 않는다(방침 개정 전에 '
  '방침에 없는 항목을 보관하지 않기 위해). ⚠️ 같은 이메일이 다시 탈퇴하면 만료일을 '
  '늦은 쪽으로 갱신한다(그냥 넣으면 중복 오류로 확정이 영원히 롤백된다).';

DROP TRIGGER IF EXISTS trg_withdrawal_email_block_capture ON public.influencers;
CREATE TRIGGER trg_withdrawal_email_block_capture
  BEFORE UPDATE OF email ON public.influencers
  FOR EACH ROW EXECUTE FUNCTION public.capture_withdrawal_email_block();

-- 352 를 읽는 사람이 「여기에 트리거도 붙어 있다」를 알 수 있게 설명만 갈아 끼운다.
--   ⚠️ **함수 본문은 건드리지 않는다** — 설명만 바꾸는 것이라 동작 위험이 없다.
COMMENT ON FUNCTION public.purge_withdrawn_personal_data(uuid) IS
  '[352 · 설명만 361 에서 갱신] 탈퇴가 확정된 회원의 개인정보를 파기한다 — 18개 칸을 '
  '비우고 회원 행·로그인 계정의 이메일 4곳을 자리표시 주소로 바꾼다. 행은 지우지 않는다. '
  '⚠️ **이 함수가 이메일을 바꾸는 순간 `influencers` 에 붙은 트리거 '
  '`trg_withdrawal_email_block_capture`(361)가 함께 돈다** — 옛 이메일의 해시를 담아 '
  '6개월 재가입 차단에 쓴다. 이 함수를 재정의할 때 그 트리거의 존재를 잊지 말 것. '
  '⚠️ 관리자를 겸한 회원은 파기하지 않고 눈에 보이게 실패시킨다(admin_account_excluded).';

-- ============================================================
-- [D] 대조 — 가입 화면과 차단 장치가 함께 쓴다
--
--   ⚠️ 익명(비로그인)에게도 실행 권한을 준다 — 가입 전이라 로그인 정보가 없다.
--   ⚠️ 원문 이메일을 **인자로만 받고 어디에도 저장하지 않는다**.
--   ⚠️ 참·거짓만 돌려준다 — 만료일을 돌려주면 탈퇴 확정 날짜가 계산돼 나온다.
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_email_withdrawal_blocked(p_email text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM public.withdrawal_email_blocks b
     WHERE b.email_hash = public._withdrawal_email_hash(p_email)
       AND b.blocked_until > now()   -- 위 헤더 ③ — 행이 남아 있어도 만료면 통과
  );
$fn$;

COMMENT ON FUNCTION public.is_email_withdrawal_blocked(text) IS
  '[361] 이 이메일이 지금 재가입 차단 중인가(참·거짓만). 가입 화면과 362 의 차단 '
  '장치가 함께 쓴다. ⚠️ 만료일이 지났으면 행이 남아 있어도 **거짓**이다 — 정리 예약이 '
  '멈춰도 재가입이 열린다. ⚠️ 만료일은 반환하지 않는다(탈퇴 확정 날짜가 역산된다). '
  '⚠️ 원문 이메일은 인자로만 받고 저장하지 않는다. 비로그인 사용자도 부를 수 있다 '
  '— 가입 전이라 로그인 정보가 없다. 관리자가 「이 이메일이 막혀 있나」를 확인할 때도 '
  '같은 함수를 쓴다(해시만 저장하므로 표를 눈으로 봐서는 알 수 없다).';

REVOKE ALL ON FUNCTION public.is_email_withdrawal_blocked(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_email_withdrawal_blocked(text) TO anon, authenticated;

-- ============================================================
-- [E] 보관기간 정리 — 6개월 지난 해시를 지운다
--
--   ⚠️ 이 예약이 멈춰도 **기능은 정상**이다(위 헤더 ③). 여기서 하는 일은
--     개인정보 보관기간을 지키는 것뿐이다.
-- ============================================================
CREATE OR REPLACE FUNCTION public.purge_expired_withdrawal_email_blocks()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE v_deleted integer;
BEGIN
  DELETE FROM public.withdrawal_email_blocks
   WHERE blocked_until <= now();
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RAISE NOTICE '[361] 보관기간이 끝난 재가입 차단 해시 %건 삭제', v_deleted;
  RETURN v_deleted;
END;
$fn$;

COMMENT ON FUNCTION public.purge_expired_withdrawal_email_blocks() IS
  '[361] 6개월이 지난 재가입 차단 해시를 지운다(개인정보 보관기간 준수). '
  '⚠️ 이 함수가 멈춰도 **재가입은 정상으로 열린다** — 판정이 만료일 기준이기 때문이다. '
  '여기서 하는 일은 보관기간을 지키는 것뿐이고, 밀리면 작업 14 의 경고에 드러내야 한다.';

REVOKE ALL ON FUNCTION public.purge_expired_withdrawal_email_blocks() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purge_expired_withdrawal_email_blocks() TO postgres;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 예약 등록 (트랜잭션 밖 — cron.schedule 은 자체 커밋)
--
--   시간표(한국·일본 시각): 04:00 위반기록 정리 / 04:15 비밀번호찾기 정리 /
--     **04:30 — 캠페인 보관 삭제 정리(258) · 행사 티켓 정리(286) · 이 파일** /
--     04:45 탈퇴 상태 전이
--   ⚠️ **04:30 은 비어 있지 않다** — 이미 둘이 돌고 있고 이것이 셋째다. 이름이 달라
--     서로를 덮어쓰지는 않고 셋 다 가벼운 삭제라 충돌 가능성은 낮지만, **적용 후 셋이
--     같이 돈 다음 날 한 번은 결과를 확인**할 것(2026-08-20 검토 지적 — 이 자리에
--     「04:30 이 파일 전용」이라 잘못 적혀 있었다).
-- ============================================================
SELECT cron.unschedule(jobid)
  FROM cron.job
 WHERE jobname = 'withdrawal-email-blocks-retention-daily';

SELECT cron.schedule(
  'withdrawal-email-blocks-retention-daily',
  '30 19 * * *',
  $cron$ SELECT public.purge_expired_withdrawal_email_blocks(); $cron$
);

-- ============================================================
-- 검증 (개발 데이터베이스 적용 후)
--
-- ⚠️ 이 파일은 **가입을 막지 않는다** — 해시가 쌓이는 것만 확인하면 된다.
--    막는 것은 362 다.
-- ============================================================
/*

-- ── SQL 편집기 ──────────────────────────────────────────────

-- [V0] 표·함수·예약이 생겼나
SELECT to_regclass('public.withdrawal_email_blocks') AS "표";
SELECT jobname, schedule, active FROM cron.job
 WHERE jobname = 'withdrawal-email-blocks-retention-daily';
-- 기대: 표 있음 · 예약 '30 19 * * *' 활성

-- [V1] ★ 해시 함수가 실제로 도는가 (자료형 오류는 첫 호출에서만 드러난다)
SELECT public._withdrawal_email_hash('  TEST@Example.com ') AS "해시",
       public._withdrawal_email_hash('test@example.com')    AS "같아야_함";
-- 기대: 두 값이 **같다**(대소문자·공백 정규화 확인) · 16진수 64자

-- [V2] 대조 함수 — 아직 담긴 것이 없으니 거짓
SELECT public.is_email_withdrawal_blocked('test@example.com') AS "막혀있나";
-- 기대: false

-- [V3] 정리 함수가 도는가 (지울 것이 없어도 오류 없이 0 반환)
SELECT public.purge_expired_withdrawal_email_blocks() AS "삭제건수";
-- 기대: 0

-- ── ★ 실제로 담기는지 (시험 계정 필요) ──────────────────────

-- [V4] 시행일이 비어 있으면 **안 담긴다**(헤더 ④)
--   지금 시행일은 NULL 이므로, 시험 계정을 확정까지 굴려도 해시가 0건이어야 한다.
--   시험 계정으로 탈퇴 신청 → 서비스 키로 scheduled_date 를 어제로 →
--   SELECT public.advance_withdrawal_states();
--   SELECT count(*) FROM public.withdrawal_email_blocks;   -- 기대: 0

-- [V5] ★ 시행일을 어제로 넣고 다시 — 이번엔 담겨야 한다
--   UPDATE public.withdrawal_settings
--      SET effective_date = (now() AT TIME ZONE 'Asia/Tokyo')::date - 1 WHERE id = 1;
--   (다른 시험 계정으로 [V4] 반복)
--   SELECT email_hash, blocked_until FROM public.withdrawal_email_blocks;
--   기대: 1행 · blocked_until 이 오늘부터 약 6개월 뒤
--   그리고 그 계정의 **원래 이메일**로 대조:
--   SELECT public.is_email_withdrawal_blocked('<원래 이메일>');   -- 기대: true
--   대소문자를 바꿔서도:
--   SELECT public.is_email_withdrawal_blocked('<원래 이메일 대문자>');  -- 기대: true

-- [V6] ★ 같은 이메일이 두 번 확정돼도 오류가 없는가 (헤더 ⑤)
--   위에서 담긴 해시를 그대로 둔 채, 같은 이메일을 쓰는 다른 시험 계정을 확정까지 굴린다.
--   기대: **오류 없이** blocked_until 이 늦은 쪽으로 갱신되고, withdrawal_requests 의
--         status 가 'done' 으로 **남아 있다**(롤백되지 않았다)

-- [V7] 탈퇴를 취소하면 안 담긴다
--   시험 계정으로 신청 → 취소 → 해시 0건 유지

-- [V8] 만료되면 통과 (헤더 ③ — 정리 예약을 안 돌려도)
--   UPDATE public.withdrawal_email_blocks SET blocked_until = now() - interval '1 day';
--   SELECT public.is_email_withdrawal_blocked('<그 이메일>');   -- 기대: false
--   (행은 그대로 남아 있어도 false 여야 한다)

-- [V9] 시험 데이터 정리
--   DELETE FROM public.withdrawal_email_blocks;
--   UPDATE public.withdrawal_settings SET effective_date = NULL WHERE id = 1;
--   SELECT public.is_withdrawal_open();   -- 기대: false (원상 복구 확인)

*/
