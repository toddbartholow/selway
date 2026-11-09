#!/bin/bash
# Run Selway's UI tests (SelwayUITests, XCUITest) on this Mac.
#
#   ./scripts/ui-test.sh                                 # every UI test
#   ./scripts/ui-test.sh ListViewTests                   # one class…
#   ./scripts/ui-test.sh ListViewTests/testShiftClickExtendsTheSelection   # …or one test
#   ./scripts/ui-test.sh --build-only                    # build them, run nothing (safe any time)
#
# !! These tests DRIVE THE MOUSE AND KEYBOARD. While they run (a few minutes) they click,
#    double-click, drag and type in windows they open; don't use the Mac meanwhile, and
#    expect the pointer to move. Run them on purpose, never from CI: there is no macOS CI
#    job for them and there mustn't be (macOS runners cost 10x Linux, and they need a
#    logged-in desktop). The script refuses to run when CI or GITHUB_ACTIONS is set.
#
# Ask whoever is at the Mac before every test run, since it takes over their mouse and
#    keyboard (--build-only doesn't, so it needs no asking). Even so, a UI change isn't done
#    until this script has exercised it: `swift test` and a clean build don't show that a
#    view works.
#
# The first run may ask for permission:
#   - macOS asks for an administrator password to "enable UI automation" (Xcode Helper /
#     testmanagerd), and may ask again later. To stop it asking, once per Mac:
#         sudo automationmodetool enable-automationmode-without-authentication
#     (`automationmodetool` alone shows the current setting.)
#   - If macOS asks whether Terminal (or the app running this script) may control the
#     computer, allow it in System Settings > Privacy & Security > Accessibility.
#
# What it touches. The tests never touch your own Selway: they build the UITest
# configuration, an app with its own bundle identifier (studio.irq.selway.uitest), so its
# preferences, saved windows and Sparkle state are separate, with no Finder extension
# embedded; the app starts from factory settings on every launch, never checks for updates
# and can't change the folder-handler setting. Files: each test makes its own folder under
# /private/tmp/studio.irq.selway.uitests and deletes it afterwards. The build goes in a
# temporary derived-data folder (ad-hoc signed, CODE_SIGN_IDENTITY=-), which is removed at
# the end along with the test app's LaunchServices registration (it claims selway:// and
# folders like the real app), its preferences and its saved windows. The log and the result
# bundle (open it in Xcode for screenshots of failures) stay in build/ui-test/.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "ui-test.sh drives the mouse and keyboard; it doesn't run in CI." >&2
    exit 1
fi
[[ "$(uname)" == Darwin ]] || { echo "the UI tests need macOS" >&2; exit 1; }
xcodebuild -version >/dev/null 2>&1 || { echo "the UI tests need Xcode (not just the Command Line Tools)" >&2; exit 1; }

BUILD_ONLY=0
ONLY=()
for arg in "$@"; do
    case "$arg" in
        --build-only) BUILD_ONLY=1 ;;
        -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        -*)           echo "unknown option: $arg" >&2; exit 2 ;;
        *)            ONLY+=("-only-testing:SelwayUITests/$arg") ;;
    esac
done

APP_ID=studio.irq.selway.uitest
FIXTURES=/private/tmp/studio.irq.selway.uitests      # also in SelwayUITests.entitlements and Fixture.swift
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
OUT="build/ui-test/$(date +%Y%m%d-%H%M%S)"
PACKAGES="build/ui-test-packages"                    # Sparkle's checkout, kept between runs
DD="$(mktemp -d "${TMPDIR:-/tmp}/selway-ui-test.XXXXXX")"
APP="$DD/Build/Products/UITest/Selway.app"
LOG="$OUT/xcodebuild.log"
mkdir -p "$OUT" "$PACKAGES"

