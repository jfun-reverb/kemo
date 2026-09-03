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
//      ⚠️ 이 RPC 는 그날 이미 기록된(campaign_promo_digest_sent 행이 있는) 인플을
//         제외한 「남은 사람만」 돌려준다 — 호출할 때마다 명단이 줄어드는 구조.
//         그래서 매 라운드 항상 앞에서부터 200명을 자른다(옛 offset 이동 금지 —
//         이미 줄어든 명단에 또 offset 을 더하면 한 무리가 통째로 안 뽑힌다. 마이그321 배경).
//   2.5. 정체 감지 (이어달리기 2회차부터) — 직전 라운드 시작 시점 잔여 인원과 비교해
//        줄지 않았으면 즉시 중단(아래 「무한 반복 방어」 참고)
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
// 무한 반복 방어 (2026-08 전수조사 C-3):
//   - 명단이 스스로 줄어드는 구조라, mark_promo_digest_sent 기록이 계속 실패하면
//     같은 사람이 명단에서 안 빠져 같은 배치가 영원히 되풀이될 수 있다(그러면 같은
//     사람에게 메일이 여러 번 나갈 위험도 같이 커진다).
//   - [정체 감지 — 1차 방어] 매 이어달리기마다 「직전 라운드 시작 시점의 잔여 인원 수」를
//     다음 호출에 실어 보낸다(prevRemainingCount). 새로 받은 명단 수가 그보다 줄지
//     않았으면 — 즉 직전 라운드가 아무도 못 줄였으면 — 그 자리에서 즉시 멈춘다.
//     같은 무리를 반복 발송하기 전(최대 1라운드 지연)에 걸러내는 게 목적.
//   - [이어달리기 횟수 상한 — 2차 방어] 그래도 못 잡는 경우를 대비해 MAX_CHAIN_COUNT 로
//     절대 상한을 둔다. 도달하면 원인 불문 멈추고 사유를 error_message 에 남긴다.
//   - 둘 다 걸려도 정상 흐름(전원 처리 완료로 자연 종료)에는 전혀 영향 없다.
//   - ⚠️ 정체 감지가 잡는 것은 「라운드 전체가 안 줄어드는」 경우뿐이다. 200명 중
//     몇 명만 기록에 실패하면 전체 잔여는 정상적으로 줄어 감지에 안 걸리는데,
//     그 몇 명은 다음 라운드에 다시 뽑혀 메일을 또 받는다(마이그321 이 명단 정렬을
//     고정한 뒤로는 같은 앞쪽 자리에 남아 거의 곧바로 재발송된다). 그래서 발송 기록은
//     실패 시 한 번 재시도하고, 두 번 다 실패하면 console.error 로 남긴다(아래 발송 루프).
//
// 부분 실패 (사양서 §4-3):
//   - 전부 성공 → status='sent'
//   - 일부 실패 → status='partial'
//   - 전부 실패 → status='failed'
//   - 데이터 0건 → status='skipped_no_data'
//   - 정체 감지·상한 도달로 조기 중단 → status='partial'(일부라도 보냈으면) 또는 'failed'
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

