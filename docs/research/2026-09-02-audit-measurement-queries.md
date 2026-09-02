# 실측·검증 조회 모음 — 전수조사(2차) 후속

**조사 결과:** `docs/research/2026-09-02-codebase-audit-findings.md`
**조치 계획:** `docs/specs/2026-09-02-audit-remediation-plan.md` — 🔴 **M 번호의 정의처는 이 문서다.** 계획의 「묶음 M」 표는 역방향 색인이고, 조각별 대응은 각 묶음의 「선행」 칸에 있다.

⚠️ **대상은 운영 데이터베이스**(`nrwtujmlbktxjgdwlpjj`). 개발 데이터베이스에는 운영 복제본이 섞여 있어 근거가 되지 않는다([[feedback_db_target_verification]]).
⚠️ **전부 읽기 전용이다.** 데이터를 바꾸는 문장은 하나도 없다.
⚠️ **SQL 편집기로 재현 못 하는 것이 있다** — 편집기는 서비스 키로 돌아 행 단위 보안 정책·`auth.uid()` 분기를 우회한다. 그런 항목은 **실제 로그인 브라우저**라고 따로 적었다.

🔴 **왜 실측을 먼저 하나** — 직전 조사(2026-08-07)에서 실측 8건 중 **절반이 「해당 없음」**이었다. 조사 문서를 그대로 믿고 착수했으면 없는 문제를 고칠 뻔했고, 실측이 계획을 크게 줄였다.

---

## 🔴 실측하면 안 되는 항목 (먼저 못박아 둔다)

**§1-1 방침 개정 통지 함수** — **그 함수를 호출하지 않는다.** 확인하는 행위가 곧 전 회원 메일 발송이다. 코드 근거(호출자 검증 0건·이스케이프 0건)와 배포 확인(`supabase functions list`)으로 이미 확정됐다.

⚠️ **금지되는 것은 「호출」이지 「조회」가 아니다.** `policy_notice_runs` 를 **읽기만 하는** 조회는 허용된다 — 그게 없으면 D-9(「선점 먼저, 발송 그다음」)의 조치 범위를 정할 수 없다. 세 문서가 이 범위로 통일돼 있다.

---

## M1 — 「감사용」 표시가 켜진 회원이 운영에 있는가 (보안, 가장 급함)

```sql
SELECT id, email, name, created_at, is_audit
  FROM public.influencers
 WHERE is_audit = true
 ORDER BY created_at DESC;
```

**무엇을 볼 것**
- 운영팀이 만든 감사용 계정(이름이 `監査用` 계열) **외에 다른 행이 있으면 그건 사고다.**
- 있으면 그 회원의 응모·결과물이 집계에서 빠져 있고, 「감사용 흔적 청소」를 누르면 **진짜 데이터가 지워진다.** 조치 전에 그 행부터 되돌려야 한다.
- **0건 또는 알려진 계정뿐이면** → 잠금(트리거 추가)만 하면 되고 소급 정리는 불필요.

---

## M2 — 탈퇴 확정자의 응모 표에 개인정보가 남아 있는가

```sql
SELECT count(*) AS 남은_응모,
       count(*) FILTER (WHERE a.user_email IS NOT NULL) AS 이메일,
       count(*) FILTER (WHERE a.user_name  IS NOT NULL) AS 이름,
       count(*) FILTER (WHERE a.address    IS NOT NULL) AS 주소
  FROM public.applications a
  JOIN public.withdrawal_requests w
    ON w.influencer_id = a.user_id AND w.status = 'done';
```

**무엇을 볼 것**
- **현재 0건이 정상이다** — 확정된 탈퇴가 아직 없다(`CLAUDE.md` 기준). 0이 나오면 「지금 피해 없음 + 시행 시 발생」이 확정된다.
- 0이 아니면 이미 방침 위반 상태이므로 우선순위가 올라간다.

⚠️ **0건이라고 조치를 미루면 안 된다** — 시행하는 순간 발생하고, 그때는 이미 화면에 실명이 떠 있다.

