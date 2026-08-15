# esp32-ai-robot

Turn a Freenove 4WD ESP32 car into an **AI agent you command in natural language**: give it a
goal (e.g. *"find the red cup and approach it"*), a vision-language model looks through the car's
camera, plans, and the car drives itself toward it.

The primary interface is a **native SwiftUI iPhone app** (v1.1.54) that runs the vision→action loop
and drives the car with no Mac at runtime. The car can be driven over the **home LAN**, or **remotely
from anywhere** through a Cloud Run relay.

> **License & firmware.** This repository (iOS app, host brain, Cloud relay, docs) is **MIT** — see
> [`LICENSE`](LICENSE). The ESP32 **firmware is a modified [Freenove](https://www.freenove.com) 4WD Car
> Kit for ESP32 sketch (CC BY-NC-SA 3.0) and is _not_ included here** to respect that license. Start
> from Freenove's kit sketch and add the changes described in the docs: in-app WiFi provisioning (STA
> mode), HC-SR04 sonar + forward-collision veto, a motor-direction fix, and deadman / stop-on-disconnect.
> Secrets stay out of git — copy [`.env.example`](.env.example) to a git-ignored `.env`; the host
> brain's `config.toml`, `service-account.json`, and the app's `GoogleService-Info.plist` are git-ignored too.

## Repository layout

```
esp32-ai-robot/
├── ios_app/      Native SwiftUI iPhone app (v1.1.54) — the primary interface
├── host_brain/   Python brain + remote bridge (a bench loop and the cloud bridge)
└── relay/        Cloud Run WebSocket relay (pairs phone <-> home bridge)
```

The ESP32 firmware is **not** in this repo — it is a not-included Freenove derivative (see the license
note above).

## What it does today

- **iPhone app** (v1.1.54): type or speak a goal, watch the live camera HUD; the app runs the
  vision→action loop and drives the car directly (no Mac at runtime). See [`ios_app/README.md`](ios_app/README.md).
- **LAN mode**: the phone talks straight to the car over the home WiFi.
- **Remote (cloud) mode**: phone ⇄ Cloud Run relay ⇄ home-side Python bridge ⇄ car, paired by
  Firebase identity (Sign in with Apple on the phone, a service-account custom token on the bridge).
  See [`REMOTE.md`](REMOTE.md) and [`relay/README.md`](relay/README.md).
- **In-app WiFi provisioning**: set the car's home WiFi from the app; the car reboots into STA mode
  and the app re-discovers it on the network. See [`WIFI_PROVISIONING_DESIGN.md`](WIFI_PROVISIONING_DESIGN.md).
- **Sonar forward-collision veto**: an HC-SR04 gives the car a reflex STOP/escape ahead of the AI loop.
- **Safety reflexes**: E-STOP, dry-run, deadman (no fresh intent), low-battery, and stale-vision all
  force STOP; the firmware deadman is the on-device backstop.

## Quick start (bench — the `host_brain` Python loop)

```bash
cd host_brain
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp config.example.toml config.toml     # edit: car IP, provider, model, api_key_env
export GEMINI_API_KEY=...               # or OPENAI_API_KEY / ANTHROPIC_API_KEY
python3 main.py
```

The default provider is Gemini (`config.example.toml`: `provider="gemini"`, `model="gemini-2.0-flash"`);
OpenAI and Anthropic also work. Keep `dry_run=true` for a bench/USB run — it plans and logs actions
but never sends motion. Set `dry_run=false` only with batteries in and a hand on **stop**.

## Status

LAN and remote operation, WiFi provisioning, and sonar collision are **shipped in the app (v1.1.54)**
and have been exercised on the real car. Autonomous driving is used **supervised**; treat long
unattended autonomy as **not yet validated**. The full comms layer (command + camera) is proven
against the real hardware.

The original design proposal that started this project is kept in
[`AI_ROBOT_PROPOSAL.md`](AI_ROBOT_PROPOSAL.md) for history; [`DESIGN.md`](DESIGN.md) and
[`REQUIREMENTS.md`](REQUIREMENTS.md) are the current specs.
