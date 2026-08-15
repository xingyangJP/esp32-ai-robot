> **Historical proposal.** The original pre-build proposal, kept for history and **superseded by [DESIGN.md](DESIGN.md) + [REQUIREMENTS.md](REQUIREMENTS.md)**. Some current-state claims here (e.g. "no forward sensor", firmware patches as TODO, brain on a Mac) are outdated — the HC-SR04 sonar and firmware patches shipped, and the vision→action brain runs inside the iPhone app.

# AI Robot Proposal — Freenove 4WD ESP32 as a cloud-brained rover

> Companion to [`HARDWARE_CAPABILITIES.md`](HARDWARE_CAPABILITIES.md) and [`FREENOVE_WORKING_NOTES.md`](FREENOVE_WORKING_NOTES.md).
> **Decision split:** the *technical architecture* below is a recommendation from the build team. **The robot concept (what it does) is the owner's call** — see §6 "Concept options". Nothing here locks that choice.

---

## 1. Vision & feasibility verdict

**Verdict: Yes — feasible, and a good fit.** Turn the car into an *embodied AI agent*: it streams what it sees over WiFi, a generative-AI vision model decides what to do, and the decisions become drive/look/express commands.

The single enabling reason: a **clean split of labor**. The ESP32-WROVER cannot run any real ML on-device (no GPU/NPU, single-digit-MB RAM — it only *forwards* frames), so we treat it as the **body/reflexes** and put the **brain off-board** (laptop now, small PC/Pi or cloud later). The owner already accepted latency, which is exactly the currency this design spends: cognition lives inside a ~0.5–2 s round-trip — fine for "look, decide, nudge, re-look" — while the ESP32 handles the fast stuff locally.

---

## 2. Recommended architecture (team recommendation)

Three nested tiers — a **reflex** layer on the car, a **broker** on the host, a **cortex** in the AI model:

```
  ┌─────────────── CORTEX (cloud VLM: Gemini / GPT / Claude) ───────────┐
  │  0.5–2 Hz : sees 1 annotated frame → returns tool calls (intent)    │
  └───────────────────────────▲───────────────┬────────────────────────┘
                              frame           tool calls
  ┌───────────────────────────┴───────────────▼────────────────────────┐
  │  BROKER / host process (Mac → later Pi)   ~20 Hz                     │
  │  • holds the ONE persistent socket to the car (never lets it drop)   │
  │  • pulls MJPEG feed, annotates, throttles cadence to the cortex      │
  │  • lowers semantic tool calls → CMD_ strings (clamps, dead-zone)     │
  │  • runs host-side reflexes: deadman, vision-stale, low-batt, e-stop  │
  └───────────────────────────▲───────────────┬────────────────────────┘
                          MJPEG :80 / :7000    CMD_* :4000
  ┌───────────────────────────┴───────────────▼────────────────────────┐
  │  REFLEX — ESP32-WROVER (car)              50–100 Hz                  │
  │  motor/servo PWM · JPEG capture · line-edge guard · low-batt cutoff  │
  │  (never waits on WiFi)                                               │
  └─────────────────────────────────────────────────────────────────────┘
```

**Why this shape (non-negotiables, grounded in the actual firmware):**
- **The broker holds one socket open forever.** Stock firmware does `client.stop(); ESP.restart()` on *any* client disconnect — a dropped socket **reboots the car**. The AI call must never be what holds that socket; the broker sits in front and absorbs cloud hiccups.
- **Motors latch** (no on-device deadman). Something must expire motion, or a lost tick = runaway.
- **SoftAP has no internet.** If the host joins the car's `Sunshine` AP it can't reach the cloud. For a *cloud* brain, put the car in **STA mode** (join the home router) so car + host + internet share one LAN. (A purely local/offline model can stay on SoftAP.)

## 3. How generative AI is used

