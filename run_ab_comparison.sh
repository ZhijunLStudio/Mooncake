#!/bin/bash
# A/B comparison script: Baseline vs Optimized Mooncake Store
# Runs test_kvcache_e2e.py against both versions, multiple iterations each
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASELINE_MASTER="/tmp/mooncake-baseline/builddir/mooncake-store/src/mooncake_master"
OPTIMIZED_MASTER="$SCRIPT_DIR/builddir/mooncake-store/src/mooncake_master"
E2E_SCRIPT="$SCRIPT_DIR/test_kvcache_e2e.py"
CONDA_LIB="/data/lizhijun/anaconda3/lib"
BUILDDIR_LIBS="$SCRIPT_DIR/builddir/mooncake-common:$SCRIPT_DIR/builddir/mooncake-store/src:$SCRIPT_DIR/builddir/mooncake-transfer-engine/src"
LD_PATH="${CONDA_LIB}:${BUILDDIR_LIBS}"
N_RUNS=${1:-10}
MASTER_PORT=50051
METRICS_PORT=23334
HTTP_PORT=8080

RESULTS_DIR="/tmp/ab_results"
mkdir -p "$RESULTS_DIR"

echo "=============================================="
echo "  Mooncake Store A/B Comparison"
echo "  Baseline (origin/main) vs Optimized (perf/store-optimizations)"
echo "  Runs per version: $N_RUNS"
echo "=============================================="

run_single_test() {
    local version_name="$1"
    local master_binary="$2"
    local run_id="$3"
    local logfile="$RESULTS_DIR/${version_name}_run${run_id}.log"

    # Kill any existing master
    fuser -k ${MASTER_PORT}/tcp 2>/dev/null || true
    fuser -k ${HTTP_PORT}/tcp 2>/dev/null || true
    fuser -k ${METRICS_PORT}/tcp 2>/dev/null || true
    sleep 1

    # Start master
    LD_LIBRARY_PATH="$LD_PATH" "$master_binary" \
        --enable_http_metadata_server=true \
        --http_metadata_server_port=$HTTP_PORT \
        --eviction_high_watermark_ratio=0.95 \
        --port=$MASTER_PORT \
        --metrics_port=$METRICS_PORT \
        --enable_metric_reporting=false \
        > /tmp/master_${version_name}.log 2>&1 &
    local master_pid=$!
    sleep 2

    # Verify master started
    if ! ss -tlnp | grep -q "$MASTER_PORT"; then
        echo "  [FAIL] Master ($version_name) failed to start"
        cat /tmp/master_${version_name}.log | tail -5
        kill $master_pid 2>/dev/null || true
        return 1
    fi

    # Run benchmark
    LD_LIBRARY_PATH="$LD_PATH" MASTER_ADDR="127.0.0.1:$MASTER_PORT" \
        python3 "$E2E_SCRIPT" > "$logfile" 2>&1
    local rc=$?

    # Kill master
    kill $master_pid 2>/dev/null || true
    wait $master_pid 2>/dev/null || true
    sleep 1

    if [ $rc -ne 0 ]; then
        echo "  [FAIL] Benchmark ($version_name run $run_id) failed"
        return 1
    fi

    # Extract metrics
    local put_small=$(grep "PUT:" "$logfile" | head -1 | awk '{print $8}' | tr -d ',')
    local put_medium=$(grep "PUT:" "$logfile" | head -2 | tail -1 | awk '{print $8}' | tr -d ',')
    local put_large=$(grep "PUT:" "$logfile" | head -3 | tail -1 | awk '{print $8}' | tr -d ',')
    local get_small=$(grep "GET:" "$logfile" | head -1 | awk '{print $8}' | tr -d ',')
    local get_medium=$(grep "GET:" "$logfile" | head -2 | tail -1 | awk '{print $8}' | tr -d ',')
    local get_large=$(grep "GET:" "$logfile" | head -3 | tail -1 | awk '{print $8}' | tr -d ',')
    local mix_small=$(grep "MIX:" "$logfile" | head -1 | awk '{print $8}' | tr -d ',')
    local mix_medium=$(grep "MIX:" "$logfile" | head -2 | tail -1 | awk '{print $8}' | tr -d ',')
    local mix_large=$(grep "MIX:" "$logfile" | head -3 | tail -1 | awk '{print $8}' | tr -d ',')

    echo "$put_small,$put_medium,$put_large,$get_small,$get_medium,$get_large,$mix_small,$mix_medium,$mix_large"
    return 0
}

# Collect results
baseline_results=()
optimized_results=()

