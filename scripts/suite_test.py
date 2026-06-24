import os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from suite import Suite

WAL = os.path.join(HERE, "..", "suites", "write-throughput-wal.json")
URSULA = os.path.join(HERE, "..", "suites", "write-throughput-ursula.json")


class TestSuite(unittest.TestCase):
    def test_loads_fields(self):
        # Structural invariants only — NOT tuning values (ladders/fleet_cpu change).
        s = Suite.load(WAL)
        self.assertEqual(s.name, "write-throughput-wal")
        self.assertEqual(s.modes, ["wal"])
        self.assertTrue(s.stream_counts)  # non-empty
        self.assertEqual(s.cluster["server_machine"], "c4d-standard-16-lssd")
        self.assertGreater(s.saturation["plateau_pct"], 0)
        self.assertGreater(s.saturation["fleet_cpu"], 0)

    def test_ladder_for_every_stream_count(self):
        # Each declared stream-count has a non-empty ladder of positive ints.
        s = Suite.load(WAL)
        for sc in s.stream_counts:
            ladder = s.ladder_for(sc)
            self.assertTrue(ladder and all(isinstance(p, int) and p >= 1 for p in ladder),
                            (sc, ladder))

    def test_ladder_for_missing_raises(self):
        s = Suite.load(WAL)
        with self.assertRaises(KeyError):
            s.ladder_for(999)

    def test_configs_for_default_when_absent(self):
        # A mode with no server_configs entry (ursula) has one implicit config =
        # the mode itself with empty server args (the baseline).
        s = Suite.load(URSULA)
        self.assertEqual(s.configs_for("ursula"), [{"label": "ursula", "args": ""}])
        self.assertEqual(s.labels(), ["ursula"])

    def test_wal_suite_server_configs_side_by_side(self):
        # The wal suite carries the tail-cache A/B as two labelled variants.
        s = Suite.load(WAL)
        self.assertEqual(s.configs_for("wal"), [
            {"label": "wal", "args": "--wal-shards 4"},
            {"label": "wal-tailcache", "args": "--wal-shards 4 --tail-cache-bytes 65536"}])
        self.assertEqual(s.labels(), ["wal", "wal-tailcache"])

    def test_configs_for_and_labels_in_memory(self):
        s = Suite({"suite": "x", "modes": ["wal"], "stream_counts": [1],
                   "cluster": {}, "saturation": {}, "pod_ladder": {"1": [1]},
                   "server_configs": {"wal": [
                       {"label": "wal", "args": ""},
                       {"label": "wal-tailcache", "args": "--tail-cache-bytes 65536"}]}})
        self.assertEqual(s.labels(), ["wal", "wal-tailcache"])


if __name__ == "__main__":
    unittest.main()
