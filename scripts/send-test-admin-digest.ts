// ══════════════════════════════════════════════════════════════════
// scripts/send-test-admin-digest.ts
// ──────────────────────────────────────────────────────────────────
// 관리자 일일 통합 다이제스트 메일 (notify-admin-daily-digest, PR 2) 의
// 메일 렌더링·깨짐 여부를 실제 메일 클라이언트에서 확인하기 위한
// 일회용 테스트 발송 스크립트.
//
// docs/email-templates/admin-daily-digest{.html, .section.html, .row-*.html}
// 7종을 그대로 사용 + 5섹션 더미 데이터 → Brevo SMTP 발송.
//
// 사용법:
//   ① 실제 발송
//   BREVO_API_KEY='xkeysib-...' \
//     deno run --allow-read --allow-env --allow-net \
//     scripts/send-test-admin-digest.ts
//
//   ② 발송 없이 본문만 파일로 (키 없이도 된다)
//   DRY_RUN=1 deno run --allow-read --allow-env --allow-write \
//     scripts/send-test-admin-digest.ts
//
// 환경변수:
//   BREVO_API_KEY     (①에서 필수) Brevo Transactional API 키
//   DRY_RUN           (옵션) 비어 있지 않고 "0" 이 아니면 발송 없이 본문만 파일로
//   DRY_RUN_OUT       (옵션) DRY_RUN 출력 경로. 기본 /tmp/reverb-admin-digest-preview.html
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
// 더미 데이터 — 5섹션 (각 2~6 entries)
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

