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
# 큰 CSS/JS 페이로드는 argv 길이 제한(MAX_ARG_STRLEN)에 걸릴 수 있으므로 임시 파일 경유
BUILD_TMP="$(mktemp -d -t reverb-build-XXXXXX)"
trap 'rm -rf "$BUILD_TMP"' EXIT

echo "🔨 REVERB JP 빌드 시작..."

# ══════════════════════════════════════
# 1. CLIENT 빌드 → ../index.html
# ══════════════════════════════════════
CLIENT_CSS_FILES=("css/base.css" "css/components.css" "css/campaign.css" "css/auth.css" "css/mypage.css")
CLIENT_JS_FILES=("lib/supabase.js" "lib/shared.js" "lib/i18n/ja.js" "lib/i18n/ko.js" "lib/i18n/index.js" "lib/storage.js" "lib/legal.js" "js/ui.js" "js/campaign.js" "js/auth.js" "js/application.js" "js/notifications.js" "js/mypage.js" "js/app.js")

: > "$BUILD_TMP/client.css"
for f in "${CLIENT_CSS_FILES[@]}"; do
  if [ -f "$f" ]; then cat "$f" >> "$BUILD_TMP/client.css"; printf '\n' >> "$BUILD_TMP/client.css"
  else echo "⚠️  $f 파일을 찾을 수 없습니다"; fi
done

: > "$BUILD_TMP/client.js"
for f in "${CLIENT_JS_FILES[@]}"; do
  if [ -f "$f" ]; then cat "$f" >> "$BUILD_TMP/client.js"; printf '\n' >> "$BUILD_TMP/client.js"
  else echo "⚠️  $f 파일을 찾을 수 없습니다"; fi
done

python3 - "../index.html" "$BUILD_TMP/client.css" "$BUILD_TMP/client.js" "$VERSION" "index.html" << 'PYTHON_SCRIPT'
import sys, re
output_path = sys.argv[1]
css_path = sys.argv[2]
js_path = sys.argv[3]
version = sys.argv[4]
src_html = sys.argv[5]

with open(css_path, "r", encoding="utf-8") as f:
    all_css = f.read()
with open(js_path, "r", encoding="utf-8") as f:
    all_js = f.read()

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

: > "$BUILD_TMP/admin.css"
for f in "${ADMIN_CSS_FILES[@]}"; do
  if [ -f "$f" ]; then cat "$f" >> "$BUILD_TMP/admin.css"; printf '\n' >> "$BUILD_TMP/admin.css"
  else echo "⚠️  $f 파일을 찾을 수 없습니다"; fi
done

: > "$BUILD_TMP/admin.js"
for f in "${ADMIN_JS_FILES[@]}"; do
  if [ -f "$f" ]; then cat "$f" >> "$BUILD_TMP/admin.js"; printf '\n' >> "$BUILD_TMP/admin.js"
  else echo "⚠️  $f 파일을 찾을 수 없습니다"; fi
done

python3 - "../admin/index.html" "$BUILD_TMP/admin.css" "$BUILD_TMP/admin.js" "$VERSION" "admin/index.html" << 'PYTHON_SCRIPT'
import sys, re
output_path = sys.argv[1]
css_path = sys.argv[2]
js_path = sys.argv[3]
version = sys.argv[4]
src_html = sys.argv[5]

with open(css_path, "r", encoding="utf-8") as f:
    all_css = f.read()
with open(js_path, "r", encoding="utf-8") as f:
    all_js = f.read()

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

# ══════════════════════════════════════
# 3. SALES 폼 → ../sales/ (self-contained HTML 단순 복사)
#    - 클라이언트/관리자 어디에서도 링크 노출 X (영업팀이 URL 직접 전달)
#    - robots.txt + meta noindex로 검색 차단
# ══════════════════════════════════════
if [ -d "sales" ]; then
  mkdir -p ../sales
  cp sales/*.html ../sales/
  # Vercel cleanUrls 설정 파일도 함께 복사 (reverb-sales 프로젝트가 sales/를 Root로 사용)
  [ -f sales/vercel.json ] && cp sales/vercel.json ../sales/
  # 이미지 디렉토리 (Qoo10 샘플 리뷰 등)
  if [ -d "sales/images" ]; then
    mkdir -p ../sales/images
    cp sales/images/* ../sales/images/
  fi
  echo "  ✅ Sales 폼 복사 완료 → ../sales/"
fi

echo "📦 빌드 완료 ($VERSION)"
