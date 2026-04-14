#!/bin/bash
# ══════════════════════════════════════
# REVERB JP — 빌드 스크립트
# Client (index.html) + Admin (admin/index.html) 각각 빌드
# 사용법: cd dev && bash build.sh
# ══════════════════════════════════════

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="v$(date +%s)"

echo "🔨 REVERB JP 빌드 시작..."

# ══════════════════════════════════════
# 1. CLIENT 빌드 → ../index.html
# ══════════════════════════════════════
CLIENT_CSS_FILES=("css/base.css" "css/components.css" "css/campaign.css" "css/auth.css" "css/mypage.css")
CLIENT_JS_FILES=("lib/supabase.js" "lib/shared.js" "lib/i18n/ja.js" "lib/i18n/ko.js" "lib/i18n/index.js" "lib/storage.js" "lib/legal.js" "js/ui.js" "js/campaign.js" "js/auth.js" "js/application.js" "js/mypage.js" "js/app.js")

CLIENT_CSS=""
for f in "${CLIENT_CSS_FILES[@]}"; do
  if [ -f "$f" ]; then CLIENT_CSS+="$(cat "$f")"$'\n'
  else echo "⚠️  $f 파일을 찾을 수 없습니다"; fi
done

CLIENT_JS=""
for f in "${CLIENT_JS_FILES[@]}"; do
  if [ -f "$f" ]; then CLIENT_JS+="$(cat "$f")"$'\n'
  else echo "⚠️  $f 파일을 찾을 수 없습니다"; fi
done

python3 - "../index.html" "$CLIENT_CSS" "$CLIENT_JS" "$VERSION" "index.html" << 'PYTHON_SCRIPT'
import sys, re
output_path = sys.argv[1]
all_css = sys.argv[2]
all_js = sys.argv[3]
version = sys.argv[4]
src_html = sys.argv[5]

with open(src_html, "r", encoding="utf-8") as f:
    html = f.read()

html = re.sub(r'<link\s+rel="stylesheet"\s+href="css/[^"]+"\s*/?>\n?', '', html)
html = re.sub(r'<script\s+src="(?:lib|js)/[^"]+"\s*></script>\n?', '', html)
version_comment = f"<!-- {version} -->"
style_block = f"<style>\n{all_css}</style>\n"
html = html.replace("</head>", f"{style_block}</head>", 1)
script_block = f"\n<script>\n{all_js}</script>\n"
html = html.replace("</body>", f"{script_block}</body>", 1)
html = re.sub(r'<!-- v\d+ -->', version_comment, html, count=1)

with open(output_path, "w", encoding="utf-8") as f:
    f.write(html)

print(f"  ✅ Client 빌드 완료 → {output_path}")
PYTHON_SCRIPT

# ══════════════════════════════════════
# 2. ADMIN 빌드 → ../admin/index.html
# ══════════════════════════════════════
mkdir -p ../admin

ADMIN_CSS_FILES=("css/base.css" "css/components.css" "css/admin.css")
ADMIN_JS_FILES=("lib/supabase.js" "lib/shared.js" "lib/storage.js" "js/ui.js" "js/admin.js" "admin/app.js")

ADMIN_CSS=""
for f in "${ADMIN_CSS_FILES[@]}"; do
  if [ -f "$f" ]; then ADMIN_CSS+="$(cat "$f")"$'\n'
  else echo "⚠️  $f 파일을 찾을 수 없습니다"; fi
done

ADMIN_JS=""
for f in "${ADMIN_JS_FILES[@]}"; do
  if [ -f "$f" ]; then ADMIN_JS+="$(cat "$f")"$'\n'
  else echo "⚠️  $f 파일을 찾을 수 없습니다"; fi
done

python3 - "../admin/index.html" "$ADMIN_CSS" "$ADMIN_JS" "$VERSION" "admin/index.html" << 'PYTHON_SCRIPT'
import sys, re
output_path = sys.argv[1]
all_css = sys.argv[2]
all_js = sys.argv[3]
version = sys.argv[4]
src_html = sys.argv[5]

with open(src_html, "r", encoding="utf-8") as f:
    html = f.read()

# admin HTML의 CSS/JS 링크 제거 (../css/, ../js/, ../lib/ 경로)
html = re.sub(r'<link\s+rel="stylesheet"\s+href="\.\./css/[^"]+"\s*/?>\n?', '', html)
html = re.sub(r'<script\s+src="(?:\.\./lib|\.\./js|)[^"]*(?:supabase|shared|storage|ui|admin|app)\.js"\s*></script>\n?', '', html)

version_comment = f"<!-- {version} -->"
style_block = f"<style>\n{all_css}</style>\n"
html = html.replace("</head>", f"{style_block}</head>", 1)
script_block = f"\n<script>\n{all_js}</script>\n"
html = html.replace("</body>", f"{script_block}</body>", 1)

with open(output_path, "w", encoding="utf-8") as f:
    f.write(html)

print(f"  ✅ Admin 빌드 완료 → {output_path}")
PYTHON_SCRIPT

echo "📦 빌드 완료 ($VERSION)"