---

## M3 — 보류 해제 뒤 송금 기록이 남은 정산 행이 있는가 (돈)

```sql
-- ① 상태와 송금 기록이 어긋난 행
SELECT id, status, amount_jpy, paid_amount_jpy, paid_at, paid_by, memo
  FROM public.settlements
 WHERE status <> 'paid'
   AND (paid_at IS NOT NULL OR paid_amount_jpy IS NOT NULL OR paid_by IS NOT NULL);

-- ② 실제로 그 경로를 지난 행 (송금완료 → 보류 → 해제)
SELECT settlement_id, string_agg(action, '→' ORDER BY at) AS 경로
  FROM public.settlement_events
 GROUP BY 1
HAVING string_agg(action, '→' ORDER BY at) LIKE '%pay%hold%revert%';
```

**무엇을 볼 것**
- ①이 0건이면 **아직 아무도 그 경로를 안 지났다** → 잠복. 고치는 것은 여전히 필요하다(버튼 두 번이면 도달).
- ①에 행이 있으면 **그 행의 `paid_amount_jpy` 가 지금 지급 준비 화면의 소계에 들어가 있다.** 조치 전에 그 금액부터 확인해야 한다.

---

## M4 — 「보수 지급」 메일이 나가는데 지급은 없는 캠페인이 얼마나 되나 (돈)

```sql
SELECT c.recruit_type,
       count(*) FILTER (WHERE c.recruit_type <> 'monitor' AND COALESCE(c.reward,0)        <= 0) AS 무보수_시딩방문,
       count(*) FILTER (WHERE c.recruit_type =  'monitor' AND COALESCE(c.product_price,0) <= 0) AS 금액없는_리뷰어,
       count(*) AS 전체_승인응모
  FROM public.applications a
  JOIN public.campaigns c ON c.id = a.campaign_id
 WHERE a.status = 'approved'
 GROUP BY 1;
```

**무엇을 볼 것**
- 메모리에 「시딩 인증성공 300건 중 261건」이라는 **옛 실측**이 있다. 재확인 대상이다.
- 🔴 **두 칸을 합치지 마라 — 성격이 다르다.**
  - **첫째 칸(무보수 시딩·방문형)** = 후보에서 **통째로 제외**돼 미등록 목록에도 안 뜬다. 운영팀이 **찾을 수조차 없다.** 이 수가 **B-3(메일이 헛되이 나가는 규모)**이다.
  - **둘째 칸(금액 없는 리뷰어형)** = `amount_issue` 로 걸려 **미등록 목록에는 뜬다.** 지급이 막히는 건 같지만 **보이기는 한다** — 이쪽은 **D-4(문구 어긋남)** 몫이다.

---

## M5 — 리뷰어형인데 제품 금액이 0인 캠페인 (돈·문구)

```sql
SELECT id, campaign_no, title, reward, product_price, status
  FROM public.campaigns
 WHERE recruit_type = 'monitor'
   AND COALESCE(product_price,0) <= 0
   AND deleted_at IS NULL
 ORDER BY created_at DESC;
```

**무엇을 볼 것**
- 이 캠페인들은 화면·홍보 메일·관리자 미리보기가 **서로 다른 문구**를 보여주고, 미리보기만 지급되지 않는 현금액을 덧붙인다.
- **0건이면 §4-9는 잠복**이다.

---

## M6 — 홍보 메일 대상 모수가 **1,200**을 넘는가 (메일)

```sql
-- ① 사거리 안인가
SELECT count(*) AS 홍보_대상_모수
  FROM public.influencers i
 WHERE i.marketing_opt_in
   AND i.marketing_unsubscribed_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM public.withdrawal_requests w
                    WHERE w.influencer_id = i.id
                      AND w.status IN ('pending_payout','scheduled','done'));

-- ② 이미 일어났는가
SELECT digest_date, status, target_influencer_count, sent_count, error_message
  FROM public.campaign_promo_digest_runs
 WHERE error_message LIKE '%정체%'
 ORDER BY digest_date DESC;
```

