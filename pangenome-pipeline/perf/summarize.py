#!/usr/bin/env python3
"""Aggregate per-trial perf data into mean +/- stdev tables.

Usage: summarize.py <perf-tag-dir>
e.g.:  summarize.py perf/yeast235-chrII
"""
import sys
import re
import statistics
from pathlib import Path

# Regexes for parsing find_mems.log phase breakdown
LOG_PATTERNS = {
    "rindex_load_s":       r"R-index loading: ([\d.]+) s",
    "tag_load_s":          r"Tag index loading: ([\d.]+) s",
    "read_proc_s":         r"Read processing: ([\d.]+) s",
    "sorting_s":           r"Sorting: ([\d.]+) s",
    "total_s":             r"Total execution time: ([\d.]+) seconds",
    "mem_finding_s":       r"MEM finding: ([\d.]+) s",
    "mem_processing_s":    r"MEM processing: ([\d.]+) s",
    "tag_query_s":         r"Tag queries: ([\d.]+) s",
    "locate_s":            r"Locate operations: ([\d.]+) s",
    "locate_first_s":      r"First locate: ([\d.]+) s",
    "locate_next_s":       r"Locate next: ([\d.]+) s",
    "peak_mem_mb":         r"Peak memory usage: ([\d.]+) MB",
}

# Regex for gtime rusage
RUSAGE_PATTERNS = {
    "wall_s":              r"Elapsed \(wall clock\) time \(h:mm:ss or m:ss\): (.+)",
    "user_s":              r"User time \(seconds\): ([\d.]+)",
    "sys_s":               r"System time \(seconds\): ([\d.]+)",
    "maxrss_kb":           r"Maximum resident set size \(kbytes\): (\d+)",
    "minor_faults":        r"Minor \(reclaiming a frame\) page faults: (\d+)",
    "major_faults":        r"Major \(requiring I/O\) page faults: (\d+)",
    "voluntary_csw":       r"Voluntary context switches: (\d+)",
    "involuntary_csw":     r"Involuntary context switches: (\d+)",
}

# gafpack stderr
GAFPACK_PATTERNS = {
    "records_loaded":      r"Loaded (\d+) path_pos records",
    "bytes_loaded":        r"Loaded \d+ path_pos records \((\d+) bytes",
    "total_gaf_entries":   r"Total GAF entries: (\d+)",
    "path_scan_total":     r"Path-scan passes: total=(\d+)",
    "path_scan_seq_ids":   r"over (\d+) seq_ids",
    "path_scan_mean":      r"mean=([\d.]+)",
    "path_scan_max":       r"max=(\d+)",
    "step_visits":         r"step-visits.~?(\d+)",
}


def parse_wall(s):
    """gtime '0:23.72' or '1:23:45.6' -> seconds float."""
    parts = s.strip().split(":")
    if len(parts) == 2:
        return float(parts[0]) * 60 + float(parts[1])
    elif len(parts) == 3:
        return float(parts[0]) * 3600 + float(parts[1]) * 60 + float(parts[2])
    return float(s)


def extract_patterns(text, patterns):
    out = {}
    for key, pat in patterns.items():
        m = re.search(pat, text)
        if m:
            v = m.group(1).strip()
            if key == "wall_s":
                out[key] = parse_wall(v)
                continue
            # Try int -> float -> str
            try:
                out[key] = int(v)
            except ValueError:
                try:
                    out[key] = float(v)
                except ValueError:
                    out[key] = v
    return out


