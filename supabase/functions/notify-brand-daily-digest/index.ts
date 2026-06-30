// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-brand-daily-digest
// ──────────────────────────────────────────────────────────────────
// PR 2 — 브랜드 일일 보고 (오리엔시트 제출 현황 일별 집계 메일)
// 사양서: docs/specs/2026-06-30-orient-submit-notification.md §7-2, §10 PR 2
//
// 트리거: pg_cron 매일 UTC 00:00 (= 한국시간 오전 9시) net.http_post
//          ※ cron 등록은 수동 curl 검증 후 별도 단계 (본 마이그레이션에 포함 안 함)
// 윈도우: 전일 한국시간(KST) 0시~24시
//
// 2섹션:
//   1. 신규 제출      — orient_sheets.submitted_at ∈ window
//   2. 수정 재제출    — orient_sheets.last_submitted_at ∈ window
//                        AND orient_sheets.submitted_at < window_start
//   ※ status 필터 없음: consumed/expired 도 시각 기준으로 포착 (§3 ⑤)
//   ※ 같은 시트가 동시 조건 만족 불가 (§5 相互排他)
//
// 동시성 (notify-admin-daily-digest 패턴 복제):
//   1. status='failed' 로 brand_daily_digest_runs INSERT (digest_date UNIQUE 가 mutex)
//   2. 23505 = 이미 처리됨 → 즉시 종료
//   3. INSERT 성공 → 데이터 조회 + 메일 발송
//   4. UPDATE 로 실제 status / sections_summary / recipients_count 갱신
//
// 0건 처리:
//   - 2섹션 모두 0건 → UPDATE status='skipped_no_data' + 메일 미발송
//   - 한 섹션만 0건 → 발송, 0건 섹션은 본문에서 생략
//
// 수신자:
//   get_subscribed_admin_emails('brand_digest')     (마이그레이션 203)
//     ∪ env.NOTIFY_ADMIN_EMAILS
//   1인 1통 분리 발송 (To 헤더 노출 차단)
//
// 환경변수:
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (자동 주입)
//   BREVO_API_KEY (양 서버 별도)
//   NOTIFY_ADMIN_EMAILS (옵션 — 외부 수신자)
//   PUBLIC_ADMIN_URL    기본 https://globalreverb.com/admin/
//   BREVO_SENDER_EMAIL  기본 noreply@globalreverb.com
//   BREVO_SENDER_NAME   기본 REVERB JP
//
// 배포:
//   bash scripts/sync-email-templates.sh
//   supabase functions deploy notify-brand-daily-digest --project-ref <ref>
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TEMPLATES } from "./templates.ts";

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";

