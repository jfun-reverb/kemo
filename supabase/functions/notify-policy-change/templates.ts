// 자동 생성 (sync-email-templates.sh) — 직접 수정 금지
// docs/email-templates/ 변경 후 sync 스크립트 실행 시 자동 갱신
//
// 백틱·${...} 패턴은 sed로 escape 처리. 새 템플릿 추가 시 패턴 점검 필요

export const TEMPLATES: Record<string, string> = {
  "policy-change-notice": `<!DOCTYPE html>
<!--
  Mail: 약관·개인정보처리방침 개정 사전 통지 (policy change notice) — 연령 정책(만 18세)
  Trigger: 운영자가 notify-policy-change Edge Function 을 1회 수동 호출
           (cron 아님 — 사건 단위 일회성 발송)
  To: 전체 인플루언서 1명당 1통 (marketing_opt_in 무관 — 필수 고지/트랜잭션 성격)
  Lang: JA (인플루언서 대상)
  멱등: policy_notice_sent (influencer_id, notice_key) UNIQUE
  중복호출 차단: policy_notice_runs.notice_key UNIQUE (mutex)

  Top-level Placeholders:
    {{effective_date}}  시행일 = 공고일 + 30일 (운영자가 호출 시 지정)

  문안 원본: docs/specs/2026-06-17-age-policy-pr5-draft.md §4
  약관 영향: docs/specs/2026-05-27-age-minor-policy.md §7
-->
<div style="font-family:'Hiragino Sans','Noto Sans JP',Arial,sans-serif;color:#222;max-width:600px;margin:0 auto;font-size:14px;line-height:1.7">
  <h2 style="color:#5B6BBF;margin:0 0 6px;font-size:19px">満18歳以上のご利用への変更・規約改定のお知らせ</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">REVERB JP からの大切なお知らせです</p>

  <p style="margin:0 0 16px">
    REVERB JP をご利用いただきありがとうございます。<br>
    {{effective_date}}より、REVERB は満18歳以上の方のみご利用いただけるよう変更されます。あわせて、登録情報に「生年月日」と「性別」が追加されます。
  </p>

  <div style="margin:0 0 16px">
    <div style="font-weight:700;color:#5B6BBF;margin-bottom:6px">■ 変更内容</div>
    <div style="margin-left:2px">
      1. 満18歳以上の方のみキャンペーンにご応募いただけます。<br>
      2. ご応募の際に生年月日をご入力ください（一度入力すると変更できません）。<br>
      3. 性別もご入力ください（「回答しない」も選べます）。
    </div>
  </div>

  <div style="margin:0 0 16px">
    <div style="font-weight:700;color:#5B6BBF;margin-bottom:6px">■ ご確認いただきたいこと</div>
    <div style="margin-left:2px">
      ・満18歳未満の方は、施行日以降、新しいご応募ができなくなります。<br>
      ・すでに当選・進行中のキャンペーンには影響しません。そのままお進めいただけます。
    </div>
  </div>

  <div style="margin:0 0 16px;padding:12px 14px;background:#F4F6FF;border-radius:8px">
    <div style="font-weight:700;color:#5B6BBF;margin-bottom:4px">■ 施行日</div>
    <div style="font-size:16px;font-weight:700;color:#222">{{effective_date}}</div>
  </div>

  <p style="margin:0 0 16px;color:#555;font-size:13px">
    改定後の利用規約・プライバシーポリシーの全文は、アプリ下部の「利用規約」「個人情報処理方針」からご確認いただけます。
  </p>

  <p style="margin:24px 0 0;color:#999;font-size:11px;line-height:1.6">
    REVERB JP のメンバーシップに紐づいて自動送信されています。<br>
    お問い合わせは LINE <a href="https://line.me/R/ti/p/@reverb.jp" style="color:#999;text-decoration:underline">@reverb.jp</a> までお願いいたします。<br>
    <br>
    © JFUN Corp. · 株式会社ジェイファン<br>
    <a href="https://globalreverb.com" style="color:#999;text-decoration:underline">https://globalreverb.com</a>
  </p>
</div>`,
};
