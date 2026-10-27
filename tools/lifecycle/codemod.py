"""Codemod: remove dead flag branches for flags at 100% for >30 days."""
import re, sys, json

def find_dead_flags(flags_json):
    return [f["key"] for f in flags_json if f.get("rolloutPercentage", 0) == 100]

def remove_branches(source, flag_key):
    # Remove if (flag) { ... } blocks referencing the flag (simplified regex)
    pattern = re.compile(rf'if\s*\(\s*{re.escape(flag_key)}\s*\)\s*\{{[^}}]*\}}', re.S)
    return pattern.sub('', source)

if __name__ == "__main__":
    flags = json.load(open(sys.argv[1]))
    src_path = sys.argv[2]
    src = open(src_path).read()
    dead = find_dead_flags(flags)
    for key in dead:
        src = remove_branches(src, key)
    if len(sys.argv) > 3:
        open(sys.argv[3], "w").write(src)
    else:
        print(src)