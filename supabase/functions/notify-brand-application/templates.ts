// 자동 생성 (sync-email-templates.sh) — 직접 수정 금지
// docs/email-templates/ 변경 후 sync 스크립트 실행 시 자동 갱신
//
// 백틱·${...} 패턴은 sed로 escape 처리. 새 템플릿 추가 시 패턴 점검 필요

export const TEMPLATES: Record<string, string> = {
  "brand-admin-notify": `<!DOCTYPE html>
<!--
  Mail: 광고주 신청 — 관리자 알림 (admin notify)
  Trigger: brand_applications INSERT → Edge Function notify-brand-application
  To:      get_subscribed_admin_emails('brand_notify') ∪ env.NOTIFY_ADMIN_EMAILS
  Lang:    KO

  Placeholders:
    {{application_no}}      신청번호 (예: B0001-A001 — 088~090 마이그레이션 후. 그 이전: JFUN-R-260504-001)
    {{form_label}}          폼 종류 라벨 (Qoo10 리뷰어 모집 | 나노 인플루언서 시딩)
    {{brand_name}}          브랜드명
    {{contact_name}}        담당자 이름
    {{phone}}               연락처
    {{email}}               담당자 이메일
    {{billing_email_row}}   계산서 행 HTML (없으면 빈 문자열)
    {{estimated_krw}}       예상 견적 (₩ 포맷)
    {{products_html}}       제품 테이블 HTML (없으면 빈 문자열)
    {{request_note_html}}   기타·요청사항 박스 HTML (없으면 빈 문자열)
    {{deep_link}}           관리자 페이지 딥링크
-->
<div style="font-family:'Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#E8344E;margin:0 0 8px">신규 광고주 신청</h2>
  <p style="margin:0 0 16px;color:#666;font-size:13px">REVERB JP 관리자 알림</p>
  <table style="border-collapse:collapse;width:100%;font-size:13px;margin-bottom:16px">
    <tr><td style="padding:6px 0;color:#888;width:100px">신청번호</td><td style="padding:6px 0;font-family:monospace">{{application_no}}</td></tr>
    <tr><td style="padding:6px 0;color:#888">폼 종류</td><td style="padding:6px 0">{{form_label}}</td></tr>
    <tr><td style="padding:6px 0;color:#888">브랜드</td><td style="padding:6px 0;font-weight:700">{{brand_name}}</td></tr>
    <tr><td style="padding:6px 0;color:#888">담당자</td><td style="padding:6px 0">{{contact_name}} · {{phone}} · {{email}}</td></tr>
    {{billing_email_row}}
    <tr><td style="padding:6px 0;color:#888">예상 견적</td><td style="padding:6px 0;font-weight:700">{{estimated_krw}}</td></tr>
  </table>
  {{products_html}}
  {{request_note_html}}
  <a href="{{deep_link}}" style="display:inline-block;background:#E8344E;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none;font-weight:700;font-size:13px">관리자 페이지에서 확인</a>
</div>`,
  "brand-ack-reviewer": `<!DOCTYPE html>
<!--
  Mail: 광고주 신청 접수 확인 — Qoo10 리뷰어 모집 (brand acknowledgement, reviewer)
  Trigger: brand_applications INSERT (form_type='reviewer') → Edge Function notify-brand-application
  To:      신청 폼에 입력된 브랜드 담당자 이메일
  Lang:    KO

  Placeholders:
    {{application_no}}   신청번호 (예: B0001-A001 — 088~090 마이그레이션 후. 그 이전: JFUN-R-260504-001)
    {{brand_name}}       브랜드명

  Note:
    "다음 단계" 5개와 문의처(LINE/카톡/TEL)는 하드코딩 — reviewer 전용 시퀀스.
    내용 변경 시 sales/reviewer.html 완료 페이지의 "다음 단계"와 같이 갱신할 것.
-->
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#E8344E;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">신청이 접수되었습니다</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">{{brand_name}} 담당자님</p>
  <div style="background:#F7F4EE;border:1px solid #EAEAE4;border-radius:12px;padding:16px 18px;margin-bottom:20px;font-size:13px">
    <div style="color:#888;font-size:11px;letter-spacing:0.08em;margin-bottom:4px;text-transform:uppercase;font-weight:700">신청번호</div>
    <div style="font-family:monospace;font-size:16px;font-weight:700;color:#E8344E">{{application_no}}</div>
    <div style="color:#888;font-size:11px;letter-spacing:0.08em;margin:12px 0 4px;text-transform:uppercase;font-weight:700">플랜</div>
    <div style="font-weight:600">Qoo10 리뷰어 모집</div>
  </div>
  <h3 style="font-size:11px;color:#161618;letter-spacing:0.15em;margin:22px 0 12px;text-transform:uppercase;font-weight:700">다음 단계</h3>
  <ol style="padding:0;margin:0;font-size:13px;list-style:none">
    <li style="margin:8px 0;color:#444;padding-left:4px"><span style="color:#E8344E;font-weight:700;font-family:monospace;margin-right:6px">01</span>담당자가 신청 내역을 검토합니다 (영업일 1일 이내)</li>
    <li style="margin:8px 0;color:#444;padding-left:4px"><span style="color:#E8344E;font-weight:700;font-family:monospace;margin-right:6px">02</span>최종 견적서를 이메일로 발송합니다</li>
    <li style="margin:8px 0;color:#444;padding-left:4px"><span style="color:#E8344E;font-weight:700;font-family:monospace;margin-right:6px">03</span>입금 확인 후 메일 및 카톡으로 안내</li>
    <li style="margin:8px 0;color:#444;padding-left:4px"><span style="color:#E8344E;font-weight:700;font-family:monospace;margin-right:6px">04</span>전체 타임라인 공유</li>
    <li style="margin:8px 0;color:#444;padding-left:4px"><span style="color:#E8344E;font-weight:700;font-family:monospace;margin-right:6px">05</span>Qoo10 리뷰어 모집 시작</li>
  </ol>
  <div style="border-top:1px solid #EAEAE4;margin-top:26px;padding-top:18px">
    <h3 style="font-size:11px;color:#161618;letter-spacing:0.15em;margin-bottom:12px;text-transform:uppercase;font-weight:700">문의</h3>
    <table style="border-collapse:collapse;width:100%;font-size:13px">
      <tr><td style="padding:6px 0;color:#888;font-size:10px;letter-spacing:0.12em;text-transform:uppercase;font-weight:700;width:100px">LINE</td><td style="padding:6px 0"><a href="https://line.me/R/ti/p/@reverb.jp" style="color:#E8344E;text-decoration:none;font-weight:600">@reverb.jp</a></td></tr>
      <tr><td style="padding:6px 0;color:#888;font-size:10px;letter-spacing:0.12em;text-transform:uppercase;font-weight:700">KakaoTalk</td><td style="padding:6px 0;font-weight:600">byhyunho7</td></tr>
      <tr><td style="padding:6px 0;color:#888;font-size:10px;letter-spacing:0.12em;text-transform:uppercase;font-weight:700">TEL</td><td style="padding:6px 0;font-family:monospace;font-weight:600">010-2550-1511</td></tr>
    </table>
  </div>
  <p style="margin-top:24px;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
</div>`,
  "brand-ack-seeding": `<!DOCTYPE html>
<!--
  Mail: 광고주 신청 접수 확인 — 나노 인플루언서 시딩 (brand acknowledgement, seeding)
  Trigger: brand_applications INSERT (form_type='seeding') → Edge Function notify-brand-application
  To:      신청 폼에 입력된 브랜드 담당자 이메일
  Lang:    KO

  Placeholders:
    {{application_no}}   신청번호 (예: B0001-A001 — 088~090 마이그레이션 후. 그 이전: JFUN-S-260504-001)
    {{brand_name}}       브랜드명

  Note:
    "다음 단계" 6개와 문의처(LINE/카톡/TEL)는 하드코딩 — seeding 전용 시퀀스.
    내용 변경 시 sales/seeding.html 완료 페이지의 "다음 단계"와 같이 갱신할 것.
-->
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#E8344E;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">신청이 접수되었습니다</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">{{brand_name}} 담당자님</p>
  <div style="background:#F7F4EE;border:1px solid #EAEAE4;border-radius:12px;padding:16px 18px;margin-bottom:20px;font-size:13px">
    <div style="color:#888;font-size:11px;letter-spacing:0.08em;margin-bottom:4px;text-transform:uppercase;font-weight:700">신청번호</div>
    <div style="font-family:monospace;font-size:16px;font-weight:700;color:#E8344E">{{application_no}}</div>
    <div style="color:#888;font-size:11px;letter-spacing:0.08em;margin:12px 0 4px;text-transform:uppercase;font-weight:700">플랜</div>
    <div style="font-weight:600">나노 인플루언서 시딩</div>
  </div>
  <h3 style="font-size:11px;color:#161618;letter-spacing:0.15em;margin:22px 0 12px;text-transform:uppercase;font-weight:700">다음 단계</h3>
  <ol style="padding:0;margin:0;font-size:13px;list-style:none">
    <li style="margin:8px 0;color:#444;padding-left:4px"><span style="color:#E8344E;font-weight:700;font-family:monospace;margin-right:6px">01</span>담당자가 신청 내역을 검토합니다 (영업일 1~2일)</li>
    <li style="margin:8px 0;color:#444;padding-left:4px"><span style="color:#E8344E;font-weight:700;font-family:monospace;margin-right:6px">02</span>전체 타임라인 공유</li>
    <li style="margin:8px 0;color:#444;padding-left:4px"><span style="color:#E8344E;font-weight:700;font-family:monospace;margin-right:6px">03</span>모집 시작</li>
    <li style="margin:8px 0;color:#444;padding-left:4px"><span style="color:#E8344E;font-weight:700;font-family:monospace;margin-right:6px">04</span>매칭 가능한 인플루언서 리스트 전달</li>
    <li style="margin:8px 0;color:#444;padding-left:4px"><span style="color:#E8344E;font-weight:700;font-family:monospace;margin-right:6px">05</span>브랜드사에서 제품 발송 (일본 현지 주소)</li>
    <li style="margin:8px 0;color:#444;padding-left:4px"><span style="color:#E8344E;font-weight:700;font-family:monospace;margin-right:6px">06</span>인플루언서 SNS 포스팅 진행</li>
  </ol>
  <div style="border-top:1px solid #EAEAE4;margin-top:26px;padding-top:18px">
    <h3 style="font-size:11px;color:#161618;letter-spacing:0.15em;margin-bottom:12px;text-transform:uppercase;font-weight:700">문의</h3>
    <table style="border-collapse:collapse;width:100%;font-size:13px">
      <tr><td style="padding:6px 0;color:#888;font-size:10px;letter-spacing:0.12em;text-transform:uppercase;font-weight:700;width:100px">LINE</td><td style="padding:6px 0"><a href="https://line.me/R/ti/p/@reverb.jp" style="color:#E8344E;text-decoration:none;font-weight:600">@reverb.jp</a></td></tr>
      <tr><td style="padding:6px 0;color:#888;font-size:10px;letter-spacing:0.12em;text-transform:uppercase;font-weight:700">KakaoTalk</td><td style="padding:6px 0;font-weight:600">byhyunho7</td></tr>
      <tr><td style="padding:6px 0;color:#888;font-size:10px;letter-spacing:0.12em;text-transform:uppercase;font-weight:700">TEL</td><td style="padding:6px 0;font-family:monospace;font-weight:600">010-2550-1511</td></tr>
    </table>
  </div>
  <p style="margin-top:24px;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
</div>`,
};
