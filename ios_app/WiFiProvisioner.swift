import Foundation
import Network
import NetworkExtension

/// In-app WiFi provisioning client (see WIFI_PROVISIONING_DESIGN.md).
/// Joins the car's setup SoftAP (`RobotBrain-setup`) via NEHotspotConfiguration, then talks to the
/// firmware provisioning CMDs over TCP 192.168.4.1:4000 (SSID/pass base64 — the CMD protocol is
/// '#'-delimited and WiFi secrets can contain '#'). joinOnce=true, so iOS auto-returns to the home
/// Wi-Fi when the car AP drops (the car reboots into STA on success) — no need for the home password.
@MainActor
final class WiFiProvisioner: ObservableObject {
    static let carAPSSID = "RobotBrain-setup"     // must match PROV_AP_SSID in firmware wifi_provision.h
    static let carAPPass = "robotbrain"           // must match PROV_AP_PASS
    static let host = "192.168.4.1"                // car's SoftAP address during provisioning
    static let mdnsHost = "robotbrain.local"       // car on the normal network (Bonjour)
    static let port: UInt16 = 4000

    struct AP: Identifiable { let id = UUID(); let ssid: String; let rssi: Int; let open: Bool }

    /// Ask iOS to join the car's setup AP. Returns nil on success, else a user-facing error string.
    /// `alreadyAssociated` counts as success. If the entitlement/capability is missing the system
    /// reports an error and the caller falls back to manual "join it in Settings" instructions.
    func joinCarAP() async -> String? {
        let cfg = NEHotspotConfiguration(ssid: Self.carAPSSID, passphrase: Self.carAPPass, isWEP: false)
        cfg.joinOnce = true
        return await withCheckedContinuation { cont in
            NEHotspotConfigurationManager.shared.apply(cfg) { error in
                if let e = error as NSError?,
                   e.code != NEHotspotConfigurationError.alreadyAssociated.rawValue {
                    cont.resume(returning: e.localizedDescription)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: firmware provisioning CMDs (one-shot request/response to 192.168.4.1:4000)
    func scan() async -> [AP] {
        guard let r = await request("CMD_WIFI_SCAN", timeout: 8),
              let hash = r.firstIndex(of: "#") else { return [] }
        let b64 = String(r[r.index(after: hash)...])
        guard let data = Data(base64Encoded: b64), let s = String(data: data, encoding: .utf8) else { return [] }
        var seen = Set<String>(); var out: [AP] = []
        for line in s.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 3 else { continue }
            let ssid = String(f[0]); if ssid.isEmpty || seen.contains(ssid) { continue }
            seen.insert(ssid)
            out.append(AP(ssid: ssid, rssi: Int(f[1]) ?? -100, open: f[2] == "open"))
        }
        return out.sorted { $0.rssi > $1.rssi }
    }

    /// Send new creds; firmware saves to NVS + reboots into STA. Returns "accepted"/error.
    /// Trim whitespace/newlines that keyboards & paste silently append — a leading/trailing
    /// space in a correct-looking password is a classic "the password is right but it won't join".
    func setCreds(ssid: String, pass: String) async -> String? {
        let s = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = pass.trimmingCharacters(in: .whitespacesAndNewlines)
        let bs = Data(s.utf8).base64EncodedString()
        let bp = Data(p.utf8).base64EncodedString()
        guard let r = await request("CMD_WIFI_SET#\(bs)#\(bp)"), let h = r.firstIndex(of: "#") else { return nil }
        return String(r[r.index(after: h)...])
    }

    /// Last provisioning outcome held by the firmware (SoftAP only): "idle" | "switching:<ssid>"
    /// | "fail:auth" (wrong password) | "fail:no_ap" (wrong band/channel/hidden) | "fail:<n>".
    func status() async -> String? {
        guard let r = await request("CMD_WIFI_STATUS"), let h = r.firstIndex(of: "#") else { return nil }
        return String(r[r.index(after: h)...])
    }

    /// Ask iOS to drop the car's setup AP so the phone returns to its previous (home) WiFi promptly.
    func leaveCarAP() {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: Self.carAPSSID)
    }

    /// After the car reboots into STA, confirm it actually joined by reaching it on the network.
    /// Returns true once `host:4000` answers CMD_POWER within `timeout`. LAN/mDNS name by default.
    func probeCar(host: String = "robotbrain.local", timeout: TimeInterval = 40) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await request("CMD_POWER", host: host, timeout: 3) != nil { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    private func request(_ cmd: String, host: String = "192.168.4.1", timeout: TimeInterval = 6) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let conn = NWConnection(host: .init(host), port: .init(rawValue: Self.port)!, using: .tcp)
            var buf = Data(); var done = false
            func finish(_ s: String?) {
                if done { return }; done = true; conn.cancel(); cont.resume(returning: s)
            }
            func pump() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
                    if let d = data { buf.append(d) }
                    if let s = String(data: buf, encoding: .utf8), s.contains("\n") {
                        finish(s.trimmingCharacters(in: .whitespacesAndNewlines)); return
                    }
                    if error != nil || isComplete {
                        finish(String(data: buf, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines))
                        return
                    }
                    pump()
                }
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    conn.send(content: (cmd + "\n").data(using: .utf8), completion: .contentProcessed { _ in })
                    pump()
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}
