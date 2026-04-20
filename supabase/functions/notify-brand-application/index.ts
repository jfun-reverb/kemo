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
// 배포 명령:
//   supabase functions deploy notify-brand-application --project-ref <ref>
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
  business_license_path?: string | null;
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

function buildAdminEmail(row: BrandApplication, adminUrl: string): { subject: string; html: string; text: string } {
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
    `관리자 페이지: ${deepLink}\n`;

  const html =
    `<div style="font-family:'Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">` +
    `<h2 style="color:#E8344E;margin:0 0 8px">신규 광고주 신청</h2>` +
    `<p style="margin:0 0 16px;color:#666;font-size:13px">REVERB JP 관리자 알림</p>` +
    `<table style="border-collapse:collapse;width:100%;font-size:13px;margin-bottom:16px">` +
    `<tr><td style="padding:6px 0;color:#888;width:100px">신청번호</td><td style="padding:6px 0;font-family:monospace">${escapeHtml(row.application_no)}</td></tr>` +
    `<tr><td style="padding:6px 0;color:#888">폼 종류</td><td style="padding:6px 0">${escapeHtml(label)}</td></tr>` +
    `<tr><td style="padding:6px 0;color:#888">브랜드</td><td style="padding:6px 0;font-weight:700">${escapeHtml(row.brand_name)}</td></tr>` +
    `<tr><td style="padding:6px 0;color:#888">담당자</td><td style="padding:6px 0">${escapeHtml(row.contact_name)} · ${escapeHtml(row.phone)} · ${escapeHtml(row.email)}</td></tr>` +
    (row.billing_email ? `<tr><td style="padding:6px 0;color:#888">계산서</td><td style="padding:6px 0">${escapeHtml(row.billing_email)}</td></tr>` : "") +
    `<tr><td style="padding:6px 0;color:#888">예상 견적</td><td style="padding:6px 0;font-weight:700">${fmtKrw(row.estimated_krw)}</td></tr>` +
    `</table>` +
    (productsHtml
      ? `<table style="border-collapse:collapse;width:100%;font-size:12px;margin-bottom:16px;border:1px solid #eee">` +
        `<thead><tr style="background:#f5f5f5"><th style="padding:6px 8px;text-align:left">제품</th><th style="padding:6px 8px;text-align:right">가격</th><th style="padding:6px 8px;text-align:right">수량</th></tr></thead>` +
        `<tbody>${productsHtml}</tbody></table>`
      : "") +
    `<a href="${escapeHtml(deepLink)}" style="display:inline-block;background:#E8344E;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none;font-weight:700;font-size:13px">관리자 페이지에서 확인</a>` +
    `</div>`;

  return { subject, html, text };
}

