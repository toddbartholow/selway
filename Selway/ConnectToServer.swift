import SwiftUI
import AppKit
import NetFS
import Network

// Go → Connect to Server… (⌘K), saved servers' rows, and Reconnect at Launch.
// What's typed is checked and normalised by ServerAddress (Core); here it's
// mounted with NetFS. Selway never sees a password: NetFS's own login prompt
// (NetAuthAgent) uses the keychain or asks, and an address's password is
// dropped while parsing it.
//
// Nothing outside the app can start a mount: `selway://` links and the Finder
// extension have no action for it (FileOpsURLAction; ServerLinkSafetyTests).

// MARK: - Mounting

/// One NetFS mount: started off the main thread, its result delivered on the
/// main thread, and cancellable until then. The orderings (a cancel racing
/// the result) are MountRequest's (Core, tested); this plugs NetFS into it.
@MainActor
final class ServerMount {
    /// NetFS's request handle, an opaque pointer only passed back to NetFS.
    private struct RequestID: @unchecked Sendable { let raw: AsyncRequestID }

    /// NetFS calls back on it, and the calls into NetFS are made on it, never
    /// on the main thread.
    nonisolated private static let queue = DispatchQueue(label: "studio.irq.selway.mount", qos: .userInitiated)

    let address: ServerAddress
    private let request: MountRequest<RequestID>

    private init(address: ServerAddress, request: MountRequest<RequestID>) {
        self.address = address
        self.request = request
    }

    /// Mounts `address` (a share, or a server, when macOS asks which shares)
    /// under /Volumes. `allowUI`: the system's login prompt and share picker
    /// may appear (Connect to Server, a saved server's row); without it, a
    /// mount that needs them fails (Reconnect at Launch, which mustn't ask or
    /// take the focus). `completion` runs once, on the main thread.
    @discardableResult
    static func start(_ address: ServerAddress, allowUI: Bool,
                      completion: @escaping (MountOutcome) -> Void) -> ServerMount {
        let request = MountRequest<RequestID>(
            queue: queue, deliverOn: .main,
            // Only for a request NetFS hasn't reported yet (MountRequest).
            cancel: { _ = NetFSMountURLCancel($0.raw) },
            completion: { outcome in MainActor.assumeIsolated { completion(outcome) } })
        #if SELWAY_UI_TESTING
        // The UI tests never mount anything: the result they asked for, after a moment.
        if UITestHooks.isActive {
            let status = UITestHooks.mountStatus
            request.start { queue, report in
                queue.asyncAfter(deadline: .now() + 0.5) { report(status, []) }
                return (0, nil)
            }
            return ServerMount(address: address, request: request)
        }
        #endif
        let url = address.url
        request.start { queue, report in
            let openOptions = NSMutableDictionary()
            openOptions[kNAUIOptionKey] = allowUI ? kNAUIOptionAllowUI : kNAUIOptionNoUI
            // Under /Volumes, where macOS mounts shares itself; soft mounts
            // (NetFS's default), so a server that stops answering times out.
            let mountOptions = NSMutableDictionary()
            var id: AsyncRequestID?
            let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, openOptions, mountOptions, &id, queue) {
                status, _, mountpoints in
                report(status, (mountpoints as NSArray?)?.compactMap { $0 as? String } ?? [])
            }
            return (status, id.map(RequestID.init))
        }
        return ServerMount(address: address, request: request)
    }

    /// Stops the mount if NetFS hasn't finished it (the login prompt goes with
    /// it) and reports `.cancelled`. A mount NetFS had already finished stays
    /// mounted: it's listed under Locations, and the window doesn't go there.
    func cancel() {
        request.cancel()
    }
}

// MARK: - Reconnect at Launch

enum ServerReconnect {
    // The servers waiting for the network (ServerReconnectPolicy) and what
    // watches for it.
    @MainActor private static var policy = ServerReconnectPolicy()
    @MainActor private static var pathMonitor: NWPathMonitor?
    /// Whether the monitor has said yet what the network is like now.
    @MainActor private static var pathKnown = false
    @MainActor private static var pathSatisfied = false
    @MainActor private static var retryCheckInProgress = false
    @MainActor private static var giveUpTimer: DispatchWorkItem?
    @MainActor private static var retryDelay: DispatchWorkItem?
    @MainActor private static var launchDeadline = Date.distantFuture

