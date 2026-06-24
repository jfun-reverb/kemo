#!/bin/bash
# ══════════════════════════════════════════════════════
# REVERB JP — iOS 앱 자산 동기화
# 빌드된 인플루언서 앱(루트 index.html)을 ios-app/www 로 복사하고
# iOS 테마 CSS 주입 + 앱에 불필요한 웹 전용 스크립트 제거.
# 사용법: cd ios-app && bash sync-ios.sh
# ══════════════════════════════════════════════════════
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

ROOT_INDEX="../index.html"
WWW_INDEX="www/index.html"

if [ ! -f "$ROOT_INDEX" ]; then
  echo "❌ $ROOT_INDEX 가 없습니다. 먼저 'cd dev && bash build.sh' 실행하세요."
  exit 1
fi

cp "$ROOT_INDEX" "$WWW_INDEX"

python3 - "$WWW_INDEX" <<'PY'
import sys, re
p = sys.argv[1]
h = open(p, encoding='utf-8').read()
# 1) Vercel 웹 분석 스크립트 제거 (앱 번들에선 404 — 불필요)
h = re.sub(r'\s*<script defer src="/_vercel/[^"]+"></script>', '', h)
# 2) iOS 테마 CSS 주입 (인라인 <style> 뒤에 와서 오버라이드, 중복 방지)
#    ⚠️ 검사는 반드시 정확한 <link> 태그로 — 'ios-theme.css' 문자열이 빌드된 CSS 주석 등에
#       섞여 있으면 주입을 건너뛰어 테마가 통째로 누락됨(2026-06-23 사고).
if '<link rel="stylesheet" href="ios-theme.css">' not in h:
    h = h.replace('</head>', '  <link rel="stylesheet" href="ios-theme.css">\n</head>', 1)
# 3) 네이티브 푸시 스크립트 주입 (body 끝 — storage.js 등 전역 함수 로드 후 실행)
if '<script src="native-push.js"></script>' not in h:
    h = h.replace('</body>', '  <script src="native-push.js"></script>\n</body>', 1)
open(p, 'w', encoding='utf-8').write(h)
print("  ✅ Vercel 분석 제거 + iOS 테마 + 네이티브 푸시 주입")
PY

echo "📦 www/index.html 동기화 완료"
