// ══════════════════════════════════════════════════════════════════
// scripts/send-test-influencer-digest.ts
// ──────────────────────────────────────────────────────────────────
// 인플루언서 일일 다이제스트(notify-influencer-daily-digest) 메일 렌더링·
// 깨짐 여부를 실제 메일 클라이언트에서 확인하기 위한 일회용 테스트 발송 스크립트.
//
// docs/email-templates/influencer-daily-digest{.html, .row-*.html} 5종을 그대로
// 사용 + 4섹션 더미 데이터(일본어 본문) → Brevo SMTP 발송.
//
// 사용법:
//   BREVO_API_KEY='xkeysib-...' \
//     deno run --allow-read --allow-env --allow-net \
//     scripts/send-test-influencer-digest.ts
//
// 환경변수:
//   BREVO_API_KEY    (필수)
//   TEST_RECIPIENT   (옵션) 기본 younggeun.kim@jfun.co.kr
//   PUBLIC_APP_URL   (옵션) 기본 https://globalreverb.com
// ══════════════════════════════════════════════════════════════════

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";
const TEMPLATES_DIR = "docs/email-templates";

function env(key: string, fb = ""): string { return Deno.env.get(key) ?? fb; }
function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}
async function loadTemplate(name: string): Promise<string> {
  const raw = await Deno.readTextFile(`${TEMPLATES_DIR}/${name}.html`);
  return raw.replace(/<!--[\s\S]*?-->/g, "");  // 주석 strip
}
function render(html: string, data: Record<string, string>): string {
  return html.replace(/\{\{(\w+)\}\}/g, (_m, k) => data[k] ?? "");
}

const apiKey = env("BREVO_API_KEY").trim();
if (!apiKey || !/^[\x20-\x7E]+$/.test(apiKey)) {
  console.error("❌ BREVO_API_KEY (ASCII, xkeysib- prefix) 가 필요합니다.");
  Deno.exit(1);
}
const recipient = env("TEST_RECIPIENT", "younggeun.kim@jfun.co.kr");
const publicAppUrl = env("PUBLIC_APP_URL", "https://globalreverb.com").replace(/\/$/, "");
const todayJp = "2026年5月19日";

// ──────────────────────────────────────────────────────────────────
// 4섹션 더미 데이터
// ──────────────────────────────────────────────────────────────────
const dummyReceived = [
  { campaign_no: "CAMP-2026-0042", campaign_title: "スキンケア新製品レビューキャンペーン — フェイシャルセラム", recruit_type_jp: "レビュアー", applied_at_jst: "2026年5月18日 21:34" },
  { campaign_no: "CAMP-2026-0043", campaign_title: "ヘアミスト無料体験団", recruit_type_jp: "ギフティング", applied_at_jst: "2026年5月18日 10:22" },
];
const dummyApproved = [
  { campaign_no: "CAMP-2026-0040", campaign_title: "プレミアムマスクパック — 日本限定キャンペーン", recruit_type_jp: "レビュアー", reviewed_at_jst: "2026年5月18日 14:22", reward: "¥3,000", deadline_summary: "レシート 5/25 まで · 投稿物 6/5 まで" },
];
const dummyRejected = [
  { campaign_no: "CAMP-2026-0036", campaign_title: "サンクリーム SPF50+ キャンペーン", reviewed_at_jst: "2026年5月18日 16:09" },
];
const dummyDeadline = [
  { kind_label_jp: "レシート", campaign_no: "CAMP-2026-0030", campaign_title: "化粧水ボトルレビュー", deadline_jp: "5月24日 (D-5)", d_minus_label: "D-5", d_minus_color: "#A06A14", d_minus_bg: "#FFF0D6", submit_url: `${publicAppUrl}/#activity` },
  { kind_label_jp: "投稿物", campaign_no: "CAMP-2026-0028", campaign_title: "リップバム新製品", deadline_jp: "5月20日 (D-1)", d_minus_label: "D-1", d_minus_color: "#E8344E", d_minus_bg: "#FFE4E9", submit_url: `${publicAppUrl}/#activity` },
];

// ──────────────────────────────────────────────────────────────────
// 섹션 렌더
// ──────────────────────────────────────────────────────────────────
async function renderReceivedSection(): Promise<string> {
  if (dummyReceived.length === 0) return "";
  const tpl = await loadTemplate("influencer-daily-digest.row-received");
  const rows = dummyReceived.map((r) => render(tpl, {
    campaign_no: escapeHtml(`【${r.campaign_no}】`),
    campaign_title: escapeHtml(r.campaign_title),
    recruit_type_jp: escapeHtml(r.recruit_type_jp),
    applied_at_jst: escapeHtml(r.applied_at_jst),
  })).join("");
  return `<h3 style="font-size:14px;color:#333;border-left:4px solid #C8789C;padding-left:10px;margin:24px 0 12px">新規応募の受付 (${dummyReceived.length}件)</h3>` + rows;
}

