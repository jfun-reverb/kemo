// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-brand-restriction
// ──────────────────────────────────────────────────────────────────
// 브랜드 계정 이용 제한 · 결과물 열람 정지 알림 메일 다섯 — 관리자 브랜드 상세(admin-brand-sanction.js — 작업표 제한 10·11)가
// 쓰기 함수 성공 뒤 supabase.functions.invoke('notify-brand-restriction', { kind, ref_id }) 로 직접 부른다.
//   사양서 docs/specs/2026-10-21-brand-account-restriction.md 4-8 · A8·A9 · R4·R5 · F5·F6
//   작업표 docs/specs/2026-10-21-brand-account-restriction-breakdown.md 「제한 6」 · 기본값 3·4
//
// 입력  POST { kind, ref_id: uuid } · Authorization: Bearer <관리자 로그인 토큰>
//   kind    ref_id                 받는 사람(서버가 정함)                    양식
//   account_restrict  제한 줄       그 계정 한 사람(A8)                      brand-account-restricted
//   account_period    새 제한 줄    그 계정 한 사람                          brand-account-restriction-changed
//   account_lift      해제한 제한 줄 그 계정 한 사람                          brand-account-unrestricted
//   results_suspend   정지 줄       그 브랜드 대표·멤버(제한 계정 뺌 — R4·R5) brand-results-suspended
//   results_lift      해제한 정지 줄 그 브랜드 대표·멤버(제한 계정 뺌)         brand-results-unsuspended
// 출력  200 { sent:true, count, failed_count }
//     | 200 { sent:true, count, dev_mail:[{ to_masked, subject, text }] }   ← 개발 프로젝트(메일을 보내지 않는다 — 아래)
//     | 200 { sent:false, reason: 'disabled' | 'forbidden' | 'not_found' | 'not_eligible' | 'already_claimed'
//                                | 'no_recipient' | 'send_failed' }
//     | 400 invalid_request · 401 Unauthorized · 500 server_error
//   · disabled        — 잠금이 꺼져 있음(선점 안 함). 작업표 응답 목록에 더한 값(배송 메일 선례 — 2026-10-22 기획 확인)
//   · already_claimed — 같은 줄·같은 종류는 한 번만(「알림 1건 = 메일 1통」). 기간 바꾸기는 새 줄이라 줄마다 한 번(A1)
//   · not_eligible    — 종류와 줄 상태가 안 맞음(예: account_lift 인데 아직 걸린 줄 · 저절로 풀린 줄)
//   관리자 화면은 sent:false 전부를 「알림 메일을 보내지 못했습니다」로 그린다 — 제한·정지는 그대로 걸려 있다(4-8)
//
// 🔴 호출자 판정 = 그 사람 토큰으로 has_permission('brand.restriction_manage','write') — 쓰기 함수(제한 4)와 같은 등급.
//    선점 함수가 같은 판정을 p_caller 로 한 번 더 한다.
// 🔴 받는 사람·내용은 서버가 정한다 — service_claim_brand_sanction_mail(제한 4)이 돌려준 recipients·payload 로만.
//    요청 본문에서는 kind·ref_id 만 받는다(화면이 보낸 주소·사유를 쓰지 않는다 — mail-webhooks.md 「요청 본문을 믿지 않는다」).
// 🔴 「선점 먼저」 — 선점 → 1명당 1통 발송 → 결과 기록(service_mark_brand_sanction_mail_sent, 선점 시각 대조 — 561 방식).
//    1명 이상 성공이면 「보냄」(일부 실패 = ok:true + 실패 명단), 전원 실패·0명이면 선점을 되돌린다(p_ok:false).
// 🔴 두 겹 잠금 — ① 비밀값 BRAND_SANCTION_MAIL === "1" **그리고** ② 개발 프로젝트에서 돌 때만 켜진다.
//    운영 데이터베이스에는 제한·정지 표가 없다. 출시 날(제한 16) ①운영 비밀값을 넣고 ②mailEnabled() 의 isStagingProject() 를 걷는다.
// 🔴 개발 프로젝트에서는 메일을 실제로 보내지 않고 제목·본문을 응답 dev_mail 에 싣는다(devEcho()).
//    선점은 남기고 보냄 기록은 하지 않는다(notify-brand-invite 와 같은 방식) — 같은 요청을 다시 부르면 already_claimed.
//    관리자만 부르는 함수이고 본문은 그 관리자가 쓴 사유뿐이라 응답에 실어도 새는 것이 없다. 실제 발송 시험은 출시 날 운영에서.
// 🔴 사유 이름표(REASON_LABELS)는 관리자 모달(admin-brand-sanction.js — 제한 10·11)과 사본 두 벌 — 한쪽을 바꾸면 함께.
// 🔴 텍스트 판(buildMail 의 text)은 docs/email-templates/brand-*.html 다섯의 사본 — 양식을 고치면 함께.
// 브라우저가 직접 부른다 — CORS + OPTIONS 필수. 공개 키 거부는 걸지 않는다(판정은 로그인 토큰 + 권한).
//
// 환경변수: BREVO_API_KEY · BREVO_SENDER_EMAIL · BREVO_SENDER_NAME · PUBLIC_BRAND_URL(기본값 없음 — https 만, 정지 메일 둘) ·
//           BRAND_SANCTION_MAIL(개발서버에만 "1") · SUPABASE_URL·SUPABASE_ANON_KEY·SUPABASE_SERVICE_ROLE_KEY(자동 주입)
//   supabase secrets set BRAND_SANCTION_MAIL=1 --project-ref qysmxtipobomefudyixw
// 양식: docs/email-templates/brand-account-restricted.html 외 넷 → bash scripts/sync-email-templates.sh → templates.ts
// 배포: supabase functions deploy notify-brand-restriction --use-api --project-ref qysmxtipobomefudyixw   # 개발만(운영은 제한 16)
//   🔴 배포는 service_claim_brand_sanction_mail·service_mark_brand_sanction_mail_sent 가 있는 데이터베이스에서만(제한 4 적용 뒤)
// 로그: 주소·토큰·사유 설명을 남기지 않는다(종류·줄 번호 앞 8자리·결과만).
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TEMPLATES } from "./templates.ts";

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";
const STAGING_PROJECT_REF = "qysmxtipobomefudyixw";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const MAX_BODY_BYTES = 1024;

