import json, sys

def convert(features):
    out, report = [], {"clean": [], "deviation": [], "manual": []}
    for f in features:
        key = f.get("id")
        # JSONLogic conditions are inexpressible in Doppio rules
        report["manual"].append({"key": key, "reasons": [{"field": "conditions", "reason": "JSONLogic not supported; manual translation needed", "severity": "manual"}]})
        continue
    return out, report

if __name__ == "__main__":
    data = json.load(open(sys.argv[1]))
    features = data if isinstance(data, list) else data.get("features", [])
    out, report = convert(features)
    json.dump(out, open(sys.argv[2], "w"), indent=2)
    json.dump({k: v for k, v in report.items()}, open(sys.argv[3], "w"), indent=2)
    print("growthbook migrated", len(out))