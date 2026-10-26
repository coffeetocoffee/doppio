import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from doppio import SyncClient, DoppioOptions

def test_apply_snapshot():
    opts = DoppioOptions(endpoint="http://x", sync_strategy="manual")
    sc = SyncClient(opts)
    sc.apply_snapshot({"type": "snapshot", "seq": 5, "flags": [{"key": "f", "enabled": True, "rollout_percentage": 50}]})
    assert len(sc.get_flags()) == 1
    assert sc.last_seq == 5

def test_apply_delta_delete():
    opts = DoppioOptions(endpoint="http://x", sync_strategy="manual")
    sc = SyncClient(opts)
    sc.apply_snapshot({"type": "snapshot", "seq": 1, "flags": [{"key": "f", "enabled": True}]})
    sc.apply_delta({"type": "delta", "seq": 2, "changes": [{"key": "f", "deleted": True}]})
    assert sc.get_flags() == []