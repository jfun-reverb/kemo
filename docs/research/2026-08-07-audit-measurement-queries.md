# 실측·검증 조회 모음 — 전수조사 후속

**조사 결과:** `docs/research/2026-08-07-codebase-audit-findings.md`
**조치 계획:** `docs/specs/2026-08-07-audit-remediation-plan.md` (실측 번호 M1~M8은 그쪽 표와 같다)

⚠️ **대상은 운영 데이터베이스**(`nrwtujmlbktxjgdwlpjj`). 개발 데이터베이스에는 운영 복제본이 섞여 있어 근거가 되지 않는다.
⚠️ **전부 읽기 전용이다.** 데이터를 바꾸는 문장은 하나도 없다.

---

## M1 — 홍보 메일 예약이 어느 서버를 가리키는가 (가장 급함)

운영 SQL 편집기에서:

```sql
SELECT jobid, jobname, schedule, active, command
  FROM cron.job
 ORDER BY jobname;
```

**무엇을 볼 것**
- `campaign-promo-*` 이름의 줄에서 `command` 안의 주소를 본다.
- **`qysmxtipobomefudyixw`(개발) 또는 옛 시드니 주소**가 나오면 → 홍보 메일이 그쪽으로 갔다는 뜻이고, **도쿄 이전 이후 한 통도 안 나갔을 수 있다.**
- 현재 운영 주소(`nrwtujmlbktxjgdwlpjj`)면 정상.
- `active` 가 `false` 인 줄도 함께 확인한다.

**이어서 실제 발송 이력 확인**

```sql
SELECT digest_date, status, started_at, finished_at,
       sent_count, skipped_count, error_message
  FROM campaign_promo_digest_runs
 ORDER BY digest_date DESC
 LIMIT 20;
```

- 최근 줄의 날짜가 **월·목 간격으로 이어지는지**. 끊긴 구간이 있으면 그 시점부터 안 나간 것이다.
- 도쿄 이관일(2026-05-27) 전후로 끊겼는지가 핵심.

---

## M2 — 영수증 사진이 로그인 없이 실제로 열리는가

**SQL이 아니라 브라우저에서 확인한다.** 로그인하지 않은 창(시크릿 창)에서 개발자 도구 콘솔을 열고:

```js
const r = await fetch(
  'https://nrwtujmlbktxjgdwlpjj.supabase.co/storage/v1/object/list/campaign-images',
  { method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: '<운영 공개 키>' },
    body: JSON.stringify({ prefix: 'receipts', limit: 5 }) }
);
console.log(r.status, (await r.json()));
```

- 운영 공개 키는 `dev/lib/supabase.js` 의 `SUPABASE_ENVS` 에 있다(공개 전제라 노출해도 되는 값이다).
- **파일 목록이 돌아오면 노출이 성립한다.** 건수를 기록해 둔다(전환 후 대조용).
- 목록에 나온 이름 하나로 `https://…/storage/v1/object/public/campaign-images/receipts/<이름>` 을 열어 **실제 사진이 보이는지**까지 확인한다.

**규모 파악(참고)**

```sql
SELECT count(*) AS 영수증_행수,
       count(*) FILTER (WHERE receipt_url IS NOT NULL) AS 사진_있는_행수
  FROM deliverables
 WHERE kind = 'receipt';
```

---

## M3 — 관리자가 자기 등급을 올릴 수 있는가

**두 번 돈다** — 묶음 A 착수 전 1회, A-1 적용 후 1회. **같은 방법으로** 해야 대조가 된다.

**① 먼저 현재 정책을 눈으로 확인**

```sql
SELECT polname, polcmd,
       pg_get_expr(polqual,     polrelid) AS using_식,
       pg_get_expr(polwithcheck, polrelid) AS with_check_식
  FROM pg_policy
 WHERE polrelid = 'public.admins'::regclass
 ORDER BY polname;
```

- `admins_update` 줄의 **`with_check_식` 이 비어 있으면** 조사 결과대로다.
- 비어 있지 않으면 운영에 문서화되지 않은 장치가 붙어 있는 것이니 **그 내용을 먼저 확인**한다.

**② 실제로 되는지 확인 (가장 낮은 등급 계정으로)**

캠페인매니저 등급 계정으로 관리자 화면에 로그인한 뒤 콘솔에서:

```js
const me = (await db.auth.getUser()).data.user;
const r = await db.from('admins').update({ role: 'super_admin' }).eq('auth_id', me.id).select();
console.log(r);
```

