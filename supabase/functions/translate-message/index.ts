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

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
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

  const record = payload.record;
  const messageId = record.id;

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
