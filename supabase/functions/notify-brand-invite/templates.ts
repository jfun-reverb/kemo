// 자동 생성 (sync-email-templates.sh) — 직접 수정 금지
// docs/email-templates/ 변경 후 sync 스크립트 실행 시 자동 갱신
//
// 백틱·${...} 패턴은 sed로 escape 처리. 새 템플릿 추가 시 패턴 점검 필요

export const TEMPLATES: Record<string, string> = {
  "brand-invite-new": `<!--
  Mail: 브랜드 멤버 초대 ⓐ — 이 이메일로 만든 계정이 아직 없는 사람 (비밀번호를 정하며 수락)
  Trigger: 브랜드 대표가 멤버 관리에서 「초대」/「다시 보내기」를 누르면 Edge Function notify-brand-invite 가 발송
  To:      초대받은 사람 (brand_invites.email — 서버가 초대 줄에서 다시 읽음)
  Lang:    KO (브랜드 담당자 대상 — 기존 브랜드 메일과 같다)
  Placeholders:
    {{brand_name}}    초대받는 브랜드 이름
    {{inviter_name}}  초대한 대표 이름 (보낸 순간의 스냅샷)
    {{link}}          /brand/?link=<초대 링크 번호>&kind=invite (일회용 인증 링크 없음)
    {{expires}}       유효 기한 문구 (초대 줄의 expires_at 을 한국 시간으로)
  사양서 §16-3 2번(누가·왜·모르면 무시). 갈래 ⓐ·ⓑ·ⓒ 는 제목·본문 문구만 다르다 — 메일 보낸 사실로 갈래가 드러나는 것은 받는 사람 본인뿐이다.
  관리자·브랜드 대상 메일이라 인플루언서 4줄 푸터 의무 없음.
-->
<!DOCTYPE html>
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#E8344E;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">「{{brand_name}}」 브랜드 페이지에 초대되었습니다</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">안녕하세요.</p>
  <p style="margin:0 0 12px;font-size:13px;color:#444;line-height:1.7">REVERB 브랜드 페이지의 「{{brand_name}}」 브랜드 대표 담당자 {{inviter_name}} 님이 이 이메일 주소로 멤버 초대를 보냈습니다.</p>
  <p style="margin:0 0 12px;font-size:13px;color:#444;line-height:1.7">아래 버튼을 눌러 이름과 비밀번호를 정하면 초대를 수락하고 「{{brand_name}}」 브랜드 페이지를 함께 쓰실 수 있습니다.</p>
  <div style="text-align:center;margin:8px 0 22px">
    <a href="{{link}}" style="display:inline-block;background:#E8344E;color:#fff;text-decoration:none;font-weight:700;font-size:14px;padding:13px 28px;border-radius:10px">초대 수락하기</a>
  </div>
  <div style="background:#F7F4EE;border:1px solid #EAEAE4;border-radius:12px;padding:16px 18px;margin-bottom:20px;font-size:13px">
    <div style="color:#888;font-size:11px;letter-spacing:0.08em;margin-bottom:4px;text-transform:uppercase;font-weight:700">초대 유효 시간</div>
    <div style="font-weight:700;color:#161618">{{expires}}</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">기한이 지나면 링크가 열리지 않습니다. 그때는 초대하신 분께 초대를 다시 보내 달라고 요청해 주세요.</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">버튼이 눌리지 않으면 아래 주소를 복사해 브라우저에 붙여넣어 주세요.</div>
    <div style="font-family:monospace;font-size:12px;color:#555;word-break:break-all;margin-top:4px">{{link}}</div>
  </div>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">본인과 관련 없거나 무슨 메일인지 모르시겠다면, 이 메일을 무시하셔도 됩니다. 링크를 누르지 않으면 아무 일도 일어나지 않습니다.</p>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">이 메일은 발신 전용입니다. 문의는 초대하신 분이나 REVERB 운영팀 담당자에게 직접 연락해 주세요.</p>
  <p style="margin-top:24px;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
</div>`,
  "brand-invite-existing": `<!--
  Mail: 브랜드 멤버 초대 ⓑ — 이미 브랜드 계정이 있는 사람 (로그인해서 수락)
  Trigger: 브랜드 대표가 멤버 관리에서 「초대」/「다시 보내기」를 누르면 Edge Function notify-brand-invite 가 발송
  To:      초대받은 사람 (brand_invites.email — 서버가 초대 줄에서 다시 읽음)
  Lang:    KO
  Placeholders: brand-invite-new 와 같다 ({{brand_name}} · {{inviter_name}} · {{link}} · {{expires}})
  사양서 §16-3 1번·2번. 링크는 로그인 화면으로 이어지고, 로그인한 뒤 수락한다(비밀번호는 지금 것을 쓴다).
-->
<!DOCTYPE html>
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#E8344E;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">「{{brand_name}}」 브랜드 페이지에 초대되었습니다</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">안녕하세요.</p>
  <p style="margin:0 0 12px;font-size:13px;color:#444;line-height:1.7">REVERB 브랜드 페이지의 「{{brand_name}}」 브랜드 대표 담당자 {{inviter_name}} 님이 이 이메일 주소로 멤버 초대를 보냈습니다.</p>
  <p style="margin:0 0 12px;font-size:13px;color:#444;line-height:1.7">이미 사용 중인 REVERB 브랜드 페이지 계정이 있으시면, 아래 버튼을 눌러 지금 쓰시는 계정으로 로그인한 뒤 초대를 수락해 주세요. 수락하면 「{{brand_name}}」 브랜드가 내 브랜드 목록에 함께 보입니다.</p>
  <div style="text-align:center;margin:8px 0 22px">
    <a href="{{link}}" style="display:inline-block;background:#E8344E;color:#fff;text-decoration:none;font-weight:700;font-size:14px;padding:13px 28px;border-radius:10px">로그인해서 수락하기</a>
  </div>
  <div style="background:#F7F4EE;border:1px solid #EAEAE4;border-radius:12px;padding:16px 18px;margin-bottom:20px;font-size:13px">
    <div style="color:#888;font-size:11px;letter-spacing:0.08em;margin-bottom:4px;text-transform:uppercase;font-weight:700">초대 유효 시간</div>
    <div style="font-weight:700;color:#161618">{{expires}}</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">기한이 지나면 링크가 열리지 않습니다. 그때는 초대하신 분께 초대를 다시 보내 달라고 요청해 주세요.</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">버튼이 눌리지 않으면 아래 주소를 복사해 브라우저에 붙여넣어 주세요.</div>
    <div style="font-family:monospace;font-size:12px;color:#555;word-break:break-all;margin-top:4px">{{link}}</div>
  </div>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">본인과 관련 없거나 무슨 메일인지 모르시겠다면, 이 메일을 무시하셔도 됩니다. 링크를 누르지 않으면 아무 일도 일어나지 않습니다.</p>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">이 메일은 발신 전용입니다. 문의는 초대하신 분이나 REVERB 운영팀 담당자에게 직접 연락해 주세요.</p>
  <p style="margin-top:24px;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
</div>`,
  "brand-invite-blocked": `<!--
  Mail: 브랜드 멤버 초대 ⓒ — 이 이메일로는 초대를 받을 수 없는 경우 (링크 없음)
  Trigger: 브랜드 대표가 멤버 관리에서 「초대」/「다시 보내기」를 누르면 Edge Function notify-brand-invite 가 발송
  To:      초대받은 사람 (brand_invites.email)
  Lang:    KO
  Placeholders:
    {{brand_name}} · {{inviter_name}}   (링크·유효 기한 칸 없음)
  🔴 이유(관리자·인플루언서 계정 이메일 등)를 적지 않는다 — 받는 사람과 대표 모두에게 계정 종류가 드러나지 않게. 문구는 ⓐ·ⓑ 와 같은 틀에서 링크만 뺐다.
-->
<!DOCTYPE html>
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#E8344E;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">「{{brand_name}}」 브랜드 페이지 초대를 받을 수 없습니다</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">안녕하세요.</p>
  <p style="margin:0 0 12px;font-size:13px;color:#444;line-height:1.7">REVERB 브랜드 페이지의 「{{brand_name}}」 브랜드 대표 담당자 {{inviter_name}} 님이 이 이메일 주소로 멤버 초대를 보냈지만, 이 이메일 주소로는 초대를 받을 수 없습니다.</p>
  <p style="margin:0 0 12px;font-size:13px;color:#444;line-height:1.7">초대하신 분께 <b>다른 이메일 주소로 초대를 요청해 주세요.</b> 이 메일에는 누르실 링크가 없습니다.</p>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">본인과 관련 없거나 무슨 메일인지 모르시겠다면, 이 메일을 무시하셔도 됩니다. 링크를 누르지 않으면 아무 일도 일어나지 않습니다.</p>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">이 메일은 발신 전용입니다. 문의는 초대하신 분이나 REVERB 운영팀 담당자에게 직접 연락해 주세요.</p>
  <p style="margin-top:24px;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
</div>`,
};
