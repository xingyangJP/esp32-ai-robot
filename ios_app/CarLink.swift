import Foundation
import Network
import UIKit

/// Persistent TCP links to the car: commands on :4000, JPEG stream on :7000.
/// Holds both connections open (the patched firmware stops-and-holds on disconnect).
@MainActor
final class CarLink: ObservableObject {
    @Published var image: UIImage?
    @Published var lastFrameAt: Date?
    @Published var cmdConnected = false
    @Published var camConnected = false
    @Published var voltage: Double?          // latest CMD_POWER reply, if any
    @Published var voltageAt: Date?          // when `voltage` was last set (freshness + dedup for the sag detector)
    @Published var distance: Double?         // latest CMD_SONIC reply (cm); ~300 = no echo/clear
    @Published var distanceAt: Date?         // when `distance` was last updated (for staleness)
    // How much the camera view CHANGED vs the previous frame (mean abs diff of a 16x16 gray thumbnail,
    // 0..255). It's an odometry-free "am I actually moving?" cue: while driving forward, a LOW value
    // means the view is static = the car is pressed against something the sonar read straight through
    // (soft/thin/angled "no echo" obstacle). Default high so it never false-signals "stuck" before frames flow.
    @Published var frameMotion: Double = 255
    @Published var frameMotionAt: Date?
    private var prevGrayThumb: [UInt8]?
    private var cmdBuf = Data()
    private var sonicWindow: [Double] = []   // small median filter for the sonar
    private var sonicRaw: [(cm: Double, at: Date)] = []   // RAW reads (~1.5s) for low-obstacle near-hit counting

    /// Called on the MainActor each time the command socket becomes ready
    /// (initial connect AND every reconnect). Used to (re)start the video stream.
    var onCommandReady: (() -> Void)?

    private var cmd: NWConnection?
    private var cam: NWConnection?
    private var vFastTask: Task<Void, Never>?    // fast CMD_POWER poll while driving forward (voltage-sag stall detect)
    private let vFastHz = 20.0                   // CMD_POWER rate while the arbiter says we're driving forward
    private var wantConnection = false       // false after an explicit stop() — suppresses retries
    private var host = "192.168.1.123"
    private let cmdPort: UInt16 = 4000
    private let camPort: UInt16 = 7000
    private let q = DispatchQueue(label: "carlink")

    func connect(host: String) {
        self.host = host
        stop()
        wantConnection = true
        openCommand()
        openCamera()
    }

    func stop() {
        vFastTask?.cancel(); vFastTask = nil       // never leave the fast poll firing at a dead socket
        wantConnection = false
        cmd?.cancel(); cam?.cancel()
        cmd = nil; cam = nil
        cmdConnected = false; camConnected = false
    }

