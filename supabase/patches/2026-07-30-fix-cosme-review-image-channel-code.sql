-- =============================================================================
-- 패치: @cosme 리뷰 인증샷 채널 코드 교정 (channel-96r9y3 → cosme)
-- 작성일: 2026-07-30
-- 대상 서버: 운영 (도쿄 nrwtujmlbktxjgdwlpjj) — 반드시 개발(qysmxtipobomefudyixw)에서
--           먼저 리허설 후 되돌리고(rollback), 운영에서 시행(commit)한다.
--
-- 사양서   : docs/specs/2026-07-30-review-image-channel-code-drift.md
-- 인수인계 : docs/specs/2026-07-30-HANDOFF-review-image-channel-drift.md
-- 참고 선례: 2026-05-29-backfill-review-image-post-channel.sql (같은 성질의 백필,
--           단계별 begin/rollback→commit 검증 형식을 그대로 따름)
-- 참고 형식: 162_review_image_channel_assign.sql ('channel_assign' 이력 기록 형식)
--
-- ── 배경 ──────────────────────────────────────────────────────────────────
-- @cosme 채널의 기준 데이터(lookup_values) 코드가 channel-96r9y3(구) → cosme(신)
-- 로 바뀌었는데, 그때 이미 제출된 kind='review_image' 결과물의 post_channel 값은
-- 함께 옮겨지지 않았다. 그 결과 ①인플루언서 활동관리 화면 ②관리자 인증성공 판정
-- ③정산 후보 판정, 3곳에서 해당 결과물이 동시에 누락됐다. 대상 81행은 전부 이미
-- 관리자가 승인(status='approved')한 행이다.
--
-- ── 그룹 정의 ──────────────────────────────────────────────────────────────
--   A 그룹 (55건, ★이 패치의 교정 대상)
--     kind='review_image' AND post_channel='channel-96r9y3' 이고,
--     같은 application_id 에 post_channel='cosme' 행이 없는 것
--   B 그룹 (26건, ★이 패치가 절대 건드리지 않는 것)
--     같은 application_id 에 옛 코드 + 새 코드가 둘 다 있는 것. 옛 코드를 새
--     코드로 바꾸면 UNIQUE 제약(deliverables_review_image_app_channel_uniq,
--     UNIQUE (application_id, post_channel) WHERE kind='review_image') 위반으로
--     배치 전체가 중단된다. 처리 방침은 사용자 미결(사양서 §사용자 확인 필요 2) —
--     이 패치의 모든 UPDATE 는 B 그룹을 SQL 조건(NOT EXISTS)으로 미리 배제하며,
--     제약 위반을 감지 수단으로 쓰지 않는다.
--
-- 운영 기대 건수: A 그룹 55건 (시험 1건 + 일괄 54건).
--   ⚠️ 개발서버 리허설에서 나오는 A/B 건수는 복제 시점 차이로 운영과 다를 수
--      있다. 개발 리허설 결과를 운영 기대값(55/54)으로 대체하지 말 것.
--
-- ── status 는 이 패치 전체에서 절대 UPDATE 하지 않는다 ──────────────────────
-- 목적은 채널 값 교정뿐이다. 이 원칙 덕에 deliverables 의 상태 전이 트리거
--   trg_deliverable_status_event → record_deliverable_status_event() (최신 정의 073)
--   trg_deliverable_notify       → notify_deliverable_status()        (최신 정의 159)
-- 둘 다 함수 첫 줄이 `IF OLD.status = NEW.status THEN RETURN NEW;` 라서 미발동한다
-- (정적 확인 완료 — 인수인계 문서 §「이미 확정된 사실」). 아래 0단계에서 실행 직전
-- 한 번 더 재확인한다.
-- 참고: trg_deliverables_updated_at 은 updated_at 만 갱신하므로 무해하고,
--       trg_deliverable_deadline_guard(274, BEFORE INSERT OR UPDATE)는 운영에는
--       아직 미적용이며, 적용돼 있어도 auth.uid() IS NULL(SQL Editor=서비스 키)
--       이면 통과하므로 이 패치를 막지 않는다.
--
-- ── 교정 이력 기록 방식 (판단 근거) ─────────────────────────────────────────
-- deliverable_events 에 action='channel_assign' 으로 **직접 INSERT** 한다
-- (아래 2·3단계 UPDATE 문에 CTE 로 원자적으로 묶어서 실행 — UPDATE 된 행과
--  이력 행이 항상 1:1로 정확히 대응한다).
--   ① from_status/to_status CHECK 확인:
--      deliverable_events.from_status/to_status 는
--        CHECK (... IN ('pending','approved','rejected'))
--      만 있고 "from_status <> to_status" 같은 제약은 없다(035번 정의 확인).
--      상태 불변 그대로 from_status=to_status='approved' 로 넣어도 위반되지 않는다.
--   ② actor_id 는 `uuid REFERENCES auth.users(id) ON DELETE SET NULL` 로
--      NOT NULL 이 아니다(035번 정의 확인). SQL Editor(서비스 키)는 auth.uid()
--      가 NULL 이므로 actor_id=NULL 로 넣는다 — 제약 위반 없음.
--   ③ 162번(assign_review_image_channel RPC)의 channel_assign 이력 INSERT 를
--      그대로 참고: action='channel_assign', from_status/to_status = 상태 불변값,
--      reason 에 "이전 채널 → 이후 채널" 텍스트. 이 패치는 그 형식을 그대로 쓴다.
--      'channel_assign' 액션 자체는 마이그레이션 162 에서 이미 CHECK 에 추가되어
--      운영에 존재하므로 이 패치에서 새 CHECK 확장은 불필요하다.
--   ④ RLS 는 "INSERT는 SECURITY DEFINER 트리거/함수에서만" 이라 애플리케이션
--      경로에서는 직접 INSERT 가 막히지만, 이 패치는 SQL Editor(서비스 키,
--      RLS 우회)로 실행하는 일회성 운영 교정이라 직접 INSERT 가 가능하고,
--      035·162 마이그레이션 자체도 같은 방식으로 이 테이블에 직접 기록한다.
-- → 결론: 제약을 위반하지 않으므로 "기록하지 않고 대안을 찾는" 상황이 아니다.
--   따라서 대안(예: 별도 감사 테이블)은 필요 없다.
--
-- ── 실행 절차 ─────────────────────────────────────────────────────────────
--   ⚠️ 알림 확인은 반드시 **커밋 뒤 별도 실행**으로 한다. 이유 2가지:
--      ① SQL Editor 는 여러 문장을 한 번에 실행하면 마지막 문장의 결과만 보여줘,
--         "트랜잭션 안에서 SELECT 로 확인하고 커밋" 이 한 번의 실행으로 성립하지
--         않는다(확인 없이 커밋되는 것과 같아진다).
--      ② 알림은 AFTER 트리거가 만들므로, UPDATE 와 같은 문장 안에서는 볼 수 없다.
--      시험 대상이 1건뿐이라 "커밋 → 확인 → 문제면 그 1건만 되돌리기" 가
--      가장 확실하다. 되돌리기 SQL 은 1단계 바로 아래에 붙여 뒀다.
--
--   [개발 리허설] — 문법 검증 + 알림 미발동 실측이 목적
--     0단계 → 1단계(개발의 A그룹 id 로 교체해 COMMIT) → 알림 확인
--     → ★1-R(개발 전용 되돌리기) 를 반드시 실행해 흔적을 지운다.
--     ⚠️ 개발에 교정 흔적을 남기면 다음 조사가 오염된다(이번 조사에서 개발/운영
--        데이터 오인 사고가 이미 한 번 있었다). 2단계(일괄)는 개발에서 돌리지 않는다.
--   [운영 시행]
--     0단계(재확인, 읽기전용)
--     → 1단계(시험 1건, COMMIT) → 알림 확인 → 0 이 아니면 1-R 로 되돌리고 중단
--     → 2단계(나머지 54건, COMMIT)
--     → 3단계(검증 4종, 읽기전용) 순서 그대로.
--
-- ── 롤백 방법 ─────────────────────────────────────────────────────────────
-- 파일 맨 아래 "전체 롤백" 섹션 참고. 요지:
--   ① 이 패치가 INSERT 한 deliverable_events(action='channel_assign', 이 패치의
--      reason 마커) 를 먼저 지운다
--   ② 이 패치가 UPDATE 한 55행의 post_channel 을 channel-96r9y3 로 되돌린다
-- =============================================================================


