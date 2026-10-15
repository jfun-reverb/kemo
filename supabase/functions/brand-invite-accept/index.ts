// ══════════════════════════════════════════════════════════════════
// Edge Function: brand-invite-accept
// ──────────────────────────────────────────────────────────────────
// 트리거: 브랜드 초대 메일(새 이메일 ⓐ)의 링크 `/brand/?link=…&kind=invite` 로 들어온 사람이
//          화면에서 이름·연락처·비밀번호를 넣고 약관에 동의한 뒤 「계속」을 누를 때, 비로그인으로 직접 호출.
//          → 브라우저 직접 호출이라 CORS + OPTIONS 필수. 🔴 공개 키 거부는 걸지 않는다
//            (비로그인 브라우저가 공개 키로 부른다 — supabase.md).
//          (마이그레이션 530~532, 작업표 docs/specs/2026-10-15-brand-member-breakdown.md 작업 6 「방식 B」)
//
// 방식 B: 일회용 인증 링크 없이, **수락하는 순간** 이 함수가 계정을 만든다 (수락 전에는 계정 없음).
//   ① 화면이 { link_id, password, name, phone, terms_version } 전송 → 입력 검사
//   ② service_brand_invite_create_account(link, name, phone, terms)   — 인증 계정 직접 삽입(비밀번호 빈칸) + brand_accounts
//   ③ auth.admin.updateUserById(auth_id, { password })               — 비밀번호 저장
//   ④ service_brand_invite_finalize(link, auth_id)                    — password_set_at · 멤버 연결 · 초대 accepted
//   ⑤ 응답 { ok:true, email } → 화면이 그 이메일·비밀번호로 로그인
//
// 요청:  POST { link_id, password, name, phone, terms_version }       (로그인 토큰 없음)
// 응답:  200 { ok:true, email }
//        200 { ok:false, reason:'invalid_link' }       링크 무효·만료·취소·갈래 어긋남 — 사유를 나누지 않는다
//        200 { ok:false, reason:'password_rejected' }  로그인 체계가 비밀번호를 거부(너무 짧음·약함)
//        400 { ok:false, reason:'invalid_request' }    ⚠️ 작업표 계약에 없는 값 — 입력 형식 불량(이름·약관 판 빈칸, 본문 이상)
//        500 { ok:false, reason:'server_error' }
//
// 🔴 비밀번호 원문이 이 함수를 지난다 → 요청 본문·비밀번호·링크 번호·이메일을 로그에 남기지 않는다.
//    로그에는 분기 이름과 오류 코드(메시지는 이메일이 섞일 수 있어 남기지 않음)만. 응답에도 링크·비밀번호를 싣지 않는다.
// 🔴 비밀번호 규칙(8자·소문자·기호)은 화면에서만 검사한다. 서버는 로그인 체계 최소값(6자, bcrypt 상한 72바이트)만
//    — 셋째 사본을 만들지 않는다(passwordPolicyIssue·validateAdminPassword 두 곳이 이미 정본).
//
// 멱등 재시도 (단계 사이 실패)
//   · ③ 실패 뒤 재호출: create_account 가 같은 초대로 만든 비밀번호 미설정 계정을 다시 쓴다 → 같은 계정으로 완료
//   · ④ 만 실패한 뒤 재호출: 비밀번호는 저장됐으나 password_set_at 이 비어 있어 재시도 예외(p_via_link=true)로 같은 계정 완료
//
// 정리 (「수락 전에는 계정 없음」을 지킨다) — 아래 조건이 모두 맞을 때만 이 초대로 만든 계정을 지운다:
//   연결 행이 하나도 없음 · created_via_invite_id = 이 초대 · password_set_at 비어 있음  (인증 계정 삭제 → brand_accounts 연쇄)
//   · ④ 가 invalid_link 로 거부될 때(두 호출 사이에 대표 해제 등으로 초대 취소)
//   · ⚠️ ③ 의 비밀번호 거부(password_rejected)는 정리하지 않는다 — 확인(조회)과 삭제 사이에 잠금이 없어, 같은 링크 동시 두 요청에서
//     한쪽의 정리가 다른 쪽의 정상 계정을 지울 수 있다. 서버가 6자 미만을 먼저 거르고 유출 비밀번호 검사도 꺼져 있어 사실상 닿지 않는
//     경로라 얻는 것도 없다. 남는 반쪽 계정은 비밀번호가 없어 로그인할 수 없고, 같은 링크로 다시 오면 재사용된다.
//   · 삭제가 실패하면 오류 기록에만 남긴다(응답은 그대로). 그 계정은 개발 세션이 SQL 로 정리한다(작업표 작업 6)
//   · ③ 의 그 밖 실패(server_error)는 지우지 않는다 — 재시도가 같은 계정을 쓴다
//
// 남용 방지: 링크 번호가 무작위 UUID(122비트)라 추측으로 맞힐 수 없고, 유효한 링크도 초대 1건당 계정 1개만 만들어
//   성공 뒤에는 invalid_link 가 된다. 별도 요청 제한 표는 만들지 않았다(보고서 「남용 방지」 참고).
//   본문 크기(8KB)와 각 칸 길이는 여기서 먼저 자른다.
//
// 환경변수: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (자동 주입) — 새 비밀값 없음, 메일도 보내지 않는다.
//
// 배포 (개발 → 운영):
//   supabase functions deploy brand-invite-accept --use-api --project-ref qysmxtipobomefudyixw
//   (운영) supabase functions deploy brand-invite-accept --use-api --project-ref nrwtujmlbktxjgdwlpjj  ← 운영 관문 뒤에만
//   JWT 검증을 끄는 설정은 따로 두지 않는다 — 같은 비로그인 함수 brand-password-reset-request 와 똑같이 공개 키로 부른다.
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_BODY_BYTES = 8 * 1024;
const MIN_PASSWORD_LEN = 6;   // 로그인 체계 최소값(Supabase 인증 기본값). 화면 규칙은 화면 몫
const MAX_PASSWORD_BYTES = 72; // bcrypt 상한 — 넘으면 로그인 체계가 거부한다
const MAX_NAME_LEN = 100;
const MAX_PHONE_LEN = 50;
const MAX_TERMS_LEN = 50;

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

