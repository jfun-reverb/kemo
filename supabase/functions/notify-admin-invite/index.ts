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

// ilike 패턴 이스케이프 — 이메일에 든 _ · % 가 와일드카드로 해석되는 것을 막는다.
function escapeLikePattern(s: string): string {
  return s.replace(/[\\%_]/g, (m) => "\\" + m);
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
    //    promoted_at 도 함께 조회: 승격자(이미 인플루언서로 쓰던 계정)는 마이그레이션 245 이후
    //    기존 비밀번호가 그대로 유효하므로 메일 문구를 다르게 안내해야 한다.
    const { data: targetRow } = await sb
      .from("admins")
      .select("name, email, role, promoted_at")
      // 대소문자는 무시하되(저장된 값이 대문자일 수 있음 — eq 로 바꾸면 못 찾는다)
      // 와일드카드는 이스케이프한다. ilike 에서 _ 는 "아무 글자 1개", % 는 "아무 글자 0개 이상"
      // 이라, kim_a@… 같은 이메일이 kimXa@… 같은 다른 관리자 행과도 매칭될 수 있다.
      .ilike("email", escapeLikePattern(targetEmail))
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
    const rawLink = linkData?.properties?.action_link;
    if (!rawLink) throw new Error("generateLink returned no action_link");

    // ★메일에는 Supabase 검증 주소를 그대로 싣지 않는다 — 우리 페이지의 프래그먼트(#) 뒤에 담는다.
    //   이유: Supabase 재설정 링크는 검증 단계(GET)에서 즉시 소모되는 1회용이다. 그런데 메일 본문의
    //   링크는 사람이 누르기 전에 여러 주체가 먼저 연다 — Brevo 클릭 추적 서버, 메일 서비스의
    //   스팸·안전 검사기 등. 그 순간 토큰이 타버려 정작 받는 사람에게는 "만료된 링크"가 된다.
    //   (2026-07-20 운영에서 실제 발생. Brevo 는 트랜잭션 메일의 클릭 추적을 끄는 옵션 자체가 없음)
    //
    //   #(프래그먼트) 뒤는 **서버로 전송되지 않는다**. 그래서 추적 서버나 스캐너가 이 주소를 열어도
    //   Supabase 검증 주소는 건드려지지 않고, 브라우저에서 사람이 「계속」을 눌렀을 때 비로소 이동한다.
    //   → 사람이 실제로 누른 순간에만 소모된다. 업계 표준 대응(Supabase Discussion #41618).
    const adminBaseForLink = adminBase;
    const actionLink =
      `${adminBaseForLink}/admin-setpw.html?mode=${linkMode}#confirm=${encodeURIComponent(rawLink)}`;

    // 4) 메일 발송
    const adminName = String(targetRow.name || "").trim() || "관리자";
    const roleLabel = ROLE_LABEL[String(targetRow.role)] || String(targetRow.role || "");

    // 승격자 = 이미 인플루언서 등으로 쓰던 계정에 관리자 권한이 추가된 사람.
    // 마이그레이션 245 이후 이들의 기존 비밀번호는 유지되므로, 링크를 안 눌러도 로그인된다.
    // 「비밀번호를 설정하세요」라고 안내하면 사실과 어긋나므로 문구를 분기한다.
    const isPromoted = !!targetRow.promoted_at;
    const headline = isPromoted
      ? "REVERB JP 관리자 권한이 추가되었습니다"
      : "REVERB JP 관리자로 초대되었습니다";
    const lead = isPromoted
      ? "기존에 쓰시던 이메일과 비밀번호로 그대로 관리자 페이지에 로그인하실 수 있습니다. 비밀번호를 바꾸고 싶으시면 아래 버튼을 눌러 주세요."
      : "아래 버튼을 눌러 사용하실 비밀번호를 설정해 주세요. 설정을 마치면 바로 관리자 페이지에 로그인하실 수 있습니다.";
    const ctaLabel = isPromoted ? "비밀번호 변경하기" : "비밀번호 설정하기";

    const subject = linkMode === "reset"
      ? "[REVERB JP] 관리자 비밀번호 재설정"
      : (isPromoted
        ? "[REVERB JP] 관리자 권한이 추가되었습니다"
        : "[REVERB JP] 관리자 계정 초대 — 비밀번호를 설정해 주세요");
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
      headline: escapeHtml(headline),
      lead: escapeHtml(lead),
      cta_label: escapeHtml(ctaLabel),
    });
    const text =
      `${adminName} 님\n\n` +
      `${headline}.\n` +
      `${lead}\n\n` +
      `링크: ${actionLink}\n` +
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

    // 발송 성공 기록 — 목록의 「발송됨/미발송」 표시와 재발송 판단 근거(마이그레이션 244).
    // 기록 실패가 발송 성공을 무효화하지 않는다(notify-orient-sheet 와 동일 패턴).
    const { error: trackErr } = await sb
      .from("admins")
      .update({ invite_mail_sent_at: new Date().toISOString(), invite_mail_sent_to: targetRow.email })
      // 조회로 확정된 행의 저장값 그대로 정확 일치 — 여기선 대소문자 문제가 없다
      .eq("email", targetRow.email);
    if (trackErr) console.error("[notify-admin-invite] tracking update failed", trackErr.message);

    return jsonResponse({ sent: true, recipient: targetRow.email }, 200);
  } catch (e) {
    const msg = (e as Error).message || "unknown";
    console.error("[notify-admin-invite] error", msg, (e as Error).stack);
    return jsonResponse({ sent: false, error: msg }, 500);
  }
});
