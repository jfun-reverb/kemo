// ══════════════════════════════════════════════════════════════════
// scripts/send-test-admin-digest.ts
// ──────────────────────────────────────────────────────────────────
// 관리자 일일 통합 다이제스트 메일 (notify-admin-daily-digest, PR 2) 의
// 메일 렌더링·깨짐 여부를 실제 메일 클라이언트에서 확인하기 위한
// 일회용 테스트 발송 스크립트.
//
// docs/email-templates/admin-daily-digest{.html, .section.html, .row-*.html}
// 6종을 그대로 사용 + 4섹션 더미 데이터 → Brevo SMTP 발송.
//
// 사용법:
//   BREVO_API_KEY='xkeysib-...' \
//     deno run --allow-read --allow-env --allow-net \
//     scripts/send-test-admin-digest.ts
//
// 환경변수:
//   BREVO_API_KEY     (필수) Brevo Transactional API 키
//   TEST_RECIPIENT    (옵션) 기본 younggeun.kim@jfun.co.kr
//   PUBLIC_ADMIN_URL  (옵션) 기본 https://globalreverb.com/admin/
//
// ※ DB 와 무관 — Brevo API 만 호출. dev/운영 어느 환경 BREVO 키로 보내든 동일.
// ※ 발송 후 「관리자 일일 통합 요약 — [TEST]」 메시지를 받음.
// ══════════════════════════════════════════════════════════════════

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";
const TEMPLATES_DIR = "docs/email-templates";

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

async function loadTemplate(name: string): Promise<string> {
  const path = `${TEMPLATES_DIR}/${name}.html`;
  const raw = await Deno.readTextFile(path);
  // HTML 주석 제거 — 주석 안 placeholder 가 render() 로 치환되면서 발생하는
  // 중첩 주석 → 조기 종료 → 본문 누출 버그 차단
  return raw.replace(/<!--[\s\S]*?-->/g, "");
}

function render(html: string, data: Record<string, string>): string {
  return html.replace(/\{\{(\w+)\}\}/g, (_m, key) => data[key] ?? "");
}

// ──────────────────────────────────────────────────────────────────
// 더미 데이터 — 4섹션 (각 2~3 entries)
// ──────────────────────────────────────────────────────────────────
const digestDate = "2026-05-17";

const dummyReceived = [
  {
    campaign_no: "CAMP-2026-0042",
    campaign_title: "스킨케어 신제품 리뷰 캠페인 — 페이셜 세럼",
    recruit_type_ko: "리뷰어",
    infls: [
      { name: "야마다 사쿠라 (山田 さくら)", email: "sakura@example.com", sns: "@sakura_jp · IG", time: "21:34 JST" },
      { name: "타나카 유이 (田中 ゆい)",      email: "yui@example.com",    sns: "@yui_official · IG", time: "22:15 JST" },
      { name: "스즈키 하루카 (鈴木 はるか)",  email: "haruka@example.com", sns: "@haruka_diary · TT", time: "23:02 JST" },
    ],
  },
  {
    campaign_no: "CAMP-2026-0043",
    campaign_title: "헤어 미스트 무료 체험단",
    recruit_type_ko: "기프팅",
    infls: [
      { name: "사토 미키 (佐藤 みき)", email: "miki@example.com", sns: "@miki_hair · IG", time: "10:22 JST" },
      { name: "고바야시 린 (小林 りん)", email: "rin@example.com", sns: "@rin_styling · YT", time: "14:48 JST" },
    ],
  },
];

const dummyCancelled = [
  {
    campaign_no: "CAMP-2026-0040",
    campaign_title: "프리미엄 마스크팩 — 일본 한정 캠페인",
    recruit_type_ko: "리뷰어",
    cancelled_at_jst: "2026-05-17 11:24 JST",
    phase: "purchase",
    phase_ko: "구매기간",
    influencer_name: "와타나베 나츠미 (渡辺 なつみ)",
    influencer_email: "natsumi@example.com",
    cancel_reason_ko: "스케줄 사정",
    cancel_reason_note: "출장 일정과 겹쳐서 어렵습니다",
  },
  {
    campaign_no: "CAMP-2026-0038",
    campaign_title: "도쿄 카페 방문 리뷰",
    recruit_type_ko: "방문형",
    cancelled_at_jst: "2026-05-17 16:09 JST",
    phase: "visit",
    phase_ko: "방문기간",
    influencer_name: "이토 아오이 (伊藤 あおい)",
    influencer_email: "aoi@example.com",
    cancel_reason_ko: "개인 사정",
    cancel_reason_note: "",
  },
  {
    campaign_no: "CAMP-2026-0035",
    campaign_title: "기능성 화장품 게시 캠페인",
    recruit_type_ko: "기프팅",
    cancelled_at_jst: "2026-05-17 20:51 JST",
    phase: "post",
    phase_ko: "결과물 제출기간",
    influencer_name: "야마구치 호노카 (山口 ほのか)",
    influencer_email: "honoka@example.com",
    cancel_reason_ko: "기타",
    cancel_reason_note: "결과물 제출 기한 안에 게시 어려움",
  },
];

