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
