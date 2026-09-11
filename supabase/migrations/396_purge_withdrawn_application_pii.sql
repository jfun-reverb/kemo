-- ============================================================
-- 396. 탈퇴 확정 파기가 응모 기록의 개인정보도 비우게 한다
--
-- 무엇이 문제였나
--   352 의 purge_withdrawn_personal_data() 는 influencers · auth.users ·
--   auth.identities · withdrawal_requests 네 곳만 비운다. 그런데 회원이
--   캠페인에 응모할 때 이름·이메일·SNS 계정·배송지가 applications 표에도
--   **복사돼** 들어간다(dev/js/application.js 의 insertApplication 호출).
--   그 사본을 아무도 지우지 않아, 탈퇴가 확정된 회원의 실명과 집 주소가
--   관리자 화면(신청 관리 · 신청자 엑셀 · 캠페인 진행현황)에 계속 보였다.
--
-- 🔴 결정이 아니라 누락이다 — 근거 셋
--   ① 352 파일에 `applications` 라는 낱말이 **한 번도 안 나온다**
--   ② 352 는 「안 비우는 것(의도적)」 목록을 따로 갖고 있는데(생년월일·
--      성별 / 팔로워·bio·category·primary_sns / is_verified·blacklisted·
--      marketing_* / PayPal 5년 · 결과물 이미지 6개월 · 이메일 해시 6개월)
--      **응모 기록이 그 목록에 없다**
--   ③ 사양서 §4-7 표 마지막 줄이 정반대를 약속한다 —
--      「응모 · 결과물 · 정산 · 메시지(기록 자체)는 안 지운다.
--        **사람을 특정할 수 없게 된 상태로 남는다**」
--
-- 실측 (2026-09-02 운영)
--   확정 탈퇴 2명 · 그중 응모 이력이 있는 사람 **1명** · 그 사람의 응모
--   **2건**에 이메일·이름·SNS 계정·주소가 **전부** 남아 있었다.
--   같은 회원의 influencers 행은 **이미 익명화**돼 있었다(플레이스홀더
--   이메일 확인) — 이 표만 빠졌다는 직접 증거다.
--   ⚠️ 그 2건은 이 마이그레이션 적용 **전에 손으로 정리**했다. 이 함수는
--   확정되는 순간에만 돌아 과거분에 소급되지 않기 때문이다.
--
-- 무엇을 바꾸나
--   함수 본문에 「8. applications」 절 하나를 더한다. 그 외 1~7 절과
--   반환값·DECLARE 는 352 와 **글자 단위로 같다**(352 의 343~462 행을
--   그대로 떼어 썼다).
--
-- 🔴 CREATE OR REPLACE 를 쓴다 — DROP 후 CREATE 하면 369 가 건
--   `REVOKE EXECUTE … FROM anon, authenticated` 가 **아무 표시 없이
--   풀린다**. 이 함수는 호출자 검사가 전혀 없어(352 자체 경고), 권한이
--   유일한 방어선이다. 풀리면 로그인한 회원 누구나 **아무 회원 고유번호나
--   넘겨 남의 개인정보를 지울 수 있다.**
--
-- 베이스: 352 (직접 전수 확인 — 353·354·361·369 는 이 함수를 언급만 하고
--   재정의하지 않는다. `CREATE … FUNCTION public.purge_withdrawn_personal_data`
--   를 가진 파일은 352 하나뿐)
--
-- 사양서 docs/specs/2026-08-18-member-withdrawal.md §4-7
-- ============================================================

