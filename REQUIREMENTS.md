# RobotBrain Requirements Specification

- Document version: 1.1 (quality-acceptance addendum)
- Target app: RobotBrain (iOS native / SwiftUI)
- Bundle ID: `com.example.robotbrainai`
- Created: 2026-07-24
- Positioning: This document specifies the requirements. A "shall" statement in the text is a requirement on the implementation; wherever the current code differs, the gap is called out explicitly in Appendix A. Code tokens (`CMD_MOTOR`, etc.) and class names (`RobotController`, etc.) are written verbatim.

---

## 1. Purpose and Scope

### 1.1 Purpose
RobotBrain is a controller app for an AI rover that operates the Freenove 4WD ESP32 chassis (FNK0053, ESP32-WROVER) **from an iPhone alone**. When the user gives a goal in natural language — **by text or by voice** — an OpenAI vision model looks at one camera frame and plans the next action, and the app lowers that action into chassis commands and sends them. It runs the deliberative "look → decide → move a little → look again" loop on the premise that latency is acceptable.

### 1.2 Scope summary
- **Target**: the software requirements of the RobotBrain iOS app (SwiftUI, iPhone portrait).
- **Core functions**: dual TCP connection to the chassis (command / camera), live video display, text/voice goal entry, the deliberative autonomous loop via OpenAI Vision, semantic-command → `CMD_*` translation, HRI output such as LED cues, in-app servo calibration, an always-visible emergency stop, a default-ON dry-run, host-side safety reflexes, and EN/JA bilingual support. Two transports are supported as **equals**: **LAN** (direct TCP to the car) and **Remote** (WSS via the Cloud Run relay and the home bridge). The normative specification for Remote operation is `REMOTE.md`.
- **Operating premise**: indoor, flat, low-speed, supervised. In **LAN** mode the iPhone and the chassis are on the same home Wi-Fi (2.4 GHz, STA mode); in **Remote** mode the phone reaches the car through the relay + home bridge from anywhere with internet access (see `REMOTE.md`). Single-owner personal use.
- **Central challenges**: (a) latency-tolerant vision-driven autonomy, (b) safety design that uses the HC-SR04 forward distance sensor while assuming it is limited against low / soft / angled / non-reflective obstacles, (c) absorbing — via in-app calibration — the fact that on this individual unit the pan/tilt servos are swapped.
- **Out-of-scope highlights**: chassis firmware implementation, on-device ML/SLAM, distance-sensor-dependent high-speed avoidance, cloud operation over SoftAP, multi-user / general distribution, iPad / landscape (details in §8).

### 1.3 System configuration (division of roles)
The system is organized in three layers. RobotBrain owns the middle **broker (brain-host) layer** at runtime and requires no Mac to run. In LAN mode the broker runs on the phone; in Remote mode the home bridge holds the broker role and the phone acts as a thin operator client (the normative Remote spec is `REMOTE.md`).

- **Reflex layer (chassis / ESP32)**: motor and servo PWM, JPEG capture, the TCP command server, on-device deadman stop and stop-and-hold on disconnect. It runs no ML inference.
- **Broker layer (RobotBrain / iPhone — or the home bridge in Remote mode)**: holds the TCP connection to the chassis, receives and displays the camera, calls the vision model, translates and clamps semantic commands into `CMD_*` strings, and runs the host-side reflexes (safety monitor).
- **Cortex layer (OpenAI vision model / cloud)**: looks at the frame and returns a structured action intent (`Intent`).

### 1.4 Scope boundary
This document covers only the software requirements of the RobotBrain iOS app. The chassis firmware implementation is out of scope but is referenced as an external interface constraint the app depends on (§7.1). The firmware is a not-included Freenove derivative; it is described here descriptively only, and its source is not part of this repository.

---

## 2. Target Users and Usage Context

### 2.1 Target users
- A single owner (personal use), whose primary language is either Japanese or English.
- The builder/assembler themselves, with enough technical literacy to configure the chassis IP and the OpenAI API key.
- General distribution / multi-user operation is not assumed.

### 2.2 Usage context
- **Indoor, low-speed, supervised** operation. A flat floor with no steps or stairs.
- In **LAN** mode the iPhone and the chassis are on the **same home Wi-Fi (2.4 GHz)**, with the chassis joining the home router in STA mode. In **Remote** mode the phone reaches the car through the Cloud Run relay + home bridge, so the phone need not be on the car's LAN (the normative Remote spec is `REMOTE.md`). SoftAP (`Sunshine`) cannot reach the cloud and is not used for operation.
- The user holds the iPhone in one hand and drives while watching the live video (portrait-locked).
- Motor drive works only with the battery installed (2× 18650). On USB power, video / camera / face display / comms can be verified, but the wheels, servos, and body LEDs do not move.

---

## 3. Glossary

