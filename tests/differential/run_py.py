import json, sys
sys.path.insert(0, "packages/py/src")
from doppio import Doppio

fixture = json.load(open(sys.argv[1]))
doppio = Doppio.init({"flags": fixture["flags"]})
out = []
for ctx in fixture["contexts"]:
    for f in fixture["flags"]:
        r = doppio.get(f["key"], ctx)
        out.append({"flag": f["key"], "ctx": ctx["targetingKey"], "value": r.value, "reason": r.reason})
print(json.dumps(out))