    /// Mounts the saved servers with Reconnect at Launch on, once, in the
    /// background: no login prompt, no window, no alert, and the focus stays
    /// where it is. One that fails (it needs a password the keychain doesn't
    /// have, the server is away) gets a log line naming the server without
    /// its user, and nothing else.
    @MainActor
    static func atLaunch() {
        policy = ServerReconnectPolicy()
        launchDeadline = Date().addingTimeInterval(ServerReconnectPolicy.lifetime)
        let servers = SavedServersStore().load()
        guard servers.contains(where: \.reconnectAtLaunch) else { return }
        // Off the main thread, though reading the mount table asks no volume.
        DispatchQueue.global(qos: .utility).async {
            let addresses = SavedServers.toReconnect(servers, mounted: mountedServers())
            guard !addresses.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for address in addresses { reconnect(address) }
                }
            }
        }
    }

    @MainActor
    private static func reconnect(_ address: ServerAddress, isRetry: Bool = false) {
        ServerMount.start(address, allowUI: false) { outcome in
            // A retry for a server given up meanwhile (the time ran out, or
            // Reconnect at Launch was turned off): it was logged, or isn't
            // wanted, and mustn't start waiting again.
            if isRetry, !policy.isWaiting(address) { return }
            switch outcome {
            case .mounted:
                policy.mounted(address)
                stopWatchingIfDone()
            case .failed(let failure, let status, _):
                guard failure != .alreadyMounted, failure != .cancelled else {
                    policy.mounted(address)
                    stopWatchingIfDone()
                    return
                }
                let gaveUp = policy.failed(address, failure: failure, status: status)
                if gaveUp || !ServerReconnectPolicy.waitsForNetwork(failure, status: status) {
                    NSLog("Selway: couldn’t reconnect %1$@ at launch (error %2$d).", address.logDescription, status)
                } else {
                    startWatching()
                    // With the network up already, no change of it will come
                    // to try this one again.
                    scheduleRetryIfAvailable()
                }
                stopWatchingIfDone()
            }
        }
    }

    @MainActor
    private static func startWatching() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        let queue = DispatchQueue(label: "studio.irq.selway.reconnect-path", qos: .utility)
        monitor.pathUpdateHandler = { [weak monitor] path in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // An update queued before this monitor was cancelled.
                    guard let monitor, pathMonitor === monitor else { return }
                    let wasKnown = pathKnown
                    let becameSatisfied = path.status == .satisfied && !pathSatisfied
                    pathKnown = true
                    pathSatisfied = path.status == .satisfied
                    if !wasKnown {
                        // How it is now, not a change: the network was up
                        // already, so the usual pause before trying again.
                        scheduleRetryIfAvailable()
                    } else if becameSatisfied {
                        attemptPendingRetries()
                    }
                }
            }
        }
        monitor.start(queue: queue)
        let timeout = DispatchWorkItem {
            MainActor.assumeIsolated {
                let waiting = policy.expire()
                for item in waiting {
                    NSLog("Selway: couldn’t reconnect %1$@ at launch (error %2$d).", item.address.logDescription, item.status)
                }
                stopWatchingIfDone()
            }
        }
        giveUpTimer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, launchDeadline.timeIntervalSinceNow), execute: timeout)
    }

    @MainActor
    private static func attemptPendingRetries() {
        guard pathSatisfied, !retryCheckInProgress, !policy.waiting.isEmpty else { return }
        retryCheckInProgress = true
        DispatchQueue.global(qos: .utility).async {
            let mounted = mountedServers()
            let enabled = SavedServers.toReconnect(SavedServersStore().load(), mounted: mounted)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    retryCheckInProgress = false
                    let enabledKeys = Set(enabled.map(\.matchKey))
                    policy.keepWaiting(enabled)
                    let retry = policy.ready(mounted: mounted).filter { enabledKeys.contains($0.matchKey) }
                    for address in retry {
                        policy.beganRetry(address)
                        NSLog("Selway: retrying %1$@ at launch after network became available.", address.logDescription)
                        reconnect(address, isRetry: true)
                    }
                    stopWatchingIfDone()
                }
            }
        }
    }

    @MainActor
    private static func stopWatchingIfDone() {
        guard policy.waiting.isEmpty else { return }
        pathMonitor?.cancel()
        pathMonitor = nil
        pathKnown = false
        pathSatisfied = false
        giveUpTimer?.cancel()
        giveUpTimer = nil
        retryDelay?.cancel()
        retryDelay = nil
    }

    @MainActor
    private static func scheduleRetryIfAvailable() {
        guard pathSatisfied, retryDelay == nil else { return }
        let retry = DispatchWorkItem {
            MainActor.assumeIsolated {
                retryDelay = nil
                attemptPendingRetries()
            }
        }
        retryDelay = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + ServerReconnectPolicy.retryPause, execute: retry)
    }

    /// The servers' shares mounted now, from the mount table's mounted-from
    /// names, so no volume is asked.
    private static func mountedServers() -> [ServerAddress] {
        MountTableEntry.shown(MountTableEntry.current()).compactMap(\.server)
    }
}

