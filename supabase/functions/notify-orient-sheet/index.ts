// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-orient-sheet
// ──────────────────────────────────────────────────────────────────
// 트리거: 관리자 발급(create_orient_sheet) 직후 admin-orient.js 가
//          supabase.functions.invoke('notify-orient-sheet', { orient_sheet_id })
//          로 직접 호출 (Webhook 아님 — 발급 화면에서 발송 성공/실패를 즉시 표시).
//
// 역할:
//   1) orient_sheet_id 로 시트 조회(토큰·연결 신청·브랜드·상태·브랜드명)
//   2) 수신자 이메일 결정
//        - 서베이 연결 건: brand_applications.applicant_email(없으면 email)
//        - 비-서베이 건  : brands 대표 담당자(contacts is_primary / primary_email)
//   3) 수신자 없으면 발송·단계전이 건너뛰고 {sent:false, reason:'no_recipient'} 반환
//   4) 작성 링크 = PUBLIC_SALES_URL + '/orient?token=' + token (서버 환경변수 — 클라 링크 조작 방지)
//   5) Brevo 로 브랜드에게 1통 발송
//   6) 발송 성공 + 연결 신청 있으면 advance_to_orient_sheet_sent(application_id) 호출
//        (단계 자동 전진 — 역행 방지·신청 연결 건만은 함수 198 안에서 처리)
//
// 환경변수 (Edge Functions Secrets):
//   BREVO_API_KEY          Brevo Transactional API 키
//   PUBLIC_SALES_URL       sales 도메인 절대 URL (운영 https://sales.globalreverb.com / 개발 https://sales-dev.globalreverb.com)
//   BREVO_SENDER_EMAIL     발신자 이메일 (기본 noreply@globalreverb.com)
//   BREVO_SENDER_NAME      발신자 이름 (기본 REVERB JP)
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY  (런타임 자동 주입)
//
// 템플릿:
//   templates.ts (sync-email-templates.sh 자동 생성) → TEMPLATES['orient-sheet-invite']
//   원본 docs/email-templates/orient-sheet-invite.html, 배포 전 sync 실행 필수.
//
// 배포 명령 (개발 → 운영 순서로 양 환경 모두 배포 필수):
//   bash scripts/sync-email-templates.sh
//   supabase functions deploy notify-orient-sheet --project-ref qysmxtipobomefudyixw   # 개발
//   supabase functions deploy notify-orient-sheet --project-ref <운영 ref>             # 운영
//   supabase secrets set PUBLIC_SALES_URL=https://sales.globalreverb.com --project-ref <운영 ref>
//   supabase secrets set PUBLIC_SALES_URL=https://sales-dev.globalreverb.com --project-ref qysmxtipobomefudyixw
//
// 메일 발송 테스트는 운영에서만 (supabase.md 정책 — 개발은 환경 동기화만).
//
// ── 브랜드 계정 받는 사람 규칙 (작업표 docs/specs/2026-10-16-brand-orient-tab-breakdown.md 조각 10 · 사양서 16-5 8·9번) ──
//   🔴 두 겹 잠금 — ① 비밀값 ORIENT_MAIL_TO_BRAND_ACCOUNTS === "1" **그리고** ② 이 함수가 개발 프로젝트에서 돌 때만 켜진다.
//      운영에 이 함수가 먼저 배포돼도(다른 이유로 배포하는 순간) 운영 발급 메일이 「받는 사람 없음」이 되지 않게 하려는 것이다
//      — 운영 데이터베이스에는 브랜드 계정이 없다. 출시 때 ①운영 비밀값을 넣고 ②아래 isStagingProject() 조건을 걷어 운영에 다시 배포한다.
//   켜지면:
//     · 받는 사람 = 그 시트 브랜드(활성)에 활성 연결된 계정 중 비밀번호를 정한 계정 전원(대표 먼저) — 이용 제한 중인 계정은 뺀다.
//       판정은 데이터베이스 service_brand_mailable_accounts 한 곳(이용 제한 작업표 제한 5 — 옛 직접 조회 사본은 걷었다).
//       🔴 배포는 그 함수가 있는 데이터베이스에서만(제한 2 적용 뒤) — 없으면 브랜드 계정 갈래 발급 메일이 전부 500. 화면이 넘긴 to_email 은 무시한다
//       (남기면 받는 사람 고르는 칸을 없앤 것이 서버에서 다시 열린다). 신청서 이메일 갈래도 쓰지 않는다
//     · 1명당 1통(받는 사람끼리 주소가 안 보이게) · 호칭 「{계정 이름}님」(이름이 비면 「{브랜드명} 담당자님」 — 결정 12)
//     · 링크 = PUBLIC_BRAND_URL + '/brand/?orient=' + 시트 번호(브랜드 페이지가 로그인 뒤 그 시트를 연다). 양식 orient-sheet-invite-brand
//     · 결과 {sent, recipients:[보낸 주소], failed:[못 보낸 주소], reason?:'no_account'} — 받을 계정이 0명이면 보내지 않고 no_account
//     · 기록: 1명 이상 성공이면 mail_sent_at + mail_sent_to = 보낸 주소를 「, 」로 이은 값(일부 실패면 성공분만) · 전원 실패면 기록 안 함
//     · 1명 이상 성공 + 연결 신청이면 서베이 상태 자동 전진(지금 규칙 그대로)
//   비밀값: ORIENT_MAIL_TO_BRAND_ACCOUNTS(개발서버에만 "1") · PUBLIC_BRAND_URL(브랜드 계정 메일 함수와 같은 값 — 기본값 없음)
//     supabase secrets set ORIENT_MAIL_TO_BRAND_ACCOUNTS=1 --project-ref qysmxtipobomefudyixw
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TEMPLATES } from "./templates.ts";

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";
const STAGING_PROJECT_REF = "qysmxtipobomefudyixw";

