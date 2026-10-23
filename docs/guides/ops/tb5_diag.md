<!-- moved from Claude memory (reference_tb5_diag) on 2026-10-23; operational reference, rewrite in place -->

When Rick says **"test TB 5 connection"** (or similar): run `~/dev/VideoScan/scripts/tb5_diag.sh [peer-ssh-host]` (default peer ricksm5.local). Takes ~1 min. Checks: TB link + negotiated speed (80/120 Gb/s = TB5; 40 = cable not TB5-rated or too long — passive limit ≈1 m, active/optical needed beyond), Thunderbolt Bridge IPs both ends, RTT (<1 ms), and 4 GB TCP throughput BOTH directions (STRONG ≥55 Gbit/s, PASS ≥30, <8 = routing over Wi-Fi).

**Baseline (2026-07-06, OWC short passive TB5 cable, M4 Studio receptacle 4 ↔ M5 Pro MBP):** 80 Gb/s link · TX 65.1 / RX 63.1 Gbit/s · RTT 0.53 ms · verdict YES.

Gotchas encoded in the script: uses `/usr/bin/python3` on BOTH ends — Apple-signed python is exempt from macOS 26 **Local Network privacy (TCC)**, which blocks Homebrew/venv binaries with silent `Errno 65 No route to host` on link-local (this blocked MLX ring 2026-07-06; fix = one-time GUI "Allow" per machine for the venv python). MLX cluster demo: `scripts/mlx_cluster_demo.py`, launch via `venv-mlx/bin/mlx.launch --backend ring --hosts <bridgeIPs> --python .../venv-mlx/bin/python`; jaccl/RDMA backend awaits `rdma_ctl enable` in Recovery on both machines. Related: [[analysis-ledger-arc]].
