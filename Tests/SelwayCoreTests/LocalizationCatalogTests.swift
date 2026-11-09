import Foundation
import Testing

private let localizationRepoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The Core uses NSLocalizedString with ordinary quoted keys. This small scanner deliberately
/// handles only that style, while allowing whitespace/newlines before the key and comment.
private func localizationCalls(in source: String) -> [(line: Int, key: String?, tableName: String?)] {
    // Remove full-line comments first so documentation examples are not treated as code.
    let lines = source.components(separatedBy: "\n")
    let uncommented = lines.map { line in
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : line
    }.joined(separator: "\n")
    let chars = Array(uncommented)

    let marker = Array("NSLocalizedString")
    var calls: [(line: Int, key: String?, tableName: String?)] = []
    var i = 0
    while i + marker.count <= chars.count {
        let endOfMarker = i + marker.count
        guard Array(chars[i..<endOfMarker]).elementsEqual(marker) else { i += 1; continue }
        var cursor = i + marker.count
        while cursor < chars.count && chars[cursor].isWhitespace { cursor += 1 }
        guard cursor < chars.count && chars[cursor] == "(" else { i += marker.count; continue }
        cursor += 1
        while cursor < chars.count && chars[cursor].isWhitespace { cursor += 1 }
        let line = chars[..<i].filter { $0 == "\n" }.count + 1
        guard cursor < chars.count && chars[cursor] == "\"" else {
            calls.append((line, nil, nil))
            i = cursor
            continue
        }

        cursor += 1
        var key = ""
        var literal = true
        var closed = false
        while cursor < chars.count {
            let char = chars[cursor]
            if char == "\"" { closed = true; cursor += 1; break }
            if char != "\\" { key.append(char); cursor += 1; continue }
            cursor += 1
            guard cursor < chars.count else { literal = false; break }
            switch chars[cursor] {
            case "\\": key.append("\\"); cursor += 1
            case "\"": key.append("\""); cursor += 1
            case "n": key.append("\n"); cursor += 1
            case "t": key.append("\t"); cursor += 1
            case "(": literal = false // String interpolation is not an extractable key.
            case "u":
                cursor += 1
                guard cursor < chars.count && chars[cursor] == "{" else { literal = false; continue }
                cursor += 1
                let start = cursor
                while cursor < chars.count && chars[cursor] != "}" { cursor += 1 }
                guard cursor < chars.count,
                      let scalarValue = UInt32(String(chars[start..<cursor]), radix: 16),
                      let scalar = Unicode.Scalar(scalarValue) else { literal = false; continue }
                key.unicodeScalars.append(scalar)
                cursor += 1
            default: literal = false; cursor += 1
            }
        }
        let tailEnd = min(chars.count, cursor + 160)
        let tail = String(chars[cursor..<tailEnd])
        let tablePattern = #"^\s*,\s*tableName:\s*"([^"]+)""#
        let tableRegex = try! NSRegularExpression(pattern: tablePattern)
        let tableMatch = tableRegex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail))
        let tableName = tableMatch.flatMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: tail) else { return nil }
            return String(tail[range])
        }
        calls.append((line, literal && closed ? key : nil, tableName))
        i = max(cursor, i + marker.count)
    }
    return calls
}

/// Each printf conversion in `value` as "<argument>$<length><conversion>" ("2$lld"), sorted.
/// An unnumbered conversion takes its argument from its order, as String(format:) does, so
/// "%lld of %@" and "%1$lld of %2$@" match but a plural on the wrong argument doesn't. A "%%"
/// is consumed as a pair, so "50%% done" has no conversion.
private func formatSpecifiers(in value: String) -> [String] {
    let pattern = #"%%|%(?:([0-9]+)\$)?[-+#0]*(?:[0-9]+|\*)?(?:\.(?:[0-9]+|\*))?(hh|h|ll|l|z|t|j|L)?([@diuoxXfFeEgGaAcCsSpn])"#
    let regex = try! NSRegularExpression(pattern: pattern)
    func group(_ match: NSTextCheckingResult, _ index: Int) -> String {
        Range(match.range(at: index), in: value).map { String(value[$0]) } ?? ""
    }
    var specifiers: [String] = []
    for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) where !group(match, 3).isEmpty {
        let argument = group(match, 1)
        specifiers.append((argument.isEmpty ? String(specifiers.count + 1) : argument) + "$" + group(match, 2) + group(match, 3))
    }
    return specifiers.sorted()
}

