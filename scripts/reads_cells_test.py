import os, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(__file__))
import reads_cells


class ReadsCellsTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.p = os.path.join(self.d, "cells.json")

    def _rec(self, sc, conn, digest="dig1", status="ok"):
        reads_cells.record(self.p, sc, conn, image_digest=digest,
                           ops_per_sec=100.0, bytes_per_sec=4096.0, p50=1.0, p99=5.0,
                           backpressure=0, other_err=0, status=status, reason="complete")

    def test_absent_before_any_record(self):
        self.assertEqual(reads_cells.status_of(self.p, 10, "dig1"), "absent")
        self.assertEqual(reads_cells.conn_status(self.p, 10, 8, "dig1"), "absent")

    def test_conn_status_done_after_record(self):
        self._rec(10, 8)
        self.assertEqual(reads_cells.conn_status(self.p, 10, 8, "dig1"), "done")
        self.assertEqual(reads_cells.conn_status(self.p, 10, 32, "dig1"), "absent")

    def test_status_done_only_after_mark_complete(self):
        self._rec(10, 8)
        self._rec(10, 32)
        self.assertEqual(reads_cells.status_of(self.p, 10, "dig1"), "absent")
        reads_cells.mark_complete(self.p, 10, "dig1")
        self.assertEqual(reads_cells.status_of(self.p, 10, "dig1"), "done")

    def test_digest_mismatch_is_absent(self):
        self._rec(10, 8)
        reads_cells.mark_complete(self.p, 10, "dig1")
        self.assertEqual(reads_cells.status_of(self.p, 10, "dig2"), "absent")

    def test_all_cells_returns_connections_map(self):
        self._rec(10, 8)
        self._rec(10, 32)
        cells = reads_cells.all_cells(self.p)
        self.assertEqual(len(cells), 1)
        self.assertEqual(set(cells[0]["connections"].keys()), {"8", "32"})


if __name__ == "__main__":
    unittest.main()
