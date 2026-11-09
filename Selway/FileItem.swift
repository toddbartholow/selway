import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The model itself (FileItem, loading, sorting, grouping) lives in
// Core/ModelFileItem.swift and Core/ModelSortGroup.swift so it can be tested
// without AppKit. This file adds the AppKit / SwiftUI presentation bits.

// MARK: - FileItem presentation

extension FileItem {
    // Icon with NSCache — safe, thread-checked, and limits RAM to ~500 entries.
    // The image is left at its own size: its representations (16 to 1024 pt,
    // drawn by IconServices when asked) cost nothing until drawn, and setting
    // `size` doesn't cap memory, it only sets the size the image is drawn at.
    // At 32 pt it was drawn from 64 pixels at 2x and blown up to the Icons
    // view's 64 to 256 pt, blurred. FileIconView draws a copy sized to fit.
    var icon: NSImage {
        if let hit = cachedIcon { return hit }
        // The file's icon is looked up through a link, which for one into an
        // automount folder would mount it (FileItem.load).
        let img = isLinkNotFollowed ? NSWorkspace.shared.icon(for: .symbolicLink)
                                    : NSWorkspace.shared.icon(forFile: url.path)
        FileItem.iconCache.setObject(img, forKey: iconKey as NSString)
        return img
    }

    /// The icon if it is cached, without loading it.
    var cachedIcon: NSImage? { FileItem.iconCache.object(forKey: iconKey as NSString) }

    /// What the icon is cached under: the path, and whether the link there was
    /// followed (the same link is followed or not as where it leads changes,
    /// and each has its own icon). A path starts with "/", so neither key can
    /// be the other.
    var iconKey: String { isLinkNotFollowed ? "link:" + url.path : url.path }

    private static let iconCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 500
        c.totalCostLimit = 16 * 1024 * 1024
        return c
    }()

    static func clearIconCache() { iconCache.removeAllObjects() }

    // Convenience
    var formattedSize: String {
        isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    var formattedDateModified: String { Self.fmt.string(from: dateModified) }
    var formattedDateCreated:  String { Self.fmt.string(from: dateCreated) }

    /// The item's tag dot colours: the colour stored with each tag, so renamed
    /// colour tags and custom coloured ones keep theirs (FileItem.tagColorNumbers).
    var tagColors: [Color] { tagColorNumbers.compactMap(FileItem.colorForLabelNumber) }

    // Single-color convenience kept for backward compat.
    var tagColor: Color? { tagColors.first }

    // macOS Finder exact system tag colors (matches Tag preferences in Finder).
    static func colorForLabelNumber(_ n: Int) -> Color? {
        switch n {
        case 1: return Color(nsColor: .systemGray)
        case 2: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case 3: return Color(red: 0.69, green: 0.32, blue: 0.87)
        case 4: return Color(red: 0.00, green: 0.48, blue: 1.00)
        case 5: return Color(red: 1.00, green: 0.80, blue: 0.00)
        case 6: return Color(red: 1.00, green: 0.23, blue: 0.19)
        case 7: return Color(red: 1.00, green: 0.58, blue: 0.00)
        default: return nil
        }
    }

    fileprivate static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}

// MARK: - Tag dot(s) view — matches macOS Finder's colored-circle appearance

/// A file's tags as coloured dots, which VoiceOver reads as one element:
/// "Tags", with their names ("Red, Work") as its value. Tags without a colour
/// draw nothing but are still read, from a point-sized element; a legacy
/// colour label with no name is only seen.
struct TagDotsView: View {
    let colors: [Color]
    let names: [String]
    /// Points at 100%; the window's text size scales it.
    var size: CGFloat = 10

    @Environment(\.textScale) private var textScale

    var body: some View {
        if !colors.isEmpty {
            HStack(spacing: 2) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(color)
                        .frame(width: (size * textScale).rounded(), height: (size * textScale).rounded())
                        .overlay(
                            Circle().strokeBorder(color.opacity(0.4), lineWidth: 0.5)
                        )
                }
            }
            .tagsElement(names)
        } else if !names.isEmpty {
            Color.clear.frame(width: 1, height: 1).tagsElement(names)
        }
    }
}

extension View {
    /// An item's tags as VoiceOver's custom content ("Tags: Red, Work") on the
    /// element for the whole item (an icon, a column row), which it offers
    /// without interacting into it; nothing without tags. One modifier either
    /// way (a nil value adds none): a branch would make the item a new view
    /// when it gains its first tag, and its column scroll.
    func accessibilityTags(_ names: [String]) -> some View {
        accessibilityCustomContent(AccessibilityCustomContentKey(Text("Tags"), id: "tags"),
                                   names.isEmpty ? nil : Text(FileTagAccessibility.value(names)))
    }
}

private extension View {
    /// The element VoiceOver reads as the tags; none without names.
    func tagsElement(_ names: [String]) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel("Tags")
            .accessibilityValue(FileTagAccessibility.value(names))
            .accessibilityAddTraits(.isStaticText)
            .accessibilityHidden(names.isEmpty)
    }
}

// MARK: - Tags submenu (shared by list / grouped / icons / columns)
//
// Renders the 7 Finder colors as toggles (a checkmark shows when EVERY targeted
// item already carries that color) plus a "Clear Tags" action. Toggling adds the
// color when absent and removes it when present — exactly like Finder, and with
// multiple colors per file preserved.
//
// A link the listing didn't follow (FileItem.isLinkNotFollowed) is left out:
// it shows its own tags, but tags are written to where a link leads, which
// would mount it. As a file whose tags can't be read is left alone
// (FileOpsTags), the rest of a selection is still tagged, and the message
// says how many links were skipped; with only such links, the menu is
// disabled (FileItem.tagTargets).

struct TagMenuContent: View {
    let targets: [FileItem]
    @ObservedObject var fileOps: FileOperationsService
    let onReload: () -> Void
    var isReadOnlyLocation = false

    private func applied(_ color: Int, in items: [FileItem], names: TagColorNames) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.hasColorTag(color, names: names) }
    }

    private var hasReadOnlyTarget: Bool { isReadOnlyLocation || targets.contains { TimeMachineBackups.isSnapshotPath($0.url) } }

    var body: some View {
        // The colours under the user's names for them (Finder lets them be renamed).
        let names = TagColorNames.current
        let (items, skipped) = FileItem.tagTargets(targets)
        let urls = items.map(\.url)
        ForEach(FileItem.colorMenuNumbers, id: \.self) { color in
            Toggle(names.name(for: color), isOn: Binding(
                get: { applied(color, in: items, names: names) },
                set: { _ in
                    fileOps.toggleColorTag(color, names: names, on: urls, skippedLinks: skipped, reload: onReload)
                }
            ))
            .disabled(items.isEmpty || hasReadOnlyTarget)
        }
        Divider()
        Button("Clear Tags") { fileOps.clearTags(on: urls, skippedLinks: skipped, reload: onReload) }
            .disabled(hasReadOnlyTarget || items.allSatisfy { $0.tags.isEmpty && $0.labelNumber == 0 })
    }
}

extension TagColorNames {
    /// The user's names for Finder's colour tags. `NSWorkspace.fileLabels`
    /// follows renames made in Finder → Settings → Tags and the system language.
    static var current: TagColorNames { TagColorNames(fileLabels: NSWorkspace.shared.fileLabels) }
}
