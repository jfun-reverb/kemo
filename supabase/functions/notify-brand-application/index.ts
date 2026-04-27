// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-brand-application
// ──────────────────────────────────────────────────────────────────
// 트리거: Supabase Database Webhook (brand_applications INSERT)
// 역할:   신규 광고주 신청 접수 시 2통 이메일 자동 발송
//          1) 관리자 알림 (브랜드 정보, 견적, 관리자 페이지 딥링크)
//          2) 브랜드 접수 확인 (신청번호, 다음 단계 안내, LINE 문의처)
//
// 환경변수 (Edge Functions Secrets):
//   BREVO_API_KEY         Brevo Transactional API 키
//   NOTIFY_ADMIN_EMAILS   관리자 수신자 추가(콤마 구분, DB 수신자와 합산). 없어도 됨.
//   PUBLIC_ADMIN_URL      관리자 페이지 절대 URL (딥링크용)
//   BREVO_SENDER_EMAIL    발신자 이메일 (기본 noreply@globalreverb.com)
//   BREVO_SENDER_NAME     발신자 이름 (기본 환경별 REVERB JP 또는 REVERB JP [DEV])
//
// 관리자 수신자 결정 로직 (2026-04-20~):
//   1) admins.receive_brand_notify = true 이메일 (DB, 관리자 페이지에서 토글)
//   2) + NOTIFY_ADMIN_EMAILS 환경변수에 나열된 이메일 (외부 수신자 병합)
//   3) 중복 제거 후 발송. DB 조회 실패 시 env만 사용.
//
// HTML 템플릿:
//   _templates/brand-admin-notify.html        관리자 알림
//   _templates/brand-ack-reviewer.html        브랜드 접수 확인 (reviewer)
//   _templates/brand-ack-seeding.html         브랜드 접수 확인 (seeding)
//
//   원본은 docs/email-templates/ 에 있고, scripts/sync-email-templates.sh 가
//   _templates/ 로 복사한다. Edge Function 배포 직전 반드시 sync 실행.
//
// 배포 명령 (개발 → 운영 순서로 양 환경 모두 배포 필수):
//   bash scripts/sync-email-templates.sh
//   # 개발
//   supabase functions deploy notify-brand-application --project-ref qysmxtipobomefudyixw
//   # 운영
//   supabase functions deploy notify-brand-application --project-ref twofagomeizrtkwlhsuv
//   # 비밀값 (각 환경별로 1회)
//   supabase secrets set BREVO_API_KEY=xxx --project-ref <ref>
//
// Webhook 설정 (Supabase Dashboard → Database → Webhooks):
//   Table: brand_applications
//   Events: INSERT
//   Type: Supabase Edge Functions
//   Edge Function: notify-brand-application
//   HTTP Method: POST
//   HTTP Headers: (기본)
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface BrandApplication {
  id: string;
  application_no: string;
  form_type: "reviewer" | "seeding";
  brand_name: string;
  contact_name: string;
  phone: string;
  email: string;
  billing_email?: string | null;
  products: Array<{ name?: string; url?: string; price?: number; qty?: number }>;
  total_jpy?: number | null;
  total_qty?: number | null;
  estimated_krw?: number | null;
  request_note?: string | null;
  created_at: string;
}

interface WebhookPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  schema: string;
  record: BrandApplication;
  old_record?: BrandApplication | null;
}

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";

function env(key: string, fallback = ""): string {
  return Deno.env.get(key) ?? fallback;
}

// 관리자 수신자 결정: admins.receive_brand_notify=true ∪ NOTIFY_ADMIN_EMAILS
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
    const { data, error } = await sb
      .from("admins")
      .select("email")
      .eq("receive_brand_notify", true);
    if (error) throw error;
    const fromDb = (data || []).map((r: { email: string | null }) => (r.email || "").trim()).filter(Boolean);
    return [...new Set([...fromDb, ...fromEnv])];
  } catch (_e) {
    // DB 조회 실패 시 env만 사용 (fail-safe)
    return [...new Set(fromEnv)];
  }
}

