# AnyaBoard

**A body in Night City that something else can drive.**

AnyaBoard is a Cyberpunk 2077 mod plus a small HTTP service. The mod spawns
an NPC, hands it to the game's own AI, and takes its orders from a *state
board* over the network. Anything that can speak HTTP — a script, an agent
loop, a language model, a stream chat — can walk a companion around Night
City, talk through her, and read back what the game sees.

It needs **Cyber Engine Tweaks** and nothing else. No AMM, no REDscript,
no game files touched.

```
your program  ──PATCH /state──>  board  ──state.json──>  CET mod  ──>  the body
              <──GET /observed──         <──observed.json──        <──  the game
```

- **Commands** are coarse and few: follow, hold, move to, fight, spawn,
  despawn, say a line. The game does the walking, the pathfinding and the
  shooting — you set intent, not joints.
- **Reports** come back twice a second: where the player is and which way
  they face, where the body is relative to them, its health, whether the
  player is in a fight, what they are looking at.
- **You can talk to her.** A chat window in the CET overlay and six hotkey
  phrases put what you say on the wire; whatever is driving answers through
  the body's on-screen line. The mod itself never answers.

Why a file relay in the middle: a CET mod cannot open a socket, but it can
read and write inside its own mod folder. A small PowerShell script carries
the JSON both ways.

## Quick start

Two machines or one; the board just has to be reachable from the game PC.

**1. The board** (any machine the game PC can reach):

```bash
docker compose up -d board        # docker compose stop board when you're done
```

or without Docker:

```bash
cd board
uv sync                       # or: pip install -r requirements.txt
uv run python main.py --host 0.0.0.0 --port 8787
```

`curl http://<board-host>:8787/health` should answer.

**2. The mod** (the game PC): copy `cet/AnyaBoard/` into

```
<Cyberpunk 2077>/bin/x64/plugins/cyber_engine_tweaks/mods/AnyaBoard/
```

**3. The relay** (the game PC): edit `BOARD` and `OUT` in
`relay/tower_relay.cmd` — `OUT` is the `state.json` **inside that mod
folder** — then run it and leave it open. No Python needed on Windows.

**4. In game:** load a save, open the CET console, **Reload all mods**.
You should see `init — AnyaBoard v0.8` and then ticks.

**5. Drive her** from the board machine:

```bash
python3 tools/boardctl.py patch '{"body":"judy","flags":{"enable_body":true,
  "body_record":"Character.Judy","body_appearance":"judy_default","follow_distance":3.0}}'
python3 tools/boardctl.py follow
python3 tools/boardctl.py say "Try not to die out here."
python3 tools/boardctl.py hold
python3 tools/boardctl.py watch          # what the game is reporting, live
```

A body should be standing next to V, following you, with your line on screen.

**6. Or let a program drive her:**

```bash
python3 examples/simple_brain.py --board http://127.0.0.1:8787
```

Fifty lines, standard library only: she keeps pace, holds when you get far
enough ahead, and joins your fights. Read it as the protocol in miniature.

**7. Or give her a voice:**

```bash
python3 examples/companion_brain.py --api chat \
    --base-url http://127.0.0.1:1234/v1 --model <the model your server has loaded>
```

Open the CET overlay and there is an **AnyaBoard chat** window: type a line,
press Enter, and she answers on screen. Bind the six phrase keys in CET's
**Bindings** tab ("AnyaBoard: say phrase 1…6") and you can talk to her
without opening anything; edit the phrases in the same window.

`companion_brain.py` is one file with no dependencies. A reflex keeps her
walking and fighting with no model at all; a language model is woken only
when something happens (you spoke, she arrived, a fight started or ended,
you have been staring at her) and answers with one line and, if you asked,
a new stance. She keeps a small notebook between sessions. Who she is lives
in `examples/persona.md` — rewrite it.

It speaks three wire formats, so nobody is locked out:

