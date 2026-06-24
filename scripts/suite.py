"""Load and expose a benchmark suite JSON (see suites/write-throughput.json)."""
import json


class Suite:
    def __init__(self, data):
        self._d = data

    @classmethod
    def load(cls, path):
        with open(path) as f:
            return cls(json.load(f))

    @property
    def name(self):            return self._d["suite"]
    @property
    def modes(self):           return list(self._d["modes"])
    @property
    def stream_counts(self):   return list(self._d["stream_counts"])
    @property
    def cluster(self):         return dict(self._d["cluster"])
    @property
    def saturation(self):      return dict(self._d["saturation"])

    def ladder_for(self, stream_count):
        ladder = self._d["pod_ladder"]
        key = str(stream_count)
        if key not in ladder:
            raise KeyError(f"no pod_ladder entry for stream_count {stream_count}")
        return list(ladder[key])
