import Foundation
import Testing
@testable import SelwayCore

@MainActor
@Suite struct NetworkResolutionTests {
    @Test func aResultIsDeliveredOnce() {
        let resolution = NetworkResolution()
        var delivered = 0, cancelled = 0
        resolution.whenCancelled { cancelled += 1 }
        resolution.finish { delivered += 1 }
        resolution.finish { delivered += 1 }
        #expect(delivered == 1)
        #expect(!resolution.isLive)
        // Cancel after the result: nothing to stop, and nothing more delivered.
        resolution.cancel()
        #expect(cancelled == 0 && delivered == 1)
    }

    @Test func aResultAfterCancelIsDropped() {
        let resolution = NetworkResolution()
        var delivered = 0, cancelled = 0
        resolution.whenCancelled { cancelled += 1 }
        resolution.cancel()
        resolution.cancel()
        #expect(cancelled == 1)
        resolution.finish { delivered += 1 }
        #expect(delivered == 0)
        #expect(!resolution.isLive)
    }

    @Test func whatToStopIsntKeptOnceItsOver() {
        let resolution = NetworkResolution()
        resolution.cancel()
        var cancelled = 0
        resolution.whenCancelled { cancelled += 1 }
        resolution.cancel()
        #expect(cancelled == 0)
    }
}
