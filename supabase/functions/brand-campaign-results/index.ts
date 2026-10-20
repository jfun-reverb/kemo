// ══════════════════════════════════════════════════════════════════
// Edge Function: brand-campaign-results
// ──────────────────────────────────────────────────────────────────
// 브랜드 페이지 캠페인 상세 「결과물」 — 결과물 판정(get_my_brand_campaign_results, 마이그레이션 547)을
// **부른 브랜드 계정의 로그인 토큰으로** 호출하고, 응답 안의 비공개 영수증 경로만 서명 주소로 바꿔 돌려준다.
//   작업표 docs/specs/2026-10-19-brand-campaign-results-breakdown.md 「조각 5」·「조각 5b」 · S13·S26 · 결정 D1(영수증만)
//
// 입력  POST { campaign_id: uuid, purpose: 'view' | 'excel' | 'receipt', deliverable_id?: uuid }  · Authorization: Bearer <브랜드 로그인 토큰>
// 출력
//   view    — 판정 응답 그대로. 🔄 조각 5b(S26)부터 **서명하지 않는다** — 영수증은 「열기」 때 receipt 로 하나씩(서명 요청이 몰리지 않게).
//             receipt_url 은 저장값 그대로(통 경로 receipts/… 또는 옛 공개 주소). 영수증 폴더 밖 이상한 경로만 null
//   excel   — 판정 응답 + 영수증 통 경로를 7일 서명 주소로(receipt_url · receipt_thumb_url — 엑셀 영수증 링크, 사양서 「영수증 사진 비공개 이전」 ②)
//   receipt — 판정 응답 안 deliverables 에서 그 번호의 영수증 하나만: {success:true, url, expires_in:3600}(통 경로 — 1시간 서명)
//             | {success:true, url, expires_in:null}(옛 공개 주소 — 그대로) | {success:false, reason:'not_found'}
//             (응답에 없는 결과물·영수증이 아님·영수증 열을 꺼 receipt_url null·공개 꺼짐·서명 실패 모두 not_found)
//
// 🔴 판정은 데이터베이스 함수 하나가 한다(이 함수는 판정하지 않는다). 그래서 사용자 토큰으로 부른다 —
//    서비스 키로 부르면 auth.uid() 가 없어 is_my_brand 판정이 돌지 않는다.
// 🔴 서명은 판정 응답 **안에 든 경로만** — 화면이 보낸 경로는 받지 않는다(남의 영수증을 서명받는 길을 막는다).
//    그 경로도 회원이 쓸 수 있는 칸이라 「receipts/ 로 시작 · .. 없음」만 서명한다(isSignablePath).
// 🔴 서명 전에 「올린 사람 대조」(service_brand_receipt_signable, 마이그레이션 551 — 548 조회 정책과 같은 판정)를 거친다.
//    receipt_url 은 회원이 쓰는 칸이라, 남의 파일 경로를 자기 줄에 적으면 경로 검사만으로는 남의 영수증이 서명된다.
//    대조에 걸리거나 대조 자체가 실패하면 서명하지 않는다(null · receipt 갈래는 not_found).
// 🔴 옛 공개 전체 주소(「://」 포함)는 그대로 통과(출시 전 이중 지원). 다른 서비스 영수증(ext_rows)도 외부 주소라 그대로.
// 🔴 제공 기록(조각 R1 — 배송 리스트 작업표 · 마이그레이션 552): view 는 화면에 돌려주기 **전에** results_view(30분 합치기 —
//    552 _record_brand_provision 한 곳), excel 은 서명하기 **전에** results_excel 을 service_record_brand_provision 으로 남긴다.
//    「누가」 = 토큰에서 확인한 계정(화면이 보낸 값 아님) · 칸 = 응답 columns · 사람 = 응답 users(회원 번호 + 응답에 실린 가린 이름).
//    기록이 실패하면 응답을 돌려주지 않는다 {success:false, reason:'record_failed'}(「기록 없는 제공」 없음). receipt 는 기록하지 않는다
//    (그 사진을 담은 표 열람이 이미 view 로 남는다). 공개 꺼짐(ready:false)이면 기록 없음.
// 브라우저가 직접 부른다 — CORS + OPTIONS 필수. 공개 키 거부는 걸지 않는다(판정은 로그인 토큰).
// 환경변수: SUPABASE_URL · SUPABASE_ANON_KEY · SUPABASE_SERVICE_ROLE_KEY(자동 주입) — 새 비밀값 없음.
// 로그: 경로·주소·토큰을 남기지 않는다(오류 코드만).
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_BODY_BYTES = 2 * 1024;
const BUCKET = "deliverable-media";
const EXPIRES = { receipt: 60 * 60, excel: 7 * 24 * 60 * 60 } as const;
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

