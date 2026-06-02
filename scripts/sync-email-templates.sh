#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# sync-email-templates.sh
#
# docs/email-templates/ → supabase/functions/<fn>/_templates/
# 메일 HTML 원본을 각 Edge Function 디렉토리로 복사.
#
# 동기화 대상:
#   notify-brand-application:    광고주 신청 메일 3종 (brand-*)
#   notify-deliverable-decision: 결과물 검수 메일 6종 (deliverable-*)
#
# 이유: Supabase Edge Function 배포는 함수 디렉토리만 번들에 포함.
#       docs/ 외부 파일은 Deno.readTextFile() 으로 읽을 수 없으므로
#       함수 디렉토리 내부에 미러본 유지가 필요.
#
# 실행:
#   bash scripts/sync-email-templates.sh
#
# 실행 시점:
#   - docs/email-templates/*.html 수정 후
#   - Edge Function 배포 직전
#   - CI에서 diff 검증 (TODO)
# ──────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/docs/email-templates"

# 동기화 매핑: "함수명|템플릿1.html,템플릿2.html,..."
SYNC_GROUPS=(
  "notify-brand-application|brand-admin-notify.html,brand-ack-reviewer.html,brand-ack-seeding.html"
  "notify-deliverable-decision|deliverable-receipt-approved.html,deliverable-receipt-rejected.html,deliverable-review-image-approved.html,deliverable-review-image-rejected.html,deliverable-post-approved.html,deliverable-post-rejected.html"
  "notify-influencer-daily-digest|influencer-daily-digest.html,influencer-daily-digest.row-received.html,influencer-daily-digest.row-approved.html,influencer-daily-digest.row-rejected.html,influencer-daily-digest.row-deadline.html"
  "notify-admin-daily-digest|admin-daily-digest.html,admin-daily-digest.section.html,admin-daily-digest.row-received.html,admin-daily-digest.row-cancelled.html,admin-daily-digest.row-submitted.html,admin-daily-digest.row-reprocessed.html"
  "notify-campaign-promo-digest|campaign-promo-digest.html,campaign-promo-digest.section.html,campaign-promo-digest.row-campaign.html,campaign-promo-digest.admin.html"
  "notify-policy-change|policy-change-notice.html"
)

if [[ ! -d "$SRC_DIR" ]]; then
  echo "❌ source dir not found: $SRC_DIR" >&2
  exit 1
fi

total_changed=0
changed_fns=()

for group in "${SYNC_GROUPS[@]}"; do
  fn_name="${group%%|*}"
  files_csv="${group#*|}"
  IFS=',' read -r -a files <<< "$files_csv"

  dst_dir="$REPO_ROOT/supabase/functions/$fn_name/_templates"
  mkdir -p "$dst_dir"

  group_changed=0
  echo "── $fn_name (${#files[@]} files)"
  for f in "${files[@]}"; do
    src="$SRC_DIR/$f"
    dst="$dst_dir/$f"
    if [[ ! -f "$src" ]]; then
      echo "❌ source missing: $src" >&2
      exit 1
    fi
    if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
      cp "$src" "$dst"
      echo "  ✓ synced: $f"
      group_changed=$((group_changed + 1))
    else
      echo "    unchanged: $f"
    fi
  done

  if [[ $group_changed -gt 0 ]]; then
    total_changed=$((total_changed + group_changed))
    changed_fns+=("$fn_name")
  fi

  # _templates 디렉토리가 Edge Function 번들에 포함 안 되는 supabase CLI
  # 동작을 회피하기 위해 templates.ts 자동 생성. 대상 함수:
  #   - notify-deliverable-decision (결과물 검수 메일 6종)
  #   - notify-influencer-daily-digest (인플루언서 일일 다이제스트 5종 — 마이그레이션 130)
  #   - notify-admin-daily-digest (관리자 통합 다이제스트 6종 — 마이그레이션 132, PR 2. 구 application_cancel·received 일일요약 2종 흡수 — 마이그레이션 164)
  #   - notify-campaign-promo-digest (캠페인 홍보 메일 다이제스트 3종 — 마이그레이션 139~143, PR 2)
  # notify-brand-application 은 과거 deploy 가 _templates/ 를 포함했던 시점에
  # 등록되어 그대로 동작 중 — 추후 재배포 회귀 발생 시 동일 분기로 이동.
  if [[ "$fn_name" == "notify-deliverable-decision" ]] || \
     [[ "$fn_name" == "notify-influencer-daily-digest" ]] || \
     [[ "$fn_name" == "notify-admin-daily-digest" ]] || \
     [[ "$fn_name" == "notify-campaign-promo-digest" ]] || \
     [[ "$fn_name" == "notify-policy-change" ]]; then
    ts_path="$REPO_ROOT/supabase/functions/$fn_name/templates.ts"
    {
      echo "// 자동 생성 (sync-email-templates.sh) — 직접 수정 금지"
      echo "// docs/email-templates/ 변경 후 sync 스크립트 실행 시 자동 갱신"
      echo "//"
      echo "// 백틱·\${...} 패턴은 sed로 escape 처리. 새 템플릿 추가 시 패턴 점검 필요"
      echo ""
      echo "export const TEMPLATES: Record<string, string> = {"
      for f in "${files[@]}"; do
        name="${f%.html}"
        # 백슬래시 → 이중 백슬래시 / 백틱·달러 escape (template literal 안전)
        content=$(sed 's/\\/\\\\/g; s/`/\\`/g; s/\$/\\$/g' "$dst_dir/$f")
        echo "  \"$name\": \`$content\`,"
      done
      echo "};"
    } > "$ts_path"
    echo "  ✓ generated: templates.ts (${#files[@]} templates inlined)"
  fi
done

echo ""
if [[ $total_changed -gt 0 ]]; then
  echo "📦 $total_changed file(s) updated across ${#changed_fns[@]} function(s):"
  for fn in "${changed_fns[@]}"; do
    echo "   - $fn"
  done
  echo ""
  echo "Don't forget:"
  echo "   1. git add supabase/functions/*/_templates/"
  echo "   2. Deploy each updated Edge Function:"
  for fn in "${changed_fns[@]}"; do
    echo "      supabase functions deploy $fn --project-ref <ref>"
  done
else
  echo "✓ all templates already in sync."
fi
