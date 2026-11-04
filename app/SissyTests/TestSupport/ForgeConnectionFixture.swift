@testable import Sissy

extension ForgeConnection {
    /// A GitHub connection, for a test that has no opinion about the address.
    static func gitHub(host: String = GitHubActivityFeed.dotComHost) -> Self {
        Self(kind: .gitHub, host: host)
    }
}