- **성공하면 즉시 되돌린다** — 최고 관리자 계정으로 그 사람 등급을 원래대로 바꾼다.
- ⚠️ 테스트용 계정으로 하고, 끝나면 반드시 원복을 확인한다.
- A-1 적용 후 같은 것을 돌려 **거부되는지** 본다.

---

## M4 — 가구매 캠페인 수

```sql
SELECT count(*) AS 가구매_캠페인수,
       count(*) FILTER (WHERE deleted_at IS NULL) AS 살아있는것
  FROM campaigns
 WHERE proxy_purchase = true;
```

이어서 영향받는 응모 수:

```sql
SELECT c.id, c.campaign_no, c.title,
       count(a.id) AS 승인응모수
  FROM campaigns c
  LEFT JOIN applications a ON a.campaign_id = c.id AND a.status = 'approved'
 WHERE c.proxy_purchase = true AND c.deleted_at IS NULL
 GROUP BY c.id, c.campaign_no, c.title
 ORDER BY 승인응모수 DESC;
```

---

## M5 — 영수증이 여러 행 쌓인 응모 + 두 정렬이 갈리는가

```sql
WITH multi AS (
  SELECT application_id
    FROM deliverables
   WHERE kind = 'receipt'
   GROUP BY application_id
  HAVING count(*) > 1
),
by_submitted AS (
  SELECT DISTINCT ON (d.application_id)
         d.application_id, d.id AS 제출시각기준_행
    FROM deliverables d JOIN multi m ON m.application_id = d.application_id
   WHERE d.kind = 'receipt'
   ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
),
by_updated AS (
  SELECT DISTINCT ON (d.application_id)
         d.application_id, d.id AS 수정시각기준_행
    FROM deliverables d JOIN multi m ON m.application_id = d.application_id
   WHERE d.kind = 'receipt'
   ORDER BY d.application_id, d.updated_at DESC, d.submitted_at DESC
)
SELECT s.application_id, s.제출시각기준_행, u.수정시각기준_행
  FROM by_submitted s JOIN by_updated u USING (application_id)
 WHERE s.제출시각기준_행 <> u.수정시각기준_행;
```

- **0행이면** 화면과 엑셀이 지금은 같은 답을 낸다(정의 차이는 그대로 남아 있으니 고칠 값어치는 있다).
- **1행 이상이면** 그 응모들에서 엑셀이 다른 영수증을 보여주고 있다.

---

## M6 — 게시물 채널에 대소문자·공백이 섞인 값이 있는가

```sql
SELECT post_channel, count(*) AS 건수
  FROM deliverables
 WHERE post_channel IS NOT NULL
   AND post_channel <> lower(btrim(post_channel))
 GROUP BY post_channel
 ORDER BY 건수 DESC;
```

- **0행이면** 채널 비교 규칙을 어느 쪽으로 통일해도 지금 데이터에는 영향이 없다 → Q1 결정이 쉬워진다.
- **1행 이상이면** 그 값들이 지금 **판정에서는 어긋난 것으로 취급되면서 감지 장치는 통과**시키고 있다. 인증 성공·정산에 영향이 있으므로 건별로 확인한다.

---

## M7 — 취소 알림이 실제로 생성된 적 있는가

```sql
SELECT kind, ref_table, count(*) AS 건수,
       min(created_at) AS 최초, max(created_at) AS 최근
  FROM notifications
 WHERE kind = 'application_cancelled'
 GROUP BY kind, ref_table;
```

- `ref_table = 'applications'` 줄이 **없거나 건수가 0이면**, 일반 응모 취소 알림이 도입 이래 한 번도 안 만들어진 것이다(행사 예약 취소는 `event_tickets` 로 잡힌다).

정책 확인도 함께:

```sql
SELECT polname, polcmd FROM pg_policy
 WHERE polrelid = 'public.notifications'::regclass ORDER BY polname;
```

- `INSERT` 정책이 없으면 조사 결과대로다(브라우저에서 넣는 알림이 전부 실패).

---

## M8 — 채널이 빈 시딩·방문형 캠페인

```sql
SELECT id, campaign_no, title, recruit_type, status,
       submission_end,
       (submission_end IS NOT NULL AND submission_end < (now() AT TIME ZONE 'Asia/Tokyo')::date) AS 제출마감지남
  FROM campaigns
 WHERE recruit_type IN ('gifting', 'visit')
   AND COALESCE(btrim(channel), '') = ''
   AND deleted_at IS NULL
 ORDER BY submission_end DESC NULLS LAST;
```

