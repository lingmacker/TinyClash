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

cd "$ROOT"
PREVIEW_BUILD="${TINYCLASH_PREVIEW:-0}"
if [[ "$PREVIEW_BUILD" == "1" ]]; then
  echo "==> 编译 Swift (preview)"
  swift build -c debug -Xswiftc -D -Xswiftc TINYCLASH_PREVIEW
  BIN="$(swift build -c debug --show-bin-path -Xswiftc -D -Xswiftc TINYCLASH_PREVIEW)/TinyClash"
else
  echo "==> 编译 Swift (release)"
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/TinyClash"
fi


echo "==> 准备 mihomo 内核"
mkdir -p "$CACHE"
if [[ -n "${MIHOMO_BIN:-}" ]]; then
  CORE="$MIHOMO_BIN"
else
  if [[ -z "${MIHOMO_VERSION:-}" ]]; then
    # API 容易被限流，改用 releases/latest 的跳转地址解析版本号
    MIHOMO_VERSION="$(curl -sSI -m 15 https://github.com/MetaCubeX/mihomo/releases/latest 2>/dev/null | awk -F/ 'tolower($1) ~ /^location:/ {print $NF}' | tr -d '\r' || true)"
    if [[ -z "$MIHOMO_VERSION" ]]; then
      # 连不上 GitHub 时使用已缓存的最新内核
      CACHED="$(ls -t "$CACHE"/mihomo-"$CORE_ARCH"-v* 2>/dev/null | grep -v '\.gz$' | head -1 || true)"
      [[ -n "$CACHED" ]] && MIHOMO_VERSION="${CACHED##*-}" && echo "    无法访问 GitHub，使用缓存内核 $MIHOMO_VERSION"
    fi
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

echo "==> 准备 Web 面板 (metacubexd)"
UI_DIR="$CACHE/ui"
if [[ ! -s "$UI_DIR/index.html" ]]; then
  UI_TGZ="$CACHE/metacubexd.tgz.tmp"
  UI_TMP="$CACHE/ui.tmp"
  rm -rf "$UI_TMP" "$UI_TGZ"
  mkdir -p "$UI_TMP"
  UI_URL="https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"
  echo "    下载 $UI_URL"
  if curl -fSL --retry 3 -o "$UI_TGZ" "$UI_URL"; then
    tar -xzf "$UI_TGZ" -C "$UI_TMP"
    rm -f "$UI_TGZ"
    if [[ -s "$UI_TMP/index.html" ]]; then
      rm -rf "$UI_DIR"
      mv "$UI_TMP" "$UI_DIR"
    else
      echo "    警告: metacubexd 压缩包结构异常，跳过内置 Web 面板"
      rm -rf "$UI_TMP"
    fi
  else
    rm -f "$UI_TGZ"
    rm -rf "$UI_TMP"
    echo "    警告: 无法下载 metacubexd，Web 面板将回退到在线版本"
  fi
fi

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TinyClash"
cp "$CORE" "$APP/Contents/Resources/mihomo"
chmod +x "$APP/Contents/Resources/mihomo"
cp -R "$GEO_DIR" "$APP/Contents/Resources/geo"
[[ -s "$UI_DIR/index.html" ]] && cp -R "$UI_DIR" "$APP/Contents/Resources/ui"

echo "==> 编译图标与资源目录"
ACTOOL_PLIST="$CACHE/actool-partial-info.plist"
xcrun actool \
  --compile "$APP/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$ACTOOL_PLIST" \
  --errors --warnings --notices \
  --output-format human-readable-text \
  "$ROOT/Resources/AppIcon.icon" \
  "$ROOT/Resources/Assets.xcassets"

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
    <key>CFBundleIconName</key><string>AppIcon</string>
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
