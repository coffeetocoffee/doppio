"""Export exposures to Parquet or CSV."""
import sys, json

def export(fmt, rows, out):
    if fmt == "csv":
        import csv
        with open(out, "w", newline="") as f:
            w = csv.writer(f)
            if rows:
                w.writerow(rows[0].keys())
                for r in rows:
                    w.writerow(r.values())
    elif fmt == "parquet":
        # placeholder: write JSON lines
        with open(out, "w") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
    print(f"exported {len(rows)} rows to {out} ({fmt})")

if __name__ == "__main__":
    export(sys.argv[1], json.load(open(sys.argv[2])), sys.argv[3])