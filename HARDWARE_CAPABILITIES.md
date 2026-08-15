> **Note.** The ESP32 firmware is a not-included Freenove derivative; `firmware/…` paths here are *descriptive* (see the [README](README.md) license note).

# Hardware Capabilities — Freenove 4WD Car for ESP32 (FNK0053), viewed as an AI-robot platform

> Board: **ESP32-WROVER**. All numbers below are quoted from the Freenove firmware lineage plus the patched `firmware/AI_Car_Firmware`. This unit now carries the camera head **and** an HC-SR04 forward ultrasonic sensor on the ultrasonic connector.

---

## 1. Compute — ESP32-WROVER

| Property | Value | Notes |
|---|---|---|
| MCU | ESP32-WROVER, dual-core **Xtensa LX6 @ 240 MHz** | Two cores; the firmware pins the camera streamer and WiFi watchdog to core 0 via `xTaskCreateUniversal(..., 0)`. |
| Internal SRAM | **~520 KB** | Shared across code/data/FreeRTOS; the real free heap is far less after WiFi + camera stacks. |
| External PSRAM | **~4–8 MB** (SPI PSRAM on WROVER) | Load-bearing for the camera: `fb_location = CAMERA_FB_IN_PSRAM`. Without PSRAM there is no frame buffer. |
| Flash | **4 MB** | Inferred from the build: `PartitionScheme=huge_app` = "Huge APP (3 MB app / no OTA / 1 MB SPIFFS)". |
| Radio | 2.4 GHz WiFi 802.11 b/g/n (+ BT/BLE on module, unused by firmware) | |
| Toolchain | Arduino ESP32 core **3.0.7**; upload at **115200 baud** on macOS (default 921600 corrupts the flash handshake). | |

**What it can do on-device:** real-time motor/servo PWM, I2C sensor polling, JPEG capture + framing, a TCP command server, LED/buzzer animations, and simple reactive control loops (line-follow, light-follow) — all comfortably.

**What it cannot do on-device:** any non-trivial ML or computer-vision inference. There is no GPU/NPU, no vector unit, single-digit-MB RAM, and the camera path is already deliberately kept tiny (HQVGA, single frame buffer) precisely because the chip has no headroom to *process* frames — it only forwards them. Object detection, segmentation, SLAM, LLM/VLM reasoning, and audio inference **must run off-board**. Treat the ESP32 as a **sensor/actuator I/O bridge with a reflex layer**, not a compute node.

---

## 2. Sensing / inputs

All I2C peripherals share one bus: **SDA = GPIO 13, SCL = GPIO 14**.

| Sensor | Bus / pin | What it senses | How it is read |
|---|---|---|---|
| **Camera OV2640** (also auto-handles OV3660/GC2145/GC0308) | Dedicated parallel DVP bus, XCLK **10 MHz**; SCCB on GPIO 26/27; data GPIO 4,5,18,19,36,39,34,35; VSYNC 25 / HREF 23 / PCLK 22 | Live video | `esp_camera_fb_get()` → JPEG. Configured at **`FRAMESIZE_HQVGA` = 240×176**, `PIXFORMAT_JPEG`, `jpeg_quality = 12`, `fb_count = 1`. OV2640 gets `hmirror=1, vflip=1`; a runtime `camera_vflip()/camera_hmirror()` exists (working notes: use `vflip=0` because the camera is mounted 180°). |
| **Ultrasonic HC-SR04** *(fitted on this build)* | TRIG GPIO 12, ECHO GPIO 15 | Forward distance along the current head direction | `Get_Sonar()` → cm; `CMD_SONIC#<cm>` returns the latest reading. Firmware also refuses/stops forward motion below `FORWARD_STOP_CM = 20cm`. Single forward sensor only: no rear/side/floor-edge coverage, and no echo is not a safety guarantee. |
| **3-channel line tracking** (PCF8574 I2C expander) | addr **0x20** on the shared bus | Floor reflectance L/M/R | `Track_Read()` → `sensorValue[0..2]` (L/M/R) + `sensorValue[3]` = 3-bit combined (bit0=L, bit1=M, bit2=R). Digital, one nibble. |
| **Photoresistor / light** | GPIO 33 ADC | Ambient brightness | `analogRead(33)`; `Light_Setup()` captures a baseline `light_init_value`; light-follow uses a ±100 ADC threshold. Single channel (no left/right light discrimination — direction comes from spinning the car). |
| **IR receiver** *(used in 05.x sketches, not wired into 06.3)* | GPIO (per `Freenove_IR_Lib`) | NEC/Sony/Samsung/RC5 remote codes | `available()` → `data()`. A manual remote input, not an autonomy sensor. |
| **Battery voltage** | GPIO 32 ADC | Pack voltage | `Get_Battery_Voltage()` = 5-sample-averaged raw ADC → `esp_adc_cal_raw_to_voltage()` × `batteryCoefficient (=4)`. 12-bit, `ADC_ATTEN_DB_12`. `LOW_VOLTAGE_VALUE 2100`. |

