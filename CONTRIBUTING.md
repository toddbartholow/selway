# Contributing to Selway

## Issues

Bug reports and feature requests are welcome in
[Issues](https://github.com/toddbartholow/selway/issues). For a bug, the most useful
report has:

- the Selway version (Selway → About Selway) and the macOS version;
- the steps that show the problem, starting from a folder anyone could make;
- what you expected and what happened instead.

For a security problem, follow [SECURITY.md](SECURITY.md) instead of opening an issue.

## Pull requests

Selway is developed in a separate repository and published here as one commit per
release. A pull request merged here would be overwritten by the next release, so pull
requests can't be accepted. A bug report with steps to reproduce it is the best way to
help, and a fix you describe in an issue is welcome there.

To translate Selway, see [docs/TRANSLATING.md](docs/TRANSLATING.md).

## Building from source

Requirements:

- macOS 14 or later.
- Swift 6.0 or later for the tests: Xcode 16 or later, or the matching Command Line
  Tools.
- Xcode 16 or later to build the app.

```sh
git clone https://github.com/toddbartholow/selway.git
cd selway
open Selway.xcodeproj    # build and run with ⌘R
```

### Signing

Debug builds are ad-hoc signed with the hardened runtime, like releases, and also carry
the `get-task-allow` entitlement so the debugger can attach. Don't hand out Debug
builds. Ad-hoc builds (Debug, and releases without a Developer ID) turn off library
validation, which would otherwise refuse the ad-hoc-signed Sparkle framework at launch;
Developer ID builds keep it. A Release build run straight from Xcode (Product →
Profile) has neither, so it crashes at launch: use Debug, or the release scripts.

Releases, the update-signing key and notarization are covered in
[docs/RELEASING.md](docs/RELEASING.md).

## Testing

```sh
./scripts/test.sh
```

The tests use [Swift Testing](https://developer.apple.com/documentation/testing) and
cover the Foundation-only logic in `Selway/Core/`, the app's Sparkle settings and the
release scripts' rules, through a small Swift package (`Package.swift`). They run with
just the Command Line Tools and never launch an app. `--filter <pattern>` runs the
suites or tests that match.

The full check also mounts real disk images, runs the update-key tool and Sparkle's
signing tools with throwaway keys, and makes a Debug build of the app that fails on
warnings. It needs Xcode:

```sh
./scripts/test.sh --app
```

The tests also run on Linux, apart from those that need macOS. The header of
`scripts/test.sh` has the Docker command that runs them there.

### UI tests

The UI tests (XCUITest, in `SelwayUITests/`) click, double-click, drag and type in the
app the way a person would, so they **take over the mouse and keyboard** for a few
minutes. Run them on purpose, and leave the Mac alone while they run. They refuse to
run in CI.

```sh
./scripts/ui-test.sh                     # all of them
./scripts/ui-test.sh ListViewTests       # one class (or Class/test for one test)
./scripts/ui-test.sh --build-only        # build them without running anything
```

The first run may ask for an administrator password to enable UI automation;
`sudo automationmodetool enable-automationmode-without-authentication` stops that. If
macOS asks whether Terminal may control the computer, allow it in System Settings →
Privacy & Security → Accessibility.

The tests never touch your own Selway or your files. They build a separate copy of the
app (`studio.irq.selway.uitest`) with its own preferences, no Finder extension and no
update checks, and work in throwaway folders under `/private/tmp`. The log and the
result bundle (with screenshots of failures) stay in `build/ui-test/`.
