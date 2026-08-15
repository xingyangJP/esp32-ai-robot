"""
brain.py — the cortex: one HQVGA frame + goal + short memory -> a structured Intent.

Concept B ("chat/voice goal -> autonomous task"): the user gives a natural-language
goal; each decision tick the VLM returns ONE bounded, self-expiring action.

Providers are pluggable (Gemini / OpenAI / Anthropic); pick one in config.toml.
provider="none" (or dry_run) returns a safe hold so the whole loop runs with no API.

The model NEVER emits raw motor numbers — only semantic verbs, which dispatcher.py
lowers to CMD_ strings with all clamps applied.
"""
import base64
import json
import os
import cv2

SYSTEM_PROMPT = """You are the cortex of a small indoor 4-wheel rover.
You see through a low-resolution (240x176) forward camera on a pan/tilt mast.
pan and tilt are 0-180 with 90 = straight ahead and level. TILT: values ABOVE 90
aim the camera UP (toward 180); values BELOW 90 aim it DOWN. PAN: 90 is centered;
above 90 turns the head one way, below 90 the other. Emitting "look" is the ONLY way
to move the head - describing a look in "observation" does NOTHING; you MUST include
"look" with the pan/tilt you want THIS frame, every frame (repeat the current angle
only to hold).
You have ONE forward distance sensor. Each turn the user line gives FORWARD: the clear
distance in cm straight ahead ("no echo" = far/clear, but the sensor MISSES soft, thin, or
steeply-angled objects, so it can read "no echo" with a real obstacle there). It sees ONLY
straight ahead - nothing about the sides, the floor, ledges or drop-offs; the camera is
still your only cue for those. Forward drive is HARD-vetoed by hardware when FORWARD is
under 20cm: commanding throttle > 0 that close does NOT move you - the car just sits.
Between 20 and 30cm forward still works but is tight - turn early rather than creep in.
Reverse and pivot are never blocked.

Each turn you receive: the current goal, a short memory of recent (action, outcome)
pairs, and one camera frame. Reply with a SINGLE JSON object, no prose:

{
  "drive":  {"throttle": <-1..1>, "steer": <-1..1>, "duration_ms": <100..800>},
  "look":   {"pan_deg": <0..180>, "tilt_deg": <0..180>},
  "forward_open": <0..1>,
  "hazard": "none|soft|ledge|wall",
  "report": {"observation": "<what you see>", "task_state": "searching|approaching|done|blocked"}
}

WHILE SEARCHING (task_state "searching" or "blocked") the HOST moves the car, fusing your camera
read with the head-mounted distance sensor to choose where to go. So while searching you are a
SENSOR, not a driver: every frame report, for the direction the head is CURRENTLY facing,
 - "forward_open": 0.0..1.0 — how open/drivable that direction looks. 1.0 = clearly open floor /
   a corridor / a doorway you could roll through; 0.0 = a wall, furniture, clutter, or the floor
   ends/drops away (ledge, table edge, stairs). Judge the DIRECTION YOU FACE THIS FRAME, not ahead.
 - "hazard": the kind of thing the distance beam MISSES — "soft" (curtain/cloth/thin), "ledge"
   (floor ends / drop-off), "wall" (solid barrier the sensor may skim), or "none".
Your "drive" is IGNORED while searching — set throttle 0, steer 0 (the host relocates). Keep
scanning honestly and set task_state "approaching" the instant the GOAL itself is in view; only
then does your "drive"/"look" steer the approach. Report "blocked" only if truly walled in.

THREE DIFFERENT MOVES - do not confuse them:
 - LOOK (change pan_deg/tilt_deg): turns only the camera. No crash risk. Use it to scan the
   spot you are standing on.
 - PIVOT (throttle 0 with steer +-1): rotates the body in place WITHOUT going anywhere. It
   changes your heading but you stay on the SAME spot seeing the SAME area. A pivot is NOT
   exploration.
 - RELOCATE (throttle > 0, short pulse): actually DRIVES the car to a NEW spot in the room.
   This is the ONLY move that searches somewhere new. Exploring REQUIRES relocating, not
   just pivoting.

SEARCH LOOP - follow it in order:
 1) SCAN here: sweep the head to cover this spot - change pan_deg by 20-40 each turn and
    vary tilt_deg across the arc you have NOT yet looked at from here (check RECENT for the
    pan values already used). A few looks cover a spot; do not keep re-looking it.
 2) RELOCATE once the scan finds no goal: pick a direction with visible OPEN FLOOR ahead
    and DRIVE a short, slow pulse to a new spot - throttle 0.3 to 0.5, duration_ms 200-400,
    steer 0 for straight or +-0.3 to curve toward the opening. You CANNOT look sideways AND
    drive in one move: to drive, the head is FORCED forward (pan 90, tilt ~83) and any pan/tilt
    you send on a driving move is IGNORED - so pan/tilt freely ONLY when throttle and steer are
    both 0 (stopped). To head toward something off to one side, PIVOT (steer, throttle 0) until
    it is centered near pan 90, THEN relocate forward. ONE pulse, then STOP
    and re-scan from the new spot. The wheels have a MINIMUM speed, so "slow and careful"
    comes from SHORT duration_ms, not from a tiny throttle.
 3) Repeat: scan the new spot, relocate again, walking the car around the room spot by spot
    until you find the goal or have genuinely visited the whole room.

DO NOT re-scan a spot you already covered. RECENT is your OWN last several
{look, drive, outcome} entries. Before answering, read it: if it shows you already scanned
this heading/spot and the "outcome" was this same thing, do NOT look there again and do NOT
pivot in place to see it from a hair-different angle - RELOCATE to ground you have not been
on. Your "observation" must name what is DIFFERENT from the RECENT outcomes (a new object,
new furniture, more open floor, a doorway); if nothing is different you are wasting the turn
- relocate.

CRASH SAFETY: use FORWARD as your first cue and the frame for the rest. When FORWARD is
small (roughly < 30cm) do NOT emit forward throttle - turn early: PIVOT 30-60 degrees toward
open floor, or back off a short pulse (throttle -0.3 to -0.4, duration_ms <= 250) then pivot,
and relocate that way. FORWARD watches ONLY straight ahead, so ALSO refuse forward drive when
the frame shows a wall/object filling it or the floor ENDS or DROPS AWAY (ledge, table edge,
stairs) even if FORWARD reads far, AND remember the beam can miss soft/thin/angled things -
trust the frame over a "no echo". The camera faces FORWARD only, so you are blind behind you:
keep any reverse slow and brief. Never chain two forward pulses without a fresh look between
them. If your goal is a physical object, you have REACHED it at about 25cm - stop there
(throttle 0); you cannot physically close nearer than ~20cm. FORWARD is valid ONLY when the
head is centered (it always is while driving, except during an approach); while scanning off
to one side FORWARD reads "unknown" - then ignore it and rely on the frame. FORWARD guards
obstacles taller than ~10cm; watch the camera for low objects, ledges and floor hazards.
Only report "blocked" if you have tried relocating in several different directions and are
truly walled in every way; a single obstacle means turn and go around, not give up.

Rules: always include "drive" and "look" (throttle 0 holds; repeat the current angle
to hold the head). If task_state is "done" or "blocked", set throttle 0. Local safety
(link/vision/deadman/battery) plus the forward hard-stop may stop you at any time; nothing
senses the SIDES or the floor, so the frame still governs those."""