- **Model:** a vision-language model — Gemini Flash / GPT-4o-mini class for cheap-and-fast, or a mid tier (GPT-4o / Claude Sonnet) for smarter scene reasoning. Choice is a cost/quality dial, not an architectural change.
- **Input:** one HQVGA (240×176) JPEG per decision tick, in **low-detail mode** (fixed ~60–90 image tokens = cheap), overlaid by the broker with a **3×3 reference grid + telemetry strip** (battery, pan/tilt, last action) so the model can refer to positions precisely.
- **Output = function calls only** (the model never emits raw motor numbers). The broker lowers semantic verbs to firmware commands and applies all clamps, so the model *cannot* emit an illegal or unsafe command:

  | Tool (model emits) | → firmware command | clamps applied by broker |
  |---|---|---|
  | `drive(throttle, steer, duration_ms 100–800)` | `CMD_MOTOR#L#0#R` (tank pair) | ±4095, snap out of **≥1600 dead-zone**, auto-stop after `duration_ms` |
  | `look(pan 0–180, tilt 80–180)` | `CMD_CAMERA#pan#tilt` | pan 0–180, **tilt 80–180** (firmware floor) |
  | `face(smile/blink/cry/…)` | `CMD_MATRIX_MOD#n` | mode 0–6 (or ≥7 random) |
  | `body_leds(mode,rgb)` | `CMD_LED_MOD` + `CMD_LED` | mode 0–5 |
  | `buzzer(freq,ms)` | `CMD_BUZZER` (`Buzzer_Variable`) | non-blocking only — never `Buzzer_Alert` |
  | `report(observation, task_state)` | — | drives memory + adaptive cadence |

- **Load-bearing safety idea:** `drive` commands are **self-expiring pulses**, not persistent velocity. A late/failed tick means the car already stopped on its own.

## 4. Control layer to build on the ESP32

**Recommendation: reuse the HTTP + MJPEG path**, not the raw port-7000 TCP protocol. My browser camera test already proved MJPEG at `http://192.168.4.1/` works and is easy to consume; it also decouples frame-reading from the fragile command socket. Commands still go over the documented `CMD_*` protocol on port 4000.

**Two small firmware patches** (do these during the wait — flashable and unit-testable on USB):
1. **On-device deadman:** if no `CMD_MOTOR` in ~300 ms → `Motor_Move(0,0,0,0)`. The single most important safety addition.
2. **Stop-and-hold instead of reboot:** replace `client.stop(); ESP.restart()` with `Motor_Move(0,0,0,0); client.stop();` + wait-for-reconnect, so a WiFi hiccup stops the car instead of rebooting it mid-move.

## 5. Host-brain software (buildable now)

Single **Python 3.11 + asyncio** process (mirrors the existing `TCP/` reference client). One event loop, latest-value slots (never stale queues), a single **arbiter** that is the only writer to the car and enforces priority **SAFETY > TELEOP > PLANNER**:

```
host_brain/
├── link/command_link.py      # persistent :4000 socket, reconnect, CMD_POWER RPC
├── link/video_link.py        # MJPEG (aiohttp) or :7000 length-prefixed reader
├── perception/vlm_client.py  # frame → VLM → structured intent (own slow cadence)
├── control/{planner,dispatcher,arbiter}.py   # intent → CMD_ strings; heartbeat
├── safety/monitor.py         # deadman · vision-stale · low-batt · link-health
└── teleop/override.py        # pygame keyboard/gamepad e-stop + nudge
```
Deps: `anthropic`/openai · `aiohttp` · `opencv-python` · `numpy` · `pygame` · `rich`. No native build beyond OpenCV. The `TCP/` folder already has a reference video reader (`Video.py`) and the canonical command strings (`Command.py`) to copy from.

---

## 6. Concept options — **owner decides**

The architecture above runs *any* of these. Difficulty and hardware fit differ. **The recommendation is advisory; pick the one you want.**

| # | Concept | What it does | Fit on THIS build | Extra HW | Team note |
|---|---|---|---|---|---|
| 🅰 | **Find & approach a colored object** | Spot a colored blob, aim the head, creep toward it, celebrate on arrival | ✅ Best — deliberative, low-speed, **benign failure**, latency-tolerant | none | **Recommended MVP.** Cheapest (blob detection can be local OpenCV = ~$0 API). Most "lovable per effort." |
| 🅱 | **Voice/chat command → autonomous task** | You type/say a goal ("look around the desk and report"), the VLM plans and drives | ✅ Good — shows off the AI most | none | Higher API use; great "wow"; needs a solid tool schema (we have one). |
| 🅲 | **Patrol & describe (roving reporter)** | Wanders and narrates what the camera sees via the VLM | ⚠️ Ambitious — no odometry/SLAM; VLM-every-frame = priciest | (advised) HC-SR04 | Flagship demo; higher cost + wants an obstacle reflex for any speed. |
| 🅳 | **Follow-me** | Detects a person/target and follows | ⚠️ Moving target amplifies latency; collision risk | (advised) HC-SR04 | Harder; wants the distance sensor. |
| 🅴 | **Wander & avoid** | Roam freely, dodge obstacles | ❌ Worst fit — **no forward distance sensor** on this camera-head build; vision-only avoidance too slow at speed | **HC-SR04 required** | Only viable if you fit the spare ultrasonic + a local stop reflex. |

