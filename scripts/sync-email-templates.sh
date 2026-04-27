#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# sync-email-templates.sh
#
# docs/email-templates/ → supabase/functions/notify-brand-application/_templates/
# 광고주 메일 3종 HTML을 Edge Function 디렉토리로 복사.
#
# 이유: Supabase Edge Function 배포는 함수 디렉토리만 번들에 포함.
#       docs/ 외부 파일은 Deno.readTextFile() 으로 읽을 수 없으므로
#       함수 디렉토리 내부에 미러본 유지가 필요.
#
# 실행:
#   bash scripts/sync-email-templates.sh
#
# 실행 시점:
#   - docs/email-templates/brand-*.html 수정 후
#   - Edge Function 배포 직전
#   - CI에서 diff 검증 (TODO)
# ──────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/docs/email-templates"
DST_DIR="$REPO_ROOT/supabase/functions/notify-brand-application/_templates"

TEMPLATES=(
  brand-admin-notify.html
  brand-ack-reviewer.html
  brand-ack-seeding.html
)

if [[ ! -d "$SRC_DIR" ]]; then
  echo "❌ source dir not found: $SRC_DIR" >&2
  exit 1
fi

mkdir -p "$DST_DIR"

changed=0
for f in "${TEMPLATES[@]}"; do
  src="$SRC_DIR/$f"
  dst="$DST_DIR/$f"
  if [[ ! -f "$src" ]]; then
    echo "❌ source missing: $src" >&2
    exit 1
  fi
  if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
    cp "$src" "$dst"
    echo "✓ synced: $f"
    changed=$((changed + 1))
  else
    echo "  unchanged: $f"
  fi
done

if [[ $changed -gt 0 ]]; then
  echo ""
  echo "📦 $changed file(s) updated. Don't forget:"
  echo "   1. git add $DST_DIR"
  echo "   2. Update brand-*.preview.html if template content changed"
  echo "   3. Deploy Edge Function:"
  echo "      supabase functions deploy notify-brand-application --project-ref <ref>"
else
  echo ""
  echo "✓ all templates already in sync."
fi
