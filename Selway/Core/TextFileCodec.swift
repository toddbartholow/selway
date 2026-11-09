import Foundation

// MARK: - Text file format (encoding, BOM, line endings)

/// The line terminator a file uses. Editors work on LF-only buffers; the file's
/// own terminator is restored when it is saved.
enum TextLineEnding: String, Equatable, Sendable {
    case lf   = "\n"
    case crlf = "\r\n"
    case cr   = "\r"

    var displayName: String {
        switch self {
        case .lf:   return "LF"
        case .crlf: return "CRLF"
        case .cr:   return "CR"
        }
    }
}

/// Everything needed to write an edited buffer back in the same shape it was read.
struct TextFileFormat: Equatable, Sendable {
    var encoding: String.Encoding
    var hasBOM: Bool
    var lineEnding: TextLineEnding
    /// The file mixed terminators; a save writes `lineEnding` everywhere.
    var hadMixedLineEndings: Bool = false

    static let utf8 = TextFileFormat(encoding: .utf8, hasBOM: false, lineEnding: .lf)

    var encodingName: String {
        switch encoding {
        case .utf8:               return "UTF-8"
        case .utf16LittleEndian:  return "UTF-16 LE"
        case .utf16BigEndian:     return "UTF-16 BE"
        case .utf32LittleEndian:  return "UTF-32 LE"
        case .utf32BigEndian:     return "UTF-32 BE"
        case .isoLatin1:          return "ISO Latin-1"
        case .windowsCP1252:      return "Windows Latin-1 (CP1252)"
        case .macOSRoman:         return "Mac OS Roman"
        default:                  return encoding.description
        }
    }
}

enum TextFileCodecError: Error, Equatable {
    /// Bytes look like a binary file (NULs, control bytes, `bplist` magic).
    case binary
    /// Bytes don't decode, or don't re-encode to the same bytes, in any supported encoding.
    case undecodable
    /// The buffer has characters the file's encoding can't represent.
    case unencodable(String.Encoding)
}

// MARK: - Codec

/// Decodes file bytes into an editor buffer and encodes it back.
///
/// Guarantees: `decode` only succeeds when `encode(decode(data))` reproduces `data`
/// byte for byte (for files with one consistent line ending), so opening and saving
/// an unedited file never changes it. Binary data is refused rather than decoded as
/// Latin-1, which accepts any bytes and would let an editor overwrite a binary file.
enum TextFileCodec {

    private static let boms: [(bytes: [UInt8], encoding: String.Encoding)] = [
        // UTF-32 LE must be tested before UTF-16 LE (same first two bytes).
        ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
        ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
        ([0xEF, 0xBB, 0xBF],       .utf8),
        ([0xFF, 0xFE],             .utf16LittleEndian),
        ([0xFE, 0xFF],             .utf16BigEndian),
    ]

    static func bom(for encoding: String.Encoding) -> [UInt8]? {
        boms.first { $0.encoding == encoding }?.bytes
    }

    /// Detects the encoding from a BOM, refusing binary content.
    static func decode(_ data: Data) throws -> (text: String, format: TextFileFormat) {
        let bytes = [UInt8](data)

        for (bom, encoding) in boms where bytes.starts(with: bom) {
            let body = Data(bytes[bom.count...])
            guard let raw = String(data: body, encoding: encoding) else { throw TextFileCodecError.undecodable }
            return try finish(raw, encoding: encoding, hasBOM: true, original: data)
        }

        if isBinaryPlist(data) || looksBinary(data) { throw TextFileCodecError.binary }

        if let raw = String(data: data, encoding: .utf8) {
            return try finish(raw, encoding: .utf8, hasBOM: false, original: data)
        }
        for encoding in legacyEncodings(for: bytes) {
            if let raw = String(data: data, encoding: encoding),
               let result = try? finish(raw, encoding: encoding, hasBOM: false, original: data) {
                return result
            }
        }
        throw TextFileCodecError.undecodable
    }

