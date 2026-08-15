import Foundation
import Combine
import UIKit

/// Connection mode. LAN = fat client (brain + arbiter run on the phone over TCP).
/// Remote = thin client (the home bridge runs the brain; the phone sends semantic
/// control + a heartbeat over WSS and renders the bridge's preview + status).
enum LinkMode: String { case lan, remote }

/// Control mode, orthogonal to LinkMode. AI = the VLM drives autonomously.
/// Manual = the human drives via the on-screen pad; the VLM loop is off but the
/// arbiter/heartbeat/deadman/dry-run/speed-cap/STOP all still apply.
enum ControlMode: String { case ai, manual }

/// Ties the pieces together and runs the control loop.
/// LAN priority every heartbeat tick: SAFETY(stop) > e-stop > dry-run(stop) > pulse-drive > hold.
@MainActor
final class RobotController: ObservableObject {
    // persisted settings (UserDefaults)
    @Published var carIP: String   { didSet { save("carIP", carIP) } }
    @Published var apiKey: String  { didSet { save("apiKey", apiKey) } }
    @Published var model: String   { didSet { save("model", model) } }
    @Published var lang: String    { didSet { save("lang", lang); speech.langCode = voiceCode } }
    @Published var speedCap: Int    { didSet { UserDefaults.standard.set(speedCap, forKey: "speedCap")
                                               if linkMode == .remote { relay.setSpeedCap(speedCap) } } }
    @Published var controlMode: ControlMode { didSet {
        UserDefaults.standard.set(controlMode.rawValue, forKey: "controlMode")
        if oldValue != controlMode { onControlModeChanged() }
    } }

    // connection mode + remote endpoint (persisted)
    @Published var linkMode: LinkMode { didSet {
        UserDefaults.standard.set(linkMode.rawValue, forKey: "linkMode")
        if oldValue != linkMode && running { switchMode(from: oldValue) }
    } }
    /// The deployed Cloud Run relay — a fixed endpoint baked into the app, not a
    /// user-facing setting (change here to point at a local dev relay).
    static let relayURL = "wss://YOUR-RELAY.a.run.app"

    // servo calibration (this build: servo1=tilt, servo2=pan — see DESIGN.md §4)
    @Published var servoSwap: Bool  { didSet { UserDefaults.standard.set(servoSwap, forKey: "servoSwap") } }
    @Published var panNeutral: Int  { didSet { UserDefaults.standard.set(panNeutral, forKey: "panNeutral") } }
    @Published var tiltNeutral: Int { didSet { UserDefaults.standard.set(tiltNeutral, forKey: "tiltNeutral") } }
    // this car's per-unit corrections (default inert): pan-servo direction, drive straightness
    @Published var panInvert: Bool { didSet {
        UserDefaults.standard.set(panInvert, forKey: "panInvert")
        if linkMode == .lan { aim(pan: curPan, tilt: curTilt) }   // re-assert pose so the flip is visible now
    } }
    @Published var motorTrim: Double { didSet { UserDefaults.standard.set(motorTrim, forKey: "motorTrim") } }

    // NOT persisted: dry-run must return to ON every launch (safety, FR-39/FR-47).
    // `applyingRemote` suppresses the re-send when we're mirroring the bridge's own echo.
    @Published var dryRun = true    { didSet {
        if linkMode == .remote && !applyingRemote { relay.setDryRun(dryRun); markLocalIntent() }
    } }
    private var applyingRemote = false
    // Operator intent protection against the lagging ~2 Hz status echo (Remote):
    // a locally-set STOP is latched, and STOP/arm/goal survive a short window so a
    // stale status frame can't visually revert them right after the operator acted.
    private var estopLatched = false
    private var localIntentUntil = Date.distantPast
    private func markLocalIntent() { localIntentUntil = Date().addingTimeInterval(1.2) }

    // live state
    @Published var goal = ""
    @Published var running = false
    @Published var estop = false
    @Published var teleopDriving = false   // a direct teleop pulse is currently driving (keeps STOP shown even with no goal)
    @Published var report = ""
    @Published var taskState = "idle"
    @Published var statusKey = "status.idle"
    @Published var curPan = 90        // current semantic aim (for telemetry)
    @Published var curTilt = 90

    // display state, republished so the UI is mode-agnostic (mirrors CarLink in LAN,
    // the bridge's status/preview in Remote).
    @Published var image: UIImage?
    @Published var cmdConnected = false
    @Published var camConnected = false
    @Published var voltage: Double?
    @Published var distance: Double?     // forward distance (cm), mirrored from CarLink (LAN) / relay (Remote); nil = unknown

    let car = CarLink()
    let relay = RelayClient()
    let auth = AuthStore()          // Firebase identity (REMOTE pairing); LAN ignores it
    let speech = Speech()
    let discovery = Discovery()
    private var cancellables = Set<AnyCancellable>()

    private func save(_ k: String, _ v: String) { UserDefaults.standard.set(v, forKey: k) }

    init() {
        let d = UserDefaults.standard
        carIP = d.string(forKey: "carIP") ?? "robotbrain.local"   // mDNS name — survives DHCP changes
        apiKey = d.string(forKey: "apiKey") ?? ""
        model = d.string(forKey: "model") ?? "gpt-4o-mini"
        lang = d.string(forKey: "lang") ?? "auto"
        speedCap = d.object(forKey: "speedCap") as? Int ?? 2000
        linkMode = LinkMode(rawValue: d.string(forKey: "linkMode") ?? "lan") ?? .lan
        controlMode = ControlMode(rawValue: d.string(forKey: "controlMode") ?? "ai") ?? .ai
        servoSwap = d.object(forKey: "servoSwap") as? Bool ?? true
        panNeutral = d.object(forKey: "panNeutral") as? Int ?? 90
        // Tilt neutral (raw servo angle that = LEVEL). Measured on the real car 2026-07-26 by sweeping
        // the raw tilt servo + watching the camera: raw ~10=down, ~95=level, ~170=up. The old default
        // 18 anchored "level" at the floor, so the head could only look down and NEVER up, AND during
        // driving the sonar pointed at the floor (~raw 11) instead of ahead — likely a cause of hitting
        // head-height walls. Migrate the stale 18 to 95 once (tiltCalV=2).
        if d.integer(forKey: "tiltCalV") < 3 {
            // Re-assert level=95 (v3): the old tilt slider was capped at 0...90 so dragging it could
            // corrupt tiltNeutral below the true level (~95). Overwrite once; the fixed 0...180 slider
            // now lets the user fine-tune from here.
            tiltNeutral = 95; d.set(95, forKey: "tiltNeutral"); d.set(3, forKey: "tiltCalV")
        } else {
            tiltNeutral = d.object(forKey: "tiltNeutral") as? Int ?? 95
        }
        panInvert = d.object(forKey: "panInvert") as? Bool ?? false
        motorTrim = d.object(forKey: "motorTrim") as? Double ?? 0
        speech.langCode = voiceCode
        // (re)start the video stream whenever the command socket becomes ready (LAN).
        car.onCommandReady = { [weak self] in
            self?.car.send(Dispatcher.video(true))
            self?.lastLedKey = ""            // repaint the current LED cue after a (re)connect
            self?.lastLookCmd = ["", ""]     // re-assert the head pose after a (re)connect
            self?.centerForDrive()           // start from a known forward pose (head guards travel)
        }
        wireTransports()
    }

    /// Mirror the active transport's display state into the controller's @Published.
    private func wireTransports() {
        // LAN transport (CarLink) -> display, only while in LAN mode.
        car.$image.sink        { [weak self] v in if self?.linkMode == .lan { self?.image = v } }.store(in: &cancellables)
        car.$cmdConnected.sink  { [weak self] v in if self?.linkMode == .lan { self?.cmdConnected = v } }.store(in: &cancellables)
        car.$camConnected.sink  { [weak self] v in if self?.linkMode == .lan { self?.camConnected = v } }.store(in: &cancellables)
        car.$voltage.sink       { [weak self] v in if self?.linkMode == .lan { self?.voltage = v } }.store(in: &cancellables)
        car.$distance.sink      { [weak self] v in if self?.linkMode == .lan { self?.distance = v } }.store(in: &cancellables)
        // Remote transport (RelayClient) -> display, only while in Remote mode.
        relay.onImage = { [weak self] img in
            guard let self, self.linkMode == .remote else { return }
            self.image = img
        }
        relay.onStatus = { [weak self] s in
            guard let self, self.linkMode == .remote else { return }
            self.applyingRemote = true          // mirror bridge state without echoing it back
            self.cmdConnected = self.relay.connected && s.cmd
            self.camConnected = s.cam
            self.voltage = s.voltage
            self.distance = s.distance      // bridge only publishes fresh values; nil = unknown/stale
            self.report = s.observation
            self.taskState = s.taskState
            if let p = s.pan { self.curPan = p }        // only when the bridge reports aim
            if let t = s.tilt { self.curTilt = t }
            // Don't let a stale echo revert what the operator just set.
            if Date() >= self.localIntentUntil {
                self.goal = s.goal
                self.dryRun = s.dryRun
            }
            self.estop = s.estop || self.estopLatched
            self.statusKey = self.remoteStatusKey(s)
            self.applyingRemote = false
        }
        relay.onConn = { [weak self] up in
            guard let self, self.linkMode == .remote else { return }
            if !up { self.cmdConnected = false; self.camConnected = false; self.statusKey = "status.remoteLinkDown" }
        }
    }

    private func remoteStatusKey(_ s: RemoteStatus) -> String {
        if !relay.connected { return "status.remoteLinkDown" }
        if !relay.peerUp { return "status.remoteConnecting" }
        if s.estop || estopLatched { return "status.estop" }
        if let sf = s.safety {
            switch sf {
            case "relay link down":  return "status.remoteLinkDown"
            case "operator link lost": return "safety.operatorLinkLost"
            case "command-link down": return "safety.linkDown"
            case "vision stale (blind)": return "safety.visionStale"
            default:
                if sf.hasPrefix("low battery") { return "safety.lowBattery" }
                if sf.hasPrefix("deadman") && goal.isEmpty { return "status.hold" }
                return "status.hold"
            }
        }
        return s.taskState == "idle" ? "status.hold" : "status.driving"
    }

    // language resolution
    var resolvedLang: String {
        if lang == "auto" {
            return Locale.current.language.languageCode?.identifier == "ja" ? "ja" : "en"
        }
        return lang
    }
    var uiLocale: Locale { Locale(identifier: resolvedLang) }
    var voiceCode: String { resolvedLang == "ja" ? "ja-JP" : "en-US" }

    // servo channel resolution (see DESIGN.md §4.2)
    var panChannel: Int  { servoSwap ? 1 : 0 }
    var tiltChannel: Int { servoSwap ? 0 : 1 }

