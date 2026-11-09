#!/bin/bash
# Export the String Catalogs for translators, one XLIFF per language in Localizations/.
#
#   ./scripts/l10n-export.sh          # refresh every language already in Localizations/
#   ./scripts/l10n-export.sh de es    # refresh these, adding any that are new
#
# Weblate (see docs/TRANSLATING.md) translates Localizations/<language>.xliff. Before
# exporting, merge the weblate branch, so its latest translations are in those files:
# a fresh export starts from the catalogs, which hold only imported (complete) languages,
# and every target it lacks is carried over from the file it replaces. A translation
# whose English changed is kept but marked for review.
set -euo pipefail
cd "$(dirname "$0")/.."

languages=("$@")
if ((${#languages[@]} == 0)); then
    for f in Localizations/*.xliff; do
        [ -e "$f" ] && languages+=("$(basename "$f" .xliff)")
    done
fi
if ((${#languages[@]} == 0)); then
    echo "usage: $0 <language>...  (no languages in Localizations/ yet)" >&2
    exit 2
fi
for lang in "${languages[@]}"; do
    [[ "$lang" =~ ^[a-z]{2,3}([-_][A-Za-z0-9]+)*$ ]] || { echo "not a language code: $lang" >&2; exit 2; }
    [ "$lang" != en ] || { echo "English is the source language; it isn't exported" >&2; exit 2; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> Exporting ${languages[*]}"
flags=()
for lang in "${languages[@]}"; do flags+=(-exportLanguage "$lang"); done
if ! xcodebuild -exportLocalizations -project Selway.xcodeproj -localizationPath "$tmp" \
        "${flags[@]}" >"$tmp/export.log" 2>&1; then
    tail -20 "$tmp/export.log" >&2
    echo "xcodebuild -exportLocalizations failed" >&2
    exit 1
fi

mkdir -p Localizations
for lang in "${languages[@]}"; do
    fresh="$tmp/$lang.xcloc/Localized Contents/$lang.xliff"
    [ -f "$fresh" ] || { echo "the export has no $lang.xliff" >&2; exit 1; }
    out="Localizations/$lang.xliff"
    echo "==> $out"
    if [ -f "$out" ]; then
        /usr/bin/python3 scripts/lib/l10n.py merge "$fresh" "$out" "$tmp/$lang.merged.xliff"
        mv "$tmp/$lang.merged.xliff" "$out"
    else
        cp "$fresh" "$out"
    fi
    read -r done total < <(/usr/bin/python3 scripts/lib/l10n.py xliff-status "$out")
    echo "    $done of $total strings translated"
done
