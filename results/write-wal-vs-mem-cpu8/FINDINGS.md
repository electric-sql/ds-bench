# wal vs memory write saturation — 8 pinned vCPUs (2026-07-08)

Part of the two-suite 2026-07-08 campaign. The combined write-up (headline table,
setup, accuracy story, provenance for BOTH suites) lives in
[`../write-wal-vs-mem-cpu4/FINDINGS.md`](../write-wal-vs-mem-cpu4/FINDINGS.md).

This suite's numbers: wal 68.8k @100k / 46.6k @500k; memory **483.6k** @100k /
**322.3k** @500k — memory ≈ 7× wal at 8 vCPU, every cell `windows_aligned=true`.
