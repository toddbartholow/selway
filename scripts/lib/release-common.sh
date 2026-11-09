#!/bin/bash
# Shared build / sign / notarize / checksum / appcast steps for release.sh and distribute.sh.
# Source it; don't run it. Every step exits non-zero with a message on failure.
#
# Publishing (see docs/RELEASING.md):
#   SELWAY_RELEASES_REPO    the public GitHub repository releases go to (default
#                       toddbartholow/selway). Its Releases hold the DMGs and deltas; its GitHub
#                       Pages site (deployed from main:/docs) serves docs/appcast.xml, which must
#                       be the app's SUFeedURL.
#   SELWAY_ARCHIVES_DIR     release.sh only: folder Sparkle's generate_appcast works in (default
#                       $SELWAY_OUT_DIR/sparkle-archives). Keep it between releases: it holds the
#                       previous DMGs (for delta updates) and a copy of the last feed.
#   SELWAY_APPCAST          release.sh only: the committed feed (default docs/appcast.xml in this
#                       checkout). release.sh extends it and writes the new signed feed back to
#                       it; it doesn't exist before the first release. In a git checkout it must
#                       match docs/appcast.xml on origin/main (fetched first) whenever that exists.
#   SELWAY_SKIP_FEED_ORIGIN_CHECK=1
#                       release.sh only: don't compare the committed feed with origin/main's
#                       docs/appcast.xml (for example offline, or a release from another remote).
#                       The other feed checks still run.
#   SELWAY_RELEASE_NOTES    release.sh only: release notes (.md or .html) for this version.
#                       Default: release-notes/<version>.md or .html if present.
#   SELWAY_SPARKLE_BIN      folder with Sparkle's generate_appcast / sign_update (default: found in
#                       the SwiftPM artifacts of the build).
#
# Signing (see docs/RELEASING.md):
#   SELWAY_SIGN_IDENTITY    codesign identity. Unset or "-" = ad-hoc (no Apple account). For
#                       Developer ID: "Developer ID Application: Your Name (TEAMID)".
#   SELWAY_NOTARY_PROFILE   notarytool keychain profile (xcrun notarytool store-credentials).
#                       Required with a Developer ID identity unless SELWAY_SKIP_NOTARIZE=1
#                       (distribute.sh only; release.sh refuses it, since its builds go into
#                       the appcast).
#   SELWAY_NOTARY_TIMEOUT   how long to wait for notarization (default 1h).
#   SELWAY_UPDATE_PRIVATE_KEY_FILE
#                       EdDSA update key file; default is the login Keychain (scripts/update-key.sh).
#                       Either way it reaches Sparkle's tools only through a pipe.
#   SELWAY_SKIP_TESTS=1     release.sh only: skip ./scripts/test.sh --app before building.
# Testing the pipeline without Xcode:
#   SELWAY_PREBUILT_APP     use this already-built Selway.app instead of running xcodebuild.

SELWAY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELWAY_SIGN_IDENTITY="${SELWAY_SIGN_IDENTITY:--}"
SELWAY_APP_ENTITLEMENTS="$SELWAY_ROOT/Selway/Selway.entitlements"
SELWAY_EXT_ENTITLEMENTS="$SELWAY_ROOT/SelwayExtension/SelwayExtension.entitlements"
SELWAY_RELEASES_REPO="${SELWAY_RELEASES_REPO:-toddbartholow/selway}"
# Committed record of the Developer ID Team ID releases are signed with, written by release.sh
# after the first Developer ID release. Once it exists, every release must use that Team ID.
SELWAY_TEAM_ID_FILE="${SELWAY_TEAM_ID_FILE:-$SELWAY_ROOT/release/team-id}"

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo "==> $*"; }

selway_is_developer_id() { [ "$SELWAY_SIGN_IDENTITY" != "-" ]; }

# selway_plist_value APP KEY — prints a key from the app's Info.plist (empty if absent).
selway_plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true
}

# selway_attach DMG [hdiutil options…] — attaches and prints the first mount point, read from
# `hdiutil attach -plist` (the human-readable output varies, and -quiet prints nothing).
selway_attach() {
    local dmg="$1" plist i mp
    shift
    plist=$(hdiutil attach "$dmg" -plist "$@") || return 1
    for i in 0 1 2 3 4 5 6 7 8 9; do
        mp=$(plutil -extract "system-entities.$i.mount-point" raw -o - - <<<"$plist" 2>/dev/null) || continue
        if [ -n "$mp" ] && [ -d "$mp" ]; then echo "$mp"; return 0; fi
    done
    # Attached but no mount point found: don't leave the image attached.
    local dev
    dev=$(plutil -extract "system-entities.0.dev-entry" raw -o - - <<<"$plist" 2>/dev/null) \
        && hdiutil detach "$dev" -force -quiet >/dev/null 2>&1
    return 1
}

