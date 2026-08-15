"""
selftest_live.py — bounded integration test of the host-brain modules against the
live car (no API key, no motion). Exercises CommandLink, VideoLink, SafetyMonitor,
Brain(provider=none -> HOLD) and dispatcher. Run from the host_brain/ directory.

    python3 selftest_live.py
"""
import asyncio

try:
    import tomllib as toml
except ModuleNotFoundError:
    import tomli as toml

import car_link
import dispatcher as D
from safety import SafetyMonitor
from brain import Brain


async def main():
    with open("config.toml", "rb") as f:
        cfg = toml.load(f)
    cmd = car_link.CommandLink(cfg["car"]["ip"], cfg["car"]["cmd_port"])
    video = car_link.VideoLink(cfg["car"]["ip"], cfg["car"]["camera_port"])
    sm = SafetyMonitor(cfg, cmd, video)
    brain = Brain(cfg)  # provider "none" -> returns HOLD, no API needed

    tasks = [asyncio.create_task(cmd.run()), asyncio.create_task(video.run())]
    await asyncio.sleep(2.0)                       # let both links connect
    await cmd.send("CMD_VIDEO#1")
    await asyncio.sleep(3.0)                       # let frames arrive

    print("cmd.connected    :", cmd.connected)
    print("video.connected  :", video.connected)
    print("frame            :", None if video.frame is None else video.frame.shape,
          "age_ms:", round(video.age_ms()))
    await sm.poll_battery()
    print("battery volts    :", sm.voltage)
    sm.note_intent()
    print("safety.want_stop :", sm.want_stop())

    intent = brain.decide(video.frame, "look around and find something red", [])
    print("brain intent     :", intent.drive, "| state:", intent.task_state)
    print("brain observation:", intent.report.get("observation", ""))
    print("dispatcher.drive :", D.drive(intent.drive.get("throttle", 0),
                                        intent.drive.get("steer", 0),
                                        cfg["drive"]["speed_cap"]))

    await cmd.send("CMD_VIDEO#0")
    await cmd.send(D.stop())
    for t in tasks:
        t.cancel()
    print("SELFTEST DONE")


if __name__ == "__main__":
    asyncio.run(main())
