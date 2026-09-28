// 자동 생성 (sync-email-templates.sh) — 직접 수정 금지
// docs/email-templates/ 변경 후 sync 스크립트 실행 시 자동 갱신
//
// 백틱·${...} 패턴은 sed로 escape 처리. 새 템플릿 추가 시 패턴 점검 필요

export const TEMPLATES: Record<string, string> = {
  "policy-change-notice": `<!DOCTYPE html>
<!--
  Mail: 약관·개인정보처리방침 개정 사전 통지 (policy change notice) — 개인정보처리방침 개정(메타 픽셀 §8.1 신설)
  Trigger: 운영자가 notify-policy-change Edge Function 을 1회 수동 호출
           (cron 아님 — 사건 단위 일회성 발송). noticeKey = meta_pixel_2026 (반드시 명시 — 빼면 옛 기본 키로 떨어진다)
  To: 전체 인플루언서 1명당 1통 (marketing_opt_in 무관 — 홍보가 아닌 서비스 고지라 수신 동의 대상이 아니다)
  Lang: JA (인플루언서 대상)
  멱등: policy_notice_sent (influencer_id, notice_key) UNIQUE
  중복호출 차단: policy_notice_runs.notice_key UNIQUE (mutex)

  이 템플릿은 통지 한 번에만 쓰고 다음 통지 때 통째로 갈아 끼운다. 그래서 날짜는 자리표시가 아니라 글자로 박았다.
    공고일 2026-09-17 / 공지 기간 끝 2026-10-16 / 시행일 2026-10-17 (정의처: 사양서 §3 표)
    함수 호출 인자 effectiveDate 도 같은 날(2026年10月17日)을 넘긴다. 제목·텍스트 판은 index.ts 의 buildMail 안에 있다.

  블록 순서(사양서 §4-1): 머리 → 인사 → 개정 일정 → 주요 개정 내용 → 회원에게 중요한 셋 → 개정 항목 표 → 맺음말(동의 간주) → 전문 안내 → 4줄 푸터
    - 「회원에게 중요한 셋」(설정에서 끌 수 있다)이 맺음말(동의하지 않으면 탈퇴)보다 반드시 앞. 뒤집히면 「끄려면 탈퇴해야 한다」로 읽힌다.
    - 「회원에게 중요한 셋」은 「オフ」(끄기), 맺음말은 「拒否の意思」(거부 의사) — 낱말을 섞지 않는다.
    - 「개정 후」 칸의 문장은 docs/PRIVACY_ja.md 에서 글자 그대로 가져온 것이다. 고치려면 방침부터 고친다(= 재공고).
    - 표 안에 표를 넣지 않는다 — 방침 8.1 의 4칸 표는 글머리 넷으로 풀었다. 방침의 「拒否の方法」 글머리는 그 칸에 넣지 않는다.

  문안 원본: docs/specs/2026-09-17-meta-pixel-policy-notice.md §4-1
-->
<div style="font-family:'Hiragino Sans','Noto Sans JP',Arial,sans-serif;color:#222;max-width:600px;margin:0 auto;font-size:14px;line-height:1.7">
  <h2 style="color:#5B6BBF;margin:0 0 6px;font-size:19px">個人情報処理方針 改定のお知らせ</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">REVERB JP からの大切なお知らせです</p>

  <p style="margin:0 0 16px">
    いつも REVERB JP をご利用いただきありがとうございます。<br>
    よりよいサービスのご提供のため、個人情報処理方針の一部を改定します。下記の内容をご確認ください。
  </p>

  <div style="margin:0 0 16px;padding:12px 14px;background:#F4F6FF;border-radius:8px">
    <div style="font-weight:700;color:#5B6BBF;margin-bottom:4px">■ 改定スケジュール</div>
    <div>
      ・お知らせ期間：2026年9月17日（木）〜 2026年10月16日（金）<br>
      ・施行日：<strong>2026年10月17日（土）</strong>
    </div>
  </div>

  <div style="margin:0 0 16px">
    <div style="font-weight:700;color:#5B6BBF;margin-bottom:6px">■ 主な改定内容</div>
    <div style="margin-left:2px">
      ・広告の効果を測定するためのツール「Metaピクセル」の導入に伴い、外部サービスへの情報送信に関する事項を新設します。
    </div>
  </div>

  <div style="margin:0 0 16px">
    <div style="font-weight:700;color:#5B6BBF;margin-bottom:6px">■ 会員の皆さまへ</div>
    <div style="margin-left:2px">
      ・お名前・メールアドレス・電話番号・配送先などの会員情報は送信しません。<br>
      ・この送信は、お使いのブラウザの設定（トラッキング防止など）でオフにできます。また、FacebookやInstagramをお使いの方は、ご自身のMetaアカウントの「広告設定」で、送られた情報を広告に使うことをオフにできます。<br>
      ・オフにしても、REVERB JP はこれまでどおりご利用いただけます。
    </div>
  </div>

  <div style="margin:0 0 16px">
    <div style="font-weight:700;color:#5B6BBF;margin-bottom:6px">■ 改定項目</div>
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;font-size:12.5px;line-height:1.65">
      <tr>
        <th align="left" style="width:34%;padding:8px 10px;background:#F4F6FF;border:1px solid #D9DEF2;color:#5B6BBF;font-weight:700">改定前</th>
        <th align="left" style="padding:8px 10px;background:#F4F6FF;border:1px solid #D9DEF2;color:#5B6BBF;font-weight:700">改定後</th>
      </tr>
      <tr>
        <td colspan="2" style="padding:7px 10px;background:#FAFAFC;border:1px solid #D9DEF2;font-weight:700;color:#444">第5条（個人情報の国外移転）</td>
      </tr>
      <tr>
        <td valign="top" style="padding:8px 10px;border:1px solid #D9DEF2;color:#777">（記載なし）</td>
        <td valign="top" style="padding:8px 10px;border:1px solid #D9DEF2">インフルエンサーサイトのMetaピクセルによる情報送信は、当社が提供するものではなくMetaが会員のブラウザから直接収集するものであり、§8.1によります。</td>
      </tr>
      <tr>
        <td colspan="2" style="padding:7px 10px;background:#FAFAFC;border:1px solid #D9DEF2;font-weight:700;color:#444">第8条 8.1 外部サービスへの情報送信（Metaピクセル）</td>
      </tr>
      <tr>
        <td valign="top" style="padding:8px 10px;border:1px solid #D9DEF2;color:#777">＜新設＞</td>
        <td valign="top" style="padding:8px 10px;border:1px solid #D9DEF2">
          当社は、広告効果の測定および広告配信の最適化のため、インフルエンサーサイトにMeta Platforms, Inc.（米国）が提供する「Metaピクセル」を設置します。このツールは会員のブラウザからMetaへ下記の情報を直接送信するもので、当社がMetaの収集した情報を受け取ったり、会員情報と結び付けたりすることはありません。<br>
          <br>
          ・送信される情報：閲覧したページのURL・閲覧日時、ブラウザ・端末情報、IPアドレス、Cookie識別子／キャンペーン詳細の閲覧・会員登録の申込み・メール認証の完了・キャンペーン応募完了の事実、（キャンペーン詳細の閲覧・応募完了時）当該キャンペーンの識別番号・タイトル<br>
          ・送信先：Meta Platforms, Inc.（米国）<br>
          ・当社の利用目的：どの広告を経由して訪問・登録・応募に至ったかの測定、広告配信対象の最適化<br>
          ・送信先の利用目的：Metaのデータポリシーに基づく広告の提供・測定等（https://www.facebook.com/privacy/policy/）
        </td>
      </tr>
    </table>
  </div>

  <p style="margin:0 0 16px">
    改定後の個人情報処理方針に同意いただけない場合は、退会（利用契約の解除）をお申し出いただけます。お知らせ期間内（2026年10月16日まで）に改定内容への拒否の意思を表明されない場合は、改定内容に同意いただいたものとみなします。<br>
    退会は、メニューの「退会する」からお手続きいただけます。
  </p>

  <p style="margin:0 0 16px;color:#555;font-size:13px">
    改定後の全文は、サイト下部の「個人情報処理方針」からご確認いただけます。<br>
    <a href="https://globalreverb.com" style="color:#5B6BBF;text-decoration:underline">https://globalreverb.com</a>
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
