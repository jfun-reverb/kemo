#!/bin/bash
# ══════════════════════════════════════════════════════════════════
# 로컬 미리보기 — 수정 → 빌드 → 새로고침 빠른 반복용
# ══════════════════════════════════════════════════════════════════
# 사용법:
#   cd dev && bash preview.sh
#
# 동작:
#   1. build.sh 실행 (dev/ → 루트 산출물)
#   2. python3 http 서버 기동 (포트 8000)
#   3. 브라우저로 /admin/ 자동 오픈
#   4. 이후 코드 수정 시 dev 디렉토리에서 `bash build.sh` 한 번 돌리고
#      브라우저 새로고침 (Cmd+Shift+R) 하면 즉시 반영
#
# 환경 분기: localhost 는 globalreverb.com 패턴 미매칭 → 개발서버
#            (qysmxtipobomefudyixw Supabase) 로 자동 연결
# ══════════════════════════════════════════════════════════════════

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PORT="${PORT:-8000}"

# 1) 빌드
bash build.sh

# 2) 프로젝트 루트로 이동 (루트에 index.html, admin/, sales/ 가 있음)
cd "$(dirname "$SCRIPT_DIR")"

# 3) 포트 이미 사용 중인지 확인
if lsof -i :$PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "⚠️  포트 $PORT 이미 사용 중. PORT=8001 bash preview.sh 로 다른 포트 지정하세요."
  exit 1
fi

# 4) 안내
echo ""
echo "🌐 Local preview ready — port $PORT"
echo ""
echo "   관리자:          http://localhost:$PORT/admin/"
echo "   인플루언서:      http://localhost:$PORT/"
echo "   광고주 랜딩:     http://localhost:$PORT/sales/"
echo "   광고주 리뷰어:   http://localhost:$PORT/sales/reviewer.html"
echo "   광고주 시딩:     http://localhost:$PORT/sales/seeding.html"
echo ""
echo "   Supabase 연결:   개발(staging) DB — qysmxtipobomefudyixw"
echo ""
echo "   🔁 코드 수정 후:  cd dev && bash build.sh  → 브라우저 Cmd+Shift+R"
echo "   🛑 Ctrl+C 로 종료"
echo ""

# 5) 브라우저 자동 오픈 (macOS)
if command -v open >/dev/null 2>&1; then
  (sleep 1 && open "http://localhost:$PORT/admin/") &
fi

# 6) HTTP 서버 기동 (Python 3)
python3 -m http.server "$PORT"
