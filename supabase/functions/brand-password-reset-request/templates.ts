// 자동 생성 (sync-email-templates.sh) — 직접 수정 금지
// docs/email-templates/ 변경 후 sync 스크립트 실행 시 자동 갱신
//
// 백틱·${...} 패턴은 sed로 escape 처리. 새 템플릿 추가 시 패턴 점검 필요

export const TEMPLATES: Record<string, string> = {
  "brand-password-reset": `<!DOCTYPE html>
<!--
  Mail: 브랜드 계정 비밀번호 재설정 — 본인이 요청한 재설정 링크 (brand password reset)
  Trigger: 브랜드 로그인 화면의 「비밀번호를 잊으셨나요」 → Edge Function
           brand-password-reset-request (익명 호출) → 이 템플릿으로 발송
  To:      요청한 이메일이 「비밀번호 설정을 마친 브랜드 계정」일 때만 (아니면 발송 자체를 안 함)
           설정 전 계정에는 이 양식이 아니라 brand-account-setup 양식(다시 보냄 문구)이 나간다
  Lang:    KO (브랜드 페이지 UI 도 한국어)

  Placeholders:
    {{contact_name}}  담당자 이름 (없으면 「담당자」)
    {{link}}          비밀번호 재설정 링크 (/brand/?link=<id>&mode=reset#confirm=… 서버 발급)
    {{expires}}       링크 유효 시간 안내 문구 (24시간)

  Note:
    「본인이 요청하지 않았다면 무시 — 비밀번호는 바뀌지 않는다」 안내 필수 — 남이 남의 주소로 요청할 수 있는
    공개 경로(로그인 화면)에서 발송되기 때문.
    브랜드 대상 메일이라 인플루언서 4줄 푸터 의무 없음.
-->
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#E8344E;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">REVERB 브랜드 페이지 비밀번호 재설정</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">{{contact_name}} 님</p>
  <p style="margin:0 0 12px;font-size:13px;color:#444;line-height:1.7">REVERB 브랜드 페이지의 비밀번호 재설정이 요청되었습니다.</p>
  <p style="margin:0 0 20px;font-size:13px;color:#444;line-height:1.7">아래 버튼을 눌러 새 비밀번호를 정해 주십시오.</p>
  <div style="text-align:center;margin:0 0 22px">
    <a href="{{link}}" style="display:inline-block;background:#E8344E;color:#fff;text-decoration:none;font-weight:700;font-size:14px;padding:13px 28px;border-radius:10px">비밀번호 다시 정하기</a>
  </div>
  <div style="background:#F7F4EE;border:1px solid #EAEAE4;border-radius:12px;padding:16px 18px;margin-bottom:20px;font-size:13px">
    <div style="color:#888;font-size:11px;letter-spacing:0.08em;margin-bottom:4px;text-transform:uppercase;font-weight:700">링크 유효 시간</div>
    <div style="font-weight:700;color:#161618">{{expires}}</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">기한이 지나면 링크가 열리지 않습니다. 그때는 로그인 화면에서 「비밀번호를 잊으셨나요」를 다시 눌러 주십시오. 여러 번 요청하셨다면 가장 최근에 받은 링크만 사용할 수 있습니다.</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">버튼이 눌리지 않으면 아래 주소를 복사해 브라우저에 붙여넣어 주십시오.</div>
    <div style="font-family:monospace;font-size:12px;color:#555;word-break:break-all;margin-top:4px">{{link}}</div>
  </div>
  <p style="margin:0 0 18px;font-size:12px;color:#888;line-height:1.7">
    본인이 요청하지 않으셨다면 이 메일을 무시하셔도 됩니다. 링크를 누르지 않으면 비밀번호는 바뀌지 않습니다.
  </p>
  <p style="margin:0 0 18px;font-size:12px;color:#888;line-height:1.7">
    이 메일은 발신 전용입니다. 문의는 REVERB 운영팀 담당자에게 직접 연락해 주십시오.
  </p>
  <p style="margin-top:24px;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
</div>`,
  "brand-account-setup": `<!DOCTYPE html>
<!--
  Mail: 브랜드 계정 생성 — 비밀번호 설정 링크 전달 (brand account setup)
  Trigger: 관리자가 브랜드 상세에서 「계정 만들기」/「다시 보내기」를 누르면 Edge Function notify-brand-account-setup 이 이 템플릿으로 발송.
           (옛 「브랜드 연결 추가」 연결 안내 갈래 mail_kind:'link' 는 2026-10-21 걷었다 — 기존 계정 연결은 notify-brand-invite 의 연결 요청 메일)
           비밀번호 찾기에서 설정 전 계정에 다시 보낼 때는 brand-password-reset-request 가 같은 템플릿을 쓴다
  To:      브랜드 대표 담당자 본인 (brand_accounts.email — 서버가 brand_id 로 다시 읽음)
  Lang:    KO (브랜드 담당자는 한국 회사 — 브랜드 페이지 UI 도 한국어)

  Placeholders:
    {{heading}}       제목 줄 (만들어짐 / 연결됨 / 다시 보냄 / 본인 요청 분기 — 두 함수가 넘긴다)
    {{brand_name}}    브랜드 이름
    {{contact_name}}  담당자 이름 (없으면 「담당자」)
    {{link}}          비밀번호 설정 링크 (/brand/?link=<id>&mode=setup#confirm=… 서버 발급)
    {{intro}}         도입 문장 — 처음 보냄 / 다시 보냄 / 연결 / 본인 요청 분기
    {{expires}}       링크 유효 시간 안내 문구 (24시간)
    {{expires_after}} 기한이 지난 뒤 안내 — 운영팀이 보냄: 「운영팀에 다시 요청」 / 본인 요청(비밀번호 찾기): 「로그인 화면에서 다시 요청」
    {{sent_by}}       누가 보냈나 — 운영팀이 보냄 / 본인 요청(2026-10-20 사용자 결정 — 본인이 요청했는데 운영팀이 보낸 것처럼 읽히지 않게)

  사양서 §16-3 2번(누가·왜·모르면 무시) · 9번(개인정보 이용 안내 — 초안, /약관확인 뒤 확정)
  관리자·브랜드 대상 메일이라 인플루언서 4줄 푸터 의무 없음.
-->
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#E8344E;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">{{heading}}</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">{{contact_name}} 님</p>
  <p style="margin:0 0 12px;font-size:13px;color:#444;line-height:1.7">{{intro}}</p>
  <p style="margin:0 0 20px;font-size:13px;color:#444;line-height:1.7">아래 버튼을 눌러 사용하실 비밀번호를 설정해 주십시오. 설정을 마치면 REVERB 브랜드 페이지에 로그인하실 수 있습니다.</p>
  <div style="text-align:center;margin:0 0 22px">
    <a href="{{link}}" style="display:inline-block;background:#E8344E;color:#fff;text-decoration:none;font-weight:700;font-size:14px;padding:13px 28px;border-radius:10px">비밀번호 설정하기</a>
  </div>
  <div style="background:#F7F4EE;border:1px solid #EAEAE4;border-radius:12px;padding:16px 18px;margin-bottom:20px;font-size:13px">
    <div style="color:#888;font-size:11px;letter-spacing:0.08em;margin-bottom:4px;text-transform:uppercase;font-weight:700">링크 유효 시간</div>
    <div style="font-weight:700;color:#161618">{{expires}}</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">{{expires_after}}</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">버튼이 눌리지 않으면 아래 주소를 복사해 브라우저에 붙여넣어 주십시오.</div>
    <div style="font-family:monospace;font-size:12px;color:#555;word-break:break-all;margin-top:4px">{{link}}</div>
  </div>
  <!-- 16-3 9번 초안 — /약관확인 뒤 확정 (담당자 정보를 이 계정에 쓰는 용도 안내). 이 주석은 발송 때 제거된다 -->
  <p style="margin:0 0 10px;font-size:12px;color:#888;line-height:1.7">
    REVERB 운영팀은 문의 또는 기존 연락으로 전달받은 담당자 정보(이름·이메일·연락처)를 브랜드 페이지 계정을 만들거나 연결하는 데에만 사용했습니다. 개인정보 이용에 관한 문의는 REVERB 운영팀으로 연락해 주십시오.
  </p>
  <p style="margin:0 0 10px;font-size:12px;color:#888;line-height:1.7">
    {{sent_by}}
  </p>
  <p style="margin:0 0 18px;font-size:12px;color:#888;line-height:1.7">
    본인이 요청하지 않았거나 무슨 메일인지 모르시겠다면, 이 메일을 무시하셔도 됩니다. 링크를 누르지 않으면 아무 일도 일어나지 않습니다.
  </p>
  <p style="margin:0 0 18px;font-size:12px;color:#888;line-height:1.7">
    이 메일은 발신 전용입니다. 문의는 REVERB 운영팀 담당자에게 직접 연락해 주십시오.
  </p>
  <p style="margin-top:24px;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
</div>`,
};
