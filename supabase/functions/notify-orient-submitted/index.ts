// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-orient-submitted
// ──────────────────────────────────────────────────────────────────
// 트리거: Database Webhook (orient_sheets UPDATE, status='submitted' 필터)
//          notify-brand-application 의 Webhook 패턴 미러링.
//
// 역할:
//   1) Webhook 페이로드에서 신규/재제출 판정
//        old_record.submitted_at IS NULL → 신규 제출
//        IS NOT NULL                     → 수정 재제출
//   2) 브랜드명·폼 종류·연결 신청 번호 조회 (service_role)
//   3) 관리자 수신자 결정
//        get_subscribed_admin_emails('brand_notify') + env NOTIFY_ADMIN_EMAILS
//   4) 관리자 1인 1통 분리 발송 (To 헤더 노출 차단)
//   5) 메일 발송 실패는 부분 실패로 처리 (제출 자체와 분리 — best-effort)
//
// Dashboard Webhook 설정 (양 서버 모두 필요):
//   Supabase Dashboard → Database → Webhooks → Create new Webhook
//     Name    : notify-orient-submitted
//     Table   : public.orient_sheets
//     Events  : UPDATE
//     Row filter: status = 'submitted'   ← NEW 기준, draft 저장 시 차단
//     Type    : Supabase Edge Functions
//     Function: notify-orient-submitted
//
// 환경변수 (Edge Functions Secrets):
//   BREVO_API_KEY        Brevo Transactional API 키
//   NOTIFY_ADMIN_EMAILS  추가 수신자 (콤마 구분, DB 구독자와 합산). 없어도 됨
//   PUBLIC_ADMIN_URL     관리자 페이지 절대 URL (딥링크용)
//   BREVO_SENDER_EMAIL   발신자 이메일 (기본 noreply@globalreverb.com)
//   BREVO_SENDER_NAME    발신자 이름 (기본 REVERB JP)
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY  (런타임 자동 주입)
//
// 템플릿:
//   templates.ts (sync-email-templates.sh 자동 생성) → TEMPLATES['orient-submitted-notify']
//   원본 docs/email-templates/orient-submitted-notify.html
//   배포 전 반드시 bash scripts/sync-email-templates.sh 실행.
//
// 배포 명령 (개발 → 운영 순서로 양 환경 모두 배포 필수):
//   bash scripts/sync-email-templates.sh
//   supabase functions deploy notify-orient-submitted --project-ref qysmxtipobomefudyixw   # 개발
//   supabase functions deploy notify-orient-submitted --project-ref nrwtujmlbktxjgdwlpjj   # 운영
//
// 메일 발송 테스트는 운영에서만 (supabase.md 정책 — 개발은 환경 구축만).
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TEMPLATES } from "./templates.ts";

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";

interface OrientSheetRecord {
  id: string;
  brand_id: string;
  application_id: string | null;
  form_type: "reviewer" | "seeding" | null;
  status: string;
  submitted_at: string | null;
  last_submitted_at: string | null;
  version: number;
  [key: string]: unknown;
}

interface WebhookPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  schema: string;
  record: OrientSheetRecord;
  old_record: OrientSheetRecord | null;
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