echo ""
echo "--- Testing BASELINE (origin/main) ---"
for i in $(seq 1 $N_RUNS); do
    echo -n "  Baseline run $i/$N_RUNS... "
    result=$(run_single_test "baseline" "$BASELINE_MASTER" "$i")
    if [ $? -eq 0 ]; then
        baseline_results+=("$result")
        echo "OK"
    else
        echo "SKIPPED"
    fi
done

echo ""
echo "--- Testing OPTIMIZED (perf/store-optimizations) ---"
for i in $(seq 1 $N_RUNS); do
    echo -n "  Optimized run $i/$N_RUNS... "
    result=$(run_single_test "optimized" "$OPTIMIZED_MASTER" "$i")
    if [ $? -eq 0 ]; then
        optimized_results+=("$result")
        echo "OK"
    else
        echo "SKIPPED"
    fi
done

echo ""
echo "=============================================="
echo "  RESULTS SUMMARY"
echo "=============================================="
echo ""

# Python script for statistical analysis
python3 << 'PYEOF'
import csv
import sys

# Read baseline results
baseline_files = ["/tmp/ab_results/baseline_run%d.log" % i for i in range(1, 100)]
optimized_files = ["/tmp/ab_results/optimized_run%d.log" % i for i in range(1, 100)]

import os

def parse_log(filename):
    if not os.path.exists(filename):
        return None
    with open(filename) as f:
        lines = f.readlines()
    metrics = {}
    for line in lines:
        if "PUT:" in line and "MB/s" in line:
            # Determine which config: Small, Medium, Large
            # Use the line ordering
            pass
    return metrics

def parse_all_logs(pattern):
    results = {"put_small": [], "put_medium": [], "put_large": [],
               "get_small": [], "get_medium": [], "get_large": [],
               "mix_small": [], "mix_medium": [], "mix_large": []}
    for f in sorted(glob.glob(pattern)):
        import glob
        with open(f) as fh:
            content = fh.read()
        # Parse PUT lines in order
        put_lines = [l for l in content.split('\n') if 'PUT:' in l and 'MB/s' in l]
        get_lines = [l for l in content.split('\n') if 'GET:' in l and 'MB/s' in l]
        mix_lines = [l for l in content.split('\n') if 'MIX:' in l and 'MB/s' in l]

        if len(put_lines) >= 3:
            results["put_small"].append(float(put_lines[0].split()[6].replace(',','')))
            results["put_medium"].append(float(put_lines[1].split()[6].replace(',','')))
            results["put_large"].append(float(put_lines[2].split()[6].replace(',','')))
        if len(get_lines) >= 3:
            results["get_small"].append(float(get_lines[0].split()[6].replace(',','')))
            results["get_medium"].append(float(get_lines[1].split()[6].replace(',','')))
            results["get_large"].append(float(get_lines[2].split()[6].replace(',','')))
        if len(mix_lines) >= 3:
            results["mix_small"].append(float(mix_lines[0].split()[6].replace(',','')))
            results["mix_medium"].append(float(mix_lines[1].split()[6].replace(',','')))
            results["mix_large"].append(float(mix_lines[2].split()[6].replace(',','')))
    return results

import glob, statistics

base = parse_all_logs("/tmp/ab_results/baseline_run*.log")
opt = parse_all_logs("/tmp/ab_results/optimized_run*.log")

labels = [
    ("PUT 4KB", "put_small"), ("PUT 128KB", "put_medium"), ("PUT 1MB", "put_large"),
    ("GET 4KB", "get_small"), ("GET 128KB", "get_medium"), ("GET 1MB", "get_large"),
    ("MIX 4KB", "mix_small"), ("MIX 128KB", "mix_medium"), ("MIX 1MB", "mix_large"),
]

print(f"{'Metric':<16} {'Baseline Avg':>14} {'Optimized Avg':>14} {'Change':>10}  {'N(base)':>8} {'N(opt)':>8}")
print("-" * 78)

for label, key in labels:
    b_vals = base.get(key, [])
    o_vals = opt.get(key, [])
    if len(b_vals) < 3 or len(o_vals) < 3:
        print(f"{label:<16} {'N/A':>14} {'N/A':>14} {'N/A':>10}  {len(b_vals):>8} {len(o_vals):>8}")
        continue
    b_avg = statistics.mean(b_vals)
    o_avg = statistics.mean(o_vals)
    pct = (o_avg - b_avg) / b_avg * 100
    print(f"{label:<16} {b_avg:>14.2f} {o_avg:>14.2f} {pct:>+9.1f}%  {len(b_vals):>8} {len(o_vals):>8}")

print()
print("Note: ops/s shown for PUT/GET, MB/s for throughput metrics from test output")
PYEOF

echo ""
echo "=============================================="
echo "  Done. Logs saved to $RESULTS_DIR/"
echo "=============================================="
