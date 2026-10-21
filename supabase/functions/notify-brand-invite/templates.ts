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
  유효 시간은 고정 문구 「보낸 때부터 24시간」(초대 줄 expires_at 과 같은 값 — 다시 보내면 새로 24시간).
  사양서 §16-3 2번(누가·왜·모르면 무시). 갈래 ⓐ·ⓑ·ⓒ 는 제목은 같고 본문만 다르다.
  관리자·브랜드 대상 메일이라 인플루언서 4줄 푸터 의무 없음.
  🔴 문구 정본 = 피그마 「[1차] 06 멤버 관리」 bw01-97·97a·97b(초안, 2026-10-16 사용자 결정 「초안대로 맞춘다」). 제목은 서버 함수 index.ts 가 만든다 —
     「[REVERB JP] {{inviter_name}} 님이 「{{brand_name}}」 브랜드 페이지에 초대했습니다 — 비밀번호를 설정해 주십시오 (MM/DD HH:MM)」(갈래마다 다른 제목 + 보낸 시각 — 2026-10-20 사용자 결정. 피그마 제목 끝 「(초안)」은 시안 표시라 넣지 않음).
  텍스트 판(index.ts 안)이 같은 문구의 사본이다 — 이 파일을 고치면 그쪽도 함께.
  ⚠️ 피그마 ⓐ 의 「[용도 안내 문단 — 약관 확인 뒤 채운다]」 자리 — 약관 확인(/약관확인) 뒤 「이 메일은 … 보냈습니다.」 아래에 문단을 넣는다. 지금은 비워 둔다.
-->
<!DOCTYPE html>
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#161618;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">「{{brand_name}}」 브랜드 페이지에 초대받았습니다</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">안녕하십니까</p>
  <p style="margin:0 0 12px;font-size:13px;color:#444;line-height:1.7">「{{brand_name}}」 브랜드의 대표 담당자 {{inviter_name}} 님이 REVERB 브랜드 페이지에 함께하도록 초대했습니다.</p>
  <p style="margin:0 0 12px;font-size:13px;color:#444;line-height:1.7">아래 버튼을 눌러 비밀번호를 설정하면 「{{brand_name}}」 브랜드의 오리엔시트와 캠페인을 함께 보실 수 있습니다.</p>
  <div style="text-align:center;margin:8px 0 22px">
    <a href="{{link}}" style="display:inline-block;background:#E8344E;color:#fff;text-decoration:none;font-weight:700;font-size:14px;padding:13px 28px;border-radius:10px">초대 수락하고 비밀번호 설정하기</a>
  </div>
  <div style="background:#F7F4EE;border:1px solid #EAEAE4;border-radius:12px;padding:16px 18px;margin-bottom:20px;font-size:13px">
    <div style="color:#888;font-size:11px;letter-spacing:0.08em;margin-bottom:4px;text-transform:uppercase;font-weight:700">초대 링크 유효 시간</div>
    <div style="font-weight:700;color:#161618">이 링크는 보낸 때부터 24시간 동안 유효합니다.</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">기한이 지나면 링크가 열리지 않습니다. 그때는 {{inviter_name}} 님께 초대를 다시 보내 달라고 요청해 주십시오.</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">버튼이 눌리지 않으면 아래 주소를 복사해 브라우저에 붙여넣어 주십시오.</div>
    <div style="font-family:monospace;font-size:12px;color:#555;word-break:break-all;margin-top:4px">{{link}}</div>
  </div>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">이 메일은 「{{brand_name}}」 브랜드의 대표 담당자 {{inviter_name}} 님의 초대로 REVERB 운영팀이 보냈습니다.</p>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">무슨 메일인지 모르시겠다면 이 메일을 무시하셔도 됩니다. 링크를 누르지 않으면 아무 일도 일어나지 않습니다.</p>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">이 메일은 발신 전용입니다. 초대에 관한 문의는 {{inviter_name}} 님께 직접 연락해 주십시오.</p>
  <p style="margin-top:24px;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
</div>`,
  "brand-invite-existing": `<!--
  Mail: 브랜드 멤버 초대 ⓑ — 이미 브랜드 계정이 있는 사람 (로그인해서 수락)
  Trigger: 브랜드 대표가 멤버 관리에서 「초대」/「다시 보내기」를 누르면 Edge Function notify-brand-invite 가 발송
  To:      초대받은 사람 (brand_invites.email)
  Lang:    KO
  Placeholders: brand-invite-new 와 같다 ({{brand_name}} · {{inviter_name}} · {{link}})
  사양서 §16-3 1번·2번. 링크는 로그인 화면으로 이어지고, 로그인한 뒤 수락한다(비밀번호는 지금 것을 쓴다). 마이페이지 「받은 초대」에서도 수락·거절할 수 있다.
  🔴 문구 정본 = 피그마 「[1차] 06 멤버 관리」 bw01-97·97a·97b(초안, 2026-10-16 사용자 결정 「초안대로 맞춘다」). 제목은 서버 함수 index.ts 가 만든다 —
     「[REVERB JP] {{inviter_name}} 님이 「{{brand_name}}」 브랜드 페이지에 초대했습니다 — 로그인해 수락해 주십시오 (MM/DD HH:MM)」(갈래마다 다른 제목 + 보낸 시각 — 2026-10-20 사용자 결정. 피그마 제목 끝 「(초안)」은 시안 표시라 넣지 않음).
  텍스트 판(index.ts 안)이 같은 문구의 사본이다 — 이 파일을 고치면 그쪽도 함께.
