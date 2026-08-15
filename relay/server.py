"""
RobotBrain cloud relay — opaque WebSocket forwarder (Cloud Run).

Pairs a phone and a home bridge that authenticate with the SAME Firebase user
(uid = room). Forwards every message (text commands / JSON, binary JPEG) between
the two peers unchanged. It never interprets CMD_* — just a secure pipe.

Env:
  PORT           listen port (Cloud Run sets this; default 8080)
  AUTH_DISABLED  "1" for LOCAL testing only — skips Firebase auth, uses hello.room
See REMOTE.md §2A and §4.
"""
import asyncio
import json
import os

import websockets

AUTH_DISABLED = os.environ.get("AUTH_DISABLED") == "1"
PORT = int(os.environ.get("PORT", "8080"))

if not AUTH_DISABLED:
    import firebase_admin
    from firebase_admin import auth as fb_auth
    firebase_admin.initialize_app()   # uses Cloud Run's default credentials + project

# uid -> {"bridge": ws, "phone": ws}
rooms: dict[str, dict] = {}


def _verify(token: str) -> str | None:
    if AUTH_DISABLED:
        return None
    try:
        return fb_auth.verify_id_token(token)["uid"]
    except Exception as e:
        print("auth failed:", e)
        return None


async def handler(ws):
    # First frame is a JSON hello: {"role":"bridge"|"phone","token":"<idToken>","room":"<uid for dev>"}
    try:
        hello = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
    except Exception:
        return await ws.close(code=4000, reason="no hello")

    role = hello.get("role")
    if role not in ("bridge", "phone"):
        return await ws.close(code=4001, reason="bad role")

    if AUTH_DISABLED:
        uid = str(hello.get("room", "dev"))
    else:
        uid = _verify(hello.get("token", ""))
        if not uid:
            return await ws.close(code=4003, reason="auth failed")

    room = rooms.setdefault(uid, {})
    old = room.get(role)
    room[role] = ws                      # register the new socket FIRST, so the
    if old is not None:                  # displaced handler's finally guard (is ws)
        try:                             # is already false -> no spurious peer-down
            await old.close(code=4009, reason="replaced by newer connection")
        except Exception:
            pass
    peer_role = "phone" if role == "bridge" else "bridge"
    await ws.send(json.dumps({"type": "ready", "role": role,
                              "peer": room.get(peer_role) is not None}))
    # tell the peer we (dis)appeared
    if (peer := room.get(peer_role)) is not None:
        try:
            await peer.send(json.dumps({"type": "peer", "role": role, "up": True}))
        except Exception:
            pass
    print(f"[{uid[:6]}] {role} connected (peer={'yes' if peer else 'no'})")

    try:
        async for msg in ws:
            peer = rooms.get(uid, {}).get(peer_role)
            if peer is not None:
                try:
                    await peer.send(msg)     # opaque forward (str or bytes)
                except Exception:
                    pass
    finally:
        if rooms.get(uid, {}).get(role) is ws:
            del rooms[uid][role]
            if (peer := rooms[uid].get(peer_role)) is not None:
                try:
                    await peer.send(json.dumps({"type": "peer", "role": role, "up": False}))
                except Exception:
                    pass
            if not rooms[uid]:
                rooms.pop(uid, None)
        print(f"[{uid[:6]}] {role} disconnected")


async def main():
    # No HTTP health handler needed: Cloud Run's default startup probe is a TCP check
    # on $PORT, which a listening WS server passes. Plain GETs just get a WS 4xx.
    async with websockets.serve(handler, "0.0.0.0", PORT,
                                max_size=8 * 1024 * 1024,      # allow ~JPEG frames
                                ping_interval=20, ping_timeout=20):
        print(f"relay listening on :{PORT} (auth_disabled={AUTH_DISABLED})")
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