// MARK: - The sheet

/// Opens Connect to Server on a browser window.
struct ConnectSheetRequest: Identifiable {
    let id = UUID()
    /// A saved server to connect to straight away (its sidebar row was
    /// chosen); nil for Go → Connect to Server….
    var saved: SavedServer?
    /// A server under Network to look up straight away (its row was chosen,
    /// or Save Server in Sidebar in its menu), and what for.
    var network: NetworkServer?
    var networkPurpose = NetworkPurpose.connect

    enum NetworkPurpose {
        /// Connect: at once to a server connected to or saved before
        /// (NetworkServers.isKnown), otherwise once the user has seen the
        /// address and clicked Connect.
        case connect
        /// Show the address, to save with "+".
        case save
    }
}

/// Go → Connect to Server…: an address field, Recent Servers, and progress
/// while connecting (Cancel stops it). A saved server's row opens it already
/// connecting. A server under Network opens it looking the server up first
/// (NetworkNeighborhood.resolve): the field then shows the address it
/// resolved to, which is what's mounted, whatever the server called itself.
/// Unless the user has connected to that server or saved it before, the sheet
/// stops there, for them to check the address and click Connect (or "+").
/// Problems are shown, and spoken, under the field rather than in an alert:
/// for some failures macOS's own login agent has already shown one.
struct ConnectToServerSheet: View {
    let request: ConnectSheetRequest
    /// Shows a folder in the window the sheet is on.
    let navigate: (URL) -> Void

    @EnvironmentObject private var favorites: FavoritesService
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var recents: [ServerAddress] = []
    @State private var selectedRecent: ServerAddress?
    /// What went wrong, under the field.
    @State private var problem: String?
    /// "Added to the sidebar", and the like.
    @State private var notice: String?
    /// The server being connected to.
    @State private var connecting: ServerAddress?
    @State private var mount: ServerMount?
    /// The server under Network being looked up, before connecting to it.
    @State private var finding: NetworkServer?
    @State private var resolution: NetworkResolution?
    /// A server under Network found, and the address in the field it was
    /// found at: "+" names it as the row did, and filling the field with it
    /// doesn't clear the note about it.
    @State private var found: (server: NetworkServer, address: String)?
    /// This connection attempt: Cancel clears it, so a step still under way
    /// (the mount's result, the last look for the folder) does nothing after.
    @State private var attempt: UUID?
    @FocusState private var fieldFocused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Looking a server up or connecting: the field and lists wait.
    private var busy: Bool { connecting != nil || finding != nil }