| Term | Meaning |
|---|---|
| Goal | The natural-language objective the user gives, entered by text or voice. |
| Intent (`Intent`) | The structured next action the vision model returns (throttle/steer/duration/pan/tilt/face/observation/task_state). |
| Decision tick | The periodic moment the vision model is called (`decisionHz` = 0.7 Hz). |
| Heartbeat | The high-frequency cycle that emits commands to the chassis (`heartbeatHz` = 10 Hz). |
| Pulse drive | A short, self-expiring drive instruction (treated as auto-stopped once `duration_ms` elapses). |
| Dry-run | A safe mode that plans, speaks, and logs but sends no motor-drive command. |
| Host-side reflex | The in-app safety monitor (linkDown / visionStale / deadman / lowBattery). |

---

## 4. Requirements Summary Tables

### 4.1 Functional requirements (FR) summary

| Category | Requirement IDs | Overview |
|---|---|---|
| Connectivity / comms (Wi-Fi/TCP) | FR-1–FR-7 | Hold dual TCP connections — command (4000) / camera (7000); `#`-delimited + `\n` send; auto-reconnect at ~1 s intervals; connection-state indicators; IP editing + persistence; JPEG frame receive; start/stop sequences |
| Live camera display | FR-8–FR-12 | Full-screen JPEG display, no-video placeholder, 3×3 reference grid, telemetry strip, retention of the frame-receive timestamp |
| Goal entry (text & voice) | FR-13–FR-17 | Text send (no empty string), STT start/stop with incremental display, locale following, permission requests, goal-commit handling |
| AI Vision autonomous loop | FR-18–FR-27 | ~0.7 Hz Vision calls, input composition, `Intent` interpretation with safe fallback, semantic → `CMD_*` central translation, self-expiring pulses, pan/tilt head aim, observation/state display + TTS, done/blocked handling, memory, differential-drive conversion |
| Expression / body output (HRI) | FR-28–FR-29 | LED-matrix face interface, body-LED / buzzer send interface |
| Servo calibration | FR-30–FR-34 | pan/tilt swap toggle, neutral offsets + real-time confirmation, settings persistence, real-axis resolution in `look()`, tilt real-travel mapping |
| Emergency stop | FR-35–FR-37 | Always-visible STOP, AI-independent immediate stop, dry-run/state-independent, settings "stop all" |
| Dry-run (safe default) | FR-38–FR-40 | No drive send, default ON + ON every launch, DRY badge |
| Host-side safety reflexes | FR-41–FR-43 | Stop on linkDown/visionStale/deadman/lowBattery, `CMD_POWER` monitoring, state reflected in the HUD |
| Settings | FR-44–FR-47 | Per-item editing, speed-cap range, API-key masking, persistence policy |
| Bilingual support (EN/JA) | FR-48–FR-50 | Full UI localization, language picker, AI/TTS/STT language following |
| Quality acceptance criteria | FR-57–FR-65 | STOP state reset, direct movement commands, collision escape, low-light limits, completion celebration, trace management |

### 4.2 Non-functional requirements (NFR) summary

| Category | Requirement IDs | Overview |
|---|---|---|
| Latency and performance | NFR-1–NFR-4 | 0.5–2 s/tick tolerated, 10 Hz heartbeat, HQVGA 10–15 fps, low-resolution Vision calls |
| Safety | NFR-5–NFR-8 | Stop is fully in-app, no default motion, double clamping, supervised-premise UI |
| API key / security | NFR-9–NFR-11 | No hardcoding, `UserDefaults` storage (unencrypted, risk stated), no key/PII in logs or URLs |
| Network / DHCP | NFR-12–NFR-13 | IP-drift premise + reconnect + state visibility, shared LAN + local-network permission |
| Platform / build | NFR-14–NFR-16 | SwiftUI portrait, iOS 17.0 target / Xcode 26 · XcodeGen, no Mac at runtime |
| Accessibility | NFR-17–NFR-18 | VoiceOver labels, Dynamic Type · adequate contrast |
| Localization | NFR-19–NFR-20 | Consistent EN/JA, new strings added in both languages · no hardcoding |
| Reliability / robustness | NFR-21–NFR-22 | No crash on failure · fail-safe fallback, connection-holding design against the patched firmware |
| Visual design (Liquid Glass) | NFR-23–NFR-24 | Full-screen video + frosted HUD · dark base, robot-render app icon |

---

## 5. Functional Requirements (FR)

### 5.1 Connectivity / Comms (Wi-Fi / TCP)

