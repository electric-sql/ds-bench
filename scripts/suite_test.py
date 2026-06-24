import os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from suite import Suite

SUITE = os.path.join(HERE, "..", "suites", "write-throughput.json")


class TestSuite(unittest.TestCase):
    def test_loads_fields(self):
        s = Suite.load(SUITE)
        self.assertEqual(s.name, "write-throughput")
        self.assertEqual(s.modes, ["wal", "ursula", "s2"])
        self.assertEqual(s.stream_counts, [1, 10, 100, 1000, 10000, 100000])
        self.assertEqual(s.cluster["server_machine"], "c4d-standard-16-lssd")
        self.assertEqual(s.saturation["plateau_pct"], 10)
        self.assertEqual(s.saturation["fleet_cpu"], 0.5)

    def test_ladder_for(self):
        s = Suite.load(SUITE)
        self.assertEqual(s.ladder_for(1000), [12, 16, 20, 24, 32])
        self.assertEqual(s.ladder_for(100000), [128, 200, 256, 320, 400, 512])

    def test_ladder_for_missing_raises(self):
        s = Suite.load(SUITE)
        with self.assertRaises(KeyError):
            s.ladder_for(999)


if __name__ == "__main__":
    unittest.main()