- `제출마감지남` 이 `true` 인 줄이 **지금 이 순간 폼이 열려 있는데 서버는 거부하는** 캠페인이다.
- 건수를 보고 Q5(정리할지)를 판단한다.

---

## 결과 기록

확인이 끝나면 조치 계획서(`docs/specs/2026-08-07-audit-remediation-plan.md`)의 §실측·검증 조회 표 옆에 숫자를 적어 둔다. 특히 **M1·M2·M3은 조치 우선순위를 바꿀 수 있는** 항목이다.

---

# ★ 실측 결과 (2026-08-07, 운영 데이터베이스)

**여덟 개를 전부 돌렸다. 절반이 「해당 없음」으로 나와 조치 범위가 크게 줄었다.**

| # | 결과 | 계획에 미치는 영향 |
|---|---|---|
| **M1** | ✅ **정상 — 우려는 사실이 아니었다.** 예약이 **현재 운영 주소**(`nrwtujmlbktxjgdwlpjj`)를 가리키고 `active=true`. 일정도 정상(월·목 KST 09시). 발송 이력도 2026-06-01~08-06 **끊김 없이** 이어지고, 보낼 캠페인이 있던 날(6/18·7/16·8/6)에 각각 8·9·10통 나갔다. 나머지는 「새 캠페인 없음」으로 건너뛴 정상 동작 | **C-1 해소.** C-2·C-3·C-4는 그대로 유효하되 **긴급도는 낮다** |
| **M2** | ❌ **노출 성립.** 로그인 없이 목록 조회 성공(200) · 영수증 **1,000건 이상**(조회 상한) · 리뷰 인증샷 87건 · 실제 사진 열림 확인 | **묶음 B는 🛑 보류**(브랜드사가 이 링크를 업무에 쓰는 중). 목록 조회 차단만 별도 가능 |
| **M3** | ❌ **결함 확정.** `admins_update` 의 `using` 은 「최고 관리자 **또는** 본인 행」인데 **`with_check` 가 비어 있다**. 즉 본인 행을 수정할 수 있고 **수정 후 값을 아무도 검사하지 않는다** → 가장 낮은 등급이 자기 등급을 최고 관리자로 바꿀 수 있다. 문서에 없는 다른 장치도 없음 | **묶음 A 그대로 필요.** ②(실제 시도)는 A-1 적용 후 대조용으로 남긴다 |
| **M4** | ✅ **가구매 캠페인 0건** | **G-1·G-2 영향 범위 0.** 고칠 값어치는 남지만(앞으로 생길 수 있다) 급하지 않다 |
| **M5** | ⚠️ **36건 발현 중.** 영수증 812행 중 여러 행 쌓인 응모 65건, 그중 **두 정렬이 갈리는 응모 36건** | **G-3 실제 발현.** 엑셀이 화면·정산과 **다른 영수증**을 보여주는 중 — G 묶음에서 가장 실질적 |
| **M6** | ✅ **이상값 0건.** 게시물 1,066행 전부 소문자·공백 없음 | **Q1 결정 불필요.** 어느 쪽으로 통일해도 지금 데이터에 영향 없다 |
| **M7** | ❌→✅ **도입 이래 0건이었고, 같은 날 고쳤다.** 마이그레이션 309(`cancel_application` 안에서 알림 생성)를 운영 배포한 뒤 **첫 알림이 실제로 생성**됐다(2026-08-07 07:24, 「応募を取り消しました — メラドロップ…」) | **F-3 대상에 취소 알림 포함.** 원인(브라우저 직접 저장)은 이미 제거됨 |
| **M8** | ✅ **채널이 빈 시딩·방문형 캠페인 0건** | **I-16 영향 범위 0. Q5 결정 불필요** |

## 이 결과가 계획을 바꾸는 지점

1. **사용자 확인 5개 중 2개가 자동 해소** — Q1(M6 0건)·Q5(M8 0건)
2. **묶음 C의 긴급도 하향** — 홍보 메일은 정상 발송 중이었다
3. **묶음 B는 보류** — 기술 문제가 아니라 **운영 전제**(브랜드사 사용 중) 때문. 계획서 묶음 B 머리말 참조
4. **묶음 G는 M5(36건) 하나로 좁혀진다** — G-1·G-2는 대상이 0건
5. **묶음 A는 그대로 최우선** — 정책에 검사가 없는 것이 실측으로 확정

⚠️ **M2·M5는 대조용 기준값이다.** 조치 후 같은 조회를 다시 돌려 대조한다.
