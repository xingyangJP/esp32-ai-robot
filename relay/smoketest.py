"""Local forwarding test for the relay (run with AUTH_DISABLED=1 server on :8080)."""
import asyncio, json, sys
import websockets

URL = sys.argv[1] if len(sys.argv) > 1 else "ws://localhost:8080"

async def peer(role):
    ws = await websockets.connect(URL)
    await ws.send(json.dumps({"role": role, "room": "test"}))
    ready = json.loads(await ws.recv())
    assert ready["type"] == "ready", ready
    return ws

async def main():
    bridge = await peer("bridge")
    phone = await peer("phone")
    await asyncio.sleep(0.2)
    # phone -> bridge (text command)
    await phone.send("CMD_MOTOR#0#0#0")
    got = await asyncio.wait_for(bridge.recv(), 3)
    # bridge may first receive a {"type":"peer"} notice; skip non-CMD
    while isinstance(got, str) and got.startswith("{"):
        got = await asyncio.wait_for(bridge.recv(), 3)
    assert got == "CMD_MOTOR#0#0#0", f"bridge got {got!r}"
    # bridge -> phone (binary "frame")
    await bridge.send(b"\xff\xd8JPEGDATA\xff\xd9")
    gotb = await asyncio.wait_for(phone.recv(), 3)
    while isinstance(gotb, str):
        gotb = await asyncio.wait_for(phone.recv(), 3)
    assert gotb == b"\xff\xd8JPEGDATA\xff\xd9", f"phone got {gotb!r}"
    print("RELAY SMOKETEST PASS: phone->bridge text + bridge->phone binary forwarded")
    await bridge.close(); await phone.close()

asyncio.run(main())
