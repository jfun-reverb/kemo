// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-admin-invite
// ──────────────────────────────────────────────────────────────────
// 트리거: 관리자 계정 추가(invite_admin RPC) 직후 admin-accounts.js 가
//          supabase.functions.invoke('notify-admin-invite', { email, mode })
//          로 직접 호출 (Webhook 아님 — 추가 화면에서 발송 성공/실패를 즉시 표시).
//
// 왜 Supabase Auth 기본 발송(resetPasswordForEmail)을 안 쓰는가 — 이유 2가지:
//   1) 메일 문구: Auth 는 메일 종류별 템플릿이 1개라 "Reset password" 를
//      인플루언서 비밀번호 찾기와 공유한다. 관리자 초대 전용 한국어 문구가 불가능.
//   2) ★기능 자체★: 클라이언트가 flowType:'pkce' 라(dev/lib/supabase.js:38),
//      resetPasswordForEmail 은 "코드 교환 검증값(code verifier)" 을 호출한 브라우저에
//      저장한다. 관리자 초대는 super_admin 브라우저에서 호출하는데, 정작 링크를 여는 건
//      초대받은 사람의 다른 브라우저 → 검증값이 없어 코드 교환이 실패한다.
//      generateLink 는 서버(service_role)가 만들고 token_hash 기반이라 이 문제가 없다.
//      (사양서 docs/specs/2026-07-20-admin-invite-mail-and-setpw.md)
//
// 역할:
//   1) 호출자 인증 — super_admin 만 허용 (초대는 super 전용 작업)
//   2) 대상이 실제 admins 행인지 확인 (임의 이메일로 메일 쏘는 악용 차단)
//   3) auth.admin.generateLink 로 비밀번호 설정 링크 발급
//   4) Brevo 로 초대받은 관리자에게 1통 발송
//
// 환경변수 (Edge Functions Secrets):
//   BREVO_API_KEY          Brevo Transactional API 키
//   PUBLIC_ADMIN_URL       사이트 절대 URL (운영 https://globalreverb.com / 개발 https://dev.globalreverb.com)
//                          — 링크 도메인을 서버가 정한다(클라 조작 방지)
//   BREVO_SENDER_EMAIL     발신자 이메일 (기본 noreply@globalreverb.com)
//   BREVO_SENDER_NAME      발신자 이름 (기본 REVERB JP)
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY  (런타임 자동 주입)
//
// 템플릿:
//   templates.ts (sync-email-templates.sh 자동 생성) → TEMPLATES['admin-invite']
//   원본 docs/email-templates/admin-invite.html, 배포 전 sync 실행 필수.
//
// 배포 명령 (개발 → 운영 순서로 양 환경 모두 배포 필수):
//   bash scripts/sync-email-templates.sh
//   supabase functions deploy notify-admin-invite --project-ref qysmxtipobomefudyixw   # 개발
//   supabase functions deploy notify-admin-invite --project-ref nrwtujmlbktxjgdwlpjj   # 운영
//   supabase secrets set PUBLIC_ADMIN_URL=https://dev.globalreverb.com --project-ref qysmxtipobomefudyixw
//   supabase secrets set PUBLIC_ADMIN_URL=https://globalreverb.com --project-ref nrwtujmlbktxjgdwlpjj
//
// 메일 발송 테스트는 운영에서만 (supabase.md 정책 — 개발은 환경 동기화 + CORS 검증만).
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TEMPLATES } from "./templates.ts";

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";

// CORS — 이 함수는 관리자 화면(globalreverb.com 등)에서 supabase.functions.invoke 로 직접 호출한다.
// 다른 도메인(*.supabase.co) 호출이라 브라우저가 사전요청(OPTIONS)+응답 CORS 헤더를 요구.
// 헤더 없으면 브라우저가 응답을 차단(Network 에 "CORS error"). 인증은 아래 JWT+admins 검증으로 별도 보장.
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
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

const ROLE_LABEL: Record<string, string> = {
  super_admin: "최고관리자",
  campaign_admin: "캠페인 관리자",
  campaign_manager: "캠페인 매니저",
};

