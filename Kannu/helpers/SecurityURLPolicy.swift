import Foundation

enum SecurityURLPolicy {
    static func isAllowedWebhookURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else { return false }

        guard scheme == "https" else { return false }
        guard !host.isEmpty else { return false }
        guard !isLoopback(host) && !isPrivateIPv4(host) else { return false }
        return true
    }

    static func isAllowedModelEndpoint(_ raw: String) -> Bool {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else { return false }

        guard scheme == "http" || scheme == "https" else { return false }
        return isLoopback(host)
    }

    static func isAllowedNtfyServerURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else { return false }
        guard scheme == "https" else { return false }
        guard !isPrivateIPv4(host) else { return false }
        return true
    }

    /// The cloud-session relay (docs/CLOUD-SESSIONS.md). Kannu streams from it and cloud sessions
    /// post to it, so it must be a public HTTPS server both can reach, written the one way the relay
    /// script also accepts: an origin and an optional path, with no credentials, query or fragment.
    /// Loopback, private and link-local addresses, `.local` names and single-label hosts are
    /// refused: a cloud session could never reach them, and they would aim Kannu's stream at this
    /// Mac's own network.
    static func isAllowedCloudRelayServerURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)*/?$"#,
                            options: .regularExpression) != nil,
              let host = URL(string: trimmed)?.host?.lowercased(),
              host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              !isLoopback(host), !isPrivateIPv4(host), !isLinkLocalOrReservedIPv4(host)
        else { return false }
        return true
    }

    private static func isLinkLocalOrReservedIPv4(_ host: String) -> Bool {
        let comps = host.split(separator: ".")
        guard comps.count == 4, let a = Int(comps[0]), let b = Int(comps[1]) else { return false }
        return a == 0 || (a == 169 && b == 254) || a >= 224
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let comps = host.split(separator: ".")
        guard comps.count == 4, let a = Int(comps[0]), let b = Int(comps[1]) else { return false }
        if a == 10 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 127 { return true }
        return false
    }
}