async function renderApprovedSection(): Promise<string> {
  if (dummyApproved.length === 0) return "";
  const tpl = await loadTemplate("influencer-daily-digest.row-approved");
  const rows = dummyApproved.map((a) => {
    const deadlineRow = a.deadline_summary
      ? `<tr><td style="padding:3px 0;color:#888;width:84px">期限</td><td style="padding:3px 0;font-size:11px;color:#666">${escapeHtml(a.deadline_summary)}</td></tr>`
      : "";
    return render(tpl, {
      campaign_no: escapeHtml(`【${a.campaign_no}】`),
      campaign_title: escapeHtml(a.campaign_title),
      recruit_type_jp: escapeHtml(a.recruit_type_jp),
      reviewed_at_jst: escapeHtml(a.reviewed_at_jst),
      reward: escapeHtml(a.reward),
      deadline_summary_row: deadlineRow,
    });
  }).join("");
  return `<h3 style="font-size:14px;color:#333;border-left:4px solid #16A34A;padding-left:10px;margin:24px 0 12px">承認のお知らせ (${dummyApproved.length}件)</h3>` + rows;
}

async function renderRejectedSection(): Promise<string> {
  if (dummyRejected.length === 0) return "";
  const tpl = await loadTemplate("influencer-daily-digest.row-rejected");
  const rows = dummyRejected.map((r) => render(tpl, {
    campaign_no: escapeHtml(`【${r.campaign_no}】`),
    campaign_title: escapeHtml(r.campaign_title),
    reviewed_at_jst: escapeHtml(r.reviewed_at_jst),
  })).join("");
  return `<h3 style="font-size:14px;color:#333;border-left:4px solid #888;padding-left:10px;margin:24px 0 12px">選考結果のお知らせ (${dummyRejected.length}件)</h3>` + rows;
}

async function renderDeadlineSection(): Promise<string> {
  if (dummyDeadline.length === 0) return "";
  const tpl = await loadTemplate("influencer-daily-digest.row-deadline");
  const rows = dummyDeadline.map((d) => render(tpl, {
    kind_label_jp: escapeHtml(d.kind_label_jp),
    campaign_no: escapeHtml(`【${d.campaign_no}】`),
    campaign_title: escapeHtml(d.campaign_title),
    deadline_jp: escapeHtml(d.deadline_jp),
    d_minus_label: escapeHtml(d.d_minus_label),
    d_minus_color: d.d_minus_color,
    d_minus_bg: d.d_minus_bg,
    submit_url: escapeHtml(d.submit_url),
  })).join("");
  return `<h3 style="font-size:14px;color:#333;border-left:4px solid #A06A14;padding-left:10px;margin:24px 0 12px">提出期限のお知らせ (${dummyDeadline.length}件)</h3>` + rows;
}

// ──────────────────────────────────────────────────────────────────
// Main
// ──────────────────────────────────────────────────────────────────
const [s1, s2, s3, s4] = await Promise.all([
  renderReceivedSection(), renderApprovedSection(), renderRejectedSection(), renderDeadlineSection(),
]);
const totalCount = dummyReceived.length + dummyApproved.length + dummyRejected.length + dummyDeadline.length;

const mainTpl = await loadTemplate("influencer-daily-digest");
let html = render(mainTpl, {
  today_jp: escapeHtml(todayJp),
  total_count: String(totalCount),
  section_received_html: s1,
  section_approved_html: s2,
  section_rejected_html: s3,
  section_deadline_html: s4,
  public_app_url: escapeHtml(publicAppUrl),
});

// TEST 배너 본문 상단 삽입
const banner = `<div style="background:#FFF3CD;border-left:4px solid #FFA000;padding:10px 14px;margin:0 0 12px;border-radius:6px;font-family:'Hiragino Sans',Arial,sans-serif;color:#5A4500;font-size:13px"><strong>⚠️ TEST MAIL — ダミーデータ</strong><br>実際のデータではありません。メールレンダリングの確認用です。<code style="background:#FFEAA7;padding:1px 6px;border-radius:3px">scripts/send-test-influencer-digest.ts</code></div>`;
html = html.replace('<div style="font-family:', banner + '<div style="font-family:');

const subject = `[TEST] 【REVERB】本日の応募状況のお知らせ (${todayJp}) — ${totalCount}件ダミー`;
const text = [
  `[TEST] 本日の応募状況のお知らせ (${todayJp})`,
  `${totalCount}件のお知らせ (ダミー)`,
  `応募履歴: ${publicAppUrl}/#mypage-applications`,
].join("\n");

console.log(`📧 인플 다이제스트 테스트 발송 — 수신: ${recipient}, HTML ${html.length} bytes`);

const res = await fetch(BREVO_ENDPOINT, {
  method: "POST",
  headers: { "api-key": apiKey, "content-type": "application/json", accept: "application/json" },
  body: JSON.stringify({
    sender: { email: env("BREVO_SENDER_EMAIL", "noreply@globalreverb.com"), name: env("BREVO_SENDER_NAME", "REVERB JP [TEST]") },
    to: [{ email: recipient }],
    subject, htmlContent: html, textContent: text,
  }),
});

if (!res.ok) {
  console.error(`❌ Brevo 발송 실패 ${res.status}:`, await res.text());
  Deno.exit(1);
}
const body = await res.json();
console.log(`✅ Brevo 발송 성공 — message_id: ${body.messageId || "(없음)"}`);
console.log(`📬 ${recipient} 받은편지함에서 확인하세요.`);
