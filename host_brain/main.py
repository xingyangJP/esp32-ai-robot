"""
main.py — host-brain entry point (Concept B: chat goal -> autonomous task).

Async tasks, one event loop:
  cmd.run()      persistent :4000 command socket (only writer via arbiter)
  video.run()    :7000 JPEG stream -> latest frame
  brain_loop()   slow (decision_hz): frame+goal -> Intent; applies look/face
  arbiter_loop() fast (heartbeat_hz): SAFETY > dry_run > pulse-drive; the heartbeat
  goal_loop()    stdin: type a goal, "stop" (e-stop), or "quit"

SAFETY: arbiter is the single writer; safety.want_stop() overrides everything;
drive pulses self-expire (duration_ms). dry_run=true never sends motion.

Run:  python3 main.py            (reads config.toml, else config.example.toml)
"""
import asyncio
import sys
import time
import contextlib

try:
    import tomllib as toml
except ModuleNotFoundError:
    import tomli as toml

import dispatcher as D
from car_link import CommandLink, VideoLink
from safety import SafetyMonitor
import safety as S
from brain import Brain, HOLD, frame_luma
from fusion_search import SearchFusion, apply_fusion_search


def load_cfg():
    import os
    here = os.path.dirname(__file__)
    for name in ("config.toml", "config.example.toml"):
        p = os.path.join(here, name)
        if os.path.exists(p):
            with open(p, "rb") as f:
                print(f"[cfg] using {name}")
                return toml.load(f)
    raise SystemExit("no config.toml found")


class State:
    goal = "wait"          # current natural-language goal
    intent = HOLD
    pulse_until = 0.0      # monotonic deadline for the current drive pulse
    memory = []            # list of {action, outcome}
    estop = False
    pan = 90               # last-commanded semantic head aim
    tilt = 90
    blocked = 0            # consecutive "blocked" count (give-up guard)
    distance = None        # latest fresh forward distance (cm), or None
    consec_reflex_reverse = 0  # consecutive sonar-reflex reverses (cap before pivoting)
    last_aim_at = 0.0      # monotonic stamp of the last head move (settle gate)
    pending_relocate = False   # a forward relocate deferred one tick to center the head first
    low_light = False      # frame too dark to trust the VLM -> sonar-led fusion + creep (FR-70)
    search = None          # SearchFusion state machine (lazily created; SCAN_FUSE/RELOCATE_FUSE)


async def aim_head(cmd, st, pan, tilt, cfg):
    """Set the head pose (semantic) + stamp the settle timer; mirrors iOS aim()."""
    pan, tilt = int(pan), int(tilt)
    if pan != getattr(st, "pan", 90) or tilt != getattr(st, "tilt", 90):
        st.last_aim_at = time.monotonic()          # arm the settle gate only on an actual move
    st.pan, st.tilt = pan, tilt
    sv = cfg.get("servo", {})
    for line in D.look_servo(pan, tilt, bool(sv.get("swap", True)),
                             int(sv.get("pan_neutral", 90)), int(sv.get("tilt_neutral", 18)),
                             bool(sv.get("pan_invert", False))):
        await cmd.send(line)


async def brain_loop(cfg, brain, video, cmd, safety, st: State):
    period = 1.0 / max(0.05, cfg["brain"]["decision_hz"])
    while True:
        await asyncio.sleep(period)
        if st.estop or st.goal in ("", "wait"):
            st.pending_relocate = False
            continue
        d = safety.fresh_distance() if S.head_forward(st) else None   # valid only while the head guards travel
        intent = brain.decide(video.frame, st.goal, st.memory, distance=d)
        # --- Fusion search (DESIGN §16): while searching, the HOST drives (SCAN_FUSE builds the
        # per-angle fan, RELOCATE_FUSE scores + picks the heading), overwriting the VLM's ignored
        # drive; on goal acquisition it yields to the VLM approach. Low-light guard inside. ---
        luma = frame_luma(video.frame)
        if luma is not None:
            st.low_light = luma < S.LOW_LIGHT_LUMA
        apply_fusion_search(intent, st, safety, st.low_light)
        # --- host forward-collision reflex (mirrors Swift; subordinate to the arbiter, which
        # still gates on SAFETY/estop/dry-run). Mutate intent.drive IN PLACE, preserving
        # intent.report, BEFORE st.intent= / memory append. Suppressed during a real approach. ---
        since_drive = 0
        for e in reversed(st.memory):
            if abs(float((e.get("drive") or {}).get("throttle", 0) or 0)) < 0.05:
                since_drive += 1
            else:
                break
        approaching = intent.report.get("task_state", "searching") in ("approaching", "done")
        sign = 1 if intent.drive.get("steer", 0) >= 0 else -1
        if d is not None and d >= 3 and not approaching:
            if d < 22 and intent.drive.get("throttle", 0) > 0.05:
                if st.consec_reflex_reverse >= 2:
                    intent.drive = {"throttle": 0.0, "steer": sign * 1.0, "duration_ms": 250}
                else:
                    intent.drive = {"throttle": -0.4, "steer": sign * 0.2, "duration_ms": 220}
                    st.consec_reflex_reverse += 1
            elif d < 25 and since_drive >= 5 and abs(intent.drive.get("throttle", 0)) < 0.05:
                intent.drive = {"throttle": -0.4, "steer": sign * 0.2, "duration_ms": 220}
                st.consec_reflex_reverse += 1
        if d is None or d > 30:
            st.consec_reflex_reverse = 0

        # --- Head guards the direction of travel (mirror Swift applyIntent) ---
        # Classify from the post-reflex intent BEFORE suppressing throttle (avoid livelock);
        # body motion forces the head forward, forward deferred one tick until centered; approach exempt.
        # Force the head FORWARD whenever the body moves (same tick); the firmware ~60ms sonar veto
        # guards the brief servo swing. Free look only while stopped; approach exempt.
        if not approaching:
            if S.forward_drive(intent.drive):
                await aim_head(cmd, st, S.FWD_PAN, S.DRIVE_TILT, cfg)
            elif intent.look:
                await aim_head(cmd, st, int(intent.look.get("pan_deg", st.pan)),
                               int(intent.look.get("tilt_deg", st.tilt)), cfg)
        elif intent.look:
            await aim_head(cmd, st, int(intent.look.get("pan_deg", st.pan)),
                           int(intent.look.get("tilt_deg", st.tilt)), cfg)

        st.intent = intent
        st.pulse_until = time.monotonic() + intent.drive.get("duration_ms", 300) / 1000.0
        safety.note_intent()
        # Record head aim WITH the drive + forward distance so the VLM detects a non-changing view.
        st.memory.append({"look": {"pan": st.pan, "tilt": st.tilt},
                          "drive": intent.drive, "dist_cm": d,
                          "outcome": intent.report.get("observation", "")})
        st.memory[:] = st.memory[-12:]
        print(f"[brain] state={intent.task_state} drive={intent.drive} :: {intent.report.get('observation','')}")
        # Don't give up on one transient "blocked"; only after several in a row.
        if intent.task_state == "done":
            print("[brain] task done -> holding."); st.goal = "wait"; st.blocked = 0
        elif intent.task_state == "blocked":
            st.blocked = getattr(st, "blocked", 0) + 1
            if st.blocked >= 3:
                print("[brain] blocked x3 -> holding."); st.goal = "wait"
        else:
            st.blocked = 0