const dummySubmitted = [
  {
    campaign_no: "CAMP-2026-0042",
    campaign_title: "스킨케어 신제품 리뷰 캠페인 — 페이셜 세럼",
    recruit_type_ko: "리뷰어",
    kind: "receipt",
    kind_ko: "영수증",
    influencer_name: "야마다 사쿠라 (山田 さくら)",
    submitted_at_jst: "13:45 JST",
  },
  {
    campaign_no: "CAMP-2026-0042",
    campaign_title: "스킨케어 신제품 리뷰 캠페인 — 페이셜 세럼",
    recruit_type_ko: "리뷰어",
    kind: "review_image",
    kind_ko: "리뷰 이미지",
    influencer_name: "타나카 유이 (田中 ゆい)",
    submitted_at_jst: "15:21 JST",
  },
  {
    campaign_no: "CAMP-2026-0043",
    campaign_title: "헤어 미스트 무료 체험단",
    recruit_type_ko: "기프팅",
    kind: "post",
    kind_ko: "게시 URL",
    influencer_name: "사토 미키 (佐藤 みき)",
    submitted_at_jst: "18:32 JST",
  },
];

const dummyReprocessed = [
  {
    type: "deliv_resubmit" as const,
    type_ko: "결과물 재제출",
    type_color_bg: "#F0E6FA",
    type_color_fg: "#6F40A6",
    campaign_no: "CAMP-2026-0036",
    campaign_title: "썬크림 SPF50+ 캠페인",
    recruit_type_ko: "리뷰어",
    influencer_name: "마츠모토 미오 (松本 みお)",
    actor_name: "-",
    event_at_jst: "09:48 JST",
  },
  {
    type: "deliv_revert" as const,
    type_ko: "결과물 되돌리기",
    type_color_bg: "#FFE8D6",
    type_color_fg: "#A0541A",
    campaign_no: "CAMP-2026-0039",
    campaign_title: "립밤 신제품 캠페인",
    recruit_type_ko: "기프팅",
    influencer_name: "후지타 시오리 (藤田 しおり)",
    actor_name: "-",
    event_at_jst: "11:15 JST",
  },
  {
    type: "app_revert" as const,
    type_ko: "신청 되돌리기",
    type_color_bg: "#E5E0F4",
    type_color_fg: "#5B6BBF",
    campaign_no: "CAMP-2026-0044",
    campaign_title: "헤어 트리트먼트 캠페인",
    recruit_type_ko: "리뷰어",
    influencer_name: "기무라 카오리 (木村 かおり)",
    actor_name: "관리자 김영근",
    event_at_jst: "14:02 JST",
  },
];

// ──────────────────────────────────────────────────────────────────
// 섹션 렌더링
// ──────────────────────────────────────────────────────────────────
async function renderReceivedSection(): Promise<string> {
  const sectionTpl = await loadTemplate("admin-daily-digest.section");
  const rowTpl = await loadTemplate("admin-daily-digest.row-received");
  const cardsHtml = dummyReceived.map((c) => {
    const inflListHtml = c.infls.map((i) =>
      `<tr>
        <td style="padding:4px 0">${escapeHtml(i.name)}</td>
        <td style="padding:4px 0;color:#666">${escapeHtml(i.email)}</td>
        <td style="padding:4px 0;color:#666;font-size:11px">${escapeHtml(i.sns)}</td>
        <td style="padding:4px 0;color:#888;font-size:11px;text-align:right">${escapeHtml(i.time)}</td>
      </tr>`
    ).join("");
    return render(rowTpl, {
      campaign_no: escapeHtml(`【${c.campaign_no}】`),
      campaign_title: escapeHtml(c.campaign_title),
      recruit_type_ko: escapeHtml(c.recruit_type_ko),
      infl_count: String(c.infls.length),
      infl_list_html: inflListHtml,
    });
  }).join("");
  const count = dummyReceived.reduce((a, c) => a + c.infls.length, 0);
  return render(sectionTpl, {
    section_title: escapeHtml("캠페인 신청 접수"),
    section_color: "#C8789C",
    section_count: String(count),
    section_body_html: cardsHtml,
  });
}

