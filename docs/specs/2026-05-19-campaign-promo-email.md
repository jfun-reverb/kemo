# 신규 캠페인 홍보 메일 — 일일 다이제스트

**작성일:** 2026-05-19
**상태:** 사양 확정 (개발 세션에 인계 대기)
**관련:** 신규 기능 (Edge Function + DB 마이그레이션 + 인플 페이지 + 마이페이지)
**참조:** `docs/specs/2026-05-18-mail-pipeline-consolidation.md` (메일 인프라 패턴), `docs/specs/2026-05-18-application-email-pipeline.md` (인플루언서 다이제스트 패턴)

---

## 1. 배경 및 동기

브랜드가 새 캠페인을 등록·노출해도, 가입된 인플루언서는 직접 캠페인 목록 페이지에 방문해야 새 캠페인을 발견할 수 있다. 결과적으로 모집 초기 신청률이 낮고 「슬롯 마감일까지 가까스로 채우는」 운영 부담이 발생.

**해결**: 어제 KST 0~24시 사이에 모집중(active) 상태로 새로 노출된 캠페인을 매일 아침 9시에 인플루언서에게 한 통의 다이제스트 메일로 안내. 인플별로 자격 매칭(채널·팔로워)된 캠페인만 묶여 발송되어 「내가 응모 가능한 신규 캠페인」 만 받음.

---

## 2. 핵심 결정 (사용자 확정 — 2026-05-19)

| 결정 항목 | 선택 | 비고 |
|---|---|---|
| 타겟팅 | **채널 + 최소 팔로워 매칭** | 리뷰어(monitor) 캠페인은 팔로워 무관 (FEATURE_SPEC §10 동일 정책) |
| 발송 트리거 | **주 2회 (월·목) 09:00 KST** | 일일 발송은 스팸 인식 위험 — 사용자 정정 §17 |
| 발송 단위 | **인플당 주 2통 (월·목)** | 한 메일에 신규 + 마감 임박 두 섹션 |
| 같은 캠페인 노출 한도 | **인플당 캠페인당 최대 2회** | 신규 1회 + D-1 임박 1회. **CTA 클릭 시 그 캠페인 자동 제외** (다음 다이제스트부터) |
| 수신거부 | **토큰 1-click** | `unsubscribe_token` UUID 영구 토큰, 익명 호출 가능 RPC |
| 응모 status별 처리 | rejected/pending/approved 제외, cancelled만 포함 | §16-2 |

---

## 3. 데이터 모델

### 3-1. 신규 테이블

#### `campaign_promo_digest_runs` (일자별 발송 run 로그 — mutex 역할)

```sql
CREATE TABLE public.campaign_promo_digest_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  digest_date date NOT NULL UNIQUE,          -- mutex: 동일 일자 중복 호출 차단
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz NULL,
  status text NOT NULL CHECK (status IN ('sent','skipped_no_data','failed','partial')),
  included_campaign_ids uuid[] NOT NULL DEFAULT '{}',
  target_influencer_count integer NOT NULL DEFAULT 0,
  sent_count integer NOT NULL DEFAULT 0,
  skipped_count integer NOT NULL DEFAULT 0,
  failed_count integer NOT NULL DEFAULT 0,
  error_message text NULL,
  triggered_by uuid REFERENCES auth.users(id) ON DELETE SET NULL  -- 향후 수동 트리거 대비
);
```

- 행 단위 보안 정책(RLS): SELECT는 `is_admin()` 한정, INSERT/UPDATE/DELETE는 정책 없음 → Edge Function service_role만 우회
- 동시성: `digest_date` UNIQUE가 mutex (INSERT 선행 status='failed' → 23505 발생 시 중복 호출 차단, 패턴은 `admin_daily_digest_runs` 미러)

#### `campaign_promo_digest_sent` (인플별 발송 로그 — 멱등성·감사)

```sql
CREATE TABLE public.campaign_promo_digest_sent (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id uuid NOT NULL REFERENCES public.influencers(auth_id) ON DELETE CASCADE,
  digest_date date NOT NULL,
  sent_at timestamptz NOT NULL DEFAULT now(),
  status text NOT NULL CHECK (status IN ('sent','skipped','failed')),
  skip_reason text NULL,                     -- 'opt_out' / 'no_email' / 'no_matched_campaign'
  error_message text NULL,
  included_campaign_ids uuid[] NOT NULL DEFAULT '{}',
  UNIQUE (influencer_id, digest_date)        -- 인플당 일 1통 보장
);
CREATE INDEX ON public.campaign_promo_digest_sent (digest_date, status);
CREATE INDEX ON public.campaign_promo_digest_sent (influencer_id, sent_at DESC);
```

- 행 단위 보안 정책: SELECT `is_admin()` 한정, INSERT/UPDATE는 정책 없음 → service_role만

### 3-2. 기존 테이블 확장 — `influencers`

```sql
ALTER TABLE public.influencers
  ADD COLUMN unsubscribe_token uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  ADD COLUMN marketing_unsubscribed_at timestamptz NULL;
```

- `unsubscribe_token`: 가입 시 자동 생성, 인플 1명당 영구 1개 토큰
- `marketing_unsubscribed_at`: 수신거부 시각 감사 (재구독 시 NULL로 초기화)
- 기존 행 백필: DEFAULT가 적용되어 자동 채워짐
- 행 단위 보안 정책: 본인만 SELECT/UPDATE (기존 정책 유지)

### 3-3. 원격 호출 함수

#### `get_promo_digest_targets(p_digest_date date)` — 발송 대상자 조회

```sql
CREATE OR REPLACE FUNCTION public.get_promo_digest_targets(p_digest_date date)
RETURNS TABLE (
  influencer_id uuid,
  email text,
  name text,
  unsubscribe_token uuid,
  matched_campaign_ids uuid[]
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  -- 1. 어제 KST 0시~24시 안에 active 전환 또는 신규 등록된 캠페인
  WITH new_campaigns AS (
    SELECT id, primary_channel, channels, channel_match, recruit_type, min_followers, deadline
    FROM public.campaigns
    WHERE status = 'active'
      AND deadline >= current_date
      AND (
        -- KST 어제 0~24시 윈도우
        (created_at AT TIME ZONE 'Asia/Seoul')::date = p_digest_date
        OR (recruit_start AT TIME ZONE 'Asia/Seoul')::date = p_digest_date
      )
  ),
  -- 2. 옵트인 인플 + 채널·팔로워 매칭
  matches AS (
    SELECT
      i.auth_id AS influencer_id,
      i.unsubscribe_token,
      i.name_kanji,
      i.name_kana,
      i.name,
      array_agg(c.id) AS matched_campaign_ids
    FROM public.influencers i
    CROSS JOIN new_campaigns c
    WHERE i.marketing_opt_in = true
      AND i.marketing_unsubscribed_at IS NULL
      -- 채널 매칭 (캠페인 channels CSV에 인플 등록 채널 포함)
      AND (
        (c.channels LIKE '%instagram%' AND i.ig IS NOT NULL AND i.ig <> '')
        OR (c.channels LIKE '%tiktok%' AND i.tiktok IS NOT NULL AND i.tiktok <> '')
        OR (c.channels LIKE '%x%' AND i.x IS NOT NULL AND i.x <> '')
        OR (c.channels LIKE '%youtube%' AND i.youtube IS NOT NULL AND i.youtube <> '')
      )
      -- 팔로워 매칭 (monitor 캠페인은 스킵)
      AND (
        c.recruit_type = 'monitor'
        OR public._meets_min_followers(i, c)  -- 헬퍼: primary_channel 기준 팔로워 비교
      )
    GROUP BY i.auth_id, i.unsubscribe_token, i.name_kanji, i.name_kana, i.name
  )
  -- 3. 이미 오늘 발송된 인플은 제외 (cron 재호출 안전)
  SELECT
    m.influencer_id,
    (SELECT email FROM auth.users WHERE id = m.influencer_id) AS email,
    COALESCE(NULLIF(TRIM(m.name_kanji), ''), NULLIF(TRIM(m.name), ''), NULLIF(TRIM(m.name_kana), ''), '') AS name,
    m.unsubscribe_token,
    m.matched_campaign_ids
  FROM matches m
  LEFT JOIN public.campaign_promo_digest_sent s
    ON s.influencer_id = m.influencer_id AND s.digest_date = p_digest_date
  WHERE s.id IS NULL;  -- 미발송자만
$$;

GRANT EXECUTE ON FUNCTION public.get_promo_digest_targets(date) TO authenticated;
```

- `_meets_min_followers` 헬퍼: primary_channel 기준 팔로워 수가 `min_followers` 이상인지 검증 (FEATURE_SPEC §10 정책)
- service_role 우회로 호출 (Edge Function)

#### `mark_promo_digest_sent(...)` — 인플별 발송 결과 INSERT (멱등)

```sql
CREATE OR REPLACE FUNCTION public.mark_promo_digest_sent(
  p_influencer_id uuid,
  p_digest_date date,
  p_status text,
  p_skip_reason text DEFAULT NULL,
  p_error_message text DEFAULT NULL,
  p_included_campaign_ids uuid[] DEFAULT '{}'
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  INSERT INTO public.campaign_promo_digest_sent
    (influencer_id, digest_date, status, skip_reason, error_message, included_campaign_ids)
  VALUES
    (p_influencer_id, p_digest_date, p_status, p_skip_reason, p_error_message, p_included_campaign_ids)
  ON CONFLICT (influencer_id, digest_date) DO NOTHING;
$$;
```

