#!/usr/bin/env python3
"""
boardctl — tiny CLI to read/patch the Anya state board.

Examples:
  python tools/boardctl.py get
  python tools/boardctl.py seq
  python tools/boardctl.py follow
  python tools/boardctl.py hold
  python tools/boardctl.py idle
  python tools/boardctl.py say "Watch your six, V."
  python tools/boardctl.py mode combat
  python tools/boardctl.py patch '{"mode":"follow","target":{"type":"player","value":null}}'
  python tools/boardctl.py reset
  python tools/boardctl.py observed        # latest perception from the game
  python tools/boardctl.py watch           # one line per observation, live
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Dict, Optional

DEFAULT_URL = os.environ.get("ANYA_BOARD_URL", "http://127.0.0.1:8787")


def _req(
    method: str,
    path: str,
    body: Optional[Dict[str, Any]] = None,
    base: str = DEFAULT_URL,
) -> Any:
    url = base.rstrip("/") + path
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=5) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")
        print(f"HTTP {e.code}: {detail}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Cannot reach board at {url}: {e.reason}", file=sys.stderr)
        print(f"Is the board running?  (cd board && uv run python main.py)", file=sys.stderr)
        sys.exit(1)


def _print(obj: Any) -> None:
    print(json.dumps(obj, indent=2))


def _deg(rad: Any) -> str:
    return f"{math.degrees(rad):+5.0f}°" if isinstance(rad, (int, float)) else "   -"


def _m(v: Any) -> str:
    return f"{v:5.1f}m" if isinstance(v, (int, float)) else "    -"


def _observed_line(view: Dict[str, Any]) -> str:
    """Bearing: 0 ahead of V, + to V's left, - to V's right."""
    obs = view.get("observed")
    if not obs:
        return "no observation yet — is the tower relay forwarding observed.json?"
    age = view.get("age_s")
    body = obs.get("body") or {}
    player = obs.get("player") or {}
    if body.get("live"):
        hp = body.get("health")
        dz = body.get("dz")
        parts = [
            "body",
            _m(body.get("distance")),
            _deg(body.get("bearing")),
            f"dz {dz:+.1f}" if isinstance(dz, (int, float)) else "dz -",
            f"hp {hp:.0f}" if isinstance(hp, (int, float)) else "hp -",
        ]
        if body.get("attitude"):
            parts.append(str(body["attitude"]))
        if body.get("dead"):
            parts.append("DEAD")
        who = " ".join(parts)
    else:
        who = "body  none"
    look = obs.get("look_at")
    looking = ""
    if look:
        name = look.get("name") or look.get("record") or "?"
        looking = f" | looking at {name} {_m(look.get('distance'))} {look.get('attitude') or ''}".rstrip()
    combat = player.get("in_combat")
    return (
        f"age {age:4.1f}s seq {obs.get('board_seq')} mode {body.get('mode')} | {who}"
        f" | V combat {combat if combat is not None else '-'}{looking}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Control the Anya state board")
    parser.add_argument(
        "--url",
        default=DEFAULT_URL,
        help=f"Board base URL (default {DEFAULT_URL} or $ANYA_BOARD_URL)",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("health", help="GET /health")
    sub.add_parser("get", help="GET /state")
    sub.add_parser("seq", help="GET /state/seq")
    sub.add_parser("reset", help="POST /state/reset")

    p_mode = sub.add_parser("mode", help="Set mode only")
    p_mode.add_argument("mode", choices=["idle", "follow", "move_to", "hold", "combat", "converse", "spawn", "despawn"])

    sub.add_parser("follow", help="mode=follow, target=player")
    sub.add_parser("hold", help="mode=hold")
    sub.add_parser("idle", help="mode=idle")
    sub.add_parser("combat", help="mode=combat")

    p_say = sub.add_parser("say", help="Set dialogue line (bumps dialogue.seq)")
    p_say.add_argument("text")
    p_say.add_argument("--emotion", default="")
    p_say.add_argument("--timeout", type=float, default=8.0)

    p_goal = sub.add_parser("goal", help="Set goal string")
    p_goal.add_argument("text")

    p_attn = sub.add_parser("attention", help="Set attention string")
    p_attn.add_argument("text")

    sub.add_parser("observed", help="GET /observed (what the game sees)")
    p_watch = sub.add_parser("watch", help="Print one line per observation")
    p_watch.add_argument("--interval", type=float, default=0.5)

    p_patch = sub.add_parser("patch", help="Raw JSON patch")
    p_patch.add_argument("json")

    p_put = sub.add_parser("put", help="Raw full-state JSON replace")
    p_put.add_argument("json")

    args = parser.parse_args()
    base = args.url

    if args.cmd == "health":
        _print(_req("GET", "/health", base=base))
    elif args.cmd == "get":
        _print(_req("GET", "/state", base=base))
    elif args.cmd == "seq":
        _print(_req("GET", "/state/seq", base=base))
    elif args.cmd == "reset":
        _print(_req("POST", "/state/reset", base=base))
    elif args.cmd == "mode":
        _print(_req("PATCH", "/state", {"mode": args.mode}, base=base))
    elif args.cmd == "follow":
        _print(
            _req(
                "PATCH",
                "/state",
                {"mode": "follow", "target": {"type": "player", "value": None}, "goal": "follow player"},
                base=base,
            )
        )
    elif args.cmd == "hold":
        _print(_req("PATCH", "/state", {"mode": "hold", "goal": "hold position"}, base=base))
    elif args.cmd == "idle":
        _print(
            _req(
                "PATCH",
                "/state",
                {"mode": "idle", "target": {"type": "none", "value": None}, "goal": ""},
                base=base,
            )
        )
    elif args.cmd == "combat":
        _print(_req("PATCH", "/state", {"mode": "combat", "goal": "engage threats"}, base=base))
    elif args.cmd == "say":
        _print(
            _req(
                "PATCH",
                "/state",
                {
                    "mode": "converse",
                    "dialogue": {
                        "text": args.text,
                        "emotion": args.emotion,
                        "timeout": args.timeout,
                    },
                },
                base=base,
            )
        )
    elif args.cmd == "goal":
        _print(_req("PATCH", "/state", {"goal": args.text}, base=base))
    elif args.cmd == "attention":
        _print(_req("PATCH", "/state", {"attention": args.text}, base=base))
    elif args.cmd == "observed":
        _print(_req("GET", "/observed", base=base))
    elif args.cmd == "watch":
        last = None
        try:
            while True:
                view = _req("GET", "/observed", base=base)
                if view.get("count") != last:
                    print(_observed_line(view), flush=True)
                    last = view.get("count")
                time.sleep(args.interval)
        except KeyboardInterrupt:
            pass
    elif args.cmd == "patch":
        body = json.loads(args.json)
        _print(_req("PATCH", "/state", body, base=base))
    elif args.cmd == "put":
        body = json.loads(args.json)
        _print(_req("PUT", "/state", body, base=base))
    else:
        parser.error(f"unknown command {args.cmd}")


if __name__ == "__main__":
    main()