-->
<!DOCTYPE html>
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#161618;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">「{{brand_name}}」 브랜드 페이지에 초대받았습니다</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">안녕하십니까</p>
  <p style="margin:0 0 12px;font-size:13px;color:#444;line-height:1.7">「{{brand_name}}」 브랜드의 대표 담당자 {{inviter_name}} 님이 REVERB 브랜드 페이지에 함께하도록 초대했습니다.</p>
  <p style="margin:0 0 12px;font-size:13px;color:#444;line-height:1.7">이미 REVERB 브랜드 페이지 계정이 있으십니다. 지금 쓰시는 계정으로 로그인해 초대를 수락하면 「{{brand_name}}」 브랜드가 연결됩니다.</p>
  <div style="text-align:center;margin:8px 0 22px">
    <a href="{{link}}" style="display:inline-block;background:#E8344E;color:#fff;text-decoration:none;font-weight:700;font-size:14px;padding:13px 28px;border-radius:10px">로그인하고 초대 확인하기</a>
  </div>
  <div style="background:#F7F4EE;border:1px solid #EAEAE4;border-radius:12px;padding:16px 18px;margin-bottom:20px;font-size:13px">
    <div style="color:#888;font-size:11px;letter-spacing:0.08em;margin-bottom:4px;text-transform:uppercase;font-weight:700">초대 링크 유효 시간</div>
    <div style="font-weight:700;color:#161618">이 링크는 보낸 때부터 24시간 동안 유효합니다.</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">로그인한 뒤 마이페이지 「받은 초대」에서도 수락하거나 거절할 수 있습니다.</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">비밀번호를 아직 정하지 않으셨다면, 먼저 받으신 비밀번호 설정 메일로 정한 뒤 수락해 주십시오.</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">버튼이 눌리지 않으면 아래 주소를 복사해 브라우저에 붙여넣어 주십시오.</div>
    <div style="font-family:monospace;font-size:12px;color:#555;word-break:break-all;margin-top:4px">{{link}}</div>
  </div>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">이 메일은 「{{brand_name}}」 브랜드의 대표 담당자 {{inviter_name}} 님의 초대로 REVERB 운영팀이 보냈습니다.</p>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">무슨 메일인지 모르시겠다면 이 메일을 무시하셔도 됩니다. 링크를 누르지 않으면 아무 일도 일어나지 않습니다.</p>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">이 메일은 발신 전용입니다. 초대에 관한 문의는 {{inviter_name}} 님께 직접 연락해 주십시오.</p>
  <p style="margin-top:24px;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
</div>`,
  "brand-invite-blocked": `<!--
  Mail: 브랜드 멤버 초대 ⓒ — 이 이메일로는 초대를 받을 수 없는 경우 (링크 없음)
  Trigger: 브랜드 대표가 멤버 관리에서 「초대」/「다시 보내기」를 누르면 Edge Function notify-brand-invite 가 발송
  To:      초대받은 사람 (brand_invites.email)
  Lang:    KO
  Placeholders:
    {{brand_name}} · {{inviter_name}}   (링크·유효 시간 칸 없음)
  🔴 어떤 종류의 계정(관리자·인플루언서)인지 적지 않는다 — 받는 사람과 대표 모두에게 계정 종류가 드러나지 않게.
  🔴 문구 정본 = 피그마 「[1차] 06 멤버 관리」 bw01-97·97a·97b(초안, 2026-10-16 사용자 결정 「초안대로 맞춘다」). 제목은 서버 함수 index.ts 가 만든다 —
     「[REVERB JP] 「{{brand_name}}」 브랜드 페이지 초대 — 이 이메일로는 계정을 만들 수 없습니다 (MM/DD HH:MM)」(갈래마다 다른 제목 + 보낸 시각 — 2026-10-20 사용자 결정. 피그마 제목 끝 「(초안)」은 시안 표시라 넣지 않음).
  텍스트 판(index.ts 안)이 같은 문구의 사본이다 — 이 파일을 고치면 그쪽도 함께.
-->
<!DOCTYPE html>
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#161618;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">「{{brand_name}}」 브랜드 페이지 초대를 받을 수 없는 이메일입니다</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">안녕하십니까</p>
  <p style="margin:0 0 12px;font-size:13px;color:#444;line-height:1.7">「{{brand_name}}」 브랜드의 대표 담당자 {{inviter_name}} 님이 이 이메일로 REVERB 브랜드 페이지에 초대했습니다.</p>
  <p style="margin:0 0 12px;font-size:13px;color:#444;line-height:1.7">하지만 이 이메일은 이미 REVERB의 다른 서비스에서 쓰고 있어 브랜드 계정을 만들 수 없습니다. 다른 이메일로 다시 초대해 달라고 {{inviter_name}} 님께 요청해 주십시오.</p>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">이 메일은 「{{brand_name}}」 브랜드의 대표 담당자 {{inviter_name}} 님의 초대로 REVERB 운영팀이 보냈습니다.</p>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">무슨 메일인지 모르시겠다면 이 메일을 무시하셔도 됩니다. 아무 일도 일어나지 않습니다.</p>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">이 메일은 발신 전용입니다. 초대에 관한 문의는 {{inviter_name}} 님께 직접 연락해 주십시오.</p>
  <p style="margin-top:24px;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