async function sendBrevoEmail(params: {
  to: { email: string; name?: string }[];
  subject: string;
  htmlContent: string;
  textContent: string;
}): Promise<void> {
  const apiKey = env("BREVO_API_KEY");
  if (!apiKey) throw new Error("BREVO_API_KEY not configured");

  const body = {
    sender: {
      email: env("BREVO_SENDER_EMAIL", "noreply@globalreverb.com"),
      name: env("BREVO_SENDER_NAME", "REVERB JP"),
    },
    to: params.to,
    subject: params.subject,
    htmlContent: params.htmlContent,
    textContent: params.textContent,
  };

  const res = await fetch(BREVO_ENDPOINT, {
    method: "POST",
    headers: { "api-key": apiKey, "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Brevo send failed ${res.status}: ${errText}`);
  }
}

Deno.serve(async (req: Request) => {
  // CORS 사전요청(preflight) — 브라우저가 실제 POST 전에 OPTIONS 로 허용 여부 확인
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405, headers: CORS_HEADERS });
  }

  try {
    const { email, mode } = await req.json();
    const targetEmail = (typeof email === "string" ? email : "").trim().toLowerCase();
    if (!targetEmail || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(targetEmail)) {
      return jsonResponse({ sent: false, error: "valid email required" }, 400);
    }
    // mode 는 착지 화면 문구만 좌우한다(초대 최초 설정 / 재설정).
    // 권한·검증 어디에도 이 값을 쓰지 않으므로 클라가 바꿔도 안전.
    const linkMode = mode === "reset" ? "reset" : "invite";

    const supaUrl = env("SUPABASE_URL");
    const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
    if (!supaUrl || !serviceKey) throw new Error("Supabase service credentials not configured");
    const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

    // 1) 호출자 인증 — super_admin 만 허용.
    //    anon 키는 공개되므로 JWT 검증 필수. 초대는 super 전용 작업이라
    //    notify-orient-sheet(전체 관리자 허용)보다 엄격하게 건다.
    const authHeader = req.headers.get("Authorization") ?? "";
    const anonKey = env("SUPABASE_ANON_KEY");
    const userSb = createClient(supaUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false },
    });
    const { data: authData } = await userSb.auth.getUser();
    const caller = authData?.user;
    if (!caller) {
      return jsonResponse({ sent: false, error: "Unauthorized" }, 401);
    }
    const { data: callerRow } = await sb
      .from("admins")
      .select("role")
      .eq("auth_id", caller.id)
      .maybeSingle();
    if (!callerRow || callerRow.role !== "super_admin") {
      return jsonResponse({ sent: false, error: "Forbidden" }, 403);
    }

    // 2) 대상이 실제 관리자인지 확인 — 임의 이메일로 메일 쏘는 악용 차단
    const { data: targetRow } = await sb
      .from("admins")
      .select("name, email, role")
      .ilike("email", targetEmail)
      .maybeSingle();
    if (!targetRow) {
      return jsonResponse({ sent: false, reason: "not_admin" }, 404);
    }

    // 3) 비밀번호 설정 링크 발급 (서버 발급 — 브라우저 검증값에 의존하지 않음)
    const adminBase = env("PUBLIC_ADMIN_URL", "https://dev.globalreverb.com").replace(/\/$/, "");
    const redirectTo = `${adminBase}/admin-setpw.html?mode=${linkMode}`;
    const { data: linkData, error: linkErr } = await sb.auth.admin.generateLink({
      type: "recovery",
      email: targetRow.email,
      options: { redirectTo },
    });
    if (linkErr) throw linkErr;
    const actionLink = linkData?.properties?.action_link;
    if (!actionLink) throw new Error("generateLink returned no action_link");

    // 4) 메일 발송
    const adminName = String(targetRow.name || "").trim() || "관리자";
    const roleLabel = ROLE_LABEL[String(targetRow.role)] || String(targetRow.role || "");
    const subject = linkMode === "reset"
      ? "[REVERB JP] 관리자 비밀번호 재설정"
      : "[REVERB JP] 관리자 계정 초대 — 비밀번호를 설정해 주세요";
    const expiresNote =
      "보안을 위해 이 링크는 일정 시간이 지나면 만료됩니다. 만료된 경우 최고관리자에게 재발송을 요청해 주세요.";

    // HTML 주석 strip — templates.ts 인라인 원본 주석이 메일 본문에 누출되는 것 차단
    // (메모리 mail_template_comment_leak)
    const tpl = TEMPLATES["admin-invite"].replace(/<!--[\s\S]*?-->/g, "");
    const html = render(tpl, {
      admin_name: escapeHtml(adminName),
      role_label: escapeHtml(roleLabel),
      link: escapeHtml(actionLink),
      expires: escapeHtml(expiresNote),
    });
    const text =
      `${adminName} 님\n\n` +
      `REVERB JP 관리자로 초대되었습니다.\n` +
      `아래 주소에서 사용하실 비밀번호를 설정해 주세요.\n\n` +
      `설정 링크: ${actionLink}\n` +
      `권한 등급: ${roleLabel}\n\n` +
      `${expiresNote}\n\n` +
      `관리자 페이지는 PC 화면에 맞춰 만들어져 있습니다. 실제 업무는 PC에서 이용해 주세요.\n`;

    await sendBrevoEmail({
      to: [{ email: targetRow.email, name: adminName }],
      subject,
      htmlContent: html,
      textContent: text,
    });
    console.log("[notify-admin-invite] mail sent", { to: targetRow.email, mode: linkMode });

    return jsonResponse({ sent: true, recipient: targetRow.email }, 200);
  } catch (e) {
    const msg = (e as Error).message || "unknown";
    console.error("[notify-admin-invite] error", msg, (e as Error).stack);
    return jsonResponse({ sent: false, error: msg }, 500);
  }
});
