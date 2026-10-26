import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from doppio import Doppio

def test_basic_eval():
    c = Doppio.init({"flags": [{"key": "f", "enabled": True, "rollout_percentage": 100}]})
    r = c.get("f", {"user_id": "u1"})
    assert r.enabled is True

def test_missing_flag():
    c = Doppio.init({})
    r = c.get("nope")
    assert r.reason == "ERROR"