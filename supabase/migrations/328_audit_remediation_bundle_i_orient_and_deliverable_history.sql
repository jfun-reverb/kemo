-- ============================================================
-- 328_audit_remediation_bundle_i_orient_and_deliverable_history.sql
-- 전수조사 후속 조치 — 묶음 I(삭제·파기·그 밖) 중 데이터베이스 조각 4개(I-4·I-5·I-7·I-9)
-- 사양: docs/specs/2026-08-07-audit-remediation-plan.md 「묶음 I — 삭제·파기·그 밖」
--
-- ── 이 파일이 하지 않는 것 ──
--   이 파일은 화면 코드(dev/js/*.js, dev/lib/storage.js, dev/sales/orient.html)를
--   전혀 건드리지 않는다. 같은 시점에 다른 작업이 그 파일들을 손대고 있어(감사조치
--   세션 병행), 파일 충돌을 피하기 위해 데이터베이스 함수·표·트리거만 바꾼다.
--   화면 변경이 필요한 지점은 각 절 하단 "화면 변경 필요"에 표시했다(대부분 없음).
--
-- ── 재정의 기준(전수 확인, feedback_function_redefine_latest_base 메모리 규칙) ──
--   delete_orient_sheet   → 199 → 239(현재 유일한 원본). 이 파일은 239 베이스.
--     (grep -rl "FUNCTION public.delete_orient_sheet" supabase/migrations/ *.sql
--      → 199·239 두 곳뿐. 251·297 은 주석 언급만 있고 재정의하지 않는다 — 확인 완료.)
--   merge_brands           → 175(현재 유일한 원본). 이 파일은 175 베이스.
--     (grep -rl "FUNCTION public.merge_brands" supabase/migrations/ *.sql → 175 한 곳뿐.)
--   save_orient_draft      → 187 → 293(현재 원본). 이 파일은 293 베이스.
--   submit_orient_sheet    → 187 → 202 → 293(현재 원본). 이 파일은 293 베이스.
--     (grep -rl "FUNCTION public.save_orient_draft\|FUNCTION public.submit_orient_sheet"
--      supabase/migrations/ *.sql → 187·202·293 세 곳. 293 이 두 함수 모두의 최신 정의.)
--   can_submit_deliverable → 274 → 276(현재 유일한 원본). 이 파일은 276 베이스.
--     (grep -rl "FUNCTION public.can_submit_deliverable" supabase/migrations/ *.sql
--      → 274·276 두 곳. 276 이 review_image·post 채널 단위 전환을 포함한 최신 정의라
--      이 파일은 276 을 베이스로 삼는다 — 274 를 베이스로 삼으면 채널 단위 전환이
--      소실된다.)
--   record_deliverable_status_event → 035 → 073(현재 유일한 원본). 이 파일은
--     이 함수 자체는 재정의하지 않는다(아래 I-9 절 "왜 트리거를 재정의하지 않는가"
--     참고 — 새 스냅샷 칸은 별도 BEFORE INSERT 트리거가 채운다).
--
-- 조각별 요약:
--   I-4 delete_orient_sheet(239) 재정의 — 함께 삭제하던 발행 캠페인을 하드 삭제
--       대신 soft_delete_campaign(255,325) 호출로 보관 삭제(30일 복구 가능)로 바꾼다.
--   I-5 merge_brands(175) 재정의 — 원본 브랜드의 오리엔시트를 대상 브랜드로 함께
--       옮긴다. 205 파일이 예고했던 후속 과제.
--   I-7 save_orient_draft·submit_orient_sheet(293) 재정의 — 브랜드가 이미 발행된
--       카드를 지운 채 저장해도, 그 카드를 원래 내용 그대로 되살린다(신규 순수
--       계산 함수 _orient_preserve_published_cards).
--   I-9 deliverable_events 에 스냅샷 칸 4종 추가 + BEFORE INSERT 트리거로 자동
--       채움 + 외래 키 CASCADE → SET NULL 전환 + can_submit_deliverable(276) 의
--       마감 후 재제출 예외(Tier 2) 조회를 스냅샷 칸 기준으로 재작성. 결과물이
--       하드 삭제돼도(본인 임시저장 삭제 포함) 반려 이력이 함께 사라지지 않는다.
--       252·253(receipt_edit_history 의 같은 문제·같은 해법) 패턴을 그대로 이식.
--
-- 롤백: 각 절 하단 참고. 전체를 한꺼번에 되돌리려면 파일 맨 아래 "전체 롤백" 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- I-4. delete_orient_sheet 재정의
--   — 함께 삭제하던 발행 캠페인을 하드 삭제 대신 보관 삭제(soft delete)로 전환
--
--   ── 무엇이 문제였나 ──
--   239 는 삭제 대상(v_delete_ids — linked_existing 아닌, 이 시트를 위해 새로
--   태어난 발행 캠페인)을 `DELETE FROM public.campaigns WHERE id = ANY(v_delete_ids)`
--   로 하드 삭제했다. 이러면 그 캠페인은 ①「삭제됨」 탭에 안 뜨고 30일 복구가
--   불가능하고 ②campaign_change_history(마이그레이션 265·266) 등 변경 이력이 그
--   자리에서 즉시 함께 사라진다. 신청이 1건이라도 있으면 이미 차단하므로(위
--   blocked_has_applications 검사) 이건 개인정보 파기 문제가 아니라 순전히
--   "복구 가능성과 감사 기록의 문제"다.
--
--   ── soft_delete_campaign(255, 325) 을 그대로 호출하는 것이 맞는 이유 ──
--   1) 권한 가드가 이미 일치한다 — soft_delete_campaign 도 is_campaign_admin() 을
--      요구하고, 이 분기(①실제 삭제 대상이 있는 경우)도 이미 is_campaign_admin()
--      을 요구한다(239 원본 그대로, 아래에서도 무변경). 호출 시 추가로 걸리는
--      권한 제약이 없다.
--   2) 저장소 파일 정리(I-1)·영수증 수정 이력 파기(I-2)가 이미 그 함수 안에
--      들어 있다(마이그레이션 325). 여기서 별도로 재구현하면 같은 로직이
--      두 곳에 흩어져 한쪽만 고쳐지는 위험(이 저장소의 반복된 실패 패턴,
--      CLAUDE.md 「채널 코드 이관」 사고와 같은 유형)이 생긴다.
--   3) 신청 0건이 이미 보장돼 있어(바로 위 blocked_has_applications 검사를
--      통과해야 이 분기에 도달) soft_delete_campaign 이 반환하는
--      storage_paths_to_delete 는 사실상 항상 빈 배열이다 — "그 경로를 누가
--      소비하나"라는 우려에 대한 답은 "지울 파일이 원래 없다"이다. 다만 이
--      확인(1)과 실행(2) 사이에 이론상 미세한 시간차 경합(체크 이후 그 짧은
--      순간에 새 신청이 끼어드는 경우)이 있을 수 있어, 안전망으로 반환값을
--      그대로 버리지 않고 이 함수의 반환값에도 투명하게 실어 보낸다(아래
--      반환값 변경 참고) — 실제로 채워질 일은 거의 없지만, 채워진다면 화면이
--      나중에 그 값을 소비해 정리할 수 있게 자리를 남겨 둔다.
--
--   ── 이미 보관 삭제돼 있는 캠페인 처리 ──
--   soft_delete_campaign 은 이미 삭제된 캠페인을 다시 호출하면 예외를 던진다
--   (255, 'campaign_already_deleted'). 오리엔시트 삭제 자체가 그 이유로 실패하면
--   안 되므로, 호출 전에 `deleted_at IS NULL` 을 확인하고(동시에 그 확인 자체가
--   행을 잠근다 — FOR UPDATE) 아직 안 지워진 캠페인만 호출한다. 이미 지워진
--   캠페인은 이미 목표 상태(보관 삭제됨)이므로 손대지 않고 건너뛴다.
--
--   ── 오리엔시트가 사라진 뒤 캠페인이 남는 것이 맞는가 ──
--   맞다. 시트(orient_sheets 행)와 그 시트가 발행한 캠페인(campaigns 행)은
--   서로 다른 생명주기를 가진 별개의 데이터다 — 캠페인이 이미 인플루언서에게
--   공개돼 있었을 수도 있는 실제 서비스 데이터이고, 시트는 그 캠페인을 만드는 데
--   쓰인 "제작 원본" 성격이다. 시트를 지운다고 그 캠페인이 존재한 적 없던 것으로
--   되지는 않는다 — 오히려 30일간 보관해 관리자가 "이 시트를 지운 게 맞았나"를
--   되돌아볼 여지를 준다(하드 삭제였다면 그 여지 자체가 없었다). 캠페인 쪽의
--   `orient_sheets.campaign_id` 역참조는 시트 행 자체가 사라지므로 자연히 무의미
--   해질 뿐, 남은 캠페인 행의 무결성에는 영향이 없다(campaigns 표에는 애초에 시트를
--   가리키는 칸이 없다 — 참조는 시트→캠페인 단방향).
--
--   ── 반환값 변경(추가만, 기존 키 무삭제 — 화면 무영향) ──
--   기존 `deleted_campaign_ids`(이제는 "보관 삭제된" 캠페인 id, 이름은 유지 —
--   CLAUDE.md 「캠페인 삭제는 보관 삭제(soft delete)」 원칙대로 이 저장소 전체가
--   "삭제"를 보관 삭제의 의미로 관용적으로 쓴다)·`preserved_campaign_ids` 는
--   그대로. `storage_paths_to_delete` 키를 신규로 추가(위 3번 이유). 화면
--   (admin-orient.js osExecuteDelete)은 `res.deleted_campaign_ids.length` 만
--   읽으므로 이 추가는 안전하다(값이 있는 키를 무시할 뿐 오류가 나지 않는다).
--
--   ⚠️ 화면 변경 필요: 없음(이 조각 단독으로는). 토스트 문구("오리엔시트와 연결
--   캠페인 N개를 삭제했습니다")는 "보관 삭제"라는 이 저장소의 관용적 용어 사용과
--   일치해 바꿀 필요가 없다.
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_orient_sheet(
  p_orient_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_data          jsonb;
  v_delete_ids    uuid[];  -- 함께 보관 삭제할 캠페인(linked_existing 아닌 발행 카드)
  v_preserved_ids uuid[];  -- 보존할 캠페인(linked_existing=true 발행 카드)
  v_blocked       uuid[];

  -- [328, I-4] 신규 변수
  v_cid               uuid;                          -- 보관 삭제 루프 변수
  v_sd_result         jsonb;                          -- soft_delete_campaign 반환값
  v_agg_msg_paths      text[] := ARRAY[]::text[];     -- 저장소 정리 대상 집계(메시지 첨부)
  v_actually_deleted  uuid[]  := '{}';   -- [328 정정] 이번 호출로 실제 보관 삭제한 캠페인만
  v_agg_receipt_paths  text[] := ARRAY[]::text[];     -- 저장소 정리 대상 집계(영수증·인증샷)
BEGIN
  -- ── 시트 행 잠금 + 존재 확인 (239 원본과 동일) ─────────────────────────
  SELECT data
    INTO v_data
    FROM public.orient_sheets
   WHERE id = p_orient_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;

  -- ── 함께 삭제할 발행 캠페인 수집 (linked_existing=true 카드는 제외, 239 원본과 동일) ──
  SELECT COALESCE(array_agg(DISTINCT cid), ARRAY[]::uuid[])
    INTO v_delete_ids
    FROM (
      SELECT (card->>'campaign_id')::uuid AS cid
        FROM jsonb_array_elements(COALESCE(v_data->'cards', '[]'::jsonb)) AS card
       WHERE COALESCE(card->>'campaign_id', '') <> ''
         AND COALESCE(card->>'linked_existing', 'false') <> 'true'
    ) t;

  -- ── 보존 대상(linked_existing=true) 캠페인 수집 (239 원본과 동일) ──────
  SELECT COALESCE(array_agg(DISTINCT cid), ARRAY[]::uuid[])
    INTO v_preserved_ids
    FROM (
      SELECT (card->>'campaign_id')::uuid AS cid
        FROM jsonb_array_elements(COALESCE(v_data->'cards', '[]'::jsonb)) AS card
       WHERE COALESCE(card->>'campaign_id', '') <> ''
         AND COALESCE(card->>'linked_existing', 'false') = 'true'
    ) t;

  -- ── 권한 가드: 3단계 분기 (239 원본과 동일) ─────────────────────────────
  IF array_length(v_delete_ids, 1) IS NOT NULL THEN
    -- ① 실제로 보관 삭제할 캠페인이 있음 — 파괴적 동작이므로 campaign_admin 이상
    IF NOT public.is_campaign_admin() THEN
      RETURN jsonb_build_object('success', false, 'reason', 'permission_denied');
    END IF;

    -- 삭제 대상 캠페인 행만 잠금(239 원본과 동일 — 경쟁 상태 방어)
    PERFORM 1
       FROM public.campaigns
      WHERE id = ANY(v_delete_ids)
      FOR UPDATE;

    -- 신청(applications) 1건이라도 있는 삭제 대상 캠페인 수집 → 있으면 차단 (239 원본과 동일)
    SELECT COALESCE(array_agg(DISTINCT a.campaign_id), ARRAY[]::uuid[])
      INTO v_blocked
      FROM public.applications a
     WHERE a.campaign_id = ANY(v_delete_ids);

    IF array_length(v_blocked, 1) IS NOT NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'reason',  'blocked_has_applications',
        'campaign_ids', to_jsonb(v_blocked)
      );
    END IF;

    -- [328, I-4] 신청 0건 확인 완료 → 삭제 대상 캠페인을 보관 삭제(soft delete)로
    --   전환한다. 239 원본은 여기서 `DELETE FROM public.campaigns WHERE id = ANY(...)`
    --   로 하드 삭제했다 — 이 파일 상단 "무엇이 문제였나" 참고.
    --   이미 다른 경로(캠페인 관리 화면)로 보관 삭제돼 있는 캠페인은 건너뛴다
    --   (soft_delete_campaign 은 이미 삭제된 캠페인을 다시 호출하면 예외를 던진다 —
    --   오리엔시트 삭제 자체를 실패시키지 않기 위해 미리 걸러낸다).
    FOREACH v_cid IN ARRAY v_delete_ids LOOP
      PERFORM 1 FROM public.campaigns WHERE id = v_cid AND deleted_at IS NULL FOR UPDATE;
      IF FOUND THEN
        v_sd_result := public.soft_delete_campaign(v_cid);
        -- 이번 호출로 **실제로** 보관 삭제한 것만 모은다. 이미 다른 경로로 삭제돼 있어
        --   건너뛴 캠페인까지 세면, 화면 안내 문구가 처리 건수를 부풀려 말한다
        --   (`admin-orient.js` 가 이 배열의 길이만 읽어 「N개 삭제」를 만든다).
        v_actually_deleted := v_actually_deleted || v_cid;

        -- 신청 0건이 보장돼 있어 사실상 항상 빈 배열이지만(위 "왜 호출하는 것이
        -- 맞는가" 3번 참고), 만약을 대비해 반환값에 투명하게 실어 보낸다.
        v_agg_msg_paths := v_agg_msg_paths || ARRAY(
          SELECT jsonb_array_elements_text(
            COALESCE(v_sd_result->'storage_paths_to_delete'->'message_attachments', '[]'::jsonb)
          )
        );
        v_agg_receipt_paths := v_agg_receipt_paths || ARRAY(
          SELECT jsonb_array_elements_text(
            COALESCE(v_sd_result->'storage_paths_to_delete'->'receipt_images', '[]'::jsonb)
          )
        );
      END IF;
    END LOOP;

  ELSIF array_length(v_preserved_ids, 1) IS NOT NULL THEN
    -- ② 보관 삭제할 캠페인은 없지만(전부 linked_existing) 발행 표시는 있는 시트.
    --    캠페인을 전혀 건드리지 않으므로 파괴 등급이 아님 — is_admin() 이면 충분
    --    (239 원본과 동일).
    IF NOT public.is_admin() THEN
      RETURN jsonb_build_object('success', false, 'reason', 'permission_denied');
    END IF;

  ELSE
    -- ③ 발행 캠페인 없음(미발행) — 오리엔시트 행만 삭제, 전체 관리자 허용 (239 원본과 동일)
    IF NOT public.is_admin() THEN
      RETURN jsonb_build_object('success', false, 'reason', 'permission_denied');
    END IF;
  END IF;

  -- ── 오리엔시트 행 삭제 (239 원본과 동일 — 시트 자체는 여전히 하드 삭제) ──
  DELETE FROM public.orient_sheets WHERE id = p_orient_id;

  RETURN jsonb_build_object(
    'success', true,
    'deleted_campaign_ids', to_jsonb(v_actually_deleted),
    'preserved_campaign_ids', to_jsonb(v_preserved_ids),
    -- [328, I-4] 신규 — 실제로 지울 저장소 파일이 있었다면(사실상 항상 빈 배열)
    -- 여기 담긴다. 화면이 아직 이 값을 소비하지 않는다(위 "화면 변경 필요" 참고).
    'storage_paths_to_delete', jsonb_build_object(
      'message_attachments', to_jsonb(v_agg_msg_paths),
      'receipt_images',      to_jsonb(v_agg_receipt_paths)
    )
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_orient_sheet(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.delete_orient_sheet(uuid) TO authenticated;

COMMENT ON FUNCTION public.delete_orient_sheet(uuid) IS
  '[239, 328 개정] 오리엔시트 삭제. 발행 캠페인 연결 없으면 시트만 삭제(is_admin). '
  '연결 있으면 linked_existing=true(237로 연결한 기존 캠페인) 카드는 삭제 대상에서 '
  '제외해 보존하고, 그 외(196 신규발행) 신청 0건 캠페인은 soft_delete_campaign(255,325) '
  '을 호출해 보관 삭제(30일 복구 가능)한다(328 — 이전에는 하드 삭제). '
  '신청 1건+ 삭제대상 캠페인 있으면 blocked_has_applications 차단. '
  'FOR UPDATE 잠금·트랜잭션. SECURITY DEFINER + search_path 고정.';

-- 이 절 롤백:
--   239_delete_orient_sheet_preserve_linked_existing.sql 의 CREATE OR REPLACE
--   FUNCTION 블록을 그대로 재실행(하드 삭제 원본 복원).
--   ⚠️ 이미 이 함수로 보관 삭제된 캠페인은 롤백해도 자동으로 되돌아가지 않는다
--   (그 캠페인들은 여전히 deleted_at 세팅된 채 30일 보관 상태로 남는다 — 이는
--   오히려 안전한 방향이라 별도 조치 불필요, 관리자가 「삭제됨」 탭에서 복구 가능).


-- ============================================================
-- I-5. merge_brands 재정의
--   — 원본 브랜드의 오리엔시트를 대상 브랜드로 함께 옮긴다
--
--   ── 무엇이 문제였나 ──
--   merge_brands(175)는 브랜드 신청(brand_applications)과 캠페인(campaigns)만
--   대상 브랜드로 옮기고 오리엔시트(orient_sheets)는 그대로 둔다. 205 파일이
--   이걸 이미 알고 있었다("merge_brands(175) 영향: … 별도 개선 과제(PR 1 범위
--   밖)"). 그 결과 병합 후 원본 브랜드를 archived 처리해도 그 브랜드에
--   orient_sheets 행이 남아 있으면, delete_brand(현재 원본 325)의
--   `v_sheets`(orient_sheets 카운트) 검사에 계속 걸려 **원본 브랜드를 영원히
--   완전 삭제할 수 없다**(orient_sheets.brand_id 가 ON DELETE RESTRICT — 186
--   파일 참고).
--
--   ── 무엇을 옮기나 ──
--   orient_sheets.brand_id 만 p_target 으로 옮긴다(단순 UPDATE, 재채번 없음 —
--   아래 "orient_no 를 재채번하지 않는 이유" 참고). application_id 는 손대지
--   않는다 — 그 오리엔시트가 연결된 신청(brand_applications)은 이미 위 단계
--   ①에서 p_target 으로 옮겨져 있으므로, 그대로 둬도 참조가 깨지지 않는다.
--
--   ── orient_no 를 재채번하지 않는 이유(판단이 갈린 지점) ──
--   175 는 신청·캠페인을 옮길 때 채번을 재발급하고 legacy_no 에 옛 번호를
--   누적한다(B{target}-A{seq}, B{target}-A{seq}-C{seq}). 오리엔시트에도 자체
--   식별번호 orient_no(B{brand_seq}-O{seq}, 마이그레이션 205)가 있어 같은 패턴을
--   적용할지 검토했다. 적용하지 않기로 했다 — 근거:
--     1) orient_sheets 표에는 legacy_no 컬럼 자체가 없다(205 파일 확인 —
--        brand_applications·campaigns 와 달리 옛 번호를 누적할 자리가 없다).
--        새로 컬럼을 추가하는 건 이번 지시 범위(기존 함수 재정의)를 넘는 스키마
--        확장이라, 「못 하겠으면 억지로 하지 마라」에 해당한다고 판단했다.
--     2) orient_no 의 UNIQUE 제약(205, `orient_sheets_orient_no_key`)은 브랜드가
--        바뀌어도 깨지지 않는다 — 옛 번호(B{source}-O###)는 이미 발급된 시점의
--        prefix 를 그대로 유지할 뿐이고, 새 발급은 target 브랜드의
--        brand_orient_counter 에서 계속 이어진다. **충돌은 없다**(205 파일이
--        이미 이렇게 명시: "번호 prefix가 달라 충돌 없음").
--     3) 재채번을 하려면 brand_applications/campaigns 처럼 legacy_no 누적 이력을
--        새로 설계해야 하는데, 오리엔시트는 "제작 원본" 성격이라 신청·캠페인만큼
--        외부 보고서·정산에 번호가 노출되지 않는다(campaign_no·application_no
--        는 엑셀·메일 등 외부에 노출되지만 orient_no 는 관리자 화면 내부
--        식별자 위주).
--   결과: 병합 후 그 오리엔시트는 브랜드는 target 인데 번호 prefix 는 옛
--   source 브랜드의 것으로 남는다(예: 브랜드는 "B" 인데 orient_no 는
--   "B0001-O003"). 관리자 화면에 다소 혼란을 줄 수 있는 화면 표시 문제이지만,
--   기능적으로는 안전하다(고유성 보장·참조 무결성 유지) — brand_applications
--   /campaigns 의 legacy_no 도 여러 번 병합되면 접두어가 섞여 보이는 것과 같은
--   종류의 이미 감수하고 있는 트레이드오프다.
--
--   ── 멱등성 체크에 orient_sheets 추가(필수) ──
--   기존 4번 단계(멱등성 — source 이미 archived + 연결 0건이면 no-op)는
--   orient_sheets 를 보지 않았다. **이 검사에 orient_sheets 를 추가하지 않으면
--   이 마이그레이션의 효과 자체가 무력화된다** — 175 로 이미 병합됐지만
--   orient_sheets 가 안 옮겨진 archived 브랜드에 대해, 관리자가 이 함수를 다시
--   호출해도(같은 source/target으로) 옛 검사라면 "이미 archived + 신청/캠페인
--   0건"만 보고 곧장 `unchanged:true` 로 조용히 종료해 orient_sheets 는 여전히
--   방치된다. orient_sheets 존재 여부를 멱등성 판정에 포함해야 이 재실행이
--   실제로 옮기는 동작을 하게 된다.
--
--   ── 이미 병합된 과거 데이터(archived 브랜드에 남은 orient_sheets)는 다루지
--   않는다(못 한 것 — 아래 "화면 변경 필요" 겸 보고 참고) ──
--   이 재정의는 **앞으로의 병합**만 고친다. 이미 archived 처리된 브랜드 밑에
--   남아 있는 고아 orient_sheets 를 어느 target 으로 옮겨야 하는지는 이
--   함수만으로는 알 수 없다 — numbering_legacy_map(088)이 entity_type 을
--   'brand_application'·'campaign' 두 가지로만 제한해(CHECK 제약) 브랜드
--   병합 자체의 source→target 매핑을 기록해 두지 않았고, 만약 그 archived
--   브랜드에 애초에 이동된 신청·캠페인이 하나도 없었다면(오리엔시트만 있던
--   브랜드) 그 흔적이 전혀 남아 있지 않다 — 안전하게 추론할 방법이 없다.
--   아래 검증 SQL 에 이런 브랜드를 찾는 진단 조회를 남겨 둔다. **자동 이관은
--   하지 않는다** — 잘못된 target 으로 옮기면 브랜드 오귀속이라는 더 나쁜
--   결과를 만든다.
--
--   반환값 변경(추가만) — `moved_orient_sheets` 키 신규 추가. 화면
--   (admin-company.js/admin-brand.js 의 병합 모달)이 이 반환값의 어느 키를
--   쓰는지는 확인이 필요하나(이 조각에서 화면을 열지 않았다), 새 키 추가는
--   기존 키를 지우지 않으므로 기존 소비 코드가 있어도 깨지지 않는다.
-- ============================================================

CREATE OR REPLACE FUNCTION public.merge_brands(
  p_source uuid,
  p_target uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_source        record;
  v_target        record;

  v_app           record;
  v_old_app_no    text;
  v_new_app_seq   integer;
  v_new_app_no    text;

  v_camp          record;
  v_old_camp_no   text;
  v_new_camp_no   text;
  v_app_seq_parsed integer;
  v_new_camp_seq  integer;
  v_new_ext_seq   integer;
  v_new_app_no_for_camp text;

  v_moved_apps         integer := 0;
  v_moved_campaigns    integer := 0;
  v_moved_orient_sheets integer := 0;  -- [328, I-5]
BEGIN
  -- 0. 권한 + 입력 검증 (175 원본과 동일)
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)' USING ERRCODE = '42501';
  END IF;
  IF p_source IS NULL OR p_target IS NULL THEN
    RAISE EXCEPTION 'source_id 와 target_id 가 모두 필요합니다' USING ERRCODE = '22023';
  END IF;
  IF p_source = p_target THEN
    RAISE EXCEPTION '원본과 대상이 같은 브랜드입니다' USING ERRCODE = '22023';
  END IF;

  -- 1. 잠금 2단 (uuid 작은 쪽 먼저 — 데드락 회피) (175 원본과 동일)
  IF p_source < p_target THEN
    PERFORM pg_advisory_xact_lock(hashtext(p_source::text)::bigint);
    PERFORM pg_advisory_xact_lock(hashtext(p_target::text)::bigint);
  ELSE
    PERFORM pg_advisory_xact_lock(hashtext(p_target::text)::bigint);
    PERFORM pg_advisory_xact_lock(hashtext(p_source::text)::bigint);
  END IF;

  -- 2. 브랜드 행 조회 (FOR UPDATE) (175 원본과 동일)
  SELECT id, name, name_ja, name_en, company_id, brand_seq, status
    INTO v_source FROM public.brands WHERE id = p_source FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '원본 브랜드를 찾을 수 없습니다: %', p_source USING ERRCODE = '22023';
  END IF;

  SELECT id, name, name_ja, name_en, company_id, brand_seq, status
    INTO v_target FROM public.brands WHERE id = p_target FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '대상 브랜드를 찾을 수 없습니다: %', p_target USING ERRCODE = '22023';
  END IF;

  -- 3. 회사 검증 없음 (175 원본과 동일, 무변경)

  -- [328, I-5] 4. 멱등성 — source 이미 archived + 연결 0건(신청·캠페인·오리엔시트
  --   모두)이면 no-op. orient_sheets 를 새로 추가한 것이 이 파일의 핵심 변경점 —
  --   위 파일 상단 "멱등성 체크에 orient_sheets 추가(필수)" 참고.
  IF v_source.status = 'archived'
     AND NOT EXISTS (SELECT 1 FROM public.brand_applications WHERE brand_id = p_source)
     AND NOT EXISTS (SELECT 1 FROM public.campaigns          WHERE brand_id = p_source)
     AND NOT EXISTS (SELECT 1 FROM public.orient_sheets      WHERE brand_id = p_source)
  THEN
    RETURN jsonb_build_object(
      'source_id', p_source, 'target_id', p_target,
      'moved_apps', 0, 'moved_campaigns', 0, 'moved_orient_sheets', 0,
      'source_archived', true, 'unchanged', true);
  END IF;

  -- 5. ① 신청 이동 + A-seq 재발급 (175 원본과 동일)
  FOR v_app IN
    SELECT id, application_no, legacy_no
      FROM public.brand_applications
     WHERE brand_id = p_source
     ORDER BY created_at
  LOOP
    v_old_app_no := v_app.application_no;

    INSERT INTO public.brand_application_counter (brand_id, last_seq)
    VALUES (p_target, 1)
    ON CONFLICT (brand_id)
    DO UPDATE SET last_seq = public.brand_application_counter.last_seq + 1
    RETURNING last_seq INTO v_new_app_seq;

    IF v_new_app_seq > 999 THEN
      RAISE EXCEPTION 'A-seq 오버플로 (>999): target brand_id=%', p_target USING ERRCODE = '22003';
    END IF;

    v_new_app_no := 'B' || lpad(v_target.brand_seq::text, 4, '0')
                 || '-A' || lpad(v_new_app_seq::text, 3, '0');

    UPDATE public.brand_applications
       SET brand_id = p_target,
           application_no = v_new_app_no,
           legacy_no = public._accumulate_legacy_no(v_app.legacy_no, v_old_app_no)
     WHERE id = v_app.id;

    INSERT INTO public.numbering_legacy_map (entity_type, entity_id, legacy_no, new_no, migrated_at)
    VALUES ('brand_application', v_app.id, COALESCE(v_app.legacy_no, v_old_app_no), v_new_app_no, now())
    ON CONFLICT (entity_type, entity_id)
    DO UPDATE SET new_no = EXCLUDED.new_no, migrated_at = now();

    v_moved_apps := v_moved_apps + 1;
  END LOOP;

  -- 6. ② 신청 파생 캠페인 이동 + 재채번 (175 원본과 동일)
  FOR v_camp IN
    SELECT c.id, c.campaign_no, c.legacy_no, c.source_application_id
      FROM public.campaigns c
      JOIN public.brand_applications ba ON ba.id = c.source_application_id
     WHERE ba.brand_id = p_target
       AND c.brand_id  = p_source
     ORDER BY c.created_at
  LOOP
    v_old_camp_no := v_camp.campaign_no;

    SELECT application_no INTO v_new_app_no_for_camp
      FROM public.brand_applications WHERE id = v_camp.source_application_id;

    IF v_new_app_no_for_camp SIMILAR TO 'B[0-9]{4}-A[0-9]{3}' THEN
      v_app_seq_parsed := split_part(v_new_app_no_for_camp, '-A', 2)::integer;
    ELSE
      RAISE EXCEPTION '신청번호 형식이 예상과 다릅니다: % (기대값 B####-A###)', v_new_app_no_for_camp
        USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.application_campaign_counter (application_id, last_seq)
    VALUES (v_camp.source_application_id, 1)
    ON CONFLICT (application_id)
    DO UPDATE SET last_seq = public.application_campaign_counter.last_seq + 1
    RETURNING last_seq INTO v_new_camp_seq;

    IF v_new_camp_seq > 999 THEN
      RAISE EXCEPTION 'C-seq 오버플로 (>999): application_id=%', v_camp.source_application_id USING ERRCODE = '22003';
    END IF;

    v_new_camp_no := 'B' || lpad(v_target.brand_seq::text, 4, '0')
                  || '-A' || lpad(v_app_seq_parsed::text, 3, '0')
                  || '-C' || lpad(v_new_camp_seq::text, 3, '0');

    UPDATE public.campaigns
       SET brand_id = p_target,
           campaign_no = v_new_camp_no,
           legacy_no = public._accumulate_legacy_no(v_camp.legacy_no, v_old_camp_no),
           updated_at = now()
     WHERE id = v_camp.id;

    INSERT INTO public.numbering_legacy_map (entity_type, entity_id, legacy_no, new_no, migrated_at)
    VALUES ('campaign', v_camp.id, COALESCE(v_camp.legacy_no, v_old_camp_no), v_new_camp_no, now())
    ON CONFLICT (entity_type, entity_id)
    DO UPDATE SET new_no = EXCLUDED.new_no, migrated_at = now();

    v_moved_campaigns := v_moved_campaigns + 1;
  END LOOP;

  -- 7. ③ 외부 캠페인(source_application_id NULL) 이동 + 재채번 (175 원본과 동일)
  FOR v_camp IN
    SELECT id, campaign_no, legacy_no
      FROM public.campaigns
     WHERE brand_id = p_source AND source_application_id IS NULL
     ORDER BY created_at
  LOOP
    v_old_camp_no := v_camp.campaign_no;

    INSERT INTO public.brand_external_campaign_counter (brand_id, last_seq)
    VALUES (p_target, 1)
    ON CONFLICT (brand_id)
    DO UPDATE SET last_seq = public.brand_external_campaign_counter.last_seq + 1
    RETURNING last_seq INTO v_new_ext_seq;

    IF v_new_ext_seq > 999 THEN
      RAISE EXCEPTION '외부 C-seq 오버플로 (>999): target brand_id=%', p_target USING ERRCODE = '22003';
    END IF;

    v_new_camp_no := 'B' || lpad(v_target.brand_seq::text, 4, '0')
                  || '-C' || lpad(v_new_ext_seq::text, 3, '0');

    UPDATE public.campaigns
       SET brand_id = p_target,
           campaign_no = v_new_camp_no,
           legacy_no = public._accumulate_legacy_no(v_camp.legacy_no, v_old_camp_no),
           updated_at = now()
     WHERE id = v_camp.id;

    INSERT INTO public.numbering_legacy_map (entity_type, entity_id, legacy_no, new_no, migrated_at)
    VALUES ('campaign', v_camp.id, COALESCE(v_camp.legacy_no, v_old_camp_no), v_new_camp_no, now())
    ON CONFLICT (entity_type, entity_id)
    DO UPDATE SET new_no = EXCLUDED.new_no, migrated_at = now();

    v_moved_campaigns := v_moved_campaigns + 1;
  END LOOP;

  -- [328, I-5] 7-2. 오리엔시트 이동 — brand_id 만 옮긴다(재채번 없음, 위 파일
  --   상단 "orient_no 를 재채번하지 않는 이유" 참고). 캠페인·신청 이동이 모두
  --   끝난 뒤에 옮기지만, 사실 순서와 무관하게 안전하다(orient_sheets 는 다른
  --   테이블의 이동 로직에 값을 공급하지도, 그로부터 값을 받지도 않는다 —
  --   application_id 참조는 이미 ①에서 옮겨진 brand_applications.id 를 그대로
  --   가리키므로 무변경으로 계속 유효하다).
  UPDATE public.orient_sheets
     SET brand_id   = p_target,
         updated_at = now()
   WHERE brand_id = p_source;
  GET DIAGNOSTICS v_moved_orient_sheets = ROW_COUNT;

  -- 8. ④ 이동된(+기존) target 캠페인 비정규화 컬럼 동기화 (175 원본과 동일)
  UPDATE public.campaigns
     SET brand = v_target.name, brand_ja = v_target.name_ja, brand_en = v_target.name_en,
         updated_at = now()
   WHERE brand_id = p_target;

  -- 9. ⑤ 원본 보관 처리 (175 원본과 동일)
  UPDATE public.brands SET status = 'archived' WHERE id = p_source;

  RETURN jsonb_build_object(
    'source_id', p_source, 'target_id', p_target,
    'moved_apps', v_moved_apps, 'moved_campaigns', v_moved_campaigns,
    'moved_orient_sheets', v_moved_orient_sheets,  -- [328, I-5] 신규
    'source_archived', true, 'unchanged', false);
END;
$$;

COMMENT ON FUNCTION public.merge_brands(uuid, uuid) IS
  '[175, 328 개정] 브랜드 병합. source 신청·캠페인·오리엔시트를 target 으로 이동 '
  '(신청·캠페인은 채번 재발급 + legacy_no 보존, 오리엔시트는 brand_id 만 이동 — '
  'orient_no 재채번 안 함, 328 파일 상단 "재채번하지 않는 이유" 참고). '
  '회사 불일치·미등록 브랜드도 허용. is_campaign_admin 가드. 121 패턴 재사용. 원본 archived. '
  '멱등성 판정에 orient_sheets 존재 여부 포함(328) — 175 로 이미 병합됐지만 오리엔시트가 '
  '안 옮겨진 과거 건은 이 함수를 다시 호출하면 이관된다(단, 이미 archived 완료된 과거 '
  '건 중 신청·캠페인 흔적이 전혀 없던 병합은 자동 추적 불가 — 이 파일 하단 검증 SQL '
  '진단 조회 참고).';

REVOKE ALL ON FUNCTION public.merge_brands(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.merge_brands(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.merge_brands(uuid, uuid) TO authenticated;

-- 이 절 롤백:
--   175_merge_brands_rpc.sql 의 CREATE OR REPLACE FUNCTION 블록을 그대로 재실행
--   (오리엔시트 미이동 원본 복원). ⚠️ 이미 이 함수로 이동된 orient_sheets.brand_id
--   는 롤백해도 자동으로 되돌아가지 않는다(그 값이 잘못됐다는 뜻이 아니라, 롤백은
--   "앞으로의 병합 동작"만 되돌린다는 뜻).


-- ============================================================
-- I-7. 오리엔시트 — 브랜드가 발행된 카드를 지운 채 저장해도 원상 복구한다
--
--   ── 무엇이 문제였나 ──
--   브랜드가 작성 폼에서 카드를 하나 지우고 저장하면, 그 카드가 이미 캠페인으로
--   발행된 카드였어도(즉 `data.cards[].campaign_id` 값이 있는 카드였어도) 그냥
--   배열에서 사라진다. 되돌릴 방법이 없고, 관리자가 나중에 그 시트를 열어봐야
--   (혹은 안 열어봐서 영영) 발견한다. 실제로 위험한 것은 "관리자가 그 카드가
--   아직 발행 안 된 줄 알고 다시 발행해 같은 제품에 캠페인이 두 번 생기는 것"이다
--   (`mark_orient_card_consumed`, 마이그레이션 196 이 이 campaign_id 값으로
--   "이미 발행됨"을 판정한다 — 그 값이 사라지면 판정 근거 자체가 없어진다).
--
--   ── 거부(reject) vs 보존(preserve) — 판단이 갈린 지점 ──
--   지시문이 짚은 그대로 두 방향 다 단점이 있다:
--     · 거부(그 저장 자체를 실패시킴): 브랜드는 왜 저장이 안 되는지 알 길이
--       없다(화면 코드를 못 건드리므로 새 오류 사유에 맞는 안내 문구를 못 만든다
--       — 클라이언트가 모르는 reason 코드는 대개 범용 "저장 실패" 문구로
--       떨어진다). 게다가 카드는 이미 브라우저 화면(DOM)에서 지워진 뒤라,
--       브랜드가 "다시 되돌리기" 조작을 할 방법 자체가 없다 — **막다른 골목**이
--       된다. 다른 카드를 편집하고 싶어도 전체 저장이 막힌다.
--     · 보존(카드를 원래 내용 그대로 되살림): 이번에 택한 방향. 브랜드 입장에서는
--       "지웠는데 다시 나타난다"는 의아함이 있을 수 있지만, 저장 자체는 항상
--       성공하고(다른 카드 편집은 막히지 않는다) 다음에 폼을 다시 불러오면 그
--       카드가 그대로 보인다 — 관리자·브랜드 양쪽 다 데이터 유실이 없다.
--     · (지시문이 언급한 세 번째 선택지 — "카드 내용 없이 표시(마커)만 남기기")
--       는 채택하지 않았다. 이 저장소는 화면 코드를 건드리지 않는 원칙이라,
--       관리자 상세 화면(admin-orient.js)이 이해 못 하는 새 "빈 카드" 스키마를
--       만들면 오히려 깨진 것처럼 보이는 카드가 관리자 화면에 나타난다(내용이
--       없는데 형식만 있는 카드는 렌더링 조건들[제품명·가격 등 필수 필드 접근]에
--       걸려 오류를 낼 수도 있다). "카드를 통째로 원상 복구"는 기존 카드 스키마
--       그대로라 관리자·브랜드 화면 모두 정상적으로 렌더링된다 — 별도 스키마
--       확장 없이 안전하게 구현 가능한 유일한 선택지였다.
--   → **보존을 택한다.**
--
--   ── 293(uid 보정)과의 정합 ──
--   293 은 "저장하는 카드 배열의 uid 를 보정"하는 함수다. 이 새 보존 로직은
--   293 의 uid 보정이 끝난 **뒤에** 실행돼야 한다 — 새로 저장되는 카드들의 최종
--   uid 가 다 정해진 뒤에야 "옛 카드 중 이번 저장에 없는 것"을 uid 로 정확히
--   비교할 수 있기 때문이다(293 이 uid 를 먼저 안 붙이면, uid 없는 카드와
--   비교해 오탐/누락이 생긴다). 293 이 이미 "물려주기는 개수가 같을 때만"으로
--   막아 둔 위험(번호가 밀려 붙는 것)과는 대체로 다른 층의 문제다
--   — 293 은 "이번에 보내는 카드들의 번호를 정하는" 것이고, 이번 추가는 "그렇게
--   번호가 정해진 결과에, 사라진 발행 카드를 되돌려 붙이는" 것이다.
--   ⚠️ **딱 한 조합만 예외다**(리뷰 지적으로 추가). 브랜드가 **발행된 카드를 지우면서
--   같은 자리에 번호 없는 새 카드를 넣어 전체 개수가 그대로**이면, 293 의 "개수가
--   같으면 같은 자리 번호를 물려받는다"가 **새 카드에 옛 번호를 물려준다.** 그러면
--   이 복원 로직이 볼 때 그 번호가 "이번 저장에 존재"하는 것으로 보여 **발동하지 않고**,
--   발행 표시가 조용히 사라진다. 293 이 원래 안고 있던 잔여 위험이고 이 파일이 만든
--   것은 아니지만, **여기서 막지도 못한다** — 발생하려면 한 번의 저장에서 삭제와 추가가
--   같은 자리에 동시에 일어나야 해 드물다.
--
--   ── 새 순수 계산 함수 _orient_preserve_published_cards ──
--   _orient_apply_card_uids(293)와 같은 성격 — 표를 읽지 않는 순수 jsonb
--   계산 함수라 SECURITY DEFINER 가 아니다. p_data(uid 보정이 끝난, 저장 예정
--   데이터)와 p_existing(저장돼 있던 옛 데이터)을 받아, p_existing 의 카드 중
--   `campaign_id` 가 있고(발행됨) 그 uid 가 p_data 에 없는(이번 저장에서
--   사라진) 카드를 원래 내용 그대로 p_data.cards 끝에 이어붙여 돌려준다.
--   uid 가 없는 옛 카드(이론상 293·294 이후로는 없어야 하지만 방어적으로)는
--   안전하게 매칭할 근거가 없으므로 건드리지 않는다(복구 시도 자체를 안 함 —
--   잘못 복구하는 것보다 안전).
--
--   ── 크기 상한(100KB) 검사와의 순서 ──
--   293 과 동일한 원칙(293 파일 "크기 상한 검사 시점" 참고) — 실제로 저장되는
--   값(카드를 되살린 뒤의 값)을 기준으로 검사해야 한다. 되살리기를 먼저 하고
--   그 결과로 크기를 검사한다. 카드 하나를 통째로 되살리는 경우 uid 보정
--   1개(293, 약 42바이트)보다 훨씬 큰 증가가 있을 수 있으나(카드 전체 내용),
--   100KB 상한 대비 카드 1~2개 분량은 여전히 크지 않다(오리엔시트 카드 1개는
--   텍스트·URL 목록 수준으로, 이미지 자체는 별도 Storage URL 문자열만 담는다).
--   만약 되살리기로 인해 상한을 넘으면 저장 자체가 `data_too_large` 로 거부되고
--   원래 있던 발행 카드는 여전히 서버 쪽 v_sheet.data 에 안전하게 보존된다
--   (거부돼도 데이터 유실은 없다 — 저장이 실패할 뿐 기존 값은 그대로).
--
--   ⚠️ 화면 변경 필요: 없음. 브랜드 폼은 다음 로드 시 서버가 돌려준(또는 다시
--   조회한) data 를 그대로 그려 되살아난 카드를 자연히 보여준다.
-- ============================================================

-- ============================================================
-- A. _orient_preserve_published_cards — 발행된 카드 원상 복구 (순수 계산)
--
--   p_data     : uid 보정(293)까지 끝난, 저장 예정 데이터
--   p_existing : 현재 저장돼 있는 데이터 (원상 복구 재료)
--
--   반환: p_existing 의 발행된 카드 중 p_data 에서 사라진 것을 그대로 이어붙인 p_data
-- ============================================================
CREATE OR REPLACE FUNCTION public._orient_preserve_published_cards(
  p_data     jsonb,
  p_existing jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_cards        jsonb;
  v_old_cards    jsonb;
  v_old_count    int;
  v_new_count    int;
  v_i            int;
  v_old_card     jsonb;
  v_old_uid      text;
  v_old_campaign text;
  v_new_uids     text[] := ARRAY[]::text[];  -- 이번 저장에 실제로 포함될 카드들의 uid
BEGIN
  -- 방어: 객체가 아니면 손대지 않는다 (293 과 동일한 방어 스타일)
  IF p_data IS NULL OR jsonb_typeof(p_data) <> 'object' THEN
    RETURN p_data;
  END IF;

  -- 이번 저장 카드 배열 — 없으면 빈 배열로 취급(전부 사라진 것으로 간주해
  -- 아래 로직이 옛 발행 카드 전체를 대상으로 비교하게 한다)
  v_cards := p_data -> 'cards';
  IF v_cards IS NULL OR jsonb_typeof(v_cards) <> 'array' THEN
    v_cards := '[]'::jsonb;
  END IF;

  -- 원상 복구 재료(옛 카드 목록) — 없으면 되살릴 것도 없다
  v_old_cards := CASE
                   WHEN p_existing IS NOT NULL
                    AND jsonb_typeof(p_existing -> 'cards') = 'array'
                     THEN p_existing -> 'cards'
                   ELSE '[]'::jsonb
                 END;
  v_old_count := jsonb_array_length(v_old_cards);

  IF v_old_count = 0 THEN
    RETURN p_data;
  END IF;

  -- 이번 저장에 실제로 포함되는 카드들의 uid 집합 수집
  -- (호출 시점에 이미 293 의 uid 보정이 끝나 있다는 전제 — save_orient_draft·
  --  submit_orient_sheet 가 _orient_apply_card_uids 다음에 이 함수를 호출한다)
  v_new_count := jsonb_array_length(v_cards);
  FOR v_i IN 0 .. v_new_count - 1 LOOP
    IF jsonb_typeof(v_cards -> v_i) = 'object'
       AND jsonb_typeof(v_cards -> v_i -> 'uid') = 'string'
    THEN
      v_new_uids := v_new_uids || (v_cards -> v_i ->> 'uid');
    END IF;
  END LOOP;

  -- 옛 카드 중 "발행됨(campaign_id 있음)" + "이번 저장에 없음" → 원래 내용 그대로 되살린다
  FOR v_i IN 0 .. v_old_count - 1 LOOP
    v_old_card := v_old_cards -> v_i;
    CONTINUE WHEN jsonb_typeof(v_old_card) <> 'object';

    v_old_campaign := NULLIF(btrim(COALESCE(v_old_card->>'campaign_id', '')), '');
    CONTINUE WHEN v_old_campaign IS NULL;  -- 발행된 적 없는 카드는 대상 아님

    v_old_uid := CASE WHEN jsonb_typeof(v_old_card->'uid') = 'string'
                       THEN NULLIF(btrim(v_old_card->>'uid'), '')
                       ELSE NULL END;
    -- 번호가 없으면 안전하게 매칭할 방법이 없다 — 잘못 복구하는 것보다
    -- 건드리지 않는 편이 안전하므로 이 카드는 건너뛴다(293·294 이후로는
    -- 저장된 카드는 항상 uid 를 가지므로 실무상 발생하지 않는 방어적 분기).
    CONTINUE WHEN v_old_uid IS NULL;

    IF NOT (v_old_uid = ANY(v_new_uids)) THEN
      -- 이번 저장에서 사라졌다 — 원래 내용 그대로 되살린다
      v_cards := v_cards || jsonb_build_array(v_old_card);
      v_new_uids := v_new_uids || v_old_uid;  -- 같은 시트 내 다른 옛 카드와의 재중복 방지
    END IF;
  END LOOP;

  RETURN jsonb_set(p_data, ARRAY['cards'], v_cards, true);
END;
$$;

-- 표를 읽지 않는 순수 계산 함수 — 외부 직접 호출 필요 없음 (293 과 동일 스타일)
REVOKE EXECUTE ON FUNCTION public._orient_preserve_published_cards(jsonb, jsonb) FROM PUBLIC;

COMMENT ON FUNCTION public._orient_preserve_published_cards(jsonb, jsonb) IS
  '[328, I-7] 오리엔시트 저장 시 발행된 카드(campaign_id 있음) 원상 복구. '
  'p_existing 의 발행 카드 중 uid 로 매칭해 p_data 에 없는 것을 원래 내용 그대로 '
  'p_data.cards 끝에 이어붙인다. uid 없는 옛 카드는 안전 매칭 불가로 건드리지 않음. '
  'save_orient_draft·submit_orient_sheet 가 _orient_apply_card_uids(293) 다음에 호출한다 '
  '(uid 보정이 먼저 끝나야 정확히 비교 가능).';


-- ============================================================
-- B. save_orient_draft — 임시저장 (베이스: 293, 변경점만 주석 표시)
-- ============================================================
CREATE OR REPLACE FUNCTION public.save_orient_draft(
  p_token   uuid,
  p_data    jsonb,
  p_version int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet        record;
  v_data_size    int;
  v_rows_updated int;
  v_data         jsonb;   -- 번호 보정 + [328] 발행 카드 복구 결과 — 이 값을 기준으로 크기 검사 + 저장
BEGIN
  -- 토큰으로 오리엔시트 행 조회 (FOR UPDATE 행 잠금 — 동시 저장 충돌 대비) (293 과 동일)
  SELECT id, status, version, token_expires_at, data
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token
     FOR UPDATE;

  -- 미매칭 (293 과 동일)
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  -- 만료 시각 경과 확인 (293 과 동일)
  IF v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < now() THEN
    IF v_sheet.status NOT IN ('expired', 'consumed') THEN
      UPDATE public.orient_sheets
         SET status = 'expired'
       WHERE id = v_sheet.id;
    END IF;
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 저장 불가 상태 차단 (293 과 동일)
  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'consumed');
  END IF;
  IF v_sheet.status = 'expired' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 카드 고유 번호 보정 (293) — 저장돼 있던 data 를 물려주기 재료로 넘긴다.
  v_data := public._orient_apply_card_uids(p_data, v_sheet.data);

  -- [328, I-7] 발행된 카드가 이번 저장에서 통째로 사라졌으면 원래 내용 그대로
  -- 되살린다. 293 의 uid 보정이 끝난 뒤에 호출해야 정확히 비교 가능(위 I-7
  -- 절 "293 과의 정합" 참고).
  v_data := public._orient_preserve_published_cards(v_data, v_sheet.data);

  -- jsonb 크기 상한 가드 (100KB = 102400 바이트). 검사 기준 = 보정 후 값(v_data)
  -- (293 과 동일 원칙 — 카드 되살리기까지 반영된 실제 저장값 기준).
  v_data_size := octet_length(v_data::text);
  IF v_data_size > 102400 THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'data_too_large',
      'limit_bytes', 102400,
      'actual_bytes', v_data_size
    );
  END IF;

  -- 낙관적 락 (293 과 동일)
  IF p_version <> v_sheet.version THEN
    RETURN jsonb_build_object(
      'success',         false,
      'reason',          'conflict',
      'current_version', v_sheet.version
    );
  END IF;

  -- 임시저장: data·version만 갱신 (293 과 동일)
  UPDATE public.orient_sheets
     SET data    = v_data,
         version = v_sheet.version + 1
   WHERE id      = v_sheet.id
     AND version = p_version;

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  IF v_rows_updated = 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'conflict'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'version', v_sheet.version + 1
  );
END;
$$;

-- ⚠️ CREATE OR REPLACE 는 기존 GRANT 를 리셋 → 293 과 동일하게 재적용 (필수)
REVOKE EXECUTE ON FUNCTION public.save_orient_draft(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_orient_draft(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.save_orient_draft(uuid, jsonb, int) IS
  '[293, 328 개정] 오리엔시트 임시저장. anon GRANT — 로그인 없이 토큰·data·version으로 저장. '
  '만료·consumed 상태 차단. 낙관적 락(version 불일치=충돌 반환). '
  '저장 직전 _orient_apply_card_uids(293)로 카드 고유 번호 보정 → '
  '_orient_preserve_published_cards(328)로 발행된 카드가 사라졌으면 원상 복구 → '
  '그 최종 값 기준으로 jsonb 100KB 상한 검사. '
  'status 미변경(submitted→draft 역전환 없음 — data·version만 갱신). '
  'SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- C. submit_orient_sheet — 제출 (베이스: 293, 변경점만 주석 표시)
--    293 이 202 에서 물려받은 반환 키를 하나도 빼지 않는다 (제출 알림 메일이 사용)
-- ============================================================
CREATE OR REPLACE FUNCTION public.submit_orient_sheet(
  p_token   uuid,
  p_data    jsonb,
  p_version int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet        record;
  v_data_size    int;
  v_rows_updated int;
  v_now          timestamptz := now();
  v_is_first     boolean;
  v_data         jsonb;   -- 번호 보정 + [328] 발행 카드 복구 결과 — 이 값을 기준으로 크기 검사 + 저장
BEGIN
  -- 토큰으로 오리엔시트 행 조회 (FOR UPDATE 행 잠금 — 동시 제출 충돌 대비) (293 과 동일)
  SELECT id, brand_id, application_id, form_type,
         status, version, token_expires_at, submitted_at, data
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token
     FOR UPDATE;

  -- 미매칭 (자원 열거 방지 — 187 패턴 유지, 293 과 동일)
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  -- 만료 시각 경과 확인 (293 과 동일)
  IF v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < v_now THEN
    IF v_sheet.status NOT IN ('expired', 'consumed') THEN
      UPDATE public.orient_sheets
         SET status = 'expired'
       WHERE id = v_sheet.id;
    END IF;
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 제출 불가 상태 차단 (293 과 동일)
  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'consumed');
  END IF;
  IF v_sheet.status = 'expired' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 기본 입력 검증: data가 NULL 이거나 빈 객체이면 제출 거부 (원본 입력 기준 — 보정 전, 293 과 동일)
  IF p_data IS NULL OR p_data = '{}'::jsonb THEN
    RETURN jsonb_build_object('success', false, 'reason', 'data_required');
  END IF;

  -- 카드 고유 번호 보정 (293) — 저장돼 있던 data 를 물려주기 재료로 넘긴다.
  v_data := public._orient_apply_card_uids(p_data, v_sheet.data);

  -- [328, I-7] 발행된 카드가 이번 제출에서 통째로 사라졌으면 원래 내용 그대로
  -- 되살린다(save_orient_draft 와 동일 원칙 — 위 I-7 절 참고).
  v_data := public._orient_preserve_published_cards(v_data, v_sheet.data);

  -- jsonb 크기 상한 가드 (100KB = 102400 바이트). 검사 기준 = 보정 후 값(v_data)
  -- (save_orient_draft 와 동일 이유).
  v_data_size := octet_length(v_data::text);
  IF v_data_size > 102400 THEN
    RETURN jsonb_build_object(
      'success',      false,
      'reason',       'data_too_large',
      'limit_bytes',  102400,
      'actual_bytes', v_data_size
    );
  END IF;

  -- 낙관적 락 (293 과 동일)
  IF p_version <> v_sheet.version THEN
    RETURN jsonb_build_object(
      'success',         false,
      'reason',          'conflict',
      'current_version', v_sheet.version
    );
  END IF;

  -- 신규/재제출 판정 (293 과 동일)
  v_is_first := (v_sheet.submitted_at IS NULL);

  -- 제출 전이: draft | submitted → submitted (293 과 동일)
  UPDATE public.orient_sheets
     SET data              = v_data,
         status            = 'submitted',
         submitted_at      = COALESCE(v_sheet.submitted_at, v_now),
         last_submitted_at = v_now,
         version           = v_sheet.version + 1
   WHERE id      = v_sheet.id
     AND version = p_version;

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  IF v_rows_updated = 0 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'conflict');
  END IF;

  RETURN jsonb_build_object(
    'success',             true,
    'version',             v_sheet.version + 1,
    'submitted_at',        COALESCE(v_sheet.submitted_at, v_now),
    'last_submitted_at',   v_now,
    'is_first_submission', v_is_first,
    'orient_sheet_id',     v_sheet.id,
    'brand_id',            v_sheet.brand_id,
    'form_type',           v_sheet.form_type,
    'application_id',      v_sheet.application_id
  );
END;
$$;

-- ⚠️ CREATE OR REPLACE 는 기존 GRANT 를 리셋 → 293 과 동일하게 재적용 (필수)
REVOKE EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) IS
  '[293, 328 개정] 오리엔시트 제출. anon GRANT — 로그인 없이 토큰·data·version 으로 최종 제출. '
  'draft·submitted 양쪽 허용(발행 전 재제출 가능). 만료·consumed 차단. 낙관적 락. '
  'submitted_at 은 최초 불변(COALESCE). last_submitted_at 은 매 제출 갱신. '
  '반환값에 is_first_submission·orient_sheet_id·brand_id·form_type·application_id 포함. '
  '저장 직전 _orient_apply_card_uids(293)로 카드 고유 번호 보정 → '
  '_orient_preserve_published_cards(328)로 발행된 카드가 사라졌으면 원상 복구 → '
  '그 최종 값 기준으로 jsonb 100KB 상한 검사. SECURITY DEFINER + search_path 고정.';

-- 이 절(I-7) 롤백:
--   save_orient_draft·submit_orient_sheet 를 293_orient_card_uid_safety_net.sql 의
--   CREATE OR REPLACE FUNCTION 블록(_orient_preserve_published_cards 호출 없는 버전)
--   그대로 재실행해 되돌린다.
--   DROP FUNCTION IF EXISTS public._orient_preserve_published_cards(jsonb, jsonb);
--   ⚠️ 이미 되살아난 카드는 이미 데이터에 반영된 상태로 남는다(무해 — 그 카드는
--   실제로 발행된 캠페인을 가리키는 정상 데이터이므로 되돌릴 이유가 없다).


-- ============================================================
-- I-9. 결과물 상태 이력(deliverable_events) — 결과물이 하드 삭제돼도 보존
--
--   ── 무엇이 문제였나 ──
--   deliverable_events.deliverable_id 는 deliverables(id) 를 ON DELETE CASCADE
--   로 참조한다(035). review_image·post 의 재제출은 "새 행"이 아니라 "기존
--   행을 draft 로 되돌리는 UPDATE"라서(276 파일 상단 설명 그대로), 반려됐던
--   행 하나가 재제출 흐름 내내 재사용된다. 그런데 인플루언서 본인에게는 이
--   draft 상태 행을 지우는 정상 기능이 있다 — `deleteDraftDeliverable`
--   (dev/lib/storage.js) 가 `deliverables_delete_own_draft`(042) 정책으로
--   본인의 draft 행을 그대로 하드 DELETE 한다("업로드했던 사진을 다시 올리기
--   전에 지우기" 같은 일상적인 조작). 마감 후 재제출 예외 상태(반려됨 →
--   재제출용으로 draft 로 되돌려짐)에서 이 "지우기"를 누르면, 그 행 자체가
--   사라지고 CASCADE 로 그 행의 deliverable_events 도 함께 사라진다.
--
--   `can_submit_deliverable`(276) 의 마감 후 판정은 Tier 1(현재 상태)에서
--   실패하면 Tier 2(deliverable_events 이력)로 폴백해 "가장 최근 결정이
--   반려였다"를 근거로 재제출을 허용한다. 그런데 그 유일한 증거(이력)까지
--   함께 사라졌으므로 Tier 2도 "아무 기록 없음"이 되어, 이후 그 채널은
--   `submission_deadline_passed`로 **영구 차단**된다 — 그 응모는 그 채널에
--   다시는 아무것도 못 낸다.
--
--   ── 왜 트리거(record_deliverable_status_event, 073)를 재정의하지 않는가 ──
--   그 트리거는 "무엇을 INSERT 하는가"(action·from_status·to_status 등)를
--   결정하는 자리다. 이번에 필요한 건 "INSERT 되는 모든 행에 스냅샷 값을
--   덧붙이는" 것으로, INSERT 경로가 이 트리거 하나가 아니라 submit_deliverable
--   RPC(035)·관리자 대리 등록/회수 RPC 4종(160·162·163·182·183)까지 최소
--   6곳에 흩어져 있다. 이 6곳을 전부 찾아 각자 INSERT 문에 스냅샷 칸을
--   추가하는 대신, **INSERT 되는 표(deliverable_events) 자체에 BEFORE INSERT
--   트리거를 새로 하나 붙여** 어느 경로로 들어오든 한 곳에서 자동으로 채운다
--   — 252(receipt_edit_history)가 update_receipt_admin RPC 코드를 하나도
--   안 건드리고 같은 방식으로 스냅샷을 넣었던 것과 동일한 설계.
--
--   ── 253 파일이 이미 남겨 둔 예고 ──
--   253 파일 상단: "⚠️ deliverable_events(카트에 담긴 결과물 자체 상태변경
--   이력) 는 이번 범위 밖 — 여전히 CASCADE 다(217 파일 주석에 명시된 기존
--   한계, 이번엔 손대지 않음)." 이 조각이 그 후속이다. 252(스냅샷 칸 추가 +
--   nullable 전환)와 253(CASCADE→SET NULL 전환)이 receipt_edit_history 에
--   했던 일을 deliverable_events 에 그대로 이식한다(두 마이그레이션으로
--   나뉘어 있던 것을 이 조각에서는 한 파일 안에 합쳤다 — 새로 하는 일이라
--   중간 단계를 오갈 필요가 없다).
--
--   ── 스냅샷 4칸 선택 근거 ──
--   `can_submit_deliverable` 의 Tier 2 조회가 실제로 필요한 값 3개
--   (application_id·kind·post_channel) + 식별용 deliverable_id_snapshot.
--   252 의 4칸(deliverable_id·application_id·campaign_id·user_id)과 구성이
--   다른 이유 — 이 표는 "그 결과물이 누구 것이었는지"가 아니라 "그 채널에
--   대해 마지막으로 무슨 결정이 내려졌는지"를 재구성하는 데 쓰이므로, 딱
--   그 판정에 필요한 값만 최소로 담는다(campaign_id·user_id 스냅샷은 이번
--   목적에 쓰이지 않아 추가하지 않았다 — 필요해지면 후속 마이그레이션에서
--   같은 트리거에 칸만 늘리면 된다).
--
--   ── 채널 재지정(162 channel_assign)과의 정합 — 사소하지만 인지된 트레이드오프 ──
--   review_image 의 채널은 "채널 없음(NULL) → 값 있음"으로 딱 한 번만 바뀔
--   수 있고(162 의 assign_review_image_channel — 이미 채널이 지정된 행은
--   재지정 자체가 막혀 있다), 그 변경 이전에 쌓인 이벤트의
--   post_channel_snapshot 은 그 시점의 실제 값(NULL)을 정확히 반영한다.
--   ⚠️ 「동작 차이 없음」이 아니다(리뷰 지적으로 정정). 예전 방식은 이벤트를
--   deliverables 의 **현재 값**과 조인했으므로, 같은 결과물의 이벤트는 채널을
--   지정하기 **전에 쌓인 것까지** 현재 채널값으로 일괄 매칭됐다. 스냅샷 방식은
--   **그때 값(NULL)** 을 고정하므로 그 이벤트는 이제 안 잡힌다.
--   → 차이가 나는 조합: 「채널이 없던 상태에서 반려됨 → 나중에 관리자가 채널을
--   지정함 → 그 행이 아직 살아 있음」. 이 셋이 동시에 성립하는 옛 데이터만 해당한다.
--   적용 전에 아래 조회로 대상이 0건인지 확인할 것(아래 검증 절차에도 넣어 뒀다):
--     SELECT d.id FROM public.deliverables d
--      WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL
--        AND EXISTS (SELECT 1 FROM public.deliverable_events e
--                     WHERE e.deliverable_id = d.id AND e.to_status = 'rejected'
--                       AND e.post_channel_snapshot IS NULL);
--   0건이 아니면 그 행들은 마감 후 재제출 권리를 잃는다 — 스냅샷을 손으로 채우거나
--   적용을 미룰지 판단할 것.
--
--   ── Tier 2 조회를 JOIN 없이 스냅샷 칸만으로 다시 쓰는 이유 ──
--   "결과물 행이 살아있든 하드 삭제됐든 항상 같은 값을 돌려줘야" 하므로,
--   deliverables 를 JOIN 해서 값을 가져오는 대신(그러면 하드 삭제된 경우
--   JOIN 대상이 없어 결과가 사라진다) 이벤트 자체에 미리 박아 둔 스냅샷을
--   직접 본다. 신규 이벤트는 트리거가 항상 채우므로 이 조회가 예전 JOIN
--   방식과 100% 동일한 결과를 낸다(살아있는 행에 대해서는) — 유일한 차이는
--   행이 하드 삭제된 뒤에도 이 조회가 계속 값을 돌려준다는 것.
--
--   ⚠️ 화면 변경 필요: 없음(이 조각 단독으로는). deliverable_events 를 직접
--   SELECT 하는 화면 조회(dev/lib/storage.js fetchDeliverableEvents)는 항상
--   "아직 존재하는 결과물"의 상세 모달에서만 호출되므로(사라진 결과물은 상세
--   모달을 열 방법 자체가 없다) 이번 변경의 영향 범위 밖이다.
--   ⚠️ 잔여 항목(구현하지 않음, 보고 전용) — `deliverable_events_select_own`
--   RLS 정책(035)은 여전히 `EXISTS(SELECT 1 FROM deliverables d WHERE
--   d.id = deliverable_id AND d.user_id = auth.uid())` 형태라, deliverable_id
--   가 SET NULL 로 비워진 이벤트는 그 인플루언서 본인의 직접 테이블 조회에서
--   더 이상 보이지 않는다(actor_id 가 본인이면 여전히 보임). `can_submit_
--   deliverable`/`get_deliverable_gate` 는 SECURITY DEFINER 라 이 RLS 와 무관하게
--   항상 정확히 동작하므로 이 조각의 목적(마감 후 재제출 예외 판정)에는 영향이
--   없다 — 순수하게 "인플루언서가 원본 테이블을 직접 조회했을 때"의 부차적인
--   가시성 이야기라, 이번 지시 범위(마이그레이션) 안에서는 손대지 않는다.
-- ============================================================

-- ── A. 스냅샷 칸 4종 추가 (252 의 receipt_edit_history 패턴 그대로) ──────
ALTER TABLE public.deliverable_events
  ADD COLUMN IF NOT EXISTS deliverable_id_snapshot  uuid NULL,
  ADD COLUMN IF NOT EXISTS application_id_snapshot  uuid NULL,
  ADD COLUMN IF NOT EXISTS kind_snapshot            text NULL,
  ADD COLUMN IF NOT EXISTS post_channel_snapshot    text NULL;

COMMENT ON COLUMN public.deliverable_events.deliverable_id_snapshot IS
  '[328] deliverable_id 의 영구 스냅샷. 결과물이 하드 삭제돼 deliverable_id 가 '
  'SET NULL 되어도 이 값은 남아 "어떤 결과물이었는지"를 식별할 수 있게 한다.';
COMMENT ON COLUMN public.deliverable_events.application_id_snapshot IS
  '[328] 이벤트 발생 시점 deliverables.application_id 스냅샷. FK 없음(정보용). '
  'can_submit_deliverable(276) 의 마감 후 재제출 예외(Tier 2) 판정이 이 값으로 조회한다.';
COMMENT ON COLUMN public.deliverable_events.kind_snapshot IS
  '[328] 이벤트 발생 시점 deliverables.kind 스냅샷. FK 없음(정보용).';
COMMENT ON COLUMN public.deliverable_events.post_channel_snapshot IS
  '[328] 이벤트 발생 시점 deliverables.post_channel 스냅샷. FK 없음(정보용). '
  'review_image·post 의 채널 단위 마감 후 재제출 예외(276) 판정에 사용.';

-- ── B. 기존 행 백필 ────────────────────────────────────────────────────
--    이 마이그레이션 시점까지는 여전히 CASCADE 이므로, 존재하는 모든
--    deliverable_events 행은 100% 유효한 deliverable_id 를 갖는다(252 와
--    동일 논리 — 고아 행이 존재할 수 없는 구조였다).
UPDATE public.deliverable_events de
   SET deliverable_id_snapshot = de.deliverable_id,
       application_id_snapshot = d.application_id,
       kind_snapshot           = d.kind,
       post_channel_snapshot   = d.post_channel
  FROM public.deliverables d
 WHERE d.id = de.deliverable_id
   AND de.deliverable_id_snapshot IS NULL;

-- 백필 후 deliverable_id_snapshot 은 NOT NULL 로 강제(신규 행은 트리거가 항상 채움)
ALTER TABLE public.deliverable_events
  ALTER COLUMN deliverable_id_snapshot SET NOT NULL;

-- ── C. BEFORE INSERT 트리거 — 신규 이벤트에 스냅샷 자동 채움 ────────────
--    (기존 6개 INSERT 지점 — 073 트리거, 035 submit_deliverable RPC,
--    160·162·163·182·183 관리자 RPC — 어느 것도 코드를 고치지 않는다.
--    이 트리거 하나가 어느 경로로 들어오든 자동으로 채운다.)
CREATE OR REPLACE FUNCTION public.snapshot_deliverable_events()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_deliverable record;
BEGIN
  NEW.deliverable_id_snapshot := NEW.deliverable_id;

  IF NEW.deliverable_id IS NOT NULL THEN
    SELECT application_id, kind, post_channel
      INTO v_deliverable
      FROM public.deliverables
     WHERE id = NEW.deliverable_id;

    IF FOUND THEN
      NEW.application_id_snapshot := v_deliverable.application_id;
      NEW.kind_snapshot           := v_deliverable.kind;
      NEW.post_channel_snapshot   := v_deliverable.post_channel;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.snapshot_deliverable_events() IS
  '[328] deliverable_events INSERT 시 deliverable_id 로부터 application_id/kind/'
  'post_channel 스냅샷을 자동 채움. 기존 INSERT 지점(073 트리거·035 RPC·160·162·163·'
  '182·183 관리자 RPC) 코드 전부 무변경 — 트리거가 투명 처리(252 패턴 재사용).';

DROP TRIGGER IF EXISTS trg_deliverable_events_snapshot ON public.deliverable_events;
CREATE TRIGGER trg_deliverable_events_snapshot
  BEFORE INSERT ON public.deliverable_events
  FOR EACH ROW
  EXECUTE FUNCTION public.snapshot_deliverable_events();

-- ── D. 조회 인덱스 — can_submit_deliverable Tier 2 조회 패턴에 맞춤 ──────
CREATE INDEX IF NOT EXISTS idx_deliverable_events_snapshot_lookup
  ON public.deliverable_events (application_id_snapshot, kind_snapshot, post_channel_snapshot, created_at DESC);

-- ── E. 외래 키: CASCADE → SET NULL (253 의 receipt_edit_history 패턴 그대로) ──
ALTER TABLE public.deliverable_events
  ALTER COLUMN deliverable_id DROP NOT NULL;

DO $$
DECLARE
  v_conname text;
BEGIN
  SELECT conname INTO v_conname
    FROM pg_constraint
   WHERE conrelid = 'public.deliverable_events'::regclass
     AND contype = 'f'
     AND confrelid = 'public.deliverables'::regclass;

  IF v_conname IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.deliverable_events DROP CONSTRAINT %I', v_conname);
  END IF;
END $$;

ALTER TABLE public.deliverable_events
  ADD CONSTRAINT deliverable_events_deliverable_id_fkey
  FOREIGN KEY (deliverable_id) REFERENCES public.deliverables(id) ON DELETE SET NULL;

COMMENT ON CONSTRAINT deliverable_events_deliverable_id_fkey ON public.deliverable_events IS
  '[328] CASCADE(035) → SET NULL 로 재정의. 결과물이 하드 삭제돼도(본인 임시저장 '
  '삭제 포함) 이 이력 행은 보존하고 deliverable_id 만 비운다 — 어떤 결과물이었는지는 '
  '위 스냅샷 칸으로 식별. 253 이 receipt_edit_history 에 한 것과 동일한 조치.';

-- ── F. can_submit_deliverable 재정의 — Tier 2 조회를 스냅샷 칸 기준으로 전환 ──
--    (276 원본과 완전히 동일 + Tier 2 SELECT 문 한 곳만 교체. 함수 시그니처·
--    반환 타입 불변 — DROP 불필요, CREATE OR REPLACE 로 충분.)
CREATE OR REPLACE FUNCTION public.can_submit_deliverable(
  p_application_id uuid,
  p_kind           text,
  p_post_channel   text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_submission_end  date;
  v_today_kst       date;
  v_latest_status   text;
  v_hist_to_status  text;
BEGIN
  -- 0. 호출자 검증 (276 과 동일 — 본인 신청만 조회 가능)
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.applications a
       WHERE a.id = p_application_id AND a.user_id = auth.uid()
    ) THEN
      RETURN jsonb_build_object('allowed', false, 'reason', 'permission_denied', 'submission_end', NULL);
    END IF;
  END IF;

  -- 1. 신청 → 캠페인 제출 마감일(submission_end) 조회 (276 과 동일)
  SELECT c.submission_end
    INTO v_submission_end
    FROM public.applications a
    JOIN public.campaigns c ON c.id = a.campaign_id
   WHERE a.id = p_application_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'application_not_found', 'submission_end', NULL);
  END IF;

  IF v_submission_end IS NULL THEN
    RETURN jsonb_build_object('allowed', true, 'reason', 'no_deadline', 'submission_end', NULL);
  END IF;

  -- 2. 일본 시각(Asia/Tokyo) 기준 오늘 <= 마감일이면 통과 (276 과 동일)
  v_today_kst := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  IF v_today_kst <= v_submission_end THEN
    RETURN jsonb_build_object('allowed', true, 'reason', 'within_deadline', 'submission_end', v_submission_end);
  END IF;

  -- 3. 마감 후 — 반려 예외 판정 (Tier 1: 현재 status 기준). (276 과 동일)
  SELECT d.status
    INTO v_latest_status
    FROM public.deliverables d
   WHERE d.application_id = p_application_id
     AND d.kind = p_kind
     AND d.status <> 'draft'
     AND (p_kind NOT IN ('review_image', 'post') OR d.post_channel = p_post_channel)
   ORDER BY d.created_at DESC, d.id DESC
   LIMIT 1;

  IF v_latest_status IS NOT NULL THEN
    IF v_latest_status = 'rejected' THEN
      RETURN jsonb_build_object('allowed', true, 'reason', 'rejected_exception', 'submission_end', v_submission_end);
    ELSE
      RETURN jsonb_build_object('allowed', false, 'reason', 'submission_deadline_passed', 'submission_end', v_submission_end);
    END IF;
  END IF;

  -- [328, I-9] 3-보강 (Tier 2: 이력 기반 폴백). JOIN 없이 이벤트 자체의 스냅샷
  -- 칸으로 직접 조회한다 — 예전에는 deliverables 를 JOIN 해서 찾았는데, 그
  -- 결과물 행이 하드 삭제(본인 임시저장 삭제 포함)되면 JOIN 대상이 사라져 이
  -- 조회가 통째로 0건이 되고, 마감 후 재제출 예외의 유일한 근거가 함께
  -- 사라져 그 채널이 영구 차단됐다(이 파일 상단 "묶음 I — I-9" 참고).
  -- 스냅샷 칸(328)은 행이 INSERT 되는 시점에 자동으로 채워지고 그 뒤로는
  -- 절대 바뀌지 않으므로, 원본 결과물 행의 생사와 무관하게 항상 같은 값을
  -- 돌려준다 — 살아있는 행에 대해서는 예전 JOIN 방식과 결과가 100% 동일하다.
  SELECT e.to_status
    INTO v_hist_to_status
    FROM public.deliverable_events e
   WHERE e.application_id_snapshot = p_application_id
     AND e.kind_snapshot = p_kind
     AND (p_kind NOT IN ('review_image', 'post') OR e.post_channel_snapshot = p_post_channel)
     AND e.to_status IN ('approved', 'rejected')
   ORDER BY e.created_at DESC
   LIMIT 1;

  IF v_hist_to_status = 'rejected' THEN
    RETURN jsonb_build_object('allowed', true, 'reason', 'rejected_exception_history', 'submission_end', v_submission_end);
  END IF;

  -- 4. 그 외 거부 (276 과 동일)
  RETURN jsonb_build_object('allowed', false, 'reason', 'submission_deadline_passed', 'submission_end', v_submission_end);
END;
$$;

COMMENT ON FUNCTION public.can_submit_deliverable(uuid, text, text) IS
  '[276, 328 개정] 결과물(deliverables) 제출 가부 판정 — 단일 소스. 마감 전이면 통과,
   마감 후엔 "최신 비-draft 행이 rejected"(Tier 1, review_image·post 는 채널 단위)
   또는 그마저 전부 draft/삭제됨이면 이력상 마지막 결정이 reject(Tier 2)일 때만
   예외 통과. [328] Tier 2 는 deliverable_events 의 스냅샷 칸(application_id_
   snapshot·kind_snapshot·post_channel_snapshot)을 JOIN 없이 직접 조회 — 결과물
   행이 하드 삭제돼도(인플루언서 본인 임시저장 삭제 포함) 이력이 함께 사라지지
   않는다(사양서 「묶음 I」 I-9). 화면·트리거·대조 게이트가 전부 이 함수 하나만
   소비해야 한다(직접 재구현 금지). 사양서 docs/specs/2026-07-29-deadline-server-
   enforcement.md 3단계 + docs/specs/2026-08-07-audit-remediation-plan.md 묶음 I.';

REVOKE ALL ON FUNCTION public.can_submit_deliverable(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_submit_deliverable(uuid, text, text) TO authenticated;

-- 이 절(I-9) 롤백:
--   -- 외래 키를 CASCADE 로 되돌리기
--   DO $$
--   DECLARE v_conname text;
--   BEGIN
--     SELECT conname INTO v_conname FROM pg_constraint
--      WHERE conrelid = 'public.deliverable_events'::regclass
--        AND contype = 'f' AND confrelid = 'public.deliverables'::regclass;
--     IF v_conname IS NOT NULL THEN
--       EXECUTE format('ALTER TABLE public.deliverable_events DROP CONSTRAINT %I', v_conname);
--     END IF;
--   END $$;
--   ALTER TABLE public.deliverable_events
--     ADD CONSTRAINT deliverable_events_deliverable_id_fkey
--     FOREIGN KEY (deliverable_id) REFERENCES public.deliverables(id) ON DELETE CASCADE;
--   DROP TRIGGER IF EXISTS trg_deliverable_events_snapshot ON public.deliverable_events;
--   DROP FUNCTION IF EXISTS public.snapshot_deliverable_events();
--   DROP INDEX IF EXISTS public.idx_deliverable_events_snapshot_lookup;
--   -- can_submit_deliverable 을 276 시점(JOIN 기반 Tier 2)으로 되돌리려면 276 파일의
--   -- CREATE OR REPLACE FUNCTION 블록을 그대로 재실행할 것.
--   -- 스냅샷 칸 자체는 남겨 둬도 무해하다(삭제하려면 아래):
--   -- ALTER TABLE public.deliverable_events DROP COLUMN IF EXISTS deliverable_id_snapshot;
--   -- ALTER TABLE public.deliverable_events DROP COLUMN IF EXISTS application_id_snapshot;
--   -- ALTER TABLE public.deliverable_events DROP COLUMN IF EXISTS kind_snapshot;
--   -- ALTER TABLE public.deliverable_events DROP COLUMN IF EXISTS post_channel_snapshot;
--   -- ⚠️ CASCADE 로 되돌린 뒤에도 deliverable_id 가 이미 SET NULL 로 비워진 과거
--   --    행은 그대로 NULL 로 남는다(복구 불가 — 그 시점에 하드 삭제된 결과물은
--   --    이미 없으므로 채울 방법이 없다). 스냅샷 칸이 남아 있으면 그래도 "어떤
--   --    결과물이었는지"는 계속 식별 가능하다.


NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 SQL (조각별 — 1단계씩 실행·결과 확인 후 다음 단계로. 개발서버 먼저.
--   .claude/rules/supabase.md 「SQL 검증 순차 안내」)
--   ⚠️ 아래 블록 안에서 파일 경로를 적을 때 "migrations/" 바로 뒤에 "*.sql" 을
--   붙이지 않는다(공백을 하나 둔다) — PostgreSQL 은 블록 주석을 중첩 처리해서
--   "/*" 조합이 나오면 새 주석이 또 열린 것으로 읽어 이 블록 전체가 안 닫히는
--   사고가 327 에서 실제로 있었다.
-- ============================================================
/*

-- ── I-4 검증 ──

-- [1] 함수 재정의 확인
SELECT routine_name, data_type
  FROM information_schema.routines
 WHERE routine_schema = 'public' AND routine_name = 'delete_orient_sheet';
-- 기대: data_type = 'jsonb' (변경 없음 — 재정의 전후 동일 타입)

-- [2] 스모크 대상 확보 — 신청 0건인 발행 캠페인이 딸린 오리엔시트 1건
--     (개발서버에서 테스트용 시트로 진행할 것. 실제 운영 데이터 삭제 금지)
SELECT os.id, os.orient_no, os.brand_id, os.status,
       jsonb_array_length(COALESCE(os.data->'cards', '[]'::jsonb)) AS card_count
  FROM public.orient_sheets os
 WHERE os.status = 'consumed'
 ORDER BY os.created_at DESC
 LIMIT 5;

-- [3] 스모크 호출은 앱에서 campaign_admin 로그인 세션으로 (SQL Editor 직접
--     실행은 auth.uid() 가 NULL 이라 permission_denied 로 막힘, 정상).
--     삭제 전후로 아래를 대조:
-- SELECT id, deleted_at, deleted_by FROM public.campaigns WHERE id = ANY('{<위 시트의 카드 campaign_id 들>}'::uuid[]);
-- 기대(호출 후): deleted_at·deleted_by 채워짐(하드 삭제로 행이 아예 사라지는 게 아님)

-- [4] 「삭제됨」 탭에서 실제로 보이는지 — 관리자 화면 캠페인 목록 「삭제됨」 탭에서
--     방금 삭제한 캠페인이 보이고 복구 버튼이 있는지 육안 확인.


-- ── I-5 검증 ──

-- [5] 함수 재정의 확인
SELECT prosrc ILIKE '%orient_sheets%SET brand_id%'
       OR prosrc ILIKE '%UPDATE public.orient_sheets%' AS has_orient_move
  FROM pg_proc
 WHERE proname = 'merge_brands' AND pronamespace = 'public'::regnamespace;
-- 기대: true

-- [6] 스모크 대상 확보 — 오리엔시트가 있는 브랜드 하나(원본 후보), 다른 브랜드
--     하나(대상 후보). 반드시 개발서버에서, 실제 운영과 무관한 테스트 브랜드로.
SELECT b.id, b.name, b.status, count(os.id) AS orient_count
  FROM public.brands b
  LEFT JOIN public.orient_sheets os ON os.brand_id = b.id
 GROUP BY b.id, b.name, b.status
HAVING count(os.id) > 0
 ORDER BY orient_count DESC
 LIMIT 5;

-- [7] 병합 스모크 (BEGIN~ROLLBACK, campaign_admin 세션 흉내)
-- BEGIN;
--   SELECT set_config('request.jwt.claims',
--     json_build_object('sub', '<campaign_admin 이상 auth_id>')::text, true);
--   SELECT public.merge_brands('<원본 브랜드 id>'::uuid, '<대상 브랜드 id>'::uuid);
--   -- 기대: moved_orient_sheets > 0 (원본에 오리엔시트가 있었다면)
--   SELECT brand_id FROM public.orient_sheets WHERE brand_id = '<원본 브랜드 id>'::uuid;
--   -- 기대: 0행(전부 대상으로 옮겨짐)
-- ROLLBACK;

-- [8] 진단 — 이미 archived 됐는데 여전히 오리엔시트가 남아 있는 브랜드(과거
--     병합 잔재, 자동 이관 대상 아님 — 위 파일 상단 "이미 병합된 과거 데이터"
--     참고). 있으면 하나씩 수동으로 어느 브랜드로 옮겨야 하는지 판단할 것.
SELECT b.id AS orphaned_source_brand_id, b.name, count(os.id) AS orphaned_orient_sheets
  FROM public.brands b
  JOIN public.orient_sheets os ON os.brand_id = b.id
 WHERE b.status = 'archived'
 GROUP BY b.id, b.name
 ORDER BY orphaned_orient_sheets DESC;
-- 0행이면 손댈 과거 데이터가 없다는 뜻(가장 좋은 결과).


-- ── I-7 검증 ──

-- [9] 함수 존재 확인
SELECT proname FROM pg_proc
 WHERE proname IN ('_orient_preserve_published_cards', 'save_orient_draft', 'submit_orient_sheet')
   AND pronamespace = 'public'::regnamespace;
-- 기대: 3행

-- [10] 시험용 시트로 재현 (BEGIN~ROLLBACK 아님 — 실제 orient_sheets 행을 만들고
--    끝에 지운다. 293 검증 블록과 같은 방식, 개발서버 한정)
INSERT INTO public.orient_sheets (brand_id, token, status, data, version, token_expires_at, orient_no)
SELECT
  (SELECT id FROM public.brands ORDER BY created_at LIMIT 1),
  gen_random_uuid(),
  'draft',
  '{"cards":[{"uid":"pubcard001","product_name":"발행됨","campaign_id":"' ||
    (SELECT id FROM public.campaigns ORDER BY created_at LIMIT 1)::text ||
    '"},{"uid":"draftcard001","product_name":"미발행"}]}'::jsonb,
  1,
  now() + interval '30 days',
  'BTEST-O' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)
RETURNING id, token, version;
-- ↑ token 값을 아래 <token> 자리에 사용.

-- [11] 발행된 카드를 뺀 채 저장(브랜드가 그 카드를 지운 상황 재현)
SELECT public.save_orient_draft(
  '<token>'::uuid,
  '{"cards":[{"uid":"draftcard001","product_name":"미발행"}]}'::jsonb,
  1
);
-- 기대: {"success":true,"version":2}

SELECT data -> 'cards' AS cards_after FROM public.orient_sheets WHERE token = '<token>'::uuid;
-- ★기대: 카드가 2개다 — "미발행" 1개(보낸 그대로) + "발행됨" 1개(자동으로 되살아남,
--   uid="pubcard001"·campaign_id 값 그대로 유지).

-- [12] 정리 — 시험용 행 삭제
DELETE FROM public.orient_sheets WHERE token = '<token>'::uuid;


-- ── I-9 검증 ──

-- [13] 컬럼·트리거·외래 키 확인
SELECT column_name, is_nullable
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='deliverable_events'
   AND column_name IN ('deliverable_id_snapshot','application_id_snapshot','kind_snapshot','post_channel_snapshot','deliverable_id')
 ORDER BY column_name;
-- 기대: deliverable_id_snapshot NOT NULL, 나머지(application_id_snapshot·kind_snapshot·
--   post_channel_snapshot·deliverable_id) 는 nullable

SELECT tgname FROM pg_trigger
 WHERE tgrelid = 'public.deliverable_events'::regclass AND tgname = 'trg_deliverable_events_snapshot';
-- 기대: 1행

SELECT conname, confdeltype
  FROM pg_constraint
 WHERE conrelid = 'public.deliverable_events'::regclass AND contype = 'f'
   AND confrelid = 'public.deliverables'::regclass;
-- 기대: confdeltype = 'n' (SET NULL)

-- [14] 백필 결과 확인 — 스냅샷이 비어 있는 기존 행이 있는지(있으면 안 됨)
SELECT count(*) FROM public.deliverable_events WHERE deliverable_id_snapshot IS NULL;
-- 기대: 0

-- [15] 재현 시나리오 — 반려 → 재제출용 draft → 그 draft 를 지워도 이력이 남는지
--    (개발서버, 실제 인플루언서 테스트 계정 필요 — SQL 만으로는 RLS 를 완전히
--    흉내낼 수 없다. 아래는 데이터베이스 쪽 사실 확인용 조회)
--    a) review_image 또는 post 가 반려된(rejected) 결과물 하나를 찾는다:
SELECT d.id, d.application_id, d.kind, d.post_channel, d.status
  FROM public.deliverables d
 WHERE d.kind IN ('review_image', 'post') AND d.status = 'rejected'
 LIMIT 5;
--    b) 그 deliverable_id 로 쌓인 이벤트를 확인한다(가장 최근 reject 이벤트가
--       있어야 함):
SELECT id, action, from_status, to_status, application_id_snapshot, kind_snapshot,
       post_channel_snapshot, created_at
  FROM public.deliverable_events
 WHERE deliverable_id = '<위 d.id>'::uuid
 ORDER BY created_at DESC;
--    c) (개발서버 한정, 테스트 계정으로) 그 결과물을 실제로 하드 삭제해 본
--       뒤(관리자 도구가 아니라 인플루언서 본인이 deleteDraft 를 누르는 화면
--       조작이 필요 — 이 마이그레이션만으로는 재현 불가, 화면 세션 필요),
--       이벤트가 남아 있는지 + can_submit_deliverable 이 여전히
--       rejected_exception_history 를 반환하는지 확인:
-- SELECT deliverable_id, deliverable_id_snapshot, application_id_snapshot, kind_snapshot
--   FROM public.deliverable_events WHERE deliverable_id_snapshot = '<위 d.id>';
-- 기대: 행이 남아있고 deliverable_id 는 NULL, deliverable_id_snapshot 은 값 유지
-- SELECT public.can_submit_deliverable('<응모 id>'::uuid, '<kind>', '<채널 또는 NULL>');
-- 기대: {"allowed":true,"reason":"rejected_exception_history",...}
--   (마감이 이미 지난 캠페인의 응모여야 이 분기까지 도달한다 — within_deadline
--   이면 이 검사 이전에 이미 allowed:true 로 끝난다)

*/

-- ============================================================
-- 전체 롤백 (조각 4개를 한 번에 되돌릴 때)
-- ============================================================
-- BEGIN;
--   -- I-4
--   DROP FUNCTION IF EXISTS public.delete_orient_sheet(uuid);
--   -- 239_delete_orient_sheet_preserve_linked_existing.sql 본문 재실행(하드 삭제 원본 복원)
--   -- I-5
--   -- 175_merge_brands_rpc.sql 의 CREATE OR REPLACE FUNCTION 블록 재실행(오리엔시트 미이동 원본 복원)
--   -- I-7
--   -- 293_orient_card_uid_safety_net.sql 의 save_orient_draft·submit_orient_sheet
--   -- CREATE OR REPLACE FUNCTION 블록 재실행(카드 복구 없는 원본 복원)
--   DROP FUNCTION IF EXISTS public._orient_preserve_published_cards(jsonb, jsonb);
--   -- I-9
--   DROP TRIGGER IF EXISTS trg_deliverable_events_snapshot ON public.deliverable_events;
--   DROP FUNCTION IF EXISTS public.snapshot_deliverable_events();
--   DROP INDEX IF EXISTS public.idx_deliverable_events_snapshot_lookup;
--   -- 외래 키를 CASCADE 로 되돌리기(동적 조회 후 DROP+ADD, 위 I-9 절 롤백 참고)
--   -- 276_deliverable_gate_batch_and_post_channel_exception.sql 의 can_submit_deliverable
--   -- CREATE OR REPLACE FUNCTION 블록 재실행(JOIN 기반 Tier 2 원본 복원)
-- COMMIT;