#### `unsubscribe_by_token(p_token uuid)` — 익명 수신거부

```sql
CREATE OR REPLACE FUNCTION public.unsubscribe_by_token(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_influencer record;
BEGIN
  SELECT auth_id, name_kanji, name FROM public.influencers
    WHERE unsubscribe_token = p_token
    INTO v_influencer;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  UPDATE public.influencers
    SET marketing_opt_in = false,
        marketing_unsubscribed_at = now()
    WHERE auth_id = v_influencer.auth_id;

  RETURN jsonb_build_object(
    'success', true,
    'name', COALESCE(NULLIF(TRIM(v_influencer.name_kanji), ''), v_influencer.name, '')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.unsubscribe_by_token(uuid) TO anon, authenticated;
```

- 익명 anon GRANT: 메일 클릭만으로 호출 (로그인 불요)
- 토큰 미매칭은 「잘못된 링크」 안내 → 보안상 무차별 대입 방지 (UUID v4 = 122 bit 엔트로피)
- 재구독은 마이페이지 토글에서 (별도 라우트 없음)

#### `resubscribe_marketing(p_user_id uuid)` — 마이페이지 재구독

```sql
-- 본인만 호출 가능 (auth.uid() 검증)
CREATE OR REPLACE FUNCTION public.resubscribe_marketing()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.influencers
    SET marketing_opt_in = true,
        marketing_unsubscribed_at = NULL,
        marketing_agreed_at = now()  -- 동의 시점 갱신 (특상법 「동의 근거 기록」 의무)
    WHERE auth_id = auth.uid();
$$;

GRANT EXECUTE ON FUNCTION public.resubscribe_marketing() TO authenticated;
```

### 3-4. pg_cron 등록

```sql
SELECT cron.schedule(
  'campaign-promo-digest-daily',
  '0 0 * * *',  -- UTC 00:00 = KST 09:00
  $$
  SELECT net.http_post(
    url := current_setting('app.supabase_url') || '/functions/v1/notify-campaign-promo-digest',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || current_setting('app.supabase_service_role_key')
    ),
    body := jsonb_build_object('source', 'cron')
  );
  $$
);
```

- `admin_daily_digest_runs` cron 패턴 미러
- 운영·개발 DB 양쪽 등록

---

## 4. Edge Function: `notify-campaign-promo-digest`

### 4-1. 입력·출력

- 입력: POST `{ source: 'cron' | 'manual' }` (manual은 향후 운영자 수동 트리거용)
- 출력: `{ ok, digest_date, target_count, sent, skipped, failed, included_campaign_count }`

### 4-2. 처리 흐름

```
1. computeDigestDate() — 어제 KST 0~24시 윈도우 → p_digest_date 결정
2. INSERT campaign_promo_digest_runs (digest_date, status='failed', error_message='in-flight')
   → 23505 발생 시 즉시 종료 (중복 호출 차단)
3. SELECT get_promo_digest_targets(p_digest_date)
   → [{influencer_id, email, name, unsubscribe_token, matched_campaign_ids}]
4. 신규 캠페인 정보 일괄 조회 (matched_campaign_ids 합집합)
   → campaignMap: id → {campaign_no, title, brand_ko, img1, deadline, slots, reward, reward_note, recruit_type}
5. 대상자 0명 또는 신규 캠페인 0건이면 status='skipped_no_data' UPDATE 후 종료
6. 대상자 루프 (직렬, await Brevo SMTP):
   for each target:
     a. 메일 HTML 렌더 — 인플 이름 + 매칭 캠페인 N개 카드 + 수신거부 링크(토큰)
     b. Brevo SMTP 발송 (to: [{ email }] 1명씩, To 헤더 노출 0)
     c. mark_promo_digest_sent(influencer_id, digest_date, 'sent' 또는 'failed', ...)
     d. Brevo rate limit 보호: 100ms 슬립
7. UPDATE campaign_promo_digest_runs SET status=..., sent_count=..., included_campaign_ids=..., finished_at=now()
8. 응답 반환
```

### 4-3. 부분 실패 정책 (admin-daily-digest §17 패턴 미러)

- 전부 성공 → status='sent'
- 일부 성공 + 일부 실패 → status='partial' + error_message에 실패 인플 ID 누적
- 전부 실패 → status='failed' + 첫 에러 메시지
- 데이터 0건 (대상자 0 또는 캠페인 0) → status='skipped_no_data'

### 4-4. 멱등성

- `digest_date` UNIQUE가 중복 호출 차단
- `(influencer_id, digest_date)` UNIQUE가 동일 인플 중복 발송 차단
- cron 재호출·향후 수동 트리거 동시성 모두 안전

---

## 5. 메일 본문 구성 (`docs/email-templates/campaign-promo-digest.html`)

### 5-1. 구조

```
[헤더]
  REVERB JP 로고
  「新しいキャンペーンのご案内」

[인사]
  {{influencer_name}} 様
  あなたが応募可能な新しいキャンペーンが {{campaign_count}}件 公開されました。

[캠페인 카드 N개]  ← {{campaign_cards_html}} placeholder
  각 카드: 썸네일 이미지 · 모집 타입 칩 · 제목 · 브랜드 · 리워드 · D-N 마감일 · 잔여 슬롯 · CTA 버튼

[CTA 푸터]
  「すべてのキャンペーンを見る」 → https://globalreverb.com/#campaigns

[발신자 정보 (특정전자메일법 의무)]
  株式会社ジェイファン (JFUN Corp.)
  주소·대표자·문의 이메일

[수신거부 (특정전자메일법 의무)]
  「マーケティング情報の配信を停止する」 → https://globalreverb.com/#unsubscribe?token={{unsubscribe_token}}
  「설정에서 변경하기」 → https://globalreverb.com/#mypage-email-settings

[푸터]
  본 메일은 자동 발송됩니다.
  {{agreed_at}}에 마케팅 정보 수신에 동의하셨기에 발송됩니다. (특상법 「동의 근거」)
```

### 5-2. Placeholder 6종

| placeholder | 내용 |
|---|---|
| `{{influencer_name}}` | 인플 표시명 (한자 우선, 없으면 가나/legacy name) |
| `{{campaign_count}}` | 매칭 캠페인 수 |
| `{{campaign_cards_html}}` | 캠페인 카드 N개 누적 HTML (Edge Function이 row partial 반복 렌더) |
| `{{unsubscribe_url}}` | 수신거부 1-click URL (토큰 포함) |
| `{{mypage_settings_url}}` | 마이페이지 메일 수신 설정 URL |
| `{{agreed_at}}` | 마케팅 동의 시점 (YYYY/MM/DD) |

### 5-3. 캠페인 카드 partial (`campaign-promo-digest.row-campaign.html`)

```html
<div style="border:1px solid #E2E7F2;border-radius:10px;padding:14px;margin-bottom:14px;background:#fff">
  <img src="{{img_url}}" alt="" style="width:100%;max-height:200px;object-fit:cover;border-radius:8px;margin-bottom:10px">
  <div style="font-size:11px;color:#888;margin-bottom:4px">
    <span style="background:{{type_chip_bg}};color:{{type_chip_fg}};padding:2px 8px;border-radius:4px;font-weight:700">{{recruit_type_ja}}</span>
    <span style="margin-left:6px">{{brand}}</span>
  </div>
  <h3 style="font-size:15px;font-weight:700;margin:6px 0 10px;line-height:1.4">{{title}}</h3>
  <table style="border-collapse:collapse;width:100%;font-size:12px;margin-bottom:12px">
    <tr><td style="color:#888;width:80px">報酬</td><td>{{reward}}</td></tr>
    <tr><td style="color:#888">締切</td><td style="color:#E8344E;font-weight:700">{{deadline_label}}</td></tr>
    <tr><td style="color:#888">残り枠</td><td>{{slots_remaining}}/{{slots_total}}</td></tr>
  </table>
  <a href="{{detail_url}}" style="display:inline-block;background:#C8789C;color:#fff;padding:8px 16px;border-radius:6px;text-decoration:none;font-weight:700;font-size:13px">詳細を見る</a>
</div>
```

### 5-4. 미리보기 파일 (`docs/email-templates/campaign-promo-digest.preview.html`)

- 다른 미리보기 패턴 미러 (preview-note 박스 + 제목 박스 + 본문)
- 샘플 시나리오: 캠페인 3건 (리뷰어 1 + 기프팅 1 + 방문형 1) 매칭된 인플
- 수신거부 링크는 `#`로 더미

---

## 6. 인플루언서 페이지 변경

### 6-1. 수신거부 라우트 — `#unsubscribe?token=...`

새 페이지 `#page-unsubscribe` (dev/index.html):

```
[상태 1] 토큰 검증 중 (스피너)
  → unsubscribe_by_token(token) 호출 결과 대기

[상태 2-A] 성공
  ✓ メールの配信を停止しました
  {influencer_name} 様、ありがとうございました。
  今後、キャンペーン情報のメールはお送りしません。
  応募状況や審査結果のメールは引き続き送信されます。
  [マイページに戻る] [再度受け取る]

[상태 2-B] 토큰 무효
  ✗ リンクが無効です
  この配信停止リンクは無効です。お手数ですが、マイページからご変更ください。
  [マイページへ] [トップへ]
```

- 인증 불요 (토큰만으로 식별)
- 재구독 버튼은 로그인 유도 (`#page-login` → 로그인 후 마이페이지 토글로 ON)

### 6-2. 마이페이지 「メール受信設定」

`#page-mypage` 하위 새 서브페이지 `#mypage-email-settings`:

```
[설정 카드]
  ☑ キャンペーン情報のお知らせメール (マーケティング)
     新しいキャンペーンが公開された際に毎朝9時に通知メールをお送りします。

  [トランザクションメール (常時送信)]
     - 応募の受付・承認・否認
     - 結果物の検収結果
     - 提出期限の通知
     これらのメールは重要な業務通知のため、配信停止できません。
```

- 토글 ON → `resubscribe_marketing()` 호출 (marketing_opt_in=true + marketing_agreed_at=now())
- 토글 OFF → `updateMarketingOptIn(false)` 호출 (marketing_opt_in=false + marketing_unsubscribed_at=now())
- 마이페이지 메뉴 리스트에 「メール受信設定」 항목 추가

### 6-3. 라우팅·파일

- `dev/index.html` — `#page-unsubscribe` + `#page-mypage-email-settings` 신규 마크업
- `dev/js/app.js` — 해시 라우트에 두 페이지 등록 (`#unsubscribe?token=` 쿼리 파라미터 파싱 포함)
- `dev/js/mypage.js` — 토글 렌더·저장 로직
- `dev/lib/storage.js` — `unsubscribeByToken(token)` / `updateMarketingOptIn(value)` / `resubscribeMarketing()` 3종 신규 함수
- `dev/lib/i18n/{ja,ko}.js` — 메일 수신 설정 + 수신거부 안내 일본어/한국어 키 추가
- `dev/css/mypage.css` — 토글 스타일

---

## 7. 관리자 페이지 변경

**MVP에서는 변경 없음** (자동 cron이라 운영자 트리거 UI 불요).

향후 옵션 (별도 PR):
- `/admin#campaign-promo-history` 신규 페인 — 발송 이력 (digest_date·캠페인 수·인플 수·발송/스킵/실패 통계)
- 운영자가 「발송 실패자 재시도」 수동 호출 (`source='manual'` 파라미터)

→ 본 사양서 범위 외, 운영 안정화 후 별도 사양서로 분리

---

## 8. 일본 특정전자메일법(특상법) 준수 체크리스트

| 의무 항목 | 본 사양 반영 |
|---|---|
| 사전 동의(옵트인) | `influencers.marketing_opt_in=true` 인 인플만 발송 (기존 가입 폼 동의) |
| 동의 기록 보관 (3년) | `marketing_agreed_at` 기록 + 메일 본문 푸터에 표기 |
| 발신자 표기 | 메일 푸터에 회사명(株式会社ジェイファン)·주소·대표자·문의 이메일 |
| 송신자 이메일 주소 | `noreply@globalreverb.com` (기존) |
| 수신거부 의사 표시 방법 | 토큰 1-click 링크 (메일 본문 하단) + 마이페이지 토글 |
| 수신거부 후 즉시 정지 | `unsubscribe_by_token` 호출 즉시 `marketing_opt_in=false` 반영, 다음 cron부터 자동 제외 |
| 광고임을 명시 | 제목에 「【お知らせ】」 prefix + 본문에 「キャンペーン情報」 명시 |
| 동의 근거 기록 표기 | 메일 푸터에 「YYYY/MM/DDに同意」 명시 |

---

## 9. 단계별 PR 분해

### PR 1 — DB 인프라 (마이그레이션 133·134·135)

- `133_campaign_promo_digest_tables.sql` — `campaign_promo_digest_runs` + `campaign_promo_digest_sent` + 인덱스 + RLS
- `134_influencer_unsubscribe_token.sql` — `influencers.unsubscribe_token` + `marketing_unsubscribed_at` + 기존 행 백필 + `unsubscribe_by_token()` + `resubscribe_marketing()` 원격 호출 함수
- `135_promo_digest_helpers.sql` — `get_promo_digest_targets()` + `mark_promo_digest_sent()` + `_meets_min_followers()` 헬퍼

검증:
- 개발 DB 인플 25명 대상으로 `get_promo_digest_targets(어제)` 호출 결과 확인
- `unsubscribe_by_token` 익명 호출 권한 확인 (anon으로 RPC 호출)
- `marketing_opt_in=false` 인플은 targets 에서 제외되는지 확인

의존: 없음 (독립 인프라). **reverb-supabase-expert 검토 필수** (마이그레이션 3개 + 4개 함수 + 익명 RPC)

### PR 2 — Edge Function + 메일 템플릿

- `docs/email-templates/campaign-promo-digest.html` (메인) + `campaign-promo-digest.row-campaign.html` (카드 partial) + `campaign-promo-digest.preview.html` 원본 + 카탈로그 등록
- `supabase/functions/notify-campaign-promo-digest/` 신규 (index.ts + templates.ts + _templates/)
- `scripts/sync-email-templates.sh` 동기화

검증:
- 개발 Supabase deploy → curl 수동 호출 → 본인 1명 인박스 도착 확인
- 메일 본문 캠페인 카드·CTA·수신거부 링크 시각 검증
- 토큰 URL 클릭 시 unsubscribe 페이지 도달 (PR 3 완료 후)

의존: PR 1 완료

### PR 3 — 인플루언서 수신거부 라우트

- `dev/index.html` `#page-unsubscribe` 신규 마크업
- `dev/js/app.js` 라우트 처리 (`#unsubscribe?token=...` 쿼리 파싱)
- `dev/lib/storage.js` `unsubscribeByToken(token)` 추가
- `dev/lib/i18n/{ja,ko}.js` 안내 텍스트 키

검증:
- PR 2로 발송된 메일의 수신거부 링크 클릭 → 페이지 도착 → DB `marketing_opt_in=false` 확인
- 잘못된 토큰 (수동 변조) → 「잘못된 링크」 안내

의존: PR 1·PR 2

### PR 4 — 마이페이지 메일 수신 설정

- `dev/index.html` `#page-mypage-email-settings` 신규
- `dev/js/mypage.js` 토글 렌더·저장
- `dev/lib/storage.js` `updateMarketingOptIn(value)` / `resubscribeMarketing()` 추가
- 마이페이지 메뉴에 「メール受信設定」 항목 추가

검증:
- 토글 OFF → 다음 cron 발송 시 인플 제외 확인 (PR 1 인프라로 검증 가능)
- 토글 ON → marketing_agreed_at 갱신 확인

의존: PR 1

### PR 5 — pg_cron 등록 + 운영 가동

- `136_promo_digest_cron.sql` — `cron.schedule` 등록 (개발 + 운영 DB 양쪽)
- 운영 DB 적용 전 PR 1~4 운영 배포 완료 확인
- 첫 자동 발송 다음 날 09:00 KST 인박스 검증

검증:
- 개발 DB cron 실행 결과 `campaign_promo_digest_runs` 로그 확인
- 운영 DB는 PR 4까지 운영 배포 완료 후 cron 등록 (사양 안정화)

의존: PR 1·2·3·4 운영 배포 완료

### PR 6 (선택) — 약관·개인정보처리방침 갱신

- `/약관확인` 슬래시 커맨드 실행 결과에 따라 `docs/PRIVACY_{ja,kr}.md` 일부 문구 추가
- 변경 강도에 따라 사전 통지 7일 검토

### PR 7 (선택, 향후) — 발송 이력 모니터링 페인

- `/admin#campaign-promo-history` 신규
- 발송 통계·실패자 리스트·재시도 버튼

---

## 10. 검증 시나리오

### 정상 케이스
- [ ] 옵트인 ON + 채널 매칭 + 팔로워 충족 → 메일 수신 (캠페인 카드 N개)
- [ ] 캠페인 카드 CTA 클릭 → 캠페인 상세 페이지 정상 진입
- [ ] 수신거부 클릭 → 즉시 처리, 다음 날 cron부터 제외
- [ ] 마이페이지에서 재구독 → 다음 날 cron에 다시 포함

### 경계 케이스
- [ ] 옵트인 OFF → 발송 제외
- [ ] 어제 신규 캠페인 0건 → cron 미발송 (status='skipped_no_data')
- [ ] 대상 인플 0명 (모두 옵트인 OFF) → 미발송
- [ ] 채널 미보유 (캠페인 IG, 인플 X만) → 제외
- [ ] monitor 캠페인 → 팔로워 체크 스킵, 모든 채널 매칭자 발송
- [ ] 이미 발송된 인플 (cron 재호출) → UNIQUE로 차단, 0건 추가 발송
- [ ] 같은 날 신규 캠페인 5건 → 인플당 1통에 5개 카드 묶여 발송

### 실패 케이스
- [ ] Brevo SMTP 실패 1건 → 다음 인플 계속 + status='partial'
- [ ] Edge Function 타임아웃 → 발송된 인플은 sent 로 남고, 미처리분은 다음 cron에서 자동 제외 (UNIQUE 멱등)
- [ ] cron 동시 호출 → digest_date UNIQUE로 한쪽만 진행
- [ ] 토큰 위변조 → 「잘못된 링크」
- [ ] 인플 삭제 → CASCADE로 토큰·발송 로그 자동 정리

### 보안·법령
- [ ] 메일 본문 푸터에 발신자 5종 정보 표기 확인
- [ ] 수신거부 링크 위치 (본문 하단 명확) 확인
- [ ] 동의 근거 (`{agreed_at}에 동의`) 표기 확인
- [ ] anon RPC `unsubscribe_by_token` 만 익명 GRANT, 나머지 함수는 authenticated 한정
- [ ] 토큰 UUID v4 (122 bit) 무차별 대입 안전

