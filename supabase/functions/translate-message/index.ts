// ══════════════════════════════════════════════════════════════════
// Edge Function: translate-message
// ──────────────────────────────────────────────────────────────────
// 트리거: Database Webhook (application_messages INSERT)
//          notify-orient-submitted 의 Webhook 실행 패턴을 미러링.
//
// CORS 관련 (.claude/rules/supabase.md 「Edge Function CORS」 필수):
//   이 함수는 브라우저(관리자·인플루언서 화면)가 functions.invoke() 로
//   직접 호출하지 않는다 — 클라이언트 코드 어디에도 호출부가 없다
//   (grep -rl "functions\.invoke\(['\"]translate-message" dev/ → 0건).
//   실행은 오직 Supabase Database Webhook(서버 → 서버 호출)이 트리거하므로
//   교차 출처(브라우저 ↔ *.supabase.co) 상황이 아니다 → CORS 헤더/OPTIONS
//   preflight 처리가 필요 없다. (다른 브라우저 직접 호출 함수와 성격이 다름 —
//   오리엔시트 발급 메일 notify-orient-sheet 사고 전례와 반대 케이스.)
//
// 역할:
//   1) 웹훅 페이로드에서 신규 메시지(record) 를 받는다.
//   2) 본문이 비어있으면(첨부만 있는 메시지) translate_status='skipped' 로
//      기록하고 종료 — 번역 API 호출 자체를 하지 않는다(비용 절약).
//   3) sender_kind 로 번역 대상 언어를 정한다:
//        influencer(일본어로 씀) → target='ko' (관리자가 읽을 한국어)
//        admin(한국어로 씀)      → target='ja' (인플루언서가 읽을 일본어)
//      source 는 지정하지 않고 Google 자동 감지에 맡긴다(사양서 §의심 8 —
//      드물게 반대 언어로 쓰는 예외 대응).
//   4) Google Cloud Translation v2 REST API 호출.
//        감지된 원본 언어가 target 과 같으면(이미 상대 언어로 씀) 번역 없이
//        skipped 처리(무의미한 API 호출·저장 방지).
//   5) 성공 시 body_translated·translated_lang·translate_status='done' 을
//      해당 메시지 행에 UPDATE (service_role).
//   6) Google API 실패·타임아웃 시 translate_status='failed' 로 기록하고
//      200 응답 반환 — best-effort. 메시지 발송·조회 흐름에는 전혀 영향 없음
//      (화면은 body_translated=NULL 이면 원문만 표시하는 폴백 구조).
//
// 로그 정책:
//   메시지 본문(개인정보 포함 가능)은 로그에 남기지 않는다. id·상태·언어만 기록.
//
// Dashboard Webhook 설정 (양 서버 모두 필요):
//   Supabase Dashboard → Database → Webhooks → Create new Webhook
//     Name    : translate-message
//     Table   : public.application_messages
//     Events  : INSERT
//     Type    : Supabase Edge Functions
//     Function: translate-message
//     HTTP Method: POST
//     HTTP Headers: (기본)
//   🔴 웹훅 하나 더(서비스 문의 대화 제목 — 마이그레이션 507·508, 개발·운영 각각):
//     Name    : translate-inquiry-thread-title
//     Table   : public.general_inquiry_threads
//     Events  : INSERT, UPDATE   (UPDATE 는 운영팀 제목 고치기 — 닫기·다시 열기도 오지만 함수가 상태를 보고 끝낸다)
//     나머지는 위와 같다(Supabase Edge Functions · translate-message · POST)
//
// 환경변수 (Edge Functions Secrets, 개발/운영 각각 설정 필요):
//   GOOGLE_TRANSLATE_API_KEY   Google Cloud Translation API 키
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY  (런타임 자동 주입)
//
// 배포 명령 (개발 → 운영 순서로 양 환경 모두 배포 필수):
//   supabase functions deploy translate-message --project-ref qysmxtipobomefudyixw   # 개발
//   supabase functions deploy translate-message --project-ref nrwtujmlbktxjgdwlpjj   # 운영
//   (양 환경 secrets set GOOGLE_TRANSLATE_API_KEY=xxx 1회씩 선행 필요)
//
// 관련 마이그레이션: supabase/migrations/235_message_translation.sql
// 사양서: docs/specs/2026-07-13-message-translation.md
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const GOOGLE_TRANSLATE_ENDPOINT = "https://translation.googleapis.com/language/translate/v2";