    private var loop: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var intent = Intent.hold
    private var pulseUntil = Date.distantPast
    private var lastIntentAt = Date.distantPast
    private var lastPowerPoll = Date.distantPast
    private var lastSonicPoll = Date.distantPast
    private var lastDecision = Date.distantPast
    private var decideInFlight = false
    private var decisionEpoch = 0        // bump to discard any in-flight VLM decision (STOP/switch/new goal)
    private var memory: [String] = []

    // --- Arbiter-level collision escape (evaluated every ~100ms in run(), NOT at the slow VLM rate) ---
    // The old decision-rate reflex reversed in tiny 220ms twitches every ~1.5-3s and released the
    // instant distance passed 22cm, so the model immediately re-drove forward -> the car pinned itself
    // against a wall ("stops, re-advances, oscillates in place"). The escape below owns getting unstuck:
    // a LATCHED reverse (hysteresis — back up until the path is decisively clear) then an in-place pivot
    // to change heading, so it never waits on a Vision decision and never releases prematurely.
    private enum EscapePhase { case none, reversing, pivoting }
    private var escapePhase: EscapePhase = .none
    private var escapeStart = Date.distantPast
    private var escapeSign = 1.0            // curve/pivot toward where the model was trying to go
    private let escapeEngageCm = 25.0       // engage when the model pushes forward and the wall is closer than this
    private let escapeClearCm  = 40.0       // reverse until the path is farther than this (hysteresis vs re-forward)
    private let escapeMaxReverseMs = 1400.0 // cap the blind reverse (no rear sensor)
    private let escapeMinReverseMs = 700.0  // ALWAYS back off at least this long — a frame-stuck escape hits a no-echo
                                            // obstacle, so the sonar reads "clear" immediately and would else skip the reverse.
    private let escapePivotMs = 650.0       // in-place turn to break the head-on approach
    // Frame-stuck ("hit a no-echo obstacle") detection: while commanding forward, if the camera view
    // stops changing (`car.frameMotion` low) the car is pressed against a soft/thin/angled thing the
    // sonar read straight through -> force the escape to back off. Sonar-independent. Tune on the car.
    private var lowMotionSince = Date.distantPast
    private let motionStuckMin = 5.0        // frameMotion (16x16 gray MAD, 0..255) below this = view static
    private let stuckMs = 1200.0            // ...for this long while driving forward = stuck -> back off
    // Low-obstacle best-effort (owner-chosen, zero-cost): the forward sonar sees a low object only
    // INTERMITTENTLY (flickers near<->300 as the down-angled beam grazes it — measured on-car), so the
    // median `distance` smooths it away. Count RAW near reads instead and require >= lowObstacleHits in the
    // window (rejects single-spike noise) -> reverse (same escape as frame-stuck). Catches the low obstacles
    // the sonar DOES occasionally see; ones fully under the beam still can't be caught (hardware ceiling).
    private let lowObstacleCm = 30.0
    private let lowObstacleHits = 2
    private let lowObstacleWindowMs = 1000.0
    // --- Voltage-sag stall reflex (dark-proof, camera-free 3rd backstop; fuses with frame-stuck). MEASURE-FIRST:
    // ships log-only (sagArmed=false) so the [SAG] d= line can be read on-car before actuation is enabled. A
    // sustained forward LOAD that pulls the pack a delta below its light-load baseline = pressed on an obstacle. ---
    private var sagBaseline: Double = 0            // self-calibrating LIGHT-LOAD pack voltage (EMA of between-pulse reads)
    private var sagBaselineN = 0                   // light-load samples folded so far (warm-up gate)
    private var sagLoaded: [(v: Double, at: Date)] = []   // loaded samples past accel-skip in the current forward run
    private var sagLastVAt = Date.distantPast      // last voltageAt consumed (dedup; loaded/baseline mutually exclusive per tick)
    private var sagForwardRunStart = Date.distantPast
    private var sagLastFwdAt = Date.distantPast    // last tick commandingForward was true (bridges inter-pulse gaps)
    private var sagStallSince = Date.distantPast   // when sustained over-threshold sag began (.distantPast = not sagging)
    private var sagCooldownUntil = Date.distantPast// suppress re-arm right after a fire (anti-livelock)
    private var sagLastLogAt = Date.distantPast    // throttle the [SAG] calibration log (~3Hz)
    private var sagArmed = false                   // MEASURE-FIRST: false = log only. Flip true after [SAG] confirms separation.
    private let sagV = 0.30                        // TRIGGER delta (baseline - loadedMean), volts. Calibrate from the [SAG] d= log.
    private let sagMinLoadedSamples = 12           // need >= this many averaged loaded samples before trusting a delta (beats PWM ripple)
    private let sagLoadWindowMs = 1200.0           // rolling window the loaded mean is computed over (~2-3 pulses)
    private let sagRunGapMs = 1200.0               // forward gaps shorter than this DON'T reset the run (corridor hops = one run)
    private let sagAccelSkipMs = 200.0             // ignore each run's first ~200ms (accel inrush mimics a stall)
    private let sagSustainMs = 900.0               // delta must persist this long while driving before firing
    private let sagBaselineAlpha = 0.02            // slow EMA (tracks discharge over minutes, never a <1s stall)
    private let sagBaselineInitSamples = 3         // don't trust the delta until this many light-load samples exist
    private let sagCooldownMs = 2000.0             // covers reverse+pivot+fresh run start before re-arming

    // --- Deterministic search loop (FR-54..56): while the VLM still reports "searching", the HOST
    // sequences SCAN (sweep the head across an arc so the VLM can judge "is the goal here?") ->
    // RELOCATE (drive to a NEW spot) -> repeat, so exploration never depends on the VLM reliably
    // choosing to move. The instant the VLM reports "approaching"/"done" the host yields and the VLM
    // drives the approach. Subordinate to collision escape + every hard safety block (SAFETY > search).
    private enum SearchPhase { case scan, relocate, corridor }
    private var searchPhase: SearchPhase = .scan
    private var scanIndex = 0
    // Corridor-follow (R2): after DRIVING forward into open space, keep advancing a few hops WITHOUT
    // re-running the full head sweep. A short hop barely changes the ~180° view, so re-scanning every
    // hop just re-searches the same spot (owner: "180deg scan -> move -> re-scan is weird"). Re-scan
    // only when the path closes / after maxCorridorHops. The VLM still analyzes each forward frame
    // while corridoring, so a goal ahead is still caught (approach takes over). Tunable on the car.
    private var corridorHops = 0
    private let maxCorridorHops = 3
    private let corridorClearCm = 55.0
    // Debug trace — the app was previously SILENT. Stream it live (device connected) with:
    //   xcrun devicectl device process launch --console --terminate-existing --device <udid> com.example.robotbrainai
    private var lastDbgAt = Date.distantPast
    private func dbg(_ s: String) { NSLog("[RB] %@", s) }
    // Sweep this spot: pan/tilt are SEMANTIC (90 = straight/level; tilt >90 = UP, <90 = DOWN). This
    // deliberately covers BOTH axes — up, down, left, right — so a floor object (e.g. a handkerchief)
    // is scanned too, not just a left/right pan. Body pivots (relocate) cover headings the head can't
    // reach. TUNE the extremes on the real car (this individual's reachable pan hemisphere / tilt).
    // With tiltNeutral=95 the semantic frame is now correct: 90=LEVEL, >90=UP, <90=DOWN (raw =
    // 95+(semTilt-90)). The head tilts the FULL up/down range (verified by raw sweep). Sweep up, level,
    // and down across a wide LEFT/RIGHT pan (pan is full range after the Servo_2 [0,180] reflash).
    private let scanArc: [(pan: Int, tilt: Int)] = [
        (90, 130),  // center, look UP        (raw ~135)
        (45,  88),  // far LEFT,  ~level       (raw ~93)
        (90,  45),  // center, look DOWN floor (raw ~50)
        (135, 88),  // far RIGHT, ~level       (raw ~93)
        (90,  83),  // center, DRIVE pose      (=driveTilt): the RELOCATE that follows measures the real
                    // travel path from here, not an up-tilted view (review #11/#19).
    ]
    private var relocatePivotSign = 1.0
    private let relocateClearCm = 45.0      // forward must be at least this open to drive; else pivot to a new heading
    // Anti-backtrack (reduce "searches the same spot"): remember the SIGN of the last committed drive's
    // lateral offset and, for turnCommitK relocate cycles, down-rank the OPPOSITE side so the car doesn't
    // immediately curve back into the area it just left (the A<->B wobble). A bare body-relative sign, not
    // an integrated heading — so it's immune to the uncalibrated open-loop pivot rate. Never traps: the
    // open-gate uses the UNPENALIZED base score, so the sole exit in a dead-end is still taken.
    private var lastTurnSign = 0.0          // -1 LEFT / +1 RIGHT / 0 disarmed = signed side of the last committed DRIVE
    private var turnCommitCycles = 0        // remaining relocate cycles the reverse-side penalty applies

    // --- Fused exploration (FR-66..71 / DESIGN §16): the camera (semantic, wide-FOV, sees soft/thin/
    // ledge obstacles) and the head-mounted sonar (accurate distance, near-field safety) share the
    // pan/tilt head, so a head sweep yields a per-direction distance fan for FREE. SCAN_FUSE reads the
    // sonar at each settled scan angle and pairs it with the VLM's forward_open/hazard for that
    // direction; RELOCATE_FUSE scores each heading and drives/pivots toward the best. ALL transient:
    // the fan is RAM-only and discarded on relocate (no odometry, no persistent map). Tunable on the car.
    private let DIST_NORM_CM = 150.0        // sonar >= this -> full distance score (norm saturates at 1)
    private let OPEN_MIN      = 0.3         // VLM openness under this = camera calls it blocked (soft-gates the sonar term)
    private let FWD_BLOCK_CM  = 30.0        // sonar closer than this = real obstacle -> exclude the direction
                                            //   (kept > host escapeEngage 25 > firmware veto 20, so fusion avoids first)
    private let W_SONAR       = 0.6         // fusion weight: accurate distance / near-field safety
    private let W_VLM         = 0.4         // fusion weight: semantic openness / soft obstacles (-> 0 in low light)
    private let W_FORWARD     = 0.30        // momentum bias: prefer continuing ~straight so the car TRAVELS across the
                                            //   room (covers NEW ground) instead of oscillating back — a no-odometry
                                            //   substitute for a visited-map (fixes "keeps searching the same spot").
    private let W_BACKTRACK   = 0.30        // reversal penalty: down-rank the side OPPOSITE the last drive. Kept <= W_FORWARD
                                            //   and << W_SONAR so it only breaks near-ties, never overrides a clearly-better
                                            //   opening or any -1 safety exclusion. W_FORWARD is symmetric L/R and can't stop
                                            //   the left<->right wobble alone; this asymmetry does.
    private let turnCommitK   = 1           // relocate cycles a drive commits the reverse-side penalty (1 = one-cycle;
                                            //   raise to 2-3 on-car if the wobble outlives a single cycle)
    private let DRIVE_CONE    = 50          // deg: if the best heading is within this of forward, DRIVE toward it with a
                                            //   steering curve (don't require ±panTol perfect alignment). Must be > the
                                            //   scanArc lateral offset (±45): at 40 a ±45 opening failed abs(off)<=cone and
                                            //   ALWAYS pivoted-in-place + re-scanned = ping-pong / re-searching the same spot.
    private struct DirSample {              // one scanned heading at THIS spot (transient; cleared on relocate)
        var semanticPan: Int                // head pan the sample was taken at (90 = forward; <90 LEFT, >90 RIGHT)
        var tilt: Int                       // head tilt of the reading kept (prefer near driveTilt = the travel path)
        var sonarCm: Double?                // sonar distance for this direction (nil = not read; >=250 = no echo/far)
        var vlmOpen: Double                 // VLM forward_open 0..1 for this direction
        var hazard: String                  // VLM hazard: none|soft|ledge|wall (things the sonar misses)
    }
    private var spotFan: [DirSample] = []   // this spot's scan result: built in SCAN_FUSE, consumed + cleared in RELOCATE_FUSE
    private var relocateFailRun = 0         // consecutive relocates that found NOWHERE open (degrade) -> bounds pivoting
    private let relocateFailLimit = 10      // only a genuinely boxed-in run this long declares "blocked" — a normal pivot
                                            // toward an opening is PROGRESS and must NOT count, or the car quits mid-search

