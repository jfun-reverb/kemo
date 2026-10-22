// 자동 생성 (sync-email-templates.sh) — 직접 수정 금지
// docs/email-templates/ 변경 후 sync 스크립트 실행 시 자동 갱신
//
// 백틱·${...} 패턴은 sed로 escape 처리. 새 템플릿 추가 시 패턴 점검 필요

export const TEMPLATES: Record<string, string> = {
  "brand-account-restricted": `<!DOCTYPE html>
<!--
  Mail: 브랜드 페이지 이용 제한 알림 — 제한한 그 계정에게 (brand account restricted)
  Figma: Admin [1차] a03-4 이용 제한 · 결과물 열람 정지 (a03-11 이용 제한 모달 — 「이용 제한」을 누르면 메일로 알린다)
  Trigger: 관리자 브랜드 상세 계정 줄 「…」 → 「이용 제한」 성공 → Edge Function notify-brand-restriction (kind:'account_restrict')
           걸 때는 항상 보낸다(체크 없음 — 사양서 F6). 두 겹 잠금은 그 함수 머리말
  To:      제한한 계정 한 사람(사양서 A8 — 같은 브랜드의 다른 사람에게 사유가 알려지지 않게)
           받는 사람은 서버(service_claim_brand_sanction_mail)가 정한다
  Lang:    KO

  Placeholders:
    {{recipient_name}}  호칭 — 「{계정 이름} 님」, 이름이 비면 「브랜드 페이지 담당자님」(함수가 만든다)
    {{reason_label}}    사유 이름 — 이용약관 제8조 위반(인플루언서 정보) / 계정 공유 / 기타
                        🔴 이름표 사본 두 벌: notify-brand-restriction REASON_LABELS ↔ 관리자 모달(admin-brand-sanction.js)
    {{reason_note}}     관리자가 쓴 사유 설명(이스케이프 + 줄바꿈 <br>)
    {{until_text}}      「YYYY/MM/DD까지」 또는 「해제할 때까지」
    {{until_note}}      기간 안내 한 줄(날짜까지 = 그날이 지나면 저절로 풀림 / 해제할 때까지 = 운영팀이 풀 때까지)
    {{brand_names}}     그 계정이 연결된 브랜드 이름들(「, 」로 이음 — 없으면 「없음」)

  Note:
    🔴 링크(로그인 단추)를 넣지 않는다(사양서 A9 — 제한 계정은 들어와도 안내 화면만 본다).
    🔴 텍스트 판은 notify-brand-restriction/index.ts 안의 사본 — 이 양식을 고치면 함께 고친다.
    문의처는 「REVERB 운영팀 담당자에게 직접」(사양서 R6 — 다른 브랜드 메일과 같은 문장).
    브랜드 대상 메일이라 인플루언서 4줄 푸터 의무 없음.
-->
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#161618;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">브랜드 페이지 이용이 제한되었습니다</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">{{recipient_name}}</p>
  <p style="margin:0 0 20px;font-size:13px;color:#444;line-height:1.7">
    이용약관에 따라 이 계정의 REVERB 브랜드 페이지 이용을 제한했습니다. 제한 중에는 로그인해도 브랜드 페이지의 정보를 볼 수 없습니다.
  </p>
  <div style="background:#F7F4EE;border:1px solid #EAEAE4;border-radius:12px;padding:16px 18px;margin-bottom:20px;font-size:13px">
    <div style="color:#888;font-size:11px;margin-bottom:4px;font-weight:700">제한 사유</div>
    <div style="font-weight:700;color:#161618;margin-bottom:4px">{{reason_label}}</div>
    <div style="color:#444;line-height:1.7;margin-bottom:14px">{{reason_note}}</div>
    <div style="color:#888;font-size:11px;margin-bottom:4px;font-weight:700">제한 기간</div>
    <div style="font-weight:700;color:#161618;margin-bottom:4px">{{until_text}}</div>
    <div style="color:#444;line-height:1.7;margin-bottom:14px">{{until_note}}</div>
    <div style="color:#888;font-size:11px;margin-bottom:4px;font-weight:700">제한되는 브랜드</div>
    <div style="color:#161618">{{brand_names}}</div>
  </div>
  <p style="margin:0 0 22px;font-size:13px;color:#444;line-height:1.7">
    같은 브랜드의 다른 담당자 계정은 이 제한과 상관없이 쓸 수 있습니다.
  </p>
  <div style="border-top:1px solid #EAEAE4;padding-top:16px">
    <p style="margin:0 0 4px;color:#888;font-size:12px;line-height:1.6">제한에 이의가 있으면 REVERB 운영팀 담당자에게 직접 문의해 주십시오.</p>
    <p style="margin:0 0 4px;color:#888;font-size:12px;line-height:1.6">이 메일은 발신 전용입니다.</p>
    <p style="margin:12px 0 0;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
  </div>
</div>`,
  "brand-account-restriction-changed": `<!DOCTYPE html>
<!--
  Mail: 브랜드 페이지 이용 제한 기간 바뀜 알림 — 그 계정에게 (brand account restriction period changed)
  Figma: Admin [1차] a03-4 (a03-94 ① 「기간 바꾸기」 — 사양서 A1)
  Trigger: 관리자 계정 줄 「기간 바꾸기」 성공 + 「바뀐 기간을 이메일로 알립니다」 체크(기본 켬)
           → Edge Function notify-brand-restriction (kind:'account_period', ref_id = 기간을 바꿔 새로 연 제한 줄)
  To:      그 계정 한 사람(사양서 A8) — 받는 사람은 서버(service_claim_brand_sanction_mail)가 정한다
  Lang:    KO

  Placeholders:
    {{recipient_name}}  호칭 — 「{계정 이름} 님」, 이름이 비면 「브랜드 페이지 담당자님」
    {{reason_label}}    사유 이름(🔴 이름표 사본 두 벌 — brand-account-restricted.html 머리말)
    {{reason_note}}     사유 설명(기간을 바꿔도 사유·설명은 그대로 — A1)
    {{until_text}}      바뀐 기간 「YYYY/MM/DD까지」 또는 「해제할 때까지」
    {{until_note}}      기간 안내 한 줄
    {{brand_names}}     연결된 브랜드 이름들

  Note:
    🔴 링크 없음(A9). 🔴 텍스트 판은 notify-brand-restriction/index.ts 안의 사본 — 함께 고친다.
    브랜드 대상 메일이라 인플루언서 4줄 푸터 의무 없음.
-->
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#161618;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">이용 제한 기간이 바뀌었습니다</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">{{recipient_name}}</p>
  <p style="margin:0 0 20px;font-size:13px;color:#444;line-height:1.7">
    이 계정의 REVERB 브랜드 페이지 이용 제한 기간을 바꿨습니다. 제한 사유는 그대로입니다.
  </p>
  <div style="background:#F7F4EE;border:1px solid #EAEAE4;border-radius:12px;padding:16px 18px;margin-bottom:20px;font-size:13px">
    <div style="color:#888;font-size:11px;margin-bottom:4px;font-weight:700">바뀐 제한 기간</div>
    <div style="font-weight:700;color:#161618;margin-bottom:4px">{{until_text}}</div>
    <div style="color:#444;line-height:1.7;margin-bottom:14px">{{until_note}}</div>
    <div style="color:#888;font-size:11px;margin-bottom:4px;font-weight:700">제한 사유</div>
    <div style="font-weight:700;color:#161618;margin-bottom:4px">{{reason_label}}</div>
    <div style="color:#444;line-height:1.7;margin-bottom:14px">{{reason_note}}</div>
    <div style="color:#888;font-size:11px;margin-bottom:4px;font-weight:700">제한되는 브랜드</div>
    <div style="color:#161618">{{brand_names}}</div>
  </div>
  <div style="border-top:1px solid #EAEAE4;padding-top:16px">
    <p style="margin:0 0 4px;color:#888;font-size:12px;line-height:1.6">제한에 이의가 있으면 REVERB 운영팀 담당자에게 직접 문의해 주십시오.</p>
    <p style="margin:0 0 4px;color:#888;font-size:12px;line-height:1.6">이 메일은 발신 전용입니다.</p>
    <p style="margin:12px 0 0;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
  </div>
</div>`,
  "brand-account-unrestricted": `<!DOCTYPE html>
<!--
  Mail: 브랜드 페이지 이용 제한 해제 알림 — 그 계정에게 (brand account restriction lifted)
  Figma: Admin [1차] a03-4 (a03-94 ③ 「제한 해제」 확인 — 「해제를 이메일로 알립니다」)
  Trigger: 관리자 「제한 해제」 성공 + 「해제를 이메일로 알립니다」 체크(기본 켬)
           → Edge Function notify-brand-restriction (kind:'account_lift', ref_id = 해제한 제한 줄)
           ⚠️ 「날짜까지」 제한이 그날이 지나 저절로 풀릴 때는 보내지 않는다(사양서 F5) — 손으로 해제한 줄만
  To:      그 계정 한 사람(사양서 A8) — 받는 사람은 서버(service_claim_brand_sanction_mail)가 정한다
  Lang:    KO

  Placeholders:
    {{recipient_name}}  호칭 — 「{계정 이름} 님」, 이름이 비면 「브랜드 페이지 담당자님」
    {{reason_label}}    해제한 제한의 사유 이름(🔴 이름표 사본 두 벌 — brand-account-restricted.html 머리말)
    {{reason_note}}     해제한 제한의 사유 설명
    {{brand_names}}     다시 쓸 수 있는 브랜드 이름들(지금 연결된 것 — 없으면 「없음」)

  Note:
    🔴 링크 없음(A9 — 링크는 결과물 열람 정지 메일 둘만). 🔴 텍스트 판은 notify-brand-restriction/index.ts 안의 사본 — 함께 고친다.
    브랜드 대상 메일이라 인플루언서 4줄 푸터 의무 없음.
-->
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#161618;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">이용 제한이 해제되었습니다</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">{{recipient_name}}</p>
  <p style="margin:0 0 20px;font-size:13px;color:#444;line-height:1.7">
    이 계정의 REVERB 브랜드 페이지 이용 제한을 해제했습니다. 지금부터 다시 로그인해 브랜드 페이지를 쓸 수 있습니다.
  </p>
  <div style="background:#F7F4EE;border:1px solid #EAEAE4;border-radius:12px;padding:16px 18px;margin-bottom:20px;font-size:13px">
    <div style="color:#888;font-size:11px;margin-bottom:4px;font-weight:700">다시 쓸 수 있는 브랜드</div>
    <div style="color:#161618;margin-bottom:14px">{{brand_names}}</div>
    <div style="color:#888;font-size:11px;margin-bottom:4px;font-weight:700">해제된 제한의 사유</div>
    <div style="font-weight:700;color:#161618;margin-bottom:4px">{{reason_label}}</div>
    <div style="color:#444;line-height:1.7">{{reason_note}}</div>
  </div>
  <div style="border-top:1px solid #EAEAE4;padding-top:16px">
    <p style="margin:0 0 4px;color:#888;font-size:12px;line-height:1.6">궁금한 점은 REVERB 운영팀 담당자에게 직접 문의해 주십시오.</p>
    <p style="margin:0 0 4px;color:#888;font-size:12px;line-height:1.6">이 메일은 발신 전용입니다.</p>
    <p style="margin:12px 0 0;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
  </div>
</div>`,
  "brand-results-suspended": `<!DOCTYPE html>
<!--
  Mail: 결과물 열람 정지 알림 — 그 브랜드의 대표·멤버에게 (brand results view suspended)
  Figma: Admin [1차] a03-4 (a03-12 결과물 열람 정지 모달 — 안내 「대표 담당자·멤버에게 이메일로 알립니다」, 사양서 R5)
  Trigger: 관리자 브랜드 상세 머리 「…」 → 「결과물 열람 정지」 성공 → Edge Function notify-brand-restriction (kind:'results_suspend')
           걸 때는 항상 보낸다(체크 없음 — 사양서 F6)
  To:      그 브랜드(활성)에 활성 연결된 계정 중 비밀번호를 정한 계정 전원(대표 먼저) — 이용 제한 중인 계정은 뺀다(R4·R5). 1명당 1통
           받는 사람은 서버(service_claim_brand_sanction_mail → _brand_mailable_accounts)가 정한다
  Lang:    KO

  Placeholders:
    {{recipient_name}}  호칭 — 「{계정 이름} 님」, 이름이 비면 「{브랜드명} 담당자님」
    {{brand_name}}      브랜드명
    {{blocked_items}}   막는 것 — 「캠페인 결과물 표 · 결과물 엑셀 · 영수증 사진」(+ 배송 포함이면 「 · 시딩형 배송 리스트」)
    {{reason_label}}    사유 이름 — 이용약관 제8조 위반(인플루언서 정보) / 기타(🔴 이름표 사본 두 벌 — brand-account-restricted.html 머리말)
    {{reason_note}}     관리자가 쓴 사유 설명(이스케이프 + 줄바꿈 <br>)
    {{brand_url}}       브랜드 페이지 주소(PUBLIC_BRAND_URL + /brand/ — 사양서 A9, 이 메일과 정지 해제 메일만)

  Note:
    정지 중에도 모집 현황·일정은 보인다(사양서 F7). 정지는 기간이 없다(운영팀이 풀 때까지 — F5).
    🔴 텍스트 판은 notify-brand-restriction/index.ts 안의 사본 — 함께 고친다.
    브랜드 대상 메일이라 인플루언서 4줄 푸터 의무 없음.
-->
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#161618;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">결과물 열람이 정지되었습니다</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">{{recipient_name}}</p>
  <p style="margin:0 0 20px;font-size:13px;color:#444;line-height:1.7">
    이용약관에 따라 「{{brand_name}}」 브랜드의 캠페인 결과물 열람을 정지했습니다. 정지 중에도 캠페인 모집 현황과 일정은 브랜드 페이지에서 볼 수 있습니다.
  </p>
  <div style="background:#F7F4EE;border:1px solid #EAEAE4;border-radius:12px;padding:16px 18px;margin-bottom:20px;font-size:13px">
    <div style="color:#888;font-size:11px;margin-bottom:4px;font-weight:700">볼 수 없게 된 것</div>
    <div style="font-weight:700;color:#161618;margin-bottom:14px">{{blocked_items}}</div>
    <div style="color:#888;font-size:11px;margin-bottom:4px;font-weight:700">정지 사유</div>
    <div style="font-weight:700;color:#161618;margin-bottom:4px">{{reason_label}}</div>
    <div style="color:#444;line-height:1.7">{{reason_note}}</div>
  </div>
  <p style="margin:0 0 4px;font-size:13px;color:#444;line-height:1.7">정지는 운영팀이 해제할 때까지 이어집니다.</p>
  <p style="margin:0 0 22px;font-size:13px;color:#444;line-height:1.7">브랜드 페이지: <span style="font-family:monospace;font-size:12px;color:#555;word-break:break-all">{{brand_url}}</span></p>
  <div style="border-top:1px solid #EAEAE4;padding-top:16px">
    <p style="margin:0 0 4px;color:#888;font-size:12px;line-height:1.6">이 메일은 「{{brand_name}}」 브랜드에 연결된 계정 모두에게 보냈습니다.</p>
    <p style="margin:0 0 4px;color:#888;font-size:12px;line-height:1.6">정지에 이의가 있으면 REVERB 운영팀 담당자에게 직접 문의해 주십시오. 이 메일은 발신 전용입니다.</p>
    <p style="margin:12px 0 0;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
  </div>
</div>`,
  "brand-results-unsuspended": `<!DOCTYPE html>
<!--
  Mail: 결과물 열람 정지 해제 알림 — 그 브랜드의 대표·멤버에게 (brand results view suspension lifted)
  Figma: Admin [1차] a03-4 (a03-94 ④ 「정지 해제」 확인 — 「해제를 이메일로 알립니다」)
  Trigger: 관리자 브랜드 상세 머리 「정지 해제」 성공 + 「해제를 이메일로 알립니다」 체크(기본 켬)
           → Edge Function notify-brand-restriction (kind:'results_lift', ref_id = 해제한 정지 줄)
  To:      그 브랜드의 대표·멤버 전원 중 이용 제한 중이 아닌 계정(R4·R5) — 1명당 1통. 받는 사람은 서버가 정한다
  Lang:    KO

  Placeholders:
    {{recipient_name}}  호칭 — 「{계정 이름} 님」, 이름이 비면 「{브랜드명} 담당자님」
    {{brand_name}}      브랜드명
    {{blocked_items}}   다시 볼 수 있게 된 것(정지 때 막았던 것 — brand-results-suspended.html 과 같은 문구)
    {{reason_label}}    해제한 정지의 사유 이름(🔴 이름표 사본 두 벌 — brand-account-restricted.html 머리말)
    {{reason_note}}     해제한 정지의 사유 설명
    {{brand_url}}       브랜드 페이지 주소(PUBLIC_BRAND_URL + /brand/ — 사양서 A9)

  Note:
    🔴 텍스트 판은 notify-brand-restriction/index.ts 안의 사본 — 함께 고친다.
    브랜드 대상 메일이라 인플루언서 4줄 푸터 의무 없음.
-->
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#161618;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">결과물 열람 정지가 해제되었습니다</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">{{recipient_name}}</p>
  <p style="margin:0 0 20px;font-size:13px;color:#444;line-height:1.7">
    「{{brand_name}}」 브랜드의 캠페인 결과물 열람 정지를 해제했습니다. 지금부터 브랜드 페이지에서 결과물을 다시 볼 수 있습니다.
  </p>
  <div style="background:#F7F4EE;border:1px solid #EAEAE4;border-radius:12px;padding:16px 18px;margin-bottom:20px;font-size:13px">
    <div style="color:#888;font-size:11px;margin-bottom:4px;font-weight:700">다시 볼 수 있게 된 것</div>
    <div style="font-weight:700;color:#161618;margin-bottom:14px">{{blocked_items}}</div>
    <div style="color:#888;font-size:11px;margin-bottom:4px;font-weight:700">해제된 정지의 사유</div>
    <div style="font-weight:700;color:#161618;margin-bottom:4px">{{reason_label}}</div>
    <div style="color:#444;line-height:1.7">{{reason_note}}</div>
  </div>
  <p style="margin:0 0 22px;font-size:13px;color:#444;line-height:1.7">브랜드 페이지: <span style="font-family:monospace;font-size:12px;color:#555;word-break:break-all">{{brand_url}}</span></p>
  <div style="border-top:1px solid #EAEAE4;padding-top:16px">
    <p style="margin:0 0 4px;color:#888;font-size:12px;line-height:1.6">이 메일은 「{{brand_name}}」 브랜드에 연결된 계정 모두에게 보냈습니다.</p>
    <p style="margin:0 0 4px;color:#888;font-size:12px;line-height:1.6">궁금한 점은 REVERB 운영팀 담당자에게 직접 문의해 주십시오. 이 메일은 발신 전용입니다.</p>
    <p style="margin:12px 0 0;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
  </div>
</div>`,
};
