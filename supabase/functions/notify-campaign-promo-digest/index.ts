// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-campaign-promo-digest
// ──────────────────────────────────────────────────────────────────
// PR 2 — 캠페인 홍보 메일 다이제스트 (주 2회 인플당 1통)
// 사양서: docs/specs/2026-05-19-campaign-promo-email.md §4, §5, §16, §17
//
// 트리거: pg_cron 매주 월·목 UTC 00:00 (= 한국시간 오전 9시) net.http_post
//         (cron 등록은 PR 5 마이그레이션 142 에서 진행)
// 윈도우: 신규 = first_active_at AT TIME ZONE 'Asia/Seoul'::date = p_digest_date
//         D-1 = deadline = CURRENT_DATE + 1
//
// 처리 흐름:
//   1. INSERT mutex (digest_date UNIQUE) — 첫 배치만
//   2. get_promo_digest_targets(KST 오늘) RPC — 발송 대상자 N명
//   3. 양 섹션 모두 0건이면 status='skipped_no_data' + 종료
//   4. 캠페인 일괄 조회 + monitor approved count 일괄 조회
//   5. 200명 배치 직렬 발송 (Brevo SMTP):
//      a. 메일 HTML 렌더 (신규 섹션 + D-1 섹션, 한쪽 0건이면 그 섹션 생략)
//      b. campaign_promo_exposure INSERT (kind='new' / 'deadline_d1')
//      c. mark_promo_digest_sent RPC 로 발송 결과 기록
//      d. 100ms 슬립 (Brevo rate limit 보호)
//   6. hasMore 이면 자기재호출 (fire-and-forget, source='chained')
//   7. finalizeRun — sent / partial / failed / skipped_no_data
//
// 동시성:
//   - digest_date UNIQUE 가 mutex (첫 배치 INSERT 시 23505 발생 → 이미 처리됨)
//   - (influencer_id, digest_date) UNIQUE 가 인플 단위 멱등
//   - chained 자기재호출: body.source='chained' → 첫 배치 mutex INSERT 스킵
//
// 부분 실패 (사양서 §4-3):
//   - 전부 성공 → status='sent'
//   - 일부 실패 → status='partial'
//   - 전부 실패 → status='failed'
//   - 데이터 0건 → status='skipped_no_data'
//
// 환경변수:
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (자동 주입)
//   BREVO_API_KEY (양 서버 별도)
//   PUBLIC_APP_URL    기본 https://globalreverb.com
//   BREVO_SENDER_EMAIL  기본 noreply@globalreverb.com
//   BREVO_SENDER_NAME   기본 REVERB JP
//
// 참고: qoo10 채널은 인플 SNS 컬럼에 없어 현재 매칭 제외 (PR 1 핸드오프 메모리 명시)
//
// 배포:
//   bash scripts/sync-email-templates.sh
//   supabase functions deploy notify-campaign-promo-digest --project-ref <ref>
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TEMPLATES } from "./templates.ts";

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";

// 첫 호출에서 처리하는 인플 수 (사양서 §16-4)
//   인플 200 명 × 약 0.6초 (Brevo + DB + 슬립) ≒ 120초
//   Deno 150 초 timeout 안에 안전. 1,398 명 → 약 7 배치 chained.
const BATCH_SIZE = 200;

// Brevo rate limit 보호용 슬립 (admin-daily-digest 동일 패턴)
const BREVO_SLEEP_MS = 100;

// 메일 안 카드 상한 (사양서 §16-5). RPC 가 이미 5건 슬라이스해서 반환.
const MAX_CARDS_PER_SECTION = 5;

