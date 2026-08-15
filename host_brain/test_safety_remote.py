"""
test_safety_remote.py — unit test for the REMOTE liveness reflexes in SafetyMonitor.
Pure Python (no car, no cv2, no websockets). Run: python3 test_safety_remote.py

Verifies the fixes from the team review:
  - relay uplink down          -> want_stop() == "relay link down"
  - operator heartbeat stale   -> want_stop() == "operator link lost"
  - armed + fresh operator     -> want_stop() is None (motion allowed)
  - LAN mode (relay is None)   -> operator reflex is INERT (main.py unchanged)
"""
import time
from safety import SafetyMonitor

CFG = {"safety": {"deadman_ms": 500, "vision_stale_ms": 800,
                  "low_voltage": 6.6, "operator_deadman_ms": 1500}}


class FakeCmd:
    connected = True


class FakeVideo:
    def age_ms(self):
        return 0.0          # always-fresh vision


class FakeRelay:
    def __init__(self, connected=True):
        self.connected = connected


def make(relay=None):
    s = SafetyMonitor(CFG, FakeCmd(), FakeVideo())
    s.note_intent()         # fresh brain intent
    s.voltage = 8.0         # healthy pack
    if relay is not None:
        s.relay = relay
        s.note_operator()   # fresh operator heartbeat
    return s


def test_armed_ok():
    s = make(relay=FakeRelay(connected=True))
    assert s.want_stop() is None, s.want_stop()


def test_relay_down():
    s = make(relay=FakeRelay(connected=False))
    assert s.want_stop() == "relay link down", s.want_stop()


def test_operator_stale():
    s = make(relay=FakeRelay(connected=True))
    s.last_operator_ts = time.monotonic() - 5.0     # 5s > 1500ms window
    assert s.want_stop() == "operator link lost", s.want_stop()


def test_lan_mode_inert():
    # No relay set (LAN main.py): operator/relay reflexes must NOT engage.
    s = make(relay=None)
    assert s.relay is None
    assert s.want_stop() is None, s.want_stop()      # fresh intent+vision+cmd -> go


def test_lan_never_blocks_on_operator():
    # Even with a never-stamped operator ts, LAN mode ignores it.
    s = SafetyMonitor(CFG, FakeCmd(), FakeVideo())
    s.note_intent()
    s.voltage = 8.0
    assert s.last_operator_ts == 0.0
    assert s.want_stop() is None, s.want_stop()


if __name__ == "__main__":
    tests = [test_armed_ok, test_relay_down, test_operator_stale,
             test_lan_mode_inert, test_lan_never_blocks_on_operator]
    for t in tests:
        t()
        print(f"  ok  {t.__name__}")
    print(f"SAFETY REMOTE TEST PASS ({len(tests)} cases)")