# Checks the tools and settings a release needs before spending minutes building.
selway_preflight() {
    if [ -z "${SELWAY_PREBUILT_APP:-}" ]; then
        xcodebuild -version >/dev/null 2>&1 \
            || die "xcodebuild needs a full Xcode install (Command Line Tools alone can't build the app)."
    fi
    if selway_is_developer_id; then
        local identities
        identities=$(security find-identity -v -p codesigning) || die "security find-identity failed"
        grep -F "\"$SELWAY_SIGN_IDENTITY\"" >/dev/null <<<"$identities" \
            || die "signing identity not found in the keychain: $SELWAY_SIGN_IDENTITY"
        if [ "${SELWAY_SKIP_NOTARIZE:-0}" != 1 ]; then
            [ -n "${SELWAY_NOTARY_PROFILE:-}" ] \
                || die "SELWAY_NOTARY_PROFILE is required with a Developer ID identity (or set SELWAY_SKIP_NOTARIZE=1)."
            xcrun --find notarytool >/dev/null 2>&1 || die "xcrun notarytool not found."
            xcrun --find stapler >/dev/null 2>&1 || die "xcrun stapler not found."
        fi
        echo "    Signing: $SELWAY_SIGN_IDENTITY"
    else
        echo "    Signing: ad-hoc (set SELWAY_SIGN_IDENTITY for Developer ID)"
    fi
    # A language ships only when it's complete (docs/TRANSLATING.md).
    local catalogs=() catalog status
    while IFS= read -r catalog; do catalogs+=("$catalog"); done \
        < <(find "$SELWAY_ROOT/Selway" "$SELWAY_ROOT/SelwayExtension" -name '*.xcstrings' -not -path '*/build/*' | sort)
    ((${#catalogs[@]})) || die "no String Catalogs found under Selway/ or SelwayExtension/"
    if ! status=$(/usr/bin/python3 "$SELWAY_ROOT/scripts/lib/l10n.py" catalog-status --check "${catalogs[@]}"); then
        sed 's/^/    /' <<<"$status"
        die "a translation is incomplete"
    fi
    sed 's/^/    /' <<<"$status"
}

# selway_feed_url — the appcast URL on the releases repository's GitHub Pages site.
selway_feed_url() {
    local owner="${SELWAY_RELEASES_REPO%%/*}" repo="${SELWAY_RELEASES_REPO#*/}"
    [[ "$SELWAY_RELEASES_REPO" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] \
        || die "SELWAY_RELEASES_REPO must be OWNER/REPO (got: $SELWAY_RELEASES_REPO)"
    echo "https://$(tr '[:upper:]' '[:lower:]' <<<"$owner").github.io/$repo/appcast.xml"
}

# selway_download_prefix VERSION — where the release's files are downloaded from.
selway_download_prefix() {
    echo "https://github.com/$SELWAY_RELEASES_REPO/releases/download/v$1/"
}

# selway_plist_file_value PLIST KEY — a key from an Info.plist file (empty if absent).
selway_plist_file_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

# selway_check_build_number BUILD [APPCAST [VERSION]] — Sparkle decides what is newer by
# CFBundleVersion (CURRENT_PROJECT_VERSION), not the marketing version. A release needs a
# positive integer build number strictly greater than every build already in the appcast, or
# installed copies would never be offered it, and a marketing version (its v<VERSION> release)
# that isn't in the appcast yet. The appcast is read as XML (update-key.sh
# check-appcast-versions, DTDs refused), so no way of writing a build number can hide one.
selway_check_build_number() {
    local build="$1" appcast="${2:-}" version="${3:-}"
    [[ "$build" =~ ^[1-9][0-9]{0,8}$ ]] \
        || die "CFBundleVersion (CURRENT_PROJECT_VERSION) must be a positive integer, got '$build'"
    [ -n "$appcast" ] && [ -f "$appcast" ] || return 0
    "$SELWAY_ROOT/scripts/update-key.sh" check-appcast-versions "$appcast" "$build" "$version" \
        || die "the new build/version can't go into $appcast (see above)"
}

# selway_project_build — CURRENT_PROJECT_VERSION from the Xcode project; every configuration
# of every target must agree.
selway_project_build() {
    local values
    values=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \(.*\);$/\1/p' "$SELWAY_ROOT/Selway.xcodeproj/project.pbxproj" | sort -u)
    [ -n "$values" ] && [ "$(wc -l <<<"$values" | tr -d ' ')" = 1 ] \
        || die "CURRENT_PROJECT_VERSION differs between targets/configurations in Selway.xcodeproj: $(echo $values)"
    echo "$values"
}

# selway_project_version — MARKETING_VERSION from the Xcode project; all must agree.
selway_project_version() {
    local values
    values=$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);$/\1/p' "$SELWAY_ROOT/Selway.xcodeproj/project.pbxproj" | sort -u)
    [ -n "$values" ] && [ "$(wc -l <<<"$values" | tr -d ' ')" = 1 ] \
        || die "MARKETING_VERSION differs between targets/configurations in Selway.xcodeproj: $(echo $values)"
    echo "$values"
}

# selway_feed_file prints the committed feed: $SELWAY_APPCAST, or docs/appcast.xml in this checkout.
# GitHub Pages on the releases repository serves it once the release reaches that repository.
selway_feed_file() {
    echo "${SELWAY_APPCAST:-$SELWAY_ROOT/docs/appcast.xml}"
}

# selway_existing_appcast ARCHIVES_DIR prints the appcast a new release extends, or nothing
# for the first release: the committed feed (selway_feed_file) if it exists. The archives
# folder's appcast.xml is the feed the last release made, so when it exists the committed feed
# must exist too and have the same content; otherwise the checkout is behind the last release
# (or that release's feed was never committed). That comparison needs the archives folder the
# last release used, so the committed feed is also compared with origin/main's
# (selway_check_feed_on_origin). Call it in a plain assignment (EXISTING=$(…)) so a failure
# stops the script.
selway_existing_appcast() {
    local archives="$1" feed
    feed=$(selway_feed_file)
    [ -d "$(dirname "$feed")" ] || die "SELWAY_APPCAST's folder doesn't exist: $feed"
    [ ! -e "$feed" ] || [ -f "$feed" ] || die "SELWAY_APPCAST is not a file: $feed"
    selway_check_feed_on_origin "$feed"
    if [ -f "$feed" ]; then
        if [ -f "$archives/appcast.xml" ] && ! cmp -s "$feed" "$archives/appcast.xml"; then
            die "$feed differs from $archives/appcast.xml, the feed the last release made. Commit that feed as $feed (it is what should be live) and merge it, then run again from an up-to-date checkout. Don't delete the archives copy to get past this check: the feed has to list every DMG in the archives folder anyway."
        fi
        echo "$feed"
    elif [ -f "$archives/appcast.xml" ]; then
        die "$archives/appcast.xml (the feed the last release made) exists but $feed doesn't. Commit that feed as $feed and merge it, then run again from an up-to-date checkout."
    fi
}

# selway_check_feed_on_origin FEED: in a git checkout (SELWAY_ROOT holds .git), fetches origin's
# main (read-only) and requires FEED to be byte for byte docs/appcast.xml on origin/main, the feed the
# last release merged. That catches a checkout that is behind even when the archives folder is new
# or was never shared with it. Skipped when origin/main has no docs/appcast.xml (before the first
# release), outside a git checkout (a source archive, the tests' temporary roots), and with
# SELWAY_SKIP_FEED_ORIGIN_CHECK=1. Prints nothing on stdout (selway_existing_appcast's output is
# the feed path).
selway_check_feed_on_origin() {
    local feed="$1" published actual
    if [ "${SELWAY_SKIP_FEED_ORIGIN_CHECK:-0}" = 1 ]; then
        echo "    WARNING: SELWAY_SKIP_FEED_ORIGIN_CHECK=1, not comparing $feed with origin/main." >&2
        return 0
    fi
    [ -e "$SELWAY_ROOT/.git" ] || return 0
    # Only origin's main, into refs/remotes/origin/main, and that ref by its full name (a
    # branch or tag called origin/main can't stand in for it). No password prompt.
    GIT_TERMINAL_PROMPT=0 git -C "$SELWAY_ROOT" fetch --quiet --no-tags origin \
            '+refs/heads/main:refs/remotes/origin/main' >&2 \
        || die "couldn't fetch origin's main in $SELWAY_ROOT to compare $feed with origin/main:docs/appcast.xml. Fix the remote, or set SELWAY_SKIP_FEED_ORIGIN_CHECK=1 if you have checked the feed by hand."
    git -C "$SELWAY_ROOT" rev-parse --verify --quiet 'refs/remotes/origin/main^{commit}' >/dev/null \
        || die "$SELWAY_ROOT has no origin/main to compare $feed with. Set SELWAY_SKIP_FEED_ORIGIN_CHECK=1 if this checkout releases from another branch or remote."
    # No feed on origin/main yet: the first release.
    published=$(git -C "$SELWAY_ROOT" rev-parse --verify --quiet 'refs/remotes/origin/main:docs/appcast.xml') || return 0
    [ -f "$feed" ] \
        || die "origin/main has docs/appcast.xml but $feed doesn't exist. This checkout is behind the last release: update it from origin/main and run again."
    actual=$(git -C "$SELWAY_ROOT" hash-object --no-filters -- "$feed") || die "couldn't read $feed"
    [ "$actual" = "$published" ] \
        || die "$feed differs from docs/appcast.xml on origin/main, the feed the last release merged. This checkout is behind (or the feed was edited): update it from origin/main and run again. Set SELWAY_SKIP_FEED_ORIGIN_CHECK=1 only if origin/main is the one that is out of date."
}

# selway_write_feed NEW_APPCAST: after a verified release, replaces the committed feed
# (selway_feed_file) with NEW_APPCAST, through a temporary file in the same folder so it is
# never left half-written. Commit the result.
selway_write_feed() {
    local new="$1" feed tmp
    feed=$(selway_feed_file)
    [ -f "$new" ] || die "no new appcast at $new"
    tmp=$(mktemp "$(dirname "$feed")/.appcast.XXXXXX") || die "couldn't write next to $feed"
    if ! cp "$new" "$tmp" || ! chmod 644 "$tmp" || ! mv -f "$tmp" "$feed"; then
        rm -f "$tmp"
        die "couldn't write $feed (the new feed is in $new)"
    fi
}

# selway_check_archives_covered ARCHIVES_DIR APPCAST VERSION — every earlier DMG kept in the
# archives folder must have an item in the feed being extended. Otherwise the feed is older than
# what was released (for example an old signed feed replayed after archives/appcast.xml went
# missing), and extending it would drop published releases. With no feed at all, there must be
# no earlier DMGs either.
selway_check_archives_covered() {
    local archives="$1" appcast="$2" version="$3" dmg
    if [ -z "$appcast" ]; then
        for dmg in "$archives"/Selway-*.dmg; do
            [ -f "$dmg" ] && [ "$(basename "$dmg")" != "Selway-$version.dmg" ] || continue
            die "$archives holds earlier releases ($(basename "$dmg")) but there is no appcast to extend. Restore the published feed as $(selway_feed_file)."
        done
        return 0
    fi
    "$SELWAY_ROOT/scripts/update-key.sh" check-archives-covered "$appcast" "$archives" "Selway-$version.dmg" \
        || die "the appcast $appcast doesn't list every release in $archives (an older feed?); refusing to extend it"
}

# selway_verify_existing_appcast APPCAST PUBKEY — the feed a release builds on must carry a valid
# signature for SUPublicEDKey (and no DTD): an edited or planted feed is never extended and
# re-signed. No-op for the first release (APPCAST empty).
selway_verify_existing_appcast() {
    [ -n "$1" ] || return 0
    "$SELWAY_ROOT/scripts/update-key.sh" verify-feed "$1" "$2" \
        || die "the existing appcast $1 isn't signed with SUPublicEDKey (or isn't a plain appcast); refusing to build on it"
}

# selway_previous_team ARCHIVES_DIR VERSION — the Developer ID Team ID earlier releases were signed
# with, read from the code signature of the DMGs in the archives folder (other than this
# version's). Prints nothing if they were all ad-hoc (unsigned DMGs). Dies if they disagree.
selway_previous_team() {
    local archives="$1" version="$2" dmg details team teams=""
    for dmg in "$archives"/Selway-*.dmg; do
        [ -f "$dmg" ] && [ "$(basename "$dmg")" != "Selway-$version.dmg" ] || continue
        details=$(codesign -dv --verbose=2 "$dmg" 2>&1 || true)
        team=$(sed -n 's/^TeamIdentifier=//p' <<<"$details")
        if [ -n "$team" ] && [ "$team" != "not set" ]; then teams+="$team"$'\n'; fi
    done
    teams=$(sort -u <<<"$teams" | sed '/^$/d')
    [ "$(wc -l <<<"$teams" | tr -d ' ')" -le 1 ] || die "earlier DMGs in $archives are signed by different Team IDs: $(echo $teams)"
    [ -z "$teams" ] || echo "$teams"
}

# selway_recorded_team — the Team ID in $SELWAY_TEAM_ID_FILE, or nothing if there's no record yet.
selway_recorded_team() {
    [ -f "$SELWAY_TEAM_ID_FILE" ] || return 0
    local team
    team=$(tr -d '[:space:]' <"$SELWAY_TEAM_ID_FILE")
    [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || die "$SELWAY_TEAM_ID_FILE doesn't hold a 10-character Team ID"
    echo "$team"
}

# selway_check_team_continuity ARCHIVES_DIR VERSION [TEAM] — once a Developer ID release has
# shipped, every later one must be Developer ID–signed by the same Team ID: copies that
# rely on that Team ID shouldn't be handed an ad-hoc build. Two signals: the committed record
# ($SELWAY_TEAM_ID_FILE, which survives a lost archives folder) and the code signature of the
# DMGs kept in the archives folder. TEAM is this release's (after signing); without it, the
# identity name's "(TEAMID)" suffix is checked against the record.
selway_check_team_continuity() {
    local recorded previous
    recorded=$(selway_recorded_team) || exit 1
    previous=$(selway_previous_team "$1" "$2") || exit 1
    if [ -n "$recorded" ] && [ -n "$previous" ] && [ "$recorded" != "$previous" ]; then
        die "$SELWAY_TEAM_ID_FILE records Team ID $recorded, but earlier DMGs in $1 are signed by $previous"
    fi
    local expected="${recorded:-$previous}"
    [ -n "$expected" ] || return 0
    selway_is_developer_id \
        || die "earlier releases were signed with Developer ID Team $expected; an ad-hoc release can't follow. Set SELWAY_SIGN_IDENTITY."
    if [ -n "${3:-}" ]; then
        [ "$3" = "$expected" ] || die "this release is signed by Team ID $3, earlier ones by $expected"
    elif [[ "$SELWAY_SIGN_IDENTITY" != *"($expected)" ]]; then
        die "SELWAY_SIGN_IDENTITY ($SELWAY_SIGN_IDENTITY) isn't for Team ID $expected, which earlier releases use"
    fi
}

# selway_record_team TEAM — after a Developer ID release: creates $SELWAY_TEAM_ID_FILE if it
# doesn't exist yet (and says to commit it), or checks that it matches.
selway_record_team() {
    local team="$1" recorded
    [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || die "unexpected Team ID '$team'"
    recorded=$(selway_recorded_team) || exit 1
    if [ -z "$recorded" ]; then
        mkdir -p "$(dirname "$SELWAY_TEAM_ID_FILE")"
        echo "$team" >"$SELWAY_TEAM_ID_FILE" || die "couldn't write $SELWAY_TEAM_ID_FILE"
        echo "    Recorded Team ID $team in $SELWAY_TEAM_ID_FILE. Commit it: from now on every release must use it."
    elif [ "$recorded" != "$team" ]; then
        die "$SELWAY_TEAM_ID_FILE records Team ID $recorded, not $team"
    fi
}

# selway_preflight_sparkle ARCHIVES_DIR EXISTING_APPCAST — before building, checks the Sparkle
# settings in Info.plist (feed URL matches SELWAY_RELEASES_REPO, a 32-byte SUPublicEDKey, signed
# feeds on), the existing appcast's signature, the build number and version against it, Team ID
# continuity with earlier releases, and that an update-signing key is available,
# so a mistake fails now rather than after a long build and notarization. A key file is also
# checked against SUPublicEDKey here. A Keychain key is only looked up (its attributes, which
# needs no permission): reading it asks every time, so a release reads it once, when it pipes
# it to generate_appcast; the result is then checked against SUPublicEDKey.
selway_preflight_sparkle() {
    local archives="$1" existing="$2" plist="$SELWAY_ROOT/Selway/Info.plist" build version expected actual feed
    if [ -n "${SELWAY_PREBUILT_APP:-}" ]; then plist="$SELWAY_PREBUILT_APP/Contents/Info.plist"; fi
    feed=$(selway_feed_url) || exit 1
    [ "$(selway_plist_file_value "$plist" SUFeedURL)" = "$feed" ] \
        || die "SUFeedURL in $plist isn't $feed (from SELWAY_RELEASES_REPO=$SELWAY_RELEASES_REPO)"
    expected=$(selway_plist_file_value "$plist" SUPublicEDKey)
    [ "$(base64 -D <<<"$expected" 2>/dev/null | wc -c | tr -d ' ')" = 32 ] \
        || die "SUPublicEDKey in $plist isn't a base64 32-byte Ed25519 key. See docs/RELEASING.md."
    [ "$(selway_plist_file_value "$plist" SURequireSignedFeed)" = true ] \
        || die "SURequireSignedFeed isn't true in $plist"
    echo "    Feed: $feed"

    if [ -n "${SELWAY_PREBUILT_APP:-}" ]; then
        build=$(selway_plist_file_value "$plist" CFBundleVersion)
        version=$(selway_plist_file_value "$plist" CFBundleShortVersionString)
    else
        build=$(selway_project_build) || exit 1
        version=$(selway_project_version) || exit 1
    fi
    selway_verify_existing_appcast "$existing" "$expected"
    selway_check_build_number "$build" "$existing" "$version"
    selway_check_archives_covered "$archives" "$existing" "$version"
    selway_check_team_continuity "$archives" "$version"

    if [ -n "${SELWAY_UPDATE_PRIVATE_KEY_FILE:-}" ]; then
        actual=$("$SELWAY_ROOT/scripts/update-key.sh" public-key) \
            || die "the update-signing key file can't be used (SELWAY_UPDATE_PRIVATE_KEY_FILE)"
        [ "$actual" = "$expected" ] \
            || die "your update-signing key doesn't match SUPublicEDKey in Info.plist — installed copies would reject this release"
        echo "    Update key: matches SUPublicEDKey"
    else
        security find-generic-password -s "Selway Update Signing" -a ed25519 >/dev/null 2>&1 \
            || die "no update-signing key in the login Keychain (scripts/update-key.sh generate or import), and SELWAY_UPDATE_PRIVATE_KEY_FILE isn't set"
        echo "    Update key: in the login Keychain (read once, when the appcast is generated)"
    fi
}

# selway_prefix_maps FLAG DERIVED_DATA — the compiler options that rewrite the build's
# absolute paths (the derived data folder, then the checkout, each as given and as its real
# path) to relative ones, one FLAG<old>=<new> per path, quoted for an xcodebuild setting.
selway_prefix_maps() {
    local flag="$1" dd="$2" pair map real out="" seen=" "
    dd=$(cd "$dd" && pwd) || die "can't resolve $dd"
    # The derived data folder first: it is usually inside the checkout, and the compilers
    # apply the first (Swift) or the longest (clang) prefix that matches.
    for pair in "$dd=build" "$SELWAY_ROOT=."; do
        real="$(cd "${pair%=*}" && pwd -P)=${pair##*=}"
        for map in "$pair" "$real"; do
            case "$seen" in *" $map "*) continue ;; esac
            seen="$seen$map "
            case "$map" in *[\"\\]*) die "the build path $map has a quote or backslash" ;; esac
            out="$out $flag\"$map\""
        done
    done
    echo "${out# }"
}

# selway_strip_debug APP — removes debug symbols (the stabs that name every source and object
# file by absolute path) and local symbols from the app's own Mach-O files, before signing.
# Sparkle.framework is left as Sparkle built it; selway_sign_app signs everything again.
selway_strip_debug() {
    local app="$1" file
    while IFS= read -r -d '' file; do
        case "$file" in "$app/Contents/Frameworks/Sparkle.framework/"*) continue ;; esac
        [ -L "$file" ] && continue
        case "$(head -c 4 "$file" | od -An -tx1 | tr -d ' \n')" in
            cffaedfe | cefaedfe | feedfacf | feedface | cafebabe | bebafeca) ;;
            *) continue ;;
        esac
        strip -S -x "$file" 2>/dev/null || die "strip failed: $file"
    done < <(find "$app" -type f -print0)
}

# selway_check_build_paths APP DERIVED_DATA — refuses an app whose own Mach-O files or
# resources still name the checkout, the derived data folder or the home folder: those paths
# would ship in the DMG and its deltas. Sparkle.framework (built elsewhere) is left out.
selway_check_build_paths() {
    local app="$1" dd="$2" file hits="" path pattern="" symbols
    dd=$(cd "$dd" && pwd) || die "can't resolve $dd"
    for path in "$SELWAY_ROOT" "$(cd "$SELWAY_ROOT" && pwd -P)" "$dd" "$(cd "$dd" && pwd -P)" "$HOME"; do
        [ -n "$path" ] && [ "$path" != / ] || continue
        pattern="$pattern${pattern:+|}$(printf '%s' "$path" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"
    done
    while IFS= read -r -d '' file; do
        case "$file" in "$app/Contents/Frameworks/Sparkle.framework/"*) continue ;; esac
        if LC_ALL=C grep -aqE "$pattern" "$file"; then
            hits="$hits    ${file#"$app"/}"$'\n'
            continue
        fi
        # nm's whole output first: piped into grep -q, nm would die of SIGPIPE when grep
        # stops at the first match, and under pipefail the match would read as a miss.
        symbols=$(nm -ap "$file" 2>/dev/null) || symbols=""
        if grep -qE ' (SO|SOL|OSO|BINCL|EXCL) ' <<<"$symbols"; then
            hits="$hits    ${file#"$app"/} (debug symbols)"$'\n'
        fi
    done < <(find "$app" -type f -print0)
    [ -z "$hits" ] || die "$(printf 'the built app still names build paths (the checkout, derived data or home folder) or has debug symbols in:\n%s' "$hits")"
    [ -z "$(find "$app" -name '*.dSYM' -print -quit)" ] || die "the built app holds a dSYM"
}

# selway_build_app ARCHS DERIVED_DATA — builds Release unsigned and prints the .app path.
# Signing happens afterwards in selway_sign_app so both scripts sign identically.
# The build maps its absolute paths to relative ones in the debug, coverage and index info
# (-file-prefix-map, -ffile-prefix-map; #file and #filePath literals aren't covered), strips
# debug symbols from the app's own binaries, and then selway_check_build_paths stops the
# release if the checkout, derived data or home folder is still named anywhere in the app,
# such as by a literal path. The dSYMs stay next to the app, outside it (selway_keep_dsyms).
selway_build_app() {
    local archs="$1" dd="$2" log
    if [ -n "${SELWAY_PREBUILT_APP:-}" ]; then
        [ -d "$SELWAY_PREBUILT_APP" ] || die "SELWAY_PREBUILT_APP is not a directory: $SELWAY_PREBUILT_APP"
        rm -rf "$dd/prebuilt" && mkdir -p "$dd/prebuilt"
        ditto "$SELWAY_PREBUILT_APP" "$dd/prebuilt/$(basename "$SELWAY_PREBUILT_APP")" || die "couldn't copy $SELWAY_PREBUILT_APP"
        echo "$dd/prebuilt/$(basename "$SELWAY_PREBUILT_APP")"
        return
    fi
    rm -rf "$dd"
    mkdir -p "$dd"
    log="$dd/xcodebuild.log"
    local swift_maps c_maps
    swift_maps=$(selway_prefix_maps "-file-prefix-map " "$dd") || exit 1
    c_maps=$(selway_prefix_maps "-ffile-prefix-map=" "$dd") || exit 1
    if ! xcodebuild \
            -project "$SELWAY_ROOT/Selway.xcodeproj" \
            -scheme Selway \
            -configuration Release \
            -derivedDataPath "$dd" \
            -destination 'generic/platform=macOS' \
            ARCHS="$archs" \
            ONLY_ACTIVE_ARCH=NO \
            CODE_SIGNING_ALLOWED=NO \
            DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
            COPY_PHASE_STRIP=NO \
            OTHER_SWIFT_FLAGS="\$(inherited) $swift_maps" \
            OTHER_CFLAGS="\$(inherited) $c_maps" \
            clean build >"$log" 2>&1; then
        grep -E "error:" "$log" >&2 || tail -40 "$log" >&2
        die "xcodebuild failed (full log: $log)"
    fi
    local app="$dd/Build/Products/Release/Selway.app"
    [ -d "$app" ] || die "build did not produce $app"
    selway_strip_debug "$app"
    selway_check_build_paths "$app" "$dd"
    echo "$app"
}

# selway_keep_dsyms APP DEST: copies the dSYMs built next to APP (Selway.app.dSYM and the
# extension's) to DEST, replacing what an earlier run left there. Release binaries are
# stripped, so these are the only way to symbolicate their crash reports, and the next build
# deletes the derived data folder they come from. A prebuilt app (SELWAY_PREBUILT_APP) has
# none.
selway_keep_dsyms() {
    local app="$1" dest="$2" dsym found=0 partial
    if [ -n "${SELWAY_PREBUILT_APP:-}" ]; then
        echo "    dSYMs: none (SELWAY_PREBUILT_APP)"
        return 0
    fi
    partial="$dest.partial"
    if ! { rm -rf "$partial" && mkdir -p "$partial"; }; then die "couldn't create $partial"; fi
    for dsym in "$(dirname "$app")"/*.dSYM; do
        [ -d "$dsym" ] || continue
        ditto "$dsym" "$partial/$(basename "$dsym")" || die "couldn't copy $dsym to $partial"
        found=1
    done
    [ "$found" = 1 ] || { rm -rf "$partial"; die "the build left no dSYMs next to $app"; }
    if ! { rm -rf "$dest" && mv "$partial" "$dest"; }; then die "couldn't move the dSYMs from $partial to $dest"; fi
    echo "    dSYMs: $dest"
}

# selway_sign_sparkle FRAMEWORK FLAGS… — signs Sparkle's helpers inside-out, as Sparkle documents
# for builds not exported by Xcode (sparkle-project.org/documentation/sandboxing): the XPC
# services (Downloader keeps its entitlements), Autoupdate, Updater.app, then the framework.
# No --deep: the helpers' entitlements differ.
selway_sign_sparkle() {
    local framework="$1" item
    shift
    local version="$framework/Versions/B"
    [ -d "$version" ] || die "unexpected Sparkle.framework layout (no Versions/B): $framework"
    for item in "$version/XPCServices/Installer.xpc" "$version/XPCServices/Downloader.xpc" \
                "$version/Autoupdate" "$version/Updater.app"; do
        [ -e "$item" ] || continue
        if [ "$(basename "$item")" = Downloader.xpc ]; then
            codesign "$@" --preserve-metadata=entitlements --sign "$SELWAY_SIGN_IDENTITY" "$item" || die "codesign failed: $item"
        else
            codesign "$@" --sign "$SELWAY_SIGN_IDENTITY" "$item" || die "codesign failed: $item"
        fi
    done
    [ -e "$version/Autoupdate" ] && [ -d "$version/Updater.app" ] \
        || die "Sparkle.framework is missing Autoupdate or Updater.app: $framework"
    codesign "$@" --sign "$SELWAY_SIGN_IDENTITY" "$framework" || die "codesign failed: $framework"
}

# selway_sign_app APP — signs nested code then the app, with the hardened runtime.
selway_sign_app() {
    local app="$1" flags=(--force --options runtime)
    if selway_is_developer_id; then flags+=(--timestamp); else flags+=(--timestamp=none); fi

    local item
    [ -d "$app/Contents/Frameworks/Sparkle.framework" ] || die "Sparkle.framework isn't embedded in $app"
    for item in "$app"/Contents/Frameworks/* ; do
        [ -e "$item" ] || continue
        if [ "$(basename "$item")" = Sparkle.framework ]; then
            selway_sign_sparkle "$item" "${flags[@]}"
        else
            codesign "${flags[@]}" --sign "$SELWAY_SIGN_IDENTITY" "$item" || die "codesign failed: $item"
        fi
    done
    for item in "$app"/Contents/PlugIns/*.appex ; do
        [ -e "$item" ] || continue
        codesign "${flags[@]}" --entitlements "$SELWAY_EXT_ENTITLEMENTS" --sign "$SELWAY_SIGN_IDENTITY" "$item" \
            || die "codesign failed: $item"
    done
    # Library validation only loads frameworks signed by the app's own Team ID, and ad-hoc
    # signatures have none, so an ad-hoc app can't load Sparkle.framework and dies at launch.
    # Ad-hoc builds turn it off; Developer ID builds keep it, since Sparkle shares their Team ID.
    local entitlements="$SELWAY_APP_ENTITLEMENTS"
    if ! selway_is_developer_id; then
        # next to the app, so a concurrent run of the other script doesn't share the file
        entitlements="$(dirname "$app")/Selway-adhoc.entitlements"
        cp "$SELWAY_APP_ENTITLEMENTS" "$entitlements" || die "couldn't write $entitlements"
        /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.cs.disable-library-validation' \
            "$entitlements" >/dev/null 2>&1 || true
        /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' \
            "$entitlements" >/dev/null || die "couldn't write $entitlements"
    fi
    codesign "${flags[@]}" --entitlements "$entitlements" --sign "$SELWAY_SIGN_IDENTITY" "$app" \
        || die "codesign failed: $app"

    codesign --verify --deep --strict --verbose=2 "$app" || die "signature verification failed: $app"
    local details
    details=$(codesign -dv --verbose=2 "$app" 2>&1)
    grep -q 'flags=.*runtime' <<<"$details" || die "hardened runtime flag missing on $app"
    local sparkle="$app/Contents/Frameworks/Sparkle.framework" helper
    local helper_details
    for helper in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
        helper_details=$(codesign -dv --verbose=2 "$helper" 2>&1) || die "codesign can't read $helper"
        grep -q 'flags=.*runtime' <<<"$helper_details" || die "hardened runtime flag missing on $helper"
    done
    if selway_is_developer_id; then
        local team
        team=$(sed -n 's/^TeamIdentifier=//p' <<<"$details")
        [ -n "$team" ] && [ "$team" != "not set" ] || die "Developer ID signature has no Team ID"
        helper_details=$(codesign -dv --verbose=2 "$sparkle" 2>&1) || die "codesign can't read $sparkle"
        [ "$(sed -n 's/^TeamIdentifier=//p' <<<"$helper_details")" = "$team" ] \
            || die "Sparkle.framework isn't signed by Team ID $team"
        echo "    Signed by Team ID $team (hardened runtime, timestamped; Sparkle helpers too)"
    else
        local signed_entitlements
        signed_entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null) || true
        grep -q 'com.apple.security.cs.disable-library-validation' <<<"$signed_entitlements" \
            || die "the ad-hoc signature on $app doesn't turn off library validation, so it can't load Sparkle"
        echo "    Ad-hoc signed (hardened runtime, library validation off)"
    fi
}

# selway_sign_and_notarize_dmg DMG APP — Developer ID only: sign, notarize, staple, assess.
selway_sign_and_notarize_dmg() {
    local dmg="$1" app="$2"
    selway_is_developer_id || return 0
    codesign --force --timestamp --sign "$SELWAY_SIGN_IDENTITY" "$dmg" || die "codesign failed: $dmg"
    codesign --verify --verbose=2 "$dmg" || die "DMG signature verification failed"

    if [ "${SELWAY_SKIP_NOTARIZE:-0}" = 1 ]; then
        echo "    WARNING: SELWAY_SKIP_NOTARIZE=1 — DMG is signed but not notarized; Gatekeeper will still block it."
        return 0
    fi
    step "Notarizing (this can take a few minutes)"
    local out
    out=$(xcrun notarytool submit "$dmg" --keychain-profile "$SELWAY_NOTARY_PROFILE" \
              --wait --timeout "${SELWAY_NOTARY_TIMEOUT:-1h}" 2>&1) || {
        echo "$out" >&2; die "notarytool submit failed"; }
    printf '    %s\n' "$out"
    grep -q 'status: Accepted' <<<"$out" \
        || die "notarization was not accepted; see: xcrun notarytool log <submission id> --keychain-profile \"$SELWAY_NOTARY_PROFILE\""
    xcrun stapler staple "$dmg" || die "stapler staple failed"
    xcrun stapler validate "$dmg" || die "stapler validate failed"

    step "Gatekeeper assessment"
    spctl -a -t open --context context:primary-signature -v "$dmg" || die "spctl rejected the DMG"
    spctl -a -vv -t exec "$app" || die "spctl rejected the app"
}

# selway_checksum DMG — writes DMG.sha256 in `shasum -c` format.
selway_checksum() {
    local dmg="$1" hash
    hash=$(shasum -a 256 "$dmg" | cut -d' ' -f1) || die "shasum failed"
    [ ${#hash} -eq 64 ] || die "unexpected shasum output for $dmg"
    echo "$hash  $(basename "$dmg")" > "$dmg.sha256"
    (cd "$(dirname "$dmg")" && shasum -a 256 -c "$(basename "$dmg").sha256" >/dev/null) || die "checksum self-check failed"
}

# selway_sparkle_bin DERIVED_DATA — prints the folder holding Sparkle's command-line tools
# (generate_appcast, sign_update): $SELWAY_SPARKLE_BIN, else the SwiftPM artifact the build
# resolved (the version pinned in Package.resolved), else any build folder's copy. Nothing is
# downloaded here.
selway_sparkle_bin() {
    local dd="$1" candidate
    local candidates=()
    if [ -n "${SELWAY_SPARKLE_BIN:-}" ]; then
        candidates=("$SELWAY_SPARKLE_BIN")
    else
        candidates=("$dd/SourcePackages/artifacts/sparkle/Sparkle/bin")
        for candidate in "$SELWAY_ROOT"/build/*/SourcePackages/artifacts/sparkle/Sparkle/bin; do
            candidates+=("$candidate")
        done
    fi
    for candidate in "${candidates[@]}"; do
        if [ -x "$candidate/generate_appcast" ] && [ -x "$candidate/sign_update" ]; then
            echo "$candidate"
            return 0
        fi
    done
    die "Sparkle's generate_appcast wasn't found. Run ./scripts/test.sh --app once (it fetches the pinned Sparkle package into build/), or set SELWAY_SPARKLE_BIN."
}

# selway_release_notes VERSION — the release notes file for VERSION, if any.
selway_release_notes() {
    local version="$1" ext
    if [ -n "${SELWAY_RELEASE_NOTES:-}" ]; then
        [ -f "$SELWAY_RELEASE_NOTES" ] || die "SELWAY_RELEASE_NOTES is not a file: $SELWAY_RELEASE_NOTES"
        case "$SELWAY_RELEASE_NOTES" in
            *.md|*.html) echo "$SELWAY_RELEASE_NOTES" ;;
            *) die "release notes must be .md or .html: $SELWAY_RELEASE_NOTES" ;;
        esac
        return 0
    fi
    for ext in md html; do
        if [ -f "$SELWAY_ROOT/release-notes/$version.$ext" ]; then
            echo "$SELWAY_ROOT/release-notes/$version.$ext"
            return 0
        fi
    done
}