// 올린 사람 대조를 통과한 결과물 → {대조한 경로, 대조한 썸네일 경로} — 실패하면 빈 표(서명 안 함 쪽으로 닫힌다)
// 🔴 서명은 이 값으로만 한다(판정 응답의 값을 다듬어 서명하면 대조한 파일과 서명하는 파일이 달라질 수 있다)
type Signable = { path: string; thumb: string | null };
// deno-lint-ignore no-explicit-any
async function signableMap(svc: any, ids: string[]): Promise<Map<string, Signable>> {
  const out = new Map<string, Signable>();
  if (!ids.length) return out;
  const { data, error } = await svc.rpc("service_brand_receipt_signable", { p_ids: ids });
  if (error || !Array.isArray(data)) {
    console.error("[brand-campaign-results] owner check failed", errTag(error, "owner_check"));
    return out;
  }
  for (const r of data) {
    if (r && r.deliverable_id && typeof r.path === "string" && isSignablePath(r.path)) {
      out.set(String(r.deliverable_id), { path: r.path, thumb: typeof r.thumb_path === "string" && isSignablePath(r.thumb_path) ? r.thumb_path : null });
    }
  }
  return out;
}

// 제공 기록 — 실패면 false(부르는 쪽이 record_failed 로 닫는다)
// deno-lint-ignore no-explicit-any
async function recordProvision(svc: any, userDb: any, token: string, campaignId: string, action: "results_view" | "results_excel", res: any): Promise<boolean> {
  const { data: who, error: whoErr } = await userDb.auth.getUser(token);
  const uid = who?.user?.id;
  if (whoErr || !uid) {
    console.error("[brand-campaign-results] record: user lookup failed", errTag(whoErr, "user"));
    return false;
  }
  const users = res && res.users && typeof res.users === "object" ? Object.values(res.users) : [];
  // deno-lint-ignore no-explicit-any
  const persons = (users as any[]).filter((u) => u && u.id).map((u) => ({
    influencer_id: String(u.id),
    name: (typeof u.name_kanji === "string" && u.name_kanji) || (typeof u.name_kana === "string" && u.name_kana) || null,
  }));
  const columns = Array.isArray(res?.columns) ? res.columns : [];
  const { error } = await svc.rpc("service_record_brand_provision", {
    p_actor_auth_id: uid, p_campaign_id: campaignId, p_action: action, p_columns: columns, p_persons: persons,
  });
  if (error) {
    console.error("[brand-campaign-results] record failed", errTag(error, "record"));
    return false;
  }
  return true;
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
  const purpose = body.purpose === "excel" ? "excel" : body.purpose === "view" ? "view" : body.purpose === "receipt" ? "receipt" : "";
  const deliverableId = typeof body.deliverable_id === "string" ? body.deliverable_id : "";
  if (!UUID_RE.test(campaignId) || !purpose) return jsonResponse({ success: false, reason: "invalid_request" }, 400);
  if (purpose === "receipt" && !UUID_RE.test(deliverableId)) return jsonResponse({ success: false, reason: "invalid_request" }, 400);

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

  // deno-lint-ignore no-explicit-any
  const targets = res.deliverables.filter((d: any) => d && d.kind === "receipt" && isBucketPath(d.receipt_url));
  // 영수증 폴더 밖 경로는 서명하지 않고 비운다(경로를 그대로 내보내지도 않는다) — 세 갈래 공통
  // deno-lint-ignore no-explicit-any
  for (const d of targets as any[]) {
    if (!isSignablePath(d.receipt_url)) { d.receipt_url = null; d.receipt_thumb_url = null; }
  }

  // 2-a) receipt — 판정 응답 안에서 그 번호의 영수증 하나만(화면이 보낸 경로는 받지 않는다 — 번호로만 찾는다)
  if (purpose === "receipt") {
    // deno-lint-ignore no-explicit-any
    const d = res.deliverables.find((x: any) => x && x.id === deliverableId && x.kind === "receipt");
    const v = d && typeof d.receipt_url === "string" ? d.receipt_url.trim() : "";
    if (!v) return jsonResponse({ success: false, reason: "not_found" });
    if (v.includes("://")) {
      // 옛 공개 주소 — 출시 전 이중 지원. 회원이 쓰는 칸이라 http(s) 만 돌려준다(「javascript://…」 같은 값이 화면 링크로 가지 않게)
      return /^https?:\/\//i.test(v) ? jsonResponse({ success: true, url: v, expires_in: null }) : jsonResponse({ success: false, reason: "not_found" });
    }
    const svc = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const okOne = (await signableMap(svc, [deliverableId])).get(deliverableId);
    if (!okOne) return jsonResponse({ success: false, reason: "not_found" });
    const { data: one, error: oneErr } = await svc.storage.from(BUCKET).createSignedUrl(okOne.path, EXPIRES.receipt);
    if (oneErr || !one?.signedUrl) {
      console.error("[brand-campaign-results] sign one failed", errTag(oneErr, "sign"));
      return jsonResponse({ success: false, reason: "not_found" });
    }
    return jsonResponse({ success: true, url: one.signedUrl, expires_in: EXPIRES.receipt });
  }

  const token = auth.replace(/^Bearer\s+/i, "").trim();

  // 2-b) view — 서명하지 않는다(S26). 저장값 그대로 · 돌려주기 전에 열람 기록(R1)
  if (purpose === "view") {
    const svcLog = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    if (!(await recordProvision(svcLog, userDb, token, campaignId, "results_view", res))) {
      return jsonResponse({ success: false, reason: "record_failed" });
    }
    return jsonResponse(res);
  }

  // 2-c-1) excel — 서명하기 전에 내려받기 기록(R1)
  {
    const svcLog = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    if (!(await recordProvision(svcLog, userDb, token, campaignId, "results_excel", res))) {
      return jsonResponse({ success: false, reason: "record_failed" });
    }
  }

  // 2-c-2) excel — 응답 안의 영수증 통 경로만 7일 서명(원본 + 썸네일) · 올린 사람 대조에 걸린 줄은 비운다
  if (targets.length) {
    const svc = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    // deno-lint-ignore no-explicit-any
    const ok = await signableMap(svc, (targets as any[]).filter((d) => d.receipt_url).map((d) => String(d.id)));
    const paths: string[] = [];
    // deno-lint-ignore no-explicit-any
    for (const d of targets as any[]) {
      const m = d.receipt_url ? ok.get(String(d.id)) : undefined;
      if (!m) { d.receipt_url = null; d.receipt_thumb_url = null; continue; }
      d.__sign = m;                       // 대조한 값 — 아래에서 이것만 서명한다
      paths.push(m.path);
      if (m.thumb) paths.push(m.thumb);
    }
    const unique = [...new Set(paths)];
    const signed = new Map<string, string>();
    for (let i = 0; i < unique.length; i += SIGN_CHUNK) {
      const chunk = unique.slice(i, i + SIGN_CHUNK);
      const { data: urls, error: signErr } = await svc.storage.from(BUCKET).createSignedUrls(chunk, EXPIRES.excel);
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
      const m = d.__sign as Signable | undefined;
      delete d.__sign;
      if (!m) continue;
      d.receipt_url = signed.get(m.path) ?? null;
      d.receipt_thumb_url = m.thumb ? (signed.get(m.thumb) ?? null) : null;
    }
  }
  res.signed_expires_in = EXPIRES.excel;
  return jsonResponse(res);
});
