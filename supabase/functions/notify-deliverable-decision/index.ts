// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-deliverable-decision
// ──────────────────────────────────────────────────────────────────
// 트리거: Supabase Database Webhook (notifications INSERT)
// 역할:   결과물(deliverables) 검수 알림 메일 자동 발송
//          - kind='deliverable_approved' / 'deliverable_rejected' 만 처리
//          - kind='deliverable_changed'(되돌리기) 는 메일 미발송 (알림 패널만)
//          - mail_sent_at IS NULL 가드로 중복 발송 차단
//
// 환경변수 (Edge Functions Secrets):
//   BREVO_API_KEY        Brevo Transactional API 키
//   BREVO_SENDER_EMAIL   발신자 이메일 (기본 noreply@globalreverb.com)
//   BREVO_SENDER_NAME    발신자 이름 (기본 환경별 REVERB JP 또는 REVERB JP [DEV])
//   PUBLIC_SITE_URL      인플루언서 사이트 루트 URL (기본 https://globalreverb.com)
//
// HTML 템플릿 (kind × status):
//   _templates/deliverable-receipt-approved.html
//   _templates/deliverable-receipt-rejected.html
//   _templates/deliverable-review-image-approved.html
//   _templates/deliverable-review-image-rejected.html
//   _templates/deliverable-post-approved.html
//   _templates/deliverable-post-rejected.html
//
//   원본은 docs/email-templates/ 에 있고, scripts/sync-email-templates.sh 가
//   _templates/ 로 복사한다. Edge Function 배포 직전 반드시 sync 실행.
//
// 멱등성:
//   1. 발송 직전 notifications.mail_sent_at 가 여전히 NULL 인지 재확인 (행 잠금).
//   2. Brevo 200 응답 후에만 mail_sent_at = now() 로 마킹.
//   3. 실패 시 NULL 유지 → 운영자가 수동 SQL 로 재발송 가능.
//
// 배포 명령:
//   bash scripts/sync-email-templates.sh
//   # 개발
//   supabase functions deploy notify-deliverable-decision --project-ref qysmxtipobomefudyixw
//   # 운영
//   supabase functions deploy notify-deliverable-decision --project-ref twofagomeizrtkwlhsuv
//   # 비밀값
//   supabase secrets set BREVO_API_KEY=xxx --project-ref <ref>
//
// Webhook 설정 (Supabase Dashboard → Database → Webhooks):
//   Table: notifications
//   Events: INSERT
//   Type: Supabase Edge Functions
//   Edge Function: notify-deliverable-decision
//   HTTP Method: POST
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface NotificationRow {
  id: string;
  user_id: string;
  kind: string;
  ref_table: string | null;
  ref_id: string | null;
  title: string | null;
  body: string | null;
  read_at: string | null;
  mail_sent_at: string | null;
  created_at: string;
}

interface WebhookPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  schema: string;
  record: NotificationRow;
  old_record?: NotificationRow | null;
}

// 메일 발송 대상 kind 화이트리스트 (확장은 이 배열만 수정)
const MAIL_KINDS = new Set(["deliverable_approved", "deliverable_rejected"]);

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

function fmtDateJa(iso?: string | null): string {
  if (!iso) return "-";
  try {
    const d = new Date(iso);
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const day = String(d.getDate()).padStart(2, "0");
    return `${y}/${m}/${day}`;
  } catch {
    return "-";
  }
}

// ──────────────────────────────────────────────────────────────────
// HTML 템플릿 로딩 + placeholder 치환 (notify-brand-application 패턴 동일)
// ──────────────────────────────────────────────────────────────────
const TEMPLATE_CACHE = new Map<string, string>();

