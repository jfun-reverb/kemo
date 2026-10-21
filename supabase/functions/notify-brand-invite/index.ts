// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-brand-invite
// ──────────────────────────────────────────────────────────────────
// 트리거: 브랜드 대표가 멤버 관리 화면에서 「초대」/「다시 보내기」를 눌러 create_brand_invite /
//          resend_brand_invite 가 성공한 뒤, 화면이 supabase.functions.invoke 로 직접 호출.
//          → 브라우저 직접 호출이라 CORS + OPTIONS 필수. 공개 키 거부는 걸지 않는다.
//          (마이그레이션 530~532, 작업표 docs/specs/2026-10-15-brand-member-breakdown.md 작업 5)
//
// 복제 원본: notify-brand-account-setup (CORS·개발서버 두 겹 잠금·Brevo 발송·템플릿 렌더 그대로). 차이 —
//   · 호출자: 관리자가 아니라 「그 초대 브랜드의 현재 대표(owner, active)」인 브랜드 계정
//   · 받는 사람·갈래(recipient_kind)·링크 번호는 요청이 아니라 brand_invites 줄에서 다시 읽는다(요청에는 invite_id 뿐)
//   · 일회용 인증 링크를 만들지 않는다 — 링크는 우리 링크 번호만(감출 토큰 없음). 수락은 화면+서버 함수 몫
//   · 선점 먼저: mail_sent_link_id 가 지금 link_id 가 아닐 때만 그 값으로 바꾸고 보낸다. 실패하면 되돌린다
//
// 🔴 「연결 요청」 갈래(brand_invites.invite_kind='owner_link' — 사양서 docs/specs/2026-10-21-brand-link-request.md 4-3 · B8)
//   · 관리자가 기존 브랜드 계정을 대표 담당자 없는 브랜드의 대표로 이을 때(admin_request_brand_owner_link 뒤 관리자 화면이 부른다)
//   · 줄을 읽자마자 **종류로 먼저 가른다** — member 줄 = 그 브랜드의 현재 대표만 / owner_link 줄 = 호출자 토큰의
//     has_permission('brand.account_manage','write') 가 참인 관리자만. 두 판정을 섞지 않는다(대표가 연결 요청을, 관리자가 멤버 초대를 보내면 403)
//   · 판정은 선점 전 한 번·선점 뒤 한 번(브랜드 활성 재확인과 함께) — 멤버 초대 갈래의 대표 확인과 같은 자리
//   · 양식 brand-link-request 하나 — 받는 계정이 비밀번호를 정했든 안 정했든 같은 메일·같은 링크(화면이 가른다)
//   · 보낸 사람은 「REVERB 운영팀」(L4 — inviter_name 칸을 읽지 않는다)
//   · 응답 모양·선점·기록·두 겹 잠금은 멤버 초대와 같다. 갈래를 응답에 싣지 않는다
//   🔴 배포는 invite_kind 칸이 있는 데이터베이스에서만(마이그레이션 577 — 연결 1). 칸이 없으면 조회가 실패해 멤버 초대 메일까지 500 이 된다
//
// 요청:  POST { invite_id: uuid }  + Authorization: Bearer <브랜드 계정 로그인 토큰 | 연결 요청이면 관리자 로그인 토큰>
// 응답:  200 { sent:true }
//        200 { sent:true, dev_mail:{ subject, text } }            ← 개발서버 두 겹 잠금일 때만(메일 안 보냄)
//        200 { sent:false, reason:'not_pending' | 'already_sent' | 'send_failed' }
//        400 { sent:false, reason:'invalid_request' } · 401 { reason:'unauthorized' } · 403 { reason:'forbidden' }
//        500 { sent:false, reason:'server_error' }
//  🔴 갈래(ⓐ new / ⓑ brand / ⓒ blocked)는 응답에 싣지 않는다. 대표가 「이 이메일이 다른 브랜드 계정/관리자/인플루언서」
//     임을 알게 되면 안 된다. dev_mail 도 ⓐⓑⓒ 모두 같은 키 집합({subject, text})이다.
//
// 🔴 개발서버 「메일 대신 본문 표시」 두 겹 잠금 (notify-brand-account-setup 과 같은 방식·같은 스위치)
//    ① 환경변수 BRAND_SETUP_DEV_ECHO === "1"  (개발서버에만 넣는다)
//    ② 이 함수가 도는 프로젝트 주소가 개발서버(STAGING_PROJECT_REF)
//    둘 다 참일 때만 메일을 보내지 않고 응답에 제목·본문(링크 포함)을 싣는다.
//    ⚠️ 하나라도 지우면 운영에서 초대 링크가 응답에 실린다. 운영에는 BRAND_SETUP_DEV_ECHO 를 넣지 않는다.
//    ⚠️ 이 모드에서는 선점(mail_sent_link_id)은 하되 mail_sent_at 은 남기지 않는다 — 실제로 메일이 나가지 않았다.
//       그래서 같은 링크로 다시 부르면 already_sent 이고, 다시 시험하려면 「다시 보내기」(새 링크)로 한다.
//
// 로그에는 링크·토큰·본문·이메일을 남기지 않는다(초대 번호 앞 8자리와 결과만).
//
// 환경변수 (Edge Functions Secrets) — 새 비밀값 없음, notify-brand-account-setup 과 같은 것:
//   BREVO_API_KEY · PUBLIC_BRAND_URL(기본값 없음) · BRAND_SETUP_DEV_ECHO(개발만) ·
//   BREVO_SENDER_EMAIL / BREVO_SENDER_NAME · SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY(자동 주입)
//
// 템플릿: templates.ts (sync-email-templates.sh 자동 생성) → TEMPLATES['brand-invite-new' | 'brand-invite-existing' | 'brand-invite-blocked' | 'brand-link-request']
//
// 배포 (개발 → 운영):
//   bash scripts/sync-email-templates.sh
//   supabase functions deploy notify-brand-invite --project-ref qysmxtipobomefudyixw
//   (비밀값은 notify-brand-account-setup 에 이미 넣었으면 같은 프로젝트라 추가 없음)
//   (운영) supabase functions deploy notify-brand-invite --project-ref nrwtujmlbktxjgdwlpjj  ← 운영 관문 뒤에만
//
// 메일 발송 테스트는 운영에서만 (supabase.md 정책). 개발은 OPTIONS·401·403·dev_mail 로만 확인.
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TEMPLATES } from "./templates.ts";

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";
const STAGING_PROJECT_REF = "qysmxtipobomefudyixw";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// CORS — 브랜드 화면(globalreverb.com 등)이 *.supabase.co 를 직접 부르는 교차 출처 호출.
// 인증은 아래 토큰 검증 + 대표 연결 검사로 별도 보장한다.
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "content-type": "application/json" },
  });
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

