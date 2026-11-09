#!/bin/bash
# Run the SelwayCore tests: the Foundation-only model, search, preferences and
# sidebar logic in Selway/Core, plus checks of the Sparkle settings and release
# scripts (Tests/SelwayCoreTests).
#
# Testing
#   ./scripts/test.sh                     # every test (fast; no disk images, no Xcode build)
#   ./scripts/test.sh --filter Search     # suites / tests matching a pattern
#   ./scripts/test.sh --app               # the full check this Mac stands in for macOS CI with:
#                                         # resolves the pinned Sparkle package, then every test,
#                                         # including the ones that mount disk images
#                                         # (SELWAY_RUN_HDIUTIL_TESTS) and run the update-key tool
#                                         # and Sparkle's generate_appcast / sign_update with
#                                         # throwaway keys (SELWAY_RUN_TOOL_TESTS, SELWAY_SPARKLE_BIN),
#                                         # then a Debug build of the app with xcodebuild (fails
#                                         # on warnings)
#   (any other `swift test` flags pass straight through)
# A run without a filter also checks the release build's path and debug-symbol steps
# (release_build_checks below) on a few throwaway binaries; that part needs macOS.
#
# The tests never launch an app or call `open`, and never read the real update key: fixture
# bundles use their own bundle ID, and key files are throwaway ones in a temporary folder.
#
# Works with Xcode or with only the Command Line Tools (--app needs Xcode). With only the
# CLT, Swift Testing's macro plugin lives in a folder the driver doesn't search, so it's
# passed explicitly. To use the CLT while Xcode is selected (e.g. before its license has
# been accepted):
#   DEVELOPER_DIR=/Library/Developer/CommandLineTools ./scripts/test.sh
#
# Linux, the same image CI uses (build output stays out of the checkout):
#   docker run --rm -v "$PWD":/src:ro -w /src swift:6.3.3-noble \
#       swift test --scratch-path /tmp/build
set -euo pipefail
cd "$(dirname "$0")/.."

APP=0
ARGS=()
for arg in "$@"; do
    if [ "$arg" = --app ]; then APP=1; else ARGS+=("$arg"); fi
done

