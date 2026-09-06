import Foundation

/// Where the dashboard lives.
///
/// The app ships no server of its own — it is a front end for a copy of
/// aniGamerPlus running somewhere else, so its address is the one thing it has
/// to be told before it can do anything at all. There is a default so a fresh
/// install opens on something, and it is editable because the same app is
/// useful pointed at a machine on the local network.
enum ServerAddress {

    private static let key = "agp.server.url"

    /// The public instance. Anything else — `192.168.1.10:5000`, a tunnel, a
    /// different port — is typed into settings.
    static let fallback = URL(string: "https://agpp.avianjay.sbs")!

    /// True once the owner has actually chosen an address, as opposed to
    /// running on the built-in default.
    static var isConfigured: Bool {
        stored != nil
    }

    static var current: URL {
        get { stored ?? fallback }
        set { UserDefaults.standard.set(newValue.absoluteString, forKey: key) }
    }

    private static var stored: URL? {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        return normalise(raw)
    }

    /// Accepts what a person actually types. `192.168.1.10:5000` is a host and a
    /// port to everyone except `URL`, which reads the address as a scheme and
    /// the port as the path, so the scheme is filled in before parsing.
    static func normalise(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let qualified = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: qualified), let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