-- =============================================================================
-- 0단계 — 실행 직전 재확인 (읽기 전용, 개발·운영 공통, 필수)
-- =============================================================================

-- 0-1. 상태 전이 트리거 두 함수가 여전히 "상태 불변 시 미발동" 조건을 갖고
--      있는지 재확인한다. 각 함수 본문(prosrc) 첫 줄 근처에
--      "IF OLD.status = NEW.status THEN RETURN NEW" 형태가 보여야 한다.
--      ⚠️ 하나라도 false 면 즉시 중단하고 보고할 것 (아래 1·2단계 진행 금지)
SELECT proname                                                       AS 함수,
       prosrc LIKE '%OLD.status = NEW.status%'                       AS 상태불변시_미발동
  FROM pg_proc
 WHERE pronamespace = 'public'::regnamespace
   AND proname IN ('record_deliverable_status_event', 'notify_deliverable_status')
 ORDER BY proname;
-- 기대: 2행, 둘 다 상태불변시_미발동 = true

-- 0-2. A 그룹 재확인 (0단계 (다) 조회 — 인수인계 문서와 동일 조건).
--      운영에서는 이미 55건이 스크래치패드에 저장돼 있으므로 필수는 아니지만,
--      실행 직전 건수가 변하지 않았는지 대조하는 용도로 돌려본다.
SELECT d.id                AS 결과물id,
       c.campaign_no       AS 캠페인번호,
       d.status            AS 상태,
       d.created_at::date  AS 올린날
  FROM deliverables d
  JOIN campaigns c ON c.id = d.campaign_id   -- ⚠️ applications 는 조인하지 않는다.
                                             --    55건을 확정한 0단계 조회와 조건을
                                             --    한 글자도 다르게 두면 대조가 깨진다
 WHERE d.kind = 'review_image'
   AND d.post_channel = 'channel-96r9y3'
   AND NOT EXISTS (                    -- B 그룹 제외 = A 그룹만
     SELECT 1 FROM deliverables x
      WHERE x.application_id = d.application_id
        AND x.kind = 'review_image'
        AND x.post_channel = 'cosme'
   )
 ORDER BY c.campaign_no, d.created_at;
