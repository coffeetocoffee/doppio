import json, subprocess, sys, os

base = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(os.path.dirname(base))
fixture = os.path.join(base, "fixture.json")
subprocess.run([sys.executable, os.path.join(base, "gen.py"), "42", fixture], check=True)

def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=root)
    if r.returncode != 0:
        print("ERR", cmd, r.stderr); sys.exit(1)
    return json.loads(r.stdout)

js = run(["node", os.path.join(base, "run_js.js"), fixture])
py = run([sys.executable, os.path.join(base, "run_py.py"), fixture])
# go requires module context; skip if not built
print("JS rows:", len(js), "PY rows:", len(py))
if js != py:
    print("MISMATCH JS vs PY")
    print(json.dumps(js, indent=2))
    print(json.dumps(py, indent=2))
    sys.exit(1)
print("OK: JS == PY")