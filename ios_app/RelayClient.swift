import Foundation
import UIKit

/// Snapshot of the bridge's status (decoded from the relay `status` JSON).
struct RemoteStatus {
    var cmd = false          // bridge <-> car command link up
    var cam = false          // bridge <-> car camera link up
    var goal = ""
    var estop = false
    var dryRun = true
    var voltage: Double?
    var distance: Double?    // forward distance (cm) from the bridge; nil = unknown/stale
    var safety: String?      // stop reason from the bridge, or nil
    var taskState = "idle"
    var observation = ""
    var pan: Int?            // nil = bridge didn't report head aim -> don't overwrite local
    var tilt: Int?
}

/// Thin remote client for REMOTE (cloud) mode. One WSS to the Cloud Run relay; the
/// home bridge runs the brain. The phone sends semantic control (goal/estop/arm/
/// dryrun/speedcap/look/face/leds) + a ~2 Hz heartbeat, and renders the preview
/// (binary JPEG) + status the bridge sends back. Keys use the REMOTE.md canonical
/// `t` (the bridge also accepts `type`). Auth: dev room now; Firebase token later.
@MainActor
final class RelayClient: ObservableObject {
    @Published var connected = false      // WSS up (hello acknowledged)
    @Published var peerUp = false         // bridge present on the relay

    var onImage: ((UIImage) -> Void)?
    var onStatus: ((RemoteStatus) -> Void)?
    var onConn: ((Bool) -> Void)?         // WSS connected changed

    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var url: URL?
    private var room = "dev"
    // A provider (not a stored string) so every (re)connect carries a FRESH Firebase
    // ID token — they expire ~1h and the relay only checks it at the hello. Returns
    // "" for the AUTH_DISABLED dev room.
    private var tokenProvider: (() async -> String)?
    private var want = false              // false after disconnect() — suppresses retries
    private var outbox: [String] = []     // control sent before the socket was ready
    private var generation = 0            // ignore callbacks from superseded sockets

    func configure(url urlString: String, room: String, tokenProvider: @escaping () async -> String) {
        self.url = URL(string: urlString)
        self.room = room
        self.tokenProvider = tokenProvider
    }

    func connect() {
        guard let url else { return }
        want = true
        open(url)
    }

    func disconnect() {
        want = false
        generation += 1                   // invalidate in-flight receive callbacks
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
        peerUp = false
        outbox.removeAll()                // never replay a torn-down session's control
    }

    // MARK: socket lifecycle
    private func open(_ url: URL) {
        guard want else { return }
        generation += 1
        let gen = generation
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive(t, gen)
        // Fetch a fresh token, then send the hello. Treat a successful send as
        // "connected". Any newer generation (reconnect/disconnect) aborts this.
        Task { [weak self] in
            guard let self else { return }
            let tok = await self.tokenProvider?() ?? ""
            guard gen == self.generation else { return }
            t.send(.string(self.json(["role": "phone", "token": tok, "room": self.room]))) { [weak self] err in
                Task { @MainActor in
                    guard let self, gen == self.generation else { return }
                    if err == nil {
                        self.connected = true
                        self.onConn?(true)
                        self.flushOutbox()
                    } else {
                        self.drop(gen)
                    }
                }
            }
        }
    }

    private func drop(_ gen: Int) {
        guard gen == self.generation else { return }
        connected = false
        peerUp = false
        onConn?(false)
        task = nil
        guard want, let url else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.want, gen == self.generation else { return }
            self.open(url)
        }
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .failure:
                    self.drop(gen)
                case .success(let msg):
                    switch msg {
                    case .string(let s): self.handleText(s)
                    case .data(let d): if let img = UIImage(data: d) { self.onImage?(img) }
                    @unknown default: break
                    }
                    self.receive(t, gen)
                }
            }
        }
    }

    private func handleText(_ s: String) {
        guard let data = s.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch obj["type"] as? String {
        case "ready":
            peerUp = (obj["peer"] as? Bool) ?? peerUp
        case "peer":
            if (obj["role"] as? String) == "bridge" { peerUp = (obj["up"] as? Bool) ?? false }
        case "status":
            var st = RemoteStatus()
            st.cmd = (obj["cmd"] as? Bool) ?? false
            st.cam = (obj["cam"] as? Bool) ?? false
            st.goal = (obj["goal"] as? String) ?? ""
            st.estop = (obj["estop"] as? Bool) ?? false
            st.dryRun = (obj["dry_run"] as? Bool) ?? true
            st.voltage = obj["voltage"] as? Double
            st.distance = obj["distance"] as? Double
            st.safety = obj["safety"] as? String
            st.taskState = (obj["task_state"] as? String) ?? "idle"
            st.observation = (obj["observation"] as? String) ?? ""
            st.pan = obj["pan"] as? Int
            st.tilt = obj["tilt"] as? Int
            onStatus?(st)
        default:
            break
        }
    }

    // MARK: control (semantic; the bridge lowers to CMD_)
    func sendGoal(_ s: String) { send(["t": "goal", "text": s]) }
    func estop()               { send(["t": "estop", "on": true]) }
    func clearEstop()          { send(["t": "estop", "on": false]) }
    func setDryRun(_ on: Bool) { send(["t": "dryrun", "on": on]) }
    func setSpeedCap(_ v: Int) { send(["t": "speedcap", "v": v]) }
    func look(pan: Int, tilt: Int) { send(["t": "look", "pan": pan, "tilt": tilt]) }
    func face(_ mode: Int)     { send(["t": "face", "mode": mode]) }
    func leds(_ mode: Int)     { send(["t": "leds", "mode": mode]) }
    func drive(throttle: Double, steer: Double, durationMs: Int) {   // manual remote drive
        send(["t": "drive", "throttle": throttle, "steer": steer, "duration_ms": durationMs])
    }

    /// Liveness ping — meaningless if stale, so NEVER queue it; drop when disconnected.
    func heartbeat() {
        guard connected, let t = task else { return }
        t.send(.string(json(["t": "heartbeat"]))) { _ in }
    }

    private func send(_ obj: [String: Any]) {
        let line = json(obj)
        guard connected, let t = task else {
            if outbox.count >= 64 { outbox.removeFirst() }   // bound growth during an outage
            outbox.append(line)
            return
        }
        t.send(.string(line)) { _ in }
    }

    private func flushOutbox() {
        guard connected, let t = task else { return }
        let pending = outbox
        outbox.removeAll()
        for line in pending { t.send(.string(line)) { _ in } }
    }

    private func json(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}
