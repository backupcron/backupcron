#!/bin/zsh

# Package an already built .app. Requires dmgbuild 1.6.7 in PATH (Python 3.10+).
# Usage: zsh scripts/build-dmg.sh [/path/to/BackupCron.app] [/path/to/output.dmg]
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
APP_DIR=${1:-"$PROJECT_DIR/.build/BackupCron.app"}
APP_DIR=${APP_DIR:A}
DMGBUILD_BIN=${DMGBUILD_BIN:-dmgbuild}

if [[ ! -d "$APP_DIR" || ! -f "$APP_DIR/Contents/Info.plist" ]]; then
  print -u2 "Build BackupCron.app first, or pass the path to an existing .app."
  exit 1
fi
if ! command -v "$DMGBUILD_BIN" >/dev/null 2>&1; then
  print -u2 "dmgbuild 1.6.7 is required. Install it in a Python 3.10+ virtual environment."
  exit 1
fi

/usr/bin/codesign --verify --deep --strict "$APP_DIR"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")
ARCHITECTURES=$(/usr/bin/lipo -archs "$APP_DIR/Contents/MacOS/BackupCron")
SUFFIX=installer
if [[ "$ARCHITECTURES" == *arm64* && "$ARCHITECTURES" == *x86_64* ]]; then
  SUFFIX=universal-installer
fi
OUTPUT_PATH=${2:-"$PROJECT_DIR/.build/BackupCron-$VERSION-$SUFFIX.dmg"}
OUTPUT_PATH=${OUTPUT_PATH:A}
mkdir -p "${OUTPUT_PATH:h}"
if [[ -e "$OUTPUT_PATH" ]]; then
  print -u2 "Output already exists: $OUTPUT_PATH. Choose another filename."
  exit 1
fi

STAGING_DIR=$(/usr/bin/mktemp -d /private/tmp/backupcron-dmg.XXXXXX)
trap '/bin/rm -rf -- "$STAGING_DIR"' EXIT
STAGED_DMG="$STAGING_DIR/BackupCron.dmg"

"$DMGBUILD_BIN" \
  -s "$PROJECT_DIR/scripts/dmg-settings.py" \
  -D "app=$APP_DIR" \
  -D "background=$PROJECT_DIR/Resources/DMG/background.tiff" \
  BackupCron "$STAGED_DMG"
/usr/bin/hdiutil verify "$STAGED_DMG"
cp "$STAGED_DMG" "$OUTPUT_PATH"
print "$OUTPUT_PATH"
/usr/bin/shasum -a 256 "$OUTPUT_PATH"
