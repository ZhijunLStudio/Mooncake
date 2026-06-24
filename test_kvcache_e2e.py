#!/usr/bin/env python3
"""
End-to-end KVCache simulation benchmark for Mooncake Store.
Simulates LLM inference KVCache put/get patterns:
- Prefill phase: write KV cache blocks (large values, sequential keys)
- Decode phase: read KV cache blocks (random access pattern)
- Mixed: concurrent reads and writes

Usage:
  1. Start master:  ./builddir/mooncake-store/src/mooncake_master --port=50051
  2. Run this:      python3 test_kvcache_e2e.py
"""

import os
import sys
import time
import threading
import numpy as np

# Add build dir to path for the store module
os.environ["LD_LIBRARY_PATH"] = (
    f"{os.environ.get('CONDA_PREFIX', '')}/lib"
    f":builddir/mooncake-common"
    f":builddir/mooncake-store/src"
    f":builddir/mooncake-transfer-engine/src"
    f":{os.environ.get('LD_LIBRARY_PATH', '')}"
)

import importlib.util
spec = importlib.util.spec_from_file_location(
    "store", "builddir/mooncake-integration/store.cpython-313-x86_64-linux-gnu.so"
)
store_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(store_mod)

MooncakeDistributedStore = store_mod.MooncakeDistributedStore
ReplicateConfig = store_mod.ReplicateConfig
KVCACHE = store_mod.KVCACHE


def make_kv_pairs(num_kv, kv_size, prefix="kv"):
    """Generate synthetic KV cache data (simulating LLM layers)."""
    pairs = []
    for i in range(num_kv):
        key = f"{prefix}_{i:06d}"
        value = np.random.bytes(kv_size)
        pairs.append((key, value))
    return pairs


def benchmark_put(store, pairs, batch_size=32):
    """Benchmark Put operations (simulates prefill write-back)."""
    config = ReplicateConfig()
    config.replica_num = 1

    total_bytes = 0
    start = time.perf_counter()

    for i in range(0, len(pairs), batch_size):
        batch = pairs[i : i + batch_size]
        for key, value in batch:
            rc = store.put(key, value, config)
            if rc != 0:
                print(f"  Put failed for {key}: rc={rc}")
            total_bytes += len(value)

    elapsed = time.perf_counter() - start
    throughput = total_bytes / elapsed / (1024 * 1024)  # MB/s
    ops_per_sec = len(pairs) / elapsed
    return elapsed, throughput, ops_per_sec, total_bytes


def benchmark_get(store, keys, batch_size=32):
    """Benchmark Get operations (simulates decode cache lookup)."""
    total_bytes = 0
    hits = 0
    misses = 0
    start = time.perf_counter()

    for i in range(0, len(keys), batch_size):
        batch = keys[i : i + batch_size]
        for key in batch:
            value = store.get(key)
            if value is not None and len(value) > 0:
                total_bytes += len(value)
                hits += 1
            else:
                misses += 1

    elapsed = time.perf_counter() - start
    throughput = total_bytes / elapsed / (1024 * 1024) if elapsed > 0 else 0
    ops_per_sec = (hits + misses) / elapsed if elapsed > 0 else 0
    return elapsed, throughput, ops_per_sec, total_bytes, hits, misses


def benchmark_mixed(store, pairs, read_ratio=0.8, num_threads=4, ops_per_thread=1000):
    """Benchmark mixed read/write (simulates concurrent prefill+decode)."""
    keys = [k for k, _ in pairs]
    all_keys = keys.copy()
    results = {"reads": 0, "writes": 0, "errors": 0, "total_bytes": 0}
    lock = threading.Lock()

    def worker(tid):
        rng = np.random.RandomState(42 + tid)
        local_reads = 0
        local_writes = 0
        local_bytes = 0
        config = ReplicateConfig()
        config.replica_num = 1

        for _ in range(ops_per_thread):
            if rng.random() < read_ratio:
                key = rng.choice(all_keys)
                value = store.get(key)
                if value and len(value) > 0:
                    local_reads += 1
                    local_bytes += len(value)
            else:
                key, value = pairs[rng.randint(0, len(pairs))]
                value = os.urandom(len(value))  # new random data
                rc = store.put(key, value, config)
                if rc == 0:
                    local_writes += 1
                    local_bytes += len(value)

        with lock:
            results["reads"] += local_reads
            results["writes"] += local_writes
            results["total_bytes"] += local_bytes

    start = time.perf_counter()
    threads = [threading.Thread(target=worker, args=(i,)) for i in range(num_threads)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    elapsed = time.perf_counter() - start

    total_ops = results["reads"] + results["writes"]
    throughput = results["total_bytes"] / elapsed / (1024 * 1024)
    return elapsed, throughput, total_ops / elapsed, results


def main():
    master_addr = os.environ.get("MASTER_ADDR", "127.0.0.1:50051")
    print(f"=== Mooncake Store KVCache E2E Benchmark ===")
    print(f"Master: {master_addr}")

    # Initialize store client
    store = MooncakeDistributedStore()
    # Configure as client (no local segment, just remote access)
    rc = store.setup(
        "localhost",                                  # local_hostname
        "http://127.0.0.1:8080/metadata",            # metadata_server
        1024 * 1024 * 1024,                          # global_segment_size (1GB)
        64 * 1024 * 1024,                            # local_buffer_size (64MB)
        "tcp",                                        # protocol
        "",                                           # rdma_devices
        master_addr,                                  # master_server_addr
    )
    if rc != 0:
        print(f"ERROR: Store.Setup failed with rc={rc}")
        print("Make sure mooncake_master is running on {master_addr}")
        sys.exit(1)
    print("Store client connected successfully!\n")

    # Test parameters
    configs = [
        {"name": "Small KV (4KB, simulates single layer)", "kv_size": 4096, "num_kv": 1000},
        {"name": "Medium KV (128KB, simulates typical page)", "kv_size": 128 * 1024, "num_kv": 500},
        {"name": "Large KV (1MB, simulates large page)", "kv_size": 1024 * 1024, "num_kv": 100},
    ]

    for cfg in configs:
        print(f"--- {cfg['name']} ---")
        pairs = make_kv_pairs(cfg["num_kv"], cfg["kv_size"])

        # Put benchmark
        elapsed, throughput, ops, total = benchmark_put(store, pairs)
        print(f"  PUT: {elapsed:.2f}s, {ops:.0f} ops/s, {throughput:.1f} MB/s, {total/(1024*1024):.1f} MB total")

        # Get benchmark
        keys = [k for k, _ in pairs]
        elapsed, throughput, ops, total, hits, misses = benchmark_get(store, keys)
        print(f"  GET: {elapsed:.2f}s, {ops:.0f} ops/s, {throughput:.1f} MB/s, hits={hits}, misses={misses}")

        # Mixed benchmark (4 threads)
        elapsed, throughput, ops, res = benchmark_mixed(
            store, pairs, read_ratio=0.8, num_threads=4, ops_per_thread=500
        )
        print(f"  MIX: {elapsed:.2f}s, {ops:.0f} ops/s, {throughput:.1f} MB/s, reads={res['reads']}, writes={res['writes']}")
        print()

    # Cleanup
    print("=== Benchmark Complete ===")


if __name__ == "__main__":
    main()
