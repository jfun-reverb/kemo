// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-deliverable-decision
// ──────────────────────────────────────────────────────────────────
// 트리거: Supabase Database Webhook (notifications INSERT)
// 역할:   결과물(deliverables) 검수 알림 메일 자동 발송
//          - kind='deliverable_approved' / 'deliverable_rejected' 만 처리
//          - kind='deliverable_changed'(되돌리기) 는 메일 미발송 (알림 패널만)
//          - mail_sent_at IS NULL 가드로 중복 발송 차단
//
// 환경변수 (Edge Functions Secrets):
//   BREVO_API_KEY        Brevo Transactional API 키
//   BREVO_SENDER_EMAIL   발신자 이메일 (기본 noreply@globalreverb.com)
//   BREVO_SENDER_NAME    발신자 이름 (기본 환경별 REVERB JP 또는 REVERB JP [DEV])
//   PUBLIC_SITE_URL      인플루언서 사이트 루트 URL (기본 https://globalreverb.com)
//
// HTML 템플릿 (kind × status):
//   _templates/deliverable-receipt-approved.html
//   _templates/deliverable-receipt-rejected.html
//   _templates/deliverable-review-image-approved.html
//   _templates/deliverable-review-image-rejected.html
//   _templates/deliverable-post-approved.html
//   _templates/deliverable-post-rejected.html
//
//   원본은 docs/email-templates/ 에 있고, scripts/sync-email-templates.sh 가
//   _templates/ 로 복사한다. Edge Function 배포 직전 반드시 sync 실행.
//
// 멱등성:
//   1. 발송 직전 notifications.mail_sent_at 가 여전히 NULL 인지 재확인 (행 잠금).
//   2. Brevo 200 응답 후에만 mail_sent_at = now() 로 마킹.
//   3. 실패 시 NULL 유지 → 운영자가 수동 SQL 로 재발송 가능.
//
// 배포 명령:
//   bash scripts/sync-email-templates.sh
//   # 개발
//   supabase functions deploy notify-deliverable-decision --project-ref qysmxtipobomefudyixw
//   # 운영
//   supabase functions deploy notify-deliverable-decision --project-ref twofagomeizrtkwlhsuv
//   # 비밀값
//   supabase secrets set BREVO_API_KEY=xxx --project-ref <ref>
//
// Webhook 설정 (Supabase Dashboard → Database → Webhooks):
//   Table: notifications
//   Events: INSERT
//   Type: Supabase Edge Functions
//   Edge Function: notify-deliverable-decision
//   HTTP Method: POST
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface NotificationRow {
  id: string;
  user_id: string;
  kind: string;
  ref_table: string | null;
  ref_id: string | null;
  title: string | null;
  body: string | null;
  read_at: string | null;
  mail_sent_at: string | null;
  created_at: string;
}

interface WebhookPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  schema: string;
  record: NotificationRow;
  old_record?: NotificationRow | null;
}

// 메일 발송 대상 kind 화이트리스트 (확장은 이 배열만 수정)
const MAIL_KINDS = new Set(["deliverable_approved", "deliverable_rejected"]);

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

function fmtDateJa(iso?: string | null): string {
  if (!iso) return "-";
  try {
    const d = new Date(iso);
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const day = String(d.getDate()).padStart(2, "0");
    return `${y}/${m}/${day}`;
  } catch {
    return "-";
  }
}

// ──────────────────────────────────────────────────────────────────
// HTML 템플릿 로딩 + placeholder 치환
// _templates/*.html이 Edge Function 번들에 포함되지 않는 supabase CLI 동작 때문에
// templates.ts에 ES 모듈로 인라인 (번들러가 자동 dependency 포함)
// ──────────────────────────────────────────────────────────────────
import { TEMPLATES } from "./templates.ts";

