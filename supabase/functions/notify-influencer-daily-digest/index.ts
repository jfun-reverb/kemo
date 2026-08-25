// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-influencer-daily-digest
// ──────────────────────────────────────────────────────────────────
// 트리거: pg_cron 매일 UTC 00:00 (= 한국시간 오전 9시) net.http_post
// 역할:   인플루언서별로 어제 응모 활동 + 오늘 D-5/D-1 마감 임박을
//         하나의 메일로 통합 발송. 4섹션 (신청·승인·반려·마감) 중
//         1개라도 0건 초과인 인플루언서만 발송. 4섹션 0건이면 스킵.
//         발송 직후 deadline_reminder_email_sent 에 D-N 항목 INSERT
//         → 다음 날 같은 D-N 메일 재발송 방지.
//
// 환경변수 (Edge Functions Secrets):
//   SUPABASE_URL              자동 주입
//   SUPABASE_SERVICE_ROLE_KEY 자동 주입
//   BREVO_API_KEY             Brevo Transactional API 키 (양 서버 별도)
//   BREVO_SENDER_EMAIL        기본 noreply@globalreverb.com
//   BREVO_SENDER_NAME         기본 REVERB JP  (개발은 REVERB JP [DEV])
//   PUBLIC_APP_URL            인플루언서 사이트 절대 URL (기본 https://globalreverb.com)
//
// HTML 템플릿 (sync-email-templates.sh):
//   _templates/influencer-daily-digest.html
//   _templates/influencer-daily-digest.row-received.html
//   _templates/influencer-daily-digest.row-approved.html
//   _templates/influencer-daily-digest.row-rejected.html
//   _templates/influencer-daily-digest.row-deadline.html
//
// pg_cron 등록 예시 (운영 절차는 docs/specs/2026-05-18-HANDOFF-... 참조):
//   SELECT cron.schedule(
//     'influencer-daily-digest',
//     '0 0 * * *',
//     $$ SELECT net.http_post(
//          url := 'https://<ref>.functions.supabase.co/notify-influencer-daily-digest',
//          headers := jsonb_build_object(
//            'Content-Type','application/json',
//            'Authorization','Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='edge_function_jwt' LIMIT 1)),
//          body := '{}'::jsonb); $$ );
//
// 사양서: docs/specs/2026-05-18-application-email-pipeline.md
//
// ──────────────────────────────────────────────────────────────────
// 【발송 없이 확인하는 법】 — 행사 당선 제외(2026-08-24 결정 3, 조각 S-14)
// ──────────────────────────────────────────────────────────────────
// 🔴 개발서버에서 이 함수를 실제로 호출해 발송 시험을 하지 않는다
//    (.claude/rules/supabase.md 「메일 발송 테스트 환경 정책」).
//    ⚠️ 손으로 불러도 소용없다 — 같은 날 재실행은 자물쇠(digest_date UNIQUE)가
//       막아 그냥 건너뛴다. **같은 조건을 데이터로 재현**하는 편이 발송 0통으로
//       대상을 산출한다(2026-08-07 마감 안내 검증에서 쓴 방법).
//
// 아래를 SQL 편집기에서 그대로 돌리면 「내일 아침 이 메일의 당선·낙첨 두
// 섹션에 무엇이 담길지」가 나온다. 조회뿐이라 아무것도 바꾸지 않는다.
// (수신자 확정에는 메일 주소·탈퇴 여부 등 뒤쪽 조건이 더 붙는다 — 이 조회는
//  S-14 가 가른 **섹션 분류**만 본다. 세 검증에 필요한 것이 그것이다.)
//
//   WITH win AS (   -- 이 함수의 어제 일본시각 창(computeWindow)을 그대로 재현
//     SELECT  ts                        AS s,
//             ts + interval '24 hours'  AS e
//     FROM (
//       SELECT ((((now() AT TIME ZONE 'Asia/Tokyo')::date - 1)::text)
//               || 'T00:00:00+09:00')::timestamptz AS ts
//     ) t
//   )
//   SELECT c.event_mode,
//          a.status,
//          CASE
//            WHEN a.status = 'approved' AND c.event_mode THEN '제외됨(행사 당선 — 14-E)'
//            WHEN a.status = 'approved'                  THEN '당선 메일 나감(14-F)'
//            WHEN a.status = 'rejected' AND c.event_mode THEN '낙첨 메일 나감(14-D)'
//            ELSE                                             '낙첨 메일 나감(기존)'
//          END                                          AS "판정",
//          count(*)                                     AS "건수"
//   FROM applications a
//   JOIN campaigns c ON c.id = a.campaign_id
//   CROSS JOIN win
//   WHERE a.status IN ('approved','rejected')
//     AND a.reviewed_at >= win.s
//     AND a.reviewed_at <  win.e
//   GROUP BY 1, 2, 3
//   ORDER BY 1, 2;
//
// 읽는 법 — 세 줄이 완료 정의 그대로다:
//   14-E  event_mode=true  + approved → 「제외됨」  (0통이어야 맞다)
//   14-D  event_mode=true  + rejected → 「나감」    (계속 가야 맞다)
//   14-F  event_mode=false + approved → 「나감」    ← 가장 중요. 이 줄이
//         비면 일반 캠페인 당선 안내가 통째로 멈춘 것이다
//
// ⚠️ 지금은 행사 줄이 아예 안 나오는 게 정상이다 — 행사 예약 경로가
//    reviewed_at 을 채우지 않기 때문(그래서 8월 행사에서도 이 메일은 안 나갔다).
//    조각 S-4 의 떨어뜨리기가 그 칸을 채우는 순간 열리는 문이라, 이 변경은
//    **S-4 와 반드시 함께 나가야 한다.** S-4 적용 뒤 위 조회를 다시 돌려
//    행사 줄이 「제외됨 / 나감」으로 갈리는지 눈으로 확인할 것.
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TEMPLATES } from "./templates.ts";

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";

