import json, os, subprocess, sys, tempfile, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
PINS = os.path.join(HERE, "pins.py")

def run(args, path):
    env = dict(os.environ, PINS_PATH=path)
    return subprocess.run([sys.executable, PINS, *args], env=env,
                          capture_output=True, text=True)

class TestKeyGetSet(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False).name
        open(self.tmp, "w").write("{}\n")
    def tearDown(self):
        os.unlink(self.tmp)

    def test_key_from_full_imageid(self):
        r = run(["key", "--image",
                 "europe-west1-docker.pkg.dev/x/ds-bench/durable-streams@sha256:c105b202e5b31b67aa",
                 "--machine", "c4d-standard-16-lssd", "--cpu", "4", "--mem", "16Gi"], self.tmp)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "c105b202e5b3-c4d-standard-16-lssd-cpu4-mem16Gi")

    def test_get_missing_exits_1(self):
        r = run(["get", "nokey", "nocell"], self.tmp)
        self.assertEqual(r.returncode, 1)

    def test_set_then_get_roundtrip(self):
        run(["set", "K", "ms-cpu4-n10", "16", "--reason", "plateau", "--ops", "860827",
             "--image", "sha256:abc", "--machine", "m", "--cpu", "4", "--mem", "16Gi"], self.tmp)
        r = run(["get", "K", "ms-cpu4-n10"], self.tmp)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "16")
        data = json.load(open(self.tmp))
        self.assertEqual(data["K"]["cells"]["ms-cpu4-n10"]["reason"], "plateau")
        self.assertEqual(data["K"]["seq"], 1)

    def test_set_preserves_other_keys(self):
        run(["set", "A", "c", "8", "--reason", "cpu"], self.tmp)
        run(["set", "B", "c", "8", "--reason", "cpu"], self.tmp)
        data = json.load(open(self.tmp))
        self.assertIn("A", data); self.assertIn("B", data)
        self.assertEqual(data["B"]["seq"], 2)

if __name__ == "__main__":
    unittest.main()