// 섹션 5 — 조치가 필요한 캠페인.
//   🔴 **여섯 갈래가 각각 한 건씩** 들어 있다 — 사양서 §3-6 ④ 가 사유 문구 여섯 줄을
//      화면 표와 한 글자씩 대조하는데, 운영 데이터가 같은 날 여섯을 다 내줄 보장이 없다.
//   🔴 **남은 날이 없는 카드를 한 건** 넣었다(recruit_low + 마감일 없음) — 정렬 규칙
//      「등급 안에서 맨 뒤」와 「날짜만 적는다」를 눈으로 확인할 유일한 방법이다.
//   ⚠️ 문구 표를 여기에 또 만들지 않는다 — **이미 조립된 문자열**을 담는다(기존 네 절과 같은 방식).
//      표를 복사하면 사본이 셋이 되어 화면·메일 두 벌 대조가 무의미해진다.
const dummyAction = [
  { level: "danger", level_color: "#DC2626", campaign_no: "B0008-C005", campaign_title: "비타민C 세럼 30ml 리뷰어 모집",
    brand_name: "Dr.Deep", recruit_type_ko: "리뷰어",
    deadline_line: "모집 마감 하루 전(2026/09/15)", status_line: "승인 2명 / 모집 10명(20%)",
    reason_text: "마감 하루 전 · 모집 저조" },
  { level: "danger", level_color: "#DC2626", campaign_no: "B0008-C008", campaign_title: "韓国スナック詰め合わせ 春の新作",
    brand_name: "모모 스낵", recruit_type_ko: "기프팅",
    deadline_line: "모집 마감 3일 남음(2026/09/17)", status_line: "승인 0명 / 모집 20명(0%)",
    reason_text: "마감 3일 남음 · 모집 저조 · 마감 3일 남음" },
  { level: "warning", level_color: "#f97316", campaign_no: "B0008-C007", campaign_title: "방문형 데이터 검증 캠페인",
    brand_name: "글로우 스킨케어", recruit_type_ko: "방문형",
    deadline_line: "결과물 제출 마감 오늘(2026/09/14)", status_line: "인증 성공 0명 / 승인 1명(0%) · 미인증 1명",
    reason_text: "미인증 1명 · 제출 마감 오늘" },
  { level: "caution", level_color: "#f59e0b", campaign_no: "B0020-C002", campaign_title: "엔모드프로 페이스라인 케어",
    brand_name: "엔모드", recruit_type_ko: "기프팅",
    deadline_line: "결과물 제출 마감 5일 남음(2026/09/19)", status_line: "인증 성공 1명 / 승인 4명(25%) · 미인증 3명",
    reason_text: "결과물 저조 · 제출 마감 5일 남음" },
  { level: "caution", level_color: "#f59e0b", campaign_no: "B0022-C002", campaign_title: "라비엘 애프터셰이브 리뷰",
    brand_name: "라비엘", recruit_type_ko: "리뷰어",
    deadline_line: "모집 마감 16일 남음(2026/09/30)", status_line: "승인 1명 / 모집 5명(20%)",
    reason_text: "모집 저조" },
  // 🔴 남은 날 없음 — 마감일 자체가 비어 있다. 「지남」이라고 쓰지 않고 「모집 마감일 없음」만 적는다.
  { level: "caution", level_color: "#f59e0b", campaign_no: "B0022-C003", campaign_title: "마감일 없는 상시 모집 캠페인",
    brand_name: "상시브랜드", recruit_type_ko: "리뷰어",
    deadline_line: "모집 마감일 없음", status_line: "승인 1명 / 모집 5명(20%)",
    reason_text: "모집 저조" },
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

async function renderActionSection(): Promise<string> {
  // 🔴 0건이면 절 통째로 생략 — **실제 메일 함수(index.ts 의 renderActionSection)와 같은 가드**다.
  //    이 더미는 index.ts 를 부르지 않는 **독립 렌더러**라, 이 줄이 없으면 「0건이면 절이 빠지는가」
  //    확인(사양서 §3-6 ③)이 엉뚱한 코드를 시험하게 된다 — 실제로 그래서 한 번 놓쳤다(2026-09-14).
  if (dummyAction.length === 0) return "";
  const rowTpl = await loadTemplate("admin-daily-digest.row-action");
  const bodyHtml = dummyAction.map((a) =>
    render(rowTpl, {
      campaign_no: escapeHtml(`【${a.campaign_no}】`),
      campaign_title: escapeHtml(a.campaign_title),
      brand_name: escapeHtml(a.brand_name),
      recruit_type_ko: escapeHtml(a.recruit_type_ko),
      level_color: a.level_color,
      deadline_line: escapeHtml(a.deadline_line),
      status_line: escapeHtml(a.status_line),
      reason_text: escapeHtml(a.reason_text),
    })
  ).join("");
  const sectionTpl = await loadTemplate("admin-daily-digest.section");
  return render(sectionTpl, {
    section_title: escapeHtml("조치가 필요한 캠페인"),
    section_color: "#E8344E",
    section_count: String(dummyAction.length),
    section_body_html: bodyHtml +
      `<p style="margin:10px 0 0;font-size:12px;color:#888">자세한 내용은 관리자 페이지 → 캠페인 관리에서 확인해 주세요.</p>`,
  });
}

// ──────────────────────────────────────────────────────────────────
// Main
// ──────────────────────────────────────────────────────────────────
// 🔴 DRY_RUN 판정은 키 검사보다 **먼저** 한다 — 키가 없으면 아래 검사가 렌더 전에 종료시켜
//    「키 없이 모양만 보기」가 아예 안 된다. 개발서버 실제 발송은 저장소 규칙상 막혀 있어
//    (`.claude/rules/supabase.md` 「개발서버 메일 발송 테스트 금지」) 이 경로가 유일한 확인 수단이다.
const dryRunRaw = env("DRY_RUN").trim();
const dryRun = dryRunRaw !== "" && dryRunRaw !== "0";

const apiKey = env("BREVO_API_KEY").trim();
if (!dryRun) {
  if (!apiKey) {
    console.error("❌ BREVO_API_KEY 환경변수가 없습니다.");
    console.error("실행 예: BREVO_API_KEY='xkeysib-...' deno run --allow-read --allow-env --allow-net scripts/send-test-admin-digest.ts");
    console.error("발송 없이 본문만 보려면: DRY_RUN=1 deno run --allow-read --allow-env --allow-write scripts/send-test-admin-digest.ts");
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
}
const recipient = env("TEST_RECIPIENT", "younggeun.kim@jfun.co.kr");

console.log(dryRun ? "📄 본문만 뽑기(DRY_RUN) — 발송하지 않습니다" : `📧 테스트 발송 준비 — 수신: ${recipient}`);

// 5섹션 렌더
const [sectionReceivedHtml, sectionCancelledHtml, sectionSubmittedHtml, sectionReprocessedHtml, sectionActionHtml] =
  await Promise.all([
    renderReceivedSection(),
    renderCancelledSection(),
    renderSubmittedSection(),
    renderReprocessedSection(),
    renderActionSection(),
  ]);

const receivedCount = dummyReceived.reduce((a, c) => a + c.infls.length, 0);
const sectionsSummary = {
  received:   receivedCount,
  cancelled:  dummyCancelled.length,
  submitted:  dummySubmitted.length,
  reprocessed: dummyReprocessed.length,
  action: dummyAction.length,
};
const totalCount = sectionsSummary.received + sectionsSummary.cancelled +
                   sectionsSummary.submitted + sectionsSummary.reprocessed +
                   sectionsSummary.action;

// 칩 HTML
const chipDef = [
  { key: "received",    label: "접수",   bg: "#FFF5F8", fg: "#C8789C" },
  { key: "cancelled",   label: "취소",   bg: "#FFE4E9", fg: "#E8344E" },
  { key: "submitted",   label: "제출",   bg: "#E4F0FF", fg: "#1F5DBF" },
  { key: "reprocessed", label: "재처리", bg: "#F0E6FA", fg: "#6F40A6" },
  { key: "action",      label: "조치 필요", bg: "#FDECEA", fg: "#DC2626" },
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
  section_action_html: sectionActionHtml,
  admin_pane_url: escapeHtml(adminPaneUrl),
});

// TEST 배너 본문 상단 삽입
const testBanner = `<div style="background:#FFF3CD;border-left:4px solid #FFA000;padding:10px 14px;margin:0 0 12px;border-radius:6px;font-family:'Noto Sans KR',Arial,sans-serif;color:#5A4500;font-size:13px"><strong>⚠️ TEST MAIL — 더미 데이터</strong><br>실제 데이터 아님. 메일 렌더링·깨짐 여부 확인용. <code style="background:#FFEAA7;padding:1px 6px;border-radius:3px">scripts/send-test-admin-digest.ts</code> 로 발송됨.</div>`;
html = html.replace('<div style="font-family:', testBanner + '<div style="font-family:');

const subject = `[TEST] 관리자 일일 요약 — ${digestDate} (총 ${totalCount}건 더미)`;

const textLines = [
  `[TEST] 관리자 일일 통합 요약 (${digestDate})`,
  `총 ${totalCount}건 더미 — 접수 ${sectionsSummary.received} · 취소 ${sectionsSummary.cancelled} · 제출 ${sectionsSummary.submitted} · 재처리 ${sectionsSummary.reprocessed} · 조치 필요 ${sectionsSummary.action}`,
  "",
  "실제 데이터 아님. 메일 렌더링·깨짐 여부 확인용.",
  "",
  `관리자 페이지: ${adminPaneUrl}`,
];
const text = textLines.join("\n");

// ── DRY_RUN — 발송하지 않고 본문만 파일로 ──────────────────────────
// ⚠️ 출력 파일은 저장소 밖(기본 /tmp)에 쓴다 — 커밋에 섞이지 않게.
if (dryRun) {
  const outPath = env("DRY_RUN_OUT", "/tmp/reverb-admin-digest-preview.html");
  // 🔴 문자 인코딩 선언을 씌운다 — 메일 본문은 `<div>` 로 시작하는 **조각**이라 `<meta charset>` 이 없다.
  //    실제 발송에서는 Brevo 가 보내는 헤더가 그 역할을 하지만, 파일로 열면 브라우저가 추측해
  //    **한국어가 통째로 깨진다**(2026-09-11 실측). 이 껍데기는 미리보기 전용이고 발송 본문에는 안 들어간다.
  const previewDoc = `<!DOCTYPE html>\n<meta charset="utf-8">\n<title>${escapeHtml(subject)}</title>\n${html}`;
  await Deno.writeTextFile(outPath, previewDoc);
  console.log(`📄 제목: ${subject}`);
  console.log(`📄 HTML 크기: ${html.length} bytes`);
  console.log(`📄 저장했습니다 — ${outPath}`);
  console.log("📄 브라우저로 열어 카드·정렬·숫자·링크를 눈으로 확인하세요. (발송하지 않았습니다)");
  Deno.exit(0);
}

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
