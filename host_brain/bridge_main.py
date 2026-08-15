"""
bridge_main.py — home bridge for REMOTE mode (REMOTE.md §2C, brain-on-bridge).

Same brain / safety / dispatcher as main.py, but:
  - goals arrive from the phone through the Cloud Run relay (RelayLink), not stdin
  - the bridge streams a JPEG preview + status JSON back to the phone
The camera stays on the home LAN; only a small preview leaves the house.

Tasks (one event loop):
  cmd.run() / video.run()  car LAN links (unchanged)
  relay.run()              WSS to the relay; on_message -> control queue
  control_loop()           applies phone control (goal / estop / look / face / leds)
  brain_loop()             frame + goal -> Intent -> look/face + drive-pulse
  arbiter_loop()           heartbeat; SAFETY > estop > dry_run > pulse; single writer
  preview_loop()           latest JPEG -> phone (throttled)
  status_loop()            telemetry/status JSON -> phone (throttled)

SAFETY: arbiter is the single motor writer; safety.want_stop() overrides everything;
drive pulses self-expire; dry_run defaults ON for remote; if the phone peer drops,
control_loop e-stops (remote deadman) on top of the arbiter deadman + onboard deadman.

Run:  python3 bridge_main.py         (reads config.toml, else config.example.toml)
"""
import asyncio
import contextlib
import time

try:
    import tomllib as toml
except ModuleNotFoundError:
    import tomli as toml

import dispatcher as D
from car_link import CommandLink, VideoLink
from safety import SafetyMonitor
from brain import Brain, HOLD, Intent, frame_luma
from relay_link import RelayLink
from main import State, load_cfg, sonar_poll_loop, aim_head
from fusion_search import apply_fusion_search
import safety as S


def _servo_cfg(cfg):
    sv = cfg.get("servo", {})
    return (bool(sv.get("swap", True)),
            int(sv.get("pan_neutral", 90)),
            int(sv.get("tilt_neutral", 18)),
            bool(sv.get("pan_invert", False)))


def _int(v, default):
    """Coerce an untrusted phone-supplied field to int, falling back to a safe default."""
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


async def supervise(name, make_coro):
    """Run a loop forever; if it raises, log and restart it rather than letting the
    exception tear down the whole bridge (arbiter, safety, remote deadman)."""
    while True:
        try:
            await make_coro()
            return                                  # clean return = intentional stop
        except asyncio.CancelledError:
            raise
        except Exception as e:
            print(f"[bridge] loop {name!r} crashed ({e!r}); restarting in 1s")
            await asyncio.sleep(1.0)


async def brain_loop(cfg, brain, video, cmd, safety, st: State):
    period = 1.0 / max(0.05, cfg["brain"]["decision_hz"])
    swap, pan_n, tilt_n, pan_inv = _servo_cfg(cfg)
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
        # --- host forward-collision reflex (mirrors Swift/main.py; the arbiter still gates on
        # SAFETY/estop/dry-run). Mutate intent.drive IN PLACE, preserving intent.report,
        # BEFORE st.intent= / memory append. Suppressed during a real approach. ---
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

        # --- Head guards the direction of travel (mirror Swift/main.py) ---
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
        st.last_report = intent.report
        print(f"[brain] state={intent.task_state} drive={intent.drive} :: {intent.report.get('observation','')}")
        # Don't give up on one transient "blocked"; only after several in a row.
        if intent.task_state == "done":
            print("[brain] task done -> holding."); st.goal = "wait"; st.blocked = 0
            st.done_flash_until = time.monotonic() + 2.5     # rainbow LEDs celebrate (face matrix physically removed)
        elif intent.task_state == "blocked":
            st.blocked = getattr(st, "blocked", 0) + 1
            if st.blocked >= 3:
                print("[brain] blocked x3 -> holding."); st.goal = "wait"
        else:
            st.blocked = 0


