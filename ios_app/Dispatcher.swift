import Foundation

/// Semantic actions -> exact CMD_ wire strings for the car's command server (:4000).
/// Mirrors the verified Python dispatcher. The firmware parses '#'-delimited fields;
/// CarLink appends the trailing '\n'.
enum Dispatcher {
    static let motorMin = 1600      // firmware dead-zone floor
    static let motorMax = 4095

    static func clampMotor(_ v: Int, cap: Int) -> Int {
        let capped = max(-min(cap, motorMax), min(min(cap, motorMax), v))
        if capped == 0 { return 0 }
        let mag = max(motorMin, abs(capped))
        return capped > 0 ? mag : -mag
    }

    /// throttle/steer in -1...1 (+throttle=forward, +steer=right) -> tank pair.
    static func drive(throttle: Double, steer: Double, speedCap: Int, trim: Double = 0) -> String {
        let t  = max(-1.0, min(1.0, throttle))
        let s  = max(-1.0, min(1.0, steer))
        let tr = max(-0.5, min(0.5, trim))          // + boosts left, - boosts right (straightness)
        var l = (t + s) * (1 + tr) * Double(speedCap)
        var r = (t - s) * (1 - tr) * Double(speedCap)
        // Straightness trim is otherwise eaten by the dead-zone: a wheel <1600 won't turn, so
        // the reduced side just snaps back up to 1600 and the differential vanishes. When both
        // wheels drive the SAME direction (straight-ish), scale them up together so the smaller
        // sits AT the floor and the trim RATIO survives — the correction actually takes effect.
        let mn = min(abs(l), abs(r))
        if mn > 0, mn < Double(motorMin), (l == 0 || r == 0 || (l > 0) == (r > 0)) {
            let k = Double(motorMin) / mn
            l *= k; r *= k
        }
        return "CMD_MOTOR#\(clampMotor(Int(l), cap: speedCap))#0#\(clampMotor(Int(r), cap: speedCap))"
    }

    static func stop() -> String { "CMD_MOTOR#0#0#0" }

    /// Semantic pan/tilt (90 = neutral for both) -> two raw CMD_SERVO commands,
    /// honoring the pan/tilt swap and per-axis neutral offsets (see DESIGN.md §4).
    static func look(pan semPan: Int, tilt semTilt: Int,
                     swap: Bool, panNeutral: Int, tiltNeutral: Int,
                     panInvert: Bool = false) -> [String] {
        let panCh  = swap ? 1 : 0
        let tiltCh = swap ? 0 : 1
        let panDelta = panInvert ? -(semPan - 90) : (semPan - 90)   // flip pan direction for this car
        let physPan  = max(0, min(180, panNeutral  + panDelta))
        let physTilt = max(0, min(180, tiltNeutral + (semTilt - 90)))
        return [servo(panCh, physPan), servo(tiltCh, physTilt)]
    }

    /// Drive one servo directly. index 0 = servo1 (ch0), 1 = servo2 (ch1).
    static func servo(_ index: Int, _ angle: Int) -> String {
        "CMD_SERVO#\(index)#\(max(0, min(180, angle)))"
    }

    static func face(_ mode: Int) -> String { "CMD_MATRIX_MOD#\(mode)" }      // 0=off..6=blink, >=7 random
    static func bodyLeds(_ mode: Int) -> String { "CMD_LED_MOD#\(mode)" }     // 0 off,1 static,3 blink,4 breathe,5 rainbow
    /// Set the color_1 of the LEDs selected by a 12-bit corner bitmask (mode 1/3/4 render it).
    static func led(mask: Int, r: Int, g: Int, b: Int) -> String {
        func c(_ v: Int) -> Int { max(0, min(255, v)) }
        return "CMD_LED#\(mask & 0xFFF)#\(c(r))#\(c(g))#\(c(b))"
    }
    static func buzzer(on: Bool, freq: Int) -> String {
        "CMD_BUZZER#\(on ? 1 : 0)#\(max(0, min(10000, freq)))"
    }
    static func video(_ on: Bool) -> String { "CMD_VIDEO#\(on ? 1 : 0)" }
    static func powerQuery() -> String { "CMD_POWER" }
    static func sonicQuery() -> String { "CMD_SONIC" }        // forward distance query -> "CMD_SONIC#<cm>"
    static func wifiForget() -> String { "CMD_WIFI_FORGET" }  // clear creds + reboot into SoftAP setup mode

    static let faceModes: [String: Int] = [
        "off": 0, "rotate": 1, "cry": 2, "smile": 3,
        "wheel_r": 4, "wheel_l": 5, "blink": 6, "random": 7
    ]
}
