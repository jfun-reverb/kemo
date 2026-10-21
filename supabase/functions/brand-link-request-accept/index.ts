// ══════════════════════════════════════════════════════════════════
// Edge Function: brand-link-request-accept
// ──────────────────────────────────────────────────────────────────
// 트리거: 「브랜드 연결 요청」 메일(notify-brand-invite owner_link 갈래, 양식 brand-link-request)의 링크
//          `/brand/?link=…&kind=invite` 를 연 사람이 **비밀번호를 아직 안 정한 기존 브랜드 계정**일 때
//          (링크 판정 get_brand_invite_link_state → recipient:'existing_setpw'), 화면에서 비밀번호·약관 동의 뒤
//          「계속」을 누르면 비로그인으로 직접 호출. → 브라우저 직접 호출이라 CORS + OPTIONS 필수.
//          🔴 공개 키 거부는 걸지 않는다(비로그인 브라우저가 공개 키로 부른다 — brand-invite-accept 와 같다).
//          (사양서 docs/specs/2026-10-21-brand-link-request.md 4-5 · 결정 L8 · 작업표 …-breakdown.md 연결 7 · 기본값 2)
//
// 흐름 — 원래 있던 계정이다(새 계정을 만들지 않는다):
//   ① 화면이 { link_id, password, terms_version } 전송 → 입력 검사
//   ② service_brand_link_request_setpw(link, terms)      — 쓰지 않는 사전 검사 → auth_id
//   ③ auth.admin.updateUserById(auth_id, { password })    — 비밀번호 저장
//   ④ service_brand_link_request_finalize(link, terms)    — password_set_at · setup_link_id 비우기 · 대표 연결 · 요청 accepted
//   ⑤ 응답 { ok:true, email, brand_id } → 화면이 그 이메일·비밀번호로 로그인하고 그 브랜드로
//
// 요청:  POST { link_id, password, terms_version }                       (로그인 토큰 없음)
// 응답:  200 { ok:true, email, brand_id }
//        200 { ok:false, reason: 'invalid_link' | 'owner_exists' | 'already_member' | 'password_already_set'
//                              | 'terms_version_required' | 'password_rejected' | 'failed' }
//        400 { ok:false, reason:'invalid_request' }    입력 형식 불량(본문 이상·약관 판 길이 초과)
//        500 { ok:false, reason:'server_error' }
//        · failed = 비밀번호를 저장한 뒤 마무리에서 예상 밖 거부. 화면 안내 「처리하지 못했습니다. 메일의 링크를 다시 열어 주십시오」
//          (비밀번호 기록이 남았으면 링크 판정이 existing 이라 로그인 뒤 수락 / 안 남았으면 처음부터 — 사양서 4-5)
//
// 🔴 계정 지우기 경로가 **없다** — brand-invite-accept 의 반쪽 계정 정리(deleteUser)를 일부러 옮기지 않았다.
//    여기서 다루는 것은 원래 있던 계정이라, 실수 한 줄로 기존 계정이 지워지면 안 된다(작업표 기본값 2).
//    마지막 단계가 실패해 인증 쪽 비밀번호만 남아도 지우지 않는다(사양서 4-5).
// 🔴 비밀번호 원문이 이 함수를 지난다 → 요청 본문·비밀번호·링크 번호·이메일을 로그에 남기지 않는다.
//    로그에는 분기 이름과 결과 코드만. 응답에도 링크·비밀번호를 싣지 않는다(이메일은 로그인용으로 본인 화면에만).
// 🔴 비밀번호 규칙(8자·소문자·기호)은 화면에서만 검사한다. 서버는 로그인 체계 최소값(6자, bcrypt 상한 72바이트)만 —
//    brand-invite-accept 와 같은 값(셋째 사본을 만들지 않는다).
// ⚠️ 사전 검사(②)와 비밀번호 저장(③) 사이 틈(그사이 다른 링크로 비밀번호가 정해짐)은 인증 저장이 데이터베이스 거래 밖이라
//    막지 못하고 감수한다(사양서 5-7) — 마지막 단계가 password_already_set 으로 수락을 멈춘다.
//
// 멱등 재시도: ③ 뒤 ④ 가 오류로 끝나면 password_set_at 이 비어 있어 같은 링크로 다시 부르면 ② 부터 다시 통과한다
//   (same_password 는 정상 재시도로 본다).
//
// 환경변수: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (자동 주입) — 새 비밀값 없음, 메일도 보내지 않는다.
//
// 배포 (개발만 — 운영은 브랜드 페이지 묶음과 함께):
//   supabase functions deploy brand-link-request-accept --use-api --project-ref qysmxtipobomefudyixw
//   🔴 배포는 service_brand_link_request_setpw·…_finalize 가 있는 데이터베이스에서만(작업표 연결 4 적용 뒤)
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_BODY_BYTES = 8 * 1024;
const MIN_PASSWORD_LEN = 6;   // 로그인 체계 최소값(Supabase 인증 기본값). 화면 규칙은 화면 몫
const MAX_PASSWORD_BYTES = 72; // bcrypt 상한 — 넘으면 로그인 체계가 거부한다
const MAX_TERMS_LEN = 50;

// 사전 검사·마무리 함수가 돌려주는 거부 중 화면에 그대로 넘기는 것
const PASS_THROUGH = new Set(["invalid_link", "owner_exists", "already_member", "password_already_set", "terms_version_required"]);

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