// 번역 API 에 보내는 본문 길이 상한. 메시지 rate limit(사용자당 100건/시간) 상
// 실제 메시지는 이보다 훨씬 짧지만, 방어적으로 상한을 둔다.
const MAX_TRANSLATE_LEN = 5000;

// 외부 API 호출 타임아웃 (ms). 초과 시 실패로 간주하고 원문 폴백.
const TRANSLATE_TIMEOUT_MS = 8000;

interface ApplicationMessageRecord {
  id: string;
  application_id: string;
  sender_kind: "influencer" | "admin";
  body: string | null;
  [key: string]: unknown;
}

interface WebhookPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  schema: string;
  record: ApplicationMessageRecord;
  old_record?: ApplicationMessageRecord | null;
}

function env(key: string, fallback = ""): string {
  return Deno.env.get(key) ?? fallback;
}

function targetLangFor(senderKind: string): "ko" | "ja" {
  // influencer 는 일본어로 쓴다고 가정 → 관리자가 읽을 한국어로 번역
  // admin 은 한국어로 쓴다고 가정 → 인플루언서가 읽을 일본어로 번역
  return senderKind === "influencer" ? "ko" : "ja";
}

function getServiceClient() {
  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) {
    throw new Error("Supabase service credentials not configured");
  }
  return createClient(supaUrl, serviceKey, { auth: { persistSession: false } });
}

// application_messages 행의 번역 관련 컬럼만 UPDATE. 실패해도 throw 하지 않고
// 로그만 남긴다 — 이 함수 자체가 이미 best-effort 파이프라인의 일부이므로.
async function updateTranslationColumns(
  messageId: string,
  patch: {
    body_translated?: string | null;
    translated_lang?: "ko" | "ja" | null;
    translate_status: "done" | "failed" | "skipped";
  },
): Promise<void> {
  const sb = getServiceClient();
  const { error } = await sb
    .from("application_messages")
    .update(patch)
    .eq("id", messageId);
  if (error) {
    console.error("[translate-message] update failed", { messageId, error: error.message });
  }
}

interface GoogleTranslateResult {
  translatedText: string;
  detectedSourceLanguage?: string;
}

