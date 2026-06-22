import json, os, subprocess, sys, tempfile, unittest
import importlib.util
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("saturation", os.path.join(HERE, "saturation.py"))
sat = importlib.util.module_from_spec(spec); spec.loader.exec_module(sat)

class TestClassify(unittest.TestCase):
    def test_cpu_bound(self):          # 370% >= 0.9*4*100=360
        self.assertEqual(sat.classify(0, 100000, 370.0, 4), "cpu")
    def test_headroom_real_n10_to_n100(self):   # +24% gain, cpu under threshold
        self.assertEqual(sat.classify(860827, 1069919, 222.0, 4), "headroom")
    def test_plateau_small_gain(self):          # +5% gain, cpu low
        self.assertEqual(sat.classify(1000000, 1050000, 200.0, 4), "plateau")
    def test_no_prev_cannot_plateau(self):
        self.assertEqual(sat.classify(0, 50, 10.0, 4), "headroom")

class TestThroughput(unittest.TestCase):
    def test_reads_aggregate_ops(self):
        p = tempfile.NamedTemporaryFile(suffix=".json", delete=False, mode="w")
        p.write('coordinator log line\n{"aggregate_ops_per_sec": 1069919.5, "p99_ms": 12.7}\n'); p.close()
        self.assertAlmostEqual(sat.extract_throughput(p.name), 1069919.5)
        os.unlink(p.name)
    def test_reads_aggregate_events(self):
        p = tempfile.NamedTemporaryFile(suffix=".json", delete=False, mode="w")
        p.write('{"aggregate_events_per_sec": 120000.0}\n'); p.close()
        self.assertAlmostEqual(sat.extract_throughput(p.name), 120000.0)
        os.unlink(p.name)
    def test_last_object_wins_multiple_objects(self):
        # Regression: ensure we return the LAST JSON object's value, not the first or a merged swallow
        p = tempfile.NamedTemporaryFile(suffix=".json", delete=False, mode="w")
        p.write('coordinator log\n{"aggregate_ops_per_sec": 100.0}\n{"aggregate_ops_per_sec": 999.0}\n')
        p.close()
        self.assertAlmostEqual(sat.extract_throughput(p.name), 999.0)
        os.unlink(p.name)
    def test_pretty_printed_multiline_with_log_prefix(self):
        # Regression: the REAL coordinator merged.json is a `mc cp` log prefix
        # followed by a PRETTY-PRINTED (multi-line) JSON object. A per-line scan
        # misses it (no single line is a complete object) → must still parse it.
        real = (
            "Added `local` successfully.\n"
            "coordinator: 8 client result file(s) under run-x\n"
            "`local/bench-results/run-x/ms-0.json` -> `/merge/ms-0.json`\n"
            "┌───┐\n│ Total │\n└───┘\n"
            "{\n"
            '  "merged_count": 1240094,\n'
            '  "p50_ms": 0.214,\n'
            '  "p99_ms": 3.813,\n'
            '  "aggregate_ops_per_sec": 82654.70762487104\n'
            "}\n"
        )
        p = tempfile.NamedTemporaryFile(suffix=".json", delete=False, mode="w")
        p.write(real); p.close()
        self.assertAlmostEqual(sat.extract_throughput(p.name), 82654.70762487104)
        os.unlink(p.name)

class TestCLI(unittest.TestCase):
    # The calibrate loop in lib-bench.sh shells out to this CLI and takes the
    # first field as the reason. Lock that "<reason> <thr>" contract.
    def _run(self, merged_text, prev_thr, cpu, cores):
        p = tempfile.NamedTemporaryFile(suffix=".json", delete=False, mode="w")
        p.write(merged_text); p.close()
        try:
            r = subprocess.run(
                [sys.executable, os.path.join(HERE, "saturation.py"),
                 "--merged", p.name, "--prev-thr", str(prev_thr),
                 "--cpu", str(cpu), "--cores", str(cores)],
                capture_output=True, text=True)
            return r
        finally:
            os.unlink(p.name)

    def test_cli_prints_reason_and_throughput(self):
        r = self._run('{"aggregate_ops_per_sec": 1050000.0}\n', 1000000, 50, 4)
        self.assertEqual(r.returncode, 0, r.stderr)
        reason, thr = r.stdout.split()
        self.assertEqual(reason, "plateau")        # +5% gain <10%
        self.assertAlmostEqual(float(thr), 1050000.0)

    def test_cli_cpu_bound(self):
        r = self._run('{"aggregate_ops_per_sec": 5000.0}\n', 0, 370, 4)
        self.assertEqual(r.stdout.split()[0], "cpu")   # 370 >= 0.9*4*100

if __name__ == "__main__":
    unittest.main()