async function loadTemplate(name: string): Promise<string> {
  const cached = TEMPLATE_CACHE.get(name);
  if (cached) return cached;
  const url = new URL(`./_templates/${name}.html`, import.meta.url);
  const html = await Deno.readTextFile(url);
  TEMPLATE_CACHE.set(name, html);
  return html;
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

// 결과물 종류별 일본어 라벨 (제목 분기용)
function kindLabelJa(kind: string): string {
  if (kind === "receipt") return "レシート";
  if (kind === "review_image") return "レビュー画像";
  if (kind === "post") return "投稿URL";
  return "成果物";
}

// 템플릿 파일명: kind + decision (approved/rejected)
function templateName(kind: string, decision: "approved" | "rejected"): string {
  // receipt / review_image / post 외 kind 는 fallback (review_image 템플릿 사용)
  const k = kind === "receipt" || kind === "review_image" || kind === "post" ? kind : "receipt";
  return `deliverable-${k}-${decision}`;
}

// 사용자 입력 URL을 href 에 안전하게 삽입하기 위한 검증.
// http(s) 외 스킴(javascript:, data: 등)을 차단해 XSS 위험 제거.
function safeUrl(url: string): string {
  if (!url) return "";
  try {
    const u = new URL(url);
    if (u.protocol === "http:" || u.protocol === "https:") return escapeHtml(url);
    return "";
  } catch {
    return "";
  }
}

// 승인 메일에 들어갈 "다음 단계" 안내 블록 (kind 별 분기).
// receipt(영수증 승인)        → STEP 2 리뷰 이미지 제출 안내
// review_image(monitor 최종)  → 전 제출 완료, 보상 지급 대기
// post(gifting/visit 최종)    → 게시 URL 검수 완료, 보상 지급 대기
// rejected 케이스에서는 호출되지 않음(템플릿 자체가 다름).
function buildNextStepBlock(kind: string, activityLink: string): string {
  if (kind === "receipt") {
    return (
      `<div style="background:#F0F9FF;border:1px solid #BAE6FD;border-radius:8px;padding:16px 18px;margin-bottom:22px">` +
      `<div style="font-size:11px;font-weight:700;color:#075985;letter-spacing:0.06em;text-transform:uppercase;margin-bottom:8px">次のステップ</div>` +
      `<div style="font-size:13px;color:#0C4A6E;line-height:1.7;margin-bottom:10px"><strong>STEP 2 — レビュー画像の提出</strong></div>` +
      `<div style="font-size:13px;color:#222;line-height:1.7">レシートが承認されました。掲載されたレビューのスクリーンショットを「活動管理」からアップロードしてください。</div>` +
      `</div>`
    );
  }
  if (kind === "review_image") {
    return (
      `<div style="background:#F0FDF4;border:1px solid #BBF7D0;border-radius:8px;padding:16px 18px;margin-bottom:22px">` +
      `<div style="font-size:11px;font-weight:700;color:#166534;letter-spacing:0.06em;text-transform:uppercase;margin-bottom:8px">次のステップ</div>` +
      `<div style="font-size:13px;color:#222;line-height:1.7"><strong>全ての提出が完了しました。</strong>担当者の最終確認のうえ、報酬のお支払いを進めます。今しばらくお待ちください。</div>` +
      `</div>`
    );
  }
  if (kind === "post") {
    return (
      `<div style="background:#F0FDF4;border:1px solid #BBF7D0;border-radius:8px;padding:16px 18px;margin-bottom:22px">` +
      `<div style="font-size:11px;font-weight:700;color:#166534;letter-spacing:0.06em;text-transform:uppercase;margin-bottom:8px">次のステップ</div>` +
      `<div style="font-size:13px;color:#222;line-height:1.7"><strong>投稿URLの審査が完了しました。</strong>担当者の最終確認のうえ、報酬のお支払いを進めます。今しばらくお待ちください。</div>` +
      `</div>`
    );
  }
  return "";
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  let payload: WebhookPayload;
  try {
    payload = (await req.json()) as WebhookPayload;
  } catch (e) {
    return new Response(JSON.stringify({ error: `invalid json: ${(e as Error).message}` }), {
      status: 400,
      headers: { "content-type": "application/json" },
    });
  }

  console.log("[notify-deliverable-decision] payload received", {
    type: payload?.type,
    table: payload?.table,
    record_id: payload?.record?.id,
    kind: payload?.record?.kind,
  });

  // INSERT on notifications 만 처리
  if (payload.type !== "INSERT" || payload.table !== "notifications") {
    return new Response(JSON.stringify({ skipped: true, reason: "non-insert-or-wrong-table" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  const note = payload.record;
  if (!note?.id || !note.kind || !note.user_id) {
    console.error("[notify-deliverable-decision] invalid payload", { note });
    return new Response(JSON.stringify({ error: "invalid payload" }), {
      status: 400,
      headers: { "content-type": "application/json" },
    });
  }

  // kind 화이트리스트 필터: 메일 대상 아닌 알림은 즉시 종료
  if (!MAIL_KINDS.has(note.kind)) {
    console.log("[notify-deliverable-decision] kind not in MAIL_KINDS, skipped", { kind: note.kind });
    return new Response(JSON.stringify({ skipped: true, reason: `kind=${note.kind}` }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  // ref_table이 deliverables가 아니면 무시 (방어적)
  if (note.ref_table !== "deliverables" || !note.ref_id) {
    console.log("[notify-deliverable-decision] ref_table not deliverables, skipped", { ref_table: note.ref_table });
    return new Response(JSON.stringify({ skipped: true, reason: "ref_table_mismatch" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  // 멱등성 1차: 페이로드의 mail_sent_at가 이미 채워져 있으면 즉시 종료
  if (note.mail_sent_at) {
    console.log("[notify-deliverable-decision] already sent (payload), skipped", { mail_sent_at: note.mail_sent_at });
    return new Response(JSON.stringify({ skipped: true, reason: "already_sent_payload" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) {
    console.error("[notify-deliverable-decision] missing supabase env");
    return new Response(JSON.stringify({ error: "missing supabase env" }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }

  const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

  // 멱등성 2차: 발송 직전 DB 재확인 (Webhook 재실행 등 race 방지)
  const { data: noteCheck, error: noteCheckErr } = await sb
    .from("notifications")
    .select("id, mail_sent_at")
    .eq("id", note.id)
    .maybeSingle();
  if (noteCheckErr) {
    console.error("[notify-deliverable-decision] note re-check failed", noteCheckErr);
    return new Response(JSON.stringify({ error: noteCheckErr.message }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
  if (noteCheck?.mail_sent_at) {
    console.log("[notify-deliverable-decision] already sent (db re-check), skipped");
    return new Response(JSON.stringify({ skipped: true, reason: "already_sent_db" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  // 결과물 + 캠페인 + 인플루언서 정보 조회
  const { data: deliv, error: delivErr } = await sb
    .from("deliverables")
    .select(`
      id, kind, status, post_url, post_channel,
      submitted_at, reviewed_at, reject_reason,
      campaigns:campaign_id (id, title, brand)
    `)
    .eq("id", note.ref_id)
    .maybeSingle();
  if (delivErr || !deliv) {
    console.error("[notify-deliverable-decision] deliverable fetch failed", delivErr);
    return new Response(JSON.stringify({ error: "deliverable not found" }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }

  const { data: inf, error: infErr } = await sb
    .from("influencers")
    .select("id, email, name, name_kanji")
    .eq("id", note.user_id)
    .maybeSingle();
  if (infErr || !inf?.email) {
    console.error("[notify-deliverable-decision] influencer fetch failed", infErr);
    return new Response(JSON.stringify({ error: "influencer not found or email missing" }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }

  const decision: "approved" | "rejected" = note.kind === "deliverable_approved" ? "approved" : "rejected";
  const camp = (deliv as any).campaigns || {};
  const siteUrl = env("PUBLIC_SITE_URL", "https://globalreverb.com");
  const helpLineUrl = "https://line.me/R/ti/p/@reverb.jp";
  const activityLink = `${siteUrl.replace(/\/$/, "")}/#mypage-applications`;
  const influencerName = inf.name_kanji || inf.name || "";
  const kindLabel = kindLabelJa(deliv.kind);

  // 제목: notifications.title이 있으면 그대로 사용 (트리거가 이미 캠페인명 + 종류별 라벨 조합)
  // 폴백: 캠페인명 + 종류 라벨 + 결정
  const subject = note.title || `${camp.title || "キャンペーン"} — ${kindLabel}が${decision === "approved" ? "承認" : "差し戻し"}されました`;

  // 반려 사유 박스 (rejected 전용)
  const rejectReasonBlock = decision === "rejected" && deliv.reject_reason
    ? `<div style="background:#FFF5F7;border-left:4px solid #E8344E;border-radius:0 8px 8px 0;padding:14px 18px;margin-bottom:22px">` +
      `<div style="font-size:11px;font-weight:700;color:#A02038;letter-spacing:0.06em;text-transform:uppercase;margin-bottom:6px">差し戻し理由</div>` +
      `<div style="font-size:13px;color:#222;line-height:1.7;white-space:pre-wrap;word-break:break-word">${escapeHtml(deliv.reject_reason)}</div>` +
      `</div>`
    : "";

  // 승인 케이스에만 들어가는 다음 단계 안내 블록 (kind 별 분기).
  const nextStepBlock = decision === "approved" ? buildNextStepBlock(deliv.kind, activityLink) : "";

  // 템플릿 변수 빌드 (placeholder 키는 모든 6개 템플릿에서 공통)
  // post_url 은 href 속성에 들어가므로 http(s) 스킴만 통과시키는 safeUrl 적용.
  const templateData: Record<string, string> = {
    influencer_name: escapeHtml(influencerName || "-"),
    campaign_title: escapeHtml(camp.title || "-"),
    campaign_brand: escapeHtml(camp.brand || "-"),
    submitted_at: fmtDateJa(deliv.submitted_at),
    reviewed_at: fmtDateJa(deliv.reviewed_at),
    reject_reason_block: rejectReasonBlock,
    next_step_block: nextStepBlock,
    post_url: safeUrl(deliv.post_url || ""),
    post_channel: escapeHtml(deliv.post_channel || ""),
    activity_link: activityLink,
    site_url: siteUrl,
    help_line_url: helpLineUrl,
  };

  const tplName = templateName(deliv.kind, decision);
  let tpl: string;
  try {
    tpl = await loadTemplate(tplName);
  } catch (e) {
    console.error("[notify-deliverable-decision] template load failed", { tplName, err: (e as Error).message });
    return new Response(JSON.stringify({ error: `template not found: ${tplName}` }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }

  const html = render(tpl, templateData);

  // 텍스트 본문: 제목 + 캠페인 + 종류 + 결정 + 활동관리 링크 (간소화)
  const textLines = [
    `${camp.title || "キャンペーン"} — ${kindLabel}${decision === "approved" ? "が承認されました" : "が差し戻されました"}`,
    "",
    `${influencerName ? influencerName + " 様" : ""}`,
    decision === "approved"
      ? `提出いただいた${kindLabel}が承認されました。`
      : `提出いただいた${kindLabel}を確認したところ、差し戻しとさせていただきました。`,
    "",
    `キャンペーン: ${camp.title || "-"}`,
    `ブランド: ${camp.brand || "-"}`,
    `提出日: ${fmtDateJa(deliv.submitted_at)}`,
    decision === "approved" ? `承認日: ${fmtDateJa(deliv.reviewed_at)}` : `差し戻し日: ${fmtDateJa(deliv.reviewed_at)}`,
  ];
  if (decision === "rejected" && deliv.reject_reason) {
    textLines.push("");
    textLines.push("差し戻し理由:");
    textLines.push(deliv.reject_reason);
  }
  textLines.push("");
  textLines.push(`活動管理: ${activityLink}`);
  textLines.push(`お問い合わせ LINE: ${helpLineUrl}`);
  const text = textLines.join("\n");

  // Brevo 발송
  try {
    console.log("[notify-deliverable-decision] sending email", { to: inf.email, subject, kind: deliv.kind, decision });
    await sendBrevoEmail({
      to: [{ email: inf.email, name: influencerName || undefined }],
      subject,
      htmlContent: html,
      textContent: text,
    });
  } catch (e) {
    console.error("[notify-deliverable-decision] brevo send failed", (e as Error).message);
    return new Response(JSON.stringify({ error: (e as Error).message, sent: false }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }

  // 발송 성공 → mail_sent_at 마킹
  const { error: markErr } = await sb
    .from("notifications")
    .update({ mail_sent_at: new Date().toISOString() })
    .eq("id", note.id)
    .is("mail_sent_at", null);
  if (markErr) {
    console.error("[notify-deliverable-decision] mark mail_sent_at failed", markErr);
    // 메일은 이미 나갔으므로 200 으로 응답하되 경고 로그만
  }

  console.log("[notify-deliverable-decision] done", { id: note.id, kind: deliv.kind, decision });
  return new Response(JSON.stringify({ sent: true, kind: deliv.kind, decision }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
});
