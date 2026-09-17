"""
Anya State Board — v0.1

Single source of truth for the Cyberpunk embodiment loop.
MacBook (or any LAN host) runs this; game executor + agent + heuristics all talk here.

Endpoints:
  GET  /health          -> liveness
  GET  /state           -> full current state
  GET  /state/seq       -> {seq, timestamp} cheap poll
  PUT  /state           -> replace full state (validated)
  PATCH /state          -> deep-merge patch (validated result)
  POST /state/reset     -> restore default_state.json
  GET  /events          -> SSE stream of state changes
  PUT  /observed        -> what the game sees (from the tower relay); never bumps seq
  GET  /observed        -> latest observation + how old it is
  GET  /observed/events -> SSE stream of observations

Design: thin, local, no auth for v0 (LAN only). Inference never lives here.
"""

from __future__ import annotations

import argparse
import asyncio
import copy
import json
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Dict, List, Optional, Set

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "schema" / "state_v0.1.schema.json"
DEFAULT_STATE_PATH = ROOT / "schema" / "default_state.json"
STATE_FILE = ROOT / "board" / "data" / "current_state.json"

# Forward-declared; filled in lifespan / startup helpers
_state: Dict[str, Any] = {}
_schema: Dict[str, Any] = {}
_validator: Optional[Draft202012Validator] = None
_lock = asyncio.Lock()
_subscribers: Set[asyncio.Queue] = set()

# Perception is kept apart from the state: it changes every half second, and a
# seq bump makes the game re-dispatch its mode. In memory only.
_observed: Optional[Dict[str, Any]] = None
_observed_at: float = 0.0
_observed_count: int = 0
_observed_subscribers: Set[asyncio.Queue] = set()


def _boot_board() -> None:
    """Load schema + initial state (called once at process start)."""
    global _state, _schema, _validator

    _schema = _load_json(SCHEMA_PATH)
    _validator = Draft202012Validator(_schema)

    if STATE_FILE.exists():
        candidate = _load_json(STATE_FILE)
    else:
        candidate = _load_json(DEFAULT_STATE_PATH)
        candidate["timestamp"] = _now()

    if "seq" not in candidate:
        candidate["seq"] = 0
    if "body" not in candidate:
        candidate["body"] = "panam"
    if "animation" not in candidate:
        candidate["animation"] = ""
    if "dialogue" in candidate and "seq" not in candidate["dialogue"]:
        candidate["dialogue"]["seq"] = 0

    _validator.validate(candidate)
    _state = candidate
    _persist(_state)
    print(f"[anya-board] ready  seq={_state['seq']}  mode={_state['mode']}")
    print(f"[anya-board] state file: {STATE_FILE}")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    _boot_board()
    yield


app = FastAPI(
    title="Anya State Board",
    version="0.1.0",
    description="Bulletin board for Anya (state machine) ↔ Panam drone (Cyberpunk).",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

def _now() -> float:
    return time.time()


def _load_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def _deep_merge(base: Dict[str, Any], patch: Dict[str, Any]) -> Dict[str, Any]:
    """Recursive dict merge. Lists and scalars replace; dicts merge."""
    out = copy.deepcopy(base)
    for key, value in patch.items():
        if (
            key in out
            and isinstance(out[key], dict)
            and isinstance(value, dict)
        ):
            out[key] = _deep_merge(out[key], value)
        else:
            out[key] = copy.deepcopy(value)
    return out


def _validate(state: Dict[str, Any]) -> None:
    assert _validator is not None
    try:
        _validator.validate(state)
    except ValidationError as e:
        path = ".".join(str(p) for p in e.absolute_path) or "(root)"
        raise HTTPException(
            status_code=400,
            detail=f"schema validation failed at {path}: {e.message}",
        ) from e


def _persist(state: Dict[str, Any]) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, sort_keys=False)
        f.write("\n")
    tmp.replace(STATE_FILE)


async def _publish(state: Dict[str, Any]) -> None:
    dead: List[asyncio.Queue] = []
    for q in _subscribers:
        try:
            q.put_nowait(copy.deepcopy(state))
        except asyncio.QueueFull:
            dead.append(q)
    for q in dead:
        _subscribers.discard(q)


def _stamp(state: Dict[str, Any], *, bump_seq: bool = True) -> Dict[str, Any]:
    state = copy.deepcopy(state)
    state["timestamp"] = _now()
    if bump_seq:
        state["seq"] = int(state.get("seq") or 0) + 1
    state["version"] = 1
    return state


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.get("/health")
async def health() -> Dict[str, Any]:
    return {
        "ok": True,
        "service": "anya-board",
        "version": 1,
        "seq": _state.get("seq", 0),
        "mode": _state.get("mode"),
        "body": _state.get("body"),
    }


@app.get("/state")
async def get_state() -> Dict[str, Any]:
    async with _lock:
        return copy.deepcopy(_state)


@app.get("/state/seq")
async def get_seq() -> Dict[str, Any]:
    async with _lock:
        return {
            "seq": _state.get("seq", 0),
            "timestamp": _state.get("timestamp", 0),
            "mode": _state.get("mode"),
        }