function env(key: string, fallback = ""): string {
  return Deno.env.get(key) ?? fallback;
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
// 한국시간(KST) 윈도우 계산 — 호출 시각의 「어제 KST」
// notify-admin-daily-digest 의 computeWindow() 와 동일 패턴
// ──────────────────────────────────────────────────────────────────
function computeWindow() {
  const KST_OFFSET_MS = 9 * 3600 * 1000;
  const nowKstMs = Date.now() + KST_OFFSET_MS;
  const yesterdayKstMs = nowKstMs - 24 * 3600 * 1000;
  const yKst = new Date(yesterdayKstMs);
  const yyyy = yKst.getUTCFullYear();
  const mm = String(yKst.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(yKst.getUTCDate()).padStart(2, "0");
  const digestDate = `${yyyy}-${mm}-${dd}`;
  const windowStartUtc = new Date(Date.parse(`${digestDate}T00:00:00+09:00`));
  const windowEndUtc = new Date(windowStartUtc.getTime() + 24 * 3600 * 1000);
  return { digestDate, windowStartUtc, windowEndUtc };
}

// UTC ISO → 한국시간 풀 표시 (YYYY-MM-DD HH:MM KST)
function formatKstFull(iso: string): string {
  const d = new Date(iso);
  const kstMs = d.getTime() + 9 * 3600 * 1000;
  const k = new Date(kstMs);
  const yyyy = k.getUTCFullYear();
  const mo = String(k.getUTCMonth() + 1).padStart(2, "0");
  const da = String(k.getUTCDate()).padStart(2, "0");
  const hh = String(k.getUTCHours()).padStart(2, "0");
  const mi = String(k.getUTCMinutes()).padStart(2, "0");
  return `${yyyy}-${mo}-${da} ${hh}:${mi} KST`;
}

// orient_sheets.form_type 한국어 레이블
// NULL 허용: §15 재설계로 1 링크 = N 카드 구조라 form_type 이 대표값 / NULL 가능
function formTypeKo(ft: string | null | undefined): string {
  switch (ft) {
    case "reviewer": return "리뷰어형";
    case "seeding":  return "시딩형";
    default:         return "-";
  }
}

// ──────────────────────────────────────────────────────────────────
// 템플릿 헬퍼
// ──────────────────────────────────────────────────────────────────
function loadTemplate(name: string): string {
  const html = TEMPLATES[name];
  if (!html) throw new Error(`template not registered: ${name}`);
  // HTML 주석 제거 — 주석 안 placeholder 가 치환되면서 발생하는 중첩 주석
  // → 조기 종료 → 본문 누출 버그 차단 (notify-admin-daily-digest 동일 패턴)
  return html.replace(/<!--[\s\S]*?-->/g, "");
}

function render(html: string, data: Record<string, string>): string {
  return html.replace(/\{\{(\w+)\}\}/g, (_m, key) => data[key] ?? "");
}

// ──────────────────────────────────────────────────────────────────
// 수신자 해결 — brand_digest 구독자 + env
// ──────────────────────────────────────────────────────────────────
async function resolveAdminEmails(
  sb: ReturnType<typeof createClient>,
): Promise<string[]> {
  const fromEnv = env("NOTIFY_ADMIN_EMAILS", "")
    .split(",")
    .map((e) => e.trim())
    .filter(Boolean);

  try {
    const res = await sb.rpc("get_subscribed_admin_emails", {
      p_mail_kind: "brand_digest",
    });
    const fromDb = res.error
      ? []
      : (res.data || [])
          .map((r: { email: string | null }) => (r.email || "").trim())
          .filter(Boolean);
    return [...new Set([...fromDb, ...fromEnv])];
  } catch (_e) {
    return [...new Set(fromEnv)];
  }
}

// ──────────────────────────────────────────────────────────────────
// Brevo 단건 발송
// ──────────────────────────────────────────────────────────────────
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
  const res = await fetch(BREVO_ENDPOINT, {
    method: "POST",
    headers: {
      "api-key": apiKey,
      "content-type": "application/json",
      accept: "application/json",
    },
    body: JSON.stringify({
      sender: { email: senderEmail, name: senderName },
      to: params.to,
      subject: params.subject,
      htmlContent: params.htmlContent,
      textContent: params.textContent,
    }),
  });
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Brevo send failed ${res.status}: ${errText}`);
  }
}

// ──────────────────────────────────────────────────────────────────
// 타입 정의
// ──────────────────────────────────────────────────────────────────
interface OrientSheetRow {
  id: string;
  brand_id: string;
  form_type: string | null;
  submitted_at: string;         // 최초 제출 (불변)
  last_submitted_at: string;    // 마지막 제출 (매 제출 갱신)
}

interface BrandRow {
  id: string;
  name: string | null;
}

// ──────────────────────────────────────────────────────────────────
// 섹션 wrapper 렌더
// ──────────────────────────────────────────────────────────────────
function renderSectionWrapper(args: {
  title: string;
  color: string;
  count: number;
  bodyHtml: string;
}): string {
  return render(loadTemplate("brand-daily-digest.section"), {
    section_title: escapeHtml(args.title),
    section_color: args.color,
    section_count: String(args.count),
    section_body_html: args.bodyHtml,
  });
}

// ──────────────────────────────────────────────────────────────────
// 섹션 1: 신규 제출 렌더
// ──────────────────────────────────────────────────────────────────
function renderNewSection(args: {
  rows: OrientSheetRow[];
  brandMap: Map<string, BrandRow>;
}): string {
  if (args.rows.length === 0) return "";

  const tableRows = args.rows.map((r) => {
    const brand = args.brandMap.get(r.brand_id);
    const brandName = escapeHtml(brand?.name || "-");
    const formType = escapeHtml(formTypeKo(r.form_type));
    const submittedAt = escapeHtml(formatKstFull(r.submitted_at));
    return `<tr>
      <td style="padding:6px 8px;vertical-align:top;border-bottom:1px solid #F0F2F8;font-weight:600">${brandName}</td>
      <td style="padding:6px 8px;vertical-align:top;color:#555;border-bottom:1px solid #F0F2F8">${formType}</td>
      <td style="padding:6px 8px;vertical-align:top;color:#666;border-bottom:1px solid #F0F2F8;white-space:nowrap">${submittedAt}</td>
    </tr>`;
  }).join("");

  const bodyHtml = `<table style="width:100%;border-collapse:collapse;font-size:12px">
    <thead>
      <tr style="background:#F5F7FC">
        <th style="padding:6px 8px;text-align:left;color:#555;font-weight:600">브랜드</th>
        <th style="padding:6px 8px;text-align:left;color:#555;font-weight:600">형식</th>
        <th style="padding:6px 8px;text-align:left;color:#555;font-weight:600">제출 시각</th>
      </tr>
    </thead>
    <tbody>${tableRows}</tbody>
  </table>`;

  return renderSectionWrapper({
    title: "신규 제출",
    color: "#5B6BBF",
    count: args.rows.length,
    bodyHtml,
  });
}

// ──────────────────────────────────────────────────────────────────
// 섹션 2: 수정 재제출 렌더
// ──────────────────────────────────────────────────────────────────
function renderResubmitSection(args: {
  rows: OrientSheetRow[];
  brandMap: Map<string, BrandRow>;
}): string {
  if (args.rows.length === 0) return "";

  const tableRows = args.rows.map((r) => {
    const brand = args.brandMap.get(r.brand_id);
    const brandName = escapeHtml(brand?.name || "-");
    const formType = escapeHtml(formTypeKo(r.form_type));
    const resubmittedAt = escapeHtml(formatKstFull(r.last_submitted_at));
    const firstAt = escapeHtml(formatKstFull(r.submitted_at));
    return `<tr>
      <td style="padding:6px 8px;vertical-align:top;border-bottom:1px solid #F0F2F8;font-weight:600">${brandName}</td>
      <td style="padding:6px 8px;vertical-align:top;color:#555;border-bottom:1px solid #F0F2F8">${formType}</td>
      <td style="padding:6px 8px;vertical-align:top;color:#666;border-bottom:1px solid #F0F2F8;white-space:nowrap">${resubmittedAt}</td>
      <td style="padding:6px 8px;vertical-align:top;color:#999;font-size:11px;border-bottom:1px solid #F0F2F8;white-space:nowrap">최초: ${firstAt}</td>
    </tr>`;
  }).join("");

  const bodyHtml = `<table style="width:100%;border-collapse:collapse;font-size:12px">
    <thead>
      <tr style="background:#F5F7FC">
        <th style="padding:6px 8px;text-align:left;color:#555;font-weight:600">브랜드</th>
        <th style="padding:6px 8px;text-align:left;color:#555;font-weight:600">형식</th>
        <th style="padding:6px 8px;text-align:left;color:#555;font-weight:600">재제출 시각</th>
        <th style="padding:6px 8px;text-align:left;color:#555;font-weight:600">최초 제출</th>
      </tr>
    </thead>
    <tbody>${tableRows}</tbody>
  </table>`;

  return renderSectionWrapper({
    title: "수정 재제출",
    color: "#C8789C",
    count: args.rows.length,
    bodyHtml,
  });
}

// ══════════════════════════════════════════════════════════════════
// Main handler
// ══════════════════════════════════════════════════════════════════
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) {
    console.error("[notify-brand-daily] SUPABASE env missing");
    return new Response(JSON.stringify({ error: "SUPABASE env missing" }), {
      status: 500, headers: { "content-type": "application/json" },
    });
  }
  const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

  const { digestDate, windowStartUtc, windowEndUtc } = computeWindow();
  console.log("[notify-brand-daily] window", {
    digestDate,
    start: windowStartUtc.toISOString(),
    end: windowEndUtc.toISOString(),
  });

  // ── 1. INSERT 선행 mutex (status='failed' 마커) ──
  //    brand_daily_digest_runs.digest_date UNIQUE 가 mutex 역할
  //    → 동시 호출 차단 (notify-admin-daily-digest 패턴 동일)
  {
    const { error } = await sb
      .from("brand_daily_digest_runs")
      .insert({
        digest_date: digestDate,
        status: "failed",
        sections_summary: {},
        recipients_count: 0,
        error_message: "in-flight",
      });
    if (error) {
      if ((error as { code?: string }).code === "23505") {
        // 이미 처리됨 (중복 호출 차단)
        console.log("[notify-brand-daily] already processed", digestDate);
        return new Response(
          JSON.stringify({ ok: true, skipped: true, reason: "already_processed", digestDate }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      }
      console.error("[notify-brand-daily] mutex INSERT failed", error);
      return new Response(JSON.stringify({ error: "mutex insert failed", detail: error.message }), {
        status: 500, headers: { "content-type": "application/json" },
      });
    }
  }

  // 헬퍼: 종료 시 brand_daily_digest_runs UPDATE
  const finalizeRun = async (payload: {
    status: "sent" | "skipped_no_data" | "failed";
    sections_summary: Record<string, number>;
    recipients_count: number;
    error_message?: string | null;
  }) => {
    const { error } = await sb
      .from("brand_daily_digest_runs")
      .update({
        status: payload.status,
        sections_summary: payload.sections_summary,
        recipients_count: payload.recipients_count,
        error_message: payload.error_message ?? null,
      })
      .eq("digest_date", digestDate);
    if (error) console.error("[notify-brand-daily] finalize UPDATE failed", error);
  };

  try {
    const startIso = windowStartUtc.toISOString();
    const endIso = windowEndUtc.toISOString();

    // ── 2. 2섹션 쿼리 병렬 ──
    //
    // §5 판정 로직 (상호배타 보장):
    //   신규: submitted_at ∈ [start, end)
    //         → 최초 제출이 어제 윈도우 안 → last_submitted_at 도 어제이므로 재제출 조건 만족 불가
    //   재제출: last_submitted_at ∈ [start, end) AND submitted_at < start
    //           → 최초 제출은 어제 이전, 마지막 제출만 어제 → 신규 조건 만족 불가
    //   ∴ 한 시트가 두 조건 동시 만족 불가 → 중복 제거 불필요
    //
    // status 필터 없음: consumed/expired 도 시각 기준으로 포착 (사양서 §3 ⑤)
    const [newRes, resubmitRes] = await Promise.all([
      // 섹션 1: 신규 제출
      sb.from("orient_sheets")
        .select("id, brand_id, form_type, submitted_at, last_submitted_at")
        .gte("submitted_at", startIso)
        .lt("submitted_at", endIso)
        .order("submitted_at", { ascending: true }),
      // 섹션 2: 수정 재제출 (마지막 제출이 어제 AND 최초 제출은 그 이전)
      sb.from("orient_sheets")
        .select("id, brand_id, form_type, submitted_at, last_submitted_at")
        .gte("last_submitted_at", startIso)
        .lt("last_submitted_at", endIso)
        .lt("submitted_at", startIso)
        .order("last_submitted_at", { ascending: true }),
    ]);

    // 에러 점검
    for (const [label, res] of [
      ["new_submitted", newRes],
      ["resubmitted", resubmitRes],
    ] as const) {
      if (res.error) {
        const msg = `query ${label}: ${res.error.message}`;
        console.error("[notify-brand-daily]", msg);
        await finalizeRun({
          status: "failed",
          sections_summary: {},
          recipients_count: 0,
          error_message: msg,
        });
        return new Response(JSON.stringify({ error: msg, stage: "query" }), {
          status: 500, headers: { "content-type": "application/json" },
        });
      }
    }

    const newRows = (newRes.data || []) as OrientSheetRow[];
    const resubmitRows = (resubmitRes.data || []) as OrientSheetRow[];

    const sectionsSummary = {
      new_submitted: newRows.length,
      resubmitted: resubmitRows.length,
    };
    const totalCount = sectionsSummary.new_submitted + sectionsSummary.resubmitted;

    console.log("[notify-brand-daily] sections", sectionsSummary);

    // ── 3. 2섹션 모두 0건 → 스킵 ──
    if (totalCount === 0) {
      await finalizeRun({
        status: "skipped_no_data",
        sections_summary: sectionsSummary,
        recipients_count: 0,
      });
      return new Response(
        JSON.stringify({ ok: true, skipped: true, reason: "no_data", digestDate, sectionsSummary }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    }

    // ── 4. 브랜드명 배치 조회 ──
    const brandIds = [
      ...new Set([
        ...newRows.map((r) => r.brand_id),
        ...resubmitRows.map((r) => r.brand_id),
      ]),
    ];
    const brandMap = new Map<string, BrandRow>();
    if (brandIds.length > 0) {
      const { data: brands, error } = await sb
        .from("brands")
        .select("id, name")
        .in("id", brandIds);
      if (error) {
        console.warn("[notify-brand-daily] brand lookup failed", error);
      } else {
        (brands || []).forEach((b: BrandRow) => brandMap.set(b.id, b));
      }
    }

    // ── 5. 섹션별 HTML 렌더 ──
    const sectionNewHtml = renderNewSection({ rows: newRows, brandMap });
    const sectionResubmitHtml = renderResubmitSection({ rows: resubmitRows, brandMap });

    // 헤더 요약 칩 (0건 섹션 생략)
    const chipDef: { key: keyof typeof sectionsSummary; label: string; bg: string; fg: string }[] = [
      { key: "new_submitted", label: "신규 제출",  bg: "#E8ECFF", fg: "#3A4DB0" },
      { key: "resubmitted",   label: "수정 재제출", bg: "#FFF0F6", fg: "#A04070" },
    ];
    const summaryChipHtml = chipDef
      .filter((c) => sectionsSummary[c.key] > 0)
      .map((c) =>
        `<span style="background:${c.bg};color:${c.fg};padding:3px 10px;border-radius:6px;font-weight:700;font-size:12px;margin-right:6px">${c.label} ${sectionsSummary[c.key]}건</span>`
      )
      .join("");

    // ── 6. 메인 HTML 조립 ──
    const adminUrlBase = env("PUBLIC_ADMIN_URL", "https://globalreverb.com/admin/").replace(/\/$/, "");
    // 오리엔시트 발급·조회 페인은 모달 기반이라 per-row 딥링크 없음 → 페인 단일 CTA
    const orientPaneUrl = `${adminUrlBase}/#orient-sheets`;

    const mainTpl = loadTemplate("brand-daily-digest");
    const html = render(mainTpl, {
      digest_date: escapeHtml(digestDate),
      total_count: String(totalCount),
      summary_chip_html: summaryChipHtml,
      section_new_html: sectionNewHtml,
      section_resubmit_html: sectionResubmitHtml,
      orient_pane_url: escapeHtml(orientPaneUrl),
    });

    const subject = `[REVERB] 브랜드 일일 보고 — ${digestDate} (총 ${totalCount}건)`;

    // 평문 폴백
    const textLines = [
      `브랜드 일일 보고 (${digestDate})`,
      `총 ${totalCount}건 — 신규 제출 ${sectionsSummary.new_submitted} · 수정 재제출 ${sectionsSummary.resubmitted}`,
      "",
      `오리엔시트 발급·조회 페인: ${orientPaneUrl}`,
    ];
    const text = textLines.join("\n");

    // ── 7. 수신자 ──
    const adminEmails = await resolveAdminEmails(sb);
    console.log("[notify-brand-daily] recipients", { count: adminEmails.length });

    if (adminEmails.length === 0) {
      await finalizeRun({
        status: "failed",
        sections_summary: sectionsSummary,
        recipients_count: 0,
        error_message: "no recipients (admin_email_subscriptions + env both empty)",
      });
      return new Response(
        JSON.stringify({ ok: false, reason: "no_recipients", digestDate, sectionsSummary }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    }

    // ── 8. 발송 — 1인 1통 분리 (To 헤더 노출 차단) ──
    let successCount = 0;
    const failures: { email: string; error: string }[] = [];
    for (const email of adminEmails) {
      try {
        await sendBrevoEmail({
          to: [{ email }],
          subject,
          htmlContent: html,
          textContent: text,
        });
        successCount++;
      } catch (e) {
        const msg = (e as Error).message || "brevo send error";
        console.error("[notify-brand-daily] send failed", email, msg);
        failures.push({ email, error: msg });
      }
    }

    if (successCount === 0) {
      const firstErr = failures[0]?.error || "unknown";
      await finalizeRun({
        status: "failed",
        sections_summary: sectionsSummary,
        recipients_count: 0,
        error_message: `all ${adminEmails.length} sends failed: ${firstErr}`,
      });
      return new Response(JSON.stringify({
        error: "all sends failed", stage: "send",
        attempted: adminEmails.length, failed: failures.length,
      }), { status: 500, headers: { "content-type": "application/json" } });
    }

    // ── 9. 성공 UPDATE ──
    const errMsg = failures.length > 0
      ? `${successCount}/${adminEmails.length} sent. failed: ${failures.map((f) => `${f.email}(${f.error})`).join("; ")}`
      : null;
    await finalizeRun({
      status: "sent",
      sections_summary: sectionsSummary,
      recipients_count: successCount,
      error_message: errMsg,
    });

    console.log("[notify-brand-daily] done", {
      digestDate,
      totalCount,
      attempted: adminEmails.length,
      succeeded: successCount,
      failed: failures.length,
    });

    return new Response(
      JSON.stringify({
        ok: true,
        digestDate,
        totalCount,
        sectionsSummary,
        attempted: adminEmails.length,
        succeeded: successCount,
        failed: failures.length,
      }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  } catch (e) {
    const msg = (e as Error).message || "unknown error";
    console.error("[notify-brand-daily] unexpected error", msg);
    try {
      await finalizeRun({
        status: "failed",
        sections_summary: {},
        recipients_count: 0,
        error_message: `unexpected: ${msg}`,
      });
    } catch (_finalizeErr) {
      console.error("[notify-brand-daily] could not finalize after unexpected error");
    }
    return new Response(JSON.stringify({ error: msg, stage: "unexpected" }), {
      status: 500, headers: { "content-type": "application/json" },
    });
  }
});
