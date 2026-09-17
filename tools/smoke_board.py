#!/usr/bin/env python3
"""
Board smoke test — the wire, without a game.

Starts the board in-process and checks the promises the mod and any brain
depend on: a patch deep-merges and bumps seq, a dialogue change bumps
dialogue.seq, an observation is served back with its age, and posting
observations never moves seq (if it did, every report would re-dispatch
the body's mode).

    python3 tools/smoke_board.py
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "board"))

from fastapi.testclient import TestClient      # noqa: E402
import main as board                          # noqa: E402

PASSED = FAILED = 0


def case(name, fn):
    global PASSED, FAILED
    try:
        fn()
        PASSED += 1
        print(f"  ok   {name}")
    except Exception as e:
        FAILED += 1
        print(f"  FAIL {name}: {e!r}")


with TestClient(board.app) as c:
    print("board smoke")

    def health():
        r = c.get("/health").json()
        assert r["ok"] is True and "seq" in r, r
    case("health answers", health)

    def patch_merges():
        c.post("/state/reset")
        before = c.get("/state/seq").json()["seq"]
        s = c.patch("/state", json={"mode": "follow",
                                    "flags": {"enable_body": True}}).json()
        assert s["mode"] == "follow" and s["flags"]["enable_body"] is True, s
        s = c.patch("/state", json={"flags": {"follow_distance": 4.0}}).json()
        assert s["flags"]["enable_body"] is True, "patch replaced flags"
        assert s["flags"]["follow_distance"] == 4.0, s
        assert s["seq"] > before, "seq did not advance"
    case("a patch deep-merges and bumps seq", patch_merges)

    def dialogue_seq():
        first = c.patch("/state", json={"dialogue": {"text": "Hey, V."}}).json()
        again = c.patch("/state", json={"dialogue": {"text": "Hey, V."}}).json()
        newer = c.patch("/state", json={"dialogue": {"text": "Watch out."}}).json()
        assert again["dialogue"]["seq"] == first["dialogue"]["seq"], "same line re-spoke"
        assert newer["dialogue"]["seq"] > first["dialogue"]["seq"], "new line did not"
    case("dialogue.seq bumps once per new line", dialogue_seq)

    def bad_state():
        assert c.patch("/state", json={"mode": "nonsense"}).status_code == 400
    case("an invalid mode is refused", bad_state)

    def observed_roundtrip():
        assert c.get("/observed").json()["count"] == 0
        seq = c.get("/state/seq").json()["seq"]
        obs = {"v": 1, "clock": 1.0, "frame": 60,
               "player": {"pos": [0, 0, 0], "heading": 0.0, "in_combat": False},
               "body": {"live": True, "distance": 3.0, "bearing": 1.0}}
        assert c.put("/observed", json=obs).json()["ok"] is True
        view = c.get("/observed").json()
        assert view["observed"]["body"]["distance"] == 3.0, view
        assert view["age_s"] is not None and view["count"] == 1, view
        assert c.get("/state/seq").json()["seq"] == seq, "an observation moved seq"
    case("observations round-trip and never move seq", observed_roundtrip)

    def observed_validated():
        assert c.put("/observed", json={"no": "version"}).status_code == 400
    case("an observation without v:1 is refused", observed_validated)

    def schema_served():
        assert "properties" in c.get("/schema").json()
    case("the schema is served", schema_served)

print(f"\n{PASSED} passed, {FAILED} failed")
sys.exit(1 if FAILED else 0)
