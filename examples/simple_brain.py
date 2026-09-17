#!/usr/bin/env python3
"""
A body, driven by fifty lines and no dependencies.

She keeps pace with you, holds when you are busy, and joins your fights.
That is the whole program — read it as the protocol in miniature, then
replace the `decide` function with whatever you actually want driving.

    python3 examples/simple_brain.py --board http://127.0.0.1:8787

It patches the board only when its mind changes, because every patch is a
seq change and the mod re-applies the mode on each one.
"""

from __future__ import annotations

import argparse
import json
import math
import time
import urllib.request

FOLLOW_M = 3.0


def call(board: str, path: str, patch: dict | None = None) -> dict:
    data = json.dumps(patch).encode() if patch is not None else None
    req = urllib.request.Request(
        board.rstrip("/") + path, data=data, method="PATCH" if data else "GET",
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read() or b"{}")


def decide(obs: dict) -> tuple[str, dict] | None:
    """Return (mode, patch) for what the body should be doing, or None to
    leave it alone. Everything you need is in one observation."""
    body, player = obs.get("body") or {}, obs.get("player") or {}
    if not body.get("live"):
        return None                                   # nothing to drive yet
    if player.get("in_combat"):
        return "combat", {"mode": "combat", "goal": "fight beside V"}
    distance = body.get("distance") or 0.0
    if distance > 25:
        # too far to walk back sensibly — ask her to come to you
        return "move_to", {"mode": "move_to",
                           "target": {"type": "player", "value": None},
                           "goal": "catch up"}
    return "follow", {"mode": "follow",
                      "target": {"type": "player", "value": None},
                      "flags": {"follow_distance": FOLLOW_M},
                      "goal": "walk with V"}


def main() -> None:
    ap = argparse.ArgumentParser(description="Drive an AnyaBoard body.")
    ap.add_argument("--board", default="http://127.0.0.1:8787")
    ap.add_argument("--record", default="Character.Judy")
    ap.add_argument("--appearance", default="judy_default")
    ap.add_argument("--say", default="Right behind you.")
    args = ap.parse_args()

    # Bring a body into the world. enable_body is false until someone asks.
    call(args.board, "/state", {
        "body": "judy",
        "flags": {"enable_body": True, "body_record": args.record,
                  "body_appearance": args.appearance,
                  "follow_distance": FOLLOW_M},
        "mode": "follow", "target": {"type": "player", "value": None}})
    print(f"[brain] body requested: {args.record} ({args.appearance})")

    said, last = False, "follow"
    while True:
        view = call(args.board, "/observed")
        obs, age = view.get("observed"), view.get("age_s")
        if not obs or age is None or age > 5:
            print("[brain] the game is not reporting", flush=True)
            time.sleep(2)
            continue

        body = obs.get("body") or {}
        if body.get("live") and not said:
            call(args.board, "/state", {"dialogue": {"text": args.say,
                                                     "timeout": 6.0}})
            said = True

        choice = decide(obs)
        if choice and choice[0] != last:
            mode, patch = choice
            call(args.board, "/state", patch)
            where = (f"{body.get('distance', 0):.1f} m, "
                     f"{math.degrees(body.get('bearing') or 0):+.0f}°")
            print(f"[brain] {last} -> {mode}  (she is {where})", flush=True)
            last = mode
        time.sleep(1.0)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n[brain] leaving her where she stands")
