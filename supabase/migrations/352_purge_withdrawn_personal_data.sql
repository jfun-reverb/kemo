-- ============================================================
-- 352_purge_withdrawn_personal_data.sql
-- 회원 탈퇴 — 작업 10 (파기 ㄱ · 확정 즉시)
-- 사양서: docs/specs/2026-08-18-member-withdrawal.md §4-6 ⑨ · §4-7 · §5 ②
-- 작업표: docs/specs/2026-08-19-member-withdrawal-breakdown.md 작업 10
-- 선행(개발서버 적용·확인 완료): 345·346·347
-- 선행(작성 완료·적용 전): 348·349·350·351(이 파일이 350 을 다시 재정의한다)
--
-- 🔴 이 파일은 개인정보를 실제로 지운다. 되돌릴 수 없다. 아래 [PRE] 를
--    먼저 실행해 몇 건이 영향받는지 눈으로 본 뒤 적용할 것.
--
-- 산출 계약:
--   public.purge_withdrawn_personal_data(p_influencer_id uuid) RETURNS jsonb
--     성공: { ok:true, already_purged:false, placeholder_email, identities_updated }
--     이미 파기됨(멱등): { ok:true, already_purged:true }
--     실패: { ok:false, reason: 'not_found'|'audit_account_blocked'|'admin_account_excluded' }
--   public.advance_withdrawal_states() 재정의(베이스 350) — section 2
--     (scheduled→done) 안에서 이 함수를 부르도록 바뀐 것 외 로직 변경 없음.
--   withdrawal_requests.personal_data_purged_at timestamptz NULL(신규 컬럼)
--
-- ============================================================
-- ① 왜 advance_withdrawal_states() 안에서 직접 부르는가(별도 루프가 아니라)
-- ============================================================
--   §4-7 표가 「이름·이메일·전화·주소·SNS·LINE」의 확정 시점을 **「확정
--   즉시」**로 못 박았다. "확정"이 되는 자리는 이 저장소 전체에서 딱 한
--   곳 — advance_withdrawal_states() 의 section 2(scheduled→done)뿐이다
--   (cancel_withdrawal[349]은 done 을 만들지 않는다, request_withdrawal
--   [347/350]도 마찬가지). 그러므로 파기 호출 지점도 그 한 곳이어야
--   "확정 즉시"가 실제로 성립한다 — 별도 루프로 나중에 돌면 "확정은 됐는데
--   아직 개인정보가 남아있는 창"이 하루~며칠 생긴다(다음 예약 실행까지).
--
--   [저울질 — 파기 실패 시 확정(done)을 되돌릴지]
--   찬성(되돌린다·채택): 마이그레이션 327 의 선례 — "재계산 실패는 승인과
--     함께 롤백된다. 조용히 틀린 채 넘어가는 것보다 눈에 보이게 막히는
--     게 낫다"(update_deliverable_status 재정의 절). 이 작업은 그보다
--     훨씬 무겁다 — "조용히 틀린 채"의 결과가 금액 오류가 아니라 **개인
--     정보 미파기 상태의 회원이 "탈퇴 확정됨"으로 표시되는 것**이다.
--     이건 §4-7 이 약속한 것과 실제 상태가 어긋나는 것이라 데이터
--     보호법 관점에서 더 나쁘다. PL/pgSQL 의 BEGIN...EXCEPTION 블록은
--     진입 시점에 암묵적 SAVEPOINT 를 잡으므로, 이 블록 안에서 예외가
--     나면 **그 블록 안에서 한 UPDATE(status='done' 포함)까지 전부**
--     그 시점으로 롤백된다 — 별도 트랜잭션 관리 코드 없이 "파기 실패 →
--     확정도 실패"가 공짜로 보장된다.
--   반대: 확정(done)과 파기가 한 몸이 되면, 파기가 계속 실패하는 회원은
--     (예: 관리자 겸직 — 아래 ③) **영원히 scheduled 에 머문다.** 그
--     사람 입장에서는 "5일 뒤 탈퇴됩니다"라던 안내가 지켜지지 않는다.
--   → 채택 이유: 반대의 대가는 "눈에 보이는 지연"(RAISE WARNING 이 매일
--     남고, 운영팀이 그 로그로 알아채 수동 처리할 수 있다)이고, 찬성을
--     버렸을 때의 대가는 "안 보이는 개인정보 잔존"이다. 후자가 훨씬
--     나쁘다. 327 의 판단 기준("조용히 틀린 것보다 눈에 보이게 막히는
--     것")을 그대로 따른다.
--
-- ============================================================
-- ② 인증 계정 이메일 바꿔치기 형식 — 왜 이 값인가
-- ============================================================
--   형식: 'withdrawn+' || <influencer_id> || '@deleted.reverbjp.invalid'
--
--   · 재로그인 불가 — signInWithPassword 는 auth.users.email 로 행을
--     찾는다. 원래 이메일은 이제 그 컬럼 어디에도 없으므로 그 주소로는
--     로그인 시도 자체가 "그런 계정 없음"으로 실패한다(§5 ② 확정).
--   · 충돌 없음 — influencer_id(=auth.users.id, PK)를 그대로 박아 넣어
--     **결정적으로** 유일하다. 무작위값을 새로 생성할 필요가 없고,
--     같은 함수를 실수로 두 번 불러도 같은 값이 나온다(자연 멱등).
--   · 사람이 봤을 때 알아볼 수 있음 — 'withdrawn' 접두어 + 별도 도메인.
--   · '.invalid' 는 RFC 2606 이 예약한 TLD — "이 주소는 절대 실제
--     메일함으로 존재하지 않는다"는 것이 표준으로 보장된 유일한
--     선택지다. 임의 도메인(예: reverbjp.internal)을 새로 지어내면
--     의도치 않게 실제 도메인과 겹칠 이론적 위험이 있다.
--
--   ⚠️ ★[2026-08-19 갱신] 이 값은 **influencers.email 에도 그대로 쓴다**
--   (아래 「④」의 수정 이력 참고) — 개발 데이터베이스 실측으로
--   influencers 19개 대상 칸 중 NOT NULL 인 것은 email 하나뿐임이
--   확인되면서(정확한 조회·날짜는 아래 ④), influencers.email 을 NULL 로
--   비우는 대신 이 플레이스홀더로 채우기로 바꿨다. 그러면 ①제약을
--   건드릴 필요가 없고 ②로그인 계정 이메일과 회원 행 이메일이 **항상
--   같은 값**이라 나중에 대조하는 사람이 어긋남을 걱정할 필요가 없다.
--
-- ============================================================
-- ③ 관리자를 겸한 회원 — 방어 가드를 새로 추가한 이유(사양서 범위 밖의
--    사고를 막기 위한 보수적 결정)
-- ============================================================
--   사양서 §5②는 "관리자를 겸한 회원은 이 범위 밖이다 — 이 사양서는
--   다루지 않는다"라고 명시적으로 선을 그었다. 이 마이그레이션도 그
--   시나리오를 "다루지"는 않는다(관리자 권한 해제·재설계 없음) — 다만
--   **아무 말 없이 밟고 지나가면 무슨 일이 벌어지는지**를 그대로 두면
--   안 된다고 판단했다.
--
--   auth.users.email 은 admins 로그인과 influencers 로그인이 **같은
--   행을 공유**한다(admins.auth_id → auth.users.id). 이 관계를 모른 채
--   관리자를 겸한 회원이 (예를 들어 브라우저 콘솔로 직접) 탈퇴를
--   신청해 확정까지 가면, 이 파기 함수가 그 사람의 **관리자 로그인
--   이메일까지 조용히 바꿔버린다** — 본인도 모르고 다른 관리자도 모른
--   채 그 사람의 관리자 계정이 갑자기 로그인되지 않는 사고가 된다.
--
--   그래서 이 함수 안에 admins 존재 여부를 확인하는 가드를 추가했다
--   (admin_account_excluded). 이건 사양서의 결정을 뒤집는 게 아니다 —
--   "다루지 않는다"를 "그 경우엔 파기하지 않고 눈에 보이게 실패시켜
--   운영팀이 수동으로 판단하게 한다"로 구현한 것뿐이다. 이 가드가 걸린
--   신청은 advance_withdrawal_states() 가 매일 재시도하며 RAISE WARNING
--   을 계속 남긴다(①의 롤백 설계 덕에 자동으로 그렇게 된다) — 이건
--   버그가 아니라 "사람이 봐야 하는 예외"를 로그로 계속 알리는 의도된
--   동작이다. 이 경우를 실제로 해소하려면(관리자 권한을 먼저 내리거나,
--   탈퇴 신청 자체를 취소하거나) 사람이 판단해야 한다 — 이 마이그레이션
--   범위 밖.
--
-- ============================================================
-- ④ 무엇을 비우고, 무엇을 안 비우는가 — §4-7 표를 그대로 옮긴 것뿐,
--    이 파일이 스스로 범위를 넓히지 않는다
-- ============================================================
--   비우는 것(influencers, 18개 칸 그룹 — NULL 처리):
--     이름            name, name_kanji, name_kana
--     전화            phone
--     주소            zip, prefecture, city, address, building
--     SNS 계정+팔로워  ig/ig_followers, x/x_followers,
--                     tiktok/tiktok_followers, youtube/youtube_followers
--     LINE            line_id
--
--   바꿔치기하는 것(influencers, 1개 칸 — NULL 이 아니라 값 교체):
--     이메일          email → 아래 「비우는 것(auth, 2개 칸 그룹)」과
--                     **정확히 같은** 플레이스홀더 값을 그대로 넣는다.
--
--   ⚠️ ★[2026-08-19 갱신 — 개발 데이터베이스 실측 반영] influencers.email
--   은 §4-7 표에서 다른 18개 칸과 함께 "칸을 비운다"로 묶여 있었지만,
--   실제로 이 칸이 **이 그룹에서 유일한 NOT NULL 컬럼**이라는 사실이
--   개발 데이터베이스 조회(2026-08-19, `information_schema.columns`)로
--   확인됐다 — 비우는 그룹 19개 칸 중 `is_nullable='NO'` 는 email 딱
--   하나였다. NULL 을 넣으면 그 즉시 제약 위반으로 이 함수가 실패한다.
--
--   해결책으로 (가)NOT NULL 을 미리 풀어 두기 대신 (나)**인증 계정
--   이메일과 같은 플레이스홀더를 그대로 채우기**를 택했다. (나)를 고른
--   이유:
--     · **제약을 안 건드린다** — 스키마를 바꾸지 않으므로 이 마이그레이션
--       안에 되돌릴 수 없는 조치가 하나도 안 생긴다(개인정보 삭제
--       자체를 빼면). 스키마 변경은 실사용 이후 사실상 편도라(§4-7 표
--       와 무관하게 일반론), 안 만드는 게 이긴다.
--     · **두 이메일이 어긋나지 않는다** — influencers.email 을 NULL 로
--       비우고 auth.users.email 만 플레이스홀더로 바꾸면, 같은 사람을
--       가리키는 두 칸이 서로 다른 상태(하나는 빈 값, 하나는 합성값)가
--       되어 나중에 대조하는 사람이 "어느 쪽이 맞는 상태인가"로 헤맨다.
--       같은 값을 넣으면 둘은 **항상 일치**한다(아래 [V2] 2-5단계가 이를
--       직접 대조 확인한다).
--     · **여전히 개인을 알아볼 수 없다** — 값이 회원 고유번호(UUID)에서
--       결정적으로 나오므로, 원래 이메일과 무관한 합성값이다. 유일
--       제약이 있어도 다른 행과 충돌하지 않는다(형식이 위 ②).
--     · **사람이 봤을 때 "탈퇴한 계정"임이 그대로 읽힌다** — 빈 칸보다
--       'withdrawn+...' 쪽이 관리자가 데이터를 볼 때 더 명확하다.
--
--   ⚠️ **§4-7 표의 글자와는 다르다** — 그 표는 "influencers.email = 칸
--   비우기" / "인증 계정 이메일 = 다른 값으로 바꾸기"로 **두 조작을
--   구분해서** 적어 뒀다. 이 마이그레이션은 그 구분을 없애고 둘을
--   같은 조작(교체)으로 통일했다. 이게 실제 정책 문서(§4-5, 회원에게
--   공개되는 약관·개인정보처리방침 문구)와 부딪히는지 따로 확인했다 —
--   §4-5 "방침 파기 범위"의 실제 개정 문구는 「**개인을 알아볼 수 있는
--   정보는 파기**하고, 거래 기록은 개인을 알아볼 수 없는 상태로
--   보관합니다」로, **구현 방식(NULL이냐 합성값이냐)을 특정하지 않고
--   기능적 결과만 약속한다.** 합성 이메일은 개인을 알아볼 수 없으므로
--   이 약속과 충돌하지 않는다고 판단했다 — 같은 사양서가 "인증 계정의
--   이메일"에는 이미 이 방식(바꿔치기)을 §5②로 명시적으로 승인해 뒀고,
--   그 승인의 근거("계정 행은 남기고 원래 주소만 풀어 준다")가
--   influencers.email 에도 그대로 적용되기 때문이다. **어긋나는 것은
--   §4-7 표의 내부 서술뿐**이고, 이는 이 마이그레이션 파일 자체가
--   수정 근거를 남기는 것으로 갈음한다(사양서 문서 자체의 표 수정은
--   이 파일의 권한 밖 — 개발 세션은 코드만 다룬다).
--
--   ⚠️ 안 비우는 것(의도적 — §4-7 표에 없다):
--     · birthdate·gender·age_consent_at — 연령 정책(마이그레이션 180)의
--       생년월일·성별. §4-7 표·breakdown 작업표 어디에도 이 항목이 없다.
--       이건 나이 확인이라는 별개 목적의 개인정보라 이번 사양서가 다룬
--       흔적이 없다 — 이 마이그레이션이 임의로 지우면 사양서에 없는
--       결정을 내가 대신 내리는 것이라 하지 않는다. 다음 사양서·작업이
--       다룰 항목으로 남겨 둔다.
--     · followers(집계 컬럼)·bio·category·primary_sns — §4-7 이 「SNS
--       계정과 팔로워 수」라고 명시한 것은 4채널의 handle+followers 쌍
--       이지, 이 보조 컬럼들이 아니다. bio·category 는 PII 라기보다
--       취향 태그·자기소개 텍스트라 명시적 결정이 없는 한 안 건드린다.
--     · is_verified·blacklisted 관련·marketing_* — 관리자 감사 기록·
--       마케팅 동의 이력. 조사 문서(breakdown "🔬 타사 관행" F항)가
--       "마케팅 동의 기록은 통째로 지우지 않는다(특정전자메일법 1개월
--       보존)"고 지적했지만, 이건 **아직 작업 목록에 반영되지 않은
--       조사 결과**다 — 이 마이그레이션은 그 반영을 대신하지 않는다.
--     · settlements.paypal_email(5년 뒤 — 작업 13) · 결과물 이미지
--       (6개월 뒤 — 작업 12) · 이메일 해시(6개월 뒤 — 작업 11) — §4-7
--       이 명시적으로 "여기 겹쳐 적지 않는다"고 한 항목들. 이 함수는
--       이 셋 중 어느 것도 건드리지 않는다(교차 확인: 아래 [V] 검증에
--       influencers.paypal_email 이 안 바뀌는지 포함).
--
--   비우는 것(auth, 2개 칸 그룹) — §5②:
--     auth.users.email                        → 위 ② 형식으로 교체
--     auth.users.raw_user_meta_data->>'email'  → 같은 값으로 동기화
--       (⚠️ 사양서엔 "두 곳"이라고만 돼 있지만 이 JSON 도 auth.users
--       테이블 안에 있다 — supabase.md "Auth 레코드 완전성"이 요구하는
--       raw_user_meta_data.email 을 안 바꾸면 이 JSON 안에 원래 이메일이
--       그대로 남는다. "auth.users 를 바꾼다"에 이 JSON 동기화가 포함
--       되지 않으면 반쪽짜리 파기가 된다고 판단해 포함시켰다)
--     auth.identities.identity_data->>'email'  → 같은 값(마이그레이션
--       245 선례 — provider_id 는 이메일이 아니라 user_id::text 라
--       손댈 필요 없음, 012·029·031·179·245 전부 동일하게 확인)
--
--   ⚠️ 행은 어느 쪽도 지우지 않는다(influencers·auth.users·auth.identities
--   전부 UPDATE 만) — settlement_events 가 ON DELETE RESTRICT 라
--   influencers 행 자체를 지우면 정산 기록이 있는 회원은 삭제가 실패한다
--   (§4-7 구조 실측).
--
-- ============================================================
-- ⑤ 로그인 차단(작업 8)을 이 파일이 대신하는가 — 아니다, 판단 근거
-- ============================================================
--   이메일 바꿔치기는 로그인 차단의 **일부**만 한다:
--     ✅ 막는 것 — 원래 이메일로 새로 로그인 시도(signInWithPassword),
--       원래 이메일로 비밀번호 재설정 요청(resetPasswordForEmail). 둘
--       다 auth.users.email 로 행을 찾는데 그 값이 이제 없으므로 실패.
--     ❌ 못 막는 것 — **이미 로그인된 상태로 열려 있는 브라우저 세션.**
--       Supabase 의 JWT 검증은 서명·만료시각만 보고, 매 요청마다
--       "이 uid 의 이메일이 지금 이 값이 맞는지"를 다시 조회하지
--       않는다. 즉 탈퇴가 확정되는 순간에도 그 전에 로그인해 둔 탭은
--       토큰이 만료(또는 강제 로그아웃)되기 전까지 **계속 응모·조회가
--       가능하다.** 여기다 request_withdrawal(347/350)이 감사용 계정
--       외에는 로그인 자체를 막지 않으므로, done 이 된 뒤에도 그
--       세션으로 새 응모를 넣을 길이 열려 있다.
--
--   작업 8(§4-6 ⑤)이 명시한 "완료이거나 예정일이 지났으면 거부"는
--   행 단위 보안 정책(RLS)이나 함수 가드 수준에서 **매 요청마다**
--   withdrawal_requests.status 를 직접 확인하는 방식이어야 위의
--   "이미 열려 있는 세션" 구멍을 막는다 — 이메일 교체와는 완전히 다른
--   방어선이다. 그러므로 **이 파일은 로그인 차단을 대신하지 않는다.
--   작업 8 은 여전히 별도로 반드시 필요하다.** (사양서 §4-6 도 ⑤를
--   ⑨[파기]와 별개 항목으로 두어 이 판단과 정합함.)
--
-- ============================================================
-- ⑥ 개인정보처리방침 개정(작업 17·18)이 아직 안 됐다 — 이 코드가 먼저
--    돌아도 되는가
-- ============================================================
--   `.claude/rules/release-timing.md` 의 3층 모델(문서는 미리 안 됨 /
--   코드는 미리 됨 / 집행은 시행일)에 따르면 **코드 배포 자체는 문제
--   없다.** 진짜 물어야 할 것은 "이 코드가 실제로 실행돼(=집행) 시행일
--   전에 회원에게 영향을 주는 경로가 지금 존재하는가"다.
--
--   🔴 실측 결과 — **그 경로는 이미 열려 있고, 이 작업이 만든 게
--   아니다.** request_withdrawal()(작업 5, 마이그레이션 347/350)은
--   `GRANT EXECUTE ... TO authenticated` 로 **이미 배포돼 있다.** 로그인한
--   인플루언서라면 화면(작업 9, 미착수)이 없어도 브라우저 개발자
--   콘솔에서 이 RPC 를 직접 호출할 수 있다. 미지급이 0건인 사람이 그렇게
--   하면 5일 뒤 advance_withdrawal_states()(작업 7, pg_cron 매일 실행
--   중)가 자동으로 done 전이를 시도하고, **이 파일을 적용하는 순간부터
--   그 done 전이에 파기까지 함께 실행된다.** 시행 전 잠금(작업 15)이
--   아직 없으므로 이 경로를 막는 장치가 현재 하나도 없다.
--
--   → 판단: 이 마이그레이션이 새 위험을 만드는 것이 아니라, **이미
--   있던 위험(작업 5 배포 시점부터 존재)의 마지막 결과(파기)를
--   실행 가능하게 만드는 것**이다. §4-7 이 "파기"에서 "익명 보관"으로
--   좁아지는 것을 "불리한 변경"으로 판정했으므로(§4-5), 이 경로로
--   실제 파기가 발생하면 **아직 시행되지 않은, 사전 통지도 안 된 조건
--   으로 회원을 처리하는 셈**이 된다.
--
--   이 파일 안에서 임시 게이트(예: withdrawal_settings 흉내)를 만들지
--   **않는다** — 그건 작업 15 가 명시적으로 맡을 일이고, 여기서
--   흉내 내면 "같은 판단이 두 곳에" 있게 돼 이 저장소가 반복해서 겪은
--   실패 패턴(채널 코드 이관 사고 등)을 또 만든다. 대신:
--     1) 이 저장소는 **현재 개발서버 전용**이다(작업표 전체가 "개발
--        적용 완료/적용 전" 뿐, 운영 배포 기록 없음) — 실제 회원 노출은
--        지금 0건이다.
--     2) **운영 서버에 이 체인(345~352)을 배포하기 전에, 반드시 작업
--        15(시행 전 잠금) 를 먼저 배포하거나, 그것이 준비되기 전까지는
--        운영 pg_cron 의 'withdrawal-states-advance-daily' 잡을 등록하지
--        말 것.** 이 마이그레이션은 그 잡을 새로 만들지 않는다(350 이
--        만든 잡을 그대로 재사용) — 운영에서는 350 적용 시점에 이 잡
--        등록 여부를 신중히 판단해야 한다.
--     3) 이 경고는 개발 세션이 판단할 수 있는 범위를 넘는다 —
--        운영 배포 순서를 결정하는 사람에게 전달할 것.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- [PRE] 적용 전 확인 — 몇 건이 영향받는지 먼저 센다 (SQL 편집기 가능,
--   읽기 전용). 🔴 이 숫자가 0이 아니면, 적용하는 순간 바로 다음
--   pg_cron 실행(withdrawal-states-advance-daily, 매일 KST 04:45)에서
--   그 회원들의 개인정보가 실제로 파기된다 — 반드시 먼저 확인할 것.
-- ============================================================
-- SELECT id, influencer_id, status, scheduled_date, requested_by_kind
--   FROM public.withdrawal_requests
--  WHERE status = 'scheduled'
--    AND scheduled_date <= (now() AT TIME ZONE 'Asia/Tokyo')::date
--  ORDER BY scheduled_date;
-- 기대(2026-08-19 시점 개발서버): 0행 또는 작업 5·6 검증 때 만든 시험
-- 행뿐 — 그 시험 행은 [V1] 검증을 하기 전에 먼저 정리할 것
-- (DELETE FROM withdrawal_requests WHERE influencer_id = '<시험 id>').

