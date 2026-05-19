// 자동 생성 (sync-email-templates.sh) — 직접 수정 금지
// docs/email-templates/ 변경 후 sync 스크립트 실행 시 자동 갱신
//
// 백틱·${...} 패턴은 sed로 escape 처리. 새 템플릿 추가 시 패턴 점검 필요

export const TEMPLATES: Record<string, string> = {
  "admin-daily-digest": `<!DOCTYPE html>
<!--
  Mail: 관리자 일일 통합 다이제스트 (admin daily digest)
  Trigger: pg_cron 매일 UTC 00:00 (= 한국시간 오전 9시) → Edge Function notify-admin-daily-digest
  Window:  전일 한국시간 0시~24시
  To:      get_subscribed_admin_emails('application_cancel') ∪
           get_subscribed_admin_emails('application_received') ∪ env.NOTIFY_ADMIN_EMAILS
  Lang:    KO
  Skip:    4섹션 모두 0건이면 메일 미발송 + 발송 로그 status='skipped_no_data'

  4섹션 구조:
    1. 캠페인 신청 접수 (received) — applications.created_at 윈도우
    2. 응모 취소 (cancelled) — cancelled_at 윈도우, cancel_phase != 'recruit'
    3. 결과물 제출 (submitted) — deliverable_events.action='submit' 윈도우
    4. 재처리 일감 (reprocessed) — deliverable_events.action IN ('resubmit','revert')
                                  + application_events.action='revert_to_pending'

  Subject (Edge Function이 동적 생성):
    [REVERB] 관리자 일일 요약 — {{digest_date}} (총 {{total_count}}건)

  Top-level Placeholders:
    {{digest_date}}              대상일 (YYYY-MM-DD, 한국시간 전일 기준)
    {{total_count}}              4섹션 합산 총 건수
    {{summary_chip_html}}        섹션별 건수 칩 HTML (0건 섹션 생략)
    {{section_received_html}}    섹션 1 본문 (0건이면 빈 문자열)
    {{section_cancelled_html}}   섹션 2 본문 (0건이면 빈 문자열)
    {{section_submitted_html}}   섹션 3 본문 (0건이면 빈 문자열)
    {{section_reprocessed_html}} 섹션 4 본문 (0건이면 빈 문자열)
    {{admin_pane_url}}           관리자 페이지 딥링크

  관련 사양:
    docs/specs/2026-05-18-mail-pipeline-consolidation.md §13~§14
    docs/specs/2026-05-18-HANDOFF-mail-pipeline-consolidation.md §5
-->
<div style="font-family:'Noto Sans KR',Arial,sans-serif;color:#222;max-width:680px">
  <h2 style="color:#5B6BBF;margin:0 0 6px">관리자 일일 통합 요약</h2>
  <p style="margin:0 0 16px;color:#666;font-size:13px">REVERB JP 관리자 알림 · 매일 한국시간 오전 9시 발송</p>

  <table style="border-collapse:collapse;width:100%;font-size:13px;margin:0 0 16px;background:#F5F7FC;border-radius:8px;overflow:hidden">
    <tr>
      <td style="padding:12px 16px;color:#888;width:90px">대상일</td>
      <td style="padding:12px 16px;font-weight:700">{{digest_date}}</td>
    </tr>
    <tr>
      <td style="padding:12px 16px;color:#888;border-top:1px solid #E2E7F2">총합</td>
      <td style="padding:12px 16px;font-weight:700;color:#5B6BBF;border-top:1px solid #E2E7F2">{{total_count}}건</td>
    </tr>
  </table>

  <div style="margin:0 0 20px;line-height:2">{{summary_chip_html}}</div>

  {{section_received_html}}
  {{section_cancelled_html}}
  {{section_submitted_html}}
  {{section_reprocessed_html}}

  <a href="{{admin_pane_url}}" style="display:inline-block;background:#5B6BBF;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none;font-weight:700;font-size:13px;margin-top:8px">관리자 페이지에서 보기</a>

  <p style="margin:24px 0 0;color:#999;font-size:11px;line-height:1.6">
    본 메일은 자동 발송됩니다. 회신 시 응답이 어렵습니다.<br>
    수신 설정 변경은 관리자 페이지 → 관리자 계정 → 메일 수신 설정.
  </p>
</div>`,
  "admin-daily-digest.section": `<!--
  Section wrapper partial: 관리자 일일 통합 다이제스트 4섹션 공통 wrapper
  Edge Function notify-admin-daily-digest 가 각 섹션마다 1회 render.
  0건 섹션은 메인 placeholder 에 빈 문자열로 치환되어 본 wrapper 미사용.

  Section Placeholders:
    {{section_title}}      섹션 제목 (캠페인 신청 접수 / 응모 취소 / 결과물 제출 / 재처리 일감)
    {{section_color}}      섹션 색상 코드 (border-left)
    {{section_count}}      섹션 건수
    {{section_body_html}}  섹션 본문 (그룹 헤더 + 행 카드 누적)
-->
<div style="margin:0 0 18px;border:1px solid #E2E7F2;border-radius:10px;overflow:hidden">
  <div style="padding:10px 14px;background:#F5F7FC;border-left:4px solid {{section_color}};display:flex;align-items:center;justify-content:space-between">
    <span style="font-weight:700;font-size:14px;color:#222">▶ {{section_title}}</span>
    <span style="font-size:12px;color:#5B6BBF;font-weight:700">{{section_count}}건</span>
  </div>
  <div style="padding:12px 14px;background:#fff">{{section_body_html}}</div>
</div>`,
  "admin-daily-digest.row-received": `<!--
  Row partial: 섹션 1 (캠페인 신청 접수) — 캠페인별 그룹 카드
  Edge Function 이 캠페인 기준으로 그룹화 후 본 견본을 캠페인마다 1회 render.

  Row Placeholders:
    {{campaign_no}}        캠페인 번호 (예: 【CAMP-2026-0042】 또는 【B0018-A002-C001】)
    {{campaign_title}}     캠페인 제목
    {{recruit_type_ko}}    모집 타입 (리뷰어 / 기프팅 / 방문형)
    {{infl_count}}         이 캠페인 신청한 인플루언서 수
    {{infl_list_html}}     인플루언서 카드 누적 HTML (이름·이메일·SNS·신청 시각)
-->
<div style="border:1px solid #E2E7F2;border-radius:8px;padding:12px 14px;margin-bottom:10px;background:#fff">
  <div style="font-size:12px;color:#888;margin-bottom:4px">
    <span style="font-family:monospace">{{campaign_no}}</span> · {{recruit_type_ko}}
  </div>
  <div style="font-size:14px;font-weight:700;margin-bottom:8px;line-height:1.4">{{campaign_title}}</div>
  <div style="font-size:11px;color:#5B6BBF;font-weight:700;margin-bottom:6px">신청 {{infl_count}}건</div>
  <table style="border-collapse:collapse;width:100%;font-size:12px">
    {{infl_list_html}}
  </table>
</div>`,
  "admin-daily-digest.row-cancelled": `<!--
  Row partial: 섹션 2 (응모 취소) — 행별 카드
  Edge Function 이 cancel_phase 그룹 안에서 행마다 1회 render.

  Row Placeholders:
    {{campaign_no}}              캠페인 번호 (【...】)
    {{campaign_title}}           캠페인 제목
    {{recruit_type_ko}}          모집 타입 (리뷰어 / 기프팅 / 방문형)
    {{influencer_name}}          인플루언서 표시명
    {{influencer_email}}         인플루언서 이메일
    {{cancelled_at_jst}}         취소 시각 (YYYY-MM-DD HH:mm JST)
    {{cancel_phase_ko}}          시점 라벨 (구매기간 / 방문기간 / 결과물 제출기간 / 기타)
    {{cancel_reason_ko}}         사유 라벨 (lookup name_ko)
    {{cancel_reason_note_row}}   보충 메모 행 (있을 때만, 없으면 빈 문자열)
-->
<div style="border:1px solid #F4DDE0;border-radius:8px;padding:12px 14px;margin-bottom:10px;background:#fff">
  <div style="font-size:12px;color:#888;margin-bottom:4px">
    <span style="font-family:monospace">{{campaign_no}}</span> · {{recruit_type_ko}} · {{cancelled_at_jst}}
  </div>
  <div style="font-size:14px;font-weight:700;margin-bottom:8px;line-height:1.4">{{campaign_title}}</div>
  <table style="border-collapse:collapse;font-size:12px;width:100%">
    <tr>
      <td style="padding:4px 0;color:#888;width:60px">인플</td>
      <td style="padding:4px 0">{{influencer_name}}</td>
    </tr>
    <tr>
      <td style="padding:4px 0;color:#888">이메일</td>
      <td style="padding:4px 0;color:#666">{{influencer_email}}</td>
    </tr>
    <tr>
      <td style="padding:4px 0;color:#888">시점</td>
      <td style="padding:4px 0;font-weight:700;color:#E8344E">{{cancel_phase_ko}}</td>
    </tr>
    <tr>
      <td style="padding:4px 0;color:#888">사유</td>
      <td style="padding:4px 0">{{cancel_reason_ko}}</td>
    </tr>
    {{cancel_reason_note_row}}
  </table>
</div>`,
  "admin-daily-digest.row-submitted": `<!--
  Row partial: 섹션 3 (결과물 제출) — 행별 카드
  Edge Function 이 kind 그룹 안에서 행마다 1회 render.
  쿼리: deliverable_events.action='submit' (재제출 자동 배제) + deliverable_id 배치 조회.

  Row Placeholders:
    {{campaign_no}}        캠페인 번호 (【...】)
    {{campaign_title}}     캠페인 제목
    {{recruit_type_ko}}    모집 타입 (리뷰어 / 기프팅 / 방문형)
    {{kind_ko}}            결과물 종류 (영수증 / 리뷰 이미지 / 게시 URL)
    {{influencer_name}}    인플루언서 표시명
    {{submitted_at_jst}}   제출 시각 (HH:mm JST)
-->
<div style="border:1px solid #DCE6F0;border-radius:8px;padding:10px 14px;margin-bottom:8px;background:#fff">
  <div style="font-size:12px;color:#888;margin-bottom:4px">
    <span style="font-family:monospace">{{campaign_no}}</span> · {{recruit_type_ko}} · {{submitted_at_jst}}
  </div>
  <div style="font-size:14px;font-weight:700;margin-bottom:4px;line-height:1.4">{{campaign_title}}</div>
  <div style="font-size:12px;color:#444">
    <span style="background:#E4F0FF;color:#1F5DBF;padding:2px 8px;border-radius:4px;font-weight:700;font-size:11px;margin-right:8px">{{kind_ko}}</span>
    {{influencer_name}}
  </div>
</div>`,
  "admin-daily-digest.row-reprocessed": `<!--
  Row partial: 섹션 4 (재처리 일감) — 행별 카드
  Edge Function 이 종류 그룹 안에서 행마다 1회 render.

  종류 3종:
    - 결과물 재제출 (deliverable_events action='resubmit')
    - 결과물 되돌리기 (deliverable_events action='revert')
    - 신청 되돌리기 (application_events action='revert_to_pending')

  Row Placeholders:
    {{campaign_no}}        캠페인 번호 (【...】)
    {{campaign_title}}     캠페인 제목
    {{recruit_type_ko}}    모집 타입 (리뷰어 / 기프팅 / 방문형)
    {{type_ko}}            재처리 종류 라벨
    {{type_color_bg}}      종류 칩 배경색
    {{type_color_fg}}      종류 칩 글자색
    {{influencer_name}}    인플루언서 표시명
    {{actor_name}}         액션 수행 운영자 이름 (또는 「-」)
    {{event_at_jst}}       이벤트 시각 (HH:mm JST)
-->
<div style="border:1px solid #E5E0F4;border-radius:8px;padding:10px 14px;margin-bottom:8px;background:#fff">
  <div style="font-size:12px;color:#888;margin-bottom:4px">
    <span style="font-family:monospace">{{campaign_no}}</span> · {{recruit_type_ko}} · {{event_at_jst}}
  </div>
  <div style="font-size:14px;font-weight:700;margin-bottom:4px;line-height:1.4">{{campaign_title}}</div>
  <div style="font-size:12px;color:#444">
    <span style="background:{{type_color_bg}};color:{{type_color_fg}};padding:2px 8px;border-radius:4px;font-weight:700;font-size:11px;margin-right:8px">{{type_ko}}</span>
    {{influencer_name}} <span style="color:#888">· 처리: {{actor_name}}</span>
  </div>
</div>`,
};
