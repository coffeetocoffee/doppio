import json, sys

def classify(flag):
    deviations = []
    manual = []
    # non-boolean kind
    if flag.get("kind") != "boolean":
        return "manual", [{"field": "kind", "reason": "non-boolean kind not supported", "severity": "manual"}]
    # rules with complex targeting
    for r in flag.get("rules", []):
        if r.get("clauses"):
            deviations.append({"field": "rules", "reason": "clauses simplified to 'true'; review targeting", "severity": "deviation"})
    # rollout
    if flag.get("rollout", {}).get("variations"):
        deviations.append({"field": "rolloutPercentage", "reason": "LD murmur3 vs Doppio xxh32; membership changes", "severity": "deviation"})
    # prerequisites not supported
    if flag.get("prerequisites"):
        manual.append({"field": "prerequisites", "reason": "prerequisites not yet supported", "severity": "manual"})
    if manual:
        return "manual", manual + deviations
    if deviations:
        return "deviation", deviations
    return "clean", []

def convert(ld_flags):
    out = []
    report = {"clean": [], "deviation": [], "manual": []}
    for f in ld_flags:
        key = f.get("key")
        status, reasons = classify(f)
        report[status].append({"key": key, "reasons": reasons})
        if status == "manual":
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
    # markdown summary
    md = ["# Migration Loss Report", ""]
    for bucket in ("clean", "deviation", "manual"):
        md.append(f"## {bucket} ({len(report[bucket])})")
        for item in report[bucket]:
            md.append(f"- **{item['key']}**")
            for r in item["reasons"]:
                md.append(f"  - [{r['severity']}] {r['field']}: {r['reason']}")
        md.append("")
    report["markdown"] = "\n".join(md)
    return out, report

if __name__ == "__main__":
    ld = json.load(open(sys.argv[1]))
    flags = ld if isinstance(ld, list) else ld.get("items", [])
    out, report = convert(flags)
    json.dump(out, open(sys.argv[2], "w"), indent=2)
    json.dump({k: v for k, v in report.items() if k != "markdown"}, open(sys.argv[3], "w"), indent=2)
    if len(sys.argv) > 4:
        with open(sys.argv[4], "w") as fh:
            fh.write(report["markdown"])
    print("clean", len(report["clean"]), "deviation", len(report["deviation"]), "manual", len(report["manual"]))