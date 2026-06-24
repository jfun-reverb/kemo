// 자동 생성 (sync-email-templates.sh) — 직접 수정 금지
// docs/email-templates/ 변경 후 sync 스크립트 실행 시 자동 갱신
//
// 백틱·${...} 패턴은 sed로 escape 처리. 새 템플릿 추가 시 패턴 점검 필요

export const TEMPLATES: Record<string, string> = {
  "orient-sheet-invite": `<!DOCTYPE html>
<!--
  Mail: 오리엔시트 작성 요청 — 브랜드에게 토큰 링크 전달 (orient sheet invite)
  Trigger: 관리자 발급(create_orient_sheet) 직후 admin-orient.js 가
           Edge Function notify-orient-sheet 를 invoke → 이 템플릿으로 발송
  To:      서베이 연결 건 = brand_applications.applicant_email(없으면 email)
           비-서베이 건  = brands 대표 담당자(contacts is_primary / primary_email)
  Lang:    KO (브랜드는 한국어로 작성 — 사양서 §1 "브랜드 한국어만")

  Placeholders:
    {{brand_name}}   브랜드명
    {{link}}         작성 링크 (sales 도메인 + /orient?token=…)
    {{deadline}}     작성 기한(YYYY. M. D. 한국어 표기, 발급+30일)

  Note:
    문의처(카톡/TEL)는 하드코딩. 브랜드 발송 메일은 LINE 제외(2026-06-24 사용자 요청).
    브랜드 대상 메일이라 인플루언서 4줄 푸터 의무 없음.
-->
<div style="font-family:'Manrope','Pretendard Variable','Noto Sans KR',Arial,sans-serif;color:#222;max-width:560px">
  <h2 style="color:#E8344E;margin:0 0 8px;font-size:20px;font-weight:800;letter-spacing:-0.02em">캠페인 오리엔시트 작성을 요청드립니다</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">{{brand_name}} 담당자님</p>
  <p style="margin:0 0 20px;font-size:13px;color:#444;line-height:1.7">
    캠페인 진행에 필요한 제품·콘텐츠 정보를 아래 링크에서 작성해 주세요.
    별도 로그인 없이 바로 작성하실 수 있으며, 작성 중 자동 저장됩니다.
  </p>
  <div style="text-align:center;margin:0 0 22px">
    <a href="{{link}}" style="display:inline-block;background:#E8344E;color:#fff;text-decoration:none;font-weight:700;font-size:14px;padding:13px 28px;border-radius:10px">오리엔시트 작성하기</a>
  </div>
  <div style="background:#F7F4EE;border:1px solid #EAEAE4;border-radius:12px;padding:16px 18px;margin-bottom:20px;font-size:13px">
    <div style="color:#888;font-size:11px;letter-spacing:0.08em;margin-bottom:4px;text-transform:uppercase;font-weight:700">작성 기한</div>
    <div style="font-weight:700;color:#E8344E">{{deadline}}</div>
    <div style="color:#888;font-size:12px;margin-top:10px;line-height:1.6">버튼이 눌리지 않으면 아래 주소를 복사해 브라우저에 붙여넣어 주세요.</div>
    <div style="font-family:monospace;font-size:12px;color:#555;word-break:break-all;margin-top:4px">{{link}}</div>
  </div>
  <div style="border-top:1px solid #EAEAE4;margin-top:26px;padding-top:18px">
    <h3 style="font-size:11px;color:#161618;letter-spacing:0.15em;margin-bottom:12px;text-transform:uppercase;font-weight:700">문의</h3>
    <table style="border-collapse:collapse;width:100%;font-size:13px">
      <tr><td style="padding:6px 0;color:#888;font-size:10px;letter-spacing:0.12em;text-transform:uppercase;font-weight:700;width:100px">KakaoTalk</td><td style="padding:6px 0;font-weight:600">byhyunho7</td></tr>
      <tr><td style="padding:6px 0;color:#888;font-size:10px;letter-spacing:0.12em;text-transform:uppercase;font-weight:700">TEL</td><td style="padding:6px 0;font-family:monospace;font-weight:600">010-2550-1511</td></tr>
    </table>
  </div>
  <p style="margin-top:24px;font-size:11px;color:#999;letter-spacing:0.02em">© JFUN Corp. · 株式会社ジェイファン</p>
</div>`,
};
