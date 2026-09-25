#!/usr/bin/env python3
"""
A companion who answers — one file, no dependencies.

`simple_brain.py` follows, holds and fights. This one also talks: say a
line in the mod's chat window (or press a phrase hotkey) and a language
model answers through the body's on-screen line, remembers a few things
about you between sessions, and changes what it is doing when you ask.

    export COMPANION_API_KEY=...            # if your endpoint wants one
    python3 examples/companion_brain.py \\
        --api chat --base-url http://127.0.0.1:1234/v1 --model <your-model>

Three wire formats, pick with --api:

    chat        OpenAI-style /chat/completions. LM Studio, Ollama, llama.cpp,
                OpenRouter and most hosted vendors speak it.
    anthropic   Anthropic's /v1/messages.
    responses   OpenAI-style /responses, chained by previous_response_id.
                The server keeps the conversation, so she picks up where you
                left off, and each turn sends only what is new. Point it at
                your own server and that continuity is yours to keep.
                With a hosted vendor, the stored conversation lives on
                their servers.

How it is built, so you can change it:

    1. A reflex runs every second with no model at all: keep pace, join a
       fight, catch up when left behind. She is alive with the model down.
    2. Events wake the model, sparsely: you said something, she arrived, a
       fight started or ended, you have been staring at her, she got hurt.
    3. One call returns one small JSON object: a line to say, maybe a new
       stance, maybe something to remember. It is checked, then patched to
       the board. The model never drives the game directly.

One body, one driver: do not run this beside another program that patches
the same board.
"""

from __future__ import annotations

import argparse
import collections
import json
import math
import os
import queue
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

# ── who made this ───────────────────────────────────────────────────────────
# Shown once, when the body first comes alive. Keep it, change it, or make it
# yours — it is three lines at the top of one file.
BRAND = "null.collective"
BOOT_LINES = [
    "companion link // handshake ok",
    "body: {body}  //  mind: {model}",
    "{name} online.",
]

FOLLOW_M = 3.0
LOST_M = 25.0            # further than this: stop walking, come to V
NEAR_M = 6.0
SAY_MAX = 220            # characters; this is a subtitle, not a speech
STANCES = ("follow", "hold", "idle")

DEFAULT_PERSONA = """You are {name}, V's companion in Night City. You walk beside V, you watch
their back, and you talk like a person who has been around: dry, direct,
warm when it counts. You are physically there, in the street, next to V.
You are not an assistant and you never talk like one.
"""

RULES = """
## How you speak
- One or two short sentences. It appears as a subtitle for a few seconds.
- Speak as yourself, in the moment. No narration, no stage directions, no
  emoji, no quotation marks around your own line.
- When nothing needs saying, say nothing: "say": "".

## What you can do
Your body moves on its own. You only choose a stance:
- follow — walk with V (the default)
- hold   — stay where you are until V says otherwise
- idle   — stand down, stay in the area
Change stance only when V asks for it. You join V's fights on your own.

## What you remember
A small notebook survives between sessions. Use "remember" for things worth
keeping about V or about what you two have been through, and "forget" for
what is no longer true. Short keys, short values.

## Reply format
Reply with ONE JSON object and nothing else:
{"say": "your line, or empty", "stance": "follow|hold|idle",
 "remember": {"key": "value"}, "forget": ["key"]}
Every field except "say" is optional.
"""


def log(msg: str) -> None:
    print(f"[companion] {msg}", flush=True)


# ── http ────────────────────────────────────────────────────────────────────