**Camera reality over WiFi:** HQVGA (240×176) JPEG frames are only a few KB each, so the streamed feed can reach roughly the low-to-mid **tens of fps** on a clean SoftAP link, but `fb_count = 1` + `CAMERA_GRAB_WHEN_EMPTY` serialize capture and send, and any higher resolution (OV2640 tops out at UXGA 1600×1200) collapses the frame rate and blows the PSRAM/WiFi budget. For an AI pipeline, **HQVGA/QVGA at ~10–15 fps is the honest working point**; treat frames as low-res perception, not high-fidelity capture.

> ⚠️ Pin oddity to verify on hardware: the working notes record `WS2812_PIN 32` **and** `PIN_BATTERY 32` sharing the same GPIO number. Confirm which peripheral actually owns GPIO 32 before relying on battery telemetry and body LEDs simultaneously.

---

## 3. Actuation / outputs

Motors and servos run through a **PCA9685** 16-channel PWM driver at I2C address **0x5F**, 50 Hz.

| Actuator | Range / control | Notes |
|---|---|---|
| **4 drive motors** | `Motor_Move(m1,m2,m3,m4)`, each **±4095**; magnitude **dead-zoned to ≥1600** (below 1600 the wheel won't turn). Reverse a wheel by flipping `MOTOR_x_DIRECTION` to −1. | Over WiFi, `CMD_MOTOR` drives them as a **tank/differential pair** — `Motor_Move(left, left, right, right)` — not four independent wheels. Line-follow uses speed levels 1500/2500/3000/4000. |
| **Tilt servo (Servo 1, PCA9685 ch0)** | `Servo_1_Angle(int)`, clamped **0–180°** | This physical unit has servo1 as tilt. App semantic tilt uses 90=level and maps through `tiltNeutral≈95`. |
| **Pan servo (Servo 2, PCA9685 ch1)** | `Servo_2_Angle(int)`, clamped **0–180°** in patched firmware | This physical unit has servo2 as pan. Stock 06.3 clamped Servo_2 to 80–180, which clipped one pan side; patched firmware opens the full range. |
| **LED-matrix face** (dual 8×8, VK16K33 @ **0x71**, brightness 15) | `Emotion_SetMode(n)` / `Emotion_Show(n)` | 06.3 modes: 0=off, 1=rotate eyes, 2=cry, 3=smile, 4=right-wheel spin, 5=left-wheel spin, 6=blink; mode ≥7 draws a pseudo-random static face. Expressive output for HRI. |
| **12 WS2812 body LEDs** (GPIO 32, GRB, RMT ch0) | `WS2812_SetMode(0–5)`: off / static / flow / blink / breathe / rainbow; per-LED color via `WS2812_Set_Color_1/2` | 3 LEDs at each of the 4 corners (FL=4–6, FR=7–9, RL=1–3, RR=10–12) — these are the position lights; there are no separate bumper strips. |
| **Buzzer** (GPIO 2, LEDC ch0) | `Buzzer_Alarm(on)` = 2000 Hz tone; `Buzzer_Variable(on,freq)` 0–10000 Hz; `Buzzer_Alert(beat,rebeat)` = blocking beep pattern | `Buzzer_Alert` **blocks** (delays) — avoid in a control loop. |

---

## 4. Comms / control interface

**WiFi (`Freenove_4WD_Car_WiFi.cpp`):**
- **SoftAP (default):** `WiFi_Setup(1)` → SSID/pass **`Sunshine`/`Sunshine`**, IP pinned to **192.168.4.1** (`softAPConfig`). Beeps once when ready.
- **STA:** `WiFi_Setup(0)` joins a router using `ssid_Router`/`password_Router` (placeholders `********` — must be filled in). 2.4 GHz only.
- Patched firmware stops and waits on disconnect instead of rebooting the car.

**Command protocol — TCP port 4000:**
- Text lines, `#`-delimited fields (`INTERVAL_CHAR '#'`), terminated by `\n` (`ENTER`). Parsed into `CmdArray[0..7]` (token) + `paramters[0..7]` (int of each field).
- Tokens: `CMD_MOTOR`, `CMD_SERVO`, `CMD_CAMERA` (legacy pan+tilt in one call), `CMD_LED`, `CMD_LED_MOD`, `CMD_MATRIX_MOD`, `CMD_BUZZER`, `CMD_VIDEO`, `CMD_LIGHT`, `CMD_TRACK`, `CMD_CAR_MODE`, `CMD_POWER`, `CMD_SONIC`.
- Example: `CMD_MOTOR#1500#0#1500\n` (left/right), `CMD_SERVO#0#90\n`, `CMD_VIDEO#1\n`.
- `CMD_POWER` replies `CMD_POWER#<voltage>\n`; `CMD_SONIC` replies `CMD_SONIC#<cm>\n`. Everything else is fire-and-forget.
- **Robustness posture for autonomy:** patched firmware holds stop on disconnect, includes a motor deadman, and refuses forward motion below 20cm. The host should still hold the connection open, send short self-expiring pulses, and reconnect deliberately.

**Camera stream — TCP port 7000:**
- Gated by `videoFlag` (set by `CMD_VIDEO#1`, cleared by `#0` or disconnect).
- Wire format per frame: **4-byte little-endian length prefix**, then raw JPEG bytes. Receiver reads 4 bytes → length → exactly that many bytes.
- The stock stream is this custom TCP protocol (needs the Freenove app or the `TCP/` Python client). **A plain HTTP + MJPEG path is already proven** (working notes: browser JPEG-poll at `http://192.168.4.1/`) and is the more integration-friendly option for a host/cloud pipeline.

---

## 5. Power / physical

**Rails (verified on USB-only, 2026-07-19):**

| Powered from USB alone | Battery-only (via power switch) |
|---|---|
| ESP32 logic, WiFi, camera, buzzer, LED-matrix face | **4 drive motors** |
| | **Pan/tilt servos** (motionless on USB — confirmed) |
| | **12 WS2812 body LEDs** (stayed dark on USB — 5 V LED rail is almost certainly battery-fed; to reconfirm with cells installed) |

Implication: you can develop and test **perception, comms, camera, and face/UI** on USB alone, but **nothing moves and the body LEDs stay dark without the 18650 pack**.

**Physical / power source:** Small 4-wheel indoor rover footprint (four independently-driven wheels, pan/tilt camera mast). Powered by 2× 18650 Li-ion cells (nominal ~7.4 V, ~8.4 V full); `LOW_VOLTAGE_VALUE 2100` flags low battery. Runtime is **not specified in code**; realistically on the order of **~1–2 hours** of mixed light use, dropping sharply under continuous full-speed driving (motors are the dominant draw). Budget conservatively and poll `CMD_POWER`.

---

## 6. Implications for autonomy

**Split of responsibilities:**
- **On-device (ESP32) — keep local:** the real-time reflex + I/O layer. Motor/servo PWM, sensor polling (line, light, battery, ultrasonic), JPEG capture/framing, LED/buzzer, and hard-real-time safety reflexes.
- **Off-board (host laptop / cloud) — must offload:** all perception and cognition. Vision (object/obstacle/lane detection, VLM scene understanding), planning, mapping, and any LLM-driven behavior. The host consumes the port-7000 JPEG stream and issues port-4000 commands.

**Latency budget:** vision round-trips (ESP32 → WiFi → host inference → command back) realistically land in the **~100–400 ms** range over SoftAP, worse over cloud. That is fine for deliberative navigation but **too slow for collision avoidance at speed**. Design the control loop so the host sets *intent* (waypoints, speeds, modes) while fast stops are handled locally.

**Safety reflexes that should stay local (do not depend on the WiFi round-trip):**
- **Command-timeout stop** — patched firmware stops if host motor commands go stale.
- **Low-battery cutoff** — act on `Get_Battery_Voltage()` / `LOW_VOLTAGE_VALUE 2100` locally rather than trusting the host to notice.
- **Edge/line detection** — the 3-channel tracker is already a local reflex (`Track_Car`) and can serve as a cheap "don't drive off the table" guard.
- **Obstacle stop** — HC-SR04 is fitted and the patched firmware refuses/stops forward motion below 20cm. This is a forward-only reflex, not full collision avoidance.

**Remaining hardware honesty for autonomous operation:**
1. HC-SR04 is single-direction and head-mounted. It cannot see behind, sideways, floor edges, stairs, or objects outside the head direction.
2. Low/soft/thin/angled/glass/cloth/no-echo obstacles can still be missed. The host's low-light mode and collision escape reduce risk but do not make unsupervised operation safe.
3. Reverse is a rescue behavior with no rear sensor. Keep reverse pulses bounded and supervise the robot.
