# AnyaBoard — CET mod (v0.8)

Polls the state board and drives a spawned body. Stock CET, no AMM.

v0.8 adds a way to talk. Open the CET overlay for the **AnyaBoard chat**
window: both sides of the conversation, a box to type in. Six hotkey slots
("AnyaBoard: say phrase 1…6" in CET's **Bindings** tab) say a stored phrase
with the overlay closed; edit the phrases in the window, they are saved to
`phrases.json` in this folder. What you say goes up in `observed.json` as
`player.said`. The mod never answers — whatever drives the board does.
The on-screen line is prefixed with the body's own name; set
`speakerName` in the config, or `flags.speaker_name` on the board, to
call her something else. `chatHud = true` keeps the log on screen with the
overlay closed.

v0.7 adds perception: every 500 ms it writes `observed.json` beside
`state.json` — where the player is and which way they face, where this body
is relative to them, its health and attitude, what the player is looking at —
for the relay to send to the board. Verified in game.

v0.6: record names are checked against `TweakDB:GetRecord` and
refused loudly if missing; follow sets `desiredDistance` /
`stopWhenDestinationReached=false`; combat marks the body friendly and sends a combat
command at the look-at threat. Field names are guesses until `Dump` confirms them.

Why each earlier version went silent, and the fixes: see `docs/CET-NOTES.md`.

Install this folder to:
```
<Cyberpunk 2077>/bin/x64/plugins/cyber_engine_tweaks/mods/AnyaBoard/
```

Leave `useFile = true`. Relay `OUT` must be this folder's `state.json`.

```lua
local a = GetMod("AnyaBoard")
a:status()
a:inspectTarget()          -- look at a combat NPC, not a scene puppet
a:bindTargetAs("judy")     -- prints the boardctl line that makes it permanent
a:trySpawn()
a:tryDrive("follow")
a:bench()                  -- spawn/resolve/despawn matrix + command dumps -> bench.log
a:say("wait here")         -- say a line without the chat window
```

Run the harness before walking to the tower:

```bash
lua tools/cet_harness.lua cet/AnyaBoard/init.lua
```

## Troubleshooting

| Symptom | Meaning |
|---------|---------|
| No `[AnyaBoard] init` at all | Wrong install path, folder not named `AnyaBoard`, or CET scripts off |
| Init prints, then silence, no `polling every` line | `onInit` aborted — old `init.lua` |
| `no  state.json (not found / not readable)` | Relay not running, or its `OUT` is not this folder |
| `curl health FAIL` / `io.popen not available` | Expected on stock CET — use the file relay |
| `GetMod("AnyaBoard")` is nil | Folder name is wrong or the mod failed to load |
| `no TweakDB record named …` | The record name is wrong — read it off a live NPC with `inspectTarget()` |
| `resolves no` in `status()` | Spawn returned an id that never became an entity — run `bench()` |
| No chat window in the overlay | `enableChat = false`, or this CET build has no ImGui; `a:say("…")` still works |
| You type and nothing answers | The mod only carries your words up. Something must be driving: run `examples/companion_brain.py` |
| Phrase keys do nothing | Bind them in CET > Bindings; they fire with the overlay **closed** |
| `chat draw error` in the log | An ImGui call this build lacks. The window is skipped, the rest of the mod runs; report the line |

`local a = GetMod("AnyaBoard"); print(a._frame, a.tickCount)` — `_frame` 0 means
`onUpdate` never ran; `_frame` rising with `tickCount` stuck means the poll never trips.