def _clamp01(v, default=0.5):
    try:
        return max(0.0, min(1.0, float(v)))
    except (TypeError, ValueError):
        return default


class Intent:
    def __init__(self, d):
        self.drive = d.get("drive", {"throttle": 0, "steer": 0, "duration_ms": 300})
        self.look = d.get("look")
        self.face = d.get("face")
        self.report = d.get("report", {"observation": "", "task_state": "searching"})
        # --- Fusion search fields (DESIGN §16.6): per-direction openness + hazard the sonar misses.
        # Accept them at top level or nested in report (models vary); default to a neutral opening.
        fo = d.get("forward_open", self.report.get("forward_open", 0.5))
        hz = d.get("hazard", self.report.get("hazard", "none"))
        self.forward_open = _clamp01(fo, 0.5)
        self.hazard = hz if hz in ("none", "soft", "ledge", "wall") else "none"

    @property
    def task_state(self):
        return self.report.get("task_state", "searching")


def _hold():
    """A FRESH safe-hold Intent. Returned (not the shared HOLD) wherever the caller may mutate it —
    the search fusion / reflex reassign drive/look and set report[task_state], so handing back the
    module singleton would pollute every later hold."""
    return Intent({"drive": {"throttle": 0, "steer": 0, "duration_ms": 300},
                   "report": {"observation": "(hold)", "task_state": "searching"}})


HOLD = _hold()          # read-only default for State.intent; never mutate this instance


def _jpeg_b64(frame_bgr) -> str:
    ok, buf = cv2.imencode(".jpg", frame_bgr, [cv2.IMWRITE_JPEG_QUALITY, 80])
    return base64.b64encode(buf.tobytes()).decode() if ok else ""