> **Key constraint driving the table:** this unit has the **camera head**, so there is **no forward distance sensor** (the HC-SR04 is the unused spare). Concepts that must *avoid* things fast (🅳🅴) really want that sensor fitted; the recommended 🅰/🅱 don't.

## 7. Phased roadmap (independent of which concept you pick)

| Phase | What | Power |
|---|---|---|
| **0 — Perception & plumbing** | Bench: MJPEG ingest, host controller + reconnect, the 2 firmware patches, face/buzzer feedback | **USB** ✅ can do now |
| **1 — Teleop** | Human drives to prove actuation, latency, runtime, deadman, reconnect | Battery |
| **2 — AI-assisted** | AI annotates + auto-aims the head; "point-and-go" with human throttle + e-stop | Battery |
| **3 — Autonomous (MVP)** | Chosen concept closed off-board, supervised, capped speed, 3 local reflexes | Battery |
| **4 — Stretch** | Concept 🅲/🅳, and/or fit the HC-SR04 for a real obstacle reflex | Battery + sensor |

## 8. What we can build & test NOW on USB (while waiting for batteries)

**✅ Now (USB, nothing moves):**
- Full **camera perception pipeline** (stationary car streams real HQVGA frames → OpenCV / VLM)
- Full **host controller & command plumbing** (`CMD_*` accepted on USB; validate parsing, reconnect, deadman heartbeat — wheels just don't spin)
- The **two firmware patches** (flash + unit-test on USB)
- **LED-matrix face + buzzer** state signaling (both run on USB)
- The whole **VLM → intent → command-string** loop, output to a HUD/log with `speed_cap = 0`

**⛔ Needs the 18650 pack (motion / aiming / body light):** drive motion, pan/tilt aiming (servos confirmed motionless on USB), the 12 WS2812 body LEDs, and any real behavior/latency tuning.

→ ~**80% of the software is buildable and regression-tested on the bench**; the battery run becomes a short confirmation, not the first integration.

## 9. Latency, cost, safety

**Latency:** ~0.5–2 s per cognitive tick (mostly the VLM call). Cognitive loop 0.5–2 Hz (deliberative). Reflexes run locally at 50–100 Hz. Never route a *stop* through the round-trip.

**Rough API cost** (per hour; ~500 in / ~120 out tokens per decision frame; prices approximate, order-of-magnitude):

| Decision cadence | Frugal VLM | Mid VLM |
|---|---|---|
| 0.2 fps (1/5 s) | ~$0.6/hr | ~$2.4/hr |
| 0.5 fps (1/2 s) | ~$1.6/hr | ~$5.9/hr |
| 1 fps | ~$3.2/hr | ~$11.9/hr |

Reality checks: concept 🅰 can run at **~$0 API** (local color detection); prompt-cache the static system prompt; battery runtime is only ~1–2 hr so spend/session is bounded to single-digit dollars.

**Safety (reflexes must live on the car, not across WiFi):** command-timeout stop *(add)*, low-battery cutoff (local, vs `LOW_VOLTAGE_VALUE 2100`), line-tracker edge guard (`Track_Read()` "don't drive off the table"). Plus a **speed governor** near the 1600 dead-zone, an always-available **teleop e-stop**, LED-face/body-LED legibility, and **human supervision, indoors, no stairs.**

## 10. Open risks to confirm

- **GPIO 32 collision:** notes show `WS2812_PIN 32` *and* `PIN_BATTERY 32` — verify which peripheral owns it before trusting body-LEDs + battery telemetry together.
- **No forward obstacle sensor** on this build (biggest gap) — mitigated by low speed + edge guard for 🅰/🅱; fit HC-SR04 for 🅲🅳🅴.
- **Low-res perception** (HQVGA, quality 12) — design targets **large, bright, mid-field**; tilt can't look far down (80–180°).

## 11. Next concrete step (proposed, pending owner's concept choice)

While batteries are en route, build **Phase 0** (all USB-testable):
1. Flash the two firmware patches (deadman + stop-on-disconnect); verify on USB (link stays up, no reboot beep, `CMD_POWER` replies).
2. Stand up the host-brain skeleton: MJPEG ingest + live view, the arbiter/heartbeat holding the socket, and the safety monitor.
3. Wire the VLM perception→intent loop in **dry-run** (`speed_cap = 0`) against the live bench camera — watch the "brain" narrate decisions with zero motion.

Then, once you pick a concept (§6) and the batteries arrive, Phases 1→3 turn it live.
