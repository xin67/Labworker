#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Labworker macOS DMG 打包与校验脚本
# 用法:
#   bash Scripts/package_dmg.sh [--skip-build] [output_dmg_path]
# ==============================================================================

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

SKIP_BUILD=0
CUSTOM_OUT=""

for arg in "$@"; do
    case "$arg" in
        --skip-build)
            SKIP_BUILD=1
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
echo "✅ DMG packaged successfully:"
echo "   Path:   $OUT_DMG"
echo "   Size:   $SIZE_BYTES bytes"
echo "   SHA256: $SHA256"
