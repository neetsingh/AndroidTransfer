#!/bin/sh
set -eu

usage() {
    echo "Usage: ./install.sh [--app PATH] [--update]"
    echo "Build and install Android Transfer in ~/Applications."
    echo "  --app PATH  Install an existing Android Transfer.app instead of building."
    echo "  --update    Replace an existing installation, keeping a backup."
}

app_source=
update=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --app)
            if [ "$#" -lt 2 ]; then
                echo "Missing path after --app." >&2
                exit 1
            fi
            app_source=$2
            shift 2
            ;;
        --update) update=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ "$(uname -s)" != Darwin ]; then
    echo "Android Transfer can only be installed on macOS." >&2
    exit 1
fi

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
applications="$HOME/Applications"
destination="$applications/Android Transfer.app"

check_existing() {
    if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
        return
    fi
    if [ "$update" != true ]; then
        echo "An item already exists at $destination. Quit the app and use --update to replace it." >&2
        exit 1
    fi
    if [ -L "$destination" ] || [ ! -d "$destination" ]; then
        echo "Refusing to replace a non-directory or symbolic link: $destination" >&2
        exit 1
    fi
    existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist") || {
        echo "Cannot identify the existing app; it was not changed." >&2
        exit 1
    }
    if [ "$existing_id" != local.androidtransfer.app ]; then
        echo "The existing app has a different bundle identifier; it was not changed." >&2
        exit 1
    fi
}

check_existing

if [ -z "$app_source" ]; then
    if ! command -v brew >/dev/null 2>&1; then
        echo "Install Xcode Command Line Tools and Homebrew, then run: brew install libmtp pkgconf" >&2
        exit 1
    fi
    "$script_dir/build-app.sh"
    app_source="$script_dir/dist/Android Transfer.app"
fi

if [ ! -d "$app_source" ]; then
    echo "App bundle not found: $app_source" >&2
    exit 1
fi
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_source/Contents/Info.plist") || {
    echo "Cannot read the app bundle identifier." >&2
    exit 1
}
if [ "$bundle_id" != local.androidtransfer.app ]; then
    echo "Not an Android Transfer app bundle: $app_source" >&2
    exit 1
fi
codesign --verify --deep --strict "$app_source"

architecture=$(uname -m)
os_version=$(sw_vers -productVersion)
for binary in \
    "$app_source/Contents/MacOS/AndroidTransfer" \
    "$app_source/Contents/Frameworks/libmtp.9.dylib" \
    "$app_source/Contents/Frameworks/libusb-1.0.0.dylib"
do
    if [ ! -f "$binary" ] || ! lipo -verify_arch "$architecture" "$binary"; then
        echo "Missing or incompatible $architecture binary: $binary" >&2
        exit 1
    fi
    build_info=$(vtool -arch "$architecture" -show-build "$binary")
    minimum=$(printf '%s\n' "$build_info" | awk '
        $1 == "cmd" { cmd = $2 }
        cmd == "LC_BUILD_VERSION" && $1 == "minos" { print $2; exit }
        cmd == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print $2; exit }
    ')
    case "$minimum" in
        ''|*[!0-9.]*) echo "Cannot determine minimum macOS version for $binary" >&2; exit 1 ;;
    esac
    if ! awk -v current="$os_version" -v minimum="$minimum" 'BEGIN {
        split(current, a, "."); split(minimum, b, ".")
        for (i = 1; i <= 3; i++) {
            if ((a[i] + 0) > (b[i] + 0)) exit 0
            if ((a[i] + 0) < (b[i] + 0)) exit 1
        }
    }'; then
        echo "$binary requires macOS $minimum or later; this Mac runs $os_version." >&2
        exit 1
    fi
done

mkdir -p "$applications"
stage=$(mktemp -d "$applications/.android-transfer-install.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app_source" "$stage/Android Transfer.app"
codesign --verify --deep --strict "$stage/Android Transfer.app"

check_existing
if [ -e "$destination" ] || [ -L "$destination" ]; then
    backup=$(mktemp -d "$applications/.android-transfer-backup.XXXXXX")
    mv "$destination" "$backup/Android Transfer.app"
    if ! mv "$stage/Android Transfer.app" "$destination"; then
        echo "Installation failed. Restoring the previous app." >&2
        if ! mv "$backup/Android Transfer.app" "$destination"; then
            echo "Restore failed; the previous app is at $backup/Android Transfer.app" >&2
        fi
        exit 1
    fi
    echo "Previous app saved at: $backup/Android Transfer.app"
else
    mv "$stage/Android Transfer.app" "$destination"
fi

echo "Installed: $destination"
echo "Open Android Transfer from your Applications folder."
