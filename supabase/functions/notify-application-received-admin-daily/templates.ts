// 자동 생성 (sync-email-templates.sh) — 직접 수정 금지
// docs/email-templates/ 변경 후 sync 스크립트 실행 시 자동 갱신
//
// 백틱·${...} 패턴은 sed로 escape 처리. 새 템플릿 추가 시 패턴 점검 필요

export const TEMPLATES: Record<string, string> = {
  "application-received-admin-daily": `<!DOCTYPE html>
<!--
  Mail: 캠페인 신청 접수 — 관리자 일일 요약 (application received admin daily digest)
  Trigger: pg_cron 매일 UTC 00:00 (= 한국시간 오전 9시) → Edge Function notify-application-received-admin-daily
  Window:  전일 한국시간 0시~24시 동안의 applications.created_at
  To:      get_subscribed_admin_emails('application_received') ∪ env.NOTIFY_ADMIN_EMAILS
  Lang:    KO
  Skip:    윈도우 내 0건이면 메일 미발송 + 발송 로그 status='skipped_no_data'

  Subject (Edge Function이 동적 생성):
    [REVERB] 캠페인 신청 접수 일일 요약 — {{digest_date}} ({{total_count}}건)

  Top-level Placeholders:
    {{digest_date}}    대상일 (YYYY-MM-DD, 한국시간 전일 기준)
    {{total_count}}    총 신청 건수
    {{rows_html}}      캠페인별 그룹 + 인플루언서 카드 누적 HTML (row 파일 참조)
    {{admin_pane_url}} 관리자 페이지 신청 관리 딥링크

  관련 사양: docs/specs/2026-05-18-application-email-pipeline.md §5, §8-2
-->
<div style="font-family:'Noto Sans KR',Arial,sans-serif;color:#222;max-width:640px">
  <h2 style="color:#C8789C;margin:0 0 6px">캠페인 신청 접수 일일 요약</h2>
  <p style="margin:0 0 16px;color:#666;font-size:13px">REVERB JP 관리자 알림 · 매일 한국시간 오전 9시 발송</p>

  <table style="border-collapse:collapse;width:100%;font-size:13px;margin:0 0 20px;background:#FFF5F8;border-radius:8px;overflow:hidden">
    <tr>
      <td style="padding:12px 16px;color:#888;width:90px">대상일</td>
      <td style="padding:12px 16px;font-weight:700">{{digest_date}}</td>
    </tr>
    <tr>
      <td style="padding:12px 16px;color:#888;border-top:1px solid #F0E1E4">총 신청</td>
      <td style="padding:12px 16px;font-weight:700;color:#C8789C;border-top:1px solid #F0E1E4">{{total_count}}건</td>
    </tr>
  </table>

  {{rows_html}}

  <a href="{{admin_pane_url}}" style="display:inline-block;background:#C8789C;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none;font-weight:700;font-size:13px;margin-top:8px">관리자 신청 관리에서 보기</a>

  <p style="margin:24px 0 0;color:#999;font-size:11px;line-height:1.6">
    본 메일은 자동 발송됩니다. 회신 시 응답이 어렵습니다.<br>
    수신 설정 변경은 관리자 페이지 → 관리자 계정 → 메일 수신 설정.
  </p>
</div>`,
  "application-received-admin-daily.row": `<!--
  Row partial: 캠페인 신청 접수 일일 요약 — 캠페인별 그룹 카드
  Edge Function notify-application-received-admin-daily 가 캠페인 기준으로 그룹화 후
  본 견본을 캠페인마다 1회 render. 인플루언서 N명은 inflList_html 로 누적 삽입.

  Row Placeholders:
    {{campaign_no}}        캠페인 번호 (예: 【CAMP-2026-0042】 또는 【B0018-A002-C001】)
    {{campaign_title}}     캠페인 제목
    {{recruit_type_ko}}    모집 타입 라벨 (리뷰어 / 기프팅 / 방문형)
    {{infl_count}}         이 캠페인에 신청한 인플루언서 수
    {{infl_list_html}}     인플루언서 카드 누적 HTML (이름·이메일·SNS·신청 시각)
                            예시 1행:
                            <tr>
                              <td style="padding:4px 0">야마다 사쿠라 (山田 さくら)</td>
                              <td style="padding:4px 0;color:#666">sakura@example.com</td>
                              <td style="padding:4px 0;color:#666;font-size:11px">@sakura_jp · IG</td>
                              <td style="padding:4px 0;color:#888;font-size:11px;text-align:right">21:34 JST</td>
                            </tr>
-->
<div style="border:1px solid #F0E1E4;border-radius:10px;padding:14px 16px;margin-bottom:12px;background:#fff">
  <div style="font-size:12px;color:#888;margin-bottom:4px">
    <span style="font-family:monospace">{{campaign_no}}</span> · {{recruit_type_ko}}
  </div>
  <div style="font-size:14px;font-weight:700;margin-bottom:10px;line-height:1.4">{{campaign_title}}</div>
  <div style="font-size:11px;color:#C8789C;font-weight:700;margin-bottom:6px">신청 {{infl_count}}건</div>
  <table style="border-collapse:collapse;width:100%;font-size:12px">
    {{infl_list_html}}
  </table>
</div>`,
};
