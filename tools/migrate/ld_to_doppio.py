import json, sys

def convert(ld_flags):
    out = []
    report = {"migrated": [], "skipped": [], "warnings": []}
    for f in ld_flags:
        key = f.get("key")
        if f.get("kind") != "boolean":
            report["skipped"].append({"key": key, "reason": "non-boolean kind"})
            continue
        variations = f.get("variations", [])
        rules = []
        for r in f.get("rules", []):
            rules.append({"id": r.get("_id"), "expression": "true", "variation": 0})
        rollout = 100
        if f.get("rollout", {}).get("variations"):
            rollout = f["rollout"]["variations"][0].get("weight", 100000) // 1000
        doppio_flag = {
            "key": key,
            "enabled": f.get("on", True),
            "rolloutPercentage": rollout,
            "variations": [{"key": v.get("name", str(i)), "value": str(v.get("value"))} for i, v in enumerate(variations)] or [{"key": "on", "value": "true"}, {"key": "off", "value": "false"}],
            "defaultVariation": 0,
            "rules": rules,
        }
        out.append(doppio_flag)
        report["migrated"].append(key)
        if variations:
            report["warnings"].append({"key": key, "note": "rollout bucketing differs (murmur3 vs xxh32); membership will change"})
    return out, report

if __name__ == "__main__":
    ld = json.load(open(sys.argv[1]))
    flags = ld if isinstance(ld, list) else ld.get("items", [])
    out, report = convert(flags)
    json.dump(out, open(sys.argv[2], "w"), indent=2)
    json.dump(report, open(sys.argv[3], "w"), indent=2)
    print("migrated", len(report["migrated"]), "skipped", len(report["skipped"]))