    // --- Approach latch (FR-55): once the VLM FINDS the goal, stay in approach mode across brief
    // losses. gpt-4o-mini flickers back to "searching" the instant the goal slips off frame (right
    // after the car turns/moves), and without this the host would immediately relocate AWAY and
    // re-scan — the "found the handkerchief, drove off, searched again" bug. Hold through short
    // losses; resume the host search only after the goal is gone this many decisions in a row.
    private var approachLatched = false
    private var approachLost = 0
    private let approachLostLimit = 4
    private var approachTurns = 0          // in-view decisions since the goal was found (confirm counter)
    private let approachDoneTurns = 2      // FOUND = STOP: on finding the goal, HOLD in place (do NOT drive toward it) and
                                           //   after this many in-view confirm frames (or a near sonar) declare DONE + celebrate.
                                           //   Was 7 = a long drive-toward approach that overshot / lost the goal under the
                                           //   camera and celebrated LATE (owner: "once found it can just stop"). 2 = a light
                                           //   confirm so a single false VLM flash can't celebrate. Tunable (1 = instant).
    private let reachedOnLossTurns = 2     // target lost after >= this many in-view frames = it really was there -> reached
    private var targetBearing = 90         // head pan where the goal was last seen (hold here while briefly lost)

    // --- Low-light mode: the camera is the VLM's ONLY cue for the low/soft/thin/angled obstacles the
    // forward sonar misses. In the dark the VLM goes blind, so those obstacles get hit. We can't fully
    // prevent it (hardware limit: one forward sonar, no floor/edge sensor), but when the frame is dark
    // we (1) creep + stop further out (sonar-guarded) and (2) turn the body LEDs into a white headlight.
    @Published var lowLight = false
    private var lastLumaAt = Date.distantPast
    private let lowLightLuma = 55.0         // average frame luma (0-255) below this = "dark" (tunable)
    private let relocateClearDarkCm = 65.0  // in the dark, require MORE forward clearance before driving

    private let heartbeatHz = 10.0
    private let decisionHz = 0.7
    private let sonicHz = 3.0            // forward-distance poll rate (each poll blocks the car cmd loop ~18ms)
    // Head-guards-travel (design 2026-07-25): the camera + sonar share the pan/tilt head, so the
    // sensor only guards where the head points. While the body MOVES, force the head FORWARD so it
    // guards the travel path; free pan/tilt look ONLY while stopped.
    private let fwdPan = 90
    private let driveTilt = 83           // safe drive down-tilt: sonar clears the floor (~40-60cm echo), keeps floor-ahead in frame
    private let panTol = 8               // deg; "head forward" band
    private let tiltMinDrive = 78        // never advance with the head tilted below this
    private let servoSettleMs = 400.0    // command->physical settle before a fresh pose counts as "forward"
    private var lastAimAt = Date.distantPast
    private let deadmanMs = 500.0
    private let visionStaleMs = 800.0
    private let lowVoltage = 6.6
    private let remoteHeartbeatHz = 2.0
    // manual-drive tuning
    private let manualPulseMs = 250      // each held pulse self-expires (missed release still stops)
    private let manualThrottle = 0.8
    private let manualSteer = 0.7
    private let camStep = 10             // semantic degrees per camera nudge

    func start() {
        guard !running else { return }
        speech.langCode = voiceCode
        running = true; estop = false; estopLatched = false; escapePhase = .none; searchPhase = .scan; scanIndex = 0; approachLatched = false; approachLost = 0; approachTurns = 0
        spotFan.removeAll(); relocateFailRun = 0        // start with an empty distance fan (transient, per-spot)
        lastTurnSign = 0; turnCommitCycles = 0          // no turn commitment at the start of a run
        resetSagTransients()                            // seed the sag baseline fast (avoid a cold start) if a valid read exists
        if let v = car.voltage, v > lowVoltage { sagBaseline = v; sagBaselineN = max(1, sagBaselineN) }
        switch linkMode {
        case .lan:
            car.connect(host: carIP)   // video (re)starts via car.onCommandReady once ready
            lastLedKey = ""            // force the first LED cue to be sent
            loop = Task { await run() }
        case .remote:
            dryRun = true              // Remote boots disarmed (mirrors the bridge)
            image = nil; cmdConnected = false; camConnected = false
            // The production (wss://) relay verifies a Firebase token; require sign-in.
            // A local dev relay (ws://) uses the AUTH_DISABLED room, so no sign-in needed.
            if Self.relayURL.hasPrefix("wss://") && !auth.isSignedIn {
                running = false
                statusKey = "status.signInRequired"
                return
            }
            statusKey = "status.remoteConnecting"
            // room = the signed-in uid (the relay pairs phone+bridge by verified uid).
            // Token fetched fresh per connect.
            relay.configure(url: Self.relayURL, room: auth.uid ?? "app",
                            tokenProvider: { [weak self] in await self?.auth.idToken() ?? "" })
            relay.connect()
            startHeartbeat()           // ~2 Hz operator heartbeat; the bridge runs the brain
        }
    }

    /// Clear ALL latched motion so nothing re-drives after a stop / re-arm (review #1/#4/#7/#8/#16):
    /// the drive pulse, the teleop window, the escape + search + approach state machines, the stale
    /// in-flight decision, and the stale taskState that would otherwise keep collisionEscape suppressed.
    private func haltMotionState() {
        intent = Intent.hold
        pulseUntil = Date.distantPast
        cmdDriveUntil = Date.distantPast
        decideInFlight = false
        escapePhase = .none
        searchPhase = .scan; scanIndex = 0
        spotFan.removeAll(); relocateFailRun = 0        // discard the transient distance fan on any halt/re-arm
        lastTurnSign = 0; turnCommitCycles = 0          // drop the turn commitment on any halt/re-arm
        approachLatched = false; approachLost = 0; approachTurns = 0
        teleopDriving = false
        taskState = "idle"
        resetSagTransients()
    }

    /// Clear the voltage-sag run/stall transients + stop the fast poll (NOT the learned baseline, a slow
    /// physical property that must survive a stop/re-arm to avoid a ~20s cold start).
    private func resetSagTransients() {
        sagLoaded.removeAll(); sagStallSince = .distantPast
        sagForwardRunStart = .distantPast; sagLastFwdAt = .distantPast
        sagCooldownUntil = .distantPast
        car.stopFastVoltagePoll()
    }

    func stopAll() {
        speech.stopSpeaking()          // flush the queued TTS backlog
        stopCelebrate()                // silence the victory jingle if it's playing
        haltMotionState()              // drop the pulse/teleop/escape/approach so a later START can't re-drive
        decisionEpoch &+= 1            // drop any in-flight decision
        loop?.cancel(); loop = nil
        stopHeartbeat()
        switch linkMode {
        case .lan:
            car.send(Dispatcher.stop())
            car.send(Dispatcher.video(false))
            car.send(Dispatcher.bodyLeds(1))                              // leave a calm idle glow
            car.send(Dispatcher.led(mask: 0xFFF, r: 0, g: 0, b: 60))      // dim blue = powered/idle
            lastLedKey = "idle"
            car.stop()
        case .remote:
            relay.estop()
            relay.disconnect()
            cmdConnected = false; camConnected = false   // don't leave stale green dots
        }
        running = false; statusKey = "status.idle"; estopLatched = false
    }

    func emergencyStop() {
        estop = true; estopLatched = true; goal = ""; markLocalIntent()
        speech.stopSpeaking()          // flush queued "見えません" TTS NOW (the actual fix)
        stopCelebrate()                // silence the victory jingle
        haltMotionState()              // clear pulse/teleop/escape so clearing estop later can't re-drive
        decisionEpoch &+= 1            // drop any in-flight decision when it lands
        switch linkMode {
        case .lan:    car.send(Dispatcher.stop())
        case .remote: relay.estop()
        }
        statusKey = "status.estop"
    }

    /// Graceful transport switch while running: stop the OLD transport, re-arm
    /// dry-run (safety), then start in the new mode (REMOTE.md §B-5).
    private func switchMode(from old: LinkMode) {
        speech.stopSpeaking(); stopCelebrate(); haltMotionState(); decisionEpoch &+= 1
        loop?.cancel(); loop = nil
        stopHeartbeat()
        switch old {
        case .lan:
            car.send(Dispatcher.stop()); car.send(Dispatcher.video(false)); car.stop()
        case .remote:
            relay.estop(); relay.disconnect()
        }
        running = false
        applyingRemote = true; dryRun = true; applyingRemote = false   // re-arm after a switch
        image = nil; cmdConnected = false; camConnected = false
        goal = ""; report = ""; taskState = "idle"; estopLatched = false
        markLocalIntent()
        start()
    }