// CORS — 이 함수는 관리자 화면(globalreverb.com 등)에서 supabase.functions.invoke 로 직접 호출한다.
// 다른 도메인(*.supabase.co) 호출이라 브라우저가 사전요청(OPTIONS)+응답 CORS 헤더를 요구.
// 헤더 없으면 브라우저가 응답을 차단(Network 에 "CORS error"). 인증은 함수 내부 JWT+admins 검증으로 별도 보장.
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// JSON 응답 + CORS 헤더 일괄 부착 헬퍼
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

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// 🔴 두 겹 잠금(머리말 참고) — 출시 때 isStagingProject() 조건만 걷는다. 비밀값 조건은 남긴다
function isStagingProject(): boolean {
  return env("SUPABASE_URL").includes(`://${STAGING_PROJECT_REF}.`);
}
function brandAccountRuleEnabled(): boolean {
  return env("ORIENT_MAIL_TO_BRAND_ACCOUNTS") === "1" && isStagingProject();
}

// 작성 기한 표기 (ja-JP 와 통일된 한국어 날짜 — YYYY. M. D.)
function fmtDeadline(iso?: string | null): string {
  if (!iso) return "-";
  const d = new Date(iso);
  if (isNaN(d.getTime())) return "-";
  // 한국/일본 표준시 기준 날짜
  return d.toLocaleDateString("ko-KR", { timeZone: "Asia/Seoul", year: "numeric", month: "long", day: "numeric" });
}

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

// 수신자 이메일·이름 결정. 서베이 연결 건 / 비-서베이 건 분기.
async function resolveRecipient(
  sb: ReturnType<typeof createClient>,
  applicationId: string | null,
  brandId: string,
): Promise<{ email: string; name: string } | null> {
  if (applicationId) {
    // 서베이 연결: applicant_email(082 스냅샷) 우선, 없으면 email(원본)
    const { data, error } = await sb
      .from("brand_applications")
      .select("applicant_email, email, contact_name")
      .eq("id", applicationId)
      .maybeSingle();
    if (error) throw error;
    const email = ((data?.applicant_email || data?.email || "") as string).trim();
    if (!email) return null;
    return { email, name: ((data?.contact_name || "") as string).trim() };
  }

  // 비-서베이: brands 대표 담당자 contacts(is_primary) → primary_email fallback
  const { data, error } = await sb
    .from("brands")
    .select("primary_email, contacts, name")
    .eq("id", brandId)
    .maybeSingle();
  if (error) throw error;

  let email = "";
  let name = "";
  const contacts = Array.isArray(data?.contacts) ? data!.contacts : [];
  const primary = contacts.find((c: Record<string, unknown>) => c?.is_primary === true) || contacts[0];
  if (primary) {
    email = String(primary.email || "").trim();
    name = String(primary.name || "").trim();
  }
  if (!email) email = String(data?.primary_email || "").trim();
  if (!email) return null;
  return { email, name: name || String(data?.name || "").trim() };
}

