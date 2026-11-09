import AppKit
import Network
import dnssd
import SystemConfiguration

// The sidebar's Network row (under Locations): file servers advertised over
// Bonjour, found with NWBrowser while the row is open, and resolved with
// dns_sd when one is clicked. What's decided about what they find (one row
// per server, this Mac left out, names made safe to show, the address to
// connect to) is NetworkServers (Core).
//
// **Local Network privacy.** Looking for services on the network is what
// makes macOS ask whether Selway may find devices on the local network (the
// first time, for each build identity), and what that setting (System
// Settings › Privacy & Security › Local Network) allows or blocks. So nothing
// here runs until the user opens the Network row: not at launch, not for a
// window opening. The row starts closed every launch (SidebarView), because
// an open one would search at once.

// MARK: - Searching

/// What a search has found so far, and how it's going.
struct NetworkBrowseUpdate: Equatable {
    var state: NetworkBrowseState
    var services: [NetworkService]
}

/// Looks for file servers on the network: Bonjour in the app, a stand-in
/// under the UI tests.
@MainActor
protocol NetworkServiceBrowsing: AnyObject {
    /// Starts looking. `update` runs on the main thread with everything found
    /// so far, each time that or the state changes, until `stop`.
    func start(_ update: @escaping @MainActor (NetworkBrowseUpdate) -> Void)
    func stop()
}

/// An NWBrowser for SMB servers, on the main queue. One that fails is
/// started again after a while (NetworkRetry: a few seconds at first, then
/// up to every 30), its servers cleared meanwhile. A waiting one (no network,
/// or Local Network access off) goes on by itself once it can.
@MainActor
final class BonjourBrowser: NetworkServiceBrowsing {
    private var browser: NWBrowser?
    private var update: (@MainActor (NetworkBrowseUpdate) -> Void)?
    private var state = NetworkBrowseState.searching
    private var found: [NetworkService] = []
    private var failures = 0
    private var restart: DispatchWorkItem?

    func start(_ update: @escaping @MainActor (NetworkBrowseUpdate) -> Void) {
        stop()
        self.update = update
        failures = 0
        launch()
    }

    func stop() {
        restart?.cancel()
        restart = nil
        tearDown()
        update = nil
        state = .searching
        found = []
    }

    private func launch() {
        let parameters = NWParameters()
        // Only the local network's Bonjour: no AWDL peer-to-peer.
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: NetworkService.bonjourType, domain: "local."), using: parameters)
        state = .searching
        found = []
        browser.stateUpdateHandler = { [weak self, weak browser] newState in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                self.changed(to: newState)
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            let services = results.compactMap { result -> NetworkService? in
                guard case .service(let name, _, let domain, _) = result.endpoint else { return nil }
                return NetworkService(name: name, domain: domain)
            }
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                self.found = services
                self.report()
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    private func changed(to newState: NWBrowser.State) {
        state = Self.browseState(newState)
        switch newState {
        case .ready:
            failures = 0
        case .failed:
            // What it found may be gone: cleared, and looked for again later.
            tearDown()
            found = []
            failures += 1
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.update != nil, self.browser == nil else { return }
                    self.launch()
                    self.report()
                }
            }
            restart = item
            DispatchQueue.main.asyncAfter(deadline: .now() + NetworkRetry.delay(afterFailures: failures), execute: item)
        default:
            break
        }
        report()
    }

    private func tearDown() {
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
    }

    private func report() {
        update?(NetworkBrowseUpdate(state: state, services: found))
    }

    /// Waiting with "policy denied" is Local Network access being off (or not
    /// yet answered): NWBrowser goes on once it's allowed. Any other wait or
    /// failure is the network's.
    nonisolated static func browseState(_ state: NWBrowser.State) -> NetworkBrowseState {
        switch state {
        case .setup, .ready, .cancelled:
            return .searching
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                return .notAllowed
            }
            return .unavailable
        @unknown default:
            return .searching
        }
    }
}

// MARK: - Resolving

/// Finds where a service is now, and the address to connect to it at.
@MainActor
protocol NetworkServiceResolving {
    /// `completion` runs once, on the main thread, unless the lookup is cancelled.
    @discardableResult
    func resolve(_ service: NetworkService,
                 completion: @escaping @MainActor (Result<ServerAddress, NetworkResolveFailure>) -> Void)
        -> NetworkResolution
}