def collect_trials(fmt_dir):
    """Return list of dicts, one per trial-N dir."""
    trials = []
    for tdir in sorted(fmt_dir.glob("trial-*")):
        rec = {"trial": tdir.name}
        # find_mems.log: phase breakdown
        log = (tdir / "find_mems.log").read_text(errors="ignore")
        rec.update({f"fm_{k}": v for k, v in extract_patterns(log, LOG_PATTERNS).items()})
        # find_mems.time: rusage
        t = (tdir / "find_mems.time").read_text(errors="ignore")
        rec.update({f"fm_{k}": v for k, v in extract_patterns(t, RUSAGE_PATTERNS).items()})
        # gafpack.stderr
        gs = (tdir / "gafpack.stderr").read_text(errors="ignore")
        rec.update({f"gp_{k}": v for k, v in extract_patterns(gs, GAFPACK_PATTERNS).items()})
        # gafpack.time
        t = (tdir / "gafpack.time").read_text(errors="ignore")
        rec.update({f"gp_{k}": v for k, v in extract_patterns(t, RUSAGE_PATTERNS).items()})
        # sizes.txt
        sz = (tdir / "sizes.txt").read_text(errors="ignore")
        for ext, key in [(".bin", "bin_bytes"), (".gaf", "gaf_bytes"),
                         ("_coverage.csv", "cov_bytes"),
                         ("_seq_id_starts.out", "starts_bytes")]:
            m = re.search(rf"\S*{re.escape(ext)}\s+(\d+) bytes", sz)
            if m:
                rec[key] = int(m.group(1))
        trials.append(rec)
    return trials


def stat_row(values, label, fmt="{:.2f}"):
    """Render mean +- stdev (with min/max for n>=2) and optional label prefix.
    Pass label='' to skip the leading label and colon entirely."""
    prefix = f"{label}: " if label else ""
    if not values:
        return prefix + "(no data)"
    n = len(values)
    if n == 1:
        return prefix + fmt.format(values[0]) + f"  (n=1)"
    mean = statistics.mean(values)
    sdev = statistics.stdev(values) if n > 1 else 0.0
    lo, hi = min(values), max(values)
    return (prefix + fmt.format(mean) + " +- " + fmt.format(sdev) +
            f"  [min " + fmt.format(lo) + ", max " + fmt.format(hi) + f"]  (n={n})")


def relpct(v2, v1):
    if v1 == 0:
        return "n/a"
    return f"{((v2 - v1) / v1) * 100:+.1f}%"


def cmp_table(label, key, v1_trials, v2_trials, unit="", fmt="{:.2f}"):
    v1 = [t[key] for t in v1_trials if key in t]
    v2 = [t[key] for t in v2_trials if key in t]
    if not v1 or not v2:
        return None
    v1_mean = statistics.mean(v1)
    v2_mean = statistics.mean(v2)
    v1_sd = statistics.stdev(v1) if len(v1) > 1 else 0.0
    v2_sd = statistics.stdev(v2) if len(v2) > 1 else 0.0
    return (label,
            fmt.format(v1_mean) + " +- " + fmt.format(v1_sd) + unit,
            fmt.format(v2_mean) + " +- " + fmt.format(v2_sd) + unit,
            relpct(v2_mean, v1_mean))


def fmt_int(n):
    return f"{n:>15,}" if isinstance(n, int) else str(n)


