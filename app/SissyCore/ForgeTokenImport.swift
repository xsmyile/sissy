import Foundation

/// A token a forge CLI on this Mac already holds, offered for a connection.
///
/// Its own type rather than a bare string because the host is half the answer:
/// `glab` is configured against one company instance on this machine, and a
/// row offering "the token glab has" has to say which host it is for before it
/// is pressed.
struct ForgeTokenCandidate: Sendable, Equatable, Identifiable {
    let kind: ForgeKind
    let host: String
    /// The account name the CLI's own configuration files it under. **Not who
    /// the token belongs to** — measured 2026-09-17, `gh`'s configuration named
    /// one account for an item whose token answered as another. It is here to
    /// locate the keychain item and for nothing else; whose numbers these are
    /// comes from the vendor on every poll.
    let configuredAccount: String?
    let token: String

    var id: String { "\(kind.rawValue):\(host)" }

    var connection: ForgeConnection { ForgeConnection(kind: kind, host: host) }
}

/// Reads the tokens `gh` and `glab` already hold, so connecting a forge is one
/// click rather than a trip to a settings page in a browser.
///
/// **This is offered, never taken.** It runs from the button that says which
/// CLI it is reading and nothing else — not at launch, not from a poll — which
/// is the rule the claude.ai login window is under, and the specific mistake
/// #167 removed: a mechanism that acquires a credential on its own is one that
/// cannot name the account it imported. The scope is the other half of the
/// reason. Measured 2026-09-17, this machine's `gh` token carries
/// `admin:public_key, gist, read:org, repo` — write access to every
/// repository — for a feature that reads two counters, so a user who would
/// rather mint a read-only token must be able to say so, and the control has
/// to tell them what they are about to hand over.
///
/// Neither CLI's storage is ever written. Sissy copies the value into a
/// keychain item of its own (`ForgeTokenStore`) and reads that from then on, so
/// a token the CLI later replaces does not change what Sissy is holding and
/// nothing Sissy does can sign the terminal out.
enum ForgeTokenImport {
    /// `gh` keeps its token in the login keychain under this service plus the
    /// host, and files it against the account its own configuration names.
    private static let gitHubKeychainPrefix = "gh:"
    /// What `go-keyring` writes in front of a value it encoded. Measured
    /// 2026-09-17: a 74-character item whose body decoded to the 40 bytes of a
    /// a GitHub token. A value with no prefix is taken as the token itself,
    /// which is the shape older releases wrote.
    private static let goKeyringBase64Prefix = "go-keyring-base64:"
    private static let gitHubConfigPath = ".config/gh/hosts.yml"
    private static let gitLabConfigPath = ".config/glab-cli/config.yml"
    /// The key older `gh` releases wrote the token to in `hosts.yml` itself,
    /// before it moved to the keychain. Read as a fallback so a machine that
    /// has never re-authenticated still offers its token.
    private static let gitHubInlineTokenKey = "oauth_token"
    private static let gitHubUserKey = "user"
    private static let gitLabTokenKey = "token"
    private static let hostsKey = "hosts"

    /// Every candidate both CLIs can offer, GitHub first.
    static func candidates(home: URL = URL(fileURLWithPath: NSHomeDirectory()))
        -> [ForgeTokenCandidate]
    {
        gitHub(home: home) + gitLab(home: home)
    }

    /// What `gh` holds, one candidate per host it is authenticated against.
    ///
    /// The keychain read goes through `/usr/bin/security` rather than
    /// `SecItemCopyMatching`, and that is not a style choice: `gh` files its
    /// item by shelling out to that tool, so the tool is on the item's ACL and
    /// this process is not. Measured 2026-09-17 from a process that had never
    /// touched the item — the CLI read returned 0 with no dialog where an
    /// in-process read raises the legacy Allow/Deny panel and earns a grant
    /// that dies at the next rewrite. It is the same mechanism
    /// `ClaudeKeychainCLI` already exists for.
    static func gitHub(home: URL = URL(fileURLWithPath: NSHomeDirectory()))
        -> [ForgeTokenCandidate]
    {
        let config = home.appendingPathComponent(gitHubConfigPath)
        return hosts(in: config).compactMap { host, fields in
            let account = fields[gitHubUserKey]
            if let inline = fields[gitHubInlineTokenKey], !inline.isEmpty {
                return ForgeTokenCandidate(
                    kind: .gitHub, host: host, configuredAccount: account, token: inline)
            }
            guard let account, !account.isEmpty,
                let data = try? ClaudeKeychainCLI.read(
                    service: gitHubKeychainPrefix + host, account: account),
                let token = decodeKeyringValue(data)
            else { return nil }
            return ForgeTokenCandidate(
                kind: .gitHub, host: host, configuredAccount: account, token: token)
        }
        .sorted { $0.host < $1.host }
    }