/// DNSServiceResolve: the service's host name and port, by its name, type and
/// domain given separately, so nothing in a name is parsed. The address made
/// from them (NetworkServers.address) is what's connected to.
struct BonjourResolver: NetworkServiceResolving {
    /// The resolver's calls are made, and its replies arrive, here.
    nonisolated fileprivate static let queue = DispatchQueue(label: "studio.irq.selway.bonjour-resolve",
                                                             qos: .userInitiated)
    /// A server that hasn't answered by then is taken to be gone.
    nonisolated fileprivate static let timeout: TimeInterval = 8

    @discardableResult
    func resolve(_ service: NetworkService,
                 completion: @escaping @MainActor (Result<ServerAddress, NetworkResolveFailure>) -> Void)
        -> NetworkResolution {
        let resolution = NetworkResolution()
        let lookup = ResolveLookup(service: service) { result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { resolution.finish { completion(result) } }
            }
        }
        resolution.whenCancelled { Self.queue.async { lookup.cancel() } }
        Self.queue.async { lookup.start() }
        return resolution
    }
}

/// One DNSServiceResolve. Used only on BonjourResolver.queue, which the
/// service reference is scheduled on, and deallocated on (as dns_sd requires).
private final class ResolveLookup: @unchecked Sendable {
    private let service: NetworkService
    private let finish: (Result<ServerAddress, NetworkResolveFailure>) -> Void
    private var ref: DNSServiceRef?
    /// The lookup, retained for the C callback's context while it's live.
    private var context: Unmanaged<ResolveLookup>?
    private var done = false

    init(service: NetworkService, finish: @escaping (Result<ServerAddress, NetworkResolveFailure>) -> Void) {
        self.service = service
        self.finish = finish
    }

    func start() {
        guard !done else { return }
        // A name with a NUL in it would be cut short as a C string: another name.
        guard !service.name.utf8.contains(0) else { return complete(.failure(.unusableAddress)) }
        let context = Unmanaged.passRetained(self)
        var ref: DNSServiceRef?
        let status = DNSServiceResolve(&ref, 0, 0, service.name, NetworkService.bonjourType, service.domain,
                                       resolveReply, context.toOpaque())
        guard status == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            context.release()
            return complete(.failure(Self.failure(status)))
        }
        self.ref = ref
        self.context = context
        let scheduled = DNSServiceSetDispatchQueue(ref, BonjourResolver.queue)
        guard scheduled == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            return complete(.failure(Self.failure(scheduled)))
        }
        BonjourResolver.queue.asyncAfter(deadline: .now() + BonjourResolver.timeout) { [weak self] in
            self?.complete(.failure(.notFound))
        }
    }

    /// The resolver's reply, on the queue. The first is taken.
    func replied(status: DNSServiceErrorType, host: UnsafePointer<CChar>?, port: UInt16) {
        guard !done else { return }
        guard status == DNSServiceErrorType(kDNSServiceErr_NoError), let host else {
            return complete(.failure(Self.failure(status)))
        }
        let bytes = Array(UnsafeBufferPointer(start: UnsafeRawPointer(host).assumingMemoryBound(to: UInt8.self),
                                              count: strlen(host)))
        // The port comes in network byte order.
        let address = NetworkServers.address(for: service, target: bytes, port: Int(UInt16(bigEndian: port)))
        complete(address.map { .success($0) } ?? .failure(.unusableAddress))
    }

    /// Stops it without a result.
    func cancel() {
        guard !done else { return }
        done = true
        tearDown()
    }

    private func complete(_ result: Result<ServerAddress, NetworkResolveFailure>) {
        guard !done else { return }
        done = true
        tearDown()
        finish(result)
    }

    private func tearDown() {
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
        context?.release()
        context = nil
    }

    private static func failure(_ status: DNSServiceErrorType) -> NetworkResolveFailure {
        status == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) ? .notAllowed : .notFound
    }
}

/// DNSServiceResolve's callback: hands the reply to the lookup in `context`.
private let resolveReply: DNSServiceResolveReply = { _, _, _, status, _, hostTarget, port, _, _, context in
    guard let context else { return }
    Unmanaged<ResolveLookup>.fromOpaque(context).takeUnretainedValue()
        .replied(status: status, host: hostTarget, port: port)
}

// MARK: - The servers found, for every window

