import Foundation

/// A mounted volume, for the sidebar's Locations section. The app reads these
/// from the volume's resource values and DiskArbitration; they're plain values
/// here so the decisions below can be tested anywhere.
struct SidebarVolume: Hashable, Sendable {
    let url: URL
    /// The name Finder shows (`.volumeLocalizedNameKey`).
    let name: String
    /// The startup disk.
    var isRoot = false
    var isInternal = false
    var isEjectable = false
    var isRemovable = false
    /// False for a server's share.
    var isLocal = true
    var isBrowsable = true
    /// A mounted disk image. No resource value says so; DiskArbitration's
    /// device model does ("Disk Image").
    var isDiskImage = false
    /// A CD, DVD or Blu-ray disc.
    var isOpticalDisc = false
    /// The BSD name of the whole disk the volume is on ("disk4"), from
    /// DiskArbitration; nil for a server's share.
    var wholeDisk: String?
    /// A server's share: the address it was mounted from (its remount URL,
    /// without a password), which saved servers are matched with. nil for a disk.
    var server: ServerAddress?

    /// Where the volume goes in Locations, in the sidebar's order.
    enum Kind: Int, CaseIterable, Comparable, Sendable {
        case startupDisk, internalDisk, externalDisk, discOrDiskImage, network

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        /// The Settings → Sidebar toggle that shows or hides it.
        var group: Group {
            switch self {
            case .startupDisk, .internalDisk: return .hardDisks
            case .externalDisk:               return .externalDisks
            case .discOrDiskImage:            return .discsAndImages
            case .network:                    return .networkVolumes
            }
        }
    }

    /// Finder's "Show in sidebar" groups under Locations (Settings → Sidebar).
    enum Group: String, CaseIterable, Sendable {
        case hardDisks, externalDisks, discsAndImages, networkVolumes

        var title: String {
            switch self {
            case .hardDisks:      return NSLocalizedString("Hard disks", comment: "Sidebar Locations setting group")
            case .externalDisks:  return NSLocalizedString("External disks", comment: "Sidebar Locations setting group")
            case .discsAndImages: return NSLocalizedString("CDs, DVDs and disk images", comment: "Sidebar Locations setting group")
            case .networkVolumes: return NSLocalizedString("Network volumes", comment: "Sidebar Locations setting group")
            }
        }

        var key: String {
            switch self {
            case .hardDisks:      return SidebarPrefs.showHardDisksKey
            case .externalDisks:  return SidebarPrefs.showExternalDisksKey
            case .discsAndImages: return SidebarPrefs.showDiscsAndImagesKey
            case .networkVolumes: return SidebarPrefs.showNetworkVolumesKey
            }
        }

        /// Every group shows until turned off. Finder starts with Hard disks
        /// off, but Selway's sidebar has no other way to the startup disk.
        var defaultShown: Bool { true }
    }

    /// A USB stick or an SD card reports itself removable (an SD card in the
    /// Mac's own reader, internal too) but is an external disk to Finder; only
    /// discs and disk images are in their own group.
    var kind: Kind {
        if isRoot { return .startupDisk }
        if !isLocal { return .network }
        if isDiskImage || isOpticalDisc { return .discOrDiskImage }
        if isInternal && !isEjectable && !isRemovable { return .internalDisk }
        return .externalDisk
    }

    /// Whether the row has an eject button, and Eject works on it: everything
    /// but the startup disk and internal disks. External drives often report
    /// neither ejectable nor removable, and Finder ejects them all the same.
    var canEject: Bool { kind != .startupDisk && kind != .internalDisk }

    /// What an eject is tracked by. Ejecting one volume ejects every volume on
    /// its disk, so they share one; a server's share has no disk, so its path.
    var ejectKey: String { wholeDisk.map { "disk:" + $0 } ?? "path:" + ShellPath.key(url) }

    /// The row's kind for VoiceOver, read after its name.
    var kindDescription: String {
        switch kind {
        case .startupDisk:     return NSLocalizedString("Startup disk", comment: "VoiceOver description of a sidebar volume")
        case .internalDisk:    return NSLocalizedString("Internal disk", comment: "VoiceOver description of a sidebar volume")
        case .externalDisk:    return NSLocalizedString("External disk", comment: "VoiceOver description of a sidebar volume")
        case .discOrDiskImage:
            return isDiskImage
                ? NSLocalizedString("Disk image", comment: "VoiceOver description of a mounted disk image")
                : NSLocalizedString("Disc", comment: "VoiceOver description of a mounted optical disc")
        case .network:         return NSLocalizedString("Server", comment: "VoiceOver description of a mounted network volume")
        }
    }
}

