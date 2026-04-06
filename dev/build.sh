#!/bin/bash
# ══════════════════════════════════════
# REVERB JP — ビルドスクリプト
# dev/ のファイルを1つの index.html に結合
# 使い方: cd dev && bash build.sh
# ══════════════════════════════════════

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

OUTPUT="../index.html"
VERSION="v$(date +%s)"

echo "🔨 REVERB JP ビルド開始..."

# CSS ファイルを結合
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
    echo "⚠️  $f が見つかりません"
  fi
done

# JS ファイルを結合
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
    echo "⚠️  $f が見つかりません"
  fi
done

# index.html から CSS/JS リンクを除去し、インラインに変換
# head の closing </head> の前に <style> を挿入
# body の closing </body> の前に <script> を挿入

python3 - "$OUTPUT" "$ALL_CSS" "$ALL_JS" "$VERSION" << 'PYTHON_SCRIPT'
import sys, re

output_path = sys.argv[1]
all_css = sys.argv[2]
all_js = sys.argv[3]
version = sys.argv[4]

with open("index.html", "r", encoding="utf-8") as f:
    html = f.read()

# 外部 CSS リンクを削除
html = re.sub(r'<link\s+rel="stylesheet"\s+href="css/[^"]+"\s*/?>\n?', '', html)

# 外部 JS スクリプトを削除
html = re.sub(r'<script\s+src="(?:lib|js)/[^"]+"\s*></script>\n?', '', html)

# バージョンコメント挿入
version_comment = f"<!-- {version} -->"

# </head> の前に <style> ブロックを挿入
style_block = f"<style>\n{all_css}</style>\n"
html = html.replace("</head>", f"{style_block}</head>", 1)

# </body> の前に <script> ブロックを挿入
script_block = f"\n<script>\n{all_js}</script>\n"
html = html.replace("</body>", f"{script_block}</body>", 1)

# バージョン更新
html = re.sub(r'<!-- v\d+ -->', version_comment, html, count=1)

with open(output_path, "w", encoding="utf-8") as f:
    f.write(html)

print(f"✅ ビルド完了 → {output_path}")
PYTHON_SCRIPT

echo "📦 $OUTPUT を更新しました ($VERSION)"
