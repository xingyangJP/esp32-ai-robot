"""
test_reconnect.py — verify a same-role reconnect does NOT emit a spurious peer-down
(finding 11). Runs the relay (AUTH_DISABLED) in-process. Run with a websockets venv:
  <venv>/bin/python test_reconnect.py

A phone that reconnects (new WSS replacing the old) must NOT make the bridge see a
transient {"type":"peer","up":false} — that would fire a needless remote e-stop.
"""
import asyncio
import json
import os

os.environ["AUTH_DISABLED"] = "1"
os.environ["PORT"] = "8091"

import websockets              # noqa: E402
import server as relay         # noqa: E402

URL = "ws://localhost:8091"


async def hello(role):
    ws = await websockets.connect(URL)
    await ws.send(json.dumps({"role": role, "room": "dev"}))
    assert json.loads(await ws.recv())["type"] == "ready"
    return ws


async def collect_peers(ws, sink):
    try:
        async for m in ws:
            if isinstance(m, str):
                d = json.loads(m)
                if d.get("type") == "peer":
                    sink.append(d)
    except Exception:
        pass


async def main():
    relay_task = asyncio.create_task(relay.main())
    await asyncio.sleep(0.5)

    bridge = await hello("bridge")
    peers = []
    reader = asyncio.create_task(collect_peers(bridge, peers))

    phone1 = await hello("phone")           # bridge should see peer up
    drain1 = asyncio.create_task(collect_peers(phone1, []))   # absorb its 4009 close quietly
    await asyncio.sleep(0.3)
    phone2 = await hello("phone")           # replaces phone1 (same role/room)
    await asyncio.sleep(0.6)                # give the replace path time to run
    drain1.cancel()

    downs = [p for p in peers if p.get("role") == "phone" and p.get("up") is False]
    ups = [p for p in peers if p.get("role") == "phone" and p.get("up") is True]
    assert not downs, f"spurious peer-down on reconnect: {peers}"
    assert len(ups) >= 2, f"expected two phone-up notices (phone1, phone2): {peers}"

    print("RELAY RECONNECT TEST PASS: phone reconnect produced no spurious peer-down "
          f"(saw {len(ups)} up, {len(downs)} down)")
    reader.cancel()
    await phone2.close()
    await bridge.close()
    relay_task.cancel()


if __name__ == "__main__":
    asyncio.run(main())
