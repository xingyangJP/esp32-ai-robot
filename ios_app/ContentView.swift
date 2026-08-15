import SwiftUI
import AuthenticationServices

struct ContentView: View {
    @StateObject private var ctl = RobotController()
    var body: some View {
        MainView(ctl: ctl, speech: ctl.speech)
            .environment(\.locale, ctl.uiLocale)   // in-app language override (ja/en)
            .preferredColorScheme(.dark)            // glass-over-camera is a dark visual world
    }
}

/// Frosted-glass panel (Liquid Glass look). On iOS 26 swap `.ultraThinMaterial`
/// for `.glassEffect()` for the true system material.
private extension View {
    func glass(_ radius: CGFloat = 22) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // dark scrim UNDER the frosted material so white text stays legible over any
        // camera frame (bright or dark) — .ultraThinMaterial alone is too transparent.
        return self
            .background(.ultraThinMaterial, in: shape)
            .background(Color.black.opacity(0.42), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
    }
}

struct MainView: View {
    @ObservedObject var ctl: RobotController
    @ObservedObject var speech: Speech

    @State private var goalText = ""
    @State private var showConfig = false

    var body: some View {
        ZStack {
            feed.ignoresSafeArea()
            GridOverlay().opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                statusPill
                if ctl.lowBatteryActive { lowBatteryBanner }
                telemetry
                modeToggle
                Spacer()
                if ctl.controlMode == .manual {
                    ManualControlsView(ctl: ctl)           // manual: pads instead of the goal input
                } else {
                    reportCard
                    inputBar                               // goal typing only in AI mode
                }
                actionButton
            }
            .padding()
            .foregroundStyle(.white)
        }
        .sheet(isPresented: $showConfig) { ConfigView(ctl: ctl, discovery: ctl.discovery, auth: ctl.auth) }
        .onChange(of: speech.transcript) { _, new in goalText = new }
        .task { ctl.start() }   // connect + stream on launch (dry-run keeps it safe)
    }

    @ViewBuilder private var feed: some View {
        if let img = ctl.image {
            // MUST drive size from a flexible Color: a bare scaledToFill Image reports its
            // filled (overflowing) size — here ~1162pt wide for a 240x176 frame on a portrait
            // screen — which widens the ZStack and pushes every off-center HUD item off-screen.
            // Color.clear reports the offered (screen) size; the image overlays + clips to it.
            Color.clear
                .overlay { Image(uiImage: img).resizable().scaledToFill() }
                .clipped()
        } else {
            ZStack { Color.black; Text("video.none").foregroundStyle(.white.opacity(0.5)) }
        }
    }

    private func dot(_ on: Bool) -> some View {
        Circle().fill(on ? .green : .red).frame(width: 8, height: 8)
            .accessibilityLabel(Text(on ? "a11y.connected" : "a11y.disconnected"))
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            dot(ctl.cmdConnected); Text("cmd")
            dot(ctl.camConnected); Text("cam")
            Text(LocalizedStringKey(ctl.statusKey)).monospaced().opacity(0.8)
            Spacer()
            if ctl.linkMode == .remote {
                Text("badge.remote").font(.caption2.bold()).foregroundStyle(.cyan)
            }
            if let v = ctl.voltage {
                Text(String(format: "%.1fV", v)).font(.caption2.bold())
                    .foregroundStyle(ctl.lowBatteryActive ? .red : .white.opacity(0.7))
            }
            if ctl.dryRun { Text("DRY").font(.caption2.bold()).foregroundStyle(.yellow) }
            Button { showConfig = true } label: {
                Image(systemName: "gearshape").foregroundStyle(.white)
            }.accessibilityLabel(Text("a11y.settings"))
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glass(20)
    }

    // Prominent low-battery alert: the safety reflex blocks ALL motion below the cutoff, so say so.
    private var lowBatteryBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("banner.lowBattery")
            if let v = ctl.voltage { Text(String(format: "%.1fV", v)).monospaced() }
            Spacer()
        }
        .font(.callout.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var telemetry: some View {
        Text("240×176 · pan \(ctl.curPan)° · tilt \(ctl.curTilt)° · " +
             (ctl.distance.map { $0 >= 250 ? "no echo" : "\(Int($0))cm" } ?? "—"))
            .font(.caption2.monospaced()).opacity(0.9)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glass(12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeToggle: some View {
        Picker("mode", selection: $ctl.controlMode) {
            Text("mode.ctl.ai").tag(ControlMode.ai)
            Text("mode.ctl.manual").tag(ControlMode.manual)
        }
        .pickerStyle(.segmented)
        .padding(4)
        .glass(14)
    }

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey("state." + ctl.taskState))
                .font(.caption2.bold()).opacity(0.8)
            Text(ctl.report.isEmpty ? "…" : ctl.report).font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glass()
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("goal.placeholder", text: $goalText, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16).frame(minHeight: 44)
                .glass(22)
            Button {
                speech.toggle()
            } label: {
                Image(systemName: speech.listening ? "mic.fill" : "mic")
                    .foregroundStyle(speech.listening ? .red : .white)
                    .frame(width: 44, height: 44)
            }
            .glass(22)
            .accessibilityLabel(Text("a11y.voice"))
            Button { ctl.setGoal(goalText); goalText = "" } label: {
                Text("btn.send").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 44)
            }
            .background(.blue.opacity(0.7), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
            .disabled(goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // Start/Stop toggle: STOP (red) only while a goal is being pursued (car may move),
    // START (green) when idle/stopped — so STOP is always present exactly when it matters.
    private var actionButton: some View {
        let manualActive = ctl.controlMode == .manual && ctl.running && !ctl.estop
        let teleopActive = ctl.teleopDriving && ctl.running && !ctl.estop   // #2/#6: a voice/text teleop pulse is driving
        let active = ctl.isMissionActive || manualActive || teleopActive    // STOP reachable whenever the car can move
        return Button {
            if active { ctl.emergencyStop() }
            else { ctl.resume(typed: goalText); goalText = "" }
        } label: {
            Label(active ? "btn.stop" : "btn.start", systemImage: active ? "stop.fill" : "play.fill")
                .font(.title3.bold()).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 56)
        }
        .background((active ? Color.red : Color.green).opacity(0.82),
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.15), value: active)
    }
}

