import SwiftUI

/// In-app WiFi provisioning flow (see WIFI_PROVISIONING_DESIGN.md §6).
/// join car setup AP → scan → pick SSID + password → CMD_WIFI_SET → poll status → done.
/// The phone auto-returns to the home WiFi (joinOnce), so on success the caller just re-discovers.
struct WiFiSetupView: View {
    /// Called after the car accepted new creds and switched — wire to a re-discover/reconnect.
    var onProvisioned: (() -> Void)? = nil
    /// Called when we're about to confirm on the home network — suspend the main LAN link so it
    /// doesn't fight probeCar for the car's single-client :4000 socket.
    var onSuspendLink: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var prov = WiFiProvisioner()

    enum Step { case intro, joining, manual, scanning, pick, sending, switching, confirming, success, unconfirmed, failed }
    @State private var step: Step = .intro
    @State private var aps: [WiFiProvisioner.AP] = []
    @State private var selectedSSID = ""
    @State private var password = ""
    @State private var showPass = false
    @State private var message = ""
    @State private var resultIP = ""
    @State private var lastFail = ""          // firmware-reported reason a PRIOR attempt failed (auth/no_ap)

    var body: some View {
        Form {
            switch step {
            case .intro:    introSection
            case .joining:  progress("wifi.joining")
            case .manual:   manualSection
            case .scanning: progress("wifi.scanning")
            case .pick:     pickSection
            case .sending:    progress("wifi.sending")
            case .switching:  progress("wifi.switching")
            case .confirming: progress("wifi.confirming")
            case .success:    successSection
            case .unconfirmed: unconfirmedSection
            case .failed:     failedSection
            }
        }
        .navigationTitle("wifi.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: sections
    private var introSection: some View {
        Section {
            Text("wifi.intro.body")
            Button("wifi.intro.start") { Task { await startJoin() } }
        } footer: { Text("wifi.intro.footer") }
    }

    private var manualSection: some View {
        Section {
            Text("wifi.manual.body")
            if !message.isEmpty {
                Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
            }
            Button("wifi.manual.continue") { Task { await doScan() } }
        } header: { Text("wifi.manual.header") }
    }

    private var pickSection: some View {
        Group {
            if !lastFail.isEmpty {
                Section {
                    Label(lastFailHint, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
            }
            Section("wifi.pick.network") {
                if aps.isEmpty {
                    Text("wifi.pick.empty").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(aps) { ap in
                    Button { selectedSSID = ap.ssid } label: {
                        HStack(spacing: 8) {
                            Text(verbatim: ap.ssid)
                            Spacer()
                            if !ap.open { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                            signalIcon(ap.rssi)
                            if ap.ssid == selectedSSID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                Button("wifi.pick.rescan") { Task { await doScan() } }
            }
            Section("wifi.pick.creds") {
                TextField("wifi.pick.ssid", text: $selectedSSID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    Group {
                        if showPass { TextField("wifi.pick.password", text: $password) }
                        else { SecureField("wifi.pick.password", text: $password) }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { showPass.toggle() } label: {
                        Image(systemName: showPass ? "eye.slash" : "eye")
                    }.buttonStyle(.borderless)
                }
                Button("wifi.pick.send") { Task { await sendCreds() } }
                    .disabled(selectedSSID.isEmpty)
            }
        }
    }

    private var successSection: some View {
        Section {
            Label("wifi.success.title", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            if !resultIP.isEmpty { LabeledContent("wifi.success.car", value: resultIP) }
            Text("wifi.success.body")
            Button("wifi.success.done") { onProvisioned?(); dismiss() }
        }
    }

    private var unconfirmedSection: some View {
        Section {
            Label("wifi.unconfirmed.title", systemImage: "questionmark.circle.fill").foregroundStyle(.orange)
            Text("wifi.unconfirmed.body")
            Button("wifi.unconfirmed.retry") { message = ""; step = .intro }
            Button("wifi.success.done") { onProvisioned?(); dismiss() }
        } footer: { Text("wifi.unconfirmed.footer") }
    }

    private var failedSection: some View {
        Section {
            Label("wifi.failed.title", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            if !message.isEmpty { Text(verbatim: message).font(.caption).foregroundStyle(.secondary) }
            Button("wifi.failed.retry") { step = .pick }
        }
    }

    private func progress(_ key: LocalizedStringKey) -> some View {
        Section { HStack(spacing: 10) { ProgressView(); Text(key) } }
    }

    private func signalIcon(_ rssi: Int) -> some View {
        let bars = rssi >= -55 ? 1.0 : rssi >= -70 ? 0.66 : 0.33
        return Image(systemName: "wifi", variableValue: bars).foregroundStyle(.secondary)
    }

    // MARK: actions
    @MainActor private func startJoin() async {
        step = .joining
        if let err = await prov.joinCarAP() {
            message = err
            step = .manual                       // NEHotspot unavailable → manual join instructions
            return
        }
        try? await Task.sleep(for: .seconds(1.5)) // let iOS associate + DHCP on the car AP
        await doScan()
    }

    @MainActor private func doScan() async {
        step = .scanning
        aps = await prov.scan()
        // If a PRIOR provisioning attempt failed, the firmware still holds the reason in SoftAP —
        // surface it so a wrong password / wrong-band SSID isn't an opaque "couldn't connect".
        if let st = await prov.status(), st.hasPrefix("fail") { lastFail = st } else { lastFail = "" }
        step = .pick
    }

    /// Friendly hint for the firmware's fail reason ("fail:auth" | "fail:no_ap" | "fail:<n>").
    private var lastFailHint: LocalizedStringKey {
        if lastFail.contains("auth") { return "wifi.fail.auth" }
        if lastFail.contains("no_ap") { return "wifi.fail.noap" }
        return "wifi.fail.other"
    }

    @MainActor private func sendCreds() async {
        step = .sending
        guard let r = await prov.setCreds(ssid: selectedSSID, pass: password) else {
            message = NSLocalizedString("wifi.err.noreply", comment: ""); step = .failed; return
        }
        guard r.hasPrefix("accepted") else { message = r; step = .failed; return }
        // The car saved the creds and reboots into pure STA to join (AP_STA can't associate reliably
        // while the phone pins the AP channel). Release the car AP so the phone returns to its WiFi,
        // then confirm by re-finding the car on the network. Suspend the main LAN link first so it
        // doesn't fight probeCar for the car's single-client :4000 socket during confirmation.
        onSuspendLink?()
        prov.leaveCarAP()
        step = .switching
        try? await Task.sleep(for: .seconds(6))   // phone reassociates to home WiFi + car boots into STA
        step = .confirming
        if await prov.probeCar(timeout: 40) {
            resultIP = WiFiProvisioner.mdnsHost
            step = .success
        } else {
            step = .unconfirmed                   // car may be on a different network, or it failed to join
        }
    }
}
