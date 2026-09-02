// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-admin-daily-digest
// ──────────────────────────────────────────────────────────────────
// PR 2 — 관리자 일일 통합 다이제스트 (4섹션 1통/일)
// 사양서: docs/specs/2026-05-18-mail-pipeline-consolidation.md §13~§14 (확정)
// HANDOFF: docs/specs/2026-05-18-HANDOFF-mail-pipeline-consolidation.md §5
//
// 트리거: pg_cron 매일 UTC 00:00 (= 한국시간 오전 9시) net.http_post
// 윈도우: 전일 한국시간 0시~24시
//
// 4섹션 본문:
//   1. 캠페인 신청 접수    — applications.created_at IN window
//   2. 응모 취소           — applications.cancelled_at IN window AND cancel_phase != 'recruit'
//   3. 결과물 제출         — deliverable_events.action='submit' IN window (재제출 자동 배제)
//   4. 재처리 일감         — deliverable_events.action IN ('resubmit','revert')
//                            + application_events.action='revert_to_pending'
//
// 동시성 (supabase-expert 검증):
//   1. status='failed' 로 admin_daily_digest_runs INSERT (digest_date UNIQUE 가 mutex)
//   2. 23505 = 이미 처리됨 → 즉시 종료 (메일 중복 발송 차단)
//   3. INSERT 성공 → 데이터 조회 + 메일 발송
//   4. UPDATE 로 실제 status / sections_summary / recipients_count 갱신
//
// 0건 처리:
//   - 4섹션 모두 0건 → UPDATE status='skipped_no_data' + 메일 미발송
//   - 부분 0건 → 발송, 0건 섹션은 본문에서 생략
//
// 수신자:
//   get_subscribed_admin_emails('daily_digest')
//     ∪ env.NOTIFY_ADMIN_EMAILS
//   (migration 164: application_cancel + application_received → daily_digest 통합)
//
// 환경변수:
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (자동 주입)
//   BREVO_API_KEY (양 서버 별도)
//   NOTIFY_ADMIN_EMAILS (옵션 — 외부 수신자)
//   PUBLIC_ADMIN_URL    기본 https://globalreverb.com/admin/
//   BREVO_SENDER_EMAIL  기본 noreply@globalreverb.com
//   BREVO_SENDER_NAME   기본 REVERB JP
//
// 배포:
//   bash scripts/sync-email-templates.sh
//   supabase functions deploy notify-admin-daily-digest --project-ref <ref>
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
// 한국시간(KST) 윈도우 계산 — 호출 시각의 「어제 KST」
// ──────────────────────────────────────────────────────────────────
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