/// Manual controls: left = hold-to-drive D-pad; right = tap-to-nudge camera pad.
struct ManualControlsView: View {
    @ObservedObject var ctl: RobotController
    var body: some View {
        HStack(spacing: 14) {
            drivePad
            cameraPad
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .glass()
    }
    private var drivePad: some View {
        VStack(spacing: 4) {
            HoldDpadButton(system: "chevron.up.circle.fill", a11y: "a11y.drive.fwd",
                           hold: { ctl.manualForward() }, release: { ctl.manualStop() })
            HStack(spacing: 4) {
                HoldDpadButton(system: "chevron.left.circle.fill", a11y: "a11y.drive.left",
                               hold: { ctl.manualLeft() }, release: { ctl.manualStop() })
                Image(systemName: "car.fill").foregroundStyle(.white.opacity(0.45))
                    .frame(width: 48, height: 48)
                HoldDpadButton(system: "chevron.right.circle.fill", a11y: "a11y.drive.right",
                               hold: { ctl.manualRight() }, release: { ctl.manualStop() })
            }
            HoldDpadButton(system: "chevron.down.circle.fill", a11y: "a11y.drive.back",
                           hold: { ctl.manualBackward() }, release: { ctl.manualStop() })
        }
    }
    private var cameraPad: some View {
        VStack(spacing: 4) {
            // Hold to pan/tilt; bigger step at a lower rate (dedup + .common timer = smooth, no flood).
            HoldDpadButton(system: "arrow.up", a11y: "a11y.cam.up",
                           hold: { ctl.nudgeCamera(dPan: 0, dTilt: 12) }, release: {}, interval: 0.15)
            HStack(spacing: 4) {
                HoldDpadButton(system: "arrow.left", a11y: "a11y.cam.left",
                               hold: { ctl.nudgeCamera(dPan: -12, dTilt: 0) }, release: {}, interval: 0.15)
                camTap("dot.circle", "a11y.cam.center") { ctl.centerHead() }
                HoldDpadButton(system: "arrow.right", a11y: "a11y.cam.right",
                               hold: { ctl.nudgeCamera(dPan: 12, dTilt: 0) }, release: {}, interval: 0.15)
            }
            HoldDpadButton(system: "arrow.down", a11y: "a11y.cam.down",
                           hold: { ctl.nudgeCamera(dPan: 0, dTilt: -12) }, release: {}, interval: 0.15)
        }
    }
    private func camTap(_ system: String, _ a11y: LocalizedStringKey,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.title2).foregroundStyle(.white).frame(width: 48, height: 48)
        }
        .glass(14)
        .accessibilityLabel(Text(a11y))
    }
}

