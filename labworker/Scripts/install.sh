#!/usr/bin/env bash
set -euo pipefail

# Labworker 一键安装脚本（免 Apple 开发者账号公证，自动校验 SHA-256 与 ad-hoc 签名并清除 Gatekeeper 隔离属性）
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/xin67/Labworker/main/labworker/Scripts/install.sh | bash
#   bash install.sh --local-dmg /path/to/Labworker-20261120.dmg

REPO="xin67/Labworker"
TAG=""
LOCAL_DMG=""
DEST_DIR="/Applications"
DRY_RUN=0

usage() {
    cat <<'EOF'
Labworker macOS Installer (Zero-Cost Ad-Hoc Gatekeeper Bypass)

Options:
  --repo <owner/repo>    GitHub repository (default: xin67/Labworker)
  --tag <tag>            Release tag to install, e.g. v20261120 (default: latest release)
  --local-dmg <path>     Install from a local .dmg file instead of downloading
  --dest <dir>           Destination Applications directory (default: /Applications)
  --dry-run              Resolve paths/URLs and validate arguments without modifying /Applications
  -h, --help             Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO="${2:?Missing value for --repo}"
            shift 2
            ;;
        --tag)
            TAG="${2:?Missing value for --tag}"
            shift 2
            ;;
        --local-dmg)
            LOCAL_DMG="${2:?Missing value for --local-dmg}"
            shift 2
            ;;
        --dest)
            DEST_DIR="${2:?Missing value for --dest}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "❌ Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "❌ Labworker only supports macOS (detected: $(uname -s))." >&2
    exit 1
fi

MACOS_MAJOR="$(sw_vers -productVersion | awk -F. '{print $1}')"
if [[ -n "$MACOS_MAJOR" && "$MACOS_MAJOR" -lt 14 ]]; then
    echo "❌ Labworker requires macOS 14.0 (Sonoma) or newer (detected: $(sw_vers -productVersion))." >&2
    exit 1
fi

TMP_ROOT="$(mktemp -d /tmp/labworker_install.XXXXXX)"
MOUNT_DIR=""

cleanup() {
    if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
        hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet || true
    fi
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

DMG_PATH=""
SHA_PATH=""

if [[ -n "$LOCAL_DMG" ]]; then
    if [[ ! -f "$LOCAL_DMG" ]]; then
        echo "❌ Local DMG not found: $LOCAL_DMG" >&2
        exit 1
    fi
    DMG_PATH="$(cd "$(dirname "$LOCAL_DMG")" && pwd)/$(basename "$LOCAL_DMG")"
    if [[ -f "${DMG_PATH}.sha256" ]]; then
        SHA_PATH="${DMG_PATH}.sha256"
    fi
else
    if [[ -z "$TAG" ]]; then
        API_URL="https://api.github.com/repos/${REPO}/releases/latest"
        echo "🔍 Querying latest Labworker release from ${REPO}..."
        TAG="$(curl -fsSL "$API_URL" | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data.get("tag_name", ""))
' 2>/dev/null || true)"
        if [[ -z "$TAG" ]]; then
            TAG="v20261120"
            echo "⚠️  Could not query latest tag from GitHub API; falling back to ${TAG}."
        fi
    fi

    VERSION_CLEAN="${TAG#v}"
    DMG_NAME="Labworker-${VERSION_CLEAN}.dmg"
    DMG_URL="https://github.com/${REPO}/releases/download/${TAG}/${DMG_NAME}"
    SHA_URL="${DMG_URL}.sha256"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "🔎 Dry-run resolved:"
        echo "   Repo: $REPO"
        echo "   Tag:  $TAG"
        echo "   URL:  $DMG_URL"
        echo "   Dest: ${DEST_DIR}/Labworker.app"
        exit 0
    fi

    DMG_PATH="${TMP_ROOT}/${DMG_NAME}"
    echo "⬇️  Downloading ${DMG_NAME} from ${TAG}..."
    curl -fL --progress-bar "$DMG_URL" -o "$DMG_PATH"

    if curl -fsSL "$SHA_URL" -o "${TMP_ROOT}/${DMG_NAME}.sha256" 2>/dev/null; then
        SHA_PATH="${TMP_ROOT}/${DMG_NAME}.sha256"
    fi
fi

if [[ -n "$SHA_PATH" ]]; then
    EXPECTED_SHA="$(awk '{print $1}' "$SHA_PATH" | head -n 1)"
    ACTUAL_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
    if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
        echo "❌ SHA-256 mismatch!" >&2
        echo "   Expected: $EXPECTED_SHA" >&2
        echo "   Actual:   $ACTUAL_SHA" >&2
        exit 1
    fi
    echo "✅ SHA-256 verified: $ACTUAL_SHA"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "🔎 Dry-run local DMG verified: $DMG_PATH -> ${DEST_DIR}/Labworker.app"
    exit 0
fi

MOUNT_DIR="${TMP_ROOT}/mount"
mkdir -p "$MOUNT_DIR"
echo "💿 Mounting $(basename "$DMG_PATH")..."
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" >/dev/null

SOURCE_APP="${MOUNT_DIR}/Labworker.app"
if [[ ! -d "$SOURCE_APP" ]]; then
    echo "❌ Labworker.app was not found inside DMG at ${MOUNT_DIR}" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"
TARGET_APP="${DEST_DIR%/}/Labworker.app"

if [[ -e "$TARGET_APP" && ! -w "$DEST_DIR" ]]; then
    echo "❌ Insufficient permission to overwrite ${TARGET_APP}. Re-run with sudo or pass --dest \"$HOME/Applications\"." >&2
    exit 1
fi

echo "📦 Installing Labworker.app to ${TARGET_APP}..."
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"

echo "🔓 Clearing macOS Gatekeeper quarantine attributes (com.apple.quarantine)..."
/usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true

echo "🔏 Verifying bundled code signature..."
/usr/bin/codesign --verify --deep --strict "$TARGET_APP"

echo ""
echo "✅ Labworker installed successfully at: ${TARGET_APP}"
echo "🚀 Launch with: open -a \"${TARGET_APP}\""
