"""
fusion_search.py — host-driven SCAN_FUSE / RELOCATE_FUSE search (DESIGN §16, FR-66..71).

Extends the deterministic scan/relocate search into a two-phase sensor-fusion state machine that
mirrors ios_app/RobotController.applySearch so LAN (Swift) and Remote (Python) behave identically:

  (A) SCAN_FUSE   — sweep the head over `SCAN_ARC`; at EACH pan, once the head SETTLES, read the
                    head-mounted sonar and attribute the distance to that pan, building a per-
                    direction fan `spot_fan` of DirSample{pan, sonar_cm, vlm_open, hazard}.
  (B) RELOCATE_FUSE — score each direction = W_SONAR*norm(sonar) * soft_gate + W_VLM*vlm_open, with
                    cross-checks (sonar < FWD_BLOCK_CM => real obstacle, exclude; sonar clear but
                    camera says blocked => soft penalty; VLM open high but sonar near => trust
                    sonar); pick the best heading, PIVOT the body to face it if off-centre, then
                    drive a short forward pulse. Degrade gracefully if all blocked (no infinite
                    pivot). In low light drop W_VLM toward 0 and fall back to sonar + creep.

Everything here is TRANSIENT: `spot_fan` is RAM only and discarded on relocate — NO persistent map,
NO odometry. This builds an Intent ONLY; the arbiter + every SAFETY veto (E-STOP / dry-run /
deadman / low-battery / collision-escape / firmware <20cm) remain strictly superior (§16.5).
"""
import safety as S


class DirSample:
    """One scanned direction at the current spot (all transient)."""
    __slots__ = ("pan", "sonar_cm", "vlm_open", "hazard")

    def __init__(self, pan, sonar_cm, vlm_open, hazard):
        self.pan = pan                # semantic head pan (90 = forward)
        self.sonar_cm = sonar_cm      # sonar at that pan (None = not read; ~300 = no echo / far)
        self.vlm_open = vlm_open      # VLM openness 0..1 for that direction
        self.hazard = hazard          # "none|soft|ledge|wall" — what the beam misses


