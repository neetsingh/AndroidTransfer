#!/bin/sh
set -eu
cd "$(dirname "$0")"
if [ -z "${MTP_PREFIX:-}" ] || [ -z "${LIBUSB_PREFIX:-}" ]; then
    if ! command -v brew >/dev/null 2>&1; then
        echo "Install Homebrew and run: brew install libmtp pkgconf" >&2
        exit 1
    fi
    MTP_PREFIX="${MTP_PREFIX:-$(brew --prefix libmtp)}"
    LIBUSB_PREFIX="${LIBUSB_PREFIX:-$(brew --prefix libusb)}"
fi
MTP_LIB="$MTP_PREFIX/lib/libmtp.9.dylib"
USB_LIB="$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib"
for file in "$MTP_LIB" "$USB_LIB" "$MTP_PREFIX/include/libmtp.h" "$MTP_PREFIX/COPYING" "$LIBUSB_PREFIX/COPYING"; do
    if [ ! -f "$file" ]; then
        echo "Missing dependency file: $file" >&2
        exit 1
    fi
done
swift build -c release -Xcc -I"$MTP_PREFIX/include" -Xlinker -L"$MTP_PREFIX/lib" -Xlinker -L"$LIBUSB_PREFIX/lib"
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="dist/Android Transfer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
for library in "$APP/Contents/Frameworks/libmtp.9.dylib" "$APP/Contents/Frameworks/libusb-1.0.0.dylib"; do
    if [ -f "$library" ]; then chmod u+w "$library"; fi
done
cp "$BIN_DIR/AndroidTransfer" "$APP/Contents/MacOS/AndroidTransfer"
cp "$MTP_LIB" "$APP/Contents/Frameworks/libmtp.9.dylib"
cp "$USB_LIB" "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
cp "$MTP_PREFIX/COPYING" "$APP/Contents/Resources/Licenses/libmtp.txt"
cp "$LIBUSB_PREFIX/COPYING" "$APP/Contents/Resources/Licenses/libusb.txt"
MTP_ID="$(otool -D "$MTP_LIB" | sed -n '2p')"
USB_ID="$(otool -L "$MTP_LIB" | awk '/libusb-1[.]0[.]0[.]dylib/ {print $1; exit}')"
if [ -z "$MTP_ID" ] || [ -z "$USB_ID" ]; then
    echo "Could not determine library install names." >&2
    exit 1
fi
install_name_tool -change "$MTP_ID" '@executable_path/../Frameworks/libmtp.9.dylib' "$APP/Contents/MacOS/AndroidTransfer"
install_name_tool -id '@rpath/libmtp.9.dylib' -change "$USB_ID" '@loader_path/libusb-1.0.0.dylib' "$APP/Contents/Frameworks/libmtp.9.dylib"
install_name_tool -id '@rpath/libusb-1.0.0.dylib' "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>AndroidTransfer</string>
    <key>CFBundleIdentifier</key><string>local.androidtransfer.app</string>
    <key>CFBundleName</key><string>Android Transfer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
codesign --force --sign - "$APP/Contents/Frameworks/libmtp.9.dylib"
codesign --force --sign - "$APP"
echo "Built $APP"
