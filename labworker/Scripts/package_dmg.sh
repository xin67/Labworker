#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Labworker macOS DMG 打包与校验脚本
# 用法:
#   bash Scripts/package_dmg.sh [--skip-build] [--update-cask] [output_dmg_path]
# ==============================================================================

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

SKIP_BUILD=0
UPDATE_CASK=0
CUSTOM_OUT=""

for arg in "$@"; do
    case "$arg" in
        --skip-build)
            SKIP_BUILD=1
            ;;
        --update-cask)
            UPDATE_CASK=1
            ;;
        *)
            CUSTOM_OUT="$arg"
            ;;
    esac
done

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    bash "$DIR/Scripts/build_app.sh"
fi

APP_DIR="$DIR/Labworker.app"
if [[ ! -d "$APP_DIR" ]]; then
    echo "❌ Error: $APP_DIR not found." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIR/Contents/Info.plist")"
BUILD_VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_DIR/Contents/Info.plist")"
GIT_COMMIT="$(/usr/libexec/PlistBuddy -c "Print :LWGitCommit" "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo "unknown")"

codesign --verify --deep --strict "$APP_DIR"

OUT_DMG="${CUSTOM_OUT:-$DIR/Labworker-${VERSION}.dmg}"
mkdir -p "$(dirname "$OUT_DMG")"

STAGING_DIR="$(mktemp -d /tmp/labworker_dmg.XXXXXX)"
cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

echo "📦 Staging Labworker.app ($VERSION / build $BUILD_VER / commit $GIT_COMMIT) into $STAGING_DIR..."
ditto "$APP_DIR" "$STAGING_DIR/Labworker.app"
ln -s /Applications "$STAGING_DIR/Applications"

cat > "$STAGING_DIR/首次打开说明.txt" <<'EOF'
Labworker 首次打开指南 (Gatekeeper 说明 / First-Launch Guide)
================================================================

为什么首次从网页下载并打开时，macOS 会提示“无法验证开发者”或“已损坏”？
------------------------------------------------------------------------
Labworker 是免费开源软件，采用本地 ad-hoc 签名发布，未购买 Apple 付费开发者账号
（$99/年）进行商业公证（Notarization）。macOS 默认会为浏览器下载的文件附加
`com.apple.quarantine` 隔离属性，从而触发 Gatekeeper 拦截。

推荐打开方式（任选其一）：
1. 【一键工具（最简单）】
   先将 Labworker.app 拖入左侧 Applications（应用程序）文件夹，
   然后右键点击 DMG 内的「一键修复首次无法打开.command」-> 打开，按提示回车即可。

2. 【系统设置放行】
   双击 Applications 中的 Labworker.app 后若出现拦截弹窗，点「完成 / 好」，
   随后打开「系统设置 -> 隐私与安全性」，拉到底部点击「仍要打开」并输入开机密码。

3. 【终端命令行（推荐极客用户）】
   拖拽至 /Applications 后运行：
   xattr -dr com.apple.quarantine /Applications/Labworker.app

4. 【Homebrew Cask 或一键脚本免拦截安装】
   curl -fsSL https://raw.githubusercontent.com/xin67/Labworker/main/labworker/Scripts/install.sh | bash

------------------------------------------------------------------------
Why macOS Gatekeeper may warn on first launch:
Labworker is open-source and ad-hoc signed without a paid Apple Developer ID.
After dragging Labworker.app to /Applications, either double-click
"一键修复首次无法打开.command" or run:
  xattr -dr com.apple.quarantine /Applications/Labworker.app
EOF

cat > "$STAGING_DIR/一键修复首次无法打开.command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "🔬 Labworker Gatekeeper 首次打开修复工具"
echo "========================================"

TARGET_APP=""
if [[ -d "/Applications/Labworker.app" ]]; then
    TARGET_APP="/Applications/Labworker.app"
elif [[ -d "$HOME/Applications/Labworker.app" ]]; then
    TARGET_APP="$HOME/Applications/Labworker.app"
fi

if [[ -z "$TARGET_APP" ]]; then
    echo "⚠️  尚未在 /Applications 或 ~/Applications 中检测到 Labworker.app。"
    echo "请先将 DMG 中的 Labworker.app 拖入 Applications（应用程序）文件夹，然后再运行本脚本。"
    read -r -p "按回车键退出..." _
    exit 1
fi

echo "🔓 正在移除隔离属性 (com.apple.quarantine): $TARGET_APP"
/usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true

echo "🔏 正在校验应用完整性签名..."
/usr/bin/codesign --verify --deep --strict "$TARGET_APP"

echo ""
echo "✅ 修复完成！现在可以正常打开 Labworker。"
read -r -p "是否立即启动 Labworker？[Y/n] " REPLY
if [[ -z "$REPLY" || "$REPLY" =~ ^[Yy]$ ]]; then
    open -a "$TARGET_APP"
fi
EOF
chmod +x "$STAGING_DIR/一键修复首次无法打开.command"

echo "💿 Creating compressed DMG image: $OUT_DMG..."
rm -f "$OUT_DMG"
hdiutil create \
    -volname "Labworker ${VERSION}" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$OUT_DMG"

echo "🔍 Verifying DMG integrity..."
hdiutil verify "$OUT_DMG"

SHA256="$(shasum -a 256 "$OUT_DMG" | awk '{print $1}')"
SIZE_BYTES="$(stat -f%z "$OUT_DMG")"
SHA_FILE="${OUT_DMG}.sha256"
printf "%s  %s\n" "$SHA256" "$(basename "$OUT_DMG")" > "$SHA_FILE"

if [[ "$UPDATE_CASK" -eq 1 ]]; then
    CASK_PATH="$(cd "$DIR/.." && pwd)/Casks/labworker.rb"
    if [[ -f "$CASK_PATH" ]]; then
        /usr/bin/python3 - "$CASK_PATH" "$VERSION" "$SHA256" <<'PYEOF'
import re, sys
path, version, sha = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
text = re.sub(r'(^\s*version\s+)"[^"]+"', rf'\1"{version}"', text, count=1, flags=re.M)
text = re.sub(r'(^\s*sha256\s+)(?::no_check|"[^"]+")', rf'\1"{sha}"', text, count=1, flags=re.M)
open(path, "w", encoding="utf-8").write(text)
print(f"🍺 Updated Cask: {path} (version={version}, sha256={sha[:12]}...)")
PYEOF
    else
        echo "⚠️  --update-cask specified, but $CASK_PATH does not exist." >&2
    fi
fi

echo "✅ DMG packaged successfully:"
echo "   Path:    $OUT_DMG"
echo "   SHAFile: $SHA_FILE"
echo "   Size:    $SIZE_BYTES bytes"
echo "   SHA256:  $SHA256"
