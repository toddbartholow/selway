#!/bin/bash
#
# release.sh — Build a Universal (Apple Silicon + Intel) Release of Selway, sign it,
# package the DMG + checksum, and add it to the signed Sparkle appcast.
#
# Usage:  ./release.sh
#         SELWAY_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" SELWAY_NOTARY_PROFILE=selway ./release.sh
#
# Output (in build/, or $SELWAY_OUT_DIR):
#   Selway-<version>.dmg          the installer
#   Selway-<version>.dmg.sha256   integrity check for people downloading by hand (shasum -c)
#   Selway<build>-<old>.delta     delta updates from earlier builds (when their DMGs are in the
#                                 archives folder)
#   appcast.xml                   the signed feed, with this release added
# The archives folder also keeps this version's dSYMs, in dSYMs/<version>/: the app's
# binaries are stripped, so crash reports symbolicate only with those.
# The new feed also replaces docs/appcast.xml (or $SELWAY_APPCAST), the committed feed it
# extends. Commit it and merge; then push the release's public commit to $SELWAY_RELEASES_REPO
# as the tag v<version>, upload the DMG, checksum and deltas to its release v<version>, and only
# then push its main, which makes GitHub Pages serve the new feed (docs/RELEASING.md).
# It first runs ./scripts/test.sh --app (every test plus an app build); SELWAY_SKIP_TESTS=1 skips that.
# The release repository, archives folder, committed feed and release notes are set with the
# SELWAY_* variables described in scripts/lib/release-common.sh.
#
# Without SELWAY_SIGN_IDENTITY the app is ad-hoc signed and NOT notarized, so the first
# open needs a one-time Gatekeeper approval (see "Install & First Open.txt").
# Full steps, including the one-time key and Developer ID setup: docs/RELEASING.md.

set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=scripts/lib/release-common.sh
source scripts/lib/release-common.sh

APP_NAME="Selway"
DD="build/dd-release"                 # derived data
OUT="${SELWAY_OUT_DIR:-build}"            # final artifacts land here
STAGE="$OUT/dmg-stage"                # what gets imaged into the DMG
ARCHIVES="${SELWAY_ARCHIVES_DIR:-$OUT/sparkle-archives}"   # generate_appcast's working folder

step "Preflight"
# Everything that goes into the appcast must be notarized once Developer ID is in use: copies
# that check the Team ID also expect Gatekeeper to accept the update.
if selway_is_developer_id && [ "${SELWAY_SKIP_NOTARIZE:-0}" = 1 ]; then
    die "SELWAY_SKIP_NOTARIZE=1 with a Developer ID identity: release.sh publishes to the appcast, which only takes notarized builds. Use distribute.sh for an un-notarized test build."
fi
selway_preflight
mkdir -p "$OUT" "$ARCHIVES"
# The real folder (a symlinked SELWAY_ARCHIVES_DIR stays a link; its target is updated).
ARCHIVES=$(cd "$ARCHIVES" && pwd -P)
[ "$ARCHIVES" != "$(cd "$OUT" && pwd -P)" ] \
    || die "SELWAY_ARCHIVES_DIR must be a different folder from the output folder ($OUT)"
# A plain assignment, so a bad SELWAY_APPCAST stops the script here.
EXISTING=$(selway_existing_appcast "$ARCHIVES")
selway_preflight_sparkle "$ARCHIVES" "$EXISTING"

if [ "${SELWAY_SKIP_TESTS:-0}" = 1 ]; then
    echo "    WARNING: SELWAY_SKIP_TESTS=1 — not running the test suite."
else
    step "Tests (./scripts/test.sh --app)"
    ./scripts/test.sh --app || die "tests failed; not building a release"
fi
rm -rf "$STAGE"

step "Building Universal Release (arm64 + x86_64)"
APP=$(selway_build_app "arm64 x86_64" "$DD")

step "Verifying Universal binary"
ARCHS_FOUND=$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")
echo "    Main app:  $ARCHS_FOUND"
if [[ "$ARCHS_FOUND" != *"arm64"* || "$ARCHS_FOUND" != *"x86_64"* ]]; then
    die "app is not Universal (got: $ARCHS_FOUND)"