/// Ref-type pulse engine. A `live` flag (not value-captured @State) makes deferred
/// timer fires no-op after release, and stop() invalidates the timer — so a
/// teardown-while-held (mode switch, backgrounding) can NEVER leave the car driving.
@MainActor final class Pulser: ObservableObject {
    private var timer: Timer?
    private var live = false
    func start(_ hold: @escaping () -> Void, interval: TimeInterval = 0.1) {
        live = true
        hold()
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.live == true { hold() } }
        }
        RunLoop.main.add(t, forMode: .common)   // fire during long-press tracking, not just idle
        timer = t
    }
    func stop(_ release: () -> Void) {
        guard live || timer != nil else { return }
        live = false
        timer?.invalidate(); timer = nil
        release()
    }
    deinit { timer?.invalidate() }
}

/// Fires `hold` ~10 Hz while pressed, `release` on lift. Each drive pulse self-expires,
/// AND the pulser stops on release / view-disappear / background — a missed release
/// (e.g. the pad removed on a mode switch) still stops the car.
struct HoldDpadButton: View {
    let system: String
    let a11y: LocalizedStringKey
    let hold: () -> Void
    let release: () -> Void
    var interval: TimeInterval = 0.1        // drive pad keeps 0.1; camera pad passes 0.15
    var size: CGFloat = 48
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var pulser = Pulser()
    @GestureState private var isDown = false     // SwiftUI resets this to false on gesture end AND cancel
    @State private var pressed = false
    var body: some View {
        Image(systemName: system)
            .font(.title2).foregroundStyle(.white)
            .frame(width: size, height: size)
            .glass(16)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(pressed ? 0.85 : 0.0), lineWidth: 1.5))
            .accessibilityLabel(Text(a11y))
            .contentShape(Rectangle())
            // DragGesture(minimumDistance:0) fires on touch-down and always resets isDown on
            // lift/cancel — unlike onLongPressGesture, which wedges under rapid taps (went dead).
            .gesture(DragGesture(minimumDistance: 0).updating($isDown) { _, s, _ in s = true }.onEnded { _ in })
            .onChange(of: isDown) { _, down in
                pressed = down
                if down { pulser.start(hold, interval: interval) } else { pulser.stop(release) }
            }
            .onDisappear { pressed = false; pulser.stop(release) }        // mode-switch/removal backstop
            .onChange(of: scenePhase) { _, phase in                      // backgrounding backstop
                if phase != .active { pressed = false; pulser.stop(release) }
            }
    }
}

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                for i in 1..<3 { let x = w * CGFloat(i) / 3; p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: h)) }
                for i in 1..<3 { let y = h * CGFloat(i) / 3; p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: w, y: y)) }
            }.stroke(.white, lineWidth: 0.5)
        }
    }
}

