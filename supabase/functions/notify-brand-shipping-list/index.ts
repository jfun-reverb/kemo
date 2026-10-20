// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-brand-shipping-list
// ──────────────────────────────────────────────────────────────────
// 배송 리스트 전달 알림 메일 — 관리자 배송 탭 「배송 리스트 전달」이 성공(delivered_now:true)한 직후
// 관리자 화면(admin-shipping.js — 조각 S3)이 supabase.functions.invoke('notify-brand-shipping-list', { campaign_id }) 로 직접 부른다.
//   작업표 docs/specs/2026-10-19-brand-seeding-shipping-list-breakdown.md 「조각 S7」 · 결정 5 · D14·D20·D23 · 피그마 bw05-95
//
// 입력  POST { campaign_id: uuid } · Authorization: Bearer <관리자 로그인 토큰>
// 출력  { sent:true, recipients:[보낸 주소], failed:[못 보낸 주소] }
//     | { sent:false, reason:'disabled' }       — 두 겹 잠금이 꺼져 있음(아래). 선점도 안 한다
//     | { sent:false, reason:'not_claimed' }    — 이미 보냈거나·다른 실행이 보내는 중이거나·전달 전(두 번째 호출이 여기로 온다)
//     | { sent:false, reason:'no_account' }     — 받을 계정이 0명(선점을 되돌린다)
//     | { sent:false, reason:'send_failed', failed:[…] } — 전원 실패(선점을 되돌려 다시 부르면 다시 시도)
//     | 401 Unauthorized · 403 Forbidden · 400 invalid_request · 500 server_error
//
// 🔴 호출자 판정 = 그 사람 토큰으로 has_permission('shipping.manage','write') — 배송 함수(557)와 같은 등급.
// 🔴 받는 사람은 서버가 정한다 — service_claim_shipping_mail(561)이 _brand_mailable_accounts(557 — notify-orient-sheet
//    resolveBrandAccountRecipients 의 사본)로 고른다. 화면이 넘긴 주소는 받지 않는다(요청 본문에서는 campaign_id 만).
// 🔴 한 캠페인 한 번(결정 5) — 「선점 먼저」(mail-webhooks.md): 선점 → 발송 → 결과 보고(선점 시각 대조 — 561).
//    1명 이상 보내면 「보냄」, 전원 실패·0명이면 선점을 되돌린다.
// 🔴 두 겹 잠금 — ① 비밀값 SHIPPING_MAIL_TO_BRAND_ACCOUNTS === "1" **그리고** ② 개발 프로젝트에서 돌 때만 보낸다
//    (notify-orient-sheet 와 같은 방식). 운영 데이터베이스에는 브랜드 계정·배송 표가 없다. 출시 때(L1) ①운영 비밀값을 넣고
//    ②isStagingProject() 조건을 걷어 운영에 다시 배포한다.
// 🔴 회원 정보(이름·주소·전화)는 메일에 넣지 않는다 — 캠페인 제품명·받는 사람 수·발송 기한·링크만.
// 브라우저가 직접 부른다 — CORS + OPTIONS 필수. 공개 키 거부는 걸지 않는다(판정은 로그인 토큰 + 권한).
//
// 환경변수: BREVO_API_KEY · BREVO_SENDER_EMAIL · BREVO_SENDER_NAME · PUBLIC_BRAND_URL(기본값 없음 — https 만) ·
//           SHIPPING_MAIL_TO_BRAND_ACCOUNTS(개발서버에만 "1") · SUPABASE_URL·SUPABASE_ANON_KEY·SUPABASE_SERVICE_ROLE_KEY(자동 주입)
//   supabase secrets set SHIPPING_MAIL_TO_BRAND_ACCOUNTS=1 --project-ref qysmxtipobomefudyixw
// 양식: docs/email-templates/brand-shipping-delivered.html → bash scripts/sync-email-templates.sh → templates.ts
// 배포: supabase functions deploy notify-brand-shipping-list --project-ref qysmxtipobomefudyixw   # 개발만(운영은 L1)
// 메일 발송 시험은 시험 계정(@example.com)만 — 개발서버 정책(supabase.md 「메일 발송 테스트 환경 정책」).
// 로그: 주소·토큰을 남기지 않는다.
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TEMPLATES } from "./templates.ts";

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";
const STAGING_PROJECT_REF = "qysmxtipobomefudyixw";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_BODY_BYTES = 1024;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "content-type": "application/json" },
  });
}

