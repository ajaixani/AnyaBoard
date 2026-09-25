#!/usr/bin/env python3
"""
Companion-brain smoke test — the whole loop, without a game or a model.

The brain runs against the REAL board in-process (so every patch meets the
real schema), observations are posted the way the relay posts them, and the
three vendor wire formats are answered by a fake that checks what it was
sent.

    python3 tools/smoke_brain.py
"""

import json
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "board"))
sys.path.insert(0, str(ROOT / "examples"))

from fastapi.testclient import TestClient      # noqa: E402
import main as board_app                       # noqa: E402
import companion_brain as cb                   # noqa: E402

PASSED = FAILED = 0


def case(name, fn):
    global PASSED, FAILED
    try:
        fn()
        PASSED += 1
        print(f"  ok   {name}")
    except Exception as e:                      # noqa: BLE001
        FAILED += 1
        print(f"  FAIL {name}: {e!r}")


cb.log = lambda msg: None                       # quiet


# ── reading the model's answer ───────────────────────────────────────────────
def t_parse():
    r = cb.parse_reply('{"say": "On it.", "stance": "hold", "remember": {"v_name": "Val"}}')
    assert r["say"] == "On it." and r["stance"] == "hold" and r["remember"] == {"v_name": "Val"}
    r = cb.parse_reply('Sure!\n```json\n{"say": "Right behind you.", "stance": "sprint"}\n```')
    assert r["say"] == "Right behind you." and r["stance"] is None, r
    r = cb.parse_reply("<think>hmm {not json}</think>Yeah, I see them too.")
    assert r["say"] == "Yeah, I see them too.", r
    r = cb.parse_reply('{"say": "' + "word " * 100 + '"}')
    assert len(r["say"]) <= cb.SAY_MAX + 1 and r["say"].endswith("…")
    assert cb.parse_reply('{"say": ""}')["say"] == ""
    assert cb.parse_reply('{"say": "a {brace} inside"}')["say"] == "a {brace} inside"
    assert cb.parse_reply("")["say"] == ""


# ── the three wire formats ───────────────────────────────────────────────────
def recent_with_history(tmp):
    r = cb.Recent(Path(tmp) / "recent.json")
    r.add('V says: "name\'s Val"', '{"say": "Val. Got it."}')
    return r


def t_chat():
    seen = []

    def post(url, body, headers):
        seen.append((url, body, headers))
        if "max_tokens" in body and len(seen) == 1:
            return 400, {"error": {"message": "use max_completion_tokens instead"}}
        return 200, {"choices": [{"message": {"content": '{"say": "hi"}'}}]}

    with tempfile.TemporaryDirectory() as tmp:
        api = cb.ChatAPI("http://x/v1/", "m", "k", 300, post=post)
        out = api.turn("SYSTEM", "USER", recent_with_history(tmp))
    assert out == '{"say": "hi"}'
    url, body, headers = seen[-1]
    assert url == "http://x/v1/chat/completions"
    assert headers["Authorization"] == "Bearer k"
    assert body["messages"][0] == {"role": "system", "content": "SYSTEM"}
    assert body["messages"][-1] == {"role": "user", "content": "USER"}
    assert len(body["messages"]) == 4, "recent exchanges ride along"
    assert "max_completion_tokens" in body and "temperature" not in body, "retried the modern way"


def t_anthropic():
    seen = []

    def post(url, body, headers):
        seen.append((url, body, headers))
        return 200, {"content": [{"type": "text", "text": '{"say": "hey"}'}]}

    with tempfile.TemporaryDirectory() as tmp:
        api = cb.AnthropicAPI("", "m", "k", 300, post=post)
        out = api.turn("SYSTEM", "USER", recent_with_history(tmp))
    url, body, headers = seen[0]
    assert out == '{"say": "hey"}'
    assert url == "https://api.anthropic.com/v1/messages"
    assert headers["x-api-key"] == "k" and headers["anthropic-version"]
    assert body["system"][0]["text"] == "SYSTEM" and body["system"][0]["cache_control"]
    assert all(m["role"] in ("user", "assistant") for m in body["messages"])
    assert body["messages"][0]["role"] == "user" and body["max_tokens"] == 300
    assert cb.AnthropicAPI("http://proxy/v1", "m", "", 1, post=post).url == "http://proxy/v1/messages"