- **FR-1**: The app shall establish and hold two TCP connections to the chassis's IPv4 address (which may drift under DHCP) via `CarLink`: a command connection (port `4000`) and a camera connection (port `7000`).
- **FR-2**: Command sends shall be a single line of ASCII text with `#`-delimited fields, with a trailing newline (`\n`) appended (appending the newline is `CarLink`'s responsibility). Ordinary commands are fire-and-forget; `CMD_POWER` and `CMD_SONIC` return a response line.
- **FR-3**: If either connection becomes `failed`, the app shall attempt auto-reconnect at roughly 1 s intervals with no user action. On an explicit `cancelled` (an app-initiated disconnect) it shall not reconnect.
- **FR-4**: The connection state of each of the command and camera connections (`cmdConnected` / `camConnected`) shall be shown persistently in the UI as an indicator (green = connected / red = disconnected) — the HUD "cmd" / "cam" dots.
- **FR-5**: The user shall be able to edit the chassis IP in the settings screen; after a change, a reconnect action (`btn.reconnect`) applies it. The IP shall be persisted (`UserDefaults` key `carIP`).
- **FR-6**: The camera stream shall be received as frames of the form "a 4-byte little-endian length prefix + that many JPEG bytes." A length of 0 or less, or 4,000,000 bytes or more, shall be discarded as an invalid frame.
- **FR-7**: At app start (`ctl.start()`) the command and camera connections shall be opened and `CMD_VIDEO#1` sent to begin the video stream. On stop (`stopAll()`) the app shall send a stop command and `CMD_VIDEO#0` and close both connections.

### 5.2 Live Camera Display

- **FR-8**: The received JPEG frame shall be decoded and shown as the background across the entire screen (`scaledToFill`). The HUD panels shall float above the video.
- **FR-9**: When no video has been received, a black background and a "video.none" (no video) placeholder shall be shown.
- **FR-10**: A 3×3 reference grid (`GridOverlay`) shall be overlaid faintly on the video.
- **FR-11**: A telemetry strip (resolution · pan angle · tilt angle) shall be shown in the HUD. The displayed values shall reflect the actual state (resolution, current pan/tilt angles).
- **FR-12**: The receive timestamp of the latest frame (`lastFrameAt`) shall be retained and used for the host-side video-stall (visionStale) determination.

### 5.3 Goal Entry (Text & Voice)

- **FR-13**: The user shall be able to enter a goal in the text field and commit it with the send button (`btn.send`). Sending an empty string (whitespace only) shall not be allowed.
- **FR-14**: The mic button shall start/stop speech recognition (STT, `SFSpeechRecognizer`) and reflect the recognized text (`transcript`) into the input field. Recognition shall display partial results incrementally.
- **FR-15**: The recognition locale shall follow the selected language (`ja-JP` for Japanese, `en-US` for English).
- **FR-16**: On first use of the mic, microphone and speech-recognition permissions shall be requested.
- **FR-17**: On goal commit (`setGoal`), leading/trailing whitespace shall be stripped, recent memory (`memory`) cleared, the emergency-stop flag (`estop`) cleared, and the control loop started if it is not already running.

### 5.4 AI Vision → Action Autonomous Loop

- **FR-18**: When a goal is set, there is no emergency stop, and a video frame is available, the app shall — each decision cycle (~0.7 Hz) — call OpenAI's Vision chat-completions API (`https://api.openai.com/v1/chat/completions`) via `Brain.decide`.
- **FR-19**: The input to the model shall be: the system prompt (its role as the cortex + the output JSON schema), the goal, recent memory (**the latest 12 entries**), and a single JPEG frame (`detail: "low"`). The model name shall follow the user setting (default `gpt-4o-mini`).
- **FR-20**: The model shall return exactly one JSON object, which the app interprets into an `Intent` (throttle -1..1 / steer -1..1 / duration_ms 100..800 / pan 0..180 / tilt 0..180 / observation / task_state, plus the fused-exploration fields forward_open 0..1 and hazard reported while searching — see FR-67). On unparseable output it shall fall back to the safe side (`Intent.hold` = full stop). (A legacy `face` field is still tolerated by the parser but the model is no longer prompted for it and it is not dispatched — see FR-23.)
- **FR-21**: The model shall not output raw motor numbers; it emits only semantic actions. `Dispatcher` alone owns the semantic → `CMD_*` translation, clamping, and dead-zone handling, so the model cannot emit an illegal or dangerous command directly.
- **FR-22**: Drive shall be treated as a **self-expiring pulse**. Each decision tick receives `duration_ms` and sets `pulseUntil` to now + duration; the heartbeat sends no drive (treated as stopped) once `pulseUntil` has passed. Even if a tick is delayed or fails, the chassis auto-stops.
- **FR-23**: When a decision includes pan/tilt, the head shall be aimed via `Dispatcher.look()` (through `aim()`). A semantic LED-matrix face interface exists (`Dispatcher.face()` / `Dispatcher.faceModes`), but the live autonomy loop does **not** dispatch a matrix face; human-robot expression (HRI) is carried by body-LED cues instead (see FR-28/FR-29 and `LedLanguage`).
- **FR-24**: `observation` (observation text) and `task_state` (searching / approaching / done / blocked) shall be shown in the HUD, and the observation shall be read aloud by TTS.
- **FR-25**: When `task_state` becomes `done`, the goal shall be cleared and the autonomous loop returned to the stopped (hold) state. `blocked` shall not end the mission on a single occurrence; the goal is abandoned only when it recurs several times in a row (current criterion: 3 consecutive).
- **FR-26**: Recent observations shall be kept as memory (**up to 12 entries; on overflow the oldest are dropped**) and included in the next decision input.
- **FR-27**: Differential drive shall convert throttle/steer (each -1..1, +throttle = forward / +steer = right) into a left/right tank pair and send it in the form `CMD_MOTOR#<left>#0#<right>`.

#### 5.4.1 Exploration strategy (scan & relocate)

> Background: FR-18–27 define the deliberative "look → decide → move a little → look again" loop and the `task_state` labels, but **how to search when the goal is not found (the exploration strategy) was left undefined** and delegated to the VLM prompt. As a result, on the real car the loop would "stop and sweep the head" without a loop that moves to a new spot and searches again. Just as making collision avoidance a deterministic host state machine stabilized it, exploration is likewise **guaranteed structurally on the host**. This is a **separate concern** from collision avoidance.

- **FR-54 (Search state machine: scan & relocate)**: While the goal is an object search and the VLM cannot see the goal in the current frame (`task_state=searching` / `blocked`), the **host shall drive exploration with a deterministic state machine**. During this time the VLM's role narrows to the perceptual judgment "can the goal be seen?", and the throttle/steer/pan/tilt it returns are treated as advisory (the host overrides them). The state machine shall satisfy at least the following:
  1. **SCAN (sweep in place)**: with the chassis stopped (throttle 0), sweep the head pan across a prescribed arc (multiple angles, within this unit's reachable hemisphere, including up/down tilt variation), giving the VLM one decision to judge visibility at each angle. If a full pass finds nothing, transition to RELOCATE. It shall not keep circling the same spot.
  2. **RELOCATE (move to a new spot)**: first return the head to front (pan 90 / drive tilt) to fix the forward distance; if the front is open (sonar distance ≥ the prescribed clearance threshold), move to a new spot with a short forward pulse. If the front is blocked, pivot in place to reorient toward a new heading. After one action, return to SCAN.
  3. **Repeat**: SCAN again at the new spot, touring the room spot by spot.
- **FR-55 (Yield of exploration)**: The moment the VLM sees the goal and returns `task_state=approaching` / `done`, the host shall immediately release the search state machine and yield the drive decision (throttle/steer/pan/tilt) to the VLM (approach and arrival remain the VLM's job as before). Goal commit (`setGoal`), STOP, stop-all, and mode switch shall reset the search state.
- **FR-56 (Safety subordination of exploration)**: The search state machine shall be subordinate to the collision-avoidance reflex (FR — host escape), E-STOP, dry-run, deadman, and low-voltage stop (priority SAFETY > search). RELOCATE's forward pulse shall be protected by the firmware forward veto (<20 cm) plus the host collision escape (<25 cm).

#### 5.4.2 Fused exploration (camera × distance sensor)

> Background: the FR-54–56 search decides its heading from a single forward ultrasonic beam and cannot use the camera's scene information (when blocked, it pivots blindly). Because the ultrasonic sensor is co-mounted on the same pan/tilt head as the camera, **sweeping the head measures distance in each direction**. Fusing this with the VLM's semantic understanding makes the search smarter. The design is in DESIGN.md §16. With no odometry/IMU, **no persistent spatial map (SLAM) is built** — only transient local judgments at each spot.

- **FR-66 (Acquire a distance fan)**: During a search scan, after the head settles at each pan angle, **read the ultrasonic distance in that heading**, attribute it to the pan angle, and hold it transiently (`spotFan`). Discard it on leaving the spot; do not persist it. The "front only" gate on distance polling shall be widened so that a reading can be taken whenever the head has settled at each scan angle.
- **FR-67 (VLM per-direction perception)**: For each search frame the VLM shall return the **openness `forward_open` (0..1)** and the **`hazard` (none/soft/ledge/wall)** of the direction the head currently faces. The host fuses these with the distance fan to decide the heading (the VLM does not emit drive values while searching).
- **FR-68 (Direction selection by fusion)**: In RELOCATE, each direction is scored by "ultrasonic distance (normalized) × camera openness," with a **cross-check** applied (sonar near-range < threshold = a real obstacle, excluded / sonar clear but low VLM openness = a soft obstacle, penalized / VLM open but sonar near = sonar wins), and the best direction is chosen. If it is lateral, pivot the body to bring it to front before driving forward.
- **FR-69 (Degraded behavior)**: When every direction is closed/low-scoring, degrade gradually (one step toward the farthest direction → if several rounds fail, consider `blocked`) and avoid falling into an endless pivot.
- **FR-70 (Fusion fallback in the dark)**: In low light (low frame luma), lower the confidence of the VLM's visibility/openness (shrink the fusion weight W_VLM toward 0) and fall back to sonar-led + creep + headlight. Do not emit false approaching/done (retain the low-light guard).
- **FR-71 (Safety subordination / parity of fused exploration)**: Fused exploration only produces an `Intent`; the arbiter makes the final drive decision, and E-STOP, dry-run, deadman, low-voltage, collision escape, and the firmware forward veto all sit above it. Behavior shall be identical on LAN (Swift) and Remote (Python).

### 5.5 Expression / Body Output (HRI)

- **FR-28**: The LED-matrix face shall be controllable via `CMD_MATRIX_MOD#<mode>`, with semantic names (off/rotate/cry/smile/wheel_r/wheel_l/blink/random) mapped to mode numbers by `Dispatcher.faceModes`. This interface exists for completeness; the current autonomous loop does not drive the matrix face — HRI is carried by body-LED cues (FR-29).
- **FR-29**: A send interface shall be provided for the body LEDs (`CMD_LED_MOD`) and the buzzer (`CMD_BUZZER`, variable tone only; the blocking `Buzzer_Alert` is not used).

### 5.6 In-App Servo Calibration

> Background: on this individual unit the pan/tilt servos are **swapped** relative to the firmware's assumption. servo1 (ch0) = TILT (up/down), servo2 (ch1) = PAN (left/right). Pan's front neutral is roughly 90°; tilt's level is measured at roughly 95° (smaller = down, larger = up). Because `CMD_CAMERA`'s axis meanings do not match this unit, precise control is done with two `CMD_SERVO` commands. Calibration must be adjustable **in-app rather than by re-flashing**.

- **FR-30**: The settings screen shall provide a **pan/tilt swap toggle**; when ON, semantic pan is assigned to servo2 (ch1) and semantic tilt to servo1 (ch0).
- **FR-31**: The settings screen shall provide adjustment sliders for the **pan neutral (front) offset** and the **tilt level offset**. Operating a slider shall move the target servo **in real time** using `CMD_SERVO#<index>#<angle>` for confirmation.
- **FR-32**: The swap setting and the pan/tilt neutral offsets shall be persisted (`UserDefaults`).
- **FR-33**: `Dispatcher.look()` (semantic pan/tilt → real command) shall resolve each axis through the swap setting and the neutral offsets and issue `CMD_SERVO#<index>#<angle>` against the correct physical axis and travel range (not bound by `CMD_CAMERA`'s fixed axis assignment or tilt lower limit). Angles shall be clamped to 0–180°.
- **FR-34**: Semantic tilt shall treat 90° as level, above 90° as up, and below 90° as down, mapping onto this unit's measured level (raw ≈ 95°). The settings slider shall span the full raw 0–180° range and safely migrate the old level value on existing devices.

### 5.7 Emergency Stop

- **FR-35**: A large, always-visible STOP button (`btn.stop`) shall be placed at the bottom of the screen. Pressing it shall immediately send `CMD_MOTOR#0#0#0` (stop), set `estop`, clear the goal, and set the status display to `status.estop`.
- **FR-36**: The emergency stop shall be able to send the stop command regardless of whether dry-run is on or off and regardless of the autonomous loop's state (stopping must not depend on an AI decision that goes over a network round-trip).
- **FR-37**: The settings screen shall provide "stop all" (`btn.stopAll`) to stop the loop, send the stop command, stop video, and close the connections in one action.

### 5.8 Dry-Run (Safe Default)

- **FR-38**: A dry-run mode shall be provided; when ON it shall send no motor-drive command (no `CMD_MOTOR` drive values) and shall only plan, display observations, run TTS, send head/expression commands, and log.
- **FR-39**: Dry-run shall default to ON and return to ON every app launch (it is not persisted in a way that starts up OFF). This keeps the car safe to operate even without the battery installed.
- **FR-40**: The HUD shall clearly indicate dry-run is active (a "DRY" badge).

### 5.9 Host-Side Safety Reflexes

- **FR-41**: Each heartbeat shall evaluate safety conditions and stop drive (`CMD_MOTOR#0#0#0`) if any of the following holds:
  - Command link down (`safety.linkDown`)
  - Video stall: time since the latest frame exceeds `visionStaleMs` (800 ms) (`safety.visionStale`)
  - Deadman: time since the last intent update exceeds `deadmanMs` (500 ms) (`safety.deadman`)
  - Low voltage: low-battery detected (`safety.lowBattery`)
- **FR-42**: For low-battery detection, `CMD_POWER` shall be sent about every 3 s, its reply `CMD_POWER#<voltage>` received and parsed, and drive stopped when the calibrated voltage is below 6.6 V. The UI shall make the stop reason clear with a voltage badge and a low-voltage banner.
- **FR-43**: The current safety/drive state (linkDown / visionStale / deadman / lowBattery / driving / hold / estop / idle) shall be reflected in the HUD status display.

### 5.10 Settings

- **FR-44**: The settings screen (`ConfigView`) shall allow editing of: chassis IP, link mode (LAN / Remote), speed cap (`speedCap`), dry-run, the OpenAI API key, model name, language, and servo calibration (swap · neutral offsets). The AI ↔ Manual control-mode selector is presented in the HUD (`modeToggle`); both link mode and control mode are persisted (see FR-47).
- **FR-45**: The speed cap shall be adjustable over 1600–4095 in steps of 100. The default is 2000.
- **FR-46**: OpenAI API-key entry shall be masked (`SecureField`).
- **FR-47**: Of the settings, carIP / apiKey / model / lang / linkMode / controlMode / speedCap / panInvert / motorTrim / servo calibration shall be persisted. Dry-run shall reset to its safe default (dry-run = ON) every launch.

### 5.11 Bilingual Support (EN / JA)

- **FR-48**: Every UI string shall be displayable in Japanese and English via `LocalizedStringKey` and `Localizable.strings` under `en.lproj` / `ja.lproj`.
- **FR-49**: The settings screen shall provide a language picker (Automatic / English / 日本語). On "Automatic," resolve to Japanese when the device locale is Japanese and to English otherwise.
- **FR-50**: The selected language shall be applied across the whole UI as the environment locale (`.environment(\.locale, …)`), and the AI response (`observation`) generation language, the TTS voice language, and the STT recognition locale shall all follow it.

### 5.12 Quality Acceptance Criteria (safety · state transitions · celebration)

- **FR-57 (STOP state reset)**: STOP / stopAll / mode switch / AI↔Manual switch shall stop or invalidate all of: the drive pulse, direct teleop, collision escape, the search, the approach latch, an unfinished Vision decision, the TTS queue, and the completion celebration. After START, reconnect, or a mode switch, the car shall not re-drive without a fresh user action.
- **FR-58 (STOP visibility conditions)**: STOP shall be pressable while an AI goal is executing, while driving in Manual mode, during a natural-language direct movement pulse, during collision escape, and during the completion celebration. When idle it may revert to START, but STOP must not be hidden while the car could move.
- **FR-59 (Direct movement commands)**: "reverse for 2 seconds," "go forward," "turn right," "stop," etc. shall be treated as timed direct teleop rather than goal search, pausing the AI loop. Conversely, search phrasings like "find the person standing still" or "find the bus stop" shall not be captured by a drive keyword and shall be treated as ordinary goals. Direct reverse is a rescue action and is therefore exempt from the forward collision veto, but it remains subordinate to E-STOP, low voltage, and dry-run.
- **FR-60 (Collision escape)**: When the AI intends to go forward and the forward distance — fresh within 1.5 s — falls below 25 cm normally (below 32 cm in low light), the 10 Hz arbiter shall latch a collision escape. The escape consists of reversing (up to 1.4 s, cleared past 40 cm) → an in-place pivot (~0.65 s), and shall not stall waiting on a Vision decision. The firmware shall refuse forward drive under 20 cm.
- **FR-61 (Scope of the distance sensor)**: The HC-SR04 measures only the head's forward direction. While moving forward, return the head to a forward posture to measure, and do not misuse a sideways/downward distance as "forward." The rear, the sides, floor edges, stairs, and low / soft / thin / angled / glass / cloth / no-echo obstacles are not guaranteed and are covered by low-speed, short-pulse, supervised operation.
- **FR-62 (Low-light mode)**: When the frame's mean luma is below 55, low light is declared, the white headlight is turned on, and the search/relocate forward drive is made slower and shorter than usual (current: throttle 0.30, 250 ms, forward-clear 65 cm). Low-light mode is not a full collision guarantee but a risk reduction where the camera sees poorly.
- **FR-63 (Manual / AI switch)**: Every switch between Manual and AI shall insert a stop and shall not carry over an old goal, search, approach, teleop, or escape state. Merely pressing START from Manual must not resurrect an old AI goal.
- **FR-64 (TTS)**: TTS normally reads the latest observation aloud, but on STOP / stopAll / new goal / mode switch it shall stop immediately so an old utterance does not trail on afterward. Duplicate-observation readouts shall be suppressed, and TTS shall never delay a drive stop.
- **FR-65 (done celebration)**: On reaching `done`, the car shall stop, and on LAN a WS2812 rainbow and a short fanfare may play for under 5 s. STOP / new goal / mode switch / stopAll shall stop the celebration immediately and return the LED state to the normal safety cues.

---

## 6. Non-Functional Requirements (NFR)

### 6.1 Latency and Performance
- **NFR-1**: A latency of roughly 0.5–2 s per cognitive tick (mostly the Vision API call) shall be **tolerated**. The decision cycle is a deliberative loop at 0.5–2 Hz (default 0.7 Hz).
- **NFR-2**: The heartbeat (command send / safety evaluation) shall run at about 10 Hz and shall not be affected by AI-response delay.
- **NFR-3**: The camera display shall use HQVGA (240×176) at a practical operating point of roughly 10–15 fps. Higher resolution is not required.
- **NFR-4**: To keep costs down, the Vision API call shall use a low-resolution image (`detail: "low"`) and minimal tokens.

### 6.2 Safety
- **NFR-5**: Stops (emergency stop and the various reflex stops) shall not depend on a network round-trip or an AI decision; they shall complete in-app and execute immediately.
- **NFR-6**: The default shall be motion-disabled (dry-run ON); executing motion shall require the battery installed and an explicit dry-run release.
- **NFR-7**: Drive values shall be double-clamped by the dead-zone floor 1600 and max 4095 and by the speed cap (`speedCap`). Values under the dead zone shall snap to 0.
- **NFR-8**: Operation shall assume indoor, flat, low-speed, human-supervised use, and the UI shall not undermine that premise (e.g. an always-visible STOP, the DRY badge).

### 6.3 API Key / Security
- **NFR-9**: The OpenAI API key shall not be hardcoded in the code.
- **NFR-10**: The API key is stored in the device's `UserDefaults` (personal-use premise, no encryption). This unencrypted storage shall be stated as a risk, with a practice of not sharing the build. As future hardening, migration to the Keychain is recommended (recommended, non-mandatory).
- **NFR-11**: The API key and personal information shall not be written to URL queries or logs. The API key shall be sent only in the Authorization header.

### 6.4 Network / DHCP
- **NFR-12**: The chassis IP shall be assumed to drift under DHCP, and the user shall be able to update and reconnect easily. On connection failure the app shall attempt auto-reconnect while making the state visible.
- **NFR-13**: The iPhone, the chassis, and the internet shall share the same LAN (home router, 2.4 GHz, STA mode). Local-network access permission (`NSLocalNetworkUsageDescription`) shall be requested. (In Remote mode the LAN premise is between the home bridge and the car; see `REMOTE.md`.)

### 6.5 Platform / Build
- **NFR-14**: It shall be implemented as an iOS-native SwiftUI app and shall operate on iPhone in a fixed portrait orientation.
- **NFR-15**: The deployment target shall be iOS 17.0, buildable with Xcode 26 / iOS 26 SDK. The project shall be generated and managed with XcodeGen (`project.yml`).
- **NFR-16**: No Mac shall be required at runtime (a Mac + Xcode is needed only for build/install).

### 6.6 Accessibility
- **NFR-17**: Key controls (mic, settings, STOP, etc.) shall carry VoiceOver accessibility labels (`a11y.*`).
- **NFR-18**: Displayed text shall respect Dynamic Type and ensure adequate contrast even over the glass HUD (white text · semi-transparent material).

### 6.7 Localization
- **NFR-19**: The supported languages shall be English and Japanese (`CFBundleLocalizations = [en, ja]`), with UI, AI responses, and audio (TTS/STT) operating consistently in the selected language.
- **NFR-20**: New UI strings shall always be added to both languages' `Localizable.strings`, leaving no hardcoded string (excluding non-translated tokens such as telemetry numbers and units).

### 6.8 Reliability / Robustness
- **NFR-21**: A temporary Wi-Fi drop or an AI-response failure shall not crash the app; it shall fall to the safe side (stop/hold).
- **NFR-22**: The design shall depend on the chassis's patched firmware (stop-and-hold on disconnect, on-device deadman) and hold the connection on the app side. It shall exploit the premise that a socket drop does not reboot the car (`ESP.restart` removed).

### 6.9 Visual Design (Liquid Glass)
- **NFR-23**: The camera video shall be the full-screen background, and the HUD panels shall be frosted (`.ultraThinMaterial`, replaceable with `.glassEffect()` on iOS 26) floating panels. A dark visual world (`.preferredColorScheme(.dark)`) shall be the base.
- **NFR-24**: The app icon shall be a render image of the robot (1024², `Assets.xcassets/AppIcon`).

---

## 7. Constraints / Assumptions

### 7.1 Hardware / Firmware Constraints (HC)

> The firmware named below is a not-included Freenove derivative; the tokens and file names here are descriptive references to that external interface, not source shipped in this repository.

- **HC-1**: The chassis is an ESP32-WROVER. On-device ML inference is not possible (no GPU/NPU, little RAM). All perception/cognition is done off-board (this app + the cloud).
- **HC-2**: Commands are TCP `4000`, `#`-delimited text, `\n`-terminated. Tokens: `CMD_MOTOR` / `CMD_SERVO` / `CMD_CAMERA` / `CMD_LED` / `CMD_LED_MOD` / `CMD_MATRIX_MOD` / `CMD_BUZZER` / `CMD_VIDEO` / `CMD_POWER` / `CMD_SONIC`, etc. The ones that return a reply are `CMD_POWER#<voltage>` and `CMD_SONIC#<cm>`.
- **HC-3**: The camera is TCP `7000`, gated by `CMD_VIDEO#1`, with frames as a 4-byte LE length + JPEG. HQVGA 240×176.
- **HC-4**: The motors are four wheels but are driven as a left/right tank pair via `CMD_MOTOR` (`CMD_MOTOR#<left>#0#<right>`). Each value ±4095; |value| < 1600 is 0 (dead zone).
- **HC-5**: The servos are driven via a PCA9685. `Servo_1` (ch0) / `Servo_2` (ch1). On this unit pan/tilt are **swapped** (ch0 = TILT, ch1 = PAN). For precise axis/travel control use `CMD_SERVO#<index>#<angle>` (0–180) rather than `CMD_CAMERA`.
- **HC-6**: Patched firmware (the not-included Freenove derivative): on-device deadman stop, stop-and-hold on disconnect (no `ESP.restart`). Dead zone |speed| < 1600 ⇒ 0.
- **HC-7**: Motion, servo drive, and body LEDs work only with the battery installed (2× 18650). The low-voltage reference is the firmware constant `LOW_VOLTAGE_VALUE 2100`.
- **HC-8**: This unit has an HC-SR04 added to the forward head. Forward distance is available via `CMD_SONIC#<cm>` and the firmware forward veto. However, the sensor is single, forward-only, and head-posture-dependent, with no guarantee for rear / side / floor-edge / stair / low / soft / thin / angled / glass / cloth / no-echo obstacles; hence low-speed, short-pulse, supervised operation is assumed.
- **HC-9**: There is a note that GPIO 32 is listed for both `WS2812_PIN` and `PIN_BATTERY`, so simultaneous use of the body LEDs and battery telemetry requires hardware verification (the app shall not depend on this uncertainty).

### 7.2 Assumptions (AS)

- **AS-1**: The chassis has joined the home Wi-Fi in STA mode and is on the same LAN as the iPhone.
- **AS-2**: A valid OpenAI API key and access to a Vision-capable model (default `gpt-4o-mini`) are available.
- **AS-3**: The chassis runs the patched firmware (deadman · stop-and-hold), a not-included Freenove derivative.
- **AS-4**: The operating environment is indoor, flat, low-speed, and human-supervised, with no step or fall risk.
- **AS-5**: This is single-owner personal use, with the build and API key not shared with third parties.
- **AS-6**: Real motion verification is done after the battery is installed; until then, functions are verified in dry-run.

---

## 8. Out of Scope (OS)

- **OS-1**: The chassis firmware implementation (this app references it only as an interface constraint).
- **OS-2**: On-device (ESP32) ML/CV inference, SLAM, mapping, odometry.
- **OS-3**: Obstacle avoidance beyond the HC-SR04 — high-speed, omnidirectional, floor-edge/stair-aware. Rear/side/cliff sensors, ToF arrays, SLAM, etc. are a separate phase and separate requirements.
- **OS-4**: Cloud operation over SoftAP (`Sunshine`) mode (not targeted since it cannot reach the internet; local/offline-model operation is out of scope for this document).
- **OS-5**: Multi-user / accounts / cloud sync, general App Store distribution.
- **OS-6**: iPad / landscape layout, languages other than English and Japanese.
- **OS-7**: Keychain / encrypted storage of the API key (noted as a recommendation in NFR-10 but not a mandatory v1 requirement).
- **OS-8**: Offline operation of the autonomous loop (the Vision API requires the network).

---

## Appendix A: Implementation-Status Notes (requirement vs. current code — honest gap)

As of 2026-07-28, the old assumptions about servo calibration, low battery, and the HC-SR04 mount that remained in earlier drafts no longer match reality. In the current code, servo adjustment, low-voltage stop, `CMD_SONIC`, collision escape, and the Manual/Remote/STOP state resets are implemented.

The remaining honest gap is not about presence of implementation but about **the granularity of real-vehicle acceptance**. `QUALITY_ACCEPTANCE.md` holds the correspondence table of FR/NFR/RFR/RNFR against implementation, automated check, and real-vehicle check, to be filled in from real-car logs before release.

---

## Appendix B: Quality-Acceptance Trace

Pre-release checks are governed by `QUALITY_ACCEPTANCE.md`. This appendix tracks the following against requirement ID, implementation location, static check, and real-car check: no re-drive after STOP, direct movement commands, collision escape, low light, low voltage, TTS/celebration interruption, Remote arm/disarm, Remote failure modes, and authentication / log redaction.

---

## Addendum v1.1 (2026-07-24): Automatic Chassis Discovery (mDNS/Bonjour)

An addition to relieve the pain of having to hand-enter the IP or re-flash on each IP drift under DHCP.

- **FR-51**: The app shall be able to discover the chassis via Bonjour/mDNS. The chassis shall be resolvable at hostname `robotbrain.local` and advertise the service `_robotbrain._tcp` (port 4000).
- **FR-52**: The default connection host shall be `robotbrain.local`. Connection shall succeed without reconfiguration even when the IP changes under DHCP. Manual entry of a numeric IP shall remain as a fallback.
- **FR-53**: The settings shall provide a "Find car" action that browses `_robotbrain._tcp` with `NWBrowser`, and on discovery sets the connection host, reconnects, and shows the user the result (found / not found). The browse shall time out within a few seconds.
- **Constraint**: On the iOS side, the Info.plist must declare `NSBonjourServices = ["_robotbrain._tcp"]` and hold local-network permission. On the firmware side, mDNS shall start after the STA connection is established (it may also start in AP mode).