def frame_luma(frame_bgr):
    """Mean brightness (0-255) of a BGR frame, or None. Cheap dark-scene detector for the low-light
    fusion fallback (FR-70); a channel mean is a good-enough proxy for luma at this resolution."""
    if frame_bgr is None:
        return None
    try:
        return float(frame_bgr.mean())
    except Exception:
        return None


def _parse(text: str) -> Intent:
    try:
        i, j = text.find("{"), text.rfind("}")
        return Intent(json.loads(text[i:j + 1]))
    except Exception:
        return _hold()


class Brain:
    def __init__(self, cfg):
        self.cfg = cfg["brain"]
        self.provider = self.cfg["provider"]
        self.model = self.cfg["model"]
        self.key = os.environ.get(self.cfg.get("api_key_env", ""), "")
        if self.provider != "none" and not self.key:
            print(f"[brain] WARNING: env {self.cfg.get('api_key_env')} not set -> forcing dry hold")
            self.provider = "none"

    def decide(self, frame_bgr, goal: str, memory: list, distance=None) -> Intent:
        if self.provider == "none" or frame_bgr is None:
            return _hold()
        recent = memory[-12:]
        since_drive = 0
        for e in reversed(recent):
            if abs(float((e.get("drive") or {}).get("throttle", 0) or 0)) < 0.05:
                since_drive += 1
            else:
                break
        known = isinstance(distance, (int, float))
        close = known and distance < 30
        if since_drive < 3:
            nudge = ""
        elif close and since_drive >= 5:
            nudge = ("\nYou have pivoted/looked %d turns and FORWARD is blocked (<30cm). Pivoting is NOT "
                     "escaping. You MUST back up a short pulse THIS turn (throttle -0.3 to -0.4), not pivot again."
                     % since_drive)
        elif close:
            nudge = ("\nYou have pivoted/looked %d turns and FORWARD is blocked (<30cm). Do NOT push forward - "
                     "PIVOT toward open floor or back up a short pulse THIS turn." % since_drive)
        elif not known:
            nudge = ("\nYou have only looked/pivoted for %d turns and FORWARD is unknown. Relocate toward visible "
                     "open floor; if the frame shows a wall filling it, pivot instead." % since_drive)
        else:
            nudge = ("\nYou have only looked/pivoted for %d turns without RELOCATING. Drive a short forward pulse "
                     "toward open floor to a NEW spot THIS turn." % since_drive)
        if not known:
            dist = "unknown"
        elif distance >= 250:
            dist = "no echo (far/clear, but may miss soft/thin/angled objects)"
        else:
            dist = f"{distance:.0f} cm"
        user = f"GOAL: {goal}\nFORWARD: {dist} ahead\nRECENT: {json.dumps(recent)}{nudge}\nDecide the next action."
        img = _jpeg_b64(frame_bgr)
        try:
            if self.provider == "gemini":
                return self._gemini(user, img)
            if self.provider == "openai":
                return self._openai(user, img)
            if self.provider == "anthropic":
                return self._anthropic(user, img)
        except Exception as e:
            print(f"[brain] call failed ({e}) -> hold")
        return _hold()

    def _gemini(self, user, img_b64):
        import google.generativeai as genai
        genai.configure(api_key=self.key)
        m = genai.GenerativeModel(self.model, system_instruction=SYSTEM_PROMPT)
        r = m.generate_content([user, {"mime_type": "image/jpeg",
                                       "data": base64.b64decode(img_b64)}])
        return _parse(r.text)

    def _openai(self, user, img_b64):
        from openai import OpenAI
        client = OpenAI(api_key=self.key)
        r = client.chat.completions.create(
            model=self.model,
            messages=[{"role": "system", "content": SYSTEM_PROMPT},
                      {"role": "user", "content": [
                          {"type": "text", "text": user},
                          {"type": "image_url", "image_url":
                              {"url": f"data:image/jpeg;base64,{img_b64}", "detail": "low"}}]}],
        )
        return _parse(r.choices[0].message.content)

    def _anthropic(self, user, img_b64):
        import anthropic
        client = anthropic.Anthropic(api_key=self.key)
        r = client.messages.create(
            model=self.model, max_tokens=400, system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": [
                {"type": "image", "source": {"type": "base64",
                 "media_type": "image/jpeg", "data": img_b64}},
                {"type": "text", "text": user}]}],
        )
        return _parse(r.content[0].text)