async function renderCancelledSection(): Promise<string> {
  const sectionTpl = await loadTemplate("admin-daily-digest.section");
  const rowTpl = await loadTemplate("admin-daily-digest.row-cancelled");
  const phaseOrder = ["purchase", "visit", "post", "other"];
  const phaseColors: Record<string, { bg: string; fg: string }> = {
    purchase: { bg: "#FFE4E9", fg: "#E8344E" },
    visit:    { bg: "#E4F0FF", fg: "#1F5DBF" },
    post:     { bg: "#FFF0D6", fg: "#A06A14" },
    other:    { bg: "#EAEAEA", fg: "#555555" },
  };
  const groups: Record<string, typeof dummyCancelled> = {};
  phaseOrder.forEach((p) => { groups[p] = []; });
  dummyCancelled.forEach((r) => {
    const k = phaseOrder.includes(r.phase) ? r.phase : "other";
    groups[k].push(r);
  });
  const renderCard = (r: typeof dummyCancelled[number]) => {
    const noteRow = r.cancel_reason_note.trim()
      ? `<tr><td style="padding:4px 0;color:#888;vertical-align:top">보충</td><td style="padding:4px 0;line-height:1.5">${escapeHtml(r.cancel_reason_note)}</td></tr>`
      : "";
    return render(rowTpl, {
      campaign_no: escapeHtml(`【${r.campaign_no}】`),
      campaign_title: escapeHtml(r.campaign_title),
      recruit_type_ko: escapeHtml(r.recruit_type_ko),
      influencer_name: escapeHtml(r.influencer_name),
      influencer_email: escapeHtml(r.influencer_email),
      cancelled_at_jst: escapeHtml(r.cancelled_at_jst),
      cancel_phase_ko: escapeHtml(r.phase_ko),
      cancel_reason_ko: escapeHtml(r.cancel_reason_ko),
      cancel_reason_note_row: noteRow,
    });
  };
  const bodyHtml = phaseOrder
    .filter((p) => groups[p].length > 0)
    .map((p) => {
      const c = phaseColors[p];
      const phaseKoLabel = ({purchase:"구매기간",visit:"방문기간",post:"결과물 제출기간",other:"기타"} as Record<string,string>)[p] || "기타";
      const groupHeader =
        `<div style="margin:8px 0 6px;padding:6px 10px;background:${c.bg};border-left:3px solid ${c.fg};border-radius:0 6px 6px 0">` +
        `<span style="color:${c.fg};font-weight:700;font-size:12px">${phaseKoLabel}</span>` +
        `<span style="color:${c.fg};font-size:11px;margin-left:6px">${groups[p].length}건</span>` +
        `</div>`;
      return groupHeader + groups[p].map(renderCard).join("");
    })
    .join("");
  return render(sectionTpl, {
    section_title: escapeHtml("응모 취소"),
    section_color: "#E8344E",
    section_count: String(dummyCancelled.length),
    section_body_html: bodyHtml,
  });
}

async function renderSubmittedSection(): Promise<string> {
  const sectionTpl = await loadTemplate("admin-daily-digest.section");
  const rowTpl = await loadTemplate("admin-daily-digest.row-submitted");
  const kindOrder = ["receipt", "review_image", "post"];
  const groups: Record<string, typeof dummySubmitted> = {};
  kindOrder.forEach((k) => { groups[k] = []; });
  dummySubmitted.forEach((s) => {
    if (groups[s.kind]) groups[s.kind].push(s);
  });
  const bodyHtml = kindOrder
    .filter((k) => groups[k].length > 0)
    .map((k) => {
      const kindLabel = ({receipt:"영수증",review_image:"리뷰 이미지",post:"게시 URL"} as Record<string,string>)[k];
      const groupHeader =
        `<div style="margin:8px 0 6px;padding:6px 10px;background:#E4F0FF;border-left:3px solid #1F5DBF;border-radius:0 6px 6px 0">` +
        `<span style="color:#1F5DBF;font-weight:700;font-size:12px">${escapeHtml(kindLabel)}</span>` +
        `<span style="color:#1F5DBF;font-size:11px;margin-left:6px">${groups[k].length}건</span>` +
        `</div>`;
      const cards = groups[k].map((s) => render(rowTpl, {
        campaign_no: escapeHtml(`【${s.campaign_no}】`),
        campaign_title: escapeHtml(s.campaign_title),
        recruit_type_ko: escapeHtml(s.recruit_type_ko),
        kind_ko: escapeHtml(s.kind_ko),
        influencer_name: escapeHtml(s.influencer_name),
        submitted_at_jst: escapeHtml(s.submitted_at_jst),
      })).join("");
      return groupHeader + cards;
    })
    .join("");
  return render(sectionTpl, {
    section_title: escapeHtml("결과물 제출"),
    section_color: "#1F5DBF",
    section_count: String(dummySubmitted.length),
    section_body_html: bodyHtml,
  });
}

