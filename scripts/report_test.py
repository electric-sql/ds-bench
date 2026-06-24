import os, sys, json, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import report

def _setup():
    # Self-contained fixture: a temp suite (modes wal/ursula, no server_configs)
    # plus matching per-mode cells.json. Returns (suite_path, results_root).
    root = tempfile.mkdtemp()
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
    suite = os.path.join(tempfile.mkdtemp(), "s.json")
    json.dump({"suite": "rpt", "modes": ["wal", "ursula"],
               "stream_counts": [1000, 100000], "cluster": {}, "saturation": {},
               "pod_ladder": {"1000": [16], "100000": [16]}}, open(suite, "w"))
    return suite, root


class TestReport(unittest.TestCase):
    def test_aggregate_rows(self):
        suite, root = _setup()
        rows, md = report.build(suite, root)
        wal1k = [r for r in rows if r["mode"] == "wal" and r["stream_count"] == 1000][0]
        self.assertEqual(wal1k["throughput"], 510000)
        self.assertIs(wal1k["saturated"], True)
        err = [r for r in rows if r["mode"] == "wal" and r["stream_count"] == 100000][0]
        self.assertEqual(err["status"], "error")

    def test_markdown_has_table_and_headers(self):
        suite, root = _setup()
        _, md = report.build(suite, root)
        self.assertTrue("| stream" in md.lower() or "| streams" in md.lower())
        self.assertIn("## Findings", md)
        self.assertIn("## Caveats", md)
        self.assertIn("ERROR", md)  # the choked 100k cell is flagged, not a real number

    def test_server_config_variants_are_side_by_side(self):
        # Two wal variants (default vs tailcache) become two columns next to each
        # other, each reading its own results/<label>/cells.json.
        root = tempfile.mkdtemp()
        for label, thr in [("wal", 100000), ("wal-tailcache", 130000)]:
            d = os.path.join(root, label); os.makedirs(d)
            json.dump({"cells": {"100": {"stream_count": 100, "throughput": thr,
                "p99": 1.0, "pinned_pods": 4, "saturated": True, "status": "ok",
                "reason": "plateau", "walk": [[4, thr]], "image_digest": "x"}}},
                open(os.path.join(d, "cells.json"), "w"))
        suite = os.path.join(tempfile.mkdtemp(), "s.json")
        json.dump({"suite": "cache-ab", "modes": ["wal"], "stream_counts": [100],
                   "cluster": {}, "saturation": {}, "pod_ladder": {"100": [4]},
                   "server_configs": {"wal": [{"label": "wal", "args": ""},
                       {"label": "wal-tailcache", "args": "--tail-cache-bytes 65536"}]}},
                  open(suite, "w"))
        rows, md = report.build(suite, root)
        labels = {r["mode"] for r in rows}
        self.assertEqual(labels, {"wal", "wal-tailcache"})
        self.assertIn("| wal | wal-tailcache |", md)  # adjacent columns


class TestSuiteStatus(unittest.TestCase):
    def _suite(self, server_configs=None):
        d = {"suite": "st", "modes": ["wal"], "stream_counts": [1, 10],
             "cluster": {}, "saturation": {}, "pod_ladder": {"1": [1], "10": [1, 2]}}
        if server_configs:
            d["server_configs"] = server_configs
        p = os.path.join(tempfile.mkdtemp(), "s.json")
        json.dump(d, open(p, "w"))
        return p

    def _cell(self, sc, status="ok"):
        return {"stream_count": sc, "throughput": 1.0, "p99": 1.0, "pinned_pods": 1,
                "saturated": True, "status": status, "reason": "plateau",
                "walk": [[1, 1.0]], "image_digest": "x"}

    def _write(self, root, label, cells):
        d = os.path.join(root, label); os.makedirs(d, exist_ok=True)
        json.dump({"cells": {str(c["stream_count"]): c for c in cells}},
                  open(os.path.join(d, "cells.json"), "w"))

    def test_complete_when_all_present_and_ok(self):
        suite = self._suite(); root = tempfile.mkdtemp()
        self._write(root, "wal", [self._cell(1), self._cell(10)])
        self.assertEqual(report.suite_status(suite, root), "complete")

    def test_incomplete_when_a_cell_missing(self):
        suite = self._suite(); root = tempfile.mkdtemp()
        self._write(root, "wal", [self._cell(1)])  # missing sc=10
        self.assertEqual(report.suite_status(suite, root), "incomplete")

    def test_errors_when_any_error_cell(self):
        suite = self._suite(); root = tempfile.mkdtemp()
        self._write(root, "wal", [self._cell(1), self._cell(10, status="error")])
        self.assertEqual(report.suite_status(suite, root), "errors")

    def test_complete_requires_every_label(self):
        # two server-config variants -> both labels must be fully present
        suite = self._suite({"wal": [{"label": "wal", "args": ""},
                                      {"label": "wal-tc", "args": "x"}]})
        root = tempfile.mkdtemp()
        self._write(root, "wal", [self._cell(1), self._cell(10)])  # wal-tc absent
        self.assertEqual(report.suite_status(suite, root), "incomplete")


if __name__ == "__main__":
    unittest.main()