CREATE OR REPLACE FUNCTION public.purge_withdrawn_personal_data(
  p_influencer_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_inf                 public.influencers%ROWTYPE;
  v_placeholder_email    text;
  v_identities_updated   integer;
BEGIN
  -- 0. 잠금 — advance_withdrawal_states() 가 이미 같은 트랜잭션 안에서
  --    influencers 를 FOR UPDATE 로 잠근 뒤 이 함수를 부르지만(349/350
  --    이 세운 "influencers 먼저" 잠금 순서), 이 함수를 단독 호출(예:
  --    SQL 편집기 검증)해도 안전하도록 스스로 다시 잠근다. 같은
  --    트랜잭션 안에서 같은 행을 다시 FOR UPDATE 하는 것은 PostgreSQL
  --    이 그대로 허용한다(교착 아님 — 자기 자신이 이미 쥔 잠금).
  SELECT * INTO v_inf FROM public.influencers WHERE id = p_influencer_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  -- 1. 플레이스홀더를 먼저 계산한다 — [2026-08-19 갱신] influencers.email
  --    도 이 값으로 채우기로 바뀌면서(위 헤더 「②」·「④」 갱신 참고),
  --    아래 2절(멱등 확인)이 이 값과 현재 email 을 직접 비교해야 하므로
  --    순서를 앞으로 옮겼다. influencer_id 로 결정적으로 나오는 값이라
  --    몇 번을 다시 계산해도 항상 같다(부작용 없음).
  v_placeholder_email := 'withdrawn+' || p_influencer_id::text || '@deleted.reverbjp.invalid';

  -- 2. 멱등 — 이미 파기됐으면 다시 손대지 않는다. [2026-08-19 갱신]
  --    influencers.email 이 이제 NULL 이 아니라 플레이스홀더로 채워지므로
  --    (아래 5절), "이미 파기됐다"의 판정도 "email 이 이 회원의 플레이스
  --    홀더 값과 정확히 같은가"로 바꿨다 — NULL 판정보다 더 엄밀하다
  --    (다른 회원의 값과 절대 우연히 일치하지 않는다, 값 자체가
  --    influencer_id 를 담고 있으므로).
  IF v_inf.email = v_placeholder_email THEN
    RETURN jsonb_build_object('ok', true, 'already_purged', true);
  END IF;

  -- 3. 감사용 계정 방어(비정상 경로 방어 — 정상 흐름에서는 347/350 이
  --    request_withdrawal 단계에서 이미 거부해 여기 도달할 수 없다.
  --    349 파일의 같은 판단을 그대로 계승).
  IF v_inf.is_audit THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'audit_account_blocked');
  END IF;

  -- 4. 관리자를 겸한 회원 방어(위 헤더 「③」 — 사양서 범위 밖 시나리오를
  --    조용히 밟지 않기 위한 이 마이그레이션의 독자적 판단).
  IF EXISTS (SELECT 1 FROM public.admins WHERE auth_id = p_influencer_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_account_excluded');
  END IF;

  -- 5. influencers — §4-7 표 그대로 칸 비우기 + email 은 바꿔치기(위
  --    헤더 「④」 갱신 절 — [2026-08-19] NOT NULL 제약이 있는 유일한
  --    칸이라 NULL 대신 아래 6절과 정확히 같은 플레이스홀더를 넣는다).
  UPDATE public.influencers
     SET name              = NULL,
         name_kanji         = NULL,
         name_kana          = NULL,
         phone              = NULL,
         zip                = NULL,
         prefecture         = NULL,
         city               = NULL,
         address            = NULL,
         building           = NULL,
         ig                 = NULL,
         ig_followers       = NULL,
         x                  = NULL,
         x_followers        = NULL,
         tiktok             = NULL,
         tiktok_followers   = NULL,
         youtube            = NULL,
         youtube_followers  = NULL,
         line_id            = NULL,
         email              = v_placeholder_email
   WHERE id = p_influencer_id;

  -- 6. auth.users — 이메일 바꿔치기(컬럼 + raw_user_meta_data JSON 안의
  --    email 키, 위 헤더 「④」 — 둘 다 auth.users 소속이라 함께 다룬다).
  UPDATE auth.users
     SET email              = v_placeholder_email,
         raw_user_meta_data = jsonb_set(
                                 COALESCE(raw_user_meta_data, '{}'::jsonb),
                                 '{email}',
                                 to_jsonb(v_placeholder_email),
                                 true
                               )
   WHERE id = p_influencer_id;

  -- 7. auth.identities — identity_data 안의 email 도 함께(마이그레이션
  --    245 선례). provider_id 는 user_id::text 라 이메일과 무관 — 손대지
  --    않는다(012·029·031·179·245 전부 이 구조를 재확인함, 위 헤더 참고).
  UPDATE auth.identities
     SET identity_data = jsonb_set(
                            COALESCE(identity_data, '{}'::jsonb),
                            '{email}',
                            to_jsonb(v_placeholder_email),
                            true
                          )
   WHERE user_id = p_influencer_id
     AND provider = 'email';
  GET DIAGNOSTICS v_identities_updated = ROW_COUNT;
  -- ⚠️ v_identities_updated 가 0이어도 이 함수는 실패시키지 않는다 —
  --   아주 오래된 계정에 identities 행이 애초에 없던 이력이 이 저장소에
  --   실제로 있었다(179 파일 주석 "일부 Supabase 버전은..." 참고). 그런
  --   경우 email/password 로그인 자체가 원래 안 됐을 사람이라 identities
  --   가 없다고 해서 이 함수를 실패시킬 이유가 없다 — 반환값에 그
  --   개수를 실어 진단 가능하게만 한다.


  -- 8. applications — 응모 기록에 복사돼 들어간 개인정보 칸을 비운다.
  --    ⚠️ **행은 지우지 않는다.** 사양서 §4-7 표 마지막 줄이 「응모 ·
  --    결과물 · 정산 · 메시지(기록 자체)는 안 지운다 — **사람을 특정할 수
  --    없게 된 상태로 남는다**」고 정한 그대로다. 비우는 것은 「사람을
  --    특정하는 값」뿐이다.
  --
  --    🔴 이 절이 352 에 없던 것은 **결정이 아니라 누락**이다. 근거 셋:
  --      · 352 는 `applications` 를 **한 번도 언급하지 않는다**(전수 확인)
  --      · 352 의 「안 비우는 것(의도적)」 목록에 응모 기록이 **없다**
  --        (그 목록은 생년월일·성별 / 팔로워·bio·category·primary_sns /
  --         is_verified·blacklisted·marketing_* / 5년·6개월 항목뿐이다)
  --      · §4-7 이 정반대(「특정할 수 없게」)를 약속한다
  --    실측(2026-09-02 운영): 확정 탈퇴 2명 중 응모 이력이 있는 **1명**의
  --    응모 **2건**에 이메일·이름·SNS 계정·주소가 **전부 남아 있었다**.
  --    같은 회원의 `influencers` 행은 **이미 익명화돼 있었다** — 이 표만
  --    빠졌다는 증거다. 그 2건은 이 마이그레이션 적용 전에 손으로 정리했다
  --    (이 함수는 확정되는 순간에만 도므로 과거분에 소급되지 않는다).
  --
  --    ⚠️ `user_email` 은 NULL 이 아니라 **5절과 정확히 같은 플레이스홀더**로
  --    바꾼다. 관리자 화면이 **이 값으로 회원 기록을 찾기** 때문이다
  --    (`admin-applications.js` 의 `_users.find(x => x.email === a.user_email)`).
  --    NULL 로 두면 그 연결이 끊겨 목록에서 이름을 눌러도 아무 데도 못 가고
  --    감사용·상태 배지도 안 뜬다. 두 곳이 같은 값이라 계속 맞물린다
  --    (5절이 `influencers.email` 에 같은 값을 넣는 이유와 동일).
  --
  --    ⚠️ `user_followers` 는 **안 비운다** — 5절이 `influencers` 의 집계
  --    팔로워 칸을 남기는 것과 같은 이유다(352 「안 비우는 것」 목록).
  --
  --    ⚠️ `message` 는 **안 비운다** — 회원이 캠페인에 지원하며 쓴 글이지
  --    프로필 사본이 아니다. §4-7 의 「기록 자체는 남는다」에 해당한다.
  --    실측한 2건도 지원 동기 문장이었고 이름·주소·연락처가 없었다.
  --    🔴 다만 **자유 입력이라 앞으로 개인정보가 들어갈 수 있다** — 그런
  --    사례가 나오면 이 판단을 다시 봐야 한다. 지금 비우지 않는 것은
  --    「비울 필요가 없다」가 아니라 「지금까지의 실측으로는 특정 정보가
  --    없다」는 뜻이다.
  --
  --    ⚠️ `applications` 에는 삽입 시 검사 트리거가 여럿 붙어 있으나
  --    (연령 180 · 마감 326 · 탈퇴 계정 359) **전부 BEFORE INSERT** 라
  --    이 UPDATE 에는 걸리지 않는다. 상태를 안 바꾸므로 상태 변경 감사
  --    트리거(`trg_application_status_event`)·정산 자동 보류(320)·
  --    송금완료 반려 가드(247)도 발동하지 않는다.
  UPDATE public.applications
     SET user_email = v_placeholder_email,
         user_name  = NULL,
         user_ig    = NULL,
         address    = NULL
   WHERE user_id = p_influencer_id;
  RETURN jsonb_build_object(
    'ok',                 true,
    'already_purged',     false,
    'placeholder_email',  v_placeholder_email,
    'identities_updated', v_identities_updated
  );
END;
$$;

COMMENT ON FUNCTION public.purge_withdrawn_personal_data(uuid) IS
  '[396, 베이스 352] 회원 탈퇴 확정(status=done) 시 개인정보를 비운다(행은 지우지 '
  '않는다 — settlement_events ON DELETE RESTRICT). 352 의 1~7 절(influencers 18개 '
  '칸 NULL + email 플레이스홀더 교체, auth.users, auth.identities, 멱등·감사용·'
  '관리자 겸직 방어)에 **8절(applications)** 을 더했다 — 응모 기록에 복사돼 들어간 '
  'user_email(플레이스홀더로 교체) · user_name · user_ig · address 를 비운다. '
  '352 가 이 표를 빠뜨려 탈퇴 확정 회원의 실명·주소가 관리자 화면에 계속 보였다'
  '(2026-09-02 운영 실측: 응모 2건 전부 잔존). user_followers 와 message 는 '
  '일부러 안 비운다(각각 집계 칸 / 회원이 쓴 지원 동기 — 파일 주석 8절 참고). '
  'PayPal(5년)·재가입 차단 해시·결과물 이미지·메시지 첨부(각 6개월)는 여전히 이 '
  '함수의 범위가 아니다.';

-- 권한 — 352 가 건 것을 그대로 다시 못 박는다. CREATE OR REPLACE 는 ACL 을
-- 보존하므로 369 의 `REVOKE … FROM anon, authenticated` 는 살아 있다(아래
-- [V-3] 로 확인할 것). 아래 두 줄은 그것을 되돌리지 않는다 —
-- `REVOKE ALL FROM PUBLIC` 은 역할별 개별 부여를 건드리지 못하기 때문이다
-- (CLAUDE.md 「함수 실행 권한 — 회수 방향이 둘이다」).
REVOKE ALL ON FUNCTION public.purge_withdrawn_personal_data(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purge_withdrawn_personal_data(uuid) TO postgres;

-- ============================================================
-- [V] 적용 뒤 확인 — 순서대로 돌릴 것
-- ============================================================
--
-- [V-1] 함수에 8절이 실제로 들어갔나 (1 이어야 정상)
--   select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--    where n.nspname='public' and p.proname='purge_withdrawn_personal_data'
--      and p.prosrc like '%public.applications%';
--
-- [V-2] 양성 대조 — 352 의 기존 절이 그대로 살아 있나 (둘 다 1 이어야 정상)
--   select count(*) filter (where p.prosrc like '%auth.identities%') as identities,
--          count(*) filter (where p.prosrc like '%admin_account_excluded%') as admin_guard
--     from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--    where n.nspname='public' and p.proname='purge_withdrawn_personal_data';
--
-- [V-3] 🔴 369 의 회수가 살아 있나 — proacl 에 anon/authenticated 가 **없어야**
--   하고 맨 앞이 `=X/` 로 시작하지 **않아야** 한다(그러면 PUBLIC 이 열린 것)
--   select p.proacl::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--    where n.nspname='public' and p.proname='purge_withdrawn_personal_data';
--
-- [V-4] 완료 기준 — 확정 탈퇴 회원의 응모에 개인정보가 0건이어야 한다.
--   ⚠️ apps_total 을 함께 보는 것이 양성 대조다(0 이면 조회가 안 돈 것)
--   select (select count(*) from public.applications) as apps_total,
--          count(*) as apps_of_withdrawn,
--          count(*) filter (where coalesce(a.user_name,'')<>'')  as name_left,
--          count(*) filter (where coalesce(a.user_ig,'')<>'')    as ig_left,
--          count(*) filter (where coalesce(a.address,'')<>'')    as addr_left,
--          count(*) filter (where a.user_email not like 'withdrawn+%') as real_email_left
--     from public.applications a
--     join public.withdrawal_requests wr
--       on wr.influencer_id = a.user_id and wr.status = 'done';
--
-- [V-5] ⚠️ 이 함수는 **확정되는 순간에만** 돈다. 적용만으로 과거분이
--   정리되지 않는다 — [V-4] 가 0 이 아니면 손으로 정리해야 한다.
--   (2026-09-02 운영의 2건은 적용 전에 이미 정리했다.)