async function loadTemplate(name: string): Promise<string> {
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

// 결과물 종류별 일본어 라벨 (제목 분기용)
function kindLabelJa(kind: string): string {
  if (kind === "receipt") return "レシート";
  if (kind === "review_image") return "レビュー画像";
  if (kind === "post") return "投稿URL";
  return "成果物";
}

// 템플릿 파일명: kind + decision (approved/rejected)
// kind는 DB 컬럼값(review_image — underscore)이지만 파일명은 review-image(hyphen) 컨벤션
function templateName(kind: string, decision: "approved" | "rejected"): string {
  // receipt / review_image / post 외 kind 는 fallback (receipt 템플릿 사용)
  const k = kind === "receipt" || kind === "review_image" || kind === "post" ? kind : "receipt";
  const kHyphen = k.replace(/_/g, "-");
  return `deliverable-${kHyphen}-${decision}`;
}

// 사용자 입력 URL을 href 에 안전하게 삽입하기 위한 검증.
// http(s) 외 스킴(javascript:, data: 등)을 차단해 XSS 위험 제거.
function safeUrl(url: string): string {
  if (!url) return "";
  try {
    const u = new URL(url);
    if (u.protocol === "http:" || u.protocol === "https:") return escapeHtml(url);
    return "";
  } catch {
    return "";
  }
}

// 승인 메일 캠페인 정보 — buildNextStepBlock 분기에 필요한 최소 칸.
// (기존엔 kind 하나만 보고 문구를 정해서, 모집 형식이 다른 캠페인에 틀린 안내가
//  나가고 있었다 — 2026-08-04 마감 안내 오발송 사고와 같은 뿌리. 전수조사 묶음 F.)
interface NextStepCampaign {
  recruit_type: string | null;
  proxy_purchase: boolean | null;
  channel: string | null;
  // 아래 두 칸은 완료 문구를 고르는 재료다(completionTail 참조).
  //   ⚠️ `undefined`(조회가 안 가져옴)와 `null`(데이터베이스가 비었다고 답함)을
  //   반드시 구분한다 — 앞은 "모른다", 뒤는 "없다"이고 문구가 갈린다.
  reward?: number | null;
  product_price?: number | null;
}

// 공통 스타일 헬퍼 — 파란(다음 단계 남음) / 초록(완료) 두 톤만 쓴다(기존 색 그대로 유지).
function nextStepBox(tone: "blue" | "green", bodyHtml: string): string {
  const bg = tone === "blue" ? "#F0F9FF" : "#F0FDF4";
  const border = tone === "blue" ? "#BAE6FD" : "#BBF7D0";
  const labelColor = tone === "blue" ? "#075985" : "#166534";
  return (
    `<div style="background:${bg};border:1px solid ${border};border-radius:8px;padding:16px 18px;margin-bottom:22px">` +
    `<div style="font-size:11px;font-weight:700;color:${labelColor};letter-spacing:0.06em;text-transform:uppercase;margin-bottom:8px">次のステップ</div>` +
    bodyHtml +
    `</div>`
  );
}

// 「전부 제출됐다」 뒤에 붙일 마지막 문장 — 세 갈래.
//
// 🔴 왜 갈래가 셋인가
//   제품만 주고 현금은 없는 캠페인(약관 제13조 3항)이 정상적으로 존재하는데, 이 메일은
//   그 사실을 모르고 **「담당자 최종 확인 후 보수 지급을 진행합니다」**를 보내 왔다.
//   지급은 영원히 없다 — 정산 후보를 고르는 함수가 그 형식을 **의도적으로 제외**하기
//   때문이다(마이그레이션 264 → 현재 원본 331 의 `reward IS NULL OR reward <= 0`).
//   실측(2026-09-02 운영): 무보수 당선 650건 중 **307건**이 이 문장을 실제로 받았다.
//
// ⚠️ 무보수와 「리뷰어형인데 제품 금액이 0」을 **한 갈래로 합치면 안 된다.** 둘은 결과가
//   반대다 — 무보수는 설계대로 영원히 안 주고, 리뷰어형 금액 0은 **관리자가 금액을
//   채우면 실제로 지급된다**(정산 후보에는 들고 `amount_issue` 로 보류될 뿐이다).
//   합쳐서 「참여해 주셔서 감사합니다」를 보내면 **줄 것을 안 준다고 말하는** 셈이라,
//   지금 결함을 정반대 방향의 같은 거짓말로 바꾸는 것이 된다.
//
// ⚠️ 무보수 문구에 「보수는 없습니다」라고 쓰지 않는다 — 회원은 응모 전에 이미 캠페인
//   상세에서 「製品無償提供」을 보고 신청했다. 다 끝난 시점에 없는 것을 다시 말하면
//   **주지 않는다는 통보**로 읽힌다.
//
// ⚠️ 모르면 중립이다. 이 파일의 기존 관례(`missingChannels === null` 갈래)와 같은
//   방향이고, 「보수 지급」을 기본값으로 두면 지금 결함이 그대로 남는다.
//   🔴 `undefined`(조회가 그 칸을 안 가져옴)와 `null`(데이터베이스가 "없다"고 답함)을
//   구분한다 — 앞은 모르는 것이라 중립, 뒤는 정산 함수와 같은 기준으로 "무보수"다.
function completionTail(camp: NextStepCampaign): string {
  const PAID    = "担当者の最終確認のうえ、報酬のお支払いを進めます。今しばらくお待ちください。";
  const UNPAID  = "ご参加ありがとうございました。";
  const NEUTRAL = "次のステップは「活動管理」でご確認ください。";

  const recruitType = camp.recruit_type || null;
  if (!recruitType) return NEUTRAL;           // 형식을 모르면 어느 갈래인지 못 고른다

  if (recruitType !== "monitor") {
    // 시딩·방문형 — 현금 리워드가 판정 재료다.
    if (camp.reward === undefined) return NEUTRAL;   // 조회가 안 가져옴 → 모름
    if ((camp.reward ?? 0) <= 0) return UNPAID;      // 정산 후보 함수와 같은 기준
    return PAID;
  }

  // 리뷰어형 — 지급액 상한이 제품 금액이다.
  if (camp.product_price === undefined) return NEUTRAL;
  if ((camp.product_price ?? 0) <= 0) return NEUTRAL; // 금액 미확정 → 감사 문구가 아니라 중립
  return PAID;
}

// ⚠️ sb 매개변수를 `ReturnType<typeof createClient>` 로 타이핑하지 않는다 — 오버로드된
//    제네릭 함수라 그 타입과 실제 호출부(핸들러 안의 const sb = createClient(...)) 타입이
//    구조적으로 어긋나 deno check 가 새 오류를 낸다(이 프로젝트의 다른 메일 함수에도
//    이미 있는 기존 결함, notify-influencer-daily-digest 등). 되돌리지 말 것.

// 채널 코드 → 일본어 라벨. lookup_values(kind='channel') 가 단일 소스(다른 메일 함수와 동일).
async function fetchChannelLabelMap(
  sb: any,
  codes: string[],
): Promise<Map<string, string>> {
  const map = new Map<string, string>();
  if (codes.length === 0) return map;
  const { data } = await sb
    .from("lookup_values")
    .select("code, name_ja")
    .eq("kind", "channel")
    .in("code", codes);
  (data || []).forEach((c: { code: string; name_ja: string | null }) => {
    if (c.name_ja) map.set(c.code, c.name_ja);
  });
  return map;
}

// review_image(리뷰 인증샷) 채널별 완성 여부 조회.
// 캠페인이 요구하는 채널마다 "최신 1건"이 approved 인지 확인 — 관리자 화면(computeCertStatus/
// _finalizeMonitorReprs)·정산 헬퍼(_settlement_cert_candidates 의 channel_cert CTE)와 같은 판정.
// ⚠️ 채널 비교는 항상 split(',') 후 대조(단일 === 비교 금지 — 멀티채널 누락 위험).
//   대소문자·트림 처리는 마이그레이션 300 과 동일하게: 캠페인 쪽 토큰만 trim, 결과물의
//   post_channel 값은 원본 그대로(대소문자 구분) — 다르게 하면 화면·정산과 또 갈린다.
// 반환값 null = 조회 실패(호출부는 "모르면 완료라고 말하지 않는다"로 처리할 것).
async function fetchMissingChannels(
  sb: any,
  applicationId: string,
  requiredChannels: string[],
  kind: "review_image" | "post",
): Promise<string[] | null> {
  const { data, error } = await sb
    .from("deliverables")
    .select("post_channel, status, submitted_at, updated_at")
    .eq("application_id", applicationId)
    .eq("kind", kind)
    .not("post_channel", "is", null)
    // 임시저장은 「아직 안 낸 것」 — 세지 않는다.
    //   지금은 채널당 행이 하나뿐이라(마이그레이션 158 의 중복 금지 + 재제출이 새 행 대신
    //   기존 행을 고침) 걸러도 결과가 같지만, 화면·정산(마이그레이션 318)이 모두 같은
    //   기준을 쓰므로 여기만 다르게 두지 않는다. 그 제약이 바뀌면 조용히 어긋난다.
    .neq("status", "draft");
  if (error) {
    console.error("[notify-deliverable-decision] review_image channel fetch failed", error);
    return null;
  }
  // 채널별 최신 1건(submitted_at desc, updated_at desc 타이브레이크) — buildDeliverableGroups 와 동일 기준.
  const latestByChannel = new Map<string, { status: string; submitted_at: string | null; updated_at: string | null }>();
  for (const row of (data || []) as { post_channel: string | null; status: string; submitted_at: string | null; updated_at: string | null }[]) {
    if (!row.post_channel) continue;
    const prev = latestByChannel.get(row.post_channel);
    if (!prev) {
      latestByChannel.set(row.post_channel, row);
      continue;
    }
    const a = row.submitted_at || "";
    const b = prev.submitted_at || "";
    if (a > b || (a === b && (row.updated_at || "") > (prev.updated_at || ""))) {
      latestByChannel.set(row.post_channel, row);
    }
  }
  return requiredChannels.filter((ch) => {
    const latest = latestByChannel.get(ch);
    return !latest || latest.status !== "approved";
  });
}

// 승인 메일에 들어갈 "다음 단계" 안내 블록 (kind × 모집 형식 별 분기).
//
// ⚠️ 예전엔 kind 하나만 보고 문구를 정해서 아래 두 가지가 틀린 안내로 나가고 있었다:
//   ① 영수증(receipt) 승인 → 무조건 "리뷰 인증샷을 내라" — 가구매(proxy_purchase) 캠페인은
//      영수증만 받고 인증샷을 요구하지 않는데도 내라고 했고, 방문형(visit)은 다음 단계가
//      리뷰 인증샷이 아니라 게시물 URL 인데도 같은 문구가 나갔다.
//   ② 리뷰 인증샷(review_image) 승인 → 무조건 "전부 제출 완료" — 캠페인이 요구하는 채널이
//      여러 개인데 1채널만 승인돼도 이 문구가 가서, 받은 사람이 나머지 채널을 안 냈다.
// 판정 근거는 dev/js/admin-deliverables.js 의 computeCertStatus·_finalizeMonitorReprs 및
// 마이그레이션 300 의 _settlement_cert_candidates()(channel_cert CTE)와 어긋나지 않게 맞췄다.
//
// post(시딩·방문형 게시물) 분기도 **마이그레이션 331 로 채널 완성도 판정이 추가됐다**(2026-08-10).
// ⚠️ 이 자리에는 원래 「게시물 1건이면 인증 성공이라 기존 '전부 완료' 문구가 시스템 판정과
// 이미 일치한다」고 적혀 있었다. 그 근거였던 규칙(300 의 post_latest — 채널을 안 봄)을
// **331 이 뒤집었다** — 요구한 채널 전부가 승인돼야 성공이다. 주석을 안 고쳤으면
// 다음 사람이 「post 는 손대지 않은 자리」로 읽었을 것이다. 아래 분기 참조.
//
// rejected 케이스에서는 호출되지 않음(템플릿 자체가 다름).
async function buildNextStepBlock(
  sb: any,
  kind: string,
  applicationId: string,
  camp: NextStepCampaign,
): Promise<string> {
  const recruitType = camp.recruit_type || null;
  const isMonitor = recruitType === "monitor";
  const isProxyPurchase = isMonitor && !!camp.proxy_purchase;

  if (kind === "receipt") {
    // 방문형(visit)은 receipt 가 "현장 사진" 이고, 다음 단계는 게시물 URL 제출이다
    // (인증 성공 판정은 post 단독 — visit 은 receipt 를 안 본다. CLAUDE.md 활동관리 §참조).
    if (recruitType === "visit") {
      return nextStepBox(
        "blue",
        `<div style="font-size:13px;color:#0C4A6E;line-height:1.7;margin-bottom:10px"><strong>次のステップ — 投稿URLの提出</strong></div>` +
        `<div style="font-size:13px;color:#222;line-height:1.7">現地写真が承認されました。次は「活動管理」からSNS投稿のURLを提出してください。</div>`,
      );
    }
    // 가구매(proxy_purchase): 영수증만 받는 캠페인 — 리뷰 인증샷 제출 자체가 없다.
    // (computeCertStatus 의 proxy_purchase 분기와 동일 기준 — 영수증 승인 = 인증 성공)
    if (isProxyPurchase) {
      return nextStepBox(
        "green",
        `<div style="font-size:13px;color:#222;line-height:1.7"><strong>全ての提出が完了しました。</strong>${completionTail(camp)}</div>`,
      );
    }
    // 리뷰어형(monitor) 일반 — 기존 STEP 2 안내(변경 없음).
    if (isMonitor) {
      return nextStepBox(
        "blue",
        `<div style="font-size:13px;color:#0C4A6E;line-height:1.7;margin-bottom:10px"><strong>STEP 2 — レビュー画像の提出</strong></div>` +
        `<div style="font-size:13px;color:#222;line-height:1.7">レシートが承認されました。掲載されたレビューのスクリーンショットを「活動管理」からアップロードしてください。</div>`,
      );
    }
    // gifting 등 receipt 를 원래 제출하지 않는 형식·recruit_type 미상 — 데이터가 예상과 다른
    // 방어적 상황. 「완료」도「다음 단계는 이것」도 단정하지 않고 활동관리 확인만 안내한다
    // (모르면 완료라고 말하지 않는다).
    return nextStepBox(
      "blue",
      `<div style="font-size:13px;color:#222;line-height:1.7">レシートが承認されました。次のステップは「活動管理」でご確認ください。</div>`,
    );
  }

  if (kind === "review_image") {
    // review_image 는 현재 UI 상 리뷰어형(monitor)·가구매 아님 캠페인에서만 발생한다.
    // 예상과 다른 조합(recruit_type 이 monitor 가 아니거나 가구매)이 들어오면 방어적으로
    // 완료를 단정하지 않는다.
    if (!isMonitor || isProxyPurchase) {
      return nextStepBox(
        "blue",
        `<div style="font-size:13px;color:#222;line-height:1.7">レビュー画像が承認されました。次のステップは「活動管理」でご確認ください。</div>`,
      );
    }
    const requiredChannels = (camp.channel || "")
      .split(",").map((c) => c.trim()).filter(Boolean);
    // 채널이 지정되지 않은 옛(레거시) 캠페인 — 채널별 판정 자체가 불가능하다.
    //   ⚠️ 여기서 "전부 완료"라고 말하면 안 된다. 이 캠페인은 시스템 어디서도 인증 성공이
    //   되지 않는다 — 화면 판정(_finalizeMonitorReprs)은 채널이 0개면 'approved' 로
    //   갈 경로 자체가 없고, 정산 판정(마이그레이션 300·318)도 채널이 비면 후보에 안 든다.
    //   즉 "담당자 확인 후 보수를 지급합니다"는 지켜지지 않을 약속이 된다.
    //   이 분기가 고치려던 실패 유형(시스템 판정보다 앞서가는 완료 약속)을 조건만 바꿔
    //   되풀이하는 자리라, 아래 다른 방어 분기와 같은 중립 문구로 맞춘다.
    if (requiredChannels.length === 0) {
      return nextStepBox(
        "blue",
        `<div style="font-size:13px;color:#222;line-height:1.7">レビュー画像が承認されました。次のステップは「活動管理」でご確認ください。</div>`,
      );
    }
    const missingChannels = await fetchMissingChannels(sb, applicationId, requiredChannels, "review_image");
    // 조회 실패 — 완료 여부를 모르는 채 "완료"라고 말하지 않는다. 최소한의 진행 상황만 전달.
    if (missingChannels === null) {
      return nextStepBox(
        "blue",
        `<div style="font-size:13px;color:#222;line-height:1.7">レビュー画像が承認されました。他のチャンネル分の提出状況は「活動管理」でご確認ください。</div>`,
      );
    }
    if (missingChannels.length === 0) {
      return nextStepBox(
        "green",
        `<div style="font-size:13px;color:#222;line-height:1.7"><strong>全ての提出が完了しました。</strong>${completionTail(camp)}</div>`,
      );
    }
    // 아직 남은 채널이 있다 — 요구 채널이 2개 이상일 때만 이름을 병기(단일 채널이면
    // 군더더기라 daily-digest 메일과 같은 기준으로 생략).
    let missingLabel = "他のチャンネル分";
    if (requiredChannels.length >= 2) {
      const labelMap = await fetchChannelLabelMap(sb, missingChannels);
      // 이름을 못 찾으면 코드값(channel-96r9y3 같은 것)을 그대로 보여주지 않는다.
      //   그런 값이 메일에 실리면 받는 사람은 무엇을 내야 하는지 알 수 없다.
      //   기준 데이터에서 채널이 사라지는 일은 실제로 있었다(채널 코드 이관 사고).
      const labels = missingChannels.map((ch) => labelMap.get(ch)).filter(Boolean) as string[];
      missingLabel = labels.length === missingChannels.length
        ? labels.join("・")
        : "他のチャンネル分";
    }
    return nextStepBox(
      "blue",
      `<div style="font-size:13px;color:#0C4A6E;line-height:1.7;margin-bottom:10px"><strong>次のステップ — 残りのレビュー画像の提出</strong></div>` +
      `<div style="font-size:13px;color:#222;line-height:1.7">${escapeHtml(missingLabel)}のレビュー画像がまだ未提出、または未承認です。「活動管理」から提出してください。</div>`,
    );
  }

  if (kind === "post") {
    // ⚠️ 예전에는 여기서 무조건 「전부 완료·지급 준비」라고 했다. 근거는 「시딩·방문형은
    //   승인된 게시물 1건이면 인증 성공」이었는데, **마이그레이션 331 이 그 규칙을 뒤집었다**
    //   (요구한 채널 전부가 승인돼야 성공 — 2026-08-10 사용자 결정).
    //   그대로 두면 **서버는 지급 대상이 아닌데 메일은 지급을 예고**한다. 리뷰 인증샷 분기와
    //   같은 방식으로 채널 완성 여부를 본다.
    const requiredChannels = (camp.channel || "")
      .split(",").map((c) => c.trim()).filter(Boolean);
    // 채널이 기록 안 된 옛 캠페인 — 판정할 근거가 없다. 서버 판정에서도 인증 성공이 되지 않으므로
    //   완료를 단정하지 않는다(리뷰 인증샷 분기와 같은 판단).
    if (requiredChannels.length === 0) {
      return nextStepBox(
        "blue",
        `<div style="font-size:13px;color:#222;line-height:1.7">投稿URLが承認されました。次のステップは「活動管理」でご確認ください。</div>`,
      );
    }
    const missingChannels = await fetchMissingChannels(sb, applicationId, requiredChannels, "post");
    if (missingChannels === null) {
      return nextStepBox(
        "blue",
        `<div style="font-size:13px;color:#222;line-height:1.7">投稿URLが承認されました。他のチャンネル分の提出状況は「活動管理」でご確認ください。</div>`,
      );
    }
    if (missingChannels.length === 0) {
      return nextStepBox(
        "green",
        `<div style="font-size:13px;color:#222;line-height:1.7"><strong>投稿URLの審査が完了しました。</strong>${completionTail(camp)}</div>`,
      );
    }
    let missingLabel = "他のチャンネル分";
    if (requiredChannels.length >= 2) {
      const labelMap = await fetchChannelLabelMap(sb, missingChannels);
      const labels = missingChannels.map((ch) => labelMap.get(ch)).filter(Boolean) as string[];
      missingLabel = labels.length === missingChannels.length ? labels.join("・") : "他のチャンネル分";
    }
    return nextStepBox(
      "blue",
      `<div style="font-size:13px;color:#0C4A6E;line-height:1.7;margin-bottom:10px"><strong>次のステップ — 残りの投稿URLの提出</strong></div>` +
      `<div style="font-size:13px;color:#222;line-height:1.7">${escapeHtml(missingLabel)}の投稿URLがまだ未提出、または未承認です。「活動管理」から提出してください。</div>`,
    );
  }
  return "";
}


// ── 공개 키로 부르는 것을 막는다 ────────────────────────────────
// 🔴 이 함수는 **메일을 보낸다.** 막는 것이 없으면 사이트에 박힌 공개 키만으로
//    누구나 발송을 시킬 수 있다(2026-09-02 전수조사 — 같은 형태가 여섯 개였다).
// ⚠️ 공개 키를 교체하면 이 목록도 함께 갱신할 것.
const PUBLIC_CLIENT_KEYS = [
  "sb_publishable_3pfK7sF55NZO7owlm13_uA_iCbORAvP",  // 운영
  "sb_publishable_WTxFsvQFllOPIdQ8MDNwCw_e0qBlYTv",  // 개발
];

function rejectPublicKeyCaller(req: Request, tag: string): boolean {
  const raw = (req.headers.get("Authorization") ?? "").trim();
  const token = raw.replace(/^Bearer\s+/i, "").trim();
  if (!token) return false;                       // 토큰 없음 — 플랫폼이 이미 막는다
  if (PUBLIC_CLIENT_KEYS.includes(token)) {
    console.warn(`[${tag}] rejected — called with the public client key`);
    return true;
  }
  // 토큰 자체는 절대 남기지 않는다.
  const isServiceRole = token === (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
  console.log(`[${tag}] caller check passed`, { isServiceRole });
  return false;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }
  if (rejectPublicKeyCaller(req, "notify-deliverable-decision")) {
    return new Response(JSON.stringify({ error: "forbidden" }), {
      status: 403,
      headers: { "content-type": "application/json" },
    });
  }

  let payload: WebhookPayload;
  try {
    payload = (await req.json()) as WebhookPayload;
  } catch (e) {
    return new Response(JSON.stringify({ error: `invalid json: ${(e as Error).message}` }), {
      status: 400,
      headers: { "content-type": "application/json" },
    });
  }

  console.log("[notify-deliverable-decision] payload received", {
    type: payload?.type,
    table: payload?.table,
    record_id: payload?.record?.id,
    kind: payload?.record?.kind,
  });

  // INSERT on notifications 만 처리
  if (payload.type !== "INSERT" || payload.table !== "notifications") {
    return new Response(JSON.stringify({ skipped: true, reason: "non-insert-or-wrong-table" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  const note = payload.record;
  if (!note?.id || !note.kind || !note.user_id) {
    console.error("[notify-deliverable-decision] invalid payload", { note });
    return new Response(JSON.stringify({ error: "invalid payload" }), {
      status: 400,
      headers: { "content-type": "application/json" },
    });
  }

  // kind 화이트리스트 필터: 메일 대상 아닌 알림은 즉시 종료
  if (!MAIL_KINDS.has(note.kind)) {
    console.log("[notify-deliverable-decision] kind not in MAIL_KINDS, skipped", { kind: note.kind });
    return new Response(JSON.stringify({ skipped: true, reason: `kind=${note.kind}` }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  // ref_table이 deliverables가 아니면 무시 (방어적)
  if (note.ref_table !== "deliverables" || !note.ref_id) {
    console.log("[notify-deliverable-decision] ref_table not deliverables, skipped", { ref_table: note.ref_table });
    return new Response(JSON.stringify({ skipped: true, reason: "ref_table_mismatch" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  // 멱등성 1차: 페이로드의 mail_sent_at가 이미 채워져 있으면 즉시 종료
  if (note.mail_sent_at) {
    console.log("[notify-deliverable-decision] already sent (payload), skipped", { mail_sent_at: note.mail_sent_at });
    return new Response(JSON.stringify({ skipped: true, reason: "already_sent_payload" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) {
    console.error("[notify-deliverable-decision] missing supabase env");
    return new Response(JSON.stringify({ error: "missing supabase env" }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }

  const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

  // 멱등성 2차: 발송 직전 DB 재확인 (Webhook 재실행 등 race 방지)
  const { data: noteCheck, error: noteCheckErr } = await sb
    .from("notifications")
    .select("id, mail_sent_at")
    .eq("id", note.id)
    .maybeSingle();
  if (noteCheckErr) {
    console.error("[notify-deliverable-decision] note re-check failed", noteCheckErr);
    return new Response(JSON.stringify({ error: noteCheckErr.message }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
  if (noteCheck?.mail_sent_at) {
    console.log("[notify-deliverable-decision] already sent (db re-check), skipped");
    return new Response(JSON.stringify({ skipped: true, reason: "already_sent_db" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  // 결과물 + 캠페인 + 인플루언서 정보 조회
  // application_id·campaigns.recruit_type/proxy_purchase/channel 은 buildNextStepBlock 이
  // "다음 단계" 안내를 모집 형식별로 분기하는 데 필요(2026-08 전수조사 묶음 F).
  const { data: deliv, error: delivErr } = await sb
    .from("deliverables")
    .select(`
      id, application_id, kind, status, post_url, post_channel,
      submitted_at, reviewed_at, reject_reason,
      campaigns:campaign_id (id, title, brand, recruit_type, proxy_purchase, channel, reward, product_price)
    `)
    .eq("id", note.ref_id)
    .maybeSingle();
  if (delivErr || !deliv) {
    console.error("[notify-deliverable-decision] deliverable fetch failed", delivErr);
    return new Response(JSON.stringify({ error: "deliverable not found" }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }

  const { data: inf, error: infErr } = await sb
    .from("influencers")
    .select("id, email, name, name_kanji")
    .eq("id", note.user_id)
    .maybeSingle();
  // 인플루언서 행 누락(legacy id 어긋남·탈퇴) 또는 이메일 없음 → graceful skip
  // 알림은 "처리됨"으로 마킹해 같은 알림에 대한 Webhook 재시도 차단
  if (infErr || !inf?.email) {
    console.warn("[notify-deliverable-decision] influencer not found or no email — graceful skip", {
      record_id: note.id,
      user_id: note.user_id,
      reason: infErr ? "fetch_error" : (!inf ? "no_row" : "no_email"),
    });
    await sb.from("notifications").update({ mail_sent_at: new Date().toISOString() })
      .eq("id", note.id).is("mail_sent_at", null);
    return new Response(JSON.stringify({ skipped: "influencer not found or email missing" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  const decision: "approved" | "rejected" = note.kind === "deliverable_approved" ? "approved" : "rejected";
  const camp = (deliv as any).campaigns || {};
  const siteUrl = env("PUBLIC_SITE_URL", "https://globalreverb.com");
  const helpLineUrl = "https://line.me/R/ti/p/@reverb.jp";
  const activityLink = `${siteUrl.replace(/\/$/, "")}/#mypage-applications`;
  const influencerName = inf.name_kanji || inf.name || "";
  const kindLabel = kindLabelJa(deliv.kind);

  // 제목: notifications.title이 있으면 그대로 사용 (트리거가 이미 캠페인명 + 종류별 라벨 조합)
  // 폴백: 캠페인명 + 종류 라벨 + 결정
  const subject = note.title || `${camp.title || "キャンペーン"} — ${kindLabel}が${decision === "approved" ? "承認" : "差し戻し"}されました`;

  // 반려 사유 박스 (rejected 전용)
  const rejectReasonBlock = decision === "rejected" && deliv.reject_reason
    ? `<div style="background:#FFF5F7;border-left:4px solid #E8344E;border-radius:0 8px 8px 0;padding:14px 18px;margin-bottom:22px">` +
      `<div style="font-size:11px;font-weight:700;color:#A02038;letter-spacing:0.06em;text-transform:uppercase;margin-bottom:6px">差し戻し理由</div>` +
      `<div style="font-size:13px;color:#222;line-height:1.7;white-space:pre-wrap;word-break:break-word">${escapeHtml(deliv.reject_reason)}</div>` +
      `</div>`
    : "";

  // 승인 케이스에만 들어가는 다음 단계 안내 블록 (kind × 모집 형식 별 분기).
  // ⚠️ 이 블록을 만드는 데 데이터베이스 조회가 최대 2회 들어간다(채널 완성 여부·채널 이름).
  //    예전엔 문자열 조립뿐이라 실패할 수 없었다. 여기서 예외가 밖으로 나가면
  //    **검수 결과 메일 자체가 통째로 안 나가고**(mail_sent_at 이 비어 손으로 복구해야 한다),
  //    인플루언서는 승인·반려 사실을 아예 못 받는다. 안내 한 줄보다 메일이 나가는 게 먼저다.
  let nextStepBlock = "";
  if (decision === "approved") {
    try {
      nextStepBlock = await buildNextStepBlock(sb, deliv.kind, (deliv as any).application_id, camp as NextStepCampaign);
    } catch (e) {
      console.error("[notify-deliverable-decision] next step block failed — sending without it", e);
      nextStepBlock = "";
    }
  }

  // 템플릿 변수 빌드 (placeholder 키는 모든 6개 템플릿에서 공통)
  // post_url 은 href 속성에 들어가므로 http(s) 스킴만 통과시키는 safeUrl 적용.
  const templateData: Record<string, string> = {
    influencer_name: escapeHtml(influencerName || "-"),
    campaign_title: escapeHtml(camp.title || "-"),
    campaign_brand: escapeHtml(camp.brand || "-"),
    submitted_at: fmtDateJa(deliv.submitted_at),
    reviewed_at: fmtDateJa(deliv.reviewed_at),
    reject_reason_block: rejectReasonBlock,
    next_step_block: nextStepBlock,
    post_url: safeUrl(deliv.post_url || ""),
    post_channel: escapeHtml(deliv.post_channel || ""),
    activity_link: activityLink,
    site_url: siteUrl,
    help_line_url: helpLineUrl,
  };

  const tplName = templateName(deliv.kind, decision);
  let tpl: string;
  try {
    tpl = await loadTemplate(tplName);
  } catch (e) {
    console.error("[notify-deliverable-decision] template load failed", { tplName, err: (e as Error).message });
    return new Response(JSON.stringify({ error: `template not found: ${tplName}` }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }

  const html = render(tpl, templateData);

  // 텍스트 본문: 제목 + 캠페인 + 종류 + 결정 + 활동관리 링크 (간소화)
  const textLines = [
    `${camp.title || "キャンペーン"} — ${kindLabel}${decision === "approved" ? "が承認されました" : "が差し戻されました"}`,
    "",
    `${influencerName ? influencerName + " 様" : ""}`,
    decision === "approved"
      ? `提出いただいた${kindLabel}が承認されました。`
      : `提出いただいた${kindLabel}を確認したところ、差し戻しとさせていただきました。`,
    "",
    `キャンペーン: ${camp.title || "-"}`,
    `ブランド: ${camp.brand || "-"}`,
    `提出日: ${fmtDateJa(deliv.submitted_at)}`,
    decision === "approved" ? `承認日: ${fmtDateJa(deliv.reviewed_at)}` : `差し戻し日: ${fmtDateJa(deliv.reviewed_at)}`,
  ];
  if (decision === "rejected" && deliv.reject_reason) {
    textLines.push("");
    textLines.push("差し戻し理由:");
    textLines.push(deliv.reject_reason);
  }
  textLines.push("");
  textLines.push(`活動管理: ${activityLink}`);
  textLines.push(`お問い合わせ LINE: ${helpLineUrl}`);
  const text = textLines.join("\n");

  // Brevo 발송
  try {
    console.log("[notify-deliverable-decision] sending email", { to: inf.email, subject, kind: deliv.kind, decision });
    await sendBrevoEmail({
      to: [{ email: inf.email, name: influencerName || undefined }],
      subject,
      htmlContent: html,
      textContent: text,
    });
  } catch (e) {
    console.error("[notify-deliverable-decision] brevo send failed", (e as Error).message);
    return new Response(JSON.stringify({ error: (e as Error).message, sent: false }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }

  // 발송 성공 → mail_sent_at 마킹
  const { error: markErr } = await sb
    .from("notifications")
    .update({ mail_sent_at: new Date().toISOString() })
    .eq("id", note.id)
    .is("mail_sent_at", null);
  if (markErr) {
    console.error("[notify-deliverable-decision] mark mail_sent_at failed", markErr);
    // 메일은 이미 나갔으므로 200 으로 응답하되 경고 로그만
  }

  console.log("[notify-deliverable-decision] done", { id: note.id, kind: deliv.kind, decision });
  return new Response(JSON.stringify({ sent: true, kind: deliv.kind, decision }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
});