function formatJstFull(iso: string): string {
  const d = new Date(iso);
  const kstMs = d.getTime() + 9 * 3600 * 1000;
  const k = new Date(kstMs);
  const yyyy = k.getUTCFullYear();
  const mm = String(k.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(k.getUTCDate()).padStart(2, "0");
  const hh = String(k.getUTCHours()).padStart(2, "0");
  const mi = String(k.getUTCMinutes()).padStart(2, "0");
  return `${yyyy}-${mm}-${dd} ${hh}:${mi} JST`;
}

function recruitTypeKo(rt: string | null | undefined): string {
  switch (rt) {
    case "monitor": return "리뷰어";
    case "gifting": return "기프팅";
    case "visit":   return "방문형";
    default:        return rt || "-";
  }
}

function deliverableKindKo(kind: string | null | undefined): string {
  switch (kind) {
    case "receipt":      return "영수증";
    case "review_image": return "리뷰 이미지";
    case "post":         return "게시 URL";
    default:             return kind || "-";
  }
}

function phaseKo(phase: string): string {
  switch (phase) {
    case "purchase": return "구매기간";
    case "visit":    return "방문기간";
    case "post":     return "결과물 제출기간";
    default:         return "기타";
  }
}

// 이름(한자) — name_kanji 우선, 없으면 legacy `name` 폴백, 둘 다 없으면 「-」
function influencerNameKanji(row: {
  name: string | null;
  name_kanji: string | null;
}): string {
  const kanji = (row.name_kanji || "").trim();
  const name  = (row.name       || "").trim();
  return kanji || name || "-";
}

// 이름(가나) — name_kana, 없으면 「-」
function influencerNameKana(row: { name_kana: string | null }): string {
  const kana = (row.name_kana || "").trim();
  return kana || "-";
}

// 합본 표시명 (섹션 3/4 한 줄 카드용) — 「한자 (가나)」 또는 한쪽만
function influencerNameFull(row: {
  name: string | null;
  name_kanji: string | null;
  name_kana: string | null;
}): string {
  const kanji = (row.name_kanji || "").trim();
  const name  = (row.name       || "").trim();
  const kana  = (row.name_kana  || "").trim();
  const main = kanji || name;
  if (main && kana && main !== kana) return `${main} (${kana})`;
  return main || kana || "-";
}

// SNS 핸들 + 공식 URL — primary_sns 우선, 없으면 첫 채널.
// dev/js/admin.js 의 _excelSnsUrl 패턴과 통일.
function snsLink(infl: {
  primary_sns: string | null;
  ig: string | null;
  tiktok: string | null;
  x: string | null;
  youtube: string | null;
}): { handle: string; url: string; label: string } | null {
  const channels: { key: string; val: string | null; label: string; url: (h: string) => string }[] = [
    { key: "instagram", val: infl.ig,      label: "IG", url: (h) => `https://www.instagram.com/${h}/` },
    { key: "tiktok",    val: infl.tiktok,  label: "TT", url: (h) => `https://www.tiktok.com/@${h}` },
    { key: "x",         val: infl.x,       label: "X",  url: (h) => `https://x.com/${h}` },
    { key: "youtube",   val: infl.youtube, label: "YT", url: (h) => `https://www.youtube.com/@${h}` },
  ];
  // primary 우선
  if (infl.primary_sns) {
    const p = channels.find((c) => c.key === infl.primary_sns && c.val);
    if (p) {
      const h = stripAtPrefix(p.val!);
      return { handle: h, url: p.url(h), label: p.label };
    }
  }
  // 폴백: 등록된 첫 채널
  const first = channels.find((c) => c.val);
  if (first) {
    const h = stripAtPrefix(first.val!);
    return { handle: h, url: first.url(h), label: first.label };
  }
  return null;
}

function stripAtPrefix(raw: string): string {
  const t = (raw || "").trim();
  return t.startsWith("@") ? t.slice(1) : t;
}

// 메일 본문용 SNS 셀 HTML — 안전한 a 태그 또는 「-」
function snsCellHtml(infl: {
  primary_sns: string | null;
  ig: string | null;
  tiktok: string | null;
  x: string | null;
  youtube: string | null;
}): string {
  const link = snsLink(infl);
  if (!link) return "-";
  const url = escapeHtml(link.url);
  const handle = escapeHtml(link.handle);
  const label = escapeHtml(link.label);
  return `<a href="${url}" target="_blank" rel="noopener noreferrer" style="color:#5B6BBF;text-decoration:none">@${handle}</a> <span style="color:#888;font-size:11px">· ${label}</span>`;
}

// 모집 채널 기준 SNS 셀 HTML — 캠페인이 모집하는 채널 중 인플루언서가 등록한 것만,
// 각 채널 아이디 + 팔로워 수를 한 줄씩(<br> 구분) 표시.
// 폴백(모집 채널이 없거나 인플루언서가 그 채널을 하나도 등록 안 함) → 기존 대표 SNS 셀.
function recruitSnsCellHtml(
  infl: {
    primary_sns: string | null;
    ig: string | null; tiktok: string | null; x: string | null; youtube: string | null;
    ig_followers?: number | null; tiktok_followers?: number | null;
    x_followers?: number | null; youtube_followers?: number | null;
  },
  channelCsv: string | null,
): string {
  const codes = (channelCsv || "").split(",").map((s) => s.trim()).filter(Boolean);
  if (!codes.length) return snsCellHtml(infl);

  const defs: Record<string, { handle: string | null; followers: number | null | undefined; label: string; url: (h: string) => string }> = {
    instagram: { handle: infl.ig,      followers: infl.ig_followers,      label: "IG", url: (h) => `https://www.instagram.com/${h}/` },
    tiktok:    { handle: infl.tiktok,  followers: infl.tiktok_followers,  label: "TT", url: (h) => `https://www.tiktok.com/@${h}` },
    x:         { handle: infl.x,       followers: infl.x_followers,       label: "X",  url: (h) => `https://x.com/${h}` },
    youtube:   { handle: infl.youtube, followers: infl.youtube_followers, label: "YT", url: (h) => `https://www.youtube.com/@${h}` },
  };

  const lines: string[] = [];
  for (const code of codes) {
    const def = defs[code];
    if (!def || !def.handle) continue;   // 그 채널 미등록은 줄 생략
    const h = escapeHtml(stripAtPrefix(def.handle));
    const url = escapeHtml(def.url(stripAtPrefix(def.handle)));
    const label = escapeHtml(def.label);
    const fol = (def.followers && def.followers > 0)
      ? ` ${def.followers.toLocaleString("en-US")}`
      : "";
    lines.push(`<a href="${url}" target="_blank" rel="noopener noreferrer" style="color:#5B6BBF;text-decoration:none">@${h}</a> <span style="color:#888;font-size:11px">· ${label}${fol}</span>`);
  }
  // 모집 채널 중 등록된 핸들이 하나도 없으면 대표 SNS 폴백
  if (!lines.length) return snsCellHtml(infl);
  return lines.join("<br>");
}

function loadTemplate(name: string): string {
  const html = TEMPLATES[name];
  if (!html) throw new Error(`template not registered: ${name}`);
  // HTML 주석 제거 — 주석 안 placeholder 가 치환되면서 발생하는 중첩 주석
  // → 조기 종료 → 본문 누출 버그 차단. 2026-05-18 dev 발송 테스트에서 발견
  return html.replace(/<!--[\s\S]*?-->/g, "");
}

function render(html: string, data: Record<string, string>): string {
  return html.replace(/\{\{(\w+)\}\}/g, (_m, key) => data[key] ?? "");
}

// 수신자 — daily_digest 구독자 + env (try-catch + env 폴백)
// migration 164: application_cancel + application_received → daily_digest 단일 RPC
async function resolveAdminEmails(
  sb: ReturnType<typeof createClient>,
): Promise<string[]> {
  const fromEnv = env("NOTIFY_ADMIN_EMAILS", "")
    .split(",")
    .map((e) => e.trim())
    .filter(Boolean);

  try {
    const digestRes = await sb.rpc("get_subscribed_admin_emails", {
      p_mail_kind: "daily_digest",
    });
    const digestEmails = digestRes.error
      ? []
      : (digestRes.data || [])
          .map((r: { email: string | null }) => (r.email || "").trim())
          .filter(Boolean);
    return [...new Set([...digestEmails, ...fromEnv])];
  } catch (_e) {
    return [...new Set(fromEnv)];
  }
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
    headers: {
      "api-key": apiKey,
      "content-type": "application/json",
      accept: "application/json",
    },
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

// ──────────────────────────────────────────────────────────────────
// 타입 정의
// ──────────────────────────────────────────────────────────────────
interface ReceivedRow {
  id: string;
  created_at: string;
  campaign_id: string;
  user_id: string;
}
interface CancelledRow {
  id: string;
  cancelled_at: string;
  cancel_phase: string;
  cancel_reason_code: string | null;
  cancel_reason: string | null;
  campaign_id: string;
  user_id: string;
}
interface SubmittedEvent {
  id: string;
  deliverable_id: string;
  action: string;
  created_at: string;
}
interface DeliverableInfo {
  id: string;
  kind: string | null;
  campaign_id: string;
  user_id: string;
  receipt_url: string | null;
  post_url: string | null;
  order_number: string | null;
  purchase_date: string | null;
  purchase_amount: number | string | null;
}
interface DeliverableReprocessEvent {
  id: string;
  deliverable_id: string;
  action: string; // 'resubmit' | 'revert'
  created_at: string;
}
interface ApplicationReprocessEvent {
  id: string;
  application_id: string;
  action: string; // 'revert_to_pending'
  created_at: string;
  changed_by_name: string | null;
}
interface ApplicationInfo {
  id: string;
  campaign_id: string;
  user_id: string;
}
interface CampaignRow {
  id: string;
  campaign_no: string | null;
  title: string | null;
  recruit_type: string | null;
  channel: string | null;   // 모집 채널 콤마 구분 (예 "instagram,x")
}
interface InfluencerRow {
  id: string;
  name: string | null;
  name_kanji: string | null;
  name_kana: string | null;
  primary_sns: string | null;
  ig: string | null;
  tiktok: string | null;
  x: string | null;
  youtube: string | null;
  ig_followers: number | null;
  x_followers: number | null;
  tiktok_followers: number | null;
  youtube_followers: number | null;
}

// ──────────────────────────────────────────────────────────────────
// 섹션 렌더 헬퍼
// ──────────────────────────────────────────────────────────────────
function renderSectionWrapper(args: {
  title: string;
  color: string;
  count: number;
  bodyHtml: string;
}): string {
  return render(loadTemplate("admin-daily-digest.section"), {
    section_title: escapeHtml(args.title),
    section_color: args.color,
    section_count: String(args.count),
    section_body_html: args.bodyHtml,
  });
}

function renderReceivedSection(args: {
  rows: ReceivedRow[];
  campaignMap: Map<string, CampaignRow>;
  influencerMap: Map<string, InfluencerRow>;
  emailMap: Map<string, string>;
}): string {
  if (args.rows.length === 0) return "";

  // 캠페인별 그룹
  const grouped = new Map<string, ReceivedRow[]>();
  args.rows.forEach((r) => {
    if (!grouped.has(r.campaign_id)) grouped.set(r.campaign_id, []);
    grouped.get(r.campaign_id)!.push(r);
  });

  // 캠페인 제목 알파벳 순 정렬
  const campIdsSorted = [...grouped.keys()].sort((a, b) => {
    const ta = (args.campaignMap.get(a)?.title || "").toLowerCase();
    const tb = (args.campaignMap.get(b)?.title || "").toLowerCase();
    return ta.localeCompare(tb);
  });

  const rowTpl = loadTemplate("admin-daily-digest.row-received");
  const cardsHtml = campIdsSorted.map((cid) => {
    const camp = args.campaignMap.get(cid);
    const apps = grouped.get(cid)!;
    const inflListHtml = apps.map((a) => {
      const i = args.influencerMap.get(a.user_id);
      const kanji = i ? influencerNameKanji(i) : "-";
      const kana  = i ? influencerNameKana(i)  : "-";
      const email = args.emailMap.get(a.user_id) || "-";
      const snsHtml = i ? recruitSnsCellHtml(i, camp?.channel ?? null) : "-";
      const appliedAt = formatJstHmin(a.created_at);
      return `<tr>
        <td style="padding:6px 8px;vertical-align:top;border-bottom:1px solid #F0F2F8">${escapeHtml(kanji)}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#555;border-bottom:1px solid #F0F2F8">${escapeHtml(kana)}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#666;border-bottom:1px solid #F0F2F8">${escapeHtml(email)}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#666;border-bottom:1px solid #F0F2F8">${snsHtml}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#888;font-size:11px;text-align:right;border-bottom:1px solid #F0F2F8">${escapeHtml(appliedAt)}</td>
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

  return renderSectionWrapper({
    title: "캠페인 신청 접수",
    color: "#C8789C",
    count: args.rows.length,
    bodyHtml: cardsHtml,
  });
}

// phase 별 컬러 칩 색상 (셀 안 인라인 칩)
const PHASE_CHIP: Record<string, { bg: string; fg: string }> = {
  purchase: { bg: "#FFE4E9", fg: "#E8344E" },
  visit:    { bg: "#E4F0FF", fg: "#1F5DBF" },
  post:     { bg: "#FFF0D6", fg: "#A06A14" },
  other:    { bg: "#EAEAEA", fg: "#555555" },
};
function phaseChipHtml(phase: string): string {
  const c = PHASE_CHIP[phase] || PHASE_CHIP.other;
  return `<span style="background:${c.bg};color:${c.fg};padding:2px 8px;border-radius:4px;font-weight:700;font-size:11px">${escapeHtml(phaseKo(phase))}</span>`;
}

function renderCancelledSection(args: {
  rows: CancelledRow[];
  campaignMap: Map<string, CampaignRow>;
  influencerMap: Map<string, InfluencerRow>;
  emailMap: Map<string, string>;
  reasonMap: Map<string, string>;
}): string {
  if (args.rows.length === 0) return "";

  // 캠페인별 그룹
  const grouped = new Map<string, CancelledRow[]>();
  args.rows.forEach((r) => {
    if (!grouped.has(r.campaign_id)) grouped.set(r.campaign_id, []);
    grouped.get(r.campaign_id)!.push(r);
  });
  const campIdsSorted = [...grouped.keys()].sort((a, b) => {
    const ta = (args.campaignMap.get(a)?.title || "").toLowerCase();
    const tb = (args.campaignMap.get(b)?.title || "").toLowerCase();
    return ta.localeCompare(tb);
  });

  const rowTpl = loadTemplate("admin-daily-digest.row-cancelled");
  const bodyHtml = campIdsSorted.map((cid) => {
    const camp = args.campaignMap.get(cid);
    const rows = grouped.get(cid)!;
    const cancelRowsHtml = rows.map((r) => {
      const infl = args.influencerMap.get(r.user_id) || {
        id: r.user_id, name: null, name_kanji: null, name_kana: null,
        primary_sns: null, ig: null, tiktok: null, x: null, youtube: null,
        ig_followers: null, x_followers: null, tiktok_followers: null, youtube_followers: null,
      };
      const reasonLabel = r.cancel_reason_code
        ? args.reasonMap.get(r.cancel_reason_code) || r.cancel_reason_code
        : "-";
      const note = (r.cancel_reason || "").trim();
      const reasonCell = note
        ? `${escapeHtml(reasonLabel)}<br><span style="color:#888;font-size:11px;line-height:1.5">${escapeHtml(note)}</span>`
        : escapeHtml(reasonLabel);
      return `<tr>
        <td style="padding:6px 8px;vertical-align:top;border-bottom:1px solid #F8E5E8">${escapeHtml(influencerNameKanji(infl))}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#555;border-bottom:1px solid #F8E5E8">${escapeHtml(influencerNameKana(infl))}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#666;border-bottom:1px solid #F8E5E8">${escapeHtml(args.emailMap.get(r.user_id) || "-")}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#666;border-bottom:1px solid #F8E5E8">${recruitSnsCellHtml(infl, camp?.channel ?? null)}</td>
        <td style="padding:6px 8px;vertical-align:top;border-bottom:1px solid #F8E5E8">${phaseChipHtml(r.cancel_phase)}</td>
        <td style="padding:6px 8px;vertical-align:top;border-bottom:1px solid #F8E5E8">${reasonCell}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#888;font-size:11px;text-align:right;border-bottom:1px solid #F8E5E8">${escapeHtml(formatJstFull(r.cancelled_at))}</td>
      </tr>`;
    }).join("");
    return render(rowTpl, {
      campaign_no: escapeHtml(`【${camp?.campaign_no ?? ""}】`),
      campaign_title: escapeHtml(camp?.title ?? "-"),
      recruit_type_ko: escapeHtml(recruitTypeKo(camp?.recruit_type ?? null)),
      cancel_count: String(rows.length),
      cancel_rows_html: cancelRowsHtml,
    });
  }).join("");

  return renderSectionWrapper({
    title: "응모 취소",
    color: "#E8344E",
    count: args.rows.length,
    bodyHtml,
  });
}

// kind 별 컬러 칩 (영수증/리뷰 이미지/게시 URL)
const KIND_CHIP: Record<string, { bg: string; fg: string }> = {
  receipt:      { bg: "#E4F0FF", fg: "#1F5DBF" },
  review_image: { bg: "#E0F1E4", fg: "#1F7A3D" },
  post:         { bg: "#FFF0D6", fg: "#A06A14" },
  other:        { bg: "#EAEAEA", fg: "#555555" },
};
function kindChipHtml(kind: string | null): string {
  const key = kind && KIND_CHIP[kind] ? kind : "other";
  const c = KIND_CHIP[key];
  return `<span style="background:${c.bg};color:${c.fg};padding:2px 8px;border-radius:4px;font-weight:700;font-size:11px">${escapeHtml(deliverableKindKo(kind))}</span>`;
}

// 일본 엔화 표시 (소수점 0자리, 0엔 허용)
function formatYen(amount: number | string | null | undefined): string {
  if (amount === null || amount === undefined || amount === "") return "-";
  const n = typeof amount === "string" ? Number(amount) : amount;
  if (!Number.isFinite(n)) return "-";
  return `¥${Math.round(n).toLocaleString("ja-JP")}`;
}

// 안전한 외부 URL — http(s) 스킴만 허용 (javascript:, data: 차단)
function safeExternalUrl(raw: string | null | undefined): string | null {
  const url = (raw || "").trim();
  if (!url) return null;
  if (!/^https?:\/\//i.test(url)) return null;
  return url;
}

// 제출 내역 셀 HTML — kind 분기
function submitContentCellHtml(d: DeliverableInfo | null): string {
  if (!d) return "-";
  if (d.kind === "receipt") {
    const url = safeExternalUrl(d.receipt_url);
    const linkHtml = url
      ? `<a href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer" style="color:#1F5DBF;text-decoration:none;font-weight:700">영수증 이미지 보기</a>`
      : `<span style="color:#888">이미지 없음</span>`;
    const orderNo = (d.order_number || "").trim();
    const purchaseDate = (d.purchase_date || "").trim();
    const amountText = formatYen(d.purchase_amount);
    const info: string[] = [];
    if (orderNo) info.push(`주문 ${escapeHtml(orderNo)}`);
    if (purchaseDate) info.push(`구매일 ${escapeHtml(purchaseDate)}`);
    if (amountText !== "-") info.push(`금액 ${escapeHtml(amountText)}`);
    const infoLine = info.length > 0
      ? `<br><span style="color:#888;font-size:11px;line-height:1.5">${info.join(" · ")}</span>`
      : "";
    return linkHtml + infoLine;
  }
  if (d.kind === "post") {
    const url = safeExternalUrl(d.post_url);
    return url
      ? `<a href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer" style="color:#1F5DBF;text-decoration:none;font-weight:700">게시 보기</a>`
      : `<span style="color:#888">URL 없음</span>`;
  }
  if (d.kind === "review_image") {
    const url = safeExternalUrl(d.receipt_url);  // review_image 도 receipt_url 컬럼 사용 (기존 스키마)
    return url
      ? `<a href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer" style="color:#1F5DBF;text-decoration:none;font-weight:700">리뷰 이미지 보기</a>`
      : `<span style="color:#888">이미지 없음</span>`;
  }
  return "-";
}

function renderSubmittedSection(args: {
  events: SubmittedEvent[];
  deliverableMap: Map<string, DeliverableInfo>;
  campaignMap: Map<string, CampaignRow>;
  influencerMap: Map<string, InfluencerRow>;
  emailMap: Map<string, string>;
}): string {
  if (args.events.length === 0) return "";

  // 캠페인별 그룹
  const grouped = new Map<string, SubmittedEvent[]>();
  args.events.forEach((ev) => {
    const d = args.deliverableMap.get(ev.deliverable_id);
    const cid = d?.campaign_id || "__no_campaign__";
    if (!grouped.has(cid)) grouped.set(cid, []);
    grouped.get(cid)!.push(ev);
  });
  const campIdsSorted = [...grouped.keys()].sort((a, b) => {
    const ta = (args.campaignMap.get(a)?.title || "").toLowerCase();
    const tb = (args.campaignMap.get(b)?.title || "").toLowerCase();
    return ta.localeCompare(tb);
  });

  const rowTpl = loadTemplate("admin-daily-digest.row-submitted");
  const bodyHtml = campIdsSorted.map((cid) => {
    const camp = args.campaignMap.get(cid);
    const events = grouped.get(cid)!;
    const submitRowsHtml = events.map((ev) => {
      const d = args.deliverableMap.get(ev.deliverable_id) || null;
      const infl = d ? args.influencerMap.get(d.user_id) : null;
      const fallbackInfl = {
        id: d?.user_id || "", name: null, name_kanji: null, name_kana: null,
        primary_sns: null, ig: null, tiktok: null, x: null, youtube: null,
        ig_followers: null, x_followers: null, tiktok_followers: null, youtube_followers: null,
      };
      const i = infl || fallbackInfl;
      return `<tr>
        <td style="padding:6px 8px;vertical-align:top;border-bottom:1px solid #E5ECF4">${escapeHtml(influencerNameKanji(i))}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#555;border-bottom:1px solid #E5ECF4">${escapeHtml(influencerNameKana(i))}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#666;border-bottom:1px solid #E5ECF4">${escapeHtml((d && args.emailMap.get(d.user_id)) || "-")}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#666;border-bottom:1px solid #E5ECF4">${recruitSnsCellHtml(i, camp?.channel ?? null)}</td>
        <td style="padding:6px 8px;vertical-align:top;border-bottom:1px solid #E5ECF4">${kindChipHtml(d?.kind ?? null)}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#444;border-bottom:1px solid #E5ECF4">${submitContentCellHtml(d)}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#888;font-size:11px;text-align:right;border-bottom:1px solid #E5ECF4">${escapeHtml(formatJstHmin(ev.created_at))}</td>
      </tr>`;
    }).join("");
    return render(rowTpl, {
      campaign_no: escapeHtml(`【${camp?.campaign_no ?? ""}】`),
      campaign_title: escapeHtml(camp?.title ?? "-"),
      recruit_type_ko: escapeHtml(recruitTypeKo(camp?.recruit_type ?? null)),
      submit_count: String(events.length),
      submit_rows_html: submitRowsHtml,
    });
  }).join("");

  return renderSectionWrapper({
    title: "결과물 제출",
    color: "#1F5DBF",
    count: args.events.length,
    bodyHtml,
  });
}

interface ReprocessedItem {
  type: "deliv_resubmit" | "deliv_revert" | "app_revert";
  created_at: string;
  campaign_id: string | null;
  user_id: string | null;
  actor_name: string | null;
}

const REPROCESS_TYPE_LABELS: Record<ReprocessedItem["type"], string> = {
  deliv_resubmit: "결과물 재제출",
  deliv_revert:   "결과물 되돌리기",
  app_revert:     "신청 되돌리기",
};
const REPROCESS_TYPE_CHIP: Record<ReprocessedItem["type"], { bg: string; fg: string }> = {
  deliv_resubmit: { bg: "#F0E6FA", fg: "#6F40A6" },
  deliv_revert:   { bg: "#FFE8D6", fg: "#A0541A" },
  app_revert:     { bg: "#E5E0F4", fg: "#5B6BBF" },
};
function reprocessTypeChipHtml(t: ReprocessedItem["type"]): string {
  const c = REPROCESS_TYPE_CHIP[t];
  return `<span style="background:${c.bg};color:${c.fg};padding:2px 8px;border-radius:4px;font-weight:700;font-size:11px">${escapeHtml(REPROCESS_TYPE_LABELS[t])}</span>`;
}

function renderReprocessedSection(args: {
  items: ReprocessedItem[];
  campaignMap: Map<string, CampaignRow>;
  influencerMap: Map<string, InfluencerRow>;
  emailMap: Map<string, string>;
}): string {
  if (args.items.length === 0) return "";

  // 캠페인별 그룹 (campaign_id null 은 「__no_campaign__」 으로 묶음)
  const grouped = new Map<string, ReprocessedItem[]>();
  args.items.forEach((it) => {
    const cid = it.campaign_id || "__no_campaign__";
    if (!grouped.has(cid)) grouped.set(cid, []);
    grouped.get(cid)!.push(it);
  });
  const campIdsSorted = [...grouped.keys()].sort((a, b) => {
    const ta = (args.campaignMap.get(a)?.title || "").toLowerCase();
    const tb = (args.campaignMap.get(b)?.title || "").toLowerCase();
    return ta.localeCompare(tb);
  });

  const rowTpl = loadTemplate("admin-daily-digest.row-reprocessed");
  const bodyHtml = campIdsSorted.map((cid) => {
    const camp = args.campaignMap.get(cid);
    const items = grouped.get(cid)!;
    const reprocessRowsHtml = items.map((it) => {
      const infl = it.user_id ? args.influencerMap.get(it.user_id) : null;
      const fallbackInfl = {
        id: it.user_id || "", name: null, name_kanji: null, name_kana: null,
        primary_sns: null, ig: null, tiktok: null, x: null, youtube: null,
        ig_followers: null, x_followers: null, tiktok_followers: null, youtube_followers: null,
      };
      const i = infl || fallbackInfl;
      return `<tr>
        <td style="padding:6px 8px;vertical-align:top;border-bottom:1px solid #E8E2F5">${escapeHtml(influencerNameKanji(i))}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#555;border-bottom:1px solid #E8E2F5">${escapeHtml(influencerNameKana(i))}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#666;border-bottom:1px solid #E8E2F5">${escapeHtml((it.user_id && args.emailMap.get(it.user_id)) || "-")}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#666;border-bottom:1px solid #E8E2F5">${recruitSnsCellHtml(i, camp?.channel ?? null)}</td>
        <td style="padding:6px 8px;vertical-align:top;border-bottom:1px solid #E8E2F5">${reprocessTypeChipHtml(it.type)}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#444;border-bottom:1px solid #E8E2F5">${escapeHtml(it.actor_name || "-")}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#888;font-size:11px;text-align:right;border-bottom:1px solid #E8E2F5">${escapeHtml(formatJstHmin(it.created_at))}</td>
      </tr>`;
    }).join("");
    return render(rowTpl, {
      campaign_no: escapeHtml(`【${camp?.campaign_no ?? ""}】`),
      campaign_title: escapeHtml(camp?.title ?? "-"),
      recruit_type_ko: escapeHtml(recruitTypeKo(camp?.recruit_type ?? null)),
      reprocess_count: String(items.length),
      reprocess_rows_html: reprocessRowsHtml,
    });
  }).join("");

  return renderSectionWrapper({
    title: "재처리 일감",
    color: "#6F40A6",
    count: args.items.length,
    bodyHtml,
  });
}

// ──────────────────────────────────────────────────────────────────
// Main handler
// ──────────────────────────────────────────────────────────────────

// ── 공개 키로 부르는 것을 막는다 ────────────────────────────────
// 🔴 이 함수는 **메일을 보낸다.** 막는 것이 없으면 사이트에 박힌 공개 키만으로
//    누구나 발송을 시킬 수 있다(2026-09-02 전수조사 — 같은 형태가 여섯 개였다).
// ⚠️ 공개 키를 교체하면 이 목록도 함께 갱신할 것.
const PUBLIC_CLIENT_KEYS = [
  "sb_publishable_3pfK7sF55NZO7owlm13_uA_iCbORAvP",  // 운영
  "sb_publishable_WTxFsvQFllOPIdQ8MDNwCw_e0qBlYTv",  // 개발
];

function rejectPublicKeyCaller(req: Request, tag: string): boolean {
  const raw = (req.headers.get("Authorization") ?? "").trim();
  const token = raw.replace(/^Bearer\s+/i, "").trim();
  if (!token) return false;                       // 토큰 없음 — 플랫폼이 이미 막는다
  if (PUBLIC_CLIENT_KEYS.includes(token)) {
    console.warn(`[${tag}] rejected — called with the public client key`);
    return true;
  }
  // 토큰 자체는 절대 남기지 않는다.
  const isServiceRole = token === (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
  console.log(`[${tag}] caller check passed`, { isServiceRole });
  return false;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
  if (rejectPublicKeyCaller(req, "notify-admin-daily-digest")) {
    return new Response(JSON.stringify({ error: "forbidden" }), {
      status: 403,
      headers: { "content-type": "application/json" },
    });
  }

  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) {
    console.error("[notify-admin-daily] SUPABASE env missing");
    return new Response(JSON.stringify({ error: "SUPABASE env missing" }), {
      status: 500, headers: { "content-type": "application/json" },
    });
  }
  const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

  const { digestDate, windowStartUtc, windowEndUtc } = computeWindow();
  console.log("[notify-admin-daily] window", {
    digestDate, start: windowStartUtc.toISOString(), end: windowEndUtc.toISOString(),
  });

  // ── 1. INSERT 선행 mutex (status='failed' 마커) ──
  //    digest_date UNIQUE 가 mutex 역할 → 동시 호출 차단
  //
  //    [F-5, 2026-08] 예전엔 23505(이미 있음) 를 만나면 무조건 "이미
  //    처리됨"으로 끝냈다. 그런데 이 마커 행이 처리 도중 함수가 죽으면
  //    (타임아웃·플랫폼 재시작 등) status='failed'·error_message=
  //    'in-flight' 인 채로 영원히 남는다 — 그러면 그날은 몇 번을 다시
  //    불러도 "이미 처리됨" 취급돼 발송이 영영 안 나가는데, 재호출은
  //    200(정상 응답)을 주므로 운영자는 "보냈는데 안 온다"로 오인한다.
  //    복구법이 코드·주석 어디에도 없었다.
  //
  //    지금은 23505 를 만나면 기존 행을 직접 읽어 ①이미 끝난 상태
  //    (sent/skipped_no_data)면 그대로 스킵 ②아직 안 끝난 상태(failed
  //    — 크래시였을 수도, 진짜 실패로 끝났을 수도 있다)면
  //    RETRY_COOLDOWN_MS 가 지났을 때만 "내가 이어받는다"는 조건부
  //    UPDATE 를 시도한다. 이 UPDATE 는 직전에 읽은 run_at 값이 그대로일
  //    때만 통과한다(낙관적 락 — dev/lib/storage.js updateCampaign() 의
  //    version 조건부 UPDATE 와 같은 원리. run_at 을 새 시각으로 같이
  //    바꿔 쓰므로, 두 재호출이 동시에 들어와도 먼저 커밋한 쪽만 통과하고
  //    나머지는 조건 불일치로 0행 UPDATE — "먼저 잡은 쪽만 진행"이 보장됨).
  //
  //    RETRY_COOLDOWN_MS = 10분 — 이 함수는 체이닝 없는 단발성 실행이라
  //    정상 처리는 Deno Edge Function 실행 시간 상한(이 저장소의 다른
  //    함수 주석 기준 약 150초, 예: notify-campaign-promo-digest·
  //    notify-policy-change) 안에 반드시 끝나거나 플랫폼에 죽는다. 10분은
  //    그 150초의 약 4배 여유 — 실제로 아직 실행 중인 프로세스와 충돌할
  //    가능성을 사실상 배제하면서도, 당일 안에 재시도가 통하기 충분히 짧다.
  const RETRY_COOLDOWN_MS = 10 * 60 * 1000;
  // [리뷰 반영 1/2026-08] "내가 지금 이 실행의 주인"임을 끝까지(finalizeRun 까지)
  // 들고 갈 값. mutex 를 잡은 방식(새 INSERT vs 재시도 UPDATE)에 따라 아래에서
  // 채운다. finalizeRun 이 이 값으로 조건부 UPDATE 를 하므로, 쿨다운 판단이
  // 틀려서(실행 상한 가정이 빗나가서) 원본과 재시도가 동시에 살아있어도 최종
  // 상태 기록만큼은 한쪽이 이긴다 — 이미 나간 메일은 못 되돌리지만 로그가
  // 거짓으로 덮이는 건 막는다.
  let ownedRunAt: string | null = null;
  {
    const { data: inserted, error } = await sb
      .from("admin_daily_digest_runs")
      .insert({
        digest_date: digestDate,
        status: "failed",
        sections_summary: {},
        recipients_count: 0,
        error_message: "in-flight",
      })
      .select("run_at")
      .maybeSingle();
    if (error) {
      if ((error as { code?: string }).code === "23505") {
        const { data: existing, error: selErr } = await sb
          .from("admin_daily_digest_runs")
          .select("status, run_at")
          .eq("digest_date", digestDate)
          .maybeSingle();
        if (selErr || !existing) {
          console.error("[notify-admin-daily] existing row lookup failed after 23505", selErr);
          return new Response(
            JSON.stringify({ ok: true, skipped: true, reason: "already_processed", digestDate }),
            { status: 200, headers: { "content-type": "application/json" } },
          );
        }
        if (existing.status === "sent" || existing.status === "skipped_no_data") {
          // 이미 끝난 상태(성공/데이터없음) — 재시도 없이 그대로 스킵
          console.log("[notify-admin-daily] already processed (terminal)", digestDate, existing.status);
          return new Response(
            JSON.stringify({ ok: true, skipped: true, reason: "already_processed", digestDate, priorStatus: existing.status }),
            { status: 200, headers: { "content-type": "application/json" } },
          );
        }
        // status === 'failed' — 크래시로 멈췄거나 진짜 실패. 최소 대기 시간 확인.
        const runAtMs = new Date(existing.run_at as string).getTime();
        const elapsedMs = Date.now() - runAtMs;
        if (elapsedMs < RETRY_COOLDOWN_MS) {
          // 아직 실행 중일 가능성을 배제 못 함 — 재시도하지 않고 대기 안내만
          console.log("[notify-admin-daily] recent failed/in-flight row, cooldown not elapsed — skip retry", {
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
          .from("admin_daily_digest_runs")
          .update({
            status: "failed",
            sections_summary: {},
            recipients_count: 0,
            error_message: "in-flight (retry)",
            run_at: retryRunAt,
          })
          .eq("digest_date", digestDate)
          .eq("run_at", existing.run_at as string)
          .select("id");
        if (claimErr || !claimed || claimed.length === 0) {
          // 다른 재호출이 먼저 가져갔거나 그 사이 상태가 바뀜 — 이번 호출은 양보
          console.log("[notify-admin-daily] lost retry race or already claimed", digestDate, claimErr);
          return new Response(
            JSON.stringify({ ok: true, skipped: true, reason: "retry_race_lost", digestDate }),
            { status: 200, headers: { "content-type": "application/json" } },
          );
        }
        ownedRunAt = retryRunAt; // 방금 내가 써넣은 값 — finalizeRun 의 소유권 조건으로 재사용
        console.warn("[notify-admin-daily] retrying stale/failed run", digestDate, { priorRunAt: existing.run_at });
        // 아래로 흘러 정상 처리 진행 (INSERT 대신 이 UPDATE 로 mutex 를 확보한 상태)
      } else {
        console.error("[notify-admin-daily] mutex INSERT failed", error);
        return new Response(JSON.stringify({ error: "mutex insert failed", detail: error.message }), {
          status: 500, headers: { "content-type": "application/json" },
        });
      }
    } else {
      ownedRunAt = (inserted?.run_at as string | undefined) ?? null;
      if (!ownedRunAt) {
        // INSERT 는 성공했는데 run_at 을 못 읽어온 경우(있어선 안 되지만) —
        // 소유권 검증 없이 진행한다는 걸 로그에 남긴다.
        console.error("[notify-admin-daily] mutex INSERT succeeded but run_at missing from response — ownership check disabled for this run", digestDate);
      }
    }
  }

  // 헬퍼: 종료 시 admin_daily_digest_runs UPDATE
  //
  // [리뷰 반영 1] mutex 를 "잡을 때"는 run_at 조건부 UPDATE 로 소유권을
  // 확인하면서 "끝낼 때"(finalizeRun)는 digest_date 로만 UPDATE 했었다 —
  // 자기가 그 실행의 주인인지 다시 확인하지 않았다. 쿨다운(10분) 은 「실행
  // 시간 상한 약 150초」라는 검증 안 된 가정에 기대는데, 실제 상한이 더
  // 길거나 이 실행이 우연히 느려져 쿨다운을 넘기면, 재시도가 "죽었다"고
  // 오판해 소유권을 가져가는 데 성공하고 원본과 재시도가 둘 다 계속 돈다
  // — 그러면 최종 상태를 서로 덮어써서 로그가 거짓말을 하게 된다(메일
  // 자체의 중복은 별개 — 그건 이미 나간 뒤라 여기서 못 막는다).
  // 그래서 ownedRunAt 이 있으면 그 값으로도 조건을 걸고, 0행이면(=그 사이
  // 다른 실행이 run_at 을 바꿔써서 내가 더 이상 주인이 아니면) 덮어쓰지
  // 않고 console.error 로만 남긴다.
  const finalizeRun = async (payload: {
    status: "sent" | "skipped_no_data" | "failed";
    sections_summary: Record<string, number>;
    recipients_count: number;
    error_message?: string | null;
  }) => {
    let q = sb
      .from("admin_daily_digest_runs")
      .update({
        status: payload.status,
        sections_summary: payload.sections_summary,
        recipients_count: payload.recipients_count,
        error_message: payload.error_message ?? null,
      })
      .eq("digest_date", digestDate);
    if (ownedRunAt != null) q = q.eq("run_at", ownedRunAt);
    const { data, error } = await q.select("id");
    if (error) {
      console.error("[notify-admin-daily] finalize UPDATE failed", error);
      return;
    }
    if (ownedRunAt != null && (!data || data.length === 0)) {
      console.error(
        "[notify-admin-daily] finalizeRun: 소유권을 잃어 최종 상태를 기록하지 못함(run_at 불일치) — 덮어쓰지 않음",
        digestDate, ownedRunAt, payload.status,
      );
    }
  };

  try {
    // ── 2. 4섹션 쿼리 병렬 ──
    const startIso = windowStartUtc.toISOString();
    const endIso = windowEndUtc.toISOString();

    const [
      receivedRes,
      cancelledRes,
      submittedEventsRes,
      deliverableReprocessEventsRes,
      applicationReprocessEventsRes,
    ] = await Promise.all([
      // 섹션 1: 신청 접수 (재응모 새 INSERT 포함)
      sb.from("applications")
        .select("id, created_at, campaign_id, user_id")
        .gte("created_at", startIso)
        .lt("created_at", endIso)
        .order("created_at", { ascending: true }),
      // 섹션 2: 응모 취소 (cancel_phase != recruit)
      sb.from("applications")
        .select("id, cancelled_at, cancel_phase, cancel_reason_code, cancel_reason, campaign_id, user_id")
        .eq("status", "cancelled")
        .neq("cancel_phase", "recruit")
        .not("cancel_phase", "is", null)
        .gte("cancelled_at", startIso)
        .lt("cancelled_at", endIso)
        .order("cancelled_at", { ascending: true }),
      // 섹션 3: 결과물 제출 (deliverable_events.action='submit' 만 — 재제출 자동 배제)
      sb.from("deliverable_events")
        .select("id, deliverable_id, action, created_at")
        .eq("action", "submit")
        .gte("created_at", startIso)
        .lt("created_at", endIso)
        .order("created_at", { ascending: true }),
      // 섹션 4a: 결과물 재처리 (resubmit / revert)
      sb.from("deliverable_events")
        .select("id, deliverable_id, action, created_at")
        .in("action", ["resubmit", "revert"])
        .gte("created_at", startIso)
        .lt("created_at", endIso)
        .order("created_at", { ascending: true }),
      // 섹션 4b: 신청 되돌리기 (application_events.action='revert_to_pending')
      sb.from("application_events")
        .select("id, application_id, action, created_at, changed_by_name")
        .eq("action", "revert_to_pending")
        .gte("created_at", startIso)
        .lt("created_at", endIso)
        .order("created_at", { ascending: true }),
    ]);

    // 에러 점검 — 한 섹션이라도 실패하면 전체 실패 처리
    for (const [label, res] of [
      ["received", receivedRes],
      ["cancelled", cancelledRes],
      ["submitted_events", submittedEventsRes],
      ["deliv_reprocess_events", deliverableReprocessEventsRes],
      ["app_reprocess_events", applicationReprocessEventsRes],
    ] as const) {
      if (res.error) {
        const msg = `query ${label}: ${res.error.message}`;
        console.error("[notify-admin-daily]", msg);
        await finalizeRun({
          status: "failed",
          sections_summary: {},
          recipients_count: 0,
          error_message: msg,
        });
        return new Response(JSON.stringify({ error: msg, stage: "query" }), {
          status: 500, headers: { "content-type": "application/json" },
        });
      }
    }

    // [F-7] 아래 5개를 let 으로 선언 — 감사용 계정(is_audit=true) 행을 걸러낸
    // 뒤 같은 이름으로 재대입한다(하단 [F-7] 필터링 블록). 이후 코드(HTML 렌더
    // 포함)는 전부 이 이름을 그대로 참조하므로 변수명은 바꾸지 않는다.
    let receivedRows = (receivedRes.data || []) as ReceivedRow[];
    let cancelledRows = (cancelledRes.data || []) as CancelledRow[];
    let submittedEvents = (submittedEventsRes.data || []) as SubmittedEvent[];
    let deliverableReprocessEvents = (deliverableReprocessEventsRes.data || []) as DeliverableReprocessEvent[];
    let applicationReprocessEvents = (applicationReprocessEventsRes.data || []) as ApplicationReprocessEvent[];

    // ── 3. 4섹션 모두 0건(감사용 계정 필터 적용 전) → 스킵 ──
    //    이 시점엔 아직 감사용 여부를 판정할 수 없다(섹션 3·4 는 deliverable_id/
    //    application_id 만 갖고 있어 user_id 를 알려면 아래 [F-7] 배치 lookup 이
    //    끝나야 함). 여기서는 "애초에 아무 일도 없던 날"만 먼저 걸러 불필요한
    //    조회를 피한다 — 아래에 [F-7] 필터 후 재확인이 한 번 더 있다.
    const totalCountRaw =
      receivedRows.length + cancelledRows.length + submittedEvents.length +
      deliverableReprocessEvents.length + applicationReprocessEvents.length;
    console.log("[notify-admin-daily] sections (raw, 감사용 필터 전)", {
      received: receivedRows.length,
      cancelled: cancelledRows.length,
      submitted: submittedEvents.length,
      reprocessed: deliverableReprocessEvents.length + applicationReprocessEvents.length,
    });
    if (totalCountRaw === 0) {
      const emptySummary = { received: 0, cancelled: 0, submitted: 0, reprocessed: 0 };
      await finalizeRun({
        status: "skipped_no_data",
        sections_summary: emptySummary,
        recipients_count: 0,
      });
      return new Response(
        JSON.stringify({ ok: true, skipped: true, reason: "no_data", digestDate, sectionsSummary: emptySummary }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    }

    // ── 4. 배치 lookup ──

    // deliverable_id 모음 (섹션 3 + 섹션 4a)
    const deliverableIds = [
      ...new Set([
        ...submittedEvents.map((e) => e.deliverable_id),
        ...deliverableReprocessEvents.map((e) => e.deliverable_id),
      ]),
    ];
    const deliverableMap = new Map<string, DeliverableInfo>();
    if (deliverableIds.length > 0) {
      const { data: delivs, error } = await sb
        .from("deliverables")
        .select("id, kind, campaign_id, user_id, receipt_url, post_url, order_number, purchase_date, purchase_amount")
        .in("id", deliverableIds);
      if (error) {
        console.warn("[notify-admin-daily] deliverable lookup failed", error);
      } else {
        (delivs || []).forEach((d: DeliverableInfo) => deliverableMap.set(d.id, d));
      }
    }

    // application_id 모음 (섹션 4b)
    const reprocessAppIds = [
      ...new Set(applicationReprocessEvents.map((e) => e.application_id)),
    ];
    const reprocessAppMap = new Map<string, ApplicationInfo>();
    if (reprocessAppIds.length > 0) {
      const { data: apps, error } = await sb
        .from("applications")
        .select("id, campaign_id, user_id")
        .in("id", reprocessAppIds);
      if (error) {
        console.warn("[notify-admin-daily] reprocess application lookup failed", error);
      } else {
        (apps || []).forEach((a: ApplicationInfo) => reprocessAppMap.set(a.id, a));
      }
    }

    // ── [F-7] 감사용 계정(is_audit=true) 제외 ────────────────────────
    //   감사용 계정은 운영팀이 인플루언서 동선을 시뮬레이션하는 공용 계정이다
    //   (마이그레이션 179). 응모수·정원·대시보드 KPI·운영현황·엑셀에서는 이미
    //   격리돼 있는데(마이그레이션 179·181) 이 관리자 다이제스트는 그 목록에
    //   없었다 — 관리자가 매일 받는 요약 메일에 가짜 활동이 실제 신청·취소·
    //   제출·재처리와 섞여 나갔다(전수조사 F-7).
    //   섹션 1·2(receivedRows/cancelledRows)는 user_id 를 직접 갖고 있어
    //   바로 거를 수 있지만, 섹션 3·4(submittedEvents/deliverableReprocess
    //   Events/applicationReprocessEvents)는 deliverable_id/application_id 만
    //   갖고 있어 방금 채운 deliverableMap/reprocessAppMap 이 있어야 user_id 를
    //   알 수 있다 — 그래서 이 필터를 그 두 맵이 준비된 지금 위치에서 한다.
    //   판정 기준은 이 저장소의 다른 곳(마이그레이션 181·218·231·232·242·259)과
    //   동일하게 `is_audit = true`(컬럼이 NOT NULL DEFAULT false 라 COALESCE
    //   불필요 — CLAUDE.md quality 규칙 「다른 곳과 같은 방식을 따르라」).
    const auditUserIds = new Set<string>();
    {
      const { data: auditRows, error } = await sb
        .from("influencers")
        .select("id")
        .eq("is_audit", true);
      if (error) {
        // 조회 실패 시 아무도 감사용으로 간주하지 않는다(모르면 지우지 않는다) —
        // 실제 관리자에게 갈 메일을 잘못 걸러 조용히 사라지게 하는 것보다,
        // 드물게 감사용 계정 활동이 한 줄 섞이는 쪽이 안전하다.
        console.warn("[notify-admin-daily] audit influencer lookup failed — 감사용 계정을 걸러내지 못했습니다", error);
      } else {
        (auditRows || []).forEach((r: { id: string }) => auditUserIds.add(r.id));
      }
    }
    if (auditUserIds.size > 0) {
      receivedRows = receivedRows.filter((r) => !auditUserIds.has(r.user_id));
      cancelledRows = cancelledRows.filter((r) => !auditUserIds.has(r.user_id));
      submittedEvents = submittedEvents.filter((e) => {
        const d = deliverableMap.get(e.deliverable_id);
        return !d || !auditUserIds.has(d.user_id); // 조회 실패(d 없음)는 배제하지 않음
      });
      deliverableReprocessEvents = deliverableReprocessEvents.filter((e) => {
        const d = deliverableMap.get(e.deliverable_id);
        return !d || !auditUserIds.has(d.user_id);
      });
      applicationReprocessEvents = applicationReprocessEvents.filter((e) => {
        const a = reprocessAppMap.get(e.application_id);
        return !a || !auditUserIds.has(a.user_id);
      });
    }

    // [F-7] 감사용 계정 필터 반영한 최종 섹션 집계 — 메일 본문·제목·배지·
    //   admin_daily_digest_runs 로그가 전부 이 값을 쓴다(총 5곳, 위 grep 확인).
    const sectionsSummary = {
      received: receivedRows.length,
      cancelled: cancelledRows.length,
      submitted: submittedEvents.length,
      reprocessed: deliverableReprocessEvents.length + applicationReprocessEvents.length,
    };
    const totalCount =
      sectionsSummary.received +
      sectionsSummary.cancelled +
      sectionsSummary.submitted +
      sectionsSummary.reprocessed;

    console.log("[notify-admin-daily] sections (감사용 제외 후)", sectionsSummary);

    // [F-7] 그날 활동이 전부 감사용 계정이었던 경우 — 위 totalCountRaw 체크는
    //   통과했지만(진짜 데이터가 있었음) 필터 후 0건이면 여기서 다시 스킵한다.
    if (totalCount === 0) {
      await finalizeRun({
        status: "skipped_no_data",
        sections_summary: sectionsSummary,
        recipients_count: 0,
      });
      return new Response(
        JSON.stringify({ ok: true, skipped: true, reason: "no_data_after_audit_exclude", digestDate, sectionsSummary }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    }

    // 전체 campaign_id / user_id 모음 — 감사용 필터를 이미 거친 배열/맵 순회만 쓴다
    // ([F-7] deliverableMap·reprocessAppMap 자체는 감사용 항목도 여전히 담고 있는
    //  범용 조회표라, 그걸 통째로 순회하지 않고 필터된 이벤트 배열을 기준으로 삼는다).
    const campaignIds = new Set<string>();
    const userIds = new Set<string>();
    receivedRows.forEach((r) => { campaignIds.add(r.campaign_id); userIds.add(r.user_id); });
    cancelledRows.forEach((r) => { campaignIds.add(r.campaign_id); userIds.add(r.user_id); });
    submittedEvents.forEach((e) => {
      const d = deliverableMap.get(e.deliverable_id);
      if (d) { campaignIds.add(d.campaign_id); userIds.add(d.user_id); }
    });
    deliverableReprocessEvents.forEach((e) => {
      const d = deliverableMap.get(e.deliverable_id);
      if (d) { campaignIds.add(d.campaign_id); userIds.add(d.user_id); }
    });
    applicationReprocessEvents.forEach((e) => {
      const a = reprocessAppMap.get(e.application_id);
      if (a) { campaignIds.add(a.campaign_id); userIds.add(a.user_id); }
    });

    const campaignMap = new Map<string, CampaignRow>();
    if (campaignIds.size > 0) {
      const { data: camps, error } = await sb
        .from("campaigns")
        .select("id, campaign_no, title, recruit_type, channel")
        .in("id", [...campaignIds]);
      if (error) {
        console.warn("[notify-admin-daily] campaign lookup failed", error);
      } else {
        (camps || []).forEach((c: CampaignRow) => campaignMap.set(c.id, c));
      }
    }

    const influencerMap = new Map<string, InfluencerRow>();
    if (userIds.size > 0) {
      const { data: infls, error } = await sb
        .from("influencers")
        .select("id, name, name_kanji, name_kana, primary_sns, ig, tiktok, x, youtube, ig_followers, x_followers, tiktok_followers, youtube_followers")
        .in("id", [...userIds]);
      if (error) {
        console.warn("[notify-admin-daily] influencer lookup failed", error);
      } else {
        (infls || []).forEach((i: InfluencerRow) => influencerMap.set(i.id, i));
      }
    }

    // 이메일 — 4섹션 전체 user_id 대상 (섹션 3·4 카드에도 이메일 노출)
    const emailUserIds = [...userIds];
    const emailMap = new Map<string, string>();
    if (emailUserIds.length > 0) {
      const results = await Promise.all(
        emailUserIds.map((id) => sb.auth.admin.getUserById(id)),
      );
      results.forEach((r, idx) => {
        if (!r.error && r.data?.user?.email) {
          emailMap.set(emailUserIds[idx], r.data.user.email);
        }
      });
    }

    // 취소 사유 lookup (섹션 2)
    const reasonCodes = [
      ...new Set(cancelledRows.map((r) => r.cancel_reason_code).filter((c): c is string => !!c)),
    ];
    const reasonMap = new Map<string, string>();
    if (reasonCodes.length > 0) {
      const { data: reasons, error } = await sb
        .from("lookup_values")
        .select("code, name_ko")
        .eq("kind", "cancel_reason")
        .in("code", reasonCodes);
      if (error) {
        console.warn("[notify-admin-daily] cancel reason lookup failed", error);
      } else {
        (reasons || []).forEach((r: { code: string; name_ko: string }) => reasonMap.set(r.code, r.name_ko));
      }
    }

    // ── 5. 섹션 4 (재처리) 통합 ReprocessedItem 빌드 ──
    const reprocessedItems: ReprocessedItem[] = [];
    deliverableReprocessEvents.forEach((ev) => {
      const d = deliverableMap.get(ev.deliverable_id);
      reprocessedItems.push({
        type: ev.action === "resubmit" ? "deliv_resubmit" : "deliv_revert",
        created_at: ev.created_at,
        campaign_id: d?.campaign_id ?? null,
        user_id: d?.user_id ?? null,
        actor_name: null, // deliverable_events 에 actor 이름 스냅샷 없음 — auth.uid() 기반이라 「-」 표시
      });
    });
    applicationReprocessEvents.forEach((ev) => {
      const a = reprocessAppMap.get(ev.application_id);
      reprocessedItems.push({
        type: "app_revert",
        created_at: ev.created_at,
        campaign_id: a?.campaign_id ?? null,
        user_id: a?.user_id ?? null,
        actor_name: ev.changed_by_name,
      });
    });
    // 시간순 정렬
    reprocessedItems.sort((a, b) => a.created_at.localeCompare(b.created_at));

    // ── 6. 섹션별 HTML 렌더 ──
    const sectionReceivedHtml = renderReceivedSection({
      rows: receivedRows,
      campaignMap,
      influencerMap,
      emailMap,
    });
    const sectionCancelledHtml = renderCancelledSection({
      rows: cancelledRows,
      campaignMap,
      influencerMap,
      emailMap,
      reasonMap,
    });
    const sectionSubmittedHtml = renderSubmittedSection({
      events: submittedEvents,
      deliverableMap,
      campaignMap,
      influencerMap,
      emailMap,
    });
    const sectionReprocessedHtml = renderReprocessedSection({
      items: reprocessedItems,
      campaignMap,
      influencerMap,
      emailMap,
    });

    // 섹션 칩 (헤더 요약)
    const chipDef: { key: keyof typeof sectionsSummary; label: string; bg: string; fg: string }[] = [
      { key: "received",    label: "접수",   bg: "#FFF5F8", fg: "#C8789C" },
      { key: "cancelled",   label: "취소",   bg: "#FFE4E9", fg: "#E8344E" },
      { key: "submitted",   label: "제출",   bg: "#E4F0FF", fg: "#1F5DBF" },
      { key: "reprocessed", label: "재처리", bg: "#F0E6FA", fg: "#6F40A6" },
    ];
    const summaryChipHtml = chipDef
      .filter((c) => sectionsSummary[c.key] > 0)
      .map((c) =>
        `<span style="background:${c.bg};color:${c.fg};padding:3px 10px;border-radius:6px;font-weight:700;font-size:12px;margin-right:6px">${c.label} ${sectionsSummary[c.key]}건</span>`
      )
      .join("");

    // ── 7. 메인 HTML ──
    const adminUrlBase = env("PUBLIC_ADMIN_URL", "https://globalreverb.com/admin/").replace(/\/$/, "");
    const adminPaneUrl = `${adminUrlBase}/`;
    const mainTpl = loadTemplate("admin-daily-digest");
    const html = render(mainTpl, {
      digest_date: escapeHtml(digestDate),
      total_count: String(totalCount),
      summary_chip_html: summaryChipHtml,
      section_received_html: sectionReceivedHtml,
      section_cancelled_html: sectionCancelledHtml,
      section_submitted_html: sectionSubmittedHtml,
      section_reprocessed_html: sectionReprocessedHtml,
      admin_pane_url: escapeHtml(adminPaneUrl),
    });

    const subject = `[REVERB] 관리자 일일 요약 — ${digestDate} (총 ${totalCount}건)`;

    // text fallback
    const textLines = [
      `관리자 일일 통합 요약 (${digestDate})`,
      `총 ${totalCount}건 — 접수 ${sectionsSummary.received} · 취소 ${sectionsSummary.cancelled} · 제출 ${sectionsSummary.submitted} · 재처리 ${sectionsSummary.reprocessed}`,
      "",
      `관리자 페이지: ${adminPaneUrl}`,
    ];
    const text = textLines.join("\n");

    // ── 8. 수신자 ──
    const adminEmails = await resolveAdminEmails(sb);
    console.log("[notify-admin-daily] recipients", { count: adminEmails.length });

    if (adminEmails.length === 0) {
      await finalizeRun({
        status: "failed",
        sections_summary: sectionsSummary,
        recipients_count: 0,
        error_message: "no recipients (admin_email_subscriptions + env both empty)",
      });
      return new Response(
        JSON.stringify({ ok: false, reason: "no_recipients", digestDate, sectionsSummary }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    }

    // ── 9. 메일 발송 ── 관리자별 1통씩 분리 발송 (To 헤더 노출 차단)
    //
    // [리뷰 반영 3] ⚠️ 잔여 위험 — 이 루프는 "누구에게 보냈는지"를 개별로
    // 기록하는 표가 없다(집계 recipients_count 만 남음). 그래서 이 실행이
    // 일부 관리자에게 보낸 뒤 죽으면(F-5 로 재시도가 안전해졌다고 해서
    // 이 문제까지 없어진 건 아님), 나중에(쿨다운 10분 경과 후) 재시도가
    // 들어와도 "누가 이미 받았는지" 알 길이 없어 adminEmails 전원에게
    // 처음부터 다시 보낸다 — 이미 받은 관리자는 같은 다이제스트를 두 번
    // 받는다. 운영자가 이 함수를 수동으로 다시 부르기 전에는 Brevo
    // 발송 이력(또는 admin_daily_digest_runs.error_message 의 실패 목록)
    // 으로 직전 실행이 몇 명까지 보냈는지 먼저 확인할 것 — 「재시도가
    // 안전해졌다」는 자물쇠(mutex) 자체의 중복 실행 얘기지, 이 루프의
    // 부분 발송 뒤 재시도 중복까지 막아주는 게 아니다.
    let successCount = 0;
    const failures: { email: string; error: string }[] = [];
    for (const email of adminEmails) {
      try {
        await sendBrevoEmail({
          to: [{ email }],
          subject,
          htmlContent: html,
          textContent: text,
        });
        successCount++;
      } catch (e) {
        const msg = (e as Error).message || "brevo send error";
        console.error("[notify-admin-daily] send failed", email, msg);
        failures.push({ email, error: msg });
      }
    }

    if (successCount === 0) {
      const firstErr = failures[0]?.error || "unknown";
      await finalizeRun({
        status: "failed",
        sections_summary: sectionsSummary,
        recipients_count: 0,
        error_message: `all ${adminEmails.length} sends failed: ${firstErr}`,
      });
      return new Response(JSON.stringify({
        error: "all sends failed", stage: "send",
        attempted: adminEmails.length, failed: failures.length,
      }), { status: 500, headers: { "content-type": "application/json" } });
    }

    // ── 10. 성공 (전부 또는 일부) UPDATE ──
    const errMsg = failures.length > 0
      ? `${successCount}/${adminEmails.length} sent. failed: ${failures.map((f) => `${f.email}(${f.error})`).join("; ")}`
      : null;
    await finalizeRun({
      status: "sent",
      sections_summary: sectionsSummary,
      recipients_count: successCount,
      error_message: errMsg,
    });

    console.log("[notify-admin-daily] done", {
      digestDate, totalCount,
      attempted: adminEmails.length, succeeded: successCount, failed: failures.length,
    });

    return new Response(
      JSON.stringify({
        ok: true,
        digestDate,
        totalCount,
        sectionsSummary,
        attempted: adminEmails.length,
        succeeded: successCount,
        failed: failures.length,
      }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  } catch (e) {
    // 예상치 못한 에러 — finalizeRun 헬퍼로 통일 (다른 에러 경로와 일관성)
    const msg = (e as Error).message || "unknown error";
    console.error("[notify-admin-daily] unexpected error", msg);
    try {
      await finalizeRun({
        status: "failed",
        sections_summary: {},
        recipients_count: 0,
        error_message: `unexpected: ${msg}`,
      });
    } catch (_finalizeErr) {
      console.error("[notify-admin-daily] could not finalize after unexpected error");
    }
    return new Response(JSON.stringify({ error: msg, stage: "unexpected" }), {
      status: 500, headers: { "content-type": "application/json" },
    });
  }
});
