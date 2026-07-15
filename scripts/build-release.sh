#!/usr/bin/env bash
#
# build-release.sh — build, sign (Developer ID), package as DMG, and
# optionally notarize a release build of PetMacOS.
#
# Usage:
#   scripts/build-release.sh              # build + sign + dmg (no notarize)
#   scripts/build-release.sh --notarize   # also notarize + staple (needs a
#                                          # notarytool keychain profile)
#
# Building your own fork? Override the signing identity via env vars:
#   PET_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   PET_TEAM_ID=TEAMID PET_NOTARY_PROFILE=YourProfile \
#   scripts/build-release.sh --notarize
#
# See docs/DISTRIBUTION.md for the full distribution plan. This script
# implements step 2 (signing + packaging); notarization (step 3) is wired
# up but disabled by default because the "PetMacOS" notarytool keychain
# profile does not exist yet on this machine.

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/PetMacOS.xcodeproj"
SCHEME="PetMacOS"
CONFIGURATION="Release"

BUILD_DIR="$ROOT_DIR/build/release"
ARCHIVE_PATH="$BUILD_DIR/PetMacOS.xcarchive"
EXPORT_APP_DIR="$BUILD_DIR/export"
APP_NAME="PetMacOS.app"
APP_PATH="$EXPORT_APP_DIR/$APP_NAME"
DMG_STAGING_DIR="$BUILD_DIR/dmg-staging"

# Signing/notarization identity — override these for your own fork:
#   PET_SIGN_IDENTITY   full "Developer ID Application: ..." identity string
#   PET_TEAM_ID         your Apple Developer team ID
#   PET_NOTARY_PROFILE  notarytool keychain profile name
#                       (create with: xcrun notarytool store-credentials)
DEVELOPER_ID="${PET_SIGN_IDENTITY:-Developer ID Application: Tran Van Thuc (N5VJ7TQLY7)}"
TEAM_ID="${PET_TEAM_ID:-N5VJ7TQLY7}"
NOTARY_PROFILE="${PET_NOTARY_PROFILE:-PetMacOS}"

DO_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --notarize)
      DO_NOTARIZE=1
      ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

log() {
  echo ""
  echo "==> $*"
}

warn() {
  echo "!!  $*" >&2
}

# ---------------------------------------------------------------------------
# 0. Clean output dir
# ---------------------------------------------------------------------------

log "Cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# 1. Archive
# ---------------------------------------------------------------------------

log "Archiving $SCHEME ($CONFIGURATION) -> $ARCHIVE_PATH"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  ENABLE_HARDENED_RUNTIME=YES

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME"
if [[ ! -d "$ARCHIVED_APP" ]]; then
  warn "Expected archived app not found at $ARCHIVED_APP"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Copy .app out of the archive
# ---------------------------------------------------------------------------

log "Copying app out of archive -> $APP_PATH"
mkdir -p "$EXPORT_APP_DIR"
ditto "$ARCHIVED_APP" "$APP_PATH"

# ---------------------------------------------------------------------------
# 3. Re-sign with Developer ID + hardened runtime + timestamp
# ---------------------------------------------------------------------------
#
# xcodebuild archive already signs everything with the identity above, but
# we re-sign explicitly here so the packaging step is not dependent on
# xcodebuild's internal signing behavior (and so re-running just the
# packaging/notarize steps against an already-exported .app is possible).
#
# --deep is deprecated/unsafe for signing arbitrary bundles, so nested
# binaries (frameworks, helper tools, etc.) are signed individually first,
# innermost-first, then the outer app bundle is signed last.

log "Locating nested binaries/frameworks inside $APP_PATH"
NESTED_ITEMS=()
while IFS= read -r -d '' item; do
  NESTED_ITEMS+=("$item")
done < <(find "$APP_PATH" \
  \( -path "*/Frameworks/*" -o -path "*/PlugIns/*" -o -path "*/Helpers/*" -o -path "*/XPCServices/*" \) \
  \( -name "*.framework" -o -name "*.dylib" -o -name "*.appex" -o -name "*.xpc" -o -type f -perm -u+x \) \
  -print0 2>/dev/null || true)