cleanup() {
    pkill -f "$APP/Contents/MacOS/" 2>/dev/null || true
    # Every app bundle built (Selway.app and Sparkle's Updater.app inside it) was registered
    # with LaunchServices by the build; unregister them before deleting them.
    if [ -d "$DD/Build/Products" ]; then
        find "$DD/Build/Products" -name "*.app" -type d -prune -print0 2>/dev/null \
            | while IFS= read -r -d '' bundle; do
                  find "$bundle" -name "*.app" -type d -print0 | xargs -0 -n1 "$LSREGISTER" -u >/dev/null 2>&1 || true
              done
    fi
    rm -rf "$DD"
    # Only after a run: a build-only check may be made while another checkout's
    # tests are running, and their fixtures are in the same folder.
    if [ "$BUILD_ONLY" = 0 ]; then
        rm -rf "$FIXTURES"/SelwayUITests-* 2>/dev/null || true
        defaults delete "$APP_ID" >/dev/null 2>&1 || true
        rm -rf "$HOME/Library/Saved Application State/$APP_ID.savedState"
    fi
}
trap cleanup EXIT

XCODEBUILD=(xcodebuild -project Selway.xcodeproj -scheme SelwayUITests -configuration UITest
            -destination "platform=macOS,arch=$(uname -m)"
            -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$PACKAGES"
            CODE_SIGN_IDENTITY=-)

if [ "$BUILD_ONLY" = 1 ]; then
    echo "==> Building the UI tests (UITest configuration)"
    if ! "${XCODEBUILD[@]}" build-for-testing >"$LOG" 2>&1; then
        grep -E "error:" "$LOG" >&2 || tail -40 "$LOG" >&2
        echo "build failed (full log: $LOG)" >&2
        exit 1
    fi
    if grep -E "^/.*:[0-9]+:[0-9]+: warning:" "$LOG" | sort -u | grep . >&2; then
        echo "built with warnings (full log: $LOG)" >&2
        exit 1
    fi
    echo "==> Built (log: $LOG)"
    exit 0
fi

mkdir -p -m 700 "$FIXTURES"
echo "==> Building and running the UI tests. They take over the mouse and keyboard: hands off"
echo "    until this finishes. (Ctrl-C to stop.)"
[ -t 1 ] && sleep 3

STATUS=0
"${XCODEBUILD[@]}" -resultBundlePath "$OUT/SelwayUITests.xcresult" -parallel-testing-enabled NO \
    ${ONLY[@]+"${ONLY[@]}"} test >"$LOG" 2>&1 || STATUS=$?

# Summary from the result bundle: totals, the known gaps still open (tests that passed as an
# expected failure) and what failed, with XCTest's messages.
RESULT="$OUT/SelwayUITests.xcresult"
echo
if [ -d "$RESULT" ] && xcrun xcresulttool get test-results summary --path "$RESULT" >"$OUT/summary.json" 2>/dev/null \
        && xcrun xcresulttool get test-results tests --path "$RESULT" >"$OUT/tests.json" 2>/dev/null; then
    /usr/bin/python3 - "$OUT/summary.json" "$OUT/tests.json" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1]))
tests = json.load(open(sys.argv[2]))
print("==> UI tests: {result}. {passedTests} passed, {failedTests} failed, {skippedTests} skipped, "
      "{expectedFailures} known gaps (expected failures), of {totalTestCount}".format(**summary))
def cases(nodes, suite=""):
    for node in nodes:
        if node.get("nodeType") == "Test Case":
            yield suite, node
        yield from cases(node.get("children", []), node["name"] if node.get("nodeType") == "Test Suite" else suite)
gaps = [f"{suite}/{case['name']}" for suite, case in cases(tests.get("testNodes", []))
        if case.get("result") == "Expected Failure"]
if gaps:
    print("    Known gaps still open:")
    for name in gaps: print("      - " + name)
failures = summary.get("testFailures", [])
if failures:
    print("    Failed:")
    for failure in failures:
        print("      - {}: {}".format(failure.get("testIdentifierString") or failure["testName"],
                                     failure["failureText"].strip().replace("\n", " ")[:300]))
PY
else
    echo "==> UI tests finished (exit $STATUS); no result bundle to summarise."
    grep -E "error:|Testing failed|\*\* TEST|Executed [0-9]+ test" "$LOG" | tail -15 || tail -40 "$LOG"
fi
echo "    Log: $LOG"
echo "    Results: $OUT/SelwayUITests.xcresult"
exit "$STATUS"
