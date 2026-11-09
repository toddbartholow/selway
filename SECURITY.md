# Security Policy

## Reporting a vulnerability

Please report security issues privately, not in a public issue.

Use GitHub's private vulnerability reporting: open the repository's **Security** tab
and choose **Report a vulnerability**. That opens a private advisory that only the
maintainer can see.

Include what you found, how to reproduce it, and the Selway version you tested
(Selway → About Selway). You will get an acknowledgment and updates as the fix
progresses.

## Scope

Selway is a file manager: it reads, writes, moves and deletes your files, mounts
servers you ask it to, and updates itself. The findings that matter most are anything
that lets a file, a folder name, a `selway://` link or a server run code, touch files
you didn't choose, mount something you didn't ask for, or get an update installed that
the maintainer didn't sign.

The main app isn't sandboxed, because a file manager needs to reach your whole disk
(Finder isn't sandboxed for the same reason). It gets only the access you grant through
macOS's own prompts. The Finder extension runs sandboxed. Server logins go through
macOS's own prompt and your keychain; Selway doesn't store passwords.

## Supported versions

Fixes land in the latest release. Please check that the newest version still has the
problem before reporting it.

## How updates work

Selway updates itself with [Sparkle](https://sparkle-project.org), the open-source
updater many Mac apps use, and shows Sparkle's own update windows.

### What the update check sends

With **Settings → General → Check for updates automatically** on (the default, so
security fixes reach you), Selway downloads the update feed (`appcast.xml`) from
`toddbartholow.github.io` about once a day. Only when you install an update does it
download the release from `github.com`. These requests carry your IP address and a
user agent naming Selway and its version, as any download does. Nothing about your
files is sent, and Sparkle's optional system profiling is off.

With the setting off, Selway checks only when you choose **Selway → Check for
Updates…**.

### How an update is verified

1. The feed must carry a valid Ed25519 signature from the maintainer's key, whose
   public half is built into the app (`SUPublicEDKey`). A feed that was edited or
   replaced, release notes included, is rejected.
2. Each download (the full DMG, or a smaller delta update) must match its Ed25519
   signature in the signed feed before Sparkle unpacks it.
3. Sparkle installs the update only after Selway has quit the normal way, so running
   file operations and unsaved-changes prompts still get their say. If you cancel the
   quit, nothing is installed until you do quit.
4. Selway installs updates only where your account can replace the app on its own:
   the app and its folder writable, and the app owned by you. Otherwise (for example,
   a standard account with Selway in `/Applications`, or a copy someone else
   installed), **Check for Updates…** says so and points to the releases page. It
   never asks for an administrator password.

### What this protects against, and what it doesn't

- A tampered or corrupted download, and a replaced or edited feed, are rejected.
  There is no fallback that shows updates once the feed's signature has failed.
- Someone who takes over the GitHub account or the release pages can't make Selway
  install anything the maintainer didn't sign. They can still withhold updates.
- If the signing key itself were stolen, an attacker could sign a malicious update.
  The key is kept out of every checkout of the source, with an offline backup.
- Releases that aren't signed with an Apple Developer ID carry no Apple-issued
  identity, so for your first download you are trusting the GitHub release page. Each
  release has a `.dmg.sha256` file; compare it with
  `shasum -a 256 Selway-<version>.dmg` to check the download wasn't corrupted.
