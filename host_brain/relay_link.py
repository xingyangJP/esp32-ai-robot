"""
relay_link.py — the home bridge's outbound WSS client to the Cloud Run relay.

Connects as role "bridge", then forwards phone<->bridge messages:
  - receives JSON control from the phone (goal / estop / go / mode)  -> on_message(dict)
  - sends JSON status/telemetry and binary JPEG preview frames to the phone

The relay is opaque; this module defines the phone<->bridge application protocol.
Auth: Firebase ID token (or a dev room string when AUTH_DISABLED on the relay).
See REMOTE.md §2B.
"""
import asyncio
import json

import websockets


class RelayLink:
    def __init__(self, url: str, token: str = "", room: str = "dev", token_provider=None):
        self.url = url
        self.token = token
        self.room = room
        # Optional callable -> fresh Firebase ID token (blocking; run off the loop).
        # When set it wins over the static `token` so every reconnect re-auths.
        self.token_provider = token_provider
        self.ws = None
        self.connected = False
        self.on_message = None       # callback(dict) for phone control messages
        self.on_disconnect = None    # callback() when the uplink drops (bridge -> e-stop)

    async def _hello_token(self) -> str:
        if self.token_provider is None:
            return self.token
        # The provider does a blocking HTTPS exchange; keep it off the event loop.
        return await asyncio.get_running_loop().run_in_executor(None, self.token_provider)

    async def run(self):
        while True:
            try:
                token = await self._hello_token()
                self.ws = await websockets.connect(self.url, max_size=8 * 1024 * 1024,
                                                   ping_interval=20, ping_timeout=20)
                await self.ws.send(json.dumps({"role": "bridge",
                                               "token": token, "room": self.room}))
                ready = json.loads(await self.ws.recv())
                self.connected = True
                print(f"[relay] connected: {ready}")
                async for msg in self.ws:
                    if not isinstance(msg, str):
                        continue                      # bridge doesn't expect binary from phone
                    try:
                        data = json.loads(msg)
                    except Exception:
                        continue
                    if data.get("type") == "ready":
                        continue                      # our own handshake ack
                    # everything else (incl. {"type":"peer"} phone up/down) -> bridge,
                    # so it can hold the car when the phone drops (remote deadman).
                    if self.on_message:
                        self.on_message(data)
            except Exception as e:
                was_connected = self.connected
                self.connected = False
                # An uplink drop must fail safe: the peer-down notice can never
                # arrive over the channel that just died, so signal it locally.
                if was_connected and self.on_disconnect:
                    try:
                        self.on_disconnect()
                    except Exception:
                        pass
                print(f"[relay] down ({e}); reconnecting in 2s")
                await asyncio.sleep(2)

    async def send_json(self, obj: dict):
        if self.connected and self.ws is not None:
            try:
                await self.ws.send(json.dumps(obj))
            except Exception:
                self.connected = False

    async def send_frame(self, jpeg: bytes):
        if self.connected and self.ws is not None:
            try:
                await self.ws.send(jpeg)              # binary preview frame -> phone
            except Exception:
                self.connected = False