-- 운영 기대: 55행 (개발은 다를 수 있음 — 위 "운영 기대 건수" 참고)


-- =============================================================================
-- 1단계 — 시험 교정 1건 (개발·운영 모두 COMMIT 으로 실행한다)
--   개발 리허설: 대상 id 를 0-2 결과의 개발 A그룹 id 로 바꿔서 실행 →
--                알림 확인 → 반드시 1-R 로 되돌린다
--   운영 시행  : 사전 확정된 시험 대상 id 그대로 실행 → 알림 확인 → 0 이면 2단계
-- =============================================================================
BEGIN;

WITH updated AS (
  UPDATE deliverables d
     SET post_channel = 'cosme'
   WHERE d.id = '9646eb9f-9a92-48fc-8559-ac03d0c54d71'   -- 운영: 사전 확정된 시험 대상
                                                          -- 개발 리허설: 0-2 결과에서 고른 A그룹 id로 교체
     AND d.kind = 'review_image'
     AND d.post_channel = 'channel-96r9y3'
     AND NOT EXISTS (                              -- ★ B 그룹 제외 — 2단계와 같은 조건을
       SELECT 1 FROM deliverables x                --   그대로 둔다. id 를 개발용으로 바꿔
        WHERE x.application_id = d.application_id  --   넣을 때 B 그룹 id 를 집어넣는 실수를
          AND x.kind = 'review_image'              --   막는다(헤더의 "모든 UPDATE" 주장과 일치)
          AND x.post_channel = 'cosme'
     )
  RETURNING d.id, d.status
)
INSERT INTO deliverable_events (deliverable_id, actor_id, action, from_status, to_status, reason)
SELECT id, NULL, 'channel_assign', status, status,
       '@cosme 채널 코드 교정(일회성 패치 2026-07-30): channel-96r9y3 → cosme'
  FROM updated;