**무엇을 볼 것**
- ①이 **1,200 미만이면 §4-2는 아직 사거리 밖**이다(1라운드 200 + 1,000 상한).
- ②에 행이 있으면 **이미 일어났고**, 그 run 의 기록된 원인은 **진짜 원인과 다르다**(운영자가 엉뚱한 곳을 봤다는 뜻).

---

## M7 — 사슬이 나무가 됐거나 반쪽만 회수된 발송이 있는가 (메일)

```sql
SELECT parent_broadcast_id,
       count(*)                                    AS 자식수,
       count(*) FILTER (WHERE withdrawn_at IS NULL) AS 살아있는_자식수
  FROM public.application_message_broadcasts
 WHERE parent_broadcast_id IS NOT NULL
 GROUP BY 1
HAVING count(*) > 1;
```

**무엇을 볼 것**
- 행이 있으면 **한 부모에 형제가 둘 이상** = 서버가 금지한 「나무」가 실제로 만들어졌다(§4-8).
- 「자식수 > 살아있는 자식수」인 행은 **회수가 사슬을 안 따라간 흔적**(§4-3)이다.
- 후속 발송을 쓴 적이 없으면 0건이 정상.

---

## M8 — 글자 `x` 가 든 채널 코드가 있는가 (메일)

```sql
SELECT code, name_ko, name_ja, active
  FROM public.lookup_values
 WHERE kind = 'channel'
   AND code LIKE '%x%'
   AND code <> 'x';
```

**무엇을 볼 것**
- 행이 있으면 **그 채널만 쓰는 캠페인이 X(트위터) 보유자 전원에게 홍보 메일 문지기를 연다**(§4-7).
- 자동 생성 코드가 글자 x 를 포함할 확률은 **15.3%**(20만 회 시행 실측). 영문 이름이면 이름이 곧 코드다.
- **0건이면 잠복** — 다음에 채널을 추가할 때 걸린다.

---

## M9 — 「또는」 캠페인에서 메일은 가는데 응모가 막히는 사람 (메일·응모)

```sql
SELECT c.id, c.campaign_no, c.channel, c.channel_match, count(*) AS 막히는_회원수
  FROM public.campaigns c
  JOIN public.influencers i
    ON i.marketing_opt_in AND i.marketing_unsubscribed_at IS NULL
 WHERE c.status = 'active' AND c.deleted_at IS NULL
   AND COALESCE(c.is_invite_only,false) = false
   AND c.recruit_type <> 'monitor'
   AND array_length(string_to_array(c.channel, ','),1) > 1
   -- 하나라도 갖고 있어 문지기를 통과하고
   AND ( (c.channel LIKE '%instagram%' AND COALESCE(i.ig,'')     <> '')
      OR (c.channel LIKE '%tiktok%'    AND COALESCE(i.tiktok,'') <> '')
      OR (c.channel LIKE '%x%'         AND COALESCE(i.x,'')      <> '')
      OR (c.channel LIKE '%youtube%'   AND COALESCE(i.youtube,'')<> '') )
   -- 그런데 하나라도 없어 계정 관문에서 막힌다
   AND ( (c.channel LIKE '%instagram%' AND COALESCE(i.ig,'')      = '')
      OR (c.channel LIKE '%tiktok%'    AND COALESCE(i.tiktok,'')  = '')
      OR (c.channel LIKE '%x%'         AND COALESCE(i.x,'')       = '')
      OR (c.channel LIKE '%youtube%'   AND COALESCE(i.youtube,'') = '')
      OR (c.channel LIKE '%qoo10%'     AND COALESCE(i.ig,'')      = '') )
 GROUP BY 1,2,3,4
 ORDER BY 5 DESC;
```

