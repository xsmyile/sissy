import Foundation

/// Why a `VersionedJSONFile` gave no document. `reason` is the error's domain
/// and code and never the file's bytes, so a log line built from it carries no
/// account.
enum JSONFileFailure: Error, Equatable {
    /// The file is there and the read itself failed, which says nothing about
    /// what is in it. No policy moves such a file: it may be a sound one behind
    /// a lock or a permission.
    case unreadable(reason: String)
    /// The file read and does not decode, which is the one case its contents
    /// are known to be bad.
    case undecodable(reason: String)
    /// The file decoded and is a schema this build does not speak.
    case unsupportedSchema(found: Int, expected: Int)

    /// The error's domain and code, which is all of it a log line may carry.
    fileprivate static func code(of error: Error) -> String {
        let bridged = error as NSError
        return "\(bridged.domain) \(bridged.code)"
    }

    /// What a copy set aside for this failure says about it, where its name
    /// says at all. Nothing sets aside a file that would not read.
    fileprivate var setAsideWord: String? {
        switch self {
        case .unreadable: nil
        case .undecodable: "decode"
        case .unsupportedSchema: "schema-mismatch"
        }
    }
}

/// One JSON file of Sissy's own, written atomically, with what happens to a bad
/// one stated rather than implied.
///
/// A missing file is not a bad one: every policy answers it with nil. What goes
/// in a file does not change by moving it here, so the formatting and the date
/// encoding stay per store.
struct VersionedJSONFile<Document: Codable> {
    /// What a load does with a file that will not give up a document.
    enum BadFilePolicy {
        /// Answers nil and leaves it, so the next save replaces it. Only for a
        /// record that costs a request or a pass to learn again.
        case replace
        /// Moves one that does not decode or is an unknown schema aside and
        /// throws why, so the next save starts a new file.
        case setAside
        /// Throws why and leaves it. Every write follows a load that succeeded,
        /// so a file this refuses is never overwritten until the store asks for
        /// `setAside(now:)` or `loadSettingAside(named:now:)`.
        case refuse
    }

    let url: URL
    let policy: BadFilePolicy
    /// What a copy set aside starts with, with a timestamp after it so a second
    /// one never replaces the first.
    var setAsidePrefix = ""
    /// Whether a copy's name carries `JSONFileFailure.setAsideWord`.
    var namesFailureInSetAside = false
    var formatting: JSONEncoder.OutputFormatting = [.sortedKeys]
    var iso8601Dates = false
    /// The version this build speaks and where a document says its own. Nil for
    /// a file with no version, and for a store that answers a mismatch itself.
    var schema: (current: Int, found: KeyPath<Document, Int>)?

    /// The document, or nil when there is no file or `policy` says to treat a
    /// bad one as if there were none.
    func load() throws -> Document? {
        do {
            return try read()
        } catch let failure as JSONFileFailure {
            switch policy {
            case .replace:
                return nil
            case .refuse:
                throw failure
            case .setAside:
                if case .unreadable = failure { throw failure }
                do {
                    _ = try setAside(word: failure.setAsideWord)
                } catch {
                    sissyLog("sissy: could not set \(url.lastPathComponent) aside (\(failure)): \(error)")
                }
                throw failure
            }
        }
    }

    /// The document, with a file that does not decode moved out of the way
    /// first and answered as if there were none. Moved rather than deleted: a
    /// person can still read it. A file whose read failed, and one that could
    /// not be moved, throw, which is the answer under which nothing may be
    /// written.
    func loadSettingAside(named label: String, now: Date = Date()) throws -> Document? {
        do {
            return try read()
        } catch let failure as JSONFileFailure {
            if case .unreadable = failure { throw failure }
            do {
                let aside = try setAside(word: failure.setAsideWord, now: now)
                sissyLog(
                    "sissy: \(label) would not decode (\(failure)); kept it as "
                        + aside.lastPathComponent)
                return nil
            } catch {
                sissyLog(
                    "sissy: \(label) would not decode (\(failure)) and could not be moved "
                        + "(\(JSONFileFailure.code(of: error)))")
                throw failure
            }
        }
    }

    /// Moves the file aside whatever is in it, and answers where it went.
    /// `word` joins the name only under `namesFailureInSetAside`.
    func setAside(word: String? = nil, now: Date = Date()) throws -> URL {
        let reason = namesFailureInSetAside ? word.map { "\($0)-" } ?? "" : ""
        let aside = url.deletingLastPathComponent().appendingPathComponent(
            "\(setAsidePrefix)\(reason)\(Int(now.timeIntervalSince1970)).json")
        try FileManager.default.moveItem(at: url, to: aside)
        return aside
    }

    /// Whether a copy has ever been set aside beside this file. Read off the
    /// directory rather than remembered, so a page keeps saying so across a
    /// relaunch until the file is dealt with.
    func hasSetAside() -> Bool {
        let parent = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.contains { $0.hasPrefix(setAsidePrefix) }
    }

    func save(_ document: Document) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = formatting
        if iso8601Dates { encoder.dateEncodingStrategy = .iso8601 }
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    private func read() throws -> Document? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw JSONFileFailure.unreadable(reason: JSONFileFailure.code(of: error))
        }
        let decoder = JSONDecoder()
        if iso8601Dates { decoder.dateDecodingStrategy = .iso8601 }
        let document: Document
        do {
            document = try decoder.decode(Document.self, from: data)
        } catch {
            throw JSONFileFailure.undecodable(
                reason: "\(data.count) bytes, \(JSONFileFailure.code(of: error))")
        }
        if let schema, document[keyPath: schema.found] != schema.current {
            throw JSONFileFailure.unsupportedSchema(
                found: document[keyPath: schema.found], expected: schema.current)
        }
        return document
    }
}