-- 기대: UPDATE 1 (RETURNING 1행) → INSERT 0 1

COMMIT;


-- ★ 1단계 확인 — 위 COMMIT 이 끝난 뒤 **별도로** 실행한다 (같은 실행에 붙이지 말 것)
--   알림은 AFTER 트리거가 만들고, 커밋 전에는 확인 결과를 신뢰할 수 없다.
SELECT COUNT(*) AS 방금_생긴_알림
  FROM notifications
 WHERE ref_table = 'deliverables'
   AND ref_id = '9646eb9f-9a92-48fc-8559-ac03d0c54d71'   -- 1단계에서 쓴 id 와 동일하게
   AND created_at > now() - INTERVAL '10 minutes';
-- 기대: 0
--   1 이상이면 → 2단계 진행 금지. 아래 1-R 로 이 1건을 되돌린 뒤,
--   생긴 알림 행도 함께 지우고(ref_id 로 특정) 보고할 것.


-- =============================================================================
-- 1-R — 시험 교정 1건 되돌리기
--   [개발 리허설] 필수 실행 (흔적 제거)
--   [운영]        알림이 1건 이상 생겼을 때만 실행
--   ⚠️ id 를 1단계에서 쓴 것과 동일하게 맞출 것
-- =============================================================================
-- BEGIN;
--
-- DELETE FROM deliverable_events
--  WHERE deliverable_id = '9646eb9f-9a92-48fc-8559-ac03d0c54d71'
--    AND action = 'channel_assign'
--    AND reason = '@cosme 채널 코드 교정(일회성 패치 2026-07-30): channel-96r9y3 → cosme';
--
-- UPDATE deliverables
--    SET post_channel = 'channel-96r9y3'
--  WHERE id = '9646eb9f-9a92-48fc-8559-ac03d0c54d71'
--    AND kind = 'review_image'
--    AND post_channel = 'cosme';
-- -- 기대: UPDATE 1
--
-- COMMIT;
--
-- -- 알림이 생겼던 경우에만 추가 실행 (해당 행 참조 알림 제거)
-- -- DELETE FROM notifications
-- --  WHERE ref_table = 'deliverables'
-- --    AND ref_id = '9646eb9f-9a92-48fc-8559-ac03d0c54d71'
-- --    AND created_at > now() - INTERVAL '1 hour';
-- =============================================================================


-- =============================================================================
-- 2단계 — 나머지 54건 일괄 교정 (B 그룹 제외 조건 필수 포함)
--   ★ 운영 전용 — 개발에서는 실행하지 않는다(헤더 「개발 리허설」 절차 참조).
--     개발 리허설의 목적은 문법 검증과 알림 미발동 실측이고 그 둘은 1단계 1건으로
--     충분히 드러난다. 개발에서 일괄로 돌릴 이유가 없고, 흔적을 남길 위험만 늘어난다.
--   ⚠️ 1단계가 이미 처리한 행은 post_channel 이 'cosme' 로 바뀌어 있으므로
--      아래 WHERE 조건(post_channel='channel-96r9y3')에서 자연히 제외된다.
-- =============================================================================
BEGIN;

WITH updated AS (
  UPDATE deliverables d
     SET post_channel = 'cosme'
   WHERE d.kind = 'review_image'
     AND d.post_channel = 'channel-96r9y3'
     AND NOT EXISTS (                    -- ★ B 그룹 제외 (없으면 제약 위반으로 전체 중단)
       SELECT 1 FROM deliverables x
        WHERE x.application_id = d.application_id
          AND x.kind = 'review_image'
          AND x.post_channel = 'cosme'
     )
  RETURNING d.id, d.status
)
INSERT INTO deliverable_events (deliverable_id, actor_id, action, from_status, to_status, reason)
SELECT id, NULL, 'channel_assign', status, status,
       '@cosme 채널 코드 교정(일회성 패치 2026-07-30): channel-96r9y3 → cosme'
  FROM updated;