class SearchFusion:
    """One instance per session (lives on State). scan -> build fan -> relocate -> clear -> scan."""

    def __init__(self):
        self.phase = "scan"           # "scan" | "relocate"
        self.scan_index = 0
        self.spot_fan = []            # [DirSample] for the CURRENT spot; cleared on relocate
        self.pivot_sign = 1.0         # alternating fallback pivot when a heading can't be derived
        self.stuck_rounds = 0         # consecutive all-blocked relocates (degrade / blocked guard)

    def reset(self):
        """Yield to the VLM approach (goal acquired) — next search starts clean (mirror Swift)."""
        self.phase = "scan"
        self.scan_index = 0
        self.spot_fan = []
        self.stuck_rounds = 0

    def _clear_spot(self):
        """Left this spot (relocate/pivot): discard the fan, re-scan the new ground."""
        self.spot_fan = []
        self.scan_index = 0
        self.phase = "scan"

    # ---- (A) SCAN_FUSE ---------------------------------------------------------------------
    def _scan(self, intent, st, safety):
        arc = S.SCAN_ARC
        idx = min(self.scan_index, len(arc) - 1)
        pan_cur, tilt_cur = arc[idx]
        intent.drive = {"throttle": 0.0, "steer": 0.0, "duration_ms": 300}   # stay put; sweep head only
        # Record this angle ONCE the head has actually settled AT it (so both the sonar reading and
        # the VLM frame describe pan_cur/tilt_cur), then advance to the next arc angle.
        settled_here = (S.head_settled(st)
                        and abs(int(getattr(st, "pan", 90)) - pan_cur) <= S.PAN_TOL
                        and abs(int(getattr(st, "tilt", 90)) - tilt_cur) <= 10
                        and self.scan_index < len(arc))
        if settled_here:
            self.spot_fan.append(DirSample(pan_cur, safety.fan_distance(pan_cur),
                                           intent.forward_open, intent.hazard))
            self.scan_index += 1
        # aim the head at the next arc angle (or hold the current one until it settles)
        nxt = min(self.scan_index, len(arc) - 1)
        intent.look = {"pan_deg": arc[nxt][0], "tilt_deg": arc[nxt][1]}
        if self.scan_index >= len(arc):
            self.scan_index = 0
            self.phase = "relocate"

    # ---- (B) RELOCATE_FUSE -----------------------------------------------------------------
    @staticmethod
    def _steer_toward(off):
        """Steer sign to pivot the body toward a target pan. off = target_pan - 90; DESIGN marks
        pan>90 as one side (calibration-dependent), +steer = right. Flip with SEARCH_PIVOT_INVERT
        if the real car turns the wrong way (untested on hardware)."""
        s = -0.9 if off > 0 else 0.9
        return -s if S.SEARCH_PIVOT_INVERT else s

    def _score(self, d, w_sonar, w_vlm):
        """Fusion score for one direction, or None if a cross-check EXCLUDES it (§16.4). The camera-
        derived penalties (soft gate, soft-hazard) fire only when the VLM is trusted (w_vlm > 0); in
        the dark we go sonar-led so a blind low-open read can't wrongly veto every heading. The hard-
        hazard exclusion (wall/ledge) is safety-positive and stays on regardless."""
        trust_vlm = w_vlm > 0.0
        cm = d.sonar_cm
        # cross-check 1: a real, close obstacle -> exclude (sonar is authoritative near-field)
        if cm is not None and cm < S.FWD_BLOCK_CM:
            return None
        # cross-check 3: VLM sees a hard hazard the beam skims (a wall) or the floor ends (a ledge)
        if d.hazard in ("ledge", "wall"):
            return None
        # distance score: unknown read -> half credit (don't over-trust a missing echo); else norm
        if cm is None:
            norm = 0.5
        else:
            norm = max(0.0, min(1.0, cm / S.DIST_NORM_CM))
        # cross-check 2: sonar clear but camera says blocked (curtain/clutter) -> soft gate penalty
        gate = 0.2 if (trust_vlm and d.vlm_open < S.OPEN_MIN) else 1.0
        score = w_sonar * norm * gate + w_vlm * d.vlm_open
        if trust_vlm and d.hazard == "soft":   # soft obstacle (curtain) the beam misses -> don't charge in
            score *= 0.3
        return score

    def _best_direction(self, low_light):
        w_vlm = 0.0 if low_light else S.W_VLM       # dark: drop VLM trust, sonar-led (§16.5 / FR-70)
        w_sonar = S.W_SONAR + (S.W_VLM - w_vlm)     # shift the freed weight to sonar (sum stays 1.0)
        best, best_score = None, -1.0
        for d in self.spot_fan:
            sc = self._score(d, w_sonar, w_vlm)
            if sc is not None and sc > best_score:
                best, best_score = d, sc
        if best is None or best_score < 0.15:       # nothing viable -> caller degrades
            return None
        return best

    def _farthest_dir(self):
        best, bd = None, -1.0
        for d in self.spot_fan:
            cm = d.sonar_cm if d.sonar_cm is not None else -1.0
            if cm > bd:
                best, bd = d, cm
        return best

    def _relocate(self, intent, st, safety, low_light):
        intent.look = {"pan_deg": S.FWD_PAN, "tilt_deg": S.DRIVE_TILT}   # face forward to measure + drive
        if not S.head_forward(st):                  # head still turning forward -> wait a tick, measure next
            intent.drive = {"throttle": 0.0, "steer": 0.0, "duration_ms": 200}
            return

        best = self._best_direction(low_light)
        if best is None:                            # everything blocked/low-score -> graceful degrade
            self.stuck_rounds += 1
            if self.stuck_rounds >= S.SEARCH_STUCK_LIMIT:
                intent.report["task_state"] = "blocked"   # let the brain-loop give-up guard handle it
                intent.drive = {"throttle": 0.0, "steer": 0.0, "duration_ms": 200}
                return
            far = self._farthest_dir()              # pivot toward the most-open heading, one step
            if far is not None and abs(far.pan - S.FWD_PAN) > S.PAN_TOL:
                steer = self._steer_toward(far.pan - S.FWD_PAN)
            else:
                steer = self.pivot_sign * 0.9
                self.pivot_sign *= -1.0             # alternate so we never spin one way forever
            intent.drive = {"throttle": 0.0, "steer": steer, "duration_ms": 350}
            self._clear_spot()
            return

        self.stuck_rounds = 0
        off = best.pan - S.FWD_PAN
        if abs(off) <= S.PAN_TOL:
            clear = S.RELOCATE_CLEAR_DARK_CM if low_light else S.RELOCATE_CLEAR_CM
            if best.sonar_cm is not None and best.sonar_cm < clear:   # ahead but not open enough -> pivot on
                steer = self.pivot_sign * 0.9
                self.pivot_sign *= -1.0
                intent.drive = {"throttle": 0.0, "steer": steer, "duration_ms": 350}
            else:                                    # dead ahead + clear -> short forward pulse to new ground
                intent.drive = {"throttle": 0.30 if low_light else 0.45, "steer": 0.0,
                                "duration_ms": 250 if low_light else 350}
        else:                                        # best heading is off to one side -> pivot to face it first
            intent.drive = {"throttle": 0.0, "steer": self._steer_toward(off), "duration_ms": 350}
        self._clear_spot()

    def apply(self, intent, st, safety, low_light):
        """Mutate intent.drive/look (and possibly report[task_state]) with the host search step."""
        if self.phase == "scan":
            self._scan(intent, st, safety)
        else:
            self._relocate(intent, st, safety, low_light)


def _ensure(st):
    s = getattr(st, "search", None)
    if s is None:
        s = SearchFusion()
        st.search = s
    return s


def apply_fusion_search(intent, st, safety, low_light):
    """Shared by main.py (LAN) and bridge_main.py (Remote) brain loops so the two stay identical.

    1) Low-light guard (FR-70 / v1.1.38): never trust "approaching"/"done" from a dark frame.
    2) If the VLM sees the goal (approaching/done) -> reset the fan and YIELD (the VLM drives the
       approach downstream, unchanged).
    3) Otherwise run the host SCAN_FUSE/RELOCATE_FUSE step, overwriting the VLM's (ignored) drive.

    Builds Intent only — the arbiter + every SAFETY veto remain superior."""
    ts = intent.report.get("task_state", "searching")
    if low_light and ts in ("approaching", "done"):
        intent.report["task_state"] = "searching"
        ts = "searching"
    search = _ensure(st)
    if ts in ("approaching", "done"):
        search.reset()
        return
    search.apply(intent, st, safety, low_light)