fi
EXT="$APP/Contents/PlugIns/SelwayExtension.appex/Contents/MacOS/SelwayExtension"
if [ -f "$EXT" ]; then echo "    Extension: $(lipo -archs "$EXT")"; fi

VERSION=$(selway_plist_value "$APP" CFBundleShortVersionString)
BUILD=$(selway_plist_value "$APP" CFBundleVersion)
[[ "$VERSION" =~ ^[0-9]{1,9}\.[0-9]{1,9}(\.[0-9]{1,9})?$ ]] \
    || die "CFBundleShortVersionString '$VERSION' isn't MAJOR.MINOR[.PATCH]. (Sparkle offers every appcast item to everyone, so this script doesn't publish prereleases.)"
[ "$(selway_plist_value "$APP" SUFeedURL)" = "$(selway_feed_url)" ] \
    || die "the built app's SUFeedURL isn't $(selway_feed_url)"
[ -n "$(selway_plist_value "$APP" SUPublicEDKey)" ] \
    || die "SUPublicEDKey is empty; this release could never update itself. See docs/RELEASING.md."
# Sparkle compares CFBundleVersion: it must beat every build already in the feed.
selway_check_build_number "$BUILD" "$EXISTING" "$VERSION"
echo "==> Version $VERSION (build $BUILD)"

# The app's binaries are stripped, so crash reports from this version symbolicate only with
# these. They go with the archives (kept between releases); the next build deletes $DD.
step "Keeping the dSYMs"
selway_keep_dsyms "$APP" "$ARCHIVES/dSYMs/$VERSION"

step "Signing"
selway_sign_app "$APP"
TEAM=""
if selway_is_developer_id; then
    TEAM_DETAILS=$(codesign -dv --verbose=2 "$APP" 2>&1)
    TEAM=$(sed -n 's/^TeamIdentifier=//p' <<<"$TEAM_DETAILS")
    selway_check_team_continuity "$ARCHIVES" "$VERSION" "$TEAM"
else
    selway_check_team_continuity "$ARCHIVES" "$VERSION"
fi

DMG="$OUT/$APP_NAME-$VERSION.dmg"
# appcast.xml in $OUT and the committed feed are only replaced once the new feed has verified.
rm -f "$DMG" "$DMG.sha256" "$DMG.sig"

step "Staging DMG contents"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
cp "dmg/background.png" "$STAGE/.background/background.png"

if selway_is_developer_id && [ "${SELWAY_SKIP_NOTARIZE:-0}" != 1 ]; then
    FIRST_OPEN='2. Open Selway from Applications. It is signed with a Developer ID and
   notarized by Apple, so macOS opens it after a quick check.'
else
    FIRST_OPEN='2. FIRST OPEN (one time): this build is not notarized by Apple, so macOS
   blocks the first open. Approve it through macOS itself:

   macOS 15 Sequoia and later:
     • Open Selway from Applications. When macOS says it can'"'"'t be opened,
       click Done.
     • Open System Settings → Privacy & Security, scroll down to the message
       about Selway, click Open Anyway, and confirm.

   macOS 14 Sonoma:
     • In Applications, Control-click (right-click) Selway → Open → Open.

   Please don'"'"'t use Terminal commands that remove the quarantine flag: that
   switches off this check for the app instead of approving it once.'
fi

cat > "$STAGE/Install & First Open.txt" <<EOF
Selway $VERSION — Install & First Open
==========================================

1. Drag Selway onto the Applications folder in this window.

$FIRST_OPEN

3. Folder permission prompts (normal — click Allow):
   Desktop / Documents / Downloads access, plus occasional Finder/Terminal
   control prompts for Get Info / Open in Terminal.

4. Optional Finder right-click menu:
   System Settings → General → Login Items & Extensions → Extensions → Selway.

Updates: Selway checks for new versions with Sparkle (Settings → General)
and installs only updates signed with the Selway release key.

Requirements: macOS 14 Sonoma or newer · Apple Silicon & Intel.

https://github.com/toddbartholow/selway
EOF