def t_truncated_is_loud():
    """A thinking model spends the budget before it writes. That must arrive
    as an error naming the cause, not as a companion who never speaks."""
    def thought_it_all_away(url, body, headers):
        return 200, {"content": [{"type": "thinking", "thinking": "..."}],
                     "stop_reason": "max_tokens"}

    with tempfile.TemporaryDirectory() as tmp:
        api = cb.AnthropicAPI("", "m", "k", 400, post=thought_it_all_away)
        try:
            api.turn("SYSTEM", "USER", recent_with_history(tmp))
            raise AssertionError("a truncated answer passed as a real one")
        except cb.ModelError as e:
            assert "max_tokens" in str(e) and "--max-tokens" in str(e), e

    def incomplete(url, body, headers):
        return 200, {"status": "incomplete",
                     "incomplete_details": {"reason": "max_output_tokens"},
                     "output": []}

    with tempfile.TemporaryDirectory() as tmp:
        api = cb.ResponsesAPI("", "m", "k", 400, Path(tmp) / "chain.json",
                              post=incomplete)
        try:
            api.turn("SYSTEM", "USER", recent_with_history(tmp))
            raise AssertionError("a truncated answer passed as a real one")
        except cb.ModelError as e:
            assert "--max-tokens" in str(e), e

    # and the per-wire defaults exist for exactly this reason
    assert cb.MAX_TOKENS["chat"] < cb.MAX_TOKENS["anthropic"]
    assert cb.MAX_TOKENS["responses"] >= 4096


def t_responses():
    seen, known = [], {"resp_1"}

    def post(url, body, headers):
        seen.append(body)
        prev = body.get("previous_response_id")
        if prev and prev not in known:
            return 404, {"error": {"message": "previous response not found"}}
        rid = f"resp_{len(seen) + 1}"
        known.add(rid)
        return 200, {"id": rid, "output": [
            {"type": "reasoning", "summary": []},
            {"type": "message", "content": [{"type": "output_text", "text": '{"say": "ok"}'}]}]}

    with tempfile.TemporaryDirectory() as tmp:
        recent, chain = recent_with_history(tmp), Path(tmp) / "chain.json"
        api = cb.ResponsesAPI("http://x/v1", "m", "k", 300, chain, roll_after=3, post=post)
        assert api.turn("SYS", "first", recent) == '{"say": "ok"}'
        first = seen[0]
        assert "previous_response_id" not in first and first["store"] is True
        assert first["instructions"] == "SYS" and first["input"].startswith("Earlier, briefly:")
        assert first["input"].endswith("first"), "a fresh chain is seeded from the recent exchanges"

        api.turn("SYS2", "second", recent)
        assert seen[1]["previous_response_id"] == "resp_2" and seen[1]["input"] == "second", \
            "a chained turn sends only what is new"
        assert seen[1]["instructions"] == "SYS2", "instructions are resent every turn"

        again = cb.ResponsesAPI("http://x/v1", "m", "k", 300, chain, post=post)
        assert again.previous == "resp_3" and again.turns == 2, "the chain id survives a restart"
        other = cb.ResponsesAPI("http://x/v1", "different-model", "k", 300, chain, post=post)
        assert other.previous is None, "a different model does not inherit the chain"

        api.turn("SYS", "third", recent)
        api.turn("SYS", "fourth", recent)
        assert "previous_response_id" not in seen[-1], "rolled to a fresh chain after roll_after"

        api.previous = "resp_expired"
        n = len(seen)
        assert api.turn("SYS", "after expiry", recent) == '{"say": "ok"}'
        assert len(seen) == n + 2 and "previous_response_id" not in seen[-1], \
            "an unknown id falls back to a fresh chain, once"


# ── the brain against the real board ─────────────────────────────────────────
class FakeModel:
    url = "fake://model"

    def __init__(self):
        self.replies, self.seen, self.fail = [], [], False

    def turn(self, instructions, user_text, recent):
        self.seen.append((instructions, user_text))
        if self.fail:
            raise cb.ModelError("503: down")
        return self.replies.pop(0) if self.replies else '{"say": ""}'


