import Foundation
import Testing
@testable import SelwayCore

/// The notices the Acknowledgments window shows: one for each component that ships, each
/// with its whole license, and in step with the versions the app bundles.
@Suite struct ThirdPartyNoticesTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func notice(_ id: String) throws -> ThirdPartyNotice {
        try #require(ThirdPartyNotice.all.first { $0.id == id }, "no notice for \(id)")
    }

    @Test func identifiersAndNamesAreUnique() {
        let all = ThirdPartyNotice.all
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.name)).count == all.count)
    }

    /// The list shows names verbatim, untranslated, so each is a product's own name rather
    /// than an English phrase describing it.
    @Test func namesAreProductNames() throws {
        #expect(try notice("browserify-shims").name == "Browserify")
        #expect(try notice("dracula").name == "Dracula")
        #expect(try notice("lodash-modules").name == "lodash.clone, lodash.slice, lodash.merge")
        #expect(try notice("vscode-diff").name == "Visual Studio Code")
        for notice in ThirdPartyNotice.all {
            let words = notice.name.split(separator: " ")
            for phrase in ["and", "theme", "shims", "algorithm"] {
                #expect(!words.contains(Substring(phrase)), "\(notice.id) is named “\(notice.name)”")
            }
        }
    }

    /// The project Selway came from first, then its Swift package, then the code editor.
    @Test func listsTheMainComponentsFirst() {
        #expect(ThirdPartyNotice.all.prefix(3).map(\.id) == ["finderflow", "sparkle", "ace"])
    }

    @Test func everyNoticeIsComplete() {
        for notice in ThirdPartyNotice.all {
            #expect(!notice.name.isEmpty && !notice.copyright.isEmpty, "\(notice.id)")
            #expect(notice.homepage.scheme == "https", "\(notice.id)")
            #expect(notice.text.count > 100, "\(notice.id) has no license text")
            #expect(!notice.role.title.isEmpty && !notice.license.title.isEmpty, "\(notice.id)")
        }
    }

    /// Each license's own conditions are there in full, not just its name.
    @Test func everyLicenseTextIsTheWholeLicense() {
        for notice in ThirdPartyNotice.all {
            // Line breaks fall in different places in each copy of a license.
            let words = notice.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            switch notice.license {
            case .mit:
                #expect(words.contains("Permission is hereby granted, free of charge"), "\(notice.id)")
                #expect(words.contains("shall be included in"), "\(notice.id)")
                #expect(words.contains("WITHOUT WARRANTY OF ANY KIND"), "\(notice.id)")
            case .bsd3:
                #expect(words.contains("Redistribution and use in source and binary forms"), "\(notice.id)")
                #expect(words.contains("Neither the name of"), "\(notice.id)")
            case .apache2:
                #expect(words.contains("Apache License"), "\(notice.id)")
                #expect(words.contains("Version 2.0, January 2004"), "\(notice.id)")
                #expect(words.contains("END OF TERMS AND CONDITIONS"), "\(notice.id)")
            case .isc:
                #expect(words.contains("Permission to use, copy, modify, and/or distribute this software"), "\(notice.id)")
                #expect(words.contains("copyright notice and this permission notice appear in all copies"), "\(notice.id)")
            case .publicDomain:
                #expect(words.contains("Public Domain"), "\(notice.id)")
            }
        }
    }

    /// The holder named in the short copyright line is the one the license names.
    @Test func copyrightHoldersAppearInTheirNotices() throws {
        let holders = ["finderflow": "Gobinda Tarafdar", "sparkle": "Andy Matuschak", "ace": "Ajax.org B.V.",
                       "codemirror": "Marijn Haverbeke", "coffeescript": "Jeremy Ashkenas",
                       "csslint": "Nicole Sullivan", "parserlib": "Nicholas C. Zakas", "dracula": "Zeno Rocha",
                       "html5": "Aria Stewart", "jshint": "Anton Kovalyov", "js-yaml": "Vitaly Puzrin",
                       "luaparse": "Oskar Schöldström", "phpjs": "Niklas von Hertzen", "xmldom": "jindw",
                       "underscore": "Jeremy Ashkenas", "lodash": "The Dojo Foundation",
                       "lodash-modules": "jQuery Foundation", "browserify-shims": "Joyent",
                       "inherits": "Isaac Z. Schlueter", "vscode-diff": "Microsoft Corporation"]
        for (id, holder) in holders {
            let notice = try notice(id)
            #expect(notice.copyright.contains(holder), "\(id)")
            #expect(notice.text.contains(holder), "\(id)")
        }
    }

    /// FinderFlow's MIT notice is the one in this repository's LICENSE, which Selway kept
    /// when it forked.
    @Test func finderFlowNoticeMatchesTheRepositoryLicense() throws {
        let license = try text("LICENSE")
        let finderFlow = try notice("finderflow")
        #expect(finderFlow.license == .mit)
        #expect(finderFlow.role == .origin)
        #expect(license.contains(finderFlow.copyright))
        // The permission and warranty paragraphs, line for line.
        let body = try #require(finderFlow.text.range(of: "Permission is hereby granted"))
        #expect(license.contains(finderFlow.text[body.lowerBound...]))
    }

    /// The Sparkle notice is for the version the project pins.
    @Test func sparkleVersionMatchesThePinnedPackage() throws {
        let resolved = try text("Selway.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(resolved.utf8)) as? [String: Any])
        let pins = try #require(json["pins"] as? [[String: Any]])
        // Sparkle is the app's only Swift package; any other needs a notice here too.
        #expect(pins.compactMap { $0["identity"] as? String } == ["sparkle"])
        let sparkle = try #require(pins.first { $0["identity"] as? String == "sparkle" })
        let version = try #require((sparkle["state"] as? [String: Any])?["version"] as? String)
        #expect(try notice("sparkle").version == version)
    }

    /// The Ace notice is for the build in Selway/AceEditor.
    @Test func aceVersionMatchesTheBundledBuild() throws {
        let ace = try text("Selway/AceEditor/ace.js")
        let marker = try #require(ace.range(of: ".version=\""))
        let rest = ace[marker.upperBound...]
        let version = String(rest.prefix { $0 != "\"" })
        #expect(try notice("ace").version == version)
    }

    /// Selway/AceEditor carries Ace's license, as its source and binary redistribution
    /// terms ask, and it's the notice the Acknowledgments window shows.
    @Test func aceLicenseShipsWithTheAceBuild() throws {
        let license = try text("Selway/AceEditor/LICENSE")
        #expect(license.trimmingCharacters(in: .whitespacesAndNewlines) == (try notice("ace")).text)
    }

    /// What the Ace build bundles, as a file in Selway/AceEditor and a string in it that
    /// shows the library is there (a module path, a version, a name the minifier kept).
    private static let aceLibraryMarkers: [String: [(file: String, marker: String)]] = [
        "browserify-shims": [("worker-javascript.js", "/node_modules/assert/assert.js"),
                             ("worker-javascript.js", "/node_modules/events/events.js"),
                             ("worker-javascript.js", "/node_modules/util/util.js"),
                             ("worker-javascript.js", "/node_modules/process/browser.js"),
                             ("worker-javascript.js", "console-browserify/index.js"),
                             ("worker-javascript.js", "date-now/index.js"),
                             ("worker-html.js", "process/browser.js")],
        "codemirror": [("keybinding-vim.js", "CodeMirror")],
        "coffeescript": [("worker-coffee.js", "ace/mode/coffee/coffee"), ("worker-coffee.js", "\"2.2.1\"")],
        "csslint": [("worker-css.js", "ace/mode/css/csslint"), ("worker-css.js", "\"1.0.5\"")],
        "parserlib": [("worker-css.js", "parserlib")],
        "dracula": [("theme-dracula.js", "dracula")],
        "html5": [("worker-html.js", "html5-entities")],
        "inherits": [("worker-javascript.js", "inherits/inherits_browser.js"), ("worker-html.js", "\"inherits\"")],
        "jshint": [("worker-javascript.js", "jshint/src/jshint.js")],
        "js-yaml": [("worker-yaml.js", "js-yaml")],
        "json-parse": [("worker-json.js", "ace/mode/json/json_parse")],
        "lodash": [("worker-xquery.js", "xqlint/node_modules/lodash/index.js"), ("worker-xquery.js", "\"3.10.1\"")],
        "lodash-modules": [("worker-javascript.js", "lodash.clone/index.js"),
                           ("worker-javascript.js", "lodash.slice/index.js"),
                           ("worker-yaml.js", "lodash.merge")],
        "luaparse": [("worker-lua.js", "\"0.3.1\"")],
        "phpjs": [("worker-php.js", "ace/mode/php/php")],
        "underscore": [("worker-javascript.js", "underscore/underscore-umd.js"), ("worker-javascript.js", "\"1.13.6\"")],
        "vscode-diff": [("ext-diff.js", "ace/ext/diff/providers/default"), ("ext-diff.js", "Invalid clipping range: ")],
        "xmldom": [("worker-xml.js", "ace/mode/xml/dom-parser")],
        "xqlint": [("worker-xquery.js", "xqlint/lib/xqlint.js")],
    ]

    /// The libraries inside the Ace build are still bundled, as the notices describe them: an
    /// Ace update that drops or replaces one fails here, so its notice can be checked.
    @Test func aceLibrariesAreStillBundled() throws {
        let partOfAce = ThirdPartyNotice.all.filter { $0.role == .partOfCodeEditor }.map(\.id)
        #expect(Set(partOfAce) == Set(Self.aceLibraryMarkers.keys))
        var files: [String: String] = [:]
        for (id, markers) in Self.aceLibraryMarkers {
            for (file, marker) in markers {
                if files[file] == nil {
                    files[file] = try? text("Selway/AceEditor/\(file)")
                }
                guard let contents = files[file] else {
                    Issue.record("\(id): Selway/AceEditor/\(file) is gone")
                    continue
                }
                #expect(contents.contains(marker), "\(id): \(file) no longer has \(marker)")
            }
        }
    }
}
