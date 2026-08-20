// ══════════════════════════════════════════════════════════════════
// Edge Function: notify-withdrawal-scheduled
// ──────────────────────────────────────────────────────────────────
// 회원 탈퇴 — 「대기(pending_payout) → 예정(scheduled)」 전이 메일 발송.
// 사양서: docs/specs/2026-08-18-member-withdrawal.md §5-①(Q2 확정)
// 작업표: docs/specs/2026-08-19-member-withdrawal-breakdown.md 작업 7
//
// 트리거: pg_cron 매일 UTC 00:00(= KST 09:00) net.http_post
//   (마이그레이션 350 「pg_cron 등록 ②」). 상태 전이 자체는
//   advance_withdrawal_states()(같은 마이그레이션, 매일 KST 04:45)가
//   별도로 돈다 — 이 함수는 그 결과를 뒤이어 메일로 전달하는 완전히
//   분리된 파이프라인이다.
//
// 왜 이 함수가 따로 있는가(SQL 쪽에 안 넣은 이유는 마이그레이션 350 파일
// 헤더 「★★ 메일 발송 경로」 절이 상세 — 요약):
//   · net.http_post 는 비동기 큐잉이라 SQL 이 "정말 보내졌는지" 알 수 없다.
//   · 상태 전이와 메일 발송을 분리해야, 메일이 실패해도(Brevo 장애 등)
//     상태 전이 자체는 절대 되돌아가지 않는다.
//
// 대상 선정(재발송 차단):
//   withdrawal_requests.status = 'scheduled'
//     AND scheduled_mail_sent_at IS NULL
//   → 348/350 어느 경로로 scheduled 가 됐든(배치 전이든, request_withdrawal
//   이 신청 즉시 미지급 0으로 바로 scheduled 를 만든 경우든) 전부 이 조건
//   하나로 포착된다 — 별도 분기 불필요.
//   → scheduled_mail_sent_at 은 **발송에 실제로 성공한 뒤에만** 채운다
//   (먼저 채우면 실패한 건이 다음 실행에서 재시도되지 않는다).
//
// 실패 처리:
//   한 건이 실패해도 나머지는 계속 처리(try/catch). 실패 건은
//   scheduled_mail_attempt_count 만 +1 — 다음 실행이 같은 조건으로 다시
//   집는다(SQL 쪽에 별도 재시도 큐 불필요 — "아직 안 보냄" 자체가 큐 역할).
//
// 환경변수 (Edge Functions Secrets):
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY   자동 주입
//   BREVO_API_KEY        Brevo Transactional API 키 (양 서버 별도)
//   BREVO_SENDER_EMAIL   기본 noreply@globalreverb.com
//   BREVO_SENDER_NAME    기본 REVERB JP (개발은 REVERB JP [DEV])
//   PUBLIC_APP_URL       인플루언서 사이트 절대 URL (기본 https://globalreverb.com)
//
// HTML 템플릿 (sync-email-templates.sh):
//   _templates/withdrawal-scheduled.html
//
// pg_cron 등록: 마이그레이션 350 「pg_cron 등록 ②」 절 참고
//   (withdrawal-scheduled-mail-daily, 매일 UTC 00:00 = KST 09:00)
//   ⚠️ 그 절의 cron.schedule 문은 URL 을 운영(nrwtujmlbktxjgdwlpjj) 기준으로
//   박아 뒀다 — 개발서버에는 이 job 을 등록하지 않는 것이 기본(마이그레이션
//   350 파일의 해당 경고 참고).
//
// 배포:
//   bash scripts/sync-email-templates.sh
//   supabase functions deploy notify-withdrawal-scheduled --project-ref qysmxtipobomefudyixw   # 개발(환경 동기화만 — 발송 시험 금지)
//   supabase functions deploy notify-withdrawal-scheduled --project-ref nrwtujmlbktxjgdwlpjj   # 운영
//
// 메일 발송 테스트는 운영에서만(.claude/rules/supabase.md 「메일 발송 테스트 환경 정책」).
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

function render(html: string, data: Record<string, string>): string {
  return html.replace(/\{\{(\w+)\}\}/g, (_m, key) => data[key] ?? "");
}

