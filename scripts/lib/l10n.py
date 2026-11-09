#!/usr/bin/python3
"""Helpers for scripts/l10n-export.sh, scripts/l10n-import.sh and the release checks.

  l10n.py merge NEW OLD OUT       carry OLD's translations into a fresh export NEW, write OUT
  l10n.py xliff-status FILE       print "<translated> <total>" for an XLIFF; fails if it has
                                  no units (not an Xcode XLIFF 1.2 file)
  l10n.py catalog-status [--check] CATALOG...
                                  per language, how many keys aren't fully translated;
                                  --check fails if any language is incomplete
  l10n.py remove-language LANGUAGE CATALOG...
                                  delete a language from the catalogs (run sync-strings.sh
                                  afterwards, which writes them in Xcode's format)

An XLIFF unit counts as translated when it has a non-blank <target> whose state is
"translated", "final" or "signed-off" (or has no state). Weblate writes
"needs-translation" or "needs-review-translation" for empty and fuzzy units.
"""
import json
import sys
import xml.etree.ElementTree as ET

NS = "urn:oasis:names:tc:xliff:document:1.2"
Q = "{%s}" % NS
DONE_STATES = {None, "translated", "final", "signed-off"}

ET.register_namespace("", NS)
ET.register_namespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")


def units(root):
    """{(file original, unit id): trans-unit} for every unit in the document."""
    found = {}
    for f in root.iter(Q + "file"):
        for u in f.iter(Q + "trans-unit"):
            found[(f.get("original"), u.get("id"))] = u
    return found


def text(el):
    return "" if el is None else "".join(el.itertext())


def has_target(unit):
    return text(unit.find(Q + "target")).strip() != ""


def is_translated(unit):
    target = unit.find(Q + "target")
    return has_target(unit) and target.get("state") in DONE_STATES


def merge(new_path, old_path, out_path):
    """Localizations/ holds the newest translations (Weblate edits them there), so each
    of OLD's targets replaces NEW's, which comes from the catalogs. A target whose
    English changed is kept, marked for review. A string whose English was reworded has
    a new id (the id is the English text), so its old translation can't be matched:
    those are counted and listed, and Weblate's translation memory still has them."""
    new = ET.parse(new_path)
    new_units = units(new.getroot())
    old_units = units(ET.parse(old_path).getroot())
    kept = review = 0
    for key, unit in new_units.items():
        prior = old_units.get(key)
        if prior is None or not has_target(prior):
            continue
        target = ET.fromstring(ET.tostring(prior.find(Q + "target")))
        if text(prior.find(Q + "source")) != text(unit.find(Q + "source")):
            target.set("state", "needs-review-translation")
            review += 1
        else:
            kept += 1
        source = unit.find(Q + "source")
        existing = unit.find(Q + "target")
        if existing is not None:
            target.tail = existing.tail
            unit.remove(existing)
        else:
            target.tail = source.tail
        unit.insert(list(unit).index(source) + 1, target)
    lost = [key for key, unit in old_units.items()
            if key not in new_units and unit.get("translate") != "no" and has_target(unit)]
    new.write(out_path, encoding="UTF-8", xml_declaration=True)
    print(f"    kept {kept} translations, {review} marked for review (English changed)")
    if lost:
        print(f"    {len(lost)} translations dropped: their English was reworded or removed")
        for original, unit_id in lost[:5]:
            print(f"      {original}: {unit_id!r}")
        if len(lost) > 5:
            print(f"      ... and {len(lost) - 5} more")


def xliff_status(path):
    # translate="no" units (catalog keys marked not to translate) need no target.
    found = [u for u in units(ET.parse(path).getroot()).values() if u.get("translate") != "no"]
    if not found:
        print(f"{path} has no XLIFF 1.2 translation units", file=sys.stderr)
        return 1
    print(sum(1 for u in found if is_translated(u)), len(found))
    return 0


def leaves(node):
    """Every stringUnit under a localization: top level, variations, substitutions."""
    if not isinstance(node, dict):
        return
    if "stringUnit" in node:
        yield node["stringUnit"]
    for value in node.get("variations", {}).values():
        for form in value.values():
            yield from leaves(form)
    for sub in node.get("substitutions", {}).values():
        yield from leaves(sub)


# The plural forms a translation needs (CLDR cardinal categories, as Xcode exports
# them). Other languages need English's "one" and "other".
PLURAL_FORMS = {
    **{lang: {"other"} for lang in ("ja", "zh", "ko", "th", "vi", "id", "ms", "km", "lo", "my")},
    **{lang: {"one", "few", "many", "other"} for lang in ("ru", "uk", "be", "pl", "cs", "sk", "lt")},
    "ar": {"zero", "one", "two", "few", "many", "other"},
}


