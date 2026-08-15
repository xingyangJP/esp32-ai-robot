"""
capture_frame.py — grab one live frame, save it, and (if a provider+key are set)
print the AI's description of that exact frame. Use it to check "did the AI really
see?" by comparing the saved image against the printed observation.

    python3 capture_frame.py [output.jpg]
"""
import asyncio
import sys

try:
    import tomllib as toml
except ModuleNotFoundError:
    import tomli as toml

import cv2
import car_link
from brain import Brain


async def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "snapshot.jpg"
    with open("config.toml", "rb") as f:
        cfg = toml.load(f)
    cmd = car_link.CommandLink(cfg["car"]["ip"], cfg["car"]["cmd_port"])
    video = car_link.VideoLink(cfg["car"]["ip"], cfg["car"]["camera_port"])
    tasks = [asyncio.create_task(cmd.run()), asyncio.create_task(video.run())]
    await asyncio.sleep(2.0)
    await cmd.send("CMD_VIDEO#1")
    for _ in range(60):                      # wait up to ~6s for a fresh frame
        await asyncio.sleep(0.1)
        if video.frame is not None and video.age_ms() < 500:
            break
    if video.frame is None:
        print("ERROR: no frame received")
    else:
        cv2.imwrite(out, video.frame)
        print(f"saved {out}  shape={video.frame.shape}")
        brain = Brain(cfg)
        intent = brain.decide(video.frame, "look around and describe what you see", [])
        print("AI observation:", intent.report.get("observation", ""))
        print("AI intent     :", intent.drive, "| state:", intent.task_state)
    await cmd.send("CMD_VIDEO#0")
    for t in tasks:
        t.cancel()


if __name__ == "__main__":
    asyncio.run(main())
