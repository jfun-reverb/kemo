// ══════════════════════════════════════════════════════════════════
// Edge Function: signup-code-send
// ──────────────────────────────────────────────────────────────────
// 용도: 회원가입 화면에서 이메일 인증번호(6자리)를 메일로 보낸다. 로그인 없이(공개 키로) 호출된다.
//
// 요청:  POST { email }
// 응답:  { ok:true, status:'sent', code_expires_at, resend_available_at }
//        { ok:true, status:'rate_limited', resend_available_at }
//        { ok:false, error:'invalid_email' | 'send_failed' | 'server_error' }
//
// 🔴 계정 존재 여부를 노출하지 않는다(사양서 완료 기준 10)
//   - 이 함수는 인증 계정·회원·탈퇴 표를 **조회하지 않는다**. 이미 가입된 주소든 탈퇴 차단 주소든
//     응답이 똑같다(구조로 보장). 가입 여부 안내는 인증번호 확인 단계 이후의 몫이다.
//   - 이메일 원문·번호·확인증은 로그에 남기지 않는다.
//
// 🔴 「공개 키 거부」(rejectPublicKeyCaller)는 일부러 걸지 않는다 — 브라우저가 공개 키로 부르는 함수다.
//   Brevo 직접 발송이라 인증 서비스 발송 한도의 보호가 없고, 보호는 DB 쪽 요청 제한
//   (signup_code_issue — 주소별 재발송 간격 + 전역 상한)이 유일하다.
//
// 해시 규격(마이그레이션 494 머리말이 정본):
//   email_hash = sha256hex(lower(trim(email)))
//   code_hash  = sha256hex(`${PEPPER}:${email_hash}:${code}`)   — PEPPER = env SIGNUP_CODE_PEPPER
//   ⚠️ 확인 함수(signup-code-verify)와 **같은 식**이어야 한다. 한쪽만 고치면 모든 번호가 불일치한다.
//
// 환경변수 (Edge Functions Secrets — 개발·운영 각각 따로 설정):
//   SIGNUP_CODE_PEPPER   (필수. 없으면 500 — 번호를 못 만든다. 개발·운영 값은 서로 달라도 된다)
//   BREVO_API_KEY / BREVO_SENDER_EMAIL / BREVO_SENDER_NAME
//   PUBLIC_APP_URL       인플루언서 사이트 URL (기본 https://globalreverb.com)
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY  (런타임 자동 주입)
//
// 배포 (개발 → 운영 각각. 병합으로는 반영되지 않는다):
//   bash scripts/sync-email-templates.sh
//   supabase functions deploy signup-code-send --project-ref <ref>
//   ⚠️ 게이트웨이가 공개 키를 막으면 {"code":401,...} 가 온다 — 그때는 verify_jwt = false 설정(admin-password-reset-request 선례)
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TEMPLATES } from "./templates.ts";

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";
const HELP_LINE_URL = "https://line.me/R/ti/p/@reverb.jp";
const EMAIL_MAX_LENGTH = 254;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function env(key: string, fallback = ""): string {
  return Deno.env.get(key) ?? fallback;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "content-type": "application/json" },
  });
}

function render(html: string, data: Record<string, string>): string {
  return html.replace(/\{\{(\w+)\}\}/g, (_m, key) => data[key] ?? "");
}

async function sha256Hex(input: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// 가입 화면(dev/js/auth.js signupEmailCheck)과 같은 기준: @ 가 있고, 도메인에 점이 있고, 끝 글자가 2자 이상.
function isValidEmail(email: string): boolean {
  if (!email || email.length > EMAIL_MAX_LENGTH) return false;
  if (!/^[^\s@]+@[^\s@]+$/.test(email)) return false;
  const domain = email.split("@")[1];
  if (!domain.includes(".")) return false;
  const tld = domain.slice(domain.lastIndexOf(".") + 1);
  return /^[A-Za-z]{2,}$/.test(tld);
}

// 6자리 번호 — 균등 분포(나머지 연산 치우침 없음). 4294967296 중 4294000000 미만만 채택해 100만으로 나눈다.
function generateCode(): string {
  const LIMIT = 4_294_000_000; // 1,000,000 의 배수 중 2^32 이하 최대값
  const buf = new Uint32Array(1);
  do {
    crypto.getRandomValues(buf);
  } while (buf[0] >= LIMIT);
  return String(buf[0] % 1_000_000).padStart(6, "0");
}

async function sendBrevoEmail(params: {
  to: string;
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
      to: [{ email: params.to }],
      subject: params.subject,
      htmlContent: params.htmlContent,
      textContent: params.textContent,
    }),
  });
  if (!res.ok) {
    // 응답 본문에 수신 주소가 들어올 수 있어 상태 코드만 남긴다
    throw new Error(`Brevo send failed ${res.status}`);
  }
}

