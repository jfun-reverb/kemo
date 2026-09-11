-- ============================================================
-- 398. 회원이 자기 계정의 「감사용」 표시를 켤 수 없게 한다
-- ============================================================
-- 전수조사(2차) 묶음 A — A-3.
-- 조사 근거: docs/research/2026-09-02-codebase-audit-findings.md §1-3
-- 조치 계획: docs/specs/2026-09-02-audit-remediation-plan.md 「묶음 A」
--
-- ── 무엇이 문제였나 ────────────────────────────────────────
-- 회원 본인 수정 정책(313)은 `USING (auth.uid()=id) WITH CHECK (auth.uid()=id)`
-- 뿐이고 **어느 칸을 고칠 수 있는지는 안 본다.** 그래서 브라우저 개발자 도구로
-- 자기 행의 `is_audit` 을 켜면 그대로 저장된다.
--
-- 켜지면 무슨 일이 생기나(179):
--   ① 정원이 찬 리뷰어 캠페인의 **정원 검사를 맨 앞에서 통과**한다
--   ② 응모 수·`applied_count`·대시보드·운영현황·엑셀·정산 자동 등록에서
--      **통째로 빠진다**(광고주에게 보고하는 수치가 조용히 어긋난다)
--   ③ 🔴 관리자가 「감사용 흔적 청소」(`purge_audit_data_all`)를 누르면
--      **그 회원의 진짜 응모·결과물·메시지·알림이 지워진다.** 되돌릴 수 없다.
--
-- ── 실측 (2026-09-03 운영) ────────────────────────────────
--   `is_audit = true` 행 **1개**, 그것이 운영팀 자기 계정(이름이 감사용 계열).
--   그 계정의 응모 **0건**. → **소급 정리할 것이 없다.** 이 조치는 앞으로만 막는다.
--
-- ── 왜 059 를 그대로 베끼지 않았나 (중요) ──────────────────
-- 059 가 인증·블랙리스트 8칸을 지키는 방식과 **모양은 같지만 통과 조항이 다르다.**
--
-- 🔴 059 의 판정은 「`auth.uid()` 가 campaign_admin 이상인가」뿐이라,
--    **로그인 정보가 없는 경로(service_role · SQL 편집기 · 예약 실행)는 거부**된다.
--    그런데 `is_audit` 은 **그 경로로만 설정된다** — 이 값을 켜고 끄는 화면이
--    저장소 전체에 **한 곳도 없다**(2026-09-03 전수 확인, 읽기만 12곳).
--    059 를 그대로 베끼면 **유일한 설정 경로가 막혀** 새 감사용 계정을 만들 수 없다.
--
-- → 그래서 통과 조항이 **둘**이다(359 의 탈퇴 차단 장치와 같은 형태):
--     ① `auth.uid() IS NULL`  — service_role · SQL 편집기 · 예약 실행
--     ② `is_campaign_admin()` — 관리자 화면에서 부를 때(지금은 부르는 곳이 없다)
--
-- ⚠️ ①이 구멍이 아닌 이유 — 익명(anon)은 `influencers` 를 **UPDATE 할 수 없다**.
--    본인 수정 정책이 `auth.uid() = id` 를 요구하므로 로그인 없는 쓰기는
--    정책 단계에서 이미 막힌다. 즉 여기 도달하는 NULL 은 서비스 키뿐이다.
--
-- 🔴 **①을 지우면 새 감사용 계정을 영영 못 만든다.** 지우지 말 것.
--
-- ── 왜 059 함수를 확장하지 않았나 ─────────────────────────
-- `guard_influencer_flag_columns()` 에 칸 하나를 더하는 편이 짧지만, 그렇게 하면
-- **기존 8칸의 판정까지 함께 바뀐다**(위 통과 조항 ①이 8칸에도 붙는다).
-- 그것은 A-3 의 범위 밖 동작 변경이라 **별도 트리거**로 뒀다.
-- ⚠️ 나중에 8칸 쪽도 같은 이유로 풀어야 한다는 판단이 서면 그때 합칠 것.
--
-- ⚠️ 트리거 이름을 `trg_guard_influencer_is_audit` 로 지었다 —
--    `influencers` BEFORE UPDATE 에는 이미 셋이 붙어 있다
--    (`trg_account_withdrawn_guard`(359) · `guard_influencer_flag_columns`(059) ·
--     `lock_influencer_birthdate`(180)). 이 트리거는 **거부만 하고 값을 안 바꾸므로**
--    실행 순서가 결과를 바꾸지 않는다.
-- ============================================================

