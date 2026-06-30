// 자동 생성 (sync-email-templates.sh) — 직접 수정 금지
// docs/email-templates/ 변경 후 sync 스크립트 실행 시 자동 갱신
//
// 백틱·${...} 패턴은 sed로 escape 처리. 새 템플릿 추가 시 패턴 점검 필요

export const TEMPLATES: Record<string, string> = {
  "brand-daily-digest": `<!DOCTYPE html>
<!--
  Mail: 브랜드 일일 보고 (brand daily digest)
  Trigger: pg_cron 매일 UTC 00:00 (= 한국시간 오전 9시) → Edge Function notify-brand-daily-digest
  Window:  전일 한국시간 0시~24시
  To:      get_subscribed_admin_emails('brand_digest') ∪ env.NOTIFY_ADMIN_EMAILS (마이그레이션 203)
  Lang:    KO
  Skip:    2섹션 모두 0건이면 메일 미발송 + 발송 로그 status='skipped_no_data'

  2섹션 구조:
    1. 신규 제출 — orient_sheets.submitted_at 어제 KST 윈도우
    2. 수정 재제출 — orient_sheets.last_submitted_at 어제 KST 윈도우
                    AND submitted_at < 어제 시작 (최초 제출은 그 이전)

  Subject (Edge Function이 동적 생성):
    [REVERB] 브랜드 일일 보고 — {{digest_date}} (총 {{total_count}}건)

  Top-level Placeholders:
    {{digest_date}}          대상일 (YYYY-MM-DD, 한국시간 전일 기준)
    {{total_count}}          2섹션 합산 총 건수
    {{summary_chip_html}}    섹션별 건수 칩 HTML (0건 섹션 생략)
    {{section_new_html}}     섹션 1 본문 (0건이면 빈 문자열)
    {{section_resubmit_html}} 섹션 2 본문 (0건이면 빈 문자열)
    {{orient_pane_url}}      관리자 오리엔시트 발급·조회 페인 URL

  관련 사양:
    docs/specs/2026-06-30-orient-submit-notification.md §7-2, §10 PR 2
    supabase/migrations/203_brand_daily_digest.sql
-->
<div style="font-family:'Noto Sans KR',Arial,sans-serif;color:#222;max-width:800px">
  <h2 style="color:#5B6BBF;margin:0 0 6px">브랜드 일일 보고</h2>
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

  {{section_new_html}}
  {{section_resubmit_html}}

  <a href="{{orient_pane_url}}" style="display:inline-block;background:#5B6BBF;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none;font-weight:700;font-size:13px;margin-top:8px">오리엔시트 발급·조회 페인에서 보기</a>

  <p style="margin:24px 0 0;color:#999;font-size:11px;line-height:1.6">
    본 메일은 자동 발송됩니다. 회신 시 응답이 어렵습니다.<br>
    수신 설정 변경은 관리자 페이지 → 관리자 계정 → 메일 수신 설정.
  </p>
</div>`,
  "brand-daily-digest.section": `<!--
  Section wrapper partial: 브랜드 일일 보고 섹션 공통 wrapper
  Edge Function notify-brand-daily-digest 가 각 섹션마다 1회 render.
  0건 섹션은 메인 placeholder 에 빈 문자열로 치환되어 본 wrapper 미사용.

  Section Placeholders:
    {{section_title}}      섹션 제목 (신규 제출 / 수정 재제출)
    {{section_color}}      섹션 색상 코드 (border-left)
    {{section_count}}      섹션 건수
    {{section_body_html}}  섹션 본문 (행 테이블)
-->
<div style="margin:0 0 18px;border:1px solid #E2E7F2;border-radius:10px;overflow:hidden">
  <div style="padding:10px 14px;background:#F5F7FC;border-left:4px solid {{section_color}};display:flex;align-items:center;justify-content:space-between">
    <span style="font-weight:700;font-size:14px;color:#222">▶ {{section_title}}</span>
    <span style="font-size:12px;color:#5B6BBF;font-weight:700">{{section_count}}건</span>
  </div>
  <div style="padding:12px 14px;background:#fff">{{section_body_html}}</div>
</div>`,
};