**무엇을 볼 것**
- 이 수가 곧 **「메일 받고 눌렀는데 차단당하는 사람」**이다(§4-1).
- ⚠️ **이 결과가 기획 결정을 가른다** — 수가 크면 「계정도 하나면 된다」로 푸는 쪽, 작으면 「화면 문구를 바로잡는」 쪽이 맞다.
- ⚠️ **위쪽 조건(문지기 통과)의 `LIKE '%x%'` 는 일부러 현재 동작을 그대로 재현한 것**이다 — M8 이 결함으로 지목한 그 패턴이고, 지금 실제로 그렇게 돌기 때문이다. **아래쪽 조건(계정 관문)은 정확 일치가 맞다** — 그쪽은 화면 코드가 채널 목록을 정확히 비교한다. 즉 이 수에는 **문지기 오탐이 일부러 섞여 있고**, M8 이 0건이면 오차도 0이다.

---

## M10 — 캠페인 하나에 결과물이 몇 건까지 쌓이나 (파기 청킹)

```sql
-- ① 한 캠페인당 최대 (× 2 가 실제 지울 경로 수)
SELECT campaign_id, count(*) AS 결과물수
  FROM public.deliverables
 WHERE receipt_url IS NOT NULL
 GROUP BY 1 ORDER BY 2 DESC LIMIT 5;

-- ② 감사용 계정 결과물 총 건수 (전체 청소가 한꺼번에 모으는 양)
SELECT count(*) AS 감사용_결과물
  FROM public.deliverables d
  JOIN public.influencers i ON i.id = d.user_id
 WHERE i.is_audit AND d.receipt_url IS NOT NULL;
```

**무엇을 볼 것**
- ①의 최댓값 × 2 가 **한 번에 보내는 경로 수**다. 이것이 저장소 상한에 닿는지가 §7-1의 위험 크기를 정한다.
- ⚠️ **상한 자체는 조회로 안 나온다** — 개발서버에서 800개 배열로 한 번 태워 봐야 확정된다.

---

## M11 — 모집 형식이 세 값 밖인 캠페인이 있는가

```sql
SELECT COALESCE(recruit_type,'(NULL)') AS 형식, count(*)
  FROM public.campaigns
 GROUP BY 1 ORDER BY 2 DESC;
```

**무엇을 볼 것**
- `monitor`·`gifting`·`visit` **외의 값이나 NULL 이 0건이면 §2-6은 문제 없음**이다(CHECK 제약이 없을 뿐).
- 있으면 서버는 인증 성공으로 보고 화면은 안 보므로, **관리자가 아직 안 끝난 줄 알면서 돈이 나간다.**

---

## M12 — 대소문자 때문에 어긋난 관리자 계정이 있는가

```sql
-- ① 대문자가 섞인 관리자 행
SELECT id, email, auth_id, role, invite_mail_sent_at, invite_completed_at
  FROM public.admins WHERE email <> lower(email);

-- ② admins 가 가리키는 계정과 이메일이 다른 경우(고아)
SELECT a.email AS admins_email, u.email AS auth_email, a.role, a.created_at
  FROM public.admins a LEFT JOIN auth.users u ON u.id = a.auth_id
 WHERE u.id IS NULL OR lower(u.email) <> lower(a.email);

-- ③ 같은 주소가 auth.users 에 두 벌
SELECT lower(email) AS 주소, count(*) FROM auth.users GROUP BY 1 HAVING count(*) > 1;
```

**무엇을 볼 것**
- ①②③ 어디든 행이 있으면 **로그인 안 되는 관리자**가 이미 있다는 뜻이다(§9-3).
- ②에 행이 있으면 그 사람의 **비밀번호 설정 링크가 인플루언서 계정을 건드렸을** 수 있다.

---

## M13 — 함수 실행 권한의 실제 상태 (개발·운영 각각)

```sql
SELECT p.proname,
       p.proacl::text AS 권한목록,
       has_function_privilege('anon',          p.oid, 'EXECUTE') AS 비로그인,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS 로그인
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('get_event_roster','is_settlement_public','is_withdrawal_open',
                     'calc_age_kst','is_email_withdrawal_blocked');
```