struct ConfigView: View {
    @ObservedObject var ctl: RobotController
    @ObservedObject var discovery: Discovery
    @ObservedObject var auth: AuthStore
    @Environment(\.dismiss) private var dismiss
    @State private var showArmConfirm = false
    @State private var showSetupModeInfo = false
    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("settings.linkMode", selection: $ctl.linkMode) {
                        Text("mode.lan").tag(LinkMode.lan)
                        Text("mode.remote").tag(LinkMode.remote)
                    }
                    if ctl.linkMode == .remote {
                        // Relay URL is a fixed built-in endpoint (not shown). Remote setup
                        // is just Sign in with Apple: the relay pairs the phone and the home
                        // bridge by the SAME signed-in uid. Paste this uid into the bridge's
                        // config.toml `owner_uid`.
                        if let uid = auth.uid {
                            LabeledContent("settings.signedIn", value: auth.email ?? "Apple ID")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("settings.ownerUid").font(.caption).foregroundStyle(.secondary)
                                Text(verbatim: uid).font(.caption.monospaced()).textSelection(.enabled)
                            }
                            Button("settings.signOut", role: .destructive) { auth.signOut() }
                        } else {
                            SignInWithAppleButton(.signIn,
                                onRequest: { req in auth.configureRequest(req) },
                                onCompletion: { res in auth.handleCompletion(res) })
                                .signInWithAppleButtonStyle(.whiteOutline)
                                .frame(height: 44)
                            if let err = auth.errorMessage {
                                Text(verbatim: err).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                } header: {
                    Text("settings.section.mode")
                } footer: {
                    Text(ctl.linkMode == .remote ? "mode.remote.hint" : "mode.lan.hint")
                }
                Section("settings.section.car") {
                    TextField("settings.carIP", text: $ctl.carIP)
                        .disabled(ctl.linkMode == .remote)
                    Button("settings.findCar") { ctl.findCar() }
                        .disabled(ctl.linkMode == .remote)
                    Text(LocalizedStringKey(discovery.status))
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper(value: $ctl.speedCap, in: 1600...4095, step: 100) {
                        Text(String(format: NSLocalizedString("settings.speedCap", comment: ""), ctl.speedCap))
                    }
                    // Remote arming (dry-run OFF) needs an explicit "you're moving an
                    // unseen car" confirmation (FR-64/NFR-29); LAN toggles immediately.
                    Toggle("settings.dryRun", isOn: Binding(
                        get: { ctl.dryRun },
                        set: { on in
                            if ctl.linkMode == .remote && on == false { showArmConfirm = true }
                            else { ctl.dryRun = on }
                        }))
                }
                Section {
                    NavigationLink("wifi.entry") {
                        WiFiSetupView(onProvisioned: {
                            // Car switched networks: drop the current link + re-discover on the new one.
                            ctl.stopAll(); ctl.findCar()
                        }, onSuspendLink: {
                            ctl.stopAll()   // free the car's single-client :4000 socket for probeCar
                        })
                    }
                    .disabled(ctl.linkMode == .remote)
                    // Force the car into setup mode over the CURRENT link (so you can set a new
                    // network before moving). Away from known WiFi the car does this on its own.
                    Button("wifi.enterSetup") { ctl.enterWiFiSetup(); showSetupModeInfo = true }
                        .disabled(ctl.linkMode == .remote || !ctl.cmdConnected)
                } header: {
                    Text("wifi.entry.header")
                } footer: {
                    Text("wifi.entry.footer")
                }
                Section("settings.section.ai") {
                    SecureField("settings.apiKey", text: $ctl.apiKey)
                    TextField("settings.model", text: $ctl.model)
                }
                Section("settings.section.language") {
                    Picker("settings.language", selection: $ctl.lang) {
                        Text("lang.auto").tag("auto")
                        Text(verbatim: "English").tag("en")
                        Text(verbatim: "日本語").tag("ja")
                    }
                }
                if ctl.linkMode == .lan {
                Section {
                    Toggle("calib.swap", isOn: $ctl.servoSwap)
                        .accessibilityLabel(Text("a11y.calib.swap"))
                    Toggle("calib.panInvert", isOn: $ctl.panInvert)
                        .accessibilityLabel(Text("a11y.calib.panInvert"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("calib.pan"); Text(verbatim: "\(ctl.panNeutral)°").font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { Double(ctl.panNeutral) },
                            set: { ctl.panNeutral = Int($0); ctl.calibratePan(Int($0)) }
                        ), in: 0...180, step: 1, onEditingChanged: { editing in
                            if !editing { ctl.calibratePan(ctl.panNeutral, force: true) }
                        })
                        .accessibilityLabel(Text("a11y.calib.pan"))
                        .accessibilityValue(Text(verbatim: "\(ctl.panNeutral)"))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("calib.tilt"); Text(verbatim: "\(ctl.tiltNeutral)°").font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { Double(ctl.tiltNeutral) },
                            set: { ctl.tiltNeutral = Int($0); ctl.calibrateTilt(Int($0)) }
                        ), in: 0...180, step: 1, onEditingChanged: { editing in   // FULL raw range: level ~95, up ~170
                            if !editing { ctl.calibrateTilt(ctl.tiltNeutral, force: true) }
                        })
                        .accessibilityLabel(Text("a11y.calib.tilt"))
                        .accessibilityValue(Text(verbatim: "\(ctl.tiltNeutral)"))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("calib.trim")
                        Text(verbatim: String(format: "%+.2f", ctl.motorTrim))
                            .font(.caption).foregroundStyle(.secondary)
                        Slider(value: $ctl.motorTrim, in: -0.30...0.30, step: 0.02)
                            .accessibilityLabel(Text("a11y.calib.trim"))
                            .accessibilityValue(Text(verbatim: String(format: "%.2f", ctl.motorTrim)))
                    }
                    Button("calib.center") { ctl.centerHead() }
                        .accessibilityLabel(Text("a11y.calib.center"))
                } header: {
                    Text("settings.section.calib")
                } footer: {
                    Text("calib.hint")
                }
                }
                Section {
                    Button("btn.reconnect") { ctl.stopAll(); ctl.start() }
                    Button("btn.stopAll", role: .destructive) { ctl.stopAll() }
                } footer: {
                    Text(verbatim: "RobotBrain  v\(Self.appVersion)")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("settings.title")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("btn.done") { dismiss() } } }
            .confirmationDialog("arm.confirm.title", isPresented: $showArmConfirm, titleVisibility: .visible) {
                Button("arm.confirm.action", role: .destructive) { ctl.dryRun = false }
                Button("btn.cancel", role: .cancel) { }
            } message: { Text("arm.confirm.msg") }
            .alert("wifi.setupmode.title", isPresented: $showSetupModeInfo) {
                Button("btn.done") { }
            } message: { Text("wifi.setupmode.msg") }
        }
        .environment(\.locale, ctl.uiLocale)
    }
}
