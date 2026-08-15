"""
safety.py — host-side reflexes that never depend on a VLM round-trip.

The arbiter asks want_stop() every tick; if it returns a reason, motion is
forced to STOP regardless of what the brain wants. These mirror the four
reflexes in AI_ROBOT_PROPOSAL.md (the firmware deadman is the on-device backstop).
"""
import time

# --- Head-guards-travel predicates (mirror ios_app/RobotController.swift) ----------
# Camera + sonar share the pan/tilt head, so the sensor only guards where the head points.
# While the body moves, the head is forced FORWARD; free look only while stopped.
FWD_PAN = 90
DRIVE_TILT = 83          # safe drive down-tilt (sonar clears the floor, keeps floor-ahead in frame)
PAN_TOL = 8
TILT_MIN_DRIVE = 78
SERVO_SETTLE_MS = 400

# --- Fusion-search constants (DESIGN §16.7; MUST match ios_app RobotController) --------------
# Sensor fusion (camera semantics x head-mounted sonar) picks the relocate heading. All TRANSIENT
# (RAM only, discarded on relocate) — no persistent map, no odometry. Initial values; tune on the car.
DIST_NORM_CM = 150.0     # sonar distance that scores full marks (farther => distance score 1.0)
OPEN_MIN     = 0.3       # VLM open below this = camera says "blocked" -> soft-obstacle gate
FWD_BLOCK_CM = 30.0      # sonar under this = real obstacle -> exclude direction (> escape 25 > veto 20)
W_SONAR      = 0.6       # fusion weight: accurate distance / near-field safety
W_VLM        = 0.4       # fusion weight: semantics / wide FOV / soft obstacles (-> ~0 in low light)
LOW_LIGHT_LUMA = 55.0    # mean frame luma (0-255) below this = "dark" -> sonar-led fallback
RELOCATE_CLEAR_CM      = 45.0   # forward sonar must be at least this open to drive straight ahead
RELOCATE_CLEAR_DARK_CM = 65.0   # require MORE forward clearance before driving when blind (dark)
SEARCH_STUCK_LIMIT = 3   # consecutive all-blocked relocates before we consider reporting "blocked"
SEARCH_PIVOT_INVERT = False  # flip if the real car pivots the WRONG way toward a chosen pan (calib)

# Scan arc — SEMANTIC pan/tilt (90 = straight/level; tilt > 90 UP, < 90 DOWN). Mirrors Swift scanArc:
# covers up / level / down across a wide LEFT/RIGHT pan so a floor object is scanned too. The last
# entry is the forward DRIVE pose so the RELOCATE that follows measures the real travel path.
SCAN_ARC = [(90, 130), (45, 88), (90, 45), (135, 88), (FWD_PAN, DRIVE_TILT)]


def body_motion(drive):
    return (abs(float(drive.get("throttle", 0) or 0)) > 0.05
            or abs(float(drive.get("steer", 0) or 0)) > 0.05)


def forward_drive(drive):
    return float(drive.get("throttle", 0) or 0) > 0.05


def approach_mode(report):
    return (report or {}).get("task_state", "searching") in ("approaching", "done")


def head_forward(st):
    """True when the head is centered forward AND settled (so the sonar guards the travel path)."""
    return (abs(getattr(st, "pan", 90) - FWD_PAN) <= PAN_TOL
            and getattr(st, "tilt", 90) >= TILT_MIN_DRIVE
            and (time.monotonic() - getattr(st, "last_aim_at", 0.0)) * 1000 > SERVO_SETTLE_MS)


def head_settled(st):
    """True when the head has stopped moving long enough that a fresh sonar read belongs to the
    CURRENT pan (ANY pan, not just forward). SCAN_FUSE uses this to attribute a distance to each
    scan angle, expanding the sonar-poll gate beyond the forward-only case (DESIGN §16.4)."""
    return (time.monotonic() - getattr(st, "last_aim_at", 0.0)) * 1000 > SERVO_SETTLE_MS


