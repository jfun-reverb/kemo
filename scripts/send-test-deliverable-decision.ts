// ══════════════════════════════════════════════════════════════════
// scripts/send-test-deliverable-decision.ts
// ──────────────────────────────────────────────────────────────────
// 결과물 검수(notify-deliverable-decision) 메일 6종을 모두 발송해서 메일
// 클라이언트에서 렌더링 확인. docs/email-templates/deliverable-*.html 6개.
//
// 사용법:
//   BREVO_API_KEY='xkeysib-...' \
//     deno run --allow-read --allow-env --allow-net \
//     scripts/send-test-deliverable-decision.ts
//
// 옵션:
//   TYPES='receipt-approved,receipt-rejected' 로 일부만 발송 가능 (기본: 6종 모두)
// ══════════════════════════════════════════════════════════════════

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";
const TEMPLATES_DIR = "docs/email-templates";

function env(key: string, fb = ""): string { return Deno.env.get(key) ?? fb; }
function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}
async function loadTemplate(name: string): Promise<string> {
  const raw = await Deno.readTextFile(`${TEMPLATES_DIR}/${name}.html`);
  return raw.replace(/<!--[\s\S]*?-->/g, "");
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
const siteUrl = env("PUBLIC_APP_URL", "https://globalreverb.com").replace(/\/$/, "");
const activityLink = `${siteUrl}/#activity`;
const helpLineUrl = "https://line.me/R/ti/p/@reverb.jp";
const filter = env("TYPES", "").split(",").map((s) => s.trim()).filter(Boolean);

// 검수 결과 next_step_block (승인용) — Edge Function 의 buildNextStepBlock 발췌
function nextStepBlock(kind: "receipt" | "review_image" | "post"): string {
  if (kind === "receipt") {
    return `<div style="background:#F0F9FF;border:1px solid #BAE6FD;border-radius:8px;padding:16px 18px;margin-bottom:22px"><div style="font-size:11px;font-weight:700;color:#075985;letter-spacing:0.06em;text-transform:uppercase;margin-bottom:8px">次のステップ</div><div style="font-size:13px;color:#0C4A6E;line-height:1.7;margin-bottom:10px"><strong>STEP 2 — レビュー画像の提出</strong></div><div style="font-size:13px;color:#222;line-height:1.7">レシートが承認されました。掲載されたレビューのスクリーンショットを「活動管理」からアップロードしてください。</div></div>`;
  }
  if (kind === "review_image") {
    return `<div style="background:#F0FDF4;border:1px solid #BBF7D0;border-radius:8px;padding:16px 18px;margin-bottom:22px"><div style="font-size:11px;font-weight:700;color:#166534;letter-spacing:0.06em;text-transform:uppercase;margin-bottom:8px">次のステップ</div><div style="font-size:13px;color:#222;line-height:1.7"><strong>全ての提出が完了しました。</strong>担当者の最終確認のうえ、報酬のお支払いを進めます。</div></div>`;
  }
  // post
  return `<div style="background:#F0FDF4;border:1px solid #BBF7D0;border-radius:8px;padding:16px 18px;margin-bottom:22px"><div style="font-size:11px;font-weight:700;color:#166534;letter-spacing:0.06em;text-transform:uppercase;margin-bottom:8px">次のステップ</div><div style="font-size:13px;color:#222;line-height:1.7"><strong>投稿が承認されました。</strong>担当者の最終確認のうえ、報酬のお支払いを進めます。</div></div>`;
}

function rejectReasonBlock(reason: string): string {
  return `<div style="background:#FFF5F7;border-left:4px solid #E8344E;border-radius:0 8px 8px 0;padding:14px 18px;margin-bottom:22px"><div style="font-size:11px;font-weight:700;color:#A02038;letter-spacing:0.06em;text-transform:uppercase;margin-bottom:6px">差し戻し理由</div><div style="font-size:13px;color:#222;line-height:1.7;white-space:pre-wrap;word-break:break-word">${escapeHtml(reason)}</div></div>`;
}

// 공용 더미 데이터
const common = {
  influencer_name: "山田 さくら (やまだ さくら)",
  campaign_title: "スキンケア新製品レビューキャンペーン — フェイシャルセラム",
  campaign_brand: "REVERB Beauty",
  submitted_at: "2026年5月15日",
  reviewed_at: "2026年5月18日",
  activity_link: activityLink,
  site_url: siteUrl,
  help_line_url: helpLineUrl,
};

interface MailDef {
  type: string;       // 식별자
  template: string;   // 템플릿 파일명
  subject: string;
  extra: Record<string, string>;
}

const mails: MailDef[] = [
  { type: "receipt-approved",      template: "deliverable-receipt-approved",      subject: "【REVERB】レシートが承認されました — STEP 2 のご案内",        extra: { next_step_block: nextStepBlock("receipt") } },
  { type: "receipt-rejected",      template: "deliverable-receipt-rejected",      subject: "【REVERB】レシートの差し戻しのお知らせ",                       extra: { reject_reason_block: rejectReasonBlock("レシート画像が不鮮明で読み取れません。再撮影のうえ再提出をお願いします。") } },
  { type: "review-image-approved", template: "deliverable-review-image-approved", subject: "【REVERB】レビュー画像が承認されました",                       extra: { next_step_block: nextStepBlock("review_image") } },
  { type: "review-image-rejected", template: "deliverable-review-image-rejected", subject: "【REVERB】レビュー画像の差し戻しのお知らせ",                   extra: { reject_reason_block: rejectReasonBlock("PR タグ(#PR / #広告 / #プロモーション のいずれか)が確認できません。タグを含めて再投稿のうえ、画像を再提出してください。") } },
  { type: "post-approved",         template: "deliverable-post-approved",         subject: "【REVERB】投稿が承認されました — 最終確認に進みます",          extra: { next_step_block: nextStepBlock("post"), post_url: "https://www.instagram.com/p/test123/", post_channel: "instagram" } },
  { type: "post-rejected",         template: "deliverable-post-rejected",         subject: "【REVERB】投稿の差し戻しのお知らせ",                          extra: { reject_reason_block: rejectReasonBlock("ハッシュタグ #PR が抜けています。投稿を編集してから再提出してください。"), post_url: "https://www.instagram.com/p/test123/", post_channel: "instagram" } },
];

const targets = filter.length > 0 ? mails.filter((m) => filter.includes(m.type)) : mails;

if (targets.length === 0) {
  console.error(`❌ TYPES 환경변수에 매칭되는 메일이 없습니다. 가능: ${mails.map((m) => m.type).join(", ")}`);
  Deno.exit(1);
}

console.log(`📧 결과물 검수 메일 ${targets.length}종 발송 시작 — 수신: ${recipient}`);

async function sendOne(m: MailDef): Promise<void> {
  const tpl = await loadTemplate(m.template);
  const data = {
    ...common,
    influencer_name: escapeHtml(common.influencer_name),
    campaign_title: escapeHtml(common.campaign_title),
    campaign_brand: escapeHtml(common.campaign_brand),
    submitted_at: escapeHtml(common.submitted_at),
    reviewed_at: escapeHtml(common.reviewed_at),
    activity_link: escapeHtml(common.activity_link),
    site_url: escapeHtml(common.site_url),
    help_line_url: escapeHtml(common.help_line_url),
    ...m.extra,
  };
  let html = render(tpl, data);
  const banner = `<div style="background:#FFF3CD;border-left:4px solid #FFA000;padding:10px 14px;margin:0 0 12px;border-radius:6px;color:#5A4500;font-size:13px"><strong>⚠️ TEST MAIL — ${m.type}</strong><br>ダミーデータ。<code>scripts/send-test-deliverable-decision.ts</code></div>`;
  html = html.replace('<div style="font-family:', banner + '<div style="font-family:');

  const subject = `[TEST] ${m.subject}`;
  const res = await fetch(BREVO_ENDPOINT, {
    method: "POST",
    headers: { "api-key": apiKey, "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      sender: { email: env("BREVO_SENDER_EMAIL", "noreply@globalreverb.com"), name: env("BREVO_SENDER_NAME", "REVERB JP [TEST]") },
      to: [{ email: recipient }],
      subject,
      htmlContent: html,
      textContent: `[TEST] ${m.type} ダミー\n${activityLink}`,
    }),
  });
  if (!res.ok) {
    const errText = await res.text();
    console.error(`❌ ${m.type} 발송 실패 ${res.status}: ${errText}`);
    return;
  }
  const body = await res.json();
  console.log(`✅ ${m.type} 발송 성공 (${html.length}B) — ${body.messageId || "(id 없음)"}`);
}

for (const m of targets) {
  await sendOne(m);
  // Brevo rate-limit 회피용 약간의 간격
  await new Promise((r) => setTimeout(r, 400));
}

console.log(`📬 ${recipient} 받은편지함에서 ${targets.length}통 확인하세요.`);
