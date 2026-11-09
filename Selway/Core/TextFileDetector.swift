import Foundation

// MARK: - Text/binary detection + editor eligibility

enum TextFileDetector {

    /// Extensions we always treat as editable text (fast path, no disk sniff).
    static let knownTextExtensions: Set<String> = [
        "txt","text","log","md","markdown","mdown","rtf",
        "json","json5","jsonc","yaml","yml","toml","ini","conf","cfg","properties","env",
        "xml","svg","html","htm","xhtml","css","scss","sass","less",
        "js","jsx","mjs","cjs","ts","tsx","swift","m","mm","h","hpp","c","cc","cpp","cxx",
        "java","kt","kts","go","rs","rb","php","py","pyw","pl","pm","lua","r","dart","scala",
        "sh","bash","zsh","fish","ps1","bat","cmd","sql","graphql","gql",
        "vue","svelte","astro","tex","bib","csv","tsv","diff","patch","gitignore",
        "gitattributes","editorconfig","dockerfile","makefile","mk","cmake","gradle",
        "asm","s","vim","el","clj","ex","exs","erl","hs","ml","fs","groovy","nim","zig"
    ]

    /// Extensions that are text only sometimes, so they are always sniffed — even when
    /// sniffing unknown types is turned off. Property lists are often binary (`bplist`).
    static let sniffedTextExtensions: Set<String> = ["plist"]

    /// Filenames (no extension) commonly used for text/config files.
    static let knownTextFilenames: Set<String> = [
        "makefile","dockerfile","readme","license","changelog","authors",
        ".gitignore",".gitattributes",".editorconfig",".env",".zshrc",".bashrc",".bash_profile",
        ".profile",".vimrc","podfile","gemfile","rakefile",".npmrc",".prettierrc",".eslintrc"
    ]

    static let sniffUnknownKey = "selwayEditorSniffUnknown"

    /// When true (default), unknown file types are sniffed and opened in the editor
    /// if they look like text. When false, only known text types open in the editor.
    static func sniffUnknown(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: sniffUnknownKey) as? Bool ?? true
    }

    /// Decide whether a file should open in the in-app code editor.
    /// - Parameter sniffUnknown: injected for tests; the app passes the user setting.
    static func isEditableText(_ url: URL, sniffUnknown: Bool = sniffUnknown()) -> Bool {
        let ext  = url.pathExtension.lowercased()
        if !ext.isEmpty && knownTextExtensions.contains(ext) { return true }
        if !ext.isEmpty && sniffedTextExtensions.contains(ext) { return sniffIsText(url) }
        let name = url.lastPathComponent.lowercased()
        if knownTextFilenames.contains(name) { return true }
        guard sniffUnknown else { return false }
        return sniffIsText(url)
    }

    /// Reads the first 8 KB and applies the same binary test the editor's loader uses.
    /// The type is checked before opening (never open a device: opening a serial
    /// port can reset the board on it) and again on the open descriptor, which is
    /// opened non-blocking and without following a link, so a FIFO swapped in
    /// after the check can't hang the caller. `beforeOpen` (tests) runs with the
    /// resolved path between the check and the open.
    static func sniffIsText(_ url: URL, beforeOpen: ((URL) -> Void)? = nil) -> Bool {
        let target = TextFileIO.resolved(url)
        guard TextFileIO.isRegularFile(target) else { return false }
        beforeOpen?(target)
        let fd = open(target.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        var buffer = [UInt8](repeating: 0, count: 8192)
        var n = 0
        repeat {
            n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        } while n < 0 && errno == EINTR
        guard n >= 0 else { return false }
        return sniffIsText(Data(buffer[0..<n]))
    }

    static func sniffIsText(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        if TextFileCodec.hasUnicodeBOM(data) { return true }
        if TextFileCodec.isBinaryPlist(data) { return false }
        return !TextFileCodec.looksBinary(data)
    }
}
