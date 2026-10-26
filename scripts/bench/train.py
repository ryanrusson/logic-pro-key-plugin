"""Fits KeyFinder's key model to Apple Loops benchmark results.

    python3 scripts/bench/train.py results.tsv

Reads the per-mode chroma and tonality that scripts/bench-apple-loops.sh
records, then:
1. scores a two-fold cross-validation (fitted on one half of the loops,
   scored on the other), the accuracy to expect on unseen material, and
2. prints the model fitted on all loops, as Rust for core/src/key.rs.
Rerun it whenever the DSP (and so the chroma) changes.

The model mirrors key::estimate: a key's log-likelihood is the chroma
(normalised to sum 1) dotted with the log of its profile, a pitch-class
distribution learned as the mean chroma of loops in that key (rotated to C).
A softmax with a fitted temperature turns the 24 log-likelihoods into a
posterior, and Platt scaling maps the winner's posterior to the chance it is
right. Auto averages the posteriors of the three modes.
"""

import math
import os
import statistics
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score import BANDS, MODES, load, mirex  # noqa: E402

SOURCES = MODES[:3]
EPS = 0.005  # floor for pitch classes a key never uses


def chroma(r, m):
    c = [float(x) for x in r[m + " chroma"].split(",")]
    s = sum(c)
    return [x / s for x in c] if s > 0 else None


def gate(r, m):
    return min(max((float(r[m + " tonality"]) - 0.10) / 0.15, 0.0), 1.0)


def label_index(r):
    return r["label"][0] + (12 if r["label"][1] else 0)


def fit_profiles(rows, m):
    sums = {False: [0.0] * 12, True: [0.0] * 12}
    for r in rows:
        c = chroma(r, m)
        if c is not None:
            tonic, minor = r["label"]
            for i in range(12):
                sums[minor][i] += c[(i + tonic) % 12]
    profiles = {}
    for minor, s in sums.items():
        total = sum(s)
        p = [x / total + EPS for x in s]
        profiles[minor] = [x / sum(p) for x in p]
    return profiles


def log_likelihoods(c, profiles):
    logs = {minor: [math.log(x) for x in p] for minor, p in profiles.items()}
    return [sum(c[(i + k) % 12] * logs[k >= 12][i] for i in range(12)) for k in range(24)]


def softmax(scores, temperature):
    top = max(scores)
    e = [math.exp(temperature * (s - top)) for s in scores]
    z = sum(e)
    return [x / z for x in e]


def fit_temperature(pairs):
    # Maximum likelihood of the labelled key, on a log-spaced grid.
    grid = [2 ** (x / 16) for x in range(0, 160)]
    return max(grid, key=lambda t: sum(math.log(max(softmax(s, t)[y], 1e-12)) for s, y in pairs))


def logit(p):
    p = min(max(p, 1e-4), 1 - 1e-4)
    return math.log(p / (1 - p))


def fit_platt(pairs):
    # Logistic regression of "the winner is right" on logit(posterior), by Newton's method.
    a, b = 1.0, 0.0
    for _ in range(50):
        ga = gb = haa = hab = hbb = 0.0
        for p, ok in pairs:
            x = logit(p)
            q = 1 / (1 + math.exp(-(a * x + b)))
            ga += (q - ok) * x
            gb += q - ok
            w = q * (1 - q)
            haa += w * x * x
            hab += w * x
            hbb += w
        det = haa * hbb - hab * hab
        a -= (hbb * ga - hab * gb) / det
        b -= (haa * gb - hab * ga) / det
    return a, b


def platt(cal, p):
    return 1 / (1 + math.exp(-(cal[0] * logit(p) + cal[1])))