/// `value` without argument numbers ("%2$@" → "%@"), to compare English text with its key.
private func withoutArgumentNumbers(_ value: String) -> String {
    value.replacingOccurrences(of: #"%[0-9]+\$"#, with: "%", options: .regularExpression)
}

private func catalogIntegerSpecifiers(in value: String) -> [String] {
    formatSpecifiers(in: value).filter { specifier in
        ["d", "i", "u"].contains(specifier.last.map(String.init) ?? "")
    }
}

private func catalogStringValue(_ value: Any?) -> String? {
    guard let object = value as? [String: Any] else { return nil }
    let unit = object["stringUnit"] as? [String: Any] ?? object
    return unit["value"] as? String
}

private func pluralForms(in localization: [String: Any]) -> [String: String] {
    guard let variations = localization["variations"] as? [String: Any],
          let plural = variations["plural"] as? [String: Any] else { return [:] }
    return plural.compactMapValues(catalogStringValue)
}

/// A plural form may leave out the integer it's counted by, in a language whose grammar
/// doesn't repeat the number (German "ein Element"). With several plural substitutions,
/// each may leave out its own count.
private func specifiersMatch(_ actual: [String], expected: [String], countedIntegers: [String] = []) -> Bool {
    var candidates = [expected]
    for counted in countedIntegers {
        candidates += candidates.compactMap { candidate in
            candidate.firstIndex(of: counted).map { index in
                var shorter = candidate
                shorter.remove(at: index)
                return shorter
            }
        }
    }
    return candidates.contains(actual)
}

/// Validate localized string values, all present plural categories, device variants, and
/// substitution expansions. The input is the parsed catalog dictionary, which also lets
/// the tests exercise translated forms before the project has real translations.
private func catalogTranslationFailures(_ catalog: [String: Any], path: String = "catalog") -> [String] {
    guard let entries = catalog["strings"] as? [String: Any] else { return ["\(path): missing strings dictionary"] }
    var failures: [String] = []

    for (key, rawEntry) in entries {
        guard let entry = rawEntry as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any] else { continue }
        let expected = formatSpecifiers(in: key)
        let expectedIntegers = catalogIntegerSpecifiers(in: key)

        for (language, rawLocalization) in localizations where language != "en" {
            guard let localization = rawLocalization as? [String: Any] else { continue }
            let prefix = "\(path): \(key) [\(language)]"
            let substitutions = localization["substitutions"] as? [String: Any] ?? [:]
            let baseValue = catalogStringValue(localization["stringUnit"])
            let localPlural = pluralForms(in: localization)

            if let baseValue, substitutions.isEmpty {
                let actual = formatSpecifiers(in: baseValue)
                if actual != expected {
                    failures.append("\(prefix): value has format specifiers \(actual), expected \(expected)")
                }
            }

            for (category, value) in localPlural {
                let actual = formatSpecifiers(in: value)
                if !specifiersMatch(actual, expected: expected, countedIntegers: expectedIntegers) {
                    failures.append("\(prefix): plural '\(category)' has format specifiers \(actual), expected \(expected)")
                }
            }

            // Device variations contain ordinary translated strings, not plural forms.
            if let variations = localization["variations"] as? [String: Any],
               let devices = variations["device"] as? [String: Any] {
                func checkDeviceValues(_ value: Any, trail: String) {
                    guard let object = value as? [String: Any] else { return }
                    if let string = catalogStringValue(object) {
                        let actual = formatSpecifiers(in: string)
                        if actual != expected {
                            failures.append("\(prefix): device '\(trail)' has format specifiers \(actual), expected \(expected)")
                        }
                        return
                    }
                    for (name, child) in object { checkDeviceValues(child, trail: trail.isEmpty ? name : "\(trail).\(name)") }
                }
                for (device, value) in devices { checkDeviceValues(value, trail: device) }
            }

            guard !substitutions.isEmpty, let baseValue else { continue }
            let names = substitutions.keys.sorted()
            var formsByName: [String: [(category: String, replacement: String, counted: String)]] = [:]
            for name in names {
                if !baseValue.contains("%#@\(name)@") {
                    failures.append("\(prefix): substitution '\(name)' is not used by its localized value")
                }
                guard let substitution = substitutions[name] as? [String: Any],
                      let argument = substitution["argNum"] as? Int,
                      let type = substitution["formatSpecifier"] as? String,
                      let variations = substitution["variations"] as? [String: Any],
                      let plural = variations["plural"] as? [String: Any] else {
                    failures.append("\(prefix): substitution '\(name)' has no plural definition")
                    continue
                }
                for (category, rawForm) in plural {
                    guard let value = catalogStringValue(rawForm) else {
                        failures.append("\(prefix): substitution '\(name)' is missing plural form '\(category)'")
                        continue
                    }
                    let count = value.components(separatedBy: "%arg").count - 1
                    if count > 1 {
                        failures.append("\(prefix): substitution '\(name)' plural '\(category)' contains %arg \(count) times, expected at most once")
                    }
                    // `formatSpecifiers` lists "2$lld" for "%2$lld".
                    formsByName[name, default: []].append((category, value.replacingOccurrences(of: "%arg", with: "%\(argument)$\(type)"),
                                                           "\(argument)$\(type)"))
                }
            }

            // Check each substitution form in context so a dropped non-count argument is
            // caught while the one counted integer may be omitted by a plural form.
            func expand(_ index: Int, _ value: String, _ counted: [String]) {
                guard index < names.count else {
                    let actual = formatSpecifiers(in: value)
                    if !specifiersMatch(actual, expected: expected, countedIntegers: counted) {
                        failures.append("\(prefix): substitution expansion has format specifiers \(actual), expected \(expected)")
                    }
                    return
                }
                let name = names[index]
                guard let forms = formsByName[name], !forms.isEmpty else {
                    expand(index + 1, value, counted)
                    return
                }
                for form in forms where value.contains("%#@\(name)@") {
                    let expanded = value.replacingOccurrences(of: "%#@\(name)@", with: form.replacement)
                    expand(index + 1, expanded, counted + [form.counted])
                }
            }
            expand(0, baseValue, [])
        }
    }
    return failures.sorted()
}