// ── 개발서버 전용 「메일 대신 화면」 (2026-10-01 사용자 결정) ─────────────
//   개발서버에는 메일 발송 열쇠가 없어 인증번호 메일이 나가지 않는다. 그래서 개발서버에서만
//   메일을 보내지 않고 **보냈을 메일(제목·본문)을 응답에 싣는다** — 가입 화면이 새 창에 띄운다.
//   🔴 두 겹 잠금 — 둘 다 참일 때만 켜진다(운영에 설정값을 잘못 넣어도 주소가 달라 안 켜진다):
//     ① 환경변수 SIGNUP_CODE_DEV_ECHO === "1" (개발서버에만 넣는다)
//     ② 이 함수가 도는 프로젝트 주소가 개발서버(STAGING_PROJECT_REF)
//   ⚠️ 켜지면 번호가 응답에 그대로 실린다 — 운영에서 켜지면 인증이 무력해진다. 잠금 둘 다 지우지 말 것.
const STAGING_PROJECT_REF = "qysmxtipobomefudyixw";
function devEchoEnabled(): boolean {
  return env("SIGNUP_CODE_DEV_ECHO") === "1"
    && env("SUPABASE_URL").includes(`://${STAGING_PROJECT_REF}.`);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405, headers: CORS_HEADERS });
  }

  let rawEmail: unknown = "";
  try {
    const body = await req.json();
    rawEmail = body?.email;
  } catch (_) {
    // 본문 파싱 실패 → 아래에서 invalid_email 로 수렴
  }
  const email = (typeof rawEmail === "string" ? rawEmail : "").trim().toLowerCase();
  if (!isValidEmail(email)) {
    return json({ ok: false, error: "invalid_email" });
  }

  const pepper = env("SIGNUP_CODE_PEPPER");
  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!pepper || !supaUrl || !serviceKey) {
    console.error("[signup-code-send] server configuration missing");
    return json({ ok: false, error: "server_error" }, 500);
  }

  try {
    const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });
    const emailHash = await sha256Hex(email);
    const code = generateCode();
    const codeHash = await sha256Hex(`${pepper}:${emailHash}:${code}`);

    const { data, error } = await sb.rpc("signup_code_issue", {
      p_email_hash: emailHash,
      p_code_hash: codeHash,
    });
    if (error || !data) {
      console.error("[signup-code-send] issue rpc failed", error?.message);
      return json({ ok: false, error: "server_error" }, 500);
    }

    if (data.status === "rate_limited") {
      return json({ ok: true, status: "rate_limited", resend_available_at: data.resend_available_at });
    }
    if (data.status !== "sent") {
      console.error("[signup-code-send] unexpected issue status");
      return json({ ok: false, error: "server_error" }, 500);
    }

    // 유효 시간(분) — 서버가 정한 만료 시각에서 계산(설정 표 수치가 바뀌어도 메일이 맞다)
    const expiresMs = new Date(data.code_expires_at).getTime() - Date.now();
    const minutes = String(Math.max(1, Math.round(expiresMs / 60000)));
    const appUrl = env("PUBLIC_APP_URL", "https://globalreverb.com").replace(/\/$/, "");

    // HTML 주석 strip — templates.ts 인라인 원본 주석이 메일 본문에 누출되는 것 차단
    const tpl = TEMPLATES["signup-code"].replace(/<!--[\s\S]*?-->/g, "");
    const html = render(tpl, {
      code, // 숫자 6자리만(generateCode)
      minutes, // 숫자만
      site_url: appUrl,
      help_line_url: HELP_LINE_URL,
    });
    const text =
      `REVERB JP にご登録いただきありがとうございます。\n` +
      `下の6けたの数字を、登録画面に入力してください。\n\n` +
      `認証コード: ${code}\n\n` +
      `このコードは ${minutes}分間 有効です。\n` +
      `このメールに心当たりがない場合は、何もせずこのメールを削除してください。\n\n` +
      `お問い合わせ LINE: ${HELP_LINE_URL}\n`;

    const subject = "【REVERB JP】認証コードのお知らせ";
    if (devEchoEnabled()) {
      // 개발서버 — 메일 대신 보냈을 메일을 그대로 돌려준다(위 두 겹 잠금)
      return json({
        ok: true,
        status: "sent",
        code_expires_at: data.code_expires_at,
        resend_available_at: data.resend_available_at,
        dev_mail: { to: email, subject, html },
      });
    }

    try {
      await sendBrevoEmail({
        to: email,
        subject,
        htmlContent: html,
        textContent: text,
      });
    } catch (e) {
      console.error("[signup-code-send] mail failed", (e as Error).message);
      // 번호를 못 보냈으니 이 번호는 무효로 표시(재발송 간격에 안 걸리게)
      const { error: cancelErr } = await sb.rpc("signup_code_cancel", { p_code_id: data.code_id });
      if (cancelErr) console.error("[signup-code-send] cancel rpc failed", cancelErr.message);
      return json({ ok: false, error: "send_failed" });
    }

    return json({
      ok: true,
      status: "sent",
      code_expires_at: data.code_expires_at,
      resend_available_at: data.resend_available_at,
    });
  } catch (e) {
    console.error("[signup-code-send] error", (e as Error).message);
    return json({ ok: false, error: "server_error" }, 500);
  }
});