async def arbiter_loop(cfg, cmd, safety, st: State):
    period = 1.0 / max(1, cfg["drive"]["heartbeat_hz"])
    started_video = False
    while True:
        await asyncio.sleep(period)
        await safety.poll_battery()

        if cmd.connected and not started_video:
            await cmd.send("CMD_VIDEO#1")
            await aim_head(cmd, st, S.FWD_PAN, S.DRIVE_TILT, cfg)   # start from a known forward pose
            started_video = True
        if not cmd.connected:
            started_video = False               # re-send CMD_VIDEO#1 + re-center after a reconnect

        cap = getattr(st, "speed_cap", cfg["drive"]["speed_cap"])   # phone-tunable cap
        reason = safety.want_stop()
        st.safety_reason = reason
        driving = (not st.estop) and reason is None and time.monotonic() < st.pulse_until
        if driving:
            d = st.intent.drive
            line = D.drive(d.get("throttle", 0), d.get("steer", 0), cap,
                           float(cfg.get("drive", {}).get("motor_trim", 0.0)))
        else:
            line = D.stop()

        if st.dry and line != D.stop():
            # dry-run: never send MOTION; log what would have gone out...
            tag = "ESTOP" if st.estop else (reason or ("PULSE" if driving else "hold"))
            print(f"[arbiter:dry] would send {line}  ({tag})")
        else:
            # ...but a stop is not motion: always send it (even in dry) so an
            # armed->dry switch actively halts the car, and non-dry sends drive.
            await cmd.send(line)

        # ---- LED "car light language" (on change only; LEDs bypass dry-run) ----
        rep = getattr(st, "last_report", {}) or {}
        led_moving = driving and not st.dry          # only show motion LEDs when actually moving
        thr = st.intent.drive.get("throttle", 0) if led_moving else 0
        steer = st.intent.drive.get("steer", 0) if led_moving else 0
        cue = D.led_cue(running=True, estop=st.estop, reason=reason,
                        task_state=rep.get("task_state", "searching"),
                        throttle=thr, steer=steer,
                        done_flash=time.monotonic() < getattr(st, "done_flash_until", 0.0))
        await apply_led_cue(cmd, st, cue)


