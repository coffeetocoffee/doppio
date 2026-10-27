"""Dual-run bridge: shadow-mode evaluation of incumbent + Doppio, diff report."""
import json, sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "packages", "py", "src"))
from doppio import Doppio

class DualRunBridge:
    def __init__(self, incumbent_flags, doppio_flags):
        self.incumbent = {f["key"]: f for f in incumbent_flags}
        self.doppio = Doppio.init({"flags": doppio_flags})
        self.log = []

    def evaluate(self, flag_key, context):
        # incumbent (simulated: use its own evaluation logic placeholder)
        inc_val = self._incumbent_eval(flag_key, context)
        # doppio
        t0 = time.time()
        try:
            dres = self.doppio.get(flag_key, context)
            doppio_val = dres.value
            doppio_reason = dres.reason
            err = None
        except Exception as e:
            doppio_val = None
            doppio_reason = "ERROR"
            err = str(e)
        latency = (time.time() - t0) * 1000
        mismatch = (inc_val != doppio_val)
        record = {
            "flag": flag_key,
            "context": context,
            "incumbent": inc_val,
            "doppio": doppio_val,
            "doppio_reason": doppio_reason,
            "mismatch": mismatch,
            "latency_ms": round(latency, 2),
            "error": err,
        }
        self.log.append(record)
        return inc_val  # serve incumbent in shadow mode

    def _incumbent_eval(self, flag_key, context):
        f = self.incumbent.get(flag_key)
        if not f:
            return False
        if not f.get("enabled", True):
            return False
        return True

    def report(self):
        total = len(self.log)
        mismatches = [r for r in self.log if r["mismatch"]]
        by_flag = {}
        for r in self.log:
            by_flag.setdefault(r["flag"], {"total": 0, "mismatch": 0})
            by_flag[r["flag"]]["total"] += 1
            if r["mismatch"]:
                by_flag[r["flag"]]["mismatch"] += 1
        summary = {
            "total_evaluations": total,
            "total_mismatches": len(mismatches),
            "mismatch_rate": (len(mismatches) / total) if total else 0,
            "by_flag": {k: {"total": v["total"], "mismatch": v["mismatch"],
                           "rate": v["mismatch"]/v["total"] if v["total"] else 0} for k, v in by_flag.items()},
            "avg_latency_ms": (sum(r["latency_ms"] for r in self.log) / total) if total else 0,
        }
        return summary

if __name__ == "__main__":
    inc = json.load(open(sys.argv[1]))
    dst = json.load(open(sys.argv[2]))
    ctxs = json.load(open(sys.argv[3]))
    bridge = DualRunBridge(inc, dst)
    for ctx in ctxs:
        for f in dst:
            bridge.evaluate(f["key"], ctx)
    rep = bridge.report()
    print(json.dumps(rep, indent=2))
    if len(sys.argv) > 4:
        with open(sys.argv[4], "w") as fh:
            json.dump(rep, fh, indent=2)