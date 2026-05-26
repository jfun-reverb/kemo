// 자동 생성 (sync-email-templates.sh) — 직접 수정 금지
// docs/email-templates/ 변경 후 sync 스크립트 실행 시 자동 갱신
//
// 백틱·${...} 패턴은 sed로 escape 처리. 새 템플릿 추가 시 패턴 점검 필요

export const TEMPLATES: Record<string, string> = {
  "influencer-daily-digest": `<!DOCTYPE html>
<!--
  Mail: 인플루언서 일일 다이제스트 (influencer daily digest)
  Trigger: pg_cron 매일 UTC 00:00 (= 한국시간 오전 9시) → Edge Function notify-influencer-daily-digest
  Window:
    - 어제 KST 0시~24시 동안의 applications.created_at / reviewed_at
    - 오늘 KST 기준 D-5/D-1 영수증·결과물 마감
  To:     각 인플루언서 1명 (이메일은 auth.users 에서 조회) — marketing_opt_in 무시
  Lang:   JA (인플루언서 UI 언어)
  Skip:   4섹션 모두 0건인 인플루언서는 발송 스킵

  Subject (Edge Function이 동적 생성):
    【REVERB】本日の応募状況のお知らせ ({{today_jp}})
    예시: 【REVERB】本日の応募状況のお知らせ (2026年5月19日)

  Top-level Placeholders:
    {{today_jp}}            오늘 일본어 날짜 (예: 2026年5月19日)
    {{total_count}}         4섹션 총 항목 수
    {{section_received_html}}   섹션 1 — 어제 신청 (0건이면 빈 문자열)
    {{section_approved_html}}   섹션 2 — 어제 승인
    {{section_rejected_html}}   섹션 3 — 어제 반려
    {{section_deadline_html}}   섹션 4 — 마감 임박
    {{public_app_url}}      인플루언서 사이트 절대 URL (https://globalreverb.com)

  각 섹션은 Edge Function 가 인플루언서별로 미리 렌더링 (헤더 + row 누적)
  하거나 빈 문자열로 치환. 헤더 + row 형식은 row 파일 4종 참조:
    influencer-daily-digest.row-received.html
    influencer-daily-digest.row-approved.html
    influencer-daily-digest.row-rejected.html
    influencer-daily-digest.row-deadline.html

  관련 사양: docs/specs/2026-05-18-application-email-pipeline.md §8-1
-->
<div style="font-family:'Hiragino Sans','Yu Gothic',Arial,sans-serif;color:#222;max-width:640px">
  <h2 style="color:#C8789C;margin:0 0 6px">本日の応募状況のお知らせ</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">{{today_jp}} · {{total_count}}件のお知らせ</p>

  {{section_received_html}}
  {{section_approved_html}}
  {{section_rejected_html}}
  {{section_deadline_html}}

  <div style="margin-top:28px;padding-top:18px;border-top:1px solid #F0E1E4">
    <a href="{{public_app_url}}/#mypage-applications" style="display:inline-block;background:#C8789C;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none;font-weight:700;font-size:13px;margin-right:8px">応募履歴を確認</a>
    <a href="{{public_app_url}}/#campaigns" style="display:inline-block;background:#fff;border:1.5px solid #C8789C;color:#C8789C;padding:9px 18px;border-radius:8px;text-decoration:none;font-weight:700;font-size:13px">キャンペーン一覧</a>
  </div>

  <p style="margin:24px 0 0;color:#999;font-size:11px;line-height:1.6">
    REVERB JP のメンバーシップに紐づいて自動送信されています。<br>
    お問い合わせは LINE <a href="https://line.me/R/ti/p/@reverb.jp" style="color:#999;text-decoration:underline">@reverb.jp</a> までお願いいたします。<br>
    <br>
    © JFUN Corp. · 株式会社ジェイファン<br>
    <a href="https://globalreverb.com" style="color:#999;text-decoration:underline">https://globalreverb.com</a>
  </p>
</div>`,
  "influencer-daily-digest.row-received": `<!--
  Row partial: 인플루언서 일일 다이제스트 — 섹션 1 「어제 신청 (received)」
  Edge Function notify-influencer-daily-digest 가 어제 신청 행마다 본 견본을
  render 한 뒤 누적하여 섹션 헤더와 함께 {{section_received_html}} 로 삽입.

  섹션 헤더는 Edge Function 에서 인라인으로 추가:
    <h3 style="...">新規応募の受付 ({{received_count}}件)</h3>

  Row Placeholders:
    {{campaign_no}}     캠페인 번호 (예: 【CAMP-2026-0042】 또는 【B0018-A002-C001】)
    {{campaign_title}}  캠페인 제목
    {{recruit_type_jp}} 모집 타입 일본어 (レビュアー / ギフティング / 訪問型)
    {{applied_at_jst}}  신청 시각 (예: 2026年5月18日 21:34)
-->
<div style="border:1px solid #F0E1E4;border-radius:10px;padding:12px 14px;margin-bottom:10px;background:#FFFAFC">
  <div style="font-size:11px;color:#888;margin-bottom:3px">
    <span style="font-family:monospace">{{campaign_no}}</span> · {{recruit_type_jp}}
  </div>
  <div style="font-size:13px;font-weight:700;line-height:1.4;margin-bottom:4px">{{campaign_title}}</div>
  <div style="font-size:11px;color:#888">応募日時 {{applied_at_jst}}</div>
</div>`,
  "influencer-daily-digest.row-approved": `<!--
  Row partial: 인플루언서 일일 다이제스트 — 섹션 2 「어제 승인 (approved)」

  Row Placeholders:
    {{campaign_no}}        캠페인 번호
    {{campaign_title}}     캠페인 제목
    {{recruit_type_jp}}    모집 타입 일본어
    {{reviewed_at_jst}}    승인 시각 (예: 2026年5月18日 14:22)
    {{reward}}             보상 (¥ 표기 포함, 예: ¥3,000)
    {{deadline_summary}}   마감일 요약 (예: 영수증 5/25 まで · 結果物 6/5 まで, 빈 문자열 가능)
-->
<div style="border:1.5px solid #C8EFC8;border-radius:10px;padding:14px 16px;margin-bottom:10px;background:#F4FBF4">
  <div style="font-size:11px;color:#16A34A;font-weight:700;margin-bottom:4px">承認されました</div>
  <div style="font-size:11px;color:#888;margin-bottom:3px">
    <span style="font-family:monospace">{{campaign_no}}</span> · {{recruit_type_jp}}
  </div>
  <div style="font-size:13px;font-weight:700;line-height:1.4;margin-bottom:6px">{{campaign_title}}</div>
  <table style="border-collapse:collapse;width:100%;font-size:12px">
    <tr><td style="padding:3px 0;color:#888;width:84px">承認日時</td><td style="padding:3px 0">{{reviewed_at_jst}}</td></tr>
    <tr><td style="padding:3px 0;color:#888">報酬</td><td style="padding:3px 0;font-weight:700">{{reward}}</td></tr>
    {{deadline_summary_row}}
  </table>
</div>`,
  "influencer-daily-digest.row-rejected": `<!--
  Row partial: 인플루언서 일일 다이제스트 — 섹션 3 「어제 반려 (rejected)」
  반려 사유는 본 사양 범위 밖 — 일반 안내 텍스트로 마무리.

  Row Placeholders:
    {{campaign_no}}        캠페인 번호
    {{campaign_title}}     캠페인 제목
    {{reviewed_at_jst}}    심사 결과 시각
-->
<div style="border:1px solid #E0E0E0;border-radius:10px;padding:12px 14px;margin-bottom:10px;background:#FAFAFA">
  <div style="font-size:11px;color:#888;font-weight:700;margin-bottom:4px">今回は選考に至りませんでした</div>
  <div style="font-size:11px;color:#888;margin-bottom:3px">
    <span style="font-family:monospace">{{campaign_no}}</span>
  </div>
  <div style="font-size:13px;font-weight:700;line-height:1.4;margin-bottom:4px">{{campaign_title}}</div>
  <div style="font-size:11px;color:#888">審査日時 {{reviewed_at_jst}}</div>
</div>`,
  "influencer-daily-digest.row-deadline": `<!--
  Row partial: 인플루언서 일일 다이제스트 — 섹션 4 「마감 임박 (deadline)」
  영수증(receipt) + 결과물(post) 모두 같은 row 형식 사용. kind 별 색상 차이 없음 — 본문에서 라벨로 구분.

  Row Placeholders:
    {{kind_label_jp}}    종류 라벨 (영수증 = レシート, 결과물 = 投稿物)
    {{campaign_no}}      캠페인 번호
    {{campaign_title}}   캠페인 제목
    {{deadline_jp}}      마감일 일본어 (예: 5月23日 (D-5))
    {{d_minus_label}}    D-N 강조 라벨 (예: D-5 또는 D-1)
    {{d_minus_color}}    D-N 강조 색상 (D-5=#A06A14 오렌지, D-1=#E8344E 빨강)
    {{d_minus_bg}}       D-N 배경색 (D-5=#FFF0D6, D-1=#FFE4E9)
    {{submit_url}}       제출 페이지 절대 URL (활동관리 페이지 딥링크)
-->
<div style="border:1.5px solid #FFE0A8;border-radius:10px;padding:14px 16px;margin-bottom:10px;background:#FFFAF0">
  <div style="display:flex;align-items:center;gap:8px;margin-bottom:6px">
    <span style="background:{{d_minus_bg}};color:{{d_minus_color}};padding:3px 10px;border-radius:4px;font-weight:700;font-size:11px">{{d_minus_label}}</span>
    <span style="font-size:11px;color:#A06A14;font-weight:700">{{kind_label_jp}}</span>
  </div>
  <div style="font-size:11px;color:#888;margin-bottom:3px">
    <span style="font-family:monospace">{{campaign_no}}</span>
  </div>
  <div style="font-size:13px;font-weight:700;line-height:1.4;margin-bottom:6px">{{campaign_title}}</div>
  <div style="font-size:12px;color:#333;margin-bottom:8px">提出期限 <strong>{{deadline_jp}}</strong></div>
  <a href="{{submit_url}}" style="display:inline-block;background:#C8789C;color:#fff;padding:6px 14px;border-radius:6px;text-decoration:none;font-weight:700;font-size:12px">提出に進む</a>
</div>`,
};
