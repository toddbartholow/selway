# Releasing Selway

One-time setup (the update-signing key, GitHub Pages and private vulnerability reporting
on the public repository, optionally a Developer ID), then the steps for each release.
`release.sh` needs a full Xcode install; the key tool works with the Command Line
Tools alone.

How the pieces work inside is documented where they live: the Sparkle settings in
`Selway/Info.plist`, the updater's rules in `UpdateManager.swift` and
`UpdateInstallLocation.swift`, the release checks in `release.sh` and
`scripts/lib/release-common.sh`, and the feed checks and key tool in
`scripts/update-signing.swift`.

## How updates reach users

Selway updates itself with [Sparkle](https://sparkle-project.org) 2. It reads
`https://toddbartholow.github.io/selway/appcast.xml`, which GitHub Pages serves from
`docs/appcast.xml` on `main` of the public `toddbartholow/selway` repository, and downloads
DMGs (and delta updates) from that repository's `v<version>` releases. This repository
commits the signed feed as `docs/appcast.xml`, and it reaches the public repository with
the rest of the release's source, in one commit per release.
The feed, its release notes and every download are signed with the Ed25519 key whose
public half is `SUPublicEDKey` in `Selway/Info.plist`, and Sparkle rejects anything that
doesn't verify.

- **Don't lose the private key.** There's no fallback: without it, installed copies can
  never be updated again and everyone has to download a new build by hand. Keep the
  offline backup (below). If it's lost or leaks anyway: delete the old "Selway Update
  Signing" Keychain item if it still exists (`generate` won't replace it), generate and
  back up a new key, put its public half in `SUPublicEDKey`, start a new archives folder,
  delete `docs/appcast.xml` (the old feed can't verify with the new key), release (with a
  new version and a build number above the last one: nothing checks them without a feed),
  and tell users to download that release by hand once.
- **Build numbers decide what's newer.** Sparkle compares `CURRENT_PROJECT_VERSION`
  (`CFBundleVersion`), not the marketing version.
- **Selway only updates itself where the user can replace it** without an administrator
  password. A standard account using a copy in `/Applications`, a copy owned by another
  user or root, and running as root get a pointer to the releases page instead; a copy run
  from a disk image is told to move it to Applications. This can be relaxed once releases
  are Developer ID–signed and notarized.

## One-time: the update-signing key

The key already exists. These steps are for a new machine or a new key.

```sh
scripts/update-key.sh generate
```

This stores the private key in your **login Keychain** (item "Selway Update Signing") and
prints the public key. macOS asks for permission every time something reads it; a release
reads it once.

> **Always click "Allow", never "Always Allow".** The program asking is the shared `swift`
> interpreter, not a Selway tool. "Always Allow" lets *any* Swift script you run read the
> signing key without asking. If you clicked it by mistake, see "Re-storing the key" under
> Troubleshooting.

Then:

1. Put the printed public key in `Selway/Info.plist` as the `SUPublicEDKey` string and
   commit it. The public key is safe to publish.
2. Back up the private key and keep the copy offline (password manager, encrypted disk):
   ```sh
   scripts/update-key.sh backup /Volumes/YourBackup/selway-update-key
   ```

To keep the key in a file instead (for example on a build machine), set
`SELWAY_UPDATE_PRIVATE_KEY_FILE=/path/outside/any/checkout/key` for `generate` and for every
release. The file must be outside any git checkout, owned by you and `chmod 600`.

## One-time: GitHub Pages on the public repository

GitHub Pages on `toddbartholow/selway` serves the feed (`docs/appcast.xml`), plus a
`docs/index.html` that only forwards visitors to the repository on GitHub (there is no
separate web page). Pages can only deploy from a branch that exists, so this is
set up during the first release, right after its final push to `main` (step 5.4 under "Each
release"):

1. On `toddbartholow/selway`: Settings → Pages → Build and deployment: Source **Deploy from a
   branch**, branch `main`, folder `/docs`. `docs/.nojekyll` makes Pages serve the files as
   they are.
2. Once Pages has deployed, check that `https://toddbartholow.github.io/selway/appcast.xml`
   shows the feed, byte for byte the committed `docs/appcast.xml`.

To use another repository, change `SELWAY_RELEASES_REPO` in `scripts/lib/release-common.sh`
and `SUFeedURL` in `Selway/Info.plist` together (`release.sh` checks they agree). Installed
copies keep the feed URL they were built with.

## One-time: private vulnerability reporting

`SECURITY.md` asks people to report security issues through GitHub's private vulnerability
reporting, which is off by default. On `toddbartholow/selway`: Settings → Code security →
**Private vulnerability reporting** → Enable. Check that the repository's **Security** tab
then offers **Report a vulnerability**.

## One-time (optional): Developer ID signing and notarization

Without this, builds are ad-hoc signed and users approve the first open once in System
Settings. With it, macOS opens the app normally.

1. **Enroll** in the [Apple Developer Program](https://developer.apple.com/programs/)
   (paid, yearly). Only the Account Holder can create Developer ID certificates.
2. **Create a CSR**: Keychain Access → Certificate Assistant → *Request a Certificate From
   a Certificate Authority…*, enter your email and name, choose *Saved to disk*.
3. **Create the certificate** at
   [developer.apple.com → Certificates](https://developer.apple.com/account/resources/certificates/list):
   **+** → **Developer ID Application**, upload the CSR, download the `.cer` and
   double-click it.
4. **Note the identity name and Team ID:**
   ```sh
   security find-identity -v -p codesigning
   #   1) ABC123… "Developer ID Application: Your Name (TEAMID1234)"
   ```
5. **Store notarization credentials.** Create an app-specific password at
   [account.apple.com](https://account.apple.com) → Sign-In and Security, then:
   ```sh
   xcrun notarytool store-credentials selway \
       --apple-id you@example.com --team-id TEAMID1234
   ```

Back up the certificate with its private key (Keychain Access → My Certificates → Export →
`.p12`) and keep it offline. The first Developer ID release installs over ad-hoc copies
like any other update, since they check its EdDSA signature. From then on every release
must be signed by the same Team ID; `release.sh` enforces this.

## Each release

1. **Version.** In Xcode, bump `MARKETING_VERSION` (both targets) and
   `CURRENT_PROJECT_VERSION` (both targets, all configurations). The marketing version
   looks like `1.6` or `1.6.1`; the build number is a whole number above every build
   already released. Every item in the feed is offered to everyone, so there are no
   prereleases.
2. **Notes.** Add the version to `CHANGELOG.md` and commit. For notes in Sparkle's update
   window, write `release-notes/<version>.md` (or `.html`), or point
   `SELWAY_RELEASE_NOTES` at a file.
3. **Build.** From an up-to-date checkout of `main` (or the release branch), so the new feed
   extends the last one:
   ```sh
   ./release.sh                                                       # ad-hoc
   SELWAY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID1234)" \
   SELWAY_NOTARY_PROFILE=selway ./release.sh                          # Developer ID + notarization
   ```
   `release.sh` reads the previous feed from `docs/appcast.xml` (absent before the first
   release; `SELWAY_APPCAST` points elsewhere), checks the versions, that feed and the Team
   ID, runs the full test suite (`SELWAY_SKIP_TESTS=1` skips it, for re-runs only) and stops
   on any problem (see Troubleshooting). In a git checkout it first runs `git fetch origin`
   and requires the feed to be byte for byte `docs/appcast.xml` on `origin/main`, once that
   exists, so a checkout that is behind the last release can't extend an old feed.
   `SELWAY_SKIP_FEED_ORIGIN_CHECK=1` skips only that comparison (offline, or when
   `origin/main` itself is the one out of date). Click **Allow** at the one Keychain
   prompt. After the first Developer ID release it writes `release/team-id`: **commit that
   file**. If notarization is rejected:
   `xcrun notarytool log <submission-id> --keychain-profile selway`.

   It writes `Selway-<version>.dmg`, its `.sha256`, any `.delta` files and the signed
   `appcast.xml` to `build/`, and replaces `docs/appcast.xml` with the same signed feed.
   The build maps the checkout's paths to relative ones and strips the debug symbols from
   Selway's own binaries before signing, so no path on the build Mac ships; it stops if one
   is left. It also keeps every released DMG and the last feed in `build/sparkle-archives/`
   (or `$SELWAY_ARCHIVES_DIR`), which later releases build their deltas from, and each
   release's dSYMs in its `dSYMs/<version>/` folder, outside the DMG. The shipped binaries
   have no debug symbols, so those dSYMs are the only way to symbolicate a crash report
   from that version (the next build deletes `build/dd-release/`, where they were built).
   **Keep that folder between releases and back it up.** If it's lost, the next release
   still works from `docs/appcast.xml`, just without deltas, but crash reports from earlier
   versions can't be symbolicated.

   The default folder lives in the checkout that runs `release.sh`, so a release from a
   fresh clone or another worktree starts without it. **Set `SELWAY_ARCHIVES_DIR` to one
   fixed folder outside any checkout or worktree** (for example
   `~/Releases/selway-archives`, in your shell profile) and use it for every release: then
   every release gets deltas, and `release.sh` can also check the committed feed against the
   copy the last release left there.
4. **Commit and merge the feed.** Commit `docs/appcast.xml` (and `release/team-id` if it
   was just written) with the version bump and notes, and merge to `main`. **Never edit
   `appcast.xml` by hand**: that breaks its signature. Until this reaches the public
   repository, nothing changes for users.
5. **Publish, in this order.** The feed goes live when the public `main` moves (Pages deploys
   `main:/docs`), so the downloads it lists have to be up first:
   1. Make the release's single commit for `toddbartholow/selway` from the merged `main`,
      including `docs/appcast.xml`.
   2. Push that commit as the tag `v<version>` only, not to `main` yet, and no other tag
      with it:
      `git -C <public clone> -c push.followTags=false push origin HEAD:refs/tags/v<version>`.
   3. Create the GitHub release `v<version>` on `toddbartholow/selway` from that tag and
      upload the DMG, its `.sha256` and the `.delta` files `release.sh` listed, exactly as
      named, with the release's title and its `CHANGELOG.md` section as notes:
      ```sh
      gh release create v<version> -R toddbartholow/selway --verify-tag --title "Selway <version>" \
          --notes-file <the "## <version>" section of CHANGELOG.md> \
          build/Selway-<version>.dmg build/Selway-<version>.dmg.sha256 build/Selway<build>-*.delta
      ```
      Leave earlier releases' files in place: older feed items still point at them.
   4. Push the commit to `main` on `toddbartholow/selway`
      (`git -C <public clone> -c push.followTags=false push origin main`, so no other tag
      goes with it). On the first release, set up GitHub Pages now (see "One-time: GitHub
      Pages on the public repository"): the setting needs `main` to exist. Pages then
      serves the new feed within a few minutes; check that
      `https://toddbartholow.github.io/selway/appcast.xml` matches `docs/appcast.xml`. (The
      other way round, Selway would offer a download that isn't there yet.)
6. **Check updates end to end.** The automated tests never install or launch the app, so
   once per release (and after any change to the update setup), on a Mac or user account
   you can disturb:
   1. Install the **previous** release in `/Applications` and open it once.
   2. Choose **Check for Updates…** → **Install Update** → **Install and Relaunch**. It
      should relaunch with the new version. Ad-hoc builds lose their folder-access and
      Automation grants on every update; that's expected.
   3. With unsaved changes in an editor, choose **Install and Relaunch** and **Cancel** the
      save prompt: Selway stays open and nothing installs. Quit later and it installs then.
   4. From a **standard (non-admin) account**, with Selway in `/Applications`: Check for
      Updates… says Selway can't update itself there, without asking for an administrator
      password.

To test the scripts without Xcode, `SELWAY_PREBUILT_APP=/path/to/Selway.app` packages an
existing build, and `SELWAY_DMG_STYLE=0` skips styling the DMG window (which opens a Finder
window). The other variables are described at the top of `release.sh` and
`scripts/lib/release-common.sh`.

## Troubleshooting

- **"refusing to handle the signing key with xtrace (set -x) on"**: run `release.sh`
  without `bash -x`/`set -x`.
- **"couldn't read the update-signing key"**: the Keychain prompt was denied, or there's no
  key (`scripts/update-key.sh public-key` should print the `SUPublicEDKey` value).
- **Re-storing the key** (after "Always Allow", or for an item made by an older
  `update-key.sh generate`, which trusted the `swift` interpreter):
  ```sh
  scripts/update-key.sh backup /Volumes/YourBackup/selway-update-key   # if you haven't
  # Keychain Access → login → delete "Selway Update Signing"
  scripts/update-key.sh import /Volumes/YourBackup/selway-update-key
  ```
- **"build N isn't newer than build M"** / **"version X is already in"**: raise
  `CURRENT_PROJECT_VERSION` above `M` in every target and configuration, or
  `MARKETING_VERSION`.
- **"the existing appcast … isn't signed with SUPublicEDKey"** or **"… contains a DTD
  declaration"**: the feed doesn't verify with the `SUPublicEDKey` in `Selway/Info.plist`.
  Either that key changed (check `git log -p Selway/Info.plist`;
  `scripts/update-key.sh public-key` should print the same value), or `appcast.xml` was
  edited after signing (`generate_appcast` never writes a DTD, so one means the same).
  Restore both `docs/appcast.xml` and the archives copy, which must match, from git history
  or a backup of the archives folder.
- **"…/docs/appcast.xml differs from …/appcast.xml"** / **"… exists but …/docs/appcast.xml
  doesn't"**: the committed feed isn't the one the last release made, usually because the
  checkout is behind the last release or its feed was never committed. Update the checkout,
  or commit the archives copy as `docs/appcast.xml`, and run again.
- **"… differs from docs/appcast.xml on origin/main"** / **"origin/main has
  docs/appcast.xml but … doesn't exist"**: the checkout is behind the last merged release.
  Update it from `origin/main` and run again. **"couldn't fetch origin"** / **"… has no
  origin/main"**: fix the remote, or check the feed by hand and set
  `SELWAY_SKIP_FEED_ORIGIN_CHECK=1`.
- **"… doesn't list every release in …"** / **"… holds earlier releases … but there is no
  appcast"**: the feed is older than what was released, or missing. Restore the newest
  published `appcast.xml` as `docs/appcast.xml`.
- **"this release is signed by Team ID …"** / **"an ad-hoc release can't follow"**:
  earlier releases used another Team ID. Sign with that Developer ID.
- **"couldn't create a scratch folder next to …"**: the archives folder is a volume root
  or its parent isn't writable; use a subfolder.
- **"Sparkle's generate_appcast wasn't found"**: run `./scripts/test.sh --app` once
  (it fetches the pinned Sparkle package into `build/`), or set `SELWAY_SPARKLE_BIN`.
- **A delta is never made**: delete
  `~/Library/Caches/Sparkle_generate_appcast/*.ignore` and run `release.sh` again.
- **"The update feed is improperly signed and could not be validated"** (in the app):
  `appcast.xml` was edited after signing, or signed with another key. Commit the
  `docs/appcast.xml` that `release.sh` wrote, unchanged.
- **"(Ed)DSA signature validation before unarchiving failed"** (in the app): the uploaded
  DMG or delta isn't the one the feed was made for. Upload the files from the same
  `release.sh` run.
- **Download fails (404)**: the release isn't published yet, or its tag or file names
  don't match the URLs in `appcast.xml` (`releases/download/v<version>/…` on
  `toddbartholow/selway`).