@app.put("/state")
async def put_state(request: Request) -> Dict[str, Any]:
    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="body must be a JSON object")

    async with _lock:
        # Preserve seq base then stamp
        incoming = copy.deepcopy(body)
        incoming["seq"] = int(_state.get("seq") or 0)
        new_state = _stamp(incoming, bump_seq=True)
        _validate(new_state)
        _state.clear()
        _state.update(new_state)
        _persist(_state)
        published = copy.deepcopy(_state)

    await _publish(published)
    return published


@app.patch("/state")
async def patch_state(request: Request) -> Dict[str, Any]:
    patch = await request.json()
    if not isinstance(patch, dict):
        raise HTTPException(status_code=400, detail="patch must be a JSON object")

    # Protect bookkeeping — always recomputed server-side
    patch.pop("version", None)
    patch.pop("timestamp", None)
    patch.pop("seq", None)

    async with _lock:
        merged = _deep_merge(_state, patch)

        # If dialogue.text is being set to a non-empty new value, bump dialogue.seq
        # so the game executor can detect "new line to speak".
        if "dialogue" in patch:
            d_patch = patch["dialogue"] or {}
            if isinstance(d_patch, dict) and "text" in d_patch:
                old_text = (_state.get("dialogue") or {}).get("text", "")
                new_text = d_patch.get("text", "")
                if new_text and new_text != old_text and "seq" not in d_patch:
                    merged["dialogue"]["seq"] = int(
                        (_state.get("dialogue") or {}).get("seq") or 0
                    ) + 1

        new_state = _stamp(merged, bump_seq=True)
        _validate(new_state)
        _state.clear()
        _state.update(new_state)
        _persist(_state)
        published = copy.deepcopy(_state)

    await _publish(published)
    return published


@app.post("/state/reset")
async def reset_state() -> Dict[str, Any]:
    async with _lock:
        fresh = _load_json(DEFAULT_STATE_PATH)
        fresh["seq"] = int(_state.get("seq") or 0)
        new_state = _stamp(fresh, bump_seq=True)
        _validate(new_state)
        _state.clear()
        _state.update(new_state)
        _persist(_state)
        published = copy.deepcopy(_state)

    await _publish(published)
    return published


@app.get("/events")
async def events() -> StreamingResponse:
    """Server-Sent Events stream of full state snapshots after each write."""
    queue: asyncio.Queue = asyncio.Queue(maxsize=8)
    _subscribers.add(queue)

    async def gen():
        try:
            # Snapshot immediately so clients sync without an extra GET
            async with _lock:
                snapshot = copy.deepcopy(_state)
            yield f"data: {json.dumps(snapshot)}\n\n"
            while True:
                state = await queue.get()
                yield f"data: {json.dumps(state)}\n\n"
        except asyncio.CancelledError:
            pass
        finally:
            _subscribers.discard(queue)

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


def _observed_view() -> Dict[str, Any]:
    age = (_now() - _observed_at) if _observed is not None else None
    return {
        "observed": copy.deepcopy(_observed),
        "received_at": _observed_at or None,
        "age_s": round(age, 3) if age is not None else None,
        "count": _observed_count,
    }


@app.put("/observed")
async def put_observed(request: Request) -> Dict[str, Any]:
    global _observed, _observed_at, _observed_count
    body = await request.json()
    if not isinstance(body, dict) or body.get("v") != 1:
        raise HTTPException(status_code=400, detail='observation must be a JSON object with "v": 1')
    _observed = body
    _observed_at = _now()
    _observed_count += 1
    view = _observed_view()
    dead: List[asyncio.Queue] = []
    for q in _observed_subscribers:
        try:
            q.put_nowait(view)
        except asyncio.QueueFull:
            dead.append(q)
    for q in dead:
        _observed_subscribers.discard(q)
    return {"ok": True, "count": _observed_count}


@app.get("/observed")
async def get_observed() -> Dict[str, Any]:
    return _observed_view()


@app.get("/observed/events")
async def observed_events() -> StreamingResponse:
    """SSE stream of observations as the relay delivers them."""
    queue: asyncio.Queue = asyncio.Queue(maxsize=8)
    _observed_subscribers.add(queue)

    async def gen():
        try:
            yield f"data: {json.dumps(_observed_view())}\n\n"
            while True:
                view = await queue.get()
                yield f"data: {json.dumps(view)}\n\n"
        except asyncio.CancelledError:
            pass
        finally:
            _observed_subscribers.discard(queue)

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive", "X-Accel-Buffering": "no"},
    )


@app.get("/schema")
async def get_schema() -> Dict[str, Any]:
    return _schema


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def run() -> None:
    parser = argparse.ArgumentParser(description="Anya State Board")
    parser.add_argument("--host", default="0.0.0.0", help="Bind host (0.0.0.0 for LAN)")
    parser.add_argument("--port", type=int, default=8787, help="Bind port")
    parser.add_argument("--reload", action="store_true", help="Dev auto-reload")
    args = parser.parse_args()

    import uvicorn

    uvicorn.run(
        "main:app",
        host=args.host,
        port=args.port,
        reload=args.reload,
        log_level="info",
    )


if __name__ == "__main__":
    run()
