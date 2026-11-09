import Foundation

/// Selway's pages on the web, in one place: the About window, the first-run sheet, the
/// error report and the update checks all link to these.
enum SelwayLinks {
    /// The project's site (GitHub Pages on the public repository, which also serves the
    /// update feed).
    static let website = URL(string: "https://toddbartholow.github.io/selway/")!

    /// The public repository.
    static let repository = URL(string: "https://github.com/toddbartholow/selway")!

    /// CHANGELOG.md on the public repository's main branch.
    static let changelog = URL(string: "https://github.com/toddbartholow/selway/blob/main/CHANGELOG.md")!

    /// A new issue on the public repository.
    static let newIssue = URL(string: "https://github.com/toddbartholow/selway/issues/new")!

    /// The releases page, where every version can be downloaded by hand.
    static let releases = URL(string: "https://github.com/toddbartholow/selway/releases")!

    /// A new issue with its title filled in.
    static func newIssue(title: String) -> URL {
        // URLComponents leaves "&", "=" and "+" alone in a query value; GitHub would read
        // them as separators (or a space), so they're encoded too.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        guard let value = title.addingPercentEncoding(withAllowedCharacters: allowed),
              var components = URLComponents(url: newIssue, resolvingAgainstBaseURL: false) else { return newIssue }
        components.percentEncodedQuery = "title=" + value
        return components.url ?? newIssue
    }
}
