import Foundation

/// Parsed remote URL info from a system mount entry.
struct ParsedRemote: Sendable {
    let host: String?
    let path: String

    /// Parse "ssh://alias/path" into components.
    static func from(urlString: String) -> ParsedRemote {
        guard let url = URL(string: urlString) else {
            return ParsedRemote(host: nil, path: urlString)
        }
        return ParsedRemote(
            host: url.host,
            path: url.path.isEmpty ? "~" : url.path
        )
    }
}

/// A system-level active mount entry.
struct ActiveMount: Sendable {
    let remote: ParsedRemote
    let localPath: String
}
