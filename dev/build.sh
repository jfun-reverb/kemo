#!/bin/bash
# ══════════════════════════════════════
# REVERB JP — 빌드 스크립트
# dev/ 폴더의 파일들을 하나의 index.html로 합침
# 사용법: cd dev && bash build.sh
# ══════════════════════════════════════

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

OUTPUT="../index.html"
VERSION="v$(date +%s)"

echo "🔨 REVERB JP 빌드 시작..."

# CSS 파일 합치기
CSS_FILES=(
  "css/base.css"
  "css/components.css"
  "css/campaign.css"
  "css/auth.css"
  "css/mypage.css"
  "css/admin.css"
)

ALL_CSS=""
for f in "${CSS_FILES[@]}"; do
  if [ -f "$f" ]; then
    ALL_CSS+="$(cat "$f")"$'\n'
  else
    echo "⚠️  $f 파일을 찾을 수 없습니다"
  fi
done

# JS 파일 합치기
JS_FILES=(
  "lib/supabase.js"
  "lib/storage.js"
  "js/ui.js"
  "js/campaign.js"
  "js/auth.js"
  "js/application.js"
  "js/mypage.js"
  "js/admin.js"
  "js/app.js"
)

ALL_JS=""
for f in "${JS_FILES[@]}"; do
  if [ -f "$f" ]; then
    ALL_JS+="$(cat "$f")"$'\n'
  else
    echo "⚠️  $f 파일을 찾을 수 없습니다"
  fi
done

# index.html에서 CSS/JS 외부 링크를 제거하고 인라인으로 삽입
# </head> 앞에 <style> 삽입
# </body> 앞에 <script> 삽입

python3 - "$OUTPUT" "$ALL_CSS" "$ALL_JS" "$VERSION" << 'PYTHON_SCRIPT'
import sys, re

output_path = sys.argv[1]
all_css = sys.argv[2]
all_js = sys.argv[3]
version = sys.argv[4]

with open("index.html", "r", encoding="utf-8") as f:
    html = f.read()

# 외부 CSS 링크 삭제
html = re.sub(r'<link\s+rel="stylesheet"\s+href="css/[^"]+"\s*/?>\n?', '', html)

# 외부 JS 스크립트 삭제
html = re.sub(r'<script\s+src="(?:lib|js)/[^"]+"\s*></script>\n?', '', html)

# 버전 주석 삽입
version_comment = f"<!-- {version} -->"

# </head> 앞에 <style> 블록 삽입
style_block = f"<style>\n{all_css}</style>\n"
html = html.replace("</head>", f"{style_block}</head>", 1)

# </body> 앞에 <script> 블록 삽입
script_block = f"\n<script>\n{all_js}</script>\n"
html = html.replace("</body>", f"{script_block}</body>", 1)

# 버전 업데이트
html = re.sub(r'<!-- v\d+ -->', version_comment, html, count=1)

with open(output_path, "w", encoding="utf-8") as f:
    f.write(html)

print(f"✅ 빌드 완료 → {output_path}")
PYTHON_SCRIPT

echo "📦 $OUTPUT 업데이트 완료 ($VERSION)"
