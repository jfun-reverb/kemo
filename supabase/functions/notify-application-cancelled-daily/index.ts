// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-application-cancelled-daily
// ──────────────────────────────────────────────────────────────────
// 트리거: pg_cron 매일 UTC 00:00 (= 한국시간 오전 9시) net.http_post
// 역할:   전일 한국시간 0시~24시 동안 cancel_phase != 'recruit' 인
//         취소 응모를 모아 관리자에게 일일 요약 메일 1통 발송.
//         0건이면 메일 미발송 + 로그(skipped_no_data).
//         발송 로그(application_cancel_digest_runs) UNIQUE(digest_date)
//         로 cron 중복 호출 차단 — 같은 날짜 재실행은 즉시 종료.
//
// 환경변수 (Edge Functions Secrets):
//   SUPABASE_URL              자동 주입 (Edge Function 런타임)
//   SUPABASE_SERVICE_ROLE_KEY 자동 주입
//   BREVO_API_KEY             Brevo Transactional API 키 (양 서버 별도)
//   NOTIFY_ADMIN_EMAILS       외부 수신자 콤마 구분 (옵션 — DB 수신자와 합산)
//   PUBLIC_ADMIN_URL          관리자 페이지 절대 URL (딥링크용)
//                             기본 https://globalreverb.com/admin/
//   BREVO_SENDER_EMAIL        기본 noreply@globalreverb.com
//   BREVO_SENDER_NAME         기본 REVERB JP  (개발은 REVERB JP [DEV])
//
// 수신자 결정 로직 (notify-brand-application 패턴 미러):
//   get_subscribed_admin_emails('application_cancel')
//     ∪ NOTIFY_ADMIN_EMAILS (env)
//
// HTML 템플릿:
//   _templates/application-cancelled-daily.html      메인
//   _templates/application-cancelled-daily.row.html  행 1건
//
//   원본은 docs/email-templates/ — scripts/sync-email-templates.sh 가
//   _templates/ 로 복사 + templates.ts 자동 생성 (Supabase CLI 가
//   _templates/ 를 함수 번들에 포함 안 시키므로 ES 모듈 임포트로 우회).
//   배포 직전 반드시 sync 실행.
//
// pg_cron 등록 (자세한 절차는 docs/specs/2026-05-12-HANDOFF-application-cancel-pr-d-cron-setup.md):
//   사전 조건: pg_net + pg_cron + supabase_vault 확장 ON,
//             vault.secrets 에 'edge_function_jwt' 이름으로 service_role JWT 저장.
//   SELECT cron.schedule(
//     'application-cancel-daily-digest',
//     '0 0 * * *',   -- 매일 UTC 00:00 = 한국시간 09:00
//     $$
//     SELECT net.http_post(
//       url := 'https://<project-ref>.functions.supabase.co/notify-application-cancelled-daily',
//       headers := jsonb_build_object(
//         'Content-Type', 'application/json',
//         'Authorization', 'Bearer ' || (
//           SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'edge_function_jwt' LIMIT 1
//         )
//       ),
//       body := '{}'::jsonb
//     );
//     $$
//   );
//
// 배포:
//   bash scripts/sync-email-templates.sh
//   supabase functions deploy notify-application-cancelled-daily --project-ref <ref>
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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
// 한국시간(KST) 윈도우 계산
//   - 호출 시각의 한국시간 「오늘」 의 전일을 digest_date 로 잡는다.
//   - 운영 의도: pg_cron 이 매일 UTC 00:00(= KST 09:00) 호출 → digest_date
//     는 「어제 한국시간」 (= 같은 칼렌더 날짜의 0:00~24:00 KST).
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

  // KST 0:00 = UTC -9h 의 그 날짜
  const windowStartUtc = new Date(Date.parse(`${digestDate}T00:00:00+09:00`));
  const windowEndUtc = new Date(windowStartUtc.getTime() + 24 * 3600 * 1000);
  return { digestDate, windowStartUtc, windowEndUtc };
}

// 관리자 수신자: get_subscribed_admin_emails('application_cancel') ∪ env
async function resolveAdminEmails(
  sb: ReturnType<typeof createClient>,
): Promise<string[]> {
  const fromEnv = env("NOTIFY_ADMIN_EMAILS", "")
    .split(",")
    .map((e) => e.trim())
    .filter(Boolean);

  try {
    const { data, error } = await sb.rpc("get_subscribed_admin_emails", {
      p_mail_kind: "application_cancel",
    });
    if (error) throw error;
    const fromDb = (data || [])
      .map((r: { email: string | null }) => (r.email || "").trim())
      .filter(Boolean);
    return [...new Set([...fromDb, ...fromEnv])];
  } catch (_e) {
    // DB 조회 실패 시 env 만 사용 (fail-safe)
    return [...new Set(fromEnv)];
  }
}

