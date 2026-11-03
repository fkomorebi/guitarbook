#!/usr/bin/env bash
# 以低延迟参数启动 Chrome 打开网页端效果器。
#
# 用法：
#   bash tool/web_low_latency.sh                 # 打开 build/web
#   bash tool/web_low_latency.sh <url>           # 打开指定地址
#
# 说明：
#   --audio-buffer-size=128 让 Chrome 音频服务的缓冲降到 128 帧，
#   本机 Scarlett 环回实测约省 27 ms（输出播放缓冲 3×512 帧 → 3×128 帧）。
#   Linux 上采集侧缓冲由 PipeWire 决定，用
#   `pw-metadata -n settings 0 clock.quantum 128` 调小（需要重启应用生效）。
#   两项都不是网页内能改的，必须在浏览器/系统侧设置。
set -euo pipefail

cd "$(dirname "$0")/.."
URL="${1:-http://localhost:8080}"

if [ ! -d build/web ]; then
  echo "build/web 不存在，先执行：flutter build web --release" >&2
  exit 1
fi

CHROME="${CHROME_BIN:-}"
if [ -z "$CHROME" ]; then
  for candidate in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge; do
    if command -v "$candidate" >/dev/null 2>&1; then
      CHROME="$candidate"
      break
    fi
  done
fi
if [ -z "$CHROME" ]; then
  echo "找不到 Chrome/Chromium，可用 CHROME_BIN 指定路径" >&2
  exit 1
fi

# 不加 --user-data-dir 时 Chrome 会复用已有实例，新参数不会生效，所以用独立 profile。
PROFILE="${TMPDIR:-/tmp}/guitarbook-low-latency-profile"
mkdir -p "$PROFILE"

echo "启动：$CHROME --audio-buffer-size=128 $URL"
echo "（独立 profile：$PROFILE，退出后可直接删除）"
exec "$CHROME" \
  --audio-buffer-size=128 \
  --autoplay-policy=no-user-gesture-required \
  --user-data-dir="$PROFILE" \
  "$URL"