function env(key: string, fallback = ""): string {
  return Deno.env.get(key) ?? fallback;
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// ──────────────────────────────────────────────────────────────────
// KST 어제 윈도우 + 오늘 KST 날짜 계산
// ──────────────────────────────────────────────────────────────────
function computeWindow() {
  const KST_OFFSET_MS = 9 * 3600 * 1000;
  const nowKstMs = Date.now() + KST_OFFSET_MS;
  const yesterdayKstMs = nowKstMs - 24 * 3600 * 1000;
  const yKst = new Date(yesterdayKstMs);
  const tKst = new Date(nowKstMs);
  const yyyyY = yKst.getUTCFullYear();
  const mmY = String(yKst.getUTCMonth() + 1).padStart(2, "0");
  const ddY = String(yKst.getUTCDate()).padStart(2, "0");
  const digestDate = `${yyyyY}-${mmY}-${ddY}`;
  const yyyyT = tKst.getUTCFullYear();
  const mmT = String(tKst.getUTCMonth() + 1).padStart(2, "0");
  const ddT = String(tKst.getUTCDate()).padStart(2, "0");
  const todayDate = `${yyyyT}-${mmT}-${ddT}`;
  const windowStartUtc = new Date(Date.parse(`${digestDate}T00:00:00+09:00`));
  const windowEndUtc = new Date(windowStartUtc.getTime() + 24 * 3600 * 1000);
  return { digestDate, todayDate, windowStartUtc, windowEndUtc };
}

// ISO timestamptz → 「YYYY年M月D日 HH:mm」 일본어 표기
function formatJpDateTime(iso: string): string {
  const d = new Date(iso);
  const kstMs = d.getTime() + 9 * 3600 * 1000;
  const k = new Date(kstMs);
  const y = k.getUTCFullYear();
  const m = k.getUTCMonth() + 1;
  const dd = k.getUTCDate();
  const hh = String(k.getUTCHours()).padStart(2, "0");
  const mi = String(k.getUTCMinutes()).padStart(2, "0");
  return `${y}年${m}月${dd}日 ${hh}:${mi}`;
}

// 'YYYY-MM-DD' 또는 'YYYY-MM-DDT...' → 「M月D日」 일본어 표기
function formatJpDateShort(iso: string): string {
  const d = new Date(iso);
  const y = d.getUTCFullYear();
  const m = d.getUTCMonth() + 1;
  const dd = d.getUTCDate();
  return `${m}月${dd}日`;
}

function formatJpDateFull(date: Date): string {
  return `${date.getUTCFullYear()}年${date.getUTCMonth() + 1}月${date.getUTCDate()}日`;
}

function recruitTypeJp(rt: string | null | undefined): string {
  // dev/js/ui.js 의 ja 표기와 일치 (レビュアー / ギフティング / 訪問型)
  switch (rt) {
    case "monitor": return "レビュアー";
    case "gifting": return "ギフティング";
    case "visit":   return "訪問型";
    default:        return rt || "";
  }
}

// 리뷰 인증샷(review_image) 마감 안내 종류 라벨.
// 캠페인 요구 채널이 2개 이상일 때만 남은(미완료) 채널명을 괄호로 병기한다
// (확정된 결정, 2026-08-04 사양서 — 단일 채널에서 채널명은 군더더기).
function reviewImageKindLabel(
  missingChannels: string[] | undefined,
  requiredChannelCount: number | undefined,
  channelLabelMap: Map<string, string>,
): string {
  const base = "レビュー認証写真";
  if (!missingChannels || !requiredChannelCount || requiredChannelCount < 2) return base;
  const names = missingChannels.map((ch) => channelLabelMap.get(ch) || ch);
  return `${base}（${names.join("・")}）`;
}

// 일자 차이 (양수: A 가 미래, 음수: A 가 과거)
function dateDiffDays(a: string, b: string): number {
  const aMs = Date.parse(a + "T00:00:00+09:00");
  const bMs = Date.parse(b + "T00:00:00+09:00");
  return Math.round((aMs - bMs) / (24 * 3600 * 1000));
}

function loadTemplate(name: string): string {
  const html = TEMPLATES[name];
  if (!html) throw new Error(`template not registered: ${name}`);
  // HTML 주석 제거 — 주석 안 placeholder 가 치환되면서 발생하는 중첩 주석
  // → 조기 종료 → 본문 누출 버그 차단 (2026-05-18 admin-daily-digest 발견 동일 패턴)
  return html.replace(/<!--[\s\S]*?-->/g, "");
}

function render(html: string, data: Record<string, string>): string {
  return html.replace(/\{\{(\w+)\}\}/g, (_m, key) => data[key] ?? "");
}

// ──────────────────────────────────────────────────────────────────
// [F-4] 1,000행 응답 상한 대응 — 여러 페이지로 나눠 전부 가져오는 공용 도우미.
//   dev/lib/storage.js 의 fetchAllPaged() 와 같은 패턴(이 프로젝트의 Edge
//   Function 은 파일끼리 공유 모듈이 없어 함수마다 각자 들고 있음). PostgREST
//   는 한 번의 응답에 최대 1,000행만 돌려주므로, 하루 단위로 리셋되지 않고
//   계속 쌓이는(all-time 누적) 조회는 반드시 이 도우미로 감싼다.
//   buildQuery 는 호출할 때마다 새 쿼리 빌더를 만들어야 하고(재사용 불가 —
//   이미 실행된 빌더는 다시 .range() 를 못 건다), 반드시 안정적인 정렬
//   (예: id 오름차순)이 걸려 있어야 한다 — 정렬이 없으면 페이지 경계에서
//   같은 행이 두 번 나오거나 아예 빠질 수 있다.
//   ⚠️ 여기서는 sb 를 인자로 받지 않는다(클로저로 캡처) — sb 를 명시적
//   매개변수로 받으면 이 파일에 이미 있던 타입 불일치(ReturnType<typeof
//   createClient> 와 실제 인스턴스 타입이 어긋나는 기존 결함, logRun 등에서
//   재현됨)가 여기도 옮아붙는다.
// ──────────────────────────────────────────────────────────────────
async function fetchAllPaged<T>(
  buildQuery: () => { range: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }> },
  pageSize = 1000,
): Promise<T[]> {
  const all: T[] = [];
  let from = 0;
  while (true) {
    const { data, error } = await buildQuery().range(from, from + pageSize - 1);
    if (error) throw new Error(error.message);
    if (!data || data.length === 0) break;
    all.push(...data);
    if (data.length < pageSize) break;
    from += pageSize;
  }
  return all;
}