// 받는 사람 = 데이터베이스 규칙 service_brand_mailable_accounts(이용 제한 작업표 제한 2 — 557 _brand_mailable_accounts 의
//   서비스 키 감싸개)가 정한다: 활성 브랜드 · 활성 연결 · 비밀번호 정함 · 이용 제한 중 아님 · 대표 먼저 · 같은 주소는 한 번.
//   🔴 이 함수 안에 규칙을 다시 베끼지 않는다(옛 사본은 제한 5 에서 걷었다 — 판정식 한 곳, 사양서 R4).
async function resolveBrandAccountRecipients(
  sb: ReturnType<typeof createClient>,
  brandId: string,
): Promise<{ email: string; name: string }[]> {
  const { data, error } = await sb.rpc("service_brand_mailable_accounts", { p_brand_id: brandId });
  if (error) throw error;
  const rows = (Array.isArray(data) ? data : []) as Array<Record<string, unknown>>;
  const out: { email: string; name: string }[] = [];
  for (const r of rows) {
    const email = String(r?.email || "").trim().toLowerCase();
    if (!email) continue;
    out.push({ email, name: String(r?.name || "").trim() });
  }
  return out;
}

// 브랜드 계정 받는 사람 규칙 — 머리말 「브랜드 계정 받는 사람 규칙」. 화면이 넘긴 to_email 은 받지도 않는다
async function sendToBrandAccounts(
  sb: ReturnType<typeof createClient>,
  sheet: Record<string, any>,
): Promise<Response> {
  const recipients = await resolveBrandAccountRecipients(sb, sheet.brand_id);
  if (!recipients.length) {
    // 받을 계정이 없다 — 보내지 않고, 나중에 계정이 설정을 마쳐도 다시 보내지 않는다(16-5 8번). 단계 전진도 없다
    console.warn("[notify-orient-sheet] no brand account recipient", { orient_sheet_id: sheet.id });
    return jsonResponse({ sent: false, reason: "no_account", recipients: [], failed: [] }, 200);
  }

  const brandBase = env("PUBLIC_BRAND_URL").replace(/\/$/, "");
  if (!/^https:\/\/[^/\s]+$/.test(brandBase)) throw new Error("PUBLIC_BRAND_URL not configured");
  const link = `${brandBase}/brand/?orient=${sheet.id}`;
  const brandName = String((sheet.brands?.name) || (sheet.data?.brand?.name) || "").trim() || "브랜드";
  const deadline = fmtDeadline(sheet.token_expires_at);
  const subject = `[REVERB JP] 캠페인 오리엔시트 작성 요청 — ${brandName}`;
  const tpl = TEMPLATES["orient-sheet-invite-brand"].replace(/<!--[\s\S]*?-->/g, "");
  // 링크는 비밀이 아니다(로그인해야 열린다) — 개발서버 확인용으로 로그에 남긴다(작업표 조각 10 완료 정의)
  console.log("[notify-orient-sheet] brand account rule", { orient_sheet_id: sheet.id, link, count: recipients.length });

  const sent: string[] = [];
  const failed: string[] = [];
  for (const r of recipients) {
    const greeting = r.name ? `${r.name}님` : `${brandName} 담당자님`;
    const html = render(tpl, {
      recipient_name: escapeHtml(greeting),
      brand_name: escapeHtml(brandName),
      link: escapeHtml(link),
      deadline: escapeHtml(deadline),
    });
    const text =
      `${greeting}\n\n` +
      `${brandName}의 캠페인 오리엔시트가 발급되었습니다.\n` +
      `브랜드 페이지에 로그인해 제품·콘텐츠 정보를 작성해 주십시오. 작성 중 자동 저장됩니다.\n\n` +
      `오리엔시트 작성: ${link}\n` +
      `작성 기한: ${deadline}\n\n` +
      `[문의]\n` +
      `· 카카오톡 byhyunho7\n` +
      `· 연락처 010-2550-1511\n`;
    try {
      await sendBrevoEmail({ to: [{ email: r.email, name: r.name || brandName }], subject, htmlContent: html, textContent: text });
      sent.push(r.email);
    } catch (e) {
      // 주소는 로그에 남기지 않는다(응답 failed 에 있다)
      console.error("[notify-orient-sheet] brand account send failed", { orient_sheet_id: sheet.id, error: (e as Error).message });
      failed.push(r.email);
    }
  }

  if (!sent.length) {
    // 전원 실패 — 기록·단계 전진 없음
    return jsonResponse({ sent: false, reason: "send_failed", recipients: [], failed }, 200);
  }

  const { error: trackErr } = await sb
    .from("orient_sheets")
    .update({ mail_sent_at: new Date().toISOString(), mail_sent_to: sent.join(", ") })
    .eq("id", sheet.id);
  if (trackErr) console.error("[notify-orient-sheet] mail_sent_at update failed", trackErr.message);

  let advanced = false;
  let advanceReason: string | null = null;
  if (sheet.application_id) {
    const { data: adv, error: advErr } = await sb.rpc("advance_to_orient_sheet_sent", {
      p_application_id: sheet.application_id,
    });
    if (advErr) {
      console.error("[notify-orient-sheet] advance failed", advErr.message);
      advanceReason = "rpc_error";
    } else {
      advanced = adv?.success === true;
      advanceReason = adv?.reason ?? null;
    }
  }

  return jsonResponse(
    { sent: true, recipients: sent, failed, recipient: sent.join(", "), advanced, advance_reason: advanceReason },
    200,
  );
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
    const { orient_sheet_id, to_email, to_name } = await req.json();
    if (!orient_sheet_id) {
      return jsonResponse({ error: "orient_sheet_id required" }, 400);
    }

    const supaUrl = env("SUPABASE_URL");
    const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
    if (!supaUrl || !serviceKey) throw new Error("Supabase service credentials not configured");
    const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

    // 0) 호출자 인증 — 관리자(admins)만 발송 허용.
    //    to_email 오버라이드로 임의 수신자에게 발송하는 스팸 악용을 차단(anon 키는 공개되므로 JWT 검증 필수).
    const authHeader = req.headers.get("Authorization") ?? "";
    const anonKey = env("SUPABASE_ANON_KEY");
    const userSb = createClient(supaUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false },
    });
    const { data: authData } = await userSb.auth.getUser();
    const caller = authData?.user;
    if (!caller) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    const { data: adminRow } = await sb
      .from("admins")
      .select("id")
      .eq("auth_id", caller.id)
      .maybeSingle();
    if (!adminRow) {
      return jsonResponse({ error: "Forbidden" }, 403);
    }

    // 1) 시트 조회 (브랜드 마스터명 join — 메일 제목·본문 브랜드명을 확실히 채움)
    const { data: sheet, error: sheetErr } = await sb
      .from("orient_sheets")
      .select("id, token, application_id, brand_id, status, token_expires_at, data, brands(name, status)")
      .eq("id", orient_sheet_id)
      .maybeSingle();
    if (sheetErr) throw sheetErr;
    if (!sheet) {
      return jsonResponse({ sent: false, reason: "sheet_not_found" }, 404);
    }

    // 1-b) 브랜드 계정 받는 사람 규칙(두 겹 잠금 — 머리말). 켜져 있으면 아래 옛 갈래(화면 주소 우선·신청서 이메일)를 타지 않는다
    if (brandAccountRuleEnabled()) {
      return await sendToBrandAccounts(sb, sheet as Record<string, any>);
    }

    // 2) 수신자 결정 — 클라가 to_email 명시(브랜드만 선택 발급 시 수신자 선택) 우선, 없으면 기존 자동 결정 폴백
    let recipient: { email: string; name: string } | null = null;
    const overrideEmail = (typeof to_email === "string" ? to_email : "").trim();
    if (overrideEmail && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(overrideEmail)) {
      recipient = { email: overrideEmail, name: (typeof to_name === "string" ? to_name : "").trim() };
    } else {
      recipient = await resolveRecipient(sb, sheet.application_id, sheet.brand_id);
    }
    if (!recipient) {
      // 3) 수신자 없음 — 발송·단계전이 건너뜀(발급 자체는 이미 성공). 단계 전이 안 함.
      console.warn("[notify-orient-sheet] no recipient email", { orient_sheet_id });
      return jsonResponse({ sent: false, reason: "no_recipient" }, 200);
    }

    // 4) 작성 링크 (서버 환경변수 도메인 — 클라 조작 방지)
    const salesBase = env("PUBLIC_SALES_URL", "https://sales-dev.globalreverb.com").replace(/\/$/, "");
    const link = `${salesBase}/orient?token=${sheet.token}`;

    const brandName = String(
      (sheet.brands?.name) || (sheet.data?.brand?.name) || recipient.name || "",
    ).trim() || "브랜드";
    const deadline = fmtDeadline(sheet.token_expires_at);

    // 5) 메일 발송
    const subject = `[REVERB JP] 캠페인 오리엔시트 작성 요청 — ${brandName}`;
    // HTML 주석 strip — templates.ts 인라인 원본 주석이 메일 본문에 누출되는 것 차단
    // (notify-deliverable-decision 동일 패턴, 메모리 mail_template_comment_leak)
    const tpl = TEMPLATES["orient-sheet-invite"].replace(/<!--[\s\S]*?-->/g, "");
    const html = render(tpl, {
      brand_name: escapeHtml(brandName),
      link: escapeHtml(link),
      deadline: escapeHtml(deadline),
    });
    const text =
      `${brandName} 담당자님\n\n` +
      `캠페인 진행에 필요한 제품·콘텐츠 정보를 아래 링크에서 작성해 주세요.\n` +
      `별도 로그인 없이 작성하실 수 있으며, 작성 중 자동 저장됩니다.\n\n` +
      `작성 링크: ${link}\n` +
      `작성 기한: ${deadline}\n\n` +
      `[문의]\n` +
      `· 카카오톡 byhyunho7\n` +
      `· 연락처 010-2550-1511\n`;

    await sendBrevoEmail({
      to: [{ email: recipient.email, name: recipient.name || brandName }],
      subject,
      htmlContent: html,
      textContent: text,
    });
    console.log("[notify-orient-sheet] mail sent", { orient_sheet_id, to: recipient.email });

    // 발송 성공 기록 — 재발송 모달에서 버튼 비활성·발송 일시 표시용 (성공 분기에만 도달)
    // 기록 실패는 발송 성공을 무효화하지 않음 — advance 와 동일하게 로그만 남김
    const { error: trackErr } = await sb
      .from("orient_sheets")
      .update({ mail_sent_at: new Date().toISOString(), mail_sent_to: recipient.email })
      .eq("id", orient_sheet_id);
    if (trackErr) console.error("[notify-orient-sheet] mail_sent_at update failed", trackErr.message);

    // 6) 발송 성공 + 연결 신청 있으면 단계 자동 전진 (역행 방지·연결 건만은 함수 198 내부 처리)
    let advanced = false;
    let advanceReason: string | null = null;
    if (sheet.application_id) {
      const { data: adv, error: advErr } = await sb.rpc("advance_to_orient_sheet_sent", {
        p_application_id: sheet.application_id,
      });
      if (advErr) {
        // 단계 전이 실패는 발송 성공을 무효화하지 않음 — 로그만 남기고 메일은 갔다고 보고
        console.error("[notify-orient-sheet] advance failed", advErr.message);
        advanceReason = "rpc_error";
      } else {
        advanced = adv?.success === true;
        advanceReason = adv?.reason ?? null;
      }
    }

    return jsonResponse(
      { sent: true, recipient: recipient.email, advanced, advance_reason: advanceReason },
      200,
    );
  } catch (e) {
    const msg = (e as Error).message || "unknown";
    console.error("[notify-orient-sheet] error", msg, (e as Error).stack);
    return jsonResponse({ sent: false, error: msg }, 500);
  }
});