step "Creating the DMG (drag to Applications)"
# Finder's alias to the background picture, saved in the volume's .DS_Store, records
# the path of the image file it was set in, plus the boot volume's name and UUID (every
# path starts there, so no location avoids that). Keep the image in a neutral folder so
# the DMG names no home folder or checkout; the check after "hdiutil convert" stops the
# release if it does, or if the boot volume has a name other than macOS's default.
TMP_DMG_DIR=$(mktemp -d /private/tmp/selway-dmg.XXXXXX) || die "couldn't make a folder for the temporary DMG"
trap 'rm -rf "$TMP_DMG_DIR"' EXIT
TMP_DMG="$TMP_DMG_DIR/${APP_NAME}-tmp.dmg"
# Writable image so we can set Finder window layout
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "$TMP_DMG" >/dev/null || die "hdiutil create failed"

# Mounted in /Volumes (visible to Finder) so the window layout can be set; hidden from Finder
# when there is no layout to set (SELWAY_DMG_STYLE=0).
ATTACH_OPTS=(-readwrite -noverify -noautoopen)
[ "${SELWAY_DMG_STYLE:-1}" = 1 ] || ATTACH_OPTS+=(-nobrowse)
MOUNT_DIR=$(selway_attach "$TMP_DMG" "${ATTACH_OPTS[@]}") || die "could not mount temporary DMG"
trap 'hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || hdiutil detach "$MOUNT_DIR" -force -quiet 2>/dev/null || true; rm -rf "$TMP_DMG_DIR"' EXIT
echo "    Mounted: $MOUNT_DIR"
# The real volume name: it gets a suffix if a same-named disk is already mounted.
VOL_NAME=$(basename "$MOUNT_DIR")

if [ "${SELWAY_DMG_STYLE:-1}" = 1 ]; then
    # Finder sees a newly attached disk a second or so after hdiutil returns; until then
    # "tell disk" fails with -1728. Wait up to 15 seconds for it.
    finder_sees_disk=0
    for _ in $(seq 1 30); do
        if [ "$(osascript -e "tell application \"Finder\" to exists disk \"$VOL_NAME\"" 2>/dev/null)" = true ]; then
            finder_sees_disk=1
            break
        fi
        sleep 0.5
    done
    [ "$finder_sees_disk" = 1 ] || echo "    Finder hadn't seen \"$VOL_NAME\" after 15 seconds; trying the layout anyway."
    # Apply the Finder window layout (icon positions and background). A release without it
    # would ship the default layout, so stop; SELWAY_DMG_STYLE=0 builds without a layout.
    osascript <<APPLESCRIPT || die "Finder couldn't set the DMG's window layout (see above). Run again, or set SELWAY_DMG_STYLE=0 to build without it."
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 920, 620}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    try
      set background picture of theViewOptions to file ".background:background.png"
    end try
    set position of item "$APP_NAME.app" of container window to {160, 250}
    set position of item "Applications" of container window to {560, 250}
    try
      set position of item "Install & First Open.txt" of container window to {360, 420}
    end try
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
fi

sync
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet || die "could not detach $MOUNT_DIR"
trap 'rm -rf "$TMP_DMG_DIR"' EXIT
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null || die "hdiutil convert failed"
rm -rf "$TMP_DMG_DIR" "$STAGE"
trap - EXIT

