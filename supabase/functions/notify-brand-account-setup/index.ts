// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-brand-account-setup
// ──────────────────────────────────────────────────────────────────
// 트리거: 관리자가 브랜드 상세에서 「계정 만들기」/「다시 보내기」를 누르면 화면(storage.js
//          sendBrandAccountSetupMail, 조각 6)이 supabase.functions.invoke 로 직접 호출.
//          → 브라우저 직접 호출이라 CORS + OPTIONS 필수. 공개 키 거부는 걸지 않는다.
//
// 복제 원본: notify-admin-invite. 차이 —
//   · 호출자: 최고 관리자 전용 → has_permission('brand.account_manage','write')(마이그레이션 530·533 — 관리자 함수와 같은 판정).
//     호출자 토큰으로 묻는다(서비스 키로 물으면 로그인 사용자가 없어 판정이 안 돈다). 거부는 403 forbidden
//   · 대상: admins → brand_account_links(owner, active) → brand_accounts. 받는 사람은 요청에서 받지 않는다
//   · 링크: 서버가 setup_link_id 를 새로 발급(service_issue_brand_account_link, 마이그레이션 527)해
//     앞서 보낸 링크를 모두 무효화하고, 그 번호를 착지 주소에 싣는다
//   · 링크 유효 시간 24시간 문구(작업표 S0-3 — 개발서버 Supabase 「Email OTP Expiration」 을 86400 으로 바꾼 뒤 배포.
//     운영은 브랜드 페이지 출시 때 설정을 먼저 바꾸고 이 함수를 배포한다. 반대면 운영 메일이 거짓 안내를 한다)
//
// 요청:  POST { brand_id: uuid, mode?: 'setup' | 'resend', mail_kind?: 'setup' | 'link' }  + Authorization: Bearer <관리자 토큰>
//        mode 는 메일 문구(처음/다시)만 가른다. 권한·검증 어디에도 쓰지 않는다.
//        mail_kind 없음/'setup' = 기존 설정 메일. 'link' = 「브랜드 연결 추가」 뒤 연결 안내 갈래 — 양식은 서버가 정한다:
//          · 대표 계정이 비밀번호를 정했으면(brand_accounts.password_set_at 을 서버가 다시 읽음) brand-link-notice 양식.
//            링크 번호 교체·복구 링크 생성 없음, 단추는 /brand/ 로그인 화면 일반 주소. 발송 기록(setup_mail_sent_*)을 남기지 않는다
//            (그 칸은 「설정 메일」 상태 줄 전용이고 service_mark_brand_setup_mail_sent 도 비밀번호 미설정 계정만 기록한다).
//          · 비밀번호를 안 정했으면 기존 설정 메일 + 「운영팀이 이 브랜드를 계정에 연결해 보내는 메일」 문장(작업표 S0-2). 기록 p_sent_by='admin'.
//        그 밖의 mail_kind 값은 400 invalid_request.
// 응답:  200 { sent:true, recipient, template:'setup'|'link_notice' }   ← 어느 양식을 보냈는지(화면·시험 구분용)
//        200 { sent:true, recipient, template:'setup', dev_link }       ← 개발서버 두 겹 잠금일 때만(메일 안 보냄)
//        200 { sent:true, recipient, template:'link_notice', dev_echo:true }  ← 같은 잠금. 링크가 없는 양식이라 dev_link 는 없다
//        200 { sent:false, reason: 'no_account' | 'password_already_set' | 'no_active_brand' | 'send_failed' | ... }
//        400 { sent:false, reason:'invalid_request' } · 401 { reason:'unauthorized' } · 403 { reason:'forbidden' }
//        500 { sent:false, reason:'server_error' }
//
// 🔴 개발서버 「메일 대신 링크 표시」 두 겹 잠금 (signup-code-send 와 같은 방식)
//    ① 환경변수 BRAND_SETUP_DEV_ECHO === "1"  (개발서버에만 넣는다)
//    ② 이 함수가 도는 프로젝트 주소가 개발서버(STAGING_PROJECT_REF)
//    둘 다 참일 때만 메일을 보내지 않고 응답에 링크를 싣는다.
//    ⚠️ 하나라도 지우면 운영에서 비밀번호 설정 링크가 응답에 실린다 — 호출한 관리자 화면·로그에
//       계정 탈취용 링크가 남는다. 잠금 둘 다 지우지 말 것. 운영에는 BRAND_SETUP_DEV_ECHO 를 넣지 않는다.
//    ⚠️ 연결 안내 양식 갈래는 링크를 새로 만들지 않으므로 잠금이 켜지면 메일만 건너뛰고 dev_echo:true 만 돌려준다
//       (일반 로그인 주소라 비밀은 아니지만 「잠금 켜짐=메일 안 나감」 규칙을 갈래와 무관하게 지킨다).
//    ⚠️ dev_link 를 쓴 경우는 발송 기록(service_mark_brand_setup_mail_sent)을 남기지 않는다 —
//       실제로 메일이 나가지 않았는데 관리자 화면 상태 줄이 「메일 보냄」으로 보이면 거짓이다.
//
// 로그에는 링크·토큰·본문을 남기지 않는다(상태와 브랜드 번호만).
//
// 환경변수 (Edge Functions Secrets):
//   BREVO_API_KEY          Brevo Transactional API 키
//   PUBLIC_BRAND_URL       브랜드 페이지 사이트 절대 URL (운영 https://globalreverb.com / 개발 https://dev.globalreverb.com)
//                          — 링크 도메인을 서버가 정한다(클라 조작 방지). 없으면 오류(기본값을 두지 않는다)
//   BRAND_SETUP_DEV_ECHO   개발서버에만 "1"
//   BREVO_SENDER_EMAIL / BREVO_SENDER_NAME   (기본 noreply@globalreverb.com / REVERB JP)
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY  (런타임 자동 주입)
//
// 템플릿: templates.ts (sync-email-templates.sh 자동 생성) → TEMPLATES['brand-account-setup'], TEMPLATES['brand-link-notice']
//
// 배포 (개발 → 운영):
//   bash scripts/sync-email-templates.sh
//   supabase functions deploy notify-brand-account-setup --project-ref qysmxtipobomefudyixw
//   supabase secrets set PUBLIC_BRAND_URL=https://dev.globalreverb.com BRAND_SETUP_DEV_ECHO=1 --project-ref qysmxtipobomefudyixw
//   (운영) supabase functions deploy notify-brand-account-setup --project-ref nrwtujmlbktxjgdwlpjj
//   (운영) supabase secrets set PUBLIC_BRAND_URL=https://globalreverb.com --project-ref nrwtujmlbktxjgdwlpjj
//
// 메일 발송 테스트는 운영에서만 (supabase.md 정책). 개발은 OPTIONS·403·dev_link 로만 확인.
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TEMPLATES } from "./templates.ts";

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";
const STAGING_PROJECT_REF = "qysmxtipobomefudyixw";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// CORS — 관리자 화면(globalreverb.com 등)이 *.supabase.co 를 직접 부르는 교차 출처 호출.
// 인증은 아래 토큰 검증 + admins 역할 검사로 별도 보장한다.
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
    let body: { brand_id?: unknown; mode?: unknown; mail_kind?: unknown } = {};
    try { body = await req.json(); } catch (_) { /* 아래에서 invalid_request 로 수렴 */ }
    const brandId = typeof body.brand_id === "string" ? body.brand_id.trim() : "";
    if (!UUID_RE.test(brandId)) {
      return jsonResponse({ sent: false, reason: "invalid_request" }, 400);
    }
    // mode 는 메일 문구(처음/다시)만 가른다 — 클라가 바꿔도 안전.
    const isResend = body.mode === "resend";
    // mail_kind: 없음/'setup' = 설정 메일, 'link' = 연결 안내 갈래. 그 밖의 값은 거부(조용히 설정 메일로 새지 않게).
    if (body.mail_kind !== undefined && body.mail_kind !== null && body.mail_kind !== "setup" && body.mail_kind !== "link") {
      return jsonResponse({ sent: false, reason: "invalid_request" }, 400);
    }
    const isLinkKind = body.mail_kind === "link";

    const supaUrl = env("SUPABASE_URL");
    const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = env("SUPABASE_ANON_KEY");
    if (!supaUrl || !serviceKey) throw new Error("Supabase service credentials not configured");
    // 링크 도메인은 서버 설정만 믿는다. 기본값을 두면 운영에서 설정을 빠뜨렸을 때 개발 주소로 메일이 나간다.
    const brandBase = env("PUBLIC_BRAND_URL").replace(/\/$/, "");
    if (!/^https:\/\/[^/\s]+$/.test(brandBase)) throw new Error("PUBLIC_BRAND_URL not configured");

    const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

    // 1) 호출자 인증 — has_permission('brand.account_manage','write')(533 의 관리자 함수와 같은 판정).
    //    anon 키는 공개되므로 JWT 검증 필수. 권한이 없으면(관리자가 아닌 계정 포함) 403.
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
    // 호출자 토큰으로 묻는다 — has_permission 은 auth.uid() 로 호출자 등급을 읽는다(서비스 키로 부르면 로그인 사용자가 없다).
    // 판정 호출 자체가 실패하면(함수 없음 등) 403 이 아니라 500 으로 — 권한 없음과 서버 문제를 섞지 않는다.
    const { data: allowed, error: permErr } = await userSb.rpc("has_permission", {
      p_feature: "brand.account_manage",
      p_min: "write",
    });
    if (permErr) throw permErr;
    if (allowed !== true) {
      return jsonResponse({ sent: false, reason: "forbidden" }, 403);
    }

    // 2) 받는 사람은 요청이 아니라 brand_id 로 서버가 다시 읽는다.
    //    브랜드의 활성 대표(owner) 연결 → 그 계정.
    const { data: linkRow, error: linkRowErr } = await sb
      .from("brand_account_links")
      .select("auth_id")
      .eq("brand_id", brandId)
      .eq("role", "owner")
      .eq("status", "active")
      .maybeSingle();
    if (linkRowErr) throw linkRowErr;
    if (!linkRow) return jsonResponse({ sent: false, reason: "no_account" }, 200);

    const { data: acct, error: acctErr } = await sb
      .from("brand_accounts")
      .select("auth_id, email, name, password_set_at")
      .eq("auth_id", linkRow.auth_id)
      .maybeSingle();
    if (acctErr) throw acctErr;
    if (!acct) return jsonResponse({ sent: false, reason: "no_account" }, 200);

    const { data: brandRow } = await sb
      .from("brands")
      .select("name")
      .eq("id", brandId)
      .maybeSingle();
    const brandName = String(brandRow?.name || "").trim() || "브랜드";

    // 2-1) 연결 안내 갈래(mail_kind:'link') + 비밀번호를 이미 정한 계정 → 링크 없는 연결 안내 양식.
    //      password_set_at 은 위에서 서버가 다시 읽은 값이다(요청 본문의 어떤 값도 양식 선택에 안 쓴다).
    //      비밀번호 미설정이면 아래 설정 메일 흐름으로 그대로 떨어진다(S0-2) — 거기서 연결 문장만 더해진다.
    if (isLinkKind && acct.password_set_at) {
      const toEmailLn = String(acct.email);
      if (devEchoEnabled()) {
        console.log("[notify-brand-account-setup] dev echo (no mail sent, link notice)", { brand_id: brandId });
        return jsonResponse({ sent: true, recipient: toEmailLn, template: "link_notice", dev_echo: true }, 200);
      }
      const nameLn = String(acct.name || "").trim() || "담당자";
      const loginUrl = `${brandBase}/brand/`;
      const tplLn = TEMPLATES["brand-link-notice"].replace(/<!--[\s\S]*?-->/g, "");
      const htmlLn = render(tplLn, {
        brand_name: escapeHtml(brandName),
        contact_name: escapeHtml(nameLn),
        link: escapeHtml(loginUrl),
      });
      const textLn =
        `${nameLn} 님\n\n` +
        `REVERB 운영팀이 「${brandName}」 브랜드를 회원님의 REVERB 브랜드 페이지 계정에 연결했습니다. 「${brandName}」 브랜드의 대표 담당자로 등록되어 이 메일을 받으셨습니다.\n` +
        `지금 쓰시는 계정으로 로그인하시면 「${brandName}」 브랜드가 내 브랜드 목록에 함께 보입니다. 비밀번호는 그대로이며 새로 정하실 필요가 없습니다.\n\n` +
        `로그인: ${loginUrl}\n\n` +
        `REVERB 운영팀은 문의 또는 기존 연락으로 전달받은 담당자 정보(이름·이메일·연락처)를 브랜드 페이지 계정을 만들거나 연결하는 데에만 사용했습니다. 개인정보 이용에 관한 문의는 REVERB 운영팀으로 연락해 주십시오.\n\n` +
        `이 메일은 REVERB 운영팀이 「${brandName}」 브랜드의 대표 담당자로 등록된 이 주소로 보냈습니다.\n` +
        `본인과 관련 없거나 무슨 메일인지 모르시겠다면, 이 메일을 무시하셔도 됩니다.\n` +
        `이 메일은 발신 전용입니다. 문의는 REVERB 운영팀 담당자에게 직접 연락해 주십시오.\n`;
      try {
        await sendBrevoEmail({
          to: [{ email: toEmailLn, name: nameLn }],
          subject: `[REVERB JP] 「${brandName}」 브랜드가 계정에 연결되었습니다`,
          htmlContent: htmlLn,
          textContent: textLn,
        });
      } catch (e) {
        console.error("[notify-brand-account-setup] link notice send failed", (e as Error).message);
        return jsonResponse({ sent: false, reason: "send_failed" }, 200);
      }
      console.log("[notify-brand-account-setup] link notice sent", { brand_id: brandId });
      // 발송 기록은 남기지 않는다 — setup_mail_sent_* 는 설정 메일 상태 줄 전용(위 머리말)
      return jsonResponse({ sent: true, recipient: toEmailLn, template: "link_notice" }, 200);
    }

    // 3) 새 링크 번호 발급 — 앞서 보낸 링크는 이 순간 모두 무효. 종류는 항상 'setup'
    //    (비밀번호가 이미 설정됐으면 password_already_set 으로 거부된다).
    const { data: issued, error: issueErr } = await sb.rpc("service_issue_brand_account_link", {
      p_auth_id: acct.auth_id,
      p_kind: "setup",
    });
    if (issueErr) throw issueErr;
    if (!issued?.ok) {
      return jsonResponse({ sent: false, reason: String(issued?.reason || "issue_failed") }, 200);
    }
    const linkId = String(issued.link_id);
    const toEmail = String(issued.email || acct.email);

    // 4) 비밀번호 설정 링크 발급 (서버 발급 — 브라우저 검증값에 의존하지 않음)
    const landing = `${brandBase}/brand/?link=${linkId}&mode=setup`;
    const { data: genData, error: genErr } = await sb.auth.admin.generateLink({
      type: "recovery",
      email: toEmail,
      options: { redirectTo: landing },
    });
    if (genErr) {
      console.error("[notify-brand-account-setup] generateLink failed", genErr.message);
      return jsonResponse({ sent: false, reason: "send_failed" }, 200);
    }
    const rawLink = genData?.properties?.action_link;
    if (!rawLink) {
      console.error("[notify-brand-account-setup] generateLink returned no action_link");
      return jsonResponse({ sent: false, reason: "send_failed" }, 200);
    }

    // ★메일에는 Supabase 검증 주소를 그대로 싣지 않는다 — 우리 페이지의 # 뒤에 담는다(notify-admin-invite 와 같은 이유).
    //   메일 보안 검사기·클릭 추적 서버가 링크를 먼저 열어도 # 뒤는 서버로 안 가므로 토큰이 소진되지 않는다.
    //   사람이 화면의 「계속하기」를 눌러야 비로소 Supabase 검증 주소로 이동한다.
    const mailLink = `${landing}#confirm=${encodeURIComponent(rawLink)}`;

    // 5) 개발서버 두 겹 잠금 — 메일을 보내지 않고 링크를 응답에 싣는다. 발송 기록도 남기지 않는다.
    if (devEchoEnabled()) {
      console.log("[notify-brand-account-setup] dev echo (no mail sent)", { brand_id: brandId });
      return jsonResponse({ sent: true, recipient: toEmail, template: "setup", dev_link: mailLink }, 200);
    }

    // 6) 메일 발송
    const contactName = String(issued.name || acct.name || "").trim() || "담당자";
    // ⚠️ 같은 양식(brand-account-setup)을 brand-password-reset-request 도 쓴다 — 그쪽은 본인 요청 문구(2026-10-20). 양식 자리표시를 늘리면 두 함수가 함께 넘긴다
    // ⚠️ 연결 갈래(mail_kind:'link')는 「다시 보냄」이 아니라 처음 안내이므로 isResend 를 무시하고 연결 문장을 쓴다.
    const intro = isLinkKind
      ? `REVERB 운영팀이 「${brandName}」 브랜드를 회원님의 브랜드 페이지 계정에 연결했습니다. 「${brandName}」 브랜드의 대표 담당자로 등록되어 이 메일을 받으셨습니다. 이 계정은 아직 비밀번호가 설정되지 않았습니다.`
      : isResend
      ? `REVERB 운영팀이 「${brandName}」 브랜드 계정의 비밀번호 설정 링크를 다시 보내 드립니다. 앞서 받으신 링크는 더 이상 쓸 수 없습니다.`
      : `REVERB 운영팀이 「${brandName}」 브랜드 계정을 만들었습니다. 「${brandName}」 브랜드의 대표 담당자로 등록되어 이 메일을 받으셨습니다.`;
    const expiresNote = "이 링크는 보낸 때부터 24시간 동안 유효합니다.";
    const heading = isLinkKind
      ? `「${brandName}」 브랜드가 계정에 연결되었습니다`
      : isResend
      ? `「${brandName}」 브랜드 계정 비밀번호 설정 링크를 다시 보내 드립니다`
      : `「${brandName}」 브랜드 계정이 만들어졌습니다`;
    // 다시 보냄은 제목 끝에 보낸 시각 — 같은 제목이면 메일 앱이 한 대화로 묶어 앞 메일 끝부분을 접는다(2026-10-20 사용자 결정)
    const subject = isLinkKind
      ? `[REVERB JP] 「${brandName}」 브랜드가 계정에 연결되었습니다 — 비밀번호를 설정해 주십시오`
      : isResend
      ? `[REVERB JP] 「${brandName}」 브랜드 계정 — 비밀번호 설정 링크를 다시 보내 드립니다 (${kstStamp()})`
      : `[REVERB JP] 「${brandName}」 브랜드 계정이 만들어졌습니다 — 비밀번호를 설정해 주십시오`;
    const expiresAfter = "기한이 지나면 링크가 열리지 않습니다. 그때는 REVERB 운영팀에 다시 보내 달라고 요청해 주십시오.";
    const sentBy = `이 메일은 REVERB 운영팀이 「${brandName}」 브랜드의 대표 담당자로 등록된 이 주소로 보냈습니다.`;

    // HTML 주석 strip — 템플릿 안 주석(용도 안내 자리 표시 포함)이 메일 본문에 누출되는 것 차단
    const tpl = TEMPLATES["brand-account-setup"].replace(/<!--[\s\S]*?-->/g, "");
    const html = render(tpl, {
      heading: escapeHtml(heading),
      brand_name: escapeHtml(brandName),
      contact_name: escapeHtml(contactName),
      link: escapeHtml(mailLink),
      intro: escapeHtml(intro),
      expires: escapeHtml(expiresNote),
      expires_after: escapeHtml(expiresAfter),
      sent_by: escapeHtml(sentBy),
    });
    const text =
      `${contactName} 님\n\n` +
      `${intro}\n` +
      `아래 링크에서 사용하실 비밀번호를 설정해 주십시오. 설정을 마치면 REVERB 브랜드 페이지에 로그인하실 수 있습니다.\n\n` +
      `링크: ${mailLink}\n\n` +
      `${expiresNote} ${expiresAfter}\n\n` +
      `REVERB 운영팀은 문의 또는 기존 연락으로 전달받은 담당자 정보(이름·이메일·연락처)를 브랜드 페이지 계정을 만들거나 연결하는 데에만 사용했습니다. 개인정보 이용에 관한 문의는 REVERB 운영팀으로 연락해 주십시오.\n\n` +
      `${sentBy}\n` +
      `본인이 요청하지 않았거나 무슨 메일인지 모르시겠다면, 이 메일을 무시하셔도 됩니다. 링크를 누르지 않으면 아무 일도 일어나지 않습니다.\n` +
      `이 메일은 발신 전용입니다. 문의는 REVERB 운영팀 담당자에게 직접 연락해 주십시오.\n`;

    try {
      await sendBrevoEmail({
        to: [{ email: toEmail, name: contactName }],
        subject,
        htmlContent: html,
        textContent: text,
      });
    } catch (e) {
      console.error("[notify-brand-account-setup] send failed", (e as Error).message);
      return jsonResponse({ sent: false, reason: "send_failed" }, 200);
    }
    console.log("[notify-brand-account-setup] mail sent", { brand_id: brandId, resend: isResend, link_kind: isLinkKind });

    // 발송 성공 기록 — 기록 실패가 발송 성공을 무효화하지 않는다.
    // 그 사이 다른 관리자가 새 링크를 발급했으면 false 가 돌아와 기록하지 않는다(정상).
    const { error: markErr } = await sb.rpc("service_mark_brand_setup_mail_sent", {
      p_auth_id: acct.auth_id,
      p_link_id: linkId,
      p_sent_to: toEmail,
      p_sent_by: "admin",
    });
    if (markErr) console.error("[notify-brand-account-setup] mark failed", markErr.message);

    return jsonResponse({ sent: true, recipient: toEmail, template: "setup" }, 200);
  } catch (e) {
    console.error("[notify-brand-account-setup] error", (e as Error).message);
    return jsonResponse({ sent: false, reason: "server_error" }, 500);
  }
});