    /// AI<->Manual switch side effect: drop any goal, hold, and stop the car so neither
    /// controller keeps driving across the switch. lastGoal is preserved so START can resume.
    private func onControlModeChanged() {
        speech.stopSpeaking(); stopCelebrate(); decisionEpoch &+= 1
        goal = ""; memory.removeAll(); blockedRun = 0
        haltMotionState()               // clear pulse/teleop/escape/search/approach + stale taskState
        switch linkMode {
        case .lan:    car.send(Dispatcher.stop())
        case .remote: relay.sendGoal(""); relay.drive(throttle: 0, steer: 0, durationMs: manualPulseMs)
        }
        centerForDrive()                    // both modes start with the head guarding travel
        statusKey = "status.idle"
    }

    /// Recognize a spoken/typed mode command ("手動"/"manual"/"AIモード"/…). Exact match
    /// after stripping a mode/モード suffix, so ordinary goals aren't captured. Returns
    /// true if it was a mode command (and switched), so callers skip goal handling.
    private var cmdDriveUntil = Date.distantPast   // a direct teleop command ("2秒後進して") drives until here, overriding the AI loop

    /// A spoken/typed DIRECT movement command ("2秒後進して", "前進", "右を向いて", "止まって") — run it as a
    /// timed teleop pulse that OVERRIDES the AI loop for its duration. Returns true if `t` WAS such a
    /// command (so setGoal won't treat it as a search goal). Safety (E-STOP/low-batt/dry-run) still wins.
    private func handleDriveCommand(_ t: String) -> Bool {
        let s = t.lowercased()
        func has(_ ws: [String]) -> Bool { ws.contains { s.contains($0) } }
        // #17: never hijack a SEARCH GOAL that merely contains a drive keyword (e.g. "止まっている人を
        // 探して", "回転寿司を探して", "find the bus stop"). If it reads as "find/look for X", it's a goal.
        if has(["探", "見つけ", "さがし", "見回", "find", "look for", "search"]) { return false }
        let num: Double? = {                                   // a number: "2秒" (seconds) or "90度" (degrees)
            guard let r = s.range(of: "[0-9]+(\\.[0-9]+)?", options: .regularExpression) else { return nil }
            return Double(s[r])
        }()
        let isDeg = has(["度", "°", "degree", "deg"])
        let secs  = (num != nil && !isDeg) ? num! : nil        // "N秒"
        let degs  = (num != nil &&  isDeg) ? num! : nil        // "N度"
        if has(["止ま", "止め", "停止", "ストップ", "stop"]) {
            emergencyStop(); return true   // #6: a spoken STOP is DURABLE — engage E-STOP + clear the goal, never clear-estop-then-resume
        }
        if has(["後進", "こうしん", "バック", "ばっく", "下がっ", "さがっ", "戻っ", "reverse", "back up", "go back"]) {
            runCommand(throttle: -0.5, steer: 0.0, seconds: secs ?? 1.5); return true   // REVERSE (never collision-vetoed)
        }
        if has(["前進", "ぜんしん", "go forward", "forward", "前へ進"]) {
            runCommand(throttle: 0.4, steer: 0.0, seconds: secs ?? 1.5); return true    // forward (still collision-guarded)
        }
        // PIVOT in place: "旋回/回転/回って/右(左)を向く/右(左)折/turn right(left)/spin". Duration from
        // "N度" (via pivotDegPerSec estimate) or "N秒", else a default. Direction: 左 => left, else right.
        if has(["旋回", "回転", "回って", "回れ", "spin", "右を向", "左を向", "右に曲", "左に曲",
                "右折", "左折", "右回", "左回", "turn right", "turn left"]) {
            let sign: Double = has(["左", "left"]) ? -1.0 : 1.0                          // default = right
            let dur = degs.map { max(0.2, min(4.0, $0 / pivotDegPerSec)) } ?? secs ?? 0.9
            runCommand(throttle: 0.0, steer: sign * 0.85, seconds: dur); return true
        }
        return false
    }
    private let pivotDegPerSec = 110.0     // ESTIMATED in-place turn rate at steer 0.85 (tune on the real car)

    /// Drive a fixed throttle/steer for `seconds`, suppressing the AI loop meanwhile (maybeDecide +
    /// applyIntent bail while `now < cmdDriveUntil`, and run() keeps the deadman fed). LAN only for now.
    private func runCommand(throttle: Double, steer: Double, seconds: Double) {
        let dur = max(0.3, min(5.0, seconds))
        estop = false; estopLatched = false
        approachLatched = false; approachLost = 0; approachTurns = 0   // a manual override drops any approach
        taskState = "idle"                                 // #4: drop stale "approaching"/"done" so collisionEscape guards this
        if !running { start() }                            // ensure the arbiter loop + link are up
        switch linkMode {
        case .lan:
            if throttle > 0.05, !headForward { centerForDrive() }      // #3: point the shared sonar/camera at the travel path
            intent = Intent(throttle: throttle, steer: steer, durationMs: Int(dur * 1000))
            pulseUntil = Date().addingTimeInterval(dur)
            cmdDriveUntil = Date().addingTimeInterval(dur)
            teleopDriving = true                           // #2/#6: keep the big STOP button visible while this drives
            lastIntentAt = Date(); markLocalIntent()
        case .remote:
            relay.clearEstop(); relay.drive(throttle: throttle, steer: steer, durationMs: Int(dur * 1000))
            cmdDriveUntil = Date().addingTimeInterval(dur); teleopDriving = true   // #1: keep STOP visible in Remote too
        }
    }

    private func handleModeCommand(_ t: String) -> Bool {
        let s = t.lowercased()
            .replacingOccurrences(of: "モード", with: "")
            .replacingOccurrences(of: "mode", with: "")
            .trimmingCharacters(in: .whitespaces)
        let manualWords: Set<String> = ["手動", "マニュアル", "manual", "コントローラ", "controller"]
        let aiWords: Set<String> = ["ai", "自動", "オート", "auto", "自律"]
        if manualWords.contains(s) { controlMode = .manual; return true }
        if aiWords.contains(s) { controlMode = .ai; return true }
        return false
    }

    /// Discover the car via Bonjour and reconnect to it (LAN only).
    func findCar() {
        discovery.find { [weak self] host in
            guard let self else { return }
            self.carIP = host
            self.stopAll()
            self.start()
        }
    }

    private var lastGoal = ""    // remembered so "開始" can resume after a stop

    /// The big button is a Start/Stop toggle: it shows STOP (and can e-stop) only
    /// while a goal is actually being pursued — i.e. whenever the car might move —
    /// and START otherwise. This keeps an always-reachable STOP during motion.
    var isMissionActive: Bool { running && !estop && !goal.isEmpty }

    /// True when the pack voltage is at/under the cutoff — the safety reflex blocks ALL motion
    /// (AI and manual, regardless of dry-run) until charged. Surfaced prominently in the UI.
    var lowBatteryActive: Bool { if let v = voltage, v > 0, v < lowVoltage { return true }; return false }

    func setGoal(_ g: String) {
        let t = g.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if handleModeCommand(t) { return }               // "手動"/"AI" etc. switch mode, not a goal
        if handleDriveCommand(t) { return }              // "2秒後進して" etc. run it directly, not a search goal
        if controlMode == .manual { controlMode = .ai }  // a real goal implies autonomy
        stopCelebrate()                                  // #9: silence a lingering win jingle
        haltMotionState()                                // #7/#8: clear any leftover pulse/teleop/escape/stale taskState
        goal = t; lastGoal = t; estop = false; estopLatched = false; blockedRun = 0; memory.removeAll(); decisionEpoch &+= 1; markLocalIntent()
        if !running { start() }
        if linkMode == .remote { relay.clearEstop(); relay.sendGoal(t) }
    }

    /// "開始": start/resume. Uses the typed goal if any, else the last goal; with no
    /// goal it just clears the stop and ensures the session is up.
    func resume(typed: String) {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if handleModeCommand(t) { return }
        // Only auto-resume the last goal in AI mode; a bare START in manual just clears
        // the stop and stays manual (never silently flips to autonomy on a stale goal).
        let g = t.isEmpty ? (controlMode == .ai ? lastGoal : "") : t
        if !g.isEmpty { setGoal(g); return }
        // Bump the epoch AND clear the in-flight gate together (#8): otherwise a superseded decision
        // returns without freeing the gate and it can't re-open until the next setGoal.
        estop = false; estopLatched = false; decisionEpoch &+= 1; decideInFlight = false; markLocalIntent()
        if !running { start() }
        if linkMode == .remote { relay.clearEstop() }
    }

    // MARK: aiming
    /// Aim the head at a semantic (90-neutral) pan/tilt. LAN lowers to CMD_ locally
    /// (swap + neutral); Remote sends `look` and the bridge applies swap + neutral.
    private var lastLookCmd: [String] = ["", ""]   // last CMD_SERVO per [pan, tilt] — dedup the pad flood
    /// The head (camera+sonar) is centered forward AND settled, so the sonar guards the travel path.
    var headForward: Bool {
        abs(curPan - fwdPan) <= panTol && curTilt >= tiltMinDrive
            && Date().timeIntervalSince(lastAimAt) > servoSettleMs / 1000.0
    }
    /// The head has physically settled at its CURRENT aim (any angle), so a sonar read + the frame
    /// both describe that direction. Used by SCAN_FUSE to attribute the sonar to each scan pan angle
    /// (headForward is forward-only; scan angles are off-center / down-tilted).
    var headSettled: Bool { Date().timeIntervalSince(lastAimAt) > servoSettleMs / 1000.0 }
    /// Force the head to the forward drive pose (used on session/mode entry and before driving).
    private func centerForDrive() { aim(pan: fwdPan, tilt: driveTilt) }

    func aim(pan: Int, tilt: Int) {
        if pan != curPan || tilt != curTilt { lastAimAt = Date() }   // arm the settle gate only on an actual move
        curPan = pan; curTilt = tilt
        switch linkMode {
        case .lan:
            let cmds = Dispatcher.look(pan: pan, tilt: tilt, swap: servoSwap,
                                       panNeutral: panNeutral, tiltNeutral: tiltNeutral,
                                       panInvert: panInvert)
            for (i, c) in cmds.enumerated() where c != lastLookCmd[i] {
                car.send(c); lastLookCmd[i] = c     // only send the axis that actually changed
            }
        case .remote:
            relay.look(pan: pan, tilt: tilt)
        }
    }
    /// Live calibration sends a RAW physical angle to the resolved channel (bypasses
    /// neutral). LAN only — you must physically see the car to calibrate it; the
    /// calibration UI is hidden in Remote mode.
    private var lastCalibSend = Date.distantPast
    private func calibThrottleOK(_ force: Bool) -> Bool {
        if force || Date().timeIntervalSince(lastCalibSend) > 0.05 { lastCalibSend = Date(); return true }
        return false
    }
    func calibratePan(_ angle: Int, force: Bool = false)  {
        guard linkMode == .lan, calibThrottleOK(force) else { return }
        car.send(Dispatcher.servo(panChannel, angle))
    }
    func calibrateTilt(_ angle: Int, force: Bool = false) {
        guard linkMode == .lan, calibThrottleOK(force) else { return }
        car.send(Dispatcher.servo(tiltChannel, angle))
    }
    /// Move to the saved forward/level home (semantic 90/90).
    func centerHead() { aim(pan: 90, tilt: 90) }