async function sendBrevoEmail(params: {
  to: { email: string; name?: string }[];
  subject: string;
  htmlContent: string;
  textContent: string;
}): Promise<void> {
  const apiKey = env("BREVO_API_KEY");
  if (!apiKey) throw new Error("BREVO_API_KEY not configured");
  const senderEmail = env("BREVO_SENDER_EMAIL", "noreply@globalreverb.com");
  const senderName = env("BREVO_SENDER_NAME", "REVERB JP");
  const body = {
    sender: { email: senderEmail, name: senderName },
    to: params.to,
    subject: params.subject,
    htmlContent: params.htmlContent,
    textContent: params.textContent,
  };
  const res = await fetch(BREVO_ENDPOINT, {
    method: "POST",
    headers: {
      "api-key": apiKey,
      "content-type": "application/json",
      accept: "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Brevo send failed ${res.status}: ${errText}`);
  }
}

// ⚠️ [F-6/F-5 재설계] 예전 logRun() 은 사전 조회(maybeSingle) 로 "혹시 이미
//   처리됐나"만 확인하고, 실제 로그는 발송이 다 끝난 뒤에야 INSERT 했다.
//   그 사이 시간(수 분)에 재시도가 겹치면 두 실행이 둘 다 "아직 안 처리됨"
//   으로 보여 전원에게 메일이 두 번 나갈 수 있었다. notify-admin-daily-digest
//   가 쓰는 "INSERT 를 먼저 해서 자물쇠로 쓰는" 방식으로 통일한다 — 아래
//   Deno.serve 핸들러 안의 mutex 블록 + finalizeRun 참고.
// ──────────────────────────────────────────────────────────────────
// 4섹션 데이터 조회 — 인플루언서별 그룹핑 전 단계
// ──────────────────────────────────────────────────────────────────

interface AppRow {
  id: string;
  user_id: string;
  campaign_id: string;
  status: string;
  created_at: string;
  reviewed_at: string | null;
}
interface CampRow {
  id: string;
  campaign_no: string | null;
  title: string | null;
  recruit_type: string | null;
  reward: number | null;
  product_price: number | null;   // レビュアー型の上限表示（購入金額をペイバック 最大 ¥N）
  purchase_end: string | null;
  submission_end: string | null;
  proxy_purchase: boolean | null;
  channel: string | null;
  // 행사(오프라인 팝업 방문 예약) 캠페인인가 — 당선 섹션 제외 판정용(2026-08-24 결정 3).
  // ⚠️ 이 칸이 조회에서 빠지면 항상 undefined 가 되어 **아무것도 안 걸러진다**(오류 없이 조용히).
  event_mode: boolean | null;
}
interface DelivRow {
  application_id: string;
  kind: string;
  status: string;
  post_channel: string | null;
}
interface SentRow {
  influencer_id: string;
  campaign_id: string;
  kind: string;
  d_minus: number;
  deadline_date: string; // [F-9] 마감일이 연장되면 새 마감일 기준으로 재안내가 나가야 하므로
                          // 중복 차단 열쇠에 포함 — 마이그레이션 322 로 DB 쪽 UNIQUE 제약도 5-튜플로 확장
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }
  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) {
    return new Response(JSON.stringify({ error: "SUPABASE env missing" }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
  const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

  const { digestDate, todayDate, windowStartUtc, windowEndUtc } = computeWindow();
  console.log("[notify-infl-digest] window", {
    digestDate,
    todayDate,
    start: windowStartUtc.toISOString(),
    end: windowEndUtc.toISOString(),
  });

  // ── 1. INSERT 선행 mutex (status='failed' 마커) ── [F-6 재설계]
  //    digest_date UNIQUE 가 mutex 역할 → 동시 호출 차단.
  //    notify-admin-daily-digest 와 동일 패턴(F-6) — 예전엔 사전 조회만
  //    하고 로그는 맨 끝에 INSERT 했는데, 그 사이(수 분) 재시도가 겹치면
  //    전원이 두 번 받을 수 있었다.
  //
  //    [F-5] 23505(이미 있음) 를 만나면 무조건 "이미 처리됨"으로 끝내지
  //    않는다 — 그 마커 행이 처리 도중 함수가 죽어서(타임아웃 등)
  //    status='failed'·error_message='in-flight' 인 채로 영원히 멈춰
  //    있을 수 있고, 그러면 그날은 몇 번을 다시 불러도 "이미 처리됨"
  //    취급돼 발송이 영영 안 나간다(재호출이 200 을 주므로 운영자는
  //    "보냈는데 안 온다"로 오인한다). 기존 행을 읽어 ①이미 끝난 상태
  //    (sent/skipped_no_data)면 그대로 스킵 ②아직 안 끝난 상태(failed)
  //    면 RETRY_COOLDOWN_MS 가 지났을 때만 "내가 이어받는다"는 조건부
  //    UPDATE 를 시도한다. 이 UPDATE 는 직전에 읽은 run_at 값이 그대로일
  //    때만 통과하므로(낙관적 락 — dev/lib/storage.js updateCampaign 의
  //    version 조건부 UPDATE 와 같은 원리), 두 재호출이 동시에 들어와도
  //    한쪽만 통과한다(먼저 커밋한 쪽이 run_at 을 새로 찍어버려 나머지는
  //    조건 불일치로 0행 UPDATE).
  //
  //    RETRY_COOLDOWN_MS = 10분 — 이 함수는 admin/brand 다이제스트와
  //    같은 단발성(체이닝 없음) 구조라, 정상 실행은 Deno Edge Function
  //    의 실행 시간 상한(이 저장소의 다른 함수 주석 기준 약 150초, 예:
  //    notify-campaign-promo-digest·notify-policy-change) 안에 반드시
  //    끝나거나 플랫폼에 의해 죽는다. 10분은 그 150초의 약 4배 여유를
  //    둔 값 — 실제로 아직 실행 중인 프로세스와 충돌할 가능성을 사실상
  //    배제하면서도, 당일 안에 수동 재시도(또는 재시도용 cron)가 통하기
  //    충분히 짧다.
  const RETRY_COOLDOWN_MS = 10 * 60 * 1000;
  // [리뷰 반영 1/2026-08] "내가 지금 이 실행의 주인"임을 끝까지(finalizeRun 까지)
  // 들고 갈 값 — notify-admin-daily-digest 와 동일 근거(쿨다운 판단이 틀려서
  // 원본과 재시도가 동시에 살아있어도, 최종 상태 기록만큼은 소유권 확인으로
  // 한쪽만 이긴다).
  let ownedRunAt: string | null = null;
  {
    const { data: inserted, error: mutexErr } = await sb
      .from("influencer_daily_digest_runs")
      .insert({
        digest_date: digestDate,
        status: "failed",
        total_influencers: 0,
        total_emails: 0,
        error_message: "in-flight",
      })
      .select("run_at")
      .maybeSingle();
    if (mutexErr) {
      if ((mutexErr as { code?: string }).code === "23505") {
        const { data: existing, error: selErr } = await sb
          .from("influencer_daily_digest_runs")
          .select("status, run_at")
          .eq("digest_date", digestDate)
          .maybeSingle();
        if (selErr || !existing) {
          console.error("[notify-infl-digest] existing row lookup failed after 23505", selErr);
          return new Response(
            JSON.stringify({ ok: true, skipped: true, reason: "already_processed", digestDate }),
            { status: 200, headers: { "content-type": "application/json" } },
          );
        }
        if (existing.status === "sent" || existing.status === "skipped_no_data") {
          // 이미 끝난 상태(성공/데이터없음) — 재시도 없이 스킵
          console.log("[notify-infl-digest] already processed (terminal)", digestDate, existing.status);
          return new Response(
            JSON.stringify({ ok: true, skipped: true, reason: "already_processed", digestDate, priorStatus: existing.status }),
            { status: 200, headers: { "content-type": "application/json" } },
          );
        }
        // status === 'failed' — 크래시로 멈췄거나 진짜 실패. 최소 대기 시간 확인.
        const runAtMs = new Date(existing.run_at as string).getTime();
        const elapsedMs = Date.now() - runAtMs;
        if (elapsedMs < RETRY_COOLDOWN_MS) {
          console.log("[notify-infl-digest] recent failed/in-flight row, cooldown not elapsed — skip retry", {
            digestDate, elapsedMs, cooldownMs: RETRY_COOLDOWN_MS,
          });
          return new Response(
            JSON.stringify({ ok: true, skipped: true, reason: "recent_failure_cooldown", digestDate, elapsedMs }),
            { status: 200, headers: { "content-type": "application/json" } },
          );
        }
        // 쿨다운 경과 — 조건부 UPDATE 로 "내가 이어받는다" 시도
        const retryRunAt = new Date().toISOString();
        const { data: claimed, error: claimErr } = await sb
          .from("influencer_daily_digest_runs")
          .update({
            status: "failed",
            total_influencers: 0,
            total_emails: 0,
            error_message: "in-flight (retry)",
            run_at: retryRunAt,
          })
          .eq("digest_date", digestDate)
          .eq("run_at", existing.run_at as string)
          .select("id");
        if (claimErr || !claimed || claimed.length === 0) {
          console.log("[notify-infl-digest] lost retry race or already claimed", digestDate, claimErr);
          return new Response(
            JSON.stringify({ ok: true, skipped: true, reason: "retry_race_lost", digestDate }),
            { status: 200, headers: { "content-type": "application/json" } },
          );
        }
        ownedRunAt = retryRunAt; // 방금 내가 써넣은 값 — finalizeRun 의 소유권 조건으로 재사용
        console.warn("[notify-infl-digest] retrying stale/failed run", digestDate, { priorRunAt: existing.run_at });
        // 아래로 흘러 정상 처리 진행 (INSERT 대신 이 UPDATE 로 mutex 를 확보한 상태)
      } else {
        console.error("[notify-infl-digest] mutex INSERT failed", mutexErr);
        return new Response(JSON.stringify({ error: "mutex insert failed", detail: mutexErr.message }), {
          status: 500, headers: { "content-type": "application/json" },
        });
      }
    } else {
      ownedRunAt = (inserted?.run_at as string | undefined) ?? null;
      if (!ownedRunAt) {
        console.error("[notify-infl-digest] mutex INSERT succeeded but run_at missing from response — ownership check disabled for this run", digestDate);
      }
    }
  }

  // 헬퍼: 종료 시 influencer_daily_digest_runs UPDATE (admin-daily-digest 의
  // finalizeRun 과 동일 패턴 — mutex 단계에서 이미 행이 존재하므로 INSERT 아님)
  //
  // [리뷰 반영 1] mutex 를 "잡을 때"는 run_at 조건부 UPDATE 로 소유권을
  // 확인하면서 "끝낼 때"(finalizeRun)는 digest_date 로만 UPDATE 했었다 —
  // 쿨다운(10분) 이 검증 안 된 실행시간 가정에 기대므로, 실제 실행이 그보다
  // 길어지면 재시도가 오판해 소유권을 가져가고 원본·재시도가 둘 다 계속
  // 돌 수 있다. ownedRunAt 이 있으면 그 값으로도 조건을 걸고, 0행이면
  // (그 사이 다른 실행이 run_at 을 바꿔써서 내가 더 이상 주인이 아니면)
  // 덮어쓰지 않고 console.error 로만 남긴다.
  const finalizeRun = async (payload: {
    status: "sent" | "skipped_no_data" | "failed";
    total_influencers: number;
    total_emails: number;
    error_message?: string | null;
  }) => {
    let q = sb
      .from("influencer_daily_digest_runs")
      .update({
        status: payload.status,
        total_influencers: payload.total_influencers,
        total_emails: payload.total_emails,
        error_message: payload.error_message ?? null,
      })
      .eq("digest_date", digestDate);
    if (ownedRunAt != null) q = q.eq("run_at", ownedRunAt);
    const { data, error } = await q.select("id");
    if (error) {
      console.error("[notify-infl-digest] finalize UPDATE failed", error);
      return;
    }
    if (ownedRunAt != null && (!data || data.length === 0)) {
      console.error(
        "[notify-infl-digest] finalizeRun: 소유권을 잃어 최종 상태를 기록하지 못함(run_at 불일치) — 덮어쓰지 않음",
        digestDate, ownedRunAt, payload.status,
      );
    }
  };

  // [리뷰 반영 2/2026-08] 여기서부터 끝까지 전체를 감싼다 — 다른 세 다이제스트
  // (admin/brand/campaign-promo) 는 자물쇠를 잡은 뒤 로직 전체를 try 로 감싸
  // 예기치 못한 예외도 finalizeRun({status:'failed', error_message: 실제
  // 메시지})로 기록하는데, 이 함수는 개별 조회 3곳과 인플루언서별 루프만
  // 부분적으로 감싸고 섹션 분류·채널 라벨·이메일 일괄 조회 단계는 안 감쌌다.
  // 거기서 예외가 나면 자물쇠 행이 최초 "진행중" 그대로 남아, F-5 덕분에
  // 그날 안에 복구는 되지만 왜 실패했는지는 로그로만 알 수 있었다 — 이제는
  // admin_daily_digest_runs.error_message 에도 남는다.
  try {
    // 2. 어제 윈도우 applications 조회 (status 무관 — 4섹션 중 reviewed_at 분기)
    const { data: appsCreated, error: e1 } = await sb
      .from("applications")
      .select("id, user_id, campaign_id, status, created_at, reviewed_at")
      .gte("created_at", windowStartUtc.toISOString())
      .lt("created_at", windowEndUtc.toISOString());
    if (e1) {
      await finalizeRun({ status: "failed", total_influencers: 0, total_emails: 0, error_message: `apps_created: ${e1.message}` });
      return new Response(JSON.stringify({ error: e1.message, stage: "apps_created" }), {
        status: 500, headers: { "content-type": "application/json" },
      });
    }

    // 3. 어제 리뷰된 (승인·반려) applications 조회
    const { data: appsReviewed, error: e2 } = await sb
      .from("applications")
      .select("id, user_id, campaign_id, status, created_at, reviewed_at")
      .in("status", ["approved", "rejected"])
      .gte("reviewed_at", windowStartUtc.toISOString())
      .lt("reviewed_at", windowEndUtc.toISOString());
    if (e2) {
      await finalizeRun({ status: "failed", total_influencers: 0, total_emails: 0, error_message: `apps_reviewed: ${e2.message}` });
      return new Response(JSON.stringify({ error: e2.message, stage: "apps_reviewed" }), {
        status: 500, headers: { "content-type": "application/json" },
      });
    }

    // 4. 승인 상태 applications 중 마감 임박(D-5/D-1) 후보.
    //    ⚠️ [F-4] status='approved' 전체 — 하루 창이 없는 all-time 누적 조회다.
    //    캠페인 정보가 필요해 "일단 전체 approved 가져옴" 이라고 예전 주석에
    //    적혀 있던 그대로, 플랫폼이 자라 승인 응모가 1,000건을 넘으면
    //    PostgREST 가 나머지를 조용히 잘라버린다 — 그러면 마감 임박 안내가
    //    누락되고, 승인 알림 메일 자체도 그 뒤 사용자에게 안 나간다.
    //    fetchAllPaged 로 감싸 전건 확보. 정렬(id)은 페이지 경계 안정성을
    //    위한 것 — id 자체의 순서 의미는 없다(이후 로직은 Map/Set 으로만 쓴다).
    let appsApproved: AppRow[];
    try {
      appsApproved = await fetchAllPaged<AppRow>(() =>
        sb.from("applications")
          .select("id, user_id, campaign_id, status, created_at, reviewed_at")
          .eq("status", "approved")
          .order("id", { ascending: true })
      );
    } catch (e3) {
      const msg = (e3 as Error).message || String(e3);
      await finalizeRun({ status: "failed", total_influencers: 0, total_emails: 0, error_message: `apps_approved: ${msg}` });
      return new Response(JSON.stringify({ error: msg, stage: "apps_approved" }), {
        status: 500, headers: { "content-type": "application/json" },
      });
    }

    // 5. 캠페인 일괄 조회 (3 쿼리 결과의 union)
    const allCampIds = [
      ...new Set([
        ...((appsCreated || []).map((a) => a.campaign_id)),
        ...((appsReviewed || []).map((a) => a.campaign_id)),
        ...((appsApproved || []).map((a) => a.campaign_id)),
      ]),
    ];
    // ⚠️ [F-4] allCampIds 는 하루 창(appsCreated/appsReviewed) + all-time 누적
    //    (appsApproved, 위에서 fetchAllPaged 로 이미 전건 확보) 의 합집합이라
    //    이 in() 목록 자체가 커질 수 있다 — 같은 이유로 페이지 나눔 + 안정
    //    정렬(id) 적용. 실패해도 조회 자체는 계속 진행(warn 만) — 기존 관용
    //    (누락된 캠페인은 화면에 "-" 로 보일 뿐 발송을 막지 않던 기존 동작 유지).
    const campMap = new Map<string, CampRow>();
    if (allCampIds.length > 0) {
      try {
        const camps = await fetchAllPaged<CampRow>(() =>
          sb.from("campaigns")
            // product_price — レビュアー型の報酬欄「購入金額をペイバック（最大 ¥N）」の上限表示に使う。
            // 抜けると上限が消えたまま案内が届く（2026-08-05）。
            // event_mode — 행사 캠페인은 당선 섹션에서 뺀다(2026-08-24 결정 3, 아래 8번 분류 참조).
            //   빠뜨리면 제외 조건이 늘 거짓이 되어 방문객에게 「報酬 -」「提出期限」이 그대로 나간다.
            .select("id, campaign_no, title, recruit_type, reward, product_price, purchase_end, submission_end, proxy_purchase, channel, event_mode")
            .in("id", allCampIds)
            .order("id", { ascending: true })
        );
        camps.forEach((c) => campMap.set(c.id, c));
      } catch (e) {
        console.warn("[notify-infl-digest] campaign lookup failed", (e as Error).message);
      }
    }

    // 6. 마감 임박 후보의 deliverables 일괄 조회 (미제출 행만 임박 메일 대상)
    //    kinds        : 영수증(receipt)/게시물(post) 종류 존재 여부 판정용 (기존)
    //    reviewChannels: 리뷰 인증샷(review_image) 채널별 존재 여부 판정용 (2026-08 신설).
    //      ⚠️ pending·approved 만 조회하므로, 반려(rejected)만 있는 채널은 이 Set 에 없음
    //      → 「없음」으로 간주해 재제출 안내 대상이 된다(사양서 §설계 단계2 대상조건 참조).
    //    ⚠️ [F-4] approvedAppIds 는 all-time 누적(appsApproved) 에서 나온 값이라
    //    응모가 쌓일수록 이 조회 결과도 함께 늘어난다 — 페이지 나눔 + 안정 정렬(id).
    const approvedAppIds = (appsApproved || []).map((a) => a.id);
    interface DelivInfo {
      kinds: Set<string>;
      reviewChannels: Set<string>;
      postChannels: Set<string>;
    }
    const delivByApp = new Map<string, DelivInfo>(); // app_id → 제출 현황
    if (approvedAppIds.length > 0) {
      try {
        const delivs = await fetchAllPaged<DelivRow>(() =>
          sb.from("deliverables")
            .select("application_id, kind, status, post_channel")
            .in("application_id", approvedAppIds)
            .in("status", ["pending", "approved"])
            .order("id", { ascending: true })
        );
        delivs.forEach((d) => {
          let info = delivByApp.get(d.application_id);
          if (!info) {
            info = { kinds: new Set(), reviewChannels: new Set(), postChannels: new Set() };
            delivByApp.set(d.application_id, info);
          }
          info.kinds.add(d.kind);
          if (d.kind === "review_image" && d.post_channel) info.reviewChannels.add(d.post_channel);
          // 게시물도 채널별로 — 시딩·방문형이 요구한 채널 전부를 내야 인증 성공이다
          //   (마이그레이션 331). 예전에는 「게시물이 하나라도 있으면」 안내를 멈춰서,
          //   2채널 중 1채널만 낸 사람은 나머지 마감 안내를 **한 통도 못 받았다.**
          if (d.kind === "post" && d.post_channel) info.postChannels.add(d.post_channel);
        });
      } catch (e) {
        console.warn("[notify-infl-digest] deliverable lookup failed", (e as Error).message);
      }
    }

    // 7. 마감 임박 발송 이력 (중복 차단) 일괄 조회
    //    ⚠️ [F-4] approvedCampIds 로 걸러도 이 표는 발송 이력이 계속 쌓이는
    //    구조(같은 캠페인·인플·kind·d_minus·deadline_date 조합마다 1행, 캠페인이
    //    오래 돌수록 늘어남) — 페이지 나눔 + 안정 정렬(id).
    //    [F-9] 열쇠에 deadline_date 를 포함한다 — 마감일을 연장한 뒤에는
    //    "이전 마감일 기준으로 이미 보냈다"는 이력이 새 마감일의 D-5/D-1 안내를
    //    막으면 안 된다. 마이그레이션 322 로 DB UNIQUE 제약도 5-튜플로 확장했다
    //    (이 키가 서버 제약과 어긋나면 11번의 벌크 INSERT 가 23505 로 막힌다).
    const sentMap = new Set<string>(); // key: influencer_id|campaign_id|kind|d_minus|deadline_date
    if (approvedAppIds.length > 0) {
      const approvedCampIds = [...new Set((appsApproved || []).map((a) => a.campaign_id))];
      try {
        const sent = await fetchAllPaged<SentRow>(() =>
          sb.from("deadline_reminder_email_sent")
            .select("influencer_id, campaign_id, kind, d_minus, deadline_date")
            .in("campaign_id", approvedCampIds)
            .order("id", { ascending: true })
        );
        sent.forEach((s) => {
          sentMap.add(`${s.influencer_id}|${s.campaign_id}|${s.kind}|${s.d_minus}|${s.deadline_date}`);
        });
      } catch (e) {
        console.warn("[notify-infl-digest] deadline reminder log lookup failed", (e as Error).message);
      }
    }

    // 8. 인플루언서별 4섹션 분류
    interface SectionAcc {
      received: AppRow[];
      approved: AppRow[];
      rejected: AppRow[];
      deadline: {
        kind: "receipt" | "post" | "review_image";
        app: AppRow;
        deadlineDate: string;
        dMinus: number;
        // review_image 전용 — 남은(미완료) 채널 코드 목록 + 캠페인 요구 채널 총 개수.
        // 요구 채널이 2개 이상일 때만 메일 문구에 채널명을 병기한다(확정된 결정, 사양서 참조).
        missingChannels?: string[];
        requiredChannelCount?: number;
      }[];
    }
    const perInfluencer = new Map<string, SectionAcc>();
    const acc = (uid: string): SectionAcc => {
      if (!perInfluencer.has(uid)) perInfluencer.set(uid, { received: [], approved: [], rejected: [], deadline: [] });
      return perInfluencer.get(uid)!;
    };

    (appsCreated || []).forEach((a: AppRow) => acc(a.user_id).received.push(a));
    (appsReviewed || []).forEach((a: AppRow) => {
      if (a.status === "approved") {
        // 【행사 당선은 이 메일에서 뺀다】 — 2026-08-24 결정 3 (조각 S-14)
        //   당선 섹션은 「報酬」(보수)와 「提出期限」(결과물 제출 마감)을 그리는데,
        //   행사(오프라인 팝업 방문 예약) 방문객은 **보수도 결과물도 없다.**
        //   마이그레이션 283 이 앱 알림(application_approved)을 행사에서 막을 때 든
        //   사유 ①(「승인 알림 문구가 결과물 제출을 요구해 방문객에게 부적합」)이
        //   **메일에는 그대로 남아 있었다** — 여기서 같은 기준으로 맞춘다.
        //
        // ⚠️ 기준은 `event_mode`(행사 전체)다. 선정형만이 아니다 — 선착순형 행사
        //    당선자도 보수·결과물이 없고, 283 과 기준이 갈리면 앱 알림과 메일이
        //    서로 다른 말을 하게 된다.
        // ⚠️ **낙첨 섹션(rejected)은 일부러 그대로 둔다.** 캠페인 번호·제목·심사 시각과
        //    「他のキャンペーンを見る」(다른 캠페인 보기)뿐이라 방문객에게도 맞고,
        //    행사 낙선자에게 가는 통지 중 하나다(결정 1).
        // ⚠️ 여기서 빼는 이유(렌더 단계가 아니라) — 제목·본문 요약이 `sec.approved.length`
        //    로 건수를 세므로, 그리는 자리에서만 빼면 「承認 1件」이라 적힌 메일에 그
        //    섹션이 없는 상태가 된다.
        // ⚠️ 캠페인 조회가 실패하면(campMap 미적재, 위 5번은 warn 만 하고 계속 간다)
        //    camp 가 undefined 라 이 조건이 거짓이 되어 **종전대로 발송**한다.
        //    조회를 못 했다는 이유로 일반 캠페인 당선 안내를 삼키지 않는다.
        const camp = campMap.get(a.campaign_id);
        if (camp?.event_mode === true) return;
        acc(a.user_id).approved.push(a);
      } else if (a.status === "rejected") acc(a.user_id).rejected.push(a);
    });

    // 마감 임박 — appsApproved 전체에서 D-5/D-1 + 미제출 + 이력 없는 것만 추출
    //
    // ⚠️ 모집 형식별 제출물 대응 (2026-08-04 사양서 docs/specs/2026-08-04-deadline-reminder-recruit-type-fix.md):
    //   - 리뷰어(monitor), 일반         : 영수증(receipt) + 채널별 리뷰 인증샷(review_image) 전부
    //   - 리뷰어(monitor), 가구매(proxy_purchase) : 영수증(receipt)만 (인증샷 미요구)
    //   - 시딩(gifting)·방문형(visit)   : 게시물(post)만
    //   리뷰어형은 게시물을 제출하는 경로가 없다 — 게시물 마감 안내를 리뷰어형에 보내면
    //   낼 수 없는 것을 독촉하는 오발송이 된다(실제 발생, 운영 1,022건).
    //   인증 성공 판정의 단일 소스는 dev/js/admin-deliverables.js 의 computeCertStatus —
    //   이 블록은 그 판정을 서버(발송 시점)에서 재현한 것이므로, 어느 한쪽을 고칠 때
    //   반드시 다른 쪽도 함께 검토할 것.
    (appsApproved || []).forEach((a: AppRow) => {
      const camp = campMap.get(a.campaign_id);
      if (!camp) return;
      const delivInfo = delivByApp.get(a.id) || { kinds: new Set<string>(), reviewChannels: new Set<string>(), postChannels: new Set<string>() };
      const delivKinds = delivInfo.kinds;

      // 영수증 (monitor 한정 — 리뷰어형은 가구매 여부와 무관하게 항상 영수증 제출)
      // ⚠️ 마감일은 **결과물 제출 마감일**이다(2026-08-11). 구매 종료일이 아니다 —
      //   08-06 부터 신규 리뷰어형은 구매 기간을 모집 기간과 같게 저장하므로, 구매 종료일을
      //   쓰면 **실제보다 2주 이른 날짜로 독촉**하게 된다(캠페인 상세 화면과 어긋남).
      //   제출 마감일이 비어 있는 옛 캠페인만 구매 종료일로 물러선다(운영 실측 1건).
      const receiptDeadline = camp.submission_end || camp.purchase_end;
      if (camp.recruit_type === "monitor" && receiptDeadline && !delivKinds.has("receipt")) {
        const d = dateDiffDays(receiptDeadline, todayDate);
        if (d === 5 || d === 1) {
          // [F-9] deadline_date 를 열쇠에 포함 — 마감 연장 시 옛 마감일로 이미 보낸 이력이
          // 새 마감일의 재안내를 막지 않게 한다.
          // ⚠️ 이번 기준 변경으로 열쇠가 바뀌어, 구매 종료일 기준으로 이미 받은 사람에게
          //    **한 번 더 나간다.** 두 번째가 맞는 날짜라 의도된 결과다(사양서 결정 4) —
          //    배포 다음 날 아침 발송량이 느는 것을 사고로 오해하지 말 것.
          const key = `${a.user_id}|${a.campaign_id}|receipt|${d}|${receiptDeadline}`;
          if (!sentMap.has(key)) {
            acc(a.user_id).deadline.push({ kind: "receipt", app: a, deadlineDate: receiptDeadline, dMinus: d });
          }
        }
      }

      // 결과물(게시물) — 시딩(gifting)·방문형(visit) 전용. 리뷰어형(monitor)은 게시물 제출 경로가 없다.
      // (submission_end 만 사용 — post_deadline 은 마이그레이션 129 에서 제거됨)
      //
      // 🔴 행사(event_mode)는 제외한다 — 행사도 recruit_type='visit' 이라 이 조건에 걸린다.
      //   방문객은 게시물을 내지 않으므로 「投稿物 … まで」(게시물 … 까지)는 **하지도 않을 일을
      //   독촉하는** 안내가 된다. 당선 섹션의 제외(2026-08-24 결정 3)와 같은 판단이고 기준도
      //   같다(선착순형 행사도 마찬가지라 event_mode 로 가른다).
      //   ⚠️ 이 자리는 당선 섹션과 **다른 경로**다 — 저 위 필터는 「어제 심사된」 목록(appsReviewed)을
      //      보고, 여기는 **누적 승인 전체**(appsApproved)를 본다. 그래서 저기만 고치면 여기는 안 걸린다.
      //   ⚠️ 지금 행사 캠페인은 submission_end 가 비어 있어 잠자고 있을 뿐, **막는 것은 없었다.**
      //      이 저장소는 정확히 같은 유형(모집 형식을 안 가린 마감 독촉)으로 운영에서 1,022건을
      //      오발송한 적이 있다 — docs/specs/2026-08-04-deadline-reminder-recruit-type-fix.md
      if (
        !camp.event_mode &&
        (camp.recruit_type === "gifting" || camp.recruit_type === "visit") &&
        camp.submission_end
      ) {
        // ⚠️ 「게시물이 하나라도 있으면 안 보낸다」가 아니다 — 요구한 채널 **전부**를 내야
        //   인증 성공이므로(마이그레이션 331), 아직 안 낸 채널이 하나라도 있으면 안내한다.
        //   채널이 기록 안 된 옛 캠페인은 채널별로 따질 근거가 없어 종전대로 「하나라도 있으면 멈춤」.
        const requiredPostChannels = (camp.channel || "").split(",").map((c) => c.trim()).filter(Boolean);
        const missingPost = requiredPostChannels.length > 0
          ? requiredPostChannels.filter((ch) => !delivInfo.postChannels.has(ch))
          : (delivKinds.has("post") ? [] : ["*"]);
        if (missingPost.length > 0) {
          const d = dateDiffDays(camp.submission_end, todayDate);
          if (d === 5 || d === 1) {
            // [F-9] deadline_date(camp.submission_end) 를 열쇠에 포함 — 위 receipt 와 동일 이유.
            const key = `${a.user_id}|${a.campaign_id}|post|${d}|${camp.submission_end}`;
            if (!sentMap.has(key)) {
              acc(a.user_id).deadline.push({ kind: "post", app: a, deadlineDate: camp.submission_end, dMinus: d });
            }
          }
        }
      }

      // 리뷰 인증샷(review_image) — 리뷰어형(monitor) 전용, 가구매(proxy_purchase) 캠페인은 제외
      // (가구매는 영수증만 요구 — computeCertStatus 의 proxy_purchase 분기와 동일 기준).
      // 대상 판정 — 캠페인 요구 채널 중 pending·approved 인증샷 행이 없는 채널이 하나라도 있으면 대상
      // (채널 단위 판정. 반려만 있는 채널은 「없음」으로 보아 재제출을 유도한다).
      if (camp.recruit_type === "monitor" && !camp.proxy_purchase && camp.submission_end) {
        const requiredChannels = (camp.channel || "")
          .split(",").map((c) => c.trim()).filter(Boolean);
        // 캠페인에 요구 채널이 하나도 없으면(데이터 미비) 어느 채널이 미완료인지 판정 불가 —
        // 잘못된 안내를 보내느니 발송하지 않는다.
        if (requiredChannels.length > 0) {
          const missingChannels = requiredChannels.filter((ch) => !delivInfo.reviewChannels.has(ch));
          if (missingChannels.length > 0) {
            const d = dateDiffDays(camp.submission_end, todayDate);
            if (d === 5 || d === 1) {
              // [F-9] deadline_date(camp.submission_end) 를 열쇠에 포함 — 위 receipt 와 동일 이유.
              const key = `${a.user_id}|${a.campaign_id}|review_image|${d}|${camp.submission_end}`;
              if (!sentMap.has(key)) {
                acc(a.user_id).deadline.push({
                  kind: "review_image",
                  app: a,
                  deadlineDate: camp.submission_end,
                  dMinus: d,
                  missingChannels,
                  requiredChannelCount: requiredChannels.length,
                });
              }
            }
          }
        }
      }
    });

    // 4섹션 모두 0건인 인플루언서 제거
    for (const [uid, sec] of perInfluencer.entries()) {
      if (sec.received.length === 0 && sec.approved.length === 0 && sec.rejected.length === 0 && sec.deadline.length === 0) {
        perInfluencer.delete(uid);
      }
    }

    if (perInfluencer.size === 0) {
      await finalizeRun({ status: "skipped_no_data", total_influencers: 0, total_emails: 0 });
      return new Response(JSON.stringify({ ok: true, skipped: true, reason: "no_data", digestDate }), {
        status: 200, headers: { "content-type": "application/json" },
      });
    }

    // 8.5. 리뷰 인증샷 안내 채널명 조회 — 캠페인 요구 채널이 2개 이상일 때만 남은 채널명을
    //      메일 문구에 병기하므로(확정된 결정), 그런 후보가 있을 때만 조회한다.
    //      라벨(name_ja)의 단일 소스는 lookup_values(kind='channel') — dev 화면과 동일.
    const channelLabelMap = new Map<string, string>();
    {
      const needsChannelLabel = [...perInfluencer.values()].some((sec) =>
        sec.deadline.some((d) => d.kind === "review_image" && (d.requiredChannelCount || 0) >= 2)
      );
      if (needsChannelLabel) {
        const { data: channels } = await sb
          .from("lookup_values")
          .select("code, name_ja")
          .eq("kind", "channel");
        (channels || []).forEach((c: { code: string; name_ja: string | null }) => {
          if (c.name_ja) channelLabelMap.set(c.code, c.name_ja);
        });
      }
    }

    // 9. 인플루언서 이메일 일괄 조회 (auth.users)
    const targetUserIds = [...perInfluencer.keys()];
    const emailMap = new Map<string, string>();
    const emailResults = await Promise.all(targetUserIds.map((id) => sb.auth.admin.getUserById(id)));
    emailResults.forEach((r, idx) => {
      if (!r.error && r.data?.user?.email) emailMap.set(targetUserIds[idx], r.data.user.email);
    });

    // 10. 인플루언서별 렌더링·발송
    //
    // [리뷰 반영 3] ⚠️ 잔여 위험 — "누구에게 다이제스트를 보냈는지" 개별
    // 기록이 없다. sendBrevoEmail 은 인플루언서 uid 마다 바로바로 나가지만,
    // 그 결과를 적는 표(deadline_reminder_email_sent)는 이 루프가 "다 끝난
    // 뒤" 11번에서 한꺼번에 벌크 INSERT 된다 — 게다가 그 표는 섹션4(마감
    // 임박)에 해당하는 사람만 기록하고, 섹션1~3(신규응모·승인·반려)만 있는
    // 사람은 애초에 어디에도 기록되지 않는다. 그래서 이 루프 도중 함수가
    // 죽으면, 이미 메일을 받은 사람 중 상당수(특히 섹션1~3만 해당하는
    // 사람 전원)는 재시도 때도 "안 받은 사람"으로 다시 뽑혀 다이제스트를
    // 통째로 다시 받는다. F-5(쿨다운·소유권 검증)는 "이 함수를 두 프로세스가
    // 동시에 돌리는 것"만 막을 뿐, 이 부분 발송 뒤 재시도 중복까지는 못
    // 막는다 — 즉 이 잔여 위험은 관리자·브랜드·홍보메일 관리자요약과
    // 같은 종류이지만, 이 함수까지 합치면 세 곳이 아니라 네 곳이다
    // (관리자 다이제스트·브랜드 다이제스트·홍보 메일의 관리자 요약 + 이 함수).
    // 운영자가 이 함수를 수동으로 다시 부르기 전에는 Brevo 발송 이력으로
    // 직전 실행이 몇 명(어느 uid)까지 보냈는지 먼저 확인할 것 — 「F-5로
    // 재시도가 안전해졌다」는 자물쇠 자체의 동시 실행 얘기지, 이 루프의
    // 부분 발송 뒤 재시도 중복까지 막아주는 게 아니다.
    const mainTpl = loadTemplate("influencer-daily-digest");
    const rowReceivedTpl = loadTemplate("influencer-daily-digest.row-received");
    const rowApprovedTpl = loadTemplate("influencer-daily-digest.row-approved");
    const rowRejectedTpl = loadTemplate("influencer-daily-digest.row-rejected");
    const rowDeadlineTpl = loadTemplate("influencer-daily-digest.row-deadline");
    const publicAppUrl = env("PUBLIC_APP_URL", "https://globalreverb.com").replace(/\/$/, "");
    const todayJp = formatJpDateFull(new Date(`${todayDate}T00:00:00+09:00`));

    let sentCount = 0;
    const sentInserts: { influencer_id: string; campaign_id: string; kind: string; d_minus: number; deadline_date: string }[] = [];
    const sentDuringRun = new Set<string>(); // 같은 인플 같은 (kind,d_minus) 중복 INSERT 차단

    for (const [uid, sec] of perInfluencer.entries()) {
      const email = emailMap.get(uid);
      if (!email) {
        console.warn("[notify-infl-digest] no email for", uid);
        continue;
      }
      try {
        // 섹션 1 (received)
        let section1 = "";
        if (sec.received.length > 0) {
          const rows = sec.received.map((a) => {
            const c = campMap.get(a.campaign_id);
            return render(rowReceivedTpl, {
              campaign_no: escapeHtml(`【${c?.campaign_no ?? ""}】`),
              campaign_title: escapeHtml(c?.title ?? ""),
              recruit_type_jp: escapeHtml(recruitTypeJp(c?.recruit_type ?? null)),
              applied_at_jst: escapeHtml(formatJpDateTime(a.created_at)),
            });
          }).join("");
          section1 =
            `<h3 style="font-size:14px;color:#333;border-left:4px solid #C8789C;padding-left:10px;margin:24px 0 12px">新規応募の受付 (${sec.received.length}件)</h3>` + rows;
        }

        // 섹션 2 (approved)
        let section2 = "";
        if (sec.approved.length > 0) {
          const rows = sec.approved.map((a) => {
            const c = campMap.get(a.campaign_id);
            // 報酬欄 — 募集形式で分ける（2026-08-05）。
            //   レビュアー型(monitor) は精算額が「レシート実支払額（商品価格を上限に切り捨て）」
            //   なので、campaigns.reward は計算に一切使われない（マイグレーション300）。
            //   ここを分けないと当選者に「報酬 -」とだけ届き、いくら戻るのかが伝わらない。
            //   ⚠️ レビュアー型に現金報酬を足して表示してはいけない — 支払われない金額の約束になる。
            const price = Number(c?.product_price ?? 0);
            const rewardStr = c?.recruit_type === "monitor"
              ? (price > 0
                  ? `購入金額をペイバック（最大 ¥${price.toLocaleString("en-US")}）`
                  : "購入金額をペイバック")
              : (c?.reward ? `¥${c.reward.toLocaleString("en-US")}` : "-");
            // 提出期限 표기 — 모집 형식별 분기(2026-08-04 사양서 §설계 단계1-B).
            //   レビュー認証写真(모니터형)/투고물(시딩·방문형)이 각자 요구하는 제출물만 표시.
            //   리뷰어형은 게시물(投稿物) 제출 경로가 없으므로 절대 여기 섞지 않는다.
            const deadlineParts: string[] = [];
            if (c?.recruit_type === "monitor") {
              // ⚠️ 영수증도 **결과물 제출 마감일**이다(2026-08-11) — 구매 종료일이 아니다.
              //   구매 종료일을 쓰면 실제보다 2주 이른 날짜를 말하게 된다(캠페인 상세와 어긋남).
              //   제출 마감일이 비어 있는 옛 캠페인만 구매 종료일로 물러선다.
              const dl = c.submission_end || c.purchase_end;
              if (dl) {
                // 영수증과 리뷰 인증샷이 같은 날짜이므로 **한 줄로 합친다**(사양서 결정 3).
                //   캠페인 상세 화면도 「영수증·게시물 인증샷 제출 마감일」로 한 번만 말한다.
                //   가구매(proxy_purchase)는 인증샷을 안 내므로 영수증만.
                const what = c.proxy_purchase ? "レシート" : "レシート・レビュー認証写真";
                deadlineParts.push(`${what} ${formatJpDateShort(dl)} まで`);
              }
            } else if ((c?.recruit_type === "gifting" || c?.recruit_type === "visit") && c?.submission_end) {
              deadlineParts.push(`投稿物 ${formatJpDateShort(c.submission_end)} まで`);
            }
            const dlRow = deadlineParts.length > 0
              ? `<tr><td style="padding:3px 0;color:#888;vertical-align:top">提出期限</td><td style="padding:3px 0">${escapeHtml(deadlineParts.join(" · "))}</td></tr>`
              : "";
            return render(rowApprovedTpl, {
              campaign_no: escapeHtml(`【${c?.campaign_no ?? ""}】`),
              campaign_title: escapeHtml(c?.title ?? ""),
              recruit_type_jp: escapeHtml(recruitTypeJp(c?.recruit_type ?? null)),
              reviewed_at_jst: escapeHtml(a.reviewed_at ? formatJpDateTime(a.reviewed_at) : "-"),
              reward: escapeHtml(rewardStr),
              deadline_summary_row: dlRow,
            });
          }).join("");
          section2 =
            `<h3 style="font-size:14px;color:#333;border-left:4px solid #16A34A;padding-left:10px;margin:24px 0 12px">応募が承認されました (${sec.approved.length}件)</h3>` +
            rows +
            `<p style="margin:8px 0 0"><a href="${publicAppUrl}/#mypage-applications" style="color:#C8789C;font-size:12px">活動管理で提出を始める →</a></p>`;
        }

        // 섹션 3 (rejected)
        let section3 = "";
        if (sec.rejected.length > 0) {
          const rows = sec.rejected.map((a) => {
            const c = campMap.get(a.campaign_id);
            return render(rowRejectedTpl, {
              campaign_no: escapeHtml(`【${c?.campaign_no ?? ""}】`),
              campaign_title: escapeHtml(c?.title ?? ""),
              reviewed_at_jst: escapeHtml(a.reviewed_at ? formatJpDateTime(a.reviewed_at) : "-"),
            });
          }).join("");
          section3 =
            `<h3 style="font-size:14px;color:#333;border-left:4px solid #999;padding-left:10px;margin:24px 0 12px">応募結果のお知らせ (${sec.rejected.length}件)</h3>` +
            rows +
            `<p style="margin:8px 0 0"><a href="${publicAppUrl}/#campaigns" style="color:#C8789C;font-size:12px">他のキャンペーンを見る →</a></p>`;
        }

        // 섹션 4 (deadline)
        let section4 = "";
        if (sec.deadline.length > 0) {
          const rows = sec.deadline.map((d) => {
            const c = campMap.get(d.app.campaign_id);
            const kindLabel = d.kind === "receipt"
              ? "レシート"
              : d.kind === "review_image"
                ? reviewImageKindLabel(d.missingChannels, d.requiredChannelCount, channelLabelMap)
                : "投稿物";
            const dMinusLabel = `D-${d.dMinus}`;
            const dColor = d.dMinus === 1 ? "#E8344E" : "#A06A14";
            const dBg = d.dMinus === 1 ? "#FFE4E9" : "#FFF0D6";
            return render(rowDeadlineTpl, {
              campaign_no: escapeHtml(`【${c?.campaign_no ?? ""}】`),
              campaign_title: escapeHtml(c?.title ?? ""),
              kind_label_jp: escapeHtml(kindLabel),
              deadline_jp: escapeHtml(`${formatJpDateShort(d.deadlineDate)} (${dMinusLabel})`),
              d_minus_label: escapeHtml(dMinusLabel),
              d_minus_color: dColor,
              d_minus_bg: dBg,
              submit_url: `${publicAppUrl}/#mypage-applications`,
            });
          }).join("");
          section4 =
            `<h3 style="font-size:14px;color:#333;border-left:4px solid #A06A14;padding-left:10px;margin:24px 0 12px">提出期限が近づいています (${sec.deadline.length}件)</h3>` + rows;
        }

        const totalCount = sec.received.length + sec.approved.length + sec.rejected.length + sec.deadline.length;
        const html = render(mainTpl, {
          today_jp: escapeHtml(todayJp),
          total_count: String(totalCount),
          section_received_html: section1,
          section_approved_html: section2,
          section_rejected_html: section3,
          section_deadline_html: section4,
          public_app_url: publicAppUrl,
        });
        const subject = `【REVERB】本日の応募状況のお知らせ (${todayJp})`;
        const textLines = [
          `本日の応募状況のお知らせ (${todayJp})`,
          `${totalCount}件のお知らせ`,
          "",
          sec.received.length > 0 ? `新規応募の受付 ${sec.received.length}件` : "",
          sec.approved.length > 0 ? `承認 ${sec.approved.length}件` : "",
          sec.rejected.length > 0 ? `応募結果 ${sec.rejected.length}件` : "",
          sec.deadline.length > 0 ? `提出期限が近づいています ${sec.deadline.length}件` : "",
          "",
          `応募履歴: ${publicAppUrl}/#mypage-applications`,
        ].filter(Boolean);
        const text = textLines.join("\n");

        await sendBrevoEmail({
          to: [{ email }],
          subject,
          htmlContent: html,
          textContent: text,
        });
        sentCount++;

        // 마감 임박 발송 이력 누적 (벌크 INSERT 용)
        sec.deadline.forEach((d) => {
          // 마감일까지 포함한다 — 저장할 행의 열쇠(마이그레이션 322 의 5개 조합)와 같은 모양이어야
          //   이 안에서 거른 것과 데이터베이스가 거부하는 것이 어긋나지 않는다.
          //   지금은 캠페인 정보를 실행당 한 번만 읽어 한 실행 안에서 마감일이 바뀔 수 없지만,
          //   그 전제가 깨지면 조용히 갈린다.
          const dedupKey = `${uid}|${d.app.campaign_id}|${d.kind}|${d.dMinus}|${d.deadlineDate}`;
          if (sentDuringRun.has(dedupKey)) return;
          sentDuringRun.add(dedupKey);
          sentInserts.push({
            influencer_id: uid,
            campaign_id: d.app.campaign_id,
            kind: d.kind,
            d_minus: d.dMinus,
            deadline_date: d.deadlineDate,
          });
        });
      } catch (e) {
        console.error("[notify-infl-digest] per-influencer failed", uid, (e as Error).message);
        // 한 명 실패 가 다음 명 발송 차단 안 함
      }
    }

    // 11. 마감 임박 이력 벌크 INSERT (다음 D-N 재발송 차단)
    if (sentInserts.length > 0) {
      const { error: insErr } = await sb.from("deadline_reminder_email_sent").insert(sentInserts);
      if (insErr) {
        // 23505 동시성 충돌은 무시 (다른 cron 가 같은 시점에 들어왔을 때)
        if ((insErr as { code?: string }).code !== "23505") {
          console.error("[notify-infl-digest] reminder log insert failed", insErr);
        }
      }
    }

    // 12. 성공 로그
    await finalizeRun({
      status: "sent",
      total_influencers: perInfluencer.size,
      total_emails: sentCount,
    });

    return new Response(
      JSON.stringify({
        ok: true,
        digestDate,
        total_influencers: perInfluencer.size,
        total_emails: sentCount,
        reminder_inserts: sentInserts.length,
      }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  } catch (e) {
    // [리뷰 반영 2] 다른 세 다이제스트와 동일한 안전망 — 위에서 개별적으로
    // 처리하지 못한 예기치 못한 예외(섹션 분류·채널 라벨 조회·이메일 일괄
    // 조회 등)도 여기서 잡아 finalizeRun 으로 실제 사유를 남긴다.
    const msg = (e as Error).message || "unknown error";
    console.error("[notify-infl-digest] unexpected error", msg);
    try {
      await finalizeRun({ status: "failed", total_influencers: 0, total_emails: 0, error_message: `unexpected: ${msg}` });
    } catch (_finalizeErr) {
      console.error("[notify-infl-digest] could not finalize after unexpected error");
    }
    return new Response(JSON.stringify({ error: msg, stage: "unexpected" }), {
      status: 500, headers: { "content-type": "application/json" },
    });
  }
});