### 데이터 정합성
- [ ] PostgREST 1000-row cap 영향 없음 (RPC 함수 내부 처리)
- [ ] 인플 1,000명 발송 시 Edge Function 150초 timeout 안전 (직렬 0.5초 × 1,000 = 500초 위험)
  - 대응: 500명 초과 시 배치 분할 (PR 2 후 검토, 첫 운영 데이터로 결정)

---

## 11. 리스크

| 리스크 | 영향 | 완화 |
|---|---|---|
| Brevo Starter 20,000/월 한도 초과 | 메일 발송 중단 | 캠페인 30건/월 × 평균 300명 = 9,000통 (안전 마진 충분), 한도 임박 시 알림 |
| 인플 1,000명+ 발송 시 timeout | 일부 미발송 | 배치 분할 (500명/호출) + 후속 cron 재시도 (UNIQUE 멱등으로 안전) |
| 캠페인 등록 직후 cron 실행 전 수정 | 잘못된 정보 발송 | cron 시점에 캠페인 상태·이미지 다시 fetch → 등록 시점 스냅샷 사용 안 함 |
| 인플이 매일 같은 캠페인 반복 노출 | 스팸 인식 | UNIQUE (influencer_id, digest_date) + cron 「어제 신규」 윈도우라 한 캠페인은 다음 날까지만 노출 (2일 이상 발송 안 됨) |
| 옵트인 인플 비율 낮음 | 도달 인플 수 적음 | 마이페이지 「メール受信設定」 도입으로 재구독 유도 (PR 4 후 안내) |
| 메일 본문 너무 길어짐 (캠페인 10건+) | 가독성 저하 | 캠페인 카드 수 상한 (예: 최대 8건, 초과분 「他 N件」 + 캠페인 목록 링크) — PR 2 구현 시 |

---

## 12. 약관·개인정보처리방침 영향

- 본 기능 도입으로 신규 수집 항목 없음 (`marketing_opt_in` 기존), 신규 처리위탁 없음 (Brevo 기존), 국외이전 변경 없음
- 개인정보처리방침 — 마케팅 정보 활용 항목이 이미 있으면 갱신 최소, 「캠페인 안내 메일 발송」 목적 명시 검토
- 이용약관 — 갱신 불필요 (기존 마케팅 동의 조항이 커버)
- **/약관확인 슬래시 커맨드** 실행 — PR 6 단계에서
- 사전 통지 7일 의무 — 신규 위탁·국외이전 없음 → 해당 없음

---

## 13. 빌드·배포 영향

- `dev/build.sh` 신규 파일 추가 없음 (기존 mypage.js/app.js/storage.js 수정)
- 외부 시스템 변경 없음 (Brevo·DNS·Supabase Auth 설정 그대로)
- 운영 적용 순서:
  1. PR 1 마이그레이션 → 개발 DB 적용 → 검증 → 운영 DB 적용
  2. PR 2 Edge Function 개발 deploy → curl 검증 → 운영 deploy
  3. PR 3·4 인플 페이지 dev push → 개발 배포 → 검증 → 운영 머지
  4. PR 5 cron 개발 DB 등록 → 익일 09:00 KST 발송 검증 → 운영 DB 등록
- 첫 운영 자동 발송: PR 5 운영 적용 다음 날 09:00 KST

---

## 14. 구현 결과 (PR 1 — DB 인프라)

**구현일:** 2026-05-19
**관련 커밋:** 5835904 (PR 1 본체) + 0db3fea (channel 컬럼명 정정·REVOKE 가드 보강) — PR #228·#229 머지
**개발 DB 적용:** 2026-05-19 ✓ (qysmxtipobomefudyixw)
**운영 DB 적용:** 2026-05-19 ✓ (마이그레이션 139·140·141, twofagomeizrtkwlhsuv)

### 초안 대비 변경 사항

#### 추가된 것
- **모든 신규 함수에 `REVOKE EXECUTE ... FROM PUBLIC, anon` 패턴 적용** — Supabase 의 자동 GRANT 정책(`default_privileges` 가 신규 public 스키마 함수에 anon/authenticated/service_role 자동 부여) 대응. 사양서 §10 「nonpublic 함수는 authenticated 한정」 원칙을 실제로 강제하기 위해 PUBLIC 뿐 아니라 anon 도 명시적으로 REVOKE 후 의도된 role 만 GRANT.
  - anon 차단: `_meets_min_followers`, `get_promo_digest_targets`, `mark_promo_digest_sent`, `resubscribe_marketing`
  - anon 의도 노출 유지 + REVOKE→GRANT 명시: `unsubscribe_by_token`, `track_promo_click`

#### 빠진 것
없음 (사양서 §3-1, §3-2, §3-3, §16, §17 모두 구현)

#### 달라진 것
- **마이그레이션 번호**: 사양서 §9·§17-11 표기 `133·134·135·136` → 실제 파일 **`139·140·141·142`**. 이전 세션이 이미 133~138 까지 사용했기에 번호 충돌 회피.
- **외래 키 컬럼명**: 사양서 §3-1·§17-4 SQL 초안의 `REFERENCES public.influencers(auth_id)` → 실제 코드 **`REFERENCES public.influencers(id)`**. influencers 의 실제 PK가 `id`(= auth.users.id) 이고, 기존 마이그레이션 059(influencer_flags) 패턴과 동일.
- **캠페인 채널 컬럼명**: 사양서 §3-3 SQL 초안의 `c.channels LIKE '%instagram%'` → 실제 코드 **`c.channel LIKE '%instagram%'`** (단수). 실제 DB 컬럼은 `campaigns.channel text` (CSV 저장). 141 적용 시 컬럼 미존재 에러로 발견.
- **`get_promo_digest_targets` 반환 시그니처**: 사양서 §3-3 초안의 `matched_campaign_ids uuid[]` 단일 배열 → §17-4 갱신 사양 **`new_campaign_ids uuid[] + deadline_d1_campaign_ids uuid[]`** 분리 구조. 두 섹션(신규 + 마감 1일전) 분리 발송 정책 반영.

### 구현 중 기술 결정 사항

1. **Supabase `default_privileges` 자동 GRANT 대응 패턴 표준화**
   - 신규 public 함수 생성 직후 `REVOKE EXECUTE FROM PUBLIC, anon` → 의도된 role 명시 GRANT.
   - 향후 모든 신규 함수에 같은 패턴 적용 권장 (보안 표면적 최소화).

2. **`first_active_at` 트리거 BEFORE UPDATE OF status**
   - `NEW.first_active_at` 직접 수정 가능하도록 BEFORE 사용.
   - `OLD.status <> 'active' AND NEW.first_active_at IS NULL` 조건으로 첫 전환만 기록 (closed→active 재개 시 원본 시각 보존).
   - 백필 SQL: `UPDATE WHERE status IN ('active','closed','expired') AND first_active_at IS NULL` 로 9건 자동 채움(개발 DB 기준).

3. **`_meets_min_followers` 함수 시그니처 — 컬럼이 아닌 개별 파라미터**
   - CTE 안에서 일부 컬럼만 SELECT 하므로 복합 행 타입 전달이 어려움 → 개별 파라미터 8종으로 분리(recruit_type/primary_channel/channels/min_followers + 4개 채널 팔로워).

4. **`array_agg(c.id ORDER BY c.deadline ASC)[1:5]` 패턴**
   - SQL 안에서 「마감 가까운 순 + 최대 5건」 동시 구현. PostgreSQL 배열 슬라이스 활용.

5. **`FULL OUTER JOIN` 으로 신규·D-1 양 섹션 결합**
   - 한 인플이 신규 0건 + D-1 3건 또는 신규 5건 + D-1 0건 시나리오 모두 발송 대상에 포함.
   - WHERE 절에서 양쪽 모두 빈 배열인 행만 제외.

### 운영 적용 체크리스트
- [x] 마이그레이션 139·140·141 운영 DB SQL Editor 실행 (개발과 동일 순서) — 2026-05-19 완료
- [x] 운영 DB 검증 SQL 3건 실행 (테이블 4종 / 인플·캠페인 컬럼 / 함수 4종 권한) — 2026-05-19 완료
- [x] 마이그레이션 142 (pg_cron 주 2회 자동 발송 등록)는 PR 5 — 2026-05-20 운영 등록 완료 (§20 참조)
- [x] 운영 적용 후 커밋 본문에 「운영 DB 적용 완료 (date)」 표기

### 후속 보완 (Warning)
- 사양서 §3-1·§17-4 SQL 초안의 `auth_id`/`channels` 표기는 본 섹션이 정정한 것으로 갈음 (초안 SQL 자체는 이력 보존 차원에서 그대로 유지)
- Edge Function `notify-campaign-promo-digest` (PR 2) 주석에 qoo10 채널 미처리 명시 예정 (인플 테이블 qoo10 핸들 컬럼 없음)

---

## 15. 다음 단계 (메인 세션 → 개발 세션 인계)

1. PR 1 시작 전 `reverb-supabase-expert` 호출 — 마이그레이션 133·134·135 + 4개 원격 호출 함수 설계 검증
2. PR 1 머지 후 PR 2 시작 (Edge Function)
3. PR 3·4는 PR 2 머지 후 병행 가능 (인플 페이지 별도 파일이라 충돌 없음)
4. PR 5는 PR 1~4 운영 배포 완료 후 cron 등록
5. 운영 첫 자동 발송 다음 날 09:00 KST, 본인 인박스 + 운영 super_admin 1명 인박스 양쪽 시각 검증

## 16. 자격 매칭·발송 안정성 보강 (2026-05-19 사용자 추가 점검 반영)