class SafetyMonitor:
    def __init__(self, cfg, cmd_link, video_link):
        self.cfg = cfg
        self.cmd = cmd_link
        self.video = video_link
        self.last_intent_ts = 0.0
        self.voltage = None
        self._last_power_poll = 0.0
        self.last_distance = None          # latest FORWARD distance (cm) — reflex/VLM cache
        self.last_distance_ts = 0.0        # monotonic stamp (success only)
        self.fan = {}                      # SCAN_FUSE per-angle cache: semantic pan -> (cm, ts)
        # REMOTE only (set by bridge_main): operator/relay liveness. When relay is
        # None (LAN main.py) these reflexes are inert and behavior is unchanged.
        self.relay = None
        self.last_operator_ts = 0.0

    def note_intent(self):
        self.last_intent_ts = time.monotonic()

    def note_operator(self):
        """Stamp the last time a fresh operator (phone) heartbeat arrived."""
        self.last_operator_ts = time.monotonic()

    async def poll_battery(self):
        """Call periodically; caches the latest pack voltage."""
        now = time.monotonic()
        if now - self._last_power_poll < 3.0:
            return
        self._last_power_poll = now
        v = await self.cmd.power()
        if v is not None:
            self.voltage = v

    async def poll_sonar(self, pan=None, forward=False):
        """Refresh the head-mounted sonar. Driven by a dedicated ~3Hz task (NOT the arbiter critical
        path) so a slow echo never queues behind the heartbeat/STOP. `forward=True` (head centered
        forward) updates the FORWARD cache the collision reflex + VLM prompt read; any settled `pan`
        also feeds the SCAN_FUSE per-angle fan. Keeping the two caches separate means a side-looking
        scan read can NEVER masquerade as a forward-clearance reading to the reflex."""
        cm = await self.cmd.sonar()
        if cm is None:                     # keep last value on a miss; stamp on success only
            return
        now = time.monotonic()
        if pan is not None:
            self.fan[int(pan)] = (cm, now)   # per-angle fan for SCAN_FUSE (attributed to this pan)
        if forward:
            self.last_distance = cm          # forward-only cache (reflex/VLM) — unchanged semantics
            self.last_distance_ts = now

    def fan_distance(self, pan, max_age=1.5):
        """Freshest sonar reading taken at ~this scan pan (SCAN_FUSE), else None. Separate from
        fresh_distance() so the forward reflex is never fed a side-looking read."""
        v = self.fan.get(int(pan))
        if v is None:
            return None
        cm, ts = v
        return cm if (time.monotonic() - ts) <= max_age else None

    def fresh_distance(self, max_age=1.5):
        """Latest forward distance if fresh (<=max_age s), else None. Used by BOTH the VLM
        prompt AND the reflex/watchdog, so a stale reading never drives a move."""
        if self.last_distance is None:
            return None
        return self.last_distance if (time.monotonic() - self.last_distance_ts) <= max_age else None

    def want_stop(self):
        """Return a reason string if motion must be blocked, else None."""
        # REMOTE reflexes (bridge only): a dropped uplink or a stale operator
        # heartbeat MUST stop the car, independent of the brain's own intent
        # freshness (the brain keeps deciding even when the operator is gone).
        if self.relay is not None:
            if not self.relay.connected:
                return "relay link down"
            op_deadman = self.cfg["safety"].get("operator_deadman_ms", 1500)
            if (time.monotonic() - self.last_operator_ts) * 1000 > op_deadman:
                return "operator link lost"
        if not self.cmd.connected:
            return "command-link down"
        if self.video.age_ms() > self.cfg["safety"]["vision_stale_ms"]:
            return "vision stale (blind)"
        if (time.monotonic() - self.last_intent_ts) * 1000 > self.cfg["safety"]["deadman_ms"]:
            return "deadman (no fresh intent)"
        if self.voltage is not None and self.voltage < self.cfg["safety"]["low_voltage"]:
            return f"low battery ({self.voltage:.1f}V)"
        return None