    /// 8-bit encodings to try, most likely first, for text that isn't valid UTF-8.
    ///
    /// Latin-1 maps every byte to one code point and back, but its 0x80–0x9F are
    /// invisible C1 controls that real text doesn't use. Those bytes are almost
    /// always Windows-1252 punctuation (curly quotes, €, dashes), so that is tried
    /// first; Mac OS Roman covers the five bytes Windows-1252 leaves undefined.
    /// Each candidate must round-trip byte for byte (`finish`).
    static func legacyEncodings(for bytes: [UInt8]) -> [String.Encoding] {
        let hasC1 = bytes.contains { (0x80...0x9F).contains($0) }
        return hasC1 ? [.windowsCP1252, .macOSRoman, .isoLatin1] : [.isoLatin1]
    }

    private static func finish(_ raw: String, encoding: String.Encoding, hasBOM: Bool,
                               original: Data) throws -> (text: String, format: TextFileFormat) {
        let (ending, mixed) = detectLineEnding(in: raw)
        let format = TextFileFormat(encoding: encoding, hasBOM: hasBOM,
                                    lineEnding: ending, hadMixedLineEndings: mixed)
        let text = normalizeLineEndings(raw)
        // A decoder that silently substitutes or drops bytes would turn a later
        // save into corruption: insist that the bytes come back unchanged.
        if !mixed {
            guard let again = try? encode(text, as: format), again == original else {
                throw TextFileCodecError.undecodable
            }
        } else {
            var verbatim = format
            verbatim.lineEnding = .lf
            guard let again = try? encodeVerbatim(raw, as: verbatim), again == original else {
                throw TextFileCodecError.undecodable
            }
        }
        return (text, format)
    }

    /// Encodes an LF (or mixed) buffer with the file's terminator, encoding and BOM.
    static func encode(_ text: String, as format: TextFileFormat) throws -> Data {
        let normalized = normalizeLineEndings(text)
        let terminated = format.lineEnding == .lf
            ? normalized
            : normalized.replacingOccurrences(of: "\n", with: format.lineEnding.rawValue)
        return try encodeVerbatim(terminated, as: format)
    }

    private static func encodeVerbatim(_ text: String, as format: TextFileFormat) throws -> Data {
        guard let body = text.data(using: format.encoding, allowLossyConversion: false) else {
            throw TextFileCodecError.unencodable(format.encoding)
        }
        guard format.hasBOM, let bom = bom(for: format.encoding) else { return body }
        return Data(bom) + body
    }

    // MARK: Line endings

    /// The most common terminator (LF when there are none) and whether others occur too.
    static func detectLineEnding(in text: String) -> (TextLineEnding, mixed: Bool) {
        var lf = 0, crlf = 0, cr = 0
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            switch units[i] {
            case 0x0D:
                if i + 1 < units.count, units[i + 1] == 0x0A { crlf += 1; i += 1 } else { cr += 1 }
            case 0x0A:
                lf += 1
            default:
                break
            }
            i += 1
        }
        let kinds = [lf, crlf, cr].filter { $0 > 0 }.count
        let ending: TextLineEnding
        if crlf > lf && crlf >= cr { ending = .crlf }
        else if cr > lf && cr > crlf { ending = .cr }
        else { ending = .lf }
        return (ending, kinds > 1)
    }

    /// Converts CRLF and lone CR to LF.
    static func normalizeLineEndings(_ text: String) -> String {
        guard text.utf16.contains(0x0D) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: Binary sniffing

    static func isBinaryPlist(_ data: Data) -> Bool {
        data.starts(with: Array("bplist".utf8))
    }

    /// True when the bytes have a BOM that marks them as Unicode text.
    static func hasUnicodeBOM(_ data: Data) -> Bool {
        boms.contains { data.starts(with: $0.bytes) }
    }

    /// Heuristic for BOM-less data: any NUL byte, or more than 5% control bytes other
    /// than tab, LF, VT, FF, CR and ESC in the first 64 KB, means binary.
    static func looksBinary(_ data: Data) -> Bool {
        if data.isEmpty { return false }
        if data.contains(0) { return true }
        let sample = data.prefix(65_536)
        var controls = 0
        for b in sample where b < 0x20 {
            switch b {
            case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1B: continue
            default: controls += 1
            }
        }
        return controls * 20 > sample.count
    }
}
