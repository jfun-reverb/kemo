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
<div style="font-family:'Noto Sans KR',Arial,sans-serif;color:#222;max-width:1000px">
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
    {{infl_list_html}}     인플루언서 행 누적 HTML
                           컬럼 5종: 이름(한자) / 이름(가나) / 이메일 / SNS(링크) / 신청 시각
                           헤더 행은 Edge Function 이 본 템플릿 안에 이미 내장
-->
<div style="border:1px solid #E2E7F2;border-radius:8px;padding:12px 14px;margin-bottom:10px;background:#fff">
  <div style="font-size:12px;color:#888;margin-bottom:4px">
    <span style="font-family:monospace">{{campaign_no}}</span> · {{recruit_type_ko}}
  </div>
  <div style="font-size:14px;font-weight:700;margin-bottom:8px;line-height:1.4">{{campaign_title}}</div>
  <div style="font-size:11px;color:#5B6BBF;font-weight:700;margin-bottom:6px">신청 {{infl_count}}건</div>
  <table style="border-collapse:collapse;width:100%;font-size:12px">
    <thead>
      <tr style="background:#F5F7FC;color:#5B6BBF">
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #E2E7F2">이름(한자)</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #E2E7F2">이름(가나)</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #E2E7F2">이메일</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #E2E7F2">SNS</th>
        <th style="padding:6px 8px;text-align:right;font-weight:700;font-size:11px;border-bottom:1px solid #E2E7F2">신청 시각</th>
      </tr>
    </thead>
    <tbody>
      {{infl_list_html}}
    </tbody>
  </table>
</div>`,
  "admin-daily-digest.row-cancelled": `<!--
  Row partial: 섹션 2 (응모 취소) — 캠페인별 그룹 카드
  Edge Function 이 캠페인 기준으로 그룹화 후 본 견본을 캠페인마다 1회 render.
  기존 phase 그룹 헤더는 폐기되고 표의 「시점」 컬럼 컬러 칩으로 흡수.

  Row Placeholders:
    {{campaign_no}}          캠페인 번호 (【...】)
    {{campaign_title}}       캠페인 제목
    {{recruit_type_ko}}      모집 타입 (리뷰어 / 기프팅 / 방문형)
    {{cancel_count}}         이 캠페인에서 취소된 건수
    {{cancel_rows_html}}     인플별 <tr> 누적 HTML (Edge Function 이 직접 생성)
                             컬럼 7종: 이름(한자) / 이름(가나) / 이메일 / SNS / 시점(칩) / 사유 / 취소시각
                             보충 메모는 사유 셀 아래 작은 글씨 줄로 자동 포함
-->
<div style="border:1px solid #F4DDE0;border-radius:8px;padding:12px 14px;margin-bottom:10px;background:#fff">
  <div style="font-size:12px;color:#888;margin-bottom:4px">
    <span style="font-family:monospace">{{campaign_no}}</span> · {{recruit_type_ko}}
  </div>
  <div style="font-size:14px;font-weight:700;margin-bottom:8px;line-height:1.4">{{campaign_title}}</div>
  <div style="font-size:11px;color:#E8344E;font-weight:700;margin-bottom:6px">취소 {{cancel_count}}건</div>
  <table style="border-collapse:collapse;width:100%;font-size:12px">
    <thead>
      <tr style="background:#FDF1F3;color:#E8344E">
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #F4DDE0">이름(한자)</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #F4DDE0">이름(가나)</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #F4DDE0">이메일</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #F4DDE0">SNS</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #F4DDE0">시점</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #F4DDE0">사유</th>
        <th style="padding:6px 8px;text-align:right;font-weight:700;font-size:11px;border-bottom:1px solid #F4DDE0">취소시각</th>
      </tr>
    </thead>
    <tbody>
      {{cancel_rows_html}}
    </tbody>
  </table>