// 이어달리기(자기재호출) 최대 횟수 — 무한 반복 2차 방어(위 파일 상단 주석 참고).
// 200명 × 약 101라운드 ≒ 2만 명까지 커버 — 현재 대상자(약 1,400명) 대비 넉넉한 여유.
// 정상 흐름에서는 절대 이 값까지 도달하지 않는다(대상자가 아무리 늘어도 전원
// 처리 완료 시 hasMore 가 false 로 떨어져 이어달리기가 스스로 멈춘다). 오직
// 「명단이 안 줄어드는 이상 상황」이 정체 감지(1차 방어)를 뚫고도 계속될 때만
// 이 상한이 개입한다.
const MAX_CHAIN_COUNT = 100;

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
// [F-4] 1,000행 응답 상한 대응 — 여러 페이지로 나눠 전부 가져오는 공용 도우미.
//   dev/lib/storage.js 의 fetchAllPaged() 와 같은 패턴(이 프로젝트의 Edge
//   Function 은 파일끼리 공유 모듈이 없어 함수마다 각자 들고 있음). 하루
//   안에서도 발송이 진행될수록 계속 쌓이는 조회(campaign_promo_digest_sent
//   누적 집계)에 사용. buildQuery 는 호출마다 새 쿼리 빌더를 만들어야 하고,
//   반드시 안정적인 정렬(id 오름차순)이 걸려 있어야 한다.
// ──────────────────────────────────────────────────────────────────
async function fetchAllPaged<T>(
  buildQuery: () => { range: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }> },
  pageSize = 1000,
): Promise<T[]> {
  const all: T[] = [];
  let from = 0;
  while (true) {
    const { data, error } = await buildQuery().range(from, from + pageSize - 1);
    if (error) throw new Error(error.message);
    if (!data || data.length === 0) break;
    all.push(...data);
    if (data.length < pageSize) break;
    from += pageSize;
  }
  return all;
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
// 리워드 텍스트 — dev/js/admin.js rewardText 패턴 미러
//   - product_price>0: 「¥N ペイバック」(monitor) 또는 「¥N 商品提供」
//   - product_price<=0: 「商品無償提供」
//   - reward>0: 「+ ¥M 報酬」 추가
// ──────────────────────────────────────────────────────────────────
function formatYenLabel(n: number | null | undefined): string {
  if (n == null || !Number.isFinite(Number(n))) return "";
  return `¥${Math.round(Number(n)).toLocaleString("ja-JP")}`;
}

function buildRewardText(camp: CampaignRow): string {
  const price = Number(camp.product_price ?? 0);
  const cash  = Number(camp.reward ?? 0);
  if (price <= 0 && cash <= 0) return "-";

  const parts: string[] = [];
  if (price > 0) {
    // レビュアー型は 294 以降「レシート実支払額（商品価格を上限に切り捨て）」なので、
    // 金額を約束する言い方をしない。アプリ側の詳細ページと同じ全体形の文言を使う
    // （メールと画面で違うことを言うと、応募前に見た約束が食い違う）。
    if (camp.recruit_type === "monitor") {
      parts.push(`購入金額をペイバック（最大 ${formatYenLabel(price)}）`);
    } else {
      parts.push(`${formatYenLabel(price)} 商品提供`);
    }
  } else {
    parts.push("商品無償提供");
  }
  // ⚠️ レビュアー型には現金報酬を足さない — 精算計算が monitor で campaigns.reward を
  //    使わないため（マイグレーション300）、足すと支払われない金額の約束になる。
  //    アプリの詳細ページ・管理者プレビューと同じ判断（2026-08-05）。
  if (cash > 0 && camp.recruit_type !== "monitor") {
    parts.push(`${formatYenLabel(cash)} 報酬`);
  }
  return parts.join(" + ");
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
// Supabase Storage transform 적용 — dev/js/ui.js imgThumb 패턴 미러
//   /storage/v1/object/public/... → /storage/v1/render/image/public/...?width=200&height=200&quality=75&resize=cover
//   외부 URL 은 그대로 반환 (Supabase 외부 호스팅도 호환).
// ──────────────────────────────────────────────────────────────────
function imgThumbSquare(url: string | null, size = 200, quality = 75): string | null {
  if (!url || typeof url !== "string") return url;
  if (!url.includes("/storage/v1/object/public/")) return url;
  const renderUrl = url.replace("/storage/v1/object/public/", "/storage/v1/render/image/public/");
  return `${renderUrl}?width=${size}&height=${size}&quality=${quality}&resize=cover`;
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
  // reward / product_price 는 integer (엔 단위). reward_note 는 자유 텍스트.
  // dev/js/admin.js rewardText 로직과 동일하게 「商品無償提供 + ¥N 報酬」 형태로 조합.
  reward: number | null;
  product_price: number | null;
  reward_note: string | null;
  img1: string | null;
}

interface RequestBody {
  source?: "cron" | "manual" | "chained";
  digestDate?: string;
  // 이어달리기 횟수 — 0 = 최초 호출(cron/manual), 1 이상 = 자기재호출(chained).
  // 옛 batchOffset(명단 위치 오프셋)을 대체. 명단이 매번 「남은 사람만」으로
  // 줄어드는 구조라 위치가 아니라 횟수로 진행 상황을 센다(위 파일 상단 주석 참고).
  chainCount?: number;
  // 직전 라운드가 시작할 때 남아있던 인원 수 — 정체 감지(1차 방어)에만 사용.
  // chainCount=0(최초 호출)에는 없음.
  prevRemainingCount?: number;
  // [리뷰 반영 1/2026-08] 이 실행 계열이 "소유"하고 있는 campaign_promo_digest_runs.
  // started_at 값 — 첫 배치가 mutex 를 잡을 때 확정(새 INSERT 로 생겼으면 그
  // 값, 재시도로 가로챘으면 새로 써넣은 값)해서 매 자기재호출마다 그대로
  // 넘긴다. 각 라운드(hop)가 자기 finalizeRun 호출 때 이 값으로 소유권을
  // 재확인한다 — 넘기지 않으면, 죽은 줄 알고 다른 프로세스가 이 자리를
  // 가로챈 뒤에도 원래 체인의 남은 라운드들이 그걸 모른 채 계속 상태를
  // 덮어쓸 수 있다.
  startedAt?: string;
  // 운영 디버그 — testRecipient 지정 시 자격 매칭 우회 + 단일 수신자 강제 발송.
  // mutex/RPC/exposure/digest_sent 모두 스킵. service_role 인증 필수.
  testRecipient?: string;
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
  // Supabase Storage transform 적용: /object/public/ → /render/image/public/ + 200x200 cover.
  // fallback 은 PNG 필수 (Gmail 등 SVG 미지원).
  const imgUrl = imgThumbSquare(imgRaw, 200, 75)
    ?? "https://dummyimage.com/200x200/eeeeee/888888.png&text=No+Image";

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
  const reward = buildRewardText(camp);
  const deadlineLabel = deadlineLabelJa(camp.deadline, args.todayKst);

  return render(args.rowTpl, {
    img_url: escapeHtml(imgUrl),
    img_alt: escapeHtml(camp.title || "キャンペーン画像"),
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
    agreed_at_label: "このメールは、マーケティング情報の配信にご同意いただいた方にお送りしています",
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
  // 수신거부 안내 — 일본 특정전자메일법 요구. HTML 을 못 읽는 환경에도 반드시 남아야 한다
  textLines.push("");
  textLines.push(`配信停止: ${unsubscribeUrl}`);
  textLines.push(`メール受信設定: ${mypageSettingsUrl}`);
  const text = textLines.join("\n");

  return { html, subject, text };
}

// ──────────────────────────────────────────────────────────────────
// 관리자용 홍보 메일 본문 렌더 (관리자 1명당 1통, 그날 캠페인 풀 전체)
//   인플 본문과 달리 개인화 인사·수신거부·클릭 추적 토큰 없음.
//   섹션·카드 렌더 헬퍼는 인플 것 재사용 (token 은 빈 문자열 — 추적 안 함).
//   머리말·제목·푸터는 한국어, 카드 본문은 원본 일본어.
// ──────────────────────────────────────────────────────────────────
function renderAdminPromoMailBody(args: {
  newCampaignIds: string[];
  newTotalCount: number;
  d1CampaignIds: string[];
  d1TotalCount: number;
  campaignMap: Map<string, CampaignRow>;
  approvedMap: Map<string, number>;
  publicAppUrl: string;
  todayKst: string;
}): { html: string; subject: string; text: string } {
  const mainTpl = loadTemplate("campaign-promo-digest.admin");
  const sectionTpl = loadTemplate("campaign-promo-digest.section");
  const rowTpl = loadTemplate("campaign-promo-digest.row-campaign");

  const newSectionHtml = renderSection({
    sectionTpl, rowTpl,
    title: "新着キャンペーン",
    color: "#C8789C",
    campaignIds: args.newCampaignIds,
    totalCount: args.newTotalCount,
    campaignMap: args.campaignMap,
    approvedMap: args.approvedMap,
    token: "",
    publicAppUrl: args.publicAppUrl,
    todayKst: args.todayKst,
    showD1Chip: false,
  });

  const deadlineSectionHtml = renderSection({
    sectionTpl, rowTpl,
    title: "締切間近キャンペーン",
    color: "#E8344E",
    campaignIds: args.d1CampaignIds,
    totalCount: args.d1TotalCount,
    campaignMap: args.campaignMap,
    approvedMap: args.approvedMap,
    token: "",
    publicAppUrl: args.publicAppUrl,
    todayKst: args.todayKst,
    showD1Chip: true,
  });

  const html = render(mainTpl, {
    new_count: String(args.newTotalCount),
    d1_count: String(args.d1TotalCount),
    new_section_html: newSectionHtml,
    deadline_section_html: deadlineSectionHtml,
  });

  const n = args.newTotalCount;
  const d = args.d1TotalCount;
  let subject: string;
  if (n > 0 && d > 0) {
    subject = `[REVERB JP 관리자] 오늘의 홍보 캠페인 신규${n}건 / 마감임박${d}건`;
  } else if (n > 0) {
    subject = `[REVERB JP 관리자] 오늘의 홍보 캠페인 신규${n}건`;
  } else {
    subject = `[REVERB JP 관리자] 오늘의 홍보 캠페인 마감임박${d}건`;
  }

  const textLines = [
    "오늘 인플루언서에게 발송된 홍보 대상 캠페인입니다 (운영 참고용).",
  ];
  if (n > 0) textLines.push(`· 신규: ${n}건`);
  if (d > 0) textLines.push(`· 마감임박(D-1): ${d}건`);
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
  chainCount: number;
  prevRemainingCount: number;
  // [리뷰 반영 1] 이 라운드가 소유한 started_at — 다음 라운드에 그대로 넘겨
  // 소유권 검증을 이어가게 한다(RequestBody.startedAt 주석 참고).
  startedAt: string | null;
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
      chainCount: args.chainCount,
      prevRemainingCount: args.prevRemainingCount,
      ...(args.startedAt != null ? { startedAt: args.startedAt } : {}),
    }),
  }).catch((e) => {
    console.error("[notify-campaign-promo] chained invoke failed", e);
  });
}