# selway_sparkle_appcast DMG APP ARCHIVES_DIR SPARKLE_BIN OUT_DIR EXISTING_APPCAST — adds DMG to
# the signed appcast.
#
# 1. ARCHIVES_DIR is resolved to its real path (a symlink stays a symlink; the work happens on
#    the target's volume). A scratch folder next to it holds a copy of EXISTING_APPCAST (empty
#    for the first release), which alone is used from then on: it must verify with the app's
#    SUPublicEDKey, hold only older builds, and list every earlier DMG in ARCHIVES_DIR.
# 2. Everything happens in a scratch copy of ARCHIVES_DIR (APFS clone when possible), so a
#    failure or an interruption at any step leaves ARCHIVES_DIR exactly as it was and removes
#    the scratch folder (EXIT/INT/TERM traps, chained with any EXIT trap already set).
# 3. generate_appcast runs there without the old feed (--versions BUILD), so it makes one new
#    item: it signs the DMG, makes and signs deltas from the older DMGs, and embeds the
#    release notes. It never sees, rewrites or prunes the earlier items.
# 4. update-key.sh merge-appcast puts that item in front of the existing feed's items, which
#    are kept exactly as published, and Sparkle's sign_update signs the result.
# 5. update-key.sh verify-appcast checks it with SUPublicEDKey alone (both feeds' signatures,
#    builds, earlier items unchanged, DMG and delta signatures). Only then does the scratch
#    copy replace ARCHIVES_DIR, and appcast.xml plus this release's deltas go to OUT_DIR.
#
# The private key is read once (one Keychain prompt) into a local, unexported shell variable
# and reaches generate_appcast and sign_update only through a pipe (`--ed-key-file -`): never
# on disk or in an argument list. Refuses to run with xtrace on, which would print it.
SELWAY_SPARKLE_WORK=""
SELWAY_SPARKLE_ARCHIVES=""
selway_sparkle_cleanup() {
    [ -n "$SELWAY_SPARKLE_WORK" ] || return 0
    # Interrupted mid-commit: the old archives sit in the scratch folder. Put them back first,
    # and if that fails keep the scratch folder rather than delete the only copy.
    if [ -d "$SELWAY_SPARKLE_WORK/previous" ] && [ -n "$SELWAY_SPARKLE_ARCHIVES" ] \
            && [ ! -e "$SELWAY_SPARKLE_ARCHIVES" ]; then
        if ! mv "$SELWAY_SPARKLE_WORK/previous" "$SELWAY_SPARKLE_ARCHIVES"; then
            echo "ERROR: the archives are in $SELWAY_SPARKLE_WORK/previous; move them back to $SELWAY_SPARKLE_ARCHIVES" >&2
            SELWAY_SPARKLE_WORK=""
            return 0
        fi
    fi
    rm -rf "$SELWAY_SPARKLE_WORK"
    SELWAY_SPARKLE_WORK=""
}