    /// Notes about what's typed: a password that won't be used, FTP's read-only mounts.
    private var hints: [String] {
        guard case .success(let parsed) = ServerAddress.parse(text) else { return [] }
        var hints: [String] = []
        if parsed.droppedPassword {
            hints.append(String(localized: "The password in the address isn’t used or kept. macOS asks for it, and can keep it in your keychain.", comment: "Hint explaining that passwords in server addresses are ignored"))
        }
        if parsed.address.scheme.isReadOnly {
            hints.append(String(localized: "FTP servers connect read-only: you can open and copy files, not change them.", comment: "Hint explaining read-only FTP access"))
        }
        if parsed.address.scheme == .http || parsed.address.scheme == .ftp {
            hints.append(parsed.address.scheme == .http
                         ? String(localized: "http:// sends your password and files unencrypted. Use https:// if the server has it.", comment: "Security hint for HTTP server connections")
                         : String(localized: "ftp:// sends your password and files unencrypted.", comment: "Security hint for FTP server connections"))
        }
        return hints
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect to Server")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text("Server Address:")
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                TextField("Server address", text: $text, prompt: Text("smb://server/share"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .focused($fieldFocused)
                    .disabled(busy)
                    .accessibilityLabel("Server address")
                    .accessibilityIdentifier("serverAddress")
                    .onChange(of: text) { _, newText in
                        // Not for the address a lookup has just put there.
                        guard newText != found?.address else { return }
                        problem = nil
                        notice = nil
                    }
                Button(action: addToSidebar) {
                    Image(systemName: "plus")
                }
                .disabled(busy || trimmed.isEmpty)
                .help("Add to Sidebar: list this server under Locations, to connect with a click")
                .accessibilityLabel("Add to Sidebar")
            }

            if let problem {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(problem)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("connectProblem")
                }
            } else if let notice {
                Text(notice)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("connectNotice")
            }
            ForEach(hints, id: \.self) { hint in
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Recent Servers:")
                .accessibilityHidden(true)
            recentList

            HStack(spacing: 8) {
                if let connecting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Connecting to “\(connecting.hostForDisplay)”…")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("connectProgress")
                } else if let finding {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(String(localized: "Looking for “\(finding.displayName)” on the network…", comment: "Progress message while finding a server on the network"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("connectProgress")
                }
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .help(busy ? "Stop connecting" : "Close without connecting")
                Button("Connect", action: connectTyped)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            recents = RecentServers.load(from: .standard)
            if let saved = request.saved {
                text = saved.fullAddress.displayString
                connect(to: saved.address, folder: saved.folder, recording: saved.fullAddress)
            } else if let server = request.network {
                find(server, purpose: request.networkPurpose)
            } else {
                fieldFocused = true
            }
        }
        // The window closing, or the sheet going any other way, stops a
        // lookup or a mount.
        .onDisappear {
            attempt = nil
            resolution?.cancel()
            mount?.cancel()
        }
    }

    /// Click to fill the field, double-click (or Return) to connect.
    private var recentList: some View {
        List(recents, id: \.self, selection: $selectedRecent) { address in
            Text(address.displayAddress)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(address.displayAddress)
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(height: 130)
        .overlay {
            if recents.isEmpty {
                Text("No recent servers")
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: ServerAddress.self) { items in
            if items.isEmpty {
                Button("Clear Recent Servers") { setRecents([]) }
                    .disabled(recents.isEmpty)
            } else {
                Button("Remove from Recent Servers") {
                    setRecents(recents.filter { address in !items.contains { $0.matchKey == address.matchKey } })
                }
            }
        } primaryAction: { items in
            guard let address = items.first, !busy else { return }
            text = address.displayString
            connect(to: address.mountTarget, folder: address.folderInShare, recording: address)
        }
        .onChange(of: selectedRecent) { _, address in
            if let address, !busy { text = address.displayString }
        }
        .disabled(busy)
        .accessibilityLabel("Recent servers")
        .accessibilityIdentifier("recentServers")
    }

    // MARK: Actions

    private func connectTyped() {
        guard !busy else { return }
        // A saved server's address, unchanged: its own share and folder (an
        // NFS export's folder isn't in the export's path).
        if let saved = request.saved, trimmed == saved.fullAddress.displayString {
            connect(to: saved.address, folder: saved.folder, recording: saved.fullAddress)
            return
        }
        switch ServerAddress.parse(text) {
        case .failure(let error):
            show(problem: error.message)
        case .success(let parsed):
            let address = parsed.address
            connect(to: address.mountTarget, folder: address.folderInShare, recording: address)
        }
    }

    private func addToSidebar() {
        switch ServerAddress.parse(text) {
        case .failure(let error):
            show(problem: error.message)
        case .success(let parsed):
            // A server found under Network is named as its row, made safe, but
            // without the row's numbering or quotes, which only meant something there.
            let name = found.flatMap { $0.address == parsed.address.displayString ? $0.server.name : nil }
            let server = SavedServer.make(typed: parsed.address, name: name)
            let message = favorites.addServer(server)
                ? String(localized: "“\(server.sidebarDisplayName)” is in the sidebar under Locations.", comment: "Notice after adding a server to the sidebar")
                : String(localized: "“\(server.sidebarDisplayName)” is in the sidebar already.", comment: "Notice when a server is already in the sidebar")
            problem = nil
            notice = message
            announce(message)
        }
    }

    /// While looking a server up or connecting, stops it (the sheet stays);
    /// otherwise closes the sheet.
    private func cancel() {
        guard busy else {
            dismiss()
            return
        }
        attempt = nil
        let lookingFor = finding
        resolution?.cancel()
        resolution = nil
        finding = nil
        mount?.cancel()
        mount = nil
        connecting = nil
        announce(lookingFor.map { String(localized: "Stopped looking for “\($0.displayName)”", comment: "VoiceOver announcement after stopping a server lookup") }
                 ?? String(localized: "Stopped connecting", comment: "VoiceOver announcement after stopping a server connection"))
        if lookingFor != nil { fieldFocused = true }
    }

    /// A server under Network: looked up now (where it is, by its name, type
    /// and domain), and the address it resolved to put in the field. Nothing
    /// of its name goes into the address. To connect, a server connected to or
    /// saved before connects at once; any other waits for Connect, so the user
    /// sees where it really is first. To save, it waits for "+".
    private func find(_ server: NetworkServer, purpose: ConnectSheetRequest.NetworkPurpose) {
        guard !busy else { return }
        problem = nil
        notice = nil
        found = nil
        finding = server
        let token = UUID()
        attempt = token
        announce(String(localized: "Looking for \(server.displayName)", comment: "VoiceOver announcement while looking for a network server"))
        resolution = NetworkNeighborhood.shared.resolve(server) { result in
            guard attempt == token else { return }
            resolution = nil
            finding = nil
            switch result {
            case .success(let address):
                let shown = address.displayString
                found = (server, shown)
                text = shown
                let known = NetworkServers.isKnown(address, recents: RecentServers.load(from: .standard),
                                                   saved: favorites.savedServers)
                if purpose == .connect && known {
                    connect(to: address, folder: "", recording: address)
                    return
                }
                attempt = nil
                let next = purpose == .save
                    ? String(localized: "Click + to add it to the sidebar.", comment: "Instruction after finding a server to save")
                    : String(localized: "Check it, then click Connect.", comment: "Instruction after finding a server to connect")
                notice = String(localized: "Found “\(server.displayName)” at this address. \(next)", comment: "Notice after resolving a network server")
                fieldFocused = true
                announce(String(localized: "Found “\(server.displayName)” at \(shown)", comment: "VoiceOver announcement after finding a network server address"))
            case .failure(let failure):
                attempt = nil
                show(problem: failure.message(serverName: server.displayName))
                fieldFocused = true
            }
        }
    }

    /// Mounts `target` and shows `folder` on it; `recording` goes in Recent Servers.
    private func connect(to target: ServerAddress, folder: String, recording: ServerAddress) {
        guard mount == nil else { return }
        problem = nil
        notice = nil
        connecting = target
        let token = UUID()
        attempt = token
        announce(String(localized: "Connecting to \(target.hostForDisplay)", comment: "VoiceOver announcement while connecting to a server"))
        mount = ServerMount.start(target, allowUI: true) { outcome in
            guard attempt == token else { return }
            mount = nil
            switch outcome {
            case .mounted(let points):
                if let point = points.first.map(Self.folderURL) ?? favorites.mountPoint(for: target) {
                    opened(point, folder: folder, recording: recording, token: token)
                } else {
                    connecting = nil
                    show(problem: String(localized: "Connected, but Selway couldn’t tell where it was mounted. Look for it under Locations.", comment: "Connection error when the mounted volume location cannot be determined"))
                }
            case .failed(.alreadyMounted, _, let points):
                // Connected already: open it where it is, as NetFS says, else
                // as the last read of the volumes does.
                if let point = points.first.map(Self.folderURL) ?? favorites.mountPoint(for: target) {
                    opened(point, folder: folder, recording: recording, token: token)
                } else {
                    connecting = nil
                    show(problem: String(localized: "“\(target.shareName ?? target.hostForDisplay)” is connected already. Look for it under Locations.", comment: "Connection error when a server is mounted but its volume location cannot be determined"))
                }
            case .failed(.cancelled, _, _):
                connecting = nil
            case .failed(let failure, _, _):
                connecting = nil
                if let message = failure.message(for: target) {
                    show(problem: message.title + " " + message.detail)
                }
            }
        }
    }

    /// Connected: remembered in Recent Servers, and the window goes to the
    /// folder (the share itself if the folder isn't there).
    /// Cancel meanwhile (`token` no longer the attempt) leaves the window where it is.
    private func opened(_ mountPoint: URL, folder: String, recording: ServerAddress, token: UUID) {
        setRecents(RecentServers.adding(recording, to: RecentServers.load(from: .standard)))
        let destination = SidebarServers.folderURL(folder, on: mountPoint)
        let name = recording.shareName ?? recording.hostForDisplay
        // Looked for off the main thread: it's on the server.
        DispatchQueue.global(qos: .userInitiated).async {
            let found = folder.isEmpty || FileItem.isBrowsableFolder(destination)
            DispatchQueue.main.async {
                guard attempt == token else { return }
                attempt = nil
                connecting = nil
                navigate(found ? destination : mountPoint)
                dismiss()
                announce(String(localized: "Connected to \(name)", comment: "VoiceOver announcement after connecting to a server"))
            }
        }
    }

    private static func folderURL(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    private func setRecents(_ list: [ServerAddress]) {
        RecentServers.save(list, to: .standard)
        recents = RecentServers.load(from: .standard)
    }

    private func show(problem message: String) {
        problem = message
        announce(message)
    }

    /// VoiceOver hears it: errors and progress appear without focus moving.
    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
