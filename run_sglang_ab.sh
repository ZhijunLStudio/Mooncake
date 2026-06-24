#!/bin/bash
# SGLang HiCache A/B comparison: Baseline vs Optimized Mooncake Store
set -e

BASELINE_MASTER="/tmp/mooncake-baseline/builddir/mooncake-store/src/mooncake_master"
OPTIMIZED_MASTER="$(dirname "$0")/builddir/mooncake-store/src/mooncake_master"
CONDA_LIB="/data/lizhijun/anaconda3/lib"
FULL_LD="$CONDA_LIB:$(dirname "$0")/builddir_py312/mooncake-common:$(dirname "$0")/builddir_py312/mooncake-store/src:$(dirname "$0")/builddir_py312/mooncake-transfer-engine/src"
SGLANG_PYTHON="/data/lizhijun/anaconda3/envs/sglang/bin/python"
MODEL_PATH="/data/lizhijun/.cache/modelscope/hub/models/qwen/Qwen2.5-0.5B-Instruct"
GPU=1
N_RUNS=${1:-3}

# Test prompts - multi-turn simulation
PROMPTS=(
    '{"model":"Qwen2.5-0.5B-Instruct","prompt":"Explain the concept of caching in 50 words.","max_tokens":128,"temperature":0}'
    '{"model":"Qwen2.5-0.5B-Instruct","prompt":"Write a Python function to sort a list.","max_tokens":128,"temperature":0}'
    '{"model":"Qwen2.5-0.5B-Instruct","prompt":"What is the capital of France?","max_tokens":64,"temperature":0}'
)

run_round() {
    local master_bin="$1"
    local label="$2"
    local port=30001

    echo "=== $label ==="

    # Start master
    fuser -k 50051/tcp 2>/dev/null || true; fuser -k 8080/tcp 2>/dev/null || true
    sleep 1
    LD_LIBRARY_PATH="$CONDA_LIB" "$master_bin" \
        --enable_http_metadata_server=true --http_metadata_server_port=8080 \
        --eviction_high_watermark_ratio=0.95 --port=50051 --metrics_port=23333 \
        --enable_metric_reporting=false > /tmp/master_"$label".log 2>&1 &
    local master_pid=$!
    sleep 3
    if ! ss -tlnp | grep -q 50051; then echo "Master failed"; return 1; fi

    # Launch SGLang
    fuser -k $port/tcp 2>/dev/null || true; sleep 1
    CUDA_VISIBLE_DEVICES=$GPU \
    LD_LIBRARY_PATH="$FULL_LD" \
    MOONCAKE_MASTER="127.0.0.1:50051" \
    MOONCAKE_PROTOCOL="tcp" \
    MOONCAKE_DEVICE="" \
    MOONCAKE_TE_META_DATA_SERVER="http://127.0.0.1:8080/metadata" \
    MOONCAKE_GLOBAL_SEGMENT_SIZE="4294967296" \
    MOONCAKE_LOCAL_HOSTNAME="localhost" \
    "$SGLANG_PYTHON" -u -m sglang.launch_server \
        --enable-hierarchical-cache --hicache-storage-backend mooncake \
        --model-path "$MODEL_PATH" --hicache-mem-layout page_first \
        --tp-size 1 --mem-fraction-static 0.6 --max-total-tokens 8192 \
        --host 0.0.0.0 --port $port \
        > /tmp/sglang_"$label".log 2>&1 &
    local sglang_pid=$!

    # Wait for server ready
    echo -n "  Waiting for SGLang..."
    for i in $(seq 1 60); do
        if curl -s http://127.0.0.1:$port/health > /dev/null 2>&1; then
            echo " ready"
            break
        fi
        sleep 2
    done

    # Run test prompts
    local results_file="/tmp/sglang_ab_${label}.jsonl"
    > "$results_file"
    for prompt_json in "${PROMPTS[@]}"; do
        local start=$(date +%s%N)
        local resp=$(curl -s http://127.0.0.1:$port/v1/completions \
            -H "Content-Type: application/json" -d "$prompt_json" 2>&1)
        local end=$(date +%s%N)
        local elapsed_ms=$(( (end - start) / 1000000 ))
        # Extract token count
        local tokens=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens',0))" 2>/dev/null || echo 0)
        echo "{\"label\":\"$label\",\"elapsed_ms\":$elapsed_ms,\"tokens\":$tokens}" >> "$results_file"
        echo "  Request: ${elapsed_ms}ms, $tokens tokens"
    done

    # Cleanup
    kill $sglang_pid 2>/dev/null || true; wait $sglang_pid 2>/dev/null || true
    kill $master_pid 2>/dev/null || true; wait $master_pid 2>/dev/null || true
    sleep 2
}

echo "============================================"
echo " SGLang HiCache A/B: Baseline vs Optimized"
echo " Rounds: $N_RUNS"
echo "============================================"

for i in $(seq 1 $N_RUNS); do
    echo ""; echo "--- Round $i/$N_RUNS ---"
    run_round "$BASELINE_MASTER" "baseline_$i"
    run_round "$OPTIMIZED_MASTER" "optimized_$i"
done

echo ""; echo "============================================"
echo " RESULTS"
echo "============================================"

python3 << 'PYEOF'
import json, glob

for label_prefix in ["baseline", "optimized"]:
    all_ms = []
    all_tps = []
    for f in sorted(glob.glob(f"/tmp/sglang_ab_{label_prefix}_*.jsonl")):
        if not f: continue
        with open(f) as fh:
            for line in fh:
                d = json.loads(line)
                all_ms.append(d["elapsed_ms"])
                if d["tokens"] > 0:
                    all_tps.append(d["tokens"] / (d["elapsed_ms"] / 1000.0))

    if all_ms:
        import statistics
        avg_ms = statistics.mean(all_ms)
        print(f"{label_prefix}: avg latency={avg_ms:.0f}ms, "
              f"throughput={statistics.mean(all_tps):.1f} tok/s "
              f"(n={len(all_ms)})")
PYEOF