DEV_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
CLT_PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
SWIFT_TEST=(swift test)
if [[ "$(uname)" == Darwin && "$DEV_DIR" != *.app/* && -d "$CLT_PLUGINS" ]]; then
    SWIFT_TEST+=(-Xswiftc -plugin-path -Xswiftc "$CLT_PLUGINS")
fi

# shellcheck disable=SC2016 # step and check take their scripts as single-quoted strings to eval
# release_build_checks: the release build's path and debug-symbol steps in
# scripts/lib/release-common.sh (selway_prefix_maps, selway_strip_debug,
# selway_check_build_paths), run as release.sh runs them (bash, set -euo pipefail) on small
# binaries built with cc -g from absolute paths in a temporary folder. macOS only.
release_build_checks() {
    local tool
    for tool in cc nm strip; do
        if [[ "$(uname)" != Darwin ]] || ! command -v "$tool" >/dev/null 2>&1; then
            echo "==> Skipping the release build checks (they need macOS with cc, nm and strip)"
            return 0
        fi
    done
    echo "==> Release build checks (build paths and debug symbols)"
    local t rt passed=0 failed=0 i maps symbols
    t=${TMPDIR:-/tmp}
    rt=$(mktemp -d "${t%/}/selway-release-checks.XXXXXX")
    # shellcheck disable=SC2064 # expand $rt now
    trap "rm -rf '$rt'" EXIT
    pass() { passed=$((passed + 1)); }
    fail() { failed=$((failed + 1)); echo "    FAILED: $1"; [ -z "${2:-}" ] || printf "%s\n" "$2" | sed "s/^/      /"; }
    # step <label> <0|1> <script> [text the output must hold] [text it must not hold]: runs
    # the script with release-common.sh sourced and a scratch HOME, and wants success (0)
    # or failure (1).
    step() {
        local out status=0
        out=$(HOME="$rt/home" RT="$rt" /bin/bash -c \
            'set -euo pipefail; source scripts/lib/release-common.sh; eval "$1"' step "$3" 2>&1) || status=$?
        if [ "$2" = 0 ] && [ "$status" != 0 ]; then fail "$1: expected success (status $status)" "$out"
        elif [ "$2" = 1 ] && [ "$status" = 0 ]; then fail "$1: expected a failure" "$out"
        elif [ -n "${4:-}" ] && ! grep -qF -- "$4" <<<"$out"; then fail "$1: output lacks \"$4\"" "$out"
        elif [ -n "${5:-}" ] && grep -qF -- "$5" <<<"$out"; then fail "$1: output has \"$5\"" "$out"
        else pass; fi
    }
    # check <label> <command>
    check() { if eval "$2"; then pass; else fail "$1"; fi; }
    # stabs <binary>: does nm list debug symbols (stabs) in it?
    stabs() { symbols=$(nm -ap "$1" 2>/dev/null) || symbols=""; grep -qE ' (SO|OSO) ' <<<"$symbols"; }
    # app <name> <object>: a minimal app bundle around the linked object, with a text resource.
    app() {
        mkdir -p "$rt/$1/Selway.app/Contents/MacOS" "$rt/$1/Selway.app/Contents/Resources"
        cc "$2" -o "$rt/$1/Selway.app/Contents/MacOS/Selway"
        printf 'plain text\n' >"$rt/$1/Selway.app/Contents/Resources/notes.txt"
    }
    mkdir -p "$rt/home" "$rt/src" "$rt/obj" "$rt/dd/src" "$rt/dd/obj"

    # Stabs alone, naming paths outside the checkout, derived data and home folder. Enough
    # of them that nm is still writing when the first match is found.
    for i in $(seq 1 2000); do echo "int f$i(void) { return $i; }"; done >"$rt/src/many.c"
    echo 'int main(void) { return 0; }' >>"$rt/src/many.c"
    (cd "$rt/src" && cc -g -c "$rt/src/many.c" -o "$rt/obj/many.o")
    app stabs "$rt/obj/many.o"
    check "the fixture has stabs" 'stabs "$rt/stabs/Selway.app/Contents/MacOS/Selway"'
    step "stabs are refused before stripping" 1 'selway_check_build_paths "$RT/stabs/Selway.app" "$RT/dd"' \
        "Contents/MacOS/Selway (debug symbols)"
    step "selway_strip_debug" 0 'selway_strip_debug "$RT/stabs/Selway.app"'
    check "no stabs after stripping" '! stabs "$rt/stabs/Selway.app/Contents/MacOS/Selway"'
    check "the stripped binary still runs" '"$rt/stabs/Selway.app/Contents/MacOS/Selway"'
    check "resources are left alone" '[ "$(cat "$rt/stabs/Selway.app/Contents/Resources/notes.txt")" = "plain text" ]'
    step "passes after stripping" 0 'selway_check_build_paths "$RT/stabs/Selway.app" "$RT/dd"'

    # The prefix maps keep derived data's path out of the debug info; the objects' own
    # paths (OSO stabs) still name it until stripping.
    echo 'int main(void) { return 0; }' >"$rt/dd/src/hello.c"
    maps=$(HOME="$rt/home" /bin/bash -c 'set -euo pipefail; source scripts/lib/release-common.sh; selway_prefix_maps "-ffile-prefix-map=" "$1"' \
        maps "$rt/dd") || { fail "selway_prefix_maps" "$maps"; maps=""; }
    check "a map for derived data and for the checkout" \
        '[[ "$maps" == *"=build\""* && "$maps" == *"$(pwd -P)=.\""* ]]'
    (cd "$rt/dd" && cc -g -c "$rt/dd/src/hello.c" -o "$rt/obj/plain.o")
    (cd "$rt/dd" && eval "cc -g $maps -c \"\$rt/dd/src/hello.c\" -o \"\$rt/dd/obj/hello.o\"")
    check "without the maps the object names derived data" 'LC_ALL=C grep -aqF "$rt/dd/" "$rt/obj/plain.o"'
    check "with the maps it doesn't" '! LC_ALL=C grep -aqF "$rt/dd/" "$rt/dd/obj/hello.o"'
    app mapped "$rt/dd/obj/hello.o"
    step "an object path in derived data is refused" 1 'selway_check_build_paths "$RT/mapped/Selway.app" "$RT/dd"' \
        "    Contents/MacOS/Selway" "(debug symbols)"
    step "selway_strip_debug (mapped)" 0 'selway_strip_debug "$RT/mapped/Selway.app"'
    step "passes after stripping (mapped)" 0 'selway_check_build_paths "$RT/mapped/Selway.app" "$RT/dd"'
    mkdir -p "$rt/mapped/Selway.app/Contents/Selway.app.dSYM"
    step "a dSYM in the app is refused" 1 'selway_check_build_paths "$RT/mapped/Selway.app" "$RT/dd"' "holds a dSYM"

    rm -rf "$rt"
    trap - EXIT
    echo "    $passed passed, $failed failed"
    [ "$failed" = 0 ] || { echo "the release build checks failed" >&2; exit 1; }
}

# The release build checks run with every full run (not with a filter).
if [ "${#ARGS[@]}" = 0 ]; then release_build_checks; fi

if [ "$APP" = 0 ]; then
    exec "${SWIFT_TEST[@]}" ${ARGS[@]+"${ARGS[@]}"}
fi

[[ "$(uname)" == Darwin ]] || { echo "--app needs macOS" >&2; exit 1; }
DD="build/dd-test"
LOG="$DD/xcodebuild.log"
mkdir -p "$DD"

echo "==> Resolving the pinned Sparkle package"
if ! xcodebuild -resolvePackageDependencies -project Selway.xcodeproj -scheme Selway \
        -derivedDataPath "$DD" >"$DD/resolve.log" 2>&1; then
    tail -20 "$DD/resolve.log" >&2
    echo "couldn't resolve the Sparkle package (full log: $DD/resolve.log)" >&2
    exit 1
fi
SPARKLE_BIN="$PWD/$DD/SourcePackages/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/generate_appcast" ] || { echo "Sparkle's tools aren't in $SPARKLE_BIN" >&2; exit 1; }

echo "==> swift test (including disk-image, update-key and Sparkle tool tests)"
SELWAY_RUN_HDIUTIL_TESTS=1 SELWAY_RUN_TOOL_TESTS=1 SELWAY_SPARKLE_BIN="$SPARKLE_BIN" \
    "${SWIFT_TEST[@]}" ${ARGS[@]+"${ARGS[@]}"}

echo "==> xcodebuild Debug build of the app"
if ! xcodebuild -project Selway.xcodeproj -scheme Selway -configuration Debug \
        -derivedDataPath "$DD" CODE_SIGN_IDENTITY=- build >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" >&2 || tail -40 "$LOG" >&2
    echo "xcodebuild failed (full log: $LOG)" >&2
    exit 1
fi
# Compiler warnings in our sources fail the check (Xcode's own tool chatter doesn't count).
if grep -E "^/.*:[0-9]+:[0-9]+: warning:" "$LOG" | sort -u | grep . >&2; then
    echo "the app built with warnings (full log: $LOG)" >&2
    exit 1
fi

echo "==> Checking String Catalogs"
./scripts/sync-strings.sh --check

echo "==> All checks passed"