async def control_loop(cfg, cmd, safety, st: State, q: asyncio.Queue):
    """Apply phone control messages. Tolerant of both the REMOTE.md canonical `t`
    key and the `type` alias, and of the spec's message names (dryrun/arm/disarm/
    estop{on}/speedcap). One bad message is logged and dropped, never fatal."""
    swap, pan_n, tilt_n, pan_inv = _servo_cfg(cfg)
    while True:
        msg = await q.get()
        try:
            if not isinstance(msg, dict):
                continue
            t = msg.get("type") or msg.get("t")    # REMOTE.md: `t` canonical, `type` alias
            if t in ("heartbeat", "deadman"):
                safety.note_operator()             # operator liveness (twin deadman)
            elif t == "goal":
                text = str(msg.get("text", "")).strip()
                st.goal = text or "wait"
                st.blocked = 0
                st.memory.clear()
                st.pending_relocate = False
                if st.search is not None:
                    st.search.reset()          # fresh goal -> discard any in-progress scan/relocate fan
                if text:                      # a real goal clears estop; an empty hold must NOT
                    st.estop = False
                print(f"[control] goal -> {st.goal}")
            elif t == "estop":
                if msg.get("on", True):            # `on` omitted = stop (spec)
                    st.estop = True
                    st.goal = "wait"
                    print("[control] E-STOP (phone)")
                else:
                    st.estop = False
                    print("[control] e-stop cleared (phone)")
            elif t == "go":
                st.estop = False
                print("[control] e-stop cleared (phone)")
            elif t in ("dryrun", "dry_run"):
                st.dry = bool(msg.get("on", True))
                print(f"[control] dry_run -> {st.dry}")
            elif t == "arm":
                st.dry = False
                print("[control] ARM (dry-run off)")
            elif t == "disarm":
                st.dry = True
                print("[control] DISARM (dry-run on)")
            elif t in ("speedcap", "speedCap"):
                st.speed_cap = max(0, min(D.MOTOR_MAX, _int(msg.get("v"), st.speed_cap)))
                print(f"[control] speed_cap -> {st.speed_cap}")
            elif t == "look":
                st.pan = _int(msg.get("pan"), 90)
                st.tilt = _int(msg.get("tilt"), 90)
                for line in D.look_servo(st.pan, st.tilt, swap, pan_n, tilt_n, pan_inv):
                    await cmd.send(line)
            elif t == "face":
                m = msg.get("mode")
                mode = D.FACE_MODES.get(m) if isinstance(m, str) else _int(m, None)
                if mode is not None:
                    await cmd.send(D.face(mode))
            elif t == "leds":
                await cmd.send(D.body_leds(_int(msg.get("mode"), 0)))
            elif t == "drive":
                # manual remote drive: set the arbiter's intent + a self-expiring pulse.
                # The arbiter (single writer) still gates on dry-run/safety/speed-cap.
                thr = max(-1.0, min(1.0, float(msg.get("throttle") or 0)))
                steer = max(-1.0, min(1.0, float(msg.get("steer") or 0)))
                dur = max(0, min(1000, _int(msg.get("duration_ms"), 250)))
                if thr > 0.05 and not S.head_forward(st):
                    await aim_head(cmd, st, S.FWD_PAN, S.DRIVE_TILT, cfg)  # center first; backstop holds forward until settled
                st.intent = Intent({"drive": {"throttle": thr, "steer": steer, "duration_ms": dur},
                                    "report": {"observation": "manual", "task_state": "searching"}})
                st.pulse_until = time.monotonic() + dur / 1000.0
                safety.note_intent()
            elif t == "peer":
                # remote deadman: if the phone drops (or our uplink dies), hold AND
                # auto-disarm so a fresh session must explicitly re-arm before motion.
                if msg.get("role") == "phone" and not msg.get("up", False):
                    st.estop = True
                    st.goal = "wait"
                    st.dry = True
                    print("[control] phone/uplink down -> E-STOP + disarm (remote deadman)")
        except Exception as e:
            print(f"[control] bad message {msg!r} dropped ({e!r})")


async def preview_loop(cfg, video, relay: RelayLink, st: State):
    hz = max(1, int(cfg.get("remote", {}).get("preview_hz", 4)))
    period = 1.0 / hz
    last_ts = 0.0
    while True:
        await asyncio.sleep(period)
        if relay.connected and video.jpeg is not None and video.frame_ts != last_ts:
            last_ts = video.frame_ts
            await relay.send_frame(video.jpeg)      # 240x176 JPEG is already small


async def status_loop(cfg, cmd, video, safety, relay: RelayLink, st: State):
    hz = max(1, int(cfg.get("remote", {}).get("status_hz", 2)))
    period = 1.0 / hz
    while True:
        await asyncio.sleep(period)
        if not relay.connected:
            continue
        rep = getattr(st, "last_report", {}) or {}
        await relay.send_json({
            "type": "status",
            "cmd": cmd.connected,
            "cam": video.connected,
            "goal": st.goal,
            "estop": st.estop,
            "dry_run": st.dry,
            "voltage": safety.voltage,
            "distance": safety.fresh_distance(),      # staleness-gated forward distance (cm); null when stale
            "safety": getattr(st, "safety_reason", None),
            "task_state": rep.get("task_state"),
            "observation": rep.get("observation"),
            "pan": getattr(st, "pan", 90),
            "tilt": getattr(st, "tilt", 90),
        })


