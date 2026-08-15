> **Note.** The ESP32 firmware is a not-included Freenove derivative — `firmware/…` paths below are *descriptive*, not files in this repo. This feature is **shipped** (app v1.1.54): the car reboots into pure STA and the app confirms it on the network (status strings `idle | switching:<ssid> | fail:auth | fail:no_ap`).

# WiFi Provisioning Design (in-app WiFi setup)

> Status: **Shipped — verified end-to-end on the real car (app v1.1.54; the firmware reboots into pure STA, runs a short diagnostic, and waits for an IP).** Setup mode → SoftAP → SET → reboot into pure STA → connect using the credentials saved in NVS → re-discovery: all confirmed in the serial log. The root cause (AP_STA channel pinning) was confirmed by measurement on the car.
> Goal: let the car (ESP32) **join a new WiFi network from the app alone** — no re-flash needed when you move house, visit a different home, or change routers.

---

## 1. Background (pre-feature baseline — now resolved)

> This section describes the state of the code *before* in-app provisioning shipped. Everything below has since been implemented; it is kept for context. The firmware is a not-included Freenove derivative, so firmware paths are descriptive.

- **App side: no WiFi provisioning UI/logic at all** (nothing SSID-related in `ios_app/*.swift`).
- **Firmware side: credentials hardcoded.** `WiFi_Init()` in the sketch read `WIFI_ROUTER_SSID/PASS` from `firmware/AI_Car_Firmware/wifi_secrets.h` and called `WiFi_Setup(0)` = **connect to a fixed router in STA mode**. A SoftAP name (`"Sunshine"`) was defined but unused at boot. **No NVS persistence and no WiFi scan.**
- The car advertises mDNS `robotbrain.local`, a command server on TCP `:4000` (`#`-delimited `CMD_*`), and a video stream on `:7000`. The app's `CarLink` connects to `carIP` (default `robotbrain.local`).
- **Problem**: changing WiFi required editing `wifi_secrets.h` and re-flashing over USB — poor portability.

---

## 2. Requirements

**FR**
- FR-P1: From the app, **set the SSID/password** the car connects to (no USB / re-flash).
- FR-P2: The SSID can be **picked from a list the car scanned** (iOS cannot scan WiFi, so the car supplies it). Manual entry (hidden SSID) is also allowed.
- FR-P3: The credentials are **saved in the car's NVS (non-volatile)** and persist across reboots.
- FR-P4: After setup the car connects to the new WiFi in STA mode, and **the app confirms the connection succeeded** before returning to normal mode.
- FR-P5: **Failure fallback**: no credentials / connection failure / STA unreachable for a while → the car re-enters SoftAP provisioning mode (re-enterable, never gets stuck).
- FR-P6: The app **automates the network hop** (car AP ⇄ home WiFi) **as much as possible** (`NEHotspotConfiguration`). Where that's not possible, it shows manual steps.

