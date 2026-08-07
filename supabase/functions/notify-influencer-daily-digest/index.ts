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

// digest_runs 로그 INSERT (23505=UNIQUE 위반은 duplicate)
async function logRun(
  sb: ReturnType<typeof createClient>,
  payload: {
    digest_date: string;
    status: "sent" | "skipped_no_data" | "failed";
    total_influencers: number;
    total_emails: number;
    error_message?: string | null;
  },
): Promise<{ duplicate: boolean }> {
  const { error } = await sb
    .from("influencer_daily_digest_runs")
    .insert({
      digest_date: payload.digest_date,
      status: payload.status,
      total_influencers: payload.total_influencers,
      total_emails: payload.total_emails,
      error_message: payload.error_message ?? null,
    });
  if (error) {
    if ((error as { code?: string }).code === "23505") {
      return { duplicate: true };
    }
    console.error("[notify-infl-digest] logRun failed", error);
  }
  return { duplicate: false };
}

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

  // 1. 같은 digest_date 가 이미 처리됐는지 사전 확인
  {
    const { data: prior } = await sb
      .from("influencer_daily_digest_runs")
      .select("id, status, run_at")
      .eq("digest_date", digestDate)
      .maybeSingle();
    if (prior) {
      return new Response(
        JSON.stringify({ ok: true, skipped: true, reason: "already_processed", digestDate, prior }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    }
  }

  // 2. 어제 윈도우 applications 조회 (status 무관 — 4섹션 중 reviewed_at 분기)
  const { data: appsCreated, error: e1 } = await sb
    .from("applications")
    .select("id, user_id, campaign_id, status, created_at, reviewed_at")
    .gte("created_at", windowStartUtc.toISOString())
    .lt("created_at", windowEndUtc.toISOString());
  if (e1) {
    await logRun(sb, { digest_date: digestDate, status: "failed", total_influencers: 0, total_emails: 0, error_message: `apps_created: ${e1.message}` });
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
    await logRun(sb, { digest_date: digestDate, status: "failed", total_influencers: 0, total_emails: 0, error_message: `apps_reviewed: ${e2.message}` });
    return new Response(JSON.stringify({ error: e2.message, stage: "apps_reviewed" }), {
      status: 500, headers: { "content-type": "application/json" },
    });
  }

  // 4. 승인 상태 applications 중 마감 임박(D-5/D-1) 후보 — 캠페인 정보가 필요해 일단 전체 approved 가져옴
  const { data: appsApproved, error: e3 } = await sb
    .from("applications")
    .select("id, user_id, campaign_id, status, created_at, reviewed_at")
    .eq("status", "approved");
  if (e3) {
    await logRun(sb, { digest_date: digestDate, status: "failed", total_influencers: 0, total_emails: 0, error_message: `apps_approved: ${e3.message}` });
    return new Response(JSON.stringify({ error: e3.message, stage: "apps_approved" }), {
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
  const campMap = new Map<string, CampRow>();
  if (allCampIds.length > 0) {
    const { data: camps } = await sb
      .from("campaigns")
      // product_price — レビュアー型の報酬欄「購入金額をペイバック（最大 ¥N）」の上限表示に使う。
      // 抜けると上限が消えたまま案内が届く（2026-08-05）。
      .select("id, campaign_no, title, recruit_type, reward, product_price, purchase_end, submission_end, proxy_purchase, channel")
      .in("id", allCampIds);
    (camps || []).forEach((c: CampRow) => campMap.set(c.id, c));
  }

  // 6. 마감 임박 후보의 deliverables 일괄 조회 (미제출 행만 임박 메일 대상)
  //    kinds        : 영수증(receipt)/게시물(post) 종류 존재 여부 판정용 (기존)
  //    reviewChannels: 리뷰 인증샷(review_image) 채널별 존재 여부 판정용 (2026-08 신설).
  //      ⚠️ pending·approved 만 조회하므로, 반려(rejected)만 있는 채널은 이 Set 에 없음
  //      → 「없음」으로 간주해 재제출 안내 대상이 된다(사양서 §설계 단계2 대상조건 참조).
  const approvedAppIds = (appsApproved || []).map((a) => a.id);
  interface DelivInfo {
    kinds: Set<string>;
    reviewChannels: Set<string>;
  }
  const delivByApp = new Map<string, DelivInfo>(); // app_id → 제출 현황
  if (approvedAppIds.length > 0) {
    const { data: delivs } = await sb
      .from("deliverables")
      .select("application_id, kind, status, post_channel")
      .in("application_id", approvedAppIds)
      .in("status", ["pending", "approved"]);
    (delivs || []).forEach((d: DelivRow) => {
      let info = delivByApp.get(d.application_id);
      if (!info) {
        info = { kinds: new Set(), reviewChannels: new Set() };
        delivByApp.set(d.application_id, info);
      }
      info.kinds.add(d.kind);
      if (d.kind === "review_image" && d.post_channel) info.reviewChannels.add(d.post_channel);
    });
  }

  // 7. 마감 임박 발송 이력 (중복 차단) 일괄 조회
  const sentMap = new Set<string>(); // key: influencer_id|campaign_id|kind|d_minus
  if (approvedAppIds.length > 0) {
    const approvedCampIds = [...new Set((appsApproved || []).map((a) => a.campaign_id))];
    const { data: sent } = await sb
      .from("deadline_reminder_email_sent")
      .select("influencer_id, campaign_id, kind, d_minus")
      .in("campaign_id", approvedCampIds);
    (sent || []).forEach((s: SentRow) => {
      sentMap.add(`${s.influencer_id}|${s.campaign_id}|${s.kind}|${s.d_minus}`);
    });
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
    if (a.status === "approved") acc(a.user_id).approved.push(a);
    else if (a.status === "rejected") acc(a.user_id).rejected.push(a);
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
    const delivInfo = delivByApp.get(a.id) || { kinds: new Set<string>(), reviewChannels: new Set<string>() };
    const delivKinds = delivInfo.kinds;

    // 영수증 (monitor 한정 — 리뷰어형은 가구매 여부와 무관하게 항상 영수증 제출)
    if (camp.recruit_type === "monitor" && camp.purchase_end && !delivKinds.has("receipt")) {
      const d = dateDiffDays(camp.purchase_end, todayDate);
      if (d === 5 || d === 1) {
        const key = `${a.user_id}|${a.campaign_id}|receipt|${d}`;
        if (!sentMap.has(key)) {
          acc(a.user_id).deadline.push({ kind: "receipt", app: a, deadlineDate: camp.purchase_end, dMinus: d });
        }
      }
    }

    // 결과물(게시물) — 시딩(gifting)·방문형(visit) 전용. 리뷰어형(monitor)은 게시물 제출 경로가 없다.
    // (submission_end 만 사용 — post_deadline 은 마이그레이션 129 에서 제거됨)
    if (
      (camp.recruit_type === "gifting" || camp.recruit_type === "visit") &&
      camp.submission_end && !delivKinds.has("post")
    ) {
      const d = dateDiffDays(camp.submission_end, todayDate);
      if (d === 5 || d === 1) {
        const key = `${a.user_id}|${a.campaign_id}|post|${d}`;
        if (!sentMap.has(key)) {
          acc(a.user_id).deadline.push({ kind: "post", app: a, deadlineDate: camp.submission_end, dMinus: d });
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
            const key = `${a.user_id}|${a.campaign_id}|review_image|${d}`;
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
    await logRun(sb, { digest_date: digestDate, status: "skipped_no_data", total_influencers: 0, total_emails: 0 });
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
            if (c.purchase_end) {
              deadlineParts.push(`レシート ${formatJpDateShort(c.purchase_end)} まで`);
            }
            if (!c.proxy_purchase && c.submission_end) {
              deadlineParts.push(`レビュー認証写真 ${formatJpDateShort(c.submission_end)} まで`);
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
        const dedupKey = `${uid}|${d.app.campaign_id}|${d.kind}|${d.dMinus}`;
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
  await logRun(sb, {
    digest_date: digestDate,
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
});
