-- ============================================================
-- 350_advance_withdrawal_states.sql
-- 회원 탈퇴 — 작업 7 (상태 전이 예약 실행)
-- 사양서: docs/specs/2026-08-18-member-withdrawal.md §4-1·§4-6 ④
-- 작업표: docs/specs/2026-08-19-member-withdrawal-breakdown.md 작업 7 +
--         「🔴 새로 드러난 것 — 행사 예약은 탈퇴로 정리되지 않는다」 절
-- 선행(개발서버 적용·확인 완료): 345(withdrawal_requests 표) · 346(withdraw_reason 시드)
--                                347(request_withdrawal 신청 함수, 이 파일이 재정의함)
-- 선행(작성 완료·적용 전): 349(cancel_withdrawal 취소 함수, 이 파일은 건드리지 않음)
-- 다음(이 파일 바로 뒤): 351(메일 예약 등록 — 이 파일에서 분리됨, 아래 참고)
--
-- 산출 계약:
--   public.advance_withdrawal_states() RETURNS jsonb   (인자 없음, pg_cron 전용)
--   반환: { ok:true, advanced_to_scheduled, advanced_to_done,
--          event_tickets_cancelled, event_tickets_cancel_failed }
--   pg_cron job: withdrawal-states-advance-daily (매일 KST 04:45 = UTC 19:45).
--   ⚠️ 「대기→예정」 메일 예약(withdrawal-scheduled-mail-daily)은 **이 파일에
--   없다** — 별도 마이그레이션 351_withdrawal_scheduled_mail_cron.sql 에
--   분리했다(아래 "★★ 메일 발송 경로" 절 + 351 파일 헤더 참고). 이유: 그
--   잡은 외부 Edge Function URL 을 부르는데, 이 저장소의 SQL 실행 안내는
--   늘 "파일을 통째로 복사해 SQL 편집기에 붙여넣기"라(.claude/rules/
--   supabase.md), 한 파일 안에 "여기만 개발에서 건너뛰라"는 경고를 둬도
--   구조적으로 안 지켜진다. 142·204·258 이 이미 같은 이유로 예약 등록을
--   별도 파일로 분리해 둔 관례를 따랐다.
--
-- ============================================================
-- 이 파일이 만드는 것 6가지
-- ============================================================
--   1) withdrawal_requests 에 컬럼 4개 추가 —
--      · event_tickets_cancelled_count · event_tickets_blocked_count
--        (행사 예약 정리 결과)
--      · scheduled_mail_sent_at · scheduled_mail_attempt_count
--        (「대기→예정」 메일 재발송 차단 — 아래 "★★ 메일 발송 경로" 참고)
--   2) public._withdrawal_unpaid_count(uuid) — 미지급 판정 공용 내부 함수(신규).
--      347 에 두 번 인라인으로 적혀 있던 로직을 뽑아냈다.
--   3) public.request_withdrawal(text, text) 재정의 — 2)를 부르도록 바꾼 것 외
--      로직 변경 없음(347 의 새 최신 원본이 이 파일이 된다).
--   4) public._withdrawal_cancel_event_ticket(uuid) + public.advance_withdrawal_states()
--      — 이번 작업의 본체.
--   5) pg_cron 1건 등록(위 「산출 계약」— 상태 전이 잡뿐. 메일 잡은 351).
--   6) 메일 파이프라인 코드 — docs/email-templates/withdrawal-scheduled.html
--      (신규) + supabase/functions/notify-withdrawal-scheduled/(신규 Edge
--      Function) + scripts/sync-email-templates.sh 매핑 등록. **이 파일이
--      만드는 데이터베이스 컬럼(scheduled_mail_sent_at 등)을 그 Edge
--      Function 이 읽고 쓴다** — 실제로 메일이 나가려면 이 파일 + Edge
--      Function 배포 + 351(메일 예약) 셋이 다 갖춰져야 한다(아래 「적용
--      순서」 참고). 이 파일 하나만 적용하고 나머지가 안 갖춰져도 회원에게
--      해는 없다(로그인은 여전히 되어 마이페이지에서 직접 확인 가능) —
--      다만 통지가 그만큼 늦어진다.
--
-- ============================================================
-- ★★ 메일 발송 경로 — 왜 SQL 함수(advance_withdrawal_states) 안에 안 넣었는가
-- ============================================================
--   작업표(docs/specs/2026-08-19-member-withdrawal-breakdown.md) §확인 완료
--   Q2 확정: "메일 — 앱 알림은 안 만든다." 후속 지시: "메일 함수를 새로
--   만든다 — Edge Function + 메일 양식(docs/email-templates/) + _templates/
--   미러 동기화." 이 파일은 그 결정 그대로 구현한다(초안이 한때 notifications
--   표로 잘못 구현했던 적이 있으나 전량 교체됨).
--
--   대기(pending_payout)를 기다리는 회원은 로그인은 되지만(§4-1 — 대기·예정
--   모두 로그인 허용) 앱에 들어와야만 앱 알림을 본다. 게다가 확정(done) 되면
--   로그인 자체가 막힌다(작업 8, 이번 범위 밖). 앱 알림은 "예정으로 넘어갔다"
--   는 사실을 그 사람이 다시 로그인해야만 아는 구조라, 메일만이 확실하게
--   닿는다.
--
--   [SQL 함수 내부에서 net.http_post 를 직접 부르지 않은 이유]
--   이 저장소의 pg_cron→Edge Function 호출은 전부 "cron 이 Edge Function 을
--   직접 부르고, Edge Function 이 모든 DB 조회·발송·기록을 담당"하는 형태다
--   (142·204·258 등 — plpgsql 함수 **안에서** net.http_post 를 호출한 선례는
--   이 저장소에 없다, 전수 검색 결과 top-level cron.schedule 문 2곳뿐).
--   그 관례를 그대로 따랐다. 추가로:
--     · net.http_post 는 비동기 큐잉이다(pg_net 확장 — 요청을 큐에 넣고 즉시
--       반환, 실제 HTTP 응답은 별도 폴링/콜백으로만 알 수 있다). SQL 트랜잭션
--       안에서 "정말 메일이 보내졌는지"를 알 방법이 없다 — 요청사항 "발송에
--       성공한 뒤 표시"를 지키려면, 실제 HTTP 응답을 손에 쥔 Edge Function
--       안에서 성공 판정과 표시(UPDATE)를 함께 해야 한다.
--     · 상태 전이(advance_withdrawal_states)와 메일 발송을 완전히 분리하면,
--       메일이 실패해도(Brevo 장애 등) **상태 전이 자체는 절대 되돌아가지
--       않는다** — 요청사항 4번("전이가 메일 때문에 막히면 안 된다")을 SQL
--       함수가 메일을 아예 모르게 만드는 것으로 구조적으로 보장한다.
--
--   [재발송 차단 방식 — withdrawal_requests.scheduled_mail_sent_at]
--   Edge Function(notify-withdrawal-scheduled)이 매일 09:00 KST 에
--   `status='scheduled' AND scheduled_mail_sent_at IS NULL` 을 조회해 대상을
--   고르고, **발송에 실제로 성공한 뒤에만** 그 컬럼을 채운다(먼저 표시하면
--   실패한 건이 영영 재시도되지 않는다 — 요청사항 3번). 이 방식을 고른 이유
--   (이 저장소의 두 선례와 비교):
--     · `deadline_reminder_email_sent`(마이그레이션 130) 처럼 **별도 표 +
--       UNIQUE 자연키**를 쓰는 방식 — 그쪽은 (인플루언서, 캠페인, 종류,
--       D-N) 4중 키로 **같은 대상에게 여러 번(D-5·D-1 각각) 독립적으로
--       보낼 수 있는 구조**라 자연키가 필요하다.
--     · 이 마이그레이션의 경우는 withdrawal_requests **행 1개당 정확히 1번**
--       (그 행이 pending_payout→scheduled 로 넘어가는 사건은 다시 없다 —
--       취소되면 349 가 새 행을 만들고, 그 새 행은 자기 자신의
--       scheduled_mail_sent_at 을 다시 가진다) 보내면 끝이라, `admins.
--       invite_mail_sent_at`(마이그레이션 244, CLAUDE.md "발송 시각·수신
--       주소는 Edge Function 이 발송 성공 시 기록") 처럼 **행 위의 컬럼 1개**
--       가 더 단순하고 정확하다 — 별도 표·조인이 필요 없다.
--   `scheduled_mail_attempt_count` 는 요청사항 4번("실패를 셀 수 있게")을
--   위한 진단용 카운터다 — 실패할 때마다 Edge Function 이 +1 하고, 다음
--   09:00 실행이 자동으로 다시 시도한다(SQL 쪽에 별도 재시도 로직 불필요 —
--   "아직 안 보냄" 조건 자체가 재시도 큐 역할을 한다).
--
-- ============================================================
-- ① 미지급 판정 공용화 — 347 을 재정의하는 위험을 감수한 이유
-- ============================================================
--   347(request_withdrawal)은 미지급 건수를 세는 동일한 두 SELECT(등록된 정산
--   [pending·on_hold] + _settlement_cert_candidates() 의 미등록 인증성공건)를
--   두 곳(멱등 분기·최종 분기)에 인라인으로 갖고 있다. 이 파일(작업 7)이 세
--   번째 사용처가 된다 — "신청(347) 시점"과 "매일 도는 배치(이 파일)의 재판정
--   시점"이 같은 기준으로 미지급을 세지 않으면, 회원이 신청할 땐 미지급이라
--   pending_payout 이었는데 배치가 다른 기준으로 세어 영영 scheduled 로 못 넘어가는
--   (또는 반대로 미지급이 남았는데 넘어가 버리는) 어긋남이 생긴다 — 요청 본문이
--   가장 우려한 바로 그 상황이다.
--
--   [저울질 — 347 을 CREATE OR REPLACE 로 다시 정의할지]
--   찬성: 두 곳이 다른 기준을 쓰는 위험을 구조적으로 없앤다. 로직은 100% 동일
--     (그대로 뽑아낸 것뿐, 새 판단 없음) — diff 로 검증 가능. request_withdrawal
--     은 아직 사용자에게 노출되지 않은 기능이다(작업 9 회원 탈퇴 화면 · 작업 15
--     시행 전 잠금이 모두 미착수) — 개발서버 시험 계정 외에는 이 함수를 호출할
--     방법이 없다. 이미 검증된 함수를 다시 검증해야 하는 부담이 있지만, 그
--     검증(347 파일 [V2] 절 전체)은 브라우저에서 몇 분이면 재현 가능하다.
--   반대: 347 은 최초 작성 당일 코드 리뷰로 결함 2건을 발견해 고친 이력이 있고,
--     이미 개발서버에서 브라우저로 꼼꼼히 검증까지 마친 함수다(작업표 "작업 5 —
--     브라우저 검증 완료" 절). 다시 손대면 그 검증이 다시 필요해진다.
--   → 채택: **재정의한다.** 이유는 위 반대 사유가 "번거로움"이지 "위험"이 아니기
--   때문이다 — 이 기능은 아직 아무도 실사용하지 않고, 변경도 순수 추출(로직
--   무변경)이라 diff 로 동등성을 기계적으로 확인할 수 있다. 아래 [V4]가 그
--   재검증 절차다.
--
--   ⚠️ 아래 "그 외 설계 메모"의 대칭 사례(행사 예약 취소, 283·288)와 **반대
--   결론**을 낸 이유 — 283·288 은 **운영에 이미 배포된, 8/28~30 행사에서 실제로
--   쓰일 함수**다. 재정의 위험의 무게가 다르다(스코프 밖 프로덕션 회귀 vs 아직
--   아무도 안 쓰는 dev 함수 재검증 부담). 같은 "재정의 위험과 저울질" 이라도
--   기능이 처한 상황에 따라 결론이 갈릴 수 있다는 것을 보여주려고 두 사례를
--   나란히 남긴다.
--
-- ============================================================
-- ② 행사 예약 취소 — 283·288 은 건드리지 않는다(대칭 결정)
-- ============================================================
--   [저울질 — cancel_event_ticket_admin(288)을 공용 내부 함수로 쪼개 재사용할지]
--   찬성: cancel_event_ticket(283 본인 취소) · cancel_event_ticket_admin(288 관리자
--     취소) · 이 배치(작업 7) 셋이 "티켓을 취소하고 대기를 승격한다"는 같은 일을
--     한다. 지금처럼 두면 이 배치가 세 번째 사본이 된다.
--   반대: cancel_event_ticket_admin(288)은 **이미 운영에 배포됐고, 2026-08-28~30
--     행사에서 현장 관리자가 실제로 쓸 함수**다(CLAUDE.md "오프라인 팝업 방문
--     예약(티켓팅)" 항목 — ★운영 배포 완료 2026-08-06). 이 마이그레이션 작성일
--     (2026-08-19)은 행사 시작 9일 전이다. 재정의는 시그니처를 안 바꿔도 함수
--     본문 전체를 다시 검토·재적용해야 하고, 만에 하나 추출 과정에서 미묘한
--     차이가 생기면 **행사 당일 관리자의 취소 버튼이 고장난다** — 그 피해는
--     "dev 함수를 다시 검증해야 하는 번거로움"과 비교할 수 없다.
--   → 채택: **283·288 은 재정의하지 않는다.** 대신:
--     · **공용화된 부분은 그대로 재사용한다** — _promote_next_event_waitlist(slot_id)
--       · _renumber_event_waitlist(slot_id)(둘 다 288 이 이미 내부 함수로 뽑아
--       둔 것). 이 배치도 그 두 함수를 그대로 부른다 — 승격·순번 재정렬 로직을
--       또 베끼지 않는다(요청사항 그대로 준수).
--     · **새로 쓰는 것은 요청이 명시한 대로 "티켓 행을 cancelled 로 바꾸는
--       부분"뿐**이다 — 아래 public._withdrawal_cancel_event_ticket(uuid). 288
--       의 가드 3종(이미 취소됨·이미 입장함·송금완료 정산 있음)과 UPDATE 두
--       문장(event_tickets·applications)을 그대로 옮겨 적었다(288 파일
--       609~742행과 나란히 비교 가능하도록 이 파일 안에도 출처를 명시해 뒀다).
--       이 부분은 짧고(가드 3개 + UPDATE 2개) 자주 안 바뀌는 로직이라, 복제
--       위험보다 프로덕션 함수를 안 건드리는 이득이 크다고 판단했다.
--     · 288 과 다른 점 1가지 — **취소 사유**. 288 은 관리자가 대신 취소할 때
--       applications.cancel_reason_code = 'admin_cancelled' 를 쓰지만, 이 배치는
--       347 이 이미 시드한 'withdrawal'(회원 탈퇴)을 쓴다 — 실제 원인이
--       "관리자가 임의로 취소함"이 아니라 "회원이 탈퇴를 확정함"이기 때문이다.
--       사용자에게는 lookup_values 라벨로 「退会のため」(347 §0 시드)가 보인다.
--     · admin_cancel_note 는 관리자 화면(288의 사용처)이 읽는 자유 텍스트 칸이다.
--       사람이 남긴 메모가 아니므로 고정 문구('会員退会に伴う自動キャンセル' —
--       "회원 탈퇴에 따른 자동 취소")를 남겨 관리자가 "왜 취소됐지"를 알 수
--       있게 한다.
--     · cancelled_by 는 NULL(사람이 아니다) · cancelled_by_role 은 'admin'(288
--       의 CHECK 이 'influencer'|'admin' 둘뿐이라 시스템 처리를 담을 세 번째
--       값이 없다 — 288 의 CHECK 자체를 넓히는 것도 재정의라 이번엔 하지
--       않는다. 'admin' 이 그나마 "회원 본인이 아니다"라는 사실을 정확히
--       반영한다) · cancelled_by_name 은 '退会処理（自動）'(표시용 스냅샷 —
--       288 의 문서화된 관례상 이 칸은 "관리자 취소일 때만 채운다"는 조건에
--       맞춰 반드시 채운다).
--
-- ============================================================
-- ③ 언제 행사 예약 취소를 시도하는가 — 상태 전이와 무관하게 매 실행마다
-- ============================================================
--   두 상태 전이(①·②)에 묶지 않고, 이 함수가 **실행될 때마다 pending_payout·
--   scheduled 인 모든 활성 신청**을 대상으로 시도한다. 이유:
--     · pending_payout 은 미지급 정산 때문에 몇 달씩 이어질 수 있다(사양서
--       §4-1). 이 상태 하나 때문에 8/28~30 행사 좌석이 몇 달간 죽어 있으면
--       "정원이 한정된 팝업에서 자리 하나가 죽는다"(작업표가 지적한 문제)가
--       그대로 재현된다 — done 전이(②)까지 기다릴 수 없다.
--     · 이미 입장했거나(entered_at) 송금완료 정산이 걸려 막힌 티켓은 재시도해도
--       매번 같은 이유로 막힌다 — 매일 재시도해도 손해가 없다(가벼운 조회 3개
--       + 실패 응답 하나뿐, 이 표의 예상 규모에서 성능 문제 없음).
--
-- ============================================================
-- 그 외 설계 메모
-- ============================================================
-- ▶ 잠금 순서 — 349 파일 하단 "잠금 순서" 메모가 이 파일에 명시적으로 지시한
--   순서(influencers 먼저, withdrawal_requests 나중)를 그대로 지킨다. 세 루프
--   (행사 예약 정리 · 전이① · 전이②) 모두 대상 행을 먼저 "잠금 없이" 조회해
--   후보 id 목록만 뽑고, 루프 안에서 건별로 ①influencers FOR UPDATE ②그
--   시점에 다시 조회한 withdrawal_requests 행을 FOR UPDATE 순서로 잠근다.
--   이렇게 하면 회원이 그 순간 request_withdrawal(347)·cancel_withdrawal(349)
--   을 부르는 것과 절대 교착(deadlock)하지 않는다 — 두 함수도 같은 순서로
--   잠그기 때문이다.
--
-- ▶ 재조회(re-check) — 후보 목록을 만든 시점과 실제로 잠그는 시점 사이에 그
--   행의 상태가 바뀔 수 있다(예: 배치가 도는 사이 회원이 cancel_withdrawal 을
--   불러 status='cancelled' 로 바뀜). 그래서 잠근 직후 상태를 다시 확인하고
--   기대한 상태가 아니면 그 행을 건너뛴다(CONTINUE) — 오래된 스냅샷으로
--   잘못된 전이를 만들지 않기 위해서다.
--
-- ▶ 건별 부분 실패 — 347 의 응모 철회 반복문과 같은 방식(BEGIN...EXCEPTION
--   WHEN OTHERS...END 로 건별로 감싼다). 한 회원 처리가 실패해도(예: 예상치
--   못한 데이터 상태) 나머지 회원은 계속 처리된다. 실패는 RAISE WARNING 으로
--   남긴다 — Supabase Logs > Database 에서 확인 가능(166·258 등 기존 예약
--   실행 함수의 RAISE NOTICE 관례와 같되, 이건 "정상 동작 보고"가 아니라
--   "그 행 하나가 실패했다"는 경고라 NOTICE 대신 WARNING 을 쓴다).
--
-- ▶ 멱등 — 함수 전체를 두 번 연속 불러도 같은 결과다. 세 루프 모두 대상
--   조회 조건(status='pending_payout' 등)이 처리 후에는 더 이상 그 조건을
--   만족하지 않도록 상태를 바꾸므로, 두 번째 호출은 자연히 0건을 처리한다.
--   행사 예약 정리도 성공한 티켓은 status='cancelled' 로 바뀌어 다음 실행의
--   후보 조회(status IN ('confirmed','waitlist'))에서 빠진다.
--
-- ▶ 날짜 계산은 전부 일본 시각(Asia/Tokyo) 기준 — scheduled_date =
--   (now() AT TIME ZONE 'Asia/Tokyo')::date + 5, 이는 347 의 계산식과 완전히
--   동일하다(같은 "그날" 정의를 공유해야 한다 — 사양서 §4-1).
--
-- ▶ 이 함수는 SQL 편집기에서 직접 호출 가능하다 — 347·349 와 다른 점이다.
--   347·349 는 auth.uid() 로 "지금 로그인한 사람이 누구인지"를 요구해 SQL
--   편집기(서비스 키, auth.uid() 가 NULL)로는 항상 not_authenticated 만
--   나왔다. 이 함수는 "지금 로그인한 사람"이라는 개념이 없는 시스템 배치라
--   auth.uid() 를 아예 참조하지 않는다 — 그래서 SQL 편집기(postgres 역할로
--   실행됨, GRANT EXECUTE 대상)에서 그대로 호출해 실제 동작을 검증할 수
--   있다. 아래 검증 절차가 347·349 와 달리 SQL 만으로 끝나는 이유다.
--
-- ▶ 작업 10(확정 즉시 개인정보 파기) · 작업 11(재가입 차단) · 작업 12(결과물
--   이미지 6개월 뒤 파기) · 작업 13(PayPal 5년 뒤 파기) 은 전부 이번 범위
--   밖이다. 즉 **이 함수가 status='done' 으로 바꿔도 influencers 행의 이름·
--   이메일·전화·주소 등은 하나도 지워지지 않고, auth.users 의 로그인 이메일도
--   그대로 남는다.** "탈퇴가 확정됐으니 개인정보가 파기됐을 것"이라고
--   오해하지 말 것 — 다음 작업(10)이 나오기 전까지는 done 은 오직 "상태
--   칸이 done 이고 completed_at 이 채워졌다"는 뜻뿐이다. 로그인 차단(작업 8)
--   도 이번 범위 밖이라, done 이 된 뒤에도 지금은 여전히 로그인·응모가 된다
--   (사양서 §4-6 ⑤가 "로그인 차단"을 별도 작업으로 명시한 이유와 정합).
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. withdrawal_requests — 컬럼 4개 추가
--    (행사 예약 정리 결과 2개 + 「대기→예정」 메일 재발송 차단 2개)
-- ============================================================
ALTER TABLE public.withdrawal_requests
  ADD COLUMN IF NOT EXISTS event_tickets_cancelled_count integer NOT NULL DEFAULT 0
    CHECK (event_tickets_cancelled_count >= 0),
  ADD COLUMN IF NOT EXISTS event_tickets_blocked_count   integer NOT NULL DEFAULT 0
    CHECK (event_tickets_blocked_count >= 0),
  ADD COLUMN IF NOT EXISTS scheduled_mail_sent_at         timestamptz NULL,
  ADD COLUMN IF NOT EXISTS scheduled_mail_attempt_count   integer NOT NULL DEFAULT 0
    CHECK (scheduled_mail_attempt_count >= 0);

COMMENT ON COLUMN public.withdrawal_requests.event_tickets_cancelled_count IS
  '[350] 이 신청이 활성(pending_payout/scheduled) 상태로 있는 동안, 상태 전이 예약 '
  '실행(advance_withdrawal_states)이 대신 취소해 준 오프라인 행사 예약(event_tickets) '
  '누적 건수. 매일 실행마다 새로 성공한 건만 더한다(줄어들지 않는다). uncancelled_count '
  '(347, 신청 시점 1회 스냅샷)와는 별개 값 — 그건 신청 그 순간 못 지운 응모 수이고, '
  '이 값은 그 이후 배치가 재시도해 실제로 지운 행사 예약 수다.';
COMMENT ON COLUMN public.withdrawal_requests.event_tickets_blocked_count IS
  '[350] 지금 이 순간 여전히 취소하지 못하고 남아 있는 오프라인 행사 예약 수(이미 '
  '입장했거나 송금완료 정산이 걸린 경우) — 매 실행마다 최신값으로 덮어쓴다(누적 '
  '아님). 0이면 관리자 화면(작업 14, 이번 범위 밖)이 표시를 생략해야 한다(사양서 '
  '§4-4 「0이면 안 그린다」 원칙과 동일).';
COMMENT ON COLUMN public.withdrawal_requests.scheduled_mail_sent_at IS
  '[350] 「대기→예정」 전이 메일이 실제로 성공 발송된 시각. Edge Function '
  '(notify-withdrawal-scheduled, 매일 KST 09:00 cron)이 status=''scheduled'' AND '
  'scheduled_mail_sent_at IS NULL 인 행을 찾아 발송하고, 성공한 뒤에만 이 칸을 '
  '채운다(실패하면 NULL 그대로 남아 다음 실행이 자동 재시도 — 먼저 표시하면 실패한 '
  '건이 영영 재시도 안 됨). 이 컬럼이 곧 재발송 차단 장치다(admins.'
  'invite_mail_sent_at, 마이그레이션 244 와 같은 패턴). advance_withdrawal_states() '
  '자신은 이 칸을 절대 건드리지 않는다 — 메일 성공 여부는 SQL 배치가 알 수 없다 '
  '(위 헤더 「★★ 메일 발송 경로」 참고).';
COMMENT ON COLUMN public.withdrawal_requests.scheduled_mail_attempt_count IS
  '[350] 「대기→예정」 메일 발송 시도 실패 누적 횟수(진단용). Edge Function 이 '
  '실패할 때마다 +1 한다. 계속 쌓이면(이메일 없음 등 영구 실패) 관리자 화면(작업 '
  '14, 이번 범위 밖)이 이 값으로 이상 신호를 보여줄 수 있다.';

-- ============================================================
-- 2. 미지급 판정 공용 내부 함수(신규) — 347 이 두 번 인라인으로 갖고 있던
--    로직을 그대로 옮긴 것. 위 "① 미지급 판정 공용화" 절 참고.
--    내부 전용(밑줄 접두어) — _settlement_cert_candidates() 와 같은 명명
--    관례. authenticated 에 GRANT 하지 않는다 — SECURITY DEFINER 함수 안에서만
--    호출된다(request_withdrawal · advance_withdrawal_states).
-- ============================================================
CREATE OR REPLACE FUNCTION public._withdrawal_unpaid_count(
  p_influencer_id uuid
) RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT (
    -- ① 이미 등록된 정산(정산대기·보류) — 347 §헤더 ②의 판단(on_hold 도
    --   포함) 그대로.
    (SELECT count(*)
       FROM public.settlements s
      WHERE s.influencer_id = p_influencer_id
        AND s.status IN ('pending', 'on_hold'))
    +
    -- ② 인증에는 성공했지만 아직 정산행이 없는 건(347 §헤더 ①의 판단 그대로).
    --   _settlement_cert_candidates() 재정의 계보 232→262→264→300→318→331,
    --   331 이 현재 유효한 원본(feedback_function_redefine_latest_base 메모리
    --   규칙에 따라 331 을 그대로 재사용 — 이 함수는 그걸 다시 베끼지 않는다).
    (SELECT count(*)
       FROM public._settlement_cert_candidates() c
      WHERE c.influencer_id = p_influencer_id
        AND c.is_success)
  )::integer;
$$;

COMMENT ON FUNCTION public._withdrawal_unpaid_count(uuid) IS
  '[350] 인플루언서 1명의 "받을 돈이 남은 건수"(미지급 판정) — 347(신청)·350(배치) '
  '양쪽이 반드시 같은 기준으로 세도록 뽑아낸 공용 내부 함수. 등록된 정산(정산대기·'
  '보류) + 정산행이 아직 없는 인증성공건의 합. 두 곳이 각자 다른 기준으로 세면 '
  '"신청 시점엔 미지급인데 배치는 다르게 판정해 영영 못 넘어가는"(또는 반대) '
  '어긋남이 생긴다. 내부 전용(밑줄 접두어) — REVOKE ALL FROM PUBLIC, authenticated '
  '에 GRANT 하지 않는다.';

REVOKE ALL ON FUNCTION public._withdrawal_unpaid_count(uuid) FROM PUBLIC;

-- ============================================================
-- 3. request_withdrawal(text, text) 재정의 — 347 의 최신 원본이 이 파일이
--    된다. 3)을 부르도록 두 곳(멱등 분기·최종 분기)을 바꾼 것 외에는 347 과
--    바이트 단위로 동일한 로직이다(diff 로 확인 — 아래 [V4] 참고).
-- ============================================================
CREATE OR REPLACE FUNCTION public.request_withdrawal(
  p_reason_code  text DEFAULT NULL,
  p_reason_note  text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_influencer_id        uuid := auth.uid();
  v_inf                  public.influencers%ROWTYPE;
  v_existing             public.withdrawal_requests%ROWTYPE;
  v_reason_valid         boolean;
  v_app_id               uuid;
  v_cancelled_count      integer := 0;
  v_uncancelled_count    integer := 0;
  v_unpaid_count         integer;
  v_status               text;
  v_scheduled_date       date;
  v_today_jst            date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_app_cancel_reason_code CONSTANT text := 'withdrawal';
BEGIN
  -- 1. 본인 확인
  IF v_influencer_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  -- 2. 본인 인플루언서 행 잠금(동시 중복 신청 직렬화) + 감사용 계정 판별
  SELECT * INTO v_inf FROM public.influencers WHERE id = v_influencer_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_inf.is_audit THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'audit_account_blocked');
  END IF;

  -- 3. 멱등 — 이미 활성 신청(대기·예정)이 있으면 재처리하지 않고 그대로 반환
  SELECT * INTO v_existing
    FROM public.withdrawal_requests
   WHERE influencer_id = v_influencer_id
     AND status IN ('pending_payout', 'scheduled')
   ORDER BY requested_at DESC
   LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'ok',                true,
      'status',             v_existing.status,
      'scheduled_date',     v_existing.scheduled_date,
      'cancelled_count',    0,
      'uncancelled_count',  v_existing.uncancelled_count,
      'unpaid_count',       public._withdrawal_unpaid_count(v_influencer_id)
    );
  END IF;

  -- 4. 사유 검증(선택) — [추가결정 A, 347] 값이 있으면 withdraw_reason 시드
  --    (346)의 활성 코드여야 하지만, 값이 없어도(NULL/빈 문자열) 통과한다.
  IF p_reason_code IS NOT NULL AND length(trim(p_reason_code)) > 0 THEN
    SELECT EXISTS (
      SELECT 1 FROM public.lookup_values
       WHERE kind = 'withdraw_reason'
         AND code = trim(p_reason_code)
         AND active = true
    ) INTO v_reason_valid;

    IF NOT v_reason_valid THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_reason');
    END IF;
  END IF;

  -- 5. 철회 가능한 응모만 취소 — 건별 처리, 한 건이 막혀도 계속 간다
  FOR v_app_id IN
    SELECT id FROM public.applications
     WHERE user_id = v_influencer_id
       AND status IN ('pending', 'approved')
  LOOP
    BEGIN
      PERFORM public.cancel_application(v_app_id, v_app_cancel_reason_code, NULL, true);
      v_cancelled_count := v_cancelled_count + 1;
    EXCEPTION WHEN OTHERS THEN
      -- 결과물 승인됨(cancel_application 자체 차단) · 송금완료 정산 있음
      -- (마이그레이션 247 트리거) · 행사(event_mode) 응모(마이그레이션 289
      -- 트리거) 등, 이유를 가리지 않고 "철회 못 한 건"으로만 센다. 행사 응모는
      -- 이 마이그레이션(350)의 배치가 뒤이어 재시도한다(아래 4·5절).
      v_uncancelled_count := v_uncancelled_count + 1;
    END;
  END LOOP;

  -- 6. 미지급 판정 — 공용 내부 함수로 통일(위 3절)
  v_unpaid_count := public._withdrawal_unpaid_count(v_influencer_id);

  IF v_unpaid_count = 0 THEN
    v_status         := 'scheduled';
    v_scheduled_date := v_today_jst + 5;
  ELSE
    v_status         := 'pending_payout';
    v_scheduled_date := NULL;
  END IF;

  INSERT INTO public.withdrawal_requests (
    influencer_id, status, reason_code, reason_note,
    scheduled_date, requested_by_kind, uncancelled_count
  ) VALUES (
    v_influencer_id, v_status, NULLIF(trim(p_reason_code), ''), NULLIF(trim(p_reason_note), ''),
    v_scheduled_date, 'self', v_uncancelled_count
  );

  RETURN jsonb_build_object(
    'ok',                true,
    'status',             v_status,
    'scheduled_date',     v_scheduled_date,
    'cancelled_count',    v_cancelled_count,
    'uncancelled_count',  v_uncancelled_count,
    'unpaid_count',       v_unpaid_count
  );
END;
$$;

COMMENT ON FUNCTION public.request_withdrawal(text, text) IS
  '[350, 347 재정의] 회원(인플루언서) 본인 탈퇴 신청. 로직은 347 과 완전히 동일 — '
  '미지급 판정만 공용 내부 함수 _withdrawal_unpaid_count()로 뽑아냈다(이 함수와 '
  'advance_withdrawal_states 가 같은 기준으로 미지급을 세게 하기 위해서, 위 헤더 '
  '「① 미지급 판정 공용화」 참고). 나머지(본인 확인·감사용 계정 거부·멱등·사유 '
  '검증[선택]·철회 가능한 응모 건별 취소[cancel_application 309 재사용]) 전부 '
  '347 과 동일. 이 함수가 request_withdrawal 의 최신 원본이다.';

REVOKE ALL ON FUNCTION public.request_withdrawal(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_withdrawal(text, text) TO authenticated;

-- ============================================================
-- 4. 오프라인 행사 예약 취소 — 내부 전용(배치가 사람 로그인 없이 부른다)
--    288(cancel_event_ticket_admin)의 가드 3종 + UPDATE 2문장을 그대로
--    옮겨 적었다(위 "② 행사 예약 취소" 절 — 283·288 은 재정의하지 않기로
--    했다). 승격·순번 재정렬은 288 이 이미 뽑아 둔 공용 함수를 그대로 쓴다.
-- ============================================================
CREATE OR REPLACE FUNCTION public._withdrawal_cancel_event_ticket(
  p_ticket_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_ticket      public.event_tickets%ROWTYPE;
  v_slot        public.event_slots%ROWTYPE;
  v_camp_title  text;
BEGIN
  SELECT * INTO v_ticket FROM public.event_tickets WHERE id = p_ticket_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  -- 이미 취소돼 있으면(경쟁 상태 — 예: 이 배치가 후보를 뽑은 뒤 관리자가 먼저
  -- 취소한 경우) 아무 일도 하지 않고 조용히 성공으로 본다. 새로 취소한 것은
  -- 아니므로 호출부(advance_withdrawal_states)는 이 경우를 "새로 성공"으로
  -- 세지 않는다(already_cancelled 플래그로 구분).
  IF v_ticket.status = 'cancelled' THEN
    RETURN jsonb_build_object('ok', true, 'already_cancelled', true);
  END IF;

  -- 288 과 동일한 가드 — 이미 입장한 티켓은 취소하지 않는다(파일 헤더 「②
  -- 행사 예약 취소」 절 참고, 288 파일 헤더의 판단 근거를 그대로 계승).
  IF v_ticket.entered_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_entered');
  END IF;

  -- 288 과 동일한 가드 — 송금완료된 정산이 걸려 있으면 취소하지 않는다.
  IF v_ticket.application_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.settlements s
        WHERE s.application_id = v_ticket.application_id
          AND s.status = 'paid'
     ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'settlement_paid_cannot_cancel');
  END IF;

  -- 슬롯 행을 잠근다 — _promote_next_event_waitlist·_renumber_event_waitlist
  -- (둘 다 288 신설)는 "호출부가 이미 슬롯 행을 잠근 상태"를 전제로 한다.
  SELECT * INTO v_slot FROM public.event_slots WHERE id = v_ticket.slot_id FOR UPDATE;

  -- 289 의 차단 트리거(guard_event_application_status_change)를 통과하기
  -- 위한 표시 — 288 과 동일한 장치.
  PERFORM set_config('reverb.event_ticket_bypass', 'on', true);

  UPDATE public.event_tickets
     SET status            = 'cancelled',
         waitlist_position = NULL,
         cancelled_at      = now(),
         cancelled_by      = NULL,       -- 사람이 아니다(시스템 배치)
         cancelled_by_role = 'admin',    -- CHECK 이 influencer|admin 뿐 — 'admin' 이
                                          -- "회원 본인이 아니다"를 가장 정확히 반영
         cancelled_by_name = '退会処理（自動）',
         admin_cancel_note = '会員退会に伴う自動キャンセル',
         version           = version + 1
   WHERE id = v_ticket.id;

  IF v_ticket.application_id IS NOT NULL THEN
    UPDATE public.applications
       SET status             = 'cancelled',
           previous_status    = CASE v_ticket.status
                                  WHEN 'confirmed' THEN 'approved'
                                  ELSE 'pending'
                                END,
           cancelled_at       = now(),
           cancel_phase       = 'other',
           -- 288 은 'admin_cancelled' 를 쓰지만, 이 배치는 347 이 이미 시드한
           -- 'withdrawal'(회원 탈퇴)을 쓴다 — 실제 원인이 다르다(위 헤더 참고).
           cancel_reason_code = 'withdrawal'
     WHERE id = v_ticket.application_id;
  END IF;

  -- 확정 자리가 빠졌으면 대기 1번 승격(288 이 뽑아 둔 공용 함수 재사용)
  IF v_ticket.status = 'confirmed' THEN
    PERFORM public._promote_next_event_waitlist(v_slot.id);
  END IF;

  -- 남은 대기자 순번 다시 매기기 — 승격 여부와 무관하게 항상 실행
  PERFORM public._renumber_event_waitlist(v_slot.id);

  -- 회원에게 알린다(best-effort — 288 과 같은 판단: 알림 실패가 취소·승격을
  -- 되돌리면 안 된다).
  BEGIN
    IF v_ticket.application_id IS NOT NULL THEN
      SELECT c.title INTO v_camp_title FROM public.campaigns c WHERE c.id = v_ticket.campaign_id;

      INSERT INTO public.notifications (
        user_id, kind, ref_table, ref_id, title, body
      ) VALUES (
        v_ticket.influencer_id,
        'application_cancelled',   -- 283/288 과 같은 기존 종류 재사용(신규 종류 불필요)
        'applications',
        v_ticket.application_id,
        'ご予約がキャンセルされました',
        COALESCE(v_camp_title, 'イベント')
          -- ⚠️ 「확정에 따라」라고 쓰면 안 된다 — 이 취소는 탈퇴가 확정(done)되기
          --    전, 신청만 들어온 단계에서도 매일 돈다(헤더 ③). 그때 「확정됐다」고
          --    하면 아직 취소할 수 있는 사람에게 거짓말이 된다.
          --    한국어 뜻: 「○○ 예약은 탈퇴 신청에 따라 취소되었습니다.
          --    탈퇴를 취소하셔도 이 예약은 되돌아오지 않습니다. 다시 예약하시려면
          --    캠페인 화면에서 신청해 주세요. 문의는 운영팀으로 연락 주세요.」
          || 'のご予約は、退会のお手続きに伴いキャンセルされました。'
          || '退会をキャンセルされた場合も、このご予約は元に戻りません。'
          || '再度ご予約される場合はキャンペーンページからお申し込みください。'
          || 'ご不明な点がございましたら運営までお問い合わせください。'
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'ticket_id', v_ticket.id);
END;
$$;

COMMENT ON FUNCTION public._withdrawal_cancel_event_ticket(uuid) IS
  '[350] 회원 탈퇴 배치(advance_withdrawal_states) 전용 — 로그인 사용자 개념이 없는 '
  'pg_cron 실행 컨텍스트에서 오프라인 행사 예약(event_tickets) 1건을 취소한다. '
  'cancel_event_ticket(283)·cancel_event_ticket_admin(288)은 auth.uid() 를 요구해 '
  '배치에서 못 쓴다(283·288 은 재정의하지 않는다 — 운영에 이미 배포돼 8/28~30 행사에서 '
  '쓰이는 함수라 재정의 위험이 더 크다고 판단, 위 헤더 「② 행사 예약 취소」 참고). '
  '가드 3종(이미 취소·이미 입장·송금완료 정산)과 UPDATE 로직은 288 을 그대로 '
  '옮겨 적은 것이고, 승격·순번 재정렬은 288 이 뽑아 둔 공용 함수 '
  '_promote_next_event_waitlist·_renumber_event_waitlist 를 재사용한다(복제 아님). '
  '내부 전용(밑줄 접두어) — authenticated 에 GRANT 하지 않는다.';

REVOKE ALL ON FUNCTION public._withdrawal_cancel_event_ticket(uuid) FROM PUBLIC;

-- ============================================================
-- 5. advance_withdrawal_states() — 이번 작업의 본체
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
BEGIN
  -- ============================================================
  -- 0. 오프라인 행사 예약 정리 — 활성(대기·예정) 신청 전부, 매 실행마다 시도
  --    (위 헤더 「③ 언제 행사 예약 취소를 시도하는가」 참고 — 상태 전이와
  --    무관하게 매번 재시도한다. done 전이까지 기다리지 않는다.)
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
      -- 잠금 순서: influencers 먼저(349 파일 「잠금 순서」 메모와 동일 순서 유지 —
      -- 위 헤더 참고). is_audit 재확인은 하지 않는다 — 감사용 계정은
      -- request_withdrawal(347/350) 이 애초에 활성 신청 행을 못 만들게 막아서
      -- (audit_account_blocked) 정상 흐름에서는 이 조인 결과에 감사용 계정이
      -- 나타날 수 없다.
      PERFORM 1 FROM public.influencers WHERE id = v_ticket_influencer_id FOR UPDATE;

      -- ★ 잠근 뒤 다시 확인한다 — 위 커서는 스냅샷이라, 목록을 만든 시점과
      --   여기 도달한 시점 사이에 그 회원이 cancel_withdrawal(349) 로 탈퇴를
      --   되돌렸을 수 있다. 349 도 influencers 를 먼저 잠그므로 이 트랜잭션이
      --   끝날 때까지 기다렸다 통과하는데, 그 사이 여기서 예약을 이미 취소해
      --   버리면 **탈퇴는 정상적으로 취소됐는데 팝업 좌석만 사라진다**.
      --   정원이 한정된 행사라 되돌릴 방법이 없다(대기자가 이미 승격됨).
      --   ⚠️ 아래 1·2 섹션은 처음부터 이 재확인을 하고 있었다. 이 섹션만
      --      빠져 있었다(2026-08-19 리뷰 지적).
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

  -- 지금 시점에 여전히 막혀 있는 행사 예약 수를 신청 행마다 다시 세어
  -- 최신값으로 덮어쓴다(누적 아님 — 위 컬럼 주석 참고).
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
  -- 1. pending_payout → scheduled — 미지급이 0건이 된 신청
  -- ============================================================
  FOR v_cand_id, v_cand_influencer_id IN
    SELECT wr.id, wr.influencer_id
      FROM public.withdrawal_requests wr
     WHERE wr.status = 'pending_payout'
     ORDER BY wr.requested_at
  LOOP
    BEGIN
      -- 잠금 순서: influencers 먼저(위 헤더 참고)
      PERFORM 1 FROM public.influencers WHERE id = v_cand_influencer_id FOR UPDATE;

      SELECT * INTO v_req FROM public.withdrawal_requests WHERE id = v_cand_id FOR UPDATE;

      -- 후보를 뽑은 뒤 상태가 바뀌었으면(예: 그 사이 회원이 취소) 건너뛴다.
      IF NOT FOUND OR v_req.status <> 'pending_payout' THEN
        CONTINUE;
      END IF;

      v_unpaid := public._withdrawal_unpaid_count(v_cand_influencer_id);

      IF v_unpaid = 0 THEN
        v_scheduled_date := v_today_jst + 5;

        UPDATE public.withdrawal_requests
           SET status = 'scheduled', scheduled_date = v_scheduled_date
         WHERE id = v_req.id;

        -- ⚠️ 여기서 메일을 직접 보내지 않는다 — 위 헤더 「★★ 메일 발송
        -- 경로」 참고. 이 UPDATE 로 scheduled_mail_sent_at 은 그대로 NULL
        -- 남고(그 칸은 345/350 이 만든 새 행이든 기존 행이든 기본값이 NULL
        -- 이라 별도로 비울 필요가 없다), 다음 KST 09:00 에 도는 별도 Edge
        -- Function(notify-withdrawal-scheduled)이 status='scheduled' AND
        -- scheduled_mail_sent_at IS NULL 조건으로 이 행을 집어 메일을
        -- 보낸다. SQL 배치(이 함수)는 메일 발송·실패를 전혀 모른다 —
        -- 상태 전이가 메일 때문에 막히지 않는다는 것을 구조로 보장한다.

        v_advanced_scheduled := v_advanced_scheduled + 1;
      END IF;
      -- v_unpaid > 0 이면 여전히 대기 — 아무것도 하지 않고 다음 실행을 기다린다.
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[advance_withdrawal_states] pending_payout row % failed: %', v_cand_id, SQLERRM;
    END;
  END LOOP;

  -- ============================================================
  -- 2. scheduled → done — 예정일이 지난 신청
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

      -- ⚠️ 개인정보 파기(작업 10)·재가입 차단 해시(작업 11)·로그인 차단(작업 8)
      -- 은 전부 이번 범위 밖 — 이 UPDATE 는 상태 칸만 바꾼다. 위 헤더 마지막
      -- 절 참고.
      UPDATE public.withdrawal_requests
         SET status = 'done', completed_at = now()
       WHERE id = v_req.id;

      v_advanced_done := v_advanced_done + 1;
    EXCEPTION WHEN OTHERS THEN
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
  '[350] 회원 탈퇴 상태 전이 예약 실행. 매일 1회(pg_cron): ①pending_payout 이고 '
  '미지급 0건이면 scheduled(예정일=오늘[JST]+5일)로 전이 ②scheduled 이고 예정일이 '
  '지났으면 done(completed_at=now())으로 전이 ③매 실행마다 활성(pending_payout/'
  'scheduled) 신청의 오프라인 행사 예약을 재시도 취소. 메일 발송은 이 함수가 하지 '
  '않는다 — status=''scheduled'' AND scheduled_mail_sent_at IS NULL 조건을 별도 '
  'Edge Function(notify-withdrawal-scheduled, 매일 KST 09:00 cron)이 읽어 처리한다 '
  '(위 헤더 「★★ 메일 발송 경로」 참고, 상태 전이가 메일 실패로 막히지 않게 하기 '
  '위한 의도적 분리). 파기(작업 10·12·13)·재가입 차단(작업 11)·로그인 차단(작업 8)은 '
  '이번 범위 밖 — done 이 돼도 개인정보는 지워지지 않는다. SQL 편집기에서 직접 호출 '
  '가능(auth.uid() 를 참조하지 않음 — 347·349 와 다른 점). pg_cron job: '
  'withdrawal-states-advance-daily.';

REVOKE ALL ON FUNCTION public.advance_withdrawal_states() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.advance_withdrawal_states() TO postgres;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- pg_cron 등록 — 상태 전이(SQL 내부 전용, 순수 DB 작업)
-- (트랜잭션 밖 — cron.schedule 은 자체 커밋. 166·243·258·286 과 동일 패턴 —
-- 15분 간격으로 시간 분산된 기존 예약 정리 작업들 뒤에 배치)
--   influencer-flags-retention-daily             = UTC 19:00 (KST 04:00, 166)
--   admin-password-reset-requests-retention-daily = UTC 19:15 (KST 04:15, 243)
--   campaign-soft-delete-purge-daily              = UTC 19:30 (KST 04:30, 258)
--   event-tickets-retention-daily                 = UTC 19:30 (KST 04:30, 286)
--   withdrawal-states-advance-daily(본 작업)       = UTC 19:45 (KST 04:45) ← 신규
--
-- 이 job 은 외부 URL 을 부르지 않는(순수 SQL) 함수라 개발·운영 양쪽에 그대로
-- 등록해도 안전하다. 「대기→예정」 메일 예약(외부 Edge Function 을 부르는 잡)
-- 은 **별도 파일 351_withdrawal_scheduled_mail_cron.sql** 에 있다 —
-- 142·204·258 이 세운 관례(예약 등록 자체가 외부 URL 을 부르면 별도 파일로
-- 분리 — 204 의 「개발: 미등록」 헤더가 그 관례를 잘 보여준다)를 그대로
-- 따른 것이다. 한 파일 안에 「여기만 건너뛰라」는 경고를 두는 방식은 이
-- 저장소의 SQL 실행 안내가 늘 "파일을 통째로 복사해 붙여넣기"이기 때문에
-- 구조적으로 지켜지지 않는다(.claude/rules/supabase.md 「마이그레이션/SQL
-- 실행 안내 시 절대경로 명시」) — 그래서 파일 자체를 나눴다.
-- ============================================================
SELECT cron.unschedule(jobid)
FROM   cron.job
WHERE  jobname = 'withdrawal-states-advance-daily';

SELECT cron.schedule(
  'withdrawal-states-advance-daily',
  '45 19 * * *',                        -- 매일 UTC 19:45 (= KST 04:45)
  $$SELECT public.advance_withdrawal_states();$$
);

-- ============================================================
-- 적용 순서 (이 파일 350)
--   1. 개발 데이터베이스에 이 파일 전체 적용 (테이블 컬럼·함수 3개·위 cron
--      전부 — 외부 URL 이 없어 안전, 환경 동기화 목적).
--   2. 운영 배포(main 머지) 후, 운영 데이터베이스에 이 파일 전체 적용.
--   3. 그 다음 351(메일 예약)로 이어간다 — 351 파일 헤더의 「적용 순서」 참고
--      (Edge Function 배포가 351 의 선행 조건이다).
-- ============================================================

-- ============================================================
-- 적용 후 확인 (⚠️ 「적용 성공」은 「동작 확인」이 아니다 — .claude/rules/supabase.md
-- 「신규 데이터베이스 함수는 적용 성공이 동작 확인이 아니다」. 1단계씩 순서대로
-- 실행하며 결과를 확인할 것 — 한 번에 다 실행하지 말 것)
-- ============================================================
--
-- [V0] (SQL 편집기 가능 — 읽기 전용) 함수 생성·서명 확인
--   SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args,
--          pg_get_function_result(p.oid) AS returns
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public'
--      AND p.proname IN ('advance_withdrawal_states', '_withdrawal_cancel_event_ticket',
--                         '_withdrawal_unpaid_count', 'request_withdrawal')
--    ORDER BY p.proname;
--   기대: 4행 전부 존재. request_withdrawal 의 args 는 347 검증 때와 동일해야
--   한다(p_reason_code text DEFAULT NULL::text, p_reason_note text DEFAULT NULL::text).
--
-- [V0-b] (SQL 편집기 가능 — 읽기 전용) 신규 컬럼 확인
--   SELECT column_name, data_type, column_default
--     FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='withdrawal_requests'
--      AND column_name IN ('event_tickets_cancelled_count', 'event_tickets_blocked_count',
--                           'scheduled_mail_sent_at', 'scheduled_mail_attempt_count');
--   기대: 4행. count 3종은 default 0, scheduled_mail_sent_at 은 default NULL.
--
-- [V0-c] (SQL 편집기 가능 — 읽기 전용) pg_cron 등록 확인 — 이 파일이 등록하는
--   건 상태 전이 잡 하나뿐이다(개발·운영 어디에 적용했든 항상 존재해야 한다).
--   메일 잡(withdrawal-scheduled-mail-daily)은 이 파일에 없다 — 351 파일의
--   검증 절이 따로 확인한다.
--   SELECT jobid, jobname, schedule, active
--     FROM cron.job WHERE jobname = 'withdrawal-states-advance-daily';
--   기대: 1행, schedule='45 19 * * *', active=true.
--
-- ============================================================
-- [V1] pending_payout → scheduled 전이 확인 (SQL 편집기로 전부 가능 —
--   advance_withdrawal_states 는 auth.uid() 를 참조하지 않는다)
-- ============================================================
-- 1단계 — 시험용 pending_payout 행을 하나 만든다(정산이 없는 임의 인플루언서로,
--   미지급이 정말 0인지 먼저 확인할 것 — 아래 조회로 그 인플루언서의 정산이
--   없는지 본다):
--   SELECT count(*) FROM public.settlements
--    WHERE influencer_id = '<시험 인플루언서 id>' AND status IN ('pending','on_hold');
--   → 0이어야 아래 [V1-2]에서 scheduled 전이가 자연스럽게 재현된다.
--
-- 1-2단계 — 시험 행 삽입(withdrawal_requests 는 직접 쓰기 정책이 없어 서비스
--   키로만 INSERT 가능 — SQL 편집기는 서비스 키이므로 가능하다):
--   INSERT INTO public.withdrawal_requests (influencer_id, status, requested_by_kind)
--     VALUES ('<시험 인플루언서 id>', 'pending_payout', 'self');
--
-- 1-3단계 — 배치 실행:
--   SELECT public.advance_withdrawal_states();
--   기대: advanced_to_scheduled >= 1 (다른 활성 대기 건이 개발서버에 이미
--   있을 수 있으므로 정확히 1이 아니어도 됨 — 아래 [V1-4]로 그 행 하나를
--   직접 확인).
--
-- 1-4단계 — 그 행이 실제로 바뀌었는지 확인:
--   SELECT id, status, scheduled_date FROM public.withdrawal_requests
--    WHERE influencer_id = '<시험 인플루언서 id>' ORDER BY requested_at DESC LIMIT 1;
--   기대: status='scheduled', scheduled_date = 오늘(JST) + 5일.
--
-- 1-5단계 — ⚠️ 이 함수는 메일을 보내지 않는다(위 헤더 「★★ 메일 발송
--   경로」 참고) — 여기서는 메일 대상 조건이 정확히 걸렸는지만 SQL 로 확인한다.
--   실제 발송 확인은 이 파일 하단 「[V5] 메일 발송 확인 — 운영 적용 후 전용」
--   절로 분리했다(개발서버 발송 시험 금지 정책):
--   SELECT id, status, scheduled_date, scheduled_mail_sent_at, scheduled_mail_attempt_count
--     FROM public.withdrawal_requests
--    WHERE influencer_id = '<시험 인플루언서 id>' ORDER BY requested_at DESC LIMIT 1;
--   기대: status='scheduled', scheduled_mail_sent_at IS NULL(아직 아무도 안 보냈다 —
--   Edge Function 을 아직 안 불렀으므로), scheduled_mail_attempt_count = 0.
--
-- 1-6단계 — ★ 멱등 확인. 같은 배치를 한 번 더 실행:
--   SELECT public.advance_withdrawal_states();
--   기대: 반환값의 advanced_to_scheduled 에 방금 그 인플루언서 건이 다시
--   포함되지 않는다(이미 scheduled 라 후보 조회에서 빠짐) — scheduled_mail_sent_at
--   은 이 함수와 무관하므로 여기서 다시 확인할 것이 없다(변하지 않아야 정상).
--
-- ============================================================
-- [V2] scheduled → done 전이 확인
-- ============================================================
-- 2-1단계 — [V1]에서 만든 행의 예정일을 어제로 앞당긴다:
--   UPDATE public.withdrawal_requests
--      SET scheduled_date = (now() AT TIME ZONE 'Asia/Tokyo')::date - 1
--    WHERE influencer_id = '<시험 인플루언서 id>' AND status = 'scheduled';
--
-- 2-2단계 — 배치 재실행:
--   SELECT public.advance_withdrawal_states();
--   기대: advanced_to_done >= 1.
--
-- 2-3단계 — 확인:
--   SELECT id, status, completed_at FROM public.withdrawal_requests
--    WHERE influencer_id = '<시험 인플루언서 id>' ORDER BY requested_at DESC LIMIT 1;
--   기대: status='done', completed_at IS NOT NULL.
--
-- 2-4단계 — ★ 멱등 확인. 한 번 더 실행:
--   SELECT public.advance_withdrawal_states();
--   기대: advanced_to_done 에 그 건이 다시 포함되지 않는다(이미 done).
--
-- 2-5단계 — 시험 데이터 정리(운영에서는 하지 말 것 — 개발서버 정리 전용):
--   DELETE FROM public.withdrawal_requests WHERE influencer_id = '<시험 인플루언서 id>';
--
-- ============================================================
-- [V3] 행사 예약 취소 확인 — ⚠️ event_tickets 도 직접 쓰기 정책이 없어
--   서비스 키(SQL 편집기)로만 시험 행을 만들 수 있다. 실제 예약은
--   reserve_event_ticket(로그인 필요)로 만드는 게 정석이지만, 이 함수
--   자체의 취소 로직만 확인하려면 아래처럼 최소 시험 행을 직접 구성해도
--   된다(운영에서는 하지 말 것).
-- ============================================================
-- 3-1단계 — 8/28~30 행사 캠페인·타임이 아직 없다면(CLAUDE.md "오프라인 팝업"
--   항목 — 운영 데이터 0건) 개발서버에 event_mode=true 캠페인 1개 · 그 캠페인의
--   event_slots 1개를 먼저 만든다(관리자 화면 또는 SQL로 — 이 파일 범위 밖이라
--   생략. 이미 있다면 아래로 건너뛴다).
--
-- 3-2단계 — 시험 인플루언서로 그 타임에 실제 예약(reserve_event_ticket, 로그인
--   필요 — 브라우저 콘솔)을 만들거나, 이미 있는 예약 하나를 고른다:
--   SELECT id, influencer_id, status, application_id FROM public.event_tickets
--    WHERE status IN ('confirmed','waitlist') LIMIT 5;
--
-- 3-3단계 — 그 인플루언서로 탈퇴 신청을 만든다(위 [V1] 1-2단계와 같은 방식,
--   같은 influencer_id 사용). 이 시점에 request_withdrawal(347/350) 이 정상
--   흐름으로 이 응모를 철회하려 시도하면 event_status_change_blocked 로 막혀
--   uncancelled_count 에 잡힐 것이다(작업 5 검증 때 확인된 동작) — 그러니
--   이번엔 [V1] 1-2단계처럼 INSERT 로 행을 직접 만드는 편이 event ticket 자체를
--   건드리지 않아 더 깔끔하다.
--
-- 3-4단계 — 배치 실행:
--   SELECT public.advance_withdrawal_states();
--   기대: 반환값의 event_tickets_cancelled >= 1.
--
-- 3-5단계 — 티켓이 실제로 취소됐는지 확인:
--   SELECT id, status, cancelled_by, cancelled_by_role, cancelled_by_name,
--          admin_cancel_note, waitlist_position
--     FROM public.event_tickets WHERE id = '<3-2단계에서 고른 ticket id>';
--   기대: status='cancelled', cancelled_by IS NULL, cancelled_by_role='admin',
--   cancelled_by_name='退会処理（自動）'.
--
-- 3-6단계 — 짝이 되는 신청도 취소됐는지:
--   SELECT status, cancel_reason_code, cancel_phase FROM public.applications
--    WHERE id = (SELECT application_id FROM public.event_tickets WHERE id = '<ticket id>');
--   기대: status='cancelled', cancel_reason_code='withdrawal', cancel_phase='other'.
--
-- 3-7단계 — 신청 행에 남은 카운트 확인:
--   SELECT event_tickets_cancelled_count, event_tickets_blocked_count
--     FROM public.withdrawal_requests
--    WHERE influencer_id = '<3-3단계 influencer_id>'
--    ORDER BY requested_at DESC LIMIT 1;
--   기대: event_tickets_cancelled_count >= 1, event_tickets_blocked_count = 0
--   (이 인플루언서에게 다른 막힌 예약이 없다면).
--
-- 3-8단계 — (선택) already_entered 가드 확인 — 다른 시험 티켓의 entered_at 을
--   직접 채운 뒤 같은 인플루언서로 탈퇴 신청을 만들고 배치를 재실행해
--   event_tickets_blocked_count 가 늘어나는지 확인. 시험 후 원복.
--
-- 3-9단계 — 시험 데이터 정리(운영에서는 하지 말 것):
--   DELETE FROM public.withdrawal_requests WHERE influencer_id = '<influencer_id>';
--   (event_tickets·applications 시험 행은 필요에 따라 별도로 정리 — 취소는
--   편도라 되돌릴 수 없다는 점은 347·349 와 동일)
--
-- ============================================================
-- [V4] request_withdrawal 재정의가 347 과 동등한지 재검증 — ★ 347 을 다시
--   손댔으므로 347 파일의 [V2] 검증 ①~⑦ 전체를 다시 한 번 통과시킬 것
--   (SQL 편집기 불가 — 로그인한 시험 인플루언서 계정 브라우저 콘솔에서).
--   특히 ⑦(모집 기간 지난 응모를 사유 없이 철회)이 여전히 통과하는지가
--   핵심 — 이 재정의가 그 로직을 한 글자도 바꾸지 않았다는 걸 실제로
--   확인하는 절차다.
--
-- ============================================================
-- [V5] 메일 발송 확인 — ★★★ 351 파일로 이동
--   ============================================================
--   「대기→예정」 메일이 실제로 나가는지 확인하는 절차(운영 전용 — 개발서버
--   발송 시험 금지)는 이 파일이 아니라 **351_withdrawal_scheduled_mail_cron.sql
--   의 검증 절**에 있다 — 그 잡(withdrawal-scheduled-mail-daily)의 등록 자체가
--   351 로 옮겨졌기 때문에, 그 잡을 확인하는 절차도 함께 옮겼다(한 잡의
--   등록과 검증이 서로 다른 파일에 있으면 다음 사람이 351만 보고 검증
--   절차가 없다고 오해한다).
--
--   이 파일(350)의 위 [V0]~[V4]는 전부 "메일 없이 상태 전이만" 확인하는
--   절차이고 그것으로 끝이다 — 350 을 적용하는 것만으로는 메일이 전혀
--   안 나간다(정상. 그게 이 파일의 책임 범위다).
--
-- ============================================================
-- 롤백
-- ============================================================
-- ⚠️★ 351 을 적용했다면 **351부터** 먼저 롤백할 것 — 351 의 메일 잡이
-- 여기서 지우는 컬럼(scheduled_mail_sent_at 등)을 읽고 쓴다. 이 파일(350)
-- 을 먼저 롤백해 컬럼이 사라지면, 아직 살아있는 351 의 cron 이 다음 실행
-- 때마다 컬럼 없음 오류로 실패한다. 순서: 351 언스케줄 → 350 롤백.
--
-- -- 1) pg_cron 해제(이 파일이 등록한 건 상태 전이 잡 하나뿐)
-- SELECT cron.unschedule('withdrawal-states-advance-daily');
--
-- -- 2) 이 파일이 만든 함수 3개 삭제
-- DROP FUNCTION IF EXISTS public.advance_withdrawal_states();
-- DROP FUNCTION IF EXISTS public._withdrawal_cancel_event_ticket(uuid);
-- DROP FUNCTION IF EXISTS public._withdrawal_unpaid_count(uuid);
--
-- -- 3) request_withdrawal 을 347 원본으로 되돌린다 — ⚠️ 이 파일이 347 을
-- --   재정의했으므로, DROP 만으로는 되돌아가지 않는다(client 가 쓰는 함수가
-- --   통째로 사라진다). supabase/migrations/347_request_withdrawal_function.sql
-- --   의 "CREATE OR REPLACE FUNCTION public.request_withdrawal(" 블록부터 그
-- --   COMMENT ON FUNCTION 문장까지를 그대로 복사해 SQL Editor 에서 재실행할 것.
--
-- -- 4) withdrawal_requests 컬럼 4개 제거 — ⚠️ 351 이 아직 살아있으면 먼저
-- --   351을 롤백할 것(위 경고 참고).
-- ALTER TABLE public.withdrawal_requests DROP COLUMN IF EXISTS event_tickets_cancelled_count;
-- ALTER TABLE public.withdrawal_requests DROP COLUMN IF EXISTS event_tickets_blocked_count;
-- ALTER TABLE public.withdrawal_requests DROP COLUMN IF EXISTS scheduled_mail_sent_at;
-- ALTER TABLE public.withdrawal_requests DROP COLUMN IF EXISTS scheduled_mail_attempt_count;
--
-- -- 5) Edge Function·템플릿은 코드 롤백(git revert)으로 처리 — 이 SQL
-- --   파일이 관리하는 영역이 아니다. supabase/functions/notify-withdrawal-
-- --   scheduled/ 를 배포에서 내리려면 별도로 그 함수만 삭제(Dashboard 또는
-- --   supabase functions delete notify-withdrawal-scheduled --project-ref <ref>).
--
-- ⚠️ 이 함수가 이미 실행돼 상태를 바꿨다면(scheduled·done 전이, 행사 예약
-- 취소), 함수·컬럼을 지워도 그 부수효과는 되돌아오지 않는다(347·349 롤백
-- 절과 같은 성격) — 필요하면 위 검증 절차의 DELETE 문으로 별도 정리할 것.
-- 메일이 이미 나갔다면(scheduled_mail_sent_at 이 채워진 행) 그 발송 자체는
-- 당연히 되돌릴 수 없다 — 회원이 이미 받은 메일이다.
