"""
bridge_relay_test.py — verify the phone<->bridge protocol over the relay WITHOUT the car.

Runs the relay (AUTH_DISABLED) in-process, connects a RelayLink (bridge role) and a
mock phone, and checks the full application contract:
  1. phone -> bridge : {"type":"goal",...} reaches RelayLink.on_message
  2. bridge -> phone : binary JPEG preview frame is delivered
  3. bridge -> phone : {"type":"status",...} JSON is delivered
  4. remote deadman  : when the phone drops, the bridge receives {"type":"peer",
                       "role":"phone","up":false} (so control_loop can e-stop)

No car, no cv2 needed. Run with a venv that has `websockets`:
  <venv>/bin/python bridge_relay_test.py
"""
import asyncio
import contextlib
import json
import os
import sys

os.environ["AUTH_DISABLED"] = "1"
os.environ["PORT"] = "8090"
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "relay"))

import websockets                      # noqa: E402
import server as relay                 # relay/server.py  # noqa: E402
from relay_link import RelayLink       # noqa: E402

URL = "ws://localhost:8090"


async def connect_phone():
    ws = await websockets.connect(URL)
    await ws.send(json.dumps({"role": "phone", "room": "dev"}))
    ready = json.loads(await ws.recv())
    assert ready["type"] == "ready", ready
    return ws


async def recv_until(ws, pred, timeout=3.0):
    async def _loop():
        while True:
            msg = await ws.recv()
            if pred(msg):
                return msg
    return await asyncio.wait_for(_loop(), timeout)


async def main():
    relay_task = asyncio.create_task(relay.main())
    await asyncio.sleep(0.5)                          # let the relay bind :8090

    link = RelayLink(URL, token="", room="dev")
    got = []
    dropped = []
    link.on_message = lambda d: got.append(d)
    link.on_disconnect = lambda: dropped.append(True)
    bridge_task = asyncio.create_task(link.run())
    for _ in range(50):
        if link.connected:
            break
        await asyncio.sleep(0.1)
    assert link.connected, "bridge RelayLink never connected to relay"

    phone = await connect_phone()
    await asyncio.sleep(0.3)                          # allow peer notices to settle

    # 1) phone -> bridge control
    await phone.send(json.dumps({"type": "goal", "text": "find the red cup"}))
    for _ in range(30):
        if any(m.get("type") == "goal" and m.get("text") == "find the red cup" for m in got):
            break
        await asyncio.sleep(0.1)
    assert any(m.get("type") == "goal" and m.get("text") == "find the red cup" for m in got), \
        f"bridge did not receive goal; got={got}"

    # 2) bridge -> phone binary preview frame
    await link.send_frame(b"\xff\xd8PREVIEW\xff\xd9")
    frame = await recv_until(phone, lambda m: isinstance(m, (bytes, bytearray)))
    assert bytes(frame) == b"\xff\xd8PREVIEW\xff\xd9", f"phone got {frame!r}"

    # 3) bridge -> phone status JSON
    await link.send_json({"type": "status", "goal": "find the red cup", "dry_run": True})
    raw = await recv_until(
        phone,
        lambda m: isinstance(m, str) and json.loads(m).get("type") == "status")
    status = json.loads(raw)
    assert status["dry_run"] is True and status["goal"] == "find the red cup", status

    # 4) remote deadman: phone drops -> bridge sees peer down
    await phone.close()
    seen_down = False
    for _ in range(50):
        if any(m.get("type") == "peer" and m.get("role") == "phone" and m.get("up") is False
               for m in got):
            seen_down = True
            break
        await asyncio.sleep(0.1)
    assert seen_down, f"bridge never saw phone-down peer notice; got={got}"

    # 5) uplink drop: kill the relay -> bridge on_disconnect fires (local fail-safe,
    #    because no peer-down can arrive over the channel that just died)
    relay_task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await relay_task
    fired = False
    for _ in range(50):
        if dropped:
            fired = True
            break
        await asyncio.sleep(0.1)
    assert fired, "bridge on_disconnect did not fire when the relay dropped"

    print("BRIDGE<->RELAY TEST PASS: goal in / frame+status out / "
          "phone-drop deadman notice / uplink-drop fail-safe")
    bridge_task.cancel()


if __name__ == "__main__":
    asyncio.run(main())