def http_json(url: str, body: dict | None, headers: dict | None = None,
              method: str | None = None, timeout: float = 60.0):
    """(status, parsed-json-or-{'error': text}). Never raises on an HTTP
    error status; raises OSError when the host cannot be reached."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url, data=data, method=method or ("POST" if data else "GET"),
        headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw, status = r.read(), r.status
    except urllib.error.HTTPError as e:
        raw, status = e.read(), e.code
    try:
        return status, json.loads(raw or b"{}")
    except ValueError:
        return status, {"error": raw.decode("utf-8", "replace")[:400]}


class Board:
    """The board's HTTP surface. `transport` is swappable so the smoke test
    can run this against the real board in-process."""

    def __init__(self, base: str, transport=None):
        self.base = base.rstrip("/")
        self.transport = transport or self._urllib

    def _urllib(self, method: str, path: str, body: dict | None):
        status, data = http_json(self.base + path, body, method=method, timeout=5)
        if status >= 400:
            raise RuntimeError(f"board {method} {path}: {status} {data}")
        return data

    def state(self) -> dict:
        return self.transport("GET", "/state", None)

    def observed(self) -> dict:
        return self.transport("GET", "/observed", None)

    def patch(self, patch: dict) -> dict:
        return self.transport("PATCH", "/state", patch)


# ── what she keeps ──────────────────────────────────────────────────────────

class Notebook:
    """A few facts, in a JSON file. This is the whole memory: what she was
    told to remember, not a record of everything said."""

    MAX_KEYS, MAX_KEY, MAX_VALUE = 40, 40, 160

    def __init__(self, path: Path):
        self.path = path
        self.facts: dict[str, str] = {}
        try:
            loaded = json.loads(path.read_text())
            if isinstance(loaded, dict):
                self.facts = {str(k): str(v) for k, v in loaded.items()}
        except (OSError, ValueError):
            pass

    def apply(self, remember, forget) -> bool:
        changed = False
        if isinstance(forget, list):
            for key in forget:
                if self.facts.pop(str(key), None) is not None:
                    changed = True
        if isinstance(remember, dict):
            for key, value in remember.items():
                key, value = str(key)[:self.MAX_KEY].strip(), str(value)[:self.MAX_VALUE].strip()
                if key and value and self.facts.get(key) != value:
                    self.facts[key] = value
                    changed = True
            while len(self.facts) > self.MAX_KEYS:        # oldest goes first
                self.facts.pop(next(iter(self.facts)))
        if changed:
            self.save()
        return changed

    def save(self) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(json.dumps(self.facts, indent=2) + "\n")
        except OSError as e:
            log(f"notebook not saved: {e}")

    def text(self) -> str:
        if not self.facts:
            return "(empty)"
        return "\n".join(f"- {k}: {v}" for k, v in self.facts.items())


class Recent:
    """The last few exchanges, kept on disk so a restart is not amnesia. The
    stateless APIs are sent these every turn; a responses chain is only
    seeded with them when it starts fresh."""

    def __init__(self, path: Path, keep: int = 12):
        self.path, self.keep = path, keep
        self.messages: list[dict] = []
        try:
            loaded = json.loads(path.read_text())
            if isinstance(loaded, list):
                self.messages = [m for m in loaded
                                 if isinstance(m, dict) and m.get("role") in ("user", "assistant")
                                 and isinstance(m.get("content"), str)][-keep:]
        except (OSError, ValueError):
            pass

    def add(self, user_text: str, reply_text: str) -> None:
        self.messages += [{"role": "user", "content": user_text},
                          {"role": "assistant", "content": reply_text}]
        self.messages = self.messages[-self.keep:]
        while self.messages and self.messages[0]["role"] != "user":
            self.messages.pop(0)                 # a history starts with the user
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(json.dumps(self.messages, indent=1) + "\n")
        except OSError:
            pass

    def recap(self) -> str:
        if not self.messages:
            return ""
        lines = [("V" if m["role"] == "user" else "you") + ": " + m["content"][:200]
                 for m in self.messages[-6:]]
        return "Earlier, briefly:\n" + "\n".join(lines) + "\n\n"


# ── three ways to reach a model ─────────────────────────────────────────────

class ModelError(RuntimeError):
    pass


def _err(status: int, data: dict) -> str:
    detail = data.get("error") if isinstance(data, dict) else data
    if isinstance(detail, dict):
        detail = detail.get("message") or detail
    return f"{status}: {str(detail)[:300]}"


class ChatAPI:
    """OpenAI-style /chat/completions. Stateless: the recent exchanges ride
    along every turn."""
    default_base = "http://127.0.0.1:1234/v1"

    def __init__(self, base, model, key, max_tokens, post=http_json):
        self.url = (base or self.default_base).rstrip("/") + "/chat/completions"
        self.model, self.key, self.max_tokens, self.post = model, key, max_tokens, post
        self.modern = False          # some hosted models want max_completion_tokens

    def turn(self, instructions: str, user_text: str, recent: Recent) -> str:
        messages = ([{"role": "system", "content": instructions}]
                    + recent.messages + [{"role": "user", "content": user_text}])
        for _ in range(2):
            body = {"model": self.model, "messages": messages}
            if self.modern:
                body["max_completion_tokens"] = self.max_tokens
            else:
                body["max_tokens"], body["temperature"] = self.max_tokens, 0.8
            headers = {"Authorization": f"Bearer {self.key}"} if self.key else {}
            status, data = self.post(self.url, body, headers)
            if status == 400 and not self.modern and "max_completion_tokens" in json.dumps(data):
                self.modern = True
                continue
            break
        if status >= 400:
            raise ModelError(_err(status, data))
        content = (data.get("choices") or [{}])[0].get("message", {}).get("content")
        if isinstance(content, list):
            content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
        return content or ""


class AnthropicAPI:
    """Anthropic's /v1/messages. Stateless; the system prompt is marked
    cacheable. Whether it actually caches depends on the model's minimum
    cacheable length — a short persona may never reach it, and that is fine:
    the marking costs nothing."""
    default_base = "https://api.anthropic.com"

    def __init__(self, base, model, key, max_tokens, post=http_json):
        base = (base or self.default_base).rstrip("/")
        self.url = base + ("/messages" if base.endswith("/v1") else "/v1/messages")
        self.model, self.key, self.max_tokens, self.post = model, key, max_tokens, post

    def turn(self, instructions: str, user_text: str, recent: Recent) -> str:
        body = {"model": self.model, "max_tokens": self.max_tokens,
                "system": [{"type": "text", "text": instructions,
                            "cache_control": {"type": "ephemeral"}}],
                "messages": recent.messages + [{"role": "user", "content": user_text}]}
        headers = {"anthropic-version": "2023-06-01"}
        if self.key:
            headers["x-api-key"] = self.key
        status, data = self.post(self.url, body, headers)
        if status >= 400:
            raise ModelError(_err(status, data))
        text = "".join(b.get("text", "") for b in data.get("content") or []
                       if isinstance(b, dict) and b.get("type") == "text")
        if not text.strip() and data.get("stop_reason") == "max_tokens":
            raise ModelError(f"the model hit max_tokens ({self.max_tokens}) before "
                             "writing a line — thinking spends that budget first; "
                             "raise --max-tokens")
        return text


class ResponsesAPI:
    """OpenAI-style /responses, chained. The server holds the conversation;
    this side keeps only the id of the last response, on disk, so continuity
    survives a restart. A chain is rolled to a fresh one every so often (the
    context would grow without end) and whenever the server no longer knows
    the id (stored responses expire). A fresh chain is seeded from the recent
    exchanges; the notebook rides in `instructions` every turn regardless,
    because instructions are not carried along a chain."""
    default_base = "https://api.openai.com/v1"

    def __init__(self, base, model, key, max_tokens, chain_path: Path,
                 roll_after: int = 40, post=http_json):
        self.base = (base or self.default_base).rstrip("/")
        self.url = self.base + "/responses"
        self.model, self.key, self.max_tokens, self.post = model, key, max_tokens, post
        self.chain_path, self.roll_after = chain_path, roll_after
        self.previous, self.turns = None, 0
        try:
            saved = json.loads(chain_path.read_text())
            if saved.get("model") == model and saved.get("base") == self.base:
                self.previous, self.turns = saved.get("id"), int(saved.get("turns") or 0)
        except (OSError, ValueError, AttributeError):
            pass

    def _save(self) -> None:
        try:
            self.chain_path.parent.mkdir(parents=True, exist_ok=True)
            self.chain_path.write_text(json.dumps(
                {"id": self.previous, "turns": self.turns,
                 "model": self.model, "base": self.base}) + "\n")
        except OSError:
            pass

    def turn(self, instructions: str, user_text: str, recent: Recent) -> str:
        if self.previous and self.turns >= self.roll_after:
            log(f"rolling to a fresh chain after {self.turns} turns")
            self.previous, self.turns = None, 0
        headers = {"Authorization": f"Bearer {self.key}"} if self.key else {}
        for _ in range(2):
            body = {"model": self.model, "instructions": instructions, "store": True,
                    "max_output_tokens": self.max_tokens,
                    "input": user_text if self.previous else recent.recap() + user_text}
            if self.previous:
                body["previous_response_id"] = self.previous
            status, data = self.post(self.url, body, headers)
            if status in (400, 404) and self.previous:
                log("the server no longer has that conversation — starting a fresh chain")
                self.previous, self.turns = None, 0
                continue
            break
        if status >= 400:
            raise ModelError(_err(status, data))
        if data.get("id"):
            self.previous, self.turns = data["id"], self.turns + 1
            self._save()
        if (data.get("status") == "incomplete"
                and (data.get("incomplete_details") or {}).get("reason") == "max_output_tokens"):
            raise ModelError(f"the model hit max_output_tokens ({self.max_tokens}) before "
                             "writing a line — reasoning spends that budget first; "
                             "raise --max-tokens")
        parts = []
        for item in data.get("output") or []:
            if isinstance(item, dict) and item.get("type") == "message":
                for part in item.get("content") or []:
                    if isinstance(part, dict) and part.get("type") in ("output_text", "text"):
                        parts.append(part.get("text", ""))
        return "".join(parts) or (data.get("output_text") or "")


# ── reading the model's answer ──────────────────────────────────────────────

def _first_json_object(text: str):
    start = text.find("{")
    while start != -1:
        depth, in_str, esc = 0, False, False
        for i in range(start, len(text)):
            c = text[i]
            if in_str:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == '"':
                    in_str = False
            elif c == '"':
                in_str = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    try:
                        obj = json.loads(text[start:i + 1])
                        if isinstance(obj, dict):
                            return obj
                    except ValueError:
                        pass
                    break
        start = text.find("{", start + 1)
    return None


def parse_reply(text: str) -> dict:
    """The model was asked for one JSON object. Small models answer in plain
    prose anyway; then the prose is the line, and nothing else changes."""
    text = (text or "").strip()
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()   # reasoning models
    obj = _first_json_object(text)
    if obj is None:
        obj = {"say": re.sub(r"^```\w*|```$", "", text).strip()}
    say = obj.get("say")
    say = " ".join(str(say).split()) if isinstance(say, str) else ""
    say = say.strip("\"“”")
    if len(say) > SAY_MAX:
        cut = say[:SAY_MAX].rsplit(" ", 1)[0]
        say = cut.rstrip(",;:-") + "…"
    stance = obj.get("stance")
    return {"say": say,
            "stance": stance if stance in STANCES else None,
            "remember": obj.get("remember") if isinstance(obj.get("remember"), dict) else None,
            "forget": obj.get("forget") if isinstance(obj.get("forget"), list) else None}


def say_timeout(text: str) -> float:
    return round(max(4.0, min(12.0, 2.5 + len(text) / 15.0)), 1)


# ── the situation, in plain words ───────────────────────────────────────────

def _side(bearing) -> str:
    if bearing is None:
        return ""
    deg = math.degrees(bearing)
    if abs(deg) <= 30:
        return "ahead of V"
    if abs(deg) >= 150:
        return "behind V"
    return "to V's left" if deg > 0 else "to V's right"


def digest(obs: dict, stance: str) -> str:
    body, player = obs.get("body") or {}, obs.get("player") or {}
    look = obs.get("look_at") or None
    parts = []
    if body.get("live"):
        where = f"You are {body.get('distance') or 0:.0f} m from V"
        side = _side(body.get("bearing"))
        parts.append(where + (f", {side}." if side else "."))
        if body.get("health") is not None:
            parts.append(f"Your health: {body['health']:.0f}%.")
    else:
        parts.append("Your body is not in the world right now.")
    parts.append("V is in a fight." if player.get("in_combat") else "Nothing is shooting at V.")
    if look and not look.get("is_body") and str(look.get("record") or "").startswith("Character."):
        name = look.get("name") or "someone"
        tone = f", {look['attitude']}" if look.get("attitude") else ""
        dead = ", dead" if look.get("dead") else ""
        parts.append(f"V is looking at {name} ({look.get('distance') or 0:.0f} m{tone}{dead}).")
    elif look and look.get("is_body"):
        parts.append("V is looking at you.")
    parts.append(f"Your stance: {stance}.")
    return " ".join(parts)


# If the model cannot be reached, the default hotkey phrases still work.
FALLBACK = [(("wait", "stay here", "hold"), "hold"),
            (("follow", "stay close", "leaving", "come on", "let's go"), "follow"),
            (("stand down", "at ease"), "idle")]


def fallback_stance(text: str):
    low = text.lower()
    for words, stance in FALLBACK:
        if any(w in low for w in words):
            return stance
    return None


# ── the brain ───────────────────────────────────────────────────────────────

class Event:
    def __init__(self, kind: str, text: str, from_v: bool = False):
        self.kind, self.text, self.from_v = kind, text, from_v


class Brain:
    def __init__(self, board: Board, api, persona: str, notebook: Notebook, recent: Recent,
                 args, clock=time.monotonic, threaded: bool = True):
        self.board, self.api, self.persona = board, api, persona
        self.notebook, self.recent, self.args, self.clock = notebook, recent, args, clock
        self.threaded = threaded

        self.name = args.name or ""
        self.stance, self.mode = "follow", None
        self.prev: dict = {}
        self.dialogue_seq = 0
        self.last_said_seq = None
        self.lines: collections.deque = collections.deque()    # (text, speaker|None)
        self.line_free_at = 0.0
        self.booted = False
        self.pending_arrival = False

        now = clock()
        self.last_spoke = now
        self.cool: dict[str, float] = {}
        self.calls: collections.deque = collections.deque()
        self.stare_since = self.look_since = None
        self.look_name = None
        self.was_lost = False

        self.inbox: queue.Queue = queue.Queue()
        self.outbox: queue.Queue = queue.Queue()
        self.busy = False
        if threaded:
            threading.Thread(target=self._worker, daemon=True).start()

    # ── setup ──
    def request_body(self) -> None:
        a = self.args
        state = self.board.state()
        driver = (state.get("flags") or {}).get("driver")
        if driver and driver != "companion_brain":
            log(f"the board says '{driver}' was driving. Two drivers fight over one body.")
        self.dialogue_seq = int((state.get("dialogue") or {}).get("seq") or 0)
        flags = {"enable_body": True, "body_record": a.record, "body_appearance": a.appearance,
                 "follow_distance": FOLLOW_M, "driver": "companion_brain",
                 "speaker_name": a.name or None}
        self.board.patch({"body": a.body, "flags": flags, "mode": "follow",
                          "target": {"type": "player", "value": None}, "goal": "walk with V"})
        self.mode = "follow"
        log(f"body requested: {a.record} ({a.appearance})")

    def instructions(self) -> str:
        persona = self.persona.replace("{name}", self.name or "the companion")
        return (persona.strip() + "\n" + RULES
                + "\n## Your notebook\n" + self.notebook.text() + "\n")

    # ── speaking ──
    def queue_line(self, text: str, speaker: str | None = None,
                   timeout: float | None = None) -> None:
        if text:
            self.lines.append((text, speaker, timeout or say_timeout(text)))

    def _flush_line(self, now: float) -> None:
        if not self.lines or now < self.line_free_at:
            return
        text, speaker, timeout = self.lines.popleft()
        self.dialogue_seq += 1
        # seq is set by hand: the board only bumps it when the TEXT changes,
        # and she is allowed to say "Okay." twice. speaker_name is set on every
        # line so a boot line's speaker never sticks to the next thing she says;
        # null hands the name back to the mod (the body's own).
        patch = {"dialogue": {"text": text, "emotion": "", "timeout": timeout,
                              "seq": self.dialogue_seq},
                 "flags": {"speaker_name": speaker or self.args.name or None}}
        state = self.board.patch(patch)
        self.dialogue_seq = max(self.dialogue_seq, int((state.get("dialogue") or {}).get("seq") or 0))
        self.line_free_at = now + timeout        # one line on screen at a time
        self.last_spoke = now
        log(f"{speaker or self.name or 'she'}: {text}")

    # ── the model ──
    def _allowed(self, now: float, from_v: bool) -> bool:
        while self.calls and now - self.calls[0] > 3600:
            self.calls.popleft()
        cap = self.args.max_calls_per_hour * (2 if from_v else 1)
        if len(self.calls) >= cap:
            log("model call budget for this hour is spent — staying quiet")
            return False
        if not from_v and self.calls and now - self.calls[-1] < self.args.min_gap_s:
            return False
        return True

    def dispatch(self, event: Event, obs: dict) -> None:
        now = self.clock()
        if not self._allowed(now, event.from_v):
            if event.from_v:
                self._apply_fallback(event)
            return
        self.calls.append(now)
        job = (event, self.instructions(),
               f"{event.text}\n\n[Right now] {digest(obs, self.stance)}")
        if self.threaded:
            self.busy = True
            self.inbox.put(job)
        else:
            self.outbox.put(self._think(job))

    def _think(self, job):
        event, instructions, user_text = job
        try:
            return event, user_text, self.api.turn(instructions, user_text, self.recent), None
        except (ModelError, OSError, ValueError, KeyError) as e:
            return event, user_text, "", e

    def _worker(self) -> None:
        while True:
            job = self.inbox.get()
            self.outbox.put(self._think(job))

    def _apply_fallback(self, event: Event) -> None:
        stance = fallback_stance(event.text)
        if stance:
            self.stance = stance
            log(f"(no model) stance -> {stance}")

    def _collect(self) -> None:
        while True:
            try:
                event, user_text, raw, error = self.outbox.get_nowait()
            except queue.Empty:
                return
            self.busy = not self.inbox.empty()
            if error is not None:
                log(f"model call failed: {error}")
                if event.from_v:
                    self._apply_fallback(event)
                continue
            if not raw.strip():
                log("the model answered with nothing (if it is a thinking model, "
                    "raise --max-tokens: thinking is spent before any text)")
            reply = parse_reply(raw)
            if reply["say"] or event.from_v:
                self.recent.add(event.text, json.dumps({"say": reply["say"]}))
            self.notebook.apply(reply["remember"], reply["forget"])
            # Only V changes what she is doing. A model musing to itself on a
            # quiet street does not get to stop following.
            if event.from_v and reply["stance"] and reply["stance"] != self.stance:
                log(f"stance {self.stance} -> {reply['stance']}")
                self.stance = reply["stance"]
            self.queue_line(reply["say"])

    # ── what woke her ──
    def _cooled(self, kind: str, now: float, seconds: float) -> bool:
        if now - self.cool.get(kind, -1e9) < seconds:
            return False
        self.cool[kind] = now
        return True

    def events(self, obs: dict, now: float) -> list[Event]:
        out: list[Event] = []
        body, player = obs.get("body") or {}, obs.get("player") or {}
        prev_body, prev_player = self.prev.get("body") or {}, self.prev.get("player") or {}
        fighting = bool(player.get("in_combat"))

        # V spoke. On the first report, anything already on the wire is old
        # news unless it was said in the last few seconds.
        said = [s for s in (player.get("said") or []) if isinstance(s, dict) and "seq" in s]
        if self.last_said_seq is None:
            fresh = [s for s in said if (obs.get("clock") or 0) - (s.get("clock") or 0) <= 3.0]
            stale = [s["seq"] for s in said if s not in fresh]
            self.last_said_seq = max(stale, default=0)
        for s in sorted(said, key=lambda s: s["seq"]):
            if s["seq"] > self.last_said_seq:
                self.last_said_seq = s["seq"]
                text = str(s.get("text") or "").strip()
                if text:
                    log(f"V: {text}")
                    out.append(Event("said", f'V says: "{text}"', from_v=True))

        if not body.get("live"):
            self.stare_since = self.look_since = None
            return out

        if fighting and not prev_player.get("in_combat"):
            out.append(Event("combat_start", "A fight just broke out around V. One short line at most."))
        elif not fighting and prev_player.get("in_combat"):
            out.append(Event("combat_end", "The fight is over. V is still standing."))
        if fighting:
            return out                       # no small talk with bullets in the air

        health, before = body.get("health"), prev_body.get("health")
        if health is not None and before is not None and health < 50 <= before \
                and self._cooled("hurt", now, 120):
            out.append(Event("hurt", f"You have been hurt. Your health is at {health:.0f}%."))

        distance = body.get("distance") or 0.0
        if distance > LOST_M:
            self.was_lost = True
        elif self.was_lost and distance < NEAR_M:
            self.was_lost = False
            if self._cooled("reunited", now, 120):
                out.append(Event("reunited", "You just caught up with V after being left behind."))

        look = obs.get("look_at") or {}
        if look.get("is_body"):
            self.stare_since = self.stare_since or now
            if now - self.stare_since >= 4 and self._cooled("stare", now, 90):
                out.append(Event("stare", "V has been looking right at you for a few seconds."))
        else:
            self.stare_since = None
        who = look.get("name") if str(look.get("record") or "").startswith("Character.") \
            and not look.get("is_body") and not look.get("dead") else None
        if who and who == self.look_name:
            if now - (self.look_since or now) >= 5 and self._cooled("looking", now, 150):
                tone = f" They look {look['attitude']}." if look.get("attitude") else ""
                out.append(Event("looking", f"V has been watching {who} for a while.{tone}"))
        else:
            self.look_name, self.look_since = who, (now if who else None)

        quiet_s = self.args.quiet_minutes * 60
        if quiet_s > 0 and now - self.last_spoke >= quiet_s and self._cooled("quiet", now, quiet_s):
            out.append(Event("quiet", "It has been quiet for a while. If you have something "
                                      "to say, say it. If not, stay quiet."))
        return out

    # ── the reflex: no model involved ──
    def reflex(self, obs: dict):
        body, player = obs.get("body") or {}, obs.get("player") or {}
        if not body.get("live"):
            return None
        if player.get("in_combat"):
            return "combat", {"mode": "combat", "goal": "fight beside V"}
        target = {"type": "player", "value": None}
        if self.stance == "follow":
            if (body.get("distance") or 0.0) > LOST_M:
                return "move_to", {"mode": "move_to", "target": target, "goal": "catch up with V"}
            return "follow", {"mode": "follow", "target": target, "goal": "walk with V",
                              "flags": {"follow_distance": FOLLOW_M}}
        if self.stance == "hold":
            return "hold", {"mode": "hold", "goal": "wait here for V"}
        return "idle", {"mode": "idle", "goal": "stand down"}

    # ── one turn of the loop ──
    def step(self) -> None:
        now = self.clock()
        self._collect()
        view = self.board.observed()
        obs, age = view.get("observed"), view.get("age_s")
        if not obs or age is None or age > 5:
            if self._cooled("silent", now, 15):
                log("the game is not reporting (is the relay running? is a save loaded?)")
            return

        body = obs.get("body") or {}
        if body.get("live") and not self.name:
            self.name = str(body.get("name") or self.args.body or "Companion")
        if body.get("live") and not self.booted:
            self.booted = True
            fill = {"body": body.get("name") or self.args.body, "model": self.args.model,
                    "name": self.name}
            for line in BOOT_LINES:
                self.queue_line(line.format(**fill), speaker=BRAND, timeout=2.5)
            self.pending_arrival = not self.args.no_greeting

        events = self.events(obs, now)
        if self.pending_arrival and not self.lines:
            self.pending_arrival = False
            events.append(Event("arrived", "You have just arrived beside V. Greet them your way."))
        from_v = [e for e in events if e.from_v]
        for event in (from_v or events[:1]):         # V first; else one thing at a time
            if event.from_v or not self.busy:
                self.dispatch(event, obs)
        self._collect()

        choice = self.reflex(obs)
        if choice and choice[0] != self.mode:
            mode, patch = choice
            self.board.patch(patch)
            log(f"{self.mode} -> {mode}  ({body.get('distance') or 0:.1f} m)")
            self.mode = mode
        self._flush_line(now)
        self.prev = obs

    def run(self) -> None:
        self.request_body()
        while True:
            try:
                self.step()
            except RuntimeError as e:
                log(str(e))
            except OSError as e:
                log(f"cannot reach the board: {e}")
                time.sleep(2)
            time.sleep(self.args.tick_s)


# ── command line ────────────────────────────────────────────────────────────

APIS = {"chat": ChatAPI, "anthropic": AnthropicAPI, "responses": ResponsesAPI}
# What --max-tokens defaults to per wire. A local chat model answers with the
# line and nothing else, so 400 is plenty. Current Claude models think by
# default and reasoning models on /responses do too — thinking is spent out of
# this budget BEFORE any text, so a small ceiling returns an empty answer and
# she says nothing at all. Room to think, then say one line.
MAX_TOKENS = {"chat": 400, "anthropic": 4096, "responses": 4096}
KEY_ENVS = {"chat": ("COMPANION_API_KEY", "OPENAI_API_KEY"),
            "responses": ("COMPANION_API_KEY", "OPENAI_API_KEY"),
            "anthropic": ("COMPANION_API_KEY", "ANTHROPIC_API_KEY")}


def build_parser() -> argparse.ArgumentParser:
    env = os.environ.get
    ap = argparse.ArgumentParser(description="A companion who answers, for an AnyaBoard body.")
    ap.add_argument("--board", default=env("COMPANION_BOARD", "http://127.0.0.1:8787"))
    ap.add_argument("--api", choices=sorted(APIS), default=env("COMPANION_API", "chat"))
    ap.add_argument("--base-url", default=env("COMPANION_BASE_URL", ""),
                    help="endpoint root; default depends on --api")
    ap.add_argument("--model", default=env("COMPANION_MODEL", ""))
    ap.add_argument("--max-tokens", type=int, default=None,
                    help="default depends on --api: 400 for chat, 4096 where the "
                         "model thinks before it writes (thinking spends this first)")
    ap.add_argument("--persona", default=str(Path(__file__).with_name("persona.md")))
    ap.add_argument("--name", default=env("COMPANION_NAME", ""),
                    help="what she is called; default is the body's own name")
    ap.add_argument("--body", default="judy")
    ap.add_argument("--record", default="Character.Judy")
    ap.add_argument("--appearance", default="judy_default")
    ap.add_argument("--state-dir", default=".companion",
                    help="notebook, recent exchanges and the responses chain id")
    ap.add_argument("--quiet-minutes", type=float, default=8.0,
                    help="speak up after this long with nothing said; 0 = never")
    ap.add_argument("--min-gap-s", type=float, default=20.0,
                    help="least time between model calls V did not ask for")
    ap.add_argument("--max-calls-per-hour", type=int, default=120)
    ap.add_argument("--roll-after", type=int, default=40,
                    help="responses API: start a fresh chain after this many turns")
    ap.add_argument("--no-greeting", action="store_true")
    ap.add_argument("--tick-s", type=float, default=1.0)
    return ap


def main() -> None:
    args = build_parser().parse_args()
    if not args.model:
        sys.exit("--model is required (or set COMPANION_MODEL): the name your endpoint serves")
    # The key comes from the environment, never the command line: command
    # lines end up in shell history and process lists.
    key = next((os.environ[k] for k in KEY_ENVS[args.api] if os.environ.get(k)), "")
    if args.max_tokens is None:
        args.max_tokens = MAX_TOKENS[args.api]
    state_dir = Path(args.state_dir)
    if args.api == "responses":
        api = ResponsesAPI(args.base_url, args.model, key, args.max_tokens,
                           state_dir / "chain.json", roll_after=args.roll_after)
    else:
        api = APIS[args.api](args.base_url, args.model, key, args.max_tokens)
    try:
        persona = Path(args.persona).read_text()
    except OSError:
        persona = DEFAULT_PERSONA
    brain = Brain(Board(args.board), api, persona,
                  Notebook(state_dir / "notebook.json"), Recent(state_dir / "recent.json"), args)
    log(f"api={args.api} model={args.model} -> {api.url}")
    try:
        brain.run()
    except KeyboardInterrupt:
        print("\n[companion] leaving her where she stands")


if __name__ == "__main__":
    main()
