#!/bin/bash
# Builds "DiscLink.app" into build/ (release, ad-hoc signed), with the icon from Resources/.
# The app is called 光盘通 on Chinese systems and DiscLink elsewhere (localized display name).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# If Xcode is installed but its license hasn't been accepted yet, fall back to the Command Line Tools.
if ! xcrun --show-sdk-version >/dev/null 2>&1 && [ -d /Library/Developer/CommandLineTools ]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
# With only the Command Line Tools, SwiftPM records the deployment target as the SDK version
# (sdk 14.0). macOS then runs the app in compatibility mode with the old window chrome
# instead of Liquid Glass, so stamp the real SDK version in at link time.
SDK_VERSION="$(xcrun --show-sdk-version)"
LINK=(-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION")
swift build -c release --product UDFDiscApp "${LINK[@]}"
BIN="$(swift build -c release --show-bin-path "${LINK[@]}")/UDFDiscApp"
NAME="DiscLink"            # file name and English name
NAME_ZH="光盘通"
APP="build/$NAME.app"
rm -rf "$APP" "build/UDF 光盘.app" "build/光盘通.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UDFDiscApp"

# Icon. With Xcode, compile the layered Icon Composer icon (Resources/AppIcon.icon): macOS 26+
# renders it with Liquid Glass and adapts it to the light, dark, tinted and clear icon styles,
# and actool also writes an AppIcon.icns for older systems. Without Xcode, build a flat .icns
# from the 1024 px picture. Both are drawn by scripts/make_icon.swift.
if xcrun --find actool >/dev/null 2>&1; then
    ICONOUT="$(mktemp -d)"
    # Absolute path: actool's background service resolves relative paths against its own last directory.
    xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$ICONOUT" --platform macosx --minimum-deployment-target 14.0 \
        --app-icon AppIcon --output-partial-info-plist "$ICONOUT/partial.plist" >/dev/null
    cp "$ICONOUT/Assets.car" "$ICONOUT/AppIcon.icns" "$APP/Contents/Resources/"
    ICON_KIND="分层液态玻璃图标"
else
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    ICON_KIND="普通图标（没有 Xcode，用不了分层图标）"
fi

# Localized name. The .lproj folders also tell macOS which languages the app speaks, so the
# system menus (Edit, Window…) and the app's own text (see Language in UDFKit) follow suit.
for loc in en zh-Hans; do
    mkdir -p "$APP/Contents/Resources/$loc.lproj"
    if [ "$loc" = en ]; then n="$NAME"; else n="$NAME_ZH"; fi
    printf 'CFBundleName = "%s";\nCFBundleDisplayName = "%s";\n' "$n" "$n" > "$APP/Contents/Resources/$loc.lproj/InfoPlist.strings"
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSHasLocalizedDisplayName</key><true/>
    <key>CFBundleIdentifier</key><string>local.udfdisc</string>
    <key>CFBundleExecutable</key><string>UDFDiscApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "已生成：$ROOT/$APP（$ICON_KIND）"