# The finished DMG's Finder layout must not record where it was built (see TMP_DMG_DIR).
# Fixed strings, matched as bytes; the home folder's name only between separators, so a
# short name can't match by chance.
dmg_leaks() {
    local home_name root_volume
    home_name=$(basename "$HOME")
    for leak in "$HOME" "$(cd "$HOME" 2>/dev/null && pwd -P)" "$SELWAY_ROOT" "$(cd "$SELWAY_ROOT" && pwd -P)"; do
        [ -n "$leak" ] && [ "$leak" != / ] && echo "$leak"
    done
    if [ -n "$home_name" ] && [ "$home_name" != / ]; then
        echo "/$home_name/"
        echo ":$home_name:"
    fi
    # The boot volume's name is in every bookmark: only macOS's default may ship.
    root_volume=$(diskutil info -plist / 2>/dev/null | plutil -extract VolumeName raw -o - - 2>/dev/null) || root_volume=""
    [ -z "$root_volume" ] || [ "$root_volume" = "Macintosh HD" ] || echo "$root_volume"
}
# The checkout's volume, when it isn't the boot volume, mustn't be named either.
dmg_leaky_uuids() {
    local checkout_dev checkout_uuid data_uuid
    checkout_dev=$(stat -f %Sd "$SELWAY_ROOT") || return 0
    checkout_uuid=$(diskutil info -plist "$checkout_dev" 2>/dev/null | plutil -extract VolumeUUID raw -o - - 2>/dev/null) || return 0
    data_uuid=$(diskutil info -plist /System/Volumes/Data 2>/dev/null | plutil -extract VolumeUUID raw -o - - 2>/dev/null) || data_uuid=""
    [ -z "$checkout_uuid" ] || [ "$checkout_uuid" = "$data_uuid" ] || echo "$checkout_uuid"
}
MOUNT_DIR=$(selway_attach "$DMG" -readonly -nobrowse -noverify -noautoopen) || die "could not mount $DMG to check it"
trap 'hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || hdiutil detach "$MOUNT_DIR" -force -quiet 2>/dev/null || true' EXIT
if [ -f "$MOUNT_DIR/.DS_Store" ]; then
    while IFS= read -r leak; do
        if grep -qaF -- "$leak" "$MOUNT_DIR/.DS_Store"; then
            hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet || true
            trap - EXIT
            rm -f "$DMG"
            die "the DMG's Finder layout (.DS_Store) records \"$leak\"; the DMG was deleted"
        fi
    done < <(dmg_leaks)
    while IFS= read -r leak; do
        if grep -qaiF -- "$leak" "$MOUNT_DIR/.DS_Store"; then
            hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet || true
            trap - EXIT
            rm -f "$DMG"
            die "the DMG's Finder layout (.DS_Store) records the checkout volume's UUID $leak; the DMG was deleted"
        fi
    done < <(dmg_leaky_uuids)
elif [ "${SELWAY_DMG_STYLE:-1}" = 1 ]; then
    die "the DMG has no Finder layout (.DS_Store), although styling ran"
fi
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet || die "could not detach $MOUNT_DIR"
trap - EXIT

selway_sign_and_notarize_dmg "$DMG" "$APP"

step "Checksum"
selway_checksum "$DMG"

step "Signed Sparkle appcast (generate_appcast)"
SPARKLE_BIN=$(selway_sparkle_bin "$DD")
echo "    Sparkle tools: $SPARKLE_BIN"
selway_sparkle_appcast "$DMG" "$APP" "$ARCHIVES" "$SPARKLE_BIN" "$OUT" "$EXISTING"
FEED_FILE=$(selway_feed_file)
selway_write_feed "$OUT/appcast.xml"
# The first Developer ID release records its Team ID for every later one (commit the file).
if [ -n "$TEAM" ]; then selway_record_team "$TEAM"; fi

echo "==> Done"
echo "    DMG:       $DMG"
echo "    Checksum:  $DMG.sha256"
echo "    Appcast:   $OUT/appcast.xml (also written to $FEED_FILE)"
RELEASE_FILES=("$DMG" "$DMG.sha256")
for delta in "$OUT/$APP_NAME$BUILD-"*.delta; do
    [ -e "$delta" ] || continue
    echo "    Delta:     $delta"
    RELEASE_FILES+=("$delta")
done
echo "    Size:      $(du -h "$DMG" | cut -f1)"
echo "    SHA256:    $(cut -d' ' -f1 "$DMG.sha256")"
echo ""
echo "1. Commit $FEED_FILE (and release/team-id if it was just written) and merge."
echo "2. From the merged main, make the release's single public commit (docs/RELEASING.md, step 5)."
echo "   Then run these in order: the tag, the release with these files under these exact"
echo "   names, and only then main. Until the files are up, Selway would offer a download"
echo "   that isn't there."
echo "     git -C <public clone> -c push.followTags=false push origin HEAD:refs/tags/v$VERSION"
echo "     gh release create v$VERSION -R $SELWAY_RELEASES_REPO --verify-tag --title \"Selway $VERSION\" \\"
echo "         --notes-file <the \"## $VERSION\" section of CHANGELOG.md> \\"
echo "        $(printf ' %q' "${RELEASE_FILES[@]}")"
echo "     git -C <public clone> -c push.followTags=false push origin main"
echo "Keep $ARCHIVES: the next release builds its deltas and feed from it."