/// The Locations section's decisions: which volumes it lists, in what order,
/// and what ejecting one does to the windows showing it.
enum SidebarVolumes {
    /// The rows: browsable volumes in a group that's shown, the startup disk
    /// first, then internal, external, discs and disk images, then servers;
    /// by name within each.
    static func rows(_ volumes: [SidebarVolume], showing groups: Set<SidebarVolume.Group>) -> [SidebarVolume] {
        sorted(volumes.filter { $0.isBrowsable && groups.contains($0.kind.group) })
    }

    static func sorted(_ volumes: [SidebarVolume]) -> [SidebarVolume] {
        volumes.sorted { a, b in
            if a.kind != b.kind { return a.kind < b.kind }
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending:  return true
            case .orderedDescending: return false
            // Two volumes of one name ("Untitled") keep a fixed order.
            case .orderedSame:       return ShellPath.key(a.url) < ShellPath.key(b.url)
            }
        }
    }

    /// Where a window showing `folder` goes once `volume` has gone (ejected
    /// here or in Finder, or pulled out), or nil when the folder wasn't on it.
    /// Home, unless home was on the volume too; then the startup disk.
    ///
    /// A folder reached through a link counts where the link goes: ~/Downloads
    /// linked to a drive was on the drive. Links are read with `readLink`
    /// (ShellPath.followingLinks), never inside `servers`, the mount points of
    /// the servers still connected: one that has stopped answering would hold
    /// the main thread up.
    static func folder(afterUnmounting volume: URL, showing folder: URL, home: URL,
                       servers: [URL], readLink: (String) -> String?) -> URL? {
        // "/" holds every path, and the startup disk can't be ejected anyway.
        guard ShellPath.key(volume) != "/" else { return nil }
        func isOnVolume(_ url: URL) -> Bool {
            if ShellPath.isSameOrInside(url, volume) { return true }
            let resolved = ShellPath.followingLinks(url, readLink: readLink) {
                !mayFollowLinks(at: $0, servers: servers)
            }
            return ShellPath.isSameOrInside(resolved, volume)
        }
        guard isOnVolume(folder) else { return nil }
        return isOnVolume(home) ? URL(fileURLWithPath: "/", isDirectory: true) : home
    }

    /// Where a window's panes (`panes`, each showing `folder(pane)`) go once
    /// `volume` has gone: each pane on the volume, with where it goes, in
    /// order. Every pane on the volume leaves it, whichever is active, and a
    /// pane elsewhere stays where it is (`folder(afterUnmounting:showing:...)`).
    static func moves<Pane>(afterUnmounting volume: URL, panes: [Pane], folder: (Pane) -> URL?, home: URL,
                            servers: [URL], readLink: (String) -> String?) -> [(pane: Pane, to: URL)] {
        panes.compactMap { pane in
            guard let folder = folder(pane) else { return nil }
            return self.folder(afterUnmounting: volume, showing: folder, home: home, servers: servers,
                               readLink: readLink).map { (pane, $0) }
        }
    }

    /// Where a pane goes when `folder`, the one it shows, is gone (deleted or
    /// renamed, or its disk ejected while the pane was hidden), or nil while
    /// `folder` exists: the nearest folder above it that's still there, unless
    /// that's only /Volumes, its disk gone; then home, as after an eject
    /// (`folder(afterUnmounting:...)`), or the startup disk without one.
    static func folder(replacingGone folder: URL, home: URL, exists: (String) -> Bool) -> URL? {
        guard !exists(ShellPath.key(folder)),
              let nearest = ShellPath.nearestExistingAncestor(of: folder, exists: exists)
        else { return nil }
        guard ShellPath.key(nearest) == "/Volumes" else { return nearest }
        return exists(ShellPath.key(home)) ? home : URL(fileURLWithPath: "/", isDirectory: true)
    }

    /// False for a path on a connected server (`servers`, their mount points):
    /// its links aren't read, in case the server has stopped answering.
    static func mayFollowLinks(at path: URL, servers: [URL]) -> Bool {
        !servers.contains { ShellPath.isSameOrInside(path, $0) }
    }

    /// The alert when a volume doesn't eject.
    struct EjectFailure: Equatable, Sendable {
        let title: String
        let detail: String
    }

    /// The busy case follows Finder's wording and names visible processes when possible.
    static func ejectFailure(name: String, isBusy: Bool, reason: String?, using processNames: [String] = []) -> EjectFailure {
        if isBusy {
            let names = busyProcessNames(processNames)
            let title: String
            switch names.count {
            case 0:
                let format = NSLocalizedString("“%@” wasn’t ejected because one or more programs may be using it.", comment: "Busy volume eject alert when the app using it is unknown")
                title = String.localizedStringWithFormat(format, name)
            case 1:
                let format = NSLocalizedString("“%1$@” wasn’t ejected because “%2$@” is using it.", comment: "Busy volume eject alert naming one app")
                title = String.localizedStringWithFormat(format, name, names[0])
            case 2:
                let format = NSLocalizedString("“%1$@” wasn’t ejected because “%2$@” and “%3$@” are using it.", comment: "Busy volume eject alert naming two apps")
                title = String.localizedStringWithFormat(format, name, names[0], names[1])
            default:
                let format = NSLocalizedString("“%1$@” wasn’t ejected because “%2$@”, “%3$@” and other apps are using it.", comment: "Busy volume eject alert naming the first two of several apps")
                title = String.localizedStringWithFormat(format, name, names[0], names[1])
            }
            let detail = NSLocalizedString("Quit any app that may be using a file on it, then try again.", comment: "Busy volume eject alert guidance")
            return EjectFailure(title: title, detail: detail)
        }
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let titleFormat = NSLocalizedString("“%@” couldn’t be ejected.", comment: "Volume eject failure alert")
        let detail = reason.isEmpty
            ? NSLocalizedString("Try again in a moment.", comment: "Volume eject failure guidance") : reason
        return EjectFailure(title: String.localizedStringWithFormat(titleFormat, name), detail: detail)
    }

    /// De-duplicate and order the names of the apps holding a volume.
    static func busyProcessNames(_ names: [String]) -> [String] {
        let unique = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        return unique.sorted {
            switch $0.localizedStandardCompare($1) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return $0 < $1
            }
        }
    }

    /// A process with a file open on a volume being ejected.
    struct BusyProcess: Equatable, Sendable {
        let name: String
        /// An app with a Dock icon or a menu bar item, one the user can quit.
        let isApp: Bool
        /// Selway itself.
        let isSelf: Bool
    }

    /// The apps the busy alert names. Daemons and command-line tools aren't
    /// named (Finder doesn't either): with only those, the alert says programs
    /// may be using the volume. Selway is named only when nothing else holds it.
    static func busyAppNames(_ processes: [BusyProcess]) -> [String] {
        let others = processes.filter { !$0.isSelf }
        if others.isEmpty, let selway = processes.first {
            return [selway.name]
        }
        return busyProcessNames(others.filter(\.isApp).map(\.name))
    }

    /// A registry entry, reduced to the properties needed to identify a physical whole disk.
    struct RegistryEntry: Equatable, Sendable {
        let className: String
        let isWhole: Bool
        let bsdName: String?
    }

    /// Resolves a synthesized APFS container through its scheme to the physical whole disk.
    static func physicalWholeDisk(container: String, chain: [RegistryEntry], isComposited: Bool) -> String {
        guard !isComposited,
              let schemeIndex = chain.firstIndex(where: { $0.className == "AppleAPFSContainerScheme" })
        else { return container }
        for entry in chain.dropFirst(schemeIndex + 1) where entry.className == "IOMedia" && entry.isWhole {
            if let bsdName = entry.bsdName { return bsdName }
        }
        return container
    }

    /// Removes preview items on an ejected volume, and says where the one
    /// shown (`current`, an index into `urls`) is now, or that Quick Look
    /// should close because it was removed or nothing is left.
    static func quickLookItems(afterUnmounting volume: URL, urls: [URL], current: Int?)
        -> (urls: [URL], current: Int?, shouldClose: Bool) {
        let kept = urls.indices.filter { !ShellPath.isSameOrInside(urls[$0], volume) }
        let remaining = kept.map { urls[$0] }
        let newCurrent = current.flatMap { kept.firstIndex(of: $0) }
        let currentWasRemoved = current.map { urls.indices.contains($0) && newCurrent == nil } ?? false
        return (remaining, newCurrent, currentWasRemoved || remaining.isEmpty)
    }

    /// True for the errors a volume in use gives: fBsyErr (-47) from
    /// NSWorkspace, or EBUSY.
    static func isBusy(errorDomain domain: String, code: Int) -> Bool {
        (domain == "NSOSStatusErrorDomain" && code == -47) || (domain == "NSPOSIXErrorDomain" && code == 16)
    }
}