selway_sparkle_appcast() {
    case "$-" in
        *x*) die "refusing to handle the signing key with xtrace (set -x) on: it would be printed" ;;
    esac
    set +a
    local dmg="$1" app="$2" archives="$3" bin="$4" out="$5" existing="${6:-}"
    local version build pub prefix name notes delta work key previous=""
    version=$(selway_plist_value "$app" CFBundleShortVersionString)
    build=$(selway_plist_value "$app" CFBundleVersion)
    pub=$(selway_plist_value "$app" SUPublicEDKey)
    prefix=$(selway_download_prefix "$version")
    name=$(basename "$dmg")
    [ "$name" = "Selway-$version.dmg" ] || die "the DMG must be named Selway-$version.dmg (got $name)"
    [ -n "$pub" ] || die "the built app has no SUPublicEDKey"
    if [ -n "$existing" ]; then [ -f "$existing" ] || die "the existing appcast $existing is missing"; fi

    mkdir -p "$archives" || die "couldn't create $archives"
    archives=$(cd "$archives" && pwd -P) || die "can't resolve $archives"
    [ "$archives" != / ] && [ "$(dirname "$archives")" != / ] || die "the archives folder can't be / or directly under it"

    # Scratch folder next to the archives (same volume, so the final swap is a rename). The
    # traps remove it however the step ends; the EXIT trap already set (if any) still runs.
    work=$(mktemp -d "$(dirname "$archives")/.sparkle-work.XXXXXX") \
        || die "couldn't create a scratch folder next to $archives (it can't be a volume's root, and its parent must be writable)"
    SELWAY_SPARKLE_WORK="$work"
    SELWAY_SPARKLE_ARCHIVES="$archives"
    local saved_exit="" saved_int saved_term
    eval "set -- $(trap -p EXIT)"; saved_exit="${3:-}"
    saved_int=$(trap -p INT); saved_term=$(trap -p TERM)
    # shellcheck disable=SC2064
    trap "selway_sparkle_cleanup; $saved_exit" EXIT
    trap 'selway_sparkle_cleanup; exit 130' INT
    trap 'selway_sparkle_cleanup; exit 143' TERM

    # Verify once, then use only this copy of the existing feed.
    if [ -n "$existing" ]; then
        previous="$work/previous-appcast.xml"
        cp "$existing" "$previous" || die "couldn't copy $existing"
    fi
    selway_verify_existing_appcast "$previous" "$pub"
    selway_check_build_number "$build" "$previous" "$version" >/dev/null
    selway_check_archives_covered "$archives" "$previous" "$version"

    if ! cp -cRp "$archives" "$work/archives" 2>/dev/null; then
        rm -rf "$work/archives"
        ditto "$archives" "$work/archives" || die "couldn't copy $archives"
    fi
    rm -f "$work/archives/appcast.xml" "$work/archives/Selway-$version.md" "$work/archives/Selway-$version.html"
    for delta in "$work/archives"/*.delta; do
        if selway_is_delta_of "$delta" "$build"; then rm -f "$delta"; fi
    done
    cp "$dmg" "$work/archives/$name" || die "couldn't copy $dmg"
    notes=$(selway_release_notes "$version") || exit 1
    if [ -n "$notes" ]; then
        cp "$notes" "$work/archives/Selway-$version.${notes##*.}" || die "couldn't copy $notes"
        echo "    Release notes: $notes (embedded in the signed appcast)"
    else
        echo "    Release notes: none (add release-notes/$version.md or set SELWAY_RELEASE_NOTES)"
    fi

    # Command substitution: export-private-key writes into a pipe, never a terminal or file.
    key=$("$SELWAY_ROOT/scripts/update-key.sh" export-private-key) \
        || die "couldn't read the update-signing key (Keychain access denied, or no key / SELWAY_UPDATE_PRIVATE_KEY_FILE?)"
    if ! printf '%s\n' "$key" | "$bin/generate_appcast" --ed-key-file - \
            --versions "$build" \
            --maximum-versions 0 \
            --download-url-prefix "$prefix" \
            --embed-release-notes \
            --link "https://github.com/$SELWAY_RELEASES_REPO/releases" \
            "$work/archives"; then
        key=""
        die "generate_appcast failed (nothing changed in $archives)"
    fi
    if ! "$SELWAY_ROOT/scripts/update-key.sh" merge-appcast "$work/archives/appcast.xml" "$previous" "$build" "$work/appcast.xml"; then
        key=""
        die "couldn't add the new item to the existing appcast (nothing changed in $archives)"
    fi
    if ! printf '%s\n' "$key" | "$bin/sign_update" --ed-key-file - "$work/appcast.xml" >/dev/null; then
        key=""
        die "sign_update couldn't sign the appcast (nothing changed in $archives)"
    fi
    key=""

    "$SELWAY_ROOT/scripts/update-key.sh" verify-appcast "$work/appcast.xml" "$pub" \
            "$work/archives/$name" "$prefix$name" "$build" "$previous" \
        || die "the new appcast doesn't verify with the app's SUPublicEDKey — does your signing key match it? (nothing changed in $archives or $out)"
    cmp -s "$dmg" "$work/archives/$name" || die "$name changed while generating the appcast"

    # Commit: the scratch copy (with the new DMG, deltas and feed) becomes the archives folder.
    mv "$work/appcast.xml" "$work/archives/appcast.xml" || die "couldn't finish $work"
    mv "$archives" "$work/previous" || die "couldn't move $archives aside"
    if ! mv "$work/archives" "$archives"; then
        if ! mv "$work/previous" "$archives"; then
            SELWAY_SPARKLE_WORK=""
            die "couldn't move the new archives into place or the old ones back: the old archives are in $work/previous"
        fi
        die "couldn't move the new archives into place; $archives is unchanged"
    fi
    selway_sparkle_cleanup
    if [ -n "$saved_exit" ]; then trap -- "$saved_exit" EXIT; else trap - EXIT; fi
    if [ -n "$saved_int" ]; then eval "$saved_int"; else trap - INT; fi
    if [ -n "$saved_term" ]; then eval "$saved_term"; else trap - TERM; fi

    rm -f "$out/appcast.xml"
    cp "$archives/appcast.xml" "$out/appcast.xml" || die "couldn't copy appcast.xml to $out"
    for delta in "$out"/*.delta; do
        if selway_is_delta_of "$delta" "$build"; then rm -f "$delta"; fi
    done
    for delta in "$archives"/*.delta; do
        if selway_is_delta_of "$delta" "$build"; then cp "$delta" "$out/" || die "couldn't copy $delta"; fi
    done
}

# selway_is_delta_of FILE BUILD — true for generate_appcast's delta from any older build to
# BUILD: <AppName><BUILD>-<old build>.delta.
selway_is_delta_of() {
    [ -f "$1" ] && [[ "$(basename "$1")" =~ ^[A-Za-z]+$2-[0-9]+\.delta$ ]]
}
