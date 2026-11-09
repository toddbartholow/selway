#!/bin/bash
# Import finished translations from Localizations/ into the String Catalogs.
#
#   ./scripts/l10n-import.sh          # every language in Localizations/
#   ./scripts/l10n-import.sh de       # just these
#
# A language ships only when it's complete, so a file with any string untranslated, or
# marked for review, is reported and skipped; the catalogs (and so the app) keep only
# finished languages. Merge the weblate branch first. Afterwards, run
# ./scripts/test.sh: the catalog tests check that every translation keeps its
# placeholders.
set -euo pipefail
cd "$(dirname "$0")/.."

languages=("$@")
if ((${#languages[@]} == 0)); then
    for f in Localizations/*.xliff; do
        [ -e "$f" ] && languages+=("$(basename "$f" .xliff)")
    done
fi
if ((${#languages[@]} == 0)); then
    echo "No translations in Localizations/ yet." >&2
    exit 2
fi

for lang in "${languages[@]}"; do
    [[ "$lang" =~ ^[a-z]{2,3}([-_][A-Za-z0-9]+)*$ ]] || { echo "not a language code: $lang" >&2; exit 2; }
    [ -f "Localizations/$lang.xliff" ] || { echo "no such file: Localizations/$lang.xliff" >&2; exit 2; }
done

# xcodebuild -importLocalizations rewrites the whole project file in an older format
# (objectVersion 70) while adding nothing it needs: a translation ships from the
# catalogs alone. Keep the project file as it was. If an import fails, or makes a new
# catalog (which would have to be added to the project by hand), put the catalogs back
# as they were too, so no language is left half imported.
project=Selway.xcodeproj/project.pbxproj
catalogs_before="$(find Selway SelwayExtension -name '*.xcstrings' | sort)"
snapshot="$(mktemp -d)"
while IFS= read -r catalog; do
    mkdir -p "$snapshot/$(dirname "$catalog")"
    cp "$catalog" "$snapshot/$catalog"
done <<<"$catalogs_before"
cp "$project" "$snapshot/project.pbxproj"
finish() {
    local status=$?
    cp "$snapshot/project.pbxproj" "$project"
    if ((status != 0)); then
        while IFS= read -r catalog; do cp "$snapshot/$catalog" "$catalog"; done <<<"$catalogs_before"
        comm -13 <(echo "$catalogs_before") <(find Selway SelwayExtension -name '*.xcstrings' | sort) \
            | while IFS= read -r extra; do rm -f "$extra"; done
        echo "Nothing was imported: the String Catalogs are as they were." >&2
    fi
    rm -rf "$snapshot"
}
trap finish EXIT

skipped=()
imported=()
for lang in "${languages[@]}"; do
    file="Localizations/$lang.xliff"
    read -r done total < <(/usr/bin/python3 scripts/lib/l10n.py xliff-status "$file")
    if [ "$done" != "$total" ]; then
        echo "==> $lang: $done of $total strings translated; not imported"
        skipped+=("$lang")
        continue
    fi
    echo "==> Importing $lang ($total strings)"
    log="$(mktemp)"
    if ! xcodebuild -importLocalizations -project Selway.xcodeproj -localizationPath "$file" >"$log" 2>&1; then
        tail -20 "$log" >&2
        rm -f "$log"
        echo "xcodebuild -importLocalizations failed for $lang" >&2
        exit 1
    fi
    rm -f "$log"
    if [ "$(find Selway SelwayExtension -name '*.xcstrings' | sort)" != "$catalogs_before" ]; then
        echo "importing $lang created a String Catalog; add it to the project in Xcode:" >&2
        comm -13 <(echo "$catalogs_before") <(find Selway SelwayExtension -name '*.xcstrings' | sort) >&2
        exit 1
    fi
    imported+=("$lang")
done

if ((${#skipped[@]})); then
    echo "Skipped (incomplete): ${skipped[*]}"
fi
# Xcode leaves a string it already had in a language as needing review when the
# imported file's English is older than the catalog's: say so now, not at release time.
if ((${#imported[@]})); then
    echo "==> Catalogs"
    # shellcheck disable=SC2046
    /usr/bin/python3 scripts/lib/l10n.py catalog-status $(find Selway SelwayExtension -name '*.xcstrings' | sort)
fi
