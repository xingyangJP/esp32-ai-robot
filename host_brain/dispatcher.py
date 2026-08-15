"""
dispatcher.py — the ONLY place that knows the car's wire syntax.

Turns semantic actions into exact CMD_ strings for the command server (TCP 4000).
Every string here is verified against the firmware parser in
06.3_Multi_Functional_Car.ino / AI_Car_Firmware.ino:
  - fields are '#'-delimited, line terminated by '\n' (added by CommandLink.send)
  - CMD_MOTOR#<left>#<placeholder>#<right>  -> Motor_Move(left,left,right,right) (tank pair)
  - both left & right == 0  -> full stop
  - motor magnitude dead-zone: the wheels do not turn below 1600
"""

MOTOR_MIN = 1600     # firmware dead-zone floor (|speed| < 1600 -> no motion)
MOTOR_MAX = 4095


def _clamp_motor(v: int, speed_cap: int) -> int:
    """Clamp to +/-speed_cap, snap out of the dead-zone, keep 0 as 0."""
    v = int(max(-MOTOR_MAX, min(MOTOR_MAX, v)))
    cap = min(int(speed_cap), MOTOR_MAX)
    v = max(-cap, min(cap, v))
    if v == 0:
        return 0
    mag = max(MOTOR_MIN, abs(v))
    return mag if v > 0 else -mag


def drive(throttle: float, steer: float, speed_cap: int, trim: float = 0.0) -> str:
    """throttle/steer in [-1,1] (+throttle=forward, +steer=right) -> tank pair.
    trim (+boost left / -boost right) corrects a straight-line drift; matches the iOS side."""
    throttle = max(-1.0, min(1.0, throttle))
    steer = max(-1.0, min(1.0, steer))
    trim = max(-0.5, min(0.5, trim))
    l = (throttle + steer) * (1 + trim) * speed_cap
    r = (throttle - steer) * (1 - trim) * speed_cap
    # Keep the trim ratio alive past the dead-zone: when both wheels drive the same
    # direction, scale them up so the smaller sits at the floor (mirrors the iOS side).
    mn = min(abs(l), abs(r))
    if mn > 0 and mn < MOTOR_MIN and (l == 0 or r == 0 or (l > 0) == (r > 0)):
        k = MOTOR_MIN / mn
        l *= k
        r *= k
    return f"CMD_MOTOR#{_clamp_motor(round(l), speed_cap)}#0#{_clamp_motor(round(r), speed_cap)}"


def stop() -> str:
    return "CMD_MOTOR#0#0#0"


def look(pan_deg: int, tilt_deg: int) -> str:
    pan = max(0, min(180, int(pan_deg)))
    tilt = max(80, min(180, int(tilt_deg)))   # firmware clamps tilt to 80..180
    return f"CMD_CAMERA#{pan}#{tilt}"


def servo(index: int, angle: int) -> str:
    """Drive one servo directly. index 0 = servo1 (ch0), 1 = servo2 (ch1)."""
    return f"CMD_SERVO#{int(index)}#{max(0, min(180, int(angle)))}"


def look_servo(pan_deg: int, tilt_deg: int,
               swap: bool = True, pan_neutral: int = 90, tilt_neutral: int = 18,
               pan_invert: bool = False) -> list:
    """Semantic pan/tilt (90 = neutral for both) -> two raw CMD_SERVO commands,
    honoring the pan/tilt swap, per-axis neutral offsets, and pan-direction invert.
    Mirrors the iOS Dispatcher.look() exactly so LAN and Remote aim identically."""
    pan_ch = 1 if swap else 0
    tilt_ch = 0 if swap else 1
    pan_delta = -(int(pan_deg) - 90) if pan_invert else (int(pan_deg) - 90)
    phys_pan = max(0, min(180, pan_neutral + pan_delta))
    phys_tilt = max(0, min(180, tilt_neutral + (int(tilt_deg) - 90)))
    return [servo(pan_ch, phys_pan), servo(tilt_ch, phys_tilt)]


def face(mode: int) -> str:
    # 0=off 1=rotate 2=cry 3=smile 4=wheelR 5=wheelL 6=blink  (>=7 random static)
    return f"CMD_MATRIX_MOD#{int(mode)}"


def body_leds(mode: int) -> str:
    return f"CMD_LED_MOD#{int(mode)}"          # 0 off,1 static,3 blink,4 breathe,5 rainbow


def led(mask: int, r: int, g: int, b: int) -> str:
    """Set color_1 of the LEDs selected by a 12-bit corner bitmask (mode 1/3/4 render it)."""
    def c(v):
        return max(0, min(255, int(v)))
    return f"CMD_LED#{int(mask) & 0xFFF}#{c(r)}#{c(g)}#{c(b)}"


# Corner map — MUST match LedLanguage.swift (12 WS2812, 4 corners x 3; masks are a guess).
LED_FL, LED_FR, LED_RL, LED_RR = 0x007, 0x038, 0x1C0, 0xE00
LED_FRONT = LED_FL | LED_FR
LED_REAR = LED_RL | LED_RR
LED_LEFT = LED_FL | LED_RL
LED_RIGHT = LED_FR | LED_RR
LED_ALL = 0xFFF
LED_TURN_STEER = 0.35


def led_cue(running, estop, reason, task_state, throttle, steer, done_flash):
    """(key, mode, mask, r, g, b, chirp). Mirrors LedLanguage.cue in Swift. Bridge
    `reason` is free text from safety.want_stop() (not the app's localization keys)."""
    if estop:
        return ("estop", 3, LED_ALL, 255, 0, 0, False)
    if reason and reason.startswith("low battery"):
        return ("lowbatt", 3, LED_ALL, 255, 40, 0, False)
    if not running:
        return ("idle", 1, LED_ALL, 0, 0, 60, False)
    if done_flash:
        return ("done", 5, LED_ALL, 0, 255, 0, False)     # rainbow = celebrate
    if task_state == "blocked":
        return ("blocked", 3, LED_ALL, 255, 90, 0, False)
    if reason in ("command-link down", "relay link down", "operator link lost", "vision stale (blind)"):
        return ("wait", 1, LED_ALL, 0, 0, 60, False)
    if throttle < -0.05:
        return ("reverse", 1, LED_REAR, 255, 0, 0, True)
    if steer > LED_TURN_STEER:
        return ("turnR", 1, LED_RIGHT, 255, 120, 0, False)
    if steer < -LED_TURN_STEER:
        return ("turnL", 1, LED_LEFT, 255, 120, 0, False)
    if throttle > 0.05:
        return ("forward", 1, LED_FRONT, 255, 255, 255, False)
    if task_state == "approaching":
        return ("approach", 1, LED_ALL, 0, 200, 0, False)
    if task_state == "idle":
        return ("standby", 1, LED_ALL, 40, 40, 45, False)     # manual / at-rest
    return ("search", 4, LED_ALL, 0, 180, 200, False)


def buzzer(on: int, freq_hz: int) -> str:
    return f"CMD_BUZZER#{int(bool(on))}#{max(0, min(10000, int(freq_hz)))}"


def power_query() -> str:
    return "CMD_POWER"                          # replies CMD_POWER#<volts>


def sonar_query() -> str:
    return "CMD_SONIC"                          # forward distance query -> CMD_SONIC#<cm>

FACE_MODES = {"off": 0, "rotate": 1, "cry": 2, "smile": 3,
              "wheel_r": 4, "wheel_l": 5, "blink": 6, "random": 7}
