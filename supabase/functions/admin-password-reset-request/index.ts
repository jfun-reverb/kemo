// ══════════════════════════════════════════════════════════════════
// Edge Function: admin-password-reset-request
// ──────────────────────────────────────────────────────────────────
// 트리거: 관리자 로그인 화면(/admin-setpw.html?mode=login)의
//          「비밀번호를 잊으셨나요」 → forgot 모드에서 익명 호출.
//
// ★이 함수는 이 프로젝트에서 유일하게 "로그인 없이 메일 발송을 유발할 수 있는 공개 경로"다.
//   그래서 다른 메일 함수와 설계 원칙이 두 가지 다르다:
//
//   1) 계정 존재 여부를 절대 노출하지 않는다 (security.md 「계정 열거 방지」)
//      - 관리자든 아니든, 요청 제한에 걸렸든 아니든, 오류가 났든 아니든
//        응답 본문·상태 코드·소요 시간·화면이 **완전히 동일**해야 한다.
//      - 「요청이 너무 많습니다」 같은 메시지도 금지 — 제한은 실재하는 이메일에서만
//        자주 걸리므로 그 문구 자체가 "이 주소는 관리자다"라는 신호가 된다.
//
//   2) Auth Rate Limits 의 보호를 못 받는다
//      - 운영 Supabase 의 「Rate limit for sending emails = 100/h」는 Auth 가 **직접**
//        보내는 메일에만 적용된다. 우리는 generateLink 로 링크만 받아 Brevo 로 직접 보내므로
//        그 한도를 통과하지 않는다.
//      - 방치하면 ①특정 관리자에게 메일 폭탄 ②Brevo 월 20,000통 소진 →
//        광고주 알림·일일 다이제스트·인플루언서 메일이 **전부 함께 죽는다**.
//      - 그래서 요청 제한을 자체 구현한다(마이그레이션 243).
//
// 흐름:
//   1) 이메일 형식·길이 검사 (형식 불량은 DB 를 아예 안 탐)
//   2) 이메일을 sha256 해시로 변환 — 요청 기록 표에 원문을 남기지 않는다
//      (이 표는 요청만 하면 행이 쌓이는 공개 경로라, 유출 시 관리자 이메일 명단이 되면 안 됨)
//   3) check_admin_password_reset_rate_limit 으로 3층 제한 판정 + 기록
//   4) 통과 + 대상이 실제 admins 행이면 generateLink + Brevo 발송
//   5) 무슨 일이 있었든 **항상 같은 응답을 같은 시각에** 반환
//
// 환경변수 (Edge Functions Secrets):
//   BREVO_API_KEY / PUBLIC_ADMIN_URL / BREVO_SENDER_EMAIL / BREVO_SENDER_NAME
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY  (런타임 자동 주입)
//
// 배포 (개발 → 운영 양 환경 모두):
//   bash scripts/sync-email-templates.sh
//   supabase functions deploy admin-password-reset-request --project-ref qysmxtipobomefudyixw
//   supabase functions deploy admin-password-reset-request --project-ref nrwtujmlbktxjgdwlpjj
//
// ⚠️ 이 프로젝트 최초의 "익명 호출 Edge Function" 이다. 게이트웨이가 anon 키를 유효한 토큰으로
//    받아들여 통과시키는 것이 정상 동작이나, 검증된 선례가 없으므로 배포 후 개발서버에서
//    실제 호출 1회로 반드시 확인할 것(형식이 틀린 이메일로 호출하면 메일 발송 없이 확인 가능).
//    게이트웨이에서 막히면 우리 함수 형식과 다른 {"code":401,...} 응답이 오므로 바로 구분된다.
//    그 경우 supabase/config.toml 에 verify_jwt = false 를 명시한다.
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TEMPLATES } from "./templates.ts";

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";

// ★최소 응답 시간(밀리초) — 하한만 강제한다. 상한은 **의도적으로 두지 않는다.**
//   상한을 둬서 generateLink + Brevo 발송을 중간에 끊으면, 그 절단 자체가 신호가 되거나
//   발송이 불완전한 상태로 남는 쪽이 더 위험하다(사양서 §D-9).
//   대신 이 값을 왕복의 현실적 최악값보다 넉넉히 잡아(초안 800 → 2500) 초과 확률을 낮춘다.
//   잔여 위험(수용): 극단적 네트워크 지연으로 발송 경로가 2500 을 넘기면 그 요청만 드물게
//   더 오래 걸린다. 줄이려면 이 값을 올릴 것 — 발송을 중단하는 방식으로 바꾸지 말 것.
const FIXED_RESPONSE_MS = 2500;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

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