| `--api` | Talks to | Notes |
|---|---|---|
| `chat` | `/chat/completions` — LM Studio, Ollama, llama.cpp, OpenRouter, most vendors | default base `http://127.0.0.1:1234/v1` |
| `anthropic` | Anthropic's `/v1/messages` | system prompt marked cacheable; a thinking model spends `--max-tokens` before it writes, so it defaults to 4096 here |
| `responses` | `/responses`, chained by `previous_response_id` | the server keeps the conversation: she picks up where you left off across restarts, and each turn sends only what is new |

The API key is read from `COMPANION_API_KEY` (or `OPENAI_API_KEY` /
`ANTHROPIC_API_KEY`), never from the command line. `--max-calls-per-hour`
and `--min-gap-s` keep a paid endpoint from running away with your money.

About `responses`: point it at a server you run and the continuity is yours
to keep. With a hosted vendor the stored conversation lives on their
servers, and a chained turn is still billed for the context it builds on —
chaining saves bandwidth and latency, prompt caching is what saves money.

## What's here

| Path | What |
|---|---|
| `cet/AnyaBoard/` | The mod. Install this folder in CET's `mods/` |
| `board/` | The state board (FastAPI): one JSON document, plus what the game reports |
| `Dockerfile`, `docker-compose.yml` | The board as a container, up only when you want it |
| `relay/` | The Windows relay, both directions, in PowerShell |
| `tools/boardctl.py` | Drive and watch the board from a terminal |
| `tools/cet_harness.lua` | Runs the mod outside the game in a stubbed CET sandbox — 254 checks |
| `examples/simple_brain.py` | A tiny program that drives a body |
| `examples/companion_brain.py`, `persona.md` | A companion who answers: reflex + a language model, three vendor formats |
| `tools/smoke_brain.py` | The companion's whole loop against the real board, no game or model needed |
| `docs/PROTOCOL.md` | Every field, both directions |
| `docs/CET-NOTES.md` | What CET does and does not allow, learned the hard way |
| `docs/probes/` | Raw in-game measurements behind the design |

## Bodies

Any TweakDB character record works — `Character.Judy`, `Character.Panam`, a
Tiger Claw, anything you can find. `flags.body_appearance` picks the look;
without it the game chooses, and its choice can be a quest outfit. Point at
an NPC in game and run `GetMod("AnyaBoard"):inspectTarget()` to read the
record off whoever you are looking at.

Story characters inside a scene cannot be driven — the scene owns them —
which is why the mod spawns a copy instead of possessing the original.

## Before you edit the mod

```bash
brew install lua        # or apt install lua5.4
lua tools/cet_harness.lua cet/AnyaBoard/init.lua
```

The harness stubs CET at its worst — `io` chrooted to the mod folder, no
`io.popen`, no `json`, no `debug` — then drives `onInit` and thousands of
frames, the board-to-body path, the perception writer, the chat window
(against a fake ImGui) and the spawn bench.
Every trip to the game PC it saves is worth it.

In game, `GetMod("AnyaBoard"):status()` says what is wrong, and
`GetMod("AnyaBoard"):bench()` measures spawning, resolution timing and the
AI command shapes, writing `bench.log` beside the mod.

## Before you put it on a network

The board has **no authentication**, allows any origin, and binds `0.0.0.0`
by default so the game PC can reach it. Anyone who can reach that port can
spawn a body next to you, move it, and put words on your screen. That is
fine on a home network and wrong on anything else:

- Bind it to one interface (`--host 192.168.1.10`), or keep it on a private
  network such as Tailscale.
- Don't port-forward it, and don't run it on a shared or public network.
- Nothing here talks to the internet on its own. The only outbound calls are
  the ones your brain makes to whatever model endpoint you point it at, and
  your API key comes from the environment — never from the command line, so
  it stays out of shell history and process lists.

## Connecting your own brain

The board is the whole interface: `PATCH /state` to command, `GET
/observed` to perceive, `GET /observed/events` for a stream. See
`docs/PROTOCOL.md`. Nothing about the mod assumes any particular kind of
program on the other end.

This came out of a companion project where the body is one seat of a larger
mind — voice, memory, an agent loop — but that half is not here and is not
needed. What is here is the body and its wire.

## License

MIT — see `LICENSE`.
