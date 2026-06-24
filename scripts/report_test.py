import os, sys, json, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import report

SUITE = os.path.join(HERE, "..", "suites", "write-throughput.json")


def _setup():
    root = tempfile.mkdtemp()
    # Accumulate cells per mode (a mode's cells.json holds one entry per stream_count).
    store = {}
    for mode, sc, thr, sat in [("wal", 1000, 510000, True), ("wal", 100000, 0, False),
                               ("ursula", 1000, 62000, True)]:
        status = "error" if (mode == "wal" and sc == 100000) else "ok"
        store.setdefault(mode, {})[str(sc)] = {"stream_count": sc, "throughput": thr,
            "p99": 2.0, "pinned_pods": 16, "saturated": sat, "status": status,
            "reason": "plateau", "walk": [[16, thr]], "image_digest": "x"}
    for mode, cells in store.items():
        d = os.path.join(root, mode); os.makedirs(d, exist_ok=True)
        json.dump({"cells": cells}, open(os.path.join(d, "cells.json"), "w"))
    return root


class TestReport(unittest.TestCase):
    def test_aggregate_rows(self):
        root = _setup()
        rows, md = report.build(SUITE, root)
        wal1k = [r for r in rows if r["mode"] == "wal" and r["stream_count"] == 1000][0]
        self.assertEqual(wal1k["throughput"], 510000)
        self.assertIs(wal1k["saturated"], True)
        err = [r for r in rows if r["mode"] == "wal" and r["stream_count"] == 100000][0]
        self.assertEqual(err["status"], "error")

    def test_markdown_has_table_and_headers(self):
        root = _setup()
        _, md = report.build(SUITE, root)
        self.assertTrue("| stream" in md.lower() or "| streams" in md.lower())
        self.assertIn("## Findings", md)
        self.assertIn("## Caveats", md)
        self.assertIn("ERROR", md)  # the choked 100k cell is flagged, not a real number


if __name__ == "__main__":
    unittest.main()