/// Every String Catalog in the app and the Finder extension, in any subfolder.
private func allCatalogPaths() throws -> [String] {
    ["Selway", "SelwayExtension"].flatMap { folder -> [String] in
        let root = localizationRepoRoot.appendingPathComponent(folder).path
        let found = FileManager.default.enumerator(atPath: root)?.compactMap { $0 as? String } ?? []
        return found.filter { $0.hasSuffix(".xcstrings") }.map { "\(folder)/\($0)" }
    }.sorted()
}

@Test func everyCatalogEntryHasTranslatorContext() throws {
    let paths = try allCatalogPaths()
    var failures: [String] = []
    for path in paths {
        let data = try Data(contentsOf: localizationRepoRoot.appendingPathComponent(path))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(catalog["strings"] as? [String: Any])
        for (key, rawEntry) in entries {
            let comment = (rawEntry as? [String: Any])?["comment"] as? String
            if comment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                failures.append("\(path): \(key.isEmpty ? "<empty key>" : key)")
            }
        }
    }
    #expect(failures.isEmpty, "Catalog entries without translator comments: \(failures.sorted().joined(separator: ", "))")
}

@Test func catalogsHaveNoEmptyKeys() throws {
    let paths = try allCatalogPaths()
    var failures: [String] = []
    for path in paths {
        let data = try Data(contentsOf: localizationRepoRoot.appendingPathComponent(path))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(catalog["strings"] as? [String: Any])
        if entries[""] != nil { failures.append(path) }
    }
    #expect(failures.isEmpty, "String catalogs with an empty key: \(failures.sorted().joined(separator: ", "))")
}

