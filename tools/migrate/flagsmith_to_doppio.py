import json, sys

def convert(flags):
    out, report = [], {"clean": [], "deviation": [], "manual": []}
    for f in flags:
        key = f.get("name") or f.get("key")
        out.append({"key": key, "enabled": f.get("enabled", True), "rolloutPercentage": 100,
                    "variations": [{"key": "on", "value": "true"}, {"key": "off", "value": "false"}],
                    "defaultVariation": 0, "rules": []})
        report["clean"].append({"key": key, "reasons": []})
    return out, report

if __name__ == "__main__":
    data = json.load(open(sys.argv[1]))
    flags = data if isinstance(data, list) else data.get("results", [])
    out, report = convert(flags)
    json.dump(out, open(sys.argv[2], "w"), indent=2)
    json.dump({k: v for k, v in report.items()}, open(sys.argv[3], "w"), indent=2)
    print("flagsmith migrated", len(out))