</div>`,
  "admin-daily-digest.row-submitted": `<!--
  Row partial: 섹션 3 (결과물 제출) — 캠페인별 그룹 카드
  Edge Function 이 캠페인 기준으로 그룹화 후 본 견본을 캠페인마다 1회 render.
  쿼리: deliverable_events.action='submit' (재제출 자동 배제) + deliverable_id 배치 조회.
  기존 kind 그룹 헤더는 폐기되고 표의 「종류」 컬럼 칩으로 흡수.

  Row Placeholders:
    {{campaign_no}}            캠페인 번호 (【...】)
    {{campaign_title}}         캠페인 제목
    {{recruit_type_ko}}        모집 타입 (리뷰어 / 기프팅 / 방문형)
    {{submit_count}}           이 캠페인에서 제출된 건수
    {{submit_rows_html}}       인플별 <tr> 누적 HTML
                               컬럼 7종: 이름(한자) / 이름(가나) / 이메일 / SNS / 종류(칩) / 제출 내역 / 제출시각
                               제출 내역 셀:
                                 - receipt: <a>영수증 이미지 보기</a> + 작은 글씨 「주문 X · 구매일 · 금액 ¥N」
                                 - review_image: <a>리뷰 이미지 보기</a>
                                 - post: <a>게시 보기</a>
-->
<div style="border:1px solid #DCE6F0;border-radius:8px;padding:12px 14px;margin-bottom:10px;background:#fff">
  <div style="font-size:12px;color:#888;margin-bottom:4px">
    <span style="font-family:monospace">{{campaign_no}}</span> · {{recruit_type_ko}}
  </div>
  <div style="font-size:14px;font-weight:700;margin-bottom:8px;line-height:1.4">{{campaign_title}}</div>
  <div style="font-size:11px;color:#1F5DBF;font-weight:700;margin-bottom:6px">제출 {{submit_count}}건</div>
  <table style="border-collapse:collapse;width:100%;font-size:12px">
    <thead>
      <tr style="background:#EEF4FC;color:#1F5DBF">
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #DCE6F0">이름(한자)</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #DCE6F0">이름(가나)</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #DCE6F0">이메일</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #DCE6F0">SNS</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #DCE6F0">종류</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #DCE6F0">제출 내역</th>
        <th style="padding:6px 8px;text-align:right;font-weight:700;font-size:11px;border-bottom:1px solid #DCE6F0">제출시각</th>
      </tr>
    </thead>
    <tbody>
      {{submit_rows_html}}
    </tbody>
  </table>
</div>`,
  "admin-daily-digest.row-reprocessed": `<!--
  Row partial: 섹션 4 (재처리 일감) — 캠페인별 그룹 카드
  Edge Function 이 캠페인 기준으로 그룹화 후 본 견본을 캠페인마다 1회 render.

  종류 3종:
    - 결과물 재제출 (deliverable_events action='resubmit')
    - 결과물 되돌리기 (deliverable_events action='revert')
    - 신청 되돌리기 (application_events action='revert_to_pending')

  Row Placeholders:
    {{campaign_no}}             캠페인 번호 (【...】)
    {{campaign_title}}          캠페인 제목
    {{recruit_type_ko}}         모집 타입 (리뷰어 / 기프팅 / 방문형)
    {{reprocess_count}}         이 캠페인에서 재처리된 건수
    {{reprocess_rows_html}}     인플별 <tr> 누적 HTML
                                컬럼 7종: 이름(한자) / 이름(가나) / 이메일 / SNS / 종류(칩) / 처리 운영자 / 시각
-->
<div style="border:1px solid #E5E0F4;border-radius:8px;padding:12px 14px;margin-bottom:10px;background:#fff">
  <div style="font-size:12px;color:#888;margin-bottom:4px">
    <span style="font-family:monospace">{{campaign_no}}</span> · {{recruit_type_ko}}
  </div>
  <div style="font-size:14px;font-weight:700;margin-bottom:8px;line-height:1.4">{{campaign_title}}</div>
  <div style="font-size:11px;color:#6F40A6;font-weight:700;margin-bottom:6px">재처리 {{reprocess_count}}건</div>
  <table style="border-collapse:collapse;width:100%;font-size:12px">
    <thead>
      <tr style="background:#F5EFFB;color:#6F40A6">
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #E5E0F4">이름(한자)</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #E5E0F4">이름(가나)</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #E5E0F4">이메일</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #E5E0F4">SNS</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #E5E0F4">종류</th>
        <th style="padding:6px 8px;text-align:left;font-weight:700;font-size:11px;border-bottom:1px solid #E5E0F4">처리 운영자</th>
        <th style="padding:6px 8px;text-align:right;font-weight:700;font-size:11px;border-bottom:1px solid #E5E0F4">시각</th>
      </tr>
    </thead>
    <tbody>
      {{reprocess_rows_html}}
    </tbody>
  </table>
</div>`,
};