    /// Put the car into WiFi setup mode (SoftAP `RobotBrain-setup`) on demand, over the current LAN
    /// link. The car arms a one-shot force-provision flag, reboots (~10s), and comes up as an AP so
    /// the app can set a new WiFi even while the old one still works (e.g. before a move). LAN only —
    /// away from any known WiFi the car enters this mode by itself. The live link drops on reboot.
    func enterWiFiSetup() {
        guard linkMode == .lan else { return }
        car.send(Dispatcher.wifiForget())
    }

    // MARK: manual control (human drives; VLM loop off, but arbiter/deadman/dry-run/STOP stay on)
    /// Feed one short self-expiring drive pulse. The UI calls this ~10 Hz while a D-pad
    /// button is held; on release it calls manualStop(). LAN: the run() arbiter reads
    /// `intent` and sends motor (respecting dry-run/safety). Remote: send it to the bridge.
    func manualDrive(throttle: Double, steer: Double) {
        guard controlMode == .manual, !estop else { return }
        // Forward guards travel only with the head centered: auto-recenter first (the run()
        // backstop holds forward until the head is forward+settled). Reverse/pivot/look stay free.
        if linkMode == .lan, throttle > 0.05, !headForward { centerForDrive() }
        let d = Intent(throttle: throttle, steer: steer, durationMs: manualPulseMs)
        intent = d
        pulseUntil = Date().addingTimeInterval(Double(manualPulseMs) / 1000.0)
        lastIntentAt = Date()
        if linkMode == .remote { relay.drive(throttle: throttle, steer: steer, durationMs: manualPulseMs) }
    }
    /// Directional helpers used by the D-pad (magnitudes from the tuning constants).
    func manualForward() { manualDrive(throttle: manualThrottle, steer: 0) }
    func manualBackward() { manualDrive(throttle: -manualThrottle, steer: 0) }
    func manualLeft()  { manualDrive(throttle: 0, steer: -manualSteer) }
    func manualRight() { manualDrive(throttle: 0, steer: manualSteer) }
    /// Stop now (D-pad release). Pulse also self-expires, so a missed release still stops.
    func manualStop() {
        intent = Intent.hold
        pulseUntil = Date.distantPast
        escapePhase = .none          // #5: a manual release must stop NOW — don't let a latched escape reverse/pivot on
        car.stopFastVoltagePoll(); sagStallSince = .distantPast; sagForwardRunStart = .distantPast
        switch linkMode {
        case .lan:    car.send(Dispatcher.stop())
        case .remote: relay.drive(throttle: 0, steer: 0, durationMs: manualPulseMs)
        }
    }
    /// Nudge the camera by a semantic delta (clamped to this build's usable arc).
    func nudgeCamera(dPan: Int, dTilt: Int) {
        let p = max(20, min(160, curPan + dPan))
        let t = max(15, min(175, curTilt + dTilt))   // semantic; with tiltNeutral 95 -> raw ~20..180 (full down..up)
        aim(pan: p, tilt: t)
    }