function env(key: string, fallback = ""): string {
  return Deno.env.get(key) ?? fallback;
}

function render(html: string, data: Record<string, string>): string {
  return html.replace(/\{\{(\w+)\}\}/g, (_m, key) => data[key] ?? "");
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

// 🔴 두 겹 잠금(머리말) — 출시 때 isStagingProject() 조건만 걷는다. 비밀값 조건은 남긴다
function isStagingProject(): boolean {
  return env("SUPABASE_URL").includes(`://${STAGING_PROJECT_REF}.`);
}
function mailEnabled(): boolean {
  return env("SHIPPING_MAIL_TO_BRAND_ACCOUNTS") === "1" && isStagingProject();
}

async function sendBrevoEmail(params: { to: { email: string; name?: string }[]; subject: string; htmlContent: string; textContent: string }): Promise<void> {
  const apiKey = env("BREVO_API_KEY");
  if (!apiKey) throw new Error("BREVO_API_KEY not configured");
  const res = await fetch(BREVO_ENDPOINT, {
    method: "POST",
    headers: { "api-key": apiKey, "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      sender: { email: env("BREVO_SENDER_EMAIL", "noreply@globalreverb.com"), name: env("BREVO_SENDER_NAME", "REVERB JP") },
      to: params.to,
      subject: params.subject,
      htmlContent: params.htmlContent,
      textContent: params.textContent,
    }),
  });
  if (!res.ok) throw new Error(`Brevo send failed ${res.status}`);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405, headers: CORS_HEADERS });

  const authHeader = req.headers.get("authorization") || "";
  if (!/^Bearer\s+\S+/i.test(authHeader)) return jsonResponse({ error: "Unauthorized" }, 401);

  let campaignId = "";
  try {
    const raw = await req.text();
    if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) return jsonResponse({ sent: false, reason: "invalid_request" }, 400);
    const body = JSON.parse(raw);
    campaignId = typeof body?.campaign_id === "string" ? body.campaign_id : "";
  } catch (_) {
    return jsonResponse({ sent: false, reason: "invalid_request" }, 400);
  }
  if (!UUID_RE.test(campaignId)) return jsonResponse({ sent: false, reason: "invalid_request" }, 400);

  const url = env("SUPABASE_URL");
  const anonKey = env("SUPABASE_ANON_KEY");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return jsonResponse({ sent: false, reason: "server_error" }, 500);

  try {
    // 0) 호출자 — 그 사람 토큰으로 권한 판정(배송 함수와 같은 등급)
    const userDb = createClient(url, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const token = authHeader.replace(/^Bearer\s+/i, "").trim();
    const { data: who } = await userDb.auth.getUser(token);
    if (!who?.user) return jsonResponse({ error: "Unauthorized" }, 401);
    const { data: allowed, error: permErr } = await userDb.rpc("has_permission", { p_feature: "shipping.manage", p_min: "write" });
    if (permErr) {
      console.error("[notify-brand-shipping-list] permission check failed", permErr.code || "rpc");
      return jsonResponse({ sent: false, reason: "server_error" }, 500);
    }
    if (allowed !== true) return jsonResponse({ error: "Forbidden" }, 403);

    // 1) 잠금 — 꺼져 있으면 선점도 하지 않는다(출시 때 다시 부를 수 있게)
    if (!mailEnabled()) return jsonResponse({ sent: false, reason: "disabled" });

    const brandBase = env("PUBLIC_BRAND_URL").replace(/\/$/, "");
    if (!/^https:\/\/[^/\s]+$/.test(brandBase)) throw new Error("PUBLIC_BRAND_URL not configured");

    // 2) 선점 — 받는 사람·내용은 서버가 돌려준 값으로만
    const svc = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: claim, error: claimErr } = await svc.rpc("service_claim_shipping_mail", { p_campaign_id: campaignId });
    if (claimErr) throw new Error(`claim failed ${claimErr.code || ""}`);
    if (!claim) return jsonResponse({ sent: false, reason: "not_claimed" });

    // deno-lint-ignore no-explicit-any
    const c = claim as any;
    const claimedAt = String(c.claimed_at || "");
    const release = async () => {
      const { error } = await svc.rpc("service_mark_shipping_mail_sent", { p_campaign_id: campaignId, p_ok: false, p_claimed_at: claimedAt });
      if (error) console.error("[notify-brand-shipping-list] release failed", error.code || "rpc");
    };

    // deno-lint-ignore no-explicit-any
    const recipients = (Array.isArray(c.recipients) ? c.recipients : []).filter((r: any) => r && typeof r.email === "string" && r.email);
    if (!recipients.length) {
      await release();
      console.warn("[notify-brand-shipping-list] no brand account recipient", { campaign_id: campaignId });
      return jsonResponse({ sent: false, reason: "no_account" });
    }

    const brandName = String(c.brand_name || "").trim() || "브랜드";
    const product = String(c.product || "").trim() || "캠페인";
    const count = String(Number(c.row_count) || 0);
    const deadline = String(c.deadline || "-");
    const link = `${brandBase}/brand/?shipping=${campaignId}`;
    const subject = `[REVERB JP] 배송 리스트가 전달되었습니다 — ${product}`;
    // HTML 주석 strip — 양식 머리 주석이 메일 본문에 새지 않게(notify-orient-sheet 와 같은 처리)
    const tpl = TEMPLATES["brand-shipping-delivered"].replace(/<!--[\s\S]*?-->/g, "");

    const sent: string[] = [];
    const failed: string[] = [];
    for (const r of recipients) {
      const name = typeof r.name === "string" ? r.name.trim() : "";
      const greeting = name ? `${name} 님` : `${brandName} 담당자님`;
      const html = render(tpl, {
        recipient_name: escapeHtml(greeting),
        brand_name: escapeHtml(brandName),
        product: escapeHtml(product),
        count: escapeHtml(count),
        deadline: escapeHtml(deadline),
        link: escapeHtml(link),
      });
      const text =
        `${greeting}\n\n` +
        `「${product}」 캠페인에 선정된 ${count}명의 배송 리스트를 REVERB 브랜드 페이지에 올렸습니다.\n` +
        `받은 날부터 3일 안에 제품을 보내고 송장번호를 등록해 주십시오.\n\n` +
        `발송 기한: ${deadline} (받은 날부터 3일)\n` +
        `배송 리스트 열기: ${link}\n\n` +
        `이 메일은 「${brandName}」 브랜드에 연결된 계정 모두에게 보냈습니다.\n` +
        `이 메일은 발신 전용입니다. 문의는 REVERB 운영팀 담당자에게 직접 연락해 주십시오.\n`;
      try {
        await sendBrevoEmail({ to: [{ email: r.email, name: name || brandName }], subject, htmlContent: html, textContent: text });
        sent.push(r.email);
      } catch (e) {
        console.error("[notify-brand-shipping-list] send failed", { campaign_id: campaignId, error: (e as Error).message });
        failed.push(r.email);
      }
    }

    if (!sent.length) {
      await release();
      return jsonResponse({ sent: false, reason: "send_failed", recipients: [], failed });
    }

    const { data: marked, error: markErr } = await svc.rpc("service_mark_shipping_mail_sent", {
      p_campaign_id: campaignId, p_ok: true, p_claimed_at: claimedAt,
    });
    if (markErr || marked !== true) {
      // 메일은 나갔다 — 기록만 못 했다(다른 실행이 선점을 다시 잡은 경우 등). 발송 결과는 그대로 알린다
      console.error("[notify-brand-shipping-list] mark sent failed", markErr?.code || "not_mine");
    }
    return jsonResponse({ sent: true, recipients: sent, failed });
  } catch (e) {
    console.error("[notify-brand-shipping-list] error", (e as Error).message);
    return jsonResponse({ sent: false, reason: "server_error" }, 500);
  }
});
