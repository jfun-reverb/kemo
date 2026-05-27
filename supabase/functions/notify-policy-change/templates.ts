// 자동 생성 (sync-email-templates.sh) — 직접 수정 금지
// docs/email-templates/ 변경 후 sync 스크립트 실행 시 자동 갱신
//
// 백틱·${...} 패턴은 sed로 escape 처리. 새 템플릿 추가 시 패턴 점검 필요

export const TEMPLATES: Record<string, string> = {
  "policy-change-notice": `<!DOCTYPE html>
<!--
  Mail: 약관·개인정보처리방침 개정 사전 통지 (policy change notice)
  Trigger: 운영자가 notify-policy-change Edge Function 을 1회 수동 호출
           (cron 아님 — 사건 단위 일회성 발송)
  To: 전체 인플루언서 1명당 1통 (marketing_opt_in 무관 — 필수 고지/트랜잭션 성격)
  Lang: JA (인플루언서 대상)
  멱등: policy_notice_sent (influencer_id, notice_key) UNIQUE
  중복호출 차단: policy_notice_runs.notice_key UNIQUE (mutex)

  Top-level Placeholders:
    {{effective_date}}  시행일 (통지 게시일 + 30일, 운영자가 호출 시 지정)

  문안 원본: docs/notices/2026-05-27-message-feature-notice.md
  약관 영향: docs/specs/2026-05-15-application-messaging.md §8
-->
<div style="font-family:'Hiragino Sans','Noto Sans JP',Arial,sans-serif;color:#222;max-width:600px;margin:0 auto;font-size:14px;line-height:1.7">
  <h2 style="color:#5B6BBF;margin:0 0 6px;font-size:19px">「メッセージ」機能の追加と、規約改定のお知らせ</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">REVERB JP からの大切なお知らせです</p>

  <p style="margin:0 0 16px">
    REVERB JP をご利用いただきありがとうございます。<br>
    このたび、応募されたキャンペーンごとに運営チームへ直接お問い合わせができる「メッセージ」機能を追加します。あわせて、利用規約とプライバシーポリシーを一部改定いたします。
  </p>

  <div style="margin:0 0 16px">
    <div style="font-weight:700;color:#5B6BBF;margin-bottom:6px">■ 何が変わりますか</div>
    <div style="margin-left:2px">
      1. 応募履歴の各キャンペーンから、運営チームにメッセージ（文章・画像）を送れるようになります。<br>
      2. これまで LINE でいただいていた個別のお問い合わせを、アプリ内でも受け付けます。
    </div>
  </div>

  <div style="margin:0 0 16px">
    <div style="font-weight:700;color:#5B6BBF;margin-bottom:6px">■ 新しく集める情報</div>
    <div style="margin-left:2px">
      ・メッセージの本文（テキスト）と、添付した画像<br>
      ・利用目的：応募件に関する運営チームへのお問い合わせ・返信・確認のため<br>
      ・保管期間：応募が終了してから1年（退会された場合はその時点で削除）
    </div>
  </div>

  <div style="margin:0 0 16px">
    <div style="font-weight:700;color:#5B6BBF;margin-bottom:6px">■ メッセージを見られる人</div>
    <div style="margin-left:2px">
      ・送信したご本人と、REVERB JP の運営チーム担当者だけが見られます。<br>
      ・他の会員のメッセージは見ることができません。<br>
      ・担当者がメッセージを開いたり画像を保存したりした記録は、安全のためにすべて残されます。
    </div>
  </div>

  <div style="margin:0 0 16px">
    <div style="font-weight:700;color:#5B6BBF;margin-bottom:6px">■ 同意について</div>
    <div style="margin-left:2px">
      メッセージはサービス運営のための連絡手段のため、別途の同意操作は不要です。施行日以降も続けてご利用いただくことで、改定内容にご同意いただいたものとします。ご同意いただけない場合は、メッセージ機能をご利用にならないか、退会の手続きが可能です。
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
