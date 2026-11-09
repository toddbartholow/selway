import Foundation

/// What new windows were asked for, each under the id its window is opened
/// with (`openWindow(id:value:)`). A window reads only its own. One opened any
/// other way has no id (File ▸ New Window, the Dock) or one filed in an earlier
/// session (a restored window), so it can't take a request meant for a window
/// still on its way, as a queue handed to whichever window appeared first
/// could (issue #84).
struct WindowRequests<Request> {
    private var waiting: [(id: UUID, request: Request, filed: Date)] = []
    /// How long a request waits for its window before it's dropped: one that
    /// hasn't come by then won't, and a quick ⌘T mustn't join its host.
    static var patience: TimeInterval { 30 }

    var isEmpty: Bool { waiting.isEmpty }

    /// Files `request` and returns the id to open its window with. Requests
    /// older than `patience` are dropped first.
    mutating func add(_ request: Request, id: UUID = UUID(), now: Date = Date()) -> UUID {
        waiting.removeAll { now.timeIntervalSince($0.filed) > Self.patience }
        waiting.append((id, request, now))
        return id
    }

    /// The request filed under `id`, taken out; nil for a window with no id,
    /// one not filed here, or one whose request was taken already.
    mutating func take(_ id: UUID?) -> Request? {
        guard let id, let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
        return waiting.remove(at: index).request
    }

    /// The latest request still waiting that satisfies `matches`.
    func last(where matches: (Request) -> Bool) -> Request? {
        waiting.last { matches($0.request) }?.request
    }
}