def plural_forms_present(forms, language):
    needed = PLURAL_FORMS.get(language.split("-")[0].split("_")[0], {"one", "other"})
    return needed <= set(forms)


def complete(entry, language):
    loc = entry.get("localizations", {}).get(language)
    if not loc:
        return False
    found = list(leaves(loc))
    if not found or any(u.get("state") != "translated" or not u.get("value", "").strip() for u in found):
        return False
    english = entry.get("localizations", {}).get("en", {})
    english_variations = english.get("variations", {})
    variations = loc.get("variations", {})
    # A plural in English needs one in the translation (or substitutions in its place),
    # with every form the language uses.
    if "plural" in english_variations:
        if "plural" in variations:
            if not plural_forms_present(variations["plural"], language):
                return False
        elif "substitutions" not in loc:
            return False
    if "device" in english_variations and \
            set(variations.get("device", {})) != set(english_variations["device"]):
        return False
    for name, sub in english.get("substitutions", {}).items():
        mine = loc.get("substitutions", {}).get(name)
        if mine is None or not any(leaves(mine)):
            return False
        if "plural" in sub.get("variations", {}) and \
                not plural_forms_present(mine.get("variations", {}).get("plural", {}), language):
            return False
    return True


def translatable(entry):
    # Stale entries are no longer in the code and aren't exported for translation.
    return entry.get("shouldTranslate", True) and entry.get("extractionState") != "stale"


def load_catalogs(paths):
    catalogs = {}
    for p in paths:
        with open(p, encoding="utf-8") as f:
            catalogs[p] = json.load(f)
    return catalogs


def catalog_status(paths, check):
    catalogs = {p: c["strings"] for p, c in load_catalogs(paths).items()}
    languages = sorted({lang for strings in catalogs.values() for entry in strings.values()
                        for lang in entry.get("localizations", {})} - {"en"})
    incomplete = False
    for lang in languages:
        missing = [(p, key) for p, strings in catalogs.items() for key, entry in strings.items()
                   if translatable(entry) and not complete(entry, lang)]
        total = sum(1 for strings in catalogs.values() for e in strings.values() if translatable(e))
        print(f"{lang}: {total - len(missing)} of {total} strings translated")
        for p, key in missing[:10]:
            print(f"    missing in {p}: {key!r}")
        if len(missing) > 10:
            print(f"    ... and {len(missing) - 10} more")
        incomplete = incomplete or bool(missing)
    if not languages:
        print("No translations yet.")
    if check and incomplete:
        print("A language ships only when it's complete: finish it in Weblate and import it "
              "(scripts/l10n-import.sh), or remove it (scripts/lib/l10n.py remove-language) "
              "before releasing.", file=sys.stderr)
        return 1
    return 0


def xcode_json(obj, indent=""):
    """JSON as Xcode writes a String Catalog: two-space indent, " : " between key and
    value, and an empty object as an opening brace, a blank line and a closing brace."""
    if isinstance(obj, dict):
        inner = indent + "  "
        if not obj:
            return "{\n\n" + indent + "}"
        items = [inner + json.dumps(k, ensure_ascii=False) + " : " + xcode_json(v, inner)
                 for k, v in obj.items()]
        return "{\n" + ",\n".join(items) + "\n" + indent + "}"
    if isinstance(obj, list):
        inner = indent + "  "
        if not obj:
            return "[\n\n" + indent + "]"
        return "[\n" + ",\n".join(inner + xcode_json(v, inner) for v in obj) + "\n" + indent + "]"
    return json.dumps(obj, ensure_ascii=False)


def remove_language(language, paths):
    if language == "en":
        print("English is the source language", file=sys.stderr)
        return 2
    for p, catalog in load_catalogs(paths).items():
        removed = 0
        for entry in catalog["strings"].values():
            if entry.get("localizations", {}).pop(language, None) is not None:
                removed += 1
                if not entry["localizations"]:
                    del entry["localizations"]
        if removed:
            with open(p, encoding="utf-8") as f:
                ends_with_newline = f.read().endswith("\n")
            with open(p, "w", encoding="utf-8") as f:
                f.write(xcode_json(catalog) + ("\n" if ends_with_newline else ""))
        print(f"{p}: removed {removed} {language} entries")
    return 0


def main(argv):
    if len(argv) == 4 and argv[0] == "merge":
        merge(*argv[1:])
    elif len(argv) == 2 and argv[0] == "xliff-status":
        return xliff_status(argv[1])
    elif argv and argv[0] == "catalog-status":
        rest = argv[1:]
        return catalog_status([p for p in rest if p != "--check"], "--check" in rest)
    elif len(argv) >= 3 and argv[0] == "remove-language":
        return remove_language(argv[1], argv[2:])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
