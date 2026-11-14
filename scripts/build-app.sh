#!/bin/bash
# 构建 TinyClash.app：编译 Swift、下载 mihomo 内核、打包并 ad-hoc 签名
#   ./scripts/build-app.sh                 # 使用 dependencies.conf 配置的版本
#   MIHOMO_VERSION=v1.19.34 ./scripts/build-app.sh
#   MIHOMO_BIN=/path/to/mihomo ./scripts/build-app.sh   # 使用本地内核
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/dependencies.conf"
APP="$ROOT/build/TinyClash.app"
VENDOR="$ROOT/vendor"
VERSION="${VERSION:-1.0.0}"
ARCH="${TARGET_ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64) CORE_ARCH="darwin-arm64" ;;
  x86_64) CORE_ARCH="darwin-amd64-v3" ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

cd "$ROOT"
PREVIEW_BUILD="${TINYCLASH_PREVIEW:-0}"
ARCH_FLAGS=(--arch "$ARCH")
if [[ "$PREVIEW_BUILD" == "1" ]]; then
  echo "==> 编译 Swift ($ARCH, preview)"
  swift build -c debug "${ARCH_FLAGS[@]}" -Xswiftc -D -Xswiftc TINYCLASH_PREVIEW
  BIN="$(swift build -c debug "${ARCH_FLAGS[@]}" --show-bin-path -Xswiftc -D -Xswiftc TINYCLASH_PREVIEW)/TinyClash"
else
  echo "==> 编译 Swift ($ARCH, release)"
  swift build -c release "${ARCH_FLAGS[@]}"
  BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/TinyClash"
fi


echo "==> 准备 mihomo 内核 ($MIHOMO_VERSION)"
mkdir -p "$VENDOR"
if [[ -n "${MIHOMO_BIN:-}" ]]; then
  CORE="$MIHOMO_BIN"
else
  CORE="$VENDOR/mihomo-$CORE_ARCH-$MIHOMO_VERSION"
  if [[ ! -x "$CORE" ]]; then
    URL="https://github.com/MetaCubeX/mihomo/releases/download/$MIHOMO_VERSION/mihomo-$CORE_ARCH-$MIHOMO_VERSION.gz"
    echo "    下载 $URL"
    curl -fSL --retry 3 -o "$CORE.gz" "$URL"
    gunzip -f "$CORE.gz"
    chmod +x "$CORE"
  fi
fi
if [[ "$ARCH" == "$(uname -m)" ]]; then
  "$CORE" -v
else
  file "$CORE"
fi

echo "==> 准备 Geo 数据库 ($GEO_VERSION)"
# 优先复用 vendor 缓存；latest 和固定提交都只下载缺失或为空的文件。
GEO_DIR="$VENDOR/geo/$GEO_VERSION"
if [[ "$GEO_VERSION" == "latest" ]]; then
  GEO_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest"
else
  GEO_URL="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/$GEO_VERSION"
fi
mkdir -p "$GEO_DIR"
for f in geoip.metadb geosite.dat geoip.dat; do
  if [[ ! -s "$GEO_DIR/$f" ]]; then
    echo "    下载 $f"
    curl -fSL --retry 3 -o "$GEO_DIR/$f.tmp" "$GEO_URL/$f"
    mv "$GEO_DIR/$f.tmp" "$GEO_DIR/$f"
  else
    echo "    使用缓存 $f"
  fi
done

echo "==> 准备 Web 面板 (metacubexd $METACUBEXD_VERSION)"
UI_DIR="$VENDOR/ui/$METACUBEXD_VERSION"
if [[ ! -s "$UI_DIR/index.html" ]]; then
  mkdir -p "$VENDOR/ui"
  UI_WORK="$(mktemp -d "$VENDOR/ui/.download.XXXXXX")"
  UI_TGZ="$UI_WORK/compressed-dist.tgz"
  UI_TMP="$UI_WORK/dist"
  mkdir -p "$UI_TMP"
  UI_URL="https://github.com/MetaCubeX/metacubexd/releases/download/$METACUBEXD_VERSION/compressed-dist.tgz"
  echo "    下载 $UI_URL"
  if curl -fSL --retry 3 -o "$UI_TGZ" "$UI_URL" && tar -xzf "$UI_TGZ" -C "$UI_TMP"; then
    if [[ -s "$UI_TMP/index.html" ]]; then
      rm -rf "$UI_DIR"
      mv "$UI_TMP" "$UI_DIR"
    else
      echo "    警告: metacubexd 压缩包结构异常，跳过内置 Web 面板"
    fi
  else
    echo "    警告: 无法准备 metacubexd，Web 面板将回退到在线版本"
  fi
  rm -rf "$UI_WORK"
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
ACTOOL_PLIST="$ROOT/build/actool-partial-info.plist"
XCODE_MAJOR="$(xcodebuild -version 2>/dev/null | awk '/^Xcode /{split($2,a,"."); print a[1]}' || echo 0)"
if [[ "${XCODE_MAJOR:-0}" -ge 26 && -d "$ROOT/Resources/AppIcon.icon" ]]; then
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
else
  xcrun actool \
    --compile "$APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$ACTOOL_PLIST" \
    --errors --warnings --notices \
    --output-format human-readable-text \
    "$ROOT/Resources/Assets.xcassets"
  [[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TinyClash</string>
    <key>CFBundleDisplayName</key><string>TinyClash</string>
    <key>CFBundleIdentifier</key><string>com.lingmacker.tinyclash</string>
    <key>CFBundleExecutable</key><string>TinyClash</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.lingmacker.tinyclash.install-config</string>
            <key>CFBundleURLSchemes</key><array><string>clash</string><string>mihomo</string><string>clash-meta</string></array>
        </dict>
    </array>
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