async def arbiter_loop(cfg, cmd, safety, st: State):
    period = 1.0 / max(1, cfg["drive"]["heartbeat_hz"])
    cap = cfg["drive"]["speed_cap"]
    dry = cfg["brain"]["dry_run"]
    started_video = False
    while True:
        await asyncio.sleep(period)
        await safety.poll_battery()

        if cmd.connected and not started_video:
            await cmd.send("CMD_VIDEO#1")          # begin the camera stream once linked
            started_video = True

        reason = safety.want_stop()
        driving = (not st.estop) and reason is None and time.monotonic() < st.pulse_until
        if driving:
            d = st.intent.drive
            line = D.drive(d.get("throttle", 0), d.get("steer", 0), cap,
                           float(cfg.get("drive", {}).get("motor_trim", 0.0)))
        else:
            line = D.stop()

        if dry:
            # dry-run: never send motion; show what WOULD go out
            tag = "ESTOP" if st.estop else (reason or ("PULSE" if driving else "hold"))
            if line != D.stop():
                print(f"[arbiter:dry] would send {line}  ({tag})")
        else:
            await cmd.send(line)                    # heartbeat keeps motors honest


async def sonar_poll_loop(safety, st):
    """Dedicated ~3 Hz sonar poll, OFF the arbiter critical path. While the head guards travel
    (forward), refresh the FORWARD cache the reflex/VLM read. While the head is settled off-forward
    during a scan, still read — attributed to the current pan — to build the SCAN_FUSE fan (§16.4).
    The two caches are separate so a side read never masquerades as forward clearance."""
    while True:
        pan = int(getattr(st, "pan", 90))
        if S.head_forward(st):
            await safety.poll_sonar(pan=pan, forward=True)
        elif S.head_settled(st):
            await safety.poll_sonar(pan=pan, forward=False)
        await asyncio.sleep(0.333)


async def goal_loop(st: State):
    loop = asyncio.get_event_loop()
    print("\nType a GOAL (e.g. 'find the red cup and approach it'), "
          "'stop' for e-stop, 'go' to clear e-stop, 'quit' to exit.\n")
    while True:
        line = (await loop.run_in_executor(None, sys.stdin.readline)).strip()
        if not line:
            continue
        if line == "quit":
            raise KeyboardInterrupt
        if line == "stop":
            st.estop = True; st.goal = "wait"; print("[goal] E-STOP")
        elif line == "go":
            st.estop = False; print("[goal] e-stop cleared")
        else:
            st.goal = line; st.estop = False; st.blocked = 0; st.memory.clear(); st.pending_relocate = False
            if st.search is not None:
                st.search.reset()          # fresh goal -> discard any in-progress scan/relocate fan
            print(f"[goal] -> {line}")


async def amain():
    cfg = load_cfg()
    cmd = CommandLink(cfg["car"]["ip"], cfg["car"]["cmd_port"])
    video = VideoLink(cfg["car"]["ip"], cfg["car"]["camera_port"])
    safety = SafetyMonitor(cfg, cmd, video)
    brain = Brain(cfg)
    st = State()
    print(f"[main] dry_run={cfg['brain']['dry_run']} provider={cfg['brain']['provider']} "
          f"speed_cap={cfg['drive']['speed_cap']}")
    tasks = [asyncio.create_task(t) for t in (
        cmd.run(), video.run(),
        brain_loop(cfg, brain, video, cmd, safety, st),
        arbiter_loop(cfg, cmd, safety, st),
        sonar_poll_loop(safety, st),
        goal_loop(st),
    )]
    try:
        await asyncio.gather(*tasks)
    finally:
        with contextlib.suppress(Exception):
            await cmd.send(D.stop())               # always leave the car stopped


if __name__ == "__main__":
    with contextlib.suppress(KeyboardInterrupt):
        asyncio.run(amain())
    print("\n[main] stopped.")