### 16-1. 응모 자격 체크 강화 (Tier 1 우려 #1) — 2026-05-19 사용자 정정 반영

**핵심 정정 (2026-05-19)**: 자격 항목 중 **즉시 변경 가능 vs 즉시 변경 불가**를 구분해야 한다.

| 항목 | 인플이 즉시 변경 가능? | 본 사양 대응 |
|---|---|---|
| 인플 필수 정보(이름·배송지·전화·SNS 핸들·PayPal) | 가능 — 응모 시점 모달에서 추가 등록 후 응모 진행 | **발송 대상 제외 안 함** (그대로 발송) |
| 인플 팔로워수 | 불가 — 즉시 늘릴 수 없는 정보 | 해당 캠페인만 매칭에서 제외 (§2 핵심 결정 반영) |
| 캠페인 deadline 경과 | 불가 (캠페인 측 조건) | 발송 대상 제외 |
| monitor 캠페인 슬롯 마감 | 불가 (캠페인 측 조건) | 발송 대상 제외 |

**왜**: 인플 정보 미완성자(zip·prefecture·phone NULL 등)도 응모 진입 시 「未登録」 모달에서 추가 등록 후 응모 가능. 미리 메일 발송 대상에서 제외하면 「본인 정보 채우면 응모 가능한데 메일도 못 받는」 손실이 더 큼.

반면 팔로워수는 즉시 변경 불가하므로 미달자에게 해당 캠페인을 소개하면 「응모해도 자격 미달」이 확정 → 그 캠페인은 해당 인플 매칭에서 제외 (이 정책은 이미 §2 핵심 결정 및 `_meets_min_followers` 헬퍼가 처리).

**해결**: `get_promo_digest_targets` 함수에 **캠페인 측 조건만** 추가 (인플 측 필수 정보 필터 없음)

```sql
-- 캠페인 측 조건만 추가 (인플이 즉시 바꿀 수 없는 항목)
AND c.deadline > now()                                      -- 마감 안 됨
AND (
  c.recruit_type <> 'monitor'                               -- 리뷰어 아니거나
  OR (SELECT COUNT(*) FROM public.applications a
      WHERE a.campaign_id = c.id AND a.status = 'approved') < c.slots  -- 슬롯 잔여
)

-- 인플 측 필수 정보 필터는 추가하지 않음
-- 채널 매칭·팔로워 매칭(§2 핵심 결정)만 적용
```

**적용 영향**:
- 마이그레이션 135 `get_promo_digest_targets` 정의에 위 캠페인 조건만 추가 (인플 필터는 §2 그대로)
- 인플 정보 미완성자도 메일 정상 발송 → 응모 진입 시 모달로 정보 등록 후 응모 → 자연스러운 흐름
- 팔로워 미달 인플 → 해당 캠페인이 매칭에서 자동 제외 (`_meets_min_followers` 헬퍼)
- 「기간 마감」/「슬롯 마감」 메시지를 받을 위험 0
- 「팔로워 미달인데 자격 미달 캠페인 안내 받는」 좌절 위험 0

### 16-2. 이미 응모한 인플 + 응모 거절된 인플 제외 (Tier 1 우려 #2) — 2026-05-19 정정 반영

**문제**: 어제 캠페인 활성화 → 같은 날 빠른 인플이 즉시 응모 → 다음 날 cron이 그 인플에게도 「응모하세요!」 발송 → 어색. 또한 한 번 거절된 인플에게 다시 같은 캠페인을 안내하는 것도 부적절.

**정책 — 응모 status별 처리** (2026-05-19 사용자 확정):

| applications.status | 의미 | 캠페인 안내 메일에 포함? |
|---|---|---|
| (행 없음) | 아직 응모 안 함 | 포함 (안내 대상) |
| pending | 심사 중 | 제외 (이미 응모함) |
| approved | 승인됨 | 제외 (이미 응모·승인) |
| rejected | 거절됨 | **제외** — 재응모 불가 (applications UNIQUE 제약상 rejected 행이 남아 있어 같은 캠페인 재INSERT 불가). 다시 안내해도 응모 못 함 |
| cancelled | 본인 취소 | 포함 (UNIQUE partial index에서 cancelled 행은 제외되어 재응모 INSERT 가능) |

**해결**: `get_promo_digest_targets` 함수의 캠페인 매칭에 `applications` LEFT JOIN 추가

```sql
-- matches CTE 안에서 각 (인플, 캠페인) 페어를 만들 때
LEFT JOIN public.applications a
  ON a.user_id = i.auth_id
  AND a.campaign_id = c.id
  AND a.status <> 'cancelled'  -- cancelled 만 「응모 안 함」 으로 간주
                               -- pending / approved / rejected 는 모두 「응모 있음」 → 자동 제외
WHERE a.id IS NULL  -- 미응모 + 미거절 페어만
```

**적용 영향**:
- 마이그레이션 135 안에 통합
- 「이미 응모한 캠페인」(pending·approved)은 매칭에서 자동 제외
- **「이미 거절된 캠페인」(rejected)도 매칭에서 자동 제외** — 재응모 불가하므로 다시 안내해도 의미 없음
- 본인 취소(cancelled) 인플은 다시 안내 받을 수 있음 (재응모 가능 상태)
- 인플이 모든 매칭 캠페인에 응모 완료했다면 메일 자체가 발송 안 됨 (matched_campaign_ids 빈 배열 → 발송 스킵)

### 16-3. `campaigns.first_active_at` 컬럼 신설 (Tier 2 우려 #3)

**문제**: 본 사양 SQL의 「어제 active 전환」 정의가 `created_at` 또는 `recruit_start` 어제만 봄. 「그저께 draft 등록 + 어제 운영자 수동 active 토글」 누락.

**해결**: 신규 컬럼 + 트리거

```sql
-- 마이그레이션 134 안에 추가
ALTER TABLE public.campaigns
  ADD COLUMN first_active_at timestamptz NULL;

-- 기존 active/closed 캠페인 백필 (이미 active 됐던 흔적)
UPDATE public.campaigns
  SET first_active_at = COALESCE(recruit_start, created_at)
  WHERE status IN (active, closed, expired)
    AND first_active_at IS NULL;

-- 트리거: status 가 처음 active 로 전환될 때 한 번만 기록
CREATE OR REPLACE FUNCTION public._record_first_active_at()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path =  AS $func$
BEGIN
  IF NEW.status = active AND OLD.status <> active AND NEW.first_active_at IS NULL THEN
    NEW.first_active_at := now();
  END IF;
  RETURN NEW;
END;
$func$;

CREATE TRIGGER trg_campaigns_first_active_at
  BEFORE UPDATE OF status ON public.campaigns
  FOR EACH ROW EXECUTE FUNCTION public._record_first_active_at();
```

**적용 영향**:
- 마이그레이션 134 신규 컬럼·트리거·백필
- 마이그레이션 135 `get_promo_digest_targets` SQL의 윈도우 조건을 `first_active_at` 기준으로 교체:
  ```sql
  WHERE (first_active_at AT TIME ZONE Asia/Seoul)::date = p_digest_date
  ```
- `created_at`/`recruit_start` 조건 제거 (`first_active_at` 단일 기준이 더 정확)

### 16-4. Edge Function timeout 대응 (Tier 2 우려 #4)

**문제**: 인플 500명+ 발송 시 직렬 0.5초 × N = timeout 초과 가능.

**해결**: 첫부터 「200명/호출 배치」 + chained invocation 패턴

```
[Edge Function 처리 흐름 §4-2 갱신]
1. computeDigestDate() + INSERT mutex (동일)
2. SELECT get_promo_digest_targets(digest_date) → 대상자 N명
3. N <= 200 이면 한 번에 처리 (기존 흐름)
4. N > 200 이면:
   a. 첫 200명 처리 (Brevo 발송 + mark_promo_digest_sent)
   b. 처리 완료 후 본 함수 자신을 비동기 재호출 (waitUntil)
      → 다음 cron 안 기다리고 연속 처리
   c. mutex 는 첫 호출의 UPDATE 로 status=partial 유지
   d. 마지막 배치에서 status=sent 또는 partial 최종 UPDATE
5. 멱등 보장: get_promo_digest_targets 가 이미 발송된 인플 자동 제외하므로 재호출 안전
```

**적용 영향**:
- Edge Function index.ts 에 배치 로직 추가
- 운영 인플 5,000명까지 안전 (25 배치 × 100초 = 약 40분)
- 1만 명+ 도달 시 Brevo batch send API 검토 (별도 PR)

### 16-5. 캠페인 카드 수 상한 (Tier 2 우려 #5)

**문제**: 어제 신규 캠페인 20건+ 등록되면 메일이 매우 길어짐 (모바일에서 스크롤 부담, Gmail 메일 클립핑 발생 가능).

**해결**: 상한 **5건** + 초과분 안내

```
[메일 본문 §5-1 갱신]
[캠페인 카드 N개]  ← N <= 5
  카드 1
  카드 2
  ...
  카드 5

[N > 5 이면 추가 안내]
  「他 {N-5}件のキャンペーンも公開中です」
  [すべてのキャンペーンを見る] → https://globalreverb.com/#campaigns
```

- 캠페인 정렬: 본인이 응모 가능한 캠페인 중 「마감일이 가장 가까운 순」 또는 「리워드가 큰 순」
- **추천**: 마감일 가까운 순 (긴급성 강조) — 운영자 의도와 일치
- Edge Function 에서 SELECT 시 `ORDER BY deadline ASC LIMIT 5` + `COUNT(*)` 별도 조회