    // MARK: remote heartbeat (operator deadman on the bridge)
    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTask = Task { [weak self] in
            let tick = UInt64(1_000_000_000 / (self?.remoteHeartbeatHz ?? 2.0))
            while !Task.isCancelled {
                await MainActor.run {
                    self?.relay.heartbeat()
                    if let s = self, s.teleopDriving, Date() >= s.cmdDriveUntil { s.teleopDriving = false }   // #1: end the STOP window (Remote has no run() loop)
                }
                try? await Task.sleep(nanoseconds: tick)
            }
        }
    }
    private func stopHeartbeat() { heartbeatTask?.cancel(); heartbeatTask = nil }

    // MARK: LED "car light language" (LAN; in Remote the bridge drives the LEDs)
    private var lastLedKey = ""
    private var doneFlashUntil = Date.distantPast
    private var lastChirpAt = Date.distantPast

    /// Compute the cue from the live state and apply it (only when it changes).
    private func updateLeds(estop: Bool, reason: String?, driving: Bool) {
        guard linkMode == .lan else { return }
        if Date() < doneFlashUntil { return }       // #9: let celebrate()'s rainbow own the LEDs during the win
        // Steady WHITE "vision light" whenever the car is active and NOT driving in normal light — i.e.
        // while STOPPED/scanning (any light) or while driving in the DARK. A breathing/blinking cue tints
        // the scene between frames and adds motion noise, weakening BOTH the VLM's per-direction judgment
        // and the frame-diff stuck detector; a constant white also lights the scene. estop / low-batt /
        // link-down (reason != nil) still fall through to their own cue below.
        if running && !estop && reason == nil && (!driving || lowLight) {
            applyLedCue(LedCue(key: "vision", mode: 1, mask: 0xFFF, r: 255, g: 255, b: 255, chirp: false))
            return
        }
        let thr = driving ? intent.throttle : 0    // 0 when the pulse has expired (not a stale cue)
        let str = driving ? intent.steer : 0
        let cue = LedLanguage.cue(running: running, estop: estop, reason: reason,
                                  taskState: taskState, throttle: thr, steer: str,
                                  doneFlash: Date() < doneFlashUntil)
        applyLedCue(cue)
    }
    private func applyLedCue(_ cue: LedCue) {
        guard cue.key != lastLedKey else { return }
        lastLedKey = cue.key
        car.send(Dispatcher.bodyLeds(cue.mode))                       // 1 static / 3 blink / 4 breathe / 5 rainbow
        if cue.mode != 5 {                                            // rainbow computes its OWN 12-LED gradient —
            car.send(Dispatcher.led(mask: 0xFFF, r: 0, g: 0, b: 0))   // painting a solid color_1 would flatten it
            car.send(Dispatcher.led(mask: cue.mask, r: cue.r, g: cue.g, b: cue.b))
        }
        if cue.chirp { chirp() }
    }

    /// Goal reached! Flashy rainbow + a short victory jingle (~3s, well under 5s). LEDs/buzzer are
    /// non-motion so they bypass dry-run. The buzzer plays a note sequence via CMD_BUZZER (non-blocking
    /// Buzzer_Variable on the car); we stop it at the end and on STOP/e-stop.
    private var celebrating = false
    private func celebrate() {
        guard linkMode == .lan, !celebrating else { return }
        celebrating = true
        doneFlashUntil = Date().addingTimeInterval(3.2)              // hold the rainbow through the jingle
        car.send(Dispatcher.bodyLeds(5)); lastLedKey = "done"        // rainbow now; block updateLeds from repainting
        // (freqHz, holdMs) — a little rising victory fanfare. Total ~2.6s.
        let jingle: [(Int, UInt64)] = [(523,160),(659,160),(784,160),(1047,260),(784,140),(1047,520),(1319,700)]
        Task { [weak self] in
            for (freq, ms) in jingle {
                guard let self, !self.estop, self.celebrating else { break }
                await MainActor.run { self.car.send(Dispatcher.buzzer(on: true, freq: freq)) }
                try? await Task.sleep(nanoseconds: ms * 1_000_000)
            }
            await MainActor.run { self?.car.send(Dispatcher.buzzer(on: false, freq: 0)); self?.celebrating = false }
        }
    }
    /// Silence the jingle immediately (STOP / e-stop / new goal / mode switch).
    private func stopCelebrate() {
        celebrating = false
        doneFlashUntil = Date.distantPast     // #3/#7: release updateLeds' rainbow early-return so the real cue repaints
        if linkMode == .lan { car.send(Dispatcher.buzzer(on: false, freq: 0)) }
    }
    /// Short reverse chirp, edge-triggered + rate-limited (LEDs/buzzer are non-motion,
    /// so they bypass dry-run — they never move the car).
    private func chirp() {
        guard Date().timeIntervalSince(lastChirpAt) > 1.5 else { return }
        lastChirpAt = Date()
        car.send(Dispatcher.buzzer(on: true, freq: 2200))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self?.car.send(Dispatcher.buzzer(on: false, freq: 0))
        }
    }

    // MARK: LAN control loop (fat client) — unchanged from the LAN-only build
    /// Returns a localization key if motion must be blocked, else nil.
    private func safetyReason() -> String? {
        if !car.cmdConnected { return "safety.linkDown" }
        let age = car.lastFrameAt.map { Date().timeIntervalSince($0) * 1000 } ?? .infinity
        if controlMode == .ai, age > visionStaleMs { return "safety.visionStale" }   // vision guards the AI; manual is human-driven
        if Date().timeIntervalSince(lastIntentAt) * 1000 > deadmanMs { return "safety.deadman" }
        if let v = car.voltage, v > 0, v < lowVoltage { return "safety.lowBattery" }
        return nil
    }

    /// Average brightness (0-255) of a frame via a 1x1 downscale. nil if the frame can't be read.
    private func frameLuma(_ img: UIImage) -> Double? {
        guard let cg = img.cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))   // average the whole frame into one pixel
        return 0.299 * Double(px[0]) + 0.587 * Double(px[1]) + 0.114 * Double(px[2])
    }

    /// Arbiter-level "get unstuck" maneuver, evaluated every ~100ms so it never waits on the slow
    /// Vision loop. Returns a motor line to OVERRIDE the model while escaping, or nil when idle.
    /// Latched + hysteretic: reverse until the path is decisively clear, THEN pivot to change heading,
    /// so the model can't re-drive forward into the same wall the moment distance ticks past engage.
    /// Subordinate to every hard safety block and suppressed during a deliberate goal approach.
    private func collisionEscape(freshFwd: Double?, approaching: Bool, hardBlock: Bool) -> String? {
        if hardBlock || approaching { escapePhase = .none; return nil }
        func reverseLine() -> String { Dispatcher.drive(throttle: -0.5, steer: escapeSign * 0.25, speedCap: speedCap, trim: motorTrim) }
        func pivotLine()   -> String { Dispatcher.drive(throttle:  0.0, steer: escapeSign * 1.0,  speedCap: speedCap, trim: motorTrim) }
        switch escapePhase {
        case .none:
            let engageCm = lowLight ? 32.0 : escapeEngageCm    // back off sooner when the camera is blind
            let wantsForward = Date() < pulseUntil && intent.throttle > 0.05
            guard wantsForward, let d = freshFwd, d < engageCm else { return nil }
            escapePhase = .reversing; escapeStart = Date()
            escapeSign = intent.steer >= 0 ? 1.0 : -1.0
            return reverseLine()
        case .reversing:
            let elapsed  = Date().timeIntervalSince(escapeStart)
            let minDone  = elapsed > escapeMinReverseMs / 1000.0   // back off a real distance even if the sonar reads clear
            let cleared  = (freshFwd ?? 0) > escapeClearCm         // hysteresis: real clearance, not just > engage
            let timedOut = elapsed > escapeMaxReverseMs / 1000.0
            if (minDone && cleared) || timedOut { escapePhase = .pivoting; escapeStart = Date(); return pivotLine() }
            return reverseLine()
        case .pivoting:
            if Date().timeIntervalSince(escapeStart) > escapePivotMs / 1000.0 { escapePhase = .none; return nil }
            return pivotLine()
        }
    }

    /// FR-54..56 deterministic search: mutate `it` so the HOST sweeps the head at each spot (scan),
    /// then drives to a NEW spot (relocate), so "stop -> sweep -> if not found, move -> re-scan" runs
    /// every time instead of depending on the VLM to choose to move. Called only while the VLM reports
    /// searching/blocked; collision escape + every safety block still win downstream in run().
    private func applySearch(_ it: inout Intent, freshFwd: Double?, scanSonar: Double?) {
        switch searchPhase {
        case .scan:
            // (A) SCAN_FUSE (FR-66/67): the head has dwelt at curPan long enough for BOTH this frame and
            // a settled sonar read to describe that direction, so attribute the VLM's forward_open/hazard
            // + the sonar to curPan (transient fan), THEN swing the head to the next scan angle. The fan
            // is discarded on relocate — no persistent map, no odometry.
            if headSettled {
                recordScanSample(pan: curPan, tilt: curTilt,
                                 vlmOpen: it.forwardOpen ?? 0.5, hazard: it.hazard, sonar: scanSonar)
            }
            it.throttle = 0; it.steer = 0                 // stay put; the VLM judges "is the goal here?"
            if scanIndex < scanArc.count {
                let a = scanArc[scanIndex]
                it.pan = a.pan; it.tilt = a.tilt          // sweep the head across this spot
                it.durationMs = 300
                scanIndex += 1
            } else {                                      // arc covered (incl. the forward drive pose) -> fuse + relocate
                scanIndex = 0; searchPhase = .relocate
                it.pan = fwdPan; it.tilt = driveTilt      // face forward to measure the travel path next tick
                it.durationMs = 200
            }
        case .relocate:
            applyRelocateFuse(&it, freshFwd: freshFwd)
        case .corridor:
            // R2: keep flowing forward down an open path instead of re-scanning after every hop.
            it.pan = fwdPan; it.tilt = driveTilt              // sonar + camera watch the travel path
            guard headForward else { it.throttle = 0; it.steer = 0; it.durationMs = 200; return }
            if let fwd = freshFwd, fwd > corridorClearCm, corridorHops < maxCorridorHops {
                corridorHops += 1
                it.throttle = 0.4; it.steer = 0; it.durationMs = 350   // one more forward hop (arbiter/escape/veto still guard)
            } else {                                          // path closed / hop limit -> re-scan the NEW area
                corridorHops = 0; spotFan.removeAll(); searchPhase = .scan; scanIndex = 0
            }
        }
    }

    /// SCAN_FUSE bookkeeping: merge a reading into `spotFan` keyed by heading (semantic pan). Several
    /// scan angles share a pan (e.g. forward is swept up/level/down); keep the sonar + openness from the
    /// frame nearest driveTilt (the real travel path) and escalate hazard to the WORST seen at that pan
    /// (a ledge spotted while tilted down still blocks driving forward there).
    private func recordScanSample(pan: Int, tilt: Int, vlmOpen: Double, hazard: String, sonar: Double?) {
        let rank = ["none": 0, "soft": 1, "ledge": 2, "wall": 3]
        if let idx = spotFan.firstIndex(where: { $0.semanticPan == pan }) {
            var s = spotFan[idx]
            if abs(tilt - driveTilt) <= abs(s.tilt - driveTilt) {   // travel-relevant frame (ties -> newest) is canonical
                s.tilt = tilt
                if let sonar = sonar { s.sonarCm = sonar }
                s.vlmOpen = vlmOpen
            } else if s.sonarCm == nil, let sonar = sonar {
                s.sonarCm = sonar                         // fill a still-missing sonar even from a less-ideal tilt
            }
            if (rank[hazard] ?? 0) > (rank[s.hazard] ?? 0) { s.hazard = hazard }   // worst hazard wins
            spotFan[idx] = s
        } else {
            spotFan.append(DirSample(semanticPan: pan, tilt: tilt, sonarCm: sonar, vlmOpen: vlmOpen, hazard: hazard))
        }
    }

    /// (B) RELOCATE_FUSE (FR-68..70): once the head is forward+settled, score every scanned heading by
    /// fusing normalized sonar distance with VLM openness (cross-checked so neither sensor's blind spot
    /// wins), then drive forward if the best heading is ahead, else PIVOT the body to face it and re-scan.
    /// Degrades gracefully with no infinite pivot. Only builds Intent — the arbiter + every safety block
    /// (E-STOP/dry-run/deadman/low-batt/collisionEscape/firmware veto) stay superior in run().
    private func applyRelocateFuse(_ it: inout Intent, freshFwd: Double?) {
        it.pan = fwdPan; it.tilt = driveTilt              // face forward to measure the travel path + drive
        guard headForward else {                          // head still swinging forward -> wait one tick, keep the fan
            it.throttle = 0; it.steer = 0; it.durationMs = 200
            return
        }
        if let f = freshFwd, let i = spotFan.firstIndex(where: { abs($0.semanticPan - fwdPan) <= panTol }) {
            spotFan[i].sonarCm = f                        // refresh the forward heading with the just-settled live read
        }
        // FR-70: in low light the camera is unreliable -> drop the VLM weight to 0 and ignore VLM hazards
        // (sonar-led + creep + headlight, which updateLeds already turns on when lowLight).
        let wVlm = lowLight ? 0.0 : W_VLM
        func score(_ s: DirSample) -> Double {
            let cm = s.sonarCm ?? DIST_NORM_CM            // unknown -> treat as far so a missing read can't veto a direction
            if cm < FWD_BLOCK_CM { return -1 }            // cross-check: sonar says real obstacle -> exclude (VLM can't override)
            if s.hazard == "wall" || s.hazard == "ledge" { return -1 }   // camera-confirmed blocker the sonar may miss — trust it EVEN in low light (a curtain/cloth fools the sonar into "open"; the camera is the only thing that sees it)
            let norm = min(max(cm / DIST_NORM_CM, 0), 1)  // farther = higher
            let gate = s.vlmOpen < OPEN_MIN ? 0.2 : 1.0   // cross-check: sonar clear but camera "blocked" -> soft obstacle penalty
            var sc = W_SONAR * norm * gate + wVlm * s.vlmOpen
            if s.hazard == "soft" { sc *= 0.2 }    // curtain/cloth: penalize EVEN in low light — the sonar reads through it as "open" and drives straight in (observed on the real car)
            sc += W_FORWARD * (1 - Double(abs(s.semanticPan - fwdPan)) / 90.0)   // momentum: prefer ~straight -> travel + cover new ground
            return sc
        }
        // Anti-backtrack: penalize the side OPPOSITE the last committed drive so the car doesn't curve
        // straight back into the area it just left (the left<->right wobble = same-spot re-search).
        func backtrackPenalty(_ s: DirSample) -> Double {
            guard turnCommitCycles > 0, lastTurnSign != 0 else { return 0 }
            let o = s.semanticPan - fwdPan
            guard abs(o) > panTol, (o < 0 ? -1.0 : 1.0) == -lastTurnSign else { return 0 }
            return W_BACKTRACK * Double(min(abs(o), 90)) / 90.0    // scaled by how lateral; always >= 0, never -1
        }
        let scored = spotFan.map { (s: $0, base: score($0), pen: backtrackPenalty($0)) }
        if turnCommitCycles > 0 { turnCommitCycles -= 1 }         // age AFTER this cycle's penalty applied (headForward guard already returned, so a settling tick can't burn it)
        // Rank by (base - penalty) but GATE openness on the UNPENALIZED base, so the sole exit in a dead
        // end is never hidden by the penalty (anti-trap): the penalty only REORDERS already-open headings.
        guard let top = scored.sorted(by: { ($0.base - $0.pen) > ($1.base - $1.pen) }).first(where: { $0.base > 0 }) else {
            lastTurnSign = 0; turnCommitCycles = 0
            degradeRelocate(&it); return                  // FR-69: nowhere scored open -> graceful, bounded degrade
        }
        let best = (s: top.s, sc: top.base)
        let off = best.s.semanticPan - fwdPan             // pan convention: <90 LEFT, >90 RIGHT (scanArc)
        dbg("relocate best pan=\(best.s.semanticPan) off=\(off) sc=\(String(format: "%.2f", best.sc)) sonar=\(best.s.sonarCm.map { String(Int($0)) } ?? "-") fan=\(spotFan.count) -> \(abs(off) <= DRIVE_CONE ? "DRIVE" : "PIVOT")")
        if abs(off) <= DRIVE_CONE {                       // within the drive cone -> DRIVE toward it (curve), don't just pivot
            let fwdSonar = best.s.sonarCm ?? DIST_NORM_CM //   (best already passed the >=FWD_BLOCK_CM/hazard exclusion)
            if lowLight, fwdSonar < relocateClearDarkCm { degradeRelocate(&it); return }   // dark -> only drive into ample clearance
            relocateFailRun = 0                           // we ADVANCED -> reset the give-up counter
            it.throttle = lowLight ? 0.30 : 0.45
            it.steer = max(-0.4, min(0.4, Double(off) / Double(DRIVE_CONE)))   // steer curve INTO the opening while moving
            it.durationMs = lowLight ? 250 : 350
            lastTurnSign = abs(off) > panTol ? (off < 0 ? -1.0 : 1.0) : 0.0    // lateral curve commits that side; a straight drive disarms
            turnCommitCycles = lastTurnSign == 0 ? 0 : turnCommitK             // suppress the reverse for the next K relocate(s)
            corridorHops = 0; spotFan.removeAll(); searchPhase = .corridor; scanIndex = 0  // moved -> flow forward (R2), don't re-scan yet
        } else {                                          // opening is FAR lateral -> pivot to FACE it, then re-scan
            let sign: Double = off < 0 ? -1.0 : 1.0       // off<0 = LEFT -> steer left (negative)
            let secs = max(0.2, min(2.0, Double(abs(off)) / pivotDegPerSec))
            it.throttle = 0; it.steer = sign * 0.85
            it.durationMs = Int(secs * 1000)
            lastTurnSign = sign; turnCommitCycles = turnCommitK   // (dead now: DRIVE_CONE>±45; future-proof if scanArc widens)
            relocateFailRun = 0                           // turning to FACE an opening is PROGRESS -> do NOT count as give-up
            spotFan.removeAll(); searchPhase = .scan; scanIndex = 0
        }
    }

    /// Nowhere fused open: step toward the farthest still-passable heading if there is one, else spin in
    /// place to a fresh view. Bounded — after `relocateFailLimit` stalled relocates in a row we mark the
    /// intent "blocked" so the existing blockedRun logic can give up (FR-69: never pivot forever).
    private func degradeRelocate(_ it: inout Intent) {
        it.pan = fwdPan; it.tilt = driveTilt
        let farthest = spotFan.max { ($0.sonarCm ?? 0) < ($1.sonarCm ?? 0) }
        if let f = farthest, (f.sonarCm ?? 0) >= FWD_BLOCK_CM, abs(f.semanticPan - fwdPan) > panTol {
            let sign: Double = (f.semanticPan - fwdPan) < 0 ? -1.0 : 1.0
            let secs = max(0.2, min(2.0, Double(abs(f.semanticPan - fwdPan)) / pivotDegPerSec))
            it.throttle = 0; it.steer = sign * 0.85; it.durationMs = Int(secs * 1000)
        } else {                                          // truly boxed in -> in-place pivot to change the view
            it.throttle = 0; it.steer = relocatePivotSign * 0.9; it.durationMs = 350
        }
        noteRelocateStall(&it)
        lastTurnSign = 0; turnCommitCycles = 0            // failed to advance -> drop any turn commitment
        spotFan.removeAll(); searchPhase = .scan; scanIndex = 0
    }

    /// Count a relocate that did NOT advance forward; declare "blocked" once too many stall in a row so
    /// the host can't pivot forever (FR-69). Reset to 0 whenever a real forward pulse fires.
    private func noteRelocateStall(_ it: inout Intent) {
        relocateFailRun += 1
        if relocateFailRun >= relocateFailLimit { it.taskState = "blocked" }
    }

    /// Decoupled from the heartbeat: spawn the Vision call so the arbiter never blocks on it.
    private func maybeDecide() {
        guard controlMode == .ai, !estop, !goal.isEmpty, !decideInFlight,
              Date() >= cmdDriveUntil,                       // a direct teleop command is running -> pause the AI
              Date().timeIntervalSince(lastDecision) >= 1.0 / decisionHz,
              let img = car.image else { return }
        decideInFlight = true
        lastDecision = Date()
        let g = goal, mem = memory, key = apiKey, mdl = model, lg = resolvedLang
        let epoch = decisionEpoch
        let distCm: Double? = {          // forward distance for the VLM — valid ONLY while the head guards travel
            guard headForward, let d = car.distance, let at = car.distanceAt, Date().timeIntervalSince(at) < 1.5 else { return nil }
            return d
        }()
        Task { [weak self] in
            let it = await Brain.decide(image: img, goal: g, memory: mem, apiKey: key, model: mdl, lang: lg, distanceCm: distCm)
            self?.applyIntent(it, epoch: epoch)
        }
    }

    private func applyIntent(_ it: Intent, epoch: Int) {
        // #8: a SUPERSEDED decision (STOP/new-goal/mode-switch bumped the epoch) must NOT free the
        // in-flight gate — a fresh decision may already be running. Only the current-epoch decision
        // clears it. haltMotionState() still clears the gate on every stop path (no stuck gate).
        guard epoch == decisionEpoch else { return }
        decideInFlight = false
        // Never apply outside a running LAN AI session, or over a STOP / teleop command.
        guard !estop, controlMode == .ai, linkMode == .lan, running,
              Date() >= cmdDriveUntil else { return }        // don't let a late AI decision override a teleop command
        var it = it
        // --- Sonar forward-collision reflex (subordinate to the arbiter). Mutate the model's
        // intent BEFORE it becomes `intent`, so RECENT records what actually ran; STOP / e-stop /
        // dry-run / deadman still win downstream in run(). Suppressed during a real approach so a
        // deliberate close-in on the goal isn't sabotaged; gated on a FRESH (<1.5s), plausible read.
        // Valid ONLY while the head guards travel (we only poll CMD_SONIC while forward, so the
        // cached reading is a forward one; the headForward check also covers "still forward now").
        let freshDist: Double? = {
            guard headForward, let d = car.distance, let at = car.distanceAt,
                  Date().timeIntervalSince(at) < 1.5, d >= 3 else { return nil }
            return d
        }()
        // Fused-search sonar (FR-66): valid at ANY settled head angle (not just forward), so SCAN_FUSE
        // can attribute a distance to each scan pan. Same freshness/plausibility gate as freshDist.
        let scanSonar: Double? = {
            guard headSettled, let d = car.distance, let at = car.distanceAt,
                  Date().timeIntervalSince(at) < 1.5, d >= 3 else { return nil }
            return d
        }()
        // --- Found -> approach (LATCHED), else host-driven search (FR-54..56) ---
        // `freshDist` is a forward-facing reading used by the search relocate step, the host "reached"
        // trigger, and the memory record. Getting UNSTUCK is owned by `collisionEscape` in run().
        // A too-dark frame can't reliably confirm the goal — the VLM may HALLUCINATE "found the cat" in
        // the black and fire a false celebration. Don't accept approaching/done while low-light; keep
        // searching (the headlight + creep handle the dark). Resolves once the scene is lit enough.
        if lowLight, it.taskState == "approaching" || it.taskState == "done" { it.taskState = "searching" }
        var vlmSeesTarget = (it.taskState == "approaching" || it.taskState == "done")
        // Host "reached" -> DONE (guarantees the celebration fires when we arrive). During approach the
        // head TRACKS the target (often tilted down / off-forward), so `freshDist` (head-forward-gated)
        // is usually nil — instead use the RAW latest sonar (the head points AT the target, so a short
        // read = arrived) PLUS a turn-count fallback for soft targets the sonar can't echo.
        if approachLatched && !lowLight {   // never fire the "reached" DONE from a dark frame (false celebration)
            // #21/#15: only count turns where the target is actually IN VIEW (not brief-loss HOLD ticks),
            // so a flickering target can't fabricate "reached".
            if vlmSeesTarget { approachTurns += 1 }
            // #20: trust a short sonar as "arrived" ONLY when the head is roughly at/above drive tilt — a
            // steeply DOWN-tilted head (tracking a floor target) reads the near floor, not the target.
            let sonarNear = (car.distanceAt.map { Date().timeIntervalSince($0) < 1.5 } ?? false)
                            && (car.distance ?? 999) < 22 && curTilt >= driveTilt - 6
            if sonarNear || approachTurns >= approachDoneTurns {
                it.taskState = "done"; it.throttle = 0; it.steer = 0   // #5: stop AT the goal, don't overrun a pulse
                vlmSeesTarget = true
            }
        }

        if vlmSeesTarget {
            if !approachLatched { approachTurns = 0; pulseUntil = Date.distantPast }   // JUST FOUND -> kill the in-flight search pulse so the car doesn't coast/overshoot past the goal (the "time lag")
            approachLatched = true; approachLost = 0
            targetBearing = it.pan ?? curPan              // remember where the goal is
            if it.taskState != "done" {                   // FOUND but not yet confirmed -> HOLD in place, keep it framed. Do NOT drive toward it: driving overshot + lost it under the camera, then celebrated late (owner bug).
                it.throttle = 0; it.steer = 0; it.pan = targetBearing; it.taskState = "approaching"
            }
            searchPhase = .scan; scanIndex = 0            // reset the search for next time
            spotFan.removeAll(); relocateFailRun = 0      // approach owns motion now -> drop the stale distance fan
            lastTurnSign = 0; turnCommitCycles = 0        // approach owns motion -> drop the turn commitment
        } else if approachLatched {
            approachLost += 1
            if approachLost >= approachLostLimit {
                if approachTurns >= reachedOnLossTurns {  // lost AFTER genuinely closing in -> it went under the camera
                    it.taskState = "done"; it.throttle = 0; it.steer = 0   // AT the goal (low object) -> REACHED, celebrate
                } else {                                  // lost early (fleeting / false detection) -> resume host search
                    approachLatched = false; approachTurns = 0
                    searchPhase = .scan; scanIndex = 0; spotFan.removeAll(); relocateFailRun = 0
                    lastTurnSign = 0; turnCommitCycles = 0    // target lost early -> resume clean search
                }
            } else {                                      // briefly lost: HOLD & keep looking where it was
                it.throttle = 0; it.steer = 0; it.pan = targetBearing; it.taskState = "approaching"
            }
        }
        let inApproach = approachLatched
        if !inApproach { applySearch(&it, freshFwd: freshDist, scanSonar: scanSonar) }   // not found -> host drives the exploration

        // --- Head guards the direction of travel ---
        // Camera + sonar share the head, so force it FORWARD whenever the body moves (SAME tick, no
        // suppression — a center-first/settle scheme froze the car when the 300ms pulse fell inside
        // the 400ms settle). During the brief servo swing the firmware's own ~60ms sonar veto guards
        // the path. Free look only while stopped; approach/done exempt (may tilt down / track target).
        if escapePhase != .none {
            aim(pan: fwdPan, tilt: driveTilt)                        // escaping -> keep the sonar looking ahead
        } else if !inApproach {
            if it.throttle > 0.05 { aim(pan: fwdPan, tilt: driveTilt) }   // FORWARD drive -> head forward (guards travel)
            else if it.pan != nil || it.tilt != nil {                // stopped / pivot / reverse -> free look (sweep)
                aim(pan: it.pan ?? curPan, tilt: it.tilt ?? curTilt)
            }
        } else if it.pan != nil || it.tilt != nil {                  // approach -> model look (tilt down / track)
            aim(pan: it.pan ?? curPan, tilt: it.tilt ?? curTilt)
        }

        intent = it
        pulseUntil = Date().addingTimeInterval(Double(it.durationMs) / 1000.0)
        lastIntentAt = Date()
        report = it.observation; taskState = it.taskState
        if !it.observation.isEmpty { speech.speak(it.observation) }
        // Record the ACTION (head aim + drive + forward distance) so the VLM sees what it tried
        // and detects when the view is NOT changing (anti-loop). d is head-forward-gated ("?" while
        // scanning off-center — a sideways reading is not "forward").
        memory.append("look pan=\(curPan) tilt=\(curTilt) drove thr=\(String(format: "%.1f", it.throttle)) steer=\(String(format: "%.1f", it.steer)) d=\(freshDist.map { $0 >= 250 ? "clear" : "\(Int($0))cm" } ?? "?") -> \(it.taskState): \(it.observation)")
        if memory.count > 12 { memory.removeFirst(memory.count - 12) }
        // Don't quit the search on a single self-reported "blocked" (often spurious);
        // only give up after several in a row. "done" ends immediately.
        if it.taskState == "done" {
            goal = ""; blockedRun = 0; approachLatched = false; approachTurns = 0
            celebrate()                                       // rainbow gradient + victory jingle (face matrix removed)
        }
        else if it.taskState == "blocked" { blockedRun += 1; if blockedRun >= 3 { goal = "" } }
        else { blockedRun = 0 }
    }
    private var blockedRun = 0

    private func run() async {
        let tick = UInt64(1_000_000_000 / heartbeatHz)
        while !Task.isCancelled {
            if Date().timeIntervalSince(lastPowerPoll) >= 3.0 {   // battery poll (~3s)
                lastPowerPoll = Date()
                car.send(Dispatcher.powerQuery())
            }
            if Date().timeIntervalSince(lastLumaAt) >= 0.5 {      // ambient-light check (~2Hz)
                lastLumaAt = Date()
                if let img = car.image, let l = frameLuma(img) { lowLight = l < lowLightLuma }
            }
            // Distance poll (~3Hz). Poll while the head guards travel OR the model wants forward OR
            // we're mid-escape — the forward-intent branch forces the head forward anyway, so this
            // removes the settle dead-zone that used to let the car drive blind into a wall. FR-66: ALSO
            // poll during SCAN once the head has settled at the current scan angle, so each scan pan gets
            // its own distance (the old "forward-only" gate is thus widened to "settled at a scan angle").
            let scanRead = controlMode == .ai && !goal.isEmpty && !estop
                           && !approachLatched && searchPhase == .scan && headSettled
            let sonicRate = (intent.throttle > 0.05 || escapePhase == .reversing) ? 10.0 : sonicHz  // fast while driving -> catch the low-obstacle flicker
            if (headForward || intent.throttle > 0.05 || escapePhase != .none || approachLatched || scanRead),
               Date().timeIntervalSince(lastSonicPoll) >= 1.0 / sonicRate {   // also poll while approaching (reached-detect)
                lastSonicPoll = Date()
                car.send(Dispatcher.sonicQuery())          // fire-and-forget; reply parsed async in CarLink
            }

            // Keep the deadman fed while a timed teleop command OR a latched collision escape is running
            // (#18): otherwise the 500ms deadman fires between the ~1.4s decisions, hardBlock trips, and
            // collisionEscape resets to .none mid-reverse — reviving the "oscillate at the wall" bug.
            if Date() < cmdDriveUntil || (escapePhase != .none && controlMode == .ai) { lastIntentAt = Date() }
            if teleopDriving && Date() >= cmdDriveUntil && escapePhase == .none { teleopDriving = false }   // keep STOP visible until the escape also ends
            maybeDecide()   // non-blocking; runs the Vision call in its own Task

            // ---- arbiter / heartbeat (runs every ~100ms regardless of AI latency) ----
            let reason = safetyReason()
            let hardBlock = estop || reason != nil          // link/vision/deadman/low-batt/E-STOP win over everything
            // Fresh forward distance, independent of the headForward settle gate: while forward-intent
            // or escaping, the head is held forward (aim above), so a short reading IS an obstacle ahead.
            let freshFwd: Double? = {
                guard let d = car.distance, let at = car.distanceAt,
                      Date().timeIntervalSince(at) < 1.5, d >= 3 else { return nil }
                return d
            }()
            let approaching = (taskState == "approaching" || taskState == "done")
            // Frame-stuck: commanding forward but the view isn't changing -> pressed against a no-echo
            // obstacle. Force the escape (which always reverses a minimum distance). Not during approach
            // (soft contact = reaching the goal) or dark (frameMotion unreliable; headlight/creep handle it).
            let commandingForward = !hardBlock && !dryRun && !approaching && escapePhase == .none
                                    && Date() < pulseUntil && intent.throttle > 0.05
            // --- Voltage-sag (MEASURE-FIRST): fast-sample V while forward, self-calibrate the baseline between pulses ---
            if commandingForward { car.startFastVoltagePoll() } else { car.stopFastVoltagePoll() }
            let sagNow = Date()
            if commandingForward {
                if sagNow.timeIntervalSince(sagLastFwdAt) > sagRunGapMs / 1000.0 {         // new forward run after a real gap
                    sagForwardRunStart = sagNow; sagLoaded.removeAll(); sagStallSince = .distantPast
                }
                sagLastFwdAt = sagNow
                if sagNow.timeIntervalSince(sagForwardRunStart) > sagAccelSkipMs / 1000.0, // past accel inrush
                   let v = car.voltage, let at = car.voltageAt, at != sagLastVAt,
                   sagNow.timeIntervalSince(at) < 0.5, v > lowVoltage {                    // fresh, dedup'd, real (excludes USB ~1V)
                    sagLoaded.append((v, at)); sagLastVAt = at
                }
                sagLoaded.removeAll { sagNow.timeIntervalSince($0.at) > sagLoadWindowMs / 1000.0 }   // keep the rolling window
            } else {                                                                       // light load between runs -> learn baseline
                sagStallSince = .distantPast
                if let v = car.voltage, let at = car.voltageAt, at != sagLastVAt,
                   sagNow.timeIntervalSince(at) < 1.0, v > lowVoltage {
                    sagBaseline = sagBaselineN == 0 ? v : sagBaseline + sagBaselineAlpha * (v - sagBaseline)
                    sagBaselineN += 1; sagLastVAt = at
                }
            }
            if commandingForward, !lowLight, car.frameMotion < motionStuckMin,
               (car.frameMotionAt.map { Date().timeIntervalSince($0) < 1.0 } ?? false) {
                if lowMotionSince == .distantPast { lowMotionSince = Date() }
                else if Date().timeIntervalSince(lowMotionSince) > stuckMs / 1000.0 {
                    escapePhase = .reversing; escapeStart = Date()          // back off the no-echo obstacle
                    escapeSign = intent.steer >= 0 ? 1.0 : -1.0
                    lowMotionSince = .distantPast
                }
            } else { lowMotionSince = .distantPast }
            // Low-obstacle best-effort: >= lowObstacleHits RAW near reads in the window while driving forward =
            // a low object flickering into the beam -> reverse (same escape as frame-stuck). MIN-based so it
            // catches the near flickers the median smooths away; the >=2 gate rejects single-spike noise.
            let lowObsHits = commandingForward ? car.nearCount(closerThan: lowObstacleCm, within: lowObstacleWindowMs / 1000.0) : 0
            if commandingForward, escapePhase == .none, lowObsHits >= lowObstacleHits {
                escapePhase = .reversing; escapeStart = Date()
                escapeSign = intent.steer >= 0 ? 1.0 : -1.0
                dbg("[LOWOBS] \(lowObsHits) near reads < \(Int(lowObstacleCm))cm -> reverse")
            }
            // Voltage-sag trigger: forward-loaded pack sits a sustained delta below the light-load baseline ->
            // pressed against an immovable (often sonar-invisible / dark) obstacle. Camera-free = the only dark
            // backstop. Same escape write as frame-stuck. Actuation gated by sagArmed (MEASURE-FIRST = log only).
            if commandingForward, sagBaselineN >= sagBaselineInitSamples, sagLoaded.count >= sagMinLoadedSamples {
                let loadedMean = sagLoaded.map { $0.v }.reduce(0, +) / Double(sagLoaded.count)
                let delta = sagBaseline - loadedMean
                if sagNow.timeIntervalSince(sagLastLogAt) > 0.33 {                          // ~3Hz calibration log
                    sagLastLogAt = sagNow
                    dbg("[SAG] base=\(String(format: "%.2f", sagBaseline)) load=\(String(format: "%.2f", loadedMean)) d=\(String(format: "%.2f", delta)) n=\(sagLoaded.count) low=\(lowLight) armed=\(sagArmed)")
                }
                if delta > sagV, sagNow >= sagCooldownUntil {
                    if sagStallSince == .distantPast { sagStallSince = sagNow }
                    else if sagNow.timeIntervalSince(sagStallSince) > sagSustainMs / 1000.0 {
                        if sagArmed, escapePhase == .none {                                 // ARMED -> reverse (same as frame-stuck)
                            escapePhase = .reversing; escapeStart = Date()
                            escapeSign = intent.steer >= 0 ? 1.0 : -1.0
                            dbg("[SAG] STALL -> reverse  d=\(String(format: "%.2f", delta))")
                        } else {
                            dbg("[SAG] STALL detected (unarmed, no action)  d=\(String(format: "%.2f", delta))")
                        }
                        sagStallSince = .distantPast; sagLoaded.removeAll()
                        sagCooldownUntil = sagNow.addingTimeInterval(sagCooldownMs / 1000.0)
                    }
                } else if delta <= sagV {
                    sagStallSince = .distantPast                                            // recovered -> reset the sustain timer
                }
            }
            let escapeLine = collisionEscape(freshFwd: freshFwd, approaching: approaching, hardBlock: hardBlock)

            let driving = !hardBlock && (escapeLine != nil || Date() < pulseUntil)
            let line: String
            if hardBlock                 { line = Dispatcher.stop() }
            else if let esc = escapeLine { line = esc }                     // escape OVERRIDES the model (fast, latched)
            else if Date() < pulseUntil  { line = Dispatcher.drive(throttle: intent.throttle, steer: intent.steer, speedCap: speedCap, trim: motorTrim) }
            else                         { line = Dispatcher.stop() }
            if !dryRun { car.send(line) }
            // Show a safety reason only when it's a real block; the deadman is normal at
            // idle (no goal) so it reads as "hold" there, not an alarming status.
            if estop { statusKey = "status.estop" }
            else if driving { statusKey = "status.driving" }
            else if let r = reason, !(r == "safety.deadman" && goal.isEmpty) { statusKey = r }
            else { statusKey = "status.hold" }

            updateLeds(estop: estop, reason: reason, driving: driving && !dryRun)   // motion LEDs only when actually moving
            if Date().timeIntervalSince(lastDbgAt) > 0.5 {   // ~2Hz brain-state trace
                lastDbgAt = Date()
                dbg("goal=\(goal.isEmpty ? "-" : "y") phase=\(searchPhase) esc=\(escapePhase) ts=\(taskState) thr=\(String(format: "%.2f", intent.throttle)) str=\(String(format: "%.2f", intent.steer)) pan=\(curPan) tilt=\(curTilt) dist=\(car.distance.map { String(Int($0)) } ?? "-") low=\(lowLight) hops=\(corridorHops) drive=\(driving) escFired=\(escapeLine != nil) block=\(hardBlock) dry=\(dryRun) :: \(report.prefix(40))")
            }
            try? await Task.sleep(nanoseconds: tick)
        }
    }
}
