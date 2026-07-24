#!/usr/bin/env python3
"""mlx_cluster_demo.py — the baby app that sells Mac Studios.

Demonstrates distributed MLX across Macs linked by Thunderbolt 5:

  Act 1 — Collective bandwidth: all_sum of growing tensors (the heartbeat
          operation of distributed training), reported in GB/s.
  Act 2 — Compute scaling: a fat matmul benchmark, solo vs. sharded
          across the cluster.
  Act 3 — The VideoScan finale: cosine-similarity search of 31 reference
          embeddings (hi Donna) against 200k synthetic 512-d face
          embeddings — the ArcFace shape — solo vs. sharded.

Run solo (baseline):           python3 mlx_cluster_demo.py
Run on the cluster (TCP ring): mlx.launch --backend ring \
                                 --hosts <ip1>,<ip2> mlx_cluster_demo.py
Run on the cluster (RDMA):     mlx.launch --backend jaccl \
                                 --hosts <ip1>,<ip2> mlx_cluster_demo.py
The script is backend-agnostic — same code, faster physics.
"""
import time
import mlx.core as mx

group = mx.distributed.init()
rank, size = group.rank(), group.size()


def say(msg: str) -> None:
    if rank == 0:
        print(msg, flush=True)


def bench(fn, warmup: int = 2, runs: int = 5) -> float:
    for _ in range(warmup):
        mx.eval(fn())
    t0 = time.perf_counter()
    for _ in range(runs):
        mx.eval(fn())
    return (time.perf_counter() - t0) / runs


say(f"━━ MLX cluster demo — {size} node(s), backend: "
    f"{'distributed' if size > 1 else 'solo'} ━━")

# ── Act 1: collective bandwidth ─────────────────────────────────────
if size > 1:
    say("\nAct 1 — all_sum collective bandwidth (the training heartbeat)")
    for mb in (1, 16, 64, 256, 1024):
        n = mb * 1024 * 1024 // 4                     # float32 elements
        x = mx.ones((n,), dtype=mx.float32)
        mx.eval(x)
        dt = bench(lambda: mx.distributed.all_sum(x))
        # all_sum moves ~2x the payload in a 2-node ring (send + recv)
        say(f"  {mb:5d} MB tensor: {dt*1e3:8.2f} ms   "
            f"≈ {2 * mb / 1024 / dt:6.2f} GB/s effective")
else:
    say("\nAct 1 skipped (solo run — nothing to sum with)")

# ── Act 2: compute scaling — fat matmul ─────────────────────────────
say("\nAct 2 — matmul scaling (8192×8192 @ 8192×8192, fp16)")
N = 8192
a = mx.random.normal((N, N), dtype=mx.float16)
b = mx.random.normal((N, N), dtype=mx.float16)
mx.eval(a, b)
solo = bench(lambda: a @ b)
say(f"  one node, full matrix:      {solo*1e3:8.2f} ms   "
    f"({2 * N**3 / solo / 1e12:5.1f} TFLOPS)")
if size > 1:
    rows = N // size
    a_shard = a[rank * rows:(rank + 1) * rows, :]
    mx.eval(a_shard)

    def sharded():
        part = a_shard @ b
        return mx.distributed.all_gather(part)

    dist = bench(sharded)
    say(f"  {size} nodes, sharded rows:    {dist*1e3:8.2f} ms   "
        f"({2 * N**3 / dist / 1e12:5.1f} TFLOPS aggregate)  "
        f"speedup ×{solo/dist:.2f}")

# ── Act 3: the VideoScan finale — find Donna ────────────────────────
say("\nAct 3 — embedding search: 31 references vs 200,000 faces (512-d)")
FACES, DIM, REFS = 200_000, 512, 31
mx.random.seed(1979)                     # the year Rick met Donna
refs = mx.random.normal((REFS, DIM))
refs = refs / mx.linalg.norm(refs, axis=1, keepdims=True)

# Every node holds its shard of the catalog (as a real cluster would).
shard = FACES // size
faces = mx.random.normal((shard, DIM), dtype=mx.float32)
faces = faces / mx.linalg.norm(faces, axis=1, keepdims=True)
mx.eval(refs, faces)


def search_local():
    sims = faces @ refs.T                # (shard, REFS) cosine sims
    return mx.max(sims, axis=1)          # best-ref score per face


# Solo baseline: rank 0 scores the WHOLE catalog alone.
if rank == 0:
    all_faces = mx.random.normal((FACES, DIM), dtype=mx.float32)
    all_faces = all_faces / mx.linalg.norm(all_faces, axis=1, keepdims=True)
    mx.eval(all_faces)
    t_solo = bench(lambda: mx.max(all_faces @ refs.T, axis=1))
    say(f"  one node scores all {FACES:,}:  {t_solo*1e3:8.2f} ms")

if size > 1:
    def search_cluster():
        return mx.distributed.all_gather(search_local())

    t_dist = bench(search_cluster)
    say(f"  {size} nodes score {shard:,} each: {t_dist*1e3:8.2f} ms   "
        f"speedup ×{t_solo/t_dist:.2f}")
    say("\n  (Same math VideoScan's ArcFace person-search runs — "
        "every added Mac is another lane through the family archive.)")

say("\n━━ demo complete ━━")