**NFR**
- NFR-P1: **2.4 GHz only** (the ESP32 has no 5 GHz radio) — stated in the UI; 5 GHz SSIDs are flagged.
- NFR-P2: Do not break existing LAN / Remote / discovery behavior (provisioning is a separate mode).
- NFR-P3: Security: the SoftAP has a password (so a neighbor can't reconfigure it); the password travels only inside the local AP and is stored as NVS plaintext (device standard). Never printed to logs.
- NFR-P4: The setup entry point is reachable from either app mode (LAN or Remote).

---

## 3. Key constraints (stated plainly, no overselling)

1. **An iOS app cannot scan WiFi** (no public API to list nearby SSIDs; NEHotspotHelper is MFi-only). → **The car (ESP32 `WiFi.scanNetworks()`) scans and returns the list to the app.**
2. **The phone crosses networks twice**: home WiFi → car AP (setup) → home WiFi (normal). They must be on the same network to talk. `NEHotspotConfigurationManager` lets the app request "join this AP" (**requires the entitlement `com.apple.developer.networking.HotspotConfiguration`**; iOS shows a confirmation dialog). The return to home WiFi is automatic: the app joins the car AP with `joinOnce = true`, so iOS drops the car AP and rejoins the previous network on its own when the AP disappears — **the app never needs the home password**.
3. **The `#`-delimiter problem (the design's crux)**: existing CMDs are `#`-delimited. **A WiFi password/SSID can itself contain `#` or delimiters**, so `CMD_WIFI_SET#ssid#pass` would break. → **base64-encode the fields** (`CMD_WIFI_SET#<b64ssid>#<b64pass>`). **Mandatory.**
4. While on the SoftAP the phone has no internet (Remote/cloud are unavailable — setup is purely local).
5. mDNS re-discovery: after returning to STA the app re-finds the car at `robotbrain.local` (robust to DHCP IP changes).

---

## 4. Architecture / state machine

### 4.1 Car firmware state machine (descriptive — firmware is a not-included Freenove derivative)
```
[BOOT]
  └─ NVS credentials present?
       ├─ yes → try STA connect (up to STA_TRY_MS, e.g. 20 s)
       │         ├─ success → [NORMAL]  (mDNS advertise, :4000 / :7000, all existing behavior)
       │         └─ fail / timeout → [PROVISION]
       └─ no  → [PROVISION]

[PROVISION]  (SoftAP "RobotBrain-setup" with a password; the :4000 command server keeps running)
  ├─ CMD_WIFI_SCAN                  → return the neighbor SSID list (base64 tab/newline table)
  ├─ CMD_WIFI_SET#b64ssid#b64pass   → save to NVS → REBOOT INTO PURE STA to join
  │         (next boot: STA joins → [NORMAL];  STA fails → back to [PROVISION], and the
  │          firmware keeps the reason so the next CMD_WIFI_STATUS returns fail:auth / fail:no_ap)
  ├─ CMD_WIFI_STATUS                → idle | switching:<ssid> | fail:auth | fail:no_ap | fail:<n>
  ├─ CMD_WIFI_FORGET                → clear NVS → reboot into SoftAP setup
  └─ (an idle / no-op session never gets stuck — it stays in PROVISION until credentials arrive)
```
- **Provisioning also uses `:4000`** (no extra HTTP server — it rides on the existing convention). The SoftAP address is the default `192.168.4.1`.
- **Why reboot into *pure* STA rather than switch in place?** AP_STA (concurrent AP+STA) cannot reliably associate while the phone pins the AP's channel — this was the confirmed root cause. So on `CMD_WIFI_SET` the car saves the creds, drops the AP, and reboots into pure STA. Success is therefore *not* reported by status polling (the AP is gone); the app confirms by re-finding the car on the network. After a successful join the car re-advertises mDNS.

### 4.2 App flow
1. In Settings, tap **"Set up the car's WiFi"** (`wifi.entry` → `WiFiSetupView`). Disabled in Remote mode (the car AP has no internet, so setup is LAN-only).
2. The app calls `NEHotspotConfiguration` to **join the car AP `RobotBrain-setup`** (passphrase `robotbrain`, `joinOnce = true`; iOS shows a join dialog). If the entitlement/capability is unavailable, it falls back to on-screen **"join it manually in Settings"** instructions.
3. The app connects to `192.168.4.1:4000`, sends `CMD_WIFI_SCAN`, and **shows the SSID list**. It also reads `CMD_WIFI_STATUS`: if a **prior** attempt failed, it surfaces the reason (wrong password / SSID not found) as a hint. The user picks an SSID and types the password (a leading/trailing space is trimmed before sending).
4. The app sends `CMD_WIFI_SET#<b64ssid>#<b64pass>`. The firmware replies `accepted`.
5. The app **suspends the main LAN link** (so it won't fight the confirmation probe for the car's single-client `:4000` socket) and releases the car AP. The car saves the creds and **reboots into pure STA** to join. Because `joinOnce` was set, the phone **automatically returns to its previous (home) WiFi** when the car AP drops — no home password needed.
6. After ~6 s the app **confirms** by re-finding the car on the network: it polls `robotbrain.local:4000` with `CMD_POWER` for up to ~40 s (`probeCar`).
   - reachable → success. The app re-discovers the car via mDNS and returns to normal mode. ✅
   - not reachable within the window → **"unconfirmed"** (the car may be on a different network, or it failed to join). The user can retry.
7. Cancel/back at any stage leaves the flow; the phone returns to its home WiFi on its own.

> There is also a **"Force setup mode"** control (`wifi.enterSetup`): over the current LAN link it sends `CMD_WIFI_FORGET`, which clears the car's saved credentials and reboots it into SoftAP setup — handy for choosing a new network *before* you move. It's disabled in Remote mode and when the command link isn't connected.

---

## 5. Wire protocol (provisioning CMDs — firmware-side names are descriptive; the firmware header is a not-included Freenove derivative)

| CMD | Args | Response | Purpose |
|---|---|---|---|
| `CMD_WIFI_SCAN` | none | `CMD_WIFI_SCAN#<b64 of "ssid1\trssi1\tenc1\nssid2\t…">` | Neighbor AP list (SSIDs base64 for non-ASCII); the enc field is `open` for an open network |
| `CMD_WIFI_SET` | `#<b64ssid>#<b64pass>` | `CMD_WIFI_SET#accepted` | Received → save to NVS → reboot into pure STA |
| `CMD_WIFI_STATUS` | none | `CMD_WIFI_STATUS#idle\|switching:<ssid>\|fail:auth\|fail:no_ap\|fail:<n>` | Last provisioning outcome held in the SoftAP. There is no `ok:<ip>` — success is confirmed by re-discovery after the reboot, not by polling. |
| `CMD_WIFI_FORGET` | none | (fire-and-forget) | Clear NVS → reboot into SoftAP setup (debug / relocation / the "Force setup mode" button) |

- **base64 is mandatory** (to survive `#` / newline / non-ASCII, §3-3). The existing `#`-split parser is used unchanged; only the values are base64-wrapped, which is safe.
- **`switching:<ssid>`** is the transient state the firmware reports while it is attempting to associate; **`fail:auth`** = wrong password, **`fail:no_ap`** = SSID not found (wrong band/channel/hidden/out of range), **`fail:<n>`** = other failure with the numeric WiFi status code.
- The password is **never printed to serial / debug** (NFR-P3).

---

## 6. Implementation map (files → what shipped)

**Firmware (`firmware/AI_Car_Firmware/` — descriptive; a not-included Freenove derivative)**
1. Provisioning CMD defines: `CMD_WIFI_SCAN / SET / STATUS / FORGET`.
2. A WiFi-provisioning unit (`wifi_provision.{h,cpp}`): uses `Preferences` (NVS, namespace `"wifi"`) to read/write `ssid`/`pass`; tracks `provisionStatus` (idle / switching / fail); `startSoftAP()` brings up `RobotBrain-setup` **with a password**; `tryConnectSTA(ssid, pass, STA_TRY_MS)`; `scanToB64()`.
3. The sketch:
   - `setup()` / WiFi init: **NVS credentials take priority** (present → try STA; fail/absent → SoftAP provisioning). A `wifi_secrets.h` value remains a **first-run fallback default** (used only when NVS is unset) so existing behavior isn't broken.
   - Command dispatch handles `CMD_WIFI_*` (parsed like the other CMDs, replies like `CMD_POWER`).
   - The `:4000` accept loop runs during provisioning too (same server, SoftAP or STA). On `CMD_WIFI_SET` the car saves the creds and **reboots into pure STA**; on a successful join it re-advertises mDNS.
4. `wifi_secrets.h.example`: a comment notes the value is only an initial default used when NVS is unset.

**App (`ios_app/`)**
5. Entitlement `com.apple.developer.networking.HotspotConfiguration` (`RobotBrain.entitlements`, declared in `project.yml`).
6. `WiFiSetupView.swift` (reached from Settings, or offered when the car can't be found): the flow state machine (join AP → scan list → pick SSID / enter password → send → suspend link + leave AP → wait for reboot → confirm by re-discovery → success / unconfirmed / failed). Includes 2.4 GHz guidance and surfaces a prior attempt's fail reason.
7. `WiFiProvisioner.swift` (an `NEHotspotConfigurationManager` wrapper + a one-shot TCP client to `:4000`): `joinCarAP()` (joinOnce), `scan()`, `setCreds()` (base64), `status()`, `leaveCarAP()`, and `probeCar()` (re-find the car on the network). Provisioning uses its own connection, separate from the normal LAN link.
8. Wiring in `ContentView` / `RobotController`: `onSuspendLink` stops the main link so it doesn't fight `probeCar` for the car's single-client `:4000` socket; `onProvisioned` drops the current link and re-discovers on the new network. `enterWiFiSetup()` sends `CMD_WIFI_FORGET` over the LAN link.
9. `Discovery` (mDNS): triggers `robotbrain.local` re-discovery after the car returns to STA.
10. Localizations (ja/en): setup copy, error text, and the "return to your home WiFi manually" fallback (only needed when NEHotspot is unavailable).

---

## 7. Failures & edge cases

- **Wrong password / out of range**: the firmware reports `fail:auth` / `fail:no_ap` and the car falls back to SoftAP; the next scan surfaces the reason so re-entry isn't an opaque "couldn't connect". The car never gets stuck.
- **NEHotspotConfiguration unavailable** (entitlement missing, or the user declines the join dialog): the app shows "join `RobotBrain-setup` manually in Settings", then continues once the phone is on the car AP.
- **Returning to home WiFi**: automatic via `joinOnce` — the phone rejoins its previous network on its own when the car AP drops (no home password needed).
- **Confirmation times out**: if `probeCar` can't reach the car within the window, the app shows an **"unconfirmed"** state (the car may be on a different network or failed to join); the user can retry from the top.
- **Picked a 5 GHz SSID**: warned up front; the attempt reports `fail:no_ap`.
- **`#` / non-ASCII / emoji in SSID or password**: avoided by base64 (§3-3).
- **Multiple devices on the SoftAP**: single-client assumed (the existing `:4000` server is single-client).
- **Security**: the SoftAP is password-protected; traffic stays inside the local AP; NVS stores plaintext (standard); the password is never logged.
- **Preserving existing behavior**: when NVS is unset, the car still connects using the `wifi_secrets.h` fallback in STA — the current behavior is unchanged (staged migration).

---

## 8. Confirmed on the real car (E2E verified)

- `NEHotspotConfiguration` behaves as designed on-device (join dialog + automatic return via `joinOnce`), with the `com.apple.developer.networking.HotspotConfiguration` entitlement.
- The SoftAP ⇄ STA transition is stable via the **reboot-into-pure-STA** approach; AP_STA channel pinning (the reason a plain in-place switch failed) was confirmed by measurement.
- The scan list renders as expected (RSSI, hidden SSIDs), and the 2.4 GHz-only limitation holds in practice.
- The phone's automatic return to the home WiFi works in the user's environment (no home password required, thanks to `joinOnce`).
- With NVS unset, the `wifi_secrets.h` fallback still connects without regression (staged migration verified).

---

## 9. Decisions (finalized as shipped)

- **A. Transport**: existing `:4000` + base64 CMDs (chosen — keeps "from the app alone" as the priority), rather than a small HTTP/captive server on the SoftAP.
- **B. Network-hop automation**: automatic via `NEHotspotConfiguration` with `joinOnce` (chosen), rather than manual-only instructions.
- **C. Provisioning entry**: automatic SoftAP on "NVS unset or STA failed" (chosen), *and* it can be forced over the current link with `CMD_WIFI_FORGET` ("Force setup mode").
- **D. SoftAP identity**: fixed SSID `RobotBrain-setup` with a fixed password (`robotbrain`).

Shipped configuration: **A = CMD (base64), B = automatic, C = automatic (STA-fail fallback) + forced via `CMD_WIFI_FORGET`, D = fixed SSID + password.**