function env(key: string, fallback = ""): string {
  return Deno.env.get(key) ?? fallback;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
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
// 템플릿 로딩·렌더
// ──────────────────────────────────────────────────────────────────
function loadTemplate(name: string): string {
  const html = TEMPLATES[name];
  if (!html) throw new Error(`template not registered: ${name}`);
  // 주석 안 placeholder 가 치환되면서 발생하는 중첩 주석 → 본문 누출 버그 차단
  return html.replace(/<!--[\s\S]*?-->/g, "");
}

function render(html: string, data: Record<string, string>): string {
  return html.replace(/\{\{(\w+)\}\}/g, (_m, key) => data[key] ?? "");
}

// ──────────────────────────────────────────────────────────────────
// 한국시간(KST) 헬퍼 — 오늘 KST 날짜 (YYYY-MM-DD)
// ──────────────────────────────────────────────────────────────────
function computeDigestDate(): string {
  const KST_OFFSET_MS = 9 * 3600 * 1000;
  const nowKstMs = Date.now() + KST_OFFSET_MS;
  const k = new Date(nowKstMs);
  const yyyy = k.getUTCFullYear();
  const mm = String(k.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(k.getUTCDate()).padStart(2, "0");
  return `${yyyy}-${mm}-${dd}`;
}

// 캠페인 deadline (YYYY-MM-DD) vs 오늘 (KST) → 며칠 남았는지 + 라벨
function deadlineLabelJa(deadline: string | null, todayKst: string): string {
  if (!deadline) return "-";
  const todayDate = new Date(`${todayKst}T00:00:00+09:00`).getTime();
  const dlDate = new Date(`${deadline}T00:00:00+09:00`).getTime();
  if (Number.isNaN(dlDate)) return "-";
  const diff = Math.round((dlDate - todayDate) / (24 * 3600 * 1000));
  if (diff < 0) return "本日締切";
  if (diff === 0) return "本日締切";
  if (diff === 1) return "明日まで";
  return `あと${diff}日`;
}

// ──────────────────────────────────────────────────────────────────
// 모집 타입 라벨·칩 컬러 (인플 카드)
// ──────────────────────────────────────────────────────────────────
function recruitTypeJa(rt: string | null | undefined): string {
  switch (rt) {
    case "monitor": return "レビュアー";
    case "gifting": return "ギフティング";
    case "visit":   return "訪問型";
    default:        return rt || "-";
  }
}

const RECRUIT_TYPE_CHIP: Record<string, { bg: string; fg: string }> = {
  monitor: { bg: "#FFE4E9", fg: "#C8789C" },
  gifting: { bg: "#E4F0FF", fg: "#1F5DBF" },
  visit:   { bg: "#E0F1E4", fg: "#1F7A3D" },
  default: { bg: "#EAEAEA", fg: "#555555" },
};
function recruitTypeChipColors(rt: string | null | undefined): { bg: string; fg: string } {
  if (!rt) return RECRUIT_TYPE_CHIP.default;
  return RECRUIT_TYPE_CHIP[rt] ?? RECRUIT_TYPE_CHIP.default;
}

// ──────────────────────────────────────────────────────────────────
// 안전한 외부 URL — http(s) 스킴만 허용 (javascript:, data: 차단)
// ──────────────────────────────────────────────────────────────────
function safeExternalUrl(raw: string | null | undefined): string | null {
  const url = (raw || "").trim();
  if (!url) return null;
  if (!/^https?:\/\//i.test(url)) return null;
  return url;
}

// ──────────────────────────────────────────────────────────────────
// Brevo 발송
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
// 타입
// ──────────────────────────────────────────────────────────────────
interface PromoTarget {
  influencer_id: string;
  email: string | null;
  name: string | null;
  unsubscribe_token: string;
  new_campaign_ids: string[];
  deadline_d1_campaign_ids: string[];
  new_total_count: number;
  deadline_d1_total_count: number;
}

interface CampaignRow {
  id: string;
  campaign_no: string | null;
  title: string | null;
  brand: string | null;
  brand_ko: string | null;
  recruit_type: string | null;
  deadline: string | null;
  slots: number | null;
  reward: string | null;
  img1: string | null;
}

interface RequestBody {
  source?: "cron" | "manual" | "chained";
  digestDate?: string;
  batchOffset?: number;
}

// ──────────────────────────────────────────────────────────────────
// 캠페인 카드 렌더
// ──────────────────────────────────────────────────────────────────
function renderCampaignCard(args: {
  rowTpl: string;
  camp: CampaignRow;
  token: string;
  publicAppUrl: string;
  todayKst: string;
  showD1Chip: boolean;
  approvedCount: number | null; // monitor 만 의미 있음, 다른 타입은 null
}): string {
  const camp = args.camp;
  const recruitType = camp.recruit_type ?? "";
  const typeChip = recruitTypeChipColors(recruitType);
  const brandName = (camp.brand || camp.brand_ko || "").trim();
  const imgRaw = safeExternalUrl(camp.img1);
  // 메일 클라이언트는 file:/cid: 같은 비표준 URL 차단 → fallback 은 빈 alt 만
  // 정적 placeholder 이미지 호스팅 별도 자산 도입 전까지 비어있는 src 회피용으로 1px 데이터 URI 사용
  const imgUrl = imgRaw
    ? `${imgRaw}${imgRaw.includes("?") ? "&" : "?"}width=520&quality=75`
    : "https://placehold.co/520x200/EEEEEE/888888?text=No+Image";

  const d1ChipHtml = args.showD1Chip
    ? `<span style="background:#FFE4E9;color:#E8344E;padding:2px 8px;border-radius:4px;font-weight:700;margin-left:6px">締切間近 D-1</span>`
    : "";

  // 사용자 결정 E: monitor (리뷰어) 만 잔여 슬롯 행 표시
  let slotsRowHtml = "";
  if (recruitType === "monitor" && camp.slots != null) {
    const total = camp.slots;
    const approved = args.approvedCount ?? 0;
    const remaining = Math.max(total - approved, 0);
    slotsRowHtml =
      `<tr><td style="color:#888;padding:3px 0">残り枠</td>` +
      `<td style="padding:3px 0">${escapeHtml(`${remaining}/${total}`)}名</td></tr>`;
  }

  const detailUrl = `${args.publicAppUrl}/#detail-${camp.id}?promo_token=${encodeURIComponent(args.token)}`;
  const reward = (camp.reward || "").trim() || "-";
  const deadlineLabel = deadlineLabelJa(camp.deadline, args.todayKst);

  return render(args.rowTpl, {
    img_url: escapeHtml(imgUrl),
    recruit_type_ja: escapeHtml(recruitTypeJa(recruitType)),
    type_chip_bg: typeChip.bg,
    type_chip_fg: typeChip.fg,
    brand: escapeHtml(brandName || "-"),
    title: escapeHtml(camp.title || "-"),
    d1_chip_html: d1ChipHtml,
    reward: escapeHtml(reward),
    deadline_label: escapeHtml(deadlineLabel),
    slots_row_html: slotsRowHtml,
    detail_url: escapeHtml(detailUrl),
  });
}

// ──────────────────────────────────────────────────────────────────
// 섹션 렌더
// ──────────────────────────────────────────────────────────────────
function renderSection(args: {
  sectionTpl: string;
  rowTpl: string;
  title: string;
  color: string;
  campaignIds: string[];
  totalCount: number;
  campaignMap: Map<string, CampaignRow>;
  approvedMap: Map<string, number>;
  token: string;
  publicAppUrl: string;
  todayKst: string;
  showD1Chip: boolean;
}): string {
  const shown = args.campaignIds.slice(0, MAX_CARDS_PER_SECTION);
  if (shown.length === 0) return "";

  const cards = shown
    .map((cid) => {
      const camp = args.campaignMap.get(cid);
      if (!camp) return "";
      return renderCampaignCard({
        rowTpl: args.rowTpl,
        camp,
        token: args.token,
        publicAppUrl: args.publicAppUrl,
        todayKst: args.todayKst,
        showD1Chip: args.showD1Chip,
        approvedCount: camp.recruit_type === "monitor"
          ? args.approvedMap.get(cid) ?? 0
          : null,
      });
    })
    .filter((s) => s.length > 0)
    .join("");

  const extra = Math.max(args.totalCount - shown.length, 0);
  const additionalHtml = extra > 0
    ? `<p style="margin:8px 0 0;text-align:center;font-size:12px;color:#888">他 ${extra}件のキャンペーンも公開中です</p>`
    : "";

  return render(args.sectionTpl, {
    section_title: escapeHtml(args.title),
    section_color: args.color,
    section_count: String(shown.length),
    section_body_html: cards + additionalHtml,
  });
}

// ──────────────────────────────────────────────────────────────────
// 메일 본문 렌더 (인플 1명당 1 회 호출)
// ──────────────────────────────────────────────────────────────────
function renderMailBody(args: {
  target: PromoTarget;
  campaignMap: Map<string, CampaignRow>;
  approvedMap: Map<string, number>;
  publicAppUrl: string;
  todayKst: string;
}): { html: string; subject: string; text: string } {
  const mainTpl = loadTemplate("campaign-promo-digest");
  const sectionTpl = loadTemplate("campaign-promo-digest.section");
  const rowTpl = loadTemplate("campaign-promo-digest.row-campaign");

  const influencerName = (args.target.name || "").trim() || "お客様";

  // 섹션 1: 新着 (분홍 #C8789C)
  const newSectionHtml = renderSection({
    sectionTpl, rowTpl,
    title: "新着キャンペーン",
    color: "#C8789C",
    campaignIds: args.target.new_campaign_ids,
    totalCount: args.target.new_total_count,
    campaignMap: args.campaignMap,
    approvedMap: args.approvedMap,
    token: args.target.unsubscribe_token,
    publicAppUrl: args.publicAppUrl,
    todayKst: args.todayKst,
    showD1Chip: false,
  });

  // 섹션 2: 締切間近 (빨강 #E8344E)
  const deadlineSectionHtml = renderSection({
    sectionTpl, rowTpl,
    title: "締切間近キャンペーン",
    color: "#E8344E",
    campaignIds: args.target.deadline_d1_campaign_ids,
    totalCount: args.target.deadline_d1_total_count,
    campaignMap: args.campaignMap,
    approvedMap: args.approvedMap,
    token: args.target.unsubscribe_token,
    publicAppUrl: args.publicAppUrl,
    todayKst: args.todayKst,
    showD1Chip: true,
  });

  const campaignsUrl = `${args.publicAppUrl}/#campaigns`;
  const unsubscribeUrl = `${args.publicAppUrl}/#unsubscribe?token=${encodeURIComponent(args.target.unsubscribe_token)}`;
  const mypageSettingsUrl = `${args.publicAppUrl}/#mypage-email-settings`;

  const html = render(mainTpl, {
    influencer_name: escapeHtml(influencerName),
    new_section_html: newSectionHtml,
    deadline_section_html: deadlineSectionHtml,
    campaigns_url: escapeHtml(campaignsUrl),
    unsubscribe_url: escapeHtml(unsubscribeUrl),
    mypage_settings_url: escapeHtml(mypageSettingsUrl),
    agreed_at_label: "マーケティング情報配信にご同意いただいた方にお送りしています",
  });

  // 제목 — 신규/마감 건수에 따라 분기
  const newCount = args.target.new_total_count;
  const d1Count = args.target.deadline_d1_total_count;
  let subject: string;
  if (newCount > 0 && d1Count > 0) {
    subject = `[REVERB JP] 新着キャンペーン${newCount}件 / 締切間近${d1Count}件`;
  } else if (newCount > 0) {
    subject = `[REVERB JP] 新着キャンペーン${newCount}件のご案内`;
  } else {
    subject = `[REVERB JP] 締切間近${d1Count}件のお知らせ`;
  }

  // text fallback
  const textLines = [
    `${influencerName} 様`,
    "",
    `新しいキャンペーン情報が届きました。`,
  ];
  if (newCount > 0) textLines.push(`・新着キャンペーン: ${newCount}件`);
  if (d1Count > 0) textLines.push(`・締切間近 (D-1): ${d1Count}件`);
  textLines.push("");
  textLines.push(`すべてのキャンペーンを見る: ${campaignsUrl}`);
  textLines.push(`配信停止: ${unsubscribeUrl}`);
  const text = textLines.join("\n");

  return { html, subject, text };
}

// ──────────────────────────────────────────────────────────────────
// 자기재호출 (fire-and-forget)
// ──────────────────────────────────────────────────────────────────
function selfInvokeChained(args: {
  supaUrl: string;
  serviceKey: string;
  digestDate: string;
  nextOffset: number;
}): void {
  const url = `${args.supaUrl.replace(/\/$/, "")}/functions/v1/notify-campaign-promo-digest`;
  // await 하지 않음 — 본 호출은 즉시 반환
  fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${args.serviceKey}`,
    },
    body: JSON.stringify({
      source: "chained",
      digestDate: args.digestDate,
      batchOffset: args.nextOffset,
    }),
  }).catch((e) => {
    console.error("[notify-campaign-promo] chained invoke failed", e);
  });
}

// ──────────────────────────────────────────────────────────────────
// Main handler
// ──────────────────────────────────────────────────────────────────
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) {
    console.error("[notify-campaign-promo] SUPABASE env missing");
    return new Response(JSON.stringify({ error: "SUPABASE env missing" }), {
      status: 500, headers: { "content-type": "application/json" },
    });
  }
  const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

  // body parse — chained 호출 또는 cron / manual
  let body: RequestBody = {};
  try {
    const raw = await req.text();
    if (raw) body = JSON.parse(raw);
  } catch (_e) {
    body = {};
  }

  const source: "cron" | "manual" | "chained" = body.source ?? "cron";
  const digestDate = body.digestDate || computeDigestDate();
  const batchOffset = body.batchOffset ?? 0;
  const isFirstBatch = batchOffset === 0;
  const todayKst = digestDate; // 컬럼명 동일 — RPC 가 이미 KST 윈도우 기준 처리

  console.log("[notify-campaign-promo] start", { source, digestDate, batchOffset, isFirstBatch });

  // ── 1. INSERT mutex (첫 배치만) ──
  //    triggered_by 는 마이그레이션 139 에서 uuid REFERENCES auth.users(id) 타입이라
  //    cron 자동 실행은 null 로 저장 (운영자 수동 트리거 구현은 후속 PR 영역).
  //    'cron' / 'manual' / 'chained' 같은 문자열을 넣으면 22P02 (uuid 캐스트 실패).
  if (isFirstBatch) {
    const { error } = await sb
      .from("campaign_promo_digest_runs")
      .insert({
        digest_date: digestDate,
        status: "failed",
        included_campaign_ids: [],
        target_influencer_count: 0,
        sent_count: 0,
        skipped_count: 0,
        failed_count: 0,
        error_message: "in-flight",
        triggered_by: null,
      });
    if (error) {
      if ((error as { code?: string }).code === "23505") {
        console.log("[notify-campaign-promo] already processed", digestDate);
        return new Response(
          JSON.stringify({ ok: true, skipped: true, reason: "already_processed", digestDate }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      }
      console.error("[notify-campaign-promo] mutex INSERT failed", error);
      return new Response(JSON.stringify({ error: "mutex insert failed", detail: error.message }), {
        status: 500, headers: { "content-type": "application/json" },
      });
    }
  }

  // 종료 시 runs UPDATE 헬퍼
  //   targetCount 는 첫 배치에서만 전달 (chained 배치는 잔여 인플만 반환하므로
  //   target_influencer_count 가 덮어씌워지면 실제 전체 대상자 수와 달라짐).
  const finalizeRun = async (payload: {
    status: "sent" | "partial" | "skipped_no_data" | "failed";
    targetCount?: number; // 첫 배치만 전달 — chained 배치는 컬럼 유지
    sentCount: number;
    skippedCount: number;
    failedCount: number;
    includedCampaignIds: string[];
    errorMessage?: string | null;
  }) => {
    const updateData: Record<string, unknown> = {
      status: payload.status,
      sent_count: payload.sentCount,
      skipped_count: payload.skippedCount,
      failed_count: payload.failedCount,
      included_campaign_ids: payload.includedCampaignIds,
      error_message: payload.errorMessage ?? null,
    };
    if (payload.targetCount !== undefined) {
      updateData.target_influencer_count = payload.targetCount;
    }
    const { error } = await sb
      .from("campaign_promo_digest_runs")
      .update(updateData)
      .eq("digest_date", digestDate);
    if (error) console.error("[notify-campaign-promo] finalize UPDATE failed", error);
  };

  try {
    // ── 2. 발송 대상자 조회 (RPC) ──
    //    RPC 가 이미 발송 완료 인플 자동 제외 → chained 재호출 시 잔여 인플만 반환
    const { data: targetsData, error: rpcError } = await sb.rpc("get_promo_digest_targets", {
      p_digest_date: digestDate,
    });
    if (rpcError) {
      console.error("[notify-campaign-promo] RPC error", rpcError);
      if (isFirstBatch) {
        await finalizeRun({
          status: "failed",
          targetCount: 0, sentCount: 0, skippedCount: 0, failedCount: 0,
          includedCampaignIds: [],
          errorMessage: `RPC get_promo_digest_targets: ${rpcError.message}`,
        });
      }
      return new Response(JSON.stringify({ error: rpcError.message, stage: "rpc" }), {
        status: 500, headers: { "content-type": "application/json" },
      });
    }
    const targets: PromoTarget[] = (targetsData || []) as PromoTarget[];
    console.log("[notify-campaign-promo] targets", { count: targets.length });

    // ── 3. 데이터 0건 처리 ──
    if (targets.length === 0) {
      if (isFirstBatch) {
        await finalizeRun({
          status: "skipped_no_data",
          targetCount: 0, sentCount: 0, skippedCount: 0, failedCount: 0,
          includedCampaignIds: [],
        });
      }
      return new Response(
        JSON.stringify({ ok: true, skipped: true, reason: "no_data", digestDate }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    }

    // ── 4. 캠페인 일괄 조회 + monitor approved count ──
    const campaignIdSet = new Set<string>();
    targets.forEach((t) => {
      (t.new_campaign_ids || []).forEach((id) => campaignIdSet.add(id));
      (t.deadline_d1_campaign_ids || []).forEach((id) => campaignIdSet.add(id));
    });
    const campaignIds = [...campaignIdSet];

    const campaignMap = new Map<string, CampaignRow>();
    if (campaignIds.length > 0) {
      const { data: camps, error: campError } = await sb
        .from("campaigns")
        .select("id, campaign_no, title, brand, brand_ko, recruit_type, deadline, slots, reward, img1")
        .in("id", campaignIds);
      if (campError) {
        console.warn("[notify-campaign-promo] campaign lookup failed", campError);
      } else {
        (camps || []).forEach((c: CampaignRow) => campaignMap.set(c.id, c));
      }
    }

    // monitor 캠페인에 대해서만 approved count 조회 (잔여 슬롯 표시용)
    const monitorCampIds = [...campaignMap.values()]
      .filter((c) => c.recruit_type === "monitor")
      .map((c) => c.id);
    const approvedMap = new Map<string, number>();
    if (monitorCampIds.length > 0) {
      const { data: apps, error: appError } = await sb
        .from("applications")
        .select("campaign_id")
        .in("campaign_id", monitorCampIds)
        .eq("status", "approved");
      if (appError) {
        console.warn("[notify-campaign-promo] approved count lookup failed", appError);
      } else {
        (apps || []).forEach((row: { campaign_id: string }) => {
          approvedMap.set(row.campaign_id, (approvedMap.get(row.campaign_id) || 0) + 1);
        });
      }
    }

    // ── 5. 배치 슬라이싱 ──
    const batchTargets = targets.slice(batchOffset, batchOffset + BATCH_SIZE);
    const hasMore = batchOffset + BATCH_SIZE < targets.length;
    console.log("[notify-campaign-promo] batch", {
      batchOffset, batchSize: batchTargets.length, hasMore, total: targets.length,
    });

    const publicAppUrl = env("PUBLIC_APP_URL", "https://globalreverb.com").replace(/\/$/, "");

    // ── 6. 직렬 발송 ──
    let batchSent = 0, batchSkipped = 0, batchFailed = 0;
    const batchFailures: { email: string; error: string }[] = [];

    for (const target of batchTargets) {
      // 이메일 없음 → skip
      if (!target.email) {
        const { error } = await sb.rpc("mark_promo_digest_sent", {
          p_influencer_id: target.influencer_id,
          p_digest_date: digestDate,
          p_status: "skipped",
          p_skip_reason: "no_email",
          p_error_message: null,
          p_included_campaign_ids: [],
        });
        if (error) console.warn("[notify-campaign-promo] mark skipped (no_email) failed", error);
        batchSkipped++;
        continue;
      }

      // 양쪽 섹션 모두 0건 → 스킵 (RPC 이미 필터링하지만 안전망)
      const newIds = target.new_campaign_ids || [];
      const d1Ids = target.deadline_d1_campaign_ids || [];
      if (newIds.length === 0 && d1Ids.length === 0) {
        const { error } = await sb.rpc("mark_promo_digest_sent", {
          p_influencer_id: target.influencer_id,
          p_digest_date: digestDate,
          p_status: "skipped",
          p_skip_reason: "no_matched_campaign",
          p_error_message: null,
          p_included_campaign_ids: [],
        });
        if (error) console.warn("[notify-campaign-promo] mark skipped (no_match) failed", error);
        batchSkipped++;
        continue;
      }

      // 메일 본문 렌더
      let mail: { html: string; subject: string; text: string };
      try {
        mail = renderMailBody({
          target,
          campaignMap,
          approvedMap,
          publicAppUrl,
          todayKst,
        });
      } catch (e) {
        const msg = (e as Error).message || "render error";
        console.error("[notify-campaign-promo] render failed", target.influencer_id, msg);
        await sb.rpc("mark_promo_digest_sent", {
          p_influencer_id: target.influencer_id,
          p_digest_date: digestDate,
          p_status: "failed",
          p_skip_reason: null,
          p_error_message: `render: ${msg}`,
          p_included_campaign_ids: [],
        });
        batchFailed++;
        batchFailures.push({ email: target.email, error: msg });
        continue;
      }

      // Brevo 발송
      try {
        await sendBrevoEmail({
          to: [{ email: target.email, name: target.name || undefined }],
          subject: mail.subject,
          htmlContent: mail.html,
          textContent: mail.text,
        });
      } catch (e) {
        const msg = (e as Error).message || "brevo send error";
        console.error("[notify-campaign-promo] send failed", target.email, msg);
        await sb.rpc("mark_promo_digest_sent", {
          p_influencer_id: target.influencer_id,
          p_digest_date: digestDate,
          p_status: "failed",
          p_skip_reason: null,
          p_error_message: msg,
          p_included_campaign_ids: [],
        });
        batchFailed++;
        batchFailures.push({ email: target.email, error: msg });
        await sleep(BREVO_SLEEP_MS);
        continue;
      }

      // 노출 기록 INSERT (멱등 — UNIQUE 충돌 시 무시)
      const exposureRows: { campaign_id: string; influencer_id: string; kind: "new" | "deadline_d1" }[] = [
        ...newIds.map((cid) => ({ campaign_id: cid, influencer_id: target.influencer_id, kind: "new" as const })),
        ...d1Ids.map((cid) => ({ campaign_id: cid, influencer_id: target.influencer_id, kind: "deadline_d1" as const })),
      ];
      if (exposureRows.length > 0) {
        const { error: expError } = await sb
          .from("campaign_promo_exposure")
          .upsert(exposureRows, {
            onConflict: "campaign_id,influencer_id,kind",
            ignoreDuplicates: true,
          });
        if (expError) {
          // 노출 INSERT 실패해도 메일은 이미 발송 → 경고만, sent 처리는 계속
          console.warn("[notify-campaign-promo] exposure insert failed", target.influencer_id, expError);
        }
      }

      // 발송 결과 기록
      const includedIds = [...newIds, ...d1Ids];
      const { error: markError } = await sb.rpc("mark_promo_digest_sent", {
        p_influencer_id: target.influencer_id,
        p_digest_date: digestDate,
        p_status: "sent",
        p_skip_reason: null,
        p_error_message: null,
        p_included_campaign_ids: includedIds,
      });
      if (markError) console.warn("[notify-campaign-promo] mark sent failed", markError);

      batchSent++;
      await sleep(BREVO_SLEEP_MS);
    }

    console.log("[notify-campaign-promo] batch result", {
      batchOffset, batchSent, batchSkipped, batchFailed,
    });

    // ── 7. chained 자기재호출 (fire-and-forget) ──
    if (hasMore) {
      selfInvokeChained({
        supaUrl, serviceKey, digestDate,
        nextOffset: batchOffset + BATCH_SIZE,
      });
    }

    // ── 8. finalizeRun (배치 누적 집계) ──
    //    매 배치마다 SUM 으로 재집계 → chained 도 안전한 누적 카운트
    const { data: sumRows, error: sumError } = await sb
      .from("campaign_promo_digest_sent")
      .select("status")
      .eq("digest_date", digestDate);
    let cumSent = 0, cumSkipped = 0, cumFailed = 0;
    if (sumError) {
      console.warn("[notify-campaign-promo] sum SELECT failed", sumError);
      cumSent = batchSent; cumSkipped = batchSkipped; cumFailed = batchFailed;
    } else {
      (sumRows || []).forEach((r: { status: string }) => {
        if (r.status === "sent") cumSent++;
        else if (r.status === "skipped") cumSkipped++;
        else if (r.status === "failed") cumFailed++;
      });
    }

    // status 결정
    let finalStatus: "sent" | "partial" | "failed" | "skipped_no_data" = "sent";
    if (hasMore) {
      finalStatus = "partial"; // 진행 중
    } else if (cumSent === 0 && cumFailed === 0 && cumSkipped === 0) {
      finalStatus = "skipped_no_data";
    } else if (cumSent > 0 && cumFailed === 0) {
      finalStatus = "sent";
    } else if (cumSent === 0 && cumFailed > 0) {
      finalStatus = "failed";
    } else {
      finalStatus = "partial";
    }

    // included_campaign_ids — 전체 캠페인 ID 합집합 (캐싱은 첫 배치에 한 번 + 매 배치 동일)
    // 단순화: 매번 캠페인 ID 합집합으로 UPDATE (총수는 같음)
    const includedCampaignIds = campaignIds;

    const errMsg = batchFailures.length > 0
      ? `batch@${batchOffset}: ${batchFailures.length} failure(s). first: ${batchFailures[0].email}(${batchFailures[0].error})`
      : null;

    await finalizeRun({
      status: finalStatus,
      // 첫 배치만 target_influencer_count 갱신 — chained 배치는 RPC 가 잔여 인플만 반환하므로 덮어쓰지 않음
      targetCount: isFirstBatch ? targets.length : undefined,
      sentCount: cumSent,
      skippedCount: cumSkipped,
      failedCount: cumFailed,
      includedCampaignIds,
      errorMessage: errMsg,
    });

    console.log("[notify-campaign-promo] done", {
      digestDate, batchOffset, batchSize: batchTargets.length, hasMore,
      cumSent, cumSkipped, cumFailed, finalStatus,
    });

    return new Response(
      JSON.stringify({
        ok: true,
        digestDate,
        batchOffset,
        batchSize: batchTargets.length,
        hasMore,
        batchSent, batchSkipped, batchFailed,
        cumSent, cumSkipped, cumFailed,
        finalStatus,
      }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  } catch (e) {
    const msg = (e as Error).message || "unknown error";
    console.error("[notify-campaign-promo] unexpected error", msg);
    if (isFirstBatch) {
      try {
        await finalizeRun({
          status: "failed",
          targetCount: 0, sentCount: 0, skippedCount: 0, failedCount: 0,
          includedCampaignIds: [],
          errorMessage: `unexpected: ${msg}`,
        });
      } catch (_finalizeErr) {
        console.error("[notify-campaign-promo] could not finalize after unexpected error");
      }
    }
    return new Response(JSON.stringify({ error: msg, stage: "unexpected" }), {
      status: 500, headers: { "content-type": "application/json" },
    });
  }
});
