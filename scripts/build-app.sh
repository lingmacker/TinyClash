#!/bin/bash
# 构建 TinyClash.app：编译 Swift、下载 mihomo 内核、打包并 ad-hoc 签名
#   ./scripts/build-app.sh                 # 使用最新版 mihomo
#   MIHOMO_VERSION=v1.19.34 ./scripts/build-app.sh
#   MIHOMO_BIN=/path/to/mihomo ./scripts/build-app.sh   # 使用本地内核
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/TinyClash.app"
CACHE="$ROOT/build/cache"
VERSION="1.0.0"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) CORE_ARCH="darwin-arm64" ;;
  x86_64) CORE_ARCH="darwin-amd64-v3" ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

echo "==> 编译 Swift (release)"
cd "$ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/TinyClash"

echo "==> 准备 mihomo 内核"
mkdir -p "$CACHE"
if [[ -n "${MIHOMO_BIN:-}" ]]; then
  CORE="$MIHOMO_BIN"
else
  if [[ -z "${MIHOMO_VERSION:-}" ]]; then
    # API 容易被限流，改用 releases/latest 的跳转地址解析版本号
    MIHOMO_VERSION="$(curl -sSI https://github.com/MetaCubeX/mihomo/releases/latest | awk -F/ 'tolower($1) ~ /^location:/ {print $NF}' | tr -d '\r')"
  fi
  [[ -n "$MIHOMO_VERSION" ]] || { echo "无法获取 mihomo 版本号，请设置 MIHOMO_VERSION"; exit 1; }
  CORE="$CACHE/mihomo-$CORE_ARCH-$MIHOMO_VERSION"
  if [[ ! -x "$CORE" ]]; then
    URL="https://github.com/MetaCubeX/mihomo/releases/download/$MIHOMO_VERSION/mihomo-$CORE_ARCH-$MIHOMO_VERSION.gz"
    echo "    下载 $URL"
    curl -fSL --retry 3 -o "$CORE.gz" "$URL"
    gunzip -f "$CORE.gz"
    chmod +x "$CORE"
  fi
fi
"$CORE" -v

echo "==> 准备 Geo 数据库"
# 内置 Geo 数据库，避免首次启动 / 校验配置时直连 GitHub 下载失败
GEO_DIR="$CACHE/geo"
mkdir -p "$GEO_DIR"
for f in geoip.metadb geosite.dat geoip.dat; do
  if [[ ! -s "$GEO_DIR/$f" ]]; then
    echo "    下载 $f"
    curl -fSL --retry 3 -o "$GEO_DIR/$f.tmp" "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/$f"
    mv "$GEO_DIR/$f.tmp" "$GEO_DIR/$f"
  fi
done

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TinyClash"
cp "$CORE" "$APP/Contents/Resources/mihomo"
chmod +x "$APP/Contents/Resources/mihomo"
cp -R "$GEO_DIR" "$APP/Contents/Resources/geo"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TinyClash</string>
    <key>CFBundleDisplayName</key><string>TinyClash</string>
    <key>CFBundleIdentifier</key><string>com.tinyclash.app</string>
    <key>CFBundleExecutable</key><string>TinyClash</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>用于请求管理员权限以启用 TUN 模式和修改网络设置。</string>
</dict>
</plist>
EOF

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP/Contents/Resources/mihomo"
codesign --force --sign - "$APP"

echo "完成: $APP"