@Test func translatedSpecifiersAreCheckedWithSyntheticCatalogs() {
    let catalog: [String: Any] = ["strings": [
        "%@": ["localizations": ["de": ["stringUnit": ["value": "Datei"]]]],
        "%lld": ["localizations": ["de": ["stringUnit": ["value": "%@ Dateien"]]]],
        "%@ in %@": ["localizations": ["de": ["stringUnit": ["value": "%2$@ in %1$@"]]]],
        "%lld files for %@": ["localizations": ["de": ["variations": ["plural": [
            "few": ["stringUnit": ["value": "%1$lld Dateien"]],
        ]]]]],
        "%lld found for “%@” in %@": ["localizations": ["de": [
            "stringUnit": ["value": "%#@found@ für „%2$@“ in %3$@"],
            "substitutions": ["found": ["argNum": 1, "formatSpecifier": "lld", "variations": ["plural": [
                "one": ["stringUnit": ["value": "ein Treffer"]],
                "other": ["stringUnit": ["value": "%arg Treffer"]],
            ]]]],
        ]]],
        "%1$lld of %2$lld in %3$@": ["localizations": ["de": [
            "stringUnit": ["value": "%#@done@ von %#@total@"],
            "substitutions": [
                "done": ["argNum": 1, "formatSpecifier": "lld", "variations": ["plural": [
                    "one": ["stringUnit": ["value": "eins"]], "other": ["stringUnit": ["value": "%arg"]]]]],
                "total": ["argNum": 2, "formatSpecifier": "lld", "variations": ["plural": [
                    "one": ["stringUnit": ["value": "einem"]], "other": ["stringUnit": ["value": "%arg"]]]]],
            ],
        ]]],
        "%lld item": ["localizations": ["de": ["variations": ["plural": [
            "one": ["stringUnit": ["value": "ein Element"]],
            "other": ["stringUnit": ["value": "%lld Elemente"]],
        ]]]]],
    ]]

    let failures = catalogTranslationFailures(catalog, path: "synthetic")
    #expect(failures.contains { $0.contains("synthetic: %@ [de]") && $0.contains("value") }, "A German value that drops %@ must fail: \(failures)")
    #expect(failures.contains { $0.contains("synthetic: %lld [de]") && $0.contains("expected [\"1$lld\"]") }, "Changing %lld to %@ must fail: \(failures)")
    #expect(failures.contains { $0.contains("synthetic: %lld files for %@ [de]") && $0.contains("plural 'few'") }, "A few form that drops the non-count %@ must fail: \(failures)")
    #expect(!failures.contains { $0.contains("synthetic: %@ in %@ [de]") }, "A correctly numbered reordering must pass: \(failures)")
    #expect(!failures.contains { $0.contains("synthetic: %lld item [de]") }, "A plural one form may omit its counted integer: \(failures)")
    #expect(!failures.contains { $0.contains("synthetic: %lld found for") }, "A substitution's one form may omit its count: \(failures)")
    #expect(failures.contains { $0.contains("synthetic: %1$lld of %2$lld in %3$@ [de]") && $0.contains("expansion") },
            "Dropping both counts is allowed, but not the %3$@: \(failures)")
}

@Test func everyTranslatedCatalogValueKeepsItsKeySpecifiers() throws {
    let paths = try allCatalogPaths()
    var failures: [String] = []
    for path in paths {
        let data = try Data(contentsOf: localizationRepoRoot.appendingPathComponent(path))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        failures += catalogTranslationFailures(catalog, path: path)
    }
    #expect(failures.isEmpty, "Translated catalog values with changed format specifiers:\n\(failures.joined(separator: "\n"))")
}

@Test func coreLocalizationKeysAreLiteralAndCatalogued() throws {
    let core = localizationRepoRoot.appendingPathComponent("Selway/Core")
    let catalogURL = localizationRepoRoot.appendingPathComponent("Selway/Localizable.xcstrings")
    let files = try FileManager.default.contentsOfDirectory(at: core, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    let catalogData = try Data(contentsOf: catalogURL)
    let catalog = try #require(try JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
    var catalogs: [String: [String: Any]] = ["": try #require(catalog["strings"] as? [String: Any])]

    var keys: [String: Set<String>] = [:]
    var nonLiteralCalls: [String] = []
    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        for call in localizationCalls(in: source) {
            guard let key = call.key else {
                let relativePath = file.path.replacingOccurrences(of: localizationRepoRoot.path + "/", with: "")
                nonLiteralCalls.append("\(relativePath):\(call.line)")
                continue
            }
            keys[call.tableName ?? "", default: []].insert(key)
        }
    }
    #expect(nonLiteralCalls.isEmpty,
            "NSLocalizedString keys must be string literals (not variables or interpolations):\n\(nonLiteralCalls.joined(separator: "\n"))")

    var missingByTable: [String: [String]] = [:]
    for (table, tableKeys) in keys {
        if catalogs[table] == nil {
            let tableURL = localizationRepoRoot.appendingPathComponent("Selway/\(table).xcstrings")
            if let data = try? Data(contentsOf: tableURL),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let entries = parsed["strings"] as? [String: Any] {
                catalogs[table] = entries
            } else {
                missingByTable[table] = tableKeys.sorted()
                continue
            }
        }
        let entries = catalogs[table] ?? [:]
        missingByTable[table] = tableKeys.filter { entries[$0] == nil }.sorted()
    }
    let missing = missingByTable.filter { !$0.value.isEmpty }
        .map { table, entries in "\(table.isEmpty ? "Localizable" : table): \(entries.joined(separator: ", "))" }
        .sorted()
    #expect(missing.isEmpty,
            "Missing from string catalogs: \(missing.joined(separator: "; ")). Run scripts/sync-strings.sh.")
}