-- 운영 기대: UPDATE 54 (RETURNING 54행) → INSERT 0 54  (1건 시험분 제외)

COMMIT;


-- =============================================================================
-- 3단계 — 회복 확인 (운영, 읽기 전용, 1·2단계 commit 후 실행)
-- =============================================================================

-- ① A 그룹 잔여가 0이어야 한다 (교정이 전부 걸렸는지)
SELECT COUNT(*) AS 남은_A그룹
  FROM deliverables d
 WHERE d.kind = 'review_image' AND d.post_channel = 'channel-96r9y3'
   AND NOT EXISTS (SELECT 1 FROM deliverables x
                    WHERE x.application_id = d.application_id
                      AND x.kind = 'review_image' AND x.post_channel = 'cosme');
-- 기대: 0

-- ② 옛 코드 전체 잔여 = B 그룹만 남아야 한다
--    ⚠️ 이 "기대 26"은 B 그룹을 「유지」로 결정한 경우에만 성립하는 값이다
--       (사용자 미결 사항 — 사양서 §사용자 확인 필요 2). 「삭제」로 결정되면
--       2단계(B 그룹 처리)가 별도로 실행된 뒤 이 값이 0이 되는 것이 정상이며,
--       이 패치는 B 그룹 처리를 하지 않으므로 이 조회는 "지금 이 패치 직후"
--       시점의 참고값이지 최종 목표값이 아니다.
SELECT COUNT(*) AS 옛코드_잔여
  FROM deliverables WHERE kind = 'review_image' AND post_channel = 'channel-96r9y3';
-- 기대(이 패치 직후, B 그룹 미처리 상태): 26

