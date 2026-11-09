import Foundation
import Testing
@testable import SelwayCore

/// The addresses the About window, the first-run sheet, the error report and the update
/// checks open: all HTTPS, all on the public repository or its Pages site.
@Suite struct SelwayLinksTests {

    @Test func everyLinkIsHTTPSOnThePublicRepository() {
        let links = [SelwayLinks.website, SelwayLinks.repository, SelwayLinks.changelog,
                     SelwayLinks.newIssue, SelwayLinks.releases]
        for link in links {
            #expect(link.scheme == "https", "\(link)")
            #expect(link.host == "github.com" || link.host == "toddbartholow.github.io", "\(link)")
            #expect(link.user == nil && link.password == nil && link.fragment == nil, "\(link)")
            let address = link.absoluteString
            #expect(address.hasPrefix("https://github.com/toddbartholow/selway")
                    || address.hasPrefix("https://toddbartholow.github.io/selway/"), "\(link)")
        }
    }

    @Test func linksAreTheOnesTheOwnerPublished() {
        #expect(SelwayLinks.website.absoluteString == "https://toddbartholow.github.io/selway/")
        #expect(SelwayLinks.repository.absoluteString == "https://github.com/toddbartholow/selway")
        #expect(SelwayLinks.changelog.absoluteString
                == "https://github.com/toddbartholow/selway/blob/main/CHANGELOG.md")
        #expect(SelwayLinks.newIssue.absoluteString == "https://github.com/toddbartholow/selway/issues/new")
        #expect(SelwayLinks.releases.absoluteString == "https://github.com/toddbartholow/selway/releases")
    }

    /// The Pages site also serves the update feed (Info.plist's SUFeedURL).
    @Test func websiteIsWhereTheUpdateFeedLives() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Selway/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let feed = try #require(plist["SUFeedURL"] as? String)
        #expect(feed == SelwayLinks.website.absoluteString + "appcast.xml")
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