async function renderReprocessedSection(): Promise<string> {
  const sectionTpl = await loadTemplate("admin-daily-digest.section");
  const rowTpl = await loadTemplate("admin-daily-digest.row-reprocessed");
  const typeOrder = ["deliv_resubmit", "deliv_revert", "app_revert"] as const;
  const groups: Record<string, typeof dummyReprocessed> = {
    deliv_resubmit: [], deliv_revert: [], app_revert: [],
  };
  dummyReprocessed.forEach((it) => groups[it.type].push(it));
  const bodyHtml = typeOrder
    .filter((t) => groups[t].length > 0)
    .map((t) => {
      const first = groups[t][0];
      const groupHeader =
        `<div style="margin:8px 0 6px;padding:6px 10px;background:${first.type_color_bg};border-left:3px solid ${first.type_color_fg};border-radius:0 6px 6px 0">` +
        `<span style="color:${first.type_color_fg};font-weight:700;font-size:12px">${escapeHtml(first.type_ko)}</span>` +
        `<span style="color:${first.type_color_fg};font-size:11px;margin-left:6px">${groups[t].length}건</span>` +
        `</div>`;
      const cards = groups[t].map((it) => render(rowTpl, {
        campaign_no: escapeHtml(`【${it.campaign_no}】`),
        campaign_title: escapeHtml(it.campaign_title),
        recruit_type_ko: escapeHtml(it.recruit_type_ko),
        type_ko: escapeHtml(it.type_ko),
        type_color_bg: it.type_color_bg,
        type_color_fg: it.type_color_fg,
        influencer_name: escapeHtml(it.influencer_name),
        actor_name: escapeHtml(it.actor_name),
        event_at_jst: escapeHtml(it.event_at_jst),
      })).join("");
      return groupHeader + cards;
    })
    .join("");
  return render(sectionTpl, {
    section_title: escapeHtml("재처리 일감"),
    section_color: "#6F40A6",
    section_count: String(dummyReprocessed.length),
    section_body_html: bodyHtml,
  });
}

// ──────────────────────────────────────────────────────────────────
// Main
// ──────────────────────────────────────────────────────────────────
const apiKey = env("BREVO_API_KEY").trim();
if (!apiKey) {
  console.error("❌ BREVO_API_KEY 환경변수가 없습니다.");
  console.error("실행 예: BREVO_API_KEY='xkeysib-...' deno run --allow-read --allow-env --allow-net scripts/send-test-admin-digest.ts");
  Deno.exit(1);
}
// ASCII 검증 — 비-ASCII (예: 한국어 placeholder) 가 들어가면 fetch headers 가 ByteString 변환 실패
if (!/^[\x20-\x7E]+$/.test(apiKey)) {
  console.error("❌ BREVO_API_KEY 에 비-ASCII 문자가 포함됨. (placeholder 가 실제 키로 교체되지 않았을 가능성)");
  console.error(`   현재 값 prefix: ${apiKey.slice(0, 10)}... (길이 ${apiKey.length})`);
  console.error("   Brevo 키는 'xkeysib-' 로 시작하는 ASCII 문자열입니다.");
  Deno.exit(1);
}
if (!apiKey.startsWith("xkeysib-")) {
  console.warn(`⚠ BREVO_API_KEY prefix 가 'xkeysib-' 가 아닙니다 (${apiKey.slice(0, 10)}...). 그래도 시도합니다.`);
}
const recipient = env("TEST_RECIPIENT", "younggeun.kim@jfun.co.kr");

console.log(`📧 테스트 발송 준비 — 수신: ${recipient}`);

// 4섹션 렌더
const [sectionReceivedHtml, sectionCancelledHtml, sectionSubmittedHtml, sectionReprocessedHtml] =
  await Promise.all([
    renderReceivedSection(),
    renderCancelledSection(),
    renderSubmittedSection(),
    renderReprocessedSection(),
  ]);

