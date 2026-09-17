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
You should see `init — AnyaBoard v0.7` and then ticks.

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

## What's here

| Path | What |
|---|---|
| `cet/AnyaBoard/` | The mod. Install this folder in CET's `mods/` |
| `board/` | The state board (FastAPI): one JSON document, plus what the game reports |
| `Dockerfile`, `docker-compose.yml` | The board as a container, up only when you want it |
| `relay/` | The Windows relay, both directions, in PowerShell |
| `tools/boardctl.py` | Drive and watch the board from a terminal |
| `tools/cet_harness.lua` | Runs the mod outside the game in a stubbed CET sandbox — 210 checks |
| `examples/simple_brain.py` | A tiny program that drives a body |
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
frames, the board-to-body path, the perception writer and the spawn bench.
Every trip to the game PC it saves is worth it.

In game, `GetMod("AnyaBoard"):status()` says what is wrong, and
`GetMod("AnyaBoard"):bench()` measures spawning, resolution timing and the
AI command shapes, writing `bench.log` beside the mod.

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