// 제목 끝에 붙이는 보낸 시각(일본·한국 시각 「MM/DD HH:MM」) — 같은 제목이면 메일 앱이 한 대화로 묶어 앞 메일 끝부분을 접는다(2026-10-20 사용자 결정)
// ⚠️ 같은 함수가 notify-brand-account-setup · brand-password-reset-request · notify-brand-invite 에 한 벌씩 있다
function kstStamp(d = new Date()): string {
  const k = new Date(d.getTime() + 9 * 3600 * 1000);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${p(k.getUTCMonth() + 1)}/${p(k.getUTCDate())} ${p(k.getUTCHours())}:${p(k.getUTCMinutes())}`;
}

// 🔴 두 겹 잠금 — 위 머리말 참고. 둘 중 하나라도 빼지 말 것.
function devEchoEnabled(): boolean {
  return env("BRAND_SETUP_DEV_ECHO") === "1"
    && env("SUPABASE_URL").includes(`://${STAGING_PROJECT_REF}.`);
}

async function sendBrevoEmail(params: {
  to: { email: string; name?: string }[];
  subject: string;
  htmlContent: string;
  textContent: string;
}): Promise<void> {
  const apiKey = env("BREVO_API_KEY");
  if (!apiKey) throw new Error("BREVO_API_KEY not configured");

  const res = await fetch(BREVO_ENDPOINT, {
    method: "POST",
    signal: AbortSignal.timeout(10_000),   // 함수 실행 한도 안쪽 — 멈추면 호출부가 선점을 되돌린다
    headers: { "api-key": apiKey, "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      sender: {
        email: env("BREVO_SENDER_EMAIL", "noreply@globalreverb.com"),
        name: env("BREVO_SENDER_NAME", "REVERB JP"),
      },
      to: params.to,
      subject: params.subject,
      htmlContent: params.htmlContent,
      textContent: params.textContent,
    }),
  });
  if (!res.ok) {
    // 응답 본문에 수신 주소가 들어올 수 있어 상태 코드만 남긴다
    throw new Error(`Brevo send failed ${res.status}`);
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405, headers: CORS_HEADERS });
  }

  try {
    let body: { invite_id?: unknown } = {};
    try { body = await req.json(); } catch (_) { /* 아래에서 invalid_request 로 수렴 */ }
    const inviteId = typeof body.invite_id === "string" ? body.invite_id.trim() : "";
    if (!UUID_RE.test(inviteId)) {
      return jsonResponse({ sent: false, reason: "invalid_request" }, 400);
    }
    const tag = inviteId.slice(0, 8);

    const supaUrl = env("SUPABASE_URL");
    const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = env("SUPABASE_ANON_KEY");
    if (!supaUrl || !serviceKey) throw new Error("Supabase service credentials not configured");
    // 링크 도메인은 서버 설정만 믿는다. 기본값을 두면 운영에서 설정을 빠뜨렸을 때 개발 주소로 메일이 나간다.
    const brandBase = env("PUBLIC_BRAND_URL").replace(/\/$/, "");
    if (!/^https:\/\/[^/\s]+$/.test(brandBase)) throw new Error("PUBLIC_BRAND_URL not configured");

    const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

    // 1) 호출자 인증 — anon 키는 공개되므로 JWT 검증 필수.
    const authHeader = req.headers.get("Authorization") ?? "";
    const userSb = createClient(supaUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false },
    });
    const { data: authData } = await userSb.auth.getUser();
    const caller = authData?.user;
    if (!caller) {
      return jsonResponse({ sent: false, reason: "unauthorized" }, 401);
    }

    // 2) 초대 줄을 읽는다(받는 사람·갈래·링크는 여기서만 — 요청 본문은 id 뿐).
    //    없는 초대도 forbidden 으로 답한다(초대 번호가 존재하는지 알려 주지 않는다).
    const { data: inv, error: invErr } = await sb
      .from("brand_invites")
      .select("id, brand_id, email, inviter_name, status, recipient_kind, link_id, expires_at, mail_sent_link_id, invite_kind")
      .eq("id", inviteId)
      .maybeSingle();
    if (invErr) throw invErr;
    if (!inv) return jsonResponse({ sent: false, reason: "forbidden" }, 403);

    // 3) 종류로 먼저 가른 뒤 호출자 판정 — 두 판정을 섞지 않는다(머리말 「연결 요청」 갈래).
    //    member     = 그 초대 브랜드의 「현재」 대표인가(대표를 넘긴 옛 대표·멤버·무관 계정은 403)
    //    owner_link = 호출자 토큰으로 has_permission('brand.account_manage','write')(notify-brand-account-setup 과 같은 판정).
    //                 판정 호출 자체가 실패하면 403 이 아니라 예외로 — 권한 없음과 서버 문제를 섞지 않는다.
    const inviteKind = String(inv.invite_kind);
    if (inviteKind !== "member" && inviteKind !== "owner_link") {
      throw new Error("unknown invite_kind");
    }
    const isOwnerLink = inviteKind === "owner_link";
    const callerAllowed = async (): Promise<boolean> => {
      if (isOwnerLink) {
        const { data: allowed, error: permErr } = await userSb.rpc("has_permission", {
          p_feature: "brand.account_manage",
          p_min: "write",
        });
        if (permErr) throw permErr;
        return allowed === true;
      }
      const { data: ownerLink, error: ownerErr } = await sb
        .from("brand_account_links")
        .select("auth_id")
        .eq("brand_id", inv.brand_id)
        .eq("auth_id", caller.id)
        .eq("role", "owner")
        .eq("status", "active")
        .maybeSingle();
      if (ownerErr) throw ownerErr;
      return !!ownerLink;
    };
    if (!(await callerAllowed())) return jsonResponse({ sent: false, reason: "forbidden" }, 403);

    // 4) 아직 보낼 수 있는 초대인가 — 대기 + 만료 전 + 브랜드 활성(수락 가능 판정과 같은 조건 중 메일에 필요한 것)
    const { data: brandRow } = await sb
      .from("brands")
      .select("name, status")
      .eq("id", inv.brand_id)
      .maybeSingle();
    if (
      inv.status !== "pending" ||
      !(new Date(inv.expires_at).getTime() > Date.now()) ||
      !brandRow || brandRow.status !== "active"
    ) {
      return jsonResponse({ sent: false, reason: "not_pending" }, 200);
    }
    const kind = String(inv.recipient_kind);
    if (kind !== "new" && kind !== "brand" && kind !== "blocked") {
      throw new Error("unknown recipient_kind");
    }
    // 연결 요청은 늘 기존 브랜드 계정 앞이다(검사 제약 brand_invites_owner_link_recipient_check — 577)
    if (isOwnerLink && kind !== "brand") throw new Error("owner_link with non-brand recipient");

    // 5-앞) 문구 — 정본은 피그마 bw01-97·97a·97b(초안, 2026-10-16 「초안대로」). HTML 은 _templates/ 양식, 아래 text 는 그 사본(함께 고칠 것)
    const brandName = String(brandRow.name || "").trim() || "브랜드";
    const inviterName = String(inv.inviter_name || "").trim() || "대표 담당자";
    const toEmail = String(inv.email);
    const link = kind === "blocked" ? "" : `${brandBase}/brand/?link=${inv.link_id}&kind=invite`;
    const opsTeam = "REVERB 운영팀";

    // 제목은 갈래마다 다르고 끝에 보낸 시각을 붙인다 — 같은 제목이면 메일 앱이 한 대화로 묶어 앞 메일 끝부분(발신 전용·© 줄)을 접는다
    //   (2026-10-20 사용자 결정 — 10/16 「세 갈래 같은 제목」을 바꿈. 각 양식 머리말 주석의 제목도 함께)
    const subject = isOwnerLink
      ? `[REVERB JP] 「${brandName}」 브랜드 대표 담당자 연결 요청 — 24시간 안에 수락해 주십시오 (${kstStamp()})`
      : kind === "new"
      ? `[REVERB JP] ${inviterName} 님이 「${brandName}」 브랜드 페이지에 초대했습니다 — 비밀번호를 설정해 주십시오 (${kstStamp()})`
      : kind === "brand"
      ? `[REVERB JP] ${inviterName} 님이 「${brandName}」 브랜드 페이지에 초대했습니다 — 로그인해 수락해 주십시오 (${kstStamp()})`
      : `[REVERB JP] 「${brandName}」 브랜드 페이지 초대 — 이 이메일로는 계정을 만들 수 없습니다 (${kstStamp()})`;
    const tplKey = isOwnerLink ? "brand-link-request" : kind === "new" ? "brand-invite-new" : kind === "brand" ? "brand-invite-existing" : "brand-invite-blocked";

    // HTML 주석 strip — 템플릿 안 주석(용도 안내)이 메일 본문에 누출되는 것 차단
    const tpl = TEMPLATES[tplKey].replace(/<!--[\s\S]*?-->/g, "");
    const html = render(tpl, {
      brand_name: escapeHtml(brandName),
      inviter_name: escapeHtml(inviterName),
      link: escapeHtml(link),
    });

    const intro = `「${brandName}」 브랜드의 대표 담당자 ${inviterName} 님이 REVERB 브랜드 페이지에 함께하도록 초대했습니다.\n\n`;
    const validity = `이 링크는 보낸 때부터 24시간 동안 유효합니다.\n`;
    const sentBy = `이 메일은 「${brandName}」 브랜드의 대표 담당자 ${inviterName} 님의 초대로 REVERB 운영팀이 보냈습니다.\n`;
    const contact = `이 메일은 발신 전용입니다. 초대에 관한 문의는 ${inviterName} 님께 직접 연락해 주십시오.\n`;
    const ignoreLink = `무슨 메일인지 모르시겠다면 이 메일을 무시하셔도 됩니다. 링크를 누르지 않으면 아무 일도 일어나지 않습니다.\n`;
    let text: string;
    if (isOwnerLink) {
      // 정본 = _templates/brand-link-request.html(피그마 bw01-98 초안). 계정 상태(비밀번호 유무)를 드러내지 않는 같은 본문
      text = `안녕하십니까\n\n` +
        `${opsTeam}이 회원님의 브랜드 페이지 계정을 「${brandName}」 브랜드의 대표 담당자로 연결하려 합니다.\n\n` +
        `아래 링크에서 요청을 수락하면 「${brandName}」 브랜드가 지금 쓰시는 계정에 연결됩니다. 수락하기 전에는 연결되지 않습니다.\n\n` +
        `연결 요청 확인하기: ${link}\n\n` + validity +
        `기한이 지나면 링크가 열리지 않습니다. 그때는 ${opsTeam}에 다시 보내 달라고 요청해 주십시오.\n` +
        `로그인한 뒤 마이페이지 「받은 초대」에서도 수락하거나 거절할 수 있습니다. 비밀번호를 아직 정하지 않으셨다면 링크를 연 화면에서 비밀번호를 정하며 바로 수락할 수 있습니다.\n\n` +
        `이 메일은 ${opsTeam}이 보냈습니다.\n` + ignoreLink +
        `이 메일은 발신 전용입니다. 연결 요청에 관한 문의는 ${opsTeam} 담당자에게 연락해 주십시오.\n`;
    } else if (kind === "new") {
      text = `안녕하십니까\n\n` + intro +
        `아래 링크에서 비밀번호를 설정하면 「${brandName}」 브랜드의 오리엔시트와 캠페인을 함께 보실 수 있습니다.\n\n` +
        `초대 수락하고 비밀번호 설정하기: ${link}\n\n` + validity +
        `기한이 지나면 링크가 열리지 않습니다. 그때는 ${inviterName} 님께 초대를 다시 보내 달라고 요청해 주십시오.\n\n` +
        sentBy + ignoreLink + contact;
    } else if (kind === "brand") {
      text = `안녕하십니까\n\n` + intro +
        `이미 REVERB 브랜드 페이지 계정이 있으십니다. 지금 쓰시는 계정으로 로그인해 초대를 수락하면 「${brandName}」 브랜드가 연결됩니다.\n\n` +
        `로그인하고 초대 확인하기: ${link}\n\n` + validity +
        `로그인한 뒤 마이페이지 「받은 초대」에서도 수락하거나 거절할 수 있습니다.\n` +
        `비밀번호를 아직 정하지 않으셨다면, 먼저 받으신 비밀번호 설정 메일로 정한 뒤 수락해 주십시오.\n\n` +
        sentBy + ignoreLink + contact;
    } else {
      text = `안녕하십니까\n\n` +
        `「${brandName}」 브랜드의 대표 담당자 ${inviterName} 님이 이 이메일로 REVERB 브랜드 페이지에 초대했습니다.\n\n` +
        `하지만 이 이메일은 이미 REVERB의 다른 서비스에서 쓰고 있어 브랜드 계정을 만들 수 없습니다. 다른 이메일로 다시 초대해 달라고 ${inviterName} 님께 요청해 주십시오.\n\n` +
        sentBy + `무슨 메일인지 모르시겠다면 이 메일을 무시하셔도 됩니다. 아무 일도 일어나지 않습니다.\n` + contact;
    }


    // 5) 선점 먼저(문구 조립은 위에서 끝냈다 — 선점 뒤에는 예외 낼 일을 최소로) — 「읽기 → 발송 → 기록」은 두 번 누르기·재시도가 겹치면 메일이 두 통 나간다.
    //    지금 link_id 로 발송 기록이 없을 때만 바꿔 넣고, 0행이면 이미 보냈거나 보내는 중이다.
    //    link_id 도 조건에 걸어, 읽은 뒤 대표가 「다시 보내기」로 링크를 바꿨다면(옛 링크로 보내지 않게) 0행이 되도록 한다.
    const prevClaim: string | null = inv.mail_sent_link_id ? String(inv.mail_sent_link_id) : null;
    const { data: claimed, error: claimErr } = await sb
      .from("brand_invites")
      .update({ mail_sent_link_id: inv.link_id })
      .eq("id", inv.id)
      .eq("link_id", inv.link_id)
      .eq("status", "pending")
      .gt("expires_at", new Date().toISOString())   // 읽은 뒤 만료됐으면 선점 못 한다
      .or(`mail_sent_link_id.is.null,mail_sent_link_id.neq.${inv.link_id}`)
      .select("id");
    if (claimErr) throw claimErr;
    if (!claimed || claimed.length === 0) {
      return jsonResponse({ sent: false, reason: "already_sent" }, 200);
    }
    // 이후 실패하면 선점을 이전 값으로 되돌린다(대표가 「초대 보내기」를 다시 눌렀을 때 멱등 재시도가 되도록).
    const releaseClaim = async () => {
      const { error } = await sb
        .from("brand_invites")
        .update({ mail_sent_link_id: prevClaim })
        .eq("id", inv.id)
        .eq("link_id", inv.link_id)
        .eq("mail_sent_link_id", inv.link_id);
      if (error) console.error("[notify-brand-invite] claim release failed", tag, error.message);
    };


    // 선점 뒤 구간 — 어떤 예외가 나도(재확인·시간 초과·발송) 선점을 되돌린다. 안 그러면 만료까지 already_sent/already_pending 으로 멈춘다.
    try {
      // 선점 직후 재확인 — 호출자가 여전히 보낼 자격이 있고(멤버 초대 = 그 브랜드의 활성 대표 · 연결 요청 = 계정 관리 권한)
      // 브랜드가 활성인가(그 사이 대표 해제·넘기기·권한 회수·보관)
      const stillAllowed = await callerAllowed();
      const { data: stillBrand, error: sbErr } = await sb
        .from("brands").select("status").eq("id", inv.brand_id).maybeSingle();
      if (sbErr) throw sbErr;
      if (!stillAllowed || !stillBrand || stillBrand.status !== "active") {
        await releaseClaim();
        return jsonResponse({ sent: false, reason: "forbidden" }, 403);
      }

      // 개발서버 두 겹 잠금 — 메일을 보내지 않고 제목·본문을 응답에 싣는다. 선점은 일부러 남기고 mail_sent_at 은 남기지 않는다.
      //    ⓐⓑⓒ 모두 같은 키 집합({subject, text}).
      if (devEchoEnabled()) {
        console.log("[notify-brand-invite] dev echo (no mail sent)", tag);
        return jsonResponse({ sent: true, dev_mail: { subject, text } }, 200);
      }

      // 메일 발송 — 실패하면 선점을 되돌리고, 초대 줄은 대기 그대로 둔다(16-7: 대표가 다시 시도).
      await sendBrevoEmail({ to: [{ email: toEmail }], subject, htmlContent: html, textContent: text });
    } catch (e) {
      console.error("[notify-brand-invite] send failed", tag, (e as Error).message);
      await releaseClaim();
      return jsonResponse({ sent: false, reason: "send_failed" }, 200);
    }
    console.log("[notify-brand-invite] mail sent", tag);

    // 발송 성공 기록 — 기록 실패가 발송 성공을 무효화하지 않는다(그 사이 링크가 바뀌었으면 0행, 정상).
    const { error: markErr } = await sb
      .from("brand_invites")
      .update({ mail_sent_at: new Date().toISOString() })
      .eq("id", inv.id)
      .eq("link_id", inv.link_id)
      .eq("mail_sent_link_id", inv.link_id);
    if (markErr) console.error("[notify-brand-invite] mark failed", tag, markErr.message);

    return jsonResponse({ sent: true }, 200);
  } catch (e) {
    console.error("[notify-brand-invite] error", (e as Error).message);
    return jsonResponse({ sent: false, reason: "server_error" }, 500);
  }
});