async function sha256Hex(input: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function sendBrevoEmail(params: {
  to: { email: string; name?: string }[];
  subject: string;
  htmlContent: string;
  textContent: string;
}): Promise<void> {
  const apiKey = env("BREVO_API_KEY");
  if (!apiKey) throw new Error("BREVO_API_KEY not configured");

  const res = await fetch(BREVO_ENDPOINT, {
    method: "POST",
    headers: { "api-key": apiKey, "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      sender: {
        email: env("BREVO_SENDER_EMAIL", "noreply@globalreverb.com"),
        name: env("BREVO_SENDER_NAME", "REVERB JP"),
      },
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

// 실제 처리. 무엇이 일어났든 예외를 밖으로 던지지 않고 로그만 남긴다
// (호출자에게는 어떤 경우에도 동일한 응답이 가야 하므로).
async function process(rawEmail: unknown): Promise<void> {
  const email = (typeof rawEmail === "string" ? rawEmail : "").trim().toLowerCase();

  // 1) 형식·길이 검사 — 불량이면 DB 도 안 탄다(요청 기록에 쓰레기가 쌓이는 것 방지)
  if (!email || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return;
  }

  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) {
    console.error("[admin-password-reset-request] service credentials not configured");
    return;
  }
  const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

  // 2) 대상이 관리자인지 확인 (결과는 절대 응답에 반영하지 않는다)
  const { data: adminRow } = await sb
    .from("admins")
    .select("name, email")
    .ilike("email", email)
    .maybeSingle();

  // 3) 요청 제한 판정 + 기록. 매칭 여부와 무관하게 항상 호출한다
  //    (미매칭 요청도 세야 무작위 이메일 난사로 메일 한도를 태우는 것을 막는다)
  const emailHash = await sha256Hex(email);
  const { data: allowed, error: rlErr } = await sb.rpc("check_admin_password_reset_rate_limit", {
    p_email_hash: emailHash,
    p_matched: !!adminRow,
  });
  if (rlErr) {
    console.error("[admin-password-reset-request] rate limit rpc failed", rlErr.message);
    return;
  }
  if (allowed !== true) {
    // 제한에 걸림 — 조용히 종료. 호출자는 이 사실을 알 수 없다.
    console.log("[admin-password-reset-request] rate limited", { matched: !!adminRow });
    return;
  }
  if (!adminRow) {
    // 관리자가 아님 — 아무것도 하지 않는다.
    console.log("[admin-password-reset-request] no admin for requested address");
    return;
  }

  // 4) 재설정 링크 발급 + 발송
  const adminBase = env("PUBLIC_ADMIN_URL", "https://dev.globalreverb.com").replace(/\/$/, "");
  const redirectTo = `${adminBase}/admin-setpw.html?mode=reset`;
  const { data: linkData, error: linkErr } = await sb.auth.admin.generateLink({
    type: "recovery",
    email: adminRow.email,
    options: { redirectTo },
  });
  if (linkErr || !linkData?.properties?.action_link) {
    console.error("[admin-password-reset-request] generateLink failed", linkErr?.message);
    return;
  }

  const adminName = String(adminRow.name || "").trim() || "관리자";
  const expiresNote =
    "보안을 위해 이 링크는 일정 시간이 지나면 만료됩니다. 만료된 경우 다시 요청해 주세요.";
  // HTML 주석 strip — templates.ts 인라인 원본 주석이 메일 본문에 누출되는 것 차단
  const tpl = TEMPLATES["admin-password-reset"].replace(/<!--[\s\S]*?-->/g, "");
  const html = render(tpl, {
    admin_name: escapeHtml(adminName),
    link: escapeHtml(linkData.properties.action_link),
    expires: escapeHtml(expiresNote),
  });
  const text =
    `${adminName} 님\n\n` +
    `REVERB JP 관리자 비밀번호 재설정이 요청되었습니다.\n` +
    `아래 주소에서 새 비밀번호를 설정해 주세요.\n\n` +
    `재설정 링크: ${linkData.properties.action_link}\n\n` +
    `${expiresNote}\n` +
    `재설정 요청을 여러 번 하시면 가장 최근에 받은 링크만 사용할 수 있습니다.\n\n` +
    `본인이 요청하지 않으셨다면 이 메일을 무시하셔도 됩니다.\n`;

  await sendBrevoEmail({
    to: [{ email: adminRow.email, name: adminName }],
    subject: "[REVERB JP] 관리자 비밀번호 재설정",
    htmlContent: html,
    textContent: text,
  });
  console.log("[admin-password-reset-request] mail sent");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405, headers: CORS_HEADERS });
  }

  const startedAt = Date.now();

  let email: unknown = "";
  try {
    const body = await req.json();
    email = body?.email;
  } catch (_) {
    // 본문 파싱 실패도 조용히 넘어간다 — 아래에서 동일 응답으로 수렴
  }

  try {
    await process(email);
  } catch (e) {
    // 어떤 실패도 응답에 드러내지 않는다. 원인은 로그에만.
    console.error("[admin-password-reset-request] error", (e as Error).message);
  }

  // ★고정 시각까지 대기 후 반환 — 분기별 소요 시간 차이를 흡수한다
  const elapsed = Date.now() - startedAt;
  if (elapsed < FIXED_RESPONSE_MS) {
    await new Promise((r) => setTimeout(r, FIXED_RESPONSE_MS - elapsed));
  }

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { ...CORS_HEADERS, "content-type": "application/json" },
  });
});