def args(**over):
    base = dict(name="", body="judy", record="Character.Judy", appearance="judy_default",
                model="test-model", quiet_minutes=0.0, min_gap_s=20.0, max_calls_per_hour=120,
                no_greeting=False, tick_s=0.0)
    base.update(over)
    return SimpleNamespace(**base)


def observation(clock=10.0, live=True, distance=3.0, combat=False, said=None, look=None, health=100):
    obs = {"v": 1, "clock": clock, "frame": 1, "board_seq": 0,
           "player": {"pos": [0, 0, 0], "heading": 0, "view_heading": 0, "in_combat": combat},
           "body": {"live": live, "mode": "follow", "pending": None}}
    if live:
        obs["body"].update(name="Judy Alvarez", record="Character.Judy", distance=distance,
                           bearing=0.5, dz=0, health=health, dead=False, attitude="friendly")
    if said:
        obs["player"]["said"] = said
    if look:
        obs["look_at"] = look
    return obs


def rig(tmp, **over):
    client = TestClient(board_app.app)
    client.__enter__()
    client.post("/state/reset")

    def transport(method, path, body):
        r = client.request(method, path, json=body)
        if r.status_code >= 400:
            raise RuntimeError(f"board {method} {path}: {r.status_code} {r.text}")
        return r.json()

    now = [1000.0]
    model = FakeModel()
    brain = cb.Brain(cb.Board("http://board", transport), model, "You are {name}.",
                     cb.Notebook(Path(tmp) / "notebook.json"), cb.Recent(Path(tmp) / "recent.json"),
                     args(**over), clock=lambda: now[0], threaded=False)

    def see(**kw):
        assert client.put("/observed", json=observation(**kw)).status_code == 200

    def tick(seconds=1.0, **kw):
        see(**kw)
        now[0] += seconds
        brain.step()
        return client.get("/state").json()

    return SimpleNamespace(client=client, brain=brain, model=model, tick=tick, now=now)


def t_boot_and_greeting():
    with tempfile.TemporaryDirectory() as tmp:
        r = rig(tmp)
        r.brain.request_body()
        state = r.client.get("/state").json()
        assert state["flags"]["enable_body"] is True and state["flags"]["driver"] == "companion_brain"
        assert state["flags"]["speaker_name"] is None and state["mode"] == "follow"

        assert r.tick(live=False)["dialogue"]["text"] == "", "no body yet: nothing said"
        r.model.replies = ['{"say": "Miss me?"}']
        seen, speakers = [], []
        for _ in range(14):
            s = r.tick()
            if s["dialogue"]["text"] and (not seen or seen[-1] != s["dialogue"]["text"]):
                seen.append(s["dialogue"]["text"])
                speakers.append(s["flags"]["speaker_name"])
        assert seen[0] == "companion link // handshake ok", seen
        assert "test-model" in seen[1] and seen[2] == "Judy Alvarez online.", seen
        assert speakers[:3] == [cb.BRAND] * 3, "boot lines are spoken by the brand"
        assert seen[3] == "Miss me?" and speakers[3] is None, \
            "then she greets, and the name goes back to the body's own"
        assert "arrived" in r.model.seen[0][1] and "You are Judy Alvarez." in r.model.seen[0][0]


def quiet_rig(tmp, **over):
    r = rig(tmp, no_greeting=True, **over)
    r.brain.request_body()
    r.brain.booted = True
    r.brain.name = "Judy Alvarez"
    return r


def t_said_and_stance():
    with tempfile.TemporaryDirectory() as tmp:
        r = quiet_rig(tmp)
        old = [{"seq": 5, "text": "from before you started", "via": "chat", "clock": 1.0}]
        r.tick(clock=50.0, said=old)
        assert r.model.seen == [], "a line said long before startup is not answered"

        r.model.replies = ['{"say": "Holding.", "stance": "hold", "remember": {"v_name": "Val"}}']
        said = old + [{"seq": 6, "text": "wait here", "via": "hotkey", "clock": 50.5}]
        s = r.tick(clock=51.0, said=said)
        assert 'V says: "wait here"' in r.model.seen[0][1]
        assert "[Right now]" in r.model.seen[0][1] and "3 m from V" in r.model.seen[0][1]
        assert s["dialogue"]["text"] == "Holding." and s["mode"] == "hold", s
        assert s["goal"] == "wait here for V"
        first_seq = s["dialogue"]["seq"]

        s = r.tick(clock=52.0, said=said)
        assert len(r.model.seen) == 1, "the same seq is never answered twice"

        r.model.replies = ['{"say": "Holding."}']
        said.append({"seq": 7, "text": "you sure?", "via": "chat", "clock": 60.0})
        r.now[0] += 20
        s = r.tick(clock=61.0, said=said)
        assert s["dialogue"]["seq"] > first_seq, "the same words twice still show twice"
        assert "v_name: Val" in r.model.seen[1][0], "what she remembered rides the next turn"
        assert json.loads((Path(tmp) / "notebook.json").read_text()) == {"v_name": "Val"}


