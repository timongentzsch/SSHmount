import Foundation

/// Parses ~/.ssh/config and resolves concrete host aliases.
struct SSHConfigParser {
    struct HostEntry {
        var hostname: String?
        var port: Int?
        var user: String?
        var identityFiles: [String] = []
        var proxyJump: String?
    }

    enum Error: LocalizedError {
        case unknownHostAlias(String)
        case resolutionFailed(String)

        var errorDescription: String? {
            switch self {
            case .unknownHostAlias(let alias):
                return "Host alias '\(alias)' is not defined in ~/.ssh/config"
            case .resolutionFailed(let alias):
                return "Failed to resolve SSH config for host alias '\(alias)'"
            }
        }
    }

    private struct ParsedEntry {
        let patterns: [String]
        let config: HostEntry
    }

    private var entries: [ParsedEntry] = []
    private var concreteAliases: Set<String> = []

    /// Get the real user home directory (bypasses sandbox container redirection).
    static var realHomeDirectory: String { PathUtilities.realHomeDirectory }

    init() {
        let root = URL(fileURLWithPath: Self.realHomeDirectory)
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)

        var visited: Set<String> = []
        parseFile(at: root, visited: &visited)
    }

    /// Resolve connection info for a concrete host alias from ~/.ssh/config.
    func resolve(alias: String) throws -> SSHConnectionInfo {
        guard concreteAliases.contains(alias) else {
            throw Error.unknownHostAlias(alias)
        }

        if let resolved = resolveViaSSH(binaryAlias: alias) {
            return resolved
        }

        let resolved = resolveViaParsedEntries(alias: alias)
        if resolved.user.isEmpty || resolved.hostname.isEmpty {
            throw Error.resolutionFailed(alias)
        }

        return resolved
    }

    /// List all concrete Host entries from ~/.ssh/config.
    func knownHosts() -> [String] {
        concreteAliases.sorted()
    }

    /// Validate that a host alias is defined in ~/.ssh/config.
    func validateAlias(_ alias: String) throws {
        guard concreteAliases.contains(alias) else {
            throw Error.unknownHostAlias(alias)
        }
    }

    // MARK: - File Parser

    private mutating func parseFile(at url: URL, visited: inout Set<String>) {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard visited.insert(path).inserted else { return }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            Log.config.debug("Could not read SSH config at \(path, privacy: .public)")
            return
        }

        var currentPatterns: [String]?
        var currentConfig = HostEntry()

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = strippedLine(rawLine)
            guard !line.isEmpty else { continue }

            guard let (key, value) = splitKeyValue(line) else { continue }

            if key == "include" {
                if let patterns = currentPatterns {
                    entries.append(ParsedEntry(patterns: patterns, config: currentConfig))
                    currentPatterns = nil
                    currentConfig = HostEntry()
                }

                for includeToken in splitTokens(value) {
                    for includeURL in resolveIncludePaths(token: includeToken, relativeTo: url) {
                        parseFile(at: includeURL, visited: &visited)
                    }
                }
                continue
            }

            if key == "host" {
                if let patterns = currentPatterns {
                    entries.append(ParsedEntry(patterns: patterns, config: currentConfig))
                }

                let patterns = splitTokens(value)
                currentPatterns = patterns
                currentConfig = HostEntry()

                for pattern in patterns where isConcreteAlias(pattern) {
                    concreteAliases.insert(pattern)
                }
                continue
            }

            guard currentPatterns != nil else { continue }
            applyConfig(key: key, value: value, to: &currentConfig)
        }

        if let patterns = currentPatterns {
            entries.append(ParsedEntry(patterns: patterns, config: currentConfig))
        }
    }

    private func splitKeyValue(_ line: String) -> (String, String)? {
        let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2 else { return nil }
        let key = parts[0].lowercased()
        let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private func strippedLine(_ rawLine: String) -> String {
        var out = ""
        var inSingleQuote = false
        var inDoubleQuote = false

        for char in rawLine {
            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                out.append(char)
                continue
            }
            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                out.append(char)
                continue
            }
            if char == "#" && !inSingleQuote && !inDoubleQuote {
                break
            }
            out.append(char)
        }

        return out.trimmingCharacters(in: .whitespaces)
    }

    private func splitTokens(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?

        for ch in value {
            if let q = quote {
                if ch == q {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }

            if ch == "\"" || ch == "'" {
                quote = ch
                continue
            }

            if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(ch)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private func applyConfig(key: String, value: String, to entry: inout HostEntry) {
        switch key {
        case "hostname":
            if entry.hostname == nil { entry.hostname = value }
        case "port":
            if entry.port == nil { entry.port = Int(value) }
        case "user":
            if entry.user == nil { entry.user = value }
        case "identityfile":
            entry.identityFiles.append(value)
        case "proxyjump":
            if entry.proxyJump == nil { entry.proxyJump = value }
        default:
            break
        }
    }

    private func resolveIncludePaths(token: String, relativeTo configFile: URL) -> [URL] {
        let home = Self.realHomeDirectory
        let resolvedToken: String

        if token.hasPrefix("~/") {
            resolvedToken = home + String(token.dropFirst(1))
        } else if token.hasPrefix("/") {
            resolvedToken = token
        } else {
            resolvedToken = configFile.deletingLastPathComponent().appendingPathComponent(token).path
        }

        if hasGlobSyntax(resolvedToken) {
            return globPaths(resolvedToken)
        }

        return [URL(fileURLWithPath: resolvedToken)]
    }

    private func hasGlobSyntax(_ path: String) -> Bool {
        path.contains("*") || path.contains("?") || path.contains("[")
    }

    private func globPaths(_ pattern: String) -> [URL] {
        var result = glob_t()
        defer { globfree(&result) }

        let rc = pattern.withCString { glob($0, 0, nil, &result) }
        guard rc == 0, let pathv = result.gl_pathv else { return [] }

        var urls: [URL] = []
        for i in 0..<Int(result.gl_pathc) {
            guard let cPath = pathv[i] else { continue }
            urls.append(URL(fileURLWithPath: String(cString: cPath)))
        }

        return urls.sorted { $0.path < $1.path }
    }

    // MARK: - Resolution

    private func resolveViaSSH(binaryAlias alias: String) -> SSHConnectionInfo? {
        guard let output = runSSHConfig(alias: alias) else { return nil }

        var values: [String: [String]] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            values[key, default: []].append(value)
        }

        let hostname = values["hostname"]?.first ?? alias
        let user = values["user"]?.first ?? NSUserName()
        let port = Int(values["port"]?.first ?? "") ?? 22

        let expandedKeys = (values["identityfile"] ?? [])
            .map { expandHome(in: $0) }
        let existingKeys = existingIdentityFiles(from: expandedKeys)

        return SSHConnectionInfo(
            alias: alias,
            hostname: hostname,
            port: port,
            user: user,
            identityFiles: existingKeys,
            proxyJump: values["proxyjump"]?.first
        )
    }

    private func runSSHConfig(alias: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", alias]

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = Self.realHomeDirectory
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            Log.config.debug("ssh -G failed for alias \(alias, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func resolveViaParsedEntries(alias: String) -> SSHConnectionInfo {
        var merged = HostEntry()

        for entry in entries where matches(patterns: entry.patterns, host: alias) {
            if merged.hostname == nil, let hostname = entry.config.hostname {
                merged.hostname = hostname
            }
            if merged.port == nil, let port = entry.config.port {
                merged.port = port
            }
            if merged.user == nil, let user = entry.config.user {
                merged.user = user
            }
            merged.identityFiles.append(contentsOf: entry.config.identityFiles)
            if merged.proxyJump == nil, let proxyJump = entry.config.proxyJump {
                merged.proxyJump = proxyJump
            }
        }

        let hostname = merged.hostname ?? alias
        let port = merged.port ?? 22
        let user = merged.user ?? NSUserName()

        let expandedKeys = merged.identityFiles.map { expandHome(in: $0) }
        let existingKeys = existingIdentityFiles(from: expandedKeys)

        return SSHConnectionInfo(
            alias: alias,
            hostname: hostname,
            port: port,
            user: user,
            identityFiles: existingKeys,
            proxyJump: merged.proxyJump
        )
    }

    private func existingIdentityFiles(from paths: [String]) -> [String] {
        let candidates: [String]
        if paths.isEmpty {
            let home = Self.realHomeDirectory
            candidates = ["id_ed25519", "id_rsa", "id_ecdsa"].map { "\(home)/.ssh/\($0)" }
        } else {
            candidates = paths
        }

        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func expandHome(in path: String) -> String {
        PathUtilities.expandTilde(path)
    }

    // MARK: - Pattern Matching

    private func isConcreteAlias(_ pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        guard !pattern.hasPrefix("!") else { return false }
        return !pattern.contains("*") && !pattern.contains("?")
    }

    private func matches(patterns: [String], host: String) -> Bool {
        var matchedPositive = false

        for pattern in patterns {
            let isNegated = pattern.hasPrefix("!")
            let rawPattern = isNegated ? String(pattern.dropFirst()) : pattern
            guard !rawPattern.isEmpty else { continue }

            if matchesSingle(pattern: rawPattern, host: host) {
                if isNegated {
                    return false
                }
                matchedPositive = true
            }
        }

        return matchedPositive
    }

    private func matchesSingle(pattern: String, host: String) -> Bool {
        if pattern == "*" { return true }
        if !pattern.contains("*") && !pattern.contains("?") {
            return pattern == host
        }

        let regex = "^" + NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".") + "$"
        return host.range(of: regex, options: .regularExpression) != nil
    }
}