    // MARK: command channel (:4000)
    private func openCommand() {
        guard wantConnection else { return }
        cmd?.cancel()                        // never leak a previous connection
        let c = NWConnection(host: .init(host), port: .init(rawValue: cmdPort)!, using: .tcp)
        cmd = c
        c.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.cmd === c else { return }   // ignore stale connections
                switch state {
                case .ready:
                    self.cmdConnected = true
                    self.readCmdReplies(c)
                    self.onCommandReady?()                        // (re)start video once ready
                case .failed, .cancelled:
                    self.cmdConnected = false
                    if case .cancelled = state { return }
                    self.retryCommand()
                default: break
                }
            }
        }
        c.start(queue: q)
    }

    private func retryCommand() {
        guard wantConnection else { return }
        q.asyncAfter(deadline: .now() + 1) { [weak self] in
            Task { @MainActor in guard let self, self.wantConnection else { return }; self.openCommand() }
        }
    }

    func send(_ line: String) {
        guard let c = cmd, cmdConnected else { return }
        c.send(content: (line + "\n").data(using: .utf8),
               completion: .contentProcessed { _ in })
    }

    /// Poll CMD_POWER fast (vFastHz) so the voltage-sag detector can average out the 50Hz PWM ripple
    /// while driving forward. send() no-ops on a dead socket, so a stray burst is harmless.
    func startFastVoltagePoll() {
        guard vFastTask == nil else { return }
        vFastTask = Task { [weak self] in
            let hz = self?.vFastHz ?? 20.0
            let tick = UInt64(1_000_000_000 / hz)
            while !Task.isCancelled {
                await MainActor.run { self?.send(Dispatcher.powerQuery()) }
                try? await Task.sleep(nanoseconds: tick)
            }
        }
    }
    func stopFastVoltagePoll() { vFastTask?.cancel(); vFastTask = nil }

    /// How many RAW forward sonar reads within `window` were closer than `cm`. Uses the raw stream, NOT
    /// the median `distance` (which smooths away the intermittent near flickers a low obstacle produces).
    func nearCount(closerThan cm: Double, within window: TimeInterval) -> Int {
        let cutoff = Date().addingTimeInterval(-window)
        return sonicRaw.reduce(0) { $0 + (($1.at >= cutoff && $1.cm < cm) ? 1 : 0) }
    }

    // Read replies on the command socket (CMD_POWER voltage + CMD_SONIC distance).
    private func readCmdReplies(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 512) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let d = data, !d.isEmpty { Task { @MainActor in self.parseReplies(d) } }
            if error == nil && !isComplete { self.readCmdReplies(c) }
        }
    }

    private func parseReplies(_ d: Data) {
        cmdBuf.append(d)
        while let nl = cmdBuf.firstIndex(of: 0x0A) {
            let line = cmdBuf[cmdBuf.startIndex..<nl]
            cmdBuf.removeSubrange(cmdBuf.startIndex...nl)
            guard let s = String(data: line, encoding: .utf8) else { continue }
            let parts = s.split(separator: "#")
            if parts.count >= 2, parts[0] == "CMD_POWER", let v = Double(parts[1]) { voltage = v; voltageAt = Date() }
            else if parts.count >= 2, parts[0] == "CMD_SONIC", let cm = Double(parts[1]), cm >= 3 {
                // reject sub-3cm glitch; publish the median of the last up-to-3 readings
                sonicWindow.append(cm); if sonicWindow.count > 3 { sonicWindow.removeFirst() }
                distance = sonicWindow.sorted()[sonicWindow.count / 2]
                let now = Date(); distanceAt = now
                sonicRaw.append((cm, now)); sonicRaw.removeAll { now.timeIntervalSince($0.at) > 1.5 }
            }
        }
    }

    // MARK: camera channel (:7000) — 4-byte LE length + JPEG
    private func openCamera() {
        guard wantConnection else { return }
        cam?.cancel()
        let c = NWConnection(host: .init(host), port: .init(rawValue: camPort)!, using: .tcp)
        cam = c
        c.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.cam === c else { return }
                switch state {
                case .ready:
                    self.camConnected = true
                    self.readFrame(on: c)
                case .failed, .cancelled:
                    self.camConnected = false
                    if case .cancelled = state { return }
                    self.retryCamera()
                default: break
                }
            }
        }
        c.start(queue: q)
    }

    private func retryCamera() {
        guard wantConnection else { return }
        q.asyncAfter(deadline: .now() + 1) { [weak self] in
            Task { @MainActor in guard let self, self.wantConnection else { return }; self.openCamera() }
        }
    }

    private func readExact(_ n: Int, on c: NWConnection, acc: Data = Data(),
                           done: @escaping (Data?) -> Void) {
        let need = n - acc.count
        c.receive(minimumIncompleteLength: need, maximumLength: need) { data, _, isComplete, error in
            var a = acc
            if let d = data { a.append(d) }
            if error != nil { done(nil); return }
            if a.count >= n { done(a) }
            else if isComplete { done(nil) }
            else { self.readExact(n, on: c, acc: a, done: done) }
        }
    }

    /// Downscale a frame to an n×n grayscale thumbnail (default 16×16) for cheap frame-to-frame motion.
    private static func grayThumb(_ img: UIImage, n: Int = 16) -> [UInt8]? {
        guard let cg = img.cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: n * n)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        return px
    }

    private func readFrame(on c: NWConnection) {
        readExact(4, on: c) { [weak self] hdr in
            guard let self, let hdr, hdr.count == 4 else { return }
            let len = Int(UInt32(hdr[0]) | UInt32(hdr[1]) << 8 |
                          UInt32(hdr[2]) << 16 | UInt32(hdr[3]) << 24)
            guard len > 0, len < 4_000_000 else { return }
            self.readExact(len, on: c) { body in
                guard let body else { return }
                if let img = UIImage(data: body) {
                    let thumb = CarLink.grayThumb(img)        // computed here (off the main actor — this runs on `q`)
                    Task { @MainActor in
                        self.image = img; self.lastFrameAt = Date()
                        if let t = thumb {                    // mean abs diff vs the previous frame -> frameMotion
                            if let p = self.prevGrayThumb, p.count == t.count {
                                var sum = 0
                                for i in 0..<t.count { sum += abs(Int(t[i]) - Int(p[i])) }
                                self.frameMotion = Double(sum) / Double(t.count)
                                self.frameMotionAt = Date()
                            }
                            self.prevGrayThumb = t
                        }
                    }
                }
                Task { @MainActor in self.readFrame(on: c) }  // next frame
            }
        }
    }
}
