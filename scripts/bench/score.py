"""Scores Apple Loops benchmark results (from scripts/bench-apple-loops.sh).

    python3 scripts/bench/score.py results.tsv [baseline.tsv]

Loops labelled major or minor are scored on the exact key and on the MIREX
weighted score (mir_eval's definition: 1 exact, 0.5 a fifth above, 0.3
relative, 0.2 parallel). Loops labelled "both" (the riff fits major and
minor) are scored on the tonic only. With a baseline, the change is paired
loop by loop.
"""

import csv
import statistics
import sys

NOTES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
MODES = ["Bass", "Guitar", "Full Mix", "Auto"]
BANDS = [("High", 0.6, 9.0), ("Medium", 0.3, 0.6), ("Low", -1.0, 0.3)]
CATEGORIES = ["Bass", "Guitars", "Keyboards", "Mixed"]


def load(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    for r in rows:
        r["label"] = (NOTES.index(r["tonic"]), r["type"] == "minor")
        for m in MODES:
            est = r[m]
            r[m] = None if est == "-" else (NOTES.index(est.split(":")[0]), est.endswith(":min"))
            r[m + " conf"] = float(r[m + " conf"])
    return {r["path"]: r for r in rows}


def mirex(est, ref):
    if est is None:
        return 0.0
    d = (est[0] - ref[0]) % 12
    if est[1] == ref[1]:
        return {0: 1.0, 7: 0.5}.get(d, 0.0)
    if (not ref[1] and d == 9) or (ref[1] and d == 3):
        return 0.3
    return 0.2 if d == 0 else 0.0


def exact(r, m):
    return r[m] == r["label"]


def tonic_ok(r, m):
    return r[m] is not None and r[m][0] == r["label"][0]


def pct(hits, n):
    return f"{100 * hits / n:5.1f}%" if n else "    -"


def report(rows):
    mm = [r for r in rows.values() if r["type"] != "both"]
    both = [r for r in rows.values() if r["type"] == "both"]
    secs = statistics.median(float(r["seconds"]) for r in rows.values())
    print(f"{len(mm)} major/minor loops, {len(both)} 'both' loops, median length {secs:.1f} s\n")

    print(f"{'':10}{'exact':>8}{'MIREX':>8}{'tonic':>8}{'both':>8}   High / Medium / Low confidence: share of loops, exact")
    for m in MODES:
        cells = [pct(sum(exact(r, m) for r in mm), len(mm)), f"{statistics.mean(mirex(r[m], r['label']) for r in mm):8.3f}",
                 pct(sum(tonic_ok(r, m) for r in mm), len(mm)), pct(sum(tonic_ok(r, m) for r in both), len(both))]
        bands = []
        for _, lo, hi in BANDS:
            sel = [r for r in mm if lo <= r[m + " conf"] < hi]
            bands.append(f"{pct(len(sel), len(mm))} {pct(sum(exact(r, m) for r in sel), len(sel))}")
        print(f"{m:10}" + "".join(f"{c:>8}" for c in cells) + "   " + " / ".join(bands))

    print("\nExact by category (major/minor loops)")
    groups = [(c, [r for r in mm if r["category"] == c]) for c in CATEGORIES]
    groups.append(("Other", [r for r in mm if r["category"] not in CATEGORIES]))
    print(f"{'':10}" + "".join(f"{c + f' ({len(g)})':>16}" for c, g in groups))
    for m in MODES:
        print(f"{m:10}" + "".join(f"{pct(sum(exact(r, m) for r in g), len(g)):>16}" for _, g in groups))

    print("\nDetected tonic minus labelled tonic (semitones), % of major/minor loops; 0 in the same mode is exact")
    print(f"{'':20}" + "".join(f"{d:+5d}" for d in range(-5, 7)))
    for m in MODES:
        for flipped in (False, True):
            counts = [0] * 12
            for r in mm:
                if r[m] is not None and (r[m][1] != r["label"][1]) == flipped:
                    counts[(r[m][0] - r["label"][0]) % 12] += 1
            name = "mode flipped" if flipped else "same mode"
            print(f"{'' if flipped else m:9}{name:11}" + "".join(f"{100 * counts[d % 12] / len(mm):5.1f}" for d in range(-5, 7)))


def compare(rows, base):
    common = [p for p in rows if p in base and rows[p]["type"] != "both"]
    print(f"\nChange against baseline, paired over {len(common)} major/minor loops")
    print(f"{'':10}{'exact':>16}{'MIREX':>16}{'fixed':>7}{'broke':>7}{'z':>6}")
    for m in MODES:
        a = [exact(base[p], m) for p in common]
        b = [exact(rows[p], m) for p in common]
        fixed = sum(y and not x for x, y in zip(a, b))
        broke = sum(x and not y for x, y in zip(a, b))
        z = (fixed - broke) / (fixed + broke) ** 0.5 if fixed + broke else 0.0
        ma = statistics.mean(mirex(base[p][m], base[p]["label"]) for p in common)
        mb = statistics.mean(mirex(rows[p][m], rows[p]["label"]) for p in common)
        print(f"{m:10}{pct(sum(a), len(a)):>7} → {pct(sum(b), len(b))}{ma:7.3f} → {mb:.3f}{fixed:7d}{broke:7d}{z:6.1f}")
    print("(z is McNemar's statistic: |z| < 2 is within noise)")


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    results = load(sys.argv[1])
    report(results)
    if len(sys.argv) == 3:
        compare(results, load(sys.argv[2]))
