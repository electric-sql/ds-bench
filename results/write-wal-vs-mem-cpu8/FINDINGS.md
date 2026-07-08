# wal vs memory write saturation — 8 pinned vCPUs (2026-07-08, corrected)

Part of the two-suite corrected campaign. The combined write-up (headline table,
knee-latency methodology + the manual verification that motivated it, setup,
provenance) lives in
[`../write-wal-vs-mem-cpu4/FINDINGS.md`](../write-wal-vs-mem-cpu4/FINDINGS.md).

This suite's numbers (plateau thr; knee p50): wal 43k @ 5.0 ms (100k) / 29k @
6.9 ms (500k); memory **526k @ 1.2 ms** (100k) / **323k @ 1.3 ms** (500k) —
memory ≈ 11–12× wal at 8 vCPU, every cell `windows_aligned=true`.
