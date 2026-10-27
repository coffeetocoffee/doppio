import json, random, sys

def gen(seed=42, nflags=5, ncontexts=8):
    rng = random.Random(seed)
    flags = []
    for i in range(nflags):
        flags.append({
            "key": f"flag-{i}",
            "enabled": rng.choice([True, False]),
            "rolloutPercentage": rng.choice([0, 25, 50, 100]),
        })
    contexts = []
    for i in range(ncontexts):
        contexts.append({"targetingKey": f"user-{rng.randint(1, 20)}"})
    return {"seed": seed, "flags": flags, "contexts": contexts}

if __name__ == "__main__":
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 42
    out = sys.argv[2] if len(sys.argv) > 2 else "fixture.json"
    with open(out, "w") as f:
        json.dump(gen(seed), f, indent=2)
    print(out)