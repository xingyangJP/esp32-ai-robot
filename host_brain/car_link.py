"""
car_link.py — persistent async links to the car.

CommandLink : one long-lived TCP socket to :4000. Held open for the whole
              session (a drop makes stock firmware reboot; the patched
              AI_Car_Firmware instead stops-and-holds). Only writer to the car.
VideoLink   : reads the :7000 stream (4-byte little-endian length + JPEG),
              exposes the LATEST frame only (never a backlog).

Both auto-reconnect. Neither raises into the control loop; failures surface as
`connected` flags the SafetyMonitor watches.
"""
import asyncio
import struct
import time
import numpy as np
import cv2


class CommandLink:
    def __init__(self, ip: str, port: int):
        self.ip, self.port = ip, port
        self._reader = self._writer = None
        self.connected = False
        self._lock = asyncio.Lock()

    async def run(self):
        while True:
            try:
                self._reader, self._writer = await asyncio.open_connection(self.ip, self.port)
                self.connected = True
                print(f"[cmd] connected {self.ip}:{self.port}")
                while self.connected:
                    await asyncio.sleep(0.5)          # socket kept open by the OS; writes happen via send()
                    if self._writer.is_closing():
                        raise ConnectionError("writer closing")
            except Exception as e:
                self.connected = False
                print(f"[cmd] link down ({e}); reconnecting in 1s")
                await asyncio.sleep(1.0)

    async def send(self, line: str):
        if not self.connected or self._writer is None:
            return
        try:
            async with self._lock:
                self._writer.write((line + "\n").encode())
                await self._writer.drain()
        except Exception as e:
            print(f"[cmd] send failed ({e})")
            self.connected = False

    async def _read_tagged(self, tag, deadline):
        """readline until a line whose token[0]==tag, or the deadline; drop mismatches.
        Prevents cross-typing when two RPC replies (CMD_POWER / CMD_SONIC) share one socket."""
        loop = asyncio.get_event_loop()
        while True:
            remaining = deadline - loop.time()
            if remaining <= 0:
                return None
            raw = await asyncio.wait_for(self._reader.readline(), remaining)
            parts = raw.decode(errors="replace").strip().split("#")
            if len(parts) >= 2 and parts[0] == tag:
                return parts[1]
            # else: stale / other-type line -> discard and keep reading within the budget

    async def power(self, timeout=1.5):
        """CMD_POWER RPC -> volts, or None."""
        if not self.connected:
            return None
        try:
            async with self._lock:
                self._writer.write(b"CMD_POWER\n")
                await self._writer.drain()
                deadline = asyncio.get_event_loop().time() + timeout
                val = await self._read_tagged("CMD_POWER", deadline)
            return float(val) if val is not None else None
        except Exception:
            return None

    async def sonar(self, timeout=0.15):
        """CMD_SONIC RPC -> distance in cm along the head's CURRENT aim, or None. Plausibility
        floor: <3cm -> None. Short timeout (> ~18ms ping, < 100ms tick) so a missed echo can't
        stall the heartbeat. This is the per-angle read SCAN_FUSE uses: the sonar shares the
        pan/tilt head, so polling it at each settled scan pan yields that direction's distance
        (attribution + fan caching happen in safety.poll_sonar / SafetyMonitor.fan)."""
        if not self.connected:
            return None
        try:
            async with self._lock:
                self._writer.write(b"CMD_SONIC\n")
                await self._writer.drain()
                deadline = asyncio.get_event_loop().time() + timeout
                val = await self._read_tagged("CMD_SONIC", deadline)
            if val is None:
                return None
            cm = float(val)
            return cm if cm >= 3 else None
        except Exception:
            return None


class VideoLink:
    def __init__(self, ip: str, port: int):
        self.ip, self.port = ip, port
        self.frame = None                # latest decoded BGR ndarray
        self.jpeg = None                 # latest RAW JPEG bytes (for relay preview, no re-encode)
        self.frame_ts = 0.0              # monotonic timestamp of latest frame
        self.connected = False

    async def run(self):
        while True:
            try:
                reader, writer = await asyncio.open_connection(self.ip, self.port)
                self.connected = True
                print(f"[cam] connected {self.ip}:{self.port}")
                while True:
                    hdr = await reader.readexactly(4)
                    (length,) = struct.unpack("<I", hdr)
                    if length == 0 or length > 4_000_000:
                        raise ValueError(f"bad frame length {length}")
                    buf = await reader.readexactly(length)
                    img = cv2.imdecode(np.frombuffer(buf, np.uint8), cv2.IMREAD_COLOR)
                    if img is not None:
                        self.frame = img
                        self.jpeg = bytes(buf)       # keep raw JPEG for the relay preview
                        self.frame_ts = time.monotonic()
            except Exception as e:
                self.connected = False
                print(f"[cam] stream down ({e}); reconnecting in 1s")
                await asyncio.sleep(1.0)

    def age_ms(self) -> float:
        if self.frame is None:
            return float("inf")
        return (time.monotonic() - self.frame_ts) * 1000.0