function formLabel(formType: string): string {
  return formType === "reviewer" ? "Qoo10 리뷰어 모집" : formType === "seeding" ? "나노 인플루언서 시딩" : formType;
}

function fmtKrw(n?: number | null): string {
  if (n === null || n === undefined || !isFinite(Number(n))) return "-";
  return "₩ " + Number(n).toLocaleString("ko-KR");
}

function fmtJpy(n?: number | null): string {
  if (n === null || n === undefined || !isFinite(Number(n))) return "-";
  return "¥ " + Number(n).toLocaleString("ja-JP");
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// ──────────────────────────────────────────────────────────────────
// HTML 템플릿 로딩 + placeholder 치환
//   - 템플릿은 _templates/*.html (docs/email-templates/와 sync 스크립트로 동기화)
//   - placeholder 문법: {{key}} (이중 중괄호, 공백 없음)
//   - 조건부/반복 섹션은 호출 측에서 미리 빌드된 HTML 문자열로 치환
//   - 인스턴스 메모리 캐시로 매 요청 시 디스크 읽기 회피
// ──────────────────────────────────────────────────────────────────
const TEMPLATE_CACHE = new Map<string, string>();

async function loadTemplate(name: string): Promise<string> {
  const cached = TEMPLATE_CACHE.get(name);
  if (cached) return cached;
  const url = new URL(`./_templates/${name}.html`, import.meta.url);
  const html = await Deno.readTextFile(url);
  TEMPLATE_CACHE.set(name, html);
  return html;
}

function render(html: string, data: Record<string, string>): string {
  return html.replace(/\{\{(\w+)\}\}/g, (_m, key) => data[key] ?? "");
}

async function sendBrevoEmail(params: {
  to: { email: string; name?: string }[];
  subject: string;
  htmlContent: string;
  textContent: string;
}): Promise<void> {
  const apiKey = env("BREVO_API_KEY");
  if (!apiKey) throw new Error("BREVO_API_KEY not configured");

  const senderEmail = env("BREVO_SENDER_EMAIL", "noreply@globalreverb.com");
  const senderName = env("BREVO_SENDER_NAME", "REVERB JP");

  const body = {
    sender: { email: senderEmail, name: senderName },
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

async function buildAdminEmail(row: BrandApplication, adminUrl: string): Promise<{ subject: string; html: string; text: string }> {
  const label = formLabel(row.form_type);
  const deepLink = `${adminUrl.replace(/\/$/, "")}/#brand-applications?id=${row.id}`;
  const subject = `[REVERB JP] 신규 광고주 신청 — ${row.brand_name} (${label})`;

  const productLines = (row.products || [])
    .map((p, i) => `${i + 1}. ${p.name ?? "-"} · ¥${(p.price ?? 0).toLocaleString("ja-JP")} × ${p.qty ?? 0}`)
    .join("\n");

  const productsHtml = (row.products || [])
    .map(
      (p) =>
        `<tr><td style="padding:4px 8px;border-bottom:1px solid #eee">${escapeHtml(p.name ?? "-")}</td>` +
        `<td style="padding:4px 8px;border-bottom:1px solid #eee;text-align:right">¥${(p.price ?? 0).toLocaleString("ja-JP")}</td>` +
        `<td style="padding:4px 8px;border-bottom:1px solid #eee;text-align:right">${p.qty ?? 0}</td></tr>`
    )
    .join("");

  const productsBlock = productsHtml
    ? `<table style="border-collapse:collapse;width:100%;font-size:12px;margin-bottom:16px;border:1px solid #eee">` +
      `<thead><tr style="background:#f5f5f5"><th style="padding:6px 8px;text-align:left">제품</th><th style="padding:6px 8px;text-align:right">가격</th><th style="padding:6px 8px;text-align:right">수량</th></tr></thead>` +
      `<tbody>${productsHtml}</tbody></table>`
    : "";

  // 신청자 자유 입력 요청사항 (선택 입력 — 있을 때만 섹션 렌더)
  const requestNote = (row.request_note ?? "").trim();
  const requestNoteText = requestNote
    ? `\n기타·요청사항\n${requestNote}\n`
    : "";
  const requestNoteHtml = requestNote
    ? `<div style="margin:0 0 16px;padding:12px 14px;background:#FFF9F0;border:1px solid #E8D0A0;border-radius:8px">` +
      `<div style="font-size:12px;color:#8A6A2A;font-weight:700;margin-bottom:6px">기타·요청사항</div>` +
      `<div style="font-size:13px;color:#222;line-height:1.6;white-space:pre-wrap;word-break:break-word">${escapeHtml(requestNote)}</div>` +
      `</div>`
    : "";

  const billingEmailRow = row.billing_email
    ? `<tr><td style="padding:6px 0;color:#888">계산서</td><td style="padding:6px 0">${escapeHtml(row.billing_email)}</td></tr>`
    : "";

  const text =
    `신규 광고주 신청이 접수되었습니다.\n\n` +
    `신청번호: ${row.application_no}\n` +
    `폼 종류: ${label}\n` +
    `브랜드: ${row.brand_name}\n` +
    `담당자: ${row.contact_name} / ${row.phone} / ${row.email}\n` +
    (row.billing_email ? `계산서: ${row.billing_email}\n` : "") +
    `\n제품 (${row.products?.length ?? 0}개, 총 ${row.total_qty ?? 0}명, ${fmtJpy(row.total_jpy)})\n` +
    productLines +
    `\n\n예상 견적: ${fmtKrw(row.estimated_krw)}\n` +
    requestNoteText +
    `관리자 페이지: ${deepLink}\n`;

  const tpl = await loadTemplate("brand-admin-notify");
  const html = render(tpl, {
    application_no: escapeHtml(row.application_no),
    form_label: escapeHtml(label),
    brand_name: escapeHtml(row.brand_name),
    contact_name: escapeHtml(row.contact_name),
    phone: escapeHtml(row.phone),
    email: escapeHtml(row.email),
    billing_email_row: billingEmailRow,
    estimated_krw: fmtKrw(row.estimated_krw),
    products_html: productsBlock,
    request_note_html: requestNoteHtml,
    deep_link: escapeHtml(deepLink),
  });

  return { subject, html, text };
}

async function buildBrandEmail(row: BrandApplication): Promise<{ subject: string; html: string; text: string }> {
  const isReviewer = row.form_type === "reviewer";
  const labelKo = isReviewer ? "Qoo10 리뷰어 모집" : "나노 인플루언서 시딩";
  const subject = `[REVERB JP] ${labelKo} 신청이 접수되었습니다 (${row.application_no})`;

  // text 본문은 sales 완료 페이지와 동기화. 템플릿 HTML의 "다음 단계"는 하드코딩.
  const nextSteps = isReviewer
    ? [
        "담당자가 신청 내역을 검토합니다 (영업일 1일 이내)",
        "최종 견적서를 이메일로 발송합니다",
        "입금 확인 후 메일 및 카톡으로 안내",
        "전체 타임라인 공유",
        "Qoo10 리뷰어 모집 시작",
      ]
    : [
        "담당자가 신청 내역을 검토합니다 (영업일 1~2일)",
        "전체 타임라인 공유",
        "모집 시작",
        "매칭 가능한 인플루언서 리스트 전달",
        "브랜드사에서 제품 발송 (일본 현지 주소)",
        "인플루언서 SNS 포스팅 진행",
      ];

  const stepsText = nextSteps.map((s, i) => `${String(i + 1).padStart(2, "0")}. ${s}`).join("\n");

  const text =
    `REVERB JP에 신청해주셔서 감사합니다.\n\n` +
    `신청번호: ${row.application_no}\n` +
    `브랜드: ${row.brand_name}\n` +
    `플랜: ${labelKo}\n\n` +
    `[다음 단계]\n` +
    stepsText +
    `\n\n` +
    `[문의]\n` +
    `· LINE @reverb.jp — https://line.me/R/ti/p/@reverb.jp\n` +
    `· 카카오톡 byhyunho7\n` +
    `· 연락처 010-2550-1511\n`;

  const tplName = isReviewer ? "brand-ack-reviewer" : "brand-ack-seeding";
  const tpl = await loadTemplate(tplName);
  const html = render(tpl, {
    application_no: escapeHtml(row.application_no),
    brand_name: escapeHtml(row.brand_name),
  });

  return { subject, html, text };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  try {
    const payload = (await req.json()) as WebhookPayload;
    console.log("[notify-brand-application] payload received", {
      type: payload?.type,
      table: payload?.table,
      record_id: payload?.record?.id,
      application_no: payload?.record?.application_no,
    });

    // INSERT 이벤트만 처리 (UPDATE/DELETE는 무시)
    if (payload.type !== "INSERT" || payload.table !== "brand_applications") {
      console.log("[notify-brand-application] skipped non-insert");
      return new Response(JSON.stringify({ skipped: true, reason: "non-insert" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }

    const row = payload.record;
    if (!row?.id || !row.application_no) {
      console.error("[notify-brand-application] invalid payload", { row });
      return new Response(JSON.stringify({ error: "invalid payload" }), {
        status: 400,
        headers: { "content-type": "application/json" },
      });
    }

    // 관리자 수신자: DB admins.receive_brand_notify=true + NOTIFY_ADMIN_EMAILS 병합
    const adminEmails = await resolveAdminEmails();
    const adminUrl = env("PUBLIC_ADMIN_URL", "https://globalreverb.com/admin/");
    console.log("[notify-brand-application] adminEmails resolved", {
      count: adminEmails.length,
      emails: adminEmails,
      adminUrl,
    });

    const results = { admin: false, brand: false, errors: [] as string[] };

    // 1) 관리자 알림
    try {
      if (adminEmails.length > 0) {
        const { subject, html, text } = await buildAdminEmail(row, adminUrl);
        console.log("[notify-brand-application] sending admin email", { to: adminEmails, subject });
        await sendBrevoEmail({
          to: adminEmails.map((e) => ({ email: e })),
          subject,
          htmlContent: html,
          textContent: text,
        });
        results.admin = true;
        console.log("[notify-brand-application] admin email sent");
      } else {
        console.warn("[notify-brand-application] no admin emails, skipping admin notification");
      }
    } catch (e) {
      const msg = (e as Error).message;
      console.error("[notify-brand-application] admin email failed", msg);
      results.errors.push(`admin: ${msg}`);
    }

    // 2) 브랜드 접수 확인
    try {
      if (row.email) {
        const { subject, html, text } = await buildBrandEmail(row);
        console.log("[notify-brand-application] sending brand email", { to: row.email, subject });
        await sendBrevoEmail({
          to: [{ email: row.email, name: row.brand_name }],
          subject,
          htmlContent: html,
          textContent: text,
        });
        results.brand = true;
        console.log("[notify-brand-application] brand email sent");
      } else {
        console.warn("[notify-brand-application] no brand email on row, skipping brand notification");
      }
    } catch (e) {
      const msg = (e as Error).message;
      console.error("[notify-brand-application] brand email failed", msg);
      results.errors.push(`brand: ${msg}`);
    }

    const status = results.errors.length > 0 && !results.admin && !results.brand ? 500 : 200;
    console.log("[notify-brand-application] done", { status, ...results });
    return new Response(JSON.stringify(results), {
      status,
      headers: { "content-type": "application/json" },
    });
  } catch (e) {
    const msg = (e as Error).message || "unknown";
    console.error("[notify-brand-application] top-level error", msg, (e as Error).stack);
    return new Response(
      JSON.stringify({ error: msg }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }
});
