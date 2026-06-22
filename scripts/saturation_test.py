import json, os, tempfile, unittest
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

if __name__ == "__main__":
    unittest.main()