-- ③ 상태가 안 바뀌었는지 — 교정한 행만 대상으로 본다
--    ⚠️ post_channel='cosme' 전체로 세지 말 것: 그 안에는 B 그룹의 새 코드 행과
--       C 그룹(원래 정상) 행이 섞여 있고, 그 행들의 상태는 이 패치가 approved
--       라고 확정한 범위(옛 코드 81행)가 아니다 → 판정이 성립하지 않는다.
--       아래 id 55개는 스크래치패드 명단(교정 전 스냅샷)에서 그대로 옮긴 것이다.
SELECT status, COUNT(*) AS 건수
  FROM deliverables
 WHERE id IN (
   '9646eb9f-9a92-48fc-8559-ac03d0c54d71','86e3980e-959a-46f1-b3d2-c6dc0d897812',
   'e6b0aba6-ae1a-432f-af43-2e7cb6743f53','468b7a3b-523d-4df6-b4cc-2febba3fe95b',
   '43882049-a481-4322-8022-956c68a5cb95','a7dc12e3-fef5-4e3a-b305-1cf704a65a24',
   '6f83e57f-cce9-4592-8dc0-0c61a2204f70','2a951400-2fd3-45a7-bba6-66c54c97ea59',
   'cbbad8f7-dbfc-4787-8bf2-cc6fc08436ad','75defc59-98a1-4fce-a722-0132e86282ba',
   '9d50d9c9-acc8-4715-9549-84cfebfbd586','6ba26022-fced-43e0-869f-b792025ccb68',
   'cd5188de-559a-4708-b732-45d839ec7a98','1619e6a0-acdc-42f2-a3fc-66592bfc5615',
   'b06c116b-4550-494b-8f75-783e134924ae','524c9e77-4435-4be4-b503-0c5c4e8f85b9',
   'b6f29875-d9c1-42d9-adc9-6157d6bf6399','f3f7e804-3009-4537-bba4-249abe222e99',
   '99020717-0fb2-4ec0-8d7b-f0ec9ddede66','d1c8c97d-732f-453b-8a26-933d51262055',
   '0e88a673-7a64-4ea8-a4db-b011f980e215','5ac29d61-b573-4ea3-ae10-cb325a945138',
   '49cd0ef3-08fa-45b9-a93a-33b0430f8e7d','11628fc0-b119-4ef6-83f2-b2520e6c99e1',
   'ef3e9279-251c-4ea2-81e8-202f57d1803a','f0fdbbc9-258d-416c-a322-5165b9754136',
   '7c1ecb24-5e38-4339-8956-a9839380fb78','d8eb6032-e332-4191-bef9-14f22b00dfd5',
   'a56b8e0f-932f-42b6-8174-bb2fd2b6a964','889e9d33-6e9d-431c-a490-5c60567a21dd',
   'c92c0f6e-c5cb-4aa4-88f7-301f1c9c1efd','a27ae62b-8a75-40f8-8c71-4140b462569e',
   'e59e2330-61fd-4322-9ea7-af1341db1858','c1085ccc-d55c-4701-b78f-ecec3508b3e3',
   'e2e6a6ad-4adc-4ec8-a37b-517c61c85917','be41c60f-eaa5-421b-a59f-a96cf8863017',
   '4fc11c82-7eef-4f00-825d-4062574e6d5d','be154a57-c3e5-4287-b323-c3d575cf3946',
   'fa16ed99-c0f0-4ef4-8718-8fbce10fe4c6','b655cea7-76e3-4ee6-ae60-d4017f008330',
   '313a0ef8-04ef-4a35-b705-6e010c823165','40238fb1-748c-466a-96aa-bb189cfb02ab',
   'bcc1605b-4b66-495d-a3c2-36da0c2435f7','d3aa9703-071e-4553-8064-489c91f80aa2',
   'fb7db541-eeac-429b-8f4b-7952bdc90641','7f234788-9633-4693-bd21-df82a43a5b61',
   'b449dd93-6724-4ae2-abb1-b44193923faf','dd803a70-537a-4b6d-b9c5-cb23ed302279',
   '71cb595d-c517-42cc-87d3-6c5ebb86b2d1','004c281f-be90-4712-9e41-e06fcd9362e9',
   'ed8b0469-1ad2-4dd6-8a6e-4b3b7069fcd7','68ed9812-384d-4735-bb15-05a02050f549',
   '5da789d8-6c70-47e1-8f1c-1df6a237a999','faddfd94-660c-4440-aa46-bc636e373392',
   'b34e0395-c502-49d5-a202-3454196be40e'
 )
 GROUP BY status;
-- 기대: approved 55 (한 행). draft·pending 등이 섞이면 status 를 건드린 것 → 즉시 보고

-- ④ (참고) 이 패치가 남긴 교정 이력 건수 확인
SELECT COUNT(*) AS 기록된_교정이력
  FROM deliverable_events
 WHERE action = 'channel_assign'
   AND reason = '@cosme 채널 코드 교정(일회성 패치 2026-07-30): channel-96r9y3 → cosme';
-- 기대: 55