if [[ ${#NESTED_ITEMS[@]} -eq 0 ]]; then
  log "No nested binaries found — this app has a single main executable"
else
  log "Found ${#NESTED_ITEMS[@]} nested item(s); signing each individually"
  for item in "${NESTED_ITEMS[@]}"; do
    echo "    signing: $item"
    codesign --force --options runtime --timestamp \
      --sign "$DEVELOPER_ID" \
      "$item"
  done
fi

log "Signing main app bundle: $APP_PATH"
codesign --force --options runtime --timestamp \
  --sign "$DEVELOPER_ID" \
  "$APP_PATH"

# ---------------------------------------------------------------------------
# 4. Read version + build DMG
# ---------------------------------------------------------------------------

APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"
VERSION="$(defaults read "$APP_INFO_PLIST" CFBundleShortVersionString 2>/dev/null || echo "0.0.0")"
log "App version: $VERSION"

DMG_NAME="PetMacOS-${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

# ---------------------------------------------------------------------------
# DMG layout: background image + Finder icon positions/window size.
#
# Strategy: build a read-write DMG, mount it, drop in the background image
# (as a hidden .background folder) + set icon size/positions/window bounds
# via an AppleScript Finder script, then convert to compressed UDZO.
#
# Finder scripting requires Automation permission for the process driving
# this script (System Settings > Privacy & Security > Automation). If that
# permission isn't granted here, the AppleScript step fails/times out and we
# fall back to a plain DMG (background image still copied in as
# `.background/background.png` so it's available for anyone who wants to
# set it manually via Finder's View Options).
# ---------------------------------------------------------------------------

DMG_VOLNAME="PetMacOS"
DMG_WINDOW_W=660
DMG_WINDOW_H=420
DMG_ICON_SIZE=128
APP_ICON_X=165
FOLDER_ICON_X=495
ICON_Y=190
BACKGROUND_PNG="$ROOT_DIR/assets/dmg-background.png"
BACKGROUND_PNG_2X="$ROOT_DIR/assets/dmg-background@2x.png"

stage_dmg_contents() {
  local staging_dir="$1"
  log "Staging DMG contents -> $staging_dir"
  rm -rf "$staging_dir"
  mkdir -p "$staging_dir"
  ditto "$APP_PATH" "$staging_dir/$APP_NAME"
  ln -s /Applications "$staging_dir/Applications"
  if [[ -f "$BACKGROUND_PNG" ]]; then
    mkdir -p "$staging_dir/.background"
    cp "$BACKGROUND_PNG" "$staging_dir/.background/background.png"
    [[ -f "$BACKGROUND_PNG_2X" ]] && cp "$BACKGROUND_PNG_2X" "$staging_dir/.background/background@2x.png"
  fi
}

# build_dmg <staging_dir> <output_dmg_path>
#
# Creates a plain (unlayouted) compressed DMG. Used as the base and as the
# fallback if the Finder-layout step below can't run.
build_dmg_plain() {
  local staging_dir="$1"
  local output_path="$2"
  log "Creating $output_path (plain layout)"
  rm -f "$output_path"
  hdiutil create \
    -volname "$DMG_VOLNAME" \
    -srcfolder "$staging_dir" \
    -ov -format UDZO \
    "$output_path"
}

# apply_dmg_layout <staging_dir> <output_dmg_path>
#
# Builds a read-write DMG, mounts it, uses Finder (via AppleScript) to set
# the background image, window size, icon size, and icon positions, then
# converts the result to a compressed read-only DMG at output_path. Returns
# non-zero (without touching output_path) if any step fails, so the caller
# can fall back to build_dmg_plain.
apply_dmg_layout() {
  local staging_dir="$1"
  local output_path="$2"
  local rw_dmg="$BUILD_DIR/PetMacOS-rw.dmg"

  rm -f "$rw_dmg"
  hdiutil create \
    -volname "$DMG_VOLNAME" \
    -srcfolder "$staging_dir" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "$rw_dmg" || return 1

  local mount_point="/Volumes/$DMG_VOLNAME"
  # Detach any stale mount from a previous failed run.
  hdiutil detach "$mount_point" -quiet 2>/dev/null || true

  local attach_out
  attach_out="$(hdiutil attach "$rw_dmg" -readwrite -noverify -noautoopen 2>&1)" || {
    warn "hdiutil attach failed: $attach_out"
    return 1
  }
  mount_point="$(echo "$attach_out" | grep -Eo '/Volumes/.*' | tail -1)"
  [[ -n "$mount_point" ]] || { warn "Could not determine mount point"; return 1; }

  local layout_ok=1
  if ! osascript <<OSA
tell application "Finder"
  tell disk "$DMG_VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 200 + $DMG_WINDOW_W, 120 + $DMG_WINDOW_H}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to $DMG_ICON_SIZE
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "$APP_NAME" of container window to {$APP_ICON_X, $ICON_Y}
    set position of item "Applications" of container window to {$FOLDER_ICON_X, $ICON_Y}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
OSA
  then
    layout_ok=0
  fi

  # Make sure the .background folder doesn't show up as a visible Finder item.
  [[ -d "$mount_point/.background" ]] && SetFile -a V "$mount_point/.background" 2>/dev/null || true

  sync
  hdiutil detach "$mount_point" -quiet 2>/dev/null || hdiutil detach "$mount_point" 2>/dev/null || true

  if [[ "$layout_ok" -ne 1 ]]; then
    warn "Finder layout AppleScript failed (likely missing Automation permission for this process)."
    rm -f "$rw_dmg"
    return 1
  fi

  log "Converting laid-out DMG -> $output_path"
  rm -f "$output_path"
  hdiutil convert "$rw_dmg" -format UDZO -ov -o "$output_path" || return 1
  rm -f "$rw_dmg"
  return 0
}

# build_dmg <staging_dir> <output_dmg_path>
#
# Tries the pretty Finder layout first; falls back to a plain DMG (still
# containing the background image under .background/ for manual setup) if
# Finder scripting isn't available/permitted on this machine.
build_dmg() {
  local staging_dir="$1"
  local output_path="$2"
  stage_dmg_contents "$staging_dir"
  if apply_dmg_layout "$staging_dir" "$output_path"; then
    log "DMG layout applied (background + icon positions)"
  else
    warn "Falling back to plain DMG layout (no custom Finder window/background)."
    build_dmg_plain "$staging_dir" "$output_path"
  fi
}

build_dmg "$DMG_STAGING_DIR" "$DMG_PATH"

# ---------------------------------------------------------------------------
# 5. Notarization (opt-in via --notarize)
# ---------------------------------------------------------------------------

notarize_submit() {
  local target="$1"

  log "Submitting $target to notarytool (profile: $NOTARY_PROFILE)"
  xcrun notarytool submit "$target" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
}

if [[ "$DO_NOTARIZE" -eq 1 ]]; then
  log "Notarization requested (--notarize)"

  # Notarize the .app itself first (zipped, since notarytool needs a
  # zip/dmg/pkg — not a raw .app bundle), staple the .app, then rebuild the
  # DMG with the stapled app, and finally notarize + staple the DMG too.
  APP_ZIP_PATH="$BUILD_DIR/PetMacOS-app-for-notarization.zip"
  log "Zipping app for notarization submission -> $APP_ZIP_PATH"
  ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP_PATH"
  notarize_submit "$APP_ZIP_PATH"
  # The stapler can't staple a zip — staple the .app bundle itself.
  log "Stapling $APP_PATH"
  xcrun stapler staple "$APP_PATH"

  log "Rebuilding DMG with stapled app"
  build_dmg "$DMG_STAGING_DIR" "$DMG_PATH"

  # Sign the DMG itself before notarizing — an unsigned DMG fails
  # `spctl --type open` with "no usable signature" even when notarized.
  log "Signing DMG"
  codesign --sign "$DEVELOPER_ID" --timestamp "$DMG_PATH"

  notarize_submit "$DMG_PATH"
  log "Stapling $DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
else
  log "Skipping notarization (run with --notarize once the '$NOTARY_PROFILE' notarytool keychain profile exists)"
fi

# ---------------------------------------------------------------------------
# 6. Verify
# ---------------------------------------------------------------------------

log "Verifying code signature (codesign --verify)"
codesign --verify --deep --strict -vv "$APP_PATH"

log "Verifying Gatekeeper acceptance (spctl --assess)"
if spctl --assess --type execute -vv "$APP_PATH"; then
  echo "spctl: accepted"
else
  if [[ "$DO_NOTARIZE" -eq 1 ]]; then
    warn "spctl rejected the app even though --notarize was requested. Check notarization status/logs."
    exit 1
  else
    warn "spctl rejected the app — this is EXPECTED because the build was not notarized (ran without --notarize)."
    warn "Developer ID signature is valid; Gatekeeper will still block until notarize+staple is run."
  fi
fi

log "Done."
echo "App:     $APP_PATH"
echo "DMG:     $DMG_PATH"