/// The Network row's servers and placeholder, shared by every window. It
/// searches while at least one window's sidebar shows the row open
/// (`setWatching`), and stops when none does. Only views that exist while
/// Network is open observe it, so its changes don't redraw other sidebars.
///
/// What the search reports is published at most every `publishInterval`
/// (the latest of what came in meanwhile), so a network flooded with
/// services coming and going costs a few updates a second, and at most
/// NetworkServers.maxRows rows.
@MainActor
final class NetworkNeighborhood: ObservableObject {
    static let shared = NetworkNeighborhood()

    /// How often, at most, what the search finds is published.
    static let publishInterval: TimeInterval = 0.3

    @Published private(set) var list = NetworkServerList()
    /// The dimmed row shown when there are no servers to list (or Local
    /// Network access is off); nil while servers are listed.
    @Published private(set) var placeholder: NetworkPlaceholder?

    private let makeBrowser: @MainActor () -> NetworkServiceBrowsing
    private let resolver: NetworkServiceResolving
    private var browser: NetworkServiceBrowsing?
    private var watchers: Set<UUID> = []
    private var state = NetworkBrowseState.searching
    private var services: [NetworkService] = []
    private var thisMac: [String] = []
    private var searchedLong = false
    private var longSearch: DispatchWorkItem?
    /// What this search has decided about its rows: which arrived first
    /// (keeping its name, and its place under the cap). Emptied when it stops.
    private var rowMemory = NetworkRowMemory()
    /// The publish waiting for `publishInterval` to pass.
    private var pendingPublish: DispatchWorkItem?

    private init() {
        #if SELWAY_UI_TESTING
        // The UI tests never search the real network (which would put up the
        // Local Network prompt): always the stand-in, empty without the hook.
        if UITestHooks.isActive {
            let entries = UITestHooks.bonjourServices
            makeBrowser = { UITestNetworkBrowser(entries: entries) }
            resolver = UITestNetworkResolver(entries: entries)
            return
        }
        #endif
        makeBrowser = { BonjourBrowser() }
        resolver = BonjourResolver()
    }

    /// A window's sidebar shows the Network row open (`true`), or no longer
    /// does (closed, the window gone, the row turned off).
    func setWatching(_ watching: Bool, id: UUID) {
        if watching { watchers.insert(id) } else { watchers.remove(id) }
        if !watchers.isEmpty, browser == nil {
            start()
        } else if watchers.isEmpty, browser != nil {
            stop()
        }
    }

    var servers: [NetworkServer] { list.servers }

    func server(id: String) -> NetworkServer? { list.servers.first { $0.id == id } }

    /// Looks `server` up and makes the address to connect to it at.
    @discardableResult
    func resolve(_ server: NetworkServer,
                 completion: @escaping @MainActor (Result<ServerAddress, NetworkResolveFailure>) -> Void)
        -> NetworkResolution {
        resolver.resolve(server.service, completion: completion)
    }

    // MARK: Searching

    private func start() {
        state = .searching
        services = []
        rowMemory = NetworkRowMemory()
        searchedLong = false
        thisMac = Self.thisMacsNames()
        let browser = makeBrowser()
        self.browser = browser
        publish()
        // "No servers found" once it has looked for a while.
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.browser != nil else { return }
                self.searchedLong = true
                self.publish()
            }
        }
        longSearch = item
        DispatchQueue.main.asyncAfter(deadline: .now() + NetworkPlaceholder.searchingFor, execute: item)
        browser.start { [weak self] update in self?.received(update) }
    }

    private func stop() {
        browser?.stop()
        browser = nil
        longSearch?.cancel()
        longSearch = nil
        pendingPublish?.cancel()
        pendingPublish = nil
        services = []
        rowMemory = NetworkRowMemory()
        if list != NetworkServerList() { list = NetworkServerList() }
        if placeholder != nil { placeholder = nil }
    }

    /// Kept, and published with whatever else comes in the next
    /// `publishInterval` (a trailing throttle).
    private func received(_ update: NetworkBrowseUpdate) {
        guard browser != nil else { return }
        state = update.state
        services = update.services
        guard pendingPublish == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingPublish = nil
                if self.browser != nil { self.publish() }
            }
        }
        pendingPublish = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.publishInterval, execute: item)
    }

    private func publish() {
        let rows = NetworkServers.list(services, thisMac: thisMac, memory: &rowMemory)
        if rows != list { list = rows }
        let shown = NetworkPlaceholder.current(state: state, serverCount: rows.servers.count + rows.hiddenCount,
                                               searchedLong: searchedLong)
        if shown != placeholder { placeholder = shown }
    }

    /// This Mac's computer name, which macOS advertises its own file sharing
    /// under. From SystemConfiguration, which asks nothing of the network
    /// (Host.current() can wait on DNS).
    private static func thisMacsNames() -> [String] {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?).map { [$0] } ?? []
    }
}

