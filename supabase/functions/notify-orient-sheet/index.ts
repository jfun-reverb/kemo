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
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TEMPLATES } from "./templates.ts";

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";

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

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  try {
    const { orient_sheet_id, to_email, to_name } = await req.json();
    if (!orient_sheet_id) {
      return new Response(JSON.stringify({ error: "orient_sheet_id required" }), {
        status: 400,
        headers: { "content-type": "application/json" },
      });
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
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { "content-type": "application/json" },
      });
    }
    const { data: adminRow } = await sb
      .from("admins")
      .select("id")
      .eq("auth_id", caller.id)
      .maybeSingle();
    if (!adminRow) {
      return new Response(JSON.stringify({ error: "Forbidden" }), {
        status: 403,
        headers: { "content-type": "application/json" },
      });
    }

    // 1) 시트 조회 (브랜드 마스터명 join — 메일 제목·본문 브랜드명을 확실히 채움)
    const { data: sheet, error: sheetErr } = await sb
      .from("orient_sheets")
      .select("id, token, application_id, brand_id, status, token_expires_at, data, brands(name)")
      .eq("id", orient_sheet_id)
      .maybeSingle();
    if (sheetErr) throw sheetErr;
    if (!sheet) {
      return new Response(JSON.stringify({ sent: false, reason: "sheet_not_found" }), {
        status: 404,
        headers: { "content-type": "application/json" },
      });
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
      return new Response(JSON.stringify({ sent: false, reason: "no_recipient" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
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

    return new Response(
      JSON.stringify({ sent: true, recipient: recipient.email, advanced, advance_reason: advanceReason }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  } catch (e) {
    const msg = (e as Error).message || "unknown";
    console.error("[notify-orient-sheet] error", msg, (e as Error).stack);
    return new Response(JSON.stringify({ sent: false, error: msg }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
});