**무엇을 볼 것**
- 🔴 **`has_function_privilege` 만 보면 방향을 모른다** — `proacl::text` 의 **맨 앞 `=X/`** 가 있으면 PUBLIC 부여, `anon` 이 따로 적혀 있으면 개별 부여다. 회수는 두 방향을 **각각** 해야 한다([[feedback_function_execute_grants]]).
- ⚠️ **개발과 운영이 다른 전례가 있다.** 반드시 양쪽에서 각각 돌린다.
- ⚠️ **다섯 중 둘은 I-3 대상이 아니다** — `get_event_roster` 는 **A-2 몫**이고, `is_email_withdrawal_blocked` 는 **비로그인에 일부러 연 것**(회원가입 화면이 로그인 전에 부른다)이라 닫으면 안 된다. 남는 셋이 I-3 이다.

---

## M14 — 1,000행 상한에 닿는 날이 있는가 (메일 다이제스트)

```sql
SELECT date_trunc('day', created_at) AS 날, count(*)
  FROM public.applications GROUP BY 1 ORDER BY 2 DESC LIMIT 5;

SELECT date_trunc('day', reviewed_at) AS 날, count(*)
  FROM public.applications
 WHERE status IN ('approved','rejected') GROUP BY 1 ORDER BY 2 DESC LIMIT 5;

SELECT campaign_id, count(*) FROM public.deliverables
 WHERE status <> 'draft' GROUP BY 1 HAVING count(*) > 900 ORDER BY 2 DESC;
```

**무엇을 볼 것**
- 하루 최대가 1,000 근처면 §4-11(8곳)이 **이미 발현 중**이다. 훨씬 아래면 잠복.
- 세 번째 조회는 §2-7(진행현황 진행바)의 사거리다.

---

## M15 — 방침 통지가 「보냈다」로만 남은 회원이 있는가 (D-9)

```sql
SELECT notice_key,
       count(*)                                   AS 전체,
       count(*) FILTER (WHERE status = 'sent')    AS 보냄,
       count(*) FILTER (WHERE status = 'failed')  AS 실패,
       min(created_at) AS 처음, max(created_at) AS 마지막
  FROM public.policy_notice_runs
 GROUP BY 1 ORDER BY 5 DESC;
```

**무엇을 볼 것**
- 이 함수는 **「보냈다」로 먼저 기록하고 그다음 발송**한다. 중간에 죽으면 실패 정정에 도달하지 못해 **영구 미발송이 「발송 완료」로** 남는다(§4-10).
- 🔴 **행 자체가 0건이면 이 함수는 아직 한 번도 안 쓰였다** — D-9 는 잠복이고, A-1 을 고치는 김에 순서만 바로잡으면 된다.
- `notice_key` 가 여럿이면 **누가 어떤 값으로 불렀는지**를 함께 본다(A-1 의 자물쇠가 본문 값으로 열린다는 뜻이다).

⚠️ **이건 읽기 전용 조회이고 허용된다.** 금지되는 것은 **그 함수를 호출하는 것**이다(맨 위 참조).

## 브라우저로만 확인 가능한 것 (SQL 편집기 불가)

| 항목 | 방법 |
|---|---|
| §1-3 감사용 칸 잠금이 실제로 막는가 | **실제 로그인 세션**으로 본인 행 수정을 시도. 편집기는 정책을 우회한다(2026-08-07 묶음 A 선례) |
| §5-1 안전 게이트가 조회 실패 때 열리는가 | 개발서버에서 그 조회를 강제로 실패시키고 라디오 잠금이 풀리는지 |
| §5-2 지급 준비 처리 후 건수가 안 줄어드는가 | 개발서버에서 한 건 처리 후 「미등록」 탭 숫자 관찰 |
| §7-1 저장소 `remove()` 의 실제 상한 | 개발서버에서 800개 배열을 한 번 태워 본다 |
| §6-2 운영 공개 문서 | 이미 확인됨 — `curl -sL` 로 HTTP 200(양성 대조 404 통과) |
