"""
bridge_smoke.py — full-bridge end-to-end smoke test WITHOUT a car.

Runs the REAL bridge (bridge_main.amain) against a local AUTH_DISABLED relay, with
the car pointed at a dead address (so cmd/video never connect), and drives it from a
mock phone. Black-box: we only observe the status/frames the phone receives and the
control we send — exactly the app's contract. Verifies the team-review fixes end to end:

  - dry-run is FORCED ON at boot (ignores config)                      [findings 4,5]
  - goal / arm / heartbeat / estop control messages take effect        [protocol]
  - a malformed control message does NOT crash the bridge (survives)   [findings 6,7]
  - phone drop -> status shows estop True + dry_run True (auto-disarm)  [findings 1-5]

Needs a venv with numpy + opencv + websockets. Run:
  <venv>/bin/python bridge_smoke.py
"""
import asyncio
import contextlib
import json
import os
import sys

os.environ["AUTH_DISABLED"] = "1"
os.environ["PORT"] = "8092"
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "relay"))

import websockets            # noqa: E402
import server as relay       # noqa: E402
import bridge_main           # noqa: E402

URL = "ws://localhost:8092"

CFG = {
    "car": {"ip": "127.0.0.1", "cmd_port": 4999, "camera_port": 4998},  # nothing listening
    "drive": {"speed_cap": 2000, "pulse_ms": 400, "heartbeat_hz": 10},
    "safety": {"deadman_ms": 500, "vision_stale_ms": 800,
               "low_voltage": 6.6, "operator_deadman_ms": 1500},
    "brain": {"provider": "none", "model": "x", "api_key_env": "NOPE",
              "decision_hz": 5, "dry_run": False},   # dry_run False on purpose: bridge MUST override to True
    "servo": {"swap": True, "pan_neutral": 90, "tilt_neutral": 18},
    "remote": {"relay_url": URL, "room": "dev", "token": "",
               "preview_hz": 4, "status_hz": 10},
}


async def connect_phone():
    ws = await websockets.connect(URL)
    await ws.send(json.dumps({"role": "phone", "room": "dev"}))
    assert json.loads(await ws.recv())["type"] == "ready"
    return ws


async def next_status(ws, timeout=3.0):
    async def _loop():
        while True:
            m = await ws.recv()
            if isinstance(m, str):
                d = json.loads(m)
                if d.get("type") == "status":
                    return d
    return await asyncio.wait_for(_loop(), timeout)


async def status_where(ws, pred, timeout=4.0):
    async def _loop():
        while True:
            d = await next_status(ws)
            if pred(d):
                return d
    return await asyncio.wait_for(_loop(), timeout)


async def main():
    relay_task = asyncio.create_task(relay.main())
    await asyncio.sleep(0.5)
    bridge_task = asyncio.create_task(bridge_main.amain(CFG))
    await asyncio.sleep(0.8)                      # let the bridge connect to the relay

    phone = await connect_phone()

    # 1) dry-run FORCED ON at boot despite cfg dry_run=False; no car -> cmd False, goal wait
    s = await next_status(phone)
    assert s["dry_run"] is True, f"boot must force dry ON: {s}"
    assert s["cmd"] is False, f"no car -> cmd should be False: {s}"
    assert s["goal"] == "wait", s
    print(f"  ok  boot: dry_run forced ON, cmd={s['cmd']}, goal={s['goal']}")

    # 2) goal takes effect (accept canonical `t` key)
    await phone.send(json.dumps({"t": "goal", "text": "find the red cup"}))
    s = await status_where(phone, lambda d: d.get("goal") == "find the red cup")
    print(f"  ok  goal applied -> {s['goal']!r}")

    # 3) arm (dry off) + heartbeat; still no car so safety reason is command-link down
    await phone.send(json.dumps({"t": "arm"}))
    await phone.send(json.dumps({"t": "heartbeat", "seq": 1}))
    s = await status_where(phone, lambda d: d.get("dry_run") is False)
    assert s["safety"] in ("command-link down", "relay link down", "operator link lost"), s
    print(f"  ok  arm applied -> dry_run={s['dry_run']}, safety={s['safety']!r}")

    # 4) malformed control message must NOT crash the bridge — status keeps flowing
    await phone.send(json.dumps({"t": "look", "pan": "not-a-number", "tilt": None}))
    await phone.send(json.dumps({"t": "leds", "mode": [1, 2, 3]}))
    await phone.send(json.dumps({"t": "face", "mode": {"bad": 1}}))
    s = await next_status(phone)                 # bridge still alive and reporting
    assert not bridge_task.done(), "bridge crashed on a malformed control message!"
    print("  ok  malformed messages survived (bridge still reporting)")

    # 5) phone drop -> remote deadman: bridge e-stops AND auto-disarms
    await phone.close()
    await asyncio.sleep(0.5)
    phone2 = await connect_phone()               # reconnect to observe post-drop state
    s = await status_where(phone2, lambda d: d.get("estop") is True and d.get("dry_run") is True)
    print(f"  ok  phone-drop deadman -> estop={s['estop']}, dry_run={s['dry_run']} (auto-disarm)")

    print("BRIDGE SMOKE PASS: full bridge ran headless, all remote-safety fixes verified")
    await phone2.close()
    bridge_task.cancel()
    relay_task.cancel()
    for t in (bridge_task, relay_task):
        with contextlib.suppress(asyncio.CancelledError):
            await t


if __name__ == "__main__":
    asyncio.run(main())
