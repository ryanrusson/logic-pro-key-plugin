#!/usr/bin/env bash
# Real-audio key accuracy benchmark on Logic's Apple Loops, whose metadata
# carries a key label. Builds the Rust core and a small swiftc harness
# (scripts/bench/main.swift + the plugin's AnalyzerHandle and KeyResult),
# analyses every pitched, labelled loop through the plugin's own decode path
# in parallel shards, then scores the results (scripts/bench/score.py).
#
#   scripts/bench-apple-loops.sh [results.tsv] [baseline.tsv]
#
# Pass a baseline (an earlier results file) to see the paired difference.
# LOOPS overrides the loop folder, JOBS the shard count.
set -euo pipefail
cd "$(dirname "$0")/.."

LOOPS=${LOOPS:-/Library/Audio/Apple Loops}
JOBS=${JOBS:-8}
WORK=core/target/bench
OUT=${1:-$WORK/apple-loops.tsv}
case $(uname -m) in
    arm64) TRIPLE=aarch64-apple-darwin ;;
    *) TRIPLE=x86_64-apple-darwin ;;
esac

(cd core && cargo build --release --target "$TRIPLE")
mkdir -p "$WORK"
xcrun swiftc -O -swift-version 5 -I core/include -L "core/target/$TRIPLE/release" -lkeyfinder_core \
    plugin/Sources/Shared/AnalyzerHandle.swift plugin/Sources/Shared/KeyResult.swift scripts/bench/main.swift \
    -o "$WORK/kf-bench"

find "$LOOPS" -name '*.caf' | sort > "$WORK/loops.txt"
[ -s "$WORK/loops.txt" ] || { echo "No .caf files under $LOOPS" >&2; exit 1; }
pids=()
for ((i = 0; i < JOBS; i++)); do
    awk -v n="$JOBS" -v i="$i" 'NR % n == i' "$WORK/loops.txt" | "$WORK/kf-bench" > "$WORK/shard.$i" &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
{ head -n 1 "$WORK/shard.0"; for ((i = 0; i < JOBS; i++)); do tail -n +2 "$WORK/shard.$i"; done | sort; } > "$OUT"
rm -f "$WORK"/shard.*

python3 -I scripts/bench/score.py "$OUT" ${2:+"$2"}
