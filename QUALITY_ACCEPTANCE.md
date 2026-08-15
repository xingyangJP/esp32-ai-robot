# RobotBrain Quality Acceptance Matrix

- Updated: 2026-07-28
- Scope: documentation-only quality criteria for the near-release RobotBrain rover.
- Version reference: iOS app `1.1.54`, bundle `com.example.robotbrainai`.

## Acceptance Matrix

| ID | Requirement / behavior | Implementation anchor | Static check | Real-device acceptance |
|---|---|---|---|---|
| FR-35 / FR-57 | STOP clears every motion latch and cannot re-drive after START/reconnect/mode switch without a new command. | `RobotController.haltMotionState()`, `emergencyStop()`, `stopAll()`, `switchMode()`, `onControlModeChanged()` | Source review: pulse, teleop, escape, search, approach, taskState, TTS, celebration are cleared/stopped. | While AI/search/teleop/escape/celebration is active, press STOP; then START/reconnect/switch mode. Wheels stay stopped until a new goal or manual command. |
| FR-59 | Direct movement commands are treated as timed teleop, while search phrases remain goals. | `RobotController.handleDriveCommand()`, `runCommand()` | Source review: search words short-circuit command hijack; reverse/forward/turn/stop phrases are parsed. | Say/type `2秒後進して`; rover reverses for bounded time and STOP is visible. Say/type `止まっている人を探して`; AI search starts, not teleop STOP. |
| FR-60 / HC-8 | Collision escape engages from fresh front sonar and uses hysteresis. | `RobotController.collisionEscape()`, firmware `FORWARD_STOP_CM` | Source review: host engage 25cm, dark 32cm, clear 40cm, max reverse 1.4s, pivot 0.65s; firmware veto 20cm. | In low-speed forward AI/manual test, obstacle within threshold causes reverse then pivot; no oscillating forward into the same wall. |
| FR-61 | Head-mounted sonar is used only as forward distance when the head guards travel. | `headForward`, `centerForDrive()`, `driveTilt`, `sonicQuery()` | Source review: distance freshness <=1.5s and head/intent gating are present. | With head off-center, stale/sideways readings are not treated as forward clearance. During forward travel, head centers before/while measuring. |
| FR-62 | Low-light mode reduces risk but is documented as non-guarantee. | `frameLuma()`, `lowLightLuma=55`, `relocateClearDarkCm=65`, LED headlight cue | Source review: luma threshold, white LED, throttle 0.30, duration 250ms. | In dim scene, headlight turns on, relocate pulses slow down, and close obstacle response occurs earlier. |
| FR-42 | Low battery blocks motion and is visible to the operator. | `CMD_POWER`, `lowVoltage=6.6`, `lowBatteryBanner` | Source review: 3s polling, parse voltage, `safety.lowBattery`, UI banner. | With pack below threshold or simulated low voltage, wheels stop and UI shows low battery reason with voltage. |
| FR-64 | TTS is interruptible and cannot continue stale observations after STOP/new goal/mode switch. | `Speech.stopSpeaking()`, `emergencyStop()`, `stopAll()`, `switchMode()`, `onControlModeChanged()` | Source review: stop paths call speech cancellation. | Start a spoken observation, press STOP or switch mode; speech stops immediately and old queue does not resume. |
| FR-65 | Done celebration is bounded and interruptible. | `celebrate()`, `stopCelebrate()` | Source review: rainbow ~3.2s, jingle <5s, stop paths silence buzzer and release LED state. | Trigger done, confirm short rainbow/fanfare; press STOP/new goal during it and buzzer stops immediately. |
| RFR-1 / RFR-11 | Remote starts disarmed and requires explicit arm/dry-run OFF confirmation. | `RobotController.start()`, `ConfigView` arm confirmation, `bridge_main.py` arm/disarm | Source review: Remote sets dryRun true, production WSS requires sign-in, dry-run OFF opens confirmation. | Switch to Remote, connect, confirm DRY is ON. Attempt dry-run OFF; confirmation appears. After disconnect/reconnect, DRY is ON again. |
| RFR-10 / RFR-13 | Remote link/operator/camera/command failures fail safe. | `SafetyMonitor.want_stop()`, `bridge_main.py` peer handling, `RobotController.remoteStatusKey()` | Source review: `relay link down`, `operator link lost`, `command-link down`, `vision stale (blind)`, `deadman`, `low battery`. | Drop phone relay, bridge relay, camera, and car command links one at a time; rover stops, UI reason matches, and re-arm is required where applicable. |
| RNFR-2 / RNFR-3 | Remote auth uses current MVP `hello.token` and never URL query tokens. | `relay/server.py`, `RelayClient.open()`, `relay_link.py` | Source review: first JSON hello has role/token; invalid token closes 4003; URL contains no token. | Production relay rejects missing/bad token. Logs do not show token or full payload. |
| RNFR-3 / Security | Secrets and production logs are redacted. | `.gitignore`, `firebase_auth.py`, relay/bridge logs | Source review: secret files ignored; docs require 600 permissions and production redaction. | Confirm `config.toml`, `service-account.json`, `GoogleService-Info.plist`, `.env` are not committed and production logs omit token/uid/room/goal/observation/full JSON. |

## Release Gate

- Automatic/static checks: `git diff --check`, stale-doc search for known outdated claims, and source-to-doc trace review.
- Real-device checks: run the acceptance rows above on the rover with batteries installed, low speed, and a supervised indoor flat area.
- Any unchecked real-device row should stay visible as release risk rather than being silently assumed complete.