// ──────────────────────────────────────────────────────────────────
// Main handler
// ──────────────────────────────────────────────────────────────────

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
function isAnonJwt(token: string): boolean {
  if (!token.startsWith("eyJ")) return false;
  const parts = token.split(".");
  if (parts.length !== 3) return false;
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const payload = JSON.parse(atob(b64 + "=".repeat((4 - (b64.length % 4)) % 4)));
    return payload?.role === "anon";
  } catch {
    return false;   // 못 읽으면 막지 않는다 — 정상 발송을 세우는 쪽이 더 나쁘다
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
  if (isAnonJwt(token)) {
    console.warn(`[${tag}] rejected — called with a legacy anon JWT`);
    return true;
  }
  // 토큰 자체는 절대 남기지 않는다.
  const isServiceRole = token === (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
  console.log(`[${tag}] caller check passed`, { isServiceRole });
  return false;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
  if (rejectPublicKeyCaller(req, "notify-campaign-promo-digest")) {
    return new Response(JSON.stringify({ error: "forbidden" }), {
      status: 403,
      headers: { "content-type": "application/json" },
    });
  }

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
  const chainCount = body.chainCount ?? 0;
  const isFirstBatch = chainCount === 0;
  const todayKst = digestDate; // 컬럼명 동일 — RPC 가 이미 KST 윈도우 기준 처리

  console.log("[notify-campaign-promo] start", { source, digestDate, chainCount, isFirstBatch });

  // ── 0. testRecipient 모드 (운영 디버그) ─────────────────────────
  //   body.testRecipient 가 있으면 자격 매칭 / mutex / 로그 모두 우회.
  //   현재 active 캠페인 최대 5개를 신규 섹션 카드로 채워 단일 수신자에게 발송.
  //   PR 5 cron 등록 전 메일 본문 깨짐 검증용. service_role 인증 필수라 외부 anon 위험 없음.
  if (body.testRecipient) {
    try {
      const publicAppUrl = env("PUBLIC_APP_URL", "https://globalreverb.com").replace(/\/$/, "");

      const { data: camps, error: campError } = await sb
        .from("campaigns")
        .select("id, campaign_no, title, brand, brand_ko, recruit_type, deadline, slots, reward, product_price, reward_note, img1")
        .eq("status", "active")
        .order("deadline", { ascending: true })
        .limit(5);
      if (campError) throw new Error(`campaigns lookup: ${campError.message}`);

      const campaignMap = new Map<string, CampaignRow>();
      (camps || []).forEach((c: CampaignRow) => campaignMap.set(c.id, c));
      const newIds = (camps || []).map((c: CampaignRow) => c.id);

      // monitor 슬롯 표시용 approved count 조회 (있으면 더 정확한 본문)
      const monitorIds = (camps || []).filter((c) => c.recruit_type === "monitor").map((c) => c.id);
      const approvedMap = new Map<string, number>();
      if (monitorIds.length > 0) {
        const { data: apps } = await sb
          .from("applications")
          .select("campaign_id")
          .in("campaign_id", monitorIds)
          .eq("status", "approved");
        (apps || []).forEach((row: { campaign_id: string }) => {
          approvedMap.set(row.campaign_id, (approvedMap.get(row.campaign_id) || 0) + 1);
        });
      }

      const fakeTarget: PromoTarget = {
        influencer_id: "00000000-0000-0000-0000-000000000000",
        email: body.testRecipient,
        name: "テスト",
        unsubscribe_token: "00000000-0000-0000-0000-000000000000",
        new_campaign_ids: newIds,
        deadline_d1_campaign_ids: [],
        new_total_count: newIds.length,
        deadline_d1_total_count: 0,
      };

      const mail = renderMailBody({
        target: fakeTarget,
        campaignMap,
        approvedMap,
        publicAppUrl,
        todayKst,
      });

      await sendBrevoEmail({
        to: [{ email: body.testRecipient, name: "テスト" }],
        subject: `[TEST] ${mail.subject}`,
        htmlContent: mail.html,
        textContent: mail.text,
      });

      return new Response(
        JSON.stringify({
          ok: true,
          test: true,
          recipient: body.testRecipient,
          campaignCount: newIds.length,
          digestDate,
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    } catch (e) {
      const msg = (e as Error).message || "test send error";
      console.error("[notify-campaign-promo] test send failed", msg);
      return new Response(
        JSON.stringify({ ok: false, test: true, error: msg }),
        { status: 500, headers: { "content-type": "application/json" } },
      );
    }
  }

  // ── 1. INSERT mutex (첫 배치만) ──
  //    triggered_by 는 마이그레이션 139 에서 uuid REFERENCES auth.users(id) 타입이라
  //    cron 자동 실행은 null 로 저장 (운영자 수동 트리거 구현은 후속 PR 영역).
  //    'cron' / 'manual' / 'chained' 같은 문자열을 넣으면 22P02 (uuid 캐스트 실패).
  //
  //    [F-5, 2026-08] 예전엔 23505(이미 있음) 를 만나면 무조건 "이미 처리됨"
  //    으로 끝냈다. 이 함수는 다른 세 다이제스트와 달리 자기재호출(체이닝)
  //    로 여러 라운드에 걸쳐 오래 돈다 — 그래서 "얼마나 지나야 죽었다고
  //    볼지"를 단순 시간 상수 하나로만 판단하면 위험하다: 너무 짧으면
  //    실제로 살아서 이어달리는 중인 첫 배치를 죽었다고 오판해 새 첫 배치를
  //    또 띄우고, 그러면 두 프로세스가 동시에 발송 대상자를 뽑아 같은
  //    사람에게 메일이 두 번 나갈 위험이 생긴다(get_promo_digest_targets
  //    는 "그날 아직 기록 안 된 사람"만 주는데, 기록이 나기 전 짧은 틈에
  //    두 프로세스가 같은 사람을 동시에 뽑을 수 있음).
  //
  //    그래서 "지금 이 순간 살아있는지"를 판단할 때 최초 시작 시각
  //    (started_at, 라운드가 몇 번을 거쳐도 안 바뀜)이 아니라 "가장 최근
  //    실제로 한 일" — campaign_promo_digest_sent 에 이 digest_date 로
  //    찍힌 가장 최근 sent_at(발송/스킵/실패 결과가 남을 때마다 갱신됨,
  //    한 명 처리에 1초가 안 걸림) — 을 심장박동으로 쓴다. 아직 한 명도
  //    처리 못 하고 죽었으면 started_at 으로 대체.
  //
  //    STALE_MS = 15분 — 한 라운드(BATCH_SIZE=200명)의 정상 처리 상한은
  //    이 파일 상단 주석 기준 약 120초, Deno 실행 시간 상한은 약 150초
  //    (notify-policy-change 등 이 저장소의 다른 체이닝 함수와 동일 가정).
  //    라운드 사이 자기재호출(fire-and-forget)이 콜드스타트로 늦어지는
  //    여유까지 감안해도 15분은 그 상한의 6배 이상 — 실제로 살아있는
  //    체인과 충돌할 가능성을 사실상 배제하면서, 죽은 체인은 당일 안에
  //    회복 가능하다.
  const STALE_MS = 15 * 60 * 1000;
  // [리뷰 반영 1/2026-08] "내가 지금 이 실행 계열의 주인"임을 매 라운드
  // finalizeRun 까지 들고 갈 값. 체이닝 구조라 admin/brand/influencer
  // 세 함수와 달리 첫 배치가 잡은 뒤 매 자기재호출(hop)마다 body.startedAt
  // 으로 이어받는다(RequestBody.startedAt 주석 참고) — 안 그러면 15분
  // 판단이 틀려서(정상 실행이 우연히 그보다 오래 걸려서) 재시도가 소유권을
  // 가로챈 뒤에도, 원래 체인의 남은 라운드들이 그걸 모른 채 자기 결과로
  // 최종 상태를 계속 덮어쓸 수 있다.
  let ownedStartedAt: string | null = null;
  if (isFirstBatch) {
    const { data: inserted, error } = await sb
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
      })
      .select("started_at")
      .maybeSingle();
    if (error) {
      if ((error as { code?: string }).code === "23505") {
        const { data: existing, error: selErr } = await sb
          .from("campaign_promo_digest_runs")
          .select("status, started_at, finished_at")
          .eq("digest_date", digestDate)
          .maybeSingle();
        if (selErr || !existing) {
          console.error("[notify-campaign-promo] existing row lookup failed after 23505", selErr);
          return new Response(
            JSON.stringify({ ok: true, skipped: true, reason: "already_processed", digestDate }),
            { status: 200, headers: { "content-type": "application/json" } },
          );
        }
        // 끝난 상태 판정: sent/skipped_no_data 는 상태만으로 끝. partial/failed 는
        // finished_at 이 찍혀야 진짜로 끝난 것 — finished_at 이 NULL 이면 아직
        // 체이닝 중이거나(정상) 라운드 사이에 죽었을 수 있다(비정상, 아래서 판단).
        const isTerminal =
          existing.status === "sent" ||
          existing.status === "skipped_no_data" ||
          existing.finished_at != null;
        if (isTerminal) {
          console.log("[notify-campaign-promo] already processed (terminal)", digestDate, existing.status);
          return new Response(
            JSON.stringify({ ok: true, skipped: true, reason: "already_processed", digestDate, priorStatus: existing.status }),
            { status: 200, headers: { "content-type": "application/json" } },
          );
        }
        // 아직 안 끝남 — "살아있는지" 최근 활동(heartbeat)으로 판단.
        // 한 명도 처리 못 하고 죽었으면 sent 로그가 없으니 started_at 으로 대체.
        const { data: lastSentRow } = await sb
          .from("campaign_promo_digest_sent")
          .select("sent_at")
          .eq("digest_date", digestDate)
          .order("sent_at", { ascending: false })
          .limit(1)
          .maybeSingle();
        const heartbeatIso = (lastSentRow?.sent_at as string | undefined) ?? (existing.started_at as string);
        const elapsedMs = Date.now() - new Date(heartbeatIso).getTime();
        if (elapsedMs < STALE_MS) {
          // 아직 실행 중일 가능성을 배제 못 함 — 재시도하지 않고 대기 안내만
          console.log("[notify-campaign-promo] recent activity, still possibly running — skip retry", {
            digestDate, elapsedMs, staleMs: STALE_MS, heartbeatIso,
          });
          return new Response(
            JSON.stringify({ ok: true, skipped: true, reason: "recent_activity_cooldown", digestDate, elapsedMs }),
            { status: 200, headers: { "content-type": "application/json" } },
          );
        }
        // 15분 넘게 활동 없음 — 죽은 것으로 보고 조건부 UPDATE 로 "내가 이어받는다" 시도.
        // 낙관적 락: 직전에 읽은 started_at 값이 그대로일 때만 통과 → 동시에 재시도가
        // 들어와도 먼저 커밋한 쪽만 통과(started_at 을 새 시각으로 바꿔 써서 나머지는
        // 조건 불일치로 0행 UPDATE).
        const retryStartedAt = new Date().toISOString();
        const { data: claimed, error: claimErr } = await sb
          .from("campaign_promo_digest_runs")
          .update({
            status: "failed",
            error_message: "in-flight (retry)",
            started_at: retryStartedAt,
            finished_at: null,
          })
          .eq("digest_date", digestDate)
          .eq("started_at", existing.started_at as string)
          .select("id");
        if (claimErr || !claimed || claimed.length === 0) {
          console.log("[notify-campaign-promo] lost retry race or already claimed", digestDate, claimErr);
          return new Response(
            JSON.stringify({ ok: true, skipped: true, reason: "retry_race_lost", digestDate }),
            { status: 200, headers: { "content-type": "application/json" } },
          );
        }
        ownedStartedAt = retryStartedAt; // 방금 내가 써넣은 값 — finalizeRun·다음 hop 의 소유권 조건으로 재사용
        console.warn("[notify-campaign-promo] retrying stale/dead chain", digestDate, {
          priorStartedAt: existing.started_at, elapsedMs,
        });
        // 아래로 흘러 정상 처리 진행 (isFirstBatch=true 그대로 — 첫 배치처럼 다시 시작)
      } else {
        console.error("[notify-campaign-promo] mutex INSERT failed", error);
        return new Response(JSON.stringify({ error: "mutex insert failed", detail: error.message }), {
          status: 500, headers: { "content-type": "application/json" },
        });
      }
    } else {
      ownedStartedAt = (inserted?.started_at as string | undefined) ?? null;
      if (!ownedStartedAt) {
        console.error("[notify-campaign-promo] mutex INSERT succeeded but started_at missing from response — ownership check disabled for this run", digestDate);
      }
    }
  } else {
    // 체이닝 호출(chainCount>0) — 이전 라운드가 넘겨준 소유권 값을 이어받는다.
    // selfInvokeChained 가 항상 startedAt 을 실어 보내므로 정상 흐름에서는
    // 비어있을 수 없다 — 비어있으면 이 호출이 어디서 왔는지부터 의심할 것.
    ownedStartedAt = body.startedAt ?? null;
    if (!ownedStartedAt) {
      console.error("[notify-campaign-promo] chained call missing startedAt in body — ownership check disabled for this hop", digestDate, chainCount);
    }
  }

  // 종료 시 runs UPDATE 헬퍼
  //   targetCount 는 첫 배치에서만 전달 (chained 배치는 잔여 인플만 반환하므로
  //   target_influencer_count 가 덮어씌워지면 실제 전체 대상자 수와 달라짐).
  //   finishedAt 은 마지막 배치 또는 즉시 종료 시점에만 기록 (chained 중간은 NULL 유지).
  //
  // [리뷰 반영 1] mutex 를 "잡을 때"는 started_at 조건부 UPDATE 로 소유권을
  // 확인하면서 "끝낼 때"(finalizeRun)는 digest_date 로만 UPDATE 했었다 —
  // 자기가 그 실행(계열)의 주인인지 다시 확인하지 않았다. STALE_MS(15분)
  // 는 검증 안 된 실행시간 가정에 기대므로, 실제 실행이 그보다 오래
  // 걸리면 재시도가 오판해 소유권을 가져가고 원본·재시도가 둘 다 계속
  // 돌 수 있다. ownedStartedAt 이 있으면 그 값으로도 조건을 걸고, 0행이면
  // (그 사이 다른 실행이 started_at 을 바꿔써서 내가 더 이상 주인이 아니면)
  // 덮어쓰지 않고 console.error 로만 남긴다. 이미 나간 메일은 못 되돌리지만
  // 최소한 잘못된 최종 상태 기록은 막는다.
  const finalizeRun = async (payload: {
    status: "sent" | "partial" | "skipped_no_data" | "failed";
    targetCount?: number; // 첫 배치만 전달 — chained 배치는 컬럼 유지
    sentCount: number;
    skippedCount: number;
    failedCount: number;
    includedCampaignIds: string[];
    errorMessage?: string | null;
    finishedAt?: string; // hasMore 면 undefined (NULL 유지)
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
    if (payload.finishedAt !== undefined) {
      updateData.finished_at = payload.finishedAt;
    }
    let q = sb
      .from("campaign_promo_digest_runs")
      .update(updateData)
      .eq("digest_date", digestDate);
    if (ownedStartedAt != null) q = q.eq("started_at", ownedStartedAt);
    const { data, error } = await q.select("id");
    if (error) {
      console.error("[notify-campaign-promo] finalize UPDATE failed", error);
      return;
    }
    if (ownedStartedAt != null && (!data || data.length === 0)) {
      console.error(
        "[notify-campaign-promo] finalizeRun: 소유권을 잃어 최종 상태를 기록하지 못함(started_at 불일치) — 덮어쓰지 않음",
        digestDate, chainCount, ownedStartedAt, payload.status,
      );
    }
  };

  try {
    const publicAppUrl = env("PUBLIC_APP_URL", "https://globalreverb.com").replace(/\/$/, "");

    // ── 1.5 관리자 발송 (첫 배치만) ──
    //   사양서 §2-3: 인플 대상자가 0명이어도 그날 캠페인 풀이 있으면 관리자는 받아야 하므로
    //   인플 0건 조기 종료(아래 ── 3)보다 앞에 둔다. 관리자는 자격 매칭 없이 풀 전체를 받는다.
    //   실패는 자체 try/catch 로 격리 — 인플 발송을 막지 않는다.
    //
    // [리뷰 반영 3] ⚠️ 잔여 위험 — 이 관리자 요약 메일은 "누구에게 보냈는지"
    // 개별 기록이 없고, isFirstBatch 일 때마다(=이번 실행이 첫 배치로
    // 취급될 때마다) 무조건 다시 돈다. 인플 발송은 campaign_promo_digest_sent
    // 로 재시도 중복이 막혀 있지만, 이 블록만은 그 표를 안 거친다 — 그래서
    // 정상 완료된 실행이 나중에(15분 STALE_MS 판단이 틀려서) "죽었다"고
    // 오판돼 재시도로 다시 첫 배치 취급되면, 관리자들은 같은 날의 홍보
    // 요약 메일을 두 번 받는다. 수동 재시도 전에 Brevo 발송 이력으로
    // 이 실행이 이미 관리자 요약을 보냈는지 먼저 확인할 것.
    if (isFirstBatch) {
      try {
        const { data: poolData, error: poolErr } = await sb.rpc("get_promo_digest_campaign_pool", {
          p_digest_date: digestDate,
        });
        if (poolErr) throw poolErr;
        const pool = (poolData?.[0]) as {
          new_campaign_ids: string[]; new_total_count: number;
          deadline_d1_campaign_ids: string[]; deadline_d1_total_count: number;
        } | undefined;
        const adminNewIds = pool?.new_campaign_ids ?? [];
        const adminD1Ids = pool?.deadline_d1_campaign_ids ?? [];

        if (adminNewIds.length === 0 && adminD1Ids.length === 0) {
          console.log("[notify-campaign-promo] admin: empty pool, skip");
        } else {
          // 관리자 수신자 (campaign_promo 구독자)
          const { data: adminData, error: adminErr } = await sb.rpc("get_subscribed_admin_emails", {
            p_mail_kind: "campaign_promo",
          });
          if (adminErr) throw adminErr;
          const adminEmails: string[] = [...new Set<string>(
            ((adminData || []) as { email: string | null }[])
              .map((r) => (r.email || "").trim())
              .filter((e): e is string => e.length > 0),
          )];

          if (adminEmails.length === 0) {
            console.log("[notify-campaign-promo] admin: no subscribers, skip");
          } else {
            // 캠페인 상세 + monitor 승인 수 (관리자 풀 전용 조회 — 인플 로직과 독립)
            const adminAllIds = [...new Set([...adminNewIds, ...adminD1Ids])];
            const adminCampaignMap = new Map<string, CampaignRow>();
            if (adminAllIds.length > 0) {
              const { data: camps, error: campErr } = await sb
                .from("campaigns")
                .select("id, campaign_no, title, brand, brand_ko, recruit_type, deadline, slots, reward, product_price, reward_note, img1")
                .in("id", adminAllIds);
              if (campErr) console.warn("[notify-campaign-promo] admin campaign lookup failed", campErr);
              else (camps || []).forEach((c: CampaignRow) => adminCampaignMap.set(c.id, c));
            }
            const adminMonitorIds = [...adminCampaignMap.values()]
              .filter((c) => c.recruit_type === "monitor").map((c) => c.id);
            const adminApprovedMap = new Map<string, number>();
            if (adminMonitorIds.length > 0) {
              const { data: apps } = await sb
                .from("applications")
                .select("campaign_id")
                .in("campaign_id", adminMonitorIds)
                .eq("status", "approved");
              (apps || []).forEach((row: { campaign_id: string }) => {
                adminApprovedMap.set(row.campaign_id, (adminApprovedMap.get(row.campaign_id) || 0) + 1);
              });
            }

            const adminMail = renderAdminPromoMailBody({
              newCampaignIds: adminNewIds,
              newTotalCount: pool?.new_total_count ?? adminNewIds.length,
              d1CampaignIds: adminD1Ids,
              d1TotalCount: pool?.deadline_d1_total_count ?? adminD1Ids.length,
              campaignMap: adminCampaignMap,
              approvedMap: adminApprovedMap,
              publicAppUrl,
              todayKst,
            });

            // 관리자 1명당 1통 분리 발송 (To 헤더에 다른 관리자 노출 안 됨)
            let adminSent = 0, adminFailed = 0;
            for (const email of adminEmails) {
              try {
                await sendBrevoEmail({
                  to: [{ email, name: "관리자" }],
                  subject: adminMail.subject,
                  htmlContent: adminMail.html,
                  textContent: adminMail.text,
                });
                adminSent++;
              } catch (e) {
                adminFailed++;
                console.error("[notify-campaign-promo] admin send failed", email, (e as Error).message);
              }
            }
            console.log("[notify-campaign-promo] admin sent", {
              recipients: adminEmails.length, sent: adminSent, failed: adminFailed,
            });
          }
        }
      } catch (e) {
        // 관리자 발송 실패는 인플 발송을 막지 않음 (격리)
        console.error("[notify-campaign-promo] admin block failed (isolated)", (e as Error).message);
      }
    }

    // ── 2. 발송 대상자 조회 (RPC) ──
    //    RPC 가 이미 발송 완료 인플 자동 제외 → chained 재호출 시 잔여 인플만 반환
    //
    // [리뷰 반영 4] ⚠️ 이 조회는 하루 제한 없이 계속 불어날 수 있는 값(대상자
    // 전체)을 돌려주는데도 일부러 페이지 나눔(fetchAllPaged)을 안 넣었다.
    // 안전한 이유는 이 함수의 성질 둘이 겹쳐야만 성립한다 — ①마이그레이션
    // 321 이 최종 SELECT 에 건 `ORDER BY t.influencer_id`(안정 정렬)로,
    // PostgREST 1,000행 상한에 걸려 잘려도 항상 "정렬된 앞쪽" 이 온다 ②이
    // 파일이 어차피 매 라운드 `targets.slice(0, BATCH_SIZE)`(200명)만 쓰고,
    // 그 200명은 이미 이전 라운드들이 처리 완료로 기록한 사람을 스스로
    // 제외한 명단이라 "앞쪽 200명"이 항상 맞는 다음 배치다. 즉 잘려도 빠지는
    // 사람은 없고, 다만 targets.length(=잔여 인원 추정치)가 부정확해질 수
    // 있을 뿐 — 그 값은 정체 감지·로그에만 쓰인다. **둘 중 하나라도 깨지면
    // (정렬을 지우거나, 이 파일이 slice 없이 전체를 쓰게 바뀌면) 이 판단은
    // 더 이상 성립하지 않는다** — 그때는 fetchAllPaged 로 감싸거나, RPC 쪽에
    // LIMIT/OFFSET 파라미터를 추가하는 쪽으로 다시 검토할 것.
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
          finishedAt: new Date().toISOString(),
        });
      }
      return new Response(JSON.stringify({ error: rpcError.message, stage: "rpc" }), {
        status: 500, headers: { "content-type": "application/json" },
      });
    }
    const targets: PromoTarget[] = (targetsData || []) as PromoTarget[];
    console.log("[notify-campaign-promo] targets", { count: targets.length, chainCount });

    // ── 2.5 정체 감지 (이어달리기 2회차부터, 무한 반복 1차 방어) ──
    //    get_promo_digest_targets 는 「그날 이미 기록된 사람」을 뺀 명단을 준다.
    //    직전 라운드 시작 시점의 잔여 인원(prevRemainingCount)과 이번 라운드 잔여
    //    인원을 비교해, 줄지 않았다면 직전 라운드가 아무도 기록시키지 못한 것 —
    //    즉 mark_promo_digest_sent 기록이 반복 실패 중이라는 뜻이다. 이 상태로
    //    계속 이어달리면 같은 사람에게 메일이 여러 번 나갈 수 있어 즉시 멈춘다.
    if (chainCount > 0 && body.prevRemainingCount != null && targets.length >= body.prevRemainingCount) {
      console.error("[notify-campaign-promo] stall detected — chain aborted", {
        chainCount, prevRemainingCount: body.prevRemainingCount, currentRemaining: targets.length,
      });
      // ⚠️ [F-4] 이 digest_date 로 지금까지 쌓인 발송 결과 전체를 세는 조회 —
      //   대상자가 많은 날은 1,000행을 넘을 수 있다(대상자 자체가 이미 1,000명대
      //   시나리오를 이 파일 상단 주석이 전제하고 있음). fetchAllPaged 로 감싸
      //   전건 집계, 정렬(id)은 페이지 경계 안정성용.
      let cumSent = 0, cumSkipped = 0, cumFailed = 0;
      try {
        const sumRows = await fetchAllPaged<{ status: string }>(() =>
          sb.from("campaign_promo_digest_sent")
            .select("status")
            .eq("digest_date", digestDate)
            .order("id", { ascending: true })
        );
        sumRows.forEach((r) => {
          if (r.status === "sent") cumSent++;
          else if (r.status === "skipped") cumSkipped++;
          else if (r.status === "failed") cumFailed++;
        });
      } catch (e) {
        console.warn("[notify-campaign-promo] sum SELECT failed (stall path)", (e as Error).message);
      }
      const stallCampaignIdSet = new Set<string>();
      targets.forEach((t) => {
        (t.new_campaign_ids || []).forEach((id) => stallCampaignIdSet.add(id));
        (t.deadline_d1_campaign_ids || []).forEach((id) => stallCampaignIdSet.add(id));
      });
      await finalizeRun({
        status: cumSent > 0 ? "partial" : "failed",
        sentCount: cumSent,
        skippedCount: cumSkipped,
        failedCount: cumFailed,
        includedCampaignIds: [...stallCampaignIdSet],
        errorMessage:
          `정체 감지로 중단 (이어달리기 #${chainCount}): 직전 잔여 ${body.prevRemainingCount}명 → ` +
          `이번 잔여 ${targets.length}명(변화 없음). mark_promo_digest_sent 기록이 반복 실패 중일 가능성 — ` +
          `campaign_promo_digest_sent 로그 확인 필요.`,
        finishedAt: new Date().toISOString(),
      });
      return new Response(
        JSON.stringify({ ok: false, stalled: true, chainCount, remaining: targets.length, digestDate }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    }

    // ── 3. 데이터 0건 처리 ──
    if (targets.length === 0) {
      if (isFirstBatch) {
        await finalizeRun({
          status: "skipped_no_data",
          targetCount: 0, sentCount: 0, skippedCount: 0, failedCount: 0,
          includedCampaignIds: [],
          finishedAt: new Date().toISOString(),
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
        .select("id, campaign_no, title, brand, brand_ko, recruit_type, deadline, slots, reward, product_price, reward_note, img1")
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
    //    targets 는 이미 「오늘 아직 안 받은 사람만」이므로 항상 앞에서부터 자른다.
    //    (옛 batchOffset 이동 방식은 줄어든 명단에 또 offset 을 더해 한 무리가
    //    통째로 안 뽑히는 결함이 있었다 — 마이그레이션 321 배경)
    const batchTargets = targets.slice(0, BATCH_SIZE);
    const hasMore = targets.length > BATCH_SIZE;
    const nextChainCount = chainCount + 1;
    // 이어달리기 상한 도달 시 hasMore 여도 더 이상 자기재호출하지 않는다(무한 반복 2차 방어)
    const chainCapReached = hasMore && nextChainCount > MAX_CHAIN_COUNT;
    // 이번 라운드가 끝난 뒤 실제로 또 이어달릴 예정인지 — finalStatus·finished_at 판단에 사용
    const willChainAgain = hasMore && !chainCapReached;
    console.log("[notify-campaign-promo] batch", {
      chainCount, batchSize: batchTargets.length, hasMore, chainCapReached, total: targets.length,
    });

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
      //
      // ⚠️ 이 기록이 실패하면 그 사람은 다음 라운드 명단에 「아직 못 받은 사람」으로 다시 뽑힌다
      //    — 메일은 이미 나간 뒤인데 또 나간다. 정체 감지(위 2.5 단계)는 「라운드 전체가
      //    안 줄어드는」 경우만 잡으므로, 200명 중 몇 명만 기록에 실패하는 이 경우는 못 잡는다.
      //    게다가 마이그321에서 명단 정렬을 고정해(ORDER BY influencer_id) 실패한 사람이
      //    다음 라운드에도 같은 앞쪽 자리에 남는다 — 거의 곧바로 재발송된다.
      //    그래서 실패하면 한 번 더 시도한다. 원인 대부분은 순간적인 연결 문제라 재시도로 걷힌다.
      //    두 번 다 실패하면 error 로 남긴다(warn 은 눈에 안 띈다).
      const includedIds = [...newIds, ...d1Ids];
      const markSentArgs = {
        p_influencer_id: target.influencer_id,
        p_digest_date: digestDate,
        p_status: "sent",
        p_skip_reason: null,
        p_error_message: null,
        p_included_campaign_ids: includedIds,
      };
      let { error: markError } = await sb.rpc("mark_promo_digest_sent", markSentArgs);
      if (markError) {
        console.warn("[notify-campaign-promo] mark sent failed — retrying once", target.influencer_id, markError);
        await sleep(300);
        ({ error: markError } = await sb.rpc("mark_promo_digest_sent", markSentArgs));
      }
      if (markError) {
        // 여기까지 오면 다음 라운드에 재발송될 수 있다 — 운영자가 반드시 봐야 하는 자리
        console.error(
          "[notify-campaign-promo] mark sent failed twice — this influencer may receive a duplicate mail",
          target.influencer_id, markError,
        );
      }

      batchSent++;
      await sleep(BREVO_SLEEP_MS);
    }

    console.log("[notify-campaign-promo] batch result", {
      chainCount, batchSent, batchSkipped, batchFailed,
    });

    // ── 7. chained 자기재호출 (fire-and-forget) ──
    //    상한(MAX_CHAIN_COUNT) 도달 시엔 hasMore 여도 더 이상 이어달리지 않는다.
    if (willChainAgain) {
      selfInvokeChained({
        supaUrl, serviceKey, digestDate,
        chainCount: nextChainCount,
        // 이번 라운드 「처리 전」 잔여 인원 — 다음 라운드가 이 값과 비교해 정체를 감지한다
        prevRemainingCount: targets.length,
        // [리뷰 반영 1] 소유권 값을 다음 라운드로 이어 넘긴다
        startedAt: ownedStartedAt,
      });
    } else if (chainCapReached) {
      console.error("[notify-campaign-promo] chain cap reached — stopping", {
        chainCount, maxChainCount: MAX_CHAIN_COUNT,
        unprocessedRemaining: Math.max(targets.length - batchTargets.length, 0),
      });
    }

    // ── 8. finalizeRun (배치 누적 집계) ──
    //    매 배치마다 SUM 으로 재집계 → chained 도 안전한 누적 카운트
    //    ⚠️ [F-4] 대상자가 많은 날은 1,000행을 넘을 수 있어 fetchAllPaged 로 감쌈
    //    (위 stall-detection 경로와 동일 조회 — 정렬(id)도 동일 기준).
    let cumSent = 0, cumSkipped = 0, cumFailed = 0;
    try {
      const sumRows = await fetchAllPaged<{ status: string }>(() =>
        sb.from("campaign_promo_digest_sent")
          .select("status")
          .eq("digest_date", digestDate)
          .order("id", { ascending: true })
      );
      sumRows.forEach((r) => {
        if (r.status === "sent") cumSent++;
        else if (r.status === "skipped") cumSkipped++;
        else if (r.status === "failed") cumFailed++;
      });
    } catch (e) {
      console.warn("[notify-campaign-promo] sum SELECT failed", (e as Error).message);
      cumSent = batchSent; cumSkipped = batchSkipped; cumFailed = batchFailed;
    }

    // status 결정
    let finalStatus: "sent" | "partial" | "failed" | "skipped_no_data" = "sent";
    if (willChainAgain) {
      finalStatus = "partial"; // 진행 중 — 이어달리기 예정
    } else if (cumSent === 0 && cumFailed === 0 && cumSkipped === 0) {
      finalStatus = "skipped_no_data";
    } else if (chainCapReached) {
      finalStatus = "partial"; // 상한 도달로 조기 종료 — 처리 못 한 인원이 남음(error_message 참고)
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

    const unprocessedRemaining = Math.max(targets.length - batchTargets.length, 0);
    const errMsg = chainCapReached
      ? `chain cap reached at #${chainCount} (max ${MAX_CHAIN_COUNT}) — ${unprocessedRemaining} influencer(s) not processed.` +
        (batchFailures.length > 0
          ? ` also ${batchFailures.length} failure(s) this round, first: ${batchFailures[0].email}(${batchFailures[0].error})`
          : "")
      : batchFailures.length > 0
        ? `chain@${chainCount}: ${batchFailures.length} failure(s). first: ${batchFailures[0].email}(${batchFailures[0].error})`
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
      // 더 이상 이어달리지 않는 시점(정상 완료 또는 상한 도달)에만 finished_at 기록
      finishedAt: willChainAgain ? undefined : new Date().toISOString(),
    });

    console.log("[notify-campaign-promo] done", {
      digestDate, chainCount, batchSize: batchTargets.length, hasMore, chainCapReached,
      cumSent, cumSkipped, cumFailed, finalStatus,
    });

    return new Response(
      JSON.stringify({
        ok: true,
        digestDate,
        chainCount,
        batchSize: batchTargets.length,
        hasMore,
        chainCapReached,
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
          finishedAt: new Date().toISOString(),
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