const invalidLink = () => jsonResponse({ ok: false, reason: "invalid_link" });
const invalidRequest = () => jsonResponse({ ok: false, reason: "invalid_request" }, 400);
const serverError = () => jsonResponse({ ok: false, reason: "server_error" }, 500);

// deno-lint-ignore no-explicit-any
type Sb = any;

// 이 초대로 만든 반쪽 계정을 지운다. 조건이 하나라도 안 맞으면 아무것도 안 한다. 예외를 던지지 않는다.
async function cleanupHalfAccount(sb: Sb, linkId: string, authId: string): Promise<void> {
  try {
    const { data: inv, error: invErr } = await sb
      .from("brand_invites").select("id").eq("link_id", linkId).maybeSingle();
    if (invErr || !inv) { if (invErr) console.error("[brand-invite-accept] cleanup invite lookup failed", errTag(invErr, "db")); return; }

    const { data: acct, error: acctErr } = await sb
      .from("brand_accounts").select("created_via_invite_id, password_set_at").eq("auth_id", authId).maybeSingle();
    if (acctErr || !acct) { if (acctErr) console.error("[brand-invite-accept] cleanup account lookup failed", errTag(acctErr, "db")); return; }
    if (acct.created_via_invite_id !== inv.id || acct.password_set_at !== null) return;

    const { count, error: linkErr } = await sb
      .from("brand_account_links").select("auth_id", { count: "exact", head: true }).eq("auth_id", authId);
    if (linkErr) { console.error("[brand-invite-accept] cleanup link count failed", errTag(linkErr, "db")); return; }
    if ((count ?? 0) > 0) return;

    const { error: delErr } = await sb.auth.admin.deleteUser(authId);
    if (delErr) console.error("[brand-invite-accept] cleanup delete failed", errTag(delErr, "db"));
    else console.log("[brand-invite-accept] half account removed");
  } catch (e) {
    console.error("[brand-invite-accept] cleanup error", errTag(e as Error, "exception"));
  }
}

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
  const name = typeof body.name === "string" ? body.name.trim() : "";
  const phone = typeof body.phone === "string" ? body.phone.trim() : "";
  const terms = typeof body.terms_version === "string" ? body.terms_version.trim() : "";

  // 링크 번호 형식 불량은 무효 링크와 같은 응답(사유를 나누지 않는다)
  if (!UUID_RE.test(linkId)) return invalidLink();

  // 입력 형식 — 서버는 최소만. 이름·약관 판은 비면 거부(약관 동의 뒤에만 계정을 만든다)
  if (!name || name.length > MAX_NAME_LEN || phone.length > MAX_PHONE_LEN || !terms || terms.length > MAX_TERMS_LEN) {
    return invalidRequest();
  }
  if (password.length < MIN_PASSWORD_LEN) return jsonResponse({ ok: false, reason: "password_rejected" });
  if (new TextEncoder().encode(password).length > MAX_PASSWORD_BYTES) return jsonResponse({ ok: false, reason: "password_rejected" });

  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) {
    console.error("[brand-invite-accept] service credentials not configured");
    return serverError();
  }
  const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

  try {
    // 2) 계정 만들기(또는 같은 초대의 반쪽 계정 재사용)
    const { data: created, error: createErr } = await sb.rpc("service_brand_invite_create_account", {
      p_link_id: linkId, p_name: name, p_phone: phone, p_terms_version: terms,
    });
    if (createErr) {
      console.error("[brand-invite-accept] create_account rpc failed", errTag(createErr, "db"));
      return serverError();
    }
    if (!created?.ok) {
      const reason = String(created?.reason || "");
      if (reason === "name_required" || reason === "terms_required") return invalidRequest(); // 위 사전 검사에서 걸러져 오지 않는 값
      console.log("[brand-invite-accept] create_account refused", reason || "unknown");
      return invalidLink();
    }
    const authId = String(created.auth_id);
    const email = String(created.email || "");

    // 3) 비밀번호 저장
    const { error: pwErr } = await sb.auth.admin.updateUserById(authId, { password });
    // same_password: 이전 시도에서 이미 같은 비밀번호가 저장된 정상 재시도 — 성공으로 보고 다음 단계로
    if (pwErr && String(pwErr.code || "") !== "same_password") {
      if (isPasswordRejection(pwErr)) {
        // 정리하지 않는다 — 머리말 참고(동시 요청 경합 · 사실상 도달 불가)
        console.log("[brand-invite-accept] password rejected");
        return jsonResponse({ ok: false, reason: "password_rejected" });
      }
      // 그 밖(일시 장애 등): 지우지 않는다 — 같은 링크로 재호출하면 같은 계정을 다시 쓴다
      console.error("[brand-invite-accept] updateUserById failed", errTag(pwErr, "unknown"));
      return serverError();
    }

    // 4) 마무리 — 멤버 연결 + 초대 accepted
    const { data: fin, error: finErr } = await sb.rpc("service_brand_invite_finalize", {
      p_link_id: linkId, p_auth_id: authId,
    });
    if (finErr) {
      // 연결 실패는 지우지 않는다 — 재호출하면 재시도 예외로 같은 계정이 완료된다
      console.error("[brand-invite-accept] finalize rpc failed", errTag(finErr, "db"));
      return serverError();
    }
    if (!fin?.ok) {
      const reason = String(fin?.reason || "");
      console.log("[brand-invite-accept] finalize refused", reason || "unknown");
      if (reason === "invalid_link") {
        // 두 호출 사이에 초대가 취소·만료됐다 — 「수락 전에는 계정 없음」을 지키려고 반쪽 계정을 지운다
        await cleanupHalfAccount(sb, linkId, authId);
        return invalidLink();
      }
      // password_not_set · already_member 등: 정상 경로에서는 오지 않는다
      return serverError();
    }

    console.log("[brand-invite-accept] accepted");
    return jsonResponse({ ok: true, email });
  } catch (e) {
    console.error("[brand-invite-accept] error", errTag(e as Error, "exception"));
    return serverError();
  }
});
