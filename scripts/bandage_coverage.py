#!/usr/bin/env python3
import csv
import sys
from pathlib import Path

def coverage_to_color(cov: float, max_cov_pos: float) -> str:
    """Map coverage to colors:
       0        -> dark gray (almost black)
       >0..max -> dark red -> bright yellow
    """
    # Zero coverage: special dark color
    if cov <= 0:
        return "#202020"   # dark gray

    # Normalize positive coverage to [0, 1]
    x = cov / max_cov_pos if max_cov_pos > 0 else 1.0
    x = max(0.0, min(1.0, x))

    # Enforce a minimum "intensity" so the smallest non-zero cov isn't too dark
    # We'll remap x from [0,1] into [0.3, 1.0]
    x = 0.3 + 0.7 * x

    # Gradient: dark red (#800000) -> yellow (#ffff00)
    # Red channel: 128 -> 255
    r = int(128 + (255 - 128) * x)
    # Green channel: 0 -> 255
    g = int(255 * x)
    # Blue channel: 0 (stay in red/yellow space)
    b = 0

    return f"#{r:02x}{g:02x}{b:02x}"

def main():
    if len(sys.argv) < 2 or len(sys.argv) > 3:
        print(f"Usage: {sys.argv[0]} <gafpack_coverage.csv> [bandage_coverage.csv]", file=sys.stderr)
        sys.exit(1)

    in_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2]) if len(sys.argv) == 3 else in_path.with_suffix(".bandage.csv")

    rows = []
    with in_path.open() as f:
        reader = csv.DictReader(f)
        for r in reader:
            rows.append(r)

    # Expect columns: node_id,node_coverage
    # Compute max over *positive* coverage only
    positive_covs = [float(r["node_coverage"]) for r in rows if float(r["node_coverage"]) > 0]
    max_cov_pos = max(positive_covs) if positive_covs else 0.0

    with out_path.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["Name", "Coverage", "Colour"])
        for r in rows:
            cov = float(r["node_coverage"])
            color = coverage_to_color(cov, max_cov_pos)
            writer.writerow([r["node_id"], cov, color])

    print(f"Wrote Bandage CSV to {out_path}")

if __name__ == "__main__":
    main()
