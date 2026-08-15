import Foundation

/// One resolved LED state. `key` dedupes so the car is only re-commanded on a change
/// (no 10 Hz spam). `mode` is the firmware WS2812 mode that renders color_1:
/// 1 = static, 3 = blink, 4 = breathe (device-side animation, so no host spam).
struct LedCue: Equatable {
    let key: String
    let mode: Int
    let mask: Int
    let r: Int, g: Int, b: Int
    let chirp: Bool          // reverse -> a short buzzer chirp (edge-triggered by the applier)
}

/// The car's "light language": maps state -> a corner-LED cue. Mirrors
/// host_brain/dispatcher.py `led_cue()` — keep the two byte-for-byte in sync.
///
/// CORNER MAP (12 WS2812, 4 corners x 3). These masks are a GUESS about the wiring
/// order; a wrong map only puts a color on the wrong corner (cosmetic). To identify:
/// with the car on LAN, send `CMD_LED_MOD#1` then `CMD_LED#<mask>#0#255#0` for each of
/// FL/FR/RL/RR and note which physical corner turns green; set the four masks here and
/// in dispatcher.py identically. Fallback: walk single bits `1<<i` for i in 0...11.
enum LedLanguage {
    static let FL = 0x007   // front-left  (LEDs 0,1,2)
    static let FR = 0x038   // front-right (3,4,5)
    static let RL = 0x1C0   // rear-left   (6,7,8)
    static let RR = 0xE00   // rear-right  (9,10,11)
    static let FRONT = FL | FR
    static let REAR  = RL | RR
    static let LEFT  = FL | RL
    static let RIGHT = FR | RR
    static let ALL   = 0xFFF
    static let turnSteer = 0.35     // |steer| above this shows a turn indicator

    /// Priority: estop > low-batt > (idle when not running) > done-flash > blocked >
    /// link/vision wait > reverse > turn > forward > approaching > searching.
    static func cue(running: Bool, estop: Bool, reason: String?, taskState: String,
                    throttle: Double, steer: Double, doneFlash: Bool) -> LedCue {
        if estop { return LedCue(key: "estop", mode: 3, mask: ALL, r: 255, g: 0, b: 0, chirp: false) }
        if reason == "safety.lowBattery" {
            return LedCue(key: "lowbatt", mode: 3, mask: ALL, r: 255, g: 40, b: 0, chirp: false)
        }
        if !running { return LedCue(key: "idle", mode: 1, mask: ALL, r: 0, g: 0, b: 60, chirp: false) }
        if doneFlash { return LedCue(key: "done", mode: 5, mask: ALL, r: 0, g: 255, b: 0, chirp: false) }   // rainbow = celebrate
        if taskState == "blocked" {
            return LedCue(key: "blocked", mode: 3, mask: ALL, r: 255, g: 90, b: 0, chirp: false)
        }
        if reason == "safety.linkDown" || reason == "safety.visionStale" {
            return LedCue(key: "wait", mode: 1, mask: ALL, r: 0, g: 0, b: 60, chirp: false)
        }
        if throttle < -0.05 { return LedCue(key: "reverse", mode: 1, mask: REAR, r: 255, g: 0, b: 0, chirp: true) }
        if steer > turnSteer { return LedCue(key: "turnR", mode: 1, mask: RIGHT, r: 255, g: 120, b: 0, chirp: false) }
        if steer < -turnSteer { return LedCue(key: "turnL", mode: 1, mask: LEFT, r: 255, g: 120, b: 0, chirp: false) }
        if throttle > 0.05 { return LedCue(key: "forward", mode: 1, mask: FRONT, r: 255, g: 255, b: 255, chirp: false) }
        if taskState == "approaching" { return LedCue(key: "approach", mode: 1, mask: ALL, r: 0, g: 200, b: 0, chirp: false) }
        if taskState == "idle" { return LedCue(key: "standby", mode: 1, mask: ALL, r: 40, g: 40, b: 45, chirp: false) }   // manual/at-rest
        return LedCue(key: "search", mode: 4, mask: ALL, r: 0, g: 180, b: 200, chirp: false)   // cyan breathe
    }
}
