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
//   get_subscribed_admin_emails('application_cancel')
//     ∪ get_subscribed_admin_emails('application_received')
//     ∪ env.NOTIFY_ADMIN_EMAILS
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

// 수신자 — 두 구독 종류 합집합 + env (개별 try-catch + env 폴백)
async function resolveAdminEmails(
  sb: ReturnType<typeof createClient>,
): Promise<string[]> {
  const fromEnv = env("NOTIFY_ADMIN_EMAILS", "")
    .split(",")
    .map((e) => e.trim())
    .filter(Boolean);

  try {
    const [cancelRes, receivedRes] = await Promise.all([
      sb.rpc("get_subscribed_admin_emails", { p_mail_kind: "application_cancel" }),
      sb.rpc("get_subscribed_admin_emails", { p_mail_kind: "application_received" }),
    ]);
    const cancelEmails = cancelRes.error
      ? []
      : (cancelRes.data || [])
          .map((r: { email: string | null }) => (r.email || "").trim())
          .filter(Boolean);
    const receivedEmails = receivedRes.error
      ? []
      : (receivedRes.data || [])
          .map((r: { email: string | null }) => (r.email || "").trim())
          .filter(Boolean);
    return [...new Set([...cancelEmails, ...receivedEmails, ...fromEnv])];
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
}
interface InfluencerRow {
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
      const snsHtml = i ? snsCellHtml(i) : "-";
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
        auth_id: r.user_id, name: null, name_kanji: null, name_kana: null,
        primary_sns: null, ig: null, tiktok: null, x: null, youtube: null,
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
        <td style="padding:6px 8px;vertical-align:top;color:#666;border-bottom:1px solid #F8E5E8">${snsCellHtml(infl)}</td>
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
        auth_id: d?.user_id || "", name: null, name_kanji: null, name_kana: null,
        primary_sns: null, ig: null, tiktok: null, x: null, youtube: null,
      };
      const i = infl || fallbackInfl;
      return `<tr>
        <td style="padding:6px 8px;vertical-align:top;border-bottom:1px solid #E5ECF4">${escapeHtml(influencerNameKanji(i))}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#555;border-bottom:1px solid #E5ECF4">${escapeHtml(influencerNameKana(i))}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#666;border-bottom:1px solid #E5ECF4">${escapeHtml((d && args.emailMap.get(d.user_id)) || "-")}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#666;border-bottom:1px solid #E5ECF4">${snsCellHtml(i)}</td>
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
        auth_id: it.user_id || "", name: null, name_kanji: null, name_kana: null,
        primary_sns: null, ig: null, tiktok: null, x: null, youtube: null,
      };
      const i = infl || fallbackInfl;
      return `<tr>
        <td style="padding:6px 8px;vertical-align:top;border-bottom:1px solid #E8E2F5">${escapeHtml(influencerNameKanji(i))}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#555;border-bottom:1px solid #E8E2F5">${escapeHtml(influencerNameKana(i))}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#666;border-bottom:1px solid #E8E2F5">${escapeHtml((it.user_id && args.emailMap.get(it.user_id)) || "-")}</td>
        <td style="padding:6px 8px;vertical-align:top;color:#666;border-bottom:1px solid #E8E2F5">${snsCellHtml(i)}</td>
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
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

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
  {
    const { error } = await sb
      .from("admin_daily_digest_runs")
      .insert({
        digest_date: digestDate,
        status: "failed",
        sections_summary: {},
        recipients_count: 0,
        error_message: "in-flight",
      });
    if (error) {
      if ((error as { code?: string }).code === "23505") {
        // 이미 처리됨 (중복 호출 차단)
        console.log("[notify-admin-daily] already processed", digestDate);
        return new Response(
          JSON.stringify({ ok: true, skipped: true, reason: "already_processed", digestDate }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      }
      console.error("[notify-admin-daily] mutex INSERT failed", error);
      return new Response(JSON.stringify({ error: "mutex insert failed", detail: error.message }), {
        status: 500, headers: { "content-type": "application/json" },
      });
    }
  }

  // 헬퍼: 종료 시 admin_daily_digest_runs UPDATE
  const finalizeRun = async (payload: {
    status: "sent" | "skipped_no_data" | "failed";
    sections_summary: Record<string, number>;
    recipients_count: number;
    error_message?: string | null;
  }) => {
    const { error } = await sb
      .from("admin_daily_digest_runs")
      .update({
        status: payload.status,
        sections_summary: payload.sections_summary,
        recipients_count: payload.recipients_count,
        error_message: payload.error_message ?? null,
      })
      .eq("digest_date", digestDate);
    if (error) console.error("[notify-admin-daily] finalize UPDATE failed", error);
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

    const receivedRows = (receivedRes.data || []) as ReceivedRow[];
    const cancelledRows = (cancelledRes.data || []) as CancelledRow[];
    const submittedEvents = (submittedEventsRes.data || []) as SubmittedEvent[];
    const deliverableReprocessEvents = (deliverableReprocessEventsRes.data || []) as DeliverableReprocessEvent[];
    const applicationReprocessEvents = (applicationReprocessEventsRes.data || []) as ApplicationReprocessEvent[];

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

    console.log("[notify-admin-daily] sections", sectionsSummary);

    // ── 3. 4섹션 모두 0건 → 스킵 ──
    if (totalCount === 0) {
      await finalizeRun({
        status: "skipped_no_data",
        sections_summary: sectionsSummary,
        recipients_count: 0,
      });
      return new Response(
        JSON.stringify({ ok: true, skipped: true, reason: "no_data", digestDate, sectionsSummary }),
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

    // 전체 campaign_id / user_id 모음
    const campaignIds = new Set<string>();
    const userIds = new Set<string>();
    receivedRows.forEach((r) => { campaignIds.add(r.campaign_id); userIds.add(r.user_id); });
    cancelledRows.forEach((r) => { campaignIds.add(r.campaign_id); userIds.add(r.user_id); });
    deliverableMap.forEach((d) => { campaignIds.add(d.campaign_id); userIds.add(d.user_id); });
    reprocessAppMap.forEach((a) => { campaignIds.add(a.campaign_id); userIds.add(a.user_id); });

    const campaignMap = new Map<string, CampaignRow>();
    if (campaignIds.size > 0) {
      const { data: camps, error } = await sb
        .from("campaigns")
        .select("id, campaign_no, title, recruit_type")
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
        .select("auth_id, name, name_kanji, name_kana, primary_sns, ig, tiktok, x, youtube")
        .in("auth_id", [...userIds]);
      if (error) {
        console.warn("[notify-admin-daily] influencer lookup failed", error);
      } else {
        (infls || []).forEach((i: InfluencerRow) => influencerMap.set(i.auth_id, i));
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