private func localizedCountCalls(in source: String) -> [(key: String, one: String, other: String)] {
    let chars = Array(source)
    let marker = Array("LocalizedCount.string")
    var calls: [(key: String, one: String, other: String)] = []
    var i = 0
    while i + marker.count < chars.count {
        guard Array(chars[i..<(i + marker.count)]).elementsEqual(marker) else { i += 1; continue }
        var open = i + marker.count
        while open < chars.count && chars[open].isWhitespace { open += 1 }
        guard open < chars.count && chars[open] == "(" else { i += marker.count; continue }
        var cursor = open + 1
        var depth = 1
        var quoted = false
        var escaped = false
        while cursor < chars.count && depth > 0 {
            let c = chars[cursor]
            if quoted {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { quoted = false }
            } else if c == "\"" { quoted = true }
            else if c == "(" { depth += 1 }
            else if c == ")" { depth -= 1 }
            cursor += 1
        }
        guard depth == 0 else { break }
        let body = String(chars[(open + 1)..<(cursor - 1)])
        let key = literalArgument(#"NSLocalizedString\s*\(\s*"((?:\\.|[^"])*)""#, in: body)
        let one = literalArgument(#"\bone:\s*"((?:\\.|[^"])*)""#, in: body)
        let other = literalArgument(#"\bother:\s*"((?:\\.|[^"])*)""#, in: body)
        if let key, let one, let other { calls.append((key, one, other)) }
        i = cursor
    }
    return calls
}

private func literalArgument(_ pattern: String, in source: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
          let range = Range(match.range(at: 1), in: source) else { return nil }
    return String(source[range])
}

@Test func localizedCountEnglishPluralFormsMatchSource() throws {
    let core = localizationRepoRoot.appendingPathComponent("Selway/Core")
    let catalogURL = localizationRepoRoot.appendingPathComponent("Selway/Localizable.xcstrings")
    let catalogData = try Data(contentsOf: catalogURL)
    let catalog = try #require(try JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
    let entries = try #require(catalog["strings"] as? [String: Any])
    let files = try FileManager.default.contentsOfDirectory(at: core, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    var failures: [String] = []

    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        let calls = localizedCountCalls(in: source)
        // A call this scanner can't read (a key or form that isn't a literal) isn't skipped.
        let written = source.components(separatedBy: "LocalizedCount.string(").count - 1
        if calls.count != written {
            failures.append("\(file.lastPathComponent): \(written - calls.count) LocalizedCount.string calls without literal key, one: and other:")
        }
        for call in calls {
            guard let entry = entries[call.key] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let english = localizations["en"] as? [String: Any],
                  let variations = english["variations"] as? [String: Any],
                  let plural = variations["plural"] as? [String: Any] else {
                failures.append("\(call.key): missing English plural catalog forms")
                continue
            }
            for (form, expected) in [("one", call.one), ("other", call.other)] {
                let actual = ((plural[form] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
                if actual != expected { failures.append("\(call.key): plural '\(form)' is \(String(describing: actual)), expected '\(expected)'") }
            }
            if call.other != call.key { failures.append("\(call.key): source other form '\(call.other)' must equal the key") }
        }
    }
    #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
}

@Test func catalogPluralFormsKeepTheKeyFormatSpecifiers() throws {
    var failures: [String] = []

    for catalogPath in try allCatalogPaths() {
        let url = localizationRepoRoot.appendingPathComponent(catalogPath)
        let data = try Data(contentsOf: url)
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(catalog["strings"] as? [String: Any])

        for (key, rawEntry) in entries {
            guard let entry = rawEntry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let english = localizations["en"] as? [String: Any] else { continue }

            let expectedTypes = formatSpecifiers(in: key)
            if let variations = english["variations"] as? [String: Any],
               let plural = variations["plural"] as? [String: Any] {
                for form in ["one", "other"] {
                    guard let formValue = plural[form] as? [String: Any],
                          let unit = formValue["stringUnit"] as? [String: Any],
                          let value = unit["value"] as? String else {
                        failures.append("\(catalogPath): \(key): missing English plural form '\(form)'")
                        continue
                    }
                    let actualTypes = formatSpecifiers(in: value)
                    if actualTypes != expectedTypes {
                        failures.append("\(catalogPath): \(key): plural '\(form)' has format specifiers \(actualTypes), expected \(expectedTypes)")
                    }
                    if form == "other" && withoutArgumentNumbers(value) != withoutArgumentNumbers(key) {
                        failures.append("\(catalogPath): \(key): plural 'other' is '\(value)', which isn't the key's English")
                    }
                }
            }

            guard let substitutions = english["substitutions"] as? [String: Any], !substitutions.isEmpty else { continue }
            guard let englishValue = (english["stringUnit"] as? [String: Any])?["value"] as? String else {
                failures.append("\(catalogPath): \(key): has substitutions but no English value to use them")
                continue
            }

            let substitutionNames = substitutions.keys.sorted()
            for name in substitutionNames where !englishValue.contains("%#@\(name)@") {
                failures.append("\(catalogPath): \(key): substitution '\(name)' isn't used by the English value '\(englishValue)'")
            }
            var availableForms: Set<String> = []
            for name in substitutionNames {
                guard let substitution = substitutions[name] as? [String: Any],
                      let argNum = substitution["argNum"] as? Int,
                      let formatSpecifier = substitution["formatSpecifier"] as? String,
                      let variations = substitution["variations"] as? [String: Any],
                      let plural = variations["plural"] as? [String: Any] else {
                    failures.append("\(catalogPath): \(key): substitution '\(name)' is missing its plural definition")
                    continue
                }
                var values: [String: String] = [:]
                for form in ["one", "other"] {
                    guard let formValue = plural[form] as? [String: Any],
                          let unit = formValue["stringUnit"] as? [String: Any],
                          let value = unit["value"] as? String else {
                        failures.append("\(catalogPath): \(key): substitution '\(name)' is missing plural form '\(form)'")
                        continue
                    }
                    let argCount = value.components(separatedBy: "%arg").count - 1
                    if argCount != 1 {
                        failures.append("\(catalogPath): \(key): substitution '\(name)' plural '\(form)' contains %arg \(argCount) times, expected once")
                    }
                    values[form] = value.replacingOccurrences(of: "%arg", with: "%\(argNum)$\(formatSpecifier)")
                }
                if values["other"] != nil { availableForms.insert(name) }
                if values["one"] != nil { availableForms.insert("\(name):one") }
            }

            for selectedName in availableForms.sorted() {
                var expanded = englishValue
                for name in substitutionNames {
                    guard let substitution = substitutions[name] as? [String: Any],
                          let argNum = substitution["argNum"] as? Int,
                          let formatSpecifier = substitution["formatSpecifier"] as? String,
                          let plural = (substitution["variations"] as? [String: Any])?["plural"] as? [String: Any] else { continue }
                    let form = selectedName == "\(name):one" ? "one" : "other"
                    guard let value = (plural[form] as? [String: Any])?["stringUnit"] as? [String: Any],
                          let valueString = value["value"] as? String else { continue }
                    let replacement = valueString.replacingOccurrences(of: "%arg", with: "%\(argNum)$\(formatSpecifier)")
                    expanded = expanded.replacingOccurrences(of: "%#@\(name)@", with: replacement)
                }
                let actualTypes = formatSpecifiers(in: expanded)
                if actualTypes != expectedTypes {
                    failures.append("\(catalogPath): \(key): substitution expansion '\(selectedName)' has format specifiers \(actualTypes), expected \(expectedTypes)")
                }
                // With every substitution in its "other" form, the English must read as the
                // key, so the noun follows the count the key puts it after.
                if !selectedName.hasSuffix(":one") && withoutArgumentNumbers(expanded) != withoutArgumentNumbers(key) {
                    failures.append("\(catalogPath): \(key): substitution expansion '\(selectedName)' reads '\(expanded)', which isn't the key's English")
                }
            }
        }
    }
    #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
}

@Test func catalogCountedStringsHaveEnglishPluralForms() throws {
    let allowlist: [String: String] = [
        "%1$@ failed (exit status %2$d).": "The integer is an exit status.",
        "Something went wrong while connecting (error %d). Try again in a moment.": "The integer is an error code.",
        "%lld of %lld": "The numbers are displayed as a ratio without a counted noun.",
        "(cancelled, %lld of %lld done)": "The numbers describe completed work without a counted noun.",
        "How many recent folders the sidebar lists (1 to %lld)": "The number is part of a settings prompt and has no agreeing noun.",
        "Font size: %lld pt": "The number is a measurement with the invariant abbreviation pt.",
        "Text size %lld%%": "The number is a percentage measurement.",
        "Markdown text size %lld%%": "The number is a percentage measurement.",
    ]
    let catalogPaths = try allCatalogPaths()
    var failures: [String] = []
    var catalogued: Set<String> = []

    for catalogPath in catalogPaths {
        let url = localizationRepoRoot.appendingPathComponent(catalogPath)
        let data = try Data(contentsOf: url)
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(catalog["strings"] as? [String: Any])
        catalogued.formUnion(entries.keys)
        for (key, rawEntry) in entries where !catalogIntegerSpecifiers(in: key).isEmpty {
            guard !allowlist.keys.contains(key) else { continue }
            guard let entry = rawEntry as? [String: Any],
                  let english = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any] else {
                failures.append("\(catalogPath): \(key)")
                continue
            }
            let hasTopLevelPlural = ((english["variations"] as? [String: Any])?["plural"] as? [String: Any]) != nil
            // A substitution counts only if the English value uses it.
            let englishValue = (english["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
            let hasSubstitutionPlural = (english["substitutions"] as? [String: Any])?.contains { name, rawSubstitution in
                guard englishValue.contains("%#@\(name)@"),
                      let substitution = rawSubstitution as? [String: Any],
                      let variations = substitution["variations"] as? [String: Any] else { return false }
                return variations["plural"] != nil
            } ?? false
            if !hasTopLevelPlural && !hasSubstitutionPlural { failures.append("\(catalogPath): \(key)") }
            // Xcode can't tell which count a whole-string plural follows, and leaves the key out.
            if hasTopLevelPlural && catalogIntegerSpecifiers(in: key).count > 1 {
                failures.append("\(catalogPath): \(key) (several counts: use a substitution, not a whole-string plural)")
            }
        }
    }

    #expect(failures.isEmpty,
            "Counted strings need English plural forms or a reasoned allowlist entry: \(failures.sorted().joined(separator: ", ")). Add plural forms or extend the allowlist with a reason.")
    let stale = allowlist.keys.filter { !catalogued.contains($0) }.sorted()
    #expect(stale.isEmpty, "Allowlisted keys no longer in a catalog; remove them: \(stale.joined(separator: ", "))")
}

/// The Finder extension compiles only the Core files it needs. With all of Core, its
/// catalog collected about 300 Core strings it never shows, which translators would
/// have translated twice. Keys are matched as quoted literals, so this holds while the
/// extension's strings have no interpolation ("Open \(name)" is catalogued as "Open %@").
@Test func extensionCatalogHoldsOnlyTheExtensionsOwnStrings() throws {
    let project = try String(contentsOf: localizationRepoRoot.appendingPathComponent("Selway.xcodeproj/project.pbxproj"),
                             encoding: .utf8)
    let targetStart = try #require(project.range(of: "/* SelwayExtension */ = {\n\t\t\tisa = PBXNativeTarget;"))
    let targetEnd = try #require(project.range(of: "\n\t\t};", range: targetStart.upperBound..<project.endIndex))
    #expect(!project[targetStart.upperBound..<targetEnd.lowerBound].contains("fileSystemSynchronizedGroups"),
            "The extension target compiles a synchronized folder (Core?). List the Core files it needs instead.")

    let extensionDir = localizationRepoRoot.appendingPathComponent("SelwayExtension")
    let sources = try FileManager.default.contentsOfDirectory(at: extensionDir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
        .map { try String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")
    let data = try Data(contentsOf: extensionDir.appendingPathComponent("Localizable.xcstrings"))
    let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let entries = try #require(catalog["strings"] as? [String: Any])
    let foreign = entries.keys.filter { !sources.contains("\"\($0)\"") }.sorted()
    #expect(foreign.isEmpty, "Extension catalog keys not in SelwayExtension's sources: \(foreign.joined(separator: ", "))")
}
