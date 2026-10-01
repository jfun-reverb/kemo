// 자동 생성 (sync-email-templates.sh) — 직접 수정 금지
// docs/email-templates/ 변경 후 sync 스크립트 실행 시 자동 갱신
//
// 백틱·${...} 패턴은 sed로 escape 처리. 새 템플릿 추가 시 패턴 점검 필요

export const TEMPLATES: Record<string, string> = {
  "signup-code": `<!DOCTYPE html>
<!--
  Mail: 회원가입 이메일 인증번호 (인플루언서 가입 희망자용)
  Trigger: signup-code-send Edge Function (가입 화면의 「認証する」 — 비로그인 호출)
  To:      가입하려는 이메일 주소 (그 사람이 입력한 주소)
  Lang:    JA
  Style:   🔴 가입·로그인 길 메일이라 **가입 확인 메일(confirm-signup.html)과 같은 틀**(진한 머리 + R 로고 + 분홍). 활동 알림 메일(빨간 머리)과 다르다

  Placeholders:
    {{code}}      6자리 숫자 (함수가 숫자만 넣는다)
    {{minutes}}   유효 시간(분, 숫자) — code_expires_at 에서 계산
    {{site_url}}  사이트 루트 URL
    {{help_line_url}} LINE 문의 URL

  ── 한국어 뜻(담당자 전달용, 화면에는 노출되지 않음) ──────────────────
    제목: "[REVERB JP] 인증 코드 안내"
    본문: "인증 코드 안내 / REVERB JP에 가입해 주셔서 감사합니다. 아래 6자리 숫자를 가입 화면에 입력해 주세요.
          [큰 숫자] / 이 코드는 {{minutes}}분간 유효합니다.
          이 메일에 짚이는 데가 없으면 아무것도 하지 말고 이 메일을 삭제해 주세요."
    푸터(4줄, 회원 메일 공통 문구)
  ──────────────────────────────────────────────────────────────────
-->
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
</head>
<body style="margin:0;padding:0;background:#E8E0EC;font-family:'Helvetica Neue',Arial,'Hiragino Kaku Gothic ProN','Noto Sans JP',sans-serif;-webkit-font-smoothing:antialiased;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#E8E0EC;padding:40px 16px;">
    <tr>
      <td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:440px;background:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 2px 6px 2px rgba(0,0,0,.08),0 1px 2px rgba(0,0,0,.04);">

          <!-- ヘッダー (가입 확인 메일 confirm-signup.html 과 같은 틀) -->
          <tr>
            <td style="background:#2D1F2B;padding:28px 24px;text-align:center;">
              <div style="width:44px;height:44px;background:#C878A3;border-radius:10px;display:inline-block;line-height:44px;font-family:'Helvetica Neue',Arial,sans-serif;font-weight:800;font-size:20px;color:#ffffff;">R</div>
              <div style="color:#ffffff;font-size:18px;font-weight:700;margin-top:10px;letter-spacing:0.5px;">REVERB JP</div>
            </td>
          </tr>

          <!-- 本文 -->
          <tr>
            <td style="padding:32px 28px 24px;">
              <h1 style="font-size:18px;font-weight:700;color:#1E1320;margin:0 0 16px;line-height:1.5;">認証コードのお知らせ</h1>
              <p style="font-size:14px;color:#7A6B78;line-height:1.7;margin:0 0 24px;">
                REVERB JP にご登録いただきありがとうございます。<br>
                下の6けたの数字を、登録画面に入力してください。
              </p>

              <!-- 認証コード -->
              <div style="background:#FDF0F7;border-radius:12px;padding:20px 18px;margin-bottom:20px;text-align:center;">
                <div style="font-size:11px;font-weight:700;color:#7D4A6A;letter-spacing:0.1em;margin-bottom:8px;">認証コード</div>
                <div style="font-size:34px;font-weight:800;color:#1E1320;letter-spacing:0.3em;padding-left:0.3em;">{{code}}</div>
              </div>

              <p style="font-size:14px;color:#7A6B78;line-height:1.7;margin:0 0 12px;">
                このコードは <b style="color:#1E1320;">{{minutes}}分間</b> 有効です。
              </p>
              <p style="font-size:12px;color:#7A6B78;line-height:1.7;margin:0;">
                ※ このメールに心当たりがない場合は、何もせずこのメールを削除してください。
              </p>
            </td>
          </tr>

          <!-- フッター (회원 메일 4줄 푸터 — 자동 발송 안내 · LINE · © JFUN · 사이트 주소) -->
          <tr>
            <td style="background:#F8F5F8;padding:20px 28px;text-align:center;">
              <p style="font-size:11px;color:#999999;line-height:1.6;margin:0;">
                REVERB JP のメンバーシップに紐づいて自動送信されています。<br>
                お問い合わせは LINE <a href="{{help_line_url}}" style="color:#999999;text-decoration:underline">@reverb.jp</a> までお願いいたします。
              </p>
              <p style="font-size:11px;color:#999999;line-height:1.6;margin:12px 0 0;">
                © JFUN Corp. · 株式会社ジェイファン<br>
                <a href="{{site_url}}" style="color:#999999;text-decoration:underline">{{site_url}}</a>
              </p>
            </td>
          </tr>

        </table>
      </td>
    </tr>
  </table>
</body>
</html>`,
  "signup-already-registered": `<!DOCTYPE html>
<!--
  Mail: 회원가입 — 이미 가입된 주소 안내 (인증번호 대신 보낸다)
  Trigger: signup-code-send Edge Function — 가입 화면 「認証する」 때 그 주소에 인증 완료 계정이 있으면
           번호 메일 대신 이 메일. 🔴 화면 응답은 번호 메일과 똑같다(가입 여부는 이 메일함 주인만 안다)
  To:      가입 화면에 입력된 이메일 주소
  Lang:    JA
  Style:   🔴 가입 확인 메일(confirm-signup.html)과 같은 틀(진한 머리 + R 로고 + 분홍)

  Placeholders:
    {{login_url}}     로그인 화면 주소 (사이트/#login)
    {{forgot_url}}    비밀번호 재설정 화면 주소 (사이트/#forgot)
    {{site_url}}      사이트 루트 URL
    {{help_line_url}} LINE 문의 URL

  ── 한국어 뜻(담당자 전달용, 화면에는 노출되지 않음) ──────────────────
    제목: "[REVERB JP] 이미 가입되어 있습니다"
    본문: "이미 가입되어 있습니다 / 이 메일 주소는 이미 REVERB JP에 가입되어 있어서 인증 코드는 보내지 않았습니다.
          아래 「ログイン」(로그인)을 눌러 로그인해 주세요.
          비밀번호를 잊으셨다면 「パスワードを再設定する」(비밀번호 재설정)를 눌러 주세요.
          짚이는 데가 없으면 삭제해 주세요(가입 정보는 바뀌지 않습니다)."
    푸터(4줄, 회원 메일 공통 문구)
  ──────────────────────────────────────────────────────────────────
-->
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
</head>
<body style="margin:0;padding:0;background:#E8E0EC;font-family:'Helvetica Neue',Arial,'Hiragino Kaku Gothic ProN','Noto Sans JP',sans-serif;-webkit-font-smoothing:antialiased;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#E8E0EC;padding:40px 16px;">
    <tr>
      <td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:440px;background:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 2px 6px 2px rgba(0,0,0,.08),0 1px 2px rgba(0,0,0,.04);">

          <!-- ヘッダー (가입 확인 메일 confirm-signup.html 과 같은 틀) -->
          <tr>
            <td style="background:#2D1F2B;padding:28px 24px;text-align:center;">
              <div style="width:44px;height:44px;background:#C878A3;border-radius:10px;display:inline-block;line-height:44px;font-family:'Helvetica Neue',Arial,sans-serif;font-weight:800;font-size:20px;color:#ffffff;">R</div>
              <div style="color:#ffffff;font-size:18px;font-weight:700;margin-top:10px;letter-spacing:0.5px;">REVERB JP</div>
            </td>
          </tr>

          <!-- 本文 -->
          <tr>
            <td style="padding:32px 28px 24px;">
              <h1 style="font-size:18px;font-weight:700;color:#1E1320;margin:0 0 16px;line-height:1.5;">すでに登録されています</h1>
              <p style="font-size:14px;color:#7A6B78;line-height:1.7;margin:0 0 24px;">
                このメールアドレスは、すでに REVERB JP に登録されています。<br>
                そのため、認証コードはお送りしていません。<br>
                下の「ログイン」を押して、ログインしてください。
              </p>

              <!-- CTA ボタン -->
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                <tr>
                  <td align="center" style="padding:4px 0 24px;">
                    <a href="{{login_url}}"
                       style="display:inline-block;background:#C878A3;color:#ffffff;font-size:15px;font-weight:600;text-decoration:none;padding:14px 40px;border-radius:12px;letter-spacing:0.3px;">
                      ログイン
                    </a>
                  </td>
                </tr>
              </table>

              <!-- パスワード再設定 -->
              <div style="background:#FDF0F7;border-radius:10px;padding:16px 18px;margin-bottom:16px;text-align:center;">
                <p style="font-size:12px;color:#7D4A6A;line-height:1.7;margin:0 0 10px;">
                  パスワードをわすれたときは、こちらから新しく設定できます。
                </p>
                <a href="{{forgot_url}}" style="display:inline-block;background:#ffffff;color:#C878A3;border:1px solid #C878A3;font-size:13px;font-weight:600;text-decoration:none;padding:10px 24px;border-radius:10px;">パスワードを再設定する</a>
              </div>

              <p style="font-size:12px;color:#7A6B78;line-height:1.7;margin:0;">
                ※ このメールに心当たりがない場合は、何もせずこのメールを削除してください。登録内容は変わりません。
              </p>
            </td>
          </tr>

          <!-- フッター (회원 메일 4줄 푸터 — 자동 발송 안내 · LINE · © JFUN · 사이트 주소) -->
          <tr>
            <td style="background:#F8F5F8;padding:20px 28px;text-align:center;">
              <p style="font-size:11px;color:#999999;line-height:1.6;margin:0;">
                REVERB JP のメンバーシップに紐づいて自動送信されています。<br>
                お問い合わせは LINE <a href="{{help_line_url}}" style="color:#999999;text-decoration:underline">@reverb.jp</a> までお願いいたします。
              </p>
              <p style="font-size:11px;color:#999999;line-height:1.6;margin:12px 0 0;">
                © JFUN Corp. · 株式会社ジェイファン<br>
                <a href="{{site_url}}" style="color:#999999;text-decoration:underline">{{site_url}}</a>
              </p>
            </td>
          </tr>

        </table>
      </td>
    </tr>
  </table>
</body>
</html>`,
};
