import Testing
@testable import SelwayCore

@Suite struct ServerReconnectPolicyTests {
    private func address(_ text: String) throws -> ServerAddress {
        try ServerAddress.parse(text).get().address
    }

    @Test func waitsForUnreachableHostsAndTimeoutsOnly() {
        #expect(ServerReconnectPolicy.waitsForNetwork(.serverNotFound, status: 51)) // ENETUNREACH
        #expect(ServerReconnectPolicy.waitsForNetwork(.serverNotFound, status: 65)) // EHOSTUNREACH
        #expect(ServerReconnectPolicy.waitsForNetwork(.serverNotFound, status: 64)) // EHOSTDOWN
        #expect(ServerReconnectPolicy.waitsForNetwork(.serverNotFound, status: 50)) // ENETDOWN
        #expect(ServerReconnectPolicy.waitsForNetwork(.serverNotFound, status: 8))  // EAI_NONAME
        #expect(ServerReconnectPolicy.waitsForNetwork(.serverNotResponding, status: 60)) // ETIMEDOUT
        #expect(!ServerReconnectPolicy.waitsForNetwork(.serverNotResponding, status: 61)) // ECONNREFUSED
        #expect(!ServerReconnectPolicy.waitsForNetwork(.serverNotResponding, status: 54)) // ECONNRESET
        #expect(!ServerReconnectPolicy.waitsForNetwork(.authentication, status: 13))
        #expect(!ServerReconnectPolicy.waitsForNetwork(.shareNotFound, status: 2))
        #expect(!ServerReconnectPolicy.waitsForNetwork(.alreadyMounted, status: 17))
    }

    @Test func waitsUntilNetworkThenSkipsMountedServers() throws {
        let one = try address("smb://one.example/share")
        let two = try address("smb://two.example/share")
        var policy = ServerReconnectPolicy()
        let oneGaveUp = policy.failed(one, failure: .serverNotFound, status: 51)
        let twoGaveUp = policy.failed(two, failure: .serverNotFound, status: 65)
        #expect(!oneGaveUp && !twoGaveUp)
        #expect(Set(policy.ready(mounted: [one]).map(\.matchKey)) == [two.matchKey])
        policy.beganRetry(two)
        #expect(policy.ready(mounted: [one]).isEmpty)
        policy.mounted(two)
        #expect(policy.waiting.map(\.matchKey) == [one.matchKey])
    }

    @Test func stopsAfterThreeRetriesAndExpiresWaitingServers() throws {
        let server = try address("smb://server.example/share")
        var policy = ServerReconnectPolicy()
        let initialGaveUp = policy.failed(server, failure: .serverNotFound, status: 51)
        #expect(!initialGaveUp)
        for _ in 0..<ServerReconnectPolicy.retryLimit {
            policy.beganRetry(server)
            let gaveUp = policy.failed(server, failure: .serverNotFound, status: 51)
            #expect(gaveUp == (policy.waiting.isEmpty))
        }
        #expect(policy.waiting.isEmpty)

        let finalInitialGaveUp = policy.failed(server, failure: .serverNotFound, status: 51)
        #expect(!finalInitialGaveUp)
        #expect(policy.expire().map { $0.address.matchKey } == [server.matchKey])
        #expect(policy.waiting.isEmpty)
    }
}