// 'YYYY-MM-DD' → 「YYYY年MM月DD日」— Date 객체를 거치지 않는다. scheduled_date
// 는 이미 일본 시각 기준 계산값(마이그레이션 350 의 (now() AT TIME ZONE
// 'Asia/Tokyo')::date + 5)이라, Date 파싱을 거치면 실행 서버 시간대에 따라
// 날짜가 하루 밀릴 위험이 있다 — 문자열을 직접 잘라 그 위험을 원천 차단한다.
function formatJpDateFullFromDateStr(dateStr: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(dateStr);
  if (!m) return dateStr;
  return `${m[1]}年${m[2]}月${m[3]}日`;
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

interface WithdrawalRow {
  id: string;
  influencer_id: string;
  scheduled_date: string | null;
  scheduled_mail_attempt_count: number | null;
}

// ── 공개 키로 온 호출은 거부한다 ─────────────────────────────────
// 이 함수는 예약 실행(pg_cron)만 부른다 — 브라우저에서 부르는 자리가 0곳이다
// (`grep -rn "notify-withdrawal-scheduled" dev/` → 없음). 그런데 사이트에 그대로
// 박혀 있는 공개 키로 부르면 인증을 통과한다(2026-08-10 운영 실측). 그러면 누구나
// 「예정일 안내 메일」을 원하는 때에 터뜨릴 수 있다.
// ⚠️ 반대로 「특정 값이어야 통과」로 조이지 않는다 — 정상 경로가 무엇을 보내는지
//    기록이 없어, 그 값이 아니면 메일이 통째로 죽는다. 증명된 구멍만 닫는다.
// ⚠️ 공개 키를 교체하면 이 목록도 함께 갱신할 것.
// (같은 형태: notify-brand-application · notify-orient-submitted)
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
  if (rejectPublicKeyCaller(req, "notify-withdrawal-scheduled")) {
    return new Response(JSON.stringify({ error: "forbidden" }), {
      status: 403,
      headers: { "content-type": "application/json" },
    });
  }
  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) {
    return new Response(JSON.stringify({ error: "SUPABASE env missing" }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
  const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

  // 1. 대상 조회 — 재시도 대상까지 자연스럽게 포함(전 실행 실패분도 오늘 다시 잡힘)
  const { data: candidates, error: candErr } = await sb
    .from("withdrawal_requests")
    .select("id, influencer_id, scheduled_date, scheduled_mail_attempt_count, requested_by_kind")
    .eq("status", "scheduled")
    .is("scheduled_mail_sent_at", null)
    .order("requested_at", { ascending: true });

  if (candErr) {
    console.error("[notify-withdrawal-scheduled] candidate query failed", candErr);
    return new Response(JSON.stringify({ error: candErr.message }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }

  const rows = (candidates ?? []) as WithdrawalRow[];
  console.log("[notify-withdrawal-scheduled] candidates", rows.length);

  if (rows.length === 0) {
    return new Response(JSON.stringify({ ok: true, sent: 0, failed: 0, total: 0 }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  const publicAppUrl = env("PUBLIC_APP_URL", "https://globalreverb.com").replace(/\/$/, "");
  const helpLineUrl = "https://line.me/R/ti/p/@reverb.jp";
  // 회원 탈퇴 화면(작업 9)이 아직 없어 마이페이지 루트로 안내한다. 그 화면이
  // 생겨도 이 링크는 그대로 유효하다(마이페이지 → 탈퇴 관리로 이어지는 구조가
  // 되면 그만이지, 이 템플릿을 다시 고칠 필요가 없다).
  const mypageUrl = `${publicAppUrl}/#mypage`;
  // ⚠️ 주석 제거는 선택이 아니다 — 양식 상단에 담당자 전달용 한국어 메모가 들어 있고,
  //    안 지우면 그대로 발송 메일 소스에 실린다(2026-05-18 실제 사고). 메일 함수 12개
  //    전부가 이 replace 를 거친다.
  const tpl = TEMPLATES["withdrawal-scheduled"].replace(/<!--[\s\S]*?-->/g, "");

  let sent = 0;
  let failed = 0;

  for (const row of rows) {
    try {
      if (!row.scheduled_date) {
        // 이론상 status='scheduled' 면 scheduled_date 도 항상 채워져 있어야
        // 한다(345·347·350 설계상 그 두 값은 같은 UPDATE/INSERT 에서 함께
        // 세팅됨). 방어적으로 스킵하되, 조용히 넘기지 않고 실패로 집계해
        // attempt_count 를 올린다 — 데이터 이상 신호가 관리자 화면(작업 14)
        // 에 남도록.
        throw new Error("scheduled_date is null");
      }

      const { data: inf, error: infErr } = await sb
        .from("influencers")
        .select("id, email, name_kanji, name")
        .eq("id", row.influencer_id)
        .maybeSingle();

      if (infErr || !inf?.email) {
        // 인플루언서 행 누락·이메일 없음 — "성공으로 위장해 표시"하지
        // 않는다(요청사항 "발송에 성공한 뒤 표시"). attempt_count 만 올리고
        // 다음 실행에서 다시 시도(운영자가 attempt_count 급증으로 발견 가능).
        throw new Error(
          infErr ? `influencer fetch error: ${infErr.message}` : "influencer email missing",
        );
      }

      const influencerName = inf.name_kanji || inf.name || "";
      const scheduledDateJp = formatJpDateFullFromDateStr(row.scheduled_date);

      // 관리자가 대신 접수한 건이면 그 사실을 본문에 밝힌다.
      //   ⚠️ 이 메일이 **회원에게 닿는 유일한 통지**다(정산 알림을 없앤 뒤로).
      //     대행 접수인데 아무 말이 없으면 회원은 「내가 신청한 적 없는데?」가 된다.
      //   ⚠️ 강제(자격 상실)도 같은 문구를 쓰지 않는다 — 그쪽은 「요청에 따라」가
      //     사실이 아니다. 지금은 화면이 강제를 안 보내지만, 열리는 날 이 분기를
      //     함께 손볼 것.
      const isProxy = row.requested_by_kind === "admin_proxy";
      const proxyNotice = isProxy
        ? `<p style="margin:0 0 20px;padding:12px 14px;background:#F7F4EE;border-left:3px solid #E8344E;border-radius:4px;font-size:13px;color:#444;line-height:1.7">`
          + `お客様からのご依頼にもとづき、運営が代わって退会のお手続きを行いました。`
          + `<br>お心当たりがない場合は、下記よりご連絡ください。</p>`
        : "";

      const html = render(tpl, {
        influencer_name: escapeHtml(influencerName || "-"),
        scheduled_date_jp: escapeHtml(scheduledDateJp),
        mypage_url: mypageUrl,
        site_url: publicAppUrl,
        help_line_url: helpLineUrl,
        // ⚠️ 이 값만 이스케이프하지 않는다 — 위에서 만든 고정 HTML 조각이고
        //   사용자 입력이 섞이지 않는다.
        proxy_notice: proxyNotice,
      });

      const subject = `【REVERB】退会予定日のお知らせ（${scheduledDateJp}）`;
      const text = [
        `${influencerName} 様`,
        "",
        ...(isProxy
          ? ["お客様からのご依頼にもとづき、運営が代わって退会のお手続きを行いました。",
             "お心当たりがない場合は、下記よりご連絡ください。", ""]
          : []),
        `退会予定日: ${scheduledDateJp}`,
        "それまでは、マイページから退会をキャンセルできます。",
        // 재가입 제한 안내(작업 11) — 가입 화면은 이유를 안 밝히므로, **본인이 미리
        //   아는 유일한 자리**가 이 메일이다.
        //   ⚠️ 구체적인 날짜를 적지 않는다 — 이 메일은 「예정」 시점에 나가고 확정일은
        //     그 뒤라, 날짜를 적으면 틀린 날짜가 된다.
        "退会が完了した日から6か月間は、同じメールアドレスで新しくご登録いただけません。",
        "",
        `マイページ: ${mypageUrl}`,
        "",
        `お問い合わせ LINE: ${helpLineUrl}`,
      ].join("\n");

      await sendBrevoEmail({
        to: [{ email: inf.email, name: influencerName || undefined }],
        subject,
        htmlContent: html,
        textContent: text,
      });

      // ★ 발송 성공 직후에만 표시 — 위 sendBrevoEmail 이 던지면 이 UPDATE
      // 자체를 안 타므로 scheduled_mail_sent_at 은 NULL 로 남아 다음 실행이
      // 자동 재시도한다.
      const { error: markErr } = await sb
        .from("withdrawal_requests")
        .update({ scheduled_mail_sent_at: new Date().toISOString() })
        .eq("id", row.id)
        .is("scheduled_mail_sent_at", null); // 동시 실행 방어(멱등 UPDATE)

      if (markErr) {
        // 메일은 이미 나갔는데 표시만 실패한 드문 경우 — 다음 실행이 중복
        // 발송할 위험이 있다. 로그로 남겨 수동 확인 가능하게.
        console.error(
          "[notify-withdrawal-scheduled] sent but mark failed — possible dup on next run",
          row.id,
          markErr,
        );
      }

      sent++;
    } catch (e) {
      failed++;
      console.error("[notify-withdrawal-scheduled] row failed", row.id, (e as Error).message);
      try {
        await sb
          .from("withdrawal_requests")
          .update({ scheduled_mail_attempt_count: (row.scheduled_mail_attempt_count ?? 0) + 1 })
          .eq("id", row.id);
      } catch (_e2) {
        // best-effort — 실패해도 무시(다음 실행이 어차피 다시 시도한다)
      }
    }
  }

  console.log("[notify-withdrawal-scheduled] done", { sent, failed, total: rows.length });

  return new Response(JSON.stringify({ ok: true, sent, failed, total: rows.length }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
});