// MARK: - UI test stand-ins

#if SELWAY_UI_TESTING
/// One entry of `-SelwayUITestBonjour` (UITestHooks.bonjourServices): a
/// server's name, after an optional behaviour:
/// - "drop:Name": found, then gone `dropAfter` seconds after the search starts;
/// - "slow:Name": looking it up takes `slowLookup` seconds (to cancel it);
/// - "lost:Name": looking it up finds nothing;
/// - "bad:Name": it resolves to a host Selway won't use (not .local).
struct UITestBonjourEntry: Equatable {
    enum Behaviour: String { case normal, drop, slow, lost, bad }

    static let dropAfter: TimeInterval = 6
    static let slowLookup: TimeInterval = 30

    let name: String
    let behaviour: Behaviour

    init(_ entry: String) {
        for behaviour in [Behaviour.drop, .slow, .lost, .bad] where entry.hasPrefix(behaviour.rawValue + ":") {
            self.name = String(entry.dropFirst(behaviour.rawValue.count + 1))
            self.behaviour = behaviour
            return
        }
        name = entry
        behaviour = .normal
    }
}

/// The servers `-SelwayUITestBonjour` lists ("Name|drop:Other|…"), found a
/// moment after the search starts, and the "drop:" ones gone a while later;
/// "!denied" instead makes it wait for Local Network access. Nothing goes on
/// the network.
@MainActor
final class UITestNetworkBrowser: NetworkServiceBrowsing {
    private let entries: [UITestBonjourEntry]
    private let denied: Bool
    private var running = false

    init(entries: [String]) {
        denied = entries.contains("!denied")
        self.entries = entries.filter { $0 != "!denied" }.map(UITestBonjourEntry.init)
    }

    func start(_ update: @escaping @MainActor (NetworkBrowseUpdate) -> Void) {
        running = true
        let state: NetworkBrowseState = denied ? .notAllowed : .searching
        let all = denied ? [] : entries.map { NetworkService(name: $0.name) }
        let kept = denied ? [] : entries.filter { $0.behaviour != .drop }.map { NetworkService(name: $0.name) }
        report(after: 0.3, NetworkBrowseUpdate(state: state, services: all), to: update)
        if kept != all {
            report(after: UITestBonjourEntry.dropAfter, NetworkBrowseUpdate(state: state, services: kept), to: update)
        }
    }

    func stop() { running = false }

    private func report(after delay: TimeInterval, _ found: NetworkBrowseUpdate,
                        to update: @escaping @MainActor (NetworkBrowseUpdate) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                update(found)
            }
        }
    }
}

/// Resolves the n-th server `-SelwayUITestBonjour` lists to the host
/// "selway-uitest-<n>.local" on the usual port, through the same checks as a
/// real reply, a moment later (or as its behaviour says: UITestBonjourEntry).
@MainActor
struct UITestNetworkResolver: NetworkServiceResolving {
    let entries: [String]

    @discardableResult
    func resolve(_ service: NetworkService,
                 completion: @escaping @MainActor (Result<ServerAddress, NetworkResolveFailure>) -> Void)
        -> NetworkResolution {
        let resolution = NetworkResolution()
        let index = entries.firstIndex { UITestBonjourEntry($0).name == service.name }
        let behaviour = index.map { UITestBonjourEntry(entries[$0]).behaviour }
        let delay = behaviour == .slow ? UITestBonjourEntry.slowLookup : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                let result: Result<ServerAddress, NetworkResolveFailure>
                if let index, behaviour != .lost {
                    let host = behaviour == .bad ? "selway-uitest.example.com." : "selway-uitest-\(index + 1).local."
                    result = NetworkServers.address(for: service, target: Array(host.utf8),
                                                    port: ServerScheme.smb.defaultPort)
                        .map { .success($0) } ?? .failure(.unusableAddress)
                } else {
                    result = .failure(.notFound)
                }
                resolution.finish { completion(result) }
            }
        }
        return resolution
    }
}
#endif