</div>`,
  "brand-link-request": `
<!--
  Mail: 브랜드 연결 요청 — 관리자가 이미 있는 브랜드 계정을 대표 담당자가 없는 브랜드의 대표로 이으려 할 때 (본인이 24시간 안에 수락)
  Trigger: 관리자 브랜드 상세 「브랜드 연결 추가」(a03-04) · 겹침 확인 창 「연결」(a03-01c)에서 admin_request_brand_owner_link 성공 뒤
           관리자 화면이 Edge Function notify-brand-invite 를 부른다(brand_invites.invite_kind='owner_link' 갈래)
  To:      연결 요청을 받은 브랜드 계정 (brand_invites.email)
  Lang:    KO
  Placeholders: {{brand_name}}  연결하려는 브랜드 이름
                {{link}}        \${PUBLIC_BRAND_URL}/brand/?link=<link_id>&kind=invite
  사양서 docs/specs/2026-10-21-brand-link-request.md 4-3 · 결정 L4(보낸 사람 「REVERB 운영팀」 — 관리자 실명을 넣지 않는다)·L6(24시간)·L8.
  🔴 받는 계정이 비밀번호를 정했든 안 정했든 **같은 메일·같은 링크**다 — 갈래는 링크를 연 뒤 화면이 가른다(메일이 계정 상태를 드러내지 않게).
     그래서 본문에 「로그인」·「비밀번호 설정」 어느 한쪽만 적지 않는다.
  🔴 문구 정본 = 피그마 bw01-98(초안). 제목은 서버 함수 index.ts 가 만든다 —
     「[REVERB JP] 「{{brand_name}}」 브랜드 대표 담당자 연결 요청 — 24시간 안에 수락해 주십시오 (MM/DD HH:MM)」(보낸 시각 — 2026-10-20 사용자 결정).
  텍스트 판(index.ts 안)이 같은 문구의 사본이다 — 이 파일을 고치면 그쪽도 함께.
-->
<!DOCTYPE html>
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#161618;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">「{{brand_name}}」 브랜드 연결 요청</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">안녕하십니까</p>
  <p style="margin:0 0 12px;font-size:13px;color:#444;line-height:1.7">REVERB 운영팀이 회원님의 브랜드 페이지 계정을 「{{brand_name}}」 브랜드의 대표 담당자로 연결하려 합니다.</p>
  <p style="margin:0 0 12px;font-size:13px;color:#444;line-height:1.7">아래 단추를 눌러 요청을 수락하면 「{{brand_name}}」 브랜드가 지금 쓰시는 계정에 연결됩니다. 수락하기 전에는 연결되지 않습니다.</p>
  <div style="text-align:center;margin:8px 0 22px">
    <a href="{{link}}" style="display:inline-block;background:#E8344E;color:#fff;text-decoration:none;font-weight:700;font-size:14px;padding:13px 28px;border-radius:10px">연결 요청 확인하기</a>
  </div>
  <div style="background:#F7F4EE;border:1px solid #EAEAE4;border-radius:12px;padding:16px 18px;margin-bottom:20px;font-size:13px">
    <div style="color:#888;font-size:11px;letter-spacing:0.08em;margin-bottom:4px;text-transform:uppercase;font-weight:700">연결 요청 링크 유효 시간</div>
    <div style="font-weight:700;color:#161618">이 링크는 보낸 때부터 24시간 동안 유효합니다.</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">기한이 지나면 링크가 열리지 않습니다. 그때는 REVERB 운영팀에 다시 보내 달라고 요청해 주십시오.</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">로그인한 뒤 마이페이지 「받은 초대」에서도 수락하거나 거절할 수 있습니다. 비밀번호를 아직 정하지 않으셨다면 링크를 연 화면에서 비밀번호를 정하며 바로 수락할 수 있습니다.</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">버튼이 눌리지 않으면 아래 주소를 복사해 브라우저에 붙여넣어 주십시오.</div>
    <div style="font-family:monospace;font-size:12px;color:#555;word-break:break-all;margin-top:4px">{{link}}</div>
  </div>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">이 메일은 REVERB 운영팀이 보냈습니다.</p>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">무슨 메일인지 모르시겠다면 이 메일을 무시하셔도 됩니다. 링크를 누르지 않으면 아무 일도 일어나지 않습니다.</p>
  <p style="margin:0 0 14px;font-size:12px;color:#888;line-height:1.7">이 메일은 발신 전용입니다. 연결 요청에 관한 문의는 REVERB 운영팀 담당자에게 연락해 주십시오.</p>
  <p style="margin-top:24px;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
</div>`,
};