**적용 영향**:
- 마이그레이션 135 `get_promo_digest_targets` 가 `matched_campaign_ids` 를 마감일 순으로 정렬해서 반환 (`array_agg(c.id ORDER BY c.deadline ASC)`)
- Edge Function 이 첫 5개만 카드 렌더, 6개+ 면 「他 N件」 안내 추가
- 인플당 메일 길이 일정 보장

### 16-6. 영향 받는 마이그레이션·파일 갱신 요약

| 파일 | 추가 변경 |
|---|---|
| `133_campaign_promo_digest_tables.sql` | 변경 없음 (테이블 자체는 기존 사양 유지) |
| `134_influencer_unsubscribe_token.sql` | `campaigns.first_active_at` 컬럼 + 트리거 + 백필 추가 |
| `135_promo_digest_helpers.sql` | `get_promo_digest_targets` SQL에 §16-1·2·3·5 모두 통합 (자격 강화 + 미응모 + first_active_at + 마감일 순 정렬) |
| `supabase/functions/notify-campaign-promo-digest/index.ts` | §16-4 배치 로직 + §16-5 카드 5개 상한 + 「他 N件」 안내 |
| `docs/email-templates/campaign-promo-digest.html` | 「他 N件のキャンペーンも公開中です」 placeholder 추가 (`{{additional_count_html}}`) |
| `docs/email-templates/campaign-promo-digest.preview.html` | 시나리오에 「他 3件」 안내 반영 |

### 16-7. 검증 시나리오 추가

- [ ] 인플 정보 미완성자(배송지 NULL) → targets 에서 제외 확인
- [ ] 슬롯 마감된 monitor 캠페인 → matches 에서 제외 확인
- [ ] deadline 경과 캠페인 → 제외 확인
- [ ] 어제 응모한 캠페인 (status=pending) → 그 인플 매칭에서 제외 확인
- [ ] 어제 거절된 캠페인 (status=rejected) → 그 인플 매칭에서 제외 확인 (재응모 불가하므로 안내 안 함)
- [ ] 본인 취소한 캠페인 (status=cancelled) → 그 인플 매칭에 정상 포함 확인 (재응모 가능)
- [ ] 그저께 등록 + 어제 수동 active 토글된 캠페인 → 포함 확인 (first_active_at 트리거)
- [ ] 어제 active 캠페인 7건·인플 1명 매칭 → 5개 카드 + 「他 2件」 안내 확인
- [ ] 인플 500명+ 발송 → 배치 분할 정상 동작, 모든 인플 발송 완료 확인

### 16-8. PR 분해 영향

- PR 1 — DB 인프라: 마이그레이션 134·135 변경 (테이블·헬퍼·트리거 추가). 마이그레이션 133 영향 없음
- PR 2 — Edge Function: 배치 로직 + 카드 5개 상한 + 「他 N件」 placeholder 처리 추가
- PR 3·4·5: 변경 없음

→ PR 1·PR 2 작업량 약 +30%, 전체 일정에 큰 영향은 없음


## 17. 발송 주기·노출 한도·클릭 트래킹 (2026-05-19 사용자 정정 — 매일 발송 폐기)

### 17-1. 배경

사용자 우려: "이미 발송된 메일로 캠페인을 확인했고 별 관심이 없는데 다음날 또 다다음날 계속 소개가 된다면 스팸 신고 하고 싶을 것 같다." 매일 cron + D-3·D-1 정책은 같은 캠페인을 인플당 최대 3번 노출 가능 → 일본 스팸 인식 위험.

또한 사용자 질문: "캠페인을 확인했고를 어떻게 알 수 있을까?" — 「확인」 신호 측정 인프라가 필요.

### 17-2. 정책 — 발송 주기 + 노출 한도 + 클릭 트래킹

| 항목 | 정책 |
|---|---|
| 발송 cron | **주 2회 — 매주 월요일·목요일 09:00 KST** (`0 0 * * 1,4` UTC) |
| 발송 단위 | 인플당 메일 1통/회 (월요일 1통 + 목요일 1통) |
| 메일 본문 | **신규 캠페인 섹션 + 마감 임박 섹션 분리** (한쪽 0건이면 그 섹션 생략) |
| 같은 캠페인 노출 한도 | **인플당 최대 2회** — 신규 안내 1회 + D-1 임박 1회 |
| D-3 노출 | **제거** (인플당 3번 노출 회피) |
| 클릭 신호 | CTA 클릭 시 `campaign_promo_email_clicks` 행 INSERT → 다음 다이제스트에서 그 캠페인 자동 제외 |
| 다이제스트 윈도우 | 월요일 = 지난 4일(목~일) 신규 + 다음 5일 안 D-1 도달 / 목요일 = 지난 3일(월~수) 신규 + 다음 4일 안 D-1 도달 |

### 17-3. 노출 종류별 처리

| 노출 종류 (`kind`) | 의미 | 발송 시점 | 멱등 키 |
|---|---|---|---|
| `new` | 신규 캠페인 안내 | 캠페인 first_active_at 이후 첫 cron | `(campaign_id, influencer_id, kind='new')` UNIQUE |
| `deadline_d1` | 마감 1일 전 임박 알림 | 캠페인 deadline D-1 도달 후 첫 cron | `(campaign_id, influencer_id, kind='deadline_d1')` UNIQUE |

→ 같은 캠페인 인플당 최대 2회 노출 (new 1번 + deadline_d1 1번). 한쪽 발송한 적 있으면 그 종류 발송 안 함.

### 17-4. 데이터 모델 변경

#### 신규 테이블 `campaign_promo_exposure` (노출 기록 — 멱등 보장)

```sql
CREATE TABLE public.campaign_promo_exposure (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,
  influencer_id uuid NOT NULL REFERENCES public.influencers(auth_id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('new', 'deadline_d1')),
  sent_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (campaign_id, influencer_id, kind)
);
CREATE INDEX ON public.campaign_promo_exposure (influencer_id, sent_at DESC);
CREATE INDEX ON public.campaign_promo_exposure (campaign_id, kind);
```

- 행 단위 보안 정책: SELECT `is_admin()` 한정. INSERT 정책 없음 → service_role 만 우회
- 한 인플 - 한 캠페인 페어에 대해 최대 2행 (new + deadline_d1)

#### 신규 테이블 `campaign_promo_email_clicks` (클릭 추적)

```sql
CREATE TABLE public.campaign_promo_email_clicks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,
  influencer_id uuid NOT NULL REFERENCES public.influencers(auth_id) ON DELETE CASCADE,
  first_clicked_at timestamptz NOT NULL DEFAULT now(),
  click_count integer NOT NULL DEFAULT 1,
  last_clicked_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (campaign_id, influencer_id)
);
CREATE INDEX ON public.campaign_promo_email_clicks (influencer_id, first_clicked_at DESC);
```

- 같은 (캠페인, 인플) 페어에 대해 1행 — 두 번째 클릭은 `last_clicked_at` 갱신 + `click_count++`
- 이후 다이제스트에서 이 페어는 매칭 제외

#### 신규 RPC `track_promo_click(p_token uuid, p_campaign_id uuid)` — 익명 클릭 기록

```sql
CREATE OR REPLACE FUNCTION public.track_promo_click(
  p_token uuid,
  p_campaign_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_influencer_id uuid;
BEGIN
  SELECT auth_id INTO v_influencer_id
    FROM public.influencers
    WHERE unsubscribe_token = p_token;

  IF v_influencer_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  INSERT INTO public.campaign_promo_email_clicks
    (campaign_id, influencer_id, first_clicked_at, click_count, last_clicked_at)
  VALUES
    (p_campaign_id, v_influencer_id, now(), 1, now())
  ON CONFLICT (campaign_id, influencer_id) DO UPDATE
    SET click_count = public.campaign_promo_email_clicks.click_count + 1,
        last_clicked_at = now();

  RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.track_promo_click(uuid, uuid) TO anon, authenticated;
```

- 익명 anon GRANT (메일 클릭 = 비로그인 가능)
- 토큰은 `influencers.unsubscribe_token` 재사용 (별도 클릭 토큰 발급 안 함, 인프라 최소화)

#### `campaign_promo_digest_sent` 갱신 — `digest_date` 의미 변경

기존: `digest_date date` (일자) → 갱신: **그대로 유지** (월요일/목요일이라도 날짜 단위 멱등은 동일하게 보장)
- 「인플당 디다이제스트 1통/일」 정책에서 「인플당 디다이제스트 1통/cron호출」로 자연 확장 (월요일/목요일은 서로 다른 날짜)

#### `get_promo_digest_targets` 함수 시그니처 변경

```sql
RETURNS TABLE (
  influencer_id uuid,
  email text,
  name text,
  unsubscribe_token uuid,
  new_campaign_ids uuid[],          -- 신규 (이번 cron 윈도우 first_active_at, kind='new' 미노출)
  deadline_d1_campaign_ids uuid[]   -- D-1 임박 (deadline D-1, kind='deadline_d1' 미노출)
)
```

매칭 SQL 안에 추가 필터:
- `NOT EXISTS (SELECT 1 FROM campaign_promo_exposure WHERE campaign_id=c.id AND influencer_id=i.auth_id AND kind=...)` — 이미 노출됨 제외
- `NOT EXISTS (SELECT 1 FROM campaign_promo_email_clicks WHERE campaign_id=c.id AND influencer_id=i.auth_id)` — 클릭 한 캠페인 제외
- `NOT EXISTS (SELECT 1 FROM applications WHERE user_id=i.auth_id AND campaign_id=c.id AND status<>'cancelled')` — §16-2 응모/거절 제외

