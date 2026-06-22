#!/usr/bin/env python3
"""calibration/pins.json CRUD + key construction (calibrate-then-pin)."""
import argparse, json, os, re, sys

_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PATH = os.path.join(_REPO, "calibration", "pins.json")

def _path(args):
    return args.path or os.environ.get("PINS_PATH") or DEFAULT_PATH

def _load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}

def _save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")

def digest12(image):
    m = re.search(r'sha256:([0-9a-f]{12,})', image) or re.search(r'([0-9a-f]{12,})', image)
    if not m:
        sys.exit(f"cannot extract digest from image ref: {image!r}")
    return m.group(1)[:12]

def make_key(image, machine, cpu, mem):
    return f"{digest12(image)}-{machine}-cpu{cpu}-mem{mem}"

def cmd_key(a):
    print(make_key(a.image, a.machine, a.cpu, a.mem))

def cmd_get(a):
    e = _load(_path(a)).get(a.key)
    if e is None or a.cell not in e.get("cells", {}):
        sys.exit(1)
    print(e["cells"][a.cell]["pods"])

def cmd_set(a):
    path = _path(a); data = _load(path); e = data.get(a.key)
    if e is None:
        seq = 1 + max((v.get("seq", 0) for v in data.values()), default=0)
        e = {"seq": seq, "image": a.image or "", "machine": a.machine or "",
             "server_cpu": a.cpu or "", "server_mem": a.mem or "", "cells": {}}
        data[a.key] = e
    cell = {"pods": a.pods, "saturated": a.saturated, "reason": a.reason}
    if a.ops is not None:
        cell["ops"] = a.ops
    e["cells"][a.cell] = cell
    _save(path, data)

def cmd_latest(a):
    data = _load(_path(a))
    m = [(v.get("seq", 0), k) for k, v in data.items()
         if v.get("machine") == a.machine and v.get("server_cpu") == a.cpu
         and v.get("server_mem") == a.mem]
    if not m:
        sys.exit(1)
    print(max(m)[1])

def cmd_list(a):
    data = _load(_path(a))
    for k in sorted(data, key=lambda k: data[k].get("seq", 0)):
        e = data[k]
        print(f"[seq {e.get('seq')}] {k}  ({len(e.get('cells', {}))} cells)")

def _bool(x):
    return str(x).lower() == "true"

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--path", default=None)
    sub = p.add_subparsers(dest="cmd", required=True)
    k = sub.add_parser("key")
    for f in ("image", "machine", "cpu", "mem"):
        k.add_argument("--" + f, required=True)
    k.set_defaults(func=cmd_key)
    g = sub.add_parser("get"); g.add_argument("key"); g.add_argument("cell"); g.set_defaults(func=cmd_get)
    s = sub.add_parser("set")
    s.add_argument("key"); s.add_argument("cell"); s.add_argument("pods", type=int)
    s.add_argument("--reason", required=True)
    s.add_argument("--saturated", type=_bool, default=True)
    s.add_argument("--ops", type=int, default=None)
    for f in ("image", "machine", "cpu", "mem"):
        s.add_argument("--" + f, default=None)
    s.set_defaults(func=cmd_set)
    la = sub.add_parser("latest")
    la.add_argument("machine"); la.add_argument("cpu"); la.add_argument("mem")
    la.set_defaults(func=cmd_latest)
    li = sub.add_parser("list"); li.set_defaults(func=cmd_list)
    a = p.parse_args(); a.func(a)

if __name__ == "__main__":
    main()