interface CancelledRow {
  id: string;
  cancelled_at: string;
  cancel_phase: string;
  cancel_reason_code: string | null;
  cancel_reason: string | null;
  campaign_id: string;
  user_id: string;
}

interface CampaignRow {
  id: string;
  campaign_no: string | null;
  title: string | null;
  recruit_type: string | null;
}

interface InfluencerRow {
  id: string;
  name: string | null;
  name_kanji: string | null;
  name_kana: string | null;
  // email 은 auth.users 에서 별도 조회 (influencers 테이블에 email 컬럼 없음)
}

function phaseKo(phase: string): string {
  switch (phase) {
    case "purchase": return "구매기간";
    case "visit":    return "방문기간";
    case "post":     return "결과물 제출기간";
    default:         return "기타";
  }
}

function recruitTypeKo(rt: string | null | undefined): string {
  switch (rt) {
    case "monitor": return "리뷰어";
    case "gifting": return "기프팅";
    case "visit":   return "방문형";
    default:        return rt || "-";
  }
}

function formatJst(iso: string): string {
  // ISO timestamptz → 'YYYY-MM-DD HH:mm JST'
  const d = new Date(iso);
  const kstMs = d.getTime() + 9 * 3600 * 1000;
  const k = new Date(kstMs);
  const yyyy = k.getUTCFullYear();
  const mm = String(k.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(k.getUTCDate()).padStart(2, "0");
  const hh = String(k.getUTCHours()).padStart(2, "0");
  const mi = String(k.getUTCMinutes()).padStart(2, "0");
  return `${yyyy}-${mm}-${dd} ${hh}:${mi} JST`;
}

function influencerDisplayName(row: InfluencerRow): string {
  // 관리자 페이지 인플루언서 목록과 동일 패턴: name_kanji || name 우선
  // (한자/가나 모두 있고 다르면 "한자 (가나)" 병기)
  const kanji = (row.name_kanji || "").trim();
  const name  = (row.name       || "").trim();
  const kana  = (row.name_kana  || "").trim();
  const main = kanji || name;
  if (main && kana && main !== kana) return `${main} (${kana})`;
  return main || kana || "-";
}

// ──────────────────────────────────────────────────────────────────
// HTML 템플릿 로딩 + placeholder 치환
// _templates/*.html 가 Edge Function 번들에 포함되지 않는 Supabase CLI
// 동작 때문에 templates.ts 에 ES 모듈로 인라인 (번들러 자동 dependency).
// (notify-deliverable-decision 과 동일 패턴 — sync-email-templates.sh 자동 생성)
// ──────────────────────────────────────────────────────────────────
import { TEMPLATES } from "./templates.ts";

function loadTemplate(name: string): string {
  const html = TEMPLATES[name];
  if (!html) throw new Error(`template not registered: ${name}`);
  // HTML 주석 제거 — 주석 안 placeholder 가 치환되면서 발생하는 중첩 주석
  // → 조기 종료 → 본문 누출 버그 차단 (2026-05-18 admin-daily-digest 발견 동일 패턴)
  return html.replace(/<!--[\s\S]*?-->/g, "");
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

// digest_runs 로그 INSERT — 실패해도 메인 흐름은 진행 (관측성 보강용 로그)
async function logRun(
  sb: ReturnType<typeof createClient>,
  payload: {
    digest_date: string;
    status: "sent" | "skipped_no_data" | "failed";
    recipients_count: number;
    cancelled_count: number;
    error_message?: string | null;
  },
): Promise<{ duplicate: boolean }> {
  const { error } = await sb
    .from("application_cancel_digest_runs")
    .insert({
      digest_date: payload.digest_date,
      status: payload.status,
      recipients_count: payload.recipients_count,
      cancelled_count: payload.cancelled_count,
      error_message: payload.error_message ?? null,
    });
  if (error) {
    // 23505 = unique violation (이미 같은 날짜 발송 로그 존재)
    if ((error as { code?: string }).code === "23505") {
      return { duplicate: true };
    }
    console.error("[notify-cancel-daily] logRun failed", error);
  }
  return { duplicate: false };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) {
    console.error("[notify-cancel-daily] Supabase env missing");
    return new Response(
      JSON.stringify({ error: "SUPABASE env missing" }),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  }
  const sb = createClient(supaUrl, serviceKey, {
    auth: { persistSession: false },
  });

  const { digestDate, windowStartUtc, windowEndUtc } = computeWindow();
  console.log("[notify-cancel-daily] window", {
    digestDate,
    start: windowStartUtc.toISOString(),
    end: windowEndUtc.toISOString(),
  });

  // 1. 같은 digest_date 가 이미 처리됐는지 사전 확인 (UNIQUE 충돌 전 빠른 단락)
  {
    const { data: prior, error: priorErr } = await sb
      .from("application_cancel_digest_runs")
      .select("id, status, ran_at")
      .eq("digest_date", digestDate)
      .maybeSingle();
    if (priorErr) {
      console.warn("[notify-cancel-daily] prior check failed", priorErr);
    }
    if (prior) {
      console.log("[notify-cancel-daily] already processed", prior);
      return new Response(
        JSON.stringify({
          ok: true,
          skipped: true,
          reason: "already_processed",
          digestDate,
          prior,
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    }
  }

  // 2. 윈도우 내 취소 행 조회 (캠페인은 별도 배치 — applications.campaign_id 는
  //    PostgREST schema 캐시에 외래 키(FK) 관계가 없어 embed 불가)
  let rows: CancelledRow[] = [];
  try {
    const { data, error } = await sb
      .from("applications")
      .select(`
        id,
        cancelled_at,
        cancel_phase,
        cancel_reason_code,
        cancel_reason,
        campaign_id,
        user_id
      `)
      .eq("status", "cancelled")
      .neq("cancel_phase", "recruit")
      .not("cancel_phase", "is", null)
      .gte("cancelled_at", windowStartUtc.toISOString())
      .lt("cancelled_at", windowEndUtc.toISOString())
      .order("cancelled_at", { ascending: true });
    if (error) throw error;
    rows = (data || []) as unknown as CancelledRow[];
  } catch (e) {
    const msg = (e as Error).message || "unknown query error";
    console.error("[notify-cancel-daily] query failed", msg);
    await logRun(sb, {
      digest_date: digestDate,
      status: "failed",
      recipients_count: 0,
      cancelled_count: 0,
      error_message: `query: ${msg}`,
    });
    return new Response(
      JSON.stringify({ error: msg, stage: "query" }),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  }

  console.log("[notify-cancel-daily] rows fetched", { count: rows.length });

  // 3. 0건 → 스킵 로그 + 즉시 종료
  if (rows.length === 0) {
    const { duplicate } = await logRun(sb, {
      digest_date: digestDate,
      status: "skipped_no_data",
      recipients_count: 0,
      cancelled_count: 0,
    });
    return new Response(
      JSON.stringify({
        ok: true,
        skipped: true,
        reason: "no_data",
        digestDate,
        duplicate,
      }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  }

  // 4. 캠페인·인플루언서·사유 lookup 배치 조회
  const campaignIds = [...new Set(rows.map((r) => r.campaign_id))];
  const userIds = [...new Set(rows.map((r) => r.user_id))];
  const reasonCodes = [
    ...new Set(
      rows.map((r) => r.cancel_reason_code).filter((c): c is string => !!c),
    ),
  ];

  const campaignMap = new Map<string, CampaignRow>();
  if (campaignIds.length > 0) {
    const { data: camps, error: cErr } = await sb
      .from("campaigns")
      .select("id, campaign_no, title, recruit_type")
      .in("id", campaignIds);
    if (cErr) {
      console.warn("[notify-cancel-daily] campaign lookup failed", cErr);
    } else {
      (camps || []).forEach((row: CampaignRow) => {
        campaignMap.set(row.id, row);
      });
    }
  }

  const influencerMap = new Map<string, InfluencerRow>();
  if (userIds.length > 0) {
    const { data: infls, error: infErr } = await sb
      .from("influencers")
      .select("id, name, name_kanji, name_kana")
      .in("id", userIds);
    if (infErr) {
      console.warn("[notify-cancel-daily] influencer lookup failed", infErr);
    } else {
      (infls || []).forEach((row: InfluencerRow) => {
        influencerMap.set(row.id, row);
      });
    }
  }

  // 이메일은 auth.users 에서 별도 조회 (influencers 테이블에 email 컬럼 없음).
  // 서비스 키 권한으로 admin.getUserById 사용 가능.
  const emailMap = new Map<string, string>();
  if (userIds.length > 0) {
    const emailResults = await Promise.all(
      userIds.map((id) => sb.auth.admin.getUserById(id)),
    );
    emailResults.forEach((result, idx) => {
      if (!result.error && result.data?.user?.email) {
        emailMap.set(userIds[idx], result.data.user.email);
      }
    });
  }

  const reasonMap = new Map<string, string>();
  if (reasonCodes.length > 0) {
    const { data: reasons, error: rErr } = await sb
      .from("lookup_values")
      .select("code, name_ko")
      .eq("kind", "cancel_reason")
      .in("code", reasonCodes);
    if (rErr) {
      console.warn("[notify-cancel-daily] reason lookup failed", rErr);
    } else {
      (reasons || []).forEach((row: { code: string; name_ko: string }) => {
        reasonMap.set(row.code, row.name_ko);
      });
    }
  }

  // 5. 시점별 카운트 (메인 템플릿 phase_summary_html 용)
  const phaseCount: Record<string, number> = {};
  rows.forEach((r) => {
    phaseCount[r.cancel_phase] = (phaseCount[r.cancel_phase] || 0) + 1;
  });
  const phaseOrder = ["purchase", "visit", "post", "other"];
  const phaseColors: Record<string, { bg: string; fg: string }> = {
    purchase: { bg: "#FFE4E9", fg: "#E8344E" },
    visit:    { bg: "#E4F0FF", fg: "#1F5DBF" },
    post:     { bg: "#FFF0D6", fg: "#A06A14" },
    other:    { bg: "#EAEAEA", fg: "#555555" },
  };
  const phaseSummaryHtml = phaseOrder
    .filter((p) => phaseCount[p])
    .map((p) => {
      const c = phaseColors[p] || phaseColors.other;
      return `<span style="background:${c.bg};color:${c.fg};padding:2px 8px;border-radius:4px;font-weight:700;margin-right:6px">${phaseKo(p)} ${phaseCount[p]}건</span>`;
    })
    .join("");

  // 6. 행별 HTML 빌드 — 시점별 그룹화 (구매기간 → 방문기간 → 결과물 제출기간 → 기타).
  //    각 그룹에 소제목 + 건수 헤더. 0건 그룹은 생략. 그룹 내 행 순서는 쿼리의
  //    cancelled_at 오름차순(ascending) 정렬을 그대로 유지.
  const rowTpl = loadTemplate("application-cancelled-daily.row");
  const phaseGroups: Record<string, CancelledRow[]> = {};
  phaseOrder.forEach((p) => {
    phaseGroups[p] = [];
  });
  rows.forEach((r) => {
    const key = phaseOrder.includes(r.cancel_phase) ? r.cancel_phase : "other";
    phaseGroups[key].push(r);
  });

  const renderCard = (r: CancelledRow): string => {
    const camp = campaignMap.get(r.campaign_id) || null;
    const infl = influencerMap.get(r.user_id) || {
      id: r.user_id,
      name: null,
      name_kanji: null,
      name_kana: null,
    };
    const reasonLabel = r.cancel_reason_code
      ? reasonMap.get(r.cancel_reason_code) || r.cancel_reason_code
      : "-";
    const noteRow = (r.cancel_reason || "").trim()
      ? `<tr><td style="padding:4px 0;color:#888;vertical-align:top">보충</td><td style="padding:4px 0;line-height:1.5">${escapeHtml(r.cancel_reason || "")}</td></tr>`
      : "";

    return render(rowTpl, {
      campaign_no: escapeHtml(`【${camp?.campaign_no ?? ""}】`),
      campaign_title: escapeHtml(camp?.title ?? "-"),
      recruit_type_ko: escapeHtml(recruitTypeKo(camp?.recruit_type ?? null)),
      influencer_name: escapeHtml(influencerDisplayName(infl)),
      influencer_email: escapeHtml(emailMap.get(r.user_id) || "-"),
      cancelled_at_jst: escapeHtml(formatJst(r.cancelled_at)),
      cancel_phase_ko: escapeHtml(phaseKo(r.cancel_phase)),
      cancel_reason_ko: escapeHtml(reasonLabel),
      cancel_reason_note_row: noteRow,
    });
  };

  const rowsHtml = phaseOrder
    .filter((p) => phaseGroups[p].length > 0)
    .map((p) => {
      const c = phaseColors[p] || phaseColors.other;
      const groupHeader =
        `<div style="margin:20px 0 10px;padding:8px 12px;background:${c.bg};border-left:3px solid ${c.fg};border-radius:0 6px 6px 0">` +
        `<span style="color:${c.fg};font-weight:700;font-size:13px">${phaseKo(p)}</span>` +
        `<span style="color:${c.fg};font-size:12px;margin-left:6px">${phaseGroups[p].length}건</span>` +
        `</div>`;
      const cardsHtml = phaseGroups[p].map(renderCard).join("");
      return groupHeader + cardsHtml;
    })
    .join("");

  // 7. 메인 HTML 빌드
  const adminUrlBase = env("PUBLIC_ADMIN_URL", "https://globalreverb.com/admin/")
    .replace(/\/$/, "");
  const adminPaneUrl = `${adminUrlBase}/#applications?filter=cancelled&date=${digestDate}`;

  const mainTpl = loadTemplate("application-cancelled-daily");
  const html = render(mainTpl, {
    digest_date: escapeHtml(digestDate),
    total_count: String(rows.length),
    phase_summary_html: phaseSummaryHtml,
    rows_html: rowsHtml,
    admin_pane_url: escapeHtml(adminPaneUrl),
  });

  const subject =
    `[REVERB] 응모 취소 일일 요약 — ${digestDate} (${rows.length}건)`;

  // text fallback (간단 요약)
  const textLines = [
    `응모 취소 일일 요약 (${digestDate})`,
    `총 ${rows.length}건`,
    "",
    ...rows.map((r) => {
      const camp = campaignMap.get(r.campaign_id) || null;
      const infl = influencerMap.get(r.user_id) || { name: null, name_kanji: null, name_kana: null } as Partial<InfluencerRow>;
      const displayName = (infl.name_kanji || infl.name || infl.name_kana || "-");
      const reasonLabel = r.cancel_reason_code
        ? reasonMap.get(r.cancel_reason_code) || r.cancel_reason_code
        : "-";
      return `- [${camp?.campaign_no ?? ""}] ${camp?.title ?? "-"} · ${displayName} · ${phaseKo(r.cancel_phase)} · ${reasonLabel}`;
    }),
    "",
    `관리자 페이지: ${adminPaneUrl}`,
  ];
  const text = textLines.join("\n");

  // 8. 수신자 결정 + 메일 발송
  const adminEmails = await resolveAdminEmails(sb);
  console.log("[notify-cancel-daily] recipients", {
    count: adminEmails.length,
    emails: adminEmails,
  });

  if (adminEmails.length === 0) {
    console.warn("[notify-cancel-daily] no recipients — skipping send");
    await logRun(sb, {
      digest_date: digestDate,
      status: "failed",
      recipients_count: 0,
      cancelled_count: rows.length,
      error_message: "no recipients (admin_email_subscriptions + env both empty)",
    });
    return new Response(
      JSON.stringify({
        ok: false,
        reason: "no_recipients",
        digestDate,
        cancelled_count: rows.length,
      }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  }

  // 관리자별 1통씩 분리 발송 (To 헤더 노출 차단)
  let successCount = 0;
  const failures: string[] = [];
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
      console.error("[notify-cancel-daily] send failed", email, msg);
      failures.push(`${email}(${msg})`);
    }
  }

  if (successCount === 0) {
    await logRun(sb, {
      digest_date: digestDate,
      status: "failed",
      recipients_count: 0,
      cancelled_count: rows.length,
      error_message: `all ${adminEmails.length} sends failed: ${failures[0] ?? "unknown"}`,
    });
    return new Response(
      JSON.stringify({ error: "all sends failed", stage: "send", attempted: adminEmails.length, failed: failures.length }),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  }

  // 9. 성공 (전부 또는 일부) 로그
  const errMsg = failures.length > 0
    ? `${successCount}/${adminEmails.length} sent. failed: ${failures.join("; ")}`
    : null;
  await logRun(sb, {
    digest_date: digestDate,
    status: "sent",
    recipients_count: successCount,
    cancelled_count: rows.length,
    error_message: errMsg,
  });

  console.log("[notify-cancel-daily] done", {
    digestDate,
    cancelled: rows.length,
    attempted: adminEmails.length,
    succeeded: successCount,
    failed: failures.length,
  });

  return new Response(
    JSON.stringify({
      ok: true,
      digestDate,
      cancelled_count: rows.length,
      attempted: adminEmails.length,
      succeeded: successCount,
      failed: failures.length,
    }),
    { status: 200, headers: { "content-type": "application/json" } },
  );
});
