import Foundation
import Testing
@testable import SelwayCore

/// The addresses the About window, the first-run sheet, the error report and the update
/// checks open: all HTTPS, all on the public repository.
@Suite struct SelwayLinksTests {

    @Test func everyLinkIsHTTPSOnThePublicRepository() {
        let links = [SelwayLinks.repository, SelwayLinks.changelog,
                     SelwayLinks.newIssue, SelwayLinks.releases]
        for link in links {
            #expect(link.scheme == "https", "\(link)")
            #expect(link.host == "github.com", "\(link)")
            #expect(link.user == nil && link.password == nil && link.fragment == nil, "\(link)")
            let address = link.absoluteString
            #expect(address.hasPrefix("https://github.com/toddbartholow/selway"), "\(link)")
        }
    }

    @Test func linksAreTheOnesTheOwnerPublished() {
        #expect(SelwayLinks.repository.absoluteString == "https://github.com/toddbartholow/selway")
        #expect(SelwayLinks.changelog.absoluteString
                == "https://github.com/toddbartholow/selway/blob/main/CHANGELOG.md")
        #expect(SelwayLinks.newIssue.absoluteString == "https://github.com/toddbartholow/selway/issues/new")
        #expect(SelwayLinks.releases.absoluteString == "https://github.com/toddbartholow/selway/releases")
    }

    @Test func newIssueTitleIsPercentEncoded() {
        #expect(SelwayLinks.newIssue(title: "Error report").absoluteString
                == "https://github.com/toddbartholow/selway/issues/new?title=Error%20report")
        let odd = SelwayLinks.newIssue(title: "a&b=c #1")
        let items = URLComponents(url: odd, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items == [URLQueryItem(name: "title", value: "a&b=c #1")])
        #expect(odd.fragment == nil)
    }
}
