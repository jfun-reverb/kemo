// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-application-received-admin-daily
// ──────────────────────────────────────────────────────────────────
// 트리거: pg_cron 매일 UTC 00:00 (= 한국시간 오전 9시)
// 역할:   전일 한국시간 0시~24시 동안 들어온 신청을 캠페인별로 그룹화해
//         관리자에게 일일 요약 메일 1통 발송. 0건이면 미발송.
//         발송 로그 application_received_admin_digest_runs UNIQUE(digest_date).
//
// 환경변수:
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (자동 주입)
//   BREVO_API_KEY (양 서버 별도)
//   NOTIFY_ADMIN_EMAILS (옵션, 외부 수신자 합산)
//   PUBLIC_ADMIN_URL  기본 https://globalreverb.com/admin/
//   BREVO_SENDER_EMAIL 기본 noreply@globalreverb.com
//   BREVO_SENDER_NAME  기본 REVERB JP
//
// 수신자: get_subscribed_admin_emails('application_received') ∪ NOTIFY_ADMIN_EMAILS
//
// 사양서: docs/specs/2026-05-18-application-email-pipeline.md §5
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

function computeWindow() {
  const KST_OFFSET_MS = 9 * 3600 * 1000;
  const nowKstMs = Date.now() + KST_OFFSET_MS;
  const yesterdayKstMs = nowKstMs - 24 * 3600 * 1000;
  const yKst = new Date(yesterdayKstMs);
  const yyyy = yKst.getUTCFullYear();
  const mm = String(yKst.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(yKst.getUTCDate()).padStart(2, "0");
  const digestDate = `${yyyy}-${mm}-${dd}`;
  const windowStartUtc = new Date(Date.parse(`${digestDate}T00:00:00+09:00`));
  const windowEndUtc = new Date(windowStartUtc.getTime() + 24 * 3600 * 1000);
  return { digestDate, windowStartUtc, windowEndUtc };
}

function formatJstHmin(iso: string): string {
  const d = new Date(iso);
  const kstMs = d.getTime() + 9 * 3600 * 1000;
  const k = new Date(kstMs);
  const hh = String(k.getUTCHours()).padStart(2, "0");
  const mi = String(k.getUTCMinutes()).padStart(2, "0");
  return `${hh}:${mi} JST`;
}

function recruitTypeKo(rt: string | null | undefined): string {
  switch (rt) {
    case "monitor": return "리뷰어";
    case "gifting": return "기프팅";
    case "visit":   return "방문형";
    default:        return rt || "-";
  }
}

function influencerDisplayName(row: { name: string | null; name_kanji: string | null; name_kana: string | null }): string {
  const kanji = (row.name_kanji || "").trim();
  const name  = (row.name       || "").trim();
  const kana  = (row.name_kana  || "").trim();
  const main = kanji || name;
  if (main && kana && main !== kana) return `${main} (${kana})`;
  return main || kana || "-";
}

// SNS 핸들 표시: primary_sns 기준 first non-empty
// influencers 테이블 컬럼명: ig(Instagram, NOT instagram) / tiktok / x / youtube
function snsHandleDisplay(infl: {
  primary_sns: string | null;
  ig: string | null;
  tiktok: string | null;
  x: string | null;
  youtube: string | null;
}): string {
  const map: Record<string, { val: string | null; label: string }> = {
    instagram: { val: infl.ig,        label: "IG" },
    tiktok:    { val: infl.tiktok,    label: "TT" },
    x:         { val: infl.x,         label: "X" },
    youtube:   { val: infl.youtube,   label: "YT" },
  };
  // 우선 primary_sns
  if (infl.primary_sns && map[infl.primary_sns]?.val) {
    const m = map[infl.primary_sns];
    return `@${m.val} · ${m.label}`;
  }
  // 폴백: 채워진 첫 채널
  for (const k of ["instagram", "tiktok", "x", "youtube"]) {
    const m = map[k];
    if (m?.val) return `@${m.val} · ${m.label}`;
  }
  return "-";
}

async function resolveAdminEmails(sb: ReturnType<typeof createClient>): Promise<string[]> {
  const fromEnv = env("NOTIFY_ADMIN_EMAILS", "")
    .split(",").map((e) => e.trim()).filter(Boolean);
  try {
    const { data, error } = await sb.rpc("get_subscribed_admin_emails", { p_mail_kind: "application_received" });
    if (error) throw error;
    const fromDb = (data || []).map((r: { email: string | null }) => (r.email || "").trim()).filter(Boolean);
    return [...new Set([...fromDb, ...fromEnv])];
  } catch (_e) {
    return [...new Set(fromEnv)];
  }
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
  const res = await fetch(BREVO_ENDPOINT, {
    method: "POST",
    headers: { "api-key": apiKey, "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      sender: { email: senderEmail, name: senderName },
      to: params.to,
      subject: params.subject,
      htmlContent: params.htmlContent,
      textContent: params.textContent,
    }),
  });
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Brevo send failed ${res.status}: ${errText}`);
  }
}

async function logRun(
  sb: ReturnType<typeof createClient>,
  payload: {
    digest_date: string;
    status: "sent" | "skipped_no_data" | "failed";
    total_applications: number;
    recipient_count: number;
    error_message?: string | null;
  },
): Promise<{ duplicate: boolean }> {
  const { error } = await sb
    .from("application_received_admin_digest_runs")
    .insert({
      digest_date: payload.digest_date,
      status: payload.status,
      total_applications: payload.total_applications,
      recipient_count: payload.recipient_count,
      error_message: payload.error_message ?? null,
    });
  if (error) {
    if ((error as { code?: string }).code === "23505") return { duplicate: true };
    console.error("[notify-app-recv-daily] logRun failed", error);
  }
  return { duplicate: false };
}

interface AppRow {
  id: string;
  created_at: string;
  campaign_id: string;
  user_id: string;
}
interface CampRow {
  id: string;
  campaign_no: string | null;
  title: string | null;
  recruit_type: string | null;
}
interface InflRow {
  auth_id: string;
  name: string | null;
  name_kanji: string | null;
  name_kana: string | null;
  primary_sns: string | null;
  ig: string | null;
  tiktok: string | null;
  x: string | null;
  youtube: string | null;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) {
    return new Response(JSON.stringify({ error: "SUPABASE env missing" }), {
      status: 500, headers: { "content-type": "application/json" },
    });
  }
  const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

  const { digestDate, windowStartUtc, windowEndUtc } = computeWindow();
  console.log("[notify-app-recv-daily] window", { digestDate, start: windowStartUtc.toISOString(), end: windowEndUtc.toISOString() });

  // 1. 이미 처리됐는지 확인
  {
    const { data: prior } = await sb
      .from("application_received_admin_digest_runs")
      .select("id, status, run_at")
      .eq("digest_date", digestDate)
      .maybeSingle();
    if (prior) {
      return new Response(JSON.stringify({ ok: true, skipped: true, reason: "already_processed", digestDate, prior }), {
        status: 200, headers: { "content-type": "application/json" },
      });
    }
  }

  // 2. 윈도우 내 신청 조회
  let rows: AppRow[] = [];
  try {
    const { data, error } = await sb
      .from("applications")
      .select("id, created_at, campaign_id, user_id")
      .gte("created_at", windowStartUtc.toISOString())
      .lt("created_at", windowEndUtc.toISOString())
      .order("created_at", { ascending: true });
    if (error) throw error;
    rows = (data || []) as AppRow[];
  } catch (e) {
    const msg = (e as Error).message || "query error";
    await logRun(sb, { digest_date: digestDate, status: "failed", total_applications: 0, recipient_count: 0, error_message: `query: ${msg}` });
    return new Response(JSON.stringify({ error: msg, stage: "query" }), { status: 500, headers: { "content-type": "application/json" } });
  }

  // 3. 0건 → 스킵
  if (rows.length === 0) {
    const { duplicate } = await logRun(sb, { digest_date: digestDate, status: "skipped_no_data", total_applications: 0, recipient_count: 0 });
    return new Response(JSON.stringify({ ok: true, skipped: true, reason: "no_data", digestDate, duplicate }), {
      status: 200, headers: { "content-type": "application/json" },
    });
  }

  // 4. 캠페인·인플루언서 일괄 조회
  const campIds = [...new Set(rows.map((r) => r.campaign_id))];
  const userIds = [...new Set(rows.map((r) => r.user_id))];

  const campMap = new Map<string, CampRow>();
  if (campIds.length > 0) {
    const { data: camps } = await sb.from("campaigns")
      .select("id, campaign_no, title, recruit_type")
      .in("id", campIds);
    (camps || []).forEach((c: CampRow) => campMap.set(c.id, c));
  }

  const inflMap = new Map<string, InflRow>();
  if (userIds.length > 0) {
    const { data: infls } = await sb.from("influencers")
      .select("auth_id, name, name_kanji, name_kana, primary_sns, ig, tiktok, x, youtube")
      .in("auth_id", userIds);
    (infls || []).forEach((i: InflRow) => inflMap.set(i.auth_id, i));
  }

  const emailMap = new Map<string, string>();
  if (userIds.length > 0) {
    const results = await Promise.all(userIds.map((id) => sb.auth.admin.getUserById(id)));
    results.forEach((r, idx) => {
      if (!r.error && r.data?.user?.email) emailMap.set(userIds[idx], r.data.user.email);
    });
  }

  // 5. 캠페인별 그룹
  const grouped = new Map<string, AppRow[]>();
  rows.forEach((r) => {
    if (!grouped.has(r.campaign_id)) grouped.set(r.campaign_id, []);
    grouped.get(r.campaign_id)!.push(r);
  });

  // 캠페인 정렬: title 알파벳 순
  const campIdsSorted = [...grouped.keys()].sort((a, b) => {
    const ta = (campMap.get(a)?.title || "").toLowerCase();
    const tb = (campMap.get(b)?.title || "").toLowerCase();
    return ta.localeCompare(tb);
  });

  // 6. 행 HTML 빌드
  const rowTpl = loadTemplate("application-received-admin-daily.row");
  const rowsHtml = campIdsSorted.map((cid) => {
    const camp = campMap.get(cid);
    const apps = grouped.get(cid)!;
    const inflListHtml = apps.map((a) => {
      const i = inflMap.get(a.user_id);
      const displayName = i ? influencerDisplayName(i) : "-";
      const email = emailMap.get(a.user_id) || "-";
      const sns = i ? snsHandleDisplay(i) : "-";
      const appliedAt = formatJstHmin(a.created_at);
      return `<tr>
        <td style="padding:4px 0">${escapeHtml(displayName)}</td>
        <td style="padding:4px 0;color:#666">${escapeHtml(email)}</td>
        <td style="padding:4px 0;color:#666;font-size:11px">${escapeHtml(sns)}</td>
        <td style="padding:4px 0;color:#888;font-size:11px;text-align:right">${escapeHtml(appliedAt)}</td>
      </tr>`;
    }).join("");
    return render(rowTpl, {
      campaign_no: escapeHtml(`【${camp?.campaign_no ?? ""}】`),
      campaign_title: escapeHtml(camp?.title ?? "-"),
      recruit_type_ko: escapeHtml(recruitTypeKo(camp?.recruit_type ?? null)),
      infl_count: String(apps.length),
      infl_list_html: inflListHtml,
    });
  }).join("");

  // 7. 메인 HTML 빌드
  const adminUrlBase = env("PUBLIC_ADMIN_URL", "https://globalreverb.com/admin/").replace(/\/$/, "");
  const adminPaneUrl = `${adminUrlBase}/#applications?status=pending`;
  const mainTpl = loadTemplate("application-received-admin-daily");
  const html = render(mainTpl, {
    digest_date: escapeHtml(digestDate),
    total_count: String(rows.length),
    rows_html: rowsHtml,
    admin_pane_url: escapeHtml(adminPaneUrl),
  });
  const subject = `[REVERB] 캠페인 신청 접수 일일 요약 — ${digestDate} (${rows.length}건)`;

  const textLines = [
    `캠페인 신청 접수 일일 요약 (${digestDate})`,
    `총 ${rows.length}건 · 캠페인 ${campIdsSorted.length}개`,
    "",
    ...campIdsSorted.map((cid) => {
      const camp = campMap.get(cid);
      const apps = grouped.get(cid)!;
      return `[${camp?.campaign_no ?? ""}] ${camp?.title ?? "-"} — ${apps.length}건`;
    }),
    "",
    `관리자 페이지: ${adminPaneUrl}`,
  ];
  const text = textLines.join("\n");

  // 8. 수신자 + 발송
  const adminEmails = await resolveAdminEmails(sb);
  if (adminEmails.length === 0) {
    await logRun(sb, { digest_date: digestDate, status: "failed", total_applications: rows.length, recipient_count: 0, error_message: "no recipients" });
    return new Response(JSON.stringify({ ok: false, reason: "no_recipients", digestDate, total_applications: rows.length }), {
      status: 200, headers: { "content-type": "application/json" },
    });
  }

  try {
    await sendBrevoEmail({
      to: adminEmails.map((e) => ({ email: e })),
      subject, htmlContent: html, textContent: text,
    });
  } catch (e) {
    const msg = (e as Error).message || "brevo send error";
    await logRun(sb, { digest_date: digestDate, status: "failed", total_applications: rows.length, recipient_count: adminEmails.length, error_message: msg });
    return new Response(JSON.stringify({ error: msg, stage: "send" }), { status: 500, headers: { "content-type": "application/json" } });
  }

  await logRun(sb, { digest_date: digestDate, status: "sent", total_applications: rows.length, recipient_count: adminEmails.length });

  return new Response(JSON.stringify({
    ok: true, digestDate,
    total_applications: rows.length,
    recipient_count: adminEmails.length,
    campaigns: campIdsSorted.length,
  }), { status: 200, headers: { "content-type": "application/json" } });
});