CREATE OR REPLACE FUNCTION public.guard_influencer_is_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 값이 안 바뀌면 볼 것이 없다(대부분의 UPDATE 가 여기서 끝난다)
  IF NEW.is_audit IS NOT DISTINCT FROM OLD.is_audit THEN
    RETURN NEW;
  END IF;

  -- 통과 ① — 로그인 정보가 없는 경로(service_role · SQL 편집기 · 예약 실행).
  --          익명 쓰기는 본인 수정 정책에서 이미 막혀 여기 도달하지 않는다.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- 통과 ② — 캠페인 관리자 이상
  IF public.is_campaign_admin() THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION '감사용 표시는 관리자만 변경할 수 있습니다.'
    USING ERRCODE = 'insufficient_privilege';
END;
$$;

COMMENT ON FUNCTION public.guard_influencer_is_audit() IS
  '[398] influencers.is_audit 변경을 관리자(또는 서비스 키)로 제한. '
  '회원이 개발자 도구로 자기 행의 이 칸을 켜면 정원 검사를 통과하고 통계에서 빠지며, '
  '관리자의 「감사용 흔적 청소」가 그 회원의 진짜 기록을 지운다. SECURITY DEFINER.';

DROP TRIGGER IF EXISTS trg_guard_influencer_is_audit ON public.influencers;
CREATE TRIGGER trg_guard_influencer_is_audit
  BEFORE UPDATE ON public.influencers
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_influencer_is_audit();


-- ============================================================
-- 검증
-- ============================================================
-- 🔴 **그냥 편집기로는 차단을 재현할 수 없다** — 편집기는 서비스 키로 돌아
--    `auth.uid()` 가 NULL 이라 **통과 ①로 빠져나간다**(마이그레이션 272·332 와 같은 함정).
--
-- ✅ **그런데 흉내 낼 수는 있다.** `auth.uid()` 는 `request.jwt.claims` 의 `sub` 를 읽으므로,
--    트랜잭션 안에서 그 설정을 세우면 **트리거가 「로그인한 회원」으로 본다.**
--    ⚠️ 행 단위 보안 정책은 여전히 우회된다(서비스 키) — 여기서 시험하는 것은 **트리거뿐**이다.
--
-- [V1] 트리거가 붙었는가
/*
SELECT tgname, tgenabled
  FROM pg_trigger
 WHERE tgrelid = 'public.influencers'::regclass AND NOT tgisinternal
 ORDER BY tgname;
-- 기대: trg_guard_influencer_is_audit 있고 tgenabled = 'O'
*/
--
-- [V2] 🔴 회원이 자기 것을 켜면 막히는가 (핵심)
/*
DO $v$
DECLARE v_id uuid; v_msg text := '';
BEGIN
  SELECT id INTO v_id FROM public.influencers WHERE is_audit = false LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_id)::text, true);
  BEGIN
    UPDATE public.influencers SET is_audit = true WHERE id = v_id;
    v_msg := v_msg || 'V2=🔴막지못함! | ';
  EXCEPTION WHEN others THEN
    v_msg := v_msg || 'V2=' || SQLERRM || ' | ';
  END;
  -- V3: 같은 회원의 **평범한 수정**은 통과해야 한다 (과잉 차단 확인)
  BEGIN
    UPDATE public.influencers SET name = name WHERE id = v_id;
    v_msg := v_msg || 'V3=통과(정상) | ';
  EXCEPTION WHEN others THEN
    v_msg := v_msg || 'V3=🔴' || SQLERRM || ' | ';
  END;
  -- V4: 로그인 정보를 지우면(서비스 키 경로) 통과해야 한다
  PERFORM set_config('request.jwt.claims', '', true);
  BEGIN
    UPDATE public.influencers SET is_audit = true WHERE id = v_id;
    v_msg := v_msg || 'V4=통과(정상)';
  EXCEPTION WHEN others THEN
    v_msg := v_msg || 'V4=🔴' || SQLERRM;
  END;
  RAISE EXCEPTION '결과: %', v_msg;   -- 예외로 전부 되돌린다
END $v$;
*/
-- 기대: V2=감사용 표시는 관리자만 변경할 수 있습니다 · V3=통과 · V4=통과
-- ⚠️ **V3 를 반드시 함께 본다** — 거부만 확인하면 「과하게 걸린 트리거」를 못 잡는다.
-- ⚠️ 마지막 `RAISE EXCEPTION` 이 트랜잭션을 되돌리므로 데이터는 안 바뀐다.
--
-- [V5] 실제 로그인 브라우저에서도 한 번 (개발서버 시험 계정)
/*
   await db.from('influencers').update({ is_audit: true })
     .eq('id', (await db.auth.getUser()).data.user.id);
   // 기대: error.code = '42501'
*/
-- ⚠️ V2 는 흉내이고 V5 가 진짜다. 다만 V2 로 **분기 셋을 한 번에** 볼 수 있어
--    먼저 V2 로 걸러 내고 V5 로 확인하는 편이 빠르다.


-- ============================================================
-- 롤백
-- ============================================================
-- DROP TRIGGER IF EXISTS trg_guard_influencer_is_audit ON public.influencers;
-- DROP FUNCTION IF EXISTS public.guard_influencer_is_audit();
