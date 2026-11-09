import Foundation
import Testing
@testable import SelwayCore

@Suite struct WindowRequestsTests {
    @Test func eachWindowTakesOnlyItsOwnRequest() {
        var requests = WindowRequests<String>()
        let tab = requests.add("subfolder tab")
        let window = requests.add("third window")

        // A window opened without an id (File ▸ New Window) takes nothing,
        // however many are waiting.
        #expect(requests.take(nil) == nil)
        // The later one can appear first.
        #expect(requests.take(window) == "third window")
        #expect(requests.take(tab) == "subfolder tab")
        #expect(requests.isEmpty)
    }

    @Test func aRequestIsTakenOnce() {
        var requests = WindowRequests<Int>()
        let id = requests.add(1)
        #expect(requests.take(id) == 1)
        #expect(requests.take(id) == nil)
        #expect(requests.take(UUID()) == nil)
    }

    /// A request whose window never came is dropped once it's old, so a
    /// quick ⌘T doesn't join its host.
    @Test func anOldRequestIsDroppedWhenAnotherIsFiled() {
        var requests = WindowRequests<String>()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let lost = requests.add("lost", now: start)
        let recent = requests.add("recent", now: start.addingTimeInterval(20))
        _ = requests.add("new", now: start.addingTimeInterval(WindowRequests<String>.patience + 1))
        #expect(requests.take(lost) == nil)
        #expect(requests.take(recent) == "recent")
        #expect(requests.last { _ in true } == "new")
    }

    @Test func theLatestMatchingRequestIsFound() {
        var requests = WindowRequests<(name: String, isTab: Bool)>()
        _ = requests.add(("a", true))
        _ = requests.add(("b", true))
        _ = requests.add(("c", false))
        #expect(requests.last { $0.isTab }?.name == "b")
        #expect(requests.last { $0.name == "z" } == nil)
    }
}