-- =============================================================================
-- 전체 롤백 (필요할 때만 실행 — 되돌리기 전 반드시 사유를 기록하고 사용자에게 보고)
--   순서: ①이 패치가 남긴 교정 이력 삭제 → ②post_channel 을 옛 코드로 되돌림
--   부분 롤백(1단계만 되돌리는 등)이 필요하면 아래 id 목록을 해당 범위로 좁혀서 사용
-- =============================================================================
-- BEGIN;
--
-- DELETE FROM deliverable_events
--  WHERE action = 'channel_assign'
--    AND reason = '@cosme 채널 코드 교정(일회성 패치 2026-07-30): channel-96r9y3 → cosme'
--    AND deliverable_id IN (
--      '9646eb9f-9a92-48fc-8559-ac03d0c54d71','86e3980e-959a-46f1-b3d2-c6dc0d897812',
--      'e6b0aba6-ae1a-432f-af43-2e7cb6743f53','468b7a3b-523d-4df6-b4cc-2febba3fe95b',
--      '43882049-a481-4322-8022-956c68a5cb95','a7dc12e3-fef5-4e3a-b305-1cf704a65a24',
--      '6f83e57f-cce9-4592-8dc0-0c61a2204f70','2a951400-2fd3-45a7-bba6-66c54c97ea59',
--      'cbbad8f7-dbfc-4787-8bf2-cc6fc08436ad','75defc59-98a1-4fce-a722-0132e86282ba',
--      '9d50d9c9-acc8-4715-9549-84cfebfbd586','6ba26022-fced-43e0-869f-b792025ccb68',
--      'cd5188de-559a-4708-b732-45d839ec7a98','1619e6a0-acdc-42f2-a3fc-66592bfc5615',
--      'b06c116b-4550-494b-8f75-783e134924ae','524c9e77-4435-4be4-b503-0c5c4e8f85b9',
--      'b6f29875-d9c1-42d9-adc9-6157d6bf6399','f3f7e804-3009-4537-bba4-249abe222e99',
--      '99020717-0fb2-4ec0-8d7b-f0ec9ddede66','d1c8c97d-732f-453b-8a26-933d51262055',
--      '0e88a673-7a64-4ea8-a4db-b011f980e215','5ac29d61-b573-4ea3-ae10-cb325a945138',
--      '49cd0ef3-08fa-45b9-a93a-33b0430f8e7d','11628fc0-b119-4ef6-83f2-b2520e6c99e1',
--      'ef3e9279-251c-4ea2-81e8-202f57d1803a','f0fdbbc9-258d-416c-a322-5165b9754136',
--      '7c1ecb24-5e38-4339-8956-a9839380fb78','d8eb6032-e332-4191-bef9-14f22b00dfd5',
--      'a56b8e0f-932f-42b6-8174-bb2fd2b6a964','889e9d33-6e9d-431c-a490-5c60567a21dd',
--      'c92c0f6e-c5cb-4aa4-88f7-301f1c9c1efd','a27ae62b-8a75-40f8-8c71-4140b462569e',
--      'e59e2330-61fd-4322-9ea7-af1341db1858','c1085ccc-d55c-4701-b78f-ecec3508b3e3',
--      'e2e6a6ad-4adc-4ec8-a37b-517c61c85917','be41c60f-eaa5-421b-a59f-a96cf8863017',
--      '4fc11c82-7eef-4f00-825d-4062574e6d5d','be154a57-c3e5-4287-b323-c3d575cf3946',
--      'fa16ed99-c0f0-4ef4-8718-8fbce10fe4c6','b655cea7-76e3-4ee6-ae60-d4017f008330',
--      '313a0ef8-04ef-4a35-b705-6e010c823165','40238fb1-748c-466a-96aa-bb189cfb02ab',
--      'bcc1605b-4b66-495d-a3c2-36da0c2435f7','d3aa9703-071e-4553-8064-489c91f80aa2',
--      'fb7db541-eeac-429b-8f4b-7952bdc90641','7f234788-9633-4693-bd21-df82a43a5b61',
--      'b449dd93-6724-4ae2-abb1-b44193923faf','dd803a70-537a-4b6d-b9c5-cb23ed302279',
--      '71cb595d-c517-42cc-87d3-6c5ebb86b2d1','004c281f-be90-4712-9e41-e06fcd9362e9',
--      'ed8b0469-1ad2-4dd6-8a6e-4b3b7069fcd7','68ed9812-384d-4735-bb15-05a02050f549',
--      '5da789d8-6c70-47e1-8f1c-1df6a237a999','faddfd94-660c-4440-aa46-bc636e373392',
--      'b34e0395-c502-49d5-a202-3454196be40e'
--    );
--
-- UPDATE deliverables
--    SET post_channel = 'channel-96r9y3'
--  WHERE post_channel = 'cosme'
--    AND id IN (
--      '9646eb9f-9a92-48fc-8559-ac03d0c54d71','86e3980e-959a-46f1-b3d2-c6dc0d897812',
--      'e6b0aba6-ae1a-432f-af43-2e7cb6743f53','468b7a3b-523d-4df6-b4cc-2febba3fe95b',
--      '43882049-a481-4322-8022-956c68a5cb95','a7dc12e3-fef5-4e3a-b305-1cf704a65a24',
--      '6f83e57f-cce9-4592-8dc0-0c61a2204f70','2a951400-2fd3-45a7-bba6-66c54c97ea59',
--      'cbbad8f7-dbfc-4787-8bf2-cc6fc08436ad','75defc59-98a1-4fce-a722-0132e86282ba',
--      '9d50d9c9-acc8-4715-9549-84cfebfbd586','6ba26022-fced-43e0-869f-b792025ccb68',
--      'cd5188de-559a-4708-b732-45d839ec7a98','1619e6a0-acdc-42f2-a3fc-66592bfc5615',
--      'b06c116b-4550-494b-8f75-783e134924ae','524c9e77-4435-4be4-b503-0c5c4e8f85b9',
--      'b6f29875-d9c1-42d9-adc9-6157d6bf6399','f3f7e804-3009-4537-bba4-249abe222e99',
--      '99020717-0fb2-4ec0-8d7b-f0ec9ddede66','d1c8c97d-732f-453b-8a26-933d51262055',
--      '0e88a673-7a64-4ea8-a4db-b011f980e215','5ac29d61-b573-4ea3-ae10-cb325a945138',
--      '49cd0ef3-08fa-45b9-a93a-33b0430f8e7d','11628fc0-b119-4ef6-83f2-b2520e6c99e1',
--      'ef3e9279-251c-4ea2-81e8-202f57d1803a','f0fdbbc9-258d-416c-a322-5165b9754136',
--      '7c1ecb24-5e38-4339-8956-a9839380fb78','d8eb6032-e332-4191-bef9-14f22b00dfd5',
--      'a56b8e0f-932f-42b6-8174-bb2fd2b6a964','889e9d33-6e9d-431c-a490-5c60567a21dd',
--      'c92c0f6e-c5cb-4aa4-88f7-301f1c9c1efd','a27ae62b-8a75-40f8-8c71-4140b462569e',
--      'e59e2330-61fd-4322-9ea7-af1341db1858','c1085ccc-d55c-4701-b78f-ecec3508b3e3',
--      'e2e6a6ad-4adc-4ec8-a37b-517c61c85917','be41c60f-eaa5-421b-a59f-a96cf8863017',
--      '4fc11c82-7eef-4f00-825d-4062574e6d5d','be154a57-c3e5-4287-b323-c3d575cf3946',
--      'fa16ed99-c0f0-4ef4-8718-8fbce10fe4c6','b655cea7-76e3-4ee6-ae60-d4017f008330',
--      '313a0ef8-04ef-4a35-b705-6e010c823165','40238fb1-748c-466a-96aa-bb189cfb02ab',
--      'bcc1605b-4b66-495d-a3c2-36da0c2435f7','d3aa9703-071e-4553-8064-489c91f80aa2',
--      'fb7db541-eeac-429b-8f4b-7952bdc90641','7f234788-9633-4693-bd21-df82a43a5b61',
--      'b449dd93-6724-4ae2-abb1-b44193923faf','dd803a70-537a-4b6d-b9c5-cb23ed302279',
--      '71cb595d-c517-42cc-87d3-6c5ebb86b2d1','004c281f-be90-4712-9e41-e06fcd9362e9',
--      'ed8b0469-1ad2-4dd6-8a6e-4b3b7069fcd7','68ed9812-384d-4735-bb15-05a02050f549',
--      '5da789d8-6c70-47e1-8f1c-1df6a237a999','faddfd94-660c-4440-aa46-bc636e373392',
--      'b34e0395-c502-49d5-a202-3454196be40e'
--    );
-- -- 기대: UPDATE 55 (전체 롤백 기준. 부분 롤백이면 그 범위만큼)
--
-- COMMIT;   -- 확인 후 진행. ROLLBACK 으로 먼저 검증 후 COMMIT 권장
-- =============================================================================