const refused = (reason: string) => jsonResponse({ ok: false, reason });
const invalidRequest = () => jsonResponse({ ok: false, reason: "invalid_request" }, 400);
const serverError = () => jsonResponse({ ok: false, reason: "server_error" }, 500);

// 로그인 체계가 비밀번호 자체를 거부했는가 — weak_password 하나만. 그 밖의 실패는 server_error
function isPasswordRejection(err: { code?: string }): boolean {
  return String(err.code || "") === "weak_password";
}

// 로그에는 오류 메시지 대신 코드(없으면 짧은 분기명)만 — 메시지에 이메일이 섞일 수 있다
function errTag(err: { code?: string; name?: string } | null | undefined, fallback: string): string {
  return String(err?.code || err?.name || fallback);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405, headers: CORS_HEADERS });

  // 1) 본문 — 크기 제한 후 파싱. 어떤 값도 로그에 남기지 않는다
  let raw: string;
  try {
    raw = await req.text();
  } catch (_) {
    return invalidRequest();
  }
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) return invalidRequest();
  let body: Record<string, unknown>;
  try {
    body = JSON.parse(raw);
  } catch (_) {
    return invalidRequest();
  }
  if (!body || typeof body !== "object") return invalidRequest();

  const linkId = typeof body.link_id === "string" ? body.link_id.trim() : "";
  const password = typeof body.password === "string" ? body.password : "";
  const terms = typeof body.terms_version === "string" ? body.terms_version.trim() : "";

  // 링크 번호 형식 불량은 입력 형식 불량(400) — 작업표 연결 7 완료 정의 「형식 틀린 링크 → 400」
  if (!UUID_RE.test(linkId)) return invalidRequest();
  if (terms.length > MAX_TERMS_LEN) return invalidRequest();
  // 약관 판이 비면 서버 함수가 terms_version_required 로 거부한다 — 판정을 한 곳(서버 함수)에 둔다
  if (password.length < MIN_PASSWORD_LEN) return refused("password_rejected");
  if (new TextEncoder().encode(password).length > MAX_PASSWORD_BYTES) return refused("password_rejected");

  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) {
    console.error("[brand-link-request-accept] service credentials not configured");
    return serverError();
  }
  const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

  try {
    // 2) 사전 검사 — 쓰지 않는다. 비밀번호를 저장하기 전이라 거부는 그대로 넘긴다
    const { data: pre, error: preErr } = await sb.rpc("service_brand_link_request_setpw", {
      p_link_id: linkId, p_terms_version: terms,
    });
    if (preErr) {
      console.error("[brand-link-request-accept] setpw rpc failed", errTag(preErr, "db"));
      return serverError();
    }
    const preResult = String(pre?.result || "");
    if (preResult !== "ok") {
      console.log("[brand-link-request-accept] setpw refused", preResult || "unknown");
      return refused(PASS_THROUGH.has(preResult) ? preResult : "invalid_link");
    }
    const authId = String(pre?.auth_id || "");
    if (!UUID_RE.test(authId)) {
      console.error("[brand-link-request-accept] setpw returned no auth_id");
      return serverError();
    }

    // 3) 비밀번호 저장
    const { error: pwErr } = await sb.auth.admin.updateUserById(authId, { password });
    // same_password: 이전 시도에서 이미 같은 비밀번호가 저장된 정상 재시도 — 성공으로 보고 다음 단계로
    if (pwErr && String(pwErr.code || "") !== "same_password") {
      if (isPasswordRejection(pwErr)) {
        console.log("[brand-link-request-accept] password rejected");
        return refused("password_rejected");
      }
      console.error("[brand-link-request-accept] updateUserById failed", errTag(pwErr, "unknown"));
      return serverError();
    }

    // 4) 마무리 — 비밀번호 기록 + 대표 연결 + 요청 accepted(한 거래 — 거부되면 비밀번호 기록도 함께 되돌아간다)
    const { data: fin, error: finErr } = await sb.rpc("service_brand_link_request_finalize", {
      p_link_id: linkId, p_terms_version: terms,
    });
    if (finErr) {
      // 지우지 않는다 — 재호출하면 같은 계정으로 다시 된다(머리말 「멱등 재시도」)
      console.error("[brand-link-request-accept] finalize rpc failed", errTag(finErr, "db"));
      return serverError();
    }
    const finResult = String(fin?.result || "");
    if (finResult !== "ok") {
      console.log("[brand-link-request-accept] finalize refused", finResult || "unknown");
      // password_not_set 등 정상 경로에서 오지 않는 값은 failed(화면: 링크를 다시 열어 주십시오)
      return refused(PASS_THROUGH.has(finResult) ? finResult : "failed");
    }

    const email = String(fin.email || "");
    if (!email) {
      // 수락은 됐으나 화면이 로그인할 이메일이 없다 — failed(링크를 다시 열면 existing 판정으로 로그인 뒤 길이 있다)
      console.error("[brand-link-request-accept] finalize returned no email");
      return refused("failed");
    }
    console.log("[brand-link-request-accept] accepted");
    return jsonResponse({ ok: true, email, brand_id: String(fin.brand_id || "") });
  } catch (e) {
    console.error("[brand-link-request-accept] error", errTag(e as Error, "exception"));
    return serverError();
  }
});