def single_format_report(trials, label, base):
    """Concise per-format summary when there's no v1 vs v2 comparison to do."""
    N = len(trials)
    print("=" * 78)
    print(f"  PERFORMANCE PROFILE  ({label}, N={N} timed trials, warm cache)")
    print(f"  Source: {base}")
    print("=" * 78)
    print()
    print("STEP 09 - find_mems")
    print("-" * 78)
    for key, lab, unit, fmt in [
        ("fm_wall_s",         "wall",            " s",   "{:6.2f}"),
        ("fm_user_s",         "  user",          " s",   "{:6.2f}"),
        ("fm_sys_s",          "  sys",           " s",   "{:6.2f}"),
        ("fm_maxrss_kb",      "peak RSS",        " KB",  "{:>8.0f}"),
        ("fm_peak_mem_mb",    "peak (reported)", " MB",  "{:7.1f}"),
        ("fm_minor_faults",   "minor faults",    "",     "{:>10.0f}"),
        ("fm_major_faults",   "major faults",    "",     "{:>4.0f}"),
    ]:
        vals = [t[key] for t in trials if key in t]
        print(f"  {lab:<22}  {stat_row(vals, '', fmt)}{unit}")
    print()
    print("STEP 09 - find_mems  PHASE BREAKDOWN")
    print("-" * 78)
    for key, lab, fmt in [
        ("fm_total_s",          "Total exec",          "{:6.2f}"),
        ("fm_rindex_load_s",    "  R-index load",      "{:6.3f}"),
        ("fm_tag_load_s",       "  Tag-index load",    "{:6.3f}"),
        ("fm_read_proc_s",      "  Read processing",   "{:6.2f}"),
        ("fm_mem_finding_s",    "    MEM finding",     "{:6.2f}"),
        ("fm_mem_processing_s", "    MEM processing",  "{:6.2f}"),
        ("fm_tag_query_s",      "      Tag queries",   "{:6.3f}"),
        ("fm_locate_s",         "      Locate ops",    "{:6.2f}"),
        ("fm_sorting_s",        "  Bucket sort+write", "{:6.3f}"),
    ]:
        vals = [t[key] for t in trials if key in t]
        print(f"  {lab:<22}  {stat_row(vals, '', fmt)} s")
    print()
    print("STEP 10 - gafpack")
    print("-" * 78)
    for key, lab, unit, fmt in [
        ("gp_wall_s",       "wall",       " s",  "{:6.2f}"),
        ("gp_user_s",       "  user",     " s",  "{:6.2f}"),
        ("gp_sys_s",        "  sys",      " s",  "{:6.2f}"),
        ("gp_maxrss_kb",    "peak RSS",   " KB", "{:>8.0f}"),
        ("gp_minor_faults", "minor faults","",   "{:>10.0f}"),
    ]:
        vals = [t[key] for t in trials if key in t]
        print(f"  {lab:<22}  {stat_row(vals, '', fmt)}{unit}")
    print()
    print("OUTPUT ARTIFACTS")
    print("-" * 78)
    t0 = trials[0]
    for key, lab in [("bin_bytes", "_path_pos*.bin"), ("gaf_bytes", ".gaf"),
                     ("cov_bytes", "_coverage.csv"), ("starts_bytes", "_seq_id_starts.out")]:
        if key in t0:
            print(f"  {lab:<22}  {t0[key]:>17,} bytes")
    print()
    sums = [t["fm_wall_s"] + t["gp_wall_s"] for t in trials
            if "fm_wall_s" in t and "gp_wall_s" in t]
    if sums:
        print("STEPS 09 + 10 COMBINED WALL")
        print("-" * 78)
        m = statistics.mean(sums); sd = statistics.stdev(sums) if len(sums)>1 else 0
        print(f"  {m:.2f} +- {sd:.2f} s")
    print()
    print("=" * 78)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    base = Path(sys.argv[1])
    v1_dir, v2_dir = base / "v1", base / "v2"
    v1_trials = collect_trials(v1_dir) if v1_dir.is_dir() else []
    v2_trials = collect_trials(v2_dir) if v2_dir.is_dir() else []

    if not v1_trials and not v2_trials:
        print(f"No trial data found under {base}/{{v1,v2}}/trial-*", file=sys.stderr)
        sys.exit(1)
    if not v1_trials:
        single_format_report(v2_trials, "v2", base); return
    if not v2_trials:
        single_format_report(v1_trials, "v1", base); return

    assert len(v1_trials) == len(v2_trials), \
        f"trial count mismatch: v1={len(v1_trials)} v2={len(v2_trials)}"
    N = len(v1_trials)

    print("=" * 78)
    print(f"  PERFORMANCE COMPARISON  v1 vs v2   (N={N} timed trials, warm cache)")
    print(f"  Source: {base}")
    print("=" * 78)
    print()

    # ---- Step 09: find_mems ------------------------------------------------
    print("STEP 09 - find_mems")
    print("-" * 78)
    rows = [
        cmp_table("wall (rusage)",    "fm_wall_s",         v1_trials, v2_trials, " s", "{:6.2f}"),
        cmp_table("  user",           "fm_user_s",         v1_trials, v2_trials, " s", "{:6.2f}"),
        cmp_table("  sys",            "fm_sys_s",          v1_trials, v2_trials, " s", "{:6.2f}"),
        cmp_table("peak RSS",         "fm_maxrss_kb",      v1_trials, v2_trials, " KB", "{:>8.0f}"),
        cmp_table("peak (reported)",  "fm_peak_mem_mb",    v1_trials, v2_trials, " MB", "{:7.1f}"),
        cmp_table("minor faults",     "fm_minor_faults",   v1_trials, v2_trials, "",   "{:>10.0f}"),
        cmp_table("major faults",     "fm_major_faults",   v1_trials, v2_trials, "",   "{:>4.0f}"),
        cmp_table("vol ctx switches", "fm_voluntary_csw",  v1_trials, v2_trials, "",   "{:>6.0f}"),
        cmp_table("invol ctx switches", "fm_involuntary_csw", v1_trials, v2_trials, "", "{:>6.0f}"),
    ]
    print(f"  {'metric':<22}  {'v1':<22}  {'v2':<22}  {'delta':>8}")
    for r in rows:
        if r: print(f"  {r[0]:<22}  {r[1]:<22}  {r[2]:<22}  {r[3]:>8}")

    print()
    print("STEP 09 - find_mems  PHASE BREAKDOWN (internal --time stats)")
    print("-" * 78)
    rows = [
        cmp_table("Total exec",          "fm_total_s",          v1_trials, v2_trials, " s", "{:6.2f}"),
        cmp_table("  R-index load",      "fm_rindex_load_s",    v1_trials, v2_trials, " s", "{:6.3f}"),
        cmp_table("  Tag-index load",    "fm_tag_load_s",       v1_trials, v2_trials, " s", "{:6.3f}"),
        cmp_table("  Read processing",   "fm_read_proc_s",      v1_trials, v2_trials, " s", "{:6.2f}"),
        cmp_table("    MEM finding",     "fm_mem_finding_s",    v1_trials, v2_trials, " s", "{:6.2f}"),
        cmp_table("    MEM processing",  "fm_mem_processing_s", v1_trials, v2_trials, " s", "{:6.2f}"),
        cmp_table("      Tag queries",   "fm_tag_query_s",      v1_trials, v2_trials, " s", "{:6.3f}"),
        cmp_table("      Locate ops",    "fm_locate_s",         v1_trials, v2_trials, " s", "{:6.2f}"),
        cmp_table("        First locate","fm_locate_first_s",   v1_trials, v2_trials, " s", "{:6.2f}"),
        cmp_table("        Locate next", "fm_locate_next_s",    v1_trials, v2_trials, " s", "{:6.2f}"),
        cmp_table("  Bucket sort+write", "fm_sorting_s",        v1_trials, v2_trials, " s", "{:6.3f}"),
    ]
    print(f"  {'phase':<22}  {'v1':<22}  {'v2':<22}  {'delta':>8}")
    for r in rows:
        if r: print(f"  {r[0]:<22}  {r[1]:<22}  {r[2]:<22}  {r[3]:>8}")

    # ---- Step 10: gafpack --------------------------------------------------
    print()
    print("STEP 10 - gafpack")
    print("-" * 78)
    rows = [
        cmp_table("wall",             "gp_wall_s",         v1_trials, v2_trials, " s", "{:6.2f}"),
        cmp_table("  user",           "gp_user_s",         v1_trials, v2_trials, " s", "{:6.2f}"),
        cmp_table("  sys",            "gp_sys_s",          v1_trials, v2_trials, " s", "{:6.2f}"),
        cmp_table("peak RSS",         "gp_maxrss_kb",      v1_trials, v2_trials, " KB", "{:>8.0f}"),
        cmp_table("minor faults",     "gp_minor_faults",   v1_trials, v2_trials, "",   "{:>10.0f}"),
        cmp_table("major faults",     "gp_major_faults",   v1_trials, v2_trials, "",   "{:>4.0f}"),
        cmp_table("vol ctx switches", "gp_voluntary_csw",  v1_trials, v2_trials, "",   "{:>6.0f}"),
        cmp_table("invol ctx switches","gp_involuntary_csw",v1_trials, v2_trials, "",   "{:>6.0f}"),
    ]
    print(f"  {'metric':<22}  {'v1':<22}  {'v2':<22}  {'delta':>8}")
    for r in rows:
        if r: print(f"  {r[0]:<22}  {r[1]:<22}  {r[2]:<22}  {r[3]:>8}")

    print()
    print("STEP 10 - gafpack  PATH-SCAN STATS (stderr)")
    print("-" * 78)
    rows = [
        cmp_table("records loaded",     "gp_records_loaded",   v1_trials, v2_trials, "",   "{:>15,.0f}"),
        cmp_table("bytes loaded",       "gp_bytes_loaded",     v1_trials, v2_trials, " B", "{:>15,.0f}"),
        cmp_table("total GAF entries",  "gp_total_gaf_entries",v1_trials, v2_trials, "",   "{:>15,.0f}"),
        cmp_table("seq_ids visited",    "gp_path_scan_seq_ids",v1_trials, v2_trials, "",   "{:>6.0f}"),
        cmp_table("mean passes/path",   "gp_path_scan_mean",   v1_trials, v2_trials, "",   "{:5.2f}"),
        cmp_table("step-visits",        "gp_step_visits",      v1_trials, v2_trials, "",   "{:>15,.0f}"),
    ]
    print(f"  {'metric':<22}  {'v1':<22}  {'v2':<22}  {'delta':>8}")
    for r in rows:
        if r: print(f"  {r[0]:<22}  {r[1]:<22}  {r[2]:<22}  {r[3]:>8}")

    # ---- Output artifacts --------------------------------------------------
    print()
    print("OUTPUT ARTIFACTS  (deterministic; same across trials of same format)")
    print("-" * 78)
    v1t = v1_trials[0]; v2t = v2_trials[0]
    artifacts = [
        ("_path_pos*.bin",     "bin_bytes"),
        (".gaf",               "gaf_bytes"),
        ("_coverage.csv",      "cov_bytes"),
        ("_seq_id_starts.out", "starts_bytes"),
    ]
    print(f"  {'artifact':<22}  {'v1':>17}  {'v2':>17}  {'delta':>8}")
    for label, key in artifacts:
        if key in v1t and key in v2t:
            v1v, v2v = v1t[key], v2t[key]
            delta = relpct(v2v, v1v)
            print(f"  {label:<22}  {v1v:>17,}  {v2v:>17,}  {delta:>8}")

    # Combined 09+10 wall
    print()
    print("STEPS 09 + 10 COMBINED WALL")
    print("-" * 78)
    sums_v1 = [t["fm_wall_s"] + t["gp_wall_s"] for t in v1_trials if "fm_wall_s" in t and "gp_wall_s" in t]
    sums_v2 = [t["fm_wall_s"] + t["gp_wall_s"] for t in v2_trials if "fm_wall_s" in t and "gp_wall_s" in t]
    if sums_v1 and sums_v2:
        v1m = statistics.mean(sums_v1); v1sd = statistics.stdev(sums_v1) if len(sums_v1)>1 else 0
        v2m = statistics.mean(sums_v2); v2sd = statistics.stdev(sums_v2) if len(sums_v2)>1 else 0
        print(f"  v1: {v1m:5.2f} +- {v1sd:4.2f} s")
        print(f"  v2: {v2m:5.2f} +- {v2sd:4.2f} s")
        print(f"  delta: {relpct(v2m, v1m)}")

    print()
    print("=" * 78)


if __name__ == "__main__":
    main()
