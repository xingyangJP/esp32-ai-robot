import Foundation
import Network

/// Finds the car on the LAN via Bonjour/mDNS (_robotbrain._tcp), so the app never
/// needs a hand-typed DHCP IP. The firmware advertises hostname "robotbrain"
/// → reachable at robotbrain.local. See DESIGN.md 追補 v1.1.
@MainActor
final class Discovery: ObservableObject {
    @Published var status = "discovery.idle"   // localization key
    private var browser: NWBrowser?

    /// Browse for the car; calls onFound(host) with e.g. "robotbrain.local".
    func find(onFound: @escaping (String) -> Void) {
        stop()
        status = "discovery.searching"
        let b = NWBrowser(for: .bonjour(type: "_robotbrain._tcp", domain: nil), using: .init())
        browser = b
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, let first = results.first else { return }
            var host = "robotbrain.local"
            if case let .service(name, _, _, _) = first.endpoint, !name.isEmpty { host = name + ".local" }
            Task { @MainActor in
                guard self.browser != nil else { return }
                self.status = "discovery.found"
                onFound(host)
                self.stop()
            }
        }
        b.start(queue: .main)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                guard let self, self.browser != nil else { return }   // still searching → gave up
                self.status = "discovery.notfound"
                self.stop()
            }
        }
    }

    func stop() { browser?.cancel(); browser = nil }
}
