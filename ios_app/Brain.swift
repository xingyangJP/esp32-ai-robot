import Foundation
import UIKit

struct Intent {
    var throttle: Double = 0
    var steer: Double = 0
    var durationMs: Int = 300
    var pan: Int? = nil
    var tilt: Int? = nil
    var face: String? = nil
    var observation: String = ""
    var taskState: String = "searching"   // searching | approaching | done | blocked
    // --- Fused-exploration perception (FR-67 / DESIGN §16.6): while SEARCHING the VLM reports, per
    // frame, the openness of the direction the head currently faces + the kind of hazard a distance
    // sensor misses. The host fuses these with the head-mounted sonar to choose a heading; the VLM does
    // NOT emit drive values while searching. nil forwardOpen = the model didn't report one this frame.
    var forwardOpen: Double? = nil        // 0 = blocked, 1 = open floor / hallway / doorway
    var hazard: String = "none"           // none | soft (curtain/cloth) | ledge (drop-off) | wall

    static let hold = Intent()
}

/// Calls an OpenAI vision model with one frame + the goal, returns a structured Intent.
/// The model only emits semantic verbs; Dispatcher lowers them to CMD_ strings with clamps.
enum Brain {
    static let system = """
    You are the cortex of a small indoor 4-wheel rover. You see through a low-resolution \
    (240x176) forward camera on a pan/tilt mast. pan and tilt are 0-180 with 90 = straight \
    ahead and level. TILT: values ABOVE 90 aim the camera UP (toward 180); values BELOW 90 \
    aim it DOWN. PAN: 90 is centered; above 90 turns the head one way, below 90 the other. \
    Changing these numbers is the ONLY way to move the head - describing a look in \
    "observation" does NOTHING; you MUST set pan and tilt to where you want to point THIS \
    frame, every frame (repeat the current angle only to hold).
    You have ONE forward distance sensor. FORWARD (given each turn) is the clear distance in \
    cm straight ahead ("no echo" = far/clear, but the sensor MISSES soft, thin, or steeply- \
    angled objects, so it can read "no echo" with a real obstacle there). It sees ONLY \
    straight ahead - nothing about the sides, the floor, ledges or drop-offs; the camera is \
    still your only cue for those. Forward drive is HARD-vetoed by hardware when FORWARD is \
    under 20cm: commanding throttle > 0 that close does NOT move you, the car just sits. \
    Between 20 and 30cm forward still works but is tight - turn early rather than creep in. \
    Reverse and pivot are never blocked.
    THE HOST SOFTWARE RUNS THE SEARCH FOR YOU. While you have NOT yet found the goal it \
    automatically sweeps this camera head around the spot, and when the spot is exhausted it drives \
    the car to a new spot and sweeps again with short, sonar-guarded pulses. While task_state is \
    "searching" the host controls throttle, steer, pan and tilt (do NOT try to aim or drive). Your job \
    each frame:
     - If you can SEE the goal (or clearly part of it) in this frame: set task_state "approaching". \
       From that point ON the host hands control to YOU and stops auto-searching - now you drive: aim \
       the head toward the goal (pan/tilt) and move toward it (throttle/steer), keeping "approaching" \
       until you are about 25cm away, then "done" with throttle 0.
     - If the goal is NOT in this frame: keep task_state "searching" and just describe what you see \
       in "observation" (whether the goal is absent, and what IS visible). Let the host sweep and \
       move. Do NOT report "blocked" merely because the goal is not visible - the host keeps exploring; \
       only use "blocked" if the whole area is genuinely impassable.
    WHILE SEARCHING, every frame ALSO report the openness of the direction the head is CURRENTLY facing \
    so the host can fuse it with its distance sensor to pick where to go:
     - "forward_open": 0.0-1.0. HIGH (toward 1) = open floor, a clear hallway, or a doorway you could \
       drive through in the direction the head faces now. LOW (toward 0) = a wall, furniture, clutter, \
       or a dead end fills that direction. Judge THE DIRECTION THE HEAD FACES THIS FRAME, not the goal.
     - "hazard": one of none|soft|ledge|wall - the kind of thing a forward distance sensor MISSES. \
       "soft" = a curtain, cloth, or thin/see-through thing the sonar echoes straight through; \
       "ledge" = the floor ends, a drop-off, a table edge, or stairs going down; "wall" = a solid \
       barrier the sonar may read past at an angle; "none" = clear. The host will NOT drive into a \
       ledge/wall and will avoid a soft hazard even when the sonar reads "no echo".
    While task_state is "searching" the HOST owns throttle, steer, pan and tilt - report forward_open \
    and hazard and do NOT try to drive or aim (any drive values you send while searching are ignored).
    WHILE APPROACHING (you are the one driving): FORWARD (given each turn) is the clear distance in \
    cm straight ahead. Hardware HARD-vetoes forward drive under 20cm (the car just sits) and it is \
    tight under 30cm, so turn or stop early; reverse and pivot are never blocked. FORWARD watches \
    ONLY straight ahead and can MISS soft, thin or steeply-angled objects, so ALSO refuse forward \
    drive when the frame shows a wall/object filling it or the floor ENDS or DROPS AWAY (ledge, table \
    edge, stairs) even if FORWARD reads far - trust the frame over a "no echo". You are blind behind \
    and to the sides: keep any reverse slow and brief. You have REACHED a physical goal at about \
    25cm - stop there (throttle 0, task_state "done"); you cannot get nearer than ~20cm. FORWARD \
    guards obstacles taller than ~10cm; watch the camera for low objects, ledges and floor hazards.
    Reply with ONE JSON object, no prose:
    {"throttle":-1..1,"steer":-1..1,"duration_ms":100..800,
     "pan":0..180,"tilt":0..180,
     "forward_open":0..1,"hazard":"none|soft|ledge|wall",
     "observation":"what you see","task_state":"searching|approaching|done|blocked"}
    Always include pan and tilt. While searching, ALWAYS include forward_open and hazard. If task_state \
    is done or blocked, set throttle 0.
    """

