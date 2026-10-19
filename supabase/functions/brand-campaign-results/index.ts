// ══════════════════════════════════════════════════════════════════
// Edge Function: brand-campaign-results
// ──────────────────────────────────────────────────────────────────
// 브랜드 페이지 캠페인 상세 「결과물」 — 결과물 판정(get_my_brand_campaign_results, 마이그레이션 547)을
// **부른 브랜드 계정의 로그인 토큰으로** 호출하고, 응답 안의 비공개 영수증 경로만 서명 주소로 바꿔 돌려준다.
//   작업표 docs/specs/2026-10-19-brand-campaign-results-breakdown.md 「조각 5」 · S13 · 결정 D1(영수증만)
//
// 입력  POST { campaign_id: uuid, purpose: 'view' | 'excel' }  · Authorization: Bearer <브랜드 로그인 토큰>
// 출력  판정 응답과 같은 모양 — deliverables[].receipt_url(영수증이고 값이 통 경로면 서명 주소) · receipt_thumb_url(썸네일 서명 주소, 없으면 null)
//       유효 시간 view 1시간 · excel 7일(엑셀 영수증 링크 — 사양서 「영수증 사진 비공개 이전」 ②)
//
// 🔴 판정은 데이터베이스 함수 하나가 한다(이 함수는 판정하지 않는다). 그래서 사용자 토큰으로 부른다 —
//    서비스 키로 부르면 auth.uid() 가 없어 is_my_brand 판정이 돌지 않는다.
// 🔴 서명은 판정 응답 **안에 든 경로만** — 화면이 보낸 경로는 받지 않는다(남의 영수증을 서명받는 길을 막는다).
//    그 경로도 회원이 쓸 수 있는 칸이라 「receipts/ 로 시작 · .. 없음」만 서명한다(isSignablePath).
// 🔴 옛 공개 전체 주소(「://」 포함)는 그대로 통과(출시 전 이중 지원). 다른 서비스 영수증(ext_rows)도 외부 주소라 그대로.
// 브라우저가 직접 부른다 — CORS + OPTIONS 필수. 공개 키 거부는 걸지 않는다(판정은 로그인 토큰).
// 환경변수: SUPABASE_URL · SUPABASE_ANON_KEY · SUPABASE_SERVICE_ROLE_KEY(자동 주입) — 새 비밀값 없음.
// 로그: 경로·주소·토큰을 남기지 않는다(오류 코드만).
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_BODY_BYTES = 2 * 1024;
const BUCKET = "deliverable-media";
const EXPIRES = { view: 60 * 60, excel: 7 * 24 * 60 * 60 } as const;
const SIGN_CHUNK = 200;

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

function env(key: string): string {
  return Deno.env.get(key) ?? "";
}

// 통 경로인가 — 옛 공개 전체 주소·외부 주소는 「://」 가 있다
function isBucketPath(v: unknown): v is string {
  return typeof v === "string" && v.trim() !== "" && !v.includes("://");
}

// 서명해도 되는 경로인가 — receipt_url 은 회원이 직접 쓸 수 있는 칸이라 영수증 폴더 밖·상위 폴더 이동은 서명하지 않는다
function isSignablePath(p: string): boolean {
  return p.startsWith("receipts/") && !p.includes("..") && !p.includes("//") && !p.includes("\\");
}

// 썸네일 경로 — 「{첫 칸}/thumb/{나머지}」(storage.js _thumbPathOf · ui.js storageThumbUrl 과 같은 규칙)
function thumbPathOf(p: string): string | null {
  const i = p.indexOf("/");
  if (i <= 0) return null;
  return p.slice(0, i) + "/thumb/" + p.slice(i + 1);
}