type Kind = "account_restrict" | "account_period" | "account_lift" | "results_suspend" | "results_lift";
const KINDS: Record<Kind, { refKind: "restriction" | "suspension"; template: string }> = {
  account_restrict: { refKind: "restriction", template: "brand-account-restricted" },
  account_period:   { refKind: "restriction", template: "brand-account-restriction-changed" },
  account_lift:     { refKind: "restriction", template: "brand-account-unrestricted" },
  results_suspend:  { refKind: "suspension",  template: "brand-results-suspended" },
  results_lift:     { refKind: "suspension",  template: "brand-results-unsuspended" },
};

// 선점 함수가 돌려주는 거부 중 화면에 그대로 넘기는 것
const CLAIM_REFUSALS = new Set(["forbidden", "not_found", "not_eligible", "already_claimed"]);

// 🔴 사본 두 벌 — 관리자 모달(admin-brand-sanction.js)과 같은 글자. 모르는 코드는 「기타」
const REASON_LABELS: Record<string, string> = {
  terms_8: "이용약관 제8조 위반(인플루언서 정보)",
  account_sharing: "계정 공유",
  other: "기타",
};

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

// 사유 설명은 관리자가 쓴 여러 줄 글 — 이스케이프 뒤 줄바꿈만 <br>
function escapeMultiline(s: string): string {
  return escapeHtml(s).replace(/\r?\n/g, "<br>");
}

// 🔴 두 겹 잠금(머리말) — 출시 때 mailEnabled() 의 isStagingProject() 조건만 걷는다. 비밀값 조건은 남긴다
function isStagingProject(): boolean {
  return env("SUPABASE_URL").includes(`://${STAGING_PROJECT_REF}.`);
}
function mailEnabled(): boolean {
  return env("BRAND_SANCTION_MAIL") === "1" && isStagingProject();
}
// 개발 프로젝트는 메일 대신 응답에 본문 — 출시 때도 걷지 않는다(개발서버는 계속 실제 발송 없음)
function devEcho(): boolean {
  return isStagingProject();
}

// 응답 dev_mail 용 — 앞 두 글자와 도메인만
function maskEmail(email: string): string {
  const at = email.indexOf("@");
  if (at <= 0) return "***";
  return `${email.slice(0, Math.min(2, at))}***${email.slice(at)}`;
}

// 'YYYY-MM-DD'(일본 날짜) → 'YYYY/MM/DD' · 그 밖은 빈 값
function fmtDate(v: unknown): string {
  const m = typeof v === "string" ? DATE_RE.exec(v.trim()) : null;
  return m ? `${m[1]}/${m[2]}/${m[3]}` : "";
}