async function callGoogleTranslate(text: string, target: string): Promise<GoogleTranslateResult> {
  const apiKey = env("GOOGLE_TRANSLATE_API_KEY");
  if (!apiKey) throw new Error("GOOGLE_TRANSLATE_API_KEY not configured");

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TRANSLATE_TIMEOUT_MS);

  try {
    const res = await fetch(`${GOOGLE_TRANSLATE_ENDPOINT}?key=${apiKey}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ q: text, target, format: "text" }),
      signal: controller.signal,
    });

    if (!res.ok) {
      const errText = await res.text();
      throw new Error(`Google Translate failed ${res.status}: ${errText}`);
    }

    const data = await res.json();
    const translation = data?.data?.translations?.[0];
    if (!translation?.translatedText) {
      throw new Error("Google Translate response missing translatedText");
    }
    return {
      translatedText: translation.translatedText as string,
      detectedSourceLanguage: translation.detectedSourceLanguage as string | undefined,
    };
  } finally {
    clearTimeout(timer);
  }
}

// ── 서비스 문의 대화 제목 번역(사양서 2026-10-06 「🔄 설계 개정」 R2-6) ─────────
//   회원이 일본어로 쓴 제목을 관리자 화면용 한국어로. 결과는 general_inquiry_threads 의
//   title_translated · title_translate_status 에 저장한다.
//   🔴 번역하는 조건 = 행의 번역 상태가 'pending' 이고 제목이 있을 때만. 상태는 제목이 생기거나
//      바뀔 때만 'pending' 이 된다(508 발신 함수 · 제목 고치기 함수) — 닫기·다시 열기로 오는
//      고쳐 쓰기 웹훅은 상태가 그대로라 여기서 끝난다(유료 번역 API 를 부르지 않는다).
//   🔴 요청 본문은 대화 번호만 쓰고 제목·상태는 데이터베이스 행에서 읽는다(메시지 갈래와 같은 원칙).
//   🔴 저장 직전에 제목이 그대로이고 아직 'pending' 인지 다시 본다 — 번역 도중 운영팀이 제목을
//      바꾸거나 비웠으면 저장하지 않는다(옛 번역이 되살아나지 않게).
//   제목이 비어 있으면(운영팀이 비움 · 옛 화면이 만든 제목 없는 대화) 상태가 'pending' 이 아니므로 그대로 끝난다.
async function handleThreadTitle(threadId: string): Promise<Response> {
  const json = (body: unknown) =>
    new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
  const sb = getServiceClient();
  const { data: row, error: rowErr } = await sb
    .from("general_inquiry_threads")
    .select("id, title, title_translate_status")
    .eq("id", threadId)
    .maybeSingle();
  if (rowErr || !row) {
    console.error("[translate-message] thread fetch failed or not found", { threadId, error: rowErr?.message });
    return json({ skipped: true, reason: rowErr ? "fetch_error" : "not_found" });
  }
  const title = (row.title ?? "").trim();
  if (row.title_translate_status !== "pending" || !title) {
    return json({ skipped: true, reason: "title_not_pending" });
  }

  // 저장 — 제목이 그대로이고 아직 pending 인 행에만(그 사이 바뀌었으면 0행 = 저장 안 함)
  const save = async (patch: { title_translated?: string | null; title_translate_status: "done" | "failed" | "skipped" }) => {
    const { error } = await sb
      .from("general_inquiry_threads")
      .update(patch)
      .eq("id", threadId)
      .eq("title", row.title)
      .eq("title_translate_status", "pending");
    if (error) console.error("[translate-message] thread update failed", { threadId, error: error.message });
  };

  let result: GoogleTranslateResult;
  try {
    result = await callGoogleTranslate(title, "ko");
  } catch (apiErr) {
    console.error("[translate-message] google translate error (thread title)", { threadId, message: (apiErr as Error).message });
    await save({ title_translate_status: "failed" });
    return json({ translated: false, reason: "api_error" });
  }
  // 이미 한국어로 쓴 제목 — 번역 불필요(화면은 원문만)
  if (result.detectedSourceLanguage === "ko") {
    await save({ title_translated: null, title_translate_status: "skipped" });
    return json({ skipped: true, reason: "same_language" });
  }
  await save({ title_translated: result.translatedText, title_translate_status: "done" });
  console.log("[translate-message] thread title done", { threadId });
  return json({ translated: true, target: "ko" });
}

// ── 공개 키로 부르는 것을 막는다 ────────────────────────────────
// 🔴 이 함수는 **메일을 보낸다.** 막는 것이 없으면 사이트에 박힌 공개 키만으로
//    누구나 발송을 시킬 수 있다(2026-09-02 전수조사 — 같은 형태가 여섯 개였다).
// ⚠️ 공개 키를 교체하면 이 목록도 함께 갱신할 것.
const PUBLIC_CLIENT_KEYS = [
  "sb_publishable_3pfK7sF55NZO7owlm13_uA_iCbORAvP",  // 운영
  "sb_publishable_WTxFsvQFllOPIdQ8MDNwCw_e0qBlYTv",  // 개발
];

// 옛 형식(JWT) 키는 **값을 적지 않고 안에 든 role 표시를 보고** 막는다.
//   🔴 2026-09-03 실측 — 위 목록에는 「지금 화면에 실려 있는 키」만 있었는데, 프로젝트에는
//   **옛 형식 anon 키가 아직 활성 상태**로 남아 있었다. 그 키를 가진 사람(옛 판을 캐시로
//   물고 있는 브라우저·저장해 둔 사람)은 이 함수들을 그대로 부를 수 있었다 — 어제 건
//   차단의 절반이 비어 있던 셈이다.
//   ⚠️ 값을 목록에 더하는 대신 role 을 보는 이유 셋: ①키 값을 소스에 늘리지 않는다
//   ②앞으로 키가 새로 생겨도 자동으로 막힌다 ③운영·개발 키를 따로 챙길 필요가 없다.
//   ⚠️ 서명은 검증하지 않는다 — 그건 플랫폼이 한다. 여기는 「정상 경로로 들어온 호출이
//   어떤 역할인가」만 본다(다중 방어의 한 겹이지 유일한 방어선이 아니다).
//   🔴 service_role 은 반드시 통과시킨다 — 운영 웹훅 4개가 **전부 옛 형식 service_role
//   JWT** 로 부른다(2026-09-03 확인: application_messages·brand_applications·
//   notifications·orient_sheets). 여기서 옛 JWT 를 통째로 막으면 자동 번역·광고주 접수
//   알림·검수 결과 메일·오리엔 제출 알림이 **한꺼번에 죽는다.** anon 만 막는다.
// JWT 의 역할(role)만 읽는다 — 서명은 플랫폼이 이미 검증했다. 못 읽으면 null(막지 않는다).
function jwtRole(token: string): string | null {
  if (!token.startsWith("eyJ")) return null;
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const payload = JSON.parse(atob(b64 + "=".repeat((4 - (b64.length % 4)) % 4)));
    return typeof payload?.role === "string" ? payload.role : null;
  } catch {
    return null;   // 못 읽으면 막지 않는다 — 정상 발송을 세우는 쪽이 더 나쁘다
  }
}

function rejectPublicKeyCaller(req: Request, tag: string): boolean {
  const raw = (req.headers.get("Authorization") ?? "").trim();
  const token = raw.replace(/^Bearer\s+/i, "").trim();
  if (!token) return false;                       // 토큰 없음 — 플랫폼이 이미 막는다
  if (PUBLIC_CLIENT_KEYS.includes(token)) {
    console.warn(`[${tag}] rejected — called with the public client key`);
    return true;
  }
  // 🔴 비로그인(anon)·로그인 회원(authenticated) 토큰은 거부한다(2026-09-28 전수조사 3차).
  //   회원가입은 누구나 할 수 있어 authenticated 토큰도 사실상 공개다 — 예전에는 anon 만 막아
  //   로그인한 회원이 방침 통지 시험 발송(임의 주소)·홍보 메일 전체 발송을 부를 수 있었다.
  //   예약 실행(vault edge_function_jwt)·데이터베이스 웹훅은 service_role 이라 통과한다.
  const role = jwtRole(token);
  if (role === "anon" || role === "authenticated") {
    console.warn(`[${tag}] rejected — called with an end-user JWT`, { role });
    return true;
  }
  // 토큰 자체는 절대 남기지 않는다.
  const isServiceRole = token === (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
  console.log(`[${tag}] caller check passed`, { isServiceRole, role });
  return false;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }
  // 🔴 웹훅(service_role) 말고는 거부한다(2026-10-01 — 이 함수만 호출자 검사가 빠져 있었다).
  //   없으면 로그인한 회원이 아무 메시지 번호와 본문을 보내 **남의 메시지 번역문을 덮어쓸** 수 있었다.
  //   ⚠️ 검사 본문은 다른 웹훅 함수 11개와 **글자 그대로 같다** — 고칠 때 함께.
  if (rejectPublicKeyCaller(req, "translate-message")) {
    return new Response(JSON.stringify({ error: "forbidden" }), {
      status: 403,
      headers: { "content-type": "application/json" },
    });
  }

  let payload: WebhookPayload;
  try {
    payload = (await req.json()) as WebhookPayload;
  } catch (_e) {
    return new Response(JSON.stringify({ skipped: true, reason: "invalid_json" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  console.log("[translate-message] payload received", {
    type: payload?.type,
    table: payload?.table,
    record_id: payload?.record?.id,
  });

  // 서비스 문의 대화 제목(마이그레이션 507·508) — 대화 표의 삽입·고쳐 쓰기 웹훅
  if (payload?.table === "general_inquiry_threads" && payload?.record?.id
      && (payload.type === "INSERT" || payload.type === "UPDATE")) {
    // 예상 못 한 오류(환경변수 누락·네트워크)도 200 으로 끝낸다 — 웹훅 재시도 폭주 방지(메시지 갈래와 같은 원칙)
    try {
      return await handleThreadTitle(String(payload.record.id));
    } catch (e) {
      console.error("[translate-message] thread title top-level error", { threadId: payload.record.id, message: (e as Error).message });
      return new Response(JSON.stringify({ skipped: true, reason: "error" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }
  }

  // INSERT + application_messages 이벤트만 처리 (Dashboard Webhook 필터가
  // 걸러주지만 이중 안전장치 — notify-orient-submitted 패턴 동일)
  if (
    payload?.type !== "INSERT" ||
    payload?.table !== "application_messages" ||
    !payload?.record?.id
  ) {
    console.log("[translate-message] skipped: non-target event");
    return new Response(JSON.stringify({ skipped: true, reason: "non-target" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  const messageId = payload.record.id;

  // 🔴 본문·보낸 쪽은 **데이터베이스의 행**에서 읽는다 — 요청 본문은 번호만 쓴다(2026-10-01).
  //   이미 처리된 메시지(translate_status 가 채워짐)는 다시 번역하지 않는다 — 같은 번호로
  //   반복 호출해 유료 번역 사용량을 태우거나 번역문을 바꾸는 것을 막는다.
  const { data: record, error: rowErr } = await getServiceClient()
    .from("application_messages")
    .select("id, sender_kind, body, translate_status")
    .eq("id", messageId)
    .maybeSingle();
  if (rowErr || !record) {
    console.error("[translate-message] message fetch failed or not found", { messageId, error: rowErr?.message });
    return new Response(JSON.stringify({ skipped: true, reason: rowErr ? "fetch_error" : "not_found" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }
  if (record.translate_status) {
    console.log("[translate-message] skipped: already processed", { messageId, status: record.translate_status });
    return new Response(JSON.stringify({ skipped: true, reason: "already_processed" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  try {
    // 본문 빈값(첨부만 있는 메시지) → 번역 대상 아님
    const rawBody = (record.body ?? "").trim();
    if (!rawBody) {
      await updateTranslationColumns(messageId, { translate_status: "skipped" });
      console.log("[translate-message] skipped: empty body", { messageId });
      return new Response(JSON.stringify({ skipped: true, reason: "empty_body" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }

    const target = targetLangFor(record.sender_kind);
    const textToTranslate = rawBody.slice(0, MAX_TRANSLATE_LEN);

    let result: GoogleTranslateResult;
    try {
      result = await callGoogleTranslate(textToTranslate, target);
    } catch (apiErr) {
      // 외부 API 실패·타임아웃 — best-effort, 원문 폴백 유지
      console.error("[translate-message] google translate error", {
        messageId,
        message: (apiErr as Error).message,
      });
      await updateTranslationColumns(messageId, { translate_status: "failed" });
      return new Response(JSON.stringify({ translated: false, reason: "api_error" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }

    // 이미 대상 언어로 쓴 메시지(감지된 원본 언어 == target) → 번역 불필요
    if (result.detectedSourceLanguage && result.detectedSourceLanguage === target) {
      await updateTranslationColumns(messageId, { translate_status: "skipped" });
      console.log("[translate-message] skipped: already target language", {
        messageId,
        target,
      });
      return new Response(JSON.stringify({ skipped: true, reason: "same_language" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }

    await updateTranslationColumns(messageId, {
      body_translated: result.translatedText,
      translated_lang: target,
      translate_status: "done",
    });

    console.log("[translate-message] done", { messageId, target });
    return new Response(JSON.stringify({ translated: true, target }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  } catch (e) {
    // 예상 못한 오류도 best-effort — 실패 상태만 남기고 200 반환(웹훅 재시도 폭주 방지)
    const msg = (e as Error).message || "unknown";
    console.error("[translate-message] top-level error", { messageId, message: msg });
    try {
      await updateTranslationColumns(messageId, { translate_status: "failed" });
    } catch (_ignored) {
      // 업데이트마저 실패하면 그냥 넘어감 — 다음 재시도나 수동 확인 대상
    }
    return new Response(JSON.stringify({ translated: false, error: msg }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }
});
