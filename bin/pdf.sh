#!/usr/bin/env bash
# viewer/print.html(全スライドを 1 ページずつ並べた印刷ビュー)をヘッドレス
# Chrome で印刷し、PDF を書き出す。`make pdf` から呼ばれる。
#
# 環境変数で上書き可:
#   PDF       出力ファイル(既定 kotoyomi.pdf)
#   PDF_PORT  ローカルサーバのポート(既定 8123)
#   CHROME    Chrome 実行ファイル(既定 macOS の Google Chrome)
#   PDF_WAIT  Chrome の virtual-time-budget(ms、既定 10000)
set -euo pipefail

PORT="${PDF_PORT:-8123}"
OUT="${PDF:-kotoyomi.pdf}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
WAIT="${PDF_WAIT:-10000}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -x "$CHROME" ]; then
  echo "pdf: Chrome が見つかりません: $CHROME" >&2
  echo "pdf: CHROME=/path/to/chrome make pdf のように指定してください。" >&2
  exit 1
fi

# 静的サーバを起動し、終了時に必ず止める。配信ルートはプロジェクトの public/
# (kotoyomi build 済み。make pdf から PDF_ROOT で渡る)。
SERVE_DIR="${PDF_ROOT:-examples/public}"
bundle exec wsv -p "$PORT" "$SERVE_DIR" >/dev/null 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null || true' EXIT

URL="http://127.0.0.1:${PORT}/viewer/print.html"

# サーバが応答するまで待つ。
for _ in $(seq 1 50); do
  if curl -sf "$URL" >/dev/null 2>&1; then break; fi
  sleep 0.2
done

# wasm 起動 + 詩の読み込みが終わるよう virtual-time-budget で時間を進めて印刷。
"$CHROME" --headless --disable-gpu --no-pdf-header-footer \
  --virtual-time-budget="$WAIT" \
  --print-to-pdf="${ROOT}/${OUT}" "$URL"

echo "pdf: wrote ${OUT}"
