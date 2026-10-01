// ══════════════════════════════════════════════════════════════════
// Edge Function: signup-code-verify
// ──────────────────────────────────────────────────────────────────
// 용도: 가입 화면에서 입력한 6자리 인증번호를 확인하고, 맞으면 「확인증」(1회용 열쇠)을 돌려준다.
//       화면은 이 확인증을 signUp 의 메타데이터(signup_ticket)에 실어 보내고, 서버 관문(가입 트리거)이 검증한다.
//
// 요청:  POST { email, code }
// 응답:  { ok:true, ticket, ticket_expires_at }
//        { ok:false, reason:'no_code'|'expired'|'locked'|'mismatch'|'contact_support'|'invalid_input'|'server_error',
//          attempts_left? }
//
// 해시 규격(마이그레이션 494 머리말이 정본):
//   email_hash  = sha256hex(lower(trim(email)))
//   code_hash   = sha256hex(`${PEPPER}:${email_hash}:${code}`)  — 발송 함수와 **같은 식**
//   ticket      = 난수 32바이트의 16진수 64자(원문은 응답으로만 나가고 DB 에는 해시만 남는다)
//   ticket_hash = sha256hex(ticket)  — 🔴 비밀값을 섞지 않는다. 관문이 SQL 안에서 digest(ticket,'sha256') 로 직접 대조한다.
//
// ⚠️ 이메일 원문·번호·확인증은 로그에 남기지 않는다.
// ⚠️ 「공개 키 거부」는 걸지 않는다 — 브라우저가 공개 키로 부르는 함수. 번호 맞히기 방어는 DB 의 시도 횟수 상한이 한다.
//
// 환경변수: SIGNUP_CODE_PEPPER(필수·개발/운영 각각) · SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY(자동)
// 배포: supabase functions deploy signup-code-verify --project-ref <ref>  (개발·운영 각각)
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const EMAIL_MAX_LENGTH = 254;
const TICKET_BYTES = 32;

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

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(input: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return toHex(new Uint8Array(buf));
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405, headers: CORS_HEADERS });
  }

  let rawEmail: unknown = "";
  let rawCode: unknown = "";
  try {
    const body = await req.json();
    rawEmail = body?.email;
    rawCode = body?.code;
  } catch (_) {
    // 아래 검사에서 invalid_input 으로 수렴
  }
  const email = (typeof rawEmail === "string" ? rawEmail : "").trim().toLowerCase();
  const code = typeof rawCode === "string" ? rawCode.trim() : "";
  if (!email || email.length > EMAIL_MAX_LENGTH || !/^\d{6}$/.test(code)) {
    return json({ ok: false, reason: "invalid_input" });
  }

  const pepper = env("SIGNUP_CODE_PEPPER");
  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!pepper || !supaUrl || !serviceKey) {
    console.error("[signup-code-verify] server configuration missing");
    return json({ ok: false, reason: "server_error" }, 500);
  }

  try {
    const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });
    const emailHash = await sha256Hex(email);
    const codeHash = await sha256Hex(`${pepper}:${emailHash}:${code}`);

    const ticketBytes = new Uint8Array(TICKET_BYTES);
    crypto.getRandomValues(ticketBytes);
    const ticket = toHex(ticketBytes); // 64자
    const ticketHash = await sha256Hex(ticket); // 비밀값 없이 — 관문이 SQL 에서 같은 식으로 대조

    const { data, error } = await sb.rpc("signup_code_verify", {
      p_email_hash: emailHash,
      p_code_hash: codeHash,
      p_ticket_hash: ticketHash,
      p_email: email,
    });
    if (error || !data) {
      console.error("[signup-code-verify] verify rpc failed", error?.message);
      return json({ ok: false, reason: "server_error" }, 500);
    }

    if (data.ok === true) {
      return json({ ok: true, ticket, ticket_expires_at: data.ticket_expires_at });
    }
    const out: Record<string, unknown> = { ok: false, reason: data.reason ?? "server_error" };
    if (typeof data.attempts_left === "number") out.attempts_left = data.attempts_left;
    return json(out);
  } catch (e) {
    console.error("[signup-code-verify] error", (e as Error).message);
    return json({ ok: false, reason: "server_error" }, 500);
  }
});
