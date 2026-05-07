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
