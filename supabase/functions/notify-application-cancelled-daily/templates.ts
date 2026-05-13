// 자동 생성 (sync-email-templates.sh) — 직접 수정 금지
// docs/email-templates/ 변경 후 sync 스크립트 실행 시 자동 갱신
//
// 백틱·${...} 패턴은 sed로 escape 처리. 새 템플릿 추가 시 패턴 점검 필요

export const TEMPLATES: Record<string, string> = {
  "application-cancelled-daily": `<!DOCTYPE html>
<!--
  Mail: 응모 취소 일일 요약 (application cancelled — daily digest)
  Trigger: pg_cron 매일 UTC 00:00 (= 한국시간 오전 9시) → Edge Function notify-application-cancelled-daily
  Window:  전일 한국시간 0시~24시 동안 cancel_phase != 'recruit' 인 취소 행
  To:      get_subscribed_admin_emails('application_cancel') ∪ env.NOTIFY_ADMIN_EMAILS
  Lang:    KO
  Skip:    윈도우 내 0건이면 메일 미발송 + 발송 로그 status='skipped_no_data'

  Subject (Edge Function이 동적 생성):
    [REVERB] 응모 취소 일일 요약 — {{digest_date}} ({{total_count}}건)
    예시: [REVERB] 응모 취소 일일 요약 — 2026-05-12 (3건)

  Top-level Placeholders:
    {{digest_date}}         다이제스트 대상일 (YYYY-MM-DD, 한국시간 전일 기준)
    {{total_count}}         총 취소 건수
    {{phase_summary_html}}  시점별 카운트 인라인 HTML (예: <span>구매기간 2건</span> · <span>방문기간 1건</span>)
    [취소 건 카드 HTML — Edge Function이 rows_html 플레이스홀더로 삽입. 행 견본: application-cancelled-daily.row.html]
    [관리자 딥링크 — admin_pane_url 플레이스홀더로 삽입 (filter=cancelled&date=YYYY-MM-DD)]

  관련 사양: docs/specs/2026-05-11-application-cancel.md §6
-->
<div style="font-family:'Noto Sans KR',Arial,sans-serif;color:#222;max-width:640px">
  <h2 style="color:#E8344E;margin:0 0 6px">응모 취소 일일 요약</h2>
  <p style="margin:0 0 16px;color:#666;font-size:13px">REVERB JP 관리자 알림 · 매일 한국시간 오전 9시 발송</p>

  <table style="border-collapse:collapse;width:100%;font-size:13px;margin:0 0 20px;background:#FFF5F7;border-radius:8px;overflow:hidden">
    <tr>
      <td style="padding:12px 16px;color:#888;width:90px">대상일</td>
      <td style="padding:12px 16px;font-weight:700">{{digest_date}}</td>
    </tr>
    <tr>
      <td style="padding:12px 16px;color:#888;border-top:1px solid #FFE4E9">총 건수</td>
      <td style="padding:12px 16px;font-weight:700;color:#E8344E;border-top:1px solid #FFE4E9">{{total_count}}건</td>
    </tr>
    <tr>
      <td style="padding:12px 16px;color:#888;border-top:1px solid #FFE4E9;vertical-align:top">시점별</td>
      <td style="padding:12px 16px;border-top:1px solid #FFE4E9;line-height:1.7">{{phase_summary_html}}</td>
    </tr>
  </table>

  {{rows_html}}

  <a href="{{admin_pane_url}}" style="display:inline-block;background:#E8344E;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none;font-weight:700;font-size:13px;margin-top:8px">관리자 신청 관리에서 일괄 확인</a>

  <p style="margin:24px 0 0;color:#999;font-size:11px;line-height:1.6">
    본 메일은 자동 발송됩니다. 회신 시 응답이 어렵습니다.<br>
    개별 취소는 발생 즉시 관리자 페이지 사이드바 공지사항에도 노출됩니다.<br>
    위반 등록은 관리자 화면 → 인플루언서 상세 모달 → 「위반 등록」 버튼.
  </p>
</div>`,
  "application-cancelled-daily.row": `<!--
  Row partial: 응모 취소 일일 요약 메일 — 행 1건 카드
  Edge Function notify-application-cancelled-daily 가 윈도우 내 취소 행마다 본 견본을 1회 render 한 뒤
  결과 문자열을 누적해 메인 템플릿의 {{rows_html}} 위치에 삽입한다.

  Row Placeholders:
    {{campaign_no}}              캠페인 번호 (예: 【CAMP-2026-0042】)
    {{campaign_title}}           캠페인 제목
    {{recruit_type_ko}}          모집 타입 라벨 (리뷰어 / 기프팅 / 방문형)
    {{influencer_name}}          인플루언서 이름 (한자/가나 병기, 예: 야마다 사쿠라 (山田 さくら))
    {{influencer_email}}         인플루언서 이메일
    {{cancelled_at_jst}}         취소 일시 (예: 2026-05-11 21:34 JST)
    {{cancel_phase_ko}}          취소 시점 한국어 (구매기간 / 방문기간 / 결과물 제출기간 / 기타)
    {{cancel_reason_ko}}         사유 카테고리 한국어 라벨
    {{cancel_reason_note_row}}   보충 텍스트 행 HTML (없으면 빈 문자열)
                                  있을 때 견본:
                                  <tr><td style="padding:4px 0;color:#888;vertical-align:top">보충</td><td style="padding:4px 0;line-height:1.5">{보충 텍스트}</td></tr>
-->
<div style="border:1px solid #F0E1E4;border-radius:10px;padding:14px 16px;margin-bottom:12px;background:#fff">
  <div style="font-size:12px;color:#888;margin-bottom:4px">
    <span style="font-family:monospace">{{campaign_no}}</span> · {{recruit_type_ko}}
  </div>
  <div style="font-size:14px;font-weight:700;margin-bottom:10px;line-height:1.4">{{campaign_title}}</div>
  <table style="border-collapse:collapse;width:100%;font-size:12px">
    <tr><td style="padding:4px 0;color:#888;width:88px">인플루언서</td><td style="padding:4px 0">{{influencer_name}} · {{influencer_email}}</td></tr>
    <tr><td style="padding:4px 0;color:#888">취소 일시</td><td style="padding:4px 0">{{cancelled_at_jst}}</td></tr>
    <tr><td style="padding:4px 0;color:#888">시점</td><td style="padding:4px 0"><span style="background:#FFE4E9;color:#E8344E;padding:2px 8px;border-radius:4px;font-weight:700">{{cancel_phase_ko}}</span></td></tr>
    <tr><td style="padding:4px 0;color:#888">사유</td><td style="padding:4px 0">{{cancel_reason_ko}}</td></tr>
    {{cancel_reason_note_row}}
  </table>
</div>`,
};
