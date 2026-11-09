#!/bin/bash
# Export English localizations from the Selway project to sync its String Catalogs.
#
#   ./scripts/sync-strings.sh         # update catalogs and report which changed
#   ./scripts/sync-strings.sh --check # fail if the export changes a catalog
#
# --check compares against each catalog's contents before the export, including any
# uncommitted edits, so it reports only changes made by this sync.
set -euo pipefail
cd "$(dirname "$0")/.."

check=0
if [[ $# -gt 1 ]] || { [[ $# -eq 1 ]] && [[ "$1" != --check ]]; }; then
    echo "usage: $0 [--check]" >&2
    exit 2
fi
[[ $# -eq 0 ]] || check=1

catalogs=()
while IFS= read -r catalog; do catalogs+=("$catalog"); done \
    < <(find Selway SelwayExtension -name '*.xcstrings' -not -path '*/build/*' | sort)
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A temporary index snapshots the working-tree catalogs as they are now. This avoids
# treating pre-existing uncommitted catalog edits as changes caused by the export.
index="$tmp/index"
GIT_INDEX_FILE="$index" git add -- "${catalogs[@]}"

echo "==> Exporting English localizations"
mkdir -p "$tmp/export"
xcodebuild -exportLocalizations -project Selway.xcodeproj \
    -localizationPath "$tmp/export" -exportLanguage en

changed=()
for catalog in "${catalogs[@]}"; do
    if ! GIT_INDEX_FILE="$index" git diff --quiet -- "$catalog"; then
        changed+=("$catalog")
    fi
done

if ((${#changed[@]})); then
    printf 'Changed catalogs:\n'
    printf '  %s\n' "${changed[@]}"
    if ((check)); then
        echo "String Catalogs are out of sync. Run scripts/sync-strings.sh and review the changes." >&2
        exit 1
    fi
else
    echo "No String Catalogs changed."
fi