// 제출 시각을 한국시간 문자열로 변환 (YYYY. MM. DD. HH:mm)
function fmtKst(iso: string | null): string {
  if (!iso) return "-";
  const d = new Date(iso);
  if (isNaN(d.getTime())) return "-";
  return d.toLocaleString("ko-KR", {
    timeZone: "Asia/Seoul",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

// 폼 종류 한국어 라벨
function formTypeLabel(formType: string | null): string {
  if (formType === "reviewer") return "리뷰어";
  if (formType === "seeding") return "시딩";
  return formType ?? "-";
}

// 관리자 수신자 결정: get_subscribed_admin_emails('brand_notify') ∪ NOTIFY_ADMIN_EMAILS
// notify-brand-application 의 resolveAdminEmails 패턴 동일
async function resolveAdminEmails(): Promise<string[]> {
  const fromEnv = env("NOTIFY_ADMIN_EMAILS", "")
    .split(",")
    .map((e) => e.trim())
    .filter(Boolean);

  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) return [...new Set(fromEnv)];

  try {
    const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });
    const { data, error } = await sb.rpc("get_subscribed_admin_emails", {
      p_mail_kind: "brand_notify",
    });
    if (error) throw error;
    const fromDb = (data || [])
      .map((r: { email: string | null }) => (r.email || "").trim())
      .filter(Boolean);
    return [...new Set([...fromDb, ...fromEnv])];
  } catch (_e) {
    // DB 조회 실패 시 env만 사용 (fail-safe)
    return [...new Set(fromEnv)];
  }
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
    headers: {
      "api-key": apiKey,
      "content-type": "application/json",
      accept: "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Brevo send failed ${res.status}: ${errText}`);
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  try {
    const payload = (await req.json()) as WebhookPayload;
    console.log("[notify-orient-submitted] payload received", {
      type: payload?.type,
      table: payload?.table,
      record_id: payload?.record?.id,
      record_status: payload?.record?.status,
    });

    // UPDATE + status='submitted' 이벤트만 처리
    // (Dashboard Webhook Row filter 가 걸러주지만 이중 안전장치)
    if (
      payload.type !== "UPDATE" ||
      payload.table !== "orient_sheets" ||
      payload.record?.status !== "submitted"
    ) {
      console.log("[notify-orient-submitted] skipped: non-target event");
      return new Response(JSON.stringify({ skipped: true, reason: "non-target" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }

    const record = payload.record;
    const oldRecord = payload.old_record;

    // 신규/재제출 판정: old_record.submitted_at IS NULL → 신규
    const isFirst = !oldRecord?.submitted_at;
    const submitKind = isFirst ? "신규 제출" : "수정 재제출";
    console.log("[notify-orient-submitted] submit kind:", submitKind, { orient_sheet_id: record.id });

    // DB 조회 (브랜드명·연결 신청 번호)
    const supaUrl = env("SUPABASE_URL");
    const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
    if (!supaUrl || !serviceKey) throw new Error("Supabase service credentials not configured");
    const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

    // 브랜드명
    let brandName = "(미상)";
    if (record.brand_id) {
      const { data: brandRow, error: brandErr } = await sb
        .from("brands")
        .select("name")
        .eq("id", record.brand_id)
        .maybeSingle();
      if (brandErr) console.error("[notify-orient-submitted] brand fetch error", brandErr.message);
      if (brandRow?.name) brandName = brandRow.name as string;
    }

    // 연결 신청 번호 (있으면)
    let applicationNo = "-";
    if (record.application_id) {
      const { data: appRow, error: appErr } = await sb
        .from("brand_applications")
        .select("application_no")
        .eq("id", record.application_id)
        .maybeSingle();
      if (appErr) console.error("[notify-orient-submitted] app fetch error", appErr.message);
      if (appRow?.application_no) applicationNo = appRow.application_no as string;
    }

    // 제출 시각 (last_submitted_at 우선, 없으면 submitted_at)
    const submittedIso = (record.last_submitted_at || record.submitted_at) ?? null;
    const submittedAt = fmtKst(submittedIso);

    // 관리자 딥링크
    const adminUrl = env("PUBLIC_ADMIN_URL", "https://globalreverb.com/admin/");
    const deepLink = `${adminUrl.replace(/\/$/, "")}/#orient-sheets`;

    // 수신자 결정
    const adminEmails = await resolveAdminEmails();
    console.log("[notify-orient-submitted] adminEmails resolved", { count: adminEmails.length });

    if (adminEmails.length === 0) {
      console.warn("[notify-orient-submitted] no admin emails, skipping");
      return new Response(JSON.stringify({ sent: false, reason: "no_recipients" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }

    // 메일 본문 빌드
    const subject = `[REVERB JP] [${submitKind}] ${brandName} 오리엔시트`;

    // HTML 주석 제거 — templates.ts 인라인 원본 주석이 본문에 누출되는 버그 차단
    // (notify-deliverable-decision 동일 패턴, 메모리 mail_template_comment_leak)
    const tpl = TEMPLATES["orient-submitted-notify"].replace(/<!--[\s\S]*?-->/g, "");
    const html = render(tpl, {
      submit_kind:      escapeHtml(submitKind),
      brand_name:       escapeHtml(brandName),
      form_type_label:  escapeHtml(formTypeLabel(record.form_type)),
      submitted_at:     escapeHtml(submittedAt),
      application_no:   escapeHtml(applicationNo),
      deep_link:        escapeHtml(deepLink),
    });

    const text =
      `[${submitKind}] 오리엔시트 알림\n\n` +
      `브랜드: ${brandName}\n` +
      `폼 종류: ${formTypeLabel(record.form_type)}\n` +
      `제출 시각: ${submittedAt}\n` +
      `연결 신청: ${applicationNo}\n\n` +
      `관리자 페이지: ${deepLink}\n`;

    // 관리자 1인 1통 분리 발송 (To 헤더 노출 차단)
    const results = { sent: 0, failed: 0, errors: [] as string[] };
    for (const email of adminEmails) {
      try {
        await sendBrevoEmail({
          to: [{ email }],
          subject,
          htmlContent: html,
          textContent: text,
        });
        results.sent++;
        console.log("[notify-orient-submitted] mail sent to", email);
      } catch (err) {
        const msg = (err as Error).message;
        console.error("[notify-orient-submitted] mail failed", email, msg);
        results.errors.push(`${email}: ${msg}`);
        results.failed++;
      }
    }

    const status = results.sent > 0 ? 200 : 500;
    console.log("[notify-orient-submitted] done", {
      orient_sheet_id: record.id,
      isFirst,
      ...results,
    });

    return new Response(
      JSON.stringify({
        sent: results.sent > 0,
        recipients: results.sent,
        failed: results.failed,
        errors: results.errors.length > 0 ? results.errors : undefined,
      }),
      { status, headers: { "content-type": "application/json" } },
    );
  } catch (e) {
    const msg = (e as Error).message || "unknown";
    console.error("[notify-orient-submitted] top-level error", msg, (e as Error).stack);
    return new Response(JSON.stringify({ sent: false, error: msg }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
});