function buildBrandEmail(row: BrandApplication): { subject: string; html: string; text: string } {
  const labelKo = row.form_type === "reviewer" ? "Qoo10 리뷰어 모집" : "나노 인플루언서 시딩";
  const subject = `[REVERB JP] ${labelKo} 신청이 접수되었습니다 (${row.application_no})`;

  // 완료 페이지(sales/*.html)와 동일한 최신 단계
  const nextSteps =
    row.form_type === "reviewer"
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

  const stepsHtml = nextSteps
    .map(
      (s, i) =>
        `<li style="margin:8px 0;color:#444;padding-left:4px">` +
        `<span style="color:#E8344E;font-weight:700;font-family:monospace;margin-right:6px">${String(i + 1).padStart(2, "0")}</span>` +
        `${escapeHtml(s)}</li>`
    )
    .join("");

  const html =
    `<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">` +
    `<h2 style="color:#E8344E;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">신청이 접수되었습니다</h2>` +
    `<p style="margin:0 0 18px;color:#666;font-size:13px">${escapeHtml(row.brand_name)} 담당자님</p>` +
    `<div style="background:#F7F4EE;border:1px solid #EAEAE4;border-radius:12px;padding:16px 18px;margin-bottom:20px;font-size:13px">` +
      `<div style="color:#888;font-size:11px;letter-spacing:0.08em;margin-bottom:4px;text-transform:uppercase;font-weight:700">신청번호</div>` +
      `<div style="font-family:monospace;font-size:16px;font-weight:700;color:#E8344E">${escapeHtml(row.application_no)}</div>` +
      `<div style="color:#888;font-size:11px;letter-spacing:0.08em;margin:12px 0 4px;text-transform:uppercase;font-weight:700">플랜</div>` +
      `<div style="font-weight:600">${escapeHtml(labelKo)}</div>` +
    `</div>` +
    `<h3 style="font-size:11px;color:#161618;letter-spacing:0.15em;margin:22px 0 12px;text-transform:uppercase;font-weight:700">다음 단계</h3>` +
    `<ol style="padding:0;margin:0;font-size:13px;list-style:none">${stepsHtml}</ol>` +
    `<div style="border-top:1px solid #EAEAE4;margin-top:26px;padding-top:18px">` +
      `<h3 style="font-size:11px;color:#161618;letter-spacing:0.15em;margin-bottom:12px;text-transform:uppercase;font-weight:700">문의</h3>` +
      `<table style="border-collapse:collapse;width:100%;font-size:13px">` +
        `<tr><td style="padding:6px 0;color:#888;font-size:10px;letter-spacing:0.12em;text-transform:uppercase;font-weight:700;width:100px">LINE</td><td style="padding:6px 0"><a href="https://line.me/R/ti/p/@reverb.jp" style="color:#E8344E;text-decoration:none;font-weight:600">@reverb.jp</a></td></tr>` +
        `<tr><td style="padding:6px 0;color:#888;font-size:10px;letter-spacing:0.12em;text-transform:uppercase;font-weight:700">KakaoTalk</td><td style="padding:6px 0;font-weight:600">byhyunho7</td></tr>` +
        `<tr><td style="padding:6px 0;color:#888;font-size:10px;letter-spacing:0.12em;text-transform:uppercase;font-weight:700">TEL</td><td style="padding:6px 0;font-family:monospace;font-weight:600">010-2550-1511</td></tr>` +
      `</table>` +
    `</div>` +
    `<p style="margin-top:24px;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>` +
    `</div>`;

  return { subject, html, text };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  try {
    const payload = (await req.json()) as WebhookPayload;

    // INSERT 이벤트만 처리 (UPDATE/DELETE는 무시)
    if (payload.type !== "INSERT" || payload.table !== "brand_applications") {
      return new Response(JSON.stringify({ skipped: true, reason: "non-insert" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }

    const row = payload.record;
    if (!row?.id || !row.application_no) {
      return new Response(JSON.stringify({ error: "invalid payload" }), {
        status: 400,
        headers: { "content-type": "application/json" },
      });
    }

    // 관리자 수신자: DB admins.receive_brand_notify=true + NOTIFY_ADMIN_EMAILS 병합
    const adminEmails = await resolveAdminEmails();
    const adminUrl = env("PUBLIC_ADMIN_URL", "https://globalreverb.com/admin/");

    const results = { admin: false, brand: false, errors: [] as string[] };

    // 1) 관리자 알림
    try {
      if (adminEmails.length > 0) {
        const { subject, html, text } = buildAdminEmail(row, adminUrl);
        await sendBrevoEmail({
          to: adminEmails.map((e) => ({ email: e })),
          subject,
          htmlContent: html,
          textContent: text,
        });
        results.admin = true;
      }
    } catch (e) {
      results.errors.push(`admin: ${(e as Error).message}`);
    }

    // 2) 브랜드 접수 확인
    try {
      if (row.email) {
        const { subject, html, text } = buildBrandEmail(row);
        await sendBrevoEmail({
          to: [{ email: row.email, name: row.brand_name }],
          subject,
          htmlContent: html,
          textContent: text,
        });
        results.brand = true;
      }
    } catch (e) {
      results.errors.push(`brand: ${(e as Error).message}`);
    }

    return new Response(JSON.stringify(results), {
      status: results.errors.length > 0 && !results.admin && !results.brand ? 500 : 200,
      headers: { "content-type": "application/json" },
    });
  } catch (e) {
    return new Response(
      JSON.stringify({ error: (e as Error).message || "unknown" }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }
});