### 17-5. Edge Function 처리 흐름 (갱신)

```
1. computeDigestWindow() — 월요일/목요일 윈도우 계산
   - 월요일: 지난 목(D-4) 09:00 KST ~ 오늘(월) 00:00 KST → 신규 윈도우
             오늘 ~ +5일 → D-1 윈도우 (이번 주 일요일까지)
   - 목요일: 지난 월(D-3) 09:00 KST ~ 오늘(목) 00:00 KST → 신규 윈도우
             오늘 ~ +4일 → D-1 윈도우 (이번 주 일요일까지)
2. INSERT mutex (`digest_date` UNIQUE)
3. SELECT get_promo_digest_targets(digest_date) → 인플별 (new_campaign_ids, deadline_d1_campaign_ids)
4. 양 배열 모두 빈 경우 status='skipped_no_data'
5. 캠페인 일괄 조회 + 메일 HTML 렌더 (2섹션)
6. 대상자 루프:
   a. Brevo SMTP 발송
   b. mark_promo_digest_sent — 인플 디다이 단위 발송 기록
   c. 발송된 캠페인마다 INSERT campaign_promo_exposure (campaign_id, influencer_id, kind) — UNIQUE 멱등
7. UPDATE digest_runs 마무리
```

### 17-6. CTA URL 갱신

각 캠페인 카드 CTA:
```
https://globalreverb.com/#detail-{campaign_id}?promo_token={influencer.unsubscribe_token}
```

인플루언서 페이지가 캠페인 상세 진입 시 `promo_token` URL 파라미터 감지 → `track_promo_click(token, campaign_id)` RPC 호출 → 정상 페이지 렌더 (사용자에게 추적 사실 노출 안 함).

### 17-7. 메일 본문 구조 — 두 섹션 분리

```
[헤더]  REVERB JP 로고 + 「キャンペーン情報のお知らせ」

[인사]  {{influencer_name}} 様

[섹션 1: 新着キャンペーン] ← new_campaign_ids 가 있을 때만 렌더
  ▶ 新着キャンペーン (N件)
  [카드 1~5 + 초과시 「他 N件のキャンペーン公開中」]

[섹션 2: 締切間近キャンペーン] ← deadline_d1_campaign_ids 가 있을 때만 렌더
  ▶ 締切間近キャンペーン (M件)
  카드마다 빨강 「D-1」 칩 + 마감일 강조
  [최대 5건 + 초과시 「他 M件」]

[CTA 푸터]  「すべてのキャンペーンを見る」

[발신자·수신거부·동의 근거 푸터]
```

- 양 섹션 모두 0건 → 발송 미실시
- 한쪽 0건 → 그 섹션 헤더 자체 미노출

### 17-8. 인플 노출 시뮬레이션

**시나리오**: 인플 A 가 캠페인 X (자격 매칭, deadline 7일 후) 등록을 화요일에 봄.

| 일자 | 다이제스트 | A의 메일 안 캠페인 X 상태 | 노출 합계 |
|---|---|---|---|
| 화요일 | 발송 안 함 (주 2회) | — | 0 |
| **목요일** | 발송 | **「新着」 섹션 카드** | **1 (new)** |
| 금~일 | 발송 안 함 | — | 1 |
| **다음 월요일** | 발송 | A 클릭함 → 매칭 제외 / A 미클릭 → D-? 카운트 (D-3 도달, but D-3 노출 없음) → 미노출 | 1 |
| 다음 수요일 (D-1) | 발송 안 함 | — | 1 |
| **다음 목요일 (D=0)** | 발송 | deadline 이미 지남 → 캠페인 제외 | 1 |

→ 캠페인 등록 후 인플 A 노출 1번 (new). 클릭 안 한 캠페인이라도 「관심 없으면 새 캠페인 안내 → 마감일 도달 → 사라짐」 자연스러운 흐름.

**시나리오 2**: 캠페인 Y (deadline 10일 후, 화요일 등록).

| 일자 | A 노출 |
|---|---|
| 목요일 | new 1회 |
| 다음 목요일 (D-3 시점) | 이미 new 노출됨, D-3 노출 없음 → 미발송 |
| 그다음 월요일 (D-1 시점) | D-1 노출 → 1회 |
| **합계 2회 (new + D-1)** |  |

→ 같은 캠페인 최대 2회 노출. 「관심 없는 캠페인 매일 봄」 우려 해소.

### 17-9. 영향 받는 마이그레이션·파일 갱신

| 파일 | 변경 |
|---|---|
| `133_campaign_promo_digest_tables.sql` | `campaign_promo_exposure` + `campaign_promo_email_clicks` 테이블 추가 |
| `135_promo_digest_helpers.sql` | `get_promo_digest_targets` 시그니처 변경 (new_campaign_ids + deadline_d1_campaign_ids) + 노출/클릭 제외 필터 + `track_promo_click()` RPC + (선택) `mark_exposure()` RPC |
| `136_promo_digest_cron.sql` | cron schedule `0 0 * * *` → **`0 0 * * 1,4`** (월·목 UTC 00:00 = KST 09:00) |
| `supabase/functions/notify-campaign-promo-digest/index.ts` | 두 섹션 렌더 + D-1 칩 + 클릭 토큰 URL 생성 + exposure INSERT |
| `dev/js/app.js` | 캠페인 상세 진입 시 `?promo_token=...` 파라미터 감지 → `track_promo_click` 호출 |
| `dev/lib/storage.js` | `trackPromoClick(token, campaignId)` 추가 |
| `docs/email-templates/campaign-promo-digest.html` | placeholder 분리 (`{{new_section_html}}`/`{{deadline_section_html}}`) |
| `docs/email-templates/campaign-promo-digest.row-campaign.html` | D-1 칩 placeholder + CTA URL에 promo_token 포함 |
| `docs/email-templates/campaign-promo-digest.preview.html` | 시나리오에 신규 + D-1 카드 각각 + 클릭 추적 URL 샘플 반영 |

### 17-10. 검증 시나리오 추가

- [ ] 화요일 등록된 캠페인 → 목요일 cron에서 「新着」 발송, exposure(kind='new') 1행
- [ ] 같은 캠페인 다음 cron(월요일) → exposure(new) 이미 있어 매칭 제외
- [ ] 인플 클릭 → `track_promo_click` 호출 → email_clicks 1행 → 다음 cron에서 그 캠페인 매칭 제외
- [ ] 인플 클릭 안 함 + D-1 도달 → 「締切間近」 발송, exposure(kind='deadline_d1') 1행
- [ ] 두 번째 D-1 cron → exposure(deadline_d1) 이미 있어 매칭 제외 (같은 캠페인 인플당 최대 2회 보장)
- [ ] D-3 시점 cron → 노출 안 함 (D-3 정책 폐기 확인)
- [ ] 한 메일에 신규 0건 + 마감 임박 3건 → 「締切間近」 섹션만 렌더
- [ ] 두 종류 합쳐 0건 → 발송 미실시 (status='skipped_no_data')
- [ ] 같은 cron 재호출 (수동 트리거) → digest_date UNIQUE로 차단
- [ ] 운영 cron 첫 발송 (월) + 두 번째(목) 인박스 시각 검증

### 17-11. PR 분해 영향

- PR 1 — DB 인프라: 마이그레이션 133·134·135 모두 변경 (테이블 2개 추가 + 함수 시그니처 변경 + 노출/클릭 제외 + track_promo_click RPC)
- PR 2 — Edge Function: 두 섹션 렌더 + 클릭 토큰 URL + exposure INSERT + cron schedule 변경
- PR 3 — 수신거부 라우트: 변경 없음
- PR 4 — 마이페이지 토글: 변경 없음
- PR 5 — pg_cron 등록: schedule 표현식 변경 (`0 0 * * 1,4`)
- 신규 PR — **인플 페이지 클릭 추적**: `app.js` 라우트 + `storage.js` `trackPromoClick` (PR 3 안에 포함 가능 — 인플 페이지 단일 PR)

→ PR 1·PR 2·PR 3 작업량 추가 +20% (§16 위)

### 17-12. 리스크 갱신

| 리스크 | 영향 | 완화 |
|---|---|---|
| 같은 캠페인 인플당 2회 노출 후 종결 → 잠재 응모자 일부 놓침 | 모집 인원 미달 | 운영자가 캠페인 상세 페이지·SNS 별도 홍보 병행 권장 (메일은 보조 채널) |
| 클릭 트래킹 false negative (앱 안 브라우저, JS off 등) → 클릭했는데 추적 안 됨 → D-1에 한 번 더 받음 | 인플 불편 작음 (최대 2회 보장이라 폭주 안 함) | MVP에서 허용 |
| 주 2회 발송으로 신규 캠페인 노출 지연 (최대 3일 후) | 모집 초기 신청자 적음 | 운영자가 캠페인 등록 직후 LINE/SNS 즉시 알림 병행 |
| 클릭 토큰(unsubscribe_token) 외부 노출 시 위변조 | 「클릭한 척」 가능 → 그 인플 그 캠페인 안내 안 받음 | 피해 작음 (재구독·수동 페이지 확인 가능). UUID v4 무차별 대입 안전 |

---

## 18. 구현 결과 (PR 3·4 — 인플 수신거부 라우트 + 마이페이지 메일 수신 설정)

**구현일:** 2026-05-20
**관련 커밋:** 2d324dd — PR #234 (dev→main) 머지 완료, 운영 배포 완료

