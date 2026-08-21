#!/bin/bash
#
# Assembles Doppio.app from the SwiftPM products.
#
# There is no Xcode project on purpose: the whole product is about hand-built
# app bundles, and `swift build` plus this script is enough. Works with the
# Command Line Tools alone.
#
#   ./scripts/build-app.sh [--release] [--install]
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

CONFIG=debug
INSTALL=0
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG=release ;;
    --install) INSTALL=1 ;;
    --universal) UNIVERSAL=1; CONFIG=release ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

PRODUCTS="DoppioShot DoppioApp doppio"

echo "==> Building ($CONFIG$([ "$UNIVERSAL" = 1 ] && echo ", universal"))"
for product in $PRODUCTS; do
  swift build -c "$CONFIG" --product "$product"
done
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

# A release for other people must run on Intel as well as Apple Silicon — the
# stub in particular, since a copy of it is embedded in every Shot the user
# generates. SwiftPM's --arch needs Xcode's xcbuild, which a Command Line Tools
# install does not have, so each slice is built separately and lipo'd.
if [ "$UNIVERSAL" = 1 ]; then
  HOST_ARCH="$(uname -m)"
  case "$HOST_ARCH" in
    arm64) OTHER_TRIPLE=x86_64-apple-macosx13.0 ;;
    x86_64) OTHER_TRIPLE=arm64-apple-macosx13.0 ;;
    *) echo "unexpected architecture: $HOST_ARCH" >&2; exit 1 ;;
  esac
  echo "==> Building $OTHER_TRIPLE slice"
  for product in $PRODUCTS; do
    swift build -c "$CONFIG" --triple "$OTHER_TRIPLE" --product "$product"
  done
  OTHER_BIN="$(swift build -c "$CONFIG" --triple "$OTHER_TRIPLE" --show-bin-path)"

  FAT="$ROOT/build/universal"
  rm -rf "$FAT"; mkdir -p "$FAT"
  for product in $PRODUCTS; do
    lipo -create "$BIN/$product" "$OTHER_BIN/$product" -output "$FAT/$product"
    echo "    $product: $(lipo -archs "$FAT/$product")"
  done
  # Resources come from the host build; only the executables are fattened.
  cp -R "$BIN"/*.bundle "$FAT/" 2>/dev/null || true
  BIN="$FAT"
fi
OUT="$ROOT/build"
APP="$OUT/Doppio.app"

VERSION=$(grep -m1 'appVersion = ' Sources/DoppioCore/Models/DoppioPaths.swift | sed 's/.*"\(.*\)".*/\1/')
echo "==> Assembling Doppio.app (version $VERSION)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/DoppioApp" "$APP/Contents/MacOS/Doppio"
# The stub is embedded as a resource: BundleForge copies it into every Shot.
cp "$BIN/DoppioShot" "$APP/Contents/Resources/DoppioShot"
# The CLI ships inside the bundle; "Install Command Line Tool" symlinks it.
cp "$BIN/doppio" "$APP/Contents/Resources/doppio"
cp "$ROOT/compat-db/rules.json" "$APP/Contents/Resources/rules.json"

# SwiftPM puts a target's resources in a .bundle next to the binary; the app
# reads rules.json through Bundle.module, so carry it along.
if [ -d "$BIN/Doppio_DoppioCore.bundle" ]; then
  cp -R "$BIN/Doppio_DoppioCore.bundle" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Doppio</string>
  <key>CFBundleIdentifier</key><string>org.doppio-mac.Doppio</string>
  <key>CFBundleName</key><string>Doppio</string>
  <key>CFBundleDisplayName</key><string>Doppio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>PolyForm Noncommercial 1.0.0. No telemetry, no network access.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "==> Drawing the app icon"
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
# A doppio: two stacked coffee circles. Drawn with sips from a generated PDF so
# the build needs no checked-in binary assets.
python3 - "$ICONSET" <<'PY'
import subprocess, sys, os
iconset = sys.argv[1]
svg = '''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#6F4E37"/><stop offset="1" stop-color="#3B2A1E"/></linearGradient></defs>
<rect width="1024" height="1024" rx="200" fill="url(#g)"/>
<circle cx="400" cy="430" r="150" fill="#F5E6D3" opacity="0.95"/>
<circle cx="624" cy="594" r="150" fill="#F5E6D3" opacity="0.75"/>
</svg>'''
src = os.path.join(iconset, "base.svg")
open(src, "w").write(svg)
png = os.path.join(iconset, "base.png")
# qlmanage renders SVG without extra dependencies.
subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", iconset, src],
               capture_output=True)
rendered = os.path.join(iconset, "base.svg.png")
if os.path.exists(rendered):
    os.replace(rendered, png)
else:
    # Fall back to a flat colour square so the build still produces an icon.
    subprocess.run(["sips", "-s", "format", "png", "--resampleHeightWidth", "1024", "1024",
                    "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns",
                    "--out", png], capture_output=True)
for name, size in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),
                   ("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),
                   ("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)]:
    subprocess.run(["sips", "-z", str(size), str(size), png,
                    "--out", os.path.join(iconset, name + ".png")], capture_output=True)
os.remove(src)
os.remove(png)
PY
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || \
  echo "    (icon generation skipped)"
rm -rf "$ICONSET"

echo "==> Signing"
codesign --force -s - "$APP" 2>&1 | sed 's/^/    /'
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Built $APP"
du -sh "$APP" | awk '{print "    size: " $1}'
echo "    architectures: $(lipo -archs "$APP/Contents/MacOS/Doppio")"

if [ "$INSTALL" = "1" ]; then
  DEST="$HOME/Applications/Doppio.app"
  echo "==> Installing to $DEST"
  rm -rf "$DEST"
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$DEST"
  echo "    installed. Open it with: open \"$DEST\""
fi