const receivedCount = dummyReceived.reduce((a, c) => a + c.infls.length, 0);
const sectionsSummary = {
  received:   receivedCount,
  cancelled:  dummyCancelled.length,
  submitted:  dummySubmitted.length,
  reprocessed: dummyReprocessed.length,
};
const totalCount = sectionsSummary.received + sectionsSummary.cancelled +
                   sectionsSummary.submitted + sectionsSummary.reprocessed;

// 칩 HTML
const chipDef = [
  { key: "received",    label: "접수",   bg: "#FFF5F8", fg: "#C8789C" },
  { key: "cancelled",   label: "취소",   bg: "#FFE4E9", fg: "#E8344E" },
  { key: "submitted",   label: "제출",   bg: "#E4F0FF", fg: "#1F5DBF" },
  { key: "reprocessed", label: "재처리", bg: "#F0E6FA", fg: "#6F40A6" },
] as const;
const summaryChipHtml = chipDef
  .filter((c) => sectionsSummary[c.key as keyof typeof sectionsSummary] > 0)
  .map((c) =>
    `<span style="background:${c.bg};color:${c.fg};padding:3px 10px;border-radius:6px;font-weight:700;font-size:12px;margin-right:6px">${c.label} ${sectionsSummary[c.key as keyof typeof sectionsSummary]}건</span>`
  )
  .join("");

const adminPaneUrl = env("PUBLIC_ADMIN_URL", "https://globalreverb.com/admin/").replace(/\/$/, "") + "/";

const mainTpl = await loadTemplate("admin-daily-digest");
let html = render(mainTpl, {
  digest_date: escapeHtml(digestDate),
  total_count: String(totalCount),
  summary_chip_html: summaryChipHtml,
  section_received_html: sectionReceivedHtml,
  section_cancelled_html: sectionCancelledHtml,
  section_submitted_html: sectionSubmittedHtml,
  section_reprocessed_html: sectionReprocessedHtml,
  admin_pane_url: escapeHtml(adminPaneUrl),
});

// TEST 배너 본문 상단 삽입
const testBanner = `<div style="background:#FFF3CD;border-left:4px solid #FFA000;padding:10px 14px;margin:0 0 12px;border-radius:6px;font-family:'Noto Sans KR',Arial,sans-serif;color:#5A4500;font-size:13px"><strong>⚠️ TEST MAIL — 더미 데이터</strong><br>실제 데이터 아님. 메일 렌더링·깨짐 여부 확인용. <code style="background:#FFEAA7;padding:1px 6px;border-radius:3px">scripts/send-test-admin-digest.ts</code> 로 발송됨.</div>`;
html = html.replace('<div style="font-family:', testBanner + '<div style="font-family:');

const subject = `[TEST] 관리자 일일 요약 — ${digestDate} (총 ${totalCount}건 더미)`;

const textLines = [
  `[TEST] 관리자 일일 통합 요약 (${digestDate})`,
  `총 ${totalCount}건 더미 — 접수 ${sectionsSummary.received} · 취소 ${sectionsSummary.cancelled} · 제출 ${sectionsSummary.submitted} · 재처리 ${sectionsSummary.reprocessed}`,
  "",
  "실제 데이터 아님. 메일 렌더링·깨짐 여부 확인용.",
  "",
  `관리자 페이지: ${adminPaneUrl}`,
];
const text = textLines.join("\n");

console.log(`📧 발송 중 — subject: ${subject}`);
console.log(`📧 HTML 크기: ${html.length} bytes`);

const res = await fetch(BREVO_ENDPOINT, {
  method: "POST",
  headers: {
    "api-key": apiKey,
    "content-type": "application/json",
    accept: "application/json",
  },
  body: JSON.stringify({
    sender: {
      email: env("BREVO_SENDER_EMAIL", "noreply@globalreverb.com"),
      name: env("BREVO_SENDER_NAME", "REVERB JP [TEST]"),
    },
    to: [{ email: recipient }],
    subject,
    htmlContent: html,
    textContent: text,
  }),
});

if (!res.ok) {
  const errText = await res.text();
  console.error(`❌ Brevo 발송 실패 ${res.status}: ${errText}`);
  Deno.exit(1);
}

const body = await res.json();
console.log(`✅ Brevo 발송 성공 — message_id: ${body.messageId || "(없음)"}`);
console.log(`📬 ${recipient} 받은편지함에서 확인하세요.`);
