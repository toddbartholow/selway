#!/bin/bash
# Make and keep Selway's update-signing key (Ed25519, the SUPublicEDKey pair Sparkle checks).
# See docs/RELEASING.md.
#   scripts/update-key.sh generate | public-key | export-private-key |
#                         verify-feed APPCAST PUBKEY |
#                         check-appcast-versions APPCAST BUILD VERSION |
#                         check-archives-covered APPCAST ARCHIVES_DIR EXCLUDE |
#                         merge-appcast GENERATED PREVIOUS BUILD OUT |
#                         verify-appcast APPCAST PUBKEY DMG URL BUILD PREVIOUS |
#                         backup PATH | import PATH | acl-check
# export-private-key only writes into a pipe, for Sparkle's tools:
#   scripts/update-key.sh export-private-key | generate_appcast --ed-key-file - …
# The appcast commands need no key; they refuse any appcast with a DTD and never load
# external entities. release-common.sh (selway_sparkle_appcast) shows how they fit together.
# The private key stays in the login Keychain (no app trusted, so every read asks), or in
# $SELWAY_UPDATE_PRIVATE_KEY_FILE (mode 600, outside any git checkout). Needs only the Command
# Line Tools. -suppress-warnings hides the deprecation warnings for the Keychain ACL calls,
# which are still the only way to restrict a login-keychain item to "ask every time".
set -euo pipefail
exec swift -suppress-warnings "$(cd "$(dirname "$0")" && pwd)/update-signing.swift" "$@"
