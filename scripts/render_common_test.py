#!/usr/bin/env python3
import os, tempfile, importlib.util, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("rc", os.path.join(HERE, "render_common.py"))
rc = importlib.util.module_from_spec(spec); spec.loader.exec_module(rc)

class TestParseVerdict(unittest.TestCase):
    def _write(self, body):
        p = tempfile.NamedTemporaryFile(suffix=".txt", delete=False, mode="w")
        p.write(body); p.close(); return p.name
    def test_measure_provenance(self):
        f = self._write("cell=ms-cpu4-n10\nmode=measure\nparallelism=16\n"
                        "calibration_matched=false\ncalibration_key=old-key\n")
        v = rc.parse_verdict(f)
        self.assertEqual(v["calibration_matched"], "false")
        self.assertEqual(v["calibration_key"], "old-key")
        os.unlink(f)
    def test_calibrate_reason(self):
        f = self._write("cell=c\nmode=calibrate\nreason=plateau\nsaturated=true\n")
        v = rc.parse_verdict(f)
        self.assertEqual(v["reason"], "plateau")
        os.unlink(f)

if __name__ == "__main__":
    unittest.main()