    /// What `glab` holds. Its token sits in plaintext in its own configuration
    /// file — measured 2026-09-17 on this machine, and `glab auth status` says
    /// so itself — so there is no keychain hop and no account to locate it by.
    static func gitLab(home: URL = URL(fileURLWithPath: NSHomeDirectory()))
        -> [ForgeTokenCandidate]
    {
        let config = home.appendingPathComponent(gitLabConfigPath)
        return hosts(in: config).compactMap { host, fields in
            guard let token = fields[gitLabTokenKey], !token.isEmpty else { return nil }
            return ForgeTokenCandidate(
                kind: .gitLab, host: host, configuredAccount: nil, token: token)
        }
        .sorted { $0.host < $1.host }
    }

    /// The value a `go-keyring` item holds, decoded.
    ///
    /// A prefix this build does not know answers nil rather than being passed
    /// through: the chunked form names a continuation rather than a token, and
    /// offering it as one would connect a forge that answers 401 for ever.
    static func decodeKeyringValue(_ data: Data) -> String? {
        let raw =
            String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        guard raw.hasPrefix("go-keyring") else { return raw }
        guard raw.hasPrefix(goKeyringBase64Prefix) else { return nil }
        let body = String(raw.dropFirst(goKeyringBase64Prefix.count))
        guard let decoded = Data(base64Encoded: body),
            let token = String(data: decoded, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
        else { return nil }
        return token
    }

    /// The `hosts:` block of either CLI's configuration, as host to fields.
    ///
    /// A deliberately small reader rather than a YAML parser, because the shape
    /// both files use is two levels of indentation under one key and a
    /// dependency for that would be a dependency in the binary for ever. Both
    /// files are foreign input, so it is read as a boundary: anything that is
    /// not `key: value` at the expected depth is skipped rather than guessed
    /// at, a host with no fields is dropped, and a value carrying a comment or
    /// quotes is unwrapped before it is taken.
    ///
    /// `gh` writes the block at the document root and `glab` writes it under
    /// `hosts:`, so the block is found by key where there is one and taken from
    /// the root where there is not.
    ///
    /// **A host's fields are its immediate children and nothing deeper.** `gh`
    /// nests a `users:` block under the host and files each account inside it,
    /// so a parser that accepted any depth would flatten
    /// `users.<account>.oauth_token` into the host's own field and hand back
    /// whichever account came last in the file — not the one the host's `user:`
    /// key names, and then preferred over the keychain read that would have been
    /// right.
    static func hosts(in url: URL) -> [String: [String: String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let scoped = lines.contains { indent(of: $0) == 0 && key(of: $0) == hostsKey }
        var hosts: [String: [String: String]] = [:]
        var hostIndent: Int?
        var fieldIndent: Int?
        var current: String?
        for line in lines {
            guard !isBlank(line) else { continue }
            let depth = indent(of: line)
            guard let name = key(of: line) else { continue }
            if scoped, depth == 0 {
                if name != hostsKey {
                    current = nil
                    hostIndent = nil
                    fieldIndent = nil
                }
                continue
            }
            if let hostIndent, depth > hostIndent {
                guard let host = current else { continue }
                if fieldIndent == nil { fieldIndent = depth }
                guard depth == fieldIndent, let value = value(of: line), !value.isEmpty else {
                    continue
                }
                hosts[host, default: [:]][name] = value
                continue
            }
            if hostIndent == nil || depth == hostIndent {
                guard value(of: line) == nil else { continue }
                hostIndent = depth
                fieldIndent = nil
                current = name
                hosts[name] = hosts[name] ?? [:]
            }
        }
        return hosts.filter { !$0.value.isEmpty }
    }

    private static func isBlank(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("-")
    }

    private static func indent(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    /// The key on a `key: value` line, or nil for a line that is not one.
    private static func key(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let name = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The value on a `key: value` line, nil where the line only opens a block.
    private static func value(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        var rest = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        if let comment = rest.firstIndex(of: "#"), !rest.hasPrefix("\"") {
            rest = String(rest[rest.startIndex..<comment]).trimmingCharacters(in: .whitespaces)
        }
        if rest.count >= 2, rest.hasPrefix("\""), rest.hasSuffix("\"") {
            rest = String(rest.dropFirst().dropLast())
        }
        return rest.isEmpty ? nil : rest
    }
}