### 초안 대비 변경 사항

- **추가된 것**
  - 수신거부 페이지를 3-상태(처리 중 / 성공 / 무효 토큰) 단일 페이지로 구현 — `#page-unsubscribe` 안에서 JS 가 `display` 토글. 인증 페이지(`auth-wrap` > `auth-card`) 마크업 패턴 재사용
  - 마이페이지 「メール受信設定」 서브뷰에 **업무 알림 메일 안내 박스**(토글 없는 정보 영역) 추가 — 응모 접수·검수·마감 알림은 수신거부 불가임을 명시 (사양서 §6-2 의도 충실)
  - storage 함수 `updateMarketingOptIn(value)` 의 ON(value=true) 분기를 `resubscribeMarketing()` 으로 내부 위임 — 동의 시각(`marketing_agreed_at`) 누락 오용을 코드 레벨에서 차단 (supabase-expert 권장 반영)
  - OFF 처리 시 `marketing_opt_in=true` 인 행만 갱신하도록 조건 추가 — 최초 수신거부 시각 보존 (멱등 재호출 시 시각 덮어쓰기 방지)

- **빠진 것**
  - **메일 CTA 클릭 추적(`trackPromoClick`) 라우트는 이번 PR 미포함** — 사양서 §17-11 에서 「PR 3 에 포함 가능」으로 선택적 표기된 항목. 자동 발송 동작에는 불필요(같은 캠페인 인플당 최대 2회 노출은 `campaign_promo_exposure` 로 이미 보장). 클릭 시 자동 제외 최적화만 미적용 → 별도 후속 작업으로 분리

- **달라진 것**
  - storage 함수명: 사양서 시그니처(`unsubscribeByToken`/`updateMarketingOptIn`/`resubscribeMarketing`) 그대로 유지. 단 ON 경로 위임으로 `updateMarketingOptIn` 은 사실상 OFF 전용

### 구현 중 기술 결정 사항

- **라우팅 — 쿼리 붙은 해시 처리**: 기존 `app.js` 라우팅은 `location.hash.replace('#','')` 만 사용해 쿼리 파라미터 파싱이 전무했음. `#unsubscribe?token=...` 을 위해 `navigate()`(페이지명 분리) + `init()`(토큰 추출 후 `handleUnsubscribePage`) + `DOMContentLoaded`(initPage 계산) 세 경로에 일관 처리 추가
- **익명 호출 분리**: `unsubscribeByToken` 은 비로그인 동작이라 세션 갱신 래퍼(`retryWithRefresh`) 미사용. `resubscribeMarketing`(로그인 본인)만 래퍼 사용
- **잘못된 토큰 처리**: 잘못된 UUID 형식은 PostgreSQL 캐스팅 에러(22P02) → storage 함수 try/catch 가 `invalid_token` 무효 처리
- **교차 사이트 스크립팅 방지**: 수신거부 성공 화면 인플 이름은 `textContent` 주입 (innerHTML 미사용)
- **신규 파일 없음**: 기존 6개 파일 수정만 → `build.sh` 등록 불필요. `dev/build.sh` 로 빌드 재생성만

---

## 19. 구현 결과 (PR 2 — Edge Function + 메일 템플릿)

**구현일:** 2026-05-20 (운영 배포 완료)
**관련 커밋:**
- 40b98ce — PR 2 본체 (Edge Function `notify-campaign-promo-digest` + 메일 템플릿 + 마이그레이션 143 신설)
- a71b423 — 카드 이미지 transform·리워드 텍스트·testRecipient 디버그 모드 보강
- 12369ce — `finalizeRun` 종료 경로에서 `finished_at` 기록 누락 수정
- ee4caf4 — 인플 메일 푸터 4줄 통일 + 회사 정보 행 추가 (홍보 메일 포함 전체 인플 메일 공통)

**운영 배포:** Edge Function v7 ACTIVE (twofagomeizrtkwlhsuv) + 마이그레이션 143 운영 적용 2026-05-20

### 초안 대비 변경 사항

#### 추가된 것
- **마이그레이션 143 신설** (`get_promo_digest_targets` 반환 시그니처에 `new_total_count` + `deadline_d1_total_count` 2컬럼 추가) — 초안에는 없던 컬럼. 메일 본문 「他 N件のキャンペーン公開中」 안내 시, 마감 가까운 순 5건 슬라이스 전 매칭 총수를 정확히 산정하기 위함 (§16-5). 함수 반환 컬럼 변경이라 `DROP FUNCTION` 선행 후 재정의 + 권한 재부여
- **testRecipient 디버그 모드** — 운영 첫 수동 발송 검증 시 전체 발송 대신 지정 주소 1명에게만 보내는 디버그 파라미터. 운영 안정화 후 무해(미지정 시 정상 전체 발송)
- **메일 템플릿 주석 누출 strip 패치** — `<!-- {{placeholder}} -->` 패턴이 render 시 중첩 주석으로 본문에 누출되던 문제(메모리 `project_mail_template_comment_leak` 참조). `loadTemplate` 단계에서 placeholder 주석 제거

#### 빠진 것
- 없음 (사양서 §4·§5 Edge Function 처리 흐름·메일 본문 구성 모두 구현)

#### 달라진 것
- **카드 이미지 URL** — Supabase Storage transform(`/render/image/...?width=&quality=`) 적용해 메일 내 썸네일 용량 축소 (인플 앱 카드와 동일 패턴)
- **qoo10 채널** — 인플 테이블에 qoo10 핸들 컬럼이 없어 매칭에서 제외 (§14 후속 보완에서 예고한 대로 코드 주석 명시)

### 구현 중 기술 결정 사항
- 인플당 1통씩 분리 발송 (To 헤더에 다른 인플 이메일 노출 차단) — 기존 다이제스트 메일 패턴과 동일
- 200명/호출 배치 + chained 자기재호출(fire-and-forget)으로 대량 발송 timeout 대응 (§16-4)
- `campaign_promo_digest_runs.finished_at` 은 마지막 배치 또는 즉시 종료 시점에만 기록 — chained 중간 호출은 NULL 유지

---

## 20. 구현 결과 (PR 5 — pg_cron 등록 + 운영 가동)

**구현일:** 2026-05-20 (운영 가동 완료)
**관련 커밋:** 1e36126 — cron 호출 방식을 운영 가동 중인 기존 다이제스트 2종 패턴(vault `edge_function_jwt`)으로 정렬. dev→main **PR #235 머지 대기** (SQL 파일 변경뿐이라 운영 동작 영향 없음)

**운영 가동:**
- 마이그레이션 142 운영 SQL Editor 적용 2026-05-20
- cron `campaign-promo-digest-weekly` 등록 확인: jobid=4, schedule `0 0 * * 1,4`(월·목 UTC 00:00 = KST 09:00), active=true
- 운영 첫 수동 발송 테스트(curl) 완료
- **첫 자동 발송: 2026-05-21(목) 09:00 KST**

### 초안 대비 변경 사항

#### 달라진 것
- **마이그레이션 번호**: 사양서 §9 표기 `136` → 실제 파일 **`142`** (번호 충돌 회피, §14와 동일 사유)
- **cron 호출 방식**: 초안의 `current_setting('app.supabase_url')` 방식 폐기 → 운영/개발 DB 양쪽에 해당 커스텀 설정이 없음을 운영 등록 시 확인. 운영 가동 중인 `notify-admin-daily-digest`/`notify-influencer-daily-digest` 와 동일하게 **vault `decrypted_secrets`의 `edge_function_jwt`(서비스 키) + `functions.supabase.co` URL** 방식으로 통일
- **URL의 project-ref 환경 분리**: 운영 `twofagomeizrtkwlhsuv`. 개발은 ref만 `qysmxtipobomefudyixw` 로 교체 필요

### 구현 중 기술 결정 사항 / 운영 정책
- **개발서버에는 cron(142) 등록하지 않음** — 개발 DB의 실제 인플 데이터로 자동 발송이 나가는 것을 방지 (메일 발송 테스트 정책 `feedback_dev_no_mail_test`). 개발은 마이그레이션 143(함수 시그니처)만 환경 동기화 적용
- 배포 순서: 마이그레이션(개발→운영) → Edge Function(개발→운영) → **운영에서만** 수동 curl 검증 → 최종적으로 cron(142) 운영 등록

### 선택·향후 항목 (본 사양 범위 내 미진행)
- **PR 6 (선택) — 약관·개인정보처리방침 갱신**: §8 일본 특정전자메일법 체크리스트는 기존 동의(`marketing_opt_in`·`marketing_agreed_at`)·푸터 표기·수신거부 경로로 충족. `docs/PRIVACY_{ja,kr}.md` 문구 추가 필요 여부는 `/약관확인` 으로 별도 점검 필요 (미실행)
- **PR 7 (선택, 향후) — 발송 이력 모니터링 페인** (`/admin#campaign-promo-history`): 발송 통계·실패자 리스트·수동 재시도 버튼. 운영 안정화 후 별도 사양서로 분리 (미착수)
- **메일 CTA 클릭 추적 라우트(`trackPromoClick`)**: PR 3·4 에서 미포함(§18). `track_promo_click` 원격 호출 함수·`campaign_promo_email_clicks` 테이블은 인프라로 존재하나, 인플 앱에서 클릭 시 호출하는 프런트 연결은 미적용 → 「클릭한 캠페인 자동 제외」 최적화만 보류 (자동 발송·노출 한도 동작에는 영향 없음, `campaign_promo_exposure` 가 최대 2회 노출 이미 보장)
