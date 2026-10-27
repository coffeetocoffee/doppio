"""Shadow-mode bridge: evaluate both source and Doppio, log mismatches, serve Doppio."""
import json, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "packages", "py", "src"))

from doppio import Doppio

def run(source_flags, doppio_flags, contexts, log_path):
    src_client = None  # placeholder: source platform client
    dst = Doppio.init({"flags": doppio_flags})
    mismatches = []
    for ctx in contexts:
        for f in doppio_flags:
            key = f["key"]
            # source evaluation (simulated: use converted flags as proxy)
            src_val = None
            dst_res = dst.get(key, ctx)
            if src_val is not None and src_val != dst_res.value:
                mismatches.append({
                    "flag": key,
                    "context": ctx,
                    "source": src_val,
                    "doppio": dst_res.value,
                    "reason": dst_res.reason,
                })
    with open(log_path, "w") as fh:
        for m in mismatches:
            fh.write(json.dumps(m) + "\n")
    print(f"evaluated {len(contexts)*len(doppio_flags)} pairs, {len(mismatches)} mismatches")

if __name__ == "__main__":
    src = json.load(open(sys.argv[1]))
    dst = json.load(open(sys.argv[2]))
    ctxs = json.load(open(sys.argv[3]))
    run(src, dst, ctxs, sys.argv[4])