BEGIN;

-- ============================================================
-- 1. withdrawal_requests — 파기 시각 감사 컬럼 1개
--    ⚠️ 작업 11(재가입 차단)·작업 12(이미지 파기)·작업 13(PayPal 파기)
--    가 쓸 기준 시각은 이 컬럼이 아니라 completed_at 이다(그 세 작업이
--    보는 것은 "탈퇴가 확정된 지 N개월/N년" 이지 "개인정보가 언제
--    비워졌나"가 아니다). 이 컬럼은 오직 이 작업(10) 자신이 "정말
--    비웠는지·언제 비웠는지"를 셀 수 있게 남기는 용도다 — 지금 설계
--    (①의 롤백 보장)에서는 이 값이 completed_at 과 항상 같은 트랜잭션
--    타임스탬프로 정확히 같은 값이 된다(PL/pgSQL now() 는 트랜잭션
--    시작 시각을 반환). 그런데도 별도 컬럼으로 남기는 이유는, 나중에
--    누군가 파기와 done 전이를 분리하도록 리팩터링해도(예: 파기를
--    비동기 Edge Function 으로 옮기는 미래 변경) "이 회원의 개인정보가
--    실제로 비워졌는가"를 completed_at 과 무관하게 독립적으로 답할 수
--    있게 하기 위해서다.
-- ============================================================
ALTER TABLE public.withdrawal_requests
  ADD COLUMN IF NOT EXISTS personal_data_purged_at timestamptz NULL;

-- 재실행 안전 — 이 저장소는 「파일을 통째로 복사해 붙여넣는」 방식이라
-- 실수로 두 번 실행되는 일이 실제로 있다(346 도 같은 짝을 쓴다).
ALTER TABLE public.withdrawal_requests
  DROP CONSTRAINT IF EXISTS withdrawal_requests_purged_only_when_done;

ALTER TABLE public.withdrawal_requests
  ADD CONSTRAINT withdrawal_requests_purged_only_when_done
  CHECK (personal_data_purged_at IS NULL OR status = 'done');

COMMENT ON COLUMN public.withdrawal_requests.personal_data_purged_at IS
  '[352] purge_withdrawn_personal_data() 가 이 신청 건의 개인정보를 실제로 '
  '비운 시각. 현재 설계에서는 advance_withdrawal_states() 의 scheduled→done '
  '전이와 같은 트랜잭션에서 채워져 completed_at 과 항상 같은 값이지만, '
  '작업 11·12·13 이 쓸 "탈퇴 확정 후 N개월/N년" 기준 시각은 반드시 '
  'completed_at 을 쓸 것 — 이 컬럼이 아니다(이 컬럼은 파기 자체의 감사 '
  '용도로만 존재). NULL 이면 아직 파기되지 않았거나 파기가 실패해 '
  'done 전이 자체가 롤백된 것(둘 다 status<>''done'' 이면 정상 — 위 CHECK).';

-- ============================================================
-- [2026-08-19 갱신] influencers 의 NOT NULL 을 미리 풀어 두는 절이
-- 여기 있었으나 삭제했다 — 개발 데이터베이스 실측(같은 날짜,
-- `information_schema.columns` 로 이 함수가 비우는 19개 칸의
-- `is_nullable` 을 직접 조회) 결과 **NOT NULL 인 칸은 email 하나뿐**
-- 이었고, 그 email 은 이제 NULL 로 비우지 않고 인증 계정과 같은
-- 플레이스홀더로 채우도록 바꿔(위 「④」 갱신 절 참고) 제약을 아예
-- 건드릴 필요가 없어졌다. 나머지 18개 칸은 원래부터 nullable 이라
-- DROP NOT NULL 문장 자체가 아무것도 바꾸지 않는 죽은 코드였다.
-- → **이 파일은 이제 표 구조(스키마 제약)를 전혀 바꾸지 않는다.**
-- 개인정보 삭제 자체를 제외하면 이 파일에 되돌릴 수 없는 조치가
-- 하나도 남지 않았다(아래 "롤백" 절 참고).
-- ============================================================

-- ============================================================
-- 2. purge_withdrawn_personal_data(uuid) — 본체
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

  RETURN jsonb_build_object(
    'ok',                 true,
    'already_purged',     false,
    'placeholder_email',  v_placeholder_email,
    'identities_updated', v_identities_updated
  );
END;
$$;

COMMENT ON FUNCTION public.purge_withdrawn_personal_data(uuid) IS
  '[352] 회원 탈퇴 확정(status=done) 시 개인정보를 비운다(행은 지우지 않는다 — '
  'settlement_events ON DELETE RESTRICT). influencers 18개 칸(이름·전화·주소·SNS '
  '계정+팔로워·LINE) 은 NULL 처리, influencers.email 1개 칸은 NULL 이 아니라 '
  'auth.users/auth.identities 의 로그인 이메일과 정확히 같은 플레이스홀더로 '
  '교체(withdrawn+<influencer_id>@deleted.reverbjp.invalid — [2026-08-19 갱신] '
  'influencers.email 이 이 19개 칸 중 유일한 NOT NULL 컬럼임이 개발 데이터베이스 '
  '실측으로 확인돼, NULL 대신 값을 통일했다). 멱등(influencers.email 이 이미 그 '
  '플레이스홀더와 같으면 already_purged:true 로 조용히 반환). 감사용 계정·관리자를 '
  '겸한 회원은 거부(ok:false) — 호출부(advance_withdrawal_states, 352 재정의)가 이 '
  '반환값을 확인해 실패 시 예외를 던져 done 전이 자체를 롤백시킨다(파일 헤더 「①」 '
  '참고). PayPal(작업 13)·재가입 차단 해시(작업 11)·결과물 이미지(작업 12)는 이 '
  '함수의 범위가 아니다 — §4-7 표가 정한 다른 시점(5년·6개월)에 다른 작업이 처리한다.';

REVOKE ALL ON FUNCTION public.purge_withdrawn_personal_data(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purge_withdrawn_personal_data(uuid) TO postgres;
-- ⚠️ authenticated 에는 절대 GRANT 하지 않는다 — 이 함수는 배치 전용
-- 내부 함수다. 본인 확인(auth.uid())이 전혀 없어, 만약 일반 로그인
-- 사용자가 이 함수를 직접 호출할 수 있게 두면 **아무 인플루언서 uuid나
-- 넘겨 남의 개인정보를 지울 수 있는 구멍**이 된다. postgres 에게만
-- 명시적으로 부여한 이유는 350 의 advance_withdrawal_states() 와 같다 —
-- 이 저장소의 SQL 편집기 실행 컨텍스트가 슈퍼유저로 모든 ACL 을
-- 우회하지 않는다는 것을 350 이 이미 확인했다(그 파일이 postgres 에게
-- 명시적으로 GRANT 하지 않았다면 검증 자체가 불가능했을 것이다).

-- ============================================================
-- 3. advance_withdrawal_states() 재정의 — 베이스는 350(현재 유일한
--    원본, feedback_function_redefine_latest_base 메모리 규칙에 따름).
--    section 2(scheduled→done) 안에서 purge_withdrawn_personal_data()
--    를 부르는 것 + personal_data_purged_at 갱신 + DECLARE 변수 1개
--    추가 + 코멘트 갱신 외에는 350 과 완전히 동일하다(diff 로 확인
--    가능 — 아래 [V] 절 [V-diff] 참고). section 0(행사 예약 정리)·
--    section 1(pending_payout→scheduled)은 한 글자도 바꾸지 않았다.
-- ============================================================
CREATE OR REPLACE FUNCTION public.advance_withdrawal_states()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_today_jst            date := (now() AT TIME ZONE 'Asia/Tokyo')::date;

  v_advanced_scheduled   integer := 0;
  v_advanced_done        integer := 0;
  v_event_cancelled      integer := 0;
  v_event_blocked        integer := 0;

  v_ticket_id            uuid;
  v_ticket_influencer_id uuid;
  v_ticket_result        jsonb;

  v_cand_id              uuid;
  v_cand_influencer_id   uuid;
  v_req                  public.withdrawal_requests%ROWTYPE;
  v_unpaid               integer;
  v_scheduled_date       date;
  v_purge_result         jsonb;   -- [352 신규] purge_withdrawn_personal_data() 반환값
BEGIN
  -- ============================================================
  -- 0. 오프라인 행사 예약 정리 — 350 과 완전히 동일(무변경)
  -- ============================================================
  FOR v_ticket_id, v_ticket_influencer_id IN
    SELECT t.id, t.influencer_id
      FROM public.event_tickets t
      JOIN public.withdrawal_requests wr
        ON wr.influencer_id = t.influencer_id
       AND wr.status IN ('pending_payout', 'scheduled')
     WHERE t.status IN ('confirmed', 'waitlist')
  LOOP
    BEGIN
      PERFORM 1 FROM public.influencers WHERE id = v_ticket_influencer_id FOR UPDATE;

      IF NOT EXISTS (
        SELECT 1 FROM public.withdrawal_requests
         WHERE influencer_id = v_ticket_influencer_id
           AND status IN ('pending_payout', 'scheduled')
      ) THEN
        CONTINUE;
      END IF;

      v_ticket_result := public._withdrawal_cancel_event_ticket(v_ticket_id);

      IF COALESCE((v_ticket_result->>'ok')::boolean, false) THEN
        IF NOT COALESCE((v_ticket_result->>'already_cancelled')::boolean, false) THEN
          v_event_cancelled := v_event_cancelled + 1;

          UPDATE public.withdrawal_requests
             SET event_tickets_cancelled_count = event_tickets_cancelled_count + 1
           WHERE influencer_id = v_ticket_influencer_id
             AND status IN ('pending_payout', 'scheduled');
        END IF;
      ELSE
        v_event_blocked := v_event_blocked + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_event_blocked := v_event_blocked + 1;
      RAISE WARNING '[advance_withdrawal_states] event ticket % cancel failed: %', v_ticket_id, SQLERRM;
    END;
  END LOOP;

  UPDATE public.withdrawal_requests wr
     SET event_tickets_blocked_count = sub.cnt
    FROM (
      SELECT wr2.id AS wr_id, count(t.id) AS cnt
        FROM public.withdrawal_requests wr2
        LEFT JOIN public.event_tickets t
          ON t.influencer_id = wr2.influencer_id
         AND t.status IN ('confirmed', 'waitlist')
       WHERE wr2.status IN ('pending_payout', 'scheduled')
       GROUP BY wr2.id
    ) sub
   WHERE wr.id = sub.wr_id;

  -- ============================================================
  -- 1. pending_payout → scheduled — 350 과 완전히 동일(무변경)
  -- ============================================================
  FOR v_cand_id, v_cand_influencer_id IN
    SELECT wr.id, wr.influencer_id
      FROM public.withdrawal_requests wr
     WHERE wr.status = 'pending_payout'
     ORDER BY wr.requested_at
  LOOP
    BEGIN
      PERFORM 1 FROM public.influencers WHERE id = v_cand_influencer_id FOR UPDATE;

      SELECT * INTO v_req FROM public.withdrawal_requests WHERE id = v_cand_id FOR UPDATE;

      IF NOT FOUND OR v_req.status <> 'pending_payout' THEN
        CONTINUE;
      END IF;

      v_unpaid := public._withdrawal_unpaid_count(v_cand_influencer_id);

      IF v_unpaid = 0 THEN
        v_scheduled_date := v_today_jst + 5;

        UPDATE public.withdrawal_requests
           SET status = 'scheduled', scheduled_date = v_scheduled_date
         WHERE id = v_req.id;

        v_advanced_scheduled := v_advanced_scheduled + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[advance_withdrawal_states] pending_payout row % failed: %', v_cand_id, SQLERRM;
    END;
  END LOOP;

  -- ============================================================
  -- 2. scheduled → done — [352] 여기만 바뀐다. 예정일이 지난 신청을
  --    확정하는 동시에, 같은 서브트랜잭션(BEGIN...EXCEPTION 블록) 안에서
  --    개인정보를 파기한다. 파기가 실패하면 이 블록 전체가(방금 한
  --    status='done' UPDATE 까지) 롤백돼 다음 실행에서 다시 시도된다
  --    (파일 헤더 「①」의 저울질 결론).
  -- ============================================================
  FOR v_cand_id, v_cand_influencer_id IN
    SELECT wr.id, wr.influencer_id
      FROM public.withdrawal_requests wr
     WHERE wr.status = 'scheduled'
       AND wr.scheduled_date IS NOT NULL
       AND wr.scheduled_date <= v_today_jst
     ORDER BY wr.scheduled_date
  LOOP
    BEGIN
      PERFORM 1 FROM public.influencers WHERE id = v_cand_influencer_id FOR UPDATE;

      SELECT * INTO v_req FROM public.withdrawal_requests WHERE id = v_cand_id FOR UPDATE;

      IF NOT FOUND OR v_req.status <> 'scheduled' THEN
        CONTINUE;
      END IF;

      UPDATE public.withdrawal_requests
         SET status = 'done', completed_at = now()
       WHERE id = v_req.id;

      -- [352 신규] 확정 즉시 파기(§4-7). 실패하면 예외를 직접 던져 위
      -- UPDATE 까지 포함해 이 블록 전체를 롤백시킨다 — purge 함수
      -- 자신은 "not_found"/"audit_account_blocked"/"admin_account_excluded"
      -- 를 조용한 {ok:false} 로 돌려주므로(내부 예외를 안 던지므로),
      -- 여기서 명시적으로 확인해 예외로 승격시켜야 롤백이 걸린다.
      v_purge_result := public.purge_withdrawn_personal_data(v_cand_influencer_id);

      IF NOT COALESCE((v_purge_result->>'ok')::boolean, false) THEN
        RAISE EXCEPTION 'purge_failed: %', COALESCE(v_purge_result->>'reason', 'unknown');
      END IF;

      UPDATE public.withdrawal_requests
         SET personal_data_purged_at = now()
       WHERE id = v_req.id;

      v_advanced_done := v_advanced_done + 1;
    EXCEPTION WHEN OTHERS THEN
      -- ⚠️ 이 WARNING 은 두 가지 원인을 구분하지 않는다 — "정말 예상 못한
      -- 오류"와 "purge_failed: admin_account_excluded 처럼 사람이 봐야
      -- 하는 예외"가 같은 로그 문구로 남는다. 메시지(SQLERRM)에
      -- purge_failed 사유가 그대로 실리므로 Supabase Logs 에서 텍스트로
      -- 구분 가능 — 별도 카운터를 새로 만들지 않는다(반환 계약을
      -- 이번 작업 범위에서 넓히지 않기 위해).
      RAISE WARNING '[advance_withdrawal_states] scheduled row % failed: %', v_cand_id, SQLERRM;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',                          true,
    'advanced_to_scheduled',       v_advanced_scheduled,
    'advanced_to_done',            v_advanced_done,
    'event_tickets_cancelled',     v_event_cancelled,
    'event_tickets_cancel_failed', v_event_blocked
  );
END;
$$;

COMMENT ON FUNCTION public.advance_withdrawal_states() IS
  '[352, 350 재정의] 회원 탈퇴 상태 전이 예약 실행. 매일 1회(pg_cron): '
  '①pending_payout 이고 미지급 0건이면 scheduled(예정일=오늘[JST]+5일)로 전이 '
  '②scheduled 이고 예정일이 지났으면 done(completed_at=now())으로 전이하면서 '
  '**같은 트랜잭션 안에서 purge_withdrawn_personal_data() 로 개인정보를 즉시 '
  '파기한다(§4-7) — 파기가 실패하면 done 전이 자체가 롤백되어 다음 실행에서 '
  '재시도된다**(advanced_to_done 카운트는 곧 "확정도 되고 파기도 성공한" 건수와 '
  '같다) ③매 실행마다 활성(pending_payout/scheduled) 신청의 오프라인 행사 예약을 '
  '재시도 취소. 메일 발송은 이 함수가 하지 않는다(별도 Edge Function, 351 참고). '
  '재가입 차단 해시(작업 11)·결과물 이미지 파기(작업 12)·PayPal 파기(작업 13)· '
  '로그인 차단(작업 8)은 이번 범위 밖 — 이메일 교체가 신규 로그인은 막지만 이미 '
  '열려 있는 세션은 못 막는다(352 파일 헤더 「⑤」 참고, 작업 8 이 별도로 필요). '
  'SQL 편집기에서 직접 호출 가능(auth.uid() 를 참조하지 않음). pg_cron job: '
  'withdrawal-states-advance-daily(350 이 등록, 이 파일은 재등록하지 않음).';

REVOKE ALL ON FUNCTION public.advance_withdrawal_states() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.advance_withdrawal_states() TO postgres;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 적용 순서 (이 파일 352)
--   0. ★ **350 이 이미 적용돼 있는지 먼저 확인한다**(아래 [V0]).
--      이 파일이 다시 정의하는 advance_withdrawal_states() 는 350 이 만드는
--      함수 둘(_withdrawal_unpaid_count · _withdrawal_cancel_event_ticket)과
--      칸 둘(event_tickets_cancelled_count · _blocked_count)을 그대로 쓴다.
--      ⚠️ **350 없이 352 만 적용해도 「성공」한다** — 함수 본문 안의 SQL 은
--      만들 때 검사되지 않는다. 그런데 실제로 돌리면 「함수 없음」 오류가
--      **같은 블록의 EXCEPTION WHEN OTHERS 에 조용히 잡혀** 경고 로그만 남고
--      함수는 「0건 처리」로 정상 반환한다. 그러면 [V1] 을 따라가는 사람이
--      **352 의 파기 로직이 잘못됐다고 오판한다**(진짜 원인은 데이터베이스
--      로그를 따로 열어야 보인다). 순서를 지키면 겪지 않을 혼란이다.
--   1. 개발 데이터베이스에 이 파일 전체 적용.
--   2. 아래 [V0]~[V9] 를 반드시 통과시킨다 — 개인정보를 실제로 지우는
--      함수라 「적용 성공」은 「동작 확인」이 아니다(.claude/rules/
--      supabase.md). 특히 [V8](파기 실패 시 done 전이 자체가 롤백되는지)
--      은 이 작업의 핵심 설계 결정을 검증하는 절차라 생략 금지.
--   3. 운영 배포는 파일 헤더 「⑥」의 경고를 반드시 먼저 검토할 것 —
--      작업 15(시행 전 잠금) 없이 이 체인을 운영에 올리면 이미 배포된
--      request_withdrawal(작업 5)을 아는 사용자가 시행일 전에 실제로
--      파기될 수 있다.
-- ============================================================

-- ============================================================
-- 적용 후 확인 (⚠️ 아래 [V1]~[V9] 는 **개발서버 전용, 처음부터 끝까지
-- 새로 만든 시험 계정으로만** 진행한다. 기존 공용 시험 계정
-- (sakura.test@reverb.jp 등)을 쓰지 않는 이유 — 이 함수는 이메일을
-- 포함한 로그인 정보를 영구히 바꾸므로, 다른 작업(5·6·7)이 재사용하는
-- 공용 시험 계정에 실행하면 그 계정을 다시는 못 쓰게 된다. 시험용
-- 계정은 검증이 끝나면 완전히 DELETE 한다(파기가 아니라 그냥
-- 지운다 — 처음부터 실사용 데이터가 아니므로 정산 감사 이력도 없어
-- 안전하게 삭제 가능하다).
-- ============================================================
--
-- [V0] (SQL 편집기 가능 — 읽기 전용) 함수·컬럼 생성 확인
--   SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args,
--          pg_get_function_result(p.oid) AS returns
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public'
--      AND p.proname IN ('purge_withdrawn_personal_data', 'advance_withdrawal_states')
--    ORDER BY p.proname;
--   기대: 2행. purge_withdrawn_personal_data(args='p_influencer_id uuid',
--   returns='jsonb').
--
--   SELECT column_name, is_nullable FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='withdrawal_requests'
--      AND column_name='personal_data_purged_at';
--   기대: 1행, is_nullable='YES'.
--
-- ============================================================
-- [V1] 시험 계정 1개 생성 — 12(감사용 계정)·179 의 INSERT 패턴을 그대로
--   따른다(auth.users + auth.identities + influencers 3단 삽입, supabase.md
--   「Auth 레코드 완전성」 준수). 아래를 통째로 SQL 편집기에서 실행:
-- ============================================================
--   DO $$
--   DECLARE
--     v_uid uuid := gen_random_uuid();
--   BEGIN
--     INSERT INTO auth.users (
--       instance_id, id, aud, role, email, encrypted_password,
--       email_confirmed_at, created_at, updated_at,
--       raw_app_meta_data, raw_user_meta_data,
--       confirmation_token, recovery_token,
--       email_change_token_new, email_change,
--       phone_change, phone_change_token, reauthentication_token
--     ) VALUES (
--       '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated',
--       'purge-test-1@reverb.jp',
--       extensions.crypt('PurgeTest2026!', extensions.gen_salt('bf', 10)),
--       now(), now(), now(),
--       jsonb_build_object('provider','email','providers',jsonb_build_array('email')),
--       jsonb_build_object('sub', v_uid::text, 'email', 'purge-test-1@reverb.jp',
--                           'email_verified', true, 'phone_verified', false),
--       '', '', '', '', '', '', ''
--     );
--     INSERT INTO auth.identities (
--       id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at
--     ) VALUES (
--       gen_random_uuid(), v_uid::text, v_uid,
--       jsonb_build_object('sub', v_uid::text, 'email', 'purge-test-1@reverb.jp', 'email_verified', true),
--       'email', now(), now(), now()
--     );
--     INSERT INTO public.influencers (
--       id, email, name, name_kanji, name_kana, phone, zip, prefecture, city, address, building,
--       ig, ig_followers, x, x_followers, tiktok, tiktok_followers, youtube, youtube_followers,
--       line_id, paypal_email, is_audit, terms_agreed_at, privacy_agreed_at, created_at
--     ) VALUES (
--       v_uid, 'purge-test-1@reverb.jp', 'テスト太郎', 'テスト太郎', 'てすとたろう',
--       '090-0000-0000', '100-0001', '東京都', '千代田区', '千代田1-1', 'テストビル101',
--       'purge_ig', 1000, 'purge_x', 2000, 'purge_tt', 3000, 'purge_yt', 4000,
--       'purge_line', 'purge-test-1@paypal.example', false, now(), now(), now()
--     );
--     RAISE NOTICE '시험 influencer id: %', v_uid;
--   END $$;
--   ⚠️ 출력된 uuid 를 반드시 복사해 둘 것 — 아래 모든 단계에서 그대로 쓴다.
--   paypal_email 도 채웠다 — 이 함수가 그 칸은 절대 건드리지 않는지
--   [V3] 에서 함께 확인하기 위함(작업 13 소관, 이 작업이 침범하면 안 됨).
--
-- ============================================================
-- [V2] 정상 파기 확인 — 위 [V1] 의 uuid 를 '<시험 id>' 자리에 그대로 넣어 실행
-- ============================================================
-- 2-1단계:
--   SELECT public.purge_withdrawn_personal_data('<시험 id>');
--   기대: {"ok":true, "already_purged":false, "placeholder_email":
--   "withdrawn+<시험 id>@deleted.reverbjp.invalid", "identities_updated":1}
--
-- 2-2단계 — influencers 행 확인:
--   SELECT name, name_kanji, name_kana, email, phone, zip, prefecture, city,
--          address, building, ig, ig_followers, x, x_followers, tiktok,
--          tiktok_followers, youtube, youtube_followers, line_id, paypal_email
--     FROM public.influencers WHERE id = '<시험 id>';
--   기대: email 만 'withdrawn+<시험 id>@deleted.reverbjp.invalid'(플레이스홀더,
--   NULL 아님 — [2026-08-19 갱신] 위 헤더 「④」 참고), paypal_email 은
--   'purge-test-1@paypal.example' 그대로(이 함수가 절대 안 건드림 — 작업 13
--   소관), **나머지는 전부 NULL**.
--
-- 2-3단계 — auth.users 확인:
--   SELECT email, raw_user_meta_data->>'email' AS meta_email
--     FROM auth.users WHERE id = '<시험 id>';
--   기대: 둘 다 'withdrawn+<시험 id>@deleted.reverbjp.invalid' 로 동일.
--
-- 2-4단계 — auth.identities 확인:
--   SELECT identity_data->>'email' AS identity_email, provider_id
--     FROM auth.identities WHERE user_id = '<시험 id>';
--   기대: identity_email 이 2-3단계와 동일한 플레이스홀더. provider_id 는
--   '<시험 id>' 그대로(바뀌지 않음 — user_id::text 라서).
--
-- 2-5단계 — ★[신규] influencers.email 과 auth.users.email 이 서로 같은지
--   직접 대조(두 곳을 따로 채우는 구조라 어긋나면 바로 알아야 한다):
--   SELECT
--     (SELECT email FROM public.influencers WHERE id = '<시험 id>') AS inf_email,
--     (SELECT email FROM auth.users       WHERE id = '<시험 id>') AS auth_email,
--     (SELECT email FROM public.influencers WHERE id = '<시험 id>')
--       = (SELECT email FROM auth.users WHERE id = '<시험 id>')      AS match;
--   기대: inf_email = auth_email, match = true.
--
-- ============================================================
-- [V3] 멱등 확인 — 같은 함수를 한 번 더 호출
-- ============================================================
--   SELECT public.purge_withdrawn_personal_data('<시험 id>');
--   기대: {"ok":true, "already_purged":true} 뿐(placeholder_email 재계산
--   없음 — v_inf.email 이 이미 그 플레이스홀더와 같아 2단계에서 조기
--   반환됨). 위 2-3·2-4·2-5 단계를 다시 실행해 값이 그대로인지(재실행으로
--   값이 또 바뀌지 않는지) 확인.
--
-- ============================================================
-- [V4] not_found 확인
-- ============================================================
--   SELECT public.purge_withdrawn_personal_data(gen_random_uuid());
--   기대: {"ok":false, "reason":"not_found"}
--
-- ============================================================
-- [V5] 감사용 계정 가드 확인 — 시험 계정 2개째(별도 uuid, [V1] 과 같은
--   INSERT 패턴이되 is_audit=true 로) 만든 뒤:
-- ============================================================
--   (동일한 3단 INSERT 를 email='purge-test-2@reverb.jp', is_audit=true 로
--   반복 — 지면상 생략, [V1] 블록을 복사해 이메일과 is_audit 값만 바꿀 것)
--   SELECT public.purge_withdrawn_personal_data('<시험2 id>');
--   기대: {"ok":false, "reason":"audit_account_blocked"}
--   확인: SELECT email FROM public.influencers WHERE id='<시험2 id>';
--   → 'purge-test-2@reverb.jp' 그대로(파기 안 됐다).
--
-- ============================================================
-- [V6] 관리자 겸직 가드 확인 — 시험 계정 3개째 만든 뒤 admins 에도 등록:
-- ============================================================
--   (동일한 3단 INSERT, email='purge-test-3@reverb.jp', is_audit=false)
--   INSERT INTO public.admins (auth_id, email, name, role)
--     VALUES ('<시험3 id>', 'purge-test-3@reverb.jp', '파기시험 관리자', 'campaign_manager');
--   SELECT public.purge_withdrawn_personal_data('<시험3 id>');
--   기대: {"ok":false, "reason":"admin_account_excluded"}
--   확인: SELECT email FROM auth.users WHERE id='<시험3 id>';
--   → 'purge-test-3@reverb.jp' 그대로(관리자 로그인 이메일이 안 바뀌었다).
--
-- ============================================================
-- [V7] advance_withdrawal_states() 통합 확인 — 시험 계정 4개째 +
--   withdrawal_requests 행을 곁들여, 실제 예약 실행 경로로 파기가
--   일어나는지 끝까지 확인한다(350 의 [V2] 패턴 재사용).
-- ============================================================
-- 7-1단계 — 시험 계정 4개째(email='purge-test-4@reverb.jp', is_audit=false,
--   paypal_email 도 채워 둘 것) 생성.
--
-- 7-2단계 — 탈퇴 신청 행을 이미 scheduled·예정일 어제로 직접 삽입:
--   INSERT INTO public.withdrawal_requests
--     (influencer_id, status, scheduled_date, requested_by_kind)
--   VALUES
--     ('<시험4 id>', 'scheduled',
--      (now() AT TIME ZONE 'Asia/Tokyo')::date - 1, 'self');
--
-- 7-3단계 — 배치 실행:
--   SELECT public.advance_withdrawal_states();
--   기대: advanced_to_done >= 1 (다른 활성 대기 건과 합산일 수 있음).
--
-- 7-4단계 — 그 신청 행 확인:
--   SELECT status, completed_at, personal_data_purged_at
--     FROM public.withdrawal_requests
--    WHERE influencer_id = '<시험4 id>';
--   기대: status='done', completed_at IS NOT NULL,
--   personal_data_purged_at = completed_at(정확히 같은 값).
--
-- 7-5단계 — influencers·auth 확인(2-2~2-4 단계와 동일한 조회를
--   '<시험4 id>' 로 반복) — 전부 파기됐는지 확인.
--
-- ============================================================
-- [V8] ★★★ 핵심 — 파기 실패 시 done 전이 자체가 롤백되는지 확인
--   (이 작업의 설계 결정 「①」을 실제로 검증하는 단계, 생략 금지)
-- ============================================================
-- 8-1단계 — 시험 계정 5개째 생성 + admins 등록([V6] 과 동일하게
--   관리자를 겸하게 만들어 purge 가 반드시 admin_account_excluded 로
--   실패하도록 유도한다).
--
-- 8-2단계 — 그 계정으로 탈퇴 신청 행을 scheduled·예정일 어제로 삽입
--   (7-2단계와 동일 패턴, influencer_id 만 시험5 id 로).
--
-- 8-3단계 — 배치 실행:
--   SELECT public.advance_withdrawal_states();
--
-- 8-4단계 — 그 신청 행이 그대로인지 확인(★ 핵심 확인):
--   SELECT status, completed_at, personal_data_purged_at
--     FROM public.withdrawal_requests WHERE influencer_id='<시험5 id>';
--   기대: status='scheduled'(그대로), completed_at IS NULL,
--   personal_data_purged_at IS NULL.
--   → 만약 status='done' 인데 personal_data_purged_at 이 NULL 이면
--   **이 작업의 핵심 설계가 깨진 것**이다(파기 실패가 확정을 못 막았다는
--   뜻) — 이 상태로 절대 운영에 적용하지 말 것.
--
-- 8-5단계 — influencers 행이 안 건드려졌는지도 확인:
--   SELECT email, name FROM public.influencers WHERE id='<시험5 id>';
--   기대: 'purge-test-5@reverb.jp' 와 원래 이름 그대로(NULL 아님).
--
-- 8-6단계 — Supabase Dashboard → Logs → Database 에서
--   "purge_failed: admin_account_excluded" 문구가 담긴 WARNING 로그가
--   찍혔는지 확인(운영 관찰 가능성 확인).
--
-- ============================================================
-- [V9] 시험 데이터 완전 정리 — 아래 5개 시험 계정 전부(1~5), 관리자를
--   겸하게 만든 [V6]·[V8] 은 admins 행부터 먼저 지운다(FK 순서).
--   [2026-08-19 갱신] influencers.email 도 이제 파기 후 플레이스홀더로
--   채워지므로(NULL 아님), influencers·auth.users 양쪽을 **같은 LIKE
--   조건 하나로** 함께 잡을 수 있다 — 더 이상 auth.users.id 로 역참조할
--   필요가 없다(이전 버전의 우회가 필요 없어짐):
-- ============================================================
--   DELETE FROM public.admins WHERE email IN ('purge-test-3@reverb.jp','purge-test-5@reverb.jp');
--   DELETE FROM public.withdrawal_requests WHERE influencer_id IN (
--     SELECT id FROM auth.users WHERE email LIKE 'purge-test-%@reverb.jp'
--        OR email LIKE 'withdrawn+%@deleted.reverbjp.invalid'
--   );
--   DELETE FROM public.influencers WHERE email LIKE 'purge-test-%@reverb.jp'
--      OR email LIKE 'withdrawn+%@deleted.reverbjp.invalid';
--   DELETE FROM auth.identities WHERE user_id IN (
--     SELECT id FROM auth.users WHERE email LIKE 'purge-test-%@reverb.jp'
--        OR email LIKE 'withdrawn+%@deleted.reverbjp.invalid'
--   );
--   DELETE FROM auth.users WHERE email LIKE 'purge-test-%@reverb.jp'
--      OR email LIKE 'withdrawn+%@deleted.reverbjp.invalid';
--
-- ============================================================
-- [V-diff] advance_withdrawal_states() 가 350 과 동등한지(section 0·1은
--   무변경) 확인하고 싶으면, 350 파일의 section 0·1 텍스트와 이 파일의
--   해당 구간을 나란히 놓고 diff 뜰 것 — 이 파일 작성 시 350 원문을
--   그대로 복사했으므로 공백까지 일치해야 정상이다.
--
-- ============================================================
-- 롤백
-- ============================================================
-- ⚠️★★★ 아래 1)~3) 은 함수·컬럼을 되돌릴 뿐이다 — **이미 이 함수가
-- 실행돼 개인정보를 비운 행이 있다면, 그 값 자체는 이 롤백으로도 절대
-- 복구되지 않는다**(원래 이름·이메일·전화·주소·SNS·LINE 값은 어디에도
-- 백업되지 않는다 — 그것이 "파기"의 정의다). 롤백은 "앞으로 이 코드가
-- 더 파기하지 않게" 만들 뿐, 이미 지워진 개인정보를 되돌리지 않는다.
--
-- -- 1) advance_withdrawal_states() 를 350 원본으로 되돌린다 — 이 파일이
-- --   350 을 재정의했으므로, DROP 만으로는 되돌아가지 않는다(pg_cron
-- --   job 이 부르는 함수가 통째로 사라진다). supabase/migrations/
-- --   350_advance_withdrawal_states.sql 의
-- --   "CREATE OR REPLACE FUNCTION public.advance_withdrawal_states("
-- --   블록부터 그 COMMENT ON FUNCTION 문장 + REVOKE/GRANT 까지를 그대로
-- --   복사해 SQL 편집기에서 재실행할 것.
--
-- -- 2) purge_withdrawn_personal_data() 함수 삭제:
-- DROP FUNCTION IF EXISTS public.purge_withdrawn_personal_data(uuid);
--
-- -- 3) withdrawal_requests 컬럼 제거:
-- ALTER TABLE public.withdrawal_requests
--   DROP CONSTRAINT IF EXISTS withdrawal_requests_purged_only_when_done;
-- ALTER TABLE public.withdrawal_requests DROP COLUMN IF EXISTS personal_data_purged_at;
--
-- -- 4) 이 파일은 표 구조(스키마 제약)를 전혀 바꾸지 않는다 — 되돌릴
-- --   것이 없다. [2026-08-19 갱신] 초안은 여기서 influencers 19개 칸에
-- --   DROP NOT NULL 을 걸었으나, 개발 데이터베이스를 직접 조회한
-- --   결과(`information_schema.columns`, 2026-08-19) **NOT NULL 인
-- --   칸은 email 하나뿐**이었고, 그 email 도 이제 NULL 이 아니라 인증
-- --   계정과 같은 플레이스홀더로 채우도록 바꿔(위 헤더 「④」 참고)
-- --   제약 자체를 안 건드리게 됐다 — DROP NOT NULL 문장이 파일에서
-- --   완전히 사라졌다. 되돌릴 수 없는 조치는 이제 "이미 파기된 개인
-- --   정보 값 자체"뿐이다(위 경고 그대로).
-- ============================================================
