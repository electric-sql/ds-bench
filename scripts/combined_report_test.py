import os, sys, json, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import combined_report


def _suite(tmp, name, labels_cells, server_configs=None):
    """labels_cells: {label: [(stream_count, throughput, saturated, status), ...]}"""
    d = {"suite": name, "modes": list(labels_cells.keys()), "stream_counts": sorted({sc for cells in labels_cells.values() for sc, *_ in cells}),
         "cluster": {}, "saturation": {}, "pod_ladder": {str(sc): [4] for cells in labels_cells.values() for sc, *_ in cells}}
    if server_configs:
        d["server_configs"] = server_configs
    sp = os.path.join(tmp, f"{name}.json")
    json.dump(d, open(sp, "w"))
    root = os.path.join("results", name)
    for label, cells in labels_cells.items():
        ld = os.path.join(root, label); os.makedirs(ld, exist_ok=True)
        obj = {"cells": {}}
        for sc, thr, sat, status in cells:
            obj["cells"][str(sc)] = {"stream_count": sc, "throughput": thr, "p50": 1.0, "p99": 1.0,
                "pinned_pods": 4, "saturated": sat, "status": status, "reason": "plateau" if sat else "ladder_exhausted",
                "walk": [[4, thr]], "image_digest": "x"}
        json.dump(obj, open(os.path.join(ld, "cells.json"), "w"))
    return sp


class TestCombined(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        # isolate results/ writes under a temp cwd
        self._cwd = os.getcwd()
        os.chdir(self.tmp)

    def tearDown(self):
        os.chdir(self._cwd)

    def test_peak_per_config(self):
        sp1 = _suite(self.tmp, "wt-a", {"wal": [(1000, 400000, False, "ok"), (10000, 485000, True, "ok")]})
        sp2 = _suite(self.tmp, "wt-b", {"ursula": [(1000, 50000, False, "ok"), (10000, 60000, True, "ok")]})
        rows, peaks = combined_report.build_combined([sp1, sp2])
        self.assertEqual(int(peaks["wal"]["throughput"]), 485000)
        self.assertEqual(peaks["wal"]["stream_count"], 10000)
        self.assertIs(peaks["wal"]["saturated"], True)
        self.assertEqual(int(peaks["ursula"]["throughput"]), 60000)

    def test_error_cells_excluded_from_peak(self):
        sp = _suite(self.tmp, "wt-c", {"wal": [(1000, 400000, False, "ok"), (100000, 0, False, "error")]})
        rows, peaks = combined_report.build_combined([sp])
        self.assertEqual(int(peaks["wal"]["throughput"]), 400000)  # error 100k not the peak

    def test_markdown_lists_configs_and_errors(self):
        sp = _suite(self.tmp, "wt-d", {"wal": [(1000, 400000, True, "ok"), (100000, 0, False, "error")]})
        rows, peaks = combined_report.build_combined([sp])
        md = combined_report.markdown(rows, peaks)
        self.assertIn("Peak throughput per configuration", md)
        self.assertIn("ERR(", md)        # error cell flagged in the matrix
        self.assertIn("400k", md)


if __name__ == "__main__":
    unittest.main()
