// 자동 생성 (sync-email-templates.sh) — 직접 수정 금지
// docs/email-templates/ 변경 후 sync 스크립트 실행 시 자동 갱신
//
// 백틱·${...} 패턴은 sed로 escape 처리. 새 템플릿 추가 시 패턴 점검 필요

export const TEMPLATES: Record<string, string> = {
  "campaign-promo-digest": `<!DOCTYPE html>
<!--
  Mail: 캠페인 홍보 메일 다이제스트 (campaign promo digest)
  Trigger: pg_cron 매주 월·목 UTC 00:00 (= 한국시간 오전 9시)
           → Edge Function notify-campaign-promo-digest
  Window:
    - 「新着」 섹션: campaigns.first_active_at 가 p_digest_date (KST) 윈도우 안
    - 「締切間近」 섹션: campaigns.deadline = 내일 (KST) — D-1 단일 시점
  To: 인플루언서 1명당 1통 (To 헤더에 다른 인플 이메일 노출 안 됨)
  Lang: JA (친근체)
  Skip: 두 섹션 모두 0건이면 인플 단위로 발송 미실시 (status='skipped_no_data')

  같은 캠페인 인플당 최대 2회 노출 (kind='new' 1회 + kind='deadline_d1' 1회)
  CTA 클릭하면 그 캠페인은 다음 다이제스트 매칭에서 자동 제외

  Subject (Edge Function 동적 생성, 신규/마감 건수에 따라 분기):
    [REVERB JP] 新着キャンペーンN件 / 締切間近M件
    또는 [REVERB JP] 新着キャンペーンN件のご案内
    또는 [REVERB JP] 締切間近M件のお知らせ

  Top-level Placeholders:
    {{influencer_name}}        인플 표시명 (한자/legacy/가나 우선순위)
    {{new_section_html}}       섹션 1 본문 (0건이면 빈 문자열로 통째 생략)
    {{deadline_section_html}}  섹션 2 본문 (0건이면 빈 문자열로 통째 생략)
    {{campaigns_url}}          하단 「すべてのキャンペーンを見る」 CTA URL

  PR 4 머지 시 복구 예정 placeholder (현 본문에 미사용 — 인플 페이지 수신거부/설정 라우트 구현 후 본문 다시 부착):
    {{unsubscribe_url}}        1-click 수신거부 URL (토큰 포함)
    {{mypage_settings_url}}    마이페이지 메일 수신 설정 URL
    {{agreed_at_label}}        동의 시점 라벨 (예: 「2024年5月にマーケティング情報配信に同意いただきました」)

  관련 사양:
    docs/specs/2026-05-19-campaign-promo-email.md §5, §16-5, §17-7
-->
<div style="font-family:'Hiragino Sans','Noto Sans JP',Arial,sans-serif;color:#222;max-width:600px;margin:0 auto">
  <h2 style="color:#C8789C;margin:0 0 6px;font-size:20px">キャンペーン情報のお知らせ</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">REVERB JP からの最新キャンペーン情報をお届けします</p>

  <p style="margin:0 0 14px;font-size:14px;line-height:1.6">
    <strong>{{influencer_name}}</strong> 様<br>
    新しいキャンペーンが届きました!気になるキャンペーンをチェックしてみてくださいね。
  </p>

  {{new_section_html}}
  {{deadline_section_html}}

  <div style="text-align:center;margin:24px 0">
    <a href="{{campaigns_url}}" style="display:inline-block;background:#C8789C;color:#fff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:700;font-size:14px">すべてのキャンペーンを見る</a>
  </div>

  <p style="margin:24px 0 0;color:#999;font-size:11px;line-height:1.6">
    REVERB JP のメンバーシップに紐づいて自動送信されています。<br>
    お問い合わせは LINE <a href="https://line.me/R/ti/p/@reverb.jp" style="color:#999;text-decoration:underline">@reverb.jp</a> までお願いいたします。<br>
    <br>
    © JFUN Corp. · 株式会社ジェイファン<br>
    <a href="https://globalreverb.com" style="color:#999;text-decoration:underline">https://globalreverb.com</a>
  </p>
</div>`,
  "campaign-promo-digest.section": `<!--
  Section wrapper partial: 캠페인 홍보 메일 2섹션 공통 wrapper
  Edge Function notify-campaign-promo-digest 가 각 섹션마다 1회 render.
  0건 섹션은 메인 placeholder 에 빈 문자열로 치환되어 본 wrapper 미사용.

  Section Placeholders:
    {{section_title}}            섹션 제목 (新着キャンペーン / 締切間近キャンペーン)
    {{section_color}}            섹션 색상 코드 (border-left)
    {{section_count}}            섹션 카드 표시 수 (1~5)
    {{section_body_html}}        섹션 본문 (캠페인 카드 누적 + 「他 N件」 안내)
-->
<div style="margin:0 0 18px;border:1px solid #E2E7F2;border-radius:10px;overflow:hidden">
  <div style="padding:10px 14px;background:#FFF5F8;border-left:4px solid {{section_color}};display:flex;align-items:center;justify-content:space-between">
    <span style="font-weight:700;font-size:14px;color:#222">▶ {{section_title}}</span>
    <span style="font-size:12px;color:{{section_color}};font-weight:700">{{section_count}}件</span>
  </div>
  <div style="padding:14px;background:#fff">{{section_body_html}}</div>
</div>`,
  "campaign-promo-digest.row-campaign": `<!--
  Row partial: 캠페인 카드 1개 (新着 섹션, 締切間近 섹션 공통 사용)
  Edge Function 이 캠페인별로 본 견본을 1회 render.

  레이아웃: 좌(이미지) / 우(정보 + 버튼) 수평 분할 — table 기반 (메일 클라이언트 호환).
  이미지 폭 ~40%, 정보 폭 ~60%.

  D-1 칩은 deadline_d1 섹션에서만 채움. 신규 섹션 카드에서는 d1_chip_html = "" (빈 문자열).
  slots 행은 monitor (리뷰어) 캠페인에서만 채움. 다른 타입은 slots_row_html = "".

  Row Placeholders:
    {{img_url}}              캠페인 썸네일 (Supabase Storage URL, safeExternalUrl 검증 통과)
    {{recruit_type_ja}}      모집 타입 (レビュアー / ギフティング / 訪問型)
    {{type_chip_bg}}         모집 타입 칩 배경색
    {{type_chip_fg}}         모집 타입 칩 글자색
    {{brand}}                브랜드명
    {{title}}                캠페인 제목
    {{d1_chip_html}}         「締切間近 D-1」 칩 HTML (신규 섹션은 "", D-1 섹션만 채움)
    {{reward}}               리워드 표기
    {{deadline_label}}       마감 표기 (「あと N日」 또는 「明日まで」)
    {{slots_row_html}}       잔여 슬롯 행 (monitor 만 채움, 다른 타입은 "")
    {{detail_url}}           캠페인 상세 URL (?promo_token={token} 포함)
-->
<table cellpadding="0" cellspacing="0" border="0" width="100%" style="border:1px solid #E2E7F2;border-radius:10px;margin-bottom:14px;background:#fff">
  <tr>
    <td width="40%" valign="top" style="padding:12px 0 12px 12px">
      <img src="{{img_url}}" alt="{{img_alt}}" width="200" height="200" style="width:100%;max-width:200px;height:200px;object-fit:cover;border-radius:8px;display:block;background:#eeeeee">
    </td>
    <td width="60%" valign="top" style="padding:12px 14px 12px 12px">
      <div style="font-size:11px;color:#888;margin-bottom:6px;line-height:1.6">
        <span style="background:{{type_chip_bg}};color:{{type_chip_fg}};padding:2px 8px;border-radius:4px;font-weight:700">{{recruit_type_ja}}</span>
        <span style="margin-left:6px">{{brand}}</span>
        {{d1_chip_html}}
      </div>

      <h3 style="font-size:14px;font-weight:700;margin:6px 0 8px;line-height:1.4;color:#222">{{title}}</h3>

      <table cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;width:100%;font-size:12px;margin-bottom:10px">
        <tr>
          <td style="color:#888;width:70px;padding:2px 0">報酬</td>
          <td style="padding:2px 0">{{reward}}</td>
        </tr>
        <tr>
          <td style="color:#888;padding:2px 0">締切</td>
          <td style="color:#E8344E;font-weight:700;padding:2px 0">{{deadline_label}}</td>
        </tr>
        {{slots_row_html}}
      </table>

      <a href="{{detail_url}}" style="display:inline-block;background:#C8789C;color:#fff;padding:6px 14px;border-radius:6px;text-decoration:none;font-weight:700;font-size:12px">詳細を見る</a>
    </td>
  </tr>
</table>`,
  "campaign-promo-digest.admin": `<!DOCTYPE html>
<!--
  Mail: 캠페인 홍보 메일 다이제스트 — 관리자용 (admin copy)
  Trigger: 인플루언서 홍보 메일 함수 notify-campaign-promo-digest 의 "첫 배치" 에서
           관리자 발송 블록이 함께 호출 (별도 cron 없음, 같은 주 2회 스케줄에 편승)
  To: 관리자 1명당 1통 (To 헤더에 다른 관리자 이메일 노출 안 됨)
  대상: 관리자 「메일 받기 설정」 에서 캠페인 홍보 메일(campaign_promo) 토글을 켠 관리자
  Lang: 머리말·안내·푸터는 한국어, 캠페인 카드(제목·리워드·모집유형)는 원본 일본어 그대로

  내용: 그날 홍보 대상이 된 캠페인 전체(신규 + 마감 D-1) 1통.
        인플루언서와 달리 자격 매칭/개인화 없음 — 그날 풀 전체.
  Skip: 그날 홍보 캠페인 풀이 비면 관리자 발송 자체 생략.

  Subject (Edge Function 동적 생성):
    [REVERB JP 관리자] 오늘의 홍보 캠페인 신규N건 / 마감임박M건
    또는 신규만 / 마감임박만 분기

  Top-level Placeholders:
    {{new_count}}              신규 캠페인 총수 (머리말 표시용)
    {{d1_count}}               마감임박 캠페인 총수 (머리말 표시용)
    {{new_section_html}}       섹션 1 본문 (0건이면 빈 문자열로 통째 생략)
    {{deadline_section_html}}  섹션 2 본문 (0건이면 빈 문자열로 통째 생략)

  관련 사양:
    docs/specs/2026-05-27-admin-promo-email-subscription.md §2
-->
<div style="font-family:'Noto Sans KR','Hiragino Sans',Arial,sans-serif;color:#222;max-width:600px;margin:0 auto">
  <h2 style="color:#5B6BBF;margin:0 0 6px;font-size:20px">오늘의 캠페인 홍보 메일</h2>
  <p style="margin:0 0 18px;color:#666;font-size:13px">인플루언서에게 발송된 오늘의 홍보 대상 캠페인입니다 (운영 참고용)</p>

  <p style="margin:0 0 14px;font-size:14px;line-height:1.6">
    오늘 홍보 대상 캠페인: <strong>신규 {{new_count}}건</strong> · <strong>마감임박 {{d1_count}}건</strong><br>
    아래 카드는 인플루언서가 받은 메일과 동일한 일본어 본문입니다.
  </p>

  {{new_section_html}}
  {{deadline_section_html}}

  <p style="margin:24px 0 0;color:#999;font-size:11px;line-height:1.6">
    이 메일은 관리자 「메일 받기 설정」 에서 '캠페인 홍보 메일' 을 켜두셔서 받고 있습니다.<br>
    수신을 끄려면 관리자 페이지 → 관리자 계정 → 「메일받기」 설정에서 변경하세요.<br>
    <br>
    © JFUN Corp. · 株式会社ジェイファン
  </p>
</div>`,
};