    static func decide(image: UIImage, goal: String, memory: [String],
                       apiKey: String, model: String, lang: String, distanceCm: Double? = nil) async -> Intent {
        guard !apiKey.isEmpty,
              let jpeg = image.jpegData(compressionQuality: 0.8) else { return .hold }
        let b64 = jpeg.base64EncodedString()
        let langLine = lang == "ja"
            ? "\nWrite the \"observation\" text in natural Japanese."
            : "\nWrite the \"observation\" text in natural English."
        let recent = memory.suffix(12)
        // The host now sequences the search (sweep/relocate), so no "you must relocate" nudge here —
        // that would fight the host. The VLM only needs the goal, the forward distance (for when it is
        // driving an approach), and RECENT for context on what it has already seen.
        let distStr: String = {
            guard let d = distanceCm else { return "unknown" }
            return d >= 250 ? "no echo (far/clear, but may miss soft/thin/angled objects)" : "\(Int(d)) cm"
        }()
        let user = "GOAL: \(goal)\nFORWARD: \(distStr) ahead\nRECENT: \(recent.joined(separator: " | "))\nIs the goal in view? If yes set task_state \"approaching\" and drive to it; if no keep \"searching\" and describe what you see."

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system + langLine],
                ["role": "user", "content": [
                    ["type": "text", "text": user],
                    ["type": "image_url",
                     "image_url": ["url": "data:image/jpeg;base64,\(b64)", "detail": "low"]]
                ]]
            ]
        ]
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return .hold }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = data
        req.timeoutInterval = 8   // bound a hung call so it can't stall the decision loop

        do {
            let (respData, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else { return .hold }
            return parse(content)
        } catch {
            return .hold
        }
    }

    static func parse(_ text: String) -> Intent {
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}") else { return .hold }
        let slice = String(text[s...e])
        guard let d = slice.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return .hold }
        var i = Intent()
        i.throttle = (j["throttle"] as? NSNumber)?.doubleValue ?? 0
        i.steer = (j["steer"] as? NSNumber)?.doubleValue ?? 0
        i.durationMs = max(100, min(800, (j["duration_ms"] as? NSNumber)?.intValue ?? 300))
        i.pan = (j["pan"] as? NSNumber)?.intValue
        i.tilt = (j["tilt"] as? NSNumber)?.intValue
        i.face = j["face"] as? String
        i.observation = j["observation"] as? String ?? ""
        i.taskState = j["task_state"] as? String ?? "searching"
        // Fused-exploration perception (FR-67): openness of the faced direction + a hazard the sonar
        // misses. forwardOpen stays nil when the model omits it (host then leans on the sonar).
        if let fo = (j["forward_open"] as? NSNumber)?.doubleValue { i.forwardOpen = min(max(fo, 0), 1) }
        i.hazard = (j["hazard"] as? String).map { $0.lowercased() } ?? "none"
        return i
    }
}
