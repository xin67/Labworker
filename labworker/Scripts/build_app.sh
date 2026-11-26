#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

echo "🔨 Building Labworker in Release mode in $DIR..."
swift build --disable-sandbox -c release

package_app_bundle() {
    local BUNDLE_NAME="$1"
    local APP_DIR="$DIR/$BUNDLE_NAME"
    local MACOS_DIR="$APP_DIR/Contents/MacOS"
    local RESOURCES_DIR="$APP_DIR/Contents/Resources"

    echo "📦 Packaging macOS App Bundle: $APP_DIR..."
    mkdir -p "$MACOS_DIR"
    mkdir -p "$RESOURCES_DIR"

    cp -f "$DIR/.build/release/CloneStudio" "$MACOS_DIR/CloneStudio"
    chmod +x "$MACOS_DIR/CloneStudio"

    # 保持 minos=14.0（兼容 macOS 14/15），同时将 LC_BUILD_VERSION.sdk 对齐当前原生 macOS SDK 版本（如 27.2），
    # 避免 SwiftPM 在 macOS 14 最低部署目标下将 sdk 误写为 14.0 从而丢失 macOS 26/27 原生 Liquid Glass、红绿灯与状态栏模糊特性。
    local SDK_VER
    SDK_VER="$(xcrun --show-sdk-version 2>/dev/null || true)"
    if command -v vtool >/dev/null 2>&1 && [[ "$SDK_VER" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        local BUILD_INFO MINOS_VER LD_VER
        BUILD_INFO="$(vtool -show-build "$MACOS_DIR/CloneStudio" 2>/dev/null || true)"
        MINOS_VER="$(printf '%s\n' "$BUILD_INFO" | awk '$1 == "minos" { print $2; exit }')"
        LD_VER="$(printf '%s\n' "$BUILD_INFO" | awk '$1 == "tool" && $2 == "LD" { getline; if ($1 == "version") print $2; exit }')"
        MINOS_VER="${MINOS_VER:-14.0}"
        if [ -n "$LD_VER" ]; then
            vtool -set-build-version macos "$MINOS_VER" "$SDK_VER" -tool ld "$LD_VER" -replace -output "$MACOS_DIR/CloneStudio" "$MACOS_DIR/CloneStudio"
        else
            vtool -set-build-version macos "$MINOS_VER" "$SDK_VER" -replace -output "$MACOS_DIR/CloneStudio" "$MACOS_DIR/CloneStudio"
        fi
        local PATCHED_SDK
        PATCHED_SDK="$(vtool -show-build "$MACOS_DIR/CloneStudio" | awk '$1 == "sdk" { print $2; exit }')"
        echo "🧬 LC_BUILD_VERSION: minos=$MINOS_VER, sdk=$PATCHED_SDK (host SDK=$SDK_VER)"
        if [ "$PATCHED_SDK" != "$SDK_VER" ]; then
            echo "❌ Failed to stamp LC_BUILD_VERSION sdk=$SDK_VER (got $PATCHED_SDK)" >&2
            exit 1
        fi
    fi

    for icon_file in "AppIcon.icns" "AppIcon_Light.icns" "AppIcon_Dark.icns" "AppIcon_1024.png" "AppIcon_Light_1024.png" "AppIcon_Dark_1024.png" "StatusBarIcon.png" "StatusBarIcon@2x.png"; do
        if [ -f "$DIR/Sources/CloneStudioCore/Resources/$icon_file" ]; then
            cp -f "$DIR/Sources/CloneStudioCore/Resources/$icon_file" "$RESOURCES_DIR/"
        fi
    done
    if [ -f "$DIR/Sources/CloneStudioCore/Resources/select.json" ]; then
        cp -f "$DIR/Sources/CloneStudioCore/Resources/select.json" "$RESOURCES_DIR/"
    fi
    if [ -f "$DIR/Sources/CloneStudioCore/Resources/en_translations.json" ]; then
        cp -f "$DIR/Sources/CloneStudioCore/Resources/en_translations.json" "$RESOURCES_DIR/"
    fi
    if [ -f "$DIR/Sources/CloneStudioCore/Resources/Libraries.sqlite" ]; then
        cp -f "$DIR/Sources/CloneStudioCore/Resources/Libraries.sqlite" "$RESOURCES_DIR/"
    fi
    for py_script in "export_order.py" "chopchop_query.py" "snapgene_bridge.py" "clonestudio_mcp_server.py"; do
        if [ -f "$DIR/Sources/CloneStudioCore/Resources/$py_script" ]; then
            cp -f "$DIR/Sources/CloneStudioCore/Resources/$py_script" "$RESOURCES_DIR/"
            chmod +x "$RESOURCES_DIR/$py_script"
        fi
    done

    for web_asset in "molstar.js" "molstar.css" "molstar_host.html"; do
        if [ -f "$DIR/Sources/CloneStudioCore/Resources/$web_asset" ]; then
            cp -f "$DIR/Sources/CloneStudioCore/Resources/$web_asset" "$RESOURCES_DIR/"
        fi
    done

    for tpl in "擎科引物合成订购表.xlsx" "擎科测序订购表专属电子订单.xlsx" "生工DNA测序订购表.xlsx" "DNA测序订购表_V9(1).xlsx"; do
        if [ -f "$DIR/$tpl" ]; then
            cp -f "$DIR/$tpl" "$RESOURCES_DIR/"
        elif [ -f "$DIR/Sources/CloneStudioCore/Resources/$tpl" ]; then
            cp -f "$DIR/Sources/CloneStudioCore/Resources/$tpl" "$RESOURCES_DIR/"
        fi
    done

    if [ -d "$DIR/.build/release/CloneStudio_CloneStudioCore.bundle" ]; then
        cp -Rf "$DIR/.build/release/CloneStudio_CloneStudioCore.bundle" "$RESOURCES_DIR/"
    fi

    local GIT_COMMIT
    GIT_COMMIT=$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")

    cat <<EOF > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CloneStudio</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.labworker.mac</string>
    <key>CFBundleName</key>
    <string>Labworker</string>
    <key>CFBundleDisplayName</key>
    <string>Labworker</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>20261120</string>
    <key>CFBundleVersion</key>
    <string>20261120</string>
    <key>LWGitCommit</key>
    <string>$GIT_COMMIT</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>DTSDKName</key>
    <string>macosx${SDK_VER:-27.2}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Labworker 需要访问下载目录以读取和导出 .dna 质粒、WB 条带图像、PDB 结构与订购表文件。</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Labworker 需要访问桌面目录以读取和保存 .dna 质粒、WB 条带图像、PDB 结构与订购表文件。</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Labworker 需要访问文稿目录以读取和保存 .dna 质粒、WB 条带图像、PDB 结构与订购表文件。</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>SnapGene DNA File</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>dna</string>
            </array>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.snapgene.dna</string>
                <string>public.data</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Laboratory Data &amp; Structure File</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>fa</string>
                <string>fasta</string>
                <string>gb</string>
                <string>gbk</string>
                <string>seq</string>
                <string>fastq</string>
                <string>fq</string>
                <string>rdml</string>
                <string>xml</string>
                <string>json</string>
                <string>jsonld</string>
                <string>txt</string>
                <string>pdb</string>
                <string>cif</string>
                <string>csv</string>
                <string>tsv</string>
                <string>tif</string>
                <string>tiff</string>
            </array>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.plain-text</string>
                <string>public.text</string>
                <string>public.image</string>
                <string>public.data</string>
            </array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.snapgene.dna</string>
            <key>UTTypeDescription</key>
            <string>SnapGene DNA Document</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>dna</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

    for loc in "zh-Hans.lproj" "zh_CN.lproj" "en.lproj"; do
        mkdir -p "$RESOURCES_DIR/$loc"
        cat <<EOF > "$RESOURCES_DIR/$loc/InfoPlist.strings"
CFBundleDisplayName = "Labworker";
CFBundleName = "Labworker";
EOF
    done

    xattr -cr "$APP_DIR" 2>/dev/null || true
    codesign --force --deep --sign - "$APP_DIR"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"

    touch "$APP_DIR"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true
}

rm -rf "$DIR/CloneStudio.app"
package_app_bundle "Labworker.app"

echo "✅ Labworker.app built and signed in: $DIR"