function errTag(err: { code?: string; name?: string; message?: string } | null | undefined, fallback: string): string {
  return String(err?.code || err?.name || fallback);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405, headers: CORS_HEADERS });

  const auth = req.headers.get("authorization") || "";
  if (!/^Bearer\s+\S+/i.test(auth)) return jsonResponse({ success: false, reason: "not_found" });

  let body: Record<string, unknown>;
  try {
    const raw = await req.text();
    if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) return jsonResponse({ success: false, reason: "invalid_request" }, 400);
    body = JSON.parse(raw);
  } catch (_) {
    return jsonResponse({ success: false, reason: "invalid_request" }, 400);
  }
  const campaignId = typeof body.campaign_id === "string" ? body.campaign_id : "";
  const purpose = body.purpose === "excel" ? "excel" : body.purpose === "view" ? "view" : "";
  if (!UUID_RE.test(campaignId) || !purpose) return jsonResponse({ success: false, reason: "invalid_request" }, 400);

  const url = env("SUPABASE_URL");
  const anonKey = env("SUPABASE_ANON_KEY");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return jsonResponse({ success: false, reason: "server_error" }, 500);

  // 1) 판정 — 부른 사람의 토큰으로
  const userDb = createClient(url, anonKey, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await userDb.rpc("get_my_brand_campaign_results", { p_campaign_id: campaignId });
  if (error) {
    // 토큰이 낡거나 틀리거나 비로그인(공개 키 — 실행 권한 없음 42501)이면 not_found(거부 하나 — 543 계약). 그 밖의 실패만 server_error
    if (/^PGRST30/.test(String(error.code || "")) || error.code === "42501") return jsonResponse({ success: false, reason: "not_found" });
    console.error("[brand-campaign-results] rpc failed", errTag(error, "rpc"));
    return jsonResponse({ success: false, reason: "server_error" }, 500);
  }
  // deno-lint-ignore no-explicit-any
  const res = data as any;
  if (!res || res.success !== true || res.ready !== true || !Array.isArray(res.deliverables)) {
    return jsonResponse(res || { success: false, reason: "not_found" });
  }

  // 2) 서명 — 응답 안의 영수증 통 경로만(원본 + 썸네일)
  // deno-lint-ignore no-explicit-any
  const targets = res.deliverables.filter((d: any) => d && d.kind === "receipt" && isBucketPath(d.receipt_url));
  // 영수증 폴더 밖 경로는 서명하지 않고 비운다(경로를 그대로 내보내지도 않는다)
  // deno-lint-ignore no-explicit-any
  for (const d of targets as any[]) {
    if (!isSignablePath(d.receipt_url)) { d.receipt_url = null; d.receipt_thumb_url = null; }
  }
  if (targets.length) {
    const paths: string[] = [];
    // deno-lint-ignore no-explicit-any
    for (const d of targets as any[]) {
      if (!d.receipt_url) continue;
      paths.push(d.receipt_url);
      const t = thumbPathOf(d.receipt_url);
      if (t) paths.push(t);
    }
    const unique = [...new Set(paths)];
    const signed = new Map<string, string>();
    const svc = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    for (let i = 0; i < unique.length; i += SIGN_CHUNK) {
      const chunk = unique.slice(i, i + SIGN_CHUNK);
      const { data: urls, error: signErr } = await svc.storage.from(BUCKET).createSignedUrls(chunk, EXPIRES[purpose]);
      if (signErr || !Array.isArray(urls)) {
        console.error("[brand-campaign-results] sign failed", errTag(signErr, "sign"));
        continue;   // 서명 못 한 칸은 null — 화면이 「열기」를 안 그린다(경로를 그대로 내보내지 않는다)
      }
      for (const u of urls) {
        if (u && u.path && u.signedUrl && !u.error) signed.set(u.path, u.signedUrl);
      }
    }
    // deno-lint-ignore no-explicit-any
    for (const d of targets as any[]) {
      if (!d.receipt_url) continue;
      const p = d.receipt_url as string;
      const t = thumbPathOf(p);
      d.receipt_url = signed.get(p) ?? null;
      d.receipt_thumb_url = t ? (signed.get(t) ?? null) : null;
    }
  }
  res.signed_expires_in = EXPIRES[purpose];
  return jsonResponse(res);
});
