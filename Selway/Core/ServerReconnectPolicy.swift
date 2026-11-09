import Foundation

/// Reconnect at Launch's servers that failed because the network wasn't up
/// yet (Wi-Fi joining after login), waiting for it: which may be tried again,
/// and when to give up. ServerReconnect watches the network and acts on it.
struct ServerReconnectPolicy: Sendable {
    /// Tries after the first, per server.
    static let retryLimit = 3
    /// The pause before trying a server again while the network stays up.
    static let retryPause: TimeInterval = 15
    /// How long after launch servers are waited for.
    static let lifetime: TimeInterval = 10 * 60

    private struct Entry: Sendable {
        let address: ServerAddress
        var retries = 0
        var inFlight = false
        var lastStatus: Int32 = 0
    }

    struct Expired: Equatable, Sendable {
        let address: ServerAddress
        let status: Int32
    }

    /// By `matchKey`.
    private var entries: [String: Entry] = [:]

    /// The servers still waited for.
    var waiting: [ServerAddress] { entries.values.map(\.address) }

    func isWaiting(_ address: ServerAddress) -> Bool { entries[address.matchKey] != nil }

    /// What a network that isn't up yet gives: the server not found (no
    /// route, no network, no name yet) or a timeout. A refusal or reset means
    /// the server is there; a login, share or other failure won't clear by
    /// waiting.
    static func waitsForNetwork(_ failure: ServerConnectFailure, status: Int32) -> Bool {
        failure == .serverNotFound || (failure == .serverNotResponding && status == 60)   // ETIMEDOUT
    }

    /// Records an initial or retry failure. Returns true when this server has
    /// exhausted its retry allowance and should get a final log line.
    mutating func failed(_ address: ServerAddress, failure: ServerConnectFailure, status: Int32) -> Bool {
        let key = address.matchKey
        guard Self.waitsForNetwork(failure, status: status) else {
            entries.removeValue(forKey: key)
            return false
        }
        var entry = entries[key] ?? Entry(address: address)
        entry.inFlight = false
        entry.lastStatus = status
        guard entry.retries < Self.retryLimit else {
            entries.removeValue(forKey: key)
            return true
        }
        entries[key] = entry
        return false
    }

    /// Selects waiting addresses that aren't mounted or already retrying.
    func ready(mounted: [ServerAddress]) -> [ServerAddress] {
        let keys = Set(mounted.map(\.matchKey))
        return entries.values.filter { !$0.inFlight && !keys.contains($0.address.matchKey) }
            .map(\.address)
    }

    /// A retry of `address` started: it isn't ready again until it fails.
    mutating func beganRetry(_ address: ServerAddress) {
        guard var entry = entries[address.matchKey], !entry.inFlight,
              entry.retries < Self.retryLimit else { return }
        entry.retries += 1
        entry.inFlight = true
        entries[address.matchKey] = entry
    }

    /// Mounted, or nothing more to do for it: no longer waited for.
    mutating func mounted(_ address: ServerAddress) {
        entries.removeValue(forKey: address.matchKey)
    }

    /// Only `addresses` are still wanted (Reconnect at Launch may have been
    /// turned off, or the server removed, meanwhile).
    mutating func keepWaiting(_ addresses: [ServerAddress]) {
        let keys = Set(addresses.map(\.matchKey))
        entries = entries.filter { keys.contains($0.key) }
    }

    /// Stops watching and returns servers that never became reachable.
    mutating func expire() -> [Expired] {
        let addresses = entries.values.map { Expired(address: $0.address, status: $0.lastStatus) }
        entries.removeAll()
        return addresses
    }
}