async def apply_led_cue(cmd, st, cue):
    """Send a LED cue only when it changes (no spam). LEDs/buzzer are non-motion."""
    key, mode, mask, r, g, b, chirp = cue
    if key == getattr(st, "led_key", None):
        return
    st.led_key = key
    await cmd.send(D.body_leds(mode))
    await cmd.send(D.led(D.LED_ALL, 0, 0, 0))        # blank, then paint the cue
    await cmd.send(D.led(mask, r, g, b))
    if chirp:
        now = time.monotonic()
        if now - getattr(st, "led_chirp_at", 0.0) > 1.5:
            st.led_chirp_at = now
            await cmd.send(D.buzzer(1, 2200))
            asyncio.create_task(_chirp_off(cmd))


async def _chirp_off(cmd):
    await asyncio.sleep(0.15)
    with contextlib.suppress(Exception):
        await cmd.send(D.buzzer(0, 0))


async def amain(cfg=None):
    cfg = cfg or load_cfg()
    rc = cfg.get("remote", {})
    cmd = CommandLink(cfg["car"]["ip"], cfg["car"]["cmd_port"])
    video = VideoLink(cfg["car"]["ip"], cfg["car"]["camera_port"])
    safety = SafetyMonitor(cfg, cmd, video)
    brain = Brain(cfg)
    st = State()
    st.dry = True                                   # REMOTE ALWAYS boots disarmed,
    st.last_report = {}                             # regardless of config; arm each session
    st.safety_reason = None
    st.speed_cap = cfg["drive"]["speed_cap"]        # phone can tune via {t:"speedcap",v:...}
    st.pan = 90; st.tilt = 90                        # last-commanded head aim (telemetry)
    st.blocked = 0                                   # consecutive "blocked" count (give-up guard)
    st.led_key = None                                # last LED cue key (dedupe)
    st.done_flash_until = 0.0
    st.led_chirp_at = 0.0

    # Auth: "firebase" (prod wss relay) mints an ID token for owner_uid each connect;
    # "dev"/absent uses the static room string (AUTH_DISABLED local relay).
    token_provider = None
    if rc.get("auth") == "firebase":
        from firebase_auth import BridgeAuth
        _ba = BridgeAuth(rc.get("service_account", "service-account.json"),
                         rc.get("owner_uid", ""), rc.get("api_key", ""))
        token_provider = _ba.id_token
    relay = RelayLink(rc.get("relay_url", "ws://localhost:8080"),
                      rc.get("token", ""), rc.get("room", "dev"),
                      token_provider=token_provider)
    q: asyncio.Queue = asyncio.Queue()
    relay.on_message = lambda d: q.put_nowait(d)
    # uplink drop -> synthesize a phone-down so control_loop e-stops + disarms at once
    relay.on_disconnect = lambda: q.put_nowait({"type": "peer", "role": "phone", "up": False})
    safety.relay = relay                            # arm the relay/operator-liveness reflex

    print(f"[bridge] relay={rc.get('relay_url','ws://localhost:8080')} room={rc.get('room','dev')} "
          f"dry_run={st.dry} provider={cfg['brain']['provider']}")
    loops = {
        "cmd": lambda: cmd.run(),
        "video": lambda: video.run(),
        "relay": lambda: relay.run(),
        "control": lambda: control_loop(cfg, cmd, safety, st, q),
        "brain": lambda: brain_loop(cfg, brain, video, cmd, safety, st),
        "arbiter": lambda: arbiter_loop(cfg, cmd, safety, st),
        "sonar": lambda: sonar_poll_loop(safety, st),
        "preview": lambda: preview_loop(cfg, video, relay, st),
        "status": lambda: status_loop(cfg, cmd, video, safety, relay, st),
    }
    tasks = [asyncio.create_task(supervise(name, make)) for name, make in loops.items()]
    try:
        await asyncio.gather(*tasks)
    finally:
        with contextlib.suppress(Exception):
            await cmd.send(D.stop())                # always leave the car stopped


if __name__ == "__main__":
    with contextlib.suppress(KeyboardInterrupt):
        asyncio.run(amain())
    print("\n[bridge] stopped.")
