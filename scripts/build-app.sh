#!/bin/zsh

set -euo pipefail

PROJECT_DIR=${0:A:h:h}
FINAL_APP_DIR="$PROJECT_DIR/.build/BackupCron.app"
FINAL_ZIP_PATH="$PROJECT_DIR/.build/BackupCron.zip"
STAGING_DIR=$(/usr/bin/mktemp -d /private/tmp/backupcron-build.XXXXXX)
SCRATCH_DIR="$STAGING_DIR/swiftpm-release"
MODULE_CACHE="$STAGING_DIR/module-cache"
APP_DIR="$STAGING_DIR/BackupCron.app"
ARCHIVE_PATH="$STAGING_DIR/BackupCron.zip"
ARCHIVE_CHECK_DIR="$STAGING_DIR/archive-check"
CONTENTS_DIR="$APP_DIR/Contents"

cleanup() {
  /bin/rm -rf -- "$STAGING_DIR"
}
trap cleanup EXIT

env \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
  swift build \
  --disable-sandbox \
  --product BackupCron \
  --configuration release \
  --scratch-path "$SCRATCH_DIR"

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$SCRATCH_DIR/release/BackupCron" "$CONTENTS_DIR/MacOS/BackupCron"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"

RESOURCE_BUNDLE="$SCRATCH_DIR/release/BackupCron_BackupFlow.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  for localization in "$RESOURCE_BUNDLE"/*.lproj; do
    [[ -d "$localization" ]] && cp -R "$localization" "$CONTENTS_DIR/Resources/"
  done
fi

/usr/bin/xattr -cr "$APP_DIR"
/usr/bin/codesign --force --deep --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

# Keep a stable transport artifact. The workspace lives in iCloud Drive, which
# may add Finder metadata to a copied .app after verification. The ZIP is made
# from the clean staging bundle and verified after a round trip.
/usr/bin/ditto -c -k --norsrc --keepParent "$APP_DIR" "$ARCHIVE_PATH"
mkdir -p "$ARCHIVE_CHECK_DIR"
/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$ARCHIVE_CHECK_DIR"
/usr/bin/codesign --verify --deep --strict "$ARCHIVE_CHECK_DIR/BackupCron.app"

/bin/rm -rf -- "$FINAL_APP_DIR"
/bin/rm -f -- "$FINAL_ZIP_PATH"
env COPYFILE_DISABLE=1 cp -R "$APP_DIR" "$FINAL_APP_DIR"
cp "$ARCHIVE_PATH" "$FINAL_ZIP_PATH"

# iCloud Drive can restore FinderInfo immediately after the bundle is copied.
# Clear and verify in one tight retry loop so a valid local build is not
# reported as failed because of that metadata race.
verified=false
for _ in 1 2 3 4 5; do
  /usr/bin/xattr -d com.apple.FinderInfo "$FINAL_APP_DIR" 2>/dev/null || true
  if /usr/bin/codesign --verify --deep --strict "$FINAL_APP_DIR" 2>/dev/null; then
    verified=true
    break
  fi
done

if [[ "$verified" != true ]]; then
  /usr/bin/codesign --verify --deep --strict "$FINAL_APP_DIR"
fi

echo "$FINAL_APP_DIR"
echo "$FINAL_ZIP_PATH"