function asText(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}

// deno-lint-ignore no-explicit-any
function buildMail(kind: Kind, p: any, recipientName: string, brandBase: string): { subject: string; html: string; text: string } {
  const reasonLabel = REASON_LABELS[asText(p?.reason_code)] || REASON_LABELS.other;
  const reasonNote = asText(p?.reason_note);
  const brandNamesList = Array.isArray(p?.brand_names) ? p.brand_names.map(asText).filter(Boolean) : [];
  const brandNames = brandNamesList.length ? brandNamesList.join(", ") : "없음";
  const brandName = asText(p?.brand_name) || "브랜드";
  const isAccount = KINDS[kind].refKind === "restriction";
  const greeting = recipientName ? `${recipientName} 님` : (isAccount ? "브랜드 페이지 담당자님" : `${brandName} 담당자님`);

  const until = fmtDate(p?.until_date);
  const untilText = until ? `${until}까지` : "해제할 때까지";
  const untilNote = until
    ? `${until}이 지나면 따로 연락 없이 다시 쓸 수 있습니다.`
    : "운영팀이 제한을 해제할 때까지 이어집니다.";
  const blockedItems = "캠페인 결과물 표 · 결과물 엑셀 · 영수증 사진" + (p?.include_shipping === true ? " · 시딩형 배송 리스트" : "");
  const brandUrl = `${brandBase}/brand/`;

  const html = render(TEMPLATES[KINDS[kind].template].replace(/<!--[\s\S]*?-->/g, ""), {
    recipient_name: escapeHtml(greeting),
    reason_label: escapeHtml(reasonLabel),
    reason_note: escapeMultiline(reasonNote),
    until_text: escapeHtml(untilText),
    until_note: escapeHtml(untilNote),
    brand_names: escapeHtml(brandNames),
    brand_name: escapeHtml(brandName),
    blocked_items: escapeHtml(blockedItems),
    brand_url: escapeHtml(brandUrl),
  });

  // 🔴 아래 텍스트 판은 양식 다섯의 사본 — 양식을 고치면 함께
  const reasonBlock = (title: string) => `[${title}]\n${reasonLabel}\n${reasonNote}\n\n`;
  const sentOnly = `이 메일은 발신 전용입니다.\n`;
  let subject = "";
  let text = "";
  switch (kind) {
    case "account_restrict":
      subject = "[REVERB JP] 브랜드 페이지 이용이 제한되었습니다";
      text = `${greeting}\n\n` +
        `이용약관에 따라 이 계정의 REVERB 브랜드 페이지 이용을 제한했습니다. 제한 중에는 로그인해도 브랜드 페이지의 정보를 볼 수 없습니다.\n\n` +
        reasonBlock("제한 사유") +
        `[제한 기간]\n${untilText}\n${untilNote}\n\n` +
        `[제한되는 브랜드]\n${brandNames}\n\n` +
        `같은 브랜드의 다른 담당자 계정은 이 제한과 상관없이 쓸 수 있습니다.\n\n` +
        `제한에 이의가 있으면 REVERB 운영팀 담당자에게 직접 문의해 주십시오.\n` + sentOnly;
      break;
    case "account_period":
      subject = "[REVERB JP] 브랜드 페이지 이용 제한 기간이 바뀌었습니다";
      text = `${greeting}\n\n` +
        `이 계정의 REVERB 브랜드 페이지 이용 제한 기간을 바꿨습니다. 제한 사유는 그대로입니다.\n\n` +
        `[바뀐 제한 기간]\n${untilText}\n${untilNote}\n\n` +
        reasonBlock("제한 사유") +
        `[제한되는 브랜드]\n${brandNames}\n\n` +
        `제한에 이의가 있으면 REVERB 운영팀 담당자에게 직접 문의해 주십시오.\n` + sentOnly;
      break;
    case "account_lift":
      subject = "[REVERB JP] 브랜드 페이지 이용 제한이 해제되었습니다";
      text = `${greeting}\n\n` +
        `이 계정의 REVERB 브랜드 페이지 이용 제한을 해제했습니다. 지금부터 다시 로그인해 브랜드 페이지를 쓸 수 있습니다.\n\n` +
        `[다시 쓸 수 있는 브랜드]\n${brandNames}\n\n` +
        reasonBlock("해제된 제한의 사유") +
        `궁금한 점은 REVERB 운영팀 담당자에게 직접 문의해 주십시오.\n` + sentOnly;
      break;
    case "results_suspend":
      subject = `[REVERB JP] 결과물 열람이 정지되었습니다 — ${brandName}`;
      text = `${greeting}\n\n` +
        `이용약관에 따라 「${brandName}」 브랜드의 캠페인 결과물 열람을 정지했습니다. 정지 중에도 캠페인 모집 현황과 일정은 브랜드 페이지에서 볼 수 있습니다.\n\n` +
        `[볼 수 없게 된 것]\n${blockedItems}\n\n` +
        reasonBlock("정지 사유") +
        `정지는 운영팀이 해제할 때까지 이어집니다.\n` +
        `브랜드 페이지: ${brandUrl}\n\n` +
        `이 메일은 「${brandName}」 브랜드에 연결된 계정 모두에게 보냈습니다.\n` +
        `정지에 이의가 있으면 REVERB 운영팀 담당자에게 직접 문의해 주십시오. ` + sentOnly;
      break;
    case "results_lift":
      subject = `[REVERB JP] 결과물 열람 정지가 해제되었습니다 — ${brandName}`;
      text = `${greeting}\n\n` +
        `「${brandName}」 브랜드의 캠페인 결과물 열람 정지를 해제했습니다. 지금부터 브랜드 페이지에서 결과물을 다시 볼 수 있습니다.\n\n` +
        `[다시 볼 수 있게 된 것]\n${blockedItems}\n\n` +
        reasonBlock("해제된 정지의 사유") +
        `브랜드 페이지: ${brandUrl}\n\n` +
        `이 메일은 「${brandName}」 브랜드에 연결된 계정 모두에게 보냈습니다.\n` +
        `궁금한 점은 REVERB 운영팀 담당자에게 직접 문의해 주십시오. ` + sentOnly;
      break;
  }
  return { subject, html, text };
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

  let kindRaw = "";
  let refId = "";
  try {
    const raw = await req.text();
    if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) return jsonResponse({ sent: false, reason: "invalid_request" }, 400);
    const body = JSON.parse(raw);
    kindRaw = typeof body?.kind === "string" ? body.kind : "";
    refId = typeof body?.ref_id === "string" ? body.ref_id : "";
  } catch (_) {
    return jsonResponse({ sent: false, reason: "invalid_request" }, 400);
  }
  if (!Object.prototype.hasOwnProperty.call(KINDS, kindRaw) || !UUID_RE.test(refId)) {
    return jsonResponse({ sent: false, reason: "invalid_request" }, 400);
  }
  const kind = kindRaw as Kind;
  const refKind = KINDS[kind].refKind;
  const tag = `${kind}:${refId.slice(0, 8)}`;
  // 선점을 쥐고 있는 동안 예외가 나면 바깥 catch 가 이것으로 되돌린다(안 그러면 그 줄·종류가 영영 already_claimed)
  let releaseHeld: (() => Promise<void>) | null = null;

  const url = env("SUPABASE_URL");
  const anonKey = env("SUPABASE_ANON_KEY");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return jsonResponse({ sent: false, reason: "server_error" }, 500);

  try {
    // 0) 호출자 — 그 사람 토큰으로 권한 판정(쓰기 함수와 같은 등급)
    const userDb = createClient(url, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const token = authHeader.replace(/^Bearer\s+/i, "").trim();
    const { data: who } = await userDb.auth.getUser(token);
    const callerId = who?.user?.id;
    if (!callerId) return jsonResponse({ error: "Unauthorized" }, 401);
    const { data: allowed, error: permErr } = await userDb.rpc("has_permission", { p_feature: "brand.restriction_manage", p_min: "write" });
    if (permErr) {
      console.error("[notify-brand-restriction] permission check failed", permErr.code || "rpc");
      return jsonResponse({ sent: false, reason: "server_error" }, 500);
    }
    if (allowed !== true) return jsonResponse({ sent: false, reason: "forbidden" });

    // 1) 잠금 — 꺼져 있으면 선점도 하지 않는다
    if (!mailEnabled()) return jsonResponse({ sent: false, reason: "disabled" });

    // 정지 메일 둘만 브랜드 페이지 주소를 싣는다(A9) — 그때만 비밀값을 요구한다
    const brandBase = env("PUBLIC_BRAND_URL").replace(/\/$/, "");
    if (refKind === "suspension" && !/^https:\/\/[^/\s]+$/.test(brandBase)) throw new Error("PUBLIC_BRAND_URL not configured");

    // 2) 선점 — 받는 사람·내용은 서버가 돌려준 값으로만
    const svc = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: claim, error: claimErr } = await svc.rpc("service_claim_brand_sanction_mail", {
      p_ref_kind: refKind, p_ref_id: refId, p_mail_kind: kind, p_caller: callerId,
    });
    if (claimErr) throw new Error(`claim failed ${claimErr.code || ""}`);
    // deno-lint-ignore no-explicit-any
    const c = (claim || {}) as any;
    const result = String(c.result || "");
    if (result !== "ok") {
      console.log("[notify-brand-restriction] claim refused", tag, result || "unknown");
      if (CLAIM_REFUSALS.has(result)) return jsonResponse({ sent: false, reason: result });
      return jsonResponse({ sent: false, reason: "server_error" }, 500);
    }
    const claimedAt = String(c.claimed_at || "");
    // 선점 시각이 없으면 결과 기록(시각 대조)이 불가능하다 — 보내지 않고 멈춘다(선점은 DB 의 오래된 선점 다시 잡기에 맡긴다)
    if (!claimedAt) {
      console.error("[notify-brand-restriction] claim returned no claimed_at", tag);
      return jsonResponse({ sent: false, reason: "server_error" }, 500);
    }
    // 결과 기록 — 한 번만(선점을 놓은 뒤에는 바깥 catch 가 다시 되돌리지 않게). 네트워크 예외도 여기서 삼킨다
    const mark = async (ok: boolean, failed: string[]) => {
      releaseHeld = null;
      try {
        const { error } = await svc.rpc("service_mark_brand_sanction_mail_sent", {
          p_ref_kind: refKind, p_ref_id: refId, p_mail_kind: kind, p_claimed_at: claimedAt, p_ok: ok, p_failed: failed,
        });
        if (error) console.error("[notify-brand-restriction] mark failed", tag, error.code || "rpc");
      } catch (e) {
        console.error("[notify-brand-restriction] mark threw", tag, (e as Error).message);
      }
    };
    releaseHeld = () => mark(false, []);

    // deno-lint-ignore no-explicit-any
    const recipients = (Array.isArray(c.recipients) ? c.recipients : []).filter((r: any) => r && typeof r.email === "string" && r.email.trim());
    if (!recipients.length) {
      await mark(false, []);
      console.warn("[notify-brand-restriction] no recipient", tag);
      return jsonResponse({ sent: false, reason: "no_recipient" });
    }

    // deno-lint-ignore no-explicit-any
    const mails = recipients.map((r: any) => {
      const email = String(r.email).trim().toLowerCase();
      const name = typeof r.name === "string" ? r.name.trim() : "";
      return { email, name, ...buildMail(kind, c.payload, name, brandBase) };
    });

    // 3-a) 개발 프로젝트 — 보내지 않고 응답에 싣는다. 선점은 남기고 보냄 기록은 안 한다(머리말)
    if (devEcho()) {
      releaseHeld = null;   // 의도된 보류 — 선점을 남긴다
      console.log("[notify-brand-restriction] dev echo (no mail sent)", tag, mails.length);
      return jsonResponse({
        sent: true,
        count: mails.length,
        dev_mail: mails.map((m: { email: string; subject: string; text: string }) => ({ to_masked: maskEmail(m.email), subject: m.subject, text: m.text })),
      });
    }

    // 3-b) 1명당 1통(받는 사람끼리 주소가 안 보이게)
    const sent: string[] = [];
    const failed: string[] = [];
    for (const m of mails) {
      try {
        await sendBrevoEmail({ to: [{ email: m.email, name: m.name || undefined }], subject: m.subject, htmlContent: m.html, textContent: m.text });
        sent.push(m.email);
        releaseHeld = null;   // 한 통이라도 나갔으면 선점을 풀지 않는다(풀면 다시 불렀을 때 두 번 나간다)
      } catch (e) {
        console.error("[notify-brand-restriction] send failed", tag, (e as Error).message);
        failed.push(m.email);
      }
    }

    if (!sent.length) {
      await mark(false, []);
      return jsonResponse({ sent: false, reason: "send_failed" });
    }
    await mark(true, failed);
    console.log("[notify-brand-restriction] sent", tag, sent.length, failed.length);
    return jsonResponse({ sent: true, count: sent.length, failed_count: failed.length });
  } catch (e) {
    console.error("[notify-brand-restriction] error", tag, (e as Error).message);
    if (releaseHeld) await releaseHeld();
    return jsonResponse({ sent: false, reason: "server_error" }, 500);
  }
});