def fit(rows):
    model = {}
    for m in SOURCES:
        profiles = fit_profiles(rows, m)
        pairs = [(log_likelihoods(c, profiles), label_index(r)) for r in rows if (c := chroma(r, m))]
        model[m] = {"profiles": profiles, "temperature": fit_temperature(pairs)}
    for m in SOURCES:
        pairs = []
        for r in rows:
            post = posterior(model, r, m)
            if post:
                pairs.append((max(post), post.index(max(post)) == label_index(r)))
        model[m]["calibration"] = fit_platt(pairs)
    pairs = []
    for r in rows:
        post, _ = auto_posterior(model, r)
        if post:
            pairs.append((max(post), post.index(max(post)) == label_index(r)))
    model["Auto"] = {"calibration": fit_platt(pairs)}
    return model


def posterior(model, r, m):
    c = chroma(r, m)
    if c is None:
        return None
    return softmax(log_likelihoods(c, model[m]["profiles"]), model[m]["temperature"])


def auto_posterior(model, r):
    parts = [(posterior(model, r, m), gate(r, m)) for m in SOURCES]
    parts = [(p, g) for p, g in parts if p]
    if not parts:
        return None, 0.0
    post = [statistics.mean(p[k] for p, _ in parts) for k in range(24)]
    return post, max(g for _, g in parts)


def predict(model, r, m):
    """(tonic, minor), confidence"""
    if m == "Auto":
        post, g = auto_posterior(model, r)
    else:
        post, g = posterior(model, r, m), gate(r, m)
    if not post:
        return None, 0.0
    k = post.index(max(post))
    return (k % 12, k >= 12), platt(model[m]["calibration"], post[k]) * g


def cross_validate(rows):
    mm = [r for r in rows if r["type"] != "both"]
    preds = {}
    for half in (0, 1):
        model = fit([r for r in mm if zlib.crc32(r["path"].encode()) % 2 != half])
        for r in rows:
            if zlib.crc32(r["path"].encode()) % 2 == half:
                preds[r["path"]] = {m: predict(model, r, m) for m in MODES}
    both = [r for r in rows if r["type"] == "both"]
    print(f"Two-fold cross-validation on {len(mm)} major/minor and {len(both)} 'both' loops (fitted on one half, scored on the other)")
    print(f"{'':10}{'exact':>8}{'MIREX':>8}{'both':>8}   High / Medium / Low confidence: share of loops, exact")
    for m in MODES:
        hits = [preds[r["path"]][m][0] == r["label"] for r in mm]
        mx = statistics.mean(mirex(preds[r["path"]][m][0], r["label"]) for r in mm)
        tonic = [preds[r["path"]][m][0] is not None and preds[r["path"]][m][0][0] == r["label"][0] for r in both]
        bands = []
        for _, lo, hi in BANDS:
            sel = [h for r, h in zip(mm, hits) if lo <= preds[r["path"]][m][1] < hi]
            bands.append(f"{100 * len(sel) / len(mm):5.1f}% {100 * sum(sel) / max(len(sel), 1):5.1f}%")
        print(f"{m:10}{100 * statistics.mean(hits):7.1f}%{mx:8.3f}{100 * statistics.mean(tonic):7.1f}%   " + " / ".join(bands))


def rust(model):
    def arr(xs):
        return "[" + ", ".join(f"{x:.4f}" for x in xs) + "]"

    print("\n// Generated by scripts/bench/train.py (all loops).")
    print("const PROFILES: [Profile; 3] = [")
    for m in SOURCES:
        p = model[m]
        a, b = p["calibration"]
        print(f"    // {m}")
        print("    Profile {")
        print(f"        major: {arr(p['profiles'][False])},")
        print(f"        minor: {arr(p['profiles'][True])},")
        print(f"        temperature: {p['temperature']:.2f},")
        print(f"        calibration: Calibration {{ slope: {a:.3f}, offset: {b:.3f} }},")
        print("    },")
    print("];")
    a, b = model["Auto"]["calibration"]
    print(f"const AUTO_CALIBRATION: Calibration = Calibration {{ slope: {a:.3f}, offset: {b:.3f} }};")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    rows = list(load(sys.argv[1]).values())
    cross_validate(rows)
    rust(fit([r for r in rows if r["type"] != "both"]))
