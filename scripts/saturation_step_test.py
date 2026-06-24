import os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from saturation import step_decision


class TestStepDecision(unittest.TestCase):
    def test_first_rung_continues(self):
        self.assertEqual(step_decision(0, 100000, 10), "continue")

    def test_big_gain_continues(self):
        # +27% gain -> keep climbing
        self.assertEqual(step_decision(300000, 380000, 10), "continue")

    def test_small_gain_plateaus(self):
        # +2.4% gain < 10% -> saturated
        self.assertEqual(step_decision(410000, 420000, 10), "plateau")

    def test_exact_threshold_plateaus(self):
        # exactly 10% is not "above" the threshold -> plateau
        self.assertEqual(step_decision(100000, 110000, 10), "plateau")

    def test_collapse_is_error(self):
        self.assertEqual(step_decision(400000, 0, 10), "error")


if __name__ == "__main__":
    unittest.main()