def t_reflex():
    with tempfile.TemporaryDirectory() as tmp:
        r = quiet_rig(tmp)
        r.brain.stance = "hold"
        assert r.tick()["mode"] == "hold"
        r.model.replies = ['{"say": "Contact!", "stance": "idle"}']
        s = r.tick(combat=True)
        assert s["mode"] == "combat", "a fight overrides a hold"
        assert r.brain.stance == "hold", "only V changes her stance, never an ambient event"
        n = len(r.model.seen)
        look = {"name": "Tyger Claw", "record": "Character.tc", "is_body": True, "dead": False,
                "distance": 5, "bearing": 0, "dz": 0, "attitude": "hostile"}
        for _ in range(8):
            r.tick(combat=True, look=look)
        assert len(r.model.seen) == n, "no small talk while the fight is on"
        r.now[0] += 30
        assert r.tick(combat=False)["mode"] == "hold", "and she goes back to holding after"

        r.brain.stance = "follow"
        assert r.tick(distance=40.0)["mode"] == "move_to", "left behind: come to V"
        assert r.tick(distance=4.0)["mode"] == "follow"


def t_ambient_is_paced():
    with tempfile.TemporaryDirectory() as tmp:
        r = quiet_rig(tmp)
        me = {"name": "Judy Alvarez", "record": "Character.Judy", "is_body": True, "dead": False,
              "distance": 3, "bearing": 0, "dz": 0, "attitude": "friendly"}
        for _ in range(6):
            r.tick(look=me)
        assert len(r.model.seen) == 1 and "looking right at you" in r.model.seen[0][1]
        r.tick(health=40)
        assert len(r.model.seen) == 1, "a second unasked-for call waits out the gap"
        said = [{"seq": 9, "text": "you ok?", "via": "chat", "clock": 10.0}]
        r.tick(said=said)
        assert len(r.model.seen) == 2, "V is never made to wait for the gap"


def t_model_down():
    with tempfile.TemporaryDirectory() as tmp:
        r = quiet_rig(tmp)
        r.model.fail = True
        s = r.tick(said=[{"seq": 3, "text": "Wait here.", "via": "hotkey", "clock": 10.0}])
        assert s["mode"] == "hold", "with the model down the stock phrases still work"
        assert s["dialogue"]["text"] == ""
        s = r.tick(said=[{"seq": 4, "text": "Follow me.", "via": "hotkey", "clock": 10.0}])
        assert s["mode"] == "follow"


def t_stale_game():
    with tempfile.TemporaryDirectory() as tmp:
        r = quiet_rig(tmp)
        r.client.post("/state/reset")
        r.brain.step()                     # nothing observed yet: must not throw
        assert r.client.get("/state").json()["mode"] == "idle"


print("companion brain smoke")
case("the model's answer is read forgivingly", t_parse)
case("chat completions wire", t_chat)
case("anthropic messages wire", t_anthropic)
case("responses wire: chained, persisted, rolled, recovered", t_responses)
case("a truncated answer is loud, not silence", t_truncated_is_loud)
case("boot sequence, then a greeting, then her own name", t_boot_and_greeting)
case("V speaks: answered once, stance obeyed, notebook kept", t_said_and_stance)
case("reflex: fights, returns, catches up", t_reflex)
case("unasked-for calls are paced; V never waits", t_ambient_is_paced)
case("model down: stock phrases still steer her", t_model_down)
case("no game reporting: quiet, not a crash", t_stale_game)
print(f"\n{PASSED} passed, {FAILED} failed")
sys.exit(1 if FAILED else